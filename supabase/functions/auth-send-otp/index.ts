// ═════════════════════════════════════════════════════════════════════════
// Authentica Send OTP — وسيط بين الفرونتند و Authentica
// يرسل OTP عبر SMS أو WhatsApp ويسجّل الطلب في otp_requests
// ═════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const AUTHENTICA_API_KEY        = Deno.env.get("AUTHENTICA_API_KEY")!;
const AUTHENTICA_BASE           = "https://api.authentica.sa/api/v2";

const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const RATE_LIMIT_MAX = 3;   // max OTPs per phone in N minutes
const RATE_LIMIT_MIN = 10;

function normalizePhone(raw: string): string | null {
  if (!raw) return null;
  let digits = raw.replace(/[^\d+]/g, "");
  if (!digits.startsWith("+")) {
    if (digits.startsWith("00")) digits = "+" + digits.slice(2);
    else if (digits.startsWith("966")) digits = "+" + digits;
    else if (digits.startsWith("0")) digits = "+966" + digits.slice(1);
    else if (digits.length === 9) digits = "+966" + digits;
    else digits = "+" + digits;
  }
  // Basic Saudi mobile validation
  if (!/^\+966[5][0-9]{8}$/.test(digits)) return null;
  return digits;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")
    return new Response("Method not allowed", { status: 405, headers: CORS });

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    const { phone, channel = "sms", context = "login" } = await req.json();

    const normalized = normalizePhone(phone);
    if (!normalized) {
      return new Response(JSON.stringify({ success: false, error: "رقم جوال غير صحيح" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    if (channel !== "sms" && channel !== "whatsapp") {
      return new Response(JSON.stringify({ success: false, error: "قناة غير مدعومة" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // Rate limit
    const { data: rateData } = await sb.rpc("otp_recent_count", {
      phone_in: normalized, minutes_in: RATE_LIMIT_MIN,
    });
    if ((rateData ?? 0) >= RATE_LIMIT_MAX) {
      return new Response(JSON.stringify({
        success: false,
        error: `تم تجاوز الحد المسموح. حاول بعد ${RATE_LIMIT_MIN} دقائق.`,
      }), { status: 429, headers: { ...CORS, "Content-Type": "application/json" } });
    }

    // Cleanup old (best effort)
    sb.rpc("otp_cleanup_expired").then(() => {}).catch(() => {});

    // Call Authentica Send OTP
    // method: 'sms' or 'whatsapp', phone in international format
    const authRes = await fetch(`${AUTHENTICA_BASE}/send-otp`, {
      method: "POST",
      headers: {
        "X-Authorization": AUTHENTICA_API_KEY,
        "Accept": "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: channel,
        phone:  normalized,
        // Optional: template_id, fallback_phone, fallback_email, custom otp
      }),
    });

    const authData = await authRes.json().catch(() => ({}));

    if (!authRes.ok || authData?.success === false) {
      const errMsg = authData?.message
                  || authData?.errors?.[0]?.message
                  || `فشل إرسال الرمز (HTTP ${authRes.status})`;
      // Log the failed attempt
      await sb.from("otp_requests").insert({
        phone:    normalized,
        channel,
        status:   "failed",
        context,
        provider_ref: null,
        ip_address:   req.headers.get("x-forwarded-for") || null,
        user_agent:   req.headers.get("user-agent") || null,
      });
      return new Response(JSON.stringify({ success: false, error: errMsg }), {
        status: 502, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // Log successful send
    await sb.from("otp_requests").insert({
      phone:    normalized,
      channel,
      status:   "sent",
      context,
      ip_address:   req.headers.get("x-forwarded-for") || null,
      user_agent:   req.headers.get("user-agent") || null,
    });

    return new Response(JSON.stringify({
      success: true,
      phone:   normalized,
      channel,
      message: `تم إرسال الرمز عبر ${channel === "sms" ? "SMS" : "واتساب"}`,
    }), { headers: { ...CORS, "Content-Type": "application/json" } });

  } catch (e) {
    console.error("auth-send-otp error:", e);
    return new Response(JSON.stringify({ success: false, error: (e as Error).message }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});

// ═════════════════════════════════════════════════════════════════════════
// Authentica Verify OTP — يتحقق من الرمز وينشئ Supabase session
// بعد التحقق، يستخدم admin API لإنشاء/تسجيل دخول المستخدم
// ═════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY")!;
const AUTHENTICA_API_KEY        = Deno.env.get("AUTHENTICA_API_KEY")!;
const AUTHENTICA_BASE           = "https://api.authentica.sa/api/v2";

const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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
  if (!/^\+966[5][0-9]{8}$/.test(digits)) return null;
  return digits;
}

// Synthetic email for phone-only users (so we can use email-based session creation)
function phoneToEmail(phone: string): string {
  const cleanPhone = phone.replace(/[^\d]/g, "");
  return `phone_${cleanPhone}@mahsob.sa`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")
    return new Response("Method not allowed", { status: 405, headers: CORS });

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    const { phone, otp, context = "login" } = await req.json();

    const normalized = normalizePhone(phone);
    if (!normalized) {
      return new Response(JSON.stringify({ success: false, error: "رقم جوال غير صحيح" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    if (!otp || !/^\d{4,8}$/.test(String(otp))) {
      return new Response(JSON.stringify({ success: false, error: "رمز تحقق غير صحيح" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // 1. Verify with Authentica
    const authRes = await fetch(`${AUTHENTICA_BASE}/verify-otp`, {
      method: "POST",
      headers: {
        "X-Authorization": AUTHENTICA_API_KEY,
        "Accept": "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        phone: normalized,
        otp:   String(otp),
      }),
    });

    const authData = await authRes.json().catch(() => ({}));
    const verified = authRes.ok && (authData?.status === true || authData?.success === true);

    if (!verified) {
      const errMsg = authData?.message
                  || authData?.errors?.[0]?.message
                  || "رمز غير صحيح أو منتهي الصلاحية";
      return new Response(JSON.stringify({ success: false, error: errMsg }), {
        status: 401, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // 2. Update OTP log
    await sb.from("otp_requests").update({
      status:      "verified",
      verified_at: new Date().toISOString(),
    }).eq("phone", normalized).eq("status", "sent");

    // 3. Find or create Supabase user
    const syntheticEmail = phoneToEmail(normalized);

    // Try find by phone first
    const { data: existingByPhone } = await sb.auth.admin.listUsers({ page: 1, perPage: 200 });
    let user = existingByPhone?.users?.find(u => u.phone === normalized.replace("+", "") || u.email === syntheticEmail);

    if (!user) {
      // Create new user
      const { data: newUser, error: createErr } = await sb.auth.admin.createUser({
        email:         syntheticEmail,
        phone:         normalized.replace("+", ""),
        phone_confirm: true,
        email_confirm: true,
        user_metadata: { auth_via: "authentica_phone_otp", context },
      });
      if (createErr) {
        console.error("createUser error:", createErr);
        return new Response(JSON.stringify({ success: false, error: "فشل إنشاء الحساب: " + createErr.message }), {
          status: 500, headers: { ...CORS, "Content-Type": "application/json" },
        });
      }
      user = newUser.user;
    }

    if (!user) {
      return new Response(JSON.stringify({ success: false, error: "تعذّر إنشاء الحساب" }), {
        status: 500, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // 4. Generate a magic-link / session for this user
    const { data: linkData, error: linkErr } = await sb.auth.admin.generateLink({
      type:  "magiclink",
      email: user.email!,
    });

    if (linkErr || !linkData) {
      console.error("generateLink error:", linkErr);
      return new Response(JSON.stringify({ success: false, error: "فشل إنشاء جلسة الدخول" }), {
        status: 500, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // Extract tokens from magic link (Supabase puts them in the URL fragment)
    // We'll use verifyOtp on the action_link's hashed_token to get a session
    const hashedToken = linkData.properties?.hashed_token;
    if (!hashedToken) {
      return new Response(JSON.stringify({ success: false, error: "فشل استخراج رمز الجلسة" }), {
        status: 500, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // Use anon client to verify the magic link and get session tokens
    const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: sessionData, error: sessionErr } = await anonClient.auth.verifyOtp({
      type:         "magiclink",
      token_hash:   hashedToken,
    });

    if (sessionErr || !sessionData?.session) {
      console.error("verifyOtp magiclink error:", sessionErr);
      return new Response(JSON.stringify({ success: false, error: "فشل إنشاء الجلسة" }), {
        status: 500, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({
      success: true,
      user: {
        id:    user.id,
        email: user.email,
        phone: normalized,
      },
      session: {
        access_token:  sessionData.session.access_token,
        refresh_token: sessionData.session.refresh_token,
        expires_at:    sessionData.session.expires_at,
      },
    }), { headers: { ...CORS, "Content-Type": "application/json" } });

  } catch (e) {
    console.error("auth-verify-otp error:", e);
    return new Response(JSON.stringify({ success: false, error: (e as Error).message }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});

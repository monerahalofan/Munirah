// ═════════════════════════════════════════════════════════════════════════
// Daily Reminder Cron — يتشغّل كل ساعة، يرسل واتساب للمستخدمين اللي ما سجلوا
// Schedule via Supabase Dashboard → Edge Functions → Cron: "0 * * * *"
// ═════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WHATSAPP_PROVIDER         = Deno.env.get("WHATSAPP_PROVIDER") || "unifonic"; // unifonic | twilio | messagebird
const WHATSAPP_API_KEY          = Deno.env.get("WHATSAPP_API_KEY") || "";
const WHATSAPP_FROM             = Deno.env.get("WHATSAPP_FROM") || "Mahsob";

const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function buildMessage(tenantName: string): string {
  return `📊 محسوب\n\nأهلاً ${tenantName} 👋\n\nلاحظنا إنك ما سجلتي أي عمليات اليوم. خلّيها 30 ثانية تتابعين تدفقك المالي:\n\n• سجلي إيراد أو مصروف\n• ارفعي إغلاق يومي\n• راجعي فواتيرك\n\nادخلي الآن: https://mahsob.sa/app\n\n— لإيقاف التذكيرات: من الإعدادات داخل التطبيق`;
}

async function sendViaUnifonic(phone: string, message: string): Promise<{ ok: boolean; ref?: string; error?: string }> {
  // https://docs.unifonic.com/reference/whatsapp
  try {
    const res = await fetch("https://el.cloud.unifonic.com/rest/Messages/messages", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        AppSid:      WHATSAPP_API_KEY,
        Recipient:   phone.replace(/^\+/, ""),
        Body:        message,
        SenderID:    WHATSAPP_FROM,
        Channel:     "whatsapp",
      }),
    });
    const data = await res.json();
    if (!res.ok || data.success === "false") return { ok: false, error: data.message || data.errorCode };
    return { ok: true, ref: data.data?.MessageID };
  } catch (e) { return { ok: false, error: (e as Error).message }; }
}

async function sendViaTwilio(phone: string, message: string): Promise<{ ok: boolean; ref?: string; error?: string }> {
  // https://www.twilio.com/docs/whatsapp/api
  const sid   = Deno.env.get("TWILIO_ACCOUNT_SID") || "";
  const token = Deno.env.get("TWILIO_AUTH_TOKEN") || "";
  const from  = Deno.env.get("TWILIO_WHATSAPP_FROM") || ""; // whatsapp:+1415xxxxxxx
  try {
    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(`${sid}:${token}`),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        From: from,
        To:   `whatsapp:${phone}`,
        Body: message,
      }),
    });
    const data = await res.json();
    if (!res.ok) return { ok: false, error: data.message };
    return { ok: true, ref: data.sid };
  } catch (e) { return { ok: false, error: (e as Error).message }; }
}

async function sendWhatsApp(phone: string, message: string) {
  if (WHATSAPP_PROVIDER === "twilio") return sendViaTwilio(phone, message);
  return sendViaUnifonic(phone, message);
}

Deno.serve(async (_req) => {
  try {
    const { data: candidates, error } = await sb.from("tenants_needing_reminder").select("*");
    if (error) throw error;
    if (!candidates || candidates.length === 0) {
      return new Response(JSON.stringify({ ok: true, sent: 0, message: "No reminders due" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const results: any[] = [];
    for (const t of candidates) {
      if (!t.reminder_phone) continue;
      const channels = Array.isArray(t.reminder_channels) ? t.reminder_channels : [];
      if (!channels.includes("whatsapp")) continue;

      const msg = buildMessage(t.name || "صديقنا");
      const sendRes = await sendWhatsApp(t.reminder_phone, msg);

      // Log result
      await sb.from("reminder_log").insert({
        tenant_id:    t.tenant_id,
        channel:      "whatsapp",
        for_date:     t.for_date,
        status:       sendRes.ok ? "sent" : "failed",
        provider_ref: sendRes.ref || null,
        message:      msg,
      });

      if (sendRes.ok) {
        await sb.from("tenants").update({ last_reminder_sent_at: new Date().toISOString() }).eq("id", t.tenant_id);
      }

      results.push({ tenant_id: t.tenant_id, ok: sendRes.ok, error: sendRes.error });
    }

    return new Response(JSON.stringify({ ok: true, sent: results.length, results }), {
      headers: { "Content-Type": "application/json" },
    });

  } catch (e) {
    console.error("daily-reminder-cron error:", e);
    return new Response(JSON.stringify({ ok: false, error: (e as Error).message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

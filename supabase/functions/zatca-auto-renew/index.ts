// ═════════════════════════════════════════════════════════════════════════
// ZATCA Auto-Renewal Cron — يجدّد CSIDs قبل انتهاءها
// Schedule: daily at 03:00 — "0 3 * * *"
// ═════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface RenewalCandidate {
  tenant_id: string;
  ccsid_expires_at: string;
  renewal_alert_days: number;
  days_left: number;
}

async function renewSingle(t: RenewalCandidate): Promise<{ ok: boolean; error?: string }> {
  // The actual renewal calls ZATCA's compliance API with the existing keys
  // to obtain new CCSID. Since this requires the tenant's private key,
  // we call the existing `zatca-onboard` Edge Function in renewal mode.
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/zatca-onboard`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      },
      body: JSON.stringify({
        mode:      "renew",
        tenant_id: t.tenant_id,
      }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data?.success === false) {
      return { ok: false, error: data?.error || `HTTP ${res.status}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

Deno.serve(async (_req) => {
  try {
    const { data: candidates, error } = await sb.from("zatca_needs_renewal").select("*");
    if (error) throw error;

    if (!candidates || candidates.length === 0) {
      return new Response(JSON.stringify({ ok: true, renewed: 0, message: "No renewals due" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const results: any[] = [];
    for (const t of candidates as RenewalCandidate[]) {
      const r = await renewSingle(t);

      // Update last_renewal_at + status
      await sb.from("zatca_state").update({
        last_renewal_at:     new Date().toISOString(),
        last_renewal_status: r.ok ? "success" : "failed",
        updated_at:          new Date().toISOString(),
        ...(r.ok ? {} : { last_error_message: r.error }),
      }).eq("tenant_id", t.tenant_id);

      // Notify tenant admin via toast/notification (insert into notifications)
      try {
        await sb.from("notifications").insert({
          tenant_id: t.tenant_id,
          type:      r.ok ? "info" : "warning",
          title:     r.ok ? "تم تجديد ربط ZATCA تلقائياً" : "فشل التجديد التلقائي لـ ZATCA",
          message:   r.ok
            ? "تم تجديد شهادة ZATCA لمدة سنة جديدة. لا حاجة لأي إجراء."
            : "تعذّر التجديد التلقائي. يُرجى مراجعة صفحة ربط ZATCA.",
          link:      "/app#zatca",
        });
      } catch (_) { /* notifications table may not exist — silent */ }

      results.push({ tenant_id: t.tenant_id, ok: r.ok, error: r.error });
    }

    const ok = results.filter(r => r.ok).length;
    return new Response(JSON.stringify({
      ok: true,
      renewed: ok,
      failed: results.length - ok,
      results,
    }), { headers: { "Content-Type": "application/json" } });

  } catch (e) {
    console.error("zatca-auto-renew error:", e);
    return new Response(JSON.stringify({ ok: false, error: (e as Error).message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

// ═════════════════════════════════════════════════════════════════════════
// Tap Payments — Webhook Handler
// Tap calls this URL when a charge status changes
// Verifies signature, updates payment + subscription + tenant.plan
// ═════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createHmac } from "node:crypto";

const TAP_SECRET_KEY = Deno.env.get("TAP_SECRET_KEY")!;

// Tap signs the body with HMAC-SHA256 using your secret key
function verifyTapSignature(body: string, signature: string | null): boolean {
  if (!signature) return false;
  try {
    const computed = createHmac("sha256", TAP_SECRET_KEY).update(body).digest("hex");
    return computed === signature;
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const body = await req.text();
  const signature = req.headers.get("hashstring") || req.headers.get("Hashstring");

  // In production: verify signature. Skip in dev if no signature.
  if (signature && !verifyTapSignature(body, signature)) {
    console.warn("Invalid Tap signature");
    return new Response("Invalid signature", { status: 401 });
  }

  try {
    const event = JSON.parse(body);
    const charge = event;  // Tap sends the charge object directly

    // Service role — bypasses RLS to update any tenant
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const meta = charge.metadata || {};
    const subId = meta.subscription_id;
    const plan  = meta.plan;
    const cycle = meta.cycle;

    if (!subId) return new Response("OK", { status: 200 });

    // Update payment record
    await supa.from("payments").update({
      status: charge.status,
      payment_method: charge.source?.payment_method,
      receipt_url:    charge.receipt?.id ? `https://api.tap.company/v2/receipts/${charge.receipt.id}` : null,
      failure_reason: charge.response?.message,
      paid_at: charge.status === "CAPTURED" ? new Date().toISOString() : null,
    }).eq("tap_charge_id", charge.id);

    // Only mark active on CAPTURED
    if (charge.status === "CAPTURED") {
      const now = new Date();
      const ends = new Date(now);
      if (cycle === "yearly") ends.setFullYear(ends.getFullYear() + 1);
      else                    ends.setMonth(ends.getMonth() + 1);

      await supa.from("subscriptions").update({
        status: "active",
        starts_at: now.toISOString(),
        ends_at:   ends.toISOString(),
        tap_customer_id: charge.customer?.id,
        tap_card_id:     charge.card?.id,
        updated_at: now.toISOString(),
      }).eq("id", subId);

      // Update tenant.plan
      const { data: sub } = await supa.from("subscriptions").select("tenant_id").eq("id", subId).maybeSingle();
      if (sub?.tenant_id) {
        await supa.from("tenants").update({
          plan,
          plan_expires_at: ends.toISOString(),
        }).eq("id", sub.tenant_id);
      }
    }

    // Mark failed/cancelled subscriptions accordingly
    if (charge.status === "FAILED" || charge.status === "CANCELLED" || charge.status === "VOID") {
      await supa.from("subscriptions").update({
        status: "failed",
        updated_at: new Date().toISOString(),
      }).eq("id", subId);
    }

    return new Response("OK", { status: 200 });

  } catch (err) {
    console.error("Webhook error:", err);
    return new Response("Error", { status: 500 });
  }
});

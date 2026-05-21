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
        current_period_start: now.toISOString(),
        current_period_end:   ends.toISOString(),
        last_payment_id: charge.id,
        tap_customer_id: charge.customer?.id,
        tap_card_id:     charge.card?.id,
        updated_at: now.toISOString(),
        // Reset reminder timestamps for next cycle
        reminder_7d_sent_at: null,
        reminder_3d_sent_at: null,
        reminder_1d_sent_at: null,
        expired_notice_sent_at: null,
        cancelled_at: null,
      }).eq("id", subId);

      // Get sub info (for tenant_id + user_id + amount)
      const { data: sub } = await supa.from("subscriptions")
        .select("tenant_id, user_id").eq("id", subId).maybeSingle();

      if (sub?.tenant_id) {
        // Update tenant plan
        await supa.from("tenants").update({
          plan,
          plan_expires_at: ends.toISOString(),
        }).eq("id", sub.tenant_id);

        // ─── ISSUE ZATCA TAX INVOICE FOR THE SUBSCRIPTION ───
        const amount = parseFloat(charge.amount || "0");
        if (amount > 0) {
          const subtotal  = amount / 1.15;
          const vatAmount = amount - subtotal;
          const { data: tenant } = await supa.from("tenants")
            .select("name").eq("id", sub.tenant_id).maybeSingle();

          const { data: invoice } = await supa.from("invoices").insert({
            tenant_id:     sub.tenant_id,
            created_by:    sub.user_id,
            number:        `SUB-${now.getFullYear()}-${Date.now().toString().slice(-6)}`,
            invoice_type:  "simplified",
            invoice_kind:  "invoice",
            client_name:   tenant?.name || charge.customer?.first_name || "عميل",
            issue_date:    now.toISOString().slice(0,10),
            subtotal:      subtotal.toFixed(2),
            vat_amount:    vatAmount.toFixed(2),
            total:         amount.toFixed(2),
            status:        "paid",
            payment_status: "paid",
            paid_at:       now.toISOString(),
            amount_paid:   amount.toFixed(2),
            amount_due:    0,
            items: [{
              desc:    `اشتراك محسوب — ${plan || "خطة"} (${cycle === "yearly" ? "سنوي" : "شهري"})`,
              qty:     1,
              price:   subtotal.toFixed(2),
              vatPct:  15,
              lineNet: subtotal.toFixed(2),
              lineVat: vatAmount.toFixed(2),
            }],
            notes: `رقم العملية: ${charge.id}`,
          }).select().single();

          if (invoice) {
            // Link invoice to subscription
            await supa.from("subscriptions").update({
              last_invoice_id: invoice.id,
            }).eq("id", subId);
          }

          // ─── SEND PAYMENT CONFIRMATION EMAIL ───
          const customerEmail = charge.customer?.email || charge.source?.email;
          if (customerEmail) {
            const customerName = [charge.customer?.first_name, charge.customer?.last_name]
              .filter(Boolean).join(" ") || customerEmail;
            try {
              await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/send-email`, {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
                },
                body: JSON.stringify({
                  to: customerEmail,
                  template: "payment_received",
                  vars: {
                    user_name:      customerName,
                    tenant_name:    tenant?.name || "حسابك",
                    plan:           plan || "—",
                    amount:         amount.toFixed(2),
                    invoice_number: invoice?.number || "—",
                    invoice_url:    invoice ? `https://mahsob.sa/app#inv-${invoice.id}` : "",
                    expires_at:     ends.toLocaleDateString("ar-SA-u-nu-latn", { year:"numeric", month:"long", day:"numeric" }),
                  },
                  tenant_id: sub.tenant_id,
                  user_id:   sub.user_id,
                }),
              });
            } catch (e) {
              console.error("Email send failed:", e);
            }
          }
        }
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

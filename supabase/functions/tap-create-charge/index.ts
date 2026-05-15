// ═════════════════════════════════════════════════════════════════════════
// Tap Payments — Create Charge
// Called from frontend when user clicks "Subscribe"
// Creates a charge in Tap and returns the redirect URL for hosted checkout
// ═════════════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TAP_SECRET_KEY = Deno.env.get("TAP_SECRET_KEY")!;
const TAP_API        = "https://api.tap.company/v2/charges";
const SITE_URL       = Deno.env.get("SITE_URL") || "https://mahsob.sa";

const PLANS = {
  starter:  { name: "مبتدئ",     price_monthly: 99,   price_yearly: 990  },
  pro:      { name: "احترافي",   price_monthly: 249,  price_yearly: 2490 },
  business: { name: "أعمال",     price_monthly: 499,  price_yearly: 4990 },
};

const cors = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST")
    return new Response("Method not allowed", { status: 405, headers: cors });

  try {
    // Auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Not authenticated");

    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user } } = await supa.auth.getUser();
    if (!user) throw new Error("Not authenticated");

    const { plan, cycle } = await req.json();
    const planDef = PLANS[plan as keyof typeof PLANS];
    if (!planDef) throw new Error("Invalid plan");
    if (cycle !== "monthly" && cycle !== "yearly") throw new Error("Invalid cycle");

    const amount = cycle === "yearly" ? planDef.price_yearly : planDef.price_monthly;

    // Get tenant info
    const { data: tenant } = await supa.from("tenants").select("*")
      .eq("owner_id", user.id).maybeSingle();
    if (!tenant) throw new Error("No tenant found");

    // Create pending subscription record
    const { data: sub, error: subErr } = await supa.from("subscriptions").insert({
      tenant_id: tenant.id,
      plan,
      billing_cycle: cycle,
      amount_sar: amount,
      status: "pending",
    }).select().single();
    if (subErr) throw subErr;

    // Build Tap charge payload
    const chargePayload = {
      amount,
      currency: "SAR",
      threeDSecure: true,
      save_card: true,
      description: `اشتراك محسوب — باقة ${planDef.name} (${cycle === "yearly" ? "سنوي" : "شهري"})`,
      statement_descriptor: "Mahsoob",
      metadata: {
        tenant_id: tenant.id,
        subscription_id: sub.id,
        plan,
        cycle,
      },
      reference: { transaction: sub.id, order: tenant.id },
      receipt: { email: true, sms: true },
      customer: {
        first_name: tenant.name || "Customer",
        email: user.email,
        phone: tenant.phone ? { country_code: "966", number: String(tenant.phone).replace(/^\+?966/, "") } : undefined,
      },
      source: { id: "src_all" },     // accept all Tap methods (mada, visa, mc, apple_pay)
      post: { url: `${SITE_URL}/api/tap-webhook` },
      redirect: { url: `${SITE_URL}/payment-return?sub=${sub.id}` },
    };

    // Call Tap API
    const tapRes = await fetch(TAP_API, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${TAP_SECRET_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(chargePayload),
    });

    const tapData = await tapRes.json();
    if (!tapRes.ok) {
      console.error("Tap error:", tapData);
      throw new Error(tapData.errors?.[0]?.description || "Tap charge creation failed");
    }

    // Log payment record
    await supa.from("payments").insert({
      tenant_id: tenant.id,
      subscription_id: sub.id,
      tap_charge_id: tapData.id,
      amount_sar: amount,
      status: tapData.status || "INITIATED",
      reference: sub.id,
      metadata: { plan, cycle },
    });

    return new Response(JSON.stringify({
      success: true,
      charge_id: tapData.id,
      redirect_url: tapData.transaction?.url,
      status: tapData.status,
    }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});

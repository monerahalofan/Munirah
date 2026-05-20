// Automated Invoice Reminders
// Runs daily (via cron) — finds overdue invoices and logs reminders
// Can also be triggered manually via POST { mode: 'manual', tenantId? }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
  const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
  const mode = body.mode || 'auto';

  // Stages of overdue reminders (in days past due_date)
  const REMINDER_STAGES = [
    { days: 1,   label: 'تذكير لطيف' },
    { days: 7,   label: 'متابعة أولى' },
    { days: 14,  label: 'متابعة ثانية' },
    { days: 30,  label: 'تنبيه نهائي' },
  ];

  const today = new Date().toISOString().slice(0, 10);

  // Build filter for unpaid invoices with passed due_date
  let q = sb
    .from('invoices')
    .select('id, tenant_id, number, buyer_name, client_name, total, amount_due, due_date, payment_status, invoice_kind')
    .eq('invoice_kind', 'invoice')
    .neq('payment_status', 'paid')
    .lt('due_date', today)
    .not('due_date', 'is', null);

  if (body.tenantId) q = q.eq('tenant_id', body.tenantId);

  const { data: invoices, error } = await q;
  if (error) return err(500, error.message);

  let processed = 0;
  let sent = 0;
  const results: any[] = [];

  for (const inv of invoices || []) {
    processed++;
    const dueDate = new Date(inv.due_date);
    const overdueDays = Math.floor((Date.now() - dueDate.getTime()) / (1000 * 60 * 60 * 24));

    // Skip if not matching any reminder stage (we only fire on exact stage days)
    const stage = REMINDER_STAGES.find(s => s.days === overdueDays);
    if (!stage && mode === 'auto') continue;

    // Check if we already sent a reminder for this stage
    if (mode === 'auto' && stage) {
      const { data: existing } = await sb
        .from('invoice_reminders')
        .select('id')
        .eq('invoice_id', inv.id)
        .gte('sent_at', new Date(Date.now() - 23 * 60 * 60 * 1000).toISOString())
        .limit(1);
      if (existing && existing.length) continue;
    }

    const buyer = inv.buyer_name || inv.client_name || 'عميلنا الكريم';
    const due_amt = (+(inv.amount_due ?? inv.total) || 0).toFixed(2);
    const stageLabel = stage?.label || 'تذكير';

    const message = `${stageLabel}: مرحباً ${buyer}،\n\nفاتورتكم رقم ${inv.number} بقيمة ${due_amt} ر.س مستحقة منذ ${inv.due_date} (متأخرة ${overdueDays} يوم).\n\nيرجى السداد في أقرب وقت.\nشكراً لتعاونكم.`;

    // Log the reminder
    const { error: logErr } = await sb.from('invoice_reminders').insert({
      tenant_id: inv.tenant_id,
      invoice_id: inv.id,
      channel: 'system',
      message,
      status: 'pending',
    });

    if (!logErr) sent++;
    results.push({
      invoice: inv.number,
      buyer,
      overdueDays,
      stage: stageLabel,
      amount: due_amt,
    });
  }

  return new Response(JSON.stringify({
    ok: true,
    processed,
    sent,
    today,
    mode,
    results: results.slice(0, 20),
  }), {
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
});

function err(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

// Daily subscription cron — runs once per day
// Checks: reminders to send (7d/3d/1d/expired) + subscriptions to cancel
// Trigger via Supabase Cron Job (pg_cron) or external scheduler

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SECRET  = Deno.env.get('CRON_SECRET') || ''; // Set this for security

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  // Security: require secret (when called externally)
  const secret = req.headers.get('x-cron-secret');
  if (CRON_SECRET && secret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_KEY);

  const results = {
    reminders_sent: 0,
    cancellations: 0,
    errors: [] as string[],
    details: [] as any[],
  };

  // ─── 1. Process reminders ────────────────────────────────
  try {
    const { data: needsReminder, error } = await sb.rpc('get_subscriptions_needing_reminders');
    if (error) throw error;

    for (const sub of (needsReminder || [])) {
      if (!sub.reminder_type || !sub.user_email) continue;
      const template = sub.reminder_type === 'expired' ? 'expired' : `reminder_${sub.reminder_type}`;

      const vars = {
        user_name:    sub.user_name || sub.user_email,
        tenant_name:  sub.tenant_name,
        plan:         sub.plan,
        days_left:    sub.days_left,
        expires_at:   formatDate(sub.current_period_end),
      };

      const emailRes = await fetch(`${SUPABASE_URL}/functions/v1/send-email`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${SUPABASE_KEY}`,
        },
        body: JSON.stringify({
          to: sub.user_email,
          template,
          vars,
          tenant_id: sub.tenant_id,
          user_id: sub.user_id,
        }),
      });

      if (emailRes.ok) {
        await sb.rpc('mark_reminder_sent', { p_sub_id: sub.sub_id, p_type: sub.reminder_type });
        results.reminders_sent++;
        results.details.push({ sub_id: sub.sub_id, type: sub.reminder_type, email: sub.user_email });
      } else {
        const err = await emailRes.text();
        results.errors.push(`reminder ${sub.reminder_type} → ${sub.user_email}: ${err.slice(0,200)}`);
      }
    }
  } catch (e) {
    results.errors.push(`reminders error: ${(e as Error).message}`);
  }

  // ─── 2. Process cancellations (past grace period) ──────────
  try {
    const { data: toCancel, error } = await sb.rpc('get_subscriptions_to_cancel');
    if (error) throw error;

    for (const sub of (toCancel || [])) {
      // Fetch user email
      const { data: { user } } = await sb.auth.admin.getUserById(sub.user_id);
      if (!user?.email) continue;

      const { data: tenant } = await sb.from('tenants').select('name').eq('id', sub.tenant_id).maybeSingle();

      // Cancel sub
      await sb.rpc('cancel_subscription', { p_sub_id: sub.sub_id, p_reason: 'unpaid' });

      // Send cancellation email
      const vars = {
        user_name:   (user.user_metadata as any)?.full_name || user.email,
        tenant_name: tenant?.name || 'حسابك',
        plan:        sub.plan,
      };

      const emailRes = await fetch(`${SUPABASE_URL}/functions/v1/send-email`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${SUPABASE_KEY}`,
        },
        body: JSON.stringify({
          to: user.email,
          template: 'cancelled',
          vars,
          tenant_id: sub.tenant_id,
          user_id: sub.user_id,
        }),
      });

      if (emailRes.ok) {
        results.cancellations++;
        results.details.push({ sub_id: sub.sub_id, type: 'cancelled', email: user.email });
      } else {
        results.errors.push(`cancel email → ${user.email}: failed`);
      }
    }
  } catch (e) {
    results.errors.push(`cancellations error: ${(e as Error).message}`);
  }

  return new Response(JSON.stringify({
    ok: true,
    ranAt: new Date().toISOString(),
    ...results,
  }, null, 2), {
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
});

function formatDate(d: string | Date | null): string {
  if (!d) return '—';
  const date = typeof d === 'string' ? new Date(d) : d;
  return date.toLocaleDateString('ar-SA-u-nu-latn', { year: 'numeric', month: 'long', day: 'numeric' });
}

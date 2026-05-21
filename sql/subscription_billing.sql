-- ══════════════════════════════════════════════════════════════════════════
-- Subscription Billing Automation
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Extend subscriptions table ──────────────────────────────────────
alter table subscriptions
  add column if not exists current_period_start timestamptz,
  add column if not exists current_period_end   timestamptz,
  add column if not exists trial_ends_at        timestamptz,
  add column if not exists grace_period_ends_at timestamptz,
  add column if not exists auto_renew           boolean default true,
  add column if not exists last_payment_id      text,
  add column if not exists last_invoice_id      uuid references invoices(id) on delete set null,
  add column if not exists reminder_7d_sent_at  timestamptz,
  add column if not exists reminder_3d_sent_at  timestamptz,
  add column if not exists reminder_1d_sent_at  timestamptz,
  add column if not exists expired_notice_sent_at timestamptz,
  add column if not exists cancelled_at         timestamptz,
  add column if not exists cancellation_reason  text;

-- ─── 2. Email log ──────────────────────────────────────────────────────
create table if not exists email_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,
  to_email    text not null,
  template    text not null,
  subject     text,
  variables   jsonb,
  status      text not null check (status in ('sent','failed','pending')) default 'pending',
  provider_id text,
  error       text,
  sent_at     timestamptz default now()
);

create index if not exists idx_email_tenant on email_log(tenant_id, sent_at desc);
create index if not exists idx_email_user on email_log(user_id, sent_at desc);
create index if not exists idx_email_template on email_log(template, sent_at desc);

alter table email_log enable row level security;
drop policy if exists "tenant_read_emails" on email_log;
create policy "tenant_read_emails" on email_log
  for select using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
    or user_id = auth.uid()
  );

grant all on email_log to service_role;
grant select on email_log to authenticated;

-- ─── 3. Auto-set current period dates on subscription create/update ────
create or replace function set_subscription_period()
returns trigger language plpgsql as $$
begin
  if NEW.status = 'active' and NEW.current_period_end is null then
    NEW.current_period_start = coalesce(NEW.current_period_start, now());
    -- Default 30 days for monthly, 365 for yearly
    NEW.current_period_end = NEW.current_period_start +
      case when NEW.plan like '%_yearly' or NEW.plan like 'yearly%' then interval '365 days'
           else interval '30 days' end;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_sub_period on subscriptions;
create trigger trg_sub_period
  before insert or update on subscriptions
  for each row execute function set_subscription_period();

-- ─── 4. Function: find subscriptions needing reminders ─────────────────
create or replace function get_subscriptions_needing_reminders()
returns table(
  sub_id uuid, tenant_id uuid, user_id uuid, user_email text,
  user_name text, tenant_name text, plan text,
  current_period_end timestamptz, days_left integer, reminder_type text
)
language plpgsql security definer as $$
begin
  return query
  select
    s.id, s.tenant_id, s.user_id,
    u.email::text, coalesce(u.raw_user_meta_data->>'full_name', u.email::text),
    t.name, s.plan, s.current_period_end,
    extract(day from (s.current_period_end - now()))::integer as days_left,
    case
      when s.current_period_end <= now() and s.expired_notice_sent_at is null then 'expired'
      when s.current_period_end <= now() + interval '1 day' and s.reminder_1d_sent_at is null then '1d'
      when s.current_period_end <= now() + interval '3 days' and s.reminder_3d_sent_at is null then '3d'
      when s.current_period_end <= now() + interval '7 days' and s.reminder_7d_sent_at is null then '7d'
      else null
    end as reminder_type
  from subscriptions s
  join auth.users u on u.id = s.user_id
  join tenants t on t.id = s.tenant_id
  where s.status = 'active'
    and s.auto_renew = false  -- Only manual-renew subs get reminders
    and s.current_period_end is not null
    and (
      (s.current_period_end <= now() + interval '7 days' and s.reminder_7d_sent_at is null) or
      (s.current_period_end <= now() + interval '3 days' and s.reminder_3d_sent_at is null) or
      (s.current_period_end <= now() + interval '1 day'  and s.reminder_1d_sent_at is null) or
      (s.current_period_end <= now() and s.expired_notice_sent_at is null)
    );
end;
$$;

grant execute on function get_subscriptions_needing_reminders() to service_role;

-- ─── 5. Function: find expired subscriptions to cancel (past grace) ────
create or replace function get_subscriptions_to_cancel()
returns table(sub_id uuid, tenant_id uuid, user_id uuid, plan text, days_overdue integer)
language plpgsql security definer as $$
begin
  return query
  select s.id, s.tenant_id, s.user_id, s.plan,
         extract(day from (now() - s.current_period_end))::integer
  from subscriptions s
  where s.status = 'active'
    and s.current_period_end < now() - interval '7 days'  -- 7-day grace period
    and s.cancelled_at is null;
end;
$$;

grant execute on function get_subscriptions_to_cancel() to service_role;

-- ─── 6. Function: mark reminder sent ───────────────────────────────────
create or replace function mark_reminder_sent(p_sub_id uuid, p_type text)
returns void language plpgsql security definer as $$
begin
  update subscriptions set
    reminder_7d_sent_at   = case when p_type='7d' then now() else reminder_7d_sent_at end,
    reminder_3d_sent_at   = case when p_type='3d' then now() else reminder_3d_sent_at end,
    reminder_1d_sent_at   = case when p_type='1d' then now() else reminder_1d_sent_at end,
    expired_notice_sent_at = case when p_type='expired' then now() else expired_notice_sent_at end
  where id = p_sub_id;
end;
$$;

grant execute on function mark_reminder_sent(uuid, text) to service_role;

-- ─── 7. Function: cancel subscription ──────────────────────────────────
create or replace function cancel_subscription(p_sub_id uuid, p_reason text default 'unpaid')
returns void language plpgsql security definer as $$
begin
  update subscriptions set
    status = 'cancelled',
    cancelled_at = now(),
    cancellation_reason = p_reason
  where id = p_sub_id;
end;
$$;

grant execute on function cancel_subscription(uuid, text) to service_role;

-- ─── 8. Function: extend subscription after successful payment ─────────
create or replace function extend_subscription_after_payment(
  p_sub_id uuid,
  p_payment_id text,
  p_invoice_id uuid default null
) returns void language plpgsql security definer as $$
declare
  v_current_end timestamptz;
  v_plan text;
  v_extension interval;
begin
  select current_period_end, plan into v_current_end, v_plan
  from subscriptions where id = p_sub_id;

  v_extension := case when v_plan like '%_yearly' or v_plan like 'yearly%'
                      then interval '365 days' else interval '30 days' end;

  update subscriptions set
    current_period_start = greatest(now(), v_current_end),
    current_period_end   = greatest(now(), v_current_end) + v_extension,
    last_payment_id = p_payment_id,
    last_invoice_id = coalesce(p_invoice_id, last_invoice_id),
    status = 'active',
    -- Reset reminders for next cycle
    reminder_7d_sent_at = null,
    reminder_3d_sent_at = null,
    reminder_1d_sent_at = null,
    expired_notice_sent_at = null,
    cancelled_at = null
  where id = p_sub_id;
end;
$$;

grant execute on function extend_subscription_after_payment(uuid, text, uuid) to service_role;

-- ─── Done ───────────────────────────────────────────────────────────────
select 'Subscription billing automation schema ready ✅' as status;

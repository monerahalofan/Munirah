-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — نظام التجربة المجانية (14 يوم)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. حقول التجربة على tenants ─────────────────────────────────────────
alter table tenants add column if not exists trial_starts_at timestamptz default now();
alter table tenants add column if not exists trial_ends_at   timestamptz;

-- لكل العملاء الحاليين اللي ما عندهم تاريخ انتهاء — نعطيهم 14 يوم من تسجيلهم
update tenants
   set trial_ends_at = coalesce(created_at, now()) + interval '14 days'
 where trial_ends_at is null;

-- ─── 2. تريغر يضبط trial_ends_at تلقائياً عند إنشاء tenant جديد ──────────
create or replace function set_trial_end()
returns trigger
language plpgsql
as $$
begin
  if NEW.trial_ends_at is null then
    NEW.trial_ends_at := coalesce(NEW.created_at, now()) + interval '14 days';
  end if;
  if NEW.trial_starts_at is null then
    NEW.trial_starts_at := coalesce(NEW.created_at, now());
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_trial_end on tenants;
create trigger trg_set_trial_end
  before insert on tenants
  for each row execute function set_trial_end();

-- ─── 3. عرض يبيّن حالة الاشتراك الفعلية لكل tenant ──────────────────────
create or replace view tenant_subscription_status as
select
  t.id,
  t.name,
  t.plan,
  t.trial_starts_at,
  t.trial_ends_at,
  t.plan_expires_at,
  case
    when t.plan in ('starter','pro','business') and (t.plan_expires_at is null or t.plan_expires_at > now())
      then 'active_paid'
    when t.plan = 'free' and t.trial_ends_at > now()
      then 'trial_active'
    when t.plan = 'free' and t.trial_ends_at <= now()
      then 'trial_expired'
    else 'inactive'
  end as status,
  greatest(0, extract(day from (t.trial_ends_at - now()))::int) as trial_days_left
from tenants t;

grant select on tenant_subscription_status to authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Admin Panel (إدارة المستخدمين والاشتراكات)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. قائمة إيميلات الـ Admins ──────────────────────────────────────────
-- ⚠️ عدّل القائمة في الدالة لإضافة/حذف admins
create or replace function is_admin()
returns boolean
language sql
security definer
stable
as $$
  select auth.jwt() ->> 'email' in (
    'monerahalofan@gmail.com'
  );
$$;

grant execute on function is_admin() to authenticated;

-- ─── 2. View — قائمة كل المستخدمين مع تفاصيلهم (للـ admins فقط) ─────────
create or replace view admin_users_view as
select
  u.id            as user_id,
  u.email,
  u.created_at    as signed_up_at,
  u.last_sign_in_at,
  t.id            as tenant_id,
  t.name          as tenant_name,
  t.plan,
  t.plan_expires_at,
  t.trial_ends_at,
  t.onboarded,
  t.business_type,
  t.branch_count,
  t.last_seen_at,
  case
    when t.plan in ('starter','pro','business') and (t.plan_expires_at is null or t.plan_expires_at > now()) then 'paid_active'
    when t.plan = 'free' and t.trial_ends_at > now() then 'trial_active'
    when t.plan = 'free' and t.trial_ends_at <= now() then 'trial_expired'
    when t.plan is null then 'no_tenant'
    else 'inactive'
  end as status
from auth.users u
left join tenants t on t.owner_id = u.id;

grant select on admin_users_view to authenticated;

-- ─── 3. RPC: قائمة كل المستخدمين (للـ admin فقط) ─────────────────────────
create or replace function admin_list_users()
returns setof admin_users_view
language plpgsql
security definer
as $$
begin
  if not is_admin() then
    raise exception 'unauthorized';
  end if;
  return query select * from admin_users_view order by signed_up_at desc;
end;
$$;

grant execute on function admin_list_users() to authenticated;

-- ─── 4. RPC: إعطاء/سحب اشتراك ────────────────────────────────────────────
create or replace function admin_set_plan(target_email text, new_plan text, lifetime boolean default true)
returns text
language plpgsql
security definer
as $$
declare
  target_user_id uuid;
  expiry timestamptz;
begin
  if not is_admin() then
    raise exception 'unauthorized';
  end if;

  if new_plan not in ('free','starter','pro','business') then
    raise exception 'invalid plan: %', new_plan;
  end if;

  select id into target_user_id from auth.users where email = target_email;
  if target_user_id is null then
    return 'لم يتم العثور على هذا الإيميل في النظام';
  end if;

  if lifetime then
    expiry := '2099-12-31'::timestamptz;
  else
    expiry := now() + interval '30 days';
  end if;

  update tenants
     set plan = new_plan,
         plan_expires_at = case when new_plan = 'free' then null else expiry end,
         trial_ends_at = case when new_plan = 'free' then now() + interval '14 days' else expiry end,
         updated_at = now()
   where owner_id = target_user_id;

  if not found then
    return 'المستخدم سجّل دخوله لكن لم يكمل الإعداد';
  end if;

  return 'تم تحديث الباقة بنجاح';
end;
$$;

grant execute on function admin_set_plan(text, text, boolean) to authenticated;

-- ─── 5. RPC: إحصائيات Dashboard ─────────────────────────────────────────
create or replace function admin_stats()
returns json
language plpgsql
security definer
as $$
begin
  if not is_admin() then
    raise exception 'unauthorized';
  end if;
  return json_build_object(
    'total_users',     (select count(*) from auth.users),
    'total_tenants',   (select count(*) from tenants),
    'onboarded',       (select count(*) from tenants where onboarded = true),
    'paying',          (select count(*) from tenants where plan in ('starter','pro','business')),
    'trial_active',    (select count(*) from tenants where plan = 'free' and trial_ends_at > now()),
    'trial_expired',   (select count(*) from tenants where plan = 'free' and trial_ends_at <= now()),
    'new_today',       (select count(*) from auth.users where created_at > now() - interval '24 hours'),
    'new_week',        (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'new_month',       (select count(*) from auth.users where created_at > now() - interval '30 days'),
    'active_today',    (select count(*) from tenants where last_seen_at > now() - interval '24 hours'),
    'mrr',             (select coalesce(sum(case
                          when plan = 'starter'  then 99
                          when plan = 'pro'      then 249
                          when plan = 'business' then 499
                          else 0 end), 0) from tenants where plan_expires_at > now())
  );
end;
$$;

grant execute on function admin_stats() to authenticated;

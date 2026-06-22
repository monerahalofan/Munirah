-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Admin Panel (إدارة المستخدمين والاشتراكات)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 0. Ensure required columns exist on tenants ─────────────────────────
alter table tenants add column if not exists last_seen_at timestamptz;
alter table tenants add column if not exists onboarded boolean default false;
alter table tenants add column if not exists business_type text;
alter table tenants add column if not exists branch_count integer default 1;
alter table tenants add column if not exists trial_ends_at timestamptz;
alter table tenants add column if not exists plan_expires_at timestamptz;

-- ─── 1. قائمة إيميلات الـ Admins ──────────────────────────────────────────
-- ⚠️ عدّل القائمة في الدالة لإضافة/حذف admins
-- جدول قابل للتحديث من الواجهة (بدل القائمة المثبتة في الكود)
create table if not exists platform_admins (
  email       text primary key,
  added_by    uuid references auth.users(id) on delete set null,
  added_at    timestamptz default now(),
  notes       text
);

-- زرع الأدمن الافتراضي (آمن — ON CONFLICT لا يفعل شي)
insert into platform_admins (email, notes) values
  ('monerahalofan@gmail.com', 'Founder'),
  ('hello@mahsob.sa',         'Official mahsob account')
on conflict (email) do nothing;

alter table platform_admins enable row level security;
drop policy if exists "admins_read" on platform_admins;
create policy "admins_read" on platform_admins for select
  using (auth.jwt() ->> 'email' in (select email from platform_admins));

grant select on platform_admins to authenticated;

-- تحديث الدالة لتقرأ من الجدول (مع fallback آمن للأدمن الأساسي)
create or replace function is_admin()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from platform_admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  ) or coalesce(auth.jwt() ->> 'email', '') = 'monerahalofan@gmail.com';
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
    when t.plan in ('freelancer','growth','business','enterprise') and (t.plan_expires_at is null or t.plan_expires_at > now()) then 'paid_active'
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

  if new_plan not in ('free','freelancer','growth','business','enterprise','trial') then
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

-- ─── RPC: تمديد فترة التجربة لمستخدم ───────────────────────────────────────
create or replace function admin_extend_trial(target_email text, extra_days int)
returns text
language plpgsql
security definer
as $$
declare
  target_user_id uuid;
  current_trial_end timestamptz;
  new_trial_end timestamptz;
begin
  if not is_admin() then
    raise exception 'unauthorized';
  end if;

  if extra_days <= 0 or extra_days > 365 then
    raise exception 'invalid days: must be between 1 and 365';
  end if;

  select id into target_user_id from auth.users where email = target_email;
  if target_user_id is null then
    return 'لم يتم العثور على هذا الإيميل';
  end if;

  -- Get current trial end (or now if expired/missing)
  select trial_ends_at into current_trial_end
    from tenants where owner_id = target_user_id;

  if current_trial_end is null or current_trial_end < now() then
    new_trial_end := now() + (extra_days || ' days')::interval;
  else
    new_trial_end := current_trial_end + (extra_days || ' days')::interval;
  end if;

  update tenants
     set trial_ends_at = new_trial_end,
         plan = 'free',
         updated_at = now()
   where owner_id = target_user_id;

  if not found then
    return 'المستخدم سجّل دخوله لكن لم يكمل الإعداد';
  end if;

  return 'تم تمديد التجربة لـ ' || extra_days || ' يوم — تنتهي في ' ||
         to_char(new_trial_end, 'YYYY-MM-DD');
end;
$$;

grant execute on function admin_extend_trial(text, int) to authenticated;

-- ─── RPC: ترقية/إزالة أدمن ─────────────────────────────────────────────────
create or replace function admin_grant_admin(target_email text, note_in text default null)
returns text
language plpgsql
security definer
as $$
declare
  e text := lower(trim(target_email));
begin
  if not is_admin() then raise exception 'unauthorized'; end if;
  if e is null or e !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'invalid email';
  end if;
  insert into platform_admins (email, added_by, notes)
  values (e, auth.uid(), note_in)
  on conflict (email) do update set added_by = excluded.added_by, notes = coalesce(excluded.notes, platform_admins.notes);
  return 'تم تعيين ' || e || ' كأدمن ✓';
end;
$$;

grant execute on function admin_grant_admin(text, text) to authenticated;

create or replace function admin_revoke_admin(target_email text)
returns text
language plpgsql
security definer
as $$
declare
  my_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  e text := lower(trim(target_email));
  remaining int;
begin
  if not is_admin() then raise exception 'unauthorized'; end if;
  if e = my_email then
    raise exception 'لا يمكنك إزالة صلاحياتك بنفسك';
  end if;
  if e = 'monerahalofan@gmail.com' then
    raise exception 'الحساب المؤسس محمي ولا يمكن إزالته';
  end if;

  delete from platform_admins where lower(email) = e;
  select count(*) into remaining from platform_admins;
  if remaining < 1 then
    raise exception 'لازم يبقى أدمن واحد على الأقل';
  end if;
  return 'تم إزالة صلاحيات الأدمن من ' || e || ' ✓';
end;
$$;

grant execute on function admin_revoke_admin(text) to authenticated;

-- ─── RPC: قائمة الأدمن الحاليين ───────────────────────────────────────────
create or replace function list_platform_admins()
returns table (email text, added_at timestamptz, notes text)
language sql
security definer
as $$
  select email, added_at, notes
    from platform_admins
   where is_admin()
   order by added_at;
$$;

grant execute on function list_platform_admins() to authenticated;

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
    'paying',          (select count(*) from tenants where plan in ('freelancer','growth','business','enterprise')),
    'trial_active',    (select count(*) from tenants where plan = 'free' and trial_ends_at > now()),
    'trial_expired',   (select count(*) from tenants where plan = 'free' and trial_ends_at <= now()),
    'new_today',       (select count(*) from auth.users where created_at > now() - interval '24 hours'),
    'new_week',        (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'new_month',       (select count(*) from auth.users where created_at > now() - interval '30 days'),
    'active_today',    (select count(*) from tenants where last_seen_at > now() - interval '24 hours'),
    'mrr',             (select coalesce(sum(case
                          when plan = 'freelancer' then 99
                          when plan = 'growth'     then 199
                          when plan = 'business'   then 399
                          else 0 end), 0) from tenants where plan_expires_at > now())
  );
end;
$$;

grant execute on function admin_stats() to authenticated;

-- ─── 6. Force PostgREST to reload schema cache ───────────────────────────
notify pgrst, 'reload schema';

-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — تتبّع آخر نشاط + إشعارات داخلية
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. آخر دخول وآخر معاملة ────────────────────────────────────────────
alter table tenants add column if not exists last_seen_at  timestamptz default now();
alter table tenants add column if not exists last_tx_at    timestamptz;

-- ─── 2. جدول الإشعارات الداخلية ─────────────────────────────────────────
create table if not exists notifications (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  user_id     uuid references auth.users(id) on delete cascade,
  type        text not null check (type in
                ('inactivity','vat_due','goal_progress','invoice_overdue','tip','welcome','milestone')),
  title       text not null,
  body        text,
  cta_label   text,
  cta_url     text,
  priority    text default 'normal' check (priority in ('low','normal','high','urgent')),
  read_at     timestamptz,
  dismissed_at timestamptz,
  created_at  timestamptz default now()
);

create index if not exists idx_notif_tenant on notifications(tenant_id, read_at, created_at desc);
create index if not exists idx_notif_user   on notifications(user_id);

grant all on notifications to authenticated;
alter table notifications enable row level security;

drop policy if exists "notif_tenant_isolation" on notifications;
create policy "notif_tenant_isolation" on notifications
  for all to authenticated using (
    tenant_id in (select id from tenants where owner_id = auth.uid())
    or tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

-- ─── 3. دالة تحدّث آخر نشاط ─────────────────────────────────────────────
create or replace function touch_tenant_activity(tid uuid)
returns void
language plpgsql
security definer
as $$
begin
  update tenants set last_seen_at = now() where id = tid;
end;
$$;

grant execute on function touch_tenant_activity(uuid) to authenticated;

-- ─── 4. دالة تنشئ إشعار تذكير لكل عميل غير نشط ──────────────────────────
-- تشغّل تلقائياً يومياً عبر pg_cron (الخطوة 5)
create or replace function generate_inactivity_reminders()
returns int
language plpgsql
security definer
as $$
declare
  cnt int := 0;
  t record;
begin
  -- اختر العملاء اللي ما دخلوا 3+ أيام وما عندهم تذكير حالي غير مقروء
  for t in
    select te.id, te.owner_id, te.name, te.last_seen_at
    from tenants te
    where te.last_seen_at < now() - interval '3 days'
      and te.onboarded = true
      and not exists (
        select 1 from notifications n
        where n.tenant_id = te.id
          and n.type = 'inactivity'
          and n.created_at > now() - interval '7 days'
          and n.dismissed_at is null
      )
  loop
    insert into notifications (tenant_id, user_id, type, title, body, cta_label, cta_url, priority)
    values (
      t.id,
      t.owner_id,
      'inactivity',
      'وحشتنا يا ' || coalesce(split_part(t.name,' ',1),'صديقنا') || '! 👋',
      'مر ' ||
        case when t.last_seen_at < now() - interval '14 days' then '14 يوم أو أكثر'
             when t.last_seen_at < now() - interval '7 days'  then 'أكثر من أسبوع'
             else extract(day from (now() - t.last_seen_at))::int || ' أيام' end ||
        ' من آخر مرة سجّلت فيها معاملاتك. حافظ على دقّة محاسبتك بسجّلها أولاً بأول.',
      'سجّل معاملة الآن',
      '/app#tx',
      case when t.last_seen_at < now() - interval '14 days' then 'high'
           else 'normal' end
    );
    cnt := cnt + 1;
  end loop;
  return cnt;
end;
$$;

grant execute on function generate_inactivity_reminders() to authenticated;

-- ─── 5. جدولة يومية عبر pg_cron (اختياري — Supabase Pro فقط) ────────────
-- لو ودك تشغّلها يدوياً: select generate_inactivity_reminders();
-- إذا كان pg_cron مفعل:
-- create extension if not exists pg_cron;
-- select cron.schedule('inactivity-reminders', '0 9 * * *', 'select generate_inactivity_reminders()');

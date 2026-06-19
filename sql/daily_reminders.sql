-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Daily Activity Reminders (تذكير يومي بالواتساب + بانر داخلي)
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Add reminder settings to tenants ─────────────────────────────────
alter table tenants add column if not exists reminder_enabled boolean default true;
alter table tenants add column if not exists reminder_hour    int default 20
  check (reminder_hour between 0 and 23);
alter table tenants add column if not exists reminder_channels jsonb default '["in_app"]'::jsonb;
alter table tenants add column if not exists reminder_phone   text;
alter table tenants add column if not exists last_reminder_sent_at timestamptz;

-- ─── 2. Reminder log (track what was sent) ───────────────────────────────
create table if not exists reminder_log (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references tenants(id) on delete cascade not null,
  user_id      uuid references auth.users(id) on delete set null,
  channel      text not null check (channel in ('in_app','whatsapp','email','sms')),
  for_date     date not null,
  status       text not null default 'sent' check (status in ('sent','failed','dismissed','clicked')),
  provider_ref text,
  message      text,
  created_at   timestamptz default now()
);

create index if not exists idx_reminder_tenant on reminder_log(tenant_id, for_date desc);
create unique index if not exists idx_reminder_unique on reminder_log(tenant_id, channel, for_date);

alter table reminder_log enable row level security;
drop policy if exists "tenant_read_reminder" on reminder_log;
create policy "tenant_read_reminder" on reminder_log for select using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);
grant select on reminder_log to authenticated;

-- ─── 3. RPC: Check if today has activity ─────────────────────────────────
create or replace function has_activity_today()
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  today date := current_date;
  tx_count int := 0;
  exp_count int := 0;
  closing_count int := 0;
  invoice_count int := 0;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then
    return json_build_object('has_activity', false, 'reason', 'no_tenant');
  end if;

  select count(*) into tx_count from transactions where tenant_id = my_tenant and date = today;
  select count(*) into exp_count from expenses where tenant_id = my_tenant and expense_date = today;
  select count(*) into closing_count from daily_closings where tenant_id = my_tenant and closing_date = today;
  select count(*) into invoice_count from invoices where tenant_id = my_tenant and (issue_date = today or (created_at::date = today));

  return json_build_object(
    'has_activity', (tx_count + exp_count + closing_count + invoice_count) > 0,
    'transactions', tx_count,
    'expenses',     exp_count,
    'closings',     closing_count,
    'invoices',     invoice_count,
    'total',        tx_count + exp_count + closing_count + invoice_count
  );
end;
$$;

grant execute on function has_activity_today() to authenticated;

-- ─── 4. RPC: Update reminder preferences ─────────────────────────────────
create or replace function update_reminder_settings(
  enabled_in boolean default null,
  hour_in int default null,
  channels_in jsonb default null,
  phone_in text default null
)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() and role = 'admin' limit 1;
  if my_tenant is null then raise exception 'unauthorized'; end if;

  update tenants set
    reminder_enabled  = coalesce(enabled_in, reminder_enabled),
    reminder_hour     = coalesce(hour_in, reminder_hour),
    reminder_channels = coalesce(channels_in, reminder_channels),
    reminder_phone    = coalesce(phone_in, reminder_phone),
    updated_at        = now()
   where id = my_tenant;

  return json_build_object('success', true);
end;
$$;

grant execute on function update_reminder_settings(boolean, int, jsonb, text) to authenticated;

-- ─── 5. RPC: Mark in-app reminder as dismissed/clicked ───────────────────
create or replace function log_reminder_action(channel_in text, status_in text)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then return json_build_object('success', false); end if;

  insert into reminder_log (tenant_id, user_id, channel, for_date, status, message)
  values (my_tenant, auth.uid(), channel_in, current_date, status_in, null)
  on conflict (tenant_id, channel, for_date) do update set
    status = excluded.status;

  return json_build_object('success', true);
end;
$$;

grant execute on function log_reminder_action(text, text) to authenticated;

-- ─── 6. View: Tenants that need a reminder NOW (for cron job) ────────────
create or replace view tenants_needing_reminder as
select
  t.id as tenant_id,
  t.name,
  t.reminder_phone,
  t.reminder_channels,
  t.reminder_hour,
  current_date as for_date
from tenants t
where t.reminder_enabled = true
  and t.reminder_phone is not null
  and t.reminder_hour = extract(hour from now() at time zone 'Asia/Riyadh')
  -- Not already sent today via WhatsApp
  and not exists (
    select 1 from reminder_log r
    where r.tenant_id = t.id
      and r.channel = 'whatsapp'
      and r.for_date = current_date
      and r.status = 'sent'
  )
  -- No activity today
  and not exists (
    select 1 from transactions where tenant_id = t.id and date = current_date
  )
  and not exists (
    select 1 from expenses where tenant_id = t.id and expense_date = current_date
  )
  and not exists (
    select 1 from daily_closings where tenant_id = t.id and closing_date = current_date
  );

grant select on tenants_needing_reminder to service_role;

notify pgrst, 'reload schema';

select 'Daily reminders ready ✅' as status;

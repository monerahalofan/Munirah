-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Activity Log (سجل الحركات بين المستخدم ومحسوب)
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists activity_log (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  user_id       uuid references auth.users(id) on delete set null,
  user_email    text,
  user_name     text,
  action        text not null,
  category      text not null check (category in ('invoice','closing','expense','supplier','transaction','quote','member','auth','settings','payment','other')),
  entity_type   text,
  entity_id     uuid,
  description   text not null,
  metadata      jsonb,
  ip_address    text,
  user_agent    text,
  created_at    timestamptz default now()
);

create index if not exists idx_activity_tenant on activity_log(tenant_id, created_at desc);
create index if not exists idx_activity_user   on activity_log(user_id, created_at desc);
create index if not exists idx_activity_cat    on activity_log(tenant_id, category, created_at desc);

alter table activity_log enable row level security;

drop policy if exists "tenant_read_activity" on activity_log;
drop policy if exists "tenant_insert_activity" on activity_log;

-- Anyone in the tenant can read activity (for the log page)
create policy "tenant_read_activity" on activity_log for select using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

-- Anyone in the tenant can insert their own activity
create policy "tenant_insert_activity" on activity_log for insert with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  and user_id = auth.uid()
);

grant select, insert on activity_log to authenticated;

-- ─── Helper RPC for clean activity logging from triggers/functions ───────
create or replace function log_activity(
  category_in text,
  action_in text,
  description_in text,
  entity_type_in text default null,
  entity_id_in uuid default null,
  metadata_in jsonb default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  my_email text;
  my_name text;
  new_id uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then return null; end if;

  my_email := auth.jwt() ->> 'email';
  select display_name into my_name from tenant_users
   where user_id = auth.uid() and tenant_id = my_tenant limit 1;

  insert into activity_log (
    tenant_id, user_id, user_email, user_name,
    action, category, entity_type, entity_id, description, metadata
  ) values (
    my_tenant, auth.uid(), my_email, my_name,
    action_in, category_in, entity_type_in, entity_id_in, description_in, metadata_in
  ) returning id into new_id;

  return new_id;
end;
$$;

grant execute on function log_activity(text, text, text, text, uuid, jsonb) to authenticated;

-- ─── Summary view: activity by day per tenant ────────────────────────────
create or replace view activity_summary as
select
  tenant_id,
  date_trunc('day', created_at)::date as day,
  category,
  count(*) as event_count
from activity_log
group by tenant_id, date_trunc('day', created_at)::date, category;

grant select on activity_summary to authenticated;

notify pgrst, 'reload schema';

select 'Activity log ready ✅' as status;

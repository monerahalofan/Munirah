-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — POS Integrations Hub
-- مركز ربط أنظمة الكاشير (Foodics, Rewaa, Marn, Loyverse, Lightspeed, Square)
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. POS Connections ──────────────────────────────────────────────────
create table if not exists pos_connections (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  provider        text not null check (provider in (
    'foodics', 'marn', 'rewaa', 'loyverse', 'lightspeed', 'square', 'other'
  )),
  display_name    text,                       -- اسم مخصص يحدّده العميل
  -- Credentials encrypted via pgsodium or app-level encryption
  -- Stored as JSONB to fit different auth schemes (OAuth tokens, API keys, etc.)
  credentials     jsonb not null default '{}'::jsonb,
  -- What to sync
  sync_sales      boolean default true,
  sync_inventory  boolean default true,
  sync_products   boolean default true,
  sync_zatca_auto boolean default true,       -- يُصدر فاتورة ZATCA لكل بيع
  -- Sync state
  status          text default 'pending' check (status in (
    'pending', 'connected', 'syncing', 'error', 'disconnected', 'paused'
  )),
  last_sync_at        timestamptz,
  last_sync_count     int default 0,
  last_error_message  text,
  last_error_at       timestamptz,
  -- Connection metadata (provider-specific: account name, branch, store name)
  metadata        jsonb default '{}'::jsonb,
  -- Webhook config
  webhook_secret  text,                       -- يولّد من نا، يثبّت عند المزوّد
  webhook_url     text,                       -- URL endpoint عندنا
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  connected_at    timestamptz,
  unique (tenant_id, provider)
);

create index if not exists idx_pos_conn_tenant on pos_connections(tenant_id);
create index if not exists idx_pos_conn_status on pos_connections(status) where status = 'connected';

alter table pos_connections enable row level security;
drop policy if exists "tenant_rw_pos_conn" on pos_connections;
create policy "tenant_rw_pos_conn" on pos_connections for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on pos_connections to authenticated;

-- ─── 2. Sync log ─────────────────────────────────────────────────────────
create table if not exists pos_sync_log (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  connection_id uuid references pos_connections(id) on delete cascade not null,
  provider      text not null,
  event_type    text not null check (event_type in (
    'sale_received', 'sale_processed',
    'inventory_synced', 'product_synced',
    'webhook_received', 'pull_sync', 'full_sync',
    'connection_test', 'connection_failed',
    'oauth_completed', 'auth_refreshed'
  )),
  status        text not null check (status in ('success', 'warning', 'error')),
  external_id   text,                         -- مرجع الطلب/الفاتورة في نظام المزوّد
  payload       jsonb,                        -- البيانات الخام للتدقيق
  error_message text,
  duration_ms   int,
  created_at    timestamptz default now()
);

create index if not exists idx_pos_log_tenant on pos_sync_log(tenant_id, created_at desc);
create index if not exists idx_pos_log_conn   on pos_sync_log(connection_id, created_at desc);
create index if not exists idx_pos_log_extid  on pos_sync_log(provider, external_id);

alter table pos_sync_log enable row level security;
drop policy if exists "tenant_r_pos_log" on pos_sync_log;
create policy "tenant_r_pos_log" on pos_sync_log for select using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant select on pos_sync_log to authenticated;
grant insert on pos_sync_log to authenticated;

-- ─── 3. Idempotency table (يمنع تكرار معالجة نفس الطلب) ─────────────────
create table if not exists pos_processed_orders (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  provider      text not null,
  external_id   text not null,                -- order id في نظام المزوّد
  invoice_id    uuid,                         -- مرجع لـ zatca_invoice_log إذا أُصدرت
  amount        numeric(14,2),
  processed_at  timestamptz default now(),
  unique (tenant_id, provider, external_id)
);

create index if not exists idx_pos_processed on pos_processed_orders(tenant_id, provider, external_id);

alter table pos_processed_orders enable row level security;
drop policy if exists "tenant_r_pos_processed" on pos_processed_orders;
create policy "tenant_r_pos_processed" on pos_processed_orders for select using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant select on pos_processed_orders to authenticated;

-- ─── 4. Helper: update connection status ─────────────────────────────────
create or replace function pos_update_connection_status(
  connection_id_in uuid,
  status_in        text,
  error_in         text default null,
  count_in         int  default null
)
returns void
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then raise exception 'unauthorized'; end if;

  update pos_connections set
    status              = status_in,
    last_sync_at        = case when status_in = 'connected' then now() else last_sync_at end,
    last_sync_count     = coalesce(count_in, last_sync_count),
    last_error_message  = case when status_in = 'error' then error_in else null end,
    last_error_at       = case when status_in = 'error' then now() else last_error_at end,
    connected_at        = case when status_in = 'connected' and connected_at is null then now() else connected_at end,
    updated_at          = now()
  where id = connection_id_in and tenant_id = my_tenant;
end;
$$;

grant execute on function pos_update_connection_status(uuid, text, text, int) to authenticated;

-- ─── 5. View: provider dashboard summary ─────────────────────────────────
create or replace view pos_integration_summary as
select
  c.tenant_id,
  c.id              as connection_id,
  c.provider,
  c.display_name,
  c.status,
  c.last_sync_at,
  c.connected_at,
  -- Today's stats
  (select count(*) from pos_processed_orders po
    where po.tenant_id = c.tenant_id
      and po.provider = c.provider
      and po.processed_at >= current_date)            as orders_today,
  (select coalesce(sum(amount), 0) from pos_processed_orders po
    where po.tenant_id = c.tenant_id
      and po.provider = c.provider
      and po.processed_at >= current_date)            as revenue_today,
  -- Last 24h errors
  (select count(*) from pos_sync_log sl
    where sl.connection_id = c.id
      and sl.status = 'error'
      and sl.created_at > now() - interval '24 hours') as errors_24h
from pos_connections c;

grant select on pos_integration_summary to authenticated;

notify pgrst, 'reload schema';

select 'POS Integrations Hub ready ✅' as status;

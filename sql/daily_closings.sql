-- ══════════════════════════════════════════════════════════════════════════
-- Daily Closings (POS Daily Reports Upload)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists daily_closings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  created_by      uuid references auth.users(id),
  closing_date    date not null,
  branch          text,
  -- Amounts
  total_sales     numeric(14,2) not null default 0,
  vat_amount      numeric(14,2) not null default 0,
  subtotal        numeric(14,2) not null default 0,
  -- Payment methods breakdown
  cash_amount     numeric(14,2) default 0,
  card_amount     numeric(14,2) default 0,
  bank_amount     numeric(14,2) default 0,
  wallet_amount   numeric(14,2) default 0,
  -- Counts and deductions
  invoice_count   integer default 0,
  returns_amount  numeric(14,2) default 0,
  discount_amount numeric(14,2) default 0,
  -- Source
  source          text default 'manual' check (source in ('manual','upload','api')),
  uploaded_file_url text,
  ai_extracted_data jsonb,
  notes           text,
  -- Tracking
  created_at      timestamptz default now()
);

create index if not exists idx_closing_tenant on daily_closings(tenant_id, closing_date desc);
create index if not exists idx_closing_date   on daily_closings(closing_date desc);
create unique index if not exists idx_closing_unique on daily_closings(tenant_id, closing_date, coalesce(branch, ''));

alter table daily_closings enable row level security;

drop policy if exists "tenant_rw_closings" on daily_closings;
create policy "tenant_rw_closings" on daily_closings
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on daily_closings to authenticated;
grant all on daily_closings to service_role;

select 'Daily closings table ready ✅' as status;

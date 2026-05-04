-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Supabase Database Schema
-- Run this in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Tenants (one per business/company) ────────────────────────────────
create table if not exists tenants (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references auth.users(id) on delete cascade not null,
  name        text not null,
  plan        text not null default 'free'
                check (plan in ('free','starter','pro','business')),
  plan_expires_at timestamptz,
  business_type   text,
  vat_number      text,
  logo_url        text,
  created_at  timestamptz default now()
);

-- ─── 2. Tenant Users (members with roles) ─────────────────────────────────
create table if not exists tenant_users (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references tenants(id) on delete cascade not null,
  user_id      uuid references auth.users(id) on delete cascade not null,
  role         text not null default 'cashier'
                 check (role in ('admin','accountant','cashier','viewer')),
  display_name text,
  created_at   timestamptz default now(),
  unique (tenant_id, user_id)
);

-- ─── 3. Transactions ──────────────────────────────────────────────────────
create table if not exists transactions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  created_by  uuid references auth.users(id),
  type        text not null check (type in ('income','expense')),
  amount      numeric(14,2) not null,
  category    text,
  party       text,
  note        text,
  date        date not null default current_date,
  vat_amount  numeric(14,2) default 0,
  invoice_ref text,
  created_at  timestamptz default now()
);

-- ─── 4. Invoices ──────────────────────────────────────────────────────────
create table if not exists invoices (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  created_by    uuid references auth.users(id),
  number        text,
  client_name   text,
  client_email  text,
  issue_date    date not null default current_date,
  due_date      date,
  subtotal      numeric(14,2) not null default 0,
  vat_amount    numeric(14,2) default 0,
  total         numeric(14,2) not null default 0,
  status        text not null default 'draft'
                  check (status in ('draft','sent','paid','overdue','cancelled')),
  notes         text,
  items         jsonb default '[]',
  created_at    timestamptz default now()
);

-- ─── 5. Budget Categories ─────────────────────────────────────────────────
create table if not exists budget_categories (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  name        text not null,
  budget      numeric(14,2) not null default 0,
  spent       numeric(14,2) not null default 0,
  color       text default '#16a372',
  created_at  timestamptz default now(),
  unique (tenant_id, name)
);

-- ─── 6. Financial Goals ───────────────────────────────────────────────────
create table if not exists goals (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  name        text not null,
  target      numeric(14,2) not null,
  current     numeric(14,2) not null default 0,
  deadline    date,
  icon        text default '🎯',
  created_at  timestamptz default now()
);

-- ─── 7. AI Scan Log (track usage per plan) ────────────────────────────────
create table if not exists scan_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  user_id     uuid references auth.users(id),
  result      jsonb,
  created_at  timestamptz default now()
);

-- ══════════════════════════════════════════════════════════════════════════
-- Row Level Security — each tenant sees only their own data
-- ══════════════════════════════════════════════════════════════════════════

alter table tenants          enable row level security;
alter table tenant_users     enable row level security;
alter table transactions     enable row level security;
alter table invoices         enable row level security;
alter table budget_categories enable row level security;
alter table goals            enable row level security;
alter table scan_log         enable row level security;

-- Helper: returns the tenant_id for the current logged-in user
create or replace function my_tenant_id()
returns uuid language sql stable as $$
  select tenant_id from tenant_users
  where user_id = auth.uid()
  limit 1;
$$;

-- tenants
drop policy if exists "tenant_owner_select" on tenants;
drop policy if exists "tenant_owner_insert" on tenants;
drop policy if exists "tenant_owner_update" on tenants;
create policy "tenant_owner_select" on tenants for select using (owner_id = auth.uid());
create policy "tenant_owner_insert" on tenants for insert with check (owner_id = auth.uid());
create policy "tenant_owner_update" on tenants for update using (owner_id = auth.uid());

-- tenant_users
drop policy if exists "tenant_users_select" on tenant_users;
drop policy if exists "tenant_users_insert" on tenant_users;
create policy "tenant_users_select" on tenant_users for select using (tenant_id = my_tenant_id());
create policy "tenant_users_insert" on tenant_users for insert with check (user_id = auth.uid());

-- transactions
drop policy if exists "tx_select" on transactions;
drop policy if exists "tx_insert" on transactions;
drop policy if exists "tx_delete" on transactions;
create policy "tx_select" on transactions for select using (tenant_id = my_tenant_id());
create policy "tx_insert" on transactions for insert with check (tenant_id = my_tenant_id());
create policy "tx_delete" on transactions for delete using (tenant_id = my_tenant_id());

-- invoices
drop policy if exists "inv_select" on invoices;
drop policy if exists "inv_insert" on invoices;
drop policy if exists "inv_update" on invoices;
drop policy if exists "inv_delete" on invoices;
create policy "inv_select" on invoices for select using (tenant_id = my_tenant_id());
create policy "inv_insert" on invoices for insert with check (tenant_id = my_tenant_id());
create policy "inv_update" on invoices for update using (tenant_id = my_tenant_id());
create policy "inv_delete" on invoices for delete using (tenant_id = my_tenant_id());

-- budget_categories
drop policy if exists "budget_select" on budget_categories;
drop policy if exists "budget_upsert" on budget_categories;
drop policy if exists "budget_update" on budget_categories;
create policy "budget_select" on budget_categories for select using (tenant_id = my_tenant_id());
create policy "budget_upsert" on budget_categories for insert with check (tenant_id = my_tenant_id());
create policy "budget_update" on budget_categories for update using (tenant_id = my_tenant_id());

-- goals
drop policy if exists "goals_select" on goals;
drop policy if exists "goals_insert" on goals;
drop policy if exists "goals_update" on goals;
create policy "goals_select" on goals for select using (tenant_id = my_tenant_id());
create policy "goals_insert" on goals for insert with check (tenant_id = my_tenant_id());
create policy "goals_update" on goals for update using (tenant_id = my_tenant_id());

-- scan_log
drop policy if exists "scan_select" on scan_log;
drop policy if exists "scan_insert" on scan_log;
create policy "scan_select" on scan_log for select using (tenant_id = my_tenant_id());
create policy "scan_insert" on scan_log for insert with check (tenant_id = my_tenant_id());

-- ══════════════════════════════════════════════════════════════════════════
-- Indexes for performance
-- ══════════════════════════════════════════════════════════════════════════
create index if not exists idx_tx_tenant_date
  on transactions(tenant_id, date desc);
create index if not exists idx_inv_tenant_status
  on invoices(tenant_id, status);
create index if not exists idx_scan_tenant_month
  on scan_log(tenant_id, created_at desc);

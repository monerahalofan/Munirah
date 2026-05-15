-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Onboarding & Chart of Accounts Migration
-- شغّل هذا في: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Add onboarding fields to tenants ──────────────────────────────────
alter table tenants add column if not exists onboarded boolean default false;
alter table tenants add column if not exists branch_count int default 1;
alter table tenants add column if not exists has_inventory boolean default false;
alter table tenants add column if not exists has_employees boolean default false;
alter table tenants add column if not exists vat_registered boolean default false;
alter table tenants add column if not exists fiscal_year_start int default 1;
alter table tenants add column if not exists goals jsonb default '[]'::jsonb;

-- ─── 2. Chart of Accounts (شجرة الحسابات) ─────────────────────────────────
create table if not exists chart_of_accounts (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  type        text not null check (type in ('asset','liability','equity','revenue','cogs','expense')),
  parent_code text,
  is_active   boolean default true,
  is_zatca    boolean default false,
  created_at  timestamptz default now(),
  unique (tenant_id, code)
);

create index if not exists idx_coa_tenant on chart_of_accounts(tenant_id);
create index if not exists idx_coa_type   on chart_of_accounts(tenant_id, type);

-- ─── 3. Cost Centers (مراكز التكلفة - للفروع) ────────────────────────────
create table if not exists cost_centers (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references tenants(id) on delete cascade not null,
  code        text not null,
  name        text not null,
  is_active   boolean default true,
  created_at  timestamptz default now(),
  unique (tenant_id, code)
);

create index if not exists idx_cc_tenant on cost_centers(tenant_id);

-- ─── 4. Row Level Security ───────────────────────────────────────────────
alter table chart_of_accounts enable row level security;
alter table cost_centers enable row level security;

create policy "tenant_isolation_coa" on chart_of_accounts
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

create policy "tenant_isolation_cc" on cost_centers
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

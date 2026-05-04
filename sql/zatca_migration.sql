-- ══════════════════════════════════════════════════════════════════════════
-- ZATCA Migration — run in Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Add ZATCA fields to invoices ──────────────────────────────────────
alter table invoices
  add column if not exists zatca_uuid       text,
  add column if not exists invoice_type     text not null default 'simplified'
                             check (invoice_type in ('standard','simplified')),
  add column if not exists previous_hash    text,
  add column if not exists xml_content      text,
  add column if not exists invoice_hash     text,
  add column if not exists qr_code          text,
  add column if not exists ecdsa_signature  text,
  add column if not exists zatca_status     text not null default 'draft'
                             check (zatca_status in ('draft','cleared','reported','rejected')),
  add column if not exists zatca_response   jsonb,
  add column if not exists buyer_vat        text,
  add column if not exists seller_city      text;

-- ─── 2. ZATCA config per tenant (certificate + keys) ──────────────────────
create table if not exists zatca_config (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null unique,
  vat_number      text not null,
  seller_name     text not null,
  seller_city     text not null default 'الرياض',
  invoice_counter integer not null default 0,
  certificate     text,   -- X.509 certificate from ZATCA (PEM)
  private_key     text,   -- ECDSA private key (PEM) — store encrypted in prod
  public_key      text,   -- ECDSA public key (PEM)
  egs_serial      text,   -- Format: 1-Name|2-Model|3-Serial
  onboarded       boolean not null default false,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table zatca_config enable row level security;

drop policy if exists "zatca_config_select" on zatca_config;
drop policy if exists "zatca_config_upsert" on zatca_config;
drop policy if exists "zatca_config_update" on zatca_config;

create policy "zatca_config_select" on zatca_config
  for select using (tenant_id = my_tenant_id());

create policy "zatca_config_upsert" on zatca_config
  for insert with check (tenant_id = my_tenant_id());

create policy "zatca_config_update" on zatca_config
  for update using (tenant_id = my_tenant_id());

-- ─── 3. Index for fast ZATCA invoice lookup ───────────────────────────────
create index if not exists idx_inv_zatca_status
  on invoices(tenant_id, zatca_status);

-- ─── 4. Atomic counter increment (prevents race conditions) ───────────────
-- Returns the new counter value; locks the row so concurrent calls are safe.
create or replace function zatca_next_counter(p_tenant_id uuid)
returns integer
language plpgsql
security definer
as $$
declare
  v_counter integer;
begin
  update zatca_config
     set invoice_counter = invoice_counter + 1,
         updated_at      = now()
   where tenant_id = p_tenant_id
   returning invoice_counter into v_counter;

  if not found then
    raise exception 'zatca_config not found for tenant %', p_tenant_id;
  end if;

  return v_counter;
end;
$$;

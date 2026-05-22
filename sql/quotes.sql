-- ══════════════════════════════════════════════════════════════════════════
-- Quotes / Estimates (عروض الأسعار)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists quotes (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  created_by      uuid references auth.users(id),
  number          text not null,
  client_name     text,
  client_email    text,
  client_phone    text,
  client_vat      text,
  issue_date      date not null default current_date,
  valid_until     date,
  subtotal        numeric(14,2) not null default 0,
  vat_amount      numeric(14,2) default 0,
  total           numeric(14,2) not null default 0,
  status          text not null default 'draft'
                  check (status in ('draft','sent','accepted','rejected','expired','converted')),
  items           jsonb default '[]',
  notes           text,
  terms           text,
  converted_invoice_id uuid references invoices(id) on delete set null,
  converted_at    timestamptz,
  sent_at         timestamptz,
  accepted_at     timestamptz,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists idx_quote_tenant on quotes(tenant_id, created_at desc);
create index if not exists idx_quote_status on quotes(tenant_id, status);
create index if not exists idx_quote_number on quotes(tenant_id, number);

alter table quotes enable row level security;

drop policy if exists "tenant_rw_quotes" on quotes;
create policy "tenant_rw_quotes" on quotes
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on quotes to authenticated;
grant all on quotes to service_role;

-- Helper: get next quote number per tenant
create or replace function next_quote_number(p_tenant_id uuid)
returns text language plpgsql security definer as $$
declare
  next_num integer;
begin
  select coalesce(count(*), 0) + 1 into next_num
  from quotes where tenant_id = p_tenant_id;
  return 'QT-' || extract(year from current_date) || '-' || lpad(next_num::text, 5, '0');
end;
$$;

grant execute on function next_quote_number(uuid) to authenticated;

select 'Quotes table ready ✅' as status;

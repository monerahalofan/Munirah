-- ══════════════════════════════════════════════════════════════════════════
-- Expenses & Suppliers (المصاريف والموردون)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ── Suppliers ──────────────────────────────────────────────────────────────
create table if not exists suppliers (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  created_by      uuid references auth.users(id),
  name            text not null,
  category        text default 'other',
  vat_number      text,
  contact_name    text,
  phone           text,
  email           text,
  address         text,
  payment_terms   integer default 30,  -- days
  bank_iban       text,
  bank_name       text,
  notes           text,
  is_active       boolean default true,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists idx_suppliers_tenant on suppliers(tenant_id, created_at desc);
create index if not exists idx_suppliers_name   on suppliers(tenant_id, name);

alter table suppliers enable row level security;

drop policy if exists "tenant_rw_suppliers" on suppliers;
create policy "tenant_rw_suppliers" on suppliers
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on suppliers to authenticated;
grant all on suppliers to service_role;

-- ── Expenses ───────────────────────────────────────────────────────────────
create table if not exists expenses (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  created_by      uuid references auth.users(id),
  number          text not null,
  supplier_id     uuid references suppliers(id) on delete set null,
  supplier_name   text,                 -- free-text fallback
  category        text not null default 'other'
                  check (category in ('rent','utilities','salaries','supplies','marketing',
                                      'maintenance','insurance','professional','materials',
                                      'shipping','other')),
  description     text not null,
  amount          numeric(14,2) not null default 0,   -- before VAT
  vat_amount      numeric(14,2) not null default 0,
  total           numeric(14,2) not null default 0,   -- amount + vat_amount
  vat_deductible  boolean default false,
  expense_date    date not null default current_date,
  due_date        date,
  payment_status  text not null default 'unpaid'
                  check (payment_status in ('unpaid','partial','paid')),
  payment_method  text default 'bank_transfer'
                  check (payment_method in ('cash','card','bank_transfer','e_wallet','other')),
  reference_number text,
  receipt_url     text,
  notes           text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists idx_expenses_tenant   on expenses(tenant_id, expense_date desc);
create index if not exists idx_expenses_status   on expenses(tenant_id, payment_status);
create index if not exists idx_expenses_category on expenses(tenant_id, category);
create index if not exists idx_expenses_supplier on expenses(supplier_id);

alter table expenses enable row level security;

drop policy if exists "tenant_rw_expenses" on expenses;
create policy "tenant_rw_expenses" on expenses
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on expenses to authenticated;
grant all on expenses to service_role;

-- ── Expense Payments ───────────────────────────────────────────────────────
create table if not exists expense_payments (
  id              uuid primary key default gen_random_uuid(),
  expense_id      uuid references expenses(id) on delete cascade not null,
  tenant_id       uuid references tenants(id) on delete cascade not null,
  amount          numeric(14,2) not null,
  payment_date    date not null default current_date,
  payment_method  text default 'bank_transfer',
  reference       text,
  notes           text,
  created_at      timestamptz default now()
);

create index if not exists idx_exp_payments_expense on expense_payments(expense_id);
create index if not exists idx_exp_payments_tenant  on expense_payments(tenant_id);

alter table expense_payments enable row level security;

drop policy if exists "tenant_rw_expense_payments" on expense_payments;
create policy "tenant_rw_expense_payments" on expense_payments
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on expense_payments to authenticated;
grant all on expense_payments to service_role;

-- ── Auto-update payment_status after payment insert/delete ────────────────
create or replace function sync_expense_payment_status()
returns trigger language plpgsql security definer as $$
declare
  exp expenses%rowtype;
  paid_total numeric;
begin
  select * into exp from expenses where id = coalesce(NEW.expense_id, OLD.expense_id);
  select coalesce(sum(amount), 0) into paid_total
    from expense_payments where expense_id = exp.id;

  update expenses set
    payment_status = case
      when paid_total <= 0                then 'unpaid'
      when paid_total < exp.total - 0.01  then 'partial'
      else                                     'paid'
    end,
    updated_at = now()
  where id = exp.id;

  return coalesce(NEW, OLD);
end;
$$;

drop trigger if exists trg_sync_exp_status on expense_payments;
create trigger trg_sync_exp_status
  after insert or delete on expense_payments
  for each row execute function sync_expense_payment_status();

-- ── Auto-update supplier balance view ─────────────────────────────────────
create or replace view supplier_balances as
select
  s.id,
  s.tenant_id,
  s.name,
  s.category,
  s.phone,
  s.payment_terms,
  s.is_active,
  coalesce(sum(case when e.payment_status != 'paid' then e.total - coalesce(ep.paid,0) else 0 end), 0) as balance_due
from suppliers s
left join expenses e on e.supplier_id = s.id
left join lateral (
  select coalesce(sum(amount),0) as paid from expense_payments where expense_id = e.id
) ep on true
group by s.id;

grant select on supplier_balances to authenticated;

-- ── Helper: next expense number ────────────────────────────────────────────
create or replace function next_expense_number(p_tenant_id uuid)
returns text language plpgsql security definer as $$
declare
  next_num integer;
begin
  select coalesce(count(*), 0) + 1 into next_num
    from expenses where tenant_id = p_tenant_id;
  return 'EXP-' || extract(year from current_date) || '-' || lpad(next_num::text, 5, '0');
end;
$$;

grant execute on function next_expense_number(uuid) to authenticated;

select 'Expenses & Suppliers tables ready ✅' as status;

-- ══════════════════════════════════════════════════════════════════════════
-- Invoice Advanced Features: Payments, Stock, Reminders
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Payments table (track every payment on an invoice) ────────────
create table if not exists invoice_payments (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references tenants(id) on delete cascade not null,
  invoice_id   uuid references invoices(id) on delete cascade not null,
  amount       numeric(14,2) not null,
  method       text not null check (method in ('cash','card','bank','wallet','other')),
  reference    text,
  notes        text,
  paid_at      timestamptz not null default now(),
  recorded_by  uuid references auth.users(id),
  created_at   timestamptz default now()
);

create index if not exists idx_pay_tenant on invoice_payments(tenant_id);
create index if not exists idx_pay_inv on invoice_payments(invoice_id);
create index if not exists idx_pay_date on invoice_payments(paid_at desc);

alter table invoice_payments enable row level security;

drop policy if exists "tenant_rw_payments" on invoice_payments;
create policy "tenant_rw_payments" on invoice_payments
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on invoice_payments to authenticated;
grant all on invoice_payments to service_role;

-- ─── 2. Add invoice payment tracking fields ─────────────────────────
alter table invoices
  add column if not exists paid_at      timestamptz,
  add column if not exists payment_status text default 'unpaid'
    check (payment_status in ('unpaid','partial','paid')),
  add column if not exists amount_paid  numeric(14,2) default 0,
  add column if not exists amount_due   numeric(14,2);

-- Trigger: update payment_status when payments are added
create or replace function update_invoice_payment_status()
returns trigger language plpgsql as $$
declare
  inv_total numeric;
  total_paid numeric;
begin
  select total into inv_total from invoices where id = NEW.invoice_id;
  select coalesce(sum(amount), 0) into total_paid
  from invoice_payments where invoice_id = NEW.invoice_id;

  update invoices set
    amount_paid = total_paid,
    amount_due  = greatest(0, inv_total - total_paid),
    payment_status = case
      when total_paid >= inv_total then 'paid'
      when total_paid > 0 then 'partial'
      else 'unpaid'
    end,
    paid_at = case when total_paid >= inv_total then now() else null end,
    status = case when total_paid >= inv_total then 'paid' else status end
  where id = NEW.invoice_id;

  return NEW;
end;
$$;

drop trigger if exists trg_update_payment_status on invoice_payments;
create trigger trg_update_payment_status
  after insert or update or delete on invoice_payments
  for each row execute function update_invoice_payment_status();

-- ─── 3. Stock movements table ──────────────────────────────────────
create table if not exists stock_movements (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references tenants(id) on delete cascade not null,
  product_id   text not null,    -- localStorage product ID (numeric/string)
  product_name text not null,
  movement_type text not null check (movement_type in ('sale','purchase','return','adjustment')),
  quantity     numeric(14,3) not null,  -- positive = increase, negative = decrease
  invoice_id   uuid references invoices(id) on delete set null,
  notes        text,
  created_at   timestamptz default now(),
  created_by   uuid references auth.users(id)
);

create index if not exists idx_stock_tenant on stock_movements(tenant_id, created_at desc);
create index if not exists idx_stock_product on stock_movements(tenant_id, product_id);

alter table stock_movements enable row level security;
drop policy if exists "tenant_rw_stock" on stock_movements;
create policy "tenant_rw_stock" on stock_movements
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on stock_movements to authenticated;
grant all on stock_movements to service_role;

-- ─── 4. Reminders log ──────────────────────────────────────────────
create table if not exists invoice_reminders (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid references tenants(id) on delete cascade not null,
  invoice_id uuid references invoices(id) on delete cascade not null,
  channel    text not null check (channel in ('whatsapp','email','sms','system')),
  recipient  text,
  message    text,
  sent_at    timestamptz not null default now(),
  sent_by    uuid references auth.users(id),
  status     text default 'sent' check (status in ('sent','failed','pending'))
);

create index if not exists idx_rem_invoice on invoice_reminders(invoice_id);
create index if not exists idx_rem_tenant on invoice_reminders(tenant_id, sent_at desc);

alter table invoice_reminders enable row level security;
drop policy if exists "tenant_rw_reminders" on invoice_reminders;
create policy "tenant_rw_reminders" on invoice_reminders
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  ) with check (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on invoice_reminders to authenticated;
grant all on invoice_reminders to service_role;

-- ─── 5. Initialize amount_due for existing invoices ────────────────
update invoices set amount_due = total where amount_due is null;

-- ─── 6. View: Accounts Receivable Aging ────────────────────────────
create or replace view ar_aging as
with invoice_age as (
  select
    i.tenant_id,
    coalesce(i.client_name, i.buyer_name, 'عميل') as client_name,
    i.id,
    i.number,
    i.total,
    coalesce(i.amount_paid, 0) as paid,
    coalesce(i.amount_due, i.total) as outstanding,
    i.due_date,
    i.issue_date,
    case
      when i.payment_status = 'paid' then 0
      when i.due_date is null then current_date - i.issue_date
      else current_date - i.due_date
    end as days_overdue
  from invoices i
  where i.invoice_kind = 'invoice'
    and coalesce(i.amount_due, i.total) > 0
)
select
  tenant_id,
  client_name,
  count(*) as invoice_count,
  sum(outstanding) as total_outstanding,
  sum(case when days_overdue <= 0 then outstanding else 0 end) as current_amount,
  sum(case when days_overdue between 1 and 30 then outstanding else 0 end) as days_1_30,
  sum(case when days_overdue between 31 and 60 then outstanding else 0 end) as days_31_60,
  sum(case when days_overdue between 61 and 90 then outstanding else 0 end) as days_61_90,
  sum(case when days_overdue > 90 then outstanding else 0 end) as days_90_plus
from invoice_age
group by tenant_id, client_name
order by sum(outstanding) desc;

grant select on ar_aging to authenticated;

-- ─── Done ───────────────────────────────────────────────────────────
select 'Invoice advanced features ready ✅' as status;

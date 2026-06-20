-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Recurring Expenses (مصاريف متكرّرة: إيجار، رواتب، إنترنت)
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists recurring_expenses (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  created_by      uuid references auth.users(id) on delete set null,

  -- Expense template
  description     text not null,
  amount          numeric(14,2) not null,
  vat_amount      numeric(14,2) default 0,
  category        text,
  supplier_id     uuid references suppliers(id) on delete set null,
  supplier_name   text,
  payment_method  text default 'bank' check (payment_method in ('cash','card','bank','wallet','other')),
  notes           text,

  -- Recurrence
  frequency       text not null check (frequency in ('weekly','monthly','quarterly','yearly')),
  day_of_month    int check (day_of_month between 1 and 31),
  day_of_week     int check (day_of_week between 0 and 6),
  start_date      date not null default current_date,
  end_date        date,

  -- Tracking
  next_due_date     date not null,
  last_generated_at timestamptz,
  generated_count   int default 0,
  active            boolean default true,
  auto_post         boolean default true,

  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists idx_recexp_tenant on recurring_expenses(tenant_id, next_due_date);
create index if not exists idx_recexp_due    on recurring_expenses(next_due_date) where active = true;

alter table recurring_expenses enable row level security;

drop policy if exists "tenant_rw_recexp" on recurring_expenses;
create policy "tenant_rw_recexp" on recurring_expenses for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on recurring_expenses to authenticated;

-- ─── Compute next due date based on frequency ────────────────────────────
create or replace function compute_next_due(
  current_due date,
  freq text
)
returns date
language plpgsql
immutable
as $$
begin
  return case freq
    when 'weekly'    then current_due + interval '7 days'
    when 'monthly'   then current_due + interval '1 month'
    when 'quarterly' then current_due + interval '3 months'
    when 'yearly'    then current_due + interval '1 year'
    else current_due + interval '1 month'
  end;
end;
$$;

-- ─── Generate due recurring expenses (auto-create real expenses) ─────────
create or replace function generate_due_recurring_expenses()
returns json
language plpgsql
security definer
as $$
declare
  rec record;
  created_count int := 0;
  expense_id uuid;
  my_tenant uuid;
begin
  -- Run for caller's tenant only
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then
    return json_build_object('success', false, 'reason', 'no_tenant');
  end if;

  for rec in
    select * from recurring_expenses
     where tenant_id = my_tenant
       and active = true
       and auto_post = true
       and next_due_date <= current_date
       and (end_date is null or next_due_date <= end_date)
  loop
    -- Skip if already generated today (defensive)
    if rec.last_generated_at is not null
       and rec.last_generated_at::date = current_date then
      continue;
    end if;

    -- Insert real expense
    insert into expenses (
      tenant_id, description, amount, vat_amount, category,
      supplier_id, supplier_name, payment_method,
      expense_date, payment_status, notes, source, created_by
    ) values (
      rec.tenant_id, rec.description, rec.amount, coalesce(rec.vat_amount, 0), rec.category,
      rec.supplier_id, rec.supplier_name, rec.payment_method,
      rec.next_due_date, 'unpaid', rec.notes, 'recurring', rec.created_by
    ) returning id into expense_id;

    -- Update recurring record
    update recurring_expenses set
      last_generated_at = now(),
      generated_count   = generated_count + 1,
      next_due_date     = compute_next_due(next_due_date, frequency),
      updated_at        = now()
    where id = rec.id;

    created_count := created_count + 1;
  end loop;

  return json_build_object('success', true, 'created', created_count);
end;
$$;

grant execute on function generate_due_recurring_expenses() to authenticated;

-- ─── Count overdue recurring expenses (for badge) ────────────────────────
create or replace function count_overdue_recurring()
returns int
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  cnt int;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then return 0; end if;

  select count(*) into cnt
    from recurring_expenses
   where tenant_id = my_tenant
     and active = true
     and next_due_date <= current_date
     and (end_date is null or next_due_date <= end_date);
  return cnt;
end;
$$;

grant execute on function count_overdue_recurring() to authenticated;

-- Add 'recurring' to expenses.source if needed (idempotent)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'expenses_source_check'
  ) then
    null; -- no source check, skip
  end if;
end $$;

notify pgrst, 'reload schema';

select 'Recurring expenses ready ✅' as status;

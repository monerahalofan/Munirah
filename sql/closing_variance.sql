-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Closing-to-Bank Reconciliation (تتبع فرق الإغلاق والإيداع)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Add bank reconciliation columns to daily_closings ────────────────
alter table daily_closings add column if not exists bank_deposit_amount numeric(14,2);
alter table daily_closings add column if not exists bank_deposit_date   date;
alter table daily_closings add column if not exists bank_deposit_ref    text;
alter table daily_closings add column if not exists cash_in_safe        numeric(14,2) default 0;
alter table daily_closings add column if not exists variance_amount     numeric(14,2);
alter table daily_closings add column if not exists variance_breakdown  jsonb;
alter table daily_closings add column if not exists variance_note       text;
alter table daily_closings add column if not exists reconciled_at       timestamptz;
alter table daily_closings add column if not exists reconciled_by       uuid references auth.users(id);

-- ─── 2. Variance categories reference table ──────────────────────────────
-- breakdown JSON shape:
-- { "tips": 12.50, "cash_shortage": 5.00, "bank_fees": 2.00, "cash_refund": 0,
--   "petty_cash": 8.00, "other": 2.50 }

create or replace function reconcile_closing(
  closing_id_in uuid,
  bank_deposit_in numeric,
  bank_deposit_date_in date,
  bank_deposit_ref_in text,
  cash_in_safe_in numeric,
  breakdown_in jsonb,
  note_in text
)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  cls daily_closings%rowtype;
  expected_deposit numeric;
  computed_variance numeric;
begin
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid()
   limit 1;

  if my_tenant is null then
    raise exception 'unauthorized';
  end if;

  select * into cls from daily_closings where id = closing_id_in and tenant_id = my_tenant;
  if cls.id is null then
    raise exception 'closing not found';
  end if;

  -- Expected deposit = cash + card + bank + wallet − returns − cash_in_safe − sum(breakdown)
  expected_deposit := coalesce(cls.cash_amount,0) + coalesce(cls.card_amount,0)
                    + coalesce(cls.bank_amount,0) + coalesce(cls.wallet_amount,0)
                    - coalesce(cls.returns_amount,0)
                    - coalesce(cash_in_safe_in, 0);

  computed_variance := coalesce(bank_deposit_in, 0) - expected_deposit;

  update daily_closings
     set bank_deposit_amount = bank_deposit_in,
         bank_deposit_date   = bank_deposit_date_in,
         bank_deposit_ref    = bank_deposit_ref_in,
         cash_in_safe        = cash_in_safe_in,
         variance_amount     = computed_variance,
         variance_breakdown  = breakdown_in,
         variance_note       = note_in,
         reconciled_at       = now(),
         reconciled_by       = auth.uid()
   where id = closing_id_in;

  return json_build_object(
    'success', true,
    'expected_deposit', expected_deposit,
    'variance', computed_variance
  );
end;
$$;

grant execute on function reconcile_closing(uuid, numeric, date, text, numeric, jsonb, text) to authenticated;

-- ─── 3. Variance summary view (for reports) ──────────────────────────────
create or replace view closing_variance_summary as
select
  tenant_id,
  date_trunc('month', closing_date) as month,
  count(*)                                            as total_closings,
  count(reconciled_at)                                as reconciled_count,
  sum(coalesce(total_sales, 0))                       as total_sales,
  sum(coalesce(bank_deposit_amount, 0))               as total_deposited,
  sum(coalesce(variance_amount, 0))                   as net_variance,
  sum(case when variance_amount > 0 then variance_amount else 0 end) as positive_variance,
  sum(case when variance_amount < 0 then variance_amount else 0 end) as negative_variance,
  sum(coalesce((variance_breakdown->>'tips')::numeric, 0))           as total_tips,
  sum(coalesce((variance_breakdown->>'cash_shortage')::numeric, 0))  as total_shortage,
  sum(coalesce((variance_breakdown->>'bank_fees')::numeric, 0))      as total_fees,
  sum(coalesce((variance_breakdown->>'petty_cash')::numeric, 0))     as total_petty
from daily_closings
where reconciled_at is not null
group by tenant_id, date_trunc('month', closing_date);

grant select on closing_variance_summary to authenticated;

-- ─── 4. Refresh PostgREST cache ──────────────────────────────────────────
notify pgrst, 'reload schema';

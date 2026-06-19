-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — B2C / B2B Mode (تحديد نوع العملاء)
-- ══════════════════════════════════════════════════════════════════════════

alter table tenants add column if not exists customer_type text
  check (customer_type in ('b2c','b2b','both'));

-- Auto-derive for existing tenants based on business_type
update tenants set customer_type =
  case
    when business_type in ('retail','restaurant') then 'b2c'
    when business_type in ('services','wholesale','manufacturing') then 'b2b'
    else 'both'
  end
where customer_type is null and business_type is not null;

notify pgrst, 'reload schema';

select 'customer_type column ready ✅' as status;

-- Add business info columns to tenants
alter table tenants
  add column if not exists vat_number text,
  add column if not exists cr_number  text,
  add column if not exists city       text default 'الرياض',
  add column if not exists address    text;

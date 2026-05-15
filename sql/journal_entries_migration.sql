-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Journal Entries (نظام القيد المزدوج)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── Journal Entries ──────────────────────────────────────────────────────
-- كل سطر = حركة محاسبية واحدة (مدين أو دائن)
-- مجموع المدين = مجموع الدائن لكل ref_id (متوازنة)
create table if not exists journal_entries (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  account_code  text not null,                                -- يربط بـ chart_of_accounts.code
  entry_date    date not null default current_date,
  debit         numeric(14,2) default 0,                       -- مدين
  credit        numeric(14,2) default 0,                       -- دائن
  description   text,
  ref_type      text check (ref_type in ('transaction','invoice','manual','opening')),
  ref_id        uuid,                                          -- معرف المعاملة/الفاتورة الأصلية
  cost_center   text,                                          -- مركز التكلفة (الفرع)
  created_by    uuid references auth.users(id),
  created_at    timestamptz default now(),
  check (debit >= 0 and credit >= 0),
  check (debit > 0 or credit > 0)
);

create index if not exists idx_je_tenant    on journal_entries(tenant_id);
create index if not exists idx_je_account   on journal_entries(tenant_id, account_code);
create index if not exists idx_je_date      on journal_entries(tenant_id, entry_date);
create index if not exists idx_je_ref       on journal_entries(tenant_id, ref_type, ref_id);

alter table journal_entries enable row level security;

create policy "tenant_isolation_je" on journal_entries
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

-- ─── View: account balances (الأرصدة الحالية) ─────────────────────────────
create or replace view account_balances as
select
  tenant_id,
  account_code,
  sum(debit)            as total_debit,
  sum(credit)           as total_credit,
  sum(debit - credit)   as balance
from journal_entries
group by tenant_id, account_code;

-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Subscriptions & Payments (Tap Integration)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── Subscriptions table ──────────────────────────────────────────────────
create table if not exists subscriptions (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  plan            text not null check (plan in ('starter','pro','business')),
  status          text not null default 'pending'
                    check (status in ('pending','active','past_due','cancelled','failed')),
  billing_cycle   text not null default 'monthly' check (billing_cycle in ('monthly','yearly')),
  amount_sar      numeric(10,2) not null,
  starts_at       timestamptz,
  ends_at         timestamptz,
  cancelled_at    timestamptz,
  tap_customer_id text,
  tap_card_id     text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists idx_sub_tenant on subscriptions(tenant_id);
create index if not exists idx_sub_status on subscriptions(tenant_id, status);

-- ─── Payments log (every Tap transaction) ─────────────────────────────────
create table if not exists payments (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  subscription_id uuid references subscriptions(id) on delete set null,
  tap_charge_id   text unique,                                  -- معرف Tap الفريد
  amount_sar      numeric(10,2) not null,
  currency        text default 'SAR',
  status          text not null check (status in
                    ('INITIATED','IN_PROGRESS','CAPTURED','AUTHORIZED','FAILED','CANCELLED','VOID','TIMEDOUT')),
  payment_method  text,                                          -- mada, visa, mastercard, apple_pay
  reference       text,                                          -- internal reference (subscription_id-cycle)
  receipt_url     text,
  failure_reason  text,
  metadata        jsonb default '{}'::jsonb,
  created_at      timestamptz default now(),
  paid_at         timestamptz
);

create index if not exists idx_pay_tenant      on payments(tenant_id);
create index if not exists idx_pay_charge      on payments(tap_charge_id);
create index if not exists idx_pay_status      on payments(tenant_id, status);

-- ─── RLS ──────────────────────────────────────────────────────────────────
alter table subscriptions enable row level security;
alter table payments      enable row level security;

create policy "tenant_isolation_sub" on subscriptions
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

create policy "tenant_isolation_pay" on payments
  for all using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

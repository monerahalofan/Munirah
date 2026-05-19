-- ══════════════════════════════════════════════════════════════════════════
-- ZATCA Phase 2: Integration with Fatoora API
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Extend zatca_config with Phase 2 fields ────────────────────────
alter table zatca_config
  add column if not exists environment text not null default 'sandbox'
    check (environment in ('sandbox', 'simulation', 'production')),
  add column if not exists compliance_csid text,           -- Initial CSID from compliance API
  add column if not exists compliance_secret text,         -- Secret returned with CSID
  add column if not exists production_csid text,           -- Production CSID (after compliance tests pass)
  add column if not exists production_secret text,
  add column if not exists csr_content text,               -- The CSR we generated
  add column if not exists certificate text,               -- Active certificate (compliance or production)
  add column if not exists certificate_secret text,        -- Active secret
  add column if not exists onboarded_at timestamptz,
  add column if not exists last_compliance_check timestamptz,
  add column if not exists compliance_passed boolean default false;

-- ─── 2. Submission log: track every ZATCA API call ─────────────────────
create table if not exists zatca_submissions (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  invoice_id      uuid references invoices(id) on delete cascade,
  submission_type text not null check (submission_type in ('compliance','clearance','reporting','onboard')),
  environment     text not null,
  request_body    jsonb,
  response_body   jsonb,
  response_status integer,
  zatca_status    text,           -- ACCEPTED / ACCEPTED_WITH_WARNINGS / REJECTED
  warnings        jsonb,
  errors          jsonb,
  retry_count     integer default 0,
  next_retry_at   timestamptz,
  created_at      timestamptz default now()
);

create index if not exists idx_zatca_sub_tenant on zatca_submissions(tenant_id, created_at desc);
create index if not exists idx_zatca_sub_invoice on zatca_submissions(invoice_id);
create index if not exists idx_zatca_sub_retry on zatca_submissions(next_retry_at)
  where zatca_status = 'REJECTED' and retry_count < 5;

alter table zatca_submissions enable row level security;

create policy "tenant_read_submissions" on zatca_submissions
  for select using (
    tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  );

grant all on zatca_submissions to service_role;
grant select on zatca_submissions to authenticated;

-- ─── 3. Add submission tracking to invoices ────────────────────────────
alter table invoices
  add column if not exists zatca_submitted_at timestamptz,
  add column if not exists zatca_response jsonb,
  add column if not exists zatca_warnings jsonb,
  add column if not exists zatca_errors jsonb,
  add column if not exists zatca_cleared_invoice text;  -- Signed XML returned by ZATCA

-- ─── 4. Helper: mark tenant as ZATCA-onboarded ─────────────────────────
create or replace function zatca_mark_onboarded(
  p_tenant_id uuid,
  p_csid text,
  p_secret text,
  p_certificate text,
  p_environment text default 'sandbox'
)
returns void
language plpgsql
security definer
as $$
begin
  update zatca_config set
    compliance_csid    = case when p_environment in ('sandbox','simulation') then p_csid else compliance_csid end,
    compliance_secret  = case when p_environment in ('sandbox','simulation') then p_secret else compliance_secret end,
    production_csid    = case when p_environment = 'production' then p_csid else production_csid end,
    production_secret  = case when p_environment = 'production' then p_secret else production_secret end,
    certificate        = p_certificate,
    certificate_secret = p_secret,
    environment        = p_environment,
    onboarded          = true,
    onboarded_at       = coalesce(onboarded_at, now())
  where tenant_id = p_tenant_id;
end;
$$;

grant execute on function zatca_mark_onboarded(uuid, text, text, text, text) to service_role;

-- ─── Done ──────────────────────────────────────────────────────────────
select 'ZATCA Phase 2 schema ready ✅' as status;

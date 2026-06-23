-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — ZATCA Automation (Smart Wizard + Auto-Renewal + Health Monitor)
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. ZATCA state per tenant ───────────────────────────────────────────
create table if not exists zatca_state (
  tenant_id            uuid primary key references tenants(id) on delete cascade,

  -- Onboarding status
  status               text default 'not_started'
                         check (status in ('not_started','csr_generated','otp_pending','onboarded','failed','expired')),
  onboarded_at         timestamptz,

  -- Cryptography (encrypted at rest by Supabase)
  csr                  text,
  ccsid                text,                -- Compliance CSID (1 year)
  pcsid                text,                -- Production CSID (3 years)
  private_key          text,                -- ECDSA private key (encrypted)
  public_key           text,

  -- Expiry tracking
  ccsid_expires_at     timestamptz,
  pcsid_expires_at     timestamptz,
  last_renewal_at      timestamptz,
  last_renewal_status  text,

  -- Health metrics
  total_invoices_sent  int default 0,
  total_accepted       int default 0,
  total_rejected       int default 0,
  total_warnings       int default 0,
  last_invoice_sent_at timestamptz,
  last_invoice_status  text,
  last_error_message   text,

  -- Wave detection
  estimated_wave       int,
  wave_mandatory_at    date,
  wave_notified_at     timestamptz,

  -- Auto-renewal preferences
  auto_renew_enabled   boolean default true,
  renewal_alert_days   int default 30,

  -- Metadata
  environment          text default 'sandbox' check (environment in ('sandbox','simulation','production')),
  created_at           timestamptz default now(),
  updated_at           timestamptz default now()
);

create index if not exists idx_zatca_expiry on zatca_state(ccsid_expires_at) where status = 'onboarded';
create index if not exists idx_zatca_wave   on zatca_state(wave_mandatory_at) where wave_notified_at is null;

alter table zatca_state enable row level security;
drop policy if exists "tenant_rw_zatca_state" on zatca_state;
create policy "tenant_rw_zatca_state" on zatca_state for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on zatca_state to authenticated;

-- ─── 2. Per-invoice ZATCA log ────────────────────────────────────────────
create table if not exists zatca_invoice_log (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  invoice_id      uuid,
  invoice_number  text,
  invoice_type    text check (invoice_type in ('standard','simplified','credit_note','debit_note')),
  uuid_zatca      text,
  hash            text,
  pih             text,
  status          text not null check (status in ('pending','submitted','accepted','rejected','warning','failed','retry')),
  zatca_status    text,
  warnings        jsonb,
  errors          jsonb,
  raw_response    jsonb,
  attempt_count   int default 1,
  submitted_at    timestamptz,
  responded_at    timestamptz,
  created_at      timestamptz default now()
);

create index if not exists idx_zatca_log_tenant on zatca_invoice_log(tenant_id, created_at desc);
create index if not exists idx_zatca_log_status on zatca_invoice_log(status, created_at desc);

alter table zatca_invoice_log enable row level security;
drop policy if exists "tenant_r_zatca_log" on zatca_invoice_log;
create policy "tenant_r_zatca_log" on zatca_invoice_log for select using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant select on zatca_invoice_log to authenticated;
grant all    on zatca_invoice_log to service_role;

-- ─── 3. Auto-detect ZATCA wave based on annual revenue ───────────────────
create or replace function zatca_detect_wave(annual_revenue numeric)
returns table (wave int, mandatory_at date)
language plpgsql
immutable
as $$
begin
  -- ZATCA Phase 2 waves (simplified mapping based on public info)
  if annual_revenue >= 3000000000 then
    return query select 1, '2023-01-01'::date;
  elsif annual_revenue >= 500000000 then
    return query select 2, '2023-07-01'::date;
  elsif annual_revenue >= 250000000 then
    return query select 3, '2023-10-01'::date;
  elsif annual_revenue >= 150000000 then
    return query select 4, '2023-11-01'::date;
  elsif annual_revenue >= 100000000 then
    return query select 5, '2023-12-01'::date;
  elsif annual_revenue >= 70000000 then
    return query select 6, '2024-01-01'::date;
  elsif annual_revenue >= 50000000 then
    return query select 7, '2024-02-01'::date;
  elsif annual_revenue >= 40000000 then
    return query select 8, '2024-03-01'::date;
  elsif annual_revenue >= 30000000 then
    return query select 9, '2024-06-01'::date;
  elsif annual_revenue >= 25000000 then
    return query select 10, '2024-10-01'::date;
  elsif annual_revenue >= 15000000 then
    return query select 11, '2024-11-01'::date;
  elsif annual_revenue >= 10000000 then
    return query select 12, '2024-12-01'::date;
  elsif annual_revenue >= 7000000 then
    return query select 13, '2025-01-01'::date;
  elsif annual_revenue >= 5000000 then
    return query select 14, '2025-02-01'::date;
  elsif annual_revenue >= 4000000 then
    return query select 15, '2025-03-01'::date;
  elsif annual_revenue >= 3000000 then
    return query select 16, '2025-04-01'::date;
  elsif annual_revenue >= 2500000 then
    return query select 17, '2025-05-01'::date;
  elsif annual_revenue >= 2000000 then
    return query select 18, '2025-06-01'::date;
  elsif annual_revenue >= 1750000 then
    return query select 19, '2025-08-01'::date;
  elsif annual_revenue >= 1500000 then
    return query select 20, '2025-09-01'::date;
  elsif annual_revenue >= 1000000 then
    return query select 21, '2025-10-01'::date;
  elsif annual_revenue >= 750000 then
    return query select 22, '2025-12-01'::date;
  else
    return query select 23, '2026-03-01'::date;
  end if;
end;
$$;

grant execute on function zatca_detect_wave(numeric) to authenticated;

-- ─── 4. RPC: Compute current health snapshot ─────────────────────────────
create or replace function zatca_health_snapshot()
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  st zatca_state%rowtype;
  annual_rev numeric := 0;
  wave_info record;
  last_24h_count int := 0;
  last_24h_accepted int := 0;
  last_24h_rejected int := 0;
  days_until_expiry int;
  days_until_mandatory int;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then
    return json_build_object('error', 'no_tenant');
  end if;

  -- Get or create state
  select * into st from zatca_state where tenant_id = my_tenant;
  if st.tenant_id is null then
    insert into zatca_state (tenant_id) values (my_tenant) returning * into st;
  end if;

  -- Compute annual revenue from past 12 months
  select coalesce(sum(amount), 0) into annual_rev
    from transactions
   where tenant_id = my_tenant and type = 'income'
     and date >= current_date - interval '12 months';

  -- Auto-detect wave
  if annual_rev > 0 then
    select wave, mandatory_at into wave_info
      from zatca_detect_wave(annual_rev) limit 1;
  end if;

  -- 24h stats
  select count(*),
         count(*) filter (where status = 'accepted'),
         count(*) filter (where status = 'rejected')
    into last_24h_count, last_24h_accepted, last_24h_rejected
    from zatca_invoice_log
   where tenant_id = my_tenant
     and created_at > now() - interval '24 hours';

  days_until_expiry := case when st.ccsid_expires_at is not null
    then extract(day from (st.ccsid_expires_at - now()))::int else null end;

  days_until_mandatory := case when wave_info.mandatory_at is not null
    then (wave_info.mandatory_at - current_date)::int else null end;

  return json_build_object(
    'tenant_id',           my_tenant,
    'status',              st.status,
    'environment',         st.environment,
    'onboarded',           st.status = 'onboarded',
    'onboarded_at',        st.onboarded_at,
    'ccsid_expires_at',    st.ccsid_expires_at,
    'pcsid_expires_at',    st.pcsid_expires_at,
    'days_until_expiry',   days_until_expiry,
    'needs_renewal',       coalesce(days_until_expiry < st.renewal_alert_days, false),
    'auto_renew_enabled',  st.auto_renew_enabled,
    'last_renewal_at',     st.last_renewal_at,
    'lifetime_sent',       st.total_invoices_sent,
    'lifetime_accepted',   st.total_accepted,
    'lifetime_rejected',   st.total_rejected,
    'lifetime_warnings',   st.total_warnings,
    'last_invoice_sent_at', st.last_invoice_sent_at,
    'last_24h_sent',       last_24h_count,
    'last_24h_accepted',   last_24h_accepted,
    'last_24h_rejected',   last_24h_rejected,
    'acceptance_rate',     case when st.total_invoices_sent > 0
                              then round((st.total_accepted::numeric / st.total_invoices_sent) * 100, 1)
                              else null end,
    'annual_revenue',      annual_rev,
    'estimated_wave',      coalesce(wave_info.wave, st.estimated_wave),
    'wave_mandatory_at',   coalesce(wave_info.mandatory_at, st.wave_mandatory_at),
    'days_until_mandatory', days_until_mandatory,
    'is_due_soon',         coalesce(days_until_mandatory < 180, false)
  );
end;
$$;

grant execute on function zatca_health_snapshot() to authenticated;

-- ─── 5. RPC: Update wave detection (call periodically) ───────────────────
create or replace function zatca_refresh_wave()
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  annual_rev numeric;
  wave_info record;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() and role = 'admin' limit 1;
  if my_tenant is null then
    return json_build_object('error', 'unauthorized');
  end if;

  select coalesce(sum(amount), 0) into annual_rev
    from transactions where tenant_id = my_tenant and type = 'income'
     and date >= current_date - interval '12 months';

  if annual_rev = 0 then
    return json_build_object('success', false, 'reason', 'no_revenue_data');
  end if;

  select wave, mandatory_at into wave_info
    from zatca_detect_wave(annual_rev) limit 1;

  insert into zatca_state (tenant_id, estimated_wave, wave_mandatory_at)
  values (my_tenant, wave_info.wave, wave_info.mandatory_at)
  on conflict (tenant_id) do update set
    estimated_wave    = excluded.estimated_wave,
    wave_mandatory_at = excluded.wave_mandatory_at,
    updated_at        = now();

  return json_build_object(
    'success', true,
    'annual_revenue', annual_rev,
    'wave', wave_info.wave,
    'mandatory_at', wave_info.mandatory_at
  );
end;
$$;

grant execute on function zatca_refresh_wave() to authenticated;

-- ─── 6. Track invoice status (called after each ZATCA submission) ────────
create or replace function zatca_log_invoice(
  invoice_id_in     uuid,
  invoice_number_in text,
  invoice_type_in   text,
  status_in         text,
  warnings_in       jsonb default null,
  errors_in         jsonb default null,
  uuid_in           text default null,
  hash_in           text default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  log_id uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then raise exception 'unauthorized'; end if;

  insert into zatca_invoice_log (
    tenant_id, invoice_id, invoice_number, invoice_type,
    status, warnings, errors, uuid_zatca, hash,
    submitted_at, responded_at
  ) values (
    my_tenant, invoice_id_in, invoice_number_in, invoice_type_in,
    status_in, warnings_in, errors_in, uuid_in, hash_in,
    now(), now()
  ) returning id into log_id;

  -- Update rollup counters
  update zatca_state set
    total_invoices_sent  = total_invoices_sent + 1,
    total_accepted       = total_accepted + case when status_in = 'accepted' then 1 else 0 end,
    total_rejected       = total_rejected + case when status_in = 'rejected' then 1 else 0 end,
    total_warnings       = total_warnings + case when status_in = 'warning' then 1 else 0 end,
    last_invoice_sent_at = now(),
    last_invoice_status  = status_in,
    last_error_message   = case when status_in in ('rejected','failed') then errors_in::text else last_error_message end,
    updated_at           = now()
   where tenant_id = my_tenant;

  return log_id;
end;
$$;

grant execute on function zatca_log_invoice(uuid, text, text, text, jsonb, jsonb, text, text) to authenticated;

-- ─── 7. View: tenants needing renewal (for cron job) ─────────────────────
create or replace view zatca_needs_renewal as
select tenant_id, ccsid_expires_at, renewal_alert_days,
  extract(day from (ccsid_expires_at - now()))::int as days_left
from zatca_state
where status = 'onboarded'
  and auto_renew_enabled = true
  and ccsid_expires_at is not null
  and ccsid_expires_at - now() < (renewal_alert_days || ' days')::interval
  and (last_renewal_at is null or last_renewal_at < now() - interval '7 days');

grant select on zatca_needs_renewal to service_role;

notify pgrst, 'reload schema';

select 'ZATCA automation ready ✅' as status;

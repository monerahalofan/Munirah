-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Authentica OTP Integration
-- جدول مؤقت لتتبع طلبات الـ OTP (Authentica لا يخزن الـ OTP في جانبه)
-- ══════════════════════════════════════════════════════════════════════════

-- Track outgoing OTP requests (for audit + rate limiting)
create table if not exists otp_requests (
  id            uuid primary key default gen_random_uuid(),
  phone         text not null,
  channel       text not null check (channel in ('sms','whatsapp')),
  status        text not null default 'sent' check (status in ('sent','verified','failed','expired')),
  ip_address    text,
  user_agent    text,
  context       text default 'login' check (context in ('login','capture','signup')),
  tenant_hint   uuid,
  provider_ref  text,
  verified_at   timestamptz,
  created_at    timestamptz default now(),
  expires_at    timestamptz default (now() + interval '10 minutes')
);

create index if not exists idx_otp_phone on otp_requests(phone, created_at desc);
create index if not exists idx_otp_status on otp_requests(status, created_at desc);

-- Rate limit helper: count recent OTPs for a phone
create or replace function otp_recent_count(phone_in text, minutes_in int default 10)
returns int
language sql
as $$
  select count(*)::int from otp_requests
   where phone = phone_in
     and created_at > now() - (minutes_in || ' minutes')::interval;
$$;

-- Cleanup old OTPs (run via cron or on every send)
create or replace function otp_cleanup_expired()
returns int
language plpgsql
as $$
declare
  deleted_count int;
begin
  delete from otp_requests
   where expires_at < now() - interval '1 hour';
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

-- RLS — only service-role can read/write
alter table otp_requests enable row level security;

-- No policies for authenticated — only service-role bypasses RLS
-- (Edge Functions use service-role key)

grant all on otp_requests to service_role;
grant execute on function otp_recent_count(text, int) to service_role;
grant execute on function otp_cleanup_expired() to service_role;

notify pgrst, 'reload schema';

select 'Authentica OTP table ready ✅' as status;

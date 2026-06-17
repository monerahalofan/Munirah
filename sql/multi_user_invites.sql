-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Multi-User Invites (دعوة كاشير/محاسب بإيميل منفصل)
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Invites table ─────────────────────────────────────────────────────
create table if not exists tenant_invites (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  email         text not null,
  role          text not null default 'cashier'
                  check (role in ('admin','accountant','cashier','viewer')),
  display_name  text,
  invited_by    uuid references auth.users(id) on delete set null,
  accepted_at   timestamptz,
  accepted_by   uuid references auth.users(id) on delete set null,
  expires_at    timestamptz default (now() + interval '14 days'),
  created_at    timestamptz default now(),
  unique (tenant_id, email)
);

create index if not exists idx_invites_email on tenant_invites(lower(email)) where accepted_at is null;

alter table tenant_invites enable row level security;

-- Owners/admins can manage invites for their tenant
drop policy if exists "invites_select" on tenant_invites;
drop policy if exists "invites_insert" on tenant_invites;
drop policy if exists "invites_delete" on tenant_invites;

create policy "invites_select" on tenant_invites for select using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid() and role = 'admin')
  or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
);
create policy "invites_insert" on tenant_invites for insert with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid() and role = 'admin')
);
create policy "invites_delete" on tenant_invites for delete using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid() and role = 'admin')
);

-- ─── 2. RPC: Invite a user (admin only) ──────────────────────────────────
create or replace function invite_user(
  email_in text,
  role_in text default 'cashier',
  display_name_in text default null
)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  inv_id uuid;
begin
  -- Verify caller is admin of some tenant
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid() and role = 'admin'
   limit 1;

  if my_tenant is null then
    raise exception 'unauthorized: only tenant admins can invite';
  end if;

  if role_in not in ('admin','accountant','cashier','viewer') then
    raise exception 'invalid role';
  end if;

  -- Upsert invite (refresh expiry if already exists)
  insert into tenant_invites (tenant_id, email, role, display_name, invited_by)
  values (my_tenant, lower(trim(email_in)), role_in, display_name_in, auth.uid())
  on conflict (tenant_id, email) do update
    set role = excluded.role,
        display_name = excluded.display_name,
        invited_by = excluded.invited_by,
        expires_at = now() + interval '14 days',
        accepted_at = null,
        accepted_by = null
  returning id into inv_id;

  return json_build_object(
    'success', true,
    'invite_id', inv_id,
    'email', lower(trim(email_in)),
    'role', role_in
  );
end;
$$;

grant execute on function invite_user(text, text, text) to authenticated;

-- ─── 3. RPC: Accept invite (called on first login) ───────────────────────
create or replace function accept_pending_invite()
returns json
language plpgsql
security definer
as $$
declare
  my_email text;
  inv record;
begin
  my_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if my_email = '' then
    return json_build_object('success', false, 'reason', 'no_email');
  end if;

  -- Find pending invite for this email
  select * into inv
    from tenant_invites
   where lower(email) = my_email
     and accepted_at is null
     and expires_at > now()
   order by created_at desc
   limit 1;

  if inv.id is null then
    return json_build_object('success', false, 'reason', 'no_invite');
  end if;

  -- Already a member? Just mark accepted.
  if exists (select 1 from tenant_users where tenant_id = inv.tenant_id and user_id = auth.uid()) then
    update tenant_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
    return json_build_object('success', true, 'tenant_id', inv.tenant_id, 'role', inv.role, 'already_member', true);
  end if;

  -- Add as tenant member
  insert into tenant_users (tenant_id, user_id, role, display_name)
  values (inv.tenant_id, auth.uid(), inv.role, coalesce(inv.display_name, split_part(my_email, '@', 1)));

  update tenant_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;

  -- If user accidentally created their own tenant before accepting, delete it (empty only)
  delete from tenants
   where owner_id = auth.uid()
     and id <> inv.tenant_id
     and not exists (select 1 from invoices where tenant_id = tenants.id)
     and not exists (select 1 from transactions where tenant_id = tenants.id);

  return json_build_object('success', true, 'tenant_id', inv.tenant_id, 'role', inv.role);
end;
$$;

grant execute on function accept_pending_invite() to authenticated;

-- ─── 4. RPC: List team members + pending invites (admin only) ────────────
create or replace function list_team_members()
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid() and role = 'admin'
   limit 1;

  if my_tenant is null then
    raise exception 'unauthorized';
  end if;

  return json_build_object(
    'members', (
      select coalesce(json_agg(json_build_object(
        'user_id', tu.user_id,
        'email', u.email,
        'role', tu.role,
        'display_name', tu.display_name,
        'joined_at', tu.created_at,
        'last_sign_in', u.last_sign_in_at
      ) order by tu.created_at), '[]'::json)
      from tenant_users tu
      join auth.users u on u.id = tu.user_id
      where tu.tenant_id = my_tenant
    ),
    'pending', (
      select coalesce(json_agg(json_build_object(
        'invite_id', id,
        'email', email,
        'role', role,
        'display_name', display_name,
        'invited_at', created_at,
        'expires_at', expires_at
      ) order by created_at desc), '[]'::json)
      from tenant_invites
      where tenant_id = my_tenant
        and accepted_at is null
        and expires_at > now()
    )
  );
end;
$$;

grant execute on function list_team_members() to authenticated;

-- ─── 5. RPC: Remove a member or invite (admin only) ──────────────────────
create or replace function remove_team_member(target_user_id uuid)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid() and role = 'admin'
   limit 1;

  if my_tenant is null then
    raise exception 'unauthorized';
  end if;

  if target_user_id = auth.uid() then
    raise exception 'cannot remove yourself';
  end if;

  delete from tenant_users
   where tenant_id = my_tenant and user_id = target_user_id;

  return json_build_object('success', true);
end;
$$;

grant execute on function remove_team_member(uuid) to authenticated;

create or replace function revoke_invite(invite_id_in uuid)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid() and role = 'admin'
   limit 1;

  if my_tenant is null then
    raise exception 'unauthorized';
  end if;

  delete from tenant_invites
   where id = invite_id_in and tenant_id = my_tenant;

  return json_build_object('success', true);
end;
$$;

grant execute on function revoke_invite(uuid) to authenticated;

-- ─── 6. RPC: Change a member's role (admin only) ─────────────────────────
create or replace function update_member_role(target_user_id uuid, new_role text)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  admin_count int;
begin
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid() and role = 'admin'
   limit 1;

  if my_tenant is null then
    raise exception 'unauthorized';
  end if;

  if new_role not in ('admin','accountant','cashier','viewer') then
    raise exception 'invalid role';
  end if;

  -- Prevent removing the last admin
  if new_role <> 'admin' then
    select count(*) into admin_count from tenant_users
     where tenant_id = my_tenant and role = 'admin' and user_id <> target_user_id;
    if admin_count = 0 then
      raise exception 'cannot demote: at least one admin required';
    end if;
  end if;

  update tenant_users
     set role = new_role
   where tenant_id = my_tenant and user_id = target_user_id;

  return json_build_object('success', true, 'role', new_role);
end;
$$;

grant execute on function update_member_role(uuid, text) to authenticated;

-- ─── 7. Refresh PostgREST cache ──────────────────────────────────────────
notify pgrst, 'reload schema';

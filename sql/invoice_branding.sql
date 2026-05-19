-- ══════════════════════════════════════════════════════════════════════════
-- Invoice Branding & Customization
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Add branding columns to tenants ────────────────────────────────
alter table tenants
  add column if not exists logo_url        text,
  add column if not exists brand_color     text default '#86BA72',
  add column if not exists accent_color    text default '#2C5559',
  add column if not exists invoice_template text default 'classic'
    check (invoice_template in ('classic', 'modern', 'minimal', 'elegant')),
  add column if not exists invoice_footer  text,
  add column if not exists invoice_terms   text,
  add column if not exists company_phone   text,
  add column if not exists company_email   text,
  add column if not exists company_address text,
  add column if not exists company_website text,
  add column if not exists invoice_show_qr boolean default true,
  add column if not exists invoice_show_terms boolean default true,
  add column if not exists invoice_show_signature boolean default false;

-- ─── 2. Create logos storage bucket (run via Dashboard separately) ─────
-- Note: Storage bucket "logos" must be created manually in Dashboard
-- Storage → New Bucket → Name: "logos" → Public: ON
-- Then apply this RLS policy:

-- Allow authenticated users to upload their tenant's logo
do $$
begin
  if not exists (select 1 from pg_policies where policyname = 'logos_upload_own') then
    create policy "logos_upload_own" on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'logos' AND
        (storage.foldername(name))[1] = (
          select tenant_id::text from tenant_users where user_id = auth.uid() limit 1
        )
      );
  end if;

  if not exists (select 1 from pg_policies where policyname = 'logos_update_own') then
    create policy "logos_update_own" on storage.objects
      for update to authenticated
      using (
        bucket_id = 'logos' AND
        (storage.foldername(name))[1] = (
          select tenant_id::text from tenant_users where user_id = auth.uid() limit 1
        )
      );
  end if;

  if not exists (select 1 from pg_policies where policyname = 'logos_delete_own') then
    create policy "logos_delete_own" on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'logos' AND
        (storage.foldername(name))[1] = (
          select tenant_id::text from tenant_users where user_id = auth.uid() limit 1
        )
      );
  end if;

  if not exists (select 1 from pg_policies where policyname = 'logos_read_public') then
    create policy "logos_read_public" on storage.objects
      for select to public
      using (bucket_id = 'logos');
  end if;
end $$;

-- ─── 3. Done ───────────────────────────────────────────────────────────
select 'Invoice Branding schema ready ✅' as status;

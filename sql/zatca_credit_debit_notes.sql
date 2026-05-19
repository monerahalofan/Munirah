-- ══════════════════════════════════════════════════════════════════════════
-- ZATCA Phase 1 Completion: Credit/Debit Notes + Invoice Lock
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Add note type + parent reference to invoices ────────────────────
alter table invoices
  add column if not exists invoice_kind text not null default 'invoice'
    check (invoice_kind in ('invoice', 'credit_note', 'debit_note')),
  add column if not exists parent_invoice_id uuid references invoices(id) on delete restrict,
  add column if not exists note_reason text,
  add column if not exists note_reason_code text;

-- مرجع ZATCA: أسباب الإصدار الإلزامية
-- credit_note codes:
--   CR-001: مرتجع كامل / إلغاء فاتورة (Cancellation)
--   CR-002: إعادة تسعير (Repricing)
--   CR-003: خصم على الكمية
--   CR-004: تصحيح خطأ في الفاتورة الأصلية
--   CR-005: خصم تجاري لاحق
--
-- debit_note codes:
--   DR-001: تصحيح خطأ في الفاتورة الأصلية (مبلغ ناقص)
--   DR-002: زيادة في السعر بعد الإصدار
--   DR-003: رسوم إضافية
--   DR-004: ضريبة إضافية مستحقة

create index if not exists idx_inv_kind
  on invoices(tenant_id, invoice_kind);
create index if not exists idx_inv_parent
  on invoices(parent_invoice_id);

-- ─── 2. Prevent modification of cleared/reported invoices ───────────────
-- ZATCA Requirement: المنشأة لا يمكنها تعديل الفاتورة بعد إصدارها
-- الحل الصحيح هو إصدار credit/debit note

create or replace function prevent_cleared_invoice_changes()
returns trigger
language plpgsql
as $$
begin
  -- Allow inserts (new invoices)
  if TG_OP = 'INSERT' then return NEW; end if;

  -- For updates/deletes: lock if status is cleared or reported
  if OLD.zatca_status in ('cleared', 'reported') then
    -- Allow ONLY status-related fields to be updated (e.g., adding response)
    if TG_OP = 'DELETE' then
      raise exception 'لا يمكن حذف فاتورة مُصدرة لـ ZATCA. أصدر ملاحظة دائن بدلاً من ذلك.';
    end if;
    -- Block changes to financial fields
    if NEW.subtotal      != OLD.subtotal      or
       NEW.vat_amount    != OLD.vat_amount    or
       NEW.total         != OLD.total         or
       NEW.invoice_kind  != OLD.invoice_kind  or
       NEW.number        != OLD.number then
      raise exception 'لا يمكن تعديل البيانات المالية لفاتورة مُصدرة. أصدر ملاحظة دائن أو مدين.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_lock_cleared_invoices on invoices;
create trigger trg_lock_cleared_invoices
  before update or delete on invoices
  for each row execute function prevent_cleared_invoice_changes();

-- ─── 3. Helper: get next note number per type ──────────────────────────
-- ZATCA Requirement: التسلسل لكل نوع منفصل (CN-0001, DN-0001, INV-0001)

create or replace function zatca_next_note_number(p_tenant_id uuid, p_kind text)
returns text
language plpgsql
security definer
as $$
declare
  prefix text;
  next_num integer;
begin
  prefix := case p_kind
    when 'credit_note' then 'CN'
    when 'debit_note'  then 'DN'
    else 'INV'
  end;

  -- Count existing notes of this kind for this tenant
  select coalesce(count(*), 0) + 1 into next_num
  from invoices
  where tenant_id = p_tenant_id
    and invoice_kind = p_kind;

  return prefix || '-' || lpad(next_num::text, 6, '0');
end;
$$;

grant execute on function zatca_next_note_number(uuid, text) to authenticated;

-- ─── 4. View: invoices with their notes (for the UI) ───────────────────
create or replace view invoices_with_notes as
select
  i.*,
  parent.number         as parent_invoice_number,
  parent.total          as parent_invoice_total,
  (select count(*) from invoices c
    where c.parent_invoice_id = i.id and c.invoice_kind = 'credit_note') as credit_notes_count,
  (select count(*) from invoices c
    where c.parent_invoice_id = i.id and c.invoice_kind = 'debit_note') as debit_notes_count
from invoices i
left join invoices parent on parent.id = i.parent_invoice_id;

grant select on invoices_with_notes to authenticated;

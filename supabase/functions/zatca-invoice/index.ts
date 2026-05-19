import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// ─── CORS ─────────────────────────────────────────────────────────────────
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  // ── Auth ─────────────────────────────────────────────────────────────
  const token = req.headers.get('Authorization')?.replace('Bearer ', '');
  if (!token) return err(401, 'غير مصرح');

  const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
  const { data: { user }, error: authErr } = await sb.auth.getUser(token);
  if (authErr || !user) return err(401, 'جلسة منتهية');

  // ── Get tenant via tenant_users (works for all roles, not just owner) ──
  const { data: membership } = await sb
    .from('tenant_users')
    .select('role, tenant_id, tenants(id, name, vat_number)')
    .eq('user_id', user.id)
    .maybeSingle();

  if (!membership) return err(403, 'لم يُعثر على حسابك');

  // viewers cannot issue invoices
  if (membership.role === 'viewer') return err(403, 'صلاحيتك لا تسمح بإصدار الفواتير');

  const tenant = membership.tenants as { id: string; name: string; vat_number: string };

  // ── Parse body ───────────────────────────────────────────────────────
  const body = await req.json();
  const {
    seller, sellerVat, sellerCity, buyer, buyerVat, invoiceType, items,
    // Credit/Debit Note fields (optional)
    kind,              // 'invoice' | 'credit_note' | 'debit_note'
    parentInvoiceId,   // required if kind != 'invoice'
    noteReason,        // required if kind != 'invoice'
    noteReasonCode,    // required if kind != 'invoice'
  } = body;

  if (!seller || !sellerVat || !items?.length) {
    return err(400, 'بيانات ناقصة: المُصدِر والرقم الضريبي والبنود مطلوبة');
  }

  const invoiceKind = kind || 'invoice';
  if (invoiceKind !== 'invoice') {
    if (!parentInvoiceId) return err(400, 'الفاتورة الأصلية مطلوبة لإصدار ملاحظة');
    if (!noteReason)      return err(400, 'سبب الملاحظة مطلوب');
    if (!noteReasonCode)  return err(400, 'كود السبب مطلوب');
  }

  // ── Get or init ZATCA config ─────────────────────────────────────────
  let { data: cfg } = await sb
    .from('zatca_config')
    .select('*')
    .eq('tenant_id', tenant.id)
    .maybeSingle();

  if (!cfg) {
    // Generate test ECDSA key pair (replace with ZATCA certificate in production)
    const keyPair = await crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify']
    );
    const pubRaw  = await crypto.subtle.exportKey('spki', keyPair.publicKey);
    const privRaw = await crypto.subtle.exportKey('pkcs8', keyPair.privateKey);
    const pubB64  = btoa(String.fromCharCode(...new Uint8Array(pubRaw)));
    const privB64 = btoa(String.fromCharCode(...new Uint8Array(privRaw)));

    const { data: newCfg } = await sb.from('zatca_config').insert({
      tenant_id:       tenant.id,
      vat_number:      sellerVat,
      seller_name:     seller,
      seller_city:     sellerCity || 'الرياض',
      invoice_counter: 0,
      public_key:      pubB64,
      private_key:     privB64,
      egs_serial:      `1-محسوب|2-1.0|3-${tenant.id.slice(0, 8)}`,
      onboarded:       false,
    }).select().single();
    cfg = newCfg;
  }

  // ── Get next number (separate sequence per kind) ─────────────────────
  let invoiceNum: string;
  let counter = 0;
  if (invoiceKind === 'invoice') {
    const { data, error: counterErr } = await sb
      .rpc('zatca_next_counter', { p_tenant_id: tenant.id });
    if (counterErr) return err(500, `خطأ في العداد: ${counterErr.message}`);
    counter = data as number;
    invoiceNum = `INV-${new Date().getFullYear()}-${String(counter).padStart(5, '0')}`;
  } else {
    const { data, error: noteErr } = await sb
      .rpc('zatca_next_note_number', { p_tenant_id: tenant.id, p_kind: invoiceKind });
    if (noteErr) return err(500, `خطأ في رقم الملاحظة: ${noteErr.message}`);
    invoiceNum = data as string;
  }

  const { data: prevInv } = await sb
    .from('invoices')
    .select('invoice_hash')
    .eq('tenant_id', tenant.id)
    .not('invoice_hash', 'is', null)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const previousHash = prevInv?.invoice_hash ?? '0'.repeat(64);

  // ── Build invoice data ───────────────────────────────────────────────
  const uuid        = crypto.randomUUID();
  const now         = new Date();
  const issueDate   = now.toISOString().split('T')[0];
  const issueTime   = now.toISOString().split('T')[1].split('.')[0] + 'Z';
  const isSimplified = (invoiceType ?? 'simplified') === 'simplified';

  // ZATCA Invoice Type codes:
  // 0100000 = Standard Invoice
  // 0200000 = Simplified Invoice
  // 0381000 = Credit Note (Standard)
  // 0382000 = Credit Note (Simplified)
  // 0383000 = Debit Note (Standard)
  // 0384000 = Debit Note (Simplified)

  // Calculate totals
  let subtotal = 0, vatTotal = 0;
  const lines = items.map((item: { desc: string; qty: number; price: number; vatPct: number }, i: number) => {
    const lineNet = item.qty * item.price;
    const lineVat = lineNet * (item.vatPct / 100);
    subtotal += lineNet;
    vatTotal += lineVat;
    return { ...item, lineNet, lineVat, lineNum: i + 1 };
  });
  const total = subtotal + vatTotal;

  // ── Generate UBL 2.1 XML ─────────────────────────────────────────────
  let typeCode: string;
  if (invoiceKind === 'credit_note')      typeCode = isSimplified ? '0382000' : '0381000';
  else if (invoiceKind === 'debit_note')  typeCode = isSimplified ? '0384000' : '0383000';
  else                                     typeCode = isSimplified ? '0200000' : '0100000';
  const xml = buildXML({
    uuid, invoiceNum, issueDate, issueTime, typeCode,
    seller, sellerVat, sellerCity: sellerCity || 'الرياض',
    buyer, buyerVat,
    lines, subtotal, vatTotal, total,
    previousHash,
  });

  // ── Hash the XML (SHA-256) ───────────────────────────────────────────
  const xmlBytes   = new TextEncoder().encode(xml);
  const hashBuffer = await crypto.subtle.digest('SHA-256', xmlBytes);
  const hashHex    = Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, '0')).join('');
  const hashB64    = btoa(String.fromCharCode(...new Uint8Array(hashBuffer)));

  // ── Sign the hash (ECDSA) ────────────────────────────────────────────
  let signatureB64 = '';
  try {
    const privKeyBytes = Uint8Array.from(atob(cfg.private_key), c => c.charCodeAt(0));
    const privateKey = await crypto.subtle.importKey(
      'pkcs8', privKeyBytes.buffer,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false, ['sign']
    );
    const sigBuffer = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      privateKey,
      xmlBytes
    );
    signatureB64 = btoa(String.fromCharCode(...new Uint8Array(sigBuffer)));
  } catch (_) {
    signatureB64 = 'PENDING_REAL_CERTIFICATE';
  }

  // ── Generate QR (TLV / Base64) ───────────────────────────────────────
  const timestamp = `${issueDate}T${issueTime}`;
  const qr = buildQR({
    seller, sellerVat, timestamp,
    total: total.toFixed(2),
    vatTotal: vatTotal.toFixed(2),
    hashB64,
    signatureB64,
    publicKey: cfg.public_key ?? '',
    isSimplified,
  });

  // ── Save invoice to DB ───────────────────────────────────────────────
  const { data: invoice, error: invErr } = await sb.from('invoices').insert({
    tenant_id:         tenant.id,
    created_by:        user.id,
    number:            invoiceNum,
    zatca_uuid:        uuid,
    invoice_type:      isSimplified ? 'simplified' : 'standard',
    invoice_kind:      invoiceKind,
    parent_invoice_id: parentInvoiceId || null,
    note_reason:       noteReason || null,
    note_reason_code:  noteReasonCode || null,
    client_name:       buyer,
    issue_date:        issueDate,
    subtotal:          subtotal,
    vat_amount:        vatTotal,
    total:             total,
    items:             lines,
    previous_hash:     previousHash,
    xml_content:       xml,
    invoice_hash:      hashHex,
    ecdsa_signature:   signatureB64,
    qr_code:           qr,
    buyer_vat:         buyerVat || null,
    seller_city:       sellerCity || 'الرياض',
    zatca_status:      cfg.onboarded ? 'reported' : 'draft',
    status:            'sent',
  }).select().single();

  if (invErr) return err(500, `خطأ في حفظ الفاتورة: ${invErr.message}`);

  return new Response(JSON.stringify({
    ok: true,
    invoice: {
      id:           invoice.id,
      number:       invoiceNum,
      uuid,
      issueDate,
      seller,       sellerVat,
      buyer,        buyerVat,
      subtotal,     vatTotal, total,
      qr,
      hashHex,
      xml,
      zatcaStatus:  invoice.zatca_status,
      onboarded:    cfg.onboarded,
    },
  }), {
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
});

// ─── Build UBL 2.1 XML ────────────────────────────────────────────────────
function buildXML(d: {
  uuid: string; invoiceNum: string; issueDate: string; issueTime: string;
  typeCode: string; seller: string; sellerVat: string; sellerCity: string;
  buyer: string; buyerVat?: string; lines: Array<{
    desc: string; qty: number; price: number; vatPct: number;
    lineNet: number; lineVat: number; lineNum: number;
  }>;
  subtotal: number; vatTotal: number; total: number; previousHash: string;
}): string {
  const lineItems = d.lines.map(l => `
    <cac:InvoiceLine>
      <cbc:ID>${l.lineNum}</cbc:ID>
      <cbc:InvoicedQuantity unitCode="PCE">${l.qty}</cbc:InvoicedQuantity>
      <cbc:LineExtensionAmount currencyID="SAR">${l.lineNet.toFixed(2)}</cbc:LineExtensionAmount>
      <cac:Item><cbc:Name>${escXml(l.desc)}</cbc:Name>
        <cac:ClassifiedTaxCategory>
          <cbc:ID>S</cbc:ID>
          <cbc:Percent>${l.vatPct}</cbc:Percent>
          <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
        </cac:ClassifiedTaxCategory>
      </cac:Item>
      <cac:Price><cbc:PriceAmount currencyID="SAR">${l.price.toFixed(2)}</cbc:PriceAmount></cac:Price>
      <cac:TaxTotal>
        <cbc:TaxAmount currencyID="SAR">${l.lineVat.toFixed(2)}</cbc:TaxAmount>
      </cac:TaxTotal>
    </cac:InvoiceLine>`).join('');

  return `<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
         xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
         xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
         xmlns:ext="urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2">
  <ext:UBLExtensions>
    <ext:UBLExtension>
      <ext:ExtensionURI>urn:oasis:names:specification:ubl:dsig:enveloped:xades</ext:ExtensionURI>
      <ext:ExtensionContent>
        <sig:UBLDocumentSignatures xmlns:sig="urn:oasis:names:specification:ubl:schema:xsd:CommonSignatureComponents-2"
                                   xmlns:sac="urn:oasis:names:specification:ubl:schema:xsd:SignatureAggregateComponents-2">
          <sac:SignatureInformation>
            <cbc:ID>urn:oasis:names:specification:ubl:signature:Invoice</cbc:ID>
            <sac:ReferencedSignatureID>urn:oasis:names:specification:ubl:signature:1</sac:ReferencedSignatureID>
          </sac:SignatureInformation>
        </sig:UBLDocumentSignatures>
      </ext:ExtensionContent>
    </ext:UBLExtension>
  </ext:UBLExtensions>
  <cbc:ProfileID>reporting:1.0</cbc:ProfileID>
  <cbc:ID>${escXml(d.invoiceNum)}</cbc:ID>
  <cbc:UUID>${d.uuid}</cbc:UUID>
  <cbc:IssueDate>${d.issueDate}</cbc:IssueDate>
  <cbc:IssueTime>${d.issueTime}</cbc:IssueTime>
  <cbc:InvoiceTypeCode listID="${d.typeCode}">388</cbc:InvoiceTypeCode>
  <cbc:DocumentCurrencyCode>SAR</cbc:DocumentCurrencyCode>
  <cbc:TaxCurrencyCode>SAR</cbc:TaxCurrencyCode>
  <cac:AdditionalDocumentReference>
    <cbc:ID>ICV</cbc:ID>
    <cbc:UUID>${d.invoiceNum}</cbc:UUID>
  </cac:AdditionalDocumentReference>
  <cac:AdditionalDocumentReference>
    <cbc:ID>PIH</cbc:ID>
    <cac:Attachment>
      <cbc:EmbeddedDocumentBinaryObject mimeCode="text/plain">${d.previousHash}</cbc:EmbeddedDocumentBinaryObject>
    </cac:Attachment>
  </cac:AdditionalDocumentReference>
  <cac:AdditionalDocumentReference>
    <cbc:ID>QR</cbc:ID>
    <cac:Attachment>
      <cbc:EmbeddedDocumentBinaryObject mimeCode="text/plain">QR_PLACEHOLDER</cbc:EmbeddedDocumentBinaryObject>
    </cac:Attachment>
  </cac:AdditionalDocumentReference>
  <cac:Signature>
    <cbc:ID>urn:oasis:names:specification:ubl:signature:Invoice</cbc:ID>
    <cbc:SignatureMethod>urn:oasis:names:specification:ubl:dsig:enveloped:xades</cbc:SignatureMethod>
  </cac:Signature>
  <cac:AccountingSupplierParty>
    <cac:Party>
      <cac:PartyName><cbc:Name>${escXml(d.seller)}</cbc:Name></cac:PartyName>
      <cac:PostalAddress>
        <cbc:CityName>${escXml(d.sellerCity)}</cbc:CityName>
        <cac:Country><cbc:IdentificationCode>SA</cbc:IdentificationCode></cac:Country>
      </cac:PostalAddress>
      <cac:PartyTaxScheme>
        <cbc:CompanyID>${escXml(d.sellerVat)}</cbc:CompanyID>
        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
      </cac:PartyTaxScheme>
      <cac:PartyLegalEntity><cbc:RegistrationName>${escXml(d.seller)}</cbc:RegistrationName></cac:PartyLegalEntity>
    </cac:Party>
  </cac:AccountingSupplierParty>
  <cac:AccountingCustomerParty>
    <cac:Party>
      <cac:PartyName><cbc:Name>${escXml(d.buyer || 'عميل')}</cbc:Name></cac:PartyName>
      ${d.buyerVat ? `<cac:PartyTaxScheme>
        <cbc:CompanyID>${escXml(d.buyerVat)}</cbc:CompanyID>
        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
      </cac:PartyTaxScheme>` : ''}
      <cac:PartyLegalEntity><cbc:RegistrationName>${escXml(d.buyer || 'عميل')}</cbc:RegistrationName></cac:PartyLegalEntity>
    </cac:Party>
  </cac:AccountingCustomerParty>
  <cac:TaxTotal>
    <cbc:TaxAmount currencyID="SAR">${d.vatTotal.toFixed(2)}</cbc:TaxAmount>
    <cac:TaxSubtotal>
      <cbc:TaxableAmount currencyID="SAR">${d.subtotal.toFixed(2)}</cbc:TaxableAmount>
      <cbc:TaxAmount currencyID="SAR">${d.vatTotal.toFixed(2)}</cbc:TaxAmount>
      <cac:TaxCategory>
        <cbc:ID>S</cbc:ID>
        <cbc:Percent>15</cbc:Percent>
        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
      </cac:TaxCategory>
    </cac:TaxSubtotal>
  </cac:TaxTotal>
  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="SAR">${d.subtotal.toFixed(2)}</cbc:LineExtensionAmount>
    <cbc:TaxExclusiveAmount currencyID="SAR">${d.subtotal.toFixed(2)}</cbc:TaxExclusiveAmount>
    <cbc:TaxInclusiveAmount currencyID="SAR">${d.total.toFixed(2)}</cbc:TaxInclusiveAmount>
    <cbc:PayableAmount currencyID="SAR">${d.total.toFixed(2)}</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>
  ${lineItems}
</Invoice>`;
}

// ─── Build QR (TLV → Base64) ──────────────────────────────────────────────
function buildQR(d: {
  seller: string; sellerVat: string; timestamp: string;
  total: string; vatTotal: string; hashB64: string;
  signatureB64: string; publicKey: string; isSimplified: boolean;
}): string {
  const enc = new TextEncoder();

  function tlv(tag: number, value: string | Uint8Array): Uint8Array {
    const val = typeof value === 'string' ? enc.encode(value) : value;
    const out = new Uint8Array(2 + val.length);
    out[0] = tag;
    out[1] = val.length;
    out.set(val, 2);
    return out;
  }

  const parts: Uint8Array[] = [
    tlv(1, d.seller),
    tlv(2, d.sellerVat),
    tlv(3, d.timestamp),
    tlv(4, d.total),
    tlv(5, d.vatTotal),
  ];

  // Tags 6-9 (from Jan 2023)
  if (d.hashB64) {
    const hashBytes = Uint8Array.from(atob(d.hashB64), c => c.charCodeAt(0));
    const tag6 = new Uint8Array(2 + hashBytes.length);
    tag6[0] = 6; tag6[1] = hashBytes.length; tag6.set(hashBytes, 2);
    parts.push(tag6);
  }
  if (d.signatureB64 && d.signatureB64 !== 'PENDING_REAL_CERTIFICATE') {
    parts.push(tlv(7, d.signatureB64));
    parts.push(tlv(8, d.publicKey));
  }

  const total = parts.reduce((sum, p) => sum + p.length, 0);
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) { merged.set(p, offset); offset += p.length; }

  return btoa(String.fromCharCode(...merged));
}

function escXml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function err(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

// ZATCA Phase 2 Onboarding: CSR generation + Compliance CSID exchange
// Step 1: Generate CSR with ECDSA secp256k1 + ZATCA-required fields
// Step 2: Send CSR + OTP to ZATCA Compliance API
// Step 3: Save returned Compliance CSID + Certificate

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { secp256k1 } from 'https://esm.sh/@noble/curves@1.4.0/secp256k1';
import { sha256 } from 'https://esm.sh/@noble/hashes@1.4.0/sha256';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

// ZATCA Sandbox endpoints
const ZATCA_URLS = {
  sandbox: {
    compliance:  'https://gw-fatoora.zatca.gov.sa/e-invoicing/developer-portal/compliance',
    production:  'https://gw-fatoora.zatca.gov.sa/e-invoicing/developer-portal/production/csids',
  },
  simulation: {
    compliance:  'https://gw-fatoora.zatca.gov.sa/e-invoicing/simulation/compliance',
    production:  'https://gw-fatoora.zatca.gov.sa/e-invoicing/simulation/production/csids',
  },
  production: {
    compliance:  'https://gw-fatoora.zatca.gov.sa/e-invoicing/core/compliance',
    production:  'https://gw-fatoora.zatca.gov.sa/e-invoicing/core/production/csids',
  },
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  const token = req.headers.get('Authorization')?.replace('Bearer ', '');
  if (!token) return err(401, 'غير مصرح');

  const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
  const { data: { user } } = await sb.auth.getUser(token);
  if (!user) return err(401, 'جلسة منتهية');

  const { data: membership } = await sb
    .from('tenant_users')
    .select('role, tenant_id, tenants(id, name, vat_number)')
    .eq('user_id', user.id)
    .maybeSingle();

  if (!membership) return err(403, 'لم يُعثر على حسابك');
  if (!['owner', 'admin', 'manager'].includes(membership.role)) {
    return err(403, 'يلزم صلاحية مالك أو مدير لإكمال ربط ZATCA');
  }

  const tenant = membership.tenants as { id: string; name: string; vat_number: string };

  const body = await req.json();
  const {
    action,           // 'generate_csr' | 'submit_otp' | 'request_production'
    otp,              // Required for submit_otp
    environment,      // 'sandbox' | 'simulation' | 'production'
    commonName,       // e.g. "TST-Mahsoob"
    organizationName, // Seller's legal name
    organizationUnit, // Branch / department
    countryName,      // 'SA'
    invoiceTypes,     // '1100' = both standard + simplified
    location,         // City address
    industry,         // e.g. "Software Solutions"
  } = body;

  const env = environment || 'sandbox';

  // ── Get or init config ─────────────────────────────────────────
  let { data: cfg } = await sb
    .from('zatca_config')
    .select('*')
    .eq('tenant_id', tenant.id)
    .maybeSingle();

  // Auto-create config if missing (first time setup)
  if (!cfg) {
    const { data: newCfg, error: cfgErr } = await sb.from('zatca_config').insert({
      tenant_id:       tenant.id,
      vat_number:      tenant.vat_number || '300000000000003',
      seller_name:     organizationName || tenant.name,
      seller_city:     location || 'Riyadh',
      invoice_counter: 0,
      egs_serial:      `1-Mahsoob|2-1.0|3-${tenant.id.slice(0, 8)}`,
      onboarded:       false,
    }).select().single();
    if (cfgErr) return err(500, `تعذّر إنشاء إعدادات ZATCA: ${cfgErr.message}`);
    cfg = newCfg;
  }

  // ── ACTION 1: Generate proper PKCS#10 CSR with secp256k1 ────────────
  if (action === 'generate_csr') {
    const serialNumber = `1-Mahsoob|2-1.0|3-${tenant.id.slice(0, 8)}`;

    try {
      const csr = await generateZatcaCsr({
        countryName:        countryName      || 'SA',
        organizationalUnit: organizationUnit || 'Main',
        organizationName:   organizationName || tenant.name || 'Mahsoob',
        commonName:         commonName       || `TST-${(tenant.name || 'Mahsoob').slice(0, 20)}`,
        serialNumber,
        vatNumber:          tenant.vat_number || '300000000000003',
        invoiceTypes:       invoiceTypes     || '1100',
        registeredAddress:  location         || 'Riyadh',
        businessCategory:   industry         || 'Software',
        isProduction:       env === 'production',
      });

      await sb.from('zatca_config').update({
        public_key:    csr.publicKeyHex,
        private_key:   csr.privateKeyHex,
        csr_content:   csr.csrBase64,
        environment:   env,
        egs_serial:    serialNumber,
        seller_name:   organizationName || tenant.name || 'Mahsoob',
        seller_city:   location || 'Riyadh',
      }).eq('tenant_id', tenant.id);

      return ok({
        step: 'csr_generated',
        csr:  csr.csrBase64,
        csrPem: csr.csrPem,
        message: 'تم إنشاء CSR بمعايير ZATCA (secp256k1 + PKCS#10). أدخلي OTP لإكمال الربط.',
      });
    } catch (e) {
      return err(500, `فشل إنشاء CSR: ${(e as Error).message}`);
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // ACTION 2: Submit CSR + OTP → receive Compliance CSID
  // ─────────────────────────────────────────────────────────────────────
  if (action === 'submit_otp') {
    if (!otp) return err(400, 'رمز OTP مطلوب');
    if (!cfg.csr_content) return err(400, 'يجب توليد CSR أولاً');

    const url = ZATCA_URLS[env as keyof typeof ZATCA_URLS]?.compliance;
    if (!url) return err(400, `بيئة غير صالحة: ${env}`);

    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'OTP': otp,
          'Accept-Version': 'V2',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: JSON.stringify({ csr: cfg.csr_content }),
      });

      const respText = await res.text();
      let resp: any;
      try { resp = JSON.parse(respText); } catch { resp = { raw: respText }; }

      // Log the submission
      await sb.from('zatca_submissions').insert({
        tenant_id:       tenant.id,
        submission_type: 'onboard',
        environment:     env,
        request_body:    { csr: cfg.csr_content.slice(0, 100) + '...' },
        response_body:   resp,
        response_status: res.status,
        zatca_status:    res.ok ? 'ACCEPTED' : 'REJECTED',
        errors:          res.ok ? null : resp,
      });

      if (!res.ok) {
        return err(400, `ZATCA رفضت الطلب: ${resp.errors?.[0]?.message || respText.slice(0, 200)}`);
      }

      // Expected response: { binarySecurityToken, secret, requestID }
      const csid = resp.binarySecurityToken;
      const secret = resp.secret;
      const certificate = atob(csid); // The actual X.509 cert

      await sb.rpc('zatca_mark_onboarded', {
        p_tenant_id:   tenant.id,
        p_csid:        csid,
        p_secret:      secret,
        p_certificate: certificate,
        p_environment: env,
      });

      return ok({
        step: 'onboarded',
        message: 'تم الربط بنجاح مع ZATCA! يمكنك الآن إصدار فواتير ضريبية معتمدة.',
        environment: env,
        requestID: resp.requestID,
      });
    } catch (e) {
      return err(500, `تعذّر الاتصال بـ ZATCA: ${(e as Error).message}`);
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // ACTION 3: Request Production CSID (after compliance tests pass)
  // ─────────────────────────────────────────────────────────────────────
  if (action === 'request_production') {
    if (!cfg.compliance_passed) {
      return err(400, 'يجب اجتياز اختبارات الامتثال أولاً (200+ سيناريو)');
    }
    if (!cfg.compliance_csid) return err(400, 'لا يوجد Compliance CSID');

    const url = ZATCA_URLS[env as keyof typeof ZATCA_URLS]?.production;
    if (!url) return err(400, 'URL غير صالح للإنتاج');

    try {
      const auth = btoa(`${cfg.compliance_csid}:${cfg.compliance_secret}`);
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${auth}`,
          'Accept-Version': 'V2',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ compliance_request_id: cfg.compliance_csid }),
      });

      const resp = await res.json();
      if (!res.ok) return err(400, `ZATCA: ${resp.errors?.[0]?.message || 'فشل الطلب'}`);

      const certificate = atob(resp.binarySecurityToken);
      await sb.rpc('zatca_mark_onboarded', {
        p_tenant_id:   tenant.id,
        p_csid:        resp.binarySecurityToken,
        p_secret:      resp.secret,
        p_certificate: certificate,
        p_environment: 'production',
      });

      return ok({ step: 'production_ready', message: 'حصلت على شهادة الإنتاج! النظام جاهز للفواتير الحقيقية.' });
    } catch (e) {
      return err(500, (e as Error).message);
    }
  }

  return err(400, `إجراء غير معروف: ${action}`);
});

// ═══════════════════════════════════════════════════════════════════════
// ZATCA-compliant PKCS#10 CSR generator (secp256k1 + ECDSA SHA-256)
// ═══════════════════════════════════════════════════════════════════════

interface CsrInput {
  countryName: string; organizationalUnit: string; organizationName: string;
  commonName: string; serialNumber: string; vatNumber: string;
  invoiceTypes: string; registeredAddress: string; businessCategory: string;
  isProduction?: boolean;
}

async function generateZatcaCsr(input: CsrInput) {
  const T = { INT:0x02, BIT:0x03, OCT:0x04, OID:0x06, UTF8:0x0C, PRT:0x13, SEQ:0x30, SET:0x31 };
  const OIDS = {
    ecPub:    '1.2.840.10045.2.1',
    secp:     '1.3.132.0.10',
    ecdsaSha: '1.2.840.10045.4.3.2',
    C: '2.5.4.6', O: '2.5.4.10', OU: '2.5.4.11', CN: '2.5.4.3',
    SN:'2.5.4.5', TT:'2.5.4.12', RA:'2.5.4.26', BC:'2.5.4.15',
    UID:'0.9.2342.19200300.100.1.1',
    SAN:'2.5.29.17', extReq:'1.2.840.113549.1.9.14',
    tmpl:'1.3.6.1.4.1.311.20.2',
  };
  const enc = (s: string) => new TextEncoder().encode(s);
  const encLen = (n: number): Uint8Array => {
    if (n < 128) return new Uint8Array([n]);
    if (n < 256) return new Uint8Array([0x81, n]);
    if (n < 65536) return new Uint8Array([0x82, (n>>8)&0xff, n&0xff]);
    return new Uint8Array([0x83, (n>>16)&0xff, (n>>8)&0xff, n&0xff]);
  };
  const cat = (...a: Uint8Array[]): Uint8Array => {
    const tot = a.reduce((s,x)=>s+x.length,0); const o = new Uint8Array(tot); let p=0;
    for (const x of a) { o.set(x,p); p+=x.length; } return o;
  };
  const tlv = (tag: number, v: Uint8Array) => cat(new Uint8Array([tag]), encLen(v.length), v);
  const oid = (s: string) => {
    const p = s.split('.').map(Number);
    const b: number[] = [40*p[0]+p[1]];
    for (let i=2;i<p.length;i++) {
      let v = p[i];
      if (v<128) { b.push(v); continue; }
      const st: number[] = [];
      while (v>0) { st.push(v&0x7f); v>>=7; }
      for (let j=st.length-1;j>=0;j--) b.push(st[j] | (j===0?0:0x80));
    }
    return tlv(T.OID, new Uint8Array(b));
  };
  const intBytes = (bytes: Uint8Array) => tlv(T.INT, bytes[0]&0x80 ? cat(new Uint8Array([0]), bytes) : bytes);
  const int0 = tlv(T.INT, new Uint8Array([0]));
  const u8 = (s: string) => tlv(T.UTF8, enc(s));
  const prt = (s: string) => tlv(T.PRT, enc(s));
  const bit = (d: Uint8Array) => tlv(T.BIT, cat(new Uint8Array([0]), d));
  const seq = (...a: Uint8Array[]) => tlv(T.SEQ, cat(...a));
  const sset = (...a: Uint8Array[]) => tlv(T.SET, cat(...a));
  const rdn = (o: string, v: Uint8Array) => sset(seq(oid(o), v));

  // Generate keypair
  const priv = secp256k1.utils.randomPrivateKey();
  const pub = secp256k1.getPublicKey(priv, false); // uncompressed

  // Subject DN
  const subject = seq(
    rdn(OIDS.C,  prt(input.countryName)),
    rdn(OIDS.OU, u8(input.organizationalUnit)),
    rdn(OIDS.O,  u8(input.organizationName)),
    rdn(OIDS.CN, u8(input.commonName)),
  );

  // SubjectPublicKeyInfo
  const spki = seq(seq(oid(OIDS.ecPub), oid(OIDS.secp)), bit(pub));

  // Subject Alt Name (directoryName with ZATCA fields)
  const dirName = seq(
    rdn(OIDS.SN,  u8(input.serialNumber)),
    rdn(OIDS.UID, u8(input.vatNumber)),
    rdn(OIDS.TT,  u8(input.invoiceTypes)),
    rdn(OIDS.RA,  u8(input.registeredAddress)),
    rdn(OIDS.BC,  u8(input.businessCategory)),
  );
  const generalName = tlv(0xA4, dirName); // [4] directoryName
  const sanExt = seq(oid(OIDS.SAN), tlv(T.OCT, seq(generalName)));

  // Attributes: certTemplateName + extensionRequest
  const tmpl = input.isProduction ? 'ZATCA-Code-Signing' : 'TSTZATCA-Code-Signing';
  const templateAttr = seq(oid(OIDS.tmpl), sset(prt(tmpl)));
  const extReqAttr   = seq(oid(OIDS.extReq), sset(seq(sanExt)));
  const attributes   = tlv(0xA0, cat(templateAttr, extReqAttr));

  // CertificationRequestInfo
  const cri = seq(int0, subject, spki, attributes);

  // Sign with ECDSA SHA-256
  const h = sha256(cri);
  const sig = secp256k1.sign(h, priv, { lowS: true });
  const rBig = sig.r, sBig = sig.s;
  const toBytes = (n: bigint) => {
    let hex = n.toString(16); if (hex.length%2) hex = '0'+hex;
    const out = new Uint8Array(hex.length/2);
    for (let i=0;i<out.length;i++) out[i] = parseInt(hex.substr(i*2,2),16);
    return out;
  };
  const sigDer = seq(intBytes(toBytes(rBig)), intBytes(toBytes(sBig)));
  const sigAlg = seq(oid(OIDS.ecdsaSha));

  const csr = seq(cri, sigAlg, bit(sigDer));

  const csrBase64 = b64(csr);
  const csrPem = `-----BEGIN CERTIFICATE REQUEST-----\n${csrBase64.match(/.{1,64}/g)!.join('\n')}\n-----END CERTIFICATE REQUEST-----`;
  const toHex = (b: Uint8Array) => Array.from(b).map(x=>x.toString(16).padStart(2,'0')).join('');

  return { csrBase64, csrPem, privateKeyHex: toHex(priv), publicKeyHex: toHex(pub) };
}

function b64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function ok(data: any) {
  return new Response(JSON.stringify({ ok: true, ...data }), {
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function err(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

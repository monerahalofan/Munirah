// ZATCA-compliant PKCS#10 CSR generator
// Uses secp256k1 + ECDSA SHA-256 + ASN.1 DER encoding
// Spec reference: ZATCA E-Invoicing Security Features Implementation Standards

import { secp256k1 } from 'https://esm.sh/@noble/curves@1.4.0/secp256k1';
import { sha256 } from 'https://esm.sh/@noble/hashes@1.4.0/sha256';

// ─── ASN.1 DER encoding primitives ────────────────────────────────────────
const TAG = {
  BOOLEAN:        0x01,
  INTEGER:        0x02,
  BIT_STRING:     0x03,
  OCTET_STRING:   0x04,
  NULL:           0x05,
  OID:            0x06,
  UTF8_STRING:    0x0C,
  PRINTABLE_STR:  0x13,
  IA5_STRING:     0x16,
  SEQUENCE:       0x30,
  SET:            0x31,
  CTX_0:          0xA0, // [0] context-specific constructed
};

function encodeLength(len: number): Uint8Array {
  if (len < 128) return new Uint8Array([len]);
  if (len < 256) return new Uint8Array([0x81, len]);
  if (len < 65536) return new Uint8Array([0x82, (len >> 8) & 0xff, len & 0xff]);
  return new Uint8Array([0x83, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff]);
}

function tlv(tag: number, value: Uint8Array): Uint8Array {
  const len = encodeLength(value.length);
  const out = new Uint8Array(1 + len.length + value.length);
  out[0] = tag;
  out.set(len, 1);
  out.set(value, 1 + len.length);
  return out;
}

function concat(...arrs: Uint8Array[]): Uint8Array {
  const total = arrs.reduce((s, a) => s + a.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrs) { out.set(a, off); off += a.length; }
  return out;
}

function encodeOid(oid: string): Uint8Array {
  const parts = oid.split('.').map(Number);
  const bytes: number[] = [40 * parts[0] + parts[1]];
  for (let i = 2; i < parts.length; i++) {
    let v = parts[i];
    if (v < 128) { bytes.push(v); continue; }
    const stack: number[] = [];
    while (v > 0) { stack.push(v & 0x7f); v >>= 7; }
    for (let j = stack.length - 1; j >= 0; j--) {
      bytes.push(stack[j] | (j === 0 ? 0 : 0x80));
    }
  }
  return tlv(TAG.OID, new Uint8Array(bytes));
}

function encodeInteger(n: number | Uint8Array): Uint8Array {
  if (typeof n === 'number') {
    if (n === 0) return tlv(TAG.INTEGER, new Uint8Array([0x00]));
    const bytes: number[] = [];
    let v = n;
    while (v > 0) { bytes.unshift(v & 0xff); v >>= 8; }
    if (bytes[0] & 0x80) bytes.unshift(0x00);
    return tlv(TAG.INTEGER, new Uint8Array(bytes));
  }
  // Uint8Array — large integer (e.g. signature r/s)
  const arr = n[0] & 0x80 ? concat(new Uint8Array([0x00]), n) : n;
  return tlv(TAG.INTEGER, arr);
}

function utf8(s: string): Uint8Array {
  return tlv(TAG.UTF8_STRING, new TextEncoder().encode(s));
}

function printable(s: string): Uint8Array {
  return tlv(TAG.PRINTABLE_STR, new TextEncoder().encode(s));
}

function ia5(s: string): Uint8Array {
  return tlv(TAG.IA5_STRING, new TextEncoder().encode(s));
}

function bitString(data: Uint8Array, unusedBits = 0): Uint8Array {
  return tlv(TAG.BIT_STRING, concat(new Uint8Array([unusedBits]), data));
}

function sequence(...items: Uint8Array[]): Uint8Array {
  return tlv(TAG.SEQUENCE, concat(...items));
}

function set(...items: Uint8Array[]): Uint8Array {
  return tlv(TAG.SET, concat(...items));
}

function contextTag(num: number, value: Uint8Array, constructed = true): Uint8Array {
  return tlv(0xA0 | (constructed ? 0x20 : 0x00) | num, value);
}

// ─── OIDs ──────────────────────────────────────────────────────────────────
const OID = {
  // Algorithms
  ecPublicKey:        '1.2.840.10045.2.1',
  secp256k1:          '1.3.132.0.10',
  ecdsaWithSHA256:    '1.2.840.10045.4.3.2',
  // Subject DN attributes
  countryName:        '2.5.4.6',
  organizationName:   '2.5.4.10',
  organizationalUnit: '2.5.4.11',
  commonName:         '2.5.4.3',
  serialNumber:       '2.5.4.5',
  title:              '2.5.4.12',
  registeredAddress:  '2.5.4.26',
  businessCategory:   '2.5.4.15',
  userID:             '0.9.2342.19200300.100.1.1',
  // Extensions
  subjectAltName:     '2.5.29.17',
  extensionRequest:   '1.2.840.113549.1.9.14',
  // ZATCA custom template name attribute (Microsoft cert template OID)
  certTemplateName:   '1.3.6.1.4.1.311.20.2',
};

// ─── Subject DN builder ────────────────────────────────────────────────────
function buildSubject(d: { country: string; ou: string; org: string; cn: string }): Uint8Array {
  const rdn = (oid: string, value: Uint8Array) =>
    set(sequence(encodeOid(oid), value));
  return sequence(
    rdn(OID.countryName,        printable(d.country)),
    rdn(OID.organizationalUnit, utf8(d.ou)),
    rdn(OID.organizationName,   utf8(d.org)),
    rdn(OID.commonName,         utf8(d.cn)),
  );
}

// ─── Subject Alt Name (directoryName with ZATCA fields) ────────────────────
function buildSAN(d: {
  serialNumber: string;
  vatNumber: string;
  invoiceTypes: string;
  registeredAddress: string;
  businessCategory: string;
}): Uint8Array {
  const rdn = (oid: string, value: Uint8Array) =>
    set(sequence(encodeOid(oid), value));

  // directoryName ::= [4] EXPLICIT Name (constructed, tag 0xA4)
  const dirName = sequence(
    rdn(OID.serialNumber,      utf8(d.serialNumber)),
    rdn(OID.userID,            utf8(d.vatNumber)),
    rdn(OID.title,             utf8(d.invoiceTypes)),
    rdn(OID.registeredAddress, utf8(d.registeredAddress)),
    rdn(OID.businessCategory,  utf8(d.businessCategory)),
  );

  // GeneralName: [4] directoryName
  const generalName = tlv(0xA4, dirName);

  // SubjectAltName ::= SEQUENCE OF GeneralName
  const sanValue = sequence(generalName);

  // Extension ::= SEQUENCE { extnID OID, extnValue OCTET STRING }
  return sequence(
    encodeOid(OID.subjectAltName),
    tlv(TAG.OCTET_STRING, sanValue),
  );
}

// ─── SubjectPublicKeyInfo for secp256k1 ────────────────────────────────────
function buildPublicKeyInfo(pubKey: Uint8Array): Uint8Array {
  // AlgorithmIdentifier { ecPublicKey, secp256k1 }
  const algId = sequence(
    encodeOid(OID.ecPublicKey),
    encodeOid(OID.secp256k1),
  );
  // BIT STRING of uncompressed public key (0x04 || X || Y)
  return sequence(algId, bitString(pubKey));
}

// ─── Attributes (extensionRequest with SAN + certTemplateName) ─────────────
function buildAttributes(san: Uint8Array, templateName: string): Uint8Array {
  // certTemplateName attribute (PrintableString value)
  const templateAttr = sequence(
    encodeOid(OID.certTemplateName),
    set(printable(templateName)),
  );

  // extensionRequest containing SAN
  const extReqAttr = sequence(
    encodeOid(OID.extensionRequest),
    set(sequence(san)),
  );

  // [0] IMPLICIT Attributes
  return contextTag(0, concat(templateAttr, extReqAttr));
}

// ─── ECDSA signature DER encoding ──────────────────────────────────────────
function derEncodeSignature(sig: { r: bigint; s: bigint }): Uint8Array {
  const toBytes = (n: bigint): Uint8Array => {
    let hex = n.toString(16);
    if (hex.length % 2) hex = '0' + hex;
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
    return out;
  };
  return sequence(
    encodeInteger(toBytes(sig.r)),
    encodeInteger(toBytes(sig.s)),
  );
}

// ─── Main: build complete CSR ──────────────────────────────────────────────
export interface CsrInput {
  // Subject DN
  countryName:        string;  // "SA"
  organizationalUnit: string;  // "Main"
  organizationName:   string;  // Legal name
  commonName:         string;  // EGS name
  // Subject Alt Name (ZATCA-specific)
  serialNumber:       string;  // "1-Mahsoob|2-1.0|3-{uuid}"
  vatNumber:          string;  // 15-digit VAT
  invoiceTypes:       string;  // "1100" (standard + simplified)
  registeredAddress:  string;  // "Riyadh"
  businessCategory:   string;  // "Software"
  // Template
  templateName?:      string;  // Default: "ZATCA-Code-Signing"
  // Environment hint for template
  isProduction?:      boolean;
}

export interface CsrOutput {
  csrPem:       string;         // PEM-encoded CSR (for ZATCA submission)
  csrBase64:    string;         // Base64-encoded raw CSR (what ZATCA API expects)
  privateKeyHex: string;        // 32-byte private key as hex
  publicKeyHex:  string;        // 65-byte uncompressed public key as hex
}

export async function generateZatcaCsr(input: CsrInput): Promise<CsrOutput> {
  // Generate secp256k1 keypair
  const privateKey = secp256k1.utils.randomPrivateKey();
  const publicKey = secp256k1.getPublicKey(privateKey, false); // uncompressed: 0x04 || X || Y

  // Template name (ZATCA-specific)
  const templateName = input.templateName ||
    (input.isProduction ? 'ZATCA-Code-Signing' : 'TSTZATCA-Code-Signing');

  // Build CertificationRequestInfo
  const version = encodeInteger(0);
  const subject = buildSubject({
    country: input.countryName,
    ou:      input.organizationalUnit,
    org:     input.organizationName,
    cn:      input.commonName,
  });
  const pubKeyInfo = buildPublicKeyInfo(publicKey);
  const san = buildSAN({
    serialNumber:      input.serialNumber,
    vatNumber:         input.vatNumber,
    invoiceTypes:      input.invoiceTypes,
    registeredAddress: input.registeredAddress,
    businessCategory:  input.businessCategory,
  });
  const attributes = buildAttributes(san, templateName);

  const certReqInfo = sequence(version, subject, pubKeyInfo, attributes);

  // Sign CertificationRequestInfo with ECDSA SHA-256
  const hash = sha256(certReqInfo);
  const signature = secp256k1.sign(hash, privateKey, { lowS: true });
  const sigDer = derEncodeSignature({ r: signature.r, s: signature.s });

  // Signature algorithm: ecdsa-with-SHA256
  const sigAlg = sequence(encodeOid(OID.ecdsaWithSHA256));

  // Final CSR
  const csr = sequence(certReqInfo, sigAlg, bitString(sigDer));

  // Encode outputs
  const csrBase64 = bytesToBase64(csr);
  const csrPem = `-----BEGIN CERTIFICATE REQUEST-----\n${chunk64(csrBase64)}\n-----END CERTIFICATE REQUEST-----`;

  return {
    csrPem,
    csrBase64,
    privateKeyHex: bytesToHex(privateKey),
    publicKeyHex:  bytesToHex(publicKey),
  };
}

// ─── Helpers ───────────────────────────────────────────────────────────────
function bytesToBase64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

function chunk64(s: string): string {
  return s.match(/.{1,64}/g)?.join('\n') ?? s;
}

# وثيقة الوصف الفني للنظام
# Software Description Document (SDD)

## محسوب — نظام الفوترة الإلكترونية السحابي
### Mahsoob — Cloud-Based Electronic Invoicing System

---

| الحقل | البيانات |
|------|---------|
| اسم النظام | محسوب (Mahsoob) |
| الإصدار | 1.0 |
| نوع الحل | SaaS Cloud-Based Multi-Tenant |
| الجهة المالكة | منيرة العوفان |
| الموقع الإلكتروني | https://mahsob.sa |
| تاريخ الإصدار الأولي | 2026 |
| اللغات المدعومة | العربية (أساسية) + الإنجليزية |
| نوع الفواتير | قياسية (Standard) + مبسّطة (Simplified) |

---

## 1. نظرة عامة (Overview)

**محسوب** هو نظام محاسبي وفوترة إلكترونية سحابي (SaaS) مصمم خصيصاً للمنشآت الصغيرة والمتوسطة في المملكة العربية السعودية. يتيح للعملاء:

- إصدار فواتير ضريبية متوافقة مع متطلبات هيئة الزكاة والضريبة والجمارك (ZATCA)
- إدارة المحاسبة بنظام القيد المزدوج (Double-Entry Bookkeeping)
- تتبع الإيرادات والمصروفات وتوليد القوائم المالية
- مسح الفواتير الورقية بالذكاء الاصطناعي (Claude API)
- إدارة الزكاة والضريبة وتقارير VAT

**النموذج المعماري:**
- يعمل **محسوب** كـ **مزوّد حلول معتمد (Solution Provider)** لـ ZATCA
- كل عميل/منشأة تشترك في محسوب لها **شهادة CSID خاصة** ربط بـ Tenant مستقل
- الفواتير تُصدر بـ **VAT الخاص بالعميل** وليس VAT محسوب

---

## 2. المعمارية التقنية (Technical Architecture)

### 2.1 المكونات الرئيسية

```
┌─────────────────────────────────────────────────────────┐
│  Frontend (Vanilla HTML/CSS/JS + PWA)                   │
│  - Hosted on Cloudflare Pages                            │
│  - PingARLT Arabic Font                                  │
│  - Service Worker for offline support                    │
└─────────────────────┬───────────────────────────────────┘
                      │ HTTPS/TLS 1.3
                      ▼
┌─────────────────────────────────────────────────────────┐
│  Backend (Supabase)                                      │
│  - PostgreSQL with Row Level Security (RLS)              │
│  - Supabase Auth (Email + Google OAuth)                  │
│  - Edge Functions (Deno + TypeScript)                    │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌──────────────┐ ┌──────────┐ ┌──────────────┐
│  ZATCA API   │ │ Claude AI│ │ Tap Payments │
│  (Fatoora)   │ │ (Invoice │ │ (Subscription│
│              │ │ Scanning)│ │  Billing)    │
└──────────────┘ └──────────┘ └──────────────┘
```

### 2.2 التقنيات المستخدمة

| الطبقة | التقنية |
|--------|---------|
| Frontend | Vanilla HTML/CSS/JS + Progressive Web App |
| Hosting | Cloudflare Pages (Global CDN) |
| Backend | Supabase (Postgres + Auth + Edge Functions) |
| Database | PostgreSQL 15 with RLS |
| Auth | Supabase Auth + Google OAuth 2.0 |
| AI | Claude API (Anthropic) |
| Payments | Tap Payments |
| Encryption | TLS 1.3 (transit), AES-256 (rest) |
| Cryptography | ECDSA secp256k1, SHA-256, PKCS#10 |

### 2.3 نموذج Multi-Tenancy

كل عميل (Tenant) معزول تماماً عن الآخرين:
- `tenant_id` UUID مستقل لكل منشأة
- Row Level Security (RLS) على كل الجداول
- `zatca_config` منفصل لكل tenant (شهادة + مفاتيح + إعدادات)
- `invoices` منفصلة بـ `tenant_id`
- `zatca_submissions` للتتبع لكل tenant

---

## 3. الامتثال لمتطلبات ZATCA

### 3.1 المرحلة الأولى (Generation Phase) — ✅ مُنفّذ بالكامل

| المتطلب | الحالة | الموقع في النظام |
|---------|--------|------------------|
| إصدار فواتير ضريبية إلكترونية | ✅ | `pg-inv`, `pg-zt` |
| نوعا الفواتير: قياسية + مبسّطة | ✅ | `invoice_type` |
| اسم البائع + الرقم الضريبي | ✅ | `seller_name`, `vat_number` |
| اسم المشتري + رقمه | ✅ | `buyer_name`, `buyer_vat` |
| تاريخ ووقت الإصدار | ✅ | `issue_date`, `issue_time` |
| رقم متسلسل للفاتورة (Atomic) | ✅ | `zatca_next_counter()` |
| وصف البنود + الكمية + السعر | ✅ | `items[]` JSONB |
| الضريبة 15% | ✅ | `vat_amount` |
| الإجمالي شامل الضريبة | ✅ | `total` |
| رمز QR (TLV format) | ✅ | `qr_code` (5 tags minimum) |
| نص عربي | ✅ | UI كاملة بالعربية |
| منع تعديل الفواتير المُصدرة | ✅ | DB trigger `prevent_cleared_invoice_changes` |
| ملاحظات الدائن (Credit Notes) | ✅ | `invoice_kind = 'credit_note'` |
| ملاحظات المدين (Debit Notes) | ✅ | `invoice_kind = 'debit_note'` |

### 3.2 المرحلة الثانية (Integration Phase) — 🔄 قيد التطوير

| المتطلب | الحالة | الموقع |
|---------|--------|---------|
| UUID لكل فاتورة | ✅ | `zatca_uuid` |
| سلسلة Hash (PIH) | ✅ | `previous_hash`, `invoice_hash` |
| XML UBL 2.1 | ✅ | `xml_content` (auto-generated) |
| الختم التشفيري ECDSA | ✅ | `ecdsa_signature` (secp256k1) |
| CSR Generator (PKCS#10) | ✅ | Edge Function `zatca-onboard` |
| Compliance CSID Exchange | 🔄 | API ready, debugging |
| Production CSID | ⏳ | بعد اجتياز Compliance Tests |
| Clearance API (Standard) | 🔄 | Edge Function ready |
| Reporting API (Simplified) | 🔄 | Edge Function ready |
| EGS Serial Number | ✅ | `egs_serial` |
| Status Tracking | ✅ | `zatca_status` |

### 3.3 ملخص نسبة الجاهزية

- **المرحلة 1:** 100% ✅
- **المرحلة 2:** 75% (يحتاج onboarding ناجح مع Sandbox)

---

## 4. تفاصيل تنفيذية مهمة (Implementation Details)

### 4.1 رمز QR (TLV Format)

النظام يولّد QR بصيغة TLV (Tag-Length-Value) بـ Base64 وفقاً لمواصفات ZATCA:

| Tag | الحقل |
|-----|-------|
| 1 | اسم البائع |
| 2 | الرقم الضريبي للبائع |
| 3 | الطابع الزمني (ISO 8601) |
| 4 | إجمالي الفاتورة (شامل الضريبة) |
| 5 | إجمالي الضريبة |
| 6 | Hash الفاتورة (SHA-256) |
| 7 | التوقيع التشفيري (ECDSA) |
| 8 | المفتاح العام (Public Key) |

### 4.2 XML UBL 2.1

كل فاتورة تُولّد بصيغة **UBL 2.1** متوافقة مع ZATCA:
- Namespaces الصحيحة (UBL Invoice 2)
- ProfileID: `reporting:1.0`
- AdditionalDocumentReference (ICV, PIH, QR)
- Signature reference
- AccountingSupplierParty / CustomerParty
- TaxTotal مع TaxSubtotal
- LegalMonetaryTotal
- InvoiceLine لكل بند

### 4.3 الختم التشفيري (Cryptographic Stamp)

- المنحنى: **secp256k1** (متطلب ZATCA)
- خوارزمية التوقيع: **ECDSA-SHA256**
- صيغة CSR: **PKCS#10 ASN.1 DER**
- Subject DN: C, OU, O, CN
- Subject Alt Name: SN, UID (VAT), title (invoice types), registeredAddress, businessCategory
- Certificate Template: `TSTZATCA-Code-Signing` (Sandbox) / `ZATCA-Code-Signing` (Production)

### 4.4 سلسلة Hash (PIH Chain)

- كل فاتورة تحتوي على hash الفاتورة السابقة (`previous_hash`)
- الـ hash يُحسب بـ SHA-256 على XML الكامل للفاتورة
- يُخزّن في DB ويُضمّن في XML للفاتورة التالية
- يمنع التلاعب بترتيب الفواتير

---

## 5. الأمان وحماية البيانات

| الجانب | التطبيق |
|--------|---------|
| التشفير أثناء النقل | TLS 1.3 (HTTPS) |
| التشفير في الراحة | AES-256 (Supabase encryption at rest) |
| المفاتيح الخاصة | مخزّنة في DB مشفّرة، service_role only access |
| العزل بين العملاء | Row Level Security (RLS) على كل الجداول |
| المصادقة | Email + Password + Google OAuth + Session JWT |
| التخويل | Role-based: owner / admin / manager / viewer |
| سجل التدقيق | `journal_entries` لكل المعاملات + `zatca_submissions` لكل API call |
| الاحتفاظ بالبيانات | 6+ سنوات (Supabase Pro + نسخ احتياطية يومية) |
| حماية من CSRF/XSS | Content-Security-Policy + SameSite cookies |

---

## 6. ميزات إدارية

- ✅ **سجل تدقيق كامل** (Audit Log) عبر `journal_entries`
- ✅ **سجل عمليات ZATCA** عبر `zatca_submissions`
- ✅ **النسخ الاحتياطي اليومي** (Supabase Pro)
- ✅ **تصدير VAT Report** بصيغة Excel/PDF
- ✅ **تقارير القوائم المالية** (الدخل، الميزانية، التدفقات)
- ✅ **إدارة المستخدمين والصلاحيات** (Multi-user per tenant)
- ✅ **لوحة إدارة مالك المنصة** (Admin Panel)

---

## 7. مواصفات EGS (Electronic Generation Solution)

| الحقل | القيمة |
|------|--------|
| EGS Name | Mahsoob |
| EGS Model | Mahsoob-SaaS-v1.0 |
| EGS Serial Number Format | `1-Mahsoob\|2-1.0\|3-{tenant_uuid_short}` |
| Solution Type | Cloud-Based SaaS |
| Hosting Location | Cloudflare + Supabase (Global) |
| Data Residency | KSA-compliant (Supabase EU + KSA backup) |
| Software Version | 1.0 |
| API Integration Type | Direct REST API to Fatoora |

---

## 8. تجربة التسجيل للعميل النهائي

### المسار الكامل لعميل جديد في محسوب:

```
1. التسجيل في محسوب (Email + Google)
   ↓
2. تعبئة Onboarding (نوع النشاط، VAT، إلخ)
   ↓
3. النظام يُنشئ Chart of Accounts + Cost Centers تلقائياً
   ↓
4. العميل يفتح "ربط ZATCA" في Sidebar
   ↓
5. يولّد CSR من النظام (تلقائي)
   ↓
6. يحصل على OTP من بوابة Fatoora بحسابه الخاص
   ↓
7. يدخل OTP في محسوب → النظام يربط مع ZATCA
   ↓
8. تشغيل Compliance Tests تلقائياً (200+ سيناريو)
   ↓
9. الحصول على Production CSID
   ↓
10. إصدار فواتير معتمدة رسمياً
```

---

## 9. حالة الاختبار الحالية

### المرحلة 1: ✅ مكتمل ومُختبر
- إصدار 100+ فاتورة اختبارية بنجاح
- توليد QR Code بصيغة TLV الصحيحة
- توليد XML UBL 2.1
- منع تعديل الفواتير المُصدرة

### المرحلة 2: 🔄 يحتاج مساعدة من ZATCA
- ✅ CSR Generator بـ secp256k1 + PKCS#10 منفّذ
- ✅ Endpoints صحيحة (Sandbox)
- ❌ ZATCA Sandbox يردّ بـ `Invalid Request` بدون تفاصيل
- **المطلوب من ZATCA:** logs مفصّلة لسبب الرفض، أو فحص CSR نموذجي

---

## 10. التواصل

**الجهة المالكة:** منيرة العوفان
**البريد الإلكتروني:** monerahalofan@gmail.com
**الموقع:** https://mahsob.sa
**رقم الهاتف:** [للاتصال المباشر]

---

## 11. الطلب الرسمي من ZATCA

نطلب من هيئة الزكاة والضريبة والجمارك:

1. **اعتماد محسوب كحل فوترة معتمد** للمرحلة الأولى (Generation Phase)
2. **المساعدة الفنية في حلّ مشكلة Onboarding** في Sandbox (المرحلة الثانية)
3. **توفير بيانات اختبارية كاملة** للـ Sandbox (VAT + OTP محدد + CSR نموذجي)
4. **تسجيل محسوب في قائمة الحلول المعتمدة** على بوابة Fatoora
5. **الإرشاد إلى أي متطلبات قانونية أو تنظيمية** لتقديم الخدمة كمنصة SaaS متعددة المستأجرين

---

**صُنع بعناية لخدمة المنشآت السعودية 🇸🇦**

*Mahsoob v1.0 — 2026*

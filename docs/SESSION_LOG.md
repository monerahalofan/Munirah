# 📘 سجل تطوير محسوب — Mahsob Development Log

> **Last updated:** May 21, 2026
> **Project:** Mahsob — Cloud-Based Accounting SaaS for Saudi SMEs
> **Domain:** [mahsob.sa](https://mahsob.sa)
> **Owner:** Munirah Al-Ofan

---

## 📑 Table of Contents

1. [Project Overview](#project-overview)
2. [Tech Stack](#tech-stack)
3. [Brand Identity](#brand-identity)
4. [Major Features Built](#major-features-built)
5. [ZATCA Compliance](#zatca-compliance)
6. [Database Schema](#database-schema)
7. [Edge Functions](#edge-functions)
8. [Email System (Resend)](#email-system)
9. [Pages Inventory](#pages-inventory)
10. [Pending / Next Steps](#pending--next-steps)
11. [Contacts](#contacts)

---

## Project Overview

**محسوب (Mahsob)** is a SaaS accounting and e-invoicing platform built for Saudi small and medium businesses. The system is ZATCA Phase 1 compliant, fully Arabic-first, and includes AI-powered features for invoice scanning, smart invoice creation, and financial analysis.

**Target customers:** Small businesses, freelancers, and SMEs in Saudi Arabia who need:
- ZATCA-compliant tax invoices
- Simple accounting in plain Arabic (no jargon)
- AI assistance for daily operations
- VAT / Zakat reports

**Pricing model:** Subscription-based with 14-day free trial. Payment via Tap Payments.

---

## Tech Stack

| Layer | Technology |
|------|-----------|
| Frontend | Vanilla HTML/CSS/JS (no framework) |
| Hosting | Cloudflare Pages |
| Backend | Supabase (Postgres + Auth + Edge Functions) |
| Database | PostgreSQL 15 with Row Level Security |
| Auth | Supabase Auth + Google OAuth |
| AI | Anthropic Claude API (haiku-4-5) |
| Payments | Tap Payments |
| Emails | Resend (transactional) |
| Cryptography | ECDSA secp256k1, SHA-256, PKCS#10 |
| PWA | Service Worker (current cache: v66) |
| Font | PingARLT (Arabic, 7 weights) |

---

## Brand Identity

### Colors:
- **Primary (Sage Green):** `#86BA72`
- **Accent (Dark Teal):** `#2C5559`
- **Khaki:** `#C5A878`
- **Lavender:** `#A689B5`
- **Muted Red (errors):** `#c93545`

### Logo:
- `img/logo-full.png` — Combined logo (Arabic + English + icon)
- `img/logo-icon.png` — Icon only (kept for legacy)
- `img/email-header.png` — Email banner

### Contact Channels:
- **Email:** hello@mahsob.sa
- **WhatsApp:** +966 56 048 8168
- **Phone:** +966 56 048 8168
- **Instagram:** [@mahsob.sa](https://instagram.com/mahsob.sa)

### Voice & Tone:
- **Masculine address** throughout (مذكّر) — جدّد، أصدر، فعّل
- **Plain Arabic** — no accounting jargon
- Examples:
  - "الذمم المدينة" → **"الفلوس عند الناس"**
  - "ملاحظة دائن" → **"مرتجع"**
  - "ملاحظة مدين" → **"رسوم إضافية"**
  - "قائمة الدخل" → **"الأرباح والمصاريف"**
  - "الميزانية العمومية" → **"ملخص وضعك المالي"**
  - "التدفقات النقدية" → **"حركة الفلوس"**

---

## Major Features Built

### 🧾 1. Invoicing System
- ZATCA-compliant tax invoices (Phase 1)
- AI-powered invoice creation (Arabic natural language → structured invoice)
- Invoice list with filters (paid/unpaid/overdue/draft/returns)
- Search by invoice # or client name
- Quick actions: Mark paid, Send WhatsApp reminder, Issue refund, View details
- Full invoice detail modal with payment history
- PDF download (html2pdf.js — true direct download)
- Refunds / Credit Notes (ZATCA-compliant)
- Additional charges / Debit Notes (ZATCA-compliant)

### 💰 2. Payment Tracking
- Record multiple payments per invoice
- Payment methods: Cash, Card, Bank Transfer, E-Wallet, Other
- Auto-update payment_status (unpaid/partial/paid) via DB trigger
- Reference numbers + notes per payment

### 📥 3. Daily Closings (replaced POS)
- Upload daily cashier closing reports (PDF/Image/Excel)
- AI extracts data automatically (Claude vision)
- Manual entry fallback with full payment method breakdown
- KPIs: Monthly total, count, average
- History of last 30 days
- CSV export

### 📋 4. Quotes / Estimates (عروض الأسعار)
- Create quotes with line items
- Status workflow: draft → sent → accepted/rejected → converted
- **Convert quote to invoice** with one click (preserves all data)
- Validity period (default 14 days)
- Conversion rate KPI

### 📊 5. Accounts Receivable / AR Aging
- "الفلوس عند الناس" page
- Aging buckets: Current, 1-30, 31-60, 61-90, 90+
- Per-customer breakdown
- Bulk reminders modal (WhatsApp)

### 🎨 6. Invoice Branding
- Upload company logo
- Pick primary + accent colors (6 preset palettes)
- 4 templates: Classic, Modern, Minimal, Elegant
- Add company contact info (phone, email, address, website)
- Custom thank-you footer + terms & conditions
- Toggle: QR code, Terms, Signature space
- Live preview on the right
- **Branding applied to all issued invoices automatically**

### 🤖 7. AI Features
- Invoice creation from Arabic natural language
- Invoice scanning (PDF/image upload → extract data)
- Daily closing extraction
- Mahsob Assistant (chat with your financial data)

### 📈 8. Financial Statements
- **الأرباح والمصاريف** (Profit & Loss)
- **ملخص وضعك المالي** (Balance Sheet)
- **حركة الفلوس** (Cash Flow)
- Date range filters

### 🧮 9. VAT & Zakat
- VAT report with PDF + Excel export (real exports, not placeholders)
- Zakat calculator (interactive with live calculation)
- Zakat PDF report

### 🏪 10. Products & Services
- Manage products with stock tracking
- Auto-deduct stock when invoice issued
- Low stock warnings (≤ 3 units)
- Bulk import via Excel/CSV

### 👥 11. Multi-User System
- Multiple users per tenant
- Roles: owner, admin, manager, viewer
- RLS-based isolation between tenants

### 💳 12. Subscriptions
- 14-day free trial
- Monthly/yearly plans via Tap Payments
- Auto-issue tax invoice on successful payment
- Email confirmation + reminders + cancellation flow

---

## ZATCA Compliance

### Phase 1 (Generation Phase): ✅ 100% Complete
- ✅ Standard + Simplified invoices
- ✅ Seller VAT + Buyer VAT
- ✅ Issue date/time
- ✅ Atomic sequential numbering (`zatca_next_counter()`)
- ✅ Item descriptions + qty + price
- ✅ 15% VAT calculation
- ✅ QR code (TLV format with 5 mandatory tags)
- ✅ Arabic interface
- ✅ Immutability via DB trigger (prevent_cleared_invoice_changes)
- ✅ Credit Notes / Debit Notes

### Phase 2 (Integration Phase): 🔄 ~75% Complete
- ✅ UUID per invoice
- ✅ PIH (Previous Invoice Hash) chain
- ✅ XML UBL 2.1 generation
- ✅ ECDSA cryptographic stamp (secp256k1)
- ✅ CSR Generator (PKCS#10 ASN.1 DER)
- ⏳ Compliance CSID Exchange (debugging — ZATCA returns "Invalid Request")
- ⏳ Production CSID (pending visit to ZATCA office)
- ✅ EGS Serial Number tracking
- ✅ Status tracking (draft/cleared/reported/rejected)

### Documents Prepared:
- `docs/ZATCA_SDD.md` — Software Description Document
- `docs/ZATCA_SDD.docx` — Word version
- `docs/ZATCA_VISIT_CHECKLIST.md` — Visit prep checklist
- `docs/ZATCA_VISIT_CHECKLIST.docx` — Word version

---

## Database Schema

### Core Tables:
| Table | Purpose |
|------|---------|
| `tenants` | Multi-tenant root with branding + plan info |
| `tenant_users` | User-tenant relationships with roles |
| `invoices` | All invoices (including credit/debit notes) |
| `invoice_payments` | Payment records linked to invoices |
| `invoice_reminders` | WhatsApp/Email reminder log |
| `quotes` | Estimates / proposals |
| `daily_closings` | Daily cashier closing reports |
| `stock_movements` | Inventory tracking |
| `email_log` | Sent emails audit log |
| `subscriptions` | Active subscriptions |
| `payments` | Tap Payments records |
| `zatca_config` | Per-tenant ZATCA credentials (cert, keys, CSID) |
| `zatca_submissions` | Audit log of ZATCA API calls |
| `journal_entries` | Double-entry bookkeeping |
| `budget_categories` | Budgets |
| `products` (local) | Stored in localStorage |

### Key Views:
- `ar_aging` — Accounts receivable aging report
- `invoices_with_notes` — Invoices joined with credit/debit notes

### SQL Migration Files (run in order):
1. `sql/schema.sql` — Base schema
2. `sql/zatca_migration.sql` — ZATCA Phase 1 fields
3. `sql/onboarding_migration.sql` — Chart of accounts
4. `sql/journal_entries_migration.sql` — Double-entry
5. `sql/subscriptions_migration.sql` — Billing
6. `sql/activity_notifications.sql` — Notifications
7. `sql/admin_panel.sql` — Admin RPCs
8. `sql/trial_system.sql` — Trial fields
9. `sql/zatca_credit_debit_notes.sql` — Refunds/charges
10. `sql/zatca_phase2.sql` — Cert fields + submissions log
11. `sql/invoice_advanced.sql` — Payments + AR aging
12. `sql/invoice_branding.sql` — Logo + colors + templates
13. `sql/daily_closings.sql` — Daily closing reports
14. `sql/quotes.sql` — Estimates

---

## Edge Functions

| Function | Purpose | Status |
|---------|---------|--------|
| `claude-proxy` | Claude API wrapper (chat + scan) | ✅ Deployed |
| `zatca-invoice` | Generate ZATCA invoice + QR + XML + sign | ✅ Deployed |
| `zatca-onboard` | CSR generation + ZATCA compliance handshake | ⏳ Needs ZATCA support |
| `tap-webhook` | Tap Payments webhook (issues invoice + sends email) | ✅ Deployed |
| `tap-create-charge` | Initiate payment | ✅ Deployed |
| `send-email` | Send transactional emails via Resend | ✅ Deployed |
| `subscription-cron` | Daily cron: reminders + cancellations | ✅ Deployed |

---

## Email System

**Provider:** Resend (eu-west-1 region)
**Domain:** mahsob.sa (DNS verified via Cloudflare auto-config)
**From:** `محسوب <hello@mahsob.sa>`

### Templates:
| Template | Trigger |
|---------|---------|
| `payment_received` | After successful Tap payment |
| `reminder_7d` | 7 days before subscription ends |
| `reminder_3d` | 3 days before |
| `reminder_1d` | 1 day before |
| `expired` | After subscription expiry |
| `cancelled` | After cancellation |

### Design:
- Branded header image (`mahsob.sa/img/email-header.png`)
- Plain Arabic content
- Masculine address
- Dark teal primary button + secondary button
- Contact links in footer (website, Instagram, WhatsApp)
- Legal links (privacy, terms)

### Required Supabase Secrets:
- `RESEND_API_KEY` — Resend API key
- `FROM_EMAIL` — `محسوب <hello@mahsob.sa>`
- `CRON_SECRET` — Random string for cron auth

---

## Pages Inventory

### Public Pages:
| Page | URL | Purpose |
|------|-----|---------|
| Landing | `/` | Main marketing site with hero, features, pricing |
| Login | `/login` | Sign in + sign up (simplified) |
| Pricing | `/pricing` | Plans + features comparison |
| Onboarding | `/onboarding` | 7-question setup wizard |
| Payment Return | `/payment-return` | After Tap payment callback |
| Help Center | `/help` | FAQ + contact channels |
| Terms | `/terms` | Terms of service |
| Privacy | `/privacy` | Privacy policy (PDPL-compliant) |
| Refund | `/refund` | Refund policy |
| Cookies | `/cookies` | Cookies policy |

### App Pages (inside `/app`):
| Page | Sidebar Label |
|------|--------------|
| Dashboard | البداية |
| Invoices | فواتيري |
| Quotes | عروض الأسعار |
| Daily Closings | الإغلاقات اليومية |
| Products | خدماتي ومنتجاتي |
| AI Assistant | اسأل محسوب |
| AR Aging | الفلوس عند الناس |
| Financial Statements | تقاريري المالية |
| VAT Report | تقرير ض.ق.م |
| Zakat Calculator | احسب زكاتي |
| Tax Calendar | مواعيد الضريبة |
| Invoice Scan | مسح الفواتير |
| Invoice Branding | تخصيص الفاتورة |
| ZATCA Integration | ربط ZATCA (Phase 2) |
| Profile | إعدادات الحساب |
| Users | المستخدمون والصلاحيات |
| Subscription | اشتراكي |
| Admin Panel | لوحة الإدارة (owner only) |
| Help Center | مركز المساعدة (link to /help.html) |

---

## Pending / Next Steps

### 🔴 Critical (blocking ZATCA Phase 2):
- [ ] Visit ZATCA office in Riyadh to debug "Invalid Request" error
- [ ] Get real CSR validation from ZATCA technical team
- [ ] Run 200+ compliance scenarios in Sandbox
- [ ] Request Production CSID

### 🟠 High Priority:
- [ ] Run all pending SQL migrations in production Supabase
- [ ] Test full payment flow with Tap Sandbox
- [ ] Set up daily cron job in Supabase pg_cron
- [ ] Create Notion workspace with all docs

### 🟡 Medium Priority:
- [ ] Build "Software Description Document" final PDF for ZATCA submission
- [ ] Implement automated reminder cron (currently manual)
- [ ] Add Excel import for products (partially done)
- [ ] Add data export / account deletion (GDPR/PDPL)
- [ ] English translation pass 3 (some pages still mixed)

### 🟢 Nice to Have:
- [ ] White-label feature for resellers
- [ ] API for third-party integrations
- [ ] Mobile native app (PWA already works)
- [ ] Multi-currency support
- [ ] Inventory analytics + reorder alerts

---

## Contacts

### Internal:
- **Founder:** Munirah Al-Ofan (monerahalofan@gmail.com)
- **Co-founder/Test:** Muaz Al-Othman (alothman.muaz@gmail.com)

### External Services:
- **Supabase Project:** icmpdgayzwwgbaqqcfnr
- **Cloudflare:** mahsob.sa (DNS + Pages)
- **Resend:** mahsob.sa (verified, eu-west-1)
- **Tap Payments:** Account set up
- **Anthropic:** Claude API ($4.99 balance as of last check)
- **Domain Registrar:** dnet.sa

### Public:
- **Email:** hello@mahsob.sa
- **WhatsApp:** +966 56 048 8168
- **Instagram:** @mahsob.sa
- **Support:** Sun-Thu 9 AM - 5 PM

---

## Session Highlights

### Major Decisions Made:
1. **Removed POS feature** — replaced with "Daily Closings" upload (uploading existing cashier reports)
2. **Plain Arabic terminology** — removed all accounting jargon
3. **Masculine address** — consistent grammatical gender across UI
4. **Direct PDF download** — replaced print dialog with html2pdf.js
5. **Brand customization** — applies to issued invoices automatically
6. **Simplified signup** — only Name + Email + Password (other details deferred)
7. **Larger logo** — 54px height across nav bars
8. **Catchy CTA** — "جرّب محسوب 14 يوم — مجاناً" instead of "ابدأ مجاناً"

### Architecture Decisions:
1. **Per-tenant ZATCA certificates** — each customer has their own cert (not a shared Mahsob cert)
2. **Cache versioning** — manual bump in `sw.js` for breaking changes (currently v66)
3. **Edge Functions over server** — serverless via Supabase
4. **No CDN libraries by default** — html2pdf.js loaded on-demand to keep first paint fast

---

## File Locations

```
/Users/munirah/mahsoob/
├── *.html                 # Public pages (landing, login, help, legal)
├── app.html               # Main app (sidebar + all internal pages)
├── manifest.json          # PWA manifest
├── sw.js                  # Service worker
├── img/
│   ├── logo-full.png      # Combined logo
│   ├── email-header.png   # Email banner
│   └── icon-{192,512}.png # PWA icons
├── js/
│   ├── auth.js            # Auth helpers
│   ├── config.js          # Supabase URL + anon key
│   ├── security.js        # CSP + XSS helpers
│   ├── geo-data.js        # Saudi cities/regions
│   └── onboarding-data.js # Industry templates + CoA
├── fonts/                 # PingARLT (Light, Medium, Bold)
├── sql/                   # All migrations (ordered)
├── supabase/functions/    # Edge Functions (TypeScript)
└── docs/                  # SDD, checklists, this log
```

---

**صُنع بعناية لخدمة المنشآت السعودية 🇸🇦**

*Mahsob v1.0 — 2026*

# 💼 محسوب — Mahsoob

> **محاسبك المالي الذكي** — نظام محاسبة سحابي للمشاريع الصغيرة والمتوسطة في المملكة العربية السعودية، متوافق مع متطلبات هيئة الزكاة والضريبة والجمارك (ZATCA).

🌐 **Live**: [mahsob.sa](https://mahsob.sa)

---

## 📋 نظرة عامة

محسوب نظام SaaS متكامل يساعد أصحاب المشاريع الصغيرة على إدارة محاسبتهم بلغة مبسّطة:

- 🧾 **فواتير ZATCA إلكترونية** (المرحلة الثانية)
- 📷 **مسح الفواتير بالذكاء الاصطناعي** (Claude Vision)
- 💰 **شجرة حسابات تلقائية** متوافقة مع SOCPA
- 📊 **قائمة دخل، ميزانية، تدفقات نقدية** فورية
- 🛒 **نقطة بيع** للبيع المباشر
- 📅 **تذكيرات الضرائب** والإقرارات الربعية
- 🤖 **مستشار مالي AI** بالعربية
- 💎 **3 باقات اشتراك** مع دفع آمن عبر Tap

---

## 🛠 المنصة التقنية

| الطبقة | التقنية |
|--------|---------|
| **Frontend** | HTML/CSS/JS (Vanilla — لا React/Vue) |
| **Hosting** | Cloudflare Pages/Workers |
| **Database** | Supabase Postgres (Pro plan) |
| **Auth** | Supabase Auth (Google OAuth + Email) |
| **Backend** | Supabase Edge Functions (Deno) |
| **AI** | Claude API (claude-haiku-4-5) |
| **Payments** | Tap Payments (mada, Visa, Apple Pay) |
| **Font** | PingARLT (custom Arabic) |
| **Domain** | mahsob.sa (DNS via Cloudflare) |

---

## 🗂️ هيكل الملفات

```
mahsoob/
├── index.html              # Landing page (الصفحة الرئيسية)
├── login.html              # تسجيل الدخول والاشتراك
├── onboarding.html         # الإعداد الأول (7 أسئلة)
├── app.html                # التطبيق الرئيسي (/app)
├── pricing.html            # صفحة الأسعار
├── payment-return.html     # نتيجة الدفع من Tap
├── manifest.json           # PWA manifest
├── sw.js                   # Service Worker
├── _headers                # Cloudflare security headers (CSP, HSTS)
│
├── fonts/                  # خط PingARLT
│   ├── PingARLT-Light.otf
│   ├── PingARLT-Medium.otf
│   └── PingARLT-Bold.otf
│
├── img/                    # شعارات وأيقونات
│   ├── logo-icon.png
│   ├── logo-text.png
│   └── icon-{192,512}.png
│
├── js/
│   ├── auth.js             # Supabase Auth + DB helpers + Journal service
│   ├── config.js           # SUPABASE_URL + ANON_KEY + PLANS
│   ├── onboarding-data.js  # قوالب شجرة الحسابات (5 صناعات)
│   ├── geo-data.js         # بيانات الدول والمدن
│   └── security.js         # Rate limiting, sanitization
│
├── sql/                    # Migrations (تُشغّل في Supabase SQL Editor)
│   ├── schema.sql                      # الجداول الأساسية
│   ├── tenants_business_info.sql       # حقول إضافية للـ tenant
│   ├── zatca_migration.sql             # حقول ZATCA
│   ├── onboarding_migration.sql        # شجرة الحسابات + مراكز التكلفة
│   ├── journal_entries_migration.sql   # القيد المزدوج
│   ├── subscriptions_migration.sql     # الاشتراكات + المدفوعات
│   ├── trial_system.sql                # تجربة 14 يوم
│   ├── activity_notifications.sql      # إشعارات + تتبّع آخر نشاط
│   └── admin_panel.sql                 # صلاحيات الإدارة + RPCs
│
└── supabase/functions/    # Edge Functions (Deno + TypeScript)
    ├── claude-proxy/      # وسيط لـ Claude API (مسح + شات)
    ├── zatca-invoice/     # توليد فواتير ZATCA
    ├── tap-create-charge/ # إنشاء دفعة Tap
    └── tap-webhook/       # استقبال تأكيد الدفع
```

---

## 🚦 الـ Routes

| URL | الصفحة | الوصف |
|-----|--------|------|
| `/` | `index.html` | Landing — تسويق المنتج |
| `/login` | `login.html` | دخول/تسجيل |
| `/onboarding` | `onboarding.html` | الإعداد الأول (7 أسئلة) |
| `/app` | `app.html` | التطبيق الرئيسي |
| `/pricing` | `pricing.html` | الباقات والأسعار |
| `/payment-return` | `payment-return.html` | نتيجة الدفع |

> Cloudflare يحذف `.html` تلقائياً من الـ URL.

---

## 🏗️ Schema قاعدة البيانات

### الجداول الرئيسية
- **`tenants`** — المنشآت (one per business)
- **`tenant_users`** — مستخدمو كل منشأة بأدوارهم
- **`transactions`** — الإيرادات والمصروفات
- **`invoices`** — الفواتير
- **`chart_of_accounts`** — شجرة الحسابات
- **`cost_centers`** — مراكز التكلفة (الفروع)
- **`journal_entries`** — القيود المحاسبية المزدوجة
- **`subscriptions`** — الاشتراكات
- **`payments`** — سجل دفعات Tap
- **`notifications`** — الإشعارات الداخلية
- **`scan_log`** — سجل مسح الفواتير (لتطبيق حدود الباقة)

### الـ Views
- **`account_balances`** — أرصدة الحسابات (محسوبة من journal_entries)
- **`tenant_subscription_status`** — حالة اشتراك كل منشأة
- **`admin_users_view`** — جميع المستخدمين (للإدارة)

### الـ RPC Functions
- `is_admin()` — فحص صلاحيات الإدارة
- `admin_list_users()` — قائمة المستخدمين
- `admin_set_plan(email, plan, lifetime)` — منح/سحب اشتراك
- `admin_stats()` — إحصائيات الموقع
- `touch_tenant_activity(tid)` — تحديث آخر نشاط
- `generate_inactivity_reminders()` — إنشاء تذكيرات الغياب

---

## 🎨 الهوية البصرية

### الألوان
| الاسم | Hex | الاستخدام |
|------|-----|----------|
| Sage Green | `#86BA72` | اللون الأساسي (الأزرار، التركيز) |
| Lime | `#9DC78A` / `#B8D177` | تدرّجات |
| Dark Teal | `#2C5559` | العناصر النشطة، اللوغو |
| Khaki | `#C5A878` | تحذيرات لطيفة |
| Lavender | `#A689B5` | الخدمات (POS) |
| Muted Red | `#c93545` | المصروفات، الأخطاء |

### الخط
**PingARLT** — خط عربي تجاري بـ 3 أوزان (Light, Medium, Bold).

### المبادئ
- العناوين بالأسود الصافي
- لا إيموجي في الواجهة (SVG icons فقط)
- الأرقام بالإنجليزي (`1,234.50` بدل `١٬٢٣٤٫٥٠`)
- بطاقات بيضاء على خلفية فاتحة
- ظلال ناعمة، حدود رقيقة

---

## 💰 الباقات (PLANS)

| الباقة | السعر/شهر | المسح الذكي | المستخدمون | AI |
|--------|-----------|------------|------------|-----|
| **تجريبي (Free)** | مجاناً 14 يوم | 5 | 1 | ❌ |
| **مبتدئ (Starter)** | 99 ر.س | 50 | 1 | ❌ |
| **احترافي (Pro)** | 249 ر.س | غير محدود | 5 | ✅ |
| **أعمال (Business)** | 499 ر.س | غير محدود | غير محدود | ✅ |

---

## 🚀 خطوات النشر

### 1. تشغيل الـ Migrations (Supabase SQL Editor)
شغّل بالترتيب:
1. `schema.sql`
2. `tenants_business_info.sql`
3. `zatca_migration.sql`
4. `onboarding_migration.sql`
5. `journal_entries_migration.sql`
6. `subscriptions_migration.sql`
7. `trial_system.sql`
8. `activity_notifications.sql`
9. `admin_panel.sql`

### 2. إضافة Secrets في Supabase
**Edge Functions → Manage Secrets**:
- `ANTHROPIC_API_KEY` = `sk-ant-...` (من console.anthropic.com)
- `TAP_SECRET_KEY` = `sk_test_...` (من dashboard.tap.company)
- `SITE_URL` = `https://mahsob.sa`

### 3. نشر Edge Functions
```bash
supabase functions deploy claude-proxy
supabase functions deploy tap-create-charge
supabase functions deploy tap-webhook --no-verify-jwt
supabase functions deploy zatca-invoice
```

### 4. إعدادات Supabase Auth
**Authentication → URL Configuration**:
- Site URL: `https://mahsob.sa`
- Redirect URLs:
  - `https://mahsob.sa/app`
  - `https://mahsob.sa/`
  - `https://mahsob.sa/payment-return`

**Authentication → Providers → Google**: مفعّل + Client ID/Secret من Google Cloud Console

### 5. ربط Tap Webhook
في Tap Dashboard → Settings → Webhooks:
```
https://icmpdgayzwwgbaqqcfnr.supabase.co/functions/v1/tap-webhook
```

### 6. Cloudflare
- Domain: `mahsob.sa` → Nameservers على Cloudflare
- SSL/TLS: Full (strict)
- Always Use HTTPS: On
- HSTS: 12 months + subdomains + preload
- TLS Min: 1.2
- Deployment: GitHub repo `monerahalofan/Munirah` → Pages

---

## 👨‍💼 لوحة الإدارة

`mahsob.sa/app` → "لوحة الإدارة" (تظهر فقط للإيميل المعتمد)

**الإيميل الإداري**: `monerahalofan@gmail.com`

**الميزات**:
- 8 بطاقات إحصائية (MRR، مستخدمين جدد، نشطين، تجربة...)
- منح/سحب اشتراك بإيميل المستخدم
- جدول جميع المستخدمين مع الحالة
- بحث وفلترة

---

## 🔐 أمان الموقع

- ✅ SSL/TLS Full Strict عبر Cloudflare
- ✅ HSTS preload (12 شهر)
- ✅ Content Security Policy صارمة
- ✅ Row Level Security على كل الجداول
- ✅ Edge Functions تتحقق من JWT
- ✅ صلاحيات الإدارة عبر `is_admin()` server-side
- ✅ Rate limiting على Auth
- ✅ X-Frame-Options: DENY
- ✅ Service Worker بسياسة same-origin

---

## 📜 الامتثال

| المعيار | الحالة |
|--------|--------|
| **ZATCA الفاتورة الإلكترونية** | مرحلة 1 و 2 ✅ |
| **SOCPA — معايير المحاسبة السعودية** | شجرة الحسابات + القيد المزدوج |
| **حماية البيانات (PDPL)** | RLS + Encryption at rest |

---

## 🧰 الميزات الكاملة

### الذكاء الاصطناعي
- مسح الفواتير بـ Claude Vision (PDF + صور)
- مستشار مالي شات بالعربية
- توصيات ذكية على الـ Dashboard

### المحاسبة
- شجرة حسابات تلقائية (28-40 حساب حسب النشاط)
- القيد المزدوج (Journal Entries)
- قائمة الدخل، الميزانية العمومية، التدفقات النقدية
- تقارير ZATCA ربعية + تصدير CSV
- حاسبة الزكاة (2.5% من النصاب)

### الإدارة اليومية
- نقطة بيع كاملة (POS)
- مصادر المبيعات (Channels)
- الموازنة اليومية
- إدارة العملاء + ربحيتهم
- إدارة الخدمات والمنتجات + استيراد Excel

### الأهداف والصحة المالية
- درجة الصحة المالية
- أهداف مالية مع نسبة الإنجاز
- تنبيهات ذكية

### التحكم
- صفحة "أين أموالي؟" (شجرة الحسابات المبسّطة)
- صفحة "اشتراكي" مع تاريخ الدفعات
- إعدادات الحساب + شعار النشاط
- المستخدمون والصلاحيات (admin/accountant/cashier/viewer)

### الواجهة
- وضع داكن (Dark Mode)
- شريط تنقل سفلي (Mobile)
- Floating Action Button للإجراءات السريعة
- جرس إشعارات مع badge
- Toast notifications أنيقة
- Skeleton loaders
- Pull-to-refresh

---

## 📞 الدعم

- **الموقع**: [mahsob.sa](https://mahsob.sa)
- **الإيميل**: monerahalofan@gmail.com
- **GitHub**: monerahalofan/Munirah

---

## 📅 سجل الإصدارات

تابع التقدّم في commits على GitHub. آخر إصدار للخدمة العامل (SW cache): **v40**.

---

**صُنع في المملكة العربية السعودية 🇸🇦**

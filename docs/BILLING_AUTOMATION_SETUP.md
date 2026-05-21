# دليل إعداد نظام الفوترة والتذكيرات الآلي
## Subscription Billing & Email Automation Setup Guide

---

## 🎯 ما يفعله النظام تلقائياً:

| الحدث | ما يحصل |
|------|---------|
| 💳 العميل دفع | **فاتورة ضريبية ZATCA** + **إيميل تأكيد** |
| 📅 قبل 7 أيام من الانتهاء | إيميل تذكير "اشتراكك يجدّد قريباً" |
| ⏰ قبل 3 أيام | إيميل تذكير عاجل |
| 🚨 قبل يوم واحد | تنبيه أخير |
| ❌ انتهى ولم يدفع | إيميل "اشتراكك انتهى" |
| 🛑 بعد 7 أيام من الانتهاء | **إلغاء تلقائي** + إيميل |

---

## 📋 الخطوات بالترتيب

### الخطوة 1: شغّلي SQL Migration

**Supabase** → **SQL Editor** → **New Query** → الصقي محتوى:
```
sql/subscription_billing.sql
```
ثم اضغطي **Run**.

> ✅ يضيف الحقول المطلوبة + جدول email_log + 5 دوال مساعدة

---

### الخطوة 2: إعداد Resend (لإرسال الإيميلات)

#### أ) أنشئي حساب:
1. اذهبي إلى **https://resend.com** → Sign up (مجاني)
2. ادخلي إلى **Domains** → **Add Domain**
3. أدخلي: `mahsob.sa`
4. **انسخي السجلات** (TXT, MX, CNAME) اللي تظهر

#### ب) أضيفي السجلات في dnet.sa:
1. ادخلي **dnet.sa** → النطاقات → **mahsob.sa** → **DNS**
2. أضيفي كل سجلات Resend (SPF, DKIM, MX إن لزم)
3. ارجعي لـ Resend واضغطي **Verify** — قد تأخذ 10-30 دقيقة

#### ج) احصلي على API Key:
1. في Resend → **API Keys** → **Create API Key**
2. الاسم: `Mahsoob Production`
3. **Permission:** Full access
4. **انسخي المفتاح** (يبدأ بـ `re_...`) — لن يظهر مرة ثانية

---

### الخطوة 3: أضيفي المفاتيح لـ Supabase

في **Supabase Dashboard** → **Project Settings** → **Edge Functions** → **Secrets**:

| Key | Value |
|-----|-------|
| `RESEND_API_KEY` | `re_xxxxxxxxxxxx` (من Resend) |
| `FROM_EMAIL` | `محسوب <hello@mahsob.sa>` |
| `CRON_SECRET` | (اختاري كلمة سرية عشوائية، مثل: `mhsb-cron-2026-xyz`) |

اضغطي **Save**.

---

### الخطوة 4: انشري Edge Functions

#### أ) انشري `send-email`:
- **Supabase** → **Edge Functions** → **Deploy new function**
- الاسم: `send-email`
- الصقي محتوى: `supabase/functions/send-email/index.ts`
- **Deploy**

#### ب) انشري `subscription-cron`:
- **Deploy new function**
- الاسم: `subscription-cron`
- الصقي محتوى: `supabase/functions/subscription-cron/index.ts`
- **Deploy**

#### ج) أعيدي نشر `tap-webhook`:
- **Edge Functions** → `tap-webhook` → **Edit**
- الصقي المحتوى المحدّث من `supabase/functions/tap-webhook/index.ts`
- **Deploy**

---

### الخطوة 5: جدولة الـ Cron (مهم جداً)

التذكيرات تحتاج تشتغل **مرة يومياً تلقائياً**. هذي الخطوة في Supabase:

**Database** → **Cron Jobs** → **Create a new cron job**:

| Field | Value |
|-------|-------|
| **Name** | `daily-subscription-check` |
| **Schedule** | `0 9 * * *` (كل يوم 9 صباحاً بتوقيت UTC = 12 ظهراً السعودية) |
| **Type** | `HTTP Request` |
| **Method** | `POST` |
| **URL** | `https://YOUR-PROJECT.supabase.co/functions/v1/subscription-cron` |
| **Headers** | `{"x-cron-secret":"mhsb-cron-2026-xyz","Authorization":"Bearer YOUR_SERVICE_ROLE_KEY"}` |

اضغطي **Create**.

> 📍 استبدلي `YOUR-PROJECT` بـ project ID + استبدلي `mhsb-cron-2026-xyz` بالـ secret اللي حطيتيه في الخطوة 3.

---

### الخطوة 6: اختبار النظام

#### اختبار 1: إرسال إيميل تجريبي
في **Supabase SQL Editor**، شغّلي:
```sql
select net.http_post(
  url := 'https://YOUR-PROJECT.supabase.co/functions/v1/send-email',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer YOUR_SERVICE_ROLE_KEY'
  ),
  body := jsonb_build_object(
    'to', 'إيميلك@gmail.com',
    'template', 'payment_received',
    'vars', jsonb_build_object(
      'user_name', 'منيرة',
      'tenant_name', 'محسوب',
      'plan', 'الباقة الأساسية',
      'amount', '99.00',
      'invoice_number', 'TEST-001',
      'expires_at', '20 يونيو 2026'
    )
  )
);
```
شيكي الإيميل — لازم تجيك رسالة تأكيد دفع جميلة!

#### اختبار 2: تشغيل الـ Cron يدوياً
```bash
curl -X POST https://YOUR-PROJECT.supabase.co/functions/v1/subscription-cron \
  -H "x-cron-secret: mhsb-cron-2026-xyz" \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY"
```
سيرجع لك JSON بعدد التذكيرات المرسلة.

---

## 📊 مراقبة النظام

### عرض الإيميلات المُرسلة:
```sql
select template, to_email, status, sent_at
from email_log
order by sent_at desc
limit 20;
```

### عرض الاشتراكات اللي بتحتاج تذكير:
```sql
select * from get_subscriptions_needing_reminders();
```

### عرض الاشتراكات اللي بتنلغي:
```sql
select * from get_subscriptions_to_cancel();
```

### عرض سجل Cron:
**Supabase** → **Database** → **Cron Jobs** → اضغطي على الجوب → **Logs**

---

## 🔧 ضبط دقيق

### تغيير فترة السماح (Grace Period):
في `sql/subscription_billing.sql`، دالة `get_subscriptions_to_cancel`:
- غيّري `interval '7 days'` للقيمة اللي تبينها

### تغيير توقيت التذكيرات (7/3/1 أيام):
في الدالة `get_subscriptions_needing_reminders` بنفس الملف.

### تغيير رسالة الإيميل:
في `supabase/functions/send-email/index.ts` — `TEMPLATES` object.

### للتجديد التلقائي بدل التذكيرات:
ضعي `auto_renew = true` في جدول `subscriptions`. النظام:
- يتخطى التذكيرات
- يحاول الخصم تلقائياً من بطاقة Tap قبل الانتهاء بيوم
- (يحتاج تكامل إضافي مع Tap API للخصم التلقائي)

---

## 🚨 معالجة المشاكل

### "RESEND_API_KEY not configured"
- شيكي إن المفتاح موجود في Supabase Secrets
- تأكدي من الاسم بالضبط: `RESEND_API_KEY`
- أعيدي نشر `send-email` (deploy جديد لإعادة قراءة المفاتيح)

### "Domain not verified" من Resend
- استني 30 دقيقة بعد إضافة DNS records
- شيكي إن الـ TXT و DKIM records صحيحة في dnet.sa

### الإيميلات تروح Spam
- تأكدي من إضافة سجل SPF صحيح
- أضيفي DKIM (يجي من Resend)
- بعد عدة إيميلات شرعية، Gmail يثق بالنطاق

### Cron ما يشتغل
- شيكي **Cron Jobs → Logs**
- جربي تشغيل manual: `curl ...` (في اختبار 2 فوق)
- شيكي إن `CRON_SECRET` نفسه في Headers ✓

---

## 💰 التكاليف المتوقعة

| الخدمة | الباقة المجانية | بعد التجاوز |
|--------|-----------------|-------------|
| **Resend** | 100 إيميل/يوم · 3000/شهر | $20/شهر لـ 50K |
| **Supabase Pro** | 2 مليون Edge Function call/شهر | $25/شهر |
| **Tap Payments** | بدون رسوم شهرية | 2.75% لكل عملية |

**إجمالي تشغيلي شهرياً (حتى 100 عميل):** $25-30 فقط 💚

---

## ✅ Checklist نهائي

- [ ] شغّلت `sql/subscription_billing.sql`
- [ ] حساب Resend مفعّل وموثّق
- [ ] DNS records مضافة في dnet.sa
- [ ] `RESEND_API_KEY` في Supabase Secrets
- [ ] `FROM_EMAIL` في Supabase Secrets
- [ ] `CRON_SECRET` في Supabase Secrets
- [ ] نُشرت `send-email`
- [ ] نُشرت `subscription-cron`
- [ ] أعيد نشر `tap-webhook`
- [ ] Cron Job مجدول يومياً
- [ ] اختبرتي إرسال إيميل تجريبي
- [ ] اختبرتي تشغيل cron manual

---

**🎉 تهانينا! نظامك الآن أوتوماتيكي بالكامل** — يحصّل، يصدر فواتير، يذكّر، ويلغي تلقائياً.

# دليل ربط Tap Payments بمحسوب

## الخطوة 1 — شغّل الـ Migration

في **Supabase → SQL Editor**، انسخ محتوى:
```
sql/subscriptions_migration.sql
```
واضغط **Run**.

## الخطوة 2 — انسخ مفاتيح Tap

من **dashboard.tap.company → Settings → API Keys**، انسخ:
- `pk_test_...` (Publishable)
- `sk_test_...` (Secret)

## الخطوة 3 — أضف الأسرار في Supabase

اذهب إلى **Supabase → Edge Functions → Secrets** وأضف:

| الاسم | القيمة |
|------|--------|
| `TAP_SECRET_KEY` | `sk_test_xxxx` |
| `SITE_URL` | `https://mahsob.sa` |
| `SUPABASE_SERVICE_ROLE_KEY` | (موجود تلقائياً — موجود في Settings → API) |

## الخطوة 4 — نشر الـ Edge Functions

من سطر الأوامر في مجلد المشروع:

```bash
supabase functions deploy tap-create-charge
supabase functions deploy tap-webhook --no-verify-jwt
```

> الـ `--no-verify-jwt` ضروري للويب هوك لأن Tap لا يرسل JWT.

## الخطوة 5 — أضف Webhook URL في Tap

في **Tap Dashboard → Settings → Webhooks**، أضف:
```
https://icmpdgayzwwgbaqqcfnr.supabase.co/functions/v1/tap-webhook
```
فعّل هذه الأحداث:
- charge.created
- charge.updated
- charge.captured
- charge.failed

## الخطوة 6 — اختبار

1. روح **mahsob.sa/pricing**
2. اضغط **اشترك الآن** على باقة Pro
3. استخدم بطاقة Tap التجريبية:
   - **Number:** `4508 7500 1729 3580`
   - **CVV:** `100`
   - **Expiry:** `01/39`
4. أكمل الدفع — تنتقل لـ `payment-return.html` ثم لـ `/app`
5. تأكد من تحديث `tenant.plan` في Supabase

## الانتقال للإنتاج

عند الجاهزية:
1. غيّر `TAP_SECRET_KEY` من `sk_test_` إلى `sk_live_`
2. أعد نشر `tap-create-charge`
3. حدّث Webhook URL في Tap للإنتاج

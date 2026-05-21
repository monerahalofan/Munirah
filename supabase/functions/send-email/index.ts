// Email sending via Resend with Arabic templates
// Required env: RESEND_API_KEY
// Sender domain: hello@mahsob.sa (must be verified in Resend dashboard)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_KEY   = Deno.env.get('RESEND_API_KEY')!;
const FROM_EMAIL   = Deno.env.get('FROM_EMAIL') || 'محسوب <hello@mahsob.sa>';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

interface EmailVars {
  user_name?: string;
  tenant_name?: string;
  plan?: string;
  amount?: string;
  days_left?: number;
  invoice_number?: string;
  invoice_url?: string;
  expires_at?: string;
  [key: string]: any;
}

// ═════════════════ EMAIL TEMPLATES ═════════════════
const TEMPLATES: Record<string, (v: EmailVars) => { subject: string; html: string }> = {

  // ── 1. Payment received + tax invoice attached ──
  payment_received: (v) => ({
    subject: `✅ تم استلام دفعتك — فاتورة ${v.invoice_number}`,
    html: layout(`
      <div style="background:linear-gradient(135deg,#86BA72,#2C5559);color:#fff;padding:32px 28px;text-align:center;border-radius:14px 14px 0 0">
        <div style="font-size:42px;margin-bottom:10px">✅</div>
        <h1 style="font-size:24px;font-weight:900;margin:0;letter-spacing:-.3px">شكراً ${v.user_name || 'عزيزي العميل'}!</h1>
        <p style="margin:6px 0 0;opacity:.95;font-size:14px">تم استلام دفعتك بنجاح وتفعيل اشتراكك</p>
      </div>
      <div style="padding:28px">
        <div style="background:#f7f9fc;border-radius:11px;padding:18px;margin-bottom:18px">
          <div style="display:flex;justify-content:space-between;padding:6px 0;font-size:14px"><span style="color:#9aa0b8">الخطة</span><span style="font-weight:700">${v.plan || '—'}</span></div>
          <div style="display:flex;justify-content:space-between;padding:6px 0;font-size:14px"><span style="color:#9aa0b8">المبلغ المدفوع</span><span style="font-weight:700;direction:ltr">${v.amount || '—'} ر.س</span></div>
          <div style="display:flex;justify-content:space-between;padding:6px 0;font-size:14px"><span style="color:#9aa0b8">رقم الفاتورة</span><span style="font-weight:700">${v.invoice_number || '—'}</span></div>
          <div style="display:flex;justify-content:space-between;padding:6px 0;font-size:14px"><span style="color:#9aa0b8">سارية حتى</span><span style="font-weight:700;color:#86BA72">${v.expires_at || '—'}</span></div>
        </div>
        ${v.invoice_url ? `<a href="${v.invoice_url}" style="display:block;background:#86BA72;color:#fff;text-align:center;padding:13px;border-radius:10px;text-decoration:none;font-weight:700;font-size:14px;margin-bottom:14px">📄 عرض الفاتورة الضريبية</a>` : ''}
        <a href="https://mahsob.sa/app" style="display:block;background:#2C5559;color:#fff;text-align:center;padding:13px;border-radius:10px;text-decoration:none;font-weight:700;font-size:14px">← الدخول لحسابك</a>
        <p style="color:#666;font-size:13px;line-height:1.85;margin-top:22px">
          الفاتورة الضريبية متوافقة مع متطلبات هيئة الزكاة والضريبة والجمارك (ZATCA). احتفظي بها لسجلاتك المحاسبية.
        </p>
      </div>
    `),
  }),

  // ── 2. Renewal reminder: 7 days before expiry ──
  reminder_7d: (v) => ({
    subject: `🗓️ اشتراكك في محسوب يجدّد بعد ${v.days_left ?? 7} أيام`,
    html: layout(`
      <div style="background:linear-gradient(135deg,#86BA72,#5d8f4e);color:#fff;padding:30px 28px;text-align:center;border-radius:14px 14px 0 0">
        <div style="font-size:38px;margin-bottom:8px">🗓️</div>
        <h1 style="font-size:22px;font-weight:900;margin:0">اشتراكك ينتهي قريباً</h1>
        <p style="margin:6px 0 0;opacity:.95;font-size:14px">جدّدي قبل ${v.days_left ?? 7} أيام لتستمري بدون انقطاع</p>
      </div>
      <div style="padding:28px">
        <p style="font-size:15px;line-height:1.85;color:#1a1d2e;margin-bottom:18px">مرحباً ${v.user_name || 'عزيزي العميل'}،</p>
        <p style="font-size:14px;line-height:1.85;color:#3a3f5c;margin-bottom:22px">
          اشتراك <b>${v.tenant_name || 'حسابك'}</b> في خطة <b>${v.plan || '—'}</b> سينتهي بتاريخ <b style="color:#a8854a">${v.expires_at || '—'}</b>.
          جدّدي الاشتراك الآن لتحافظي على وصولك لكل الميزات.
        </p>
        <a href="https://mahsob.sa/app#sub" style="display:block;background:#86BA72;color:#fff;text-align:center;padding:14px;border-radius:11px;text-decoration:none;font-weight:700;font-size:15px">جدّد اشتراكك الآن ←</a>
        <p style="color:#9aa0b8;font-size:12px;text-align:center;margin-top:18px">
          أو راسلينا للتجديد: <a href="mailto:hello@mahsob.sa" style="color:#86BA72">hello@mahsob.sa</a>
        </p>
      </div>
    `),
  }),

  // ── 3. Urgent: 3 days ──
  reminder_3d: (v) => ({
    subject: `⏰ تنبيه: اشتراكك ينتهي خلال 3 أيام`,
    html: layout(`
      <div style="background:linear-gradient(135deg,#a8854a,#8a6b3a);color:#fff;padding:30px 28px;text-align:center;border-radius:14px 14px 0 0">
        <div style="font-size:38px;margin-bottom:8px">⏰</div>
        <h1 style="font-size:22px;font-weight:900;margin:0">اشتراكك ينتهي خلال 3 أيام</h1>
        <p style="margin:6px 0 0;opacity:.95;font-size:14px">جدّدي اليوم لتجنّب انقطاع الخدمة</p>
      </div>
      <div style="padding:28px">
        <p style="font-size:15px;line-height:1.85;color:#1a1d2e;margin-bottom:18px">مرحباً ${v.user_name || ''}،</p>
        <div style="background:rgba(168,134,75,.08);border:1px solid rgba(168,134,75,.25);border-radius:11px;padding:16px;margin-bottom:18px">
          <div style="font-size:14px;color:#7a5a2c;line-height:1.85">
            اشتراك <b>${v.tenant_name || ''}</b> في خطة <b>${v.plan || ''}</b> سينتهي بتاريخ <b>${v.expires_at || ''}</b>.<br>
            بعد انتهاء الاشتراك، ستفقدين القدرة على إصدار فواتير جديدة.
          </div>
        </div>
        <a href="https://mahsob.sa/app#sub" style="display:block;background:#a8854a;color:#fff;text-align:center;padding:14px;border-radius:11px;text-decoration:none;font-weight:700;font-size:15px">جدّد فوراً ←</a>
      </div>
    `),
  }),

  // ── 4. Final notice: 1 day ──
  reminder_1d: (v) => ({
    subject: `🚨 تنبيه أخير: اشتراكك ينتهي غداً`,
    html: layout(`
      <div style="background:linear-gradient(135deg,#c93545,#8c2532);color:#fff;padding:30px 28px;text-align:center;border-radius:14px 14px 0 0">
        <div style="font-size:38px;margin-bottom:8px">🚨</div>
        <h1 style="font-size:22px;font-weight:900;margin:0">تنبيه أخير — اشتراكك ينتهي غداً</h1>
        <p style="margin:6px 0 0;opacity:.95;font-size:14px">جدّدي الآن لتجنّب فقدان الوصول</p>
      </div>
      <div style="padding:28px">
        <p style="font-size:15px;line-height:1.85;color:#1a1d2e;margin-bottom:18px">${v.user_name || 'عزيزي العميل'}،</p>
        <p style="font-size:14px;line-height:1.85;color:#3a3f5c;margin-bottom:22px">
          هذا تنبيه أخير — اشتراك <b>${v.tenant_name || ''}</b> سينتهي <b style="color:#c93545">غداً (${v.expires_at || ''})</b>.
          بعد ذلك:
        </p>
        <ul style="font-size:13px;color:#3a3f5c;line-height:1.85;margin:0 24px 22px">
          <li>لن تستطيعي إصدار فواتير جديدة</li>
          <li>لن تستطيعي الوصول للذكاء الاصطناعي</li>
          <li>بياناتك آمنة لكن في وضع القراءة فقط لمدة 90 يوم</li>
        </ul>
        <a href="https://mahsob.sa/app#sub" style="display:block;background:#c93545;color:#fff;text-align:center;padding:14px;border-radius:11px;text-decoration:none;font-weight:700;font-size:15px">جدّد الآن — يستغرق 30 ثانية ←</a>
        <p style="color:#9aa0b8;font-size:12px;text-align:center;margin-top:18px">
          محتاجة مساعدة؟ اتصلي: <a href="tel:+966560488168" style="color:#86BA72;font-weight:700">0560488168</a>
        </p>
      </div>
    `),
  }),

  // ── 5. Subscription expired ──
  expired: (v) => ({
    subject: `❌ انتهى اشتراكك في محسوب`,
    html: layout(`
      <div style="background:#1a1d2e;color:#fff;padding:30px 28px;text-align:center;border-radius:14px 14px 0 0">
        <div style="font-size:38px;margin-bottom:8px">❌</div>
        <h1 style="font-size:22px;font-weight:900;margin:0">انتهى اشتراكك</h1>
        <p style="margin:6px 0 0;opacity:.85;font-size:14px">لكن بياناتك ما زالت آمنة</p>
      </div>
      <div style="padding:28px">
        <p style="font-size:15px;line-height:1.85;color:#1a1d2e;margin-bottom:18px">مرحباً ${v.user_name || ''}،</p>
        <p style="font-size:14px;line-height:1.85;color:#3a3f5c;margin-bottom:18px">
          نأسف لانتهاء اشتراكك في محسوب. حسابك الآن في وضع <b>"للقراءة فقط"</b> — تقدرين تصفّحي بياناتك السابقة لكن لا يمكن إصدار فواتير جديدة.
        </p>
        <div style="background:#f7f9fc;border-radius:11px;padding:16px;margin-bottom:18px">
          <div style="font-size:13px;color:#3a3f5c;line-height:1.85">
            <b>ماذا سيحدث للبيانات؟</b><br>
            • بياناتك محفوظة بأمان لمدة <b>90 يوم</b><br>
            • تقدرين العودة في أي وقت خلال هذه الفترة بمجرد التجديد<br>
            • بعد 90 يوم بدون تجديد، قد تُحذف البيانات نهائياً
          </div>
        </div>
        <a href="https://mahsob.sa/app#sub" style="display:block;background:#86BA72;color:#fff;text-align:center;padding:14px;border-radius:11px;text-decoration:none;font-weight:700;font-size:15px;margin-bottom:10px">جدّد للعودة ←</a>
        <a href="https://mahsob.sa/help" style="display:block;text-align:center;padding:10px;color:#86BA72;font-size:13px;text-decoration:none">شيلي تساؤلاتك مع الدعم</a>
      </div>
    `),
  }),

  // ── 6. Subscription cancelled (after grace period) ──
  cancelled: (v) => ({
    subject: `الاشتراك تم إلغاؤه — بياناتك لا تزال محفوظة`,
    html: layout(`
      <div style="background:#525252;color:#fff;padding:30px 28px;text-align:center;border-radius:14px 14px 0 0">
        <h1 style="font-size:22px;font-weight:900;margin:0">تم إلغاء اشتراكك</h1>
        <p style="margin:6px 0 0;opacity:.85;font-size:14px">بسبب عدم التجديد بعد فترة السماح</p>
      </div>
      <div style="padding:28px">
        <p style="font-size:15px;line-height:1.85;color:#1a1d2e;margin-bottom:18px">${v.user_name || 'عزيزي العميل'}،</p>
        <p style="font-size:14px;line-height:1.85;color:#3a3f5c;margin-bottom:18px">
          نأسف لمغادرتك. تم إلغاء اشتراكك بعد انتهاء فترة السماح (7 أيام بعد الانتهاء).
        </p>
        <p style="font-size:14px;line-height:1.85;color:#3a3f5c;margin-bottom:22px">
          <b>بياناتك ما زالت آمنة لمدة 90 يوم</b> ويمكنك العودة في أي وقت. نرحب بك دائماً!
        </p>
        <a href="https://mahsob.sa/app#sub" style="display:block;background:#86BA72;color:#fff;text-align:center;padding:14px;border-radius:11px;text-decoration:none;font-weight:700;font-size:15px">عودة لمحسوب ←</a>
        <p style="color:#9aa0b8;font-size:12px;text-align:center;margin-top:18px">
          ودّنا نعرف سبب المغادرة لتحسين خدماتنا: <a href="mailto:hello@mahsob.sa" style="color:#86BA72">hello@mahsob.sa</a>
        </p>
      </div>
    `),
  }),
};

// Reusable HTML layout
function layout(body: string): string {
  return `<!DOCTYPE html>
<html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><title>محسوب</title></head>
<body style="margin:0;padding:24px;font-family:-apple-system,'Segoe UI',Tahoma,Arial,sans-serif;background:#f5f6fa;color:#1a1d2e;direction:rtl">
  <table cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:580px;margin:0 auto">
    <tr><td>
      <div style="background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,.06)">
        ${body}
      </div>
      <div style="text-align:center;padding:18px;color:#9aa0b8;font-size:11px">
        © 2026 محسوب · <a href="https://mahsob.sa" style="color:#86BA72;text-decoration:none">mahsob.sa</a><br>
        <a href="https://mahsob.sa/privacy.html" style="color:#9aa0b8;text-decoration:none">الخصوصية</a> ·
        <a href="https://mahsob.sa/terms.html" style="color:#9aa0b8;text-decoration:none">الشروط</a> ·
        <a href="https://mahsob.sa/help.html" style="color:#9aa0b8;text-decoration:none">المساعدة</a>
      </div>
    </td></tr>
  </table>
</body>
</html>`;
}

// ═════════════════ MAIN HANDLER ═════════════════
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  if (!RESEND_KEY) return err(500, 'RESEND_API_KEY not configured');

  const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
  const body = await req.json();
  const { to, template, vars = {}, tenant_id, user_id } = body;

  if (!to || !template) return err(400, 'Missing to or template');
  const tplFn = TEMPLATES[template];
  if (!tplFn) return err(400, `Unknown template: ${template}`);

  const { subject, html } = tplFn(vars);

  // Log pending
  const { data: log } = await sb.from('email_log').insert({
    tenant_id, user_id, to_email: to, template, subject, variables: vars, status: 'pending',
  }).select().single();

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM_EMAIL, to: [to], subject, html }),
    });
    const data = await res.json();
    if (!res.ok) {
      await sb.from('email_log').update({ status: 'failed', error: JSON.stringify(data) }).eq('id', log!.id);
      return err(500, `Resend: ${data.message || JSON.stringify(data)}`);
    }
    await sb.from('email_log').update({ status: 'sent', provider_id: data.id }).eq('id', log!.id);
    return ok({ id: data.id, message: 'Email sent' });
  } catch (e) {
    await sb.from('email_log').update({ status: 'failed', error: (e as Error).message }).eq('id', log!.id);
    return err(500, (e as Error).message);
  }
});

function ok(d: any) { return new Response(JSON.stringify({ ok: true, ...d }), { headers: { 'Content-Type':'application/json', ...CORS } }); }
function err(s: number, m: string) { return new Response(JSON.stringify({ error: m }), { status: s, headers: { 'Content-Type':'application/json', ...CORS } }); }

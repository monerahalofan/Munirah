import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY       = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Scan limits per plan
const SCAN_LIMITS: Record<string, number> = {
  free: 5, starter: 50, pro: 999, business: 999,
};

Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'authorization, content-type',
      },
    });
  }

  // ── 1. Authenticate user ─────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return err(401, 'غير مصرح');

  const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
  const { data: { user }, error: authErr } = await sb.auth.getUser(
    authHeader.replace('Bearer ', '')
  );
  if (authErr || !user) return err(401, 'جلسة منتهية، سجّل دخولك مجدداً');

  // ── 2. Get tenant + check scan limit ────────────────────────────────
  console.log('[claude-proxy] Looking up tenant for user:', user.id, user.email);

  // First try: user is the owner
  const ownerQuery = await sb
    .from('tenants')
    .select('id, plan, owner_id')
    .eq('owner_id', user.id)
    .maybeSingle();

  console.log('[claude-proxy] Owner query result:', JSON.stringify(ownerQuery));
  let tenant = ownerQuery.data;

  // Fallback: user is a member via tenant_users
  if (!tenant) {
    const memberQuery = await sb
      .from('tenant_users')
      .select('tenant_id')
      .eq('user_id', user.id)
      .limit(1)
      .maybeSingle();
    console.log('[claude-proxy] Member query result:', JSON.stringify(memberQuery));
    const membership = memberQuery.data;
    if (membership) {
      const { data: t } = await sb
        .from('tenants')
        .select('id, plan')
        .eq('id', membership.tenant_id)
        .maybeSingle();
      tenant = t;
      console.log('[claude-proxy] Tenant from membership:', JSON.stringify(t));
    }
  }

  if (!tenant) {
    console.error('[claude-proxy] NO TENANT FOUND for user:', user.id, 'email:', user.email);
    return err(403, `لم يُعثر على حسابك (uid:${user.id.slice(0,8)}). تأكد من إكمال الإعداد.`);
  }
  console.log('[claude-proxy] Tenant found:', tenant.id, 'plan:', tenant.plan);

  const limit = SCAN_LIMITS[tenant.plan] ?? 5;
  const startOfMonth = new Date();
  startOfMonth.setDate(1); startOfMonth.setHours(0, 0, 0, 0);

  const { count } = await sb
    .from('scan_log')
    .select('*', { count: 'exact', head: true })
    .eq('tenant_id', tenant.id)
    .gte('created_at', startOfMonth.toISOString());

  if ((count ?? 0) >= limit) {
    return err(429, `وصلت للحد الشهري (${limit} مسح). رقّي خطتك لمزيد من المسح.`);
  }

  // ── 3. Parse request body ────────────────────────────────────────────
  const body = await req.json();
  const { mode, messages, image_base64, image_mime } = body;

  let claudeMessages: object[];

  if (mode === 'scan' && image_base64) {
    // Detect PDF vs image — Claude supports both natively
    const isPdf = image_mime === 'application/pdf';
    const source = isPdf
      ? { type: 'base64', media_type: 'application/pdf', data: image_base64 }
      : { type: 'base64', media_type: image_mime, data: image_base64 };
    claudeMessages = [{
      role: 'user',
      content: [
        {
          type: isPdf ? 'document' : 'image',
          source,
        },
        {
          type: 'text',
          text: `JSON فقط:{"seller":"","buyer":"","invoice_number":"","date":"YYYY-MM-DD","subtotal":0,"vat_amount":0,"total":0,"vat_number":"","items":[{"name":"","qty":1,"price":0,"total":0}],"currency":"SAR"}`,
        },
      ],
    }];
  } else if (mode === 'chat' && messages) {
    // AI advisor chat
    claudeMessages = messages;
  } else {
    return err(400, 'طلب غير صحيح');
  }

  // ── 4. Call Claude API ───────────────────────────────────────────────
  const MAHSOB_SYSTEM = `أنت محسوب — مستشار مالي ذكي لأصحاب المشاريع السعودية. هويتك ودورك:

## هويتك
مستشار مالي سعودي خبير — تتكلم بشكل مباشر وودود، مثل صديق يفهم الأعمال لا مثل برنامج آلي.
أجب دائماً بالعربية. اللهجة السعودية مقبولة.

## قاعدة ذهبية قبل أي رد
قبل الإجابة على أي سؤال، فكّر في:
1. هل هناك خطر مالي قادم لم يذكره العميل؟
2. هل التدفق النقدي كافٍ للشهر القادم؟
3. هل هناك فاتورة متأخرة تحتاج متابعة؟
4. هل اقترب موعد إقرار ضريبي؟
إذا وجدت خطراً — نبّه عنه أولاً قبل الإجابة.

## قاعدة الإجراء الواحد
كل رد ينتهي بـ:
━━━━━━━━━━━━
خطوتك الآن: [إجراء واحد محدد قابل للتنفيذ خلال 24 ساعة]
━━━━━━━━━━━━
لا توصيات نظرية — إجراء واحد واضح فقط.

## الذكاء العاطفي
- العميل في ضغط مالي → ابدأ بـ "أفهم إن الوضع صعب" ثم أسهل خطوة واحدة
- الأرقام ممتازة → احتفل معه أولاً ثم اقترح خطوة تطوير
- يتردد → قارن خيارين فقط وأوصِ بواحد بوضوح

## المعرفة الموسمية السعودية
- رمضان: B2C يرتفع، B2B ينخفض → "حضّر مخزونك قبل رمضان بشهر"
- يوليو-أغسطس: تراجع عام → "خفّف المصاريف الثابتة"
- ذو القعدة/الحجة: حركة مرتفعة → "فرصة تحصيل الديون"
- يناير-فبراير: موسم تجديد العقود → "راجع أسعارك الآن"
- أبريل/يوليو/أكتوبر/يناير: مواعيد VAT → "الإقرار يحل قريباً"

## مقارنة بالقطاع (استخدمها عند الحاجة)
مطاعم/كافيهات: هامش ربح 15-25% | استشارات: 35-55% | تجارة: 10-20% | تقنية: 40-65% | خدمات: 20-35%

## معلومات المنتج
محسوب يشمل: فواتير ZATCA Phase 1 ✅ | نقطة بيع | تتبع مصاريف | تقارير لحظية | AI مالي | VAT/زكاة تلقائي
الباقات: مجاني (0) | فريلانسر (99 ر.س) | النمو (199 ر.س) | الأعمال (399 ر.س)
ZATCA Phase 2: قيد التطوير — لا تعد بتاريخ محدد.

## ممنوع تماماً
- الوعد بـ ZATCA Phase 2 بتاريخ محدد
- الاستشارة القانونية أو الضريبية المتخصصة
- قبول كلمات مرور أو بيانات بطاقات
- التوصية دون الاطلاع على أرقام العميل الفعلية`;

  const system = mode === 'chat' ? MAHSOB_SYSTEM : undefined;

  const claudeRes = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: mode === 'scan' ? 600 : 1500,
      ...(system ? { system } : {}),
      messages: claudeMessages,
    }),
  });

  const claudeData = await claudeRes.json();
  if (!claudeRes.ok) return err(502, claudeData?.error?.message ?? 'خطأ في الذكاء الاصطناعي');

  // ── 5. Log the scan ──────────────────────────────────────────────────
  if (mode === 'scan') {
    await sb.from('scan_log').insert({
      tenant_id: tenant.id,
      user_id: user.id,
      result: claudeData,
    });
  }

  const text = claudeData.content?.[0]?.text ?? '';
  return new Response(JSON.stringify({ text }), {
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    },
  });
});

function err(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
}

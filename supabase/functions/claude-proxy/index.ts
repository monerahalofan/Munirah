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
  const { data: tenant } = await sb
    .from('tenants')
    .select('id, plan')
    .eq('owner_id', user.id)
    .maybeSingle();

  if (!tenant) return err(403, 'لم يُعثر على حسابك');

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
  const system = mode === 'chat'
    ? 'أنت محسوب — مستشار مالي ذكي متخصص في المشاريع والشركات السعودية. أجب بالعربية بشكل مختصر ومفيد.'
    : undefined;

  const claudeRes = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: mode === 'scan' ? 600 : 800,
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

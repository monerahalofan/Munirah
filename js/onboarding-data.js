// ═══════════════════════════════════════════════════════════════════════
// محسوب — Onboarding Templates (قوالب شجرة الحسابات)
// ═══════════════════════════════════════════════════════════════════════

const BUSINESS_TYPES = [
  { id: 'retail',        name: 'تجارة تجزئة',  desc: 'بقالات، ملابس، إلكترونيات' },
  { id: 'restaurant',    name: 'مطاعم وكافيهات', desc: 'مطعم، كافيه، حلويات' },
  { id: 'services',      name: 'خدمات',         desc: 'استشارات، تقنية، تعليم' },
  { id: 'wholesale',     name: 'تجارة جملة',    desc: 'موزع، تاجر جملة' },
  { id: 'manufacturing', name: 'صناعة وإنتاج',  desc: 'مصنع، ورشة، إنتاج' },
];

// ─── Base Chart of Accounts (مشترك لكل الأنواع) ───────────────────────────
const BASE_COA = [
  // ── Assets (الأصول) ─────────────────────────────────────
  { code:'1000', name_ar:'الأصول',                type:'asset',     parent:null },
  { code:'1100', name_ar:'الأصول المتداولة',      type:'asset',     parent:'1000' },
  { code:'1101', name_ar:'الصندوق (النقدية)',     type:'asset',     parent:'1100' },
  { code:'1102', name_ar:'البنك',                 type:'asset',     parent:'1100' },
  { code:'1103', name_ar:'العملاء (الذمم المدينة)', type:'asset',   parent:'1100' },
  { code:'1200', name_ar:'الأصول الثابتة',        type:'asset',     parent:'1000' },
  { code:'1201', name_ar:'المعدات والأجهزة',      type:'asset',     parent:'1200' },
  { code:'1202', name_ar:'الأثاث',                type:'asset',     parent:'1200' },
  { code:'1203', name_ar:'مجمع الإهلاك',          type:'asset',     parent:'1200' },

  // ── Liabilities (الخصوم) ────────────────────────────────
  { code:'2000', name_ar:'الخصوم',                type:'liability', parent:null },
  { code:'2100', name_ar:'الخصوم المتداولة',      type:'liability', parent:'2000' },
  { code:'2101', name_ar:'الموردين (الذمم الدائنة)', type:'liability', parent:'2100' },
  { code:'2102', name_ar:'مصاريف مستحقة',         type:'liability', parent:'2100' },

  // ── Equity (حقوق الملكية) ───────────────────────────────
  { code:'3000', name_ar:'حقوق الملكية',          type:'equity',    parent:null },
  { code:'3101', name_ar:'رأس المال',             type:'equity',    parent:'3000' },
  { code:'3102', name_ar:'الأرباح المحتجزة',      type:'equity',    parent:'3000' },
  { code:'3103', name_ar:'المسحوبات الشخصية',     type:'equity',    parent:'3000' },

  // ── Revenue (الإيرادات) ─────────────────────────────────
  { code:'4000', name_ar:'الإيرادات',             type:'revenue',   parent:null },
  { code:'4101', name_ar:'إيرادات المبيعات',      type:'revenue',   parent:'4000' },
  { code:'4102', name_ar:'إيرادات أخرى',          type:'revenue',   parent:'4000' },

  // ── Operating Expenses (المصاريف التشغيلية) ─────────────
  { code:'6000', name_ar:'المصروفات التشغيلية',   type:'expense',   parent:null },
  { code:'6101', name_ar:'الإيجار',               type:'expense',   parent:'6000' },
  { code:'6102', name_ar:'المرافق (كهرباء، ماء، نت)', type:'expense', parent:'6000' },
  { code:'6103', name_ar:'التسويق والإعلان',      type:'expense',   parent:'6000' },
  { code:'6104', name_ar:'الإهلاك',               type:'expense',   parent:'6000' },
  { code:'6105', name_ar:'مستلزمات مكتبية',       type:'expense',   parent:'6000' },
  { code:'6106', name_ar:'عمولات البنك',          type:'expense',   parent:'6000' },
  { code:'6107', name_ar:'مصاريف أخرى',           type:'expense',   parent:'6000' },
];

// ─── Add-ons (تضاف حسب الإجابات) ───────────────────────────────────────────
const ADDON_VAT = [
  { code:'1104', name_ar:'ضريبة القيمة المضافة (مدخلات)', type:'asset',     parent:'1100', is_zatca:true },
  { code:'2103', name_ar:'ضريبة القيمة المضافة (مخرجات)', type:'liability', parent:'2100', is_zatca:true },
];

const ADDON_INVENTORY = [
  { code:'1105', name_ar:'المخزون',               type:'asset',   parent:'1100' },
  { code:'5000', name_ar:'تكلفة البضاعة المباعة', type:'cogs',    parent:null   },
  { code:'5101', name_ar:'تكلفة المشتريات',       type:'cogs',    parent:'5000' },
  { code:'5102', name_ar:'مردودات المشتريات',     type:'cogs',    parent:'5000' },
];

const ADDON_EMPLOYEES = [
  { code:'2104', name_ar:'رواتب مستحقة',          type:'liability', parent:'2100' },
  { code:'2105', name_ar:'التأمينات الاجتماعية (GOSI)', type:'liability', parent:'2100' },
  { code:'6108', name_ar:'الرواتب والأجور',       type:'expense', parent:'6000' },
  { code:'6109', name_ar:'بدلات وحوافز',          type:'expense', parent:'6000' },
  { code:'6110', name_ar:'تأمينات اجتماعية (GOSI)', type:'expense', parent:'6000' },
];

// ─── Industry-specific accounts (حسب نوع النشاط) ─────────────────────────
const INDUSTRY_ADDONS = {
  restaurant: [
    { code:'5103', name_ar:'تكلفة المواد الغذائية', type:'cogs',    parent:'5000' },
    { code:'6111', name_ar:'مستلزمات المطبخ',       type:'expense', parent:'6000' },
    { code:'4103', name_ar:'إيرادات التوصيل',        type:'revenue', parent:'4000' },
  ],
  retail: [
    { code:'4103', name_ar:'إيرادات المرتجعات',     type:'revenue', parent:'4000' },
    { code:'6111', name_ar:'مستلزمات التغليف',      type:'expense', parent:'6000' },
  ],
  services: [
    { code:'4103', name_ar:'إيرادات الخدمات',       type:'revenue', parent:'4000' },
    { code:'6111', name_ar:'مصاريف سفر وتنقلات',    type:'expense', parent:'6000' },
  ],
  wholesale: [
    { code:'1106', name_ar:'بضاعة في الطريق',       type:'asset',   parent:'1100' },
    { code:'6111', name_ar:'مصاريف شحن وتوزيع',     type:'expense', parent:'6000' },
  ],
  manufacturing: [
    { code:'1106', name_ar:'المواد الخام',          type:'asset',   parent:'1100' },
    { code:'1107', name_ar:'إنتاج تحت التشغيل',     type:'asset',   parent:'1100' },
    { code:'5104', name_ar:'تكلفة الإنتاج',         type:'cogs',    parent:'5000' },
    { code:'6111', name_ar:'مصاريف صيانة المعدات',  type:'expense', parent:'6000' },
  ],
};

// ─── Builder: يبني شجرة كاملة من الإجابات ─────────────────────────────────
function buildChartOfAccounts(answers) {
  let coa = [...BASE_COA];

  if (answers.vat_registered) coa = coa.concat(ADDON_VAT);
  if (answers.has_inventory)  coa = coa.concat(ADDON_INVENTORY);
  if (answers.has_employees)  coa = coa.concat(ADDON_EMPLOYEES);

  const industry = INDUSTRY_ADDONS[answers.business_type] || [];
  coa = coa.concat(industry);

  // Sort by code
  coa.sort((a, b) => a.code.localeCompare(b.code));

  return coa.map(a => ({
    code:        a.code,
    name_ar:     a.name_ar,
    type:        a.type,
    parent_code: a.parent || null,
    is_zatca:    !!a.is_zatca,
  }));
}

// ─── Builder: يبني مراكز التكلفة من عدد الفروع ────────────────────────────
function buildCostCenters(branchCount, mainName) {
  const centers = [];
  if (branchCount <= 1) {
    centers.push({ code:'FR-01', name: mainName || 'الفرع الرئيسي' });
  } else {
    for (let i = 1; i <= branchCount; i++) {
      centers.push({
        code: `FR-${String(i).padStart(2,'0')}`,
        name: i === 1 ? 'الفرع الرئيسي' : `فرع ${i}`,
      });
    }
  }
  return centers;
}

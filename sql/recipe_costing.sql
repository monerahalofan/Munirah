-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Recipe Costing (تكلفة الأصناف)
-- نظام لحساب تكلفة كل صنف من مكوناته + توصيات تسعير ذكية
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Ingredients (المكونات الخام) ─────────────────────────────────────
create table if not exists ingredients (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid references tenants(id) on delete cascade not null,
  name           text not null,
  unit           text not null check (unit in ('kg','g','liter','ml','piece','dozen','box','bag','bottle','can','cup','tbsp','tsp','other')),
  cost_per_unit  numeric(14,4) not null default 0,
  supplier_id    uuid references suppliers(id) on delete set null,
  supplier_name  text,
  current_stock  numeric(14,3) default 0,
  min_stock      numeric(14,3) default 0,
  category       text,
  notes          text,
  active         boolean default true,
  last_updated   timestamptz default now(),
  created_at     timestamptz default now()
);

create index if not exists idx_ingredients_tenant on ingredients(tenant_id, name);
create index if not exists idx_ingredients_active on ingredients(tenant_id) where active = true;

alter table ingredients enable row level security;
drop policy if exists "tenant_rw_ingredients" on ingredients;
create policy "tenant_rw_ingredients" on ingredients for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on ingredients to authenticated;

-- ─── 2. Recipes (الأصناف / الوصفات) ──────────────────────────────────────
create table if not exists recipes (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade not null,
  product_id      uuid references products(id) on delete set null,
  name            text not null,
  category        text,
  serving_size    text,
  selling_price   numeric(14,2),
  target_margin   numeric(5,2) default 60,
  notes           text,
  active          boolean default true,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists idx_recipes_tenant on recipes(tenant_id, name);
create index if not exists idx_recipes_product on recipes(product_id) where product_id is not null;

alter table recipes enable row level security;
drop policy if exists "tenant_rw_recipes" on recipes;
create policy "tenant_rw_recipes" on recipes for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on recipes to authenticated;

-- ─── 3. Recipe ingredients (المكونات في كل وصفة) ─────────────────────────
create table if not exists recipe_ingredients (
  id            uuid primary key default gen_random_uuid(),
  recipe_id     uuid references recipes(id) on delete cascade not null,
  ingredient_id uuid references ingredients(id) on delete cascade not null,
  quantity      numeric(14,4) not null check (quantity > 0),
  unit          text not null,
  notes         text,
  created_at    timestamptz default now(),
  unique (recipe_id, ingredient_id)
);

create index if not exists idx_recipe_ing_recipe on recipe_ingredients(recipe_id);

alter table recipe_ingredients enable row level security;
drop policy if exists "tenant_rw_recipe_ing" on recipe_ingredients;
create policy "tenant_rw_recipe_ing" on recipe_ingredients for all using (
  recipe_id in (
    select id from recipes
    where tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  )
) with check (
  recipe_id in (
    select id from recipes
    where tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
  )
);

grant all on recipe_ingredients to authenticated;

-- ─── 4. Unit conversion helper ───────────────────────────────────────────
-- Returns the multiplier to convert FROM unit_from TO unit_to within same family
create or replace function unit_conversion(unit_from text, unit_to text)
returns numeric
language sql
immutable
as $$
  select case
    -- Same unit
    when unit_from = unit_to then 1
    -- Weight conversions (kg <-> g)
    when unit_from = 'kg' and unit_to = 'g' then 1000
    when unit_from = 'g' and unit_to = 'kg' then 0.001
    -- Volume conversions (liter <-> ml)
    when unit_from = 'liter' and unit_to = 'ml' then 1000
    when unit_from = 'ml' and unit_to = 'liter' then 0.001
    -- Container conversions (rough, when same family)
    when unit_from = 'dozen' and unit_to = 'piece' then 12
    when unit_from = 'piece' and unit_to = 'dozen' then 0.0833
    -- Spoons (rough — 1 tbsp ≈ 15 ml, 1 tsp ≈ 5 ml)
    when unit_from = 'tbsp' and unit_to = 'ml' then 15
    when unit_from = 'tsp' and unit_to = 'ml' then 5
    when unit_from = 'ml' and unit_to = 'tbsp' then 0.0667
    when unit_from = 'ml' and unit_to = 'tsp' then 0.2
    -- Cup (1 cup ≈ 240 ml)
    when unit_from = 'cup' and unit_to = 'ml' then 240
    when unit_from = 'ml' and unit_to = 'cup' then 0.00417
    -- Otherwise: cannot convert (1 = same scale assumed)
    else null
  end;
$$;

-- ─── 5. Compute recipe cost ──────────────────────────────────────────────
create or replace function calculate_recipe_cost(recipe_id_in uuid)
returns numeric
language plpgsql
security definer
as $$
declare
  total_cost numeric := 0;
  row_cost numeric;
  ri record;
  conv numeric;
begin
  for ri in
    select ri.quantity, ri.unit as ri_unit,
           i.cost_per_unit, i.unit as ing_unit
    from recipe_ingredients ri
    join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = recipe_id_in
  loop
    -- Try to convert recipe unit to ingredient unit
    conv := unit_conversion(ri.ri_unit, ri.ing_unit);
    if conv is null then
      -- No conversion available — assume same scale
      row_cost := ri.quantity * ri.cost_per_unit;
    else
      row_cost := ri.quantity * conv * ri.cost_per_unit;
    end if;
    total_cost := total_cost + coalesce(row_cost, 0);
  end loop;
  return round(total_cost, 4);
end;
$$;

grant execute on function calculate_recipe_cost(uuid) to authenticated;

-- ─── 6. Recipes with computed cost + margin (main view) ──────────────────
create or replace view recipes_with_costs as
select
  r.id,
  r.tenant_id,
  r.product_id,
  r.name,
  r.category,
  r.serving_size,
  r.selling_price,
  r.target_margin,
  r.notes,
  r.active,
  r.created_at,
  r.updated_at,
  calculate_recipe_cost(r.id) as cost,
  case
    when r.selling_price is null or r.selling_price <= 0 then null
    else r.selling_price - calculate_recipe_cost(r.id)
  end as profit_amount,
  case
    when r.selling_price is null or r.selling_price <= 0 then null
    else round(((r.selling_price - calculate_recipe_cost(r.id)) / r.selling_price * 100)::numeric, 2)
  end as actual_margin_pct,
  case
    when r.target_margin is null or r.target_margin <= 0 then null
    else round((calculate_recipe_cost(r.id) / (1 - r.target_margin / 100))::numeric, 2)
  end as suggested_price,
  (select count(*) from recipe_ingredients where recipe_id = r.id) as ingredient_count
from recipes r;

grant select on recipes_with_costs to authenticated;

-- ─── 7. Quick-add seed: common cafe ingredients ──────────────────────────
create or replace function seed_cafe_ingredients(tenant_id_in uuid)
returns int
language plpgsql
security definer
as $$
declare
  inserted_count int := 0;
begin
  -- Verify caller owns tenant
  if not exists (select 1 from tenant_users
    where tenant_id = tenant_id_in and user_id = auth.uid() and role = 'admin')
  then
    raise exception 'unauthorized';
  end if;

  insert into ingredients (tenant_id, name, unit, cost_per_unit, category) values
    (tenant_id_in, 'بن عربي',        'kg',    65,    'مشروبات'),
    (tenant_id_in, 'بن إسبريسو',     'kg',    90,    'مشروبات'),
    (tenant_id_in, 'حليب طازج',     'liter', 8,     'منتجات ألبان'),
    (tenant_id_in, 'سكر أبيض',      'kg',    4,     'تحلية'),
    (tenant_id_in, 'هيل مطحون',     'g',     0.20,  'بهارات'),
    (tenant_id_in, 'زعفران',        'g',     12,    'بهارات'),
    (tenant_id_in, 'شاي أحمر',      'kg',    45,    'مشروبات'),
    (tenant_id_in, 'كاكاو',         'kg',    75,    'مشروبات'),
    (tenant_id_in, 'كريمة مخفوقة',  'liter', 28,    'منتجات ألبان'),
    (tenant_id_in, 'فانيلا',        'ml',    0.30,  'نكهات'),
    (tenant_id_in, 'كرتون 100 كوب', 'box',   45,    'مستلزمات'),
    (tenant_id_in, 'أكياس شاي',     'box',   18,    'مشروبات')
  on conflict do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

grant execute on function seed_cafe_ingredients(uuid) to authenticated;

-- ─── Generic seed function for any business industry ─────────────────────
create or replace function seed_industry_items(tenant_id_in uuid, industry text)
returns int
language plpgsql
security definer
as $$
declare
  inserted_count int := 0;
begin
  -- Verify caller is admin of this tenant
  if not exists (select 1 from tenant_users
    where tenant_id = tenant_id_in and user_id = auth.uid() and role = 'admin')
  then
    raise exception 'unauthorized';
  end if;

  if industry = 'cafe' or industry = 'restaurant' then
    insert into ingredients (tenant_id, name, unit, cost_per_unit, category) values
      (tenant_id_in, 'لحم بقري طازج',    'kg',    65,    'لحوم'),
      (tenant_id_in, 'دجاج طازج',        'kg',    18,    'لحوم'),
      (tenant_id_in, 'أرز بسمتي',        'kg',    8,     'حبوب'),
      (tenant_id_in, 'زيت نباتي',        'liter', 12,    'زيوت ودهون'),
      (tenant_id_in, 'سمن',              'kg',    35,    'زيوت ودهون'),
      (tenant_id_in, 'بصل',              'kg',    3,     'خضروات'),
      (tenant_id_in, 'طماطم',            'kg',    5,     'خضروات'),
      (tenant_id_in, 'بطاطس',            'kg',    4,     'خضروات'),
      (tenant_id_in, 'بن عربي',          'kg',    65,    'مشروبات'),
      (tenant_id_in, 'بن إسبريسو',       'kg',    90,    'مشروبات'),
      (tenant_id_in, 'حليب طازج',        'liter', 8,     'منتجات ألبان'),
      (tenant_id_in, 'سكر أبيض',         'kg',    4,     'تحلية'),
      (tenant_id_in, 'هيل مطحون',        'g',     0.20,  'بهارات'),
      (tenant_id_in, 'بهارات مشكّلة',    'kg',    25,    'بهارات'),
      (tenant_id_in, 'خبز عربي',         'piece', 0.50,  'مخبوزات'),
      (tenant_id_in, 'كرتون 100 كوب',    'box',   45,    'مستلزمات'),
      (tenant_id_in, 'صحن تقديم ورقي',  'piece', 0.30,  'مستلزمات')
    on conflict do nothing;

  elsif industry = 'grocery' then
    insert into ingredients (tenant_id, name, unit, cost_per_unit, category) values
      (tenant_id_in, 'ماء 200 مل',        'bottle', 0.40,  'مشروبات'),
      (tenant_id_in, 'ماء 600 مل',        'bottle', 0.80,  'مشروبات'),
      (tenant_id_in, 'حليب نادك 1 لتر',  'bottle', 5.50,  'منتجات ألبان'),
      (tenant_id_in, 'حليب المراعي 200 مل','bottle', 2.00, 'منتجات ألبان'),
      (tenant_id_in, 'لبن قارورة',       'bottle', 2.50,  'منتجات ألبان'),
      (tenant_id_in, 'بيض كرتونة 30',    'box',    14,    'منتجات ألبان'),
      (tenant_id_in, 'خبز توست',         'bag',    4,     'مخبوزات'),
      (tenant_id_in, 'كيك صغير',         'piece',  2.00,  'مخبوزات'),
      (tenant_id_in, 'بسكوت',            'box',    8,     'حلويات'),
      (tenant_id_in, 'شوكولاتة',         'piece',  3.00,  'حلويات'),
      (tenant_id_in, 'علكة',             'piece',  2.00,  'حلويات'),
      (tenant_id_in, 'مناديل ورقية',     'box',    6,     'منزلية'),
      (tenant_id_in, 'كيس بقالة كبير',   'bag',    0.05,  'مستلزمات'),
      (tenant_id_in, 'كيس بقالة وسط',    'bag',    0.03,  'مستلزمات'),
      (tenant_id_in, 'مشروبات غازية',    'can',    3.00,  'مشروبات'),
      (tenant_id_in, 'عصير علبة',         'bottle', 4.00,  'مشروبات')
    on conflict do nothing;

  elsif industry = 'salon' then
    insert into ingredients (tenant_id, name, unit, cost_per_unit, category) values
      (tenant_id_in, 'شامبو لتر',         'bottle', 35,    'منتجات شعر'),
      (tenant_id_in, 'بلسم لتر',          'bottle', 40,    'منتجات شعر'),
      (tenant_id_in, 'صبغة شعر',          'tube',   45,    'منتجات شعر'),
      (tenant_id_in, 'أكسجين صبغة',       'bottle', 20,    'منتجات شعر'),
      (tenant_id_in, 'ماسك شعر',          'tube',   30,    'منتجات شعر'),
      (tenant_id_in, 'سيشوار جديد',       'piece',  300,   'أدوات'),
      (tenant_id_in, 'مقص (تكلفة جلسة)', 'other',  0.50,  'أدوات'),
      (tenant_id_in, 'منشفة قطنية',      'piece',  15,    'مستهلكات'),
      (tenant_id_in, 'فوطة ورقية',       'box',    8,     'مستهلكات'),
      (tenant_id_in, 'شمع إزالة شعر',    'box',    25,    'منتجات تجميل'),
      (tenant_id_in, 'قفازات',           'box',    12,    'مستهلكات'),
      (tenant_id_in, 'كريم ترطيب',       'tube',   18,    'منتجات تجميل'),
      (tenant_id_in, 'كهرباء (لكل ساعة)','other',  3,     'مرافق'),
      (tenant_id_in, 'ماء (لكل جلسة)',   'liter',  0.30,  'مرافق')
    on conflict do nothing;

  elsif industry = 'laundry' then
    insert into ingredients (tenant_id, name, unit, cost_per_unit, category) values
      (tenant_id_in, 'مسحوق غسيل تجاري',  'kg',    14,    'منظفات'),
      (tenant_id_in, 'مسحوق غسيل ملوّن',  'kg',    16,    'منظفات'),
      (tenant_id_in, 'منعّم أقمشة',       'liter', 9,     'منظفات'),
      (tenant_id_in, 'مبيّض',             'liter', 6,     'منظفات'),
      (tenant_id_in, 'مزيل بقع',          'bottle',12,    'منظفات'),
      (tenant_id_in, 'نشاء كي',           'kg',    20,    'منظفات'),
      (tenant_id_in, 'ماء (لكل كجم)',     'liter', 0.05,  'مرافق'),
      (tenant_id_in, 'كهرباء (لكل ساعة)', 'other', 4,     'مرافق'),
      (tenant_id_in, 'كيس بلاستيك تغليف', 'piece', 0.10,  'مستلزمات'),
      (tenant_id_in, 'شماعة بلاستيك',     'piece', 0.40,  'مستلزمات'),
      (tenant_id_in, 'علاقات أرقام',      'piece', 0.05,  'مستلزمات'),
      (tenant_id_in, 'بخاخ معطّر',        'bottle',8,     'مستهلكات')
    on conflict do nothing;

  elsif industry = 'retail' then
    insert into ingredients (tenant_id, name, unit, cost_per_unit, category) values
      (tenant_id_in, 'كيس تسوّق ورقي',    'bag',    0.50,  'تغليف'),
      (tenant_id_in, 'كيس تسوّق بلاستيك', 'bag',    0.15,  'تغليف'),
      (tenant_id_in, 'علبة كرتون',        'piece',  1.50,  'تغليف'),
      (tenant_id_in, 'ورق تغليف',         'piece',  0.60,  'تغليف'),
      (tenant_id_in, 'لاصق سعر',          'piece',  0.05,  'تغليف'),
      (tenant_id_in, 'فاتورة طباعة',      'piece',  0.10,  'مستلزمات'),
      (tenant_id_in, 'كيس هدية',          'bag',    1.00,  'تغليف'),
      (tenant_id_in, 'بطاقة هدية',        'piece',  0.80,  'تغليف'),
      (tenant_id_in, 'باركود',            'piece',  0.05,  'مستلزمات'),
      (tenant_id_in, 'مناديل عرض',        'box',    5,     'مستلزمات')
    on conflict do nothing;

  else
    raise exception 'unknown industry: %', industry;
  end if;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

grant execute on function seed_industry_items(uuid, text) to authenticated;

-- ─── Generic AI-driven seed (accepts any items array) ────────────────────
create or replace function seed_items_from_list(items_in jsonb)
returns int
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  inserted_count int := 0;
  item jsonb;
begin
  select tenant_id into my_tenant
    from tenant_users
   where user_id = auth.uid() and role = 'admin' limit 1;
  if my_tenant is null then
    raise exception 'unauthorized';
  end if;

  for item in select * from jsonb_array_elements(items_in)
  loop
    insert into ingredients (
      tenant_id, name, unit, cost_per_unit, category
    ) values (
      my_tenant,
      coalesce(item->>'name',     'عنصر'),
      coalesce(item->>'unit',     'piece'),
      coalesce((item->>'cost_per_unit')::numeric, 0),
      item->>'category'
    )
    on conflict do nothing;
    inserted_count := inserted_count + 1;
  end loop;

  return inserted_count;
end;
$$;

grant execute on function seed_items_from_list(jsonb) to authenticated;

notify pgrst, 'reload schema';

select 'Recipe costing — multi-industry ready ✅' as status;

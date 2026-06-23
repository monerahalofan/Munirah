-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Inventory Tracking (إدارة المخزون)
-- يتتبع حركة الدخول/الخروج/التعديل لكل مكوّن + تنبيهات إعادة الطلب
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Stock movements log ──────────────────────────────────────────────
create table if not exists stock_movements (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  ingredient_id uuid references ingredients(id) on delete cascade not null,
  movement_type text not null check (movement_type in (
    'received',    -- استلام من مورد
    'sold',        -- بيع (خصم تلقائي عبر وصفة)
    'consumed',    -- استهلاك يدوي (تالف، تجربة، عينة)
    'wasted',      -- هدر (انتهاء صلاحية، كسر)
    'adjustment',  -- تعديل جرد (زيادة/نقصان بعد العد)
    'transfer',    -- نقل بين فروع
    'returned'     -- إرجاع للمورد
  )),
  quantity      numeric(14,4) not null,  -- موجبة دائماً
  unit          text not null,
  unit_cost     numeric(14,4),           -- التكلفة وقت الحركة
  total_value   numeric(14,2),
  reason        text,
  recipe_id     uuid references recipes(id) on delete set null,
  supplier_id   uuid references suppliers(id) on delete set null,
  expense_id    uuid references expenses(id) on delete set null,
  reference     text,                    -- رقم فاتورة المورد أو مرجع
  notes         text,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz default now()
);

create index if not exists idx_stock_mov_tenant on stock_movements(tenant_id, created_at desc);
create index if not exists idx_stock_mov_ing on stock_movements(ingredient_id, created_at desc);
create index if not exists idx_stock_mov_type on stock_movements(tenant_id, movement_type);

alter table stock_movements enable row level security;
drop policy if exists "tenant_rw_stock_mov" on stock_movements;
create policy "tenant_rw_stock_mov" on stock_movements for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on stock_movements to authenticated;

-- ─── 2. Trigger: auto-update ingredient stock on movement ────────────────
create or replace function apply_stock_movement()
returns trigger
language plpgsql
as $$
declare
  delta numeric;
begin
  -- Determine delta direction
  delta := case new.movement_type
    when 'received'   then  new.quantity
    when 'sold'       then -new.quantity
    when 'consumed'   then -new.quantity
    when 'wasted'     then -new.quantity
    when 'transfer'   then -new.quantity
    when 'returned'   then -new.quantity
    when 'adjustment' then  new.quantity  -- can be negative if user passes negative qty (but qty is >0, see logic below)
    else 0
  end;

  -- For adjustment, allow signed via reason "+X" or "-X"
  -- Simpler: callers should use 'received' or 'wasted' to be explicit
  -- 'adjustment' here = absolute set, computed delta = qty - current_stock
  if new.movement_type = 'adjustment' then
    select new.quantity - coalesce(current_stock, 0) into delta
      from ingredients where id = new.ingredient_id;
  end if;

  update ingredients
     set current_stock = greatest(0, coalesce(current_stock, 0) + delta),
         last_updated  = now()
   where id = new.ingredient_id;

  -- Auto-fill unit_cost + total_value if missing
  if new.unit_cost is null then
    select cost_per_unit into new.unit_cost
      from ingredients where id = new.ingredient_id;
  end if;
  if new.total_value is null and new.unit_cost is not null then
    new.total_value := new.quantity * new.unit_cost;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_apply_stock_movement on stock_movements;
create trigger trg_apply_stock_movement
  before insert on stock_movements
  for each row execute function apply_stock_movement();

-- ─── 3. View: low-stock ingredients (need reorder) ───────────────────────
create or replace view low_stock_alerts as
select
  i.id              as ingredient_id,
  i.tenant_id,
  i.name,
  i.category,
  i.current_stock,
  i.min_stock,
  i.unit,
  i.cost_per_unit,
  i.supplier_id,
  i.supplier_name,
  i.min_stock - i.current_stock as shortage,
  -- Suggested reorder quantity = 2× min_stock - current
  greatest(2 * i.min_stock - i.current_stock, i.min_stock) as suggested_qty,
  -- Days of stock remaining (based on last 30d avg consumption)
  case
    when (select coalesce(sum(quantity), 0) from stock_movements
          where ingredient_id = i.id
            and movement_type in ('sold','consumed','wasted')
            and created_at > now() - interval '30 days') > 0
    then round(
      i.current_stock /
      ((select sum(quantity) from stock_movements
        where ingredient_id = i.id
          and movement_type in ('sold','consumed','wasted')
          and created_at > now() - interval '30 days') / 30.0),
      1)
    else null
  end as days_remaining
from ingredients i
where i.active = true
  and i.min_stock > 0
  and i.current_stock <= i.min_stock;

grant select on low_stock_alerts to authenticated;

-- ─── 4. View: stock value summary per tenant ─────────────────────────────
create or replace view stock_value_summary as
select
  tenant_id,
  count(*) filter (where active = true)                              as total_active_ingredients,
  count(*) filter (where current_stock <= min_stock and min_stock>0) as low_stock_count,
  count(*) filter (where current_stock = 0)                          as out_of_stock_count,
  coalesce(sum(current_stock * cost_per_unit), 0)                    as total_value
from ingredients
group by tenant_id;

grant select on stock_value_summary to authenticated;

-- ─── 5. RPC: deduct stock when a recipe is sold ──────────────────────────
create or replace function sell_recipe(
  recipe_id_in uuid,
  quantity_sold int default 1,
  reason_in text default null
)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  r record;
  ri record;
  conv numeric;
  movements_count int := 0;
  total_cost numeric := 0;
  warnings jsonb := '[]'::jsonb;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then raise exception 'unauthorized'; end if;

  -- Verify recipe belongs to tenant
  select * into r from recipes where id = recipe_id_in and tenant_id = my_tenant;
  if r.id is null then raise exception 'recipe not found'; end if;

  -- Deduct each ingredient
  for ri in
    select ri.ingredient_id, ri.quantity as ri_qty, ri.unit as ri_unit,
           i.unit as ing_unit, i.cost_per_unit, i.current_stock, i.name
    from recipe_ingredients ri
    join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = recipe_id_in
  loop
    conv := unit_conversion(ri.ri_unit, ri.ing_unit);
    if conv is null then conv := 1; end if;
    declare needed numeric := ri.ri_qty * conv * quantity_sold;
    begin
      if ri.current_stock < needed then
        warnings := warnings || jsonb_build_object(
          'ingredient', ri.name,
          'needed', needed,
          'available', ri.current_stock,
          'shortage', needed - ri.current_stock
        );
      end if;
      insert into stock_movements (
        tenant_id, ingredient_id, movement_type, quantity, unit,
        unit_cost, total_value, reason, recipe_id, created_by
      ) values (
        my_tenant, ri.ingredient_id, 'sold', needed, ri.ing_unit,
        ri.cost_per_unit, needed * ri.cost_per_unit,
        coalesce(reason_in, format('بيع %s × %s', r.name, quantity_sold)),
        recipe_id_in, auth.uid()
      );
      movements_count := movements_count + 1;
      total_cost := total_cost + (needed * ri.cost_per_unit);
    end;
  end loop;

  return json_build_object(
    'success', true,
    'recipe_id', recipe_id_in,
    'quantity_sold', quantity_sold,
    'movements_count', movements_count,
    'total_cost', total_cost,
    'warnings', warnings
  );
end;
$$;

grant execute on function sell_recipe(uuid, int, text) to authenticated;

-- ─── 6. RPC: receive stock from supplier ─────────────────────────────────
create or replace function receive_stock(
  ingredient_id_in uuid,
  quantity_in numeric,
  unit_cost_in numeric default null,
  supplier_id_in uuid default null,
  reference_in text default null,
  notes_in text default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  movement_id uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then raise exception 'unauthorized'; end if;

  -- Verify ingredient belongs to tenant
  if not exists (select 1 from ingredients
    where id = ingredient_id_in and tenant_id = my_tenant)
  then raise exception 'ingredient not found'; end if;

  insert into stock_movements (
    tenant_id, ingredient_id, movement_type, quantity, unit,
    unit_cost, supplier_id, reference, notes, created_by
  ) values (
    my_tenant, ingredient_id_in, 'received', quantity_in,
    (select unit from ingredients where id = ingredient_id_in),
    unit_cost_in, supplier_id_in, reference_in, notes_in, auth.uid()
  ) returning id into movement_id;

  -- Update cost_per_unit if new price provided (weighted-average style)
  if unit_cost_in is not null and unit_cost_in > 0 then
    update ingredients set
      cost_per_unit = unit_cost_in,
      last_updated = now()
    where id = ingredient_id_in;
  end if;

  return movement_id;
end;
$$;

grant execute on function receive_stock(uuid, numeric, numeric, uuid, text, text) to authenticated;

-- ─── 7. RPC: stock count adjustment ──────────────────────────────────────
create or replace function adjust_stock(
  ingredient_id_in uuid,
  new_quantity numeric,
  reason_in text default 'تعديل جرد'
)
returns uuid
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  movement_id uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then raise exception 'unauthorized'; end if;

  if not exists (select 1 from ingredients
    where id = ingredient_id_in and tenant_id = my_tenant)
  then raise exception 'ingredient not found'; end if;

  insert into stock_movements (
    tenant_id, ingredient_id, movement_type, quantity, unit,
    reason, created_by
  ) values (
    my_tenant, ingredient_id_in, 'adjustment', new_quantity,
    (select unit from ingredients where id = ingredient_id_in),
    reason_in, auth.uid()
  ) returning id into movement_id;

  return movement_id;
end;
$$;

grant execute on function adjust_stock(uuid, numeric, text) to authenticated;

notify pgrst, 'reload schema';

select 'Inventory tracking ready ✅' as status;

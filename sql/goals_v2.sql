-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Goals v2 (إعادة تصميم الأهداف المالية)
-- ══════════════════════════════════════════════════════════════════════════

alter table goals add column if not exists category text default 'custom'
  check (category in ('revenue','savings','expense_reduction','customers','custom'));
alter table goals add column if not exists frequency text default 'one_time'
  check (frequency in ('one_time','monthly','quarterly','yearly'));
alter table goals add column if not exists start_date date default current_date;
alter table goals add column if not exists description text;
alter table goals add column if not exists color text default '#86BA72';
alter table goals add column if not exists status text default 'active'
  check (status in ('active','completed','paused','archived'));
alter table goals add column if not exists auto_track boolean default false;
alter table goals add column if not exists priority int default 2 check (priority between 1 and 3);
alter table goals add column if not exists updated_at timestamptz default now();

-- ─── Auto-recalculate `current` value for tracked revenue/savings goals ──
create or replace function refresh_goal_progress(goal_id_in uuid)
returns numeric
language plpgsql
security definer
as $$
declare
  g goals%rowtype;
  computed numeric := 0;
begin
  select * into g from goals where id = goal_id_in;
  if g.id is null then return 0; end if;

  if not coalesce(g.auto_track, false) then
    return g.current;
  end if;

  if g.category = 'revenue' then
    select coalesce(sum(amount),0) into computed
      from transactions
     where tenant_id = g.tenant_id and type = 'income'
       and date >= coalesce(g.start_date, '1900-01-01')
       and (g.deadline is null or date <= g.deadline);
  elsif g.category = 'expense_reduction' then
    select coalesce(sum(amount),0) into computed
      from transactions
     where tenant_id = g.tenant_id and type = 'expense'
       and date >= coalesce(g.start_date, '1900-01-01')
       and (g.deadline is null or date <= g.deadline);
  end if;

  update goals set current = computed, updated_at = now() where id = goal_id_in;
  return computed;
end;
$$;

grant execute on function refresh_goal_progress(uuid) to authenticated;

notify pgrst, 'reload schema';

select 'Goals v2 ready ✅' as status;

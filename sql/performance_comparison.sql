-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Performance Comparison (مقارنة الأداء)
-- يقارن اليوم/الأسبوع/الشهر بالفترة المقابلة السابقة
-- ══════════════════════════════════════════════════════════════════════════

create or replace function compare_performance()
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  today date := current_date;
  yesterday date := current_date - 1;
  same_day_last_week date := current_date - 7;
  same_day_last_month date := current_date - interval '1 month';

  -- Week ranges
  this_week_start date := current_date - extract(dow from current_date)::int;
  last_week_start date := this_week_start - 7;
  last_week_end   date := this_week_start - 1;

  -- Month ranges
  this_month_start date := date_trunc('month', current_date)::date;
  last_month_start date := date_trunc('month', current_date - interval '1 month')::date;
  last_month_end   date := this_month_start - 1;

  -- Today
  today_rev numeric := 0;
  today_exp numeric := 0;
  today_closing numeric := 0;

  -- Yesterday
  yest_rev numeric := 0;
  yest_exp numeric := 0;
  yest_closing numeric := 0;

  -- Same day last week
  slw_rev numeric := 0;
  slw_exp numeric := 0;
  slw_closing numeric := 0;

  -- Same day last month
  slm_rev numeric := 0;
  slm_exp numeric := 0;

  -- This week so far
  tw_rev numeric := 0;
  tw_exp numeric := 0;
  tw_closing numeric := 0;

  -- Last week same period (Sun to today's day-of-week)
  lw_rev numeric := 0;
  lw_exp numeric := 0;
  lw_closing numeric := 0;

  -- This month so far
  tm_rev numeric := 0;
  tm_exp numeric := 0;

  -- Last month same period (1st to today's day-of-month)
  lm_rev numeric := 0;
  lm_exp numeric := 0;
begin
  -- Tenant
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then
    return json_build_object('error', 'no_tenant');
  end if;

  -- ─── TODAY ─────────────────────────────────────────────────────────────
  select coalesce(sum(amount), 0) into today_rev
    from transactions where tenant_id = my_tenant and type = 'income' and date = today;
  select coalesce(sum(amount), 0) into today_exp
    from expenses where tenant_id = my_tenant and expense_date = today;
  select coalesce(sum(total_sales), 0) into today_closing
    from daily_closings where tenant_id = my_tenant and closing_date = today;

  -- ─── YESTERDAY ─────────────────────────────────────────────────────────
  select coalesce(sum(amount), 0) into yest_rev
    from transactions where tenant_id = my_tenant and type = 'income' and date = yesterday;
  select coalesce(sum(amount), 0) into yest_exp
    from expenses where tenant_id = my_tenant and expense_date = yesterday;
  select coalesce(sum(total_sales), 0) into yest_closing
    from daily_closings where tenant_id = my_tenant and closing_date = yesterday;

  -- ─── SAME DAY LAST WEEK ────────────────────────────────────────────────
  select coalesce(sum(amount), 0) into slw_rev
    from transactions where tenant_id = my_tenant and type = 'income' and date = same_day_last_week;
  select coalesce(sum(amount), 0) into slw_exp
    from expenses where tenant_id = my_tenant and expense_date = same_day_last_week;
  select coalesce(sum(total_sales), 0) into slw_closing
    from daily_closings where tenant_id = my_tenant and closing_date = same_day_last_week;

  -- ─── SAME DAY LAST MONTH ───────────────────────────────────────────────
  select coalesce(sum(amount), 0) into slm_rev
    from transactions where tenant_id = my_tenant and type = 'income' and date = same_day_last_month::date;
  select coalesce(sum(amount), 0) into slm_exp
    from expenses where tenant_id = my_tenant and expense_date = same_day_last_month::date;

  -- ─── THIS WEEK SO FAR ──────────────────────────────────────────────────
  select coalesce(sum(amount), 0) into tw_rev
    from transactions where tenant_id = my_tenant and type = 'income'
      and date >= this_week_start and date <= today;
  select coalesce(sum(amount), 0) into tw_exp
    from expenses where tenant_id = my_tenant
      and expense_date >= this_week_start and expense_date <= today;
  select coalesce(sum(total_sales), 0) into tw_closing
    from daily_closings where tenant_id = my_tenant
      and closing_date >= this_week_start and closing_date <= today;

  -- ─── LAST WEEK SAME PERIOD ─────────────────────────────────────────────
  select coalesce(sum(amount), 0) into lw_rev
    from transactions where tenant_id = my_tenant and type = 'income'
      and date >= last_week_start and date <= last_week_start + (today - this_week_start);
  select coalesce(sum(amount), 0) into lw_exp
    from expenses where tenant_id = my_tenant
      and expense_date >= last_week_start and expense_date <= last_week_start + (today - this_week_start);
  select coalesce(sum(total_sales), 0) into lw_closing
    from daily_closings where tenant_id = my_tenant
      and closing_date >= last_week_start and closing_date <= last_week_start + (today - this_week_start);

  -- ─── THIS MONTH SO FAR ─────────────────────────────────────────────────
  select coalesce(sum(amount), 0) into tm_rev
    from transactions where tenant_id = my_tenant and type = 'income'
      and date >= this_month_start and date <= today;
  select coalesce(sum(amount), 0) into tm_exp
    from expenses where tenant_id = my_tenant
      and expense_date >= this_month_start and expense_date <= today;

  -- ─── LAST MONTH SAME PERIOD ────────────────────────────────────────────
  select coalesce(sum(amount), 0) into lm_rev
    from transactions where tenant_id = my_tenant and type = 'income'
      and date >= last_month_start
      and date <= least(last_month_end, last_month_start + (today - this_month_start));
  select coalesce(sum(amount), 0) into lm_exp
    from expenses where tenant_id = my_tenant
      and expense_date >= last_month_start
      and expense_date <= least(last_month_end, last_month_start + (today - this_month_start));

  return json_build_object(
    'today', json_build_object(
      'revenue',  today_rev,
      'expense',  today_exp,
      'closing',  today_closing,
      'net',      today_rev - today_exp
    ),
    'yesterday', json_build_object(
      'revenue', yest_rev, 'expense', yest_exp, 'closing', yest_closing, 'net', yest_rev - yest_exp
    ),
    'same_day_last_week', json_build_object(
      'revenue', slw_rev, 'expense', slw_exp, 'closing', slw_closing, 'net', slw_rev - slw_exp,
      'date', same_day_last_week
    ),
    'same_day_last_month', json_build_object(
      'revenue', slm_rev, 'expense', slm_exp, 'net', slm_rev - slm_exp,
      'date', same_day_last_month::date
    ),
    'this_week', json_build_object(
      'revenue', tw_rev, 'expense', tw_exp, 'closing', tw_closing, 'net', tw_rev - tw_exp,
      'start', this_week_start
    ),
    'last_week', json_build_object(
      'revenue', lw_rev, 'expense', lw_exp, 'closing', lw_closing, 'net', lw_rev - lw_exp,
      'start', last_week_start, 'end', last_week_end
    ),
    'this_month', json_build_object(
      'revenue', tm_rev, 'expense', tm_exp, 'net', tm_rev - tm_exp,
      'start', this_month_start
    ),
    'last_month', json_build_object(
      'revenue', lm_rev, 'expense', lm_exp, 'net', lm_rev - lm_exp,
      'start', last_month_start, 'end', last_month_end
    )
  );
end;
$$;

grant execute on function compare_performance() to authenticated;

notify pgrst, 'reload schema';

select 'Performance comparison ready ✅' as status;

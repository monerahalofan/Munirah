-- ══════════════════════════════════════════════════════════════════════════
-- محسوب — Anomaly Detection (اكتشاف الشذوذ المالي)
-- يكتشف القفزات والانخفاضات غير المعتادة في الإيرادات والمصاريف
-- ══════════════════════════════════════════════════════════════════════════

-- ─── 1. Anomaly dismissals tracker (don't re-alert same anomaly) ─────────
create table if not exists anomaly_dismissals (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references tenants(id) on delete cascade not null,
  user_id       uuid references auth.users(id) on delete set null,
  anomaly_type  text not null,
  for_date      date not null,
  dismissed_at  timestamptz default now(),
  unique (tenant_id, anomaly_type, for_date)
);

create index if not exists idx_anomaly_dismiss on anomaly_dismissals(tenant_id, for_date);
alter table anomaly_dismissals enable row level security;

drop policy if exists "tenant_rw_anomdis" on anomaly_dismissals;
create policy "tenant_rw_anomdis" on anomaly_dismissals for all using (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
) with check (
  tenant_id in (select tenant_id from tenant_users where user_id = auth.uid())
);

grant all on anomaly_dismissals to authenticated;

-- ─── 2. Main detection function ──────────────────────────────────────────
create or replace function detect_anomalies()
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
  today date := current_date;
  anomalies jsonb := '[]'::jsonb;
  dismissed_types text[];

  -- Daily expenses
  exp_avg numeric := 0;
  exp_today numeric := 0;
  exp_multiplier numeric := 0;

  -- Single big expense
  single_exp_avg numeric := 0;
  big_expenses jsonb := '[]'::jsonb;

  -- Revenue
  rev_avg numeric := 0;
  rev_today numeric := 0;
  rev_drop_pct numeric := 0;

  -- Closings
  closing_today_total numeric := 0;
  closing_dow_avg numeric := 0;
begin
  -- Tenant
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then
    return json_build_object('anomalies', '[]'::jsonb);
  end if;

  -- Get already-dismissed types for today
  select coalesce(array_agg(anomaly_type), '{}')
    into dismissed_types
    from anomaly_dismissals
   where tenant_id = my_tenant and for_date = today;

  -- ─── Anomaly 1: Daily expense spike ───────────────────────────────────
  if not ('expense_spike' = any(dismissed_types)) then
    select coalesce(avg(daily_total), 0) into exp_avg
    from (
      select expense_date, sum(amount) as daily_total
      from expenses
      where tenant_id = my_tenant
        and expense_date >= today - 30
        and expense_date < today
      group by expense_date
    ) dt;

    select coalesce(sum(amount), 0) into exp_today
    from expenses where tenant_id = my_tenant and expense_date = today;

    if exp_avg > 50 and exp_today > exp_avg * 3 then
      exp_multiplier := round((exp_today / exp_avg)::numeric, 1);
      anomalies := anomalies || jsonb_build_object(
        'type',       'expense_spike',
        'severity',   'high',
        'icon',       '📈',
        'title',      'مصاريف اليوم مرتفعة بشكل غير معتاد',
        'message',    format('سجّلت %s ر.س اليوم — أعلى بـ %sx من المتوسط الشهري (%s ر.س)',
                        to_char(exp_today, 'FM999,999,999.00'),
                        exp_multiplier,
                        to_char(exp_avg, 'FM999,999,999.00')),
        'cta_label',  'افتح المصاريف',
        'cta_page',   'exp',
        'value',      exp_today,
        'baseline',   exp_avg,
        'multiplier', exp_multiplier
      );
    end if;
  end if;

  -- ─── Anomaly 2: Single large expense ──────────────────────────────────
  if not ('large_single_expense' = any(dismissed_types)) then
    select coalesce(avg(amount), 0) into single_exp_avg
    from expenses
    where tenant_id = my_tenant
      and expense_date >= today - 30
      and expense_date < today;

    if single_exp_avg > 0 then
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'id',          id,
          'description', description,
          'amount',      amount,
          'multiplier',  round((amount / nullif(single_exp_avg, 0))::numeric, 1)
        )),
        '[]'::jsonb
      ) into big_expenses
      from expenses
      where tenant_id = my_tenant
        and expense_date = today
        and amount > single_exp_avg * 5;

      if jsonb_array_length(big_expenses) > 0 then
        anomalies := anomalies || jsonb_build_object(
          'type',      'large_single_expense',
          'severity',  'medium',
          'icon',      '💰',
          'title',     'مصروف فردي ضخم',
          'message',   format('في %s مصروف اليوم أكبر بكثير من المعتاد — تأكد منه',
                         jsonb_array_length(big_expenses)),
          'cta_label', 'افتح المصاريف',
          'cta_page',  'exp',
          'items',     big_expenses,
          'baseline',  single_exp_avg
        );
      end if;
    end if;
  end if;

  -- ─── Anomaly 3: Revenue drop ──────────────────────────────────────────
  if not ('revenue_drop' = any(dismissed_types)) then
    select coalesce(avg(daily_total), 0) into rev_avg
    from (
      select date, sum(amount) as daily_total
      from transactions
      where tenant_id = my_tenant
        and type = 'income'
        and date >= today - 30
        and date < today
      group by date
    ) dt;

    select coalesce(sum(amount), 0) into rev_today
    from transactions
    where tenant_id = my_tenant
      and type = 'income'
      and date = today;

    -- Only flag if there was activity before today (not the user's first day)
    if rev_avg > 100 and rev_today < rev_avg * 0.3 then
      rev_drop_pct := round(((1 - rev_today / rev_avg) * 100)::numeric, 0);
      anomalies := anomalies || jsonb_build_object(
        'type',      'revenue_drop',
        'severity',  'medium',
        'icon',      '📉',
        'title',     'إيرادات اليوم منخفضة',
        'message',   format('سجّلت %s ر.س فقط اليوم — أقل بنسبة %s%% من المتوسط (%s ر.س)',
                       to_char(rev_today, 'FM999,999,999.00'),
                       rev_drop_pct,
                       to_char(rev_avg, 'FM999,999,999.00')),
        'cta_label', 'سجّل إيراد',
        'cta_page',  'tx',
        'value',     rev_today,
        'baseline',  rev_avg,
        'drop_pct',  rev_drop_pct
      );
    end if;
  end if;

  -- ─── Anomaly 4: Daily closing anomaly (B2C) ───────────────────────────
  if not ('closing_low' = any(dismissed_types)) then
    select coalesce(sum(total_sales), 0) into closing_today_total
    from daily_closings
    where tenant_id = my_tenant and closing_date = today;

    if closing_today_total > 0 then
      -- Compare to same day-of-week over last 4 weeks
      select coalesce(avg(total_sales), 0) into closing_dow_avg
      from daily_closings
      where tenant_id = my_tenant
        and extract(dow from closing_date) = extract(dow from today)
        and closing_date >= today - 28
        and closing_date < today;

      if closing_dow_avg > 500 and closing_today_total < closing_dow_avg * 0.5 then
        anomalies := anomalies || jsonb_build_object(
          'type',      'closing_low',
          'severity',  'medium',
          'icon',      '🏦',
          'title',     'إغلاق اليوم منخفض',
          'message',   format('إغلاقك (%s ر.س) أقل من معدل %s السابقة (%s ر.س) — تأكد من رفع التقرير كاملاً',
                         to_char(closing_today_total, 'FM999,999,999.00'),
                         to_char(closing_dow_avg, 'FM999,999,999.00'),
                         to_char(closing_today_total, 'FM999,999,999.00')),
          'cta_label', 'افتح الإغلاقات',
          'cta_page',  'pos',
          'value',     closing_today_total,
          'baseline',  closing_dow_avg
        );
      end if;
    end if;
  end if;

  return json_build_object(
    'anomalies',   anomalies,
    'count',       jsonb_array_length(anomalies),
    'checked_at',  now(),
    'for_date',    today
  );
end;
$$;

grant execute on function detect_anomalies() to authenticated;

-- ─── 3. Dismiss anomaly RPC ─────────────────────────────────────────────
create or replace function dismiss_anomaly(anomaly_type_in text)
returns json
language plpgsql
security definer
as $$
declare
  my_tenant uuid;
begin
  select tenant_id into my_tenant from tenant_users
   where user_id = auth.uid() limit 1;
  if my_tenant is null then
    return json_build_object('success', false);
  end if;

  insert into anomaly_dismissals (tenant_id, user_id, anomaly_type, for_date)
  values (my_tenant, auth.uid(), anomaly_type_in, current_date)
  on conflict (tenant_id, anomaly_type, for_date) do nothing;

  return json_build_object('success', true);
end;
$$;

grant execute on function dismiss_anomaly(text) to authenticated;

notify pgrst, 'reload schema';

select 'Anomaly detection ready ✅' as status;

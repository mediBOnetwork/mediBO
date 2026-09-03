-- CHANGE #693 — Partner scorecard, monthly targets and partner-scope incentives.
-- feature_gaps row 156.
--
-- Suppliers are ranked by SPN and riders gained SLA + ratings in #309. The
-- FULFILMENT partner — who owns the whole physical lane for a zone — had no
-- score at all. Everything below is computed from data the platform ALREADY
-- captures (orders, supplier_disputes, deliveries, settlement periods and their
-- acknowledgements, exception_state); nothing new is asked of anyone.
--
-- Max-backend: every label, every formatted value, every tone and every
-- progress fraction is produced here. The Flutter card renders the payload.
--
-- Idempotent throughout: a resumed worker re-applies this file as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CONFIG — the two thresholds the scorecard cannot read from elsewhere.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.partner_scorecard_config (
  id                  smallint primary key default 1,
  dispatch_sla_hours  numeric not null default 12,
  exception_sla_hours numeric not null default 24,
  rank_min_orders     integer not null default 1,
  updated_at          timestamptz not null default now(),
  updated_by          text,
  constraint partner_scorecard_config_single check (id = 1)
);
insert into public.partner_scorecard_config(id) values (1) on conflict (id) do nothing;
alter table public.partner_scorecard_config enable row level security;
drop policy if exists partner_scorecard_config_read on public.partner_scorecard_config;
create policy partner_scorecard_config_read on public.partner_scorecard_config
  for select using (auth.uid() is not null);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. METRIC CATALOGUE — the seven metrics, their words and their direction.
--    A metric is DATA, so a new one is an INSERT plus a branch in
--    _partner_metric_values(); the app learns of it from the payload.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.partner_scorecard_metric (
  slug           text primary key,
  label          text not null,
  hint           text not null default '',
  value_suffix   text not null default '',
  direction      text not null default 'higher_better',
  default_target numeric not null default 0,
  decimals       smallint not null default 1,
  sort_order     integer not null default 100,
  active         boolean not null default true,
  constraint partner_scorecard_metric_dir_ck
    check (direction in ('higher_better','lower_better'))
);
alter table public.partner_scorecard_metric enable row level security;
drop policy if exists partner_scorecard_metric_read on public.partner_scorecard_metric;
create policy partner_scorecard_metric_read on public.partner_scorecard_metric
  for select using (auth.uid() is not null);

insert into public.partner_scorecard_metric
  (slug, label, hint, value_suffix, direction, default_target, decimals, sort_order)
values
  ('inquiry_to_pack_h','Inquiry to pack',
   'Average hours from the customer''s order to the bag being ready to dispatch.',
   ' h','lower_better', 24, 1, 10),
  ('on_time_dispatch_pct','On-time dispatch',
   'Share of orders made dispatch-ready inside the dispatch SLA.',
   '%','higher_better', 90, 1, 20),
  ('count_dispute_rate_pct','Count disputes',
   'Share of ordered lines that raised a short or wrong-product dispute.',
   '%','lower_better', 2, 1, 30),
  ('unfulfilled_rate_pct','Unfulfilled lines',
   'Share of ordered lines no supplier in the zone could fulfil.',
   '%','lower_better', 5, 1, 40),
  ('delivery_sla_pct','Delivery SLA',
   'Share of deliveries handed over inside the promised window.',
   '%','higher_better', 95, 1, 50),
  ('settlement_ack_h','Settlement acknowledged in',
   'Average hours from a statement closing to the partner acknowledging it.',
   ' h','lower_better', 48, 1, 60),
  ('exception_sla_pct','Exceptions closed in SLA',
   'Share of the zone''s exceptions closed inside the exception SLA.',
   '%','higher_better', 90, 1, 70)
on conflict (slug) do update set
  label = excluded.label, hint = excluded.hint,
  value_suffix = excluded.value_suffix, direction = excluded.direction,
  default_target = excluded.default_target, decimals = excluded.decimals,
  sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. HISTORY — one row per partner / month / metric. Written by the nightly
--    snapshot so a closed month keeps the number it was scored on even after
--    the underlying orders are archived or corrected.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.partner_scorecard_month (
  partner_id  bigint not null references public.region_partners(id) on delete cascade,
  month       date   not null,
  metric      text   not null references public.partner_scorecard_metric(slug) on delete cascade,
  value       numeric,
  sample_n    integer not null default 0,
  target      numeric,
  score       numeric,
  computed_at timestamptz not null default now(),
  primary key (partner_id, month, metric)
);
create index if not exists partner_scorecard_month_month_idx
  on public.partner_scorecard_month(month, partner_id);
alter table public.partner_scorecard_month enable row level security;
drop policy if exists partner_scorecard_month_admin on public.partner_scorecard_month;
create policy partner_scorecard_month_admin on public.partner_scorecard_month
  for select to authenticated using (public.is_admin());
drop policy if exists partner_scorecard_month_own on public.partner_scorecard_month;
create policy partner_scorecard_month_own on public.partner_scorecard_month
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. TARGETS — super admin sets a monthly target per partner per metric.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.partner_metric_target (
  partner_id bigint not null references public.region_partners(id) on delete cascade,
  month      date   not null,
  metric     text   not null references public.partner_scorecard_metric(slug) on delete cascade,
  target     numeric not null,
  note       text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (partner_id, month, metric)
);
alter table public.partner_metric_target enable row level security;
drop policy if exists partner_metric_target_admin on public.partner_metric_target;
create policy partner_metric_target_admin on public.partner_metric_target
  for select to authenticated using (public.is_admin());
drop policy if exists partner_metric_target_own on public.partner_metric_target;
create policy partner_metric_target_own on public.partner_metric_target
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. INCENTIVES — scope='partner'.
--    incentive_schemes.agency_id points at delivery_partner_registrations
--    (a RIDER agency). A fulfilment partner is region_partners(id) bigint, a
--    different table entirely, so it gets its own column rather than a cast.
--    incentive_schemes_for() joins delivery_partner_registrations and matches
--    only scope all/zone/agency, so a partner scheme can never be paid to a
--    rider — the new scope is invisible on that side by construction.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.incentive_schemes
  add column if not exists region_partner_id bigint references public.region_partners(id) on delete cascade;

alter table public.incentive_schemes drop constraint if exists incentive_schemes_scope_ck;
alter table public.incentive_schemes add constraint incentive_schemes_scope_ck
  check (scope in ('all','zone','agency','partner'));

-- The metric catalogue is shared, so it needs to say which side a metric is
-- for. Existing rows are the rider's.
alter table public.incentive_metrics
  add column if not exists scope text not null default 'delivery';
alter table public.incentive_metrics drop constraint if exists incentive_metrics_scope_ck;
alter table public.incentive_metrics add constraint incentive_metrics_scope_ck
  check (scope in ('delivery','partner'));

insert into public.incentive_metrics(slug, label, value_suffix, target_hint, sort_order, active, scope)
select m.slug, m.label, m.value_suffix, m.hint, 100 + m.sort_order, m.active, 'partner'
  from public.partner_scorecard_metric m
on conflict (slug) do update set
  label = excluded.label, value_suffix = excluded.value_suffix,
  target_hint = excluded.target_hint, scope = 'partner';

-- Earnings for a partner scheme. incentive_earnings.partner_id is a uuid FK to
-- delivery_partner_registrations, so partner bonuses keep their own ledger —
-- monthly, not daily, because every partner metric is a monthly average.
create table if not exists public.partner_incentive_earning (
  id           bigserial primary key,
  scheme_id    uuid   not null references public.incentive_schemes(id) on delete cascade,
  partner_id   bigint not null references public.region_partners(id) on delete cascade,
  month        date   not null,
  metric       text   not null,
  metric_value numeric not null default 0,
  threshold    numeric not null default 0,
  amount       numeric not null default 0,
  period_id    bigint references public.partner_settlement_periods(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (scheme_id, partner_id, month)
);
create index if not exists partner_incentive_earning_open_idx
  on public.partner_incentive_earning(partner_id, month) where period_id is null;
create index if not exists partner_incentive_earning_period_idx
  on public.partner_incentive_earning(period_id);
alter table public.partner_incentive_earning enable row level security;
drop policy if exists partner_incentive_earning_admin on public.partner_incentive_earning;
create policy partner_incentive_earning_admin on public.partner_incentive_earning
  for select to authenticated using (public.is_admin());
drop policy if exists partner_incentive_earning_own on public.partner_incentive_earning;
create policy partner_incentive_earning_own on public.partner_incentive_earning
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());

-- The settlement carries the bonus as its own line.
alter table public.partner_settlement_periods
  add column if not exists bonus_total numeric not null default 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE MEASUREMENT. One function, seven metrics, all from existing tables.
--    Returns NULL value + sample_n 0 when the month gave nothing to measure —
--    absence is explicit, never a zero that reads like a failure.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._partner_metric_values(p_partner bigint, p_month date)
returns table(metric text, value numeric, sample_n integer)
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_from date := date_trunc('month', p_month)::date;
  v_to   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  cfg    public.partner_scorecard_config%rowtype;
  v_zone smallint;
  v_lines int;
begin
  select * into cfg from public.partner_scorecard_config where id = 1;
  select r.zone_id::smallint into v_zone from public.region_partners r where r.id = p_partner;

  select count(*)::int into v_lines
    from public.order_items i
    join public.orders o on o.id = i.order_id
   where o.fulfillment_partner_id = p_partner
     and o.order_date between v_from and v_to
     and coalesce(o.is_synthetic,false) = false;

  -- 1. inquiry -> pack, in hours.
  return query
    select 'inquiry_to_pack_h'::text,
           round(avg(extract(epoch from (o.dispatch_ready_at - o.created_at)) / 3600.0)::numeric, 2),
           count(*)::int
      from public.orders o
     where o.fulfillment_partner_id = p_partner
       and o.order_date between v_from and v_to
       and coalesce(o.is_synthetic,false) = false
       and o.dispatch_ready_at is not null and o.created_at is not null
       and o.dispatch_ready_at >= o.created_at
    having count(*) > 0;

  -- 2. on-time dispatch %, against the dispatch SLA in partner_scorecard_config.
  return query
    select 'on_time_dispatch_pct'::text,
           round(100.0 * count(*) filter (
             where o.dispatch_ready_at <= o.created_at + make_interval(hours => cfg.dispatch_sla_hours::int))
                 / nullif(count(*),0)::numeric, 2),
           count(*)::int
      from public.orders o
     where o.fulfillment_partner_id = p_partner
       and o.order_date between v_from and v_to
       and coalesce(o.is_synthetic,false) = false
       and o.dispatch_ready_at is not null and o.created_at is not null
    having count(*) > 0;

  -- 3. count-dispute rate: ordered lines that raised a short / wrong-product
  --    dispute, over every ordered line in the month.
  if v_lines > 0 then
    return query
      select 'count_dispute_rate_pct'::text,
             round(100.0 * (
               select count(distinct d.order_item_id)
                 from public.supplier_disputes d
                 join public.order_items i2 on i2.id = d.order_item_id
                 join public.orders o2 on o2.id = i2.order_id
                where o2.fulfillment_partner_id = p_partner
                  and o2.order_date between v_from and v_to
                  and coalesce(o2.is_synthetic,false) = false
             )::numeric / v_lines::numeric, 2),
             v_lines;
  end if;

  -- 4. unfulfilled rate: lines no supplier in the zone could fulfil.
  if v_lines > 0 then
    return query
      select 'unfulfilled_rate_pct'::text,
             round(100.0 * (
               select coalesce(sum(coalesce(o3.unfulfilled_count,0)),0)
                 from public.orders o3
                where o3.fulfillment_partner_id = p_partner
                  and o3.order_date between v_from and v_to
                  and coalesce(o3.is_synthetic,false) = false
             )::numeric / v_lines::numeric, 2),
             v_lines;
  end if;

  -- 5. delivery SLA: handed over inside the promised window.
  return query
    select 'delivery_sla_pct'::text,
           round(100.0 * count(*) filter (where d.delivered_at <= d.promised_at)
                 / nullif(count(*),0)::numeric, 2),
           count(*)::int
      from public.deliveries d
      join public.orders o4 on o4.id = d.order_id
     where o4.fulfillment_partner_id = p_partner
       and o4.order_date between v_from and v_to
       and coalesce(o4.is_synthetic,false) = false
       and coalesce(d.is_synthetic,false) = false
       and d.delivered_at is not null and d.promised_at is not null
    having count(*) > 0;

  -- 6. settlement acknowledgement time, in hours, for statements that CLOSED
  --    inside the month.
  return query
    select 'settlement_ack_h'::text,
           round(avg(extract(epoch from (a.acked_at - p.closed_at)) / 3600.0)::numeric, 2),
           count(*)::int
      from public.partner_settlement_periods p
      join public.partner_settlement_ack a on a.period_id = p.id
     where p.partner_id = p_partner
       and p.closed_at is not null
       and (p.closed_at at time zone 'Asia/Kolkata')::date between v_from and v_to
       and a.acked_at >= p.closed_at
    having count(*) > 0;

  -- 7. exceptions closed inside the exception SLA, for the partner's zone.
  if v_zone is not null then
    return query
      select 'exception_sla_pct'::text,
             round(100.0 * count(*) filter (
               where e.closed_at <= coalesce(e.started_at, e.created_at)
                                    + make_interval(hours => cfg.exception_sla_hours::int))
                   / nullif(count(*),0)::numeric, 2),
             count(*)::int
        from public.exception_state e
       where e.zone_id = v_zone
         and e.closed_at is not null
         and (e.closed_at at time zone 'Asia/Kolkata')::date between v_from and v_to
      having count(*) > 0;
  end if;
end $fn$;

-- The score a value earns against its target: 0-100, direction-aware, and
-- capped so a runaway metric cannot buy back a failing one.
create or replace function public._partner_metric_score(
  p_direction text, p_value numeric, p_target numeric)
returns numeric language sql immutable as $fn$
  select case
    when p_value is null or p_target is null or p_target <= 0 then null
    when p_direction = 'lower_better' then
      case when p_value <= 0 then 100
           else round(least(100, 100 * p_target / p_value), 1) end
    else round(least(100, 100 * p_value / p_target), 1)
  end;
$fn$;

-- One formatted number, the ONLY place a scorecard value becomes text.
create or replace function public._partner_metric_label(
  p_value numeric, p_suffix text, p_decimals int)
returns text language sql immutable as $fn$
  select case when p_value is null then ''
              else to_char(round(p_value, greatest(coalesce(p_decimals,1),0)),
                           case when coalesce(p_decimals,1) <= 0 then 'FM9999999990'
                                else 'FM9999999990.' || repeat('0', coalesce(p_decimals,1)) end)
                   || coalesce(p_suffix,'') end;
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. SNAPSHOT — the month's numbers, frozen. Re-running a month overwrites it,
--    so a correction to an order re-scores the month until the month is old.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_scorecard_snapshot(
  p_month date default null, p_partner bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_month date := date_trunc('month',
    coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  rp record; mv record; m public.partner_scorecard_metric%rowtype;
  v_target numeric; v_rows int := 0; v_partners int := 0;
begin
  for rp in select r.id from public.region_partners r
             where coalesce(r.is_active, true)
               and (p_partner is null or r.id = p_partner)
             order by r.id
  loop
    v_partners := v_partners + 1;
    for mv in select * from public._partner_metric_values(rp.id, v_month) loop
      select * into m from public.partner_scorecard_metric where slug = mv.metric;
      if m.slug is null then continue; end if;
      select t.target into v_target from public.partner_metric_target t
       where t.partner_id = rp.id and t.month = v_month and t.metric = mv.metric;
      v_target := coalesce(v_target, m.default_target);

      insert into public.partner_scorecard_month
        (partner_id, month, metric, value, sample_n, target, score, computed_at)
      values (rp.id, v_month, mv.metric, mv.value, coalesce(mv.sample_n,0), v_target,
              public._partner_metric_score(m.direction, mv.value, v_target), now())
      on conflict (partner_id, month, metric) do update set
        value = excluded.value, sample_n = excluded.sample_n,
        target = excluded.target, score = excluded.score, computed_at = now();
      v_rows := v_rows + 1;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'month', v_month,
    'partners', v_partners, 'rows', v_rows);
end $fn$;

-- The backend itself (service_role, i.e. the cron dispatcher and the runner)
-- is an operator; this is the same escape incentive_evaluate_day already uses.
create or replace function public._c693_operator()
returns text language sql stable security definer set search_path to 'public' as $fn$
  select case
    when public.role_for_medibo_only() in ('admin','super_admin')
      then public.role_for_medibo_only()
    when coalesce(current_setting('request.jwt.claim.role', true),'') = 'service_role'
      then 'super_admin'
    else '' end;
$fn$;
grant execute on function public._c693_operator() to authenticated, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE PARTNER'S OWN CARD. Live numbers, not the snapshot: a partner looking
--    at the month in progress must see today's position, and the snapshot only
--    exists to keep a CLOSED month honest.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_scorecard(
  p_partner bigint default null, p_month date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_partner bigint;
  v_month  date := date_trunc('month',
    coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  v_role   text := public._c693_operator();
  rp       public.region_partners%rowtype;
  m        public.partner_scorecard_metric%rowtype;
  v_val    numeric; v_n int; v_target numeric; v_score numeric; v_vals jsonb;
  v_rows   jsonb := '[]'::jsonb; v_sum numeric := 0; v_cnt int := 0;
  v_overall numeric; v_bonus jsonb := '[]'::jsonb; v_bonus_total numeric := 0;
  s        record;
begin
  v_partner := coalesce(p_partner, public.my_partner_id());
  if v_role not in ('admin','super_admin') then
    -- A partner only ever sees its own card, whatever it asks for.
    v_partner := public.my_partner_id();
  end if;
  if v_partner is null then
    return jsonb_build_object('ok', false, 'error', 'no_partner',
      'message', public._c('pscore.no_partner'));
  end if;
  select * into rp from public.region_partners where id = v_partner;
  if rp.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_partner',
      'message', public._c('pscore.no_partner'));
  end if;

  -- ONE pass over the measurement, not one per metric: the 1 GB instance pays
  -- for every extra scan and this RPC is on the partner's home screen.
  select coalesce(jsonb_object_agg(v.metric,
           jsonb_build_object('value', v.value, 'n', v.sample_n)), '{}'::jsonb)
    into v_vals from public._partner_metric_values(v_partner, v_month) v;

  for m in select * from public.partner_scorecard_metric where active order by sort_order, slug
  loop
    v_val := nullif(v_vals #>> array[m.slug,'value'], '')::numeric;
    v_n   := coalesce(nullif(v_vals #>> array[m.slug,'n'], '')::int, 0);

    select t.target into v_target from public.partner_metric_target t
     where t.partner_id = v_partner and t.month = v_month and t.metric = m.slug;
    v_target := coalesce(v_target, m.default_target);
    v_score  := public._partner_metric_score(m.direction, v_val, v_target);
    if v_score is not null then v_sum := v_sum + v_score; v_cnt := v_cnt + 1; end if;

    v_rows := v_rows || jsonb_build_object(
      'slug',          m.slug,
      'label',         m.label,
      'hint',          m.hint,
      'direction',     m.direction,
      'has_value',     v_val is not null,
      'value',         v_val,
      'value_label',   public._partner_metric_label(v_val, m.value_suffix, m.decimals),
      'no_value_label',public._c('pscore.no_data'),
      'sample_label',  public._cf('pscore.sample', jsonb_build_object('n', coalesce(v_n,0)::text)),
      'has_target',    v_target is not null and v_target > 0,
      'target',        v_target,
      'target_label',  public._partner_metric_label(v_target, m.value_suffix, m.decimals),
      'target_caption',public._c('pscore.target_caption'),
      'progress',      case when v_score is null then 0 else round(v_score / 100.0, 4) end,
      'progress_label',case when v_score is null then public._c('pscore.no_data')
                            else public._partner_metric_label(v_score, '%', 0) end,
      'met',           coalesce(v_score, 0) >= 100,
      'status_label',  case when v_score is null then public._c('pscore.no_data')
                            when v_score >= 100 then public._c('pscore.on_target')
                            when v_score >= 80  then public._c('pscore.near_target')
                            else public._c('pscore.off_target') end,
      'tone',          case when v_score is null then 'muted'
                            when v_score >= 100 then 'success'
                            when v_score >= 80  then 'warning'
                            else 'danger' end);
  end loop;

  v_overall := case when v_cnt = 0 then null else round(v_sum / v_cnt, 1) end;

  -- The month's partner-scope schemes, and whether the partner has earned them.
  for s in
    select sc.*, e.amount as earned_amount, e.period_id
      from public.incentive_schemes sc
      left join public.partner_incentive_earning e
             on e.scheme_id = sc.id and e.partner_id = v_partner and e.month = v_month
     where sc.scope = 'partner'
       and (sc.region_partner_id is null or sc.region_partner_id = v_partner)
       and (sc.window_start is null or sc.window_start <= (v_month + interval '1 month - 1 day')::date)
       and (sc.window_end   is null or sc.window_end   >= v_month)
     order by sc.sort_order, sc.label
  loop
    select * into m from public.partner_scorecard_metric where slug = s.metric;
    if s.earned_amount is not null then v_bonus_total := v_bonus_total + s.earned_amount; end if;
    v_bonus := v_bonus || jsonb_build_object(
      'scheme_id',      s.id,
      'label',          s.label,
      'metric_label',   coalesce(m.label, s.metric),
      'threshold_label',public._partner_metric_label(s.threshold, coalesce(m.value_suffix,''), coalesce(m.decimals,1)),
      'bonus_label',    public.inr_money(s.bonus_amount),
      'achieved',       s.earned_amount is not null,
      'status_label',   case when s.earned_amount is null then public._c('pscore.bonus_open')
                             when s.period_id is null    then public._c('pscore.bonus_earned')
                             else public._c('pscore.bonus_settled') end,
      'tone',           case when s.earned_amount is null then 'muted'
                             when s.period_id is null    then 'success'
                             else 'info' end,
      'active',         s.active);
  end loop;

  return jsonb_build_object('ok', true,
    'partner_id',     v_partner,
    'partner_label',  rp.partner_name,
    'zone_label',     coalesce((select z.name from public.zones z where z.id = rp.zone_id), ''),
    'month',          v_month,
    'month_label',    to_char(v_month, 'FMMonth YYYY'),
    'heading',        public._c('pscore.heading'),
    'subtitle',       public._c('pscore.subtitle'),
    'metrics_heading',public._c('pscore.metrics_heading'),
    'bonus_heading',  public._c('pscore.bonus_heading'),
    'has_score',      v_overall is not null,
    'score',          v_overall,
    'score_label',    coalesce(public._partner_metric_label(v_overall, '', 0), ''),
    -- A partner with nothing to score yet says so where its score would be;
    -- a blank cell on a ranking reads as a zero, which is a different claim.
    'no_score_label', public._c('pscore.no_data'),
    'score_caption',  public._c('pscore.score_caption'),
    'score_tone',     case when v_overall is null then 'muted'
                           when v_overall >= 95 then 'success'
                           when v_overall >= 80 then 'warning'
                           else 'danger' end,
    'metrics',        v_rows,
    'bonuses',        v_bonus,
    'has_bonus',      jsonb_array_length(v_bonus) > 0,
    'bonus_total_label', public.inr_money(v_bonus_total),
    'bonus_total_caption', public._c('pscore.bonus_total_caption'),
    'settlement_note',public._c('pscore.settlement_note'),
    'empty_label',    public._c('pscore.empty'));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE ADMIN "Partners" TAB — every partner, ranked, one row each.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_partner_scorecards(p_month date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_month date := date_trunc('month',
    coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  rp record; card jsonb; v_rows jsonb := '[]'::jsonb; v_i int := 0;
  v_months jsonb := '[]'::jsonb; v_d date;
begin
  if public._c693_operator() = '' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._c('pscore.not_authorized'));
  end if;

  for v_d in
    select (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
            - make_interval(months => g))::date
      from generate_series(0, 11) g
  loop
    v_months := v_months || jsonb_build_object(
      'month', v_d, 'label', to_char(v_d, 'FMMonth YYYY'), 'selected', v_d = v_month);
  end loop;

  for rp in
    select r.id, r.partner_name
      from public.region_partners r
     where coalesce(r.is_active, true)
     order by r.id
  loop
    -- The row IS the card. Expanding a partner on this screen must show the
    -- partner their own card verbatim, so nothing is re-derived here.
    card := public.partner_scorecard(rp.id, v_month);
    if coalesce((card->>'ok')::boolean, false) then
      v_rows := v_rows || card;
    end if;
  end loop;

  -- Rank: highest overall score first, an unscored partner last, both stated
  -- by the BACKEND so two surfaces can never order the same month differently.
  select coalesce(jsonb_agg(x.row || jsonb_build_object(
             'rank', x.rn,
             'rank_label', case when coalesce((x.row->>'has_score')::boolean,false)
                                then '#' || x.rn::text else '' end)
           order by x.rn), '[]'::jsonb)
    into v_rows
    from (
      select r as row,
             row_number() over (
               order by coalesce((r->>'has_score')::boolean,false) desc,
                        coalesce((r->>'score')::numeric, -1) desc,
                        r->>'partner_label') as rn
        from jsonb_array_elements(v_rows) r
    ) x;
  v_i := jsonb_array_length(v_rows);

  return jsonb_build_object('ok', true,
    'title',        public._c('pscore.admin_title'),
    'subtitle',     public._c('pscore.admin_subtitle'),
    'month',        v_month,
    'month_label',  to_char(v_month, 'FMMonth YYYY'),
    'months',       v_months,
    'columns',      coalesce((select jsonb_agg(jsonb_build_object(
                        'slug', m.slug, 'label', m.label) order by m.sort_order)
                      from public.partner_scorecard_metric m where m.active), '[]'::jsonb),
    'rows',         v_rows,
    'count',        v_i,
    'count_label',  public._cf('pscore.admin_count', jsonb_build_object('n', v_i::text)),
    'targets_label',public._c('pscore.targets_btn'),
    'save_label',   public._c('pscore.save_btn'),
    'empty_label',  public._c('pscore.admin_empty'));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. TARGETS — the editor payload and its writer. Super admin only: a target
--     is what the partner is paid against, so it is not an admin-wide edit.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_targets_get(
  p_partner bigint, p_month date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_month date := date_trunc('month',
    coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  v_rows jsonb;
begin
  if public._c693_operator() = '' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._c('pscore.not_authorized'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', m.slug, 'label', m.label, 'hint', m.hint,
           'suffix', m.value_suffix, 'direction', m.direction,
           'direction_label', case when m.direction = 'lower_better'
                                   then public._c('pscore.dir_lower')
                                   else public._c('pscore.dir_higher') end,
           'default_target', m.default_target,
           'value', coalesce(t.target, m.default_target),
           'value_label', public._partner_metric_label(
                            coalesce(t.target, m.default_target), m.value_suffix, m.decimals),
           'is_default', t.target is null)
         order by m.sort_order), '[]'::jsonb)
    into v_rows
    from public.partner_scorecard_metric m
    left join public.partner_metric_target t
           on t.metric = m.slug and t.partner_id = p_partner and t.month = v_month
   where m.active;

  return jsonb_build_object('ok', true,
    'partner_id', p_partner,
    'partner_label', coalesce((select r.partner_name from public.region_partners r where r.id = p_partner), ''),
    'month', v_month, 'month_label', to_char(v_month, 'FMMonth YYYY'),
    'title', public._c('pscore.targets_title'),
    'hint',  public._c('pscore.targets_hint'),
    'save_label', public._c('pscore.save_btn'),
    'can_edit', public._c693_operator() = 'super_admin',
    'readonly_note', public._c('pscore.targets_readonly'),
    'rows', v_rows);
end $fn$;

create or replace function public.partner_targets_set(
  p_partner bigint, p_month date, p_targets jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_month date := date_trunc('month',
    coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  k text; v numeric; v_n int := 0;
begin
  if public._c693_operator() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._c('pscore.targets_readonly'));
  end if;
  if not exists (select 1 from public.region_partners where id = p_partner) then
    return jsonb_build_object('ok', false, 'error', 'no_partner',
      'message', public._c('pscore.no_partner'));
  end if;

  for k in select jsonb_object_keys(coalesce(p_targets, '{}'::jsonb)) loop
    if not exists (select 1 from public.partner_scorecard_metric where slug = k) then
      continue;
    end if;
    v := nullif(p_targets->>k, '')::numeric;
    if v is null then
      delete from public.partner_metric_target
       where partner_id = p_partner and month = v_month and metric = k;
    else
      insert into public.partner_metric_target
        (partner_id, month, metric, target, updated_at, updated_by)
      values (p_partner, v_month, k, v, now(), coalesce(auth.jwt() ->> 'email','admin'))
      on conflict (partner_id, month, metric) do update set
        target = excluded.target, updated_at = now(), updated_by = excluded.updated_by;
    end if;
    v_n := v_n + 1;
  end loop;

  perform public.partner_scorecard_snapshot(v_month, p_partner);
  return jsonb_build_object('ok', true, 'saved', v_n,
    'message', public._c('pscore.targets_saved'));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. INCENTIVES — partner scope, evaluated on the MONTH the scored day sits in.
--     incentive_evaluate_day() keeps its rider pass untouched and gains a
--     partner pass, so the nightly cron that already runs it pays both sides.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_incentive_evaluate_month(
  p_month date default null, p_partner bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_month date := date_trunc('month',
    coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  rp record; s record; m public.partner_scorecard_metric%rowtype;
  v_val numeric; v_hit int := 0; v_miss int := 0; v_amount numeric := 0; v_n int := 0;
  v_met boolean; v_vals jsonb;
begin
  for rp in select r.id from public.region_partners r
             where coalesce(r.is_active, true)
               and (p_partner is null or r.id = p_partner)
             order by r.id
  loop
    v_n := v_n + 1;
    select coalesce(jsonb_object_agg(v.metric,
             jsonb_build_object('value', v.value, 'n', v.sample_n)), '{}'::jsonb)
      into v_vals from public._partner_metric_values(rp.id, v_month) v;
    for s in
      select * from public.incentive_schemes sc
       where sc.active and sc.scope = 'partner'
         and (sc.region_partner_id is null or sc.region_partner_id = rp.id)
         and (sc.window_start is null or sc.window_start <= (v_month + interval '1 month - 1 day')::date)
         and (sc.window_end   is null or sc.window_end   >= v_month)
       order by sc.sort_order, sc.label
    loop
      select * into m from public.partner_scorecard_metric where slug = s.metric;
      if m.slug is null then continue; end if;

      v_val := nullif(v_vals #>> array[s.metric,'value'], '')::numeric;
      if v_val is null then continue; end if;

      -- A "lower is better" metric is met by coming in UNDER the threshold.
      v_met := case when m.direction = 'lower_better'
                    then v_val <= s.threshold
                    else v_val >= s.threshold and s.threshold > 0 end;

      if v_met then
        insert into public.partner_incentive_earning
          (scheme_id, partner_id, month, metric, metric_value, threshold, amount)
        values (s.id, rp.id, v_month, s.metric, v_val, s.threshold, s.bonus_amount)
        on conflict (scheme_id, partner_id, month) do update set
          metric_value = excluded.metric_value,
          threshold    = excluded.threshold,
          amount       = excluded.amount
          where public.partner_incentive_earning.period_id is null;
        v_hit := v_hit + 1;
        v_amount := v_amount + s.bonus_amount;
      else
        -- The month slipped back below target on a re-run. An earning already
        -- carried into a settlement is never withdrawn.
        delete from public.partner_incentive_earning e
         where e.scheme_id = s.id and e.partner_id = rp.id and e.month = v_month
           and e.period_id is null;
        v_miss := v_miss + 1;
      end if;
    end loop;

    perform public.partner_bonus_attach(rp.id);
  end loop;

  return jsonb_build_object('ok', true, 'month', v_month, 'partners', v_n,
    'earned', v_hit, 'missed', v_miss, 'amount', v_amount,
    'amount_label', public.inr_money(v_amount));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. THE BONUS REACHES THE MONEY. An earned bonus attaches to the EARLIEST
--     statement of that partner which is still open and which ends on or after
--     the scored month — the first statement that can still carry it. Until one
--     exists the earning simply stays unattached and the card says so.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_bonus_attach(p_partner bigint)
returns integer language plpgsql security definer set search_path to 'public' as $fn$
declare e record; v_period bigint; v_n int := 0;
begin
  for e in select * from public.partner_incentive_earning
            where partner_id = p_partner and period_id is null
            order by month, id
  loop
    select p.id into v_period
      from public.partner_settlement_periods p
     where p.partner_id = p_partner
       and p.status <> 'settled'
       and p.period_end >= (e.month + interval '1 month - 1 day')::date
     order by p.period_start, p.id
     limit 1;
    if v_period is null then continue; end if;
    update public.partner_incentive_earning set period_id = v_period where id = e.id;
    perform public.settlement_period_totals(v_period);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $fn$;

-- settlement_period_totals gains ONE line: the bonus the partner earned.
-- A bonus is money mediBO pays the partner ON TOP of its share, so it is added
-- to net_due and taken off mediBO's side. It is deliberately NOT a cost line:
-- order costs are deducted before the split, so booking a bonus there would
-- have REDUCED the partner's own payout — the opposite of an incentive.
create or replace function public.settlement_period_totals(p_period_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare
  p public.partner_settlement_periods%rowtype;
  t record;
  v_share numeric;
  v_net   numeric;
  v_bonus numeric;
begin
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found or p.status = 'settled' then return; end if;

  select count(*) n,
         coalesce(sum(revenue),0)      rev,
         coalesce(sum(goods_cost),0)   goods,
         coalesce(sum(gross_margin),0) gross,
         coalesce(sum(cost_total),0)   costs
    into t
    from public.partner_settlements where period_id = p_period_id;

  select coalesce(sum(amount),0) into v_bonus
    from public.partner_incentive_earning where period_id = p_period_id;

  v_share := round((t.gross - t.costs) * p.split_pct / 100, 2);
  v_net   := round(v_share + v_bonus + coalesce(p.brought_forward, 0), 2);

  update public.partner_settlement_periods set
    orders_count  = t.n,
    revenue       = t.rev,
    goods_cost    = t.goods,
    gross_margin  = t.gross,
    cost_total    = t.costs,
    distributable = round(t.gross - t.costs, 2),
    partner_share = v_share,
    bonus_total   = v_bonus,
    medibo_share  = round((t.gross - t.costs) - v_share - v_bonus, 2),
    net_due       = v_net,
    -- A period under water transfers NOTHING and hands the shortfall on. The
    -- partner is never asked to pay money back.
    payable       = greatest(v_net, 0),
    carry_forward = least(v_net, 0),
    computed_at   = now()
  where id = p_period_id;
end $fn$;

-- The rider pass keeps its own shape; the partner pass rides the same nightly
-- call so no new cron row is needed for the payout side.
create or replace function public.incentive_evaluate_day(
  p_date date default null, p_partner uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  r record; s record; v_val numeric; v_hit int := 0; v_miss int := 0;
  v_amount numeric := 0; v_riders int := 0; v_partner jsonb := '{}'::jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin')
     and current_setting('request.jwt.claim.role', true) is distinct from 'service_role'
     and auth.uid() is not null then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  for r in select id from public.delivery_partner_registrations
            where is_active and coalesce(is_deleted,false) = false
              and (p_partner is null or id = p_partner)
  loop
    v_riders := v_riders + 1;
    for s in select * from public.incentive_schemes_for(r.id, v_date) loop
      v_val := public._incentive_metric_value(r.id, v_date, s.metric);
      if v_val is null then continue; end if;

      if v_val >= s.threshold and s.threshold > 0 then
        insert into public.incentive_earnings(
            scheme_id, partner_id, earn_date, metric, metric_value, threshold, amount)
        values (s.id, r.id, v_date, s.metric, v_val, s.threshold, s.bonus_amount)
        on conflict (scheme_id, partner_id, earn_date) do update
          set metric_value = excluded.metric_value,
              threshold    = excluded.threshold,
              amount       = excluded.amount
          where public.incentive_earnings.payout_period_id is null;
        v_hit := v_hit + 1;
        v_amount := v_amount + s.bonus_amount;
      else
        -- The rider fell back below the target on a re-run of the same day.
        delete from public.incentive_earnings e
         where e.scheme_id = s.id and e.partner_id = r.id and e.earn_date = v_date
           and e.payout_period_id is null;
        v_miss := v_miss + 1;
      end if;
    end loop;
  end loop;

  -- CHANGE #693 — the fulfilment partner's monthly schemes, scored on the month
  -- the day belongs to. Riders are scored daily; a partner metric is a monthly
  -- average, so re-running any day of the month re-scores that month.
  if p_partner is null then
    v_partner := public.partner_incentive_evaluate_month(v_date, null);
  end if;

  return jsonb_build_object('ok',true,'the_date',v_date,
    'riders',v_riders,'earned',v_hit,'missed',v_miss,
    'amount',v_amount,'amount_label', public.inr_money(v_amount),
    'partners', v_partner);
end $fn$;

-- The scheme editor learns the fourth scope and the partner it points at.
create or replace function public.incentive_scheme_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id uuid; cur public.incentive_schemes%rowtype; v_slug text; v_scope text; v_metric text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  v_id := nullif(p_patch->>'scheme_id','')::uuid;
  if v_id is not null then select * into cur from public.incentive_schemes where id = v_id; end if;

  v_slug := trim(both '_' from lower(regexp_replace(
              coalesce(nullif(p_patch->>'slug',''), cur.slug, p_patch->>'label',''),
              '[^a-zA-Z0-9]+','_','g')));
  if v_slug = '' or btrim(coalesce(p_patch->>'label', coalesce(cur.label,''))) = '' then
    return jsonb_build_object('ok',false,'error','label_required',
      'message', public._c('incentive.err_label'));
  end if;
  v_scope  := coalesce(nullif(p_patch->>'scope',''), cur.scope, 'all');
  if v_scope not in ('all','zone','agency','partner') then
    return jsonb_build_object('ok',false,'error','bad_scope',
      'message', public._c('incentive.err_scope'));
  end if;
  v_metric := coalesce(nullif(p_patch->>'metric',''), cur.metric, '');
  -- A partner scheme is scored on a partner metric and a rider scheme on a
  -- rider metric; the catalogue says which is which.
  if not exists (select 1 from public.incentive_metrics
                  where slug = v_metric and active
                    and scope = case when v_scope = 'partner' then 'partner' else 'delivery' end) then
    return jsonb_build_object('ok',false,'error','bad_metric',
      'message', public._c('incentive.err_metric'));
  end if;

  insert into public.incentive_schemes(id, slug, label, scope, zone_id, agency_id,
      region_partner_id, metric, threshold, bonus_amount, window_start, window_end,
      active, sort_order, note, updated_at, updated_by)
  values (coalesce(v_id, gen_random_uuid()), v_slug,
      coalesce(nullif(p_patch->>'label',''), cur.label), v_scope,
      case when v_scope = 'zone'   then nullif(p_patch->>'zone_id','')::smallint end,
      case when v_scope = 'agency' then nullif(p_patch->>'agency_id','')::uuid end,
      case when v_scope = 'partner' then nullif(p_patch->>'region_partner_id','')::bigint end,
      v_metric,
      coalesce(nullif(p_patch->>'threshold','')::numeric, cur.threshold, 0),
      coalesce(nullif(p_patch->>'bonus_amount','')::numeric, cur.bonus_amount, 0),
      coalesce(nullif(p_patch->>'window_start','')::date, cur.window_start),
      coalesce(nullif(p_patch->>'window_end','')::date, cur.window_end),
      coalesce((p_patch->>'active')::boolean, cur.active, false),
      coalesce(nullif(p_patch->>'sort_order','')::int, cur.sort_order, 100),
      coalesce(p_patch->>'note', cur.note),
      now(), coalesce(auth.jwt() ->> 'email','admin'))
  on conflict (id) do update set
    slug = excluded.slug, label = excluded.label, scope = excluded.scope,
    zone_id = excluded.zone_id, agency_id = excluded.agency_id,
    region_partner_id = excluded.region_partner_id, metric = excluded.metric,
    threshold = excluded.threshold, bonus_amount = excluded.bonus_amount,
    window_start = excluded.window_start, window_end = excluded.window_end,
    active = excluded.active, sort_order = excluded.sort_order, note = excluded.note,
    updated_at = now(), updated_by = excluded.updated_by
  returning id into v_id;

  return jsonb_build_object('ok',true,'scheme_id',v_id,'message', public._c('incentive.saved'));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. THE MONTHLY WHATSAPP LINE. It rides the evening digest that already goes
--     out, and only on the first of the month — the message a partner gets on
--     the 1st carries the month that just closed.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_scorecard_digest_line(
  p_partner bigint, p_date date default null)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_date  date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  v_month date;
  card jsonb; v_line text; v_metrics text := '';
  it jsonb;
begin
  if extract(day from v_date)::int <> 1 then return ''; end if;
  v_month := (date_trunc('month', v_date) - interval '1 month')::date;
  card := public.partner_scorecard(p_partner, v_month);
  if not coalesce((card->>'ok')::boolean,false)
     or not coalesce((card->>'has_score')::boolean,false) then
    return '';
  end if;

  for it in select value from jsonb_array_elements(card->'metrics') loop
    if coalesce((it->>'has_value')::boolean,false) then
      v_metrics := v_metrics || case when v_metrics = '' then '' else ', ' end
                 || (it->>'label') || ' ' || (it->>'value_label');
    end if;
  end loop;

  v_line := public._cf('pscore.digest_line', jsonb_build_object(
              'month',  card->>'month_label',
              'score',  card->>'score_label',
              'metrics', v_metrics,
              'bonus',  card->>'bonus_total_label'));
  return coalesce(v_line, '');
end $fn$;

-- The rider incentive editor must not offer partner metrics: one catalogue,
-- two sides, and `scope` is what keeps them apart.
create or replace function public.admin_incentive_schemes()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb; v_metrics jsonb; v_zones jsonb; v_agencies jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', m.slug, 'label', m.label, 'value_suffix', m.value_suffix,
           'target_hint', m.target_hint) order by m.sort_order), '[]'::jsonb)
    into v_metrics from public.incentive_metrics m
   where m.active and m.scope = 'delivery';

  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name) order by z.id), '[]'::jsonb)
    into v_zones from public.zones z;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'label', coalesce(r.full_name,''))
           order by r.full_name), '[]'::jsonb)
    into v_agencies from public.delivery_partner_registrations r
   where r.partner_type = 'agency' and coalesce(r.is_deleted,false) = false;

  select coalesce(jsonb_agg(jsonb_build_object(
           'scheme_id', s.id, 'slug', s.slug, 'label', s.label,
           'scope', s.scope,
           'scope_label', case s.scope
             when 'zone'   then public._cf('incentive.scope_zone',
                                  jsonb_build_object('zone', coalesce((select z.name from public.zones z where z.id = s.zone_id),'')))
             when 'agency' then public._cf('incentive.scope_agency',
                                  jsonb_build_object('agency', coalesce((select r2.full_name from public.delivery_partner_registrations r2 where r2.id = s.agency_id),'')))
             else public._c('incentive.scope_all') end,
           'zone_id', s.zone_id, 'agency_id', s.agency_id,
           'metric', s.metric,
           'metric_label', coalesce((select m.label from public.incentive_metrics m where m.slug = s.metric), s.metric),
           'target_label', trim_scale(s.threshold)::text
                           || coalesce((select m.value_suffix from public.incentive_metrics m where m.slug = s.metric),''),
           'threshold', s.threshold,
           'bonus', s.bonus_amount,
           'bonus_label', public.inr_money(s.bonus_amount),
           'bonus_caption', public._c('incentive.bonus_caption'),
           'paid_caption',  public._c('incentive.paid_caption'),
           'window_label', case when s.window_start is null and s.window_end is null
                                then public._c('incentive.window_always')
                                else coalesce(to_char(s.window_start,'DD Mon YYYY'), '…')
                                     || ' – ' || coalesce(to_char(s.window_end,'DD Mon YYYY'), '…') end,
           'window_start', s.window_start, 'window_end', s.window_end,
           'active', s.active,
           'status_label', case when s.active then public._c('incentive.on') else public._c('incentive.off') end,
           'tone', case when s.active then 'success' else 'muted' end,
           'toggle_label', case when s.active then public._c('incentive.turn_off')
                                else public._c('incentive.turn_on') end,
           'toggle_tone',  case when s.active then 'muted' else 'success' end,
           'paid_label', public.inr_money(coalesce((select sum(e.amount) from public.incentive_earnings e where e.scheme_id = s.id),0)),
           'note', coalesce(s.note,''))
           order by s.sort_order, s.label), '[]'::jsonb)
    into v_rows from public.incentive_schemes s
   where s.scope <> 'partner';

  return jsonb_build_object('ok',true,
    'title', public._c('incentive.admin_title'),
    'empty_note', public._c('incentive.admin_empty'),
    'add_label', public._c('incentive.add_btn'),
    'save_label', public._c('incentive.save_btn'),
    'run_label', public._c('incentive.run_btn'),
    'scope_options', jsonb_build_array(
      jsonb_build_object('slug','all',   'label', public._c('incentive.scope_all')),
      jsonb_build_object('slug','zone',  'label', public._c('incentive.scope_zone_opt')),
      jsonb_build_object('slug','agency','label', public._c('incentive.scope_agency_opt'))),
    'metrics', v_metrics, 'zones', v_zones, 'agencies', v_agencies, 'rows', v_rows);
end $fn$;

-- The partner-side scheme list, for the Partners scorecard screen.
create or replace function public.partner_incentive_schemes()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb; v_metrics jsonb; v_partners jsonb;
begin
  if public._c693_operator() = '' then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public._c('pscore.not_authorized'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', m.slug, 'label', m.label, 'suffix', m.value_suffix,
           'direction', m.direction,
           'direction_label', case when m.direction = 'lower_better'
                                   then public._c('pscore.dir_lower')
                                   else public._c('pscore.dir_higher') end,
           'default_target', m.default_target) order by m.sort_order), '[]'::jsonb)
    into v_metrics from public.partner_scorecard_metric m where m.active;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'label', r.partner_name)
           order by r.id), '[]'::jsonb)
    into v_partners from public.region_partners r where coalesce(r.is_active,true);

  select coalesce(jsonb_agg(jsonb_build_object(
           'scheme_id', s.id, 'label', s.label,
           'metric', s.metric,
           'metric_label', coalesce((select m.label from public.partner_scorecard_metric m where m.slug = s.metric), s.metric),
           'scope_label', coalesce((select r.partner_name from public.region_partners r where r.id = s.region_partner_id),
                                   public._c('pscore.scheme_all_partners')),
           'region_partner_id', s.region_partner_id,
           'threshold', s.threshold,
           'threshold_label', public._partner_metric_label(s.threshold,
              coalesce((select m.value_suffix from public.partner_scorecard_metric m where m.slug = s.metric),''),
              coalesce((select m.decimals from public.partner_scorecard_metric m where m.slug = s.metric),1)),
           'bonus', s.bonus_amount,
           'bonus_label', public.inr_money(s.bonus_amount),
           'active', s.active,
           'status_label', case when s.active then public._c('incentive.on') else public._c('incentive.off') end,
           'tone', case when s.active then 'success' else 'muted' end,
           'paid_label', public.inr_money(coalesce(
              (select sum(e.amount) from public.partner_incentive_earning e where e.scheme_id = s.id),0)),
           'paid_caption', public._c('incentive.paid_caption'))
           order by s.sort_order, s.label), '[]'::jsonb)
    into v_rows from public.incentive_schemes s where s.scope = 'partner';

  return jsonb_build_object('ok', true,
    'title', public._c('pscore.schemes_title'),
    'hint',  public._c('pscore.schemes_hint'),
    'add_label', public._c('incentive.add_btn'),
    'save_label', public._c('pscore.save_btn'),
    'run_label', public._c('incentive.run_btn'),
    'empty_label', public._c('pscore.schemes_empty'),
    'all_partners_label', public._c('pscore.scheme_all_partners'),
    'metrics', v_metrics, 'partners', v_partners, 'rows', v_rows);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. The evening digest carries the monthly line on the 1st.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_daily_digest(
  p_date date default null, p_partner bigint default null, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  v_copy jsonb := coalesce((select value from app_settings where key='partner_digest_copy'),'{}'::jsonb);
  rp record; d jsonb; v_body text; v_res jsonb; v_exc text; v_score text;
  v_sent int := 0; v_skipped int := 0; v_out jsonb := '[]'::jsonb;
begin
  for rp in
    select r.id, r.zone_id from region_partners r
     where coalesce(r.is_active,true)
       and (p_partner is null or r.id = p_partner)
       and r.zone_id is not null
     order by r.id
  loop
    if not p_force and exists (select 1 from partner_digest_log l
                                where l.partner_id = rp.id and l.digest_date = v_date) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    d := public.partner_digest_data(rp.id, v_date);

    if coalesce((d->>'has_any')::boolean,false) then
      v_body := public.notif_render(coalesce(v_copy->>'line',''), jsonb_build_object(
                  'received',  (d->>'orders_received'),
                  'delivered', (d->>'orders_delivered'),
                  'collected', (d->>'collected_display')))
                || E'\n'
                || case when coalesce((d->>'has_share')::boolean,false)
                        then public.notif_render(coalesce(v_copy->>'share',''),
                               jsonb_build_object('share', d->>'share_display'))
                        else coalesce(v_copy->>'share_pending','') end;
    else
      v_body := coalesce(v_copy->>'empty','');
    end if;

    -- CHANGE #690 — the same evening message now carries the zone's open
    -- exceptions, so a partner learns what is stuck without opening the app.
    v_exc := public.exception_digest_line(rp.zone_id::smallint);
    if coalesce(v_exc,'') <> '' then
      v_body := v_body || E'\n' || v_exc;
    end if;

    -- CHANGE #693 — on the 1st, the month that just closed and what it earned.
    v_score := public.partner_scorecard_digest_line(rp.id, v_date);
    if coalesce(v_score,'') <> '' then
      v_body := v_body || E'\n' || v_score;
    end if;

    begin
      v_res := public.notify_partner('partner_daily_digest', jsonb_build_object(
                 'partner_id', rp.id::text,
                 'zone_id',    coalesce(rp.zone_id,0)::text,
                 'zone',       coalesce(d->>'zone_label',''),
                 'received',   (d->>'orders_received'),
                 'delivered',  (d->>'orders_delivered'),
                 'collected',  (d->>'collected_display'),
                 'share',      case when coalesce((d->>'has_share')::boolean,false)
                                    then (d->>'share_display')
                                    else coalesce(v_copy->>'share_pending','') end,
                 'exceptions', coalesce(v_exc,''),
                 'scorecard',  coalesce(v_score,''),
                 'summary',    v_body));
    exception when others then
      v_res := jsonb_build_object('ok', false, 'reason','send_exception', 'message', sqlerrm);
    end;

    insert into partner_digest_log
      (partner_id, zone_id, digest_date, orders_received, orders_delivered,
       collected, partner_share, body, send_result)
    values (rp.id, rp.zone_id, v_date,
            (d->>'orders_received')::int, (d->>'orders_delivered')::int,
            (d->>'collected')::numeric, (d->>'partner_share')::numeric,
            v_body, coalesce(v_res,'{}'::jsonb))
    on conflict (partner_id, digest_date) do update
      set orders_received = excluded.orders_received,
          orders_delivered = excluded.orders_delivered,
          collected = excluded.collected,
          partner_share = excluded.partner_share,
          body = excluded.body,
          send_result = excluded.send_result;

    v_sent := v_sent + 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
               'partner_id', rp.id, 'zone_id', rp.zone_id,
               'body', v_body, 'send', v_res));
  end loop;

  return jsonb_build_object('ok', true, 'the_date', v_date,
    'sent', v_sent, 'skipped_already_sent', v_skipped, 'digests', v_out);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. COPY. Every word the two screens print starts here.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('pscore.heading',        to_jsonb('Your scorecard'::text)),
  ('pscore.subtitle',       to_jsonb('Measured from your own fulfilment data. Updated through the month.'::text)),
  ('pscore.metrics_heading',to_jsonb('This month'::text)),
  ('pscore.bonus_heading',  to_jsonb('Incentives'::text)),
  ('pscore.score_caption',  to_jsonb('Overall score against target'::text)),
  ('pscore.target_caption', to_jsonb('Target'::text)),
  ('pscore.no_data',        to_jsonb('No data yet'::text)),
  ('pscore.sample',         to_jsonb('{n} measured'::text)),
  ('pscore.on_target',      to_jsonb('On target'::text)),
  ('pscore.near_target',    to_jsonb('Close'::text)),
  ('pscore.off_target',     to_jsonb('Below target'::text)),
  ('pscore.no_partner',     to_jsonb('This login is not linked to a fulfilment partner.'::text)),
  ('pscore.not_authorized', to_jsonb('This screen is for mediBO operators.'::text)),
  ('pscore.empty',          to_jsonb('Nothing to score for this month yet.'::text)),
  ('pscore.bonus_open',     to_jsonb('Not earned yet'::text)),
  ('pscore.bonus_earned',   to_jsonb('Earned'::text)),
  ('pscore.bonus_settled',  to_jsonb('Paid in a statement'::text)),
  ('pscore.bonus_total_caption', to_jsonb('Earned this month'::text)),
  ('pscore.settlement_note',to_jsonb('An earned bonus is added to your next open statement automatically.'::text)),
  ('pscore.admin_title',    to_jsonb('Partner scorecards'::text)),
  ('pscore.admin_subtitle', to_jsonb('Every fulfilment partner, ranked on the month.'::text)),
  ('pscore.admin_count',    to_jsonb('{n} partners'::text)),
  ('pscore.admin_empty',    to_jsonb('No active fulfilment partners.'::text)),
  ('pscore.targets_btn',    to_jsonb('Targets'::text)),
  ('pscore.save_btn',       to_jsonb('Save'::text)),
  ('pscore.targets_title',  to_jsonb('Monthly targets'::text)),
  ('pscore.targets_hint',   to_jsonb('Leave a field empty to fall back to the platform default.'::text)),
  ('pscore.targets_saved',  to_jsonb('Targets saved.'::text)),
  ('pscore.targets_readonly', to_jsonb('Only a super admin can change targets.'::text)),
  ('pscore.dir_lower',      to_jsonb('Lower is better'::text)),
  ('pscore.dir_higher',     to_jsonb('Higher is better'::text)),
  ('pscore.schemes_title',  to_jsonb('Partner incentives'::text)),
  ('pscore.schemes_hint',   to_jsonb('A bonus is paid once for the month the partner clears the threshold.'::text)),
  ('pscore.schemes_empty',  to_jsonb('No partner incentive schemes yet.'::text)),
  ('pscore.scheme_all_partners', to_jsonb('All partners'::text)),
  ('pscore.digest_line',    to_jsonb('Scorecard {month}: score {score}. {metrics}. Incentive earned {bonus}.'::text)),
  ('pscore.settlement_line',to_jsonb('Incentive bonus'::text)),
  ('pscore.load_failed',    to_jsonb('Could not load the scorecard.'::text)),
  ('pscore.retry',          to_jsonb('Try again'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 16. The statement grows one tile: the bonus. Everything else in this
--     definition is the live function verbatim.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.settlement_statement(p_period_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'books', 'public'
AS $function$
declare
  p public.partner_settlement_periods%rowtype;
  cfg public.settlement_config%rowtype;
  v_paid numeric; v_pending numeric;
  v_admin boolean := public.is_admin();
  v_ack jsonb; v_frozen boolean;
begin
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;
  if not v_admin and p.partner_id is distinct from public.my_partner_id() then
    return jsonb_build_object('ok', false, 'message', public._stl_c('ui.partner_denied'));
  end if;
  select * into cfg from public.settlement_config where id = 1;

  select coalesce(sum(amount) filter (where status = 'paid'), 0)
    into v_paid from public.partner_settlement_payments where period_id = p.id;
  v_pending := round(greatest(p.payable - v_paid, 0), 2);

  v_ack := public._stl_ack_block(p.id, v_admin);
  v_frozen := coalesce((v_ack->>'frozen')::boolean, false)
              and coalesce(cfg.route_mode,'manual') = 'automatic';

  return jsonb_build_object(
    'ok', true,
    'period_id', p.id,
    'title',    public._stl_c('ui.title'),
    'heading',  format(public._stl_c('period.window'),
                       public.ist_fmt(p.period_start::timestamptz, 'dmy'),
                       public.ist_fmt(p.period_end::timestamptz, 'dmy')),
    'sub',      public._stl_c('cad.' || p.cadence) || ' · ' ||
                format(public._stl_c('period.due_on'),
                       public.ist_fmt(p.due_on::timestamptz, 'dmy')),
    'partner',  coalesce((select partner_name from public.region_partners where id = p.partner_id), ''),
    'status',       p.status,
    'status_label', public._stl_c('period.' || p.status),
    'status_tone',  public._stl_tone('period.' || p.status),
    'is_admin',     v_admin,
    'ack',          v_ack,
    'payout_frozen', v_frozen,
    'can_settle',   v_admin and p.status = 'due' and not v_frozen,
    'settle_label', public._stl_c('period.settle'),
    'record_label', public._stl_c('route.record'),
    'amount_label', public._stl_c('fld.amount'),
    'reference_label', public._stl_c('fld.reference'),
    'route_mode',   coalesce(cfg.route_mode,'manual'),
    'route_label',  public._stl_c('route.' || coalesce(cfg.route_mode,'manual')),
    'route_note',   public._stl_c('route.' || coalesce(cfg.route_mode,'manual') || '_note'),
    'negative',     p.payable = 0 and p.net_due < 0,
    'negative_text',public._stl_c('period.negative'),
    'tiles', jsonb_build_array(
      public._stl_money_tile('tile.revenue',       p.revenue),
      public._stl_money_tile('tile.goods',         p.goods_cost),
      public._stl_money_tile('tile.gross',         p.gross_margin),
      public._stl_money_tile('tile.costs',         p.cost_total),
      public._stl_money_tile('tile.distributable', p.distributable),
      public._stl_money_tile('tile.medibo',        p.medibo_share),
      public._stl_money_tile('tile.partner',       p.partner_share),
      -- CHANGE #693 — the incentive bonus the partner earned, on the
      -- statement that carries it. mediBO funds it, so it is added to the
      -- partner's due and taken off mediBO's share; it is NOT an order cost.
      public._stl_money_tile('tile.bonus',         p.bonus_total),
      public._stl_money_tile('tile.brought_forward', p.brought_forward),
      public._stl_money_tile('tile.due',           p.payable),
      public._stl_money_tile('tile.transferred',   v_paid),
      public._stl_money_tile('tile.pending',       v_pending),
      public._stl_money_tile('tile.carry_forward', p.carry_forward),
      public._stl_tile('tile.orders', p.orders_count::text)),
    -- CHANGE #400 fix: min()/sum() must be aggregated in an inner query before
    -- jsonb_agg wraps them. As written in #323 this raised "aggregate function
    -- calls cannot be nested" on EVERY call — invisible only because no
    -- settlement period existed yet.
    'costs', jsonb_build_object(
      'heading', public._stl_c('sec.cost_lines'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'label', g.label,
                 'sub',   public._stl_c('basis.' || g.basis),
                 'value', public.inr_money(g.amt))
               order by g.sort_order)
          from (select ct.label, ct.sort_order,
                       coalesce(min(oc.basis), ct.basis) as basis,
                       sum(coalesce(oc.override_amount, oc.computed_amount)) as amt
                  from public.order_costs oc
                  join public.cost_types ct on ct.slug = oc.cost_type
                 where oc.order_id in (select order_id from public.partner_settlements
                                        where period_id = p.id)
                 group by ct.slug, ct.label, ct.sort_order, ct.basis) g), '[]'::jsonb)),
    'orders', jsonb_build_object(
      'heading', public._stl_c('sec.orders'),
      'empty_text', public._stl_c('ui.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'order_id', s.order_id,
                 'label', coalesce(s.order_code, ''),
                 'sub', public.ist_fmt(s.order_date::timestamptz, 'dmy') || ' · ' ||
                        public._stl_c('tile.gross') || ' ' || public.inr_money(s.gross_margin) ||
                        ' · ' || public._stl_c('tile.costs') || ' ' || public.inr_money(s.cost_total),
                 'value', public.inr_money(s.distributable),
                 'value_tone', case when s.distributable < 0 then 'danger' end)
               order by s.order_date, s.order_code)
          from public.partner_settlements s where s.period_id = p.id), '[]'::jsonb)),
    'payments', jsonb_build_object(
      'heading', public._stl_c('sec.payments'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'label', public._stl_c('route.' || case when x.method = 'razorpay_route'
                                                         then 'automatic' else 'manual' end),
                 'sub', case when x.status = 'queued' then public._stl_c('route.queued')
                             else coalesce(nullif(x.rzp_transfer_id,''), nullif(x.reference,''), '') end ||
                        ' · ' || public.ist_fmt(x.paid_at, 'dmy'),
                 'value', public.inr_money(x.amount),
                 'value_tone', case when x.status = 'queued' then 'warning' else 'success' end)
               order by x.paid_at desc)
          from public.partner_settlement_payments x where x.period_id = p.id), '[]'::jsonb)),
    'footnote', public._stl_c('ui.footnote'));
end $function$;

insert into public.settlement_label(key, label, tone, sort_order)
values ('tile.bonus', 'Incentive bonus', 'success', 15)
on conflict (key) do update set label = excluded.label, tone = excluded.tone;

-- ─────────────────────────────────────────────────────────────────────────────
-- 17. THE DOORS. A screen nobody can reach does not exist (rule 11), and
--     rg_check fails a registry tile without a declared route.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, category, surface, roles_allowed,
   search_terms, description, deep_link)
values
  ('admin.partner_scorecards', 'Partner scorecards', 'Partners', 'rule',
   'partner_scorecards', 65, 'medibo', false, 'none', 'money', 'dashboard',
   array['admin','super_admin'],
   'partner scorecard score ranking target incentive bonus fulfilment',
   'Every fulfilment partner ranked on the month, with monthly targets and partner incentive schemes.',
   '/admin/partner-scorecards'),
  ('partner.scorecard', 'My scorecard', 'Partner', 'rule',
   'partner_scorecard', 66, 'partner', true, 'read', 'money', 'dashboard',
   array['admin','super_admin'],
   'scorecard score target incentive bonus',
   'The partner''s own monthly scorecard, targets and incentive progress.',
   '/partner/scorecard')
on conflict (feature_key) do update set
  label = excluded.label, group_label = excluded.group_label,
  icon_key = excluded.icon_key, route_key = excluded.route_key,
  category = excluded.category, surface = excluded.surface,
  owner = excluded.owner, partner_eligible = excluded.partner_eligible,
  default_access = excluded.default_access,
  roles_allowed = excluded.roles_allowed,
  search_terms = excluded.search_terms, description = excluded.description,
  deep_link = excluded.deep_link;
-- The two tiles stay DARK until the build that opens them is live. A registry
-- row is a promise of a door (CHANGE #570): activating it before the Dart route
-- ships is how a tile lands on "route unavailable". The activation is the last
-- step of this change, after verify_live.sh is green.
update public.feature_registry set is_active = false
 where feature_key in ('admin.partner_scorecards','partner.scorecard')
   and not exists (select 1 from public.app_settings
                    where key = 'c693_scorecard_tiles_live'
                      and value::text = 'true');

insert into public.surface_route(route_key, feature_key, kind, handled_by, note)
values
  ('partner_scorecards', 'admin.partner_scorecards', 'feature', 'home_shell',
   'CHANGE #693 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through its one `case _ when shellExtraRouteScreen(route) != null` lookup.'),
  ('partner_scorecard', 'partner.scorecard', 'feature', 'home_shell',
   'CHANGE #693 — same lookup; the partner sees its own card, admin sees the ranked list.')
on conflict (route_key, feature_key) do update set
  handled_by = excluded.handled_by, note = excluded.note, is_active = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 18. THE NIGHTLY SNAPSHOT. The payout side already rides
--     incentive_evaluate_yesterday (02:10 IST); this freezes the month's
--     numbers so a closed month cannot silently re-score later.
--     Offset schedule, never a bare */N — see the connection-exhaustion rule.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.cron_task(name, ord, mode, work_sql, run_at_ist, dml, enabled, note)
values ('partner_scorecard_snapshot', 260, 'poll',
        $$select public.partner_scorecard_snapshot(null, null),
                 public.partner_scorecard_snapshot(
                   (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
                    - interval '1 month')::date, null)$$,
        '02:25:00', true, true,
        'CHANGE #693 — freezes this month and the one before it into partner_scorecard_month.')
on conflict (name) do update set
  work_sql = excluded.work_sql, run_at_ist = excluded.run_at_ist,
  dml = excluded.dml, note = excluded.note, enabled = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 19. GRANTS. Read RPCs for anyone signed in; the writers gate on role inside.
-- ─────────────────────────────────────────────────────────────────────────────
grant execute on function public.partner_scorecard(bigint, date) to authenticated, anon;
grant execute on function public.admin_partner_scorecards(date) to authenticated;
grant execute on function public.partner_targets_get(bigint, date) to authenticated;
grant execute on function public.partner_targets_set(bigint, date, jsonb) to authenticated;
grant execute on function public.partner_incentive_schemes() to authenticated;
grant execute on function public.partner_incentive_evaluate_month(date, bigint) to authenticated;
grant execute on function public.partner_scorecard_snapshot(date, bigint) to authenticated;
grant execute on function public.partner_scorecard_digest_line(bigint, date) to authenticated;

-- The partner surface reaches its own RPCs through the partner RPC guard.
insert into public.partner_rpc_allow(proname, source, note)
values ('partner_scorecard', 'c693', 'CHANGE #693 — clamps to my_partner_id() for a non-admin caller.')
on conflict (proname) do nothing;

-- CHANGE #812 — Dashboard v2 backend.
--
-- The admin home was six flat counters (admin_dashboard_counts) with one of
-- them a `count(*)` over the 563k-row "MEDICINE" table. It answered "how many"
-- and never "is today better than yesterday" or "what should I do first".
--
-- This replaces it with ONE payload — dashboard_v2(p_date, p_zone) — that feeds
-- super admin, admin and partner from the same code path: role, zone and the
-- access matrix decide what is filled, never the client. Every string, every
-- rupee, every delta and every plural in it is composed here.
--
-- Everything expensive is a CACHE READ. Two bounded cron tasks do the scanning:
--   dashboard_daily_rollup  — the 5 daily metrics per zone, last 8 days
--   dashboard_ops_snapshot  — the open-order funnel, needs-you and the ring
-- so dashboard_v2 itself never scans an order table (rg rule: < 200 ms, < 30 kB).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE ROLLUPS
-- ─────────────────────────────────────────────────────────────────────────────

-- zone_id 0 is the synthetic "all zones" bucket: zones.id starts at 1, so it can
-- never collide with a real zone and the strip reads one row either way.
create table if not exists public.dashboard_daily (
  the_date        date     not null,
  zone_id         smallint not null,
  orders_received int      not null default 0,
  to_dispatch     int      not null default 0,
  delivered       int      not null default 0,
  money_in        numeric  not null default 0,
  money_out       numeric  not null default 0,
  built_at        timestamptz not null default now(),
  primary key (the_date, zone_id)
);

create index if not exists dashboard_daily_zone_date_idx
  on public.dashboard_daily (zone_id, the_date desc);

-- The open-order snapshot (funnel + needs-you + promised ring), one row per
-- zone scope. Rebuilt whole by the cron; dashboard_v2 only ever reads it.
create table if not exists public.dashboard_cache (
  cache_key text primary key,
  payload   jsonb not null default '{}'::jsonb,
  built_at  timestamptz not null default now()
);

-- The five strip metrics are DATA: order, wording and kind live here, so the
-- strip changes with an UPDATE and never a deploy.
create table if not exists public.dashboard_metric (
  key        text primary key,
  label      text not null,
  short_label text not null default '',
  kind       text not null default 'count',   -- count | money
  sort_order int  not null default 0,
  is_active  boolean not null default true,
  higher_is_better boolean not null default true
);

insert into public.dashboard_metric (key, label, short_label, kind, sort_order, higher_is_better) values
  ('orders_received', 'Orders received',   'Received',  'count', 10, true),
  ('to_dispatch',     'Ready to dispatch', 'Dispatch',  'count', 20, true),
  ('delivered',       'Delivered',         'Delivered', 'count', 30, true),
  ('money_in',        'Money in',          'In',        'money', 40, true),
  ('money_out',       'Money out',         'Out',       'money', 50, false)
on conflict (key) do update
  set label = excluded.label, short_label = excluded.short_label,
      kind = excluded.kind, sort_order = excluded.sort_order,
      higher_is_better = excluded.higher_is_better;

-- The funnel's seven stages, and which of the ten sla_stage keys each one
-- swallows. A stage is a row, so re-cutting the funnel is an UPDATE.
create table if not exists public.dashboard_funnel_stage (
  stage_key     text primary key,
  label         text not null,
  sort_order    int  not null default 0,
  source_stages text[] not null default '{}',
  route_key     text not null default '',
  deep_link     text not null default '',
  is_active     boolean not null default true
);

insert into public.dashboard_funnel_stage (stage_key, label, sort_order, source_stages, route_key, deep_link) values
  ('received',  'Received',  10, array['accept'],                  'customer_orders', '/admin/go/fulfillment'),
  ('inquiry',   'Inquiry',   20, array['inquiry','supplier_order'],'inquiry',         '/admin/go/fulfillment'),
  ('collect',   'Collect',   30, array['collect','arrival'],       'collect',         '/admin/go/fulfillment'),
  ('count',     'Count',     40, array['count','bag'],             'count',           '/admin/go/fulfillment'),
  ('pack',      'Pack',      50, array['pack'],                    'pack',            '/admin/go/fulfillment'),
  ('dispatch',  'Dispatch',  60, array['dispatch'],                'assign_delivery', '/admin/go/fulfillment'),
  ('delivered', 'Delivered', 70, array['delivered'],               'delivery_ops',    '/admin/delivery-ops')
on conflict (stage_key) do update
  set label = excluded.label, sort_order = excluded.sort_order,
      source_stages = excluded.source_stages,
      route_key = excluded.route_key, deep_link = excluded.deep_link;

-- Quick actions, each behind its own matrix door for admin and for partner.
create table if not exists public.dashboard_quick_action (
  key             text primary key,
  label           text not null,
  icon_key        text not null default '',
  route_key       text not null default '',
  deep_link       text not null default '',
  admin_feature   text not null default '',
  partner_feature text not null default '',
  sort_order      int  not null default 0,
  is_active       boolean not null default true
);

insert into public.dashboard_quick_action
  (key, label, icon_key, route_key, deep_link, admin_feature, partner_feature, sort_order) values
  ('add_order',       'Add order',       'add_shopping_cart', 'customer_order',  '', 'fulfill.customer_order',  'partner.customer_orders', 10),
  ('start_inquiry',   'Start inquiry',   'question_answer',   'supplier_inquiry','', 'fulfill.supplier_inquiry','partner.inquiry',         20),
  ('assign_delivery', 'Assign delivery', 'local_shipping',    'assign_delivery', '', 'admin.delivery_ops',      'partner.assign_delivery', 30)
on conflict (key) do update
  set label = excluded.label, icon_key = excluded.icon_key,
      route_key = excluded.route_key, deep_link = excluded.deep_link,
      admin_feature = excluded.admin_feature, partner_feature = excluded.partner_feature,
      sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE DAILY REFRESH — bounded: (active zones + 1) x p_days rows, no scans
--    outside the window.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.dashboard_daily_refresh(p_days integer default 8)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_days int  := least(greatest(coalesce(p_days, 8), 1), 31);
  v_from date := (now() at time zone 'Asia/Kolkata')::date - (v_days - 1);
  v_to   date := (now() at time zone 'Asia/Kolkata')::date;
  v_rows int  := 0;
begin
  with days as (
    select generate_series(v_from, v_to, interval '1 day')::date as d
  ), scopes as (
    select 0::smallint as zid
    union all
    select z.id::smallint from public.zones z where coalesce(z.is_active, false)
  ), grid as (
    select d.d, s.zid from days d cross join scopes s
  ), ord as (
    select (o.created_at at time zone 'Asia/Kolkata')::date as d,
           coalesce(o.zone_id, pp.zone_id)::smallint as zid,
           count(*)::int as n
      from public.orders o
      left join public.pharmacy_profiles pp on pp.id = o.customer_id
     where not coalesce(o.is_synthetic, false)
       and (o.created_at at time zone 'Asia/Kolkata')::date between v_from and v_to
     group by 1, 2
  ), disp as (
    select (o.dispatch_ready_at at time zone 'Asia/Kolkata')::date as d,
           coalesce(o.zone_id, pp.zone_id)::smallint as zid,
           count(*)::int as n
      from public.orders o
      left join public.pharmacy_profiles pp on pp.id = o.customer_id
     where not coalesce(o.is_synthetic, false)
       and o.dispatch_ready_at is not null
       and (o.dispatch_ready_at at time zone 'Asia/Kolkata')::date between v_from and v_to
     group by 1, 2
  ), dlv as (
    select (dd.delivered_at at time zone 'Asia/Kolkata')::date as d,
           coalesce(dd.zone_id, o.zone_id, pp.zone_id)::smallint as zid,
           count(*)::int as n
      from public.deliveries dd
      join public.orders o on o.id = dd.order_id
      left join public.pharmacy_profiles pp on pp.id = o.customer_id
     where not coalesce(o.is_synthetic, false)
       and dd.delivered_at is not null
       and (dd.delivered_at at time zone 'Asia/Kolkata')::date between v_from and v_to
     group by 1, 2
  ), cash_in as (
    select coalesce(pc.business_date,
             (coalesce(pc.paid_ts, pc.received_at, pc.created_at) at time zone 'Asia/Kolkata')::date) as d,
           pc.zone_id::smallint as zid,
           sum(coalesce(pc.amount, 0))::numeric as amt
      from public.payment_claims pc
     where not coalesce(pc.is_synthetic, false)
       and pc.status = 'verified'
       and coalesce(pc.business_date,
             (coalesce(pc.paid_ts, pc.received_at, pc.created_at) at time zone 'Asia/Kolkata')::date)
           between v_from and v_to
     group by 1, 2
  ), cash_out as (
    select (sp.created_at at time zone 'Asia/Kolkata')::date as d,
           so.zone_id::smallint as zid,
           sum(coalesce(sp.amount, 0))::numeric as amt
      from public.supplier_payments sp
      left join public.supplier_orders so on so.id = sp.supplier_order_id
     where not coalesce(sp.is_synthetic, false)
       and (sp.created_at at time zone 'Asia/Kolkata')::date between v_from and v_to
     group by 1, 2
  )
  insert into public.dashboard_daily
    (the_date, zone_id, orders_received, to_dispatch, delivered, money_in, money_out, built_at)
  select g.d, g.zid,
         coalesce((select sum(x.n) from ord      x where x.d = g.d and (g.zid = 0 or x.zid = g.zid)), 0)::int,
         coalesce((select sum(x.n) from disp     x where x.d = g.d and (g.zid = 0 or x.zid = g.zid)), 0)::int,
         coalesce((select sum(x.n) from dlv      x where x.d = g.d and (g.zid = 0 or x.zid = g.zid)), 0)::int,
         coalesce((select sum(x.amt) from cash_in  x where x.d = g.d and (g.zid = 0 or x.zid = g.zid)), 0)::numeric,
         coalesce((select sum(x.amt) from cash_out x where x.d = g.d and (g.zid = 0 or x.zid = g.zid)), 0)::numeric,
         now()
    from grid g
  on conflict (the_date, zone_id) do update
    set orders_received = excluded.orders_received,
        to_dispatch     = excluded.to_dispatch,
        delivered       = excluded.delivered,
        money_in        = excluded.money_in,
        money_out       = excluded.money_out,
        built_at        = excluded.built_at;

  get diagnostics v_rows = row_count;
  return jsonb_build_object('ok', true, 'rows', v_rows, 'from', v_from, 'to', v_to);
end $fn$;

revoke all on function public.dashboard_daily_refresh(integer) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE OPEN-ORDER SNAPSHOT — funnel, needs-you, promised ring, per zone scope.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._dashboard_ops_build(p_zone smallint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_funnel jsonb := '[]'::jsonb;
  v_needs  jsonb := '[]'::jsonb;
  v_total  int   := 0;
  v_ring   jsonb;
  v_done   int   := 0;
  v_prom   int   := 0;
  v_today  date  := (now() at time zone 'Asia/Kolkata')::date;
begin
  -- The funnel: every open order sits in exactly one sla_stage, and each
  -- funnel stage swallows one or more of them.
  with cur as (select s.* from public._ops_order_stage(nullif(p_zone, 0)) s),
  per as (
    select f.stage_key, f.label, f.sort_order, f.route_key, f.deep_link,
           coalesce((select count(*) from cur c where c.stage_key = any (f.source_stages)), 0)::int as n
      from public.dashboard_funnel_stage f
     where f.is_active
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',        p.stage_key,
           'label',      p.label,
           'count',      p.n,
           'count_label', p.n::text,
           'route_key',  p.route_key,
           'deep_link',  p.deep_link) order by p.sort_order), '[]'::jsonb),
         coalesce(sum(p.n), 0)::int
    into v_funnel, v_total
    from per p;

  -- Needs-you: the most overdue open work, ops board (#688) and exceptions
  -- (#690) merged into ONE ranked list. Both sides carry their own action.
  with cur as (select s.* from public._ops_order_stage(nullif(p_zone, 0)) s),
  ops as (
    select 'ops:' || c.order_id::text || ':' || c.stage_key            as id,
           coalesce(nullif(c.order_code, ''), 'Order ' || left(c.order_id::text, 8)) as label,
           coalesce(nullif(c.customer, ''), st.label)                  as sub_label,
           coalesce(h.entered_at, c.since, c.created_at)               as since,
           st.owner_label, st.label as stage_label, st.next_action,
           cfg.sla_minutes
      from cur c
      join public.sla_stage st on st.stage_key = c.stage_key and st.is_active
      left join public.order_stage_history h
             on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
      left join lateral (
        select f.sla_minutes from public.sla_config f
         where f.stage_key = c.stage_key and f.is_active
           and (f.zone_id = c.zone_id or f.zone_id is null)
         order by (f.zone_id is null) limit 1) cfg on true
     where cfg.sla_minutes is not null
  ),
  ops_over as (
    select o.id, o.label, o.sub_label, o.since, o.owner_label, o.stage_label,
           o.next_action,
           extract(epoch from (now() - o.since)) / 60.0 - o.sla_minutes as over_min
      from ops o
     where extract(epoch from (now() - o.since)) / 60.0 > o.sla_minutes
  ),
  exc as (
    select 'exc:' || r.reason_code || ':' || r.ref_id                  as id,
           r.title                                                     as label,
           coalesce(nullif(r.subtitle, ''), '')                        as sub_label,
           r.since,
           case when x.owner_kind = 'admin' or r.zone_id is null
                then public._c('exc.owner.admin')
                else coalesce((select rp.partner_name from public.region_partners rp
                                where rp.zone_id = r.zone_id and coalesce(rp.is_active, true)
                                order by rp.id limit 1), public._c('exc.owner.admin')) end as owner_label,
           public._c('exc.reason.' || r.reason_code)                   as stage_label,
           public._c('exc.action.' || r.reason_code)                   as next_action,
           r.reason_code || ':' || r.ref_id                            as action_id,
           extract(epoch from (now() - r.since)) / 60.0 - (x.sla_hours * 60.0) as over_min
      from public._exception_rows() r
      join public.exception_reason x
        on x.reason_code = r.reason_code and x.enabled
      left join public.exception_state s
        on s.reason_code = r.reason_code and s.ref_id = r.ref_id
     where coalesce(s.status, 'open') <> 'closed'
       and (p_zone = 0 or r.zone_id = p_zone or r.zone_id is null)
       and extract(epoch from (now() - r.since)) / 60.0 > (x.sla_hours * 60.0)
  ),
  merged as (
    select o.id, o.label, o.sub_label, o.since, o.owner_label, o.stage_label,
           o.next_action, o.over_min, null::text as action_id, 'ops'::text as source
      from ops_over o
    union all
    select e.id, e.label, e.sub_label, e.since, e.owner_label, e.stage_label,
           e.next_action, e.over_min, e.action_id, 'exception'::text
      from exc e
  ),
  picked as (
    select * from merged order by over_min desc, since asc limit 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          m.id,
           'label',       m.label,
           'sub_label',   m.sub_label,
           'stage_label', m.stage_label,
           'age_label',   public.ops_age_label(m.since),
           'over_label',  replace(public._c('dash.needs_over'), '{d}',
                                  public.ops_dur_label(m.over_min * 60.0)),
           'owner_label', replace(public._c('dash.needs_owner'), '{owner}',
                                  coalesce(nullif(m.owner_label, ''), '')),
           'tone',        case when m.over_min > 240 then 'bad' else 'warn' end,
           'source',      m.source,
           'action',      case when m.source = 'exception'
                               then jsonb_build_object('has', true, 'kind', 'rpc',
                                      'label', coalesce(nullif(m.next_action, ''), public._c('dash.needs_action')),
                                      'rpc', 'exceptions_action',
                                      'args', jsonb_build_object('p_id', m.action_id),
                                      'route', 'exceptions')
                               else jsonb_build_object('has', true, 'kind', 'route',
                                      'label', coalesce(nullif(m.next_action, ''), public._c('dash.needs_action')),
                                      'rpc', '', 'args', '{}'::jsonb,
                                      'route', 'ops_board') end)
           order by m.over_min desc, m.since asc), '[]'::jsonb)
    into v_needs
    from picked m;

  -- The promised ring: deliveries promised for today, and how many landed.
  select count(*) filter (where d.delivered_at is not null)::int, count(*)::int
    into v_done, v_prom
    from public.deliveries d
    join public.orders o on o.id = d.order_id
   where not coalesce(o.is_synthetic, false)
     and d.promised_at is not null
     and (d.promised_at at time zone 'Asia/Kolkata')::date = v_today
     and (p_zone = 0 or coalesce(d.zone_id, o.zone_id) = p_zone);

  v_ring := jsonb_build_object(
    'has',   v_prom > 0,
    'done',  v_done,
    'total', v_prom,
    'pct',   case when v_prom > 0 then round((v_done::numeric / v_prom) * 100)::int else 0 end,
    'label', replace(replace(public._c('dash.ring_label'), '{done}', v_done::text), '{total}', v_prom::text),
    'sub_label', case when v_prom = 0 then public._c('dash.ring_none')
                      when v_done >= v_prom then public._c('dash.ring_clear')
                      else replace(public._c('dash.ring_left'), '{n}', (v_prom - v_done)::text) end);

  return jsonb_build_object(
    'funnel',      v_funnel,
    'funnel_total', v_total,
    'needs_you',   v_needs,
    'promised',    v_ring,
    'open_total',  v_total,
    'accept_open', coalesce((select (e->>'count')::int from jsonb_array_elements(v_funnel) e
                              where e->>'key' = 'received'), 0));
end $fn$;

revoke all on function public._dashboard_ops_build(smallint) from public, anon, authenticated;

create or replace function public.dashboard_ops_refresh()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_n int := 0; v_zid smallint;
begin
  for v_zid in
    select 0::smallint
    union all
    select z.id::smallint from public.zones z where coalesce(z.is_active, false)
  loop
    insert into public.dashboard_cache (cache_key, payload, built_at)
    values ('ops:' || v_zid::text, public._dashboard_ops_build(v_zid), now())
    on conflict (cache_key) do update
      set payload = excluded.payload, built_at = excluded.built_at;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'scopes', v_n);
end $fn$;

revoke all on function public.dashboard_ops_refresh() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. COPY — every word the dashboard says.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('dash.title',            to_jsonb('Today'::text)),
  ('dash.strip_title',      to_jsonb('Today'::text)),
  ('dash.greeting_morning', to_jsonb('Good morning'::text)),
  ('dash.greeting_afternoon', to_jsonb('Good afternoon'::text)),
  ('dash.greeting_evening', to_jsonb('Good evening'::text)),
  ('dash.greeting_night',   to_jsonb('Good evening'::text)),
  ('dash.first_thing',      to_jsonb('{n} orders waiting for accept'::text)),
  ('dash.first_thing_one',  to_jsonb('1 order waiting for accept'::text)),
  ('dash.first_thing_needs', to_jsonb('{label} is overdue'::text)),
  ('dash.first_thing_clear', to_jsonb('nothing is overdue'::text)),
  ('dash.needs_title',      to_jsonb('Needs you'::text)),
  ('dash.needs_empty',      to_jsonb('Nothing is overdue right now.'::text)),
  ('dash.needs_over',       to_jsonb('{d} over'::text)),
  ('dash.needs_owner',      to_jsonb('Waiting on: {owner}'::text)),
  ('dash.needs_action',     to_jsonb('Open'::text)),
  ('dash.funnel_title',     to_jsonb('Where orders are'::text)),
  ('dash.funnel_empty',     to_jsonb('No open orders.'::text)),
  ('dash.ring_title',       to_jsonb('Promised today'::text)),
  ('dash.ring_label',       to_jsonb('{done} of {total}'::text)),
  ('dash.ring_none',        to_jsonb('Nothing promised for today.'::text)),
  ('dash.ring_clear',       to_jsonb('All promises kept.'::text)),
  ('dash.ring_left',        to_jsonb('{n} still to land'::text)),
  ('dash.zones_title',      to_jsonb('Zones'::text)),
  ('dash.actions_title',    to_jsonb('Quick actions'::text)),
  ('dash.delta_up',         to_jsonb('+{n} vs yesterday'::text)),
  ('dash.delta_down',       to_jsonb('{n} vs yesterday'::text)),
  ('dash.delta_flat',       to_jsonb('same as yesterday'::text)),
  ('dash.alert_rg',         to_jsonb('Regression guard is red'::text)),
  ('dash.alert_licence',    to_jsonb('{n} partner licence(s) expiring within 30 days'::text)),
  ('dash.all_zones',        to_jsonb('All zones'::text)),
  ('dash.updated',          to_jsonb('Updated {t}'::text)),
  ('dash.not_authorized',   to_jsonb('You do not have access to this dashboard.'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. dashboard_v2 — ONE payload, every role, all cache reads.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._dashboard_strip(p_zone smallint, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_out jsonb;
begin
  with span as (
    select generate_series(p_date - 6, p_date, interval '1 day')::date as d
  ), rows as (
    select s.d,
           coalesce(dd.orders_received, 0) as orders_received,
           coalesce(dd.to_dispatch, 0)     as to_dispatch,
           coalesce(dd.delivered, 0)       as delivered,
           coalesce(dd.money_in, 0)        as money_in,
           coalesce(dd.money_out, 0)       as money_out
      from span s
      left join public.dashboard_daily dd
             on dd.the_date = s.d and dd.zone_id = p_zone
  ), vals as (
    select m.key, m.label, m.short_label, m.kind, m.sort_order, m.higher_is_better,
           (select case m.key
                     when 'orders_received' then r.orders_received::numeric
                     when 'to_dispatch'     then r.to_dispatch::numeric
                     when 'delivered'       then r.delivered::numeric
                     when 'money_in'        then r.money_in
                     else r.money_out end
              from rows r where r.d = p_date)                       as today,
           (select case m.key
                     when 'orders_received' then r.orders_received::numeric
                     when 'to_dispatch'     then r.to_dispatch::numeric
                     when 'delivered'       then r.delivered::numeric
                     when 'money_in'        then r.money_in
                     else r.money_out end
              from rows r where r.d = p_date - 1)                   as yday,
           (select jsonb_agg(case m.key
                     when 'orders_received' then to_jsonb(r.orders_received)
                     when 'to_dispatch'     then to_jsonb(r.to_dispatch)
                     when 'delivered'       then to_jsonb(r.delivered)
                     when 'money_in'        then to_jsonb(round(r.money_in))
                     else to_jsonb(round(r.money_out)) end order by r.d)
              from rows r)                                          as spark
      from public.dashboard_metric m
     where m.is_active
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   v.key,
           'label', v.label,
           'short_label', v.short_label,
           'kind',  v.kind,
           'value', case when v.kind = 'money' then round(v.today) else v.today end,
           'value_display', case when v.kind = 'money'
                                 then public.inr_money_compact(v.today)
                                 else v.today::bigint::text end,
           'delta', case when v.kind = 'money' then round(v.today - v.yday) else v.today - v.yday end,
           'delta_display', case
             when v.today = v.yday then public._c('dash.delta_flat')
             when v.today > v.yday then replace(public._c('dash.delta_up'), '{n}',
                    case when v.kind = 'money' then public.inr_money_compact(v.today - v.yday)
                         else (v.today - v.yday)::bigint::text end)
             else replace(public._c('dash.delta_down'), '{n}',
                    case when v.kind = 'money' then '-' || public.inr_money_compact(v.yday - v.today)
                         else (v.today - v.yday)::bigint::text end) end,
           'delta_tone', case
             when v.today = v.yday then 'neutral'
             when (v.today > v.yday) = v.higher_is_better then 'good'
             else 'warn' end,
           'spark', coalesce(v.spark, '[]'::jsonb)) order by v.sort_order), '[]'::jsonb)
    into v_out
    from vals v;
  return v_out;
end $fn$;

revoke all on function public._dashboard_strip(smallint, date) from public, anon;
grant execute on function public._dashboard_strip(smallint, date) to authenticated;

create or replace function public.dashboard_v2(p_date date default null, p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role    text     := coalesce(public.get_my_role(), 'none');
  v_partner bigint   := public.my_partner_id();
  v_is_admin boolean := (coalesce(public.role_for_medibo_only(), 'none') in ('admin','super_admin'));
  v_super   boolean  := (coalesce(public.role_for_medibo_only(), 'none') = 'super_admin');
  v_zone    smallint;
  v_scope   smallint;                    -- 0 = all zones
  v_date    date;
  v_zlabel  text;
  v_ops     jsonb    := '{}'::jsonb;
  v_strip   jsonb;
  v_alerts  jsonb    := '[]'::jsonb;
  v_actions jsonb    := '[]'::jsonb;
  v_zcards  jsonb    := '[]'::jsonb;
  v_hour    int      := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  v_greet   text;
  v_first   text;
  v_accept  int;
  v_top     jsonb;
  v_breaker jsonb;
  v_lic     int;
  v_rg_ok   boolean;
begin
  if v_partner is null and not v_is_admin then
    return jsonb_build_object('ok', false, 'allowed', false,
      'error', 'not_authorized',
      'title', public._c('dash.title'),
      'message', public._c('dash.not_authorized'),
      'strip', '[]'::jsonb, 'needs_you', '[]'::jsonb, 'funnel', '[]'::jsonb,
      'alerts', '[]'::jsonb, 'quick_actions', '[]'::jsonb, 'zone_cards', '[]'::jsonb);
  end if;

  -- A partner sees ITS zone and only its zone; an admin follows the zone
  -- picker, and "all zones" is scope 0.
  if v_partner is not null then
    v_zone := public.partner_zone_id();
  else
    v_zone := coalesce(p_zone, public.admin_active_zone());
  end if;
  v_scope  := coalesce(v_zone, 0)::smallint;
  v_date   := coalesce(p_date, public.admin_active_date(), (now() at time zone 'Asia/Kolkata')::date);
  v_zlabel := coalesce((select z.name from public.zones z where z.id = v_zone),
                       public._c('dash.all_zones'));

  select c.payload into v_ops from public.dashboard_cache c
   where c.cache_key = 'ops:' || v_scope::text;
  v_ops := coalesce(v_ops, '{}'::jsonb);

  v_strip := public._dashboard_strip(v_scope, v_date);

  -- Greeting + first thing. Both are sentences composed HERE.
  v_greet := case when v_hour < 12 then public._c('dash.greeting_morning')
                  when v_hour < 17 then public._c('dash.greeting_afternoon')
                  else public._c('dash.greeting_evening') end;
  v_accept := coalesce((v_ops->>'accept_open')::int, 0);
  v_top    := (v_ops->'needs_you')->0;
  v_first  := case
    when v_accept = 1 then public._c('dash.first_thing_one')
    when v_accept > 1 then replace(public._c('dash.first_thing'), '{n}', v_accept::text)
    when v_top is not null and v_top <> 'null'::jsonb
      then replace(public._c('dash.first_thing_needs'), '{label}', coalesce(v_top->>'label',''))
    else public._c('dash.first_thing_clear') end;

  -- Alerts — thin-banner strings only, and only for platform operators.
  if v_is_admin then
    v_breaker := public._dev_breaker_badge();
    if coalesce((v_breaker->>'tripped')::boolean, false) then
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'key', 'breaker', 'tone', 'danger', 'label', coalesce(v_breaker->>'label','')));
    end if;

    select count(*)::int into v_lic
      from public.region_partners rp
     where coalesce(rp.is_active, true)
       and rp.suspended_at is null
       and least(coalesce(rp.gstin_expiry,   'infinity'::date),
                 coalesce(rp.dl_20b_expiry,  'infinity'::date),
                 coalesce(rp.dl_21b_expiry,  'infinity'::date),
                 coalesce(rp.agreement_expiry,'infinity'::date))
           <= (now() at time zone 'Asia/Kolkata')::date + 30;
    if coalesce(v_lic, 0) > 0 then
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'key', 'licence', 'tone', 'warn',
        'label', replace(public._c('dash.alert_licence'), '{n}', v_lic::text)));
    end if;

    if v_super then
      select r.ok into v_rg_ok from public.rg_check_cache r where r.id = 1;
      if v_rg_ok is not null and v_rg_ok = false then
        v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
          'key', 'rg', 'tone', 'danger', 'label', public._c('dash.alert_rg')));
      end if;
    end if;
  end if;

  -- Quick actions, each behind its own matrix door.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', q.key, 'label', q.label, 'icon_key', q.icon_key,
           'route_key', q.route_key, 'deep_link', q.deep_link)
         order by q.sort_order), '[]'::jsonb)
    into v_actions
    from public.dashboard_quick_action q
   where q.is_active
     and case when v_partner is not null
              then q.partner_feature <> ''
                   and coalesce(public.partner_access(q.partner_feature, v_partner), 'none') <> 'none'
              else q.admin_feature <> ''
                   and coalesce(public.admin_access(q.admin_feature), 'none') <> 'none' end;

  -- Zone cards: super admin only, one per active zone, same strip.
  if v_super and v_partner is null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'zone_id', z.id, 'zone_label', z.name,
             'metrics', public._dashboard_strip(z.id::smallint, v_date),
             'route_key', 'dashboard')
           order by z.id), '[]'::jsonb)
      into v_zcards
      from public.zones z
     where coalesce(z.is_active, false);
  end if;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'role', v_role, 'is_partner', (v_partner is not null), 'is_super', v_super,
    'zone_id', v_zone, 'zone_label', v_zlabel,
    'the_date', v_date, 'date_label', public.ist_fmt(v_date::timestamptz, 'day_mon_year'),
    'title', public._c('dash.title'),
    'greeting', v_greet,
    'first_thing', v_first,
    'strip', jsonb_build_object(
      'title', public._c('dash.strip_title'),
      'metrics', coalesce(v_strip, '[]'::jsonb)),
    'needs_you', jsonb_build_object(
      'title', public._c('dash.needs_title'),
      'empty_label', public._c('dash.needs_empty'),
      'items', coalesce(v_ops->'needs_you', '[]'::jsonb)),
    'funnel', jsonb_build_object(
      'title', public._c('dash.funnel_title'),
      'empty_label', public._c('dash.funnel_empty'),
      'total', coalesce((v_ops->>'funnel_total')::int, 0),
      'stages', coalesce(v_ops->'funnel', '[]'::jsonb)),
    'promised', coalesce(v_ops->'promised',
      jsonb_build_object('has', false, 'done', 0, 'total', 0, 'pct', 0,
                         'label', '', 'sub_label', public._c('dash.ring_none')))
      || jsonb_build_object('title', public._c('dash.ring_title')),
    'alerts', v_alerts,
    'quick_actions', jsonb_build_object(
      'title', public._c('dash.actions_title'),
      'items', v_actions),
    'zone_cards', jsonb_build_object(
      'title', public._c('dash.zones_title'),
      'has', jsonb_array_length(v_zcards) > 0,
      'cards', v_zcards),
    'built_at', (select c.built_at from public.dashboard_cache c
                  where c.cache_key = 'ops:' || v_scope::text),
    'updated_label', replace(public._c('dash.updated'), '{t}', public.ist_fmt(now(), 'time12')),
    'refresh_ms', 60000);
end $fn$;

revoke all on function public.dashboard_v2(date, smallint) from public, anon;
grant execute on function public.dashboard_v2(date, smallint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. admin_dashboard_counts stays for old callers — as a THIN wrapper. The
--    `count(*) from "MEDICINE"` it used to run on every admin home load (563k
--    rows) is now the count cache; the tile that displayed it is gone.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_dashboard_counts(p_date date default null, p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'books', 'public'
as $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint; v_date date; v_zname text;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false,
      'medicines',0,'pending_bills',0,'flagged_bills',0,
      'pending_orders',0,'contact_inquiries',0,'pending_customers',0);
  end if;
  v_zone := public.scope_zone(p_zone);
  v_date := public.scope_date(p_date);
  select name into v_zname from zones where id = v_zone;

  return jsonb_build_object('allowed', true,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'), 'the_date', v_date,
    -- CHANGE #812 — the count cache, never a live scan of "MEDICINE".
    'medicines', coalesce((select c.total from public.medicine_count_cache c limit 1), 0),
    'pending_bills', (select count(*) from pending_bills pb
                      where pb.status='pending'
                        and not coalesce(pb.is_synthetic,false)
                        and public.scope_zone_ok(
                              public._c529_bill_zone(pb.supplier_id, pb.supplier_name), v_zone)),
    'flagged_bills', (select count(*) from pending_bills pb
                      where pb.verdict in ('needs_approval','fake')
                        and not coalesce(pb.is_synthetic,false)
                        and public.scope_zone_ok(
                              public._c529_bill_zone(pb.supplier_id, pb.supplier_name), v_zone)),
    'unresolved_bills', (select count(*) from pending_bills pb
                          where pb.status='pending'
                            and not coalesce(pb.is_synthetic,false)
                            and public._c529_bill_zone(pb.supplier_id, pb.supplier_name) is null),
    'unresolved_bills_label', public._c('bills.unresolved_label'),
    'unresolved_bills_note',  public._c('bills.unresolved_note'),
    'pending_orders', (select count(*) from orders o
                        left join pharmacy_profiles pp on pp.id = o.customer_id
                       where o.status='pending'
                         and not coalesce(o.is_synthetic,false)
                         and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'orders_today', coalesce((select d.orders_received from public.dashboard_daily d
                               where d.the_date = v_date and d.zone_id = coalesce(v_zone,0)::smallint), 0),
    'contact_inquiries', (select count(*) from contact_inquiries),
    'pending_customers', (select count(*) from pharmacy_profiles pp
                           where coalesce(pp.approved,false) = false
                             and not coalesce(pp.is_synthetic,false)
                             and public.scope_zone_ok(pp.zone_id, v_zone)),
    'deliveries_today', coalesce((select d.delivered from public.dashboard_daily d
                                   where d.the_date = v_date and d.zone_id = coalesce(v_zone,0)::smallint), 0));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE CRON — bounded, offset schedules (never a bare */N: CHANGE #301).
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                              enabled, base_interval_s, max_interval_s, dml, note)
values
  ('dashboard_ops_snapshot', 812, 'poll', '',
   'select public.dashboard_ops_refresh()', 50000, true, 60, 300, true,
   'CHANGE #812 — open-order funnel, needs-you and the promised ring, per zone'),
  ('dashboard_daily_rollup', 813, 'poll', '',
   'select public.dashboard_daily_refresh(8)', 50000, true, 300, 900, true,
   'CHANGE #812 — the 5 daily strip metrics per zone, last 8 days')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = excluded.enabled,
      base_interval_s = excluded.base_interval_s,
      max_interval_s = excluded.max_interval_s,
      step_timeout_ms = excluded.step_timeout_ms,
      dml = excluded.dml, note = excluded.note;

-- First fill, so the dashboard is never blank on the deploy that ships it.
select public.dashboard_daily_refresh(8);
select public.dashboard_ops_refresh();

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE RG RULE — dashboard_v2 must stay a cache read: under 200 ms and under
--    30 kB. A regression that puts a live scan back in is a red guard.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('dashboard_v2_fast_and_small', $rg_outer$
do $rg$
declare
  v jsonb; t0 timestamptz; v_ms numeric; v_bytes int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','f5d6ce2f-1182-427f-93de-fb70cde2cf2a','role','authenticated')::text, true);
  -- warm the plan, then measure the read the app actually makes
  v := public.dashboard_v2(null, null);
  t0 := clock_timestamp();
  v := public.dashboard_v2(null, null);
  v_ms := extract(epoch from (clock_timestamp() - t0)) * 1000.0;
  if coalesce((v->>'ok')::boolean, false) is not true then
    raise exception 'RG_FAIL: dashboard_v2 not ok %', left(v::text, 300);
  end if;
  if v_ms > 200 then
    raise exception 'RG_FAIL: dashboard_v2 took % ms from cache (limit 200)', round(v_ms);
  end if;
  v_bytes := octet_length(v::text);
  if v_bytes > 30720 then
    raise exception 'RG_FAIL: dashboard_v2 payload % bytes (limit 30720)', v_bytes;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$rg_outer$, true,
'CHANGE #812 — dashboard_v2 is a cache read: < 200 ms and < 30 kB, never a live scan')
on conflict (name) do update
  set body = excluded.body, enabled = excluded.enabled, note = excluded.note;

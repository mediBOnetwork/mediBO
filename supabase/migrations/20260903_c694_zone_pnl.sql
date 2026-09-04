-- CHANGE #694 — Zone P&L, shared with the partner (feature_gaps #157).
--
-- pnl_dashboard()/pnl_breakdown() have always been mediBO-only: is_admin() and
-- nothing else, no per-zone view a partner could ever be shown. The partner
-- sees its settlement statement — what it is OWED — and never the trade the
-- statement came out of. This is the same numbers, per zone, per period, with
-- the backend deciding line by line which of them a partner may read.
--
-- ONE source of truth. Every rupee below comes from `pnl_order_v` — the same
-- view pnl_dashboard sums and the same one partner_settlements is computed
-- from — so zone_pnl, pnl_dashboard and settlement_period_totals cannot drift
-- apart. Nothing here re-derives revenue or cost from order lines.
--
-- MRP is never a price (the business rule every bill here obeys); revenue is
-- the billed trade value pnl_order_v already carries.
--
-- Idempotent throughout.

-- ── 1. the line types, and who may see each one ────────────────────────────
create table if not exists public.pnl_line_type (
  key             text primary key,
  label           text not null,
  sort_order      int  not null default 100,
  -- '+' adds to the zone's money, '-' takes from it. The SIGN is data, so a
  -- new cost line is one INSERT rather than a branch in the RPC.
  sign            text not null default '-' check (sign in ('+','-')),
  -- The whole point of this change: mediBO sees every line, the partner sees
  -- the ones that explain ITS OWN share. A line the partner cannot act on and
  -- is not charged for is not hidden out of secrecy — it is simply not part
  -- of the partner's arithmetic, and showing it would invite a dispute about
  -- a number the partner has no lever on.
  partner_visible boolean not null default false,
  is_active       boolean not null default true
);

-- `source` says where a line's amount comes from:
--   'settlement' — a cost_types row in order_costs, the ledger the partner is
--                  actually settled on. These are the ONLY lines that move the
--                  partner's share, because settlement_period_totals computes
--                  distributable as gross_margin - sum(order_costs).
--   'derived'    — mediBO's own economic view out of pnl_order_v (gateway fee,
--                  message cost, credit). Real money, but not in the ledger the
--                  statement is built from, so it is mediBO-only and NEVER
--                  changes what the partner is owed. Showing a partner a share
--                  its own statement disagrees with is the one thing this
--                  feature must not do.
alter table public.pnl_line_type
  add column if not exists source text not null default 'derived'
    check (source in ('settlement','derived'));

insert into public.pnl_line_type (key, label, sort_order, sign, partner_visible, source) values
  ('revenue',           'Billed to customers',        10, '+', true,  'derived'),
  ('goods_cost',        'Supplier purchase cost',     20, '-', true,  'derived'),
  ('scheme_saving',     'Scheme and offer savings',   30, '+', true,  'derived'),
  ('delivery',          'Delivery',                   40, '-', true,  'settlement'),
  ('packaging',         'Packaging',                  50, '-', true,  'settlement'),
  ('handling_damage',   'Handling damage',            60, '-', true,  'settlement'),
  ('marketing',         'Marketing',                  70, '-', true,  'settlement'),
  ('platform_fee',      'Platform operation fee',     80, '-', true,  'settlement'),
  ('whatsapp_cost',     'Notifications and messages', 90, '-', false, 'derived'),
  ('gateway_fee',       'Payment gateway',           100, '-', false, 'derived'),
  ('credit_revenue',    'Credit charges billed',     110, '+', false, 'derived'),
  ('credit_cost',       'Credit cost',               120, '-', false, 'derived')
on conflict (key) do update
  set label = excluded.label, sort_order = excluded.sort_order,
      sign = excluded.sign, partner_visible = excluded.partner_visible,
      source = excluded.source, is_active = true;

-- The old derived-cost keys are retired: they double-counted against the
-- settlement ledger's own delivery/packaging rows.
update public.pnl_line_type set is_active = false
 where key in ('delivery_cost','delivery_recovered','packing_cost');

alter table public.pnl_line_type enable row level security;
drop policy if exists pnl_line_type_read on public.pnl_line_type;
create policy pnl_line_type_read on public.pnl_line_type
  for select to authenticated using (true);

-- ── 2. the copy ────────────────────────────────────────────────────────────
insert into public.pnl_label (key, label) values
  ('zone.title',          'Zone P&L'),
  ('zone.subtitle',       'What this zone earned and what it cost, for the period you pick.'),
  ('zone.empty',          'No billed orders in this period.'),
  ('zone.not_authorized', 'You cannot see the P&L for this zone.'),
  ('zone.all_zones',      'All zones'),
  ('zone.tile_revenue',   'Billed'),
  ('zone.tile_gross',     'Gross margin'),
  ('zone.tile_margin',    'Margin %'),
  ('zone.tile_orders',    'Orders'),
  ('zone.tile_partner',   'Partner share'),
  ('zone.tile_medibo',    'mediBO share'),
  ('zone.costs_heading',  'What it cost'),
  ('zone.shares_heading', 'How the margin splits'),
  ('zone.trend_heading',  'Trend'),
  ('zone.partner_note',   'These are the lines your share is worked out from.'),
  ('zone.split_label',    'Split {pct}% to you'),
  ('zone.period_day',     'Today'),
  ('zone.period_week',    'This week'),
  ('zone.period_month',   'This month'),
  ('zone.period_quarter', 'This quarter'),
  ('zone.period_year',    'This year'),
  ('zone.margin_alert',   'Margin in {zone} is {pct}%, under the {threshold}% floor.'),
  ('zone.export_label',   'Send as PDF'),
  ('zone.reconciles',     'Reconciled against the settlement statement.')
on conflict (key) do update set label = excluded.label;

-- The margin floor a zone is allowed to run at before it is reported.
insert into public.app_settings (key, value)
values ('zone_pnl_margin_floor_pct', to_jsonb(6.0))
on conflict (key) do nothing;

-- ── 3. the period, resolved in one place ───────────────────────────────────
create or replace function public._c694_period(p_period text)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with k as (select lower(coalesce(nullif(btrim(p_period),''),'month')) as k),
  today as (select ((now() at time zone 'Asia/Kolkata')::date) as d)
  select jsonb_build_object(
    'key', k.k,
    'from', case k.k
              when 'day'     then t.d
              when 'week'    then t.d - ((extract(isodow from t.d)::int) - 1)
              when 'quarter' then date_trunc('quarter', t.d)::date
              when 'year'    then date_trunc('year', t.d)::date
              else date_trunc('month', t.d)::date end,
    'to', t.d,
    'label', public._pnl_c('zone.period_' || k.k),
    -- Short windows are read day by day; long ones month by month. The
    -- granularity is the BACKEND's call so two surfaces cannot disagree.
    'grain', case when k.k in ('quarter','year') then 'month' else 'day' end)
    from k, today t;
$function$;

comment on function public._c694_period(text) is
  'CHANGE #694 — one period resolver for zone_pnl, in IST.';

-- ── 4. the numbers for one zone, over one window ───────────────────────────
-- Split out so the mediBO view (every zone side by side) and the partner view
-- (its own zone) are literally the same arithmetic, called twice.
create or replace function public._c694_zone_slice(
  p_zone smallint, p_from date, p_to date, p_partner_view boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  r record; v_lines jsonb; v_split numeric; v_dist numeric; v_ledger numeric;
  v_by_type jsonb;
  v_partner numeric; v_medibo numeric; v_margin numeric;
begin
  select
    coalesce(sum(o.revenue),0)            as revenue,
    coalesce(sum(o.goods_cost),0)         as goods_cost,
    coalesce(sum(o.scheme_saving),0)      as scheme_saving,
    coalesce(sum(o.gross_margin),0)       as gross_margin,
    coalesce(sum(o.delivery_cost),0)      as delivery_cost,
    coalesce(sum(o.delivery_recovered),0) as delivery_recovered,
    coalesce(sum(o.packing_cost),0)       as packing_cost,
    coalesce(sum(o.whatsapp_cost),0)      as whatsapp_cost,
    coalesce(sum(o.gateway_fee + o.gateway_fee_gst),0) as gateway_fee,
    coalesce(sum(o.credit_revenue),0)     as credit_revenue,
    coalesce(sum(o.credit_cost),0)        as credit_cost,
    count(*)::int                         as orders
    into r
    from public.pnl_order_v o
   where o.order_date between p_from and p_to
     and o.zone_id = p_zone;

  -- The split the settlement engine itself uses for this zone. Reading it
  -- here rather than recomputing a percentage is what keeps zone_pnl and
  -- settlement_period_totals from ever disagreeing.
  select coalesce(max(p.split_pct), 0) into v_split
    from public.partner_settlement_periods p
   where p.zone_id = p_zone
     and p.period_start <= p_to and p.period_end >= p_from;
  if v_split is null or v_split = 0 then
    select coalesce(max(s.split_pct), 0) into v_split
      from public.partner_settlements s
     where s.zone_id = p_zone and s.order_date between p_from and p_to;
  end if;

  -- distributable = gross margin less the SETTLEMENT ledger's costs, which is
  -- exactly settlement_period_totals' own arithmetic (gross - cost_total,
  -- where cost_total is _stl_cost_total = sum of order_costs). Subtracting
  -- mediBO's derived costs here instead would hand the partner a share its
  -- own statement disagrees with, which is a dispute, not a report.
  select coalesce(sum(coalesce(oc.override_amount, oc.computed_amount)), 0)
    into v_ledger
    from public.order_costs oc
    join public.pnl_order_v o2 on o2.order_id = oc.order_id
   where o2.zone_id = p_zone
     and o2.order_date between p_from and p_to;
  v_dist := round(r.gross_margin - v_ledger, 2);
  v_partner := round(v_dist * coalesce(v_split,0) / 100, 2);
  v_medibo  := round(v_dist - v_partner, 2);
  v_margin  := case when r.revenue <> 0
                    then round(r.gross_margin / r.revenue * 100, 2) else null end;

  -- The ledger, one total per cost_type, read once.
  select coalesce(jsonb_object_agg(k, amt), '{}'::jsonb) into v_by_type
    from (select oc.cost_type as k,
                 sum(coalesce(oc.override_amount, oc.computed_amount)) as amt
            from public.order_costs oc
            join public.pnl_order_v o2 on o2.order_id = oc.order_id
           where o2.zone_id = p_zone
             and o2.order_date between p_from and p_to
           group by oc.cost_type) z;

  -- The lines, in the table's own order, filtered by the table's own
  -- partner_visible flag. Nothing about which lines a partner sees is decided
  -- in Dart, and nothing is decided here either — it is a column. A
  -- settlement-sourced line reads the ledger; a derived one reads pnl_order_v.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.key, 'label', t.label, 'sign', t.sign, 'source', t.source,
           'amount', x.amt,
           'amount_display', case when t.sign = '-' then '- ' else '+ ' end
                             || public.inr_money(abs(x.amt)))
         order by t.sort_order), '[]'::jsonb)
    into v_lines
    from public.pnl_line_type t
    join lateral (select case
             when t.source = 'settlement'
               then coalesce((v_by_type->>t.key)::numeric, 0)
             when t.key = 'revenue'        then r.revenue
             when t.key = 'goods_cost'     then r.goods_cost
             when t.key = 'scheme_saving'  then r.scheme_saving
             when t.key = 'whatsapp_cost'  then r.whatsapp_cost
             when t.key = 'gateway_fee'    then r.gateway_fee
             when t.key = 'credit_revenue' then r.credit_revenue
             when t.key = 'credit_cost'    then r.credit_cost
             else 0 end as amt) x on true
   where t.is_active
     and (not p_partner_view or t.partner_visible);

  return jsonb_build_object(
    'zone_id', p_zone,
    'zone_name', coalesce((select z.name from public.zones z where z.id = p_zone), '—'),
    'orders', r.orders,
    'revenue', r.revenue,
    'gross_margin', r.gross_margin,
    'distributable', v_dist,
    'ledger_cost', v_ledger,
    'split_pct', coalesce(v_split, 0),
    'partner_share', v_partner,
    'medibo_share', v_medibo,
    'margin_pct', v_margin,
    'revenue_display', public.inr_money(r.revenue),
    'gross_display', public.inr_money(r.gross_margin),
    'partner_display', public.inr_money(v_partner),
    'medibo_display', public.inr_money(v_medibo),
    'margin_display', case when v_margin is null then '—'
                           else to_char(v_margin, 'FM990.00') || '%' end,
    'margin_tone', case when v_margin is null then 'neutral'
                        when v_margin < coalesce((select (value #>> '{}')::numeric
                                                    from public.app_settings
                                                   where key = 'zone_pnl_margin_floor_pct'), 6.0)
                        then 'danger' else 'success' end,
    'split_label', replace(public._pnl_c('zone.split_label'), '{pct}',
                           to_char(coalesce(v_split,0), 'FM990.##')),
    'lines', v_lines);
end $function$;

-- ── 5. zone_pnl() — the one RPC both views read ────────────────────────────
create or replace function public.zone_pnl(
  p_zone smallint default null, p_period text default 'month')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role     text := coalesce(public.get_my_role(), 'none');
  v_partner  bigint := public.my_partner_id();
  v_is_admin boolean := v_role in ('admin','super_admin');
  v_pv       boolean;                    -- the partner's view of the lines
  v_p        jsonb := public._c694_period(p_period);
  v_from     date := (v_p->>'from')::date;
  v_to       date := (v_p->>'to')::date;
  v_zones    smallint[];
  v_slices   jsonb := '[]'::jsonb;
  v_trend    jsonb;
  v_z        smallint;
  v_floor    numeric := coalesce((select (value #>> '{}')::numeric from public.app_settings
                                   where key = 'zone_pnl_margin_floor_pct'), 6.0);
begin
  if v_partner is not null then
    -- A partner reads its OWN zone and nothing else, and only if the access
    -- matrix grants it. The zone is resolved from the partner's own row: a
    -- p_zone naming somebody else's zone is ignored, not refused, because the
    -- caller never had a choice to make.
    if coalesce(public.partner_access('partner.zone_pnl', v_partner), 'none') = 'none' then
      return jsonb_build_object('ok', false, 'error', 'not_authorized',
        'title', public._pnl_c('zone.title'),
        'message', public._pnl_c('zone.not_authorized'));
    end if;
    v_pv := true;
    v_zones := array[public.partner_zone_id()];
  elsif v_is_admin then
    v_pv := false;
    if p_zone is not null then
      v_zones := array[p_zone];
    else
      select coalesce(array_agg(z.id order by z.id), '{}') into v_zones
        from public.zones z
       where z.is_active and not coalesce(z.is_synthetic, false);
    end if;
  else
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', public._pnl_c('zone.title'),
      'message', public._pnl_c('zone.not_authorized'));
  end if;

  foreach v_z in array coalesce(v_zones, '{}') loop
    if v_z is not null then
      -- The export descriptor rides on the slice: the card that prints a
      -- zone is the card that offers to send it, and the kind + ref it will
      -- quote back are the backend's, never assembled in Dart.
      v_slices := v_slices || jsonb_build_array(
        public._c694_zone_slice(v_z, v_from, v_to, v_pv)
        || jsonb_build_object('export',
             public._c694_export(v_z, v_p->>'key')));
    end if;
  end loop;

  -- The trend, at the grain the period resolver chose, over the same rows.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', to_char(g.bucket, case when v_p->>'grain' = 'month'
                                         then 'YYYY-MM' else 'YYYY-MM-DD' end),
           'label', to_char(g.bucket, case when v_p->>'grain' = 'month'
                                           then 'Mon' else 'DD Mon' end),
           'revenue', g.revenue,
           'gross', g.gross,
           'revenue_display', public.inr_money(g.revenue),
           'gross_display', public.inr_money(g.gross))
         order by g.bucket), '[]'::jsonb)
    into v_trend
    from (
      select date_trunc(v_p->>'grain', o.order_date::timestamp)::date as bucket,
             coalesce(sum(o.revenue),0) as revenue,
             coalesce(sum(o.gross_margin),0) as gross
        from public.pnl_order_v o
       where o.order_date between v_from and v_to
         and o.zone_id = any(v_zones)
       group by 1
    ) g;

  return jsonb_build_object(
    'ok', true,
    'title', public._pnl_c('zone.title'),
    'subtitle', public._pnl_c('zone.subtitle'),
    'empty_note', public._pnl_c('zone.empty'),
    'costs_heading', public._pnl_c('zone.costs_heading'),
    'shares_heading', public._pnl_c('zone.shares_heading'),
    'trend_heading', public._pnl_c('zone.trend_heading'),
    'export_label', public._pnl_c('zone.export_label'),
    'reconcile_note', public._pnl_c('zone.reconciles'),
    -- The partner is told, in the backend's words, why its list is shorter.
    'view_note', case when v_pv then public._pnl_c('zone.partner_note') else '' end,
    'is_partner_view', v_pv,
    'period', v_p,
    'period_options', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'key', k, 'label', public._pnl_c('zone.period_' || k),
               'active', k = (v_p->>'key')) order by o), '[]'::jsonb)
        from (values ('day',1),('week',2),('month',3),('quarter',4),('year',5)) v(k,o)),
    'margin_floor_pct', v_floor,
    'zones', v_slices,
    'trend', v_trend,
    'tile_labels', jsonb_build_object(
      'revenue', public._pnl_c('zone.tile_revenue'),
      'gross',   public._pnl_c('zone.tile_gross'),
      'margin',  public._pnl_c('zone.tile_margin'),
      'orders',  public._pnl_c('zone.tile_orders'),
      'partner', public._pnl_c('zone.tile_partner'),
      'medibo',  public._pnl_c('zone.tile_medibo')));
end $function$;

comment on function public.zone_pnl(smallint, text) is
  'CHANGE #694 — one zone P&L, read by mediBO (every zone) and by the partner '
  '(its own, lines filtered by pnl_line_type.partner_visible). Every rupee '
  'comes from pnl_order_v, the same view pnl_dashboard and partner_settlements '
  'read, so the three can never disagree.';

revoke all on function public.zone_pnl(smallint, text) from anon;
grant execute on function public.zone_pnl(smallint, text) to authenticated;

-- ── 6. a zone running under the floor is reported ──────────────────────────
-- pnl_alert is a per-LINE table (one row per bill line sold below cost), so a
-- ZONE-level margin warning gets its own table rather than being forced into
-- a shape that has an order_code and a product in it.
create table if not exists public.zone_pnl_alert (
  id            bigserial primary key,
  zone_id       smallint not null,
  period_key    text not null,
  period_from   date not null,
  period_to     date not null,
  revenue       numeric not null default 0,
  gross_margin  numeric not null default 0,
  margin_pct    numeric,
  floor_pct     numeric not null,
  message       text not null,
  created_at    timestamptz not null default now(),
  seen_at       timestamptz,
  unique (zone_id, period_key)
);

alter table public.zone_pnl_alert enable row level security;
drop policy if exists zone_pnl_alert_admin on public.zone_pnl_alert;
create policy zone_pnl_alert_admin on public.zone_pnl_alert
  for select to authenticated
  using (public.get_my_role() in ('admin','super_admin'));

create or replace function public.zone_pnl_scan(p_period text default 'month')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_p jsonb := public._c694_period(p_period);
  v_floor numeric := coalesce((select (value #>> '{}')::numeric from public.app_settings
                                where key = 'zone_pnl_margin_floor_pct'), 6.0);
  z record; v_slice jsonb; v_n int := 0; v_msg text;
begin
  for z in select id, name from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    v_slice := public._c694_zone_slice(z.id::smallint,
                 (v_p->>'from')::date, (v_p->>'to')::date, false);
    -- A zone that billed nothing has no margin to be under a floor. Reporting
    -- one would fill the inbox with every dormant zone, every run.
    continue when coalesce((v_slice->>'revenue')::numeric, 0) = 0;
    continue when (v_slice->>'margin_pct') is null;
    continue when (v_slice->>'margin_pct')::numeric >= v_floor;

    v_msg := replace(replace(replace(public._pnl_c('zone.margin_alert'),
               '{zone}', z.name),
               '{pct}', to_char((v_slice->>'margin_pct')::numeric, 'FM990.00')),
               '{threshold}', to_char(v_floor, 'FM990.##'));

    insert into public.zone_pnl_alert (zone_id, period_key, period_from, period_to,
      revenue, gross_margin, margin_pct, floor_pct, message)
    values (z.id::smallint,
            (v_p->>'key') || ':' || (v_p->>'from'),
            (v_p->>'from')::date, (v_p->>'to')::date,
            (v_slice->>'revenue')::numeric, (v_slice->>'gross_margin')::numeric,
            (v_slice->>'margin_pct')::numeric, v_floor, v_msg)
    -- One row per zone per period: a nightly scan must not file the same
    -- warning thirty times before somebody reads it.
    on conflict (zone_id, period_key) do update
      set revenue = excluded.revenue, gross_margin = excluded.gross_margin,
          margin_pct = excluded.margin_pct, message = excluded.message;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'period', v_p->>'key',
                            'floor_pct', v_floor, 'zones_under_floor', v_n);
end $function$;

comment on function public.zone_pnl_scan(text) is
  'CHANGE #694 — files a zone whose margin is under the floor. One row per '
  'zone per period, so a nightly run cannot spam the inbox.';

-- On the ONE dispatcher (never a bare */N schedule), in the quiet window.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, note,
                              base_interval_s, run_at_ist, dml)
values ('zone_pnl_margin_scan', 950, 'poll',
        null, 'select public.zone_pnl_scan(''month'')', true,
        'CHANGE #694 — reports a zone running under the margin floor.',
        null, '02:40', true)
on conflict (name) do update
  set work_sql = excluded.work_sql, note = excluded.note, enabled = true;

-- ── 7. the doors — THREE rows, not two ─────────────────────────────────────
-- surface_route (the door) + feature_registry (the tile) are the two every
-- migration remembers. access_role_default is the third, and it is auto-seeded
-- with can_view=false for 'admin' and 'partner' — so without it #653 refuses
-- the route, the deep link resolves, the RPC answers, and the screen still
-- never opens. #713 shipped and was verified live before that was noticed.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, description)
values
  ('admin.zone_pnl', 'Zone P&L', 'Money', 'rule', 'zone_pnl', 58, 'medibo',
   false, 'none', true, 'money', 'dashboard',
   array['admin','super_admin'],
   'CHANGE #694 — revenue, costs, commission and delivery payouts per zone per period, every zone side by side.'),
  ('partner.zone_pnl', 'Zone P&L', 'Money', 'rule', 'partner_zone_pnl', 59, 'partner',
   true, 'read', true, 'money', 'dashboard',
   array['partner','admin','super_admin'],
   'CHANGE #694 — the partner''s own zone: the same numbers its settlement statement is built from.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      route_key = excluded.route_key, roles_allowed = excluded.roles_allowed,
      surface = excluded.surface, partner_eligible = excluded.partner_eligible,
      default_access = excluded.default_access,
      description = excluded.description, is_active = true;

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('zone_pnl', 'admin.zone_pnl', 'feature', 'home_shell',
   'CHANGE #694 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true),
  ('partner_zone_pnl', 'partner.zone_pnl', 'feature', 'partner_home_screen',
   'CHANGE #694 — the partner console''s own door onto the same screen, zone-clamped by zone_pnl().', true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true;

-- THE THIRD ROW. Without these the tile renders and the tap does nothing.
insert into public.access_role_default (role, feature_key, can_view, can_write) values
  ('admin',       'admin.zone_pnl',   true,  false),
  ('super_admin', 'admin.zone_pnl',   true,  true),
  ('partner',     'partner.zone_pnl', true,  false),
  ('admin',       'partner.zone_pnl', true,  false),
  ('super_admin', 'partner.zone_pnl', true,  true)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write;

-- ── 8. the P&L as a document ───────────────────────────────────────────────
-- The renderer (bill-render) draws whatever the payload describes — its own
-- comment says "the column widths arrive in the payload — so a fourth document
-- kind is a payload, not a code change". So this is a payload and one branch,
-- and the Flutter side reuses partner_doc_request/partner_doc_status verbatim.
insert into public.pnl_label (key, label) values
  ('zone.doc_title',    'Zone P&L — {zone}'),
  ('zone.doc_subtitle', 'Generated {at}'),
  ('zone.doc_period',   'Period'),
  ('zone.doc_zone',     'Zone'),
  ('zone.doc_orders',   'Orders'),
  ('zone.col_line',     'Line'),
  ('zone.col_amount',   'Amount'),
  ('zone.doc_note',     'Every figure here comes from the same records your settlement statement is built from.')
on conflict (key) do update set label = excluded.label;

create or replace function public._c694_doc_payload(p_zone smallint, p_period text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v jsonb; z jsonb; v_p jsonb; v_rows jsonb; v_title text;
begin
  v := public.zone_pnl(p_zone, p_period);
  if coalesce(v->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(v->>'error','not_found'));
  end if;
  z := v->'zones'->0;
  if z is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  v_p := v->'period';

  -- The document prints the SAME lines the screen printed, already filtered by
  -- partner_visible: a partner's PDF can never carry a line its own screen
  -- would not show it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', e->>'label', 'amount', e->>'amount_display')), '[]'::jsonb)
    into v_rows from jsonb_array_elements(z->'lines') e;

  v_title := replace(public._pnl_c('zone.doc_title'), '{zone}',
                     coalesce(z->>'zone_name','—'));

  return jsonb_build_object('ok', true,
    'stamp', md5(coalesce(z->>'revenue','') || coalesce(z->>'gross_margin','')
                 || coalesce(z->>'partner_share','') || coalesce(z->>'orders','')
                 || coalesce(v_p->>'from','') || coalesce(v_p->>'to','')),
    'file_name', 'zone-pnl-' || coalesce(z->>'zone_id','0') || '-'
                 || coalesce(v_p->>'from','') || '.pdf',
    'title', v_title,
    'doc', jsonb_build_object(
      'title', v_title,
      'subtitle', replace(public._pnl_c('zone.doc_subtitle'), '{at}',
                          public.ist_fmt(now(), 'dmy_hm')),
      'brand', public._c('partner_doc.doc_brand'),
      'header', jsonb_build_array(
        jsonb_build_object('label', public._pnl_c('zone.doc_zone'),
                           'value', coalesce(z->>'zone_name','—')),
        jsonb_build_object('label', public._pnl_c('zone.doc_period'),
                           'value', coalesce(v_p->>'from','') || ' → ' || coalesce(v_p->>'to','')),
        jsonb_build_object('label', public._pnl_c('zone.doc_orders'),
                           'value', coalesce(z->>'orders','0'))),
      'sections', jsonb_build_array(
        jsonb_build_object(
          'heading', public._pnl_c('zone.costs_heading'),
          'columns', jsonb_build_array(
            jsonb_build_object('key','label','label',public._pnl_c('zone.col_line'),
                               'align','left','width',330),
            jsonb_build_object('key','amount','label',public._pnl_c('zone.col_amount'),
                               'align','right','width',110)),
          'rows', v_rows,
          'empty_label', public._pnl_c('zone.empty'))),
      'totals', jsonb_build_array(
        jsonb_build_object('label', public._pnl_c('zone.tile_gross'),
                           'value', z->>'gross_display'),
        jsonb_build_object('label', public._pnl_c('zone.tile_partner'),
                           'value', z->>'partner_display'),
        jsonb_build_object('label', public._pnl_c('zone.tile_medibo'),
                           'value', z->>'medibo_display')),
      'notes', jsonb_build_array(public._pnl_c('zone.doc_note')),
      'footer', public._c('partner_doc.footer')));
end $function$;

comment on function public._c694_doc_payload(smallint, text) is
  'CHANGE #694 — the zone P&L as a bill-render payload. Prints the SAME lines '
  'the screen printed, already filtered by pnl_line_type.partner_visible.';

-- ── 9. the anon fence ──────────────────────────────────────────────────────
-- `revoke ... from anon` is NOT enough: every function is created with an
-- implicit GRANT EXECUTE TO PUBLIC, and anon inherits that. Revoking from
-- `anon` alone leaves the PUBLIC grant standing, so the anon key — which
-- ships inside the web bundle and the APK — could still call the zone P&L.
-- Caught by privileged_rpcs_are_not_anon in the same command that wrote it.
revoke all on function public.zone_pnl(smallint, text) from public, anon;
revoke all on function public.zone_pnl_scan(text) from public, anon;
revoke all on function public._c694_zone_slice(smallint, date, date, boolean) from public, anon;
revoke all on function public._c694_doc_payload(smallint, text) from public, anon;
revoke all on function public._c694_period(text) from public, anon;

grant execute on function public.zone_pnl(smallint, text) to authenticated;
grant execute on function public._c694_doc_payload(smallint, text) to authenticated;

-- ── 10. the export, actually reachable ─────────────────────────────────────
-- Section 8 built the P&L as a bill-render payload and stopped there: nothing
-- could ASK for it. `partner_doc_request` only knew 'agreement' and
-- 'statement', so `_c694_doc_payload` was an orphan and the screen's
-- `export_label` labelled a button that did not exist. This section closes
-- spec item 3 — the same statement pattern, one more kind.

insert into public.pnl_label (key, label) values
  ('zone.export_none',  'This zone has no partner yet, so there is nobody to send it to.'),
  ('zone.export_kind',  'zone_pnl')
on conflict (key) do update set label = excluded.label;

-- Who owns a zone. An admin exporting a zone files the document against that
-- zone's partner (partner_document.partner_id is NOT NULL and carries the
-- storage prefix), so a zone with no active partner has no export at all —
-- said in the backend's words rather than a dead button.
create or replace function public._c694_zone_owner(p_zone smallint)
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $function$
  select rp.id from public.region_partners rp
   where rp.zone_id = p_zone and rp.is_active
   order by rp.id limit 1
$function$;

comment on function public._c694_zone_owner(smallint) is
  'CHANGE #694 — the active region partner that owns a zone, for filing the '
  'zone P&L document against.';

-- The export descriptor the card renders. `has` is the backend''s decision,
-- the label is the backend''s wording, and the kind and the ref are the
-- backend''s too — Dart never assembles a document reference.
create or replace function public._c694_export(p_zone smallint, p_period_key text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'has',   public._c694_zone_owner(p_zone) is not null,
    'label', public._pnl_c('zone.export_label'),
    'kind',  public._pnl_c('zone.export_kind'),
    'ref',   'z' || p_zone::text || '-' || coalesce(p_period_key, 'month'),
    'note',  case when public._c694_zone_owner(p_zone) is null
                  then public._pnl_c('zone.export_none') else '' end)
$function$;

comment on function public._c694_export(smallint, text) is
  'CHANGE #694 — the Send-as-PDF descriptor for one zone slice: has/label/'
  'kind/ref, so the screen carries the backend''s own document reference.';

revoke all on function public._c694_zone_owner(smallint) from public, anon;
revoke all on function public._c694_export(smallint, text) from public, anon;
grant execute on function public._c694_zone_owner(smallint) to authenticated;
grant execute on function public._c694_export(smallint, text) to authenticated;

-- ── 11. the export, asked for and rendered ─────────────────────────────────
-- Both of these already existed; each gains ONE branch for kind='zone_pnl'.
-- Replaced whole because that is what `create or replace function` means —
-- the rest of each body is byte-for-byte what was live before this change.

CREATE OR REPLACE FUNCTION public.partner_doc_render_input(p_doc_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.partner_document%rowtype; pay jsonb;
begin
  select * into d from public.partner_document where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error','doc_not_found'); end if;

  update public.partner_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  if d.kind = 'agreement' then
    pay := public._c692_agreement_doc_payload(d.ref_key::bigint);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'partner-receipts',
      'path', 'p' || d.partner_id::text || '/agreement/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'agreement.pdf'),
      'document', pay->'doc');
  end if;

  -- CHANGE #694 — the zone P&L, drawn by the same renderer. ref_key is
  -- 'z<zone>-<period>', which is also the storage file name, so the document
  -- for March never overwrites the document for April.
  if d.kind = 'zone_pnl' then
    pay := public._c694_doc_payload(
             nullif(regexp_replace(split_part(d.ref_key, '-', 1), '\D', '', 'g'),'')::smallint,
             coalesce(nullif(split_part(d.ref_key, '-', 2), ''), 'month'));
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'partner-receipts',
      'path', 'p' || d.partner_id::text || '/zone_pnl/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'zone-pnl.pdf'),
      'document', pay->'doc');
  end if;

  pay := public._c466_statement_payload(d.partner_id, d.ref_key::bigint);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'partner-receipts',
    'path', 'p' || d.partner_id::text || '/statement/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'statement.pdf'),
    'document', pay->'doc');
end $function$;

CREATE OR REPLACE FUNCTION public.partner_doc_request(p_kind text, p_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  v_pid bigint := public.my_partner_id();
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_period bigint; v_sig bigint; pay jsonb; d public.partner_document%rowtype; v_id uuid;
  v_zone smallint; v_pk text; v_ref text;
  s public.partner_agreement_signature%rowtype;
begin
  if coalesce(p_kind,'') = 'agreement' then
    v_sig := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
    select * into s from public.partner_agreement_signature where id = v_sig;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('partner_doc.err_not_found'));
    end if;
    if v_pid is null and v_admin then v_pid := s.partner_id; end if;
    if v_pid is distinct from s.partner_id and not v_admin then
      return jsonb_build_object('ok', false, 'error','not_partner',
        'message', public._c('partner_doc.err_not_partner'));
    end if;
    v_pid := s.partner_id;

    pay := public._c692_agreement_doc_payload(v_sig);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
        'message', public._c('partner_doc.err_not_found'));
    end if;

    select * into d from public.partner_document
     where partner_id = v_pid and kind = 'agreement' and ref_key = v_sig::text;
    if found and d.status = 'ready' and coalesce(d.path,'') <> '' then
      return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
        'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
        'expires_s', 300, 'message', public._c('partner_doc.ready_message'));
    end if;

    insert into public.partner_document(
        partner_id, kind, ref_key, title, file_name, status, attempts,
        source_stamp, requested_by, requested_at, started_at, last_error)
    values (v_pid, 'agreement', v_sig::text,
            coalesce(pay#>>'{doc,title}',''),
            'agreement-v' || s.version::text || '.pdf',
            'queued', 0, 'sig' || v_sig::text, auth.uid(), now(), null, null)
    on conflict (partner_id, kind, ref_key) do update
      set status = 'queued', attempts = 0, requested_at = now(),
          started_at = null, last_error = null
    returning id into v_id;

    update public.partner_agreement_signature set doc_id = v_id, updated_at = now()
     where id = v_sig;

    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('supplier_doc_id', v_id),
      timeout_milliseconds := 20000);

    return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
      'poll_ms', 1500, 'message', public._c('partner_doc.building_message'));
  end if;

  -- CHANGE #694 — the zone P&L as a document. Section 8 built the payload and
  -- nothing could ask for it; this is the ask. The role fence is zone_pnl()'s
  -- own (a partner reads its own zone whatever it names), and the document is
  -- filed against the partner that owns the zone because partner_document
  -- carries the storage prefix.
  if coalesce(p_kind,'') = 'zone_pnl' then
    v_zone := nullif(regexp_replace(split_part(coalesce(p_ref,''), '-', 1), '\D', '', 'g'),'')::smallint;
    v_pk   := nullif(split_part(coalesce(p_ref,''), '-', 2), '');
    if v_pid is not null then v_zone := public.partner_zone_id(); end if;
    if v_zone is null or not (v_admin or v_pid is not null) then
      return jsonb_build_object('ok', false, 'error','not_partner',
        'message', public._c('partner_doc.err_not_partner'));
    end if;
    if v_pid is null then v_pid := public._c694_zone_owner(v_zone); end if;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('partner_doc.err_not_found'));
    end if;

    pay := public._c694_doc_payload(v_zone, coalesce(v_pk, 'month'));
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
        'message', public._c('partner_doc.err_not_found'));
    end if;

    v_ref := 'z' || v_zone::text || '-' || coalesce(v_pk, 'month');
    select * into d from public.partner_document
     where partner_id = v_pid and kind = 'zone_pnl' and ref_key = v_ref;
    -- The stamp is the figures themselves, so a period that has moved on
    -- rebuilds instead of handing back yesterday's PDF.
    if found and d.status = 'ready' and coalesce(d.path,'') <> ''
       and d.source_stamp is not distinct from (pay->>'stamp') then
      return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
        'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
        'expires_s', 300, 'message', public._c('partner_doc.ready_message'));
    end if;

    insert into public.partner_document(
        partner_id, kind, ref_key, title, file_name, status, attempts,
        source_stamp, requested_by, requested_at, started_at, last_error)
    values (v_pid, 'zone_pnl', v_ref, pay->>'title', pay->>'file_name',
            'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
    on conflict (partner_id, kind, ref_key) do update
      set title = excluded.title, file_name = excluded.file_name,
          status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
          requested_by = excluded.requested_by, requested_at = now(),
          started_at = null, last_error = null
    returning id into v_id;

    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('supplier_doc_id', v_id),
      timeout_milliseconds := 20000);

    return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
      'poll_ms', 1500, 'message', public._c('partner_doc.building_message'));
  end if;

  if v_pid is null and v_admin then
    select p.partner_id into v_pid from partner_settlement_periods p
     where p.id = nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  end if;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','not_partner',
      'message', public._c('partner_doc.err_not_partner'));
  end if;
  if coalesce(p_kind,'') <> 'statement' then
    return jsonb_build_object('ok', false, 'error','unknown_kind',
      'message', public._c('partner_doc.err_unknown_kind'));
  end if;

  v_period := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  if v_period is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('partner_doc.err_not_found'));
  end if;

  pay := public._c466_statement_payload(v_pid, v_period);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public._c('partner_doc.err_not_found'));
  end if;

  select * into d from public.partner_document
   where partner_id = v_pid and kind = p_kind and ref_key = v_period::text;

  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('partner_doc.ready_message'),
      'gst', pay->'gst');
  end if;

  insert into public.partner_document(
      partner_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (v_pid, p_kind, v_period::text, pay->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (partner_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public._c('partner_doc.building_message'),
    'gst', pay->'gst');
end $function$;

comment on function public.partner_doc_request(text, text) is
  'Partner documents: agreement (CHANGE #692), settlement statement (CMD #466) '
  'and the zone P&L (CHANGE #694). Every kind files a partner_document row and '
  'hands bill-render the same envelope.';

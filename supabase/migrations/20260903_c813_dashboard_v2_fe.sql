-- CHANGE #813 — Dashboard v2, the frontend pass. Everything the screen needs
-- to be scannable is composed HERE; the Flutter side only draws it.
--
-- #812 shipped the payload. This command asks the SCREEN for five things the
-- payload could not answer yet, so each one is a backend gap first:
--
--   1. a sticky header that says WHEN and WHERE you are ("Today · Raipur Zone")
--   2. a strip where every number is a door (tap = that filtered list) and can
--      be shared to WhatsApp on a long press — the sentence and the wa.me URL
--      are composed here, never assembled in Dart
--   3. a needs-you queue that carries FOUR states, not just "overdue":
--      overdue (red) · due today (amber) · done (green) · open (grey)
--   4. zone cards that switch the dashboard's zone when tapped
--   5. a 30-second refresh cadence (the screen must not choose one)

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Percent-encoding, so a share link is built where the sentence is.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._url_encode(p_text text)
returns text
language sql
immutable
set search_path to 'public'
as $fn$
  select coalesce(string_agg(
           case when t.ch ~ '^[A-Za-z0-9_.~-]$' then t.ch
                else upper(regexp_replace(
                       encode(convert_to(t.ch, 'UTF8'), 'hex'), '(..)', '%\1', 'g')) end,
           '' order by t.i), '')
    from unnest(string_to_array(coalesce(p_text, ''), null)) with ordinality as t(ch, i);
$fn$;

grant execute on function public._url_encode(text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. A metric is a DOOR. Where each number goes is data, not a Dart switch.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.dashboard_metric add column if not exists route_key text not null default '';
alter table public.dashboard_metric add column if not exists deep_link text not null default '';

update public.dashboard_metric set route_key = v.route_key, deep_link = v.deep_link
  from (values
    ('orders_received', 'customer_orders',  '/admin/go/fulfillment'),
    ('to_dispatch',     'pack',             '/admin/go/fulfillment'),
    ('delivered',       'delivery_ops',     '/admin/delivery-ops'),
    ('money_in',        'money',            ''),
    ('money_out',       'supplier_payment', '')
  ) as v(key, route_key, deep_link)
 where public.dashboard_metric.key = v.key;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The new wording. Every one of these is a sentence the screen prints.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('dash.header',        to_jsonb('{when} · {zone}'::text)),
  ('dash.today',         to_jsonb('Today'::text)),
  ('dash.share_action',  to_jsonb('Share on WhatsApp'::text)),
  ('dash.share_metric',  to_jsonb('{label}: {value} ({delta}) · {zone} · {date} · mediBO'::text)),
  ('dash.share_hint',    to_jsonb('Long-press a number to share it'::text)),
  ('dash.needs_due',     to_jsonb('due in {d}'::text)),
  ('dash.needs_open',    to_jsonb('{d} left'::text)),
  ('dash.needs_done',    to_jsonb('done {d}'::text)),
  ('dash.needs_view',    to_jsonb('View'::text)),
  ('dash.zone_open',     to_jsonb('Show this zone'::text)),
  ('dash.search_hint',   to_jsonb('Order code, phone, pharmacy, supplier or product'::text))
on conflict (key) do update set value = excluded.value;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE SNAPSHOT — needs-you now carries four states and always offers up to
--    five rows. #812 listed OVERDUE work only, so the queue was empty on a good
--    day and the screen had exactly two colours to show. Work that is merely
--    due today, work that is simply open, and work that was CLEARED today are
--    all part of "what needs me", and each one has its own tone.
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
  ops_all as (
    select o.id, o.label, o.sub_label, o.since, o.owner_label, o.stage_label,
           o.next_action,
           (extract(epoch from (now() - o.since)) / 60.0 - o.sla_minutes)::numeric  as over_min,
           o.since + make_interval(mins => o.sla_minutes::int)           as due_at,
           null::text as action_id, 'ops'::text as source
      from ops o
  ),
  exc_all as (
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
           (extract(epoch from (now() - r.since)) / 60.0 - (x.sla_hours * 60.0))::numeric as over_min,
           r.since + make_interval(hours => x.sla_hours::int)          as due_at,
           r.reason_code || ':' || r.ref_id                            as action_id,
           'exception'::text                                           as source
      from public._exception_rows() r
      join public.exception_reason x
        on x.reason_code = r.reason_code and x.enabled
      left join public.exception_state s
        on s.reason_code = r.reason_code and s.ref_id = r.ref_id
     where coalesce(s.status, 'open') <> 'closed'
       and (p_zone = 0 or r.zone_id = p_zone or r.zone_id is null)
  ),
  -- Cleared today: the green row. Bounded to five and to one IST day, so the
  -- snapshot stays the cache read the rg rule requires.
  done_rows as (
    select 'done:' || s.reason_code || ':' || s.ref_id                 as id,
           public._c('exc.reason.' || s.reason_code)                   as label,
           coalesce(nullif(s.note, ''), nullif(s.outcome_code, ''), '') as sub_label,
           s.closed_at                                                 as since,
           coalesce(nullif(s.owner_label, ''), '')                     as owner_label,
           public._c('exc.reason.' || s.reason_code)                   as stage_label,
           ''::text                                                    as next_action,
           null::numeric                                               as over_min,
           s.closed_at                                                 as due_at,
           null::text                                                  as action_id,
           'done'::text                                                as source
      from public.exception_state s
     where s.status = 'closed'
       and s.closed_at is not null
       and (s.closed_at at time zone 'Asia/Kolkata')::date = v_today
       and (p_zone = 0 or s.zone_id = p_zone or s.zone_id is null)
     order by s.closed_at desc
     limit 5
  ),
  merged as (
    select u.*,
           case when u.source = 'done'                                  then 'done'
                when u.over_min > 0                                     then 'overdue'
                when (u.due_at at time zone 'Asia/Kolkata')::date <= v_today then 'due_today'
                else 'open' end as state
      from (select * from ops_all
            union all select * from exc_all
            union all select * from done_rows) u
  ),
  ranked as (
    select m.*,
           case m.state when 'overdue' then 1 when 'due_today' then 2
                        when 'open' then 3 else 4 end as bucket,
           case when m.state = 'done' then extract(epoch from m.due_at)::numeric
                else coalesce(m.over_min, 0)::numeric end as rank_val
      from merged m
  ),
  picked as (
    select * from ranked order by bucket asc, rank_val desc, due_at asc limit 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          m.id,
           'label',       m.label,
           'sub_label',   m.sub_label,
           'stage_label', m.stage_label,
           'state',       m.state,
           'age_label',   public.ops_age_label(m.since),
           'over_label',  case m.state
             when 'overdue' then replace(public._c('dash.needs_over'), '{d}',
                                         public.ops_dur_label((m.over_min * 60.0)::numeric))
             when 'due_today' then replace(public._c('dash.needs_due'), '{d}',
                                         public.ops_dur_label((abs(m.over_min) * 60.0)::numeric))
             when 'open' then replace(public._c('dash.needs_open'), '{d}',
                                         public.ops_dur_label((abs(m.over_min) * 60.0)::numeric))
             else replace(public._c('dash.needs_done'), '{d}',
                                         public.ops_age_label(m.since)) end,
           'owner_label', case when coalesce(nullif(m.owner_label, ''), '') = '' then ''
                               else replace(public._c('dash.needs_owner'), '{owner}', m.owner_label) end,
           'tone',        case m.state when 'overdue' then 'bad'
                                       when 'due_today' then 'warn'
                                       when 'done' then 'good'
                                       else 'neutral' end,
           'source',      m.source,
           'action',      case
             when m.state = 'done'
               then jsonb_build_object('has', false, 'kind', '', 'label', '',
                                       'rpc', '', 'args', '{}'::jsonb, 'route', '')
             when m.source = 'exception'
               then jsonb_build_object('has', true, 'kind', 'rpc',
                      'label', coalesce(nullif(m.next_action, ''), public._c('dash.needs_action')),
                      'rpc', 'exceptions_action',
                      'args', jsonb_build_object('p_id', m.action_id),
                      'route', 'exceptions')
             when m.state = 'overdue'
               then jsonb_build_object('has', true, 'kind', 'route',
                      'label', coalesce(nullif(m.next_action, ''), public._c('dash.needs_action')),
                      'rpc', '', 'args', '{}'::jsonb, 'route', 'ops_board')
             else jsonb_build_object('has', true, 'kind', 'route',
                      'label', public._c('dash.needs_view'),
                      'rpc', '', 'args', '{}'::jsonb, 'route', 'ops_board') end)
           order by m.bucket asc, m.rank_val desc, m.due_at asc), '[]'::jsonb)
    into v_needs
    from picked m;

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

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE STRIP — every number is now a door and a share. The sentence that
--    goes to WhatsApp and the wa.me link are composed here so the app has
--    nothing left to decide: it opens `share.url` and prints `share.label`.
--    The extra two arguments are the zone and date that sentence names.
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public._dashboard_strip(smallint, date);

create or replace function public._dashboard_strip(
  p_zone smallint,
  p_date date,
  p_zone_label text default '',
  p_date_label text default '')
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
           m.route_key, m.deep_link,
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
  ), disp as (
    select v.*,
           case when v.kind = 'money' then public.inr_money_compact(v.today)
                else v.today::bigint::text end                      as value_display,
           case
             when v.today = v.yday then public._c('dash.delta_flat')
             when v.today > v.yday then replace(public._c('dash.delta_up'), '{n}',
                    case when v.kind = 'money' then public.inr_money_compact(v.today - v.yday)
                         else (v.today - v.yday)::bigint::text end)
             else replace(public._c('dash.delta_down'), '{n}',
                    case when v.kind = 'money' then '-' || public.inr_money_compact(v.yday - v.today)
                         else (v.today - v.yday)::bigint::text end) end as delta_display,
           case
             when v.today = v.yday then 'neutral'
             when (v.today > v.yday) = v.higher_is_better then 'good'
             else 'warn' end                                        as delta_tone,
           case when v.today = v.yday then 'flat'
                when v.today > v.yday then 'up'
                else 'down' end                                     as delta_arrow
      from vals v
  ), shared as (
    select d.*,
           replace(replace(replace(replace(replace(
             public._c('dash.share_metric'),
             '{label}', d.label),
             '{value}', d.value_display),
             '{delta}', d.delta_display),
             '{zone}',  coalesce(nullif(p_zone_label, ''), '')),
             '{date}',  coalesce(nullif(p_date_label, ''), '')) as share_text
      from disp d
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   s.key,
           'label', s.label,
           'short_label', s.short_label,
           'kind',  s.kind,
           'value', case when s.kind = 'money' then round(s.today) else s.today end,
           'value_display', s.value_display,
           'delta', case when s.kind = 'money' then round(s.today - s.yday) else s.today - s.yday end,
           'delta_display', s.delta_display,
           'delta_tone', s.delta_tone,
           'delta_arrow', s.delta_arrow,
           'route_key', s.route_key,
           'deep_link', s.deep_link,
           'can_open', (s.route_key <> '' or s.deep_link <> ''),
           'share', jsonb_build_object(
             'has',   true,
             'label', public._c('dash.share_action'),
             'text',  s.share_text,
             'url',   'https://wa.me/?text=' || public._url_encode(s.share_text)),
           'spark', coalesce(s.spark, '[]'::jsonb)) order by s.sort_order), '[]'::jsonb)
    into v_out
    from shared s;
  return v_out;
end $fn$;

revoke all on function public._dashboard_strip(smallint, date, text, text) from public, anon;
grant execute on function public._dashboard_strip(smallint, date, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. dashboard_v2 — plus the sticky header's own sentence, a 30-second cadence
--    and zone cards that DO something when tapped.
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_scope   smallint;
  v_date    date;
  v_zlabel  text;
  v_dlabel  text;
  v_when    text;
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
  v_today   date     := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_partner is null and not v_is_admin then
    return jsonb_build_object('ok', false, 'allowed', false,
      'error', 'not_authorized',
      'title', public._c('dash.title'),
      'message', public._c('dash.not_authorized'),
      'strip', '[]'::jsonb, 'needs_you', '[]'::jsonb, 'funnel', '[]'::jsonb,
      'alerts', '[]'::jsonb, 'quick_actions', '[]'::jsonb, 'zone_cards', '[]'::jsonb);
  end if;

  if v_partner is not null then
    v_zone := public.partner_zone_id();
  else
    v_zone := coalesce(p_zone, public.admin_active_zone());
  end if;
  v_scope  := coalesce(v_zone, 0)::smallint;
  v_date   := coalesce(p_date, public.admin_active_date(), v_today);
  v_zlabel := coalesce((select z.name from public.zones z where z.id = v_zone),
                       public._c('dash.all_zones'));
  v_dlabel := public.ist_fmt(v_date::timestamptz, 'day_mon_year');
  -- "Today · Raipur Zone" on the day itself, the date on any other day. The
  -- header never says "Today" about yesterday.
  v_when   := case when v_date = v_today then public._c('dash.today') else v_dlabel end;

  select c.payload into v_ops from public.dashboard_cache c
   where c.cache_key = 'ops:' || v_scope::text;
  v_ops := coalesce(v_ops, '{}'::jsonb);

  v_strip := public._dashboard_strip(v_scope, v_date, v_zlabel, v_dlabel);

  v_greet := case when v_hour < 12 then public._c('dash.greeting_morning')
                  when v_hour < 17 then public._c('dash.greeting_afternoon')
                  else public._c('dash.greeting_evening') end;
  v_accept := coalesce((v_ops->>'accept_open')::int, 0);
  -- The queue now carries four states, so "the top row" is only the thing to
  -- do first when it is actually OVERDUE.
  select e into v_top
    from jsonb_array_elements(coalesce(v_ops->'needs_you', '[]'::jsonb)) e
   where e->>'state' = 'overdue'
   limit 1;
  v_first  := case
    when v_accept = 1 then public._c('dash.first_thing_one')
    when v_accept > 1 then replace(public._c('dash.first_thing'), '{n}', v_accept::text)
    when v_top is not null and v_top <> 'null'::jsonb
      then replace(public._c('dash.first_thing_needs'), '{label}', coalesce(v_top->>'label',''))
    else public._c('dash.first_thing_clear') end;

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
           <= v_today + 30;
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

  -- Zone cards: super admin only. A card now SWITCHES the dashboard to its
  -- zone — the same server-side scope the picker writes, so the whole console
  -- follows, not just this screen.
  if v_super and v_partner is null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'zone_id', z.id, 'zone_label', z.name,
             'metrics', public._dashboard_strip(z.id::smallint, v_date, z.name, v_dlabel),
             'is_current', (z.id = v_zone),
             'action', jsonb_build_object(
               'has', true, 'kind', 'rpc',
               'label', public._c('dash.zone_open'),
               'rpc', 'admin_set_zone_scope',
               'args', jsonb_build_object('p_zone_id', z.id),
               'route', ''),
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
    'the_date', v_date, 'date_label', v_dlabel,
    'title', public._c('dash.title'),
    -- The sticky header's own line, composed here: "Today · Raipur Zone".
    'header', jsonb_build_object(
      'title', replace(replace(public._c('dash.header'), '{when}', v_when), '{zone}', v_zlabel),
      'when_label', v_when,
      'zone_label', v_zlabel,
      'sub_label', v_dlabel,
      'is_today', (v_date = v_today),
      'search_hint', public._c('dash.search_hint')),
    'greeting', v_greet,
    'first_thing', v_first,
    'strip', jsonb_build_object(
      'title', public._c('dash.strip_title'),
      'share_hint', public._c('dash.share_hint'),
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
    -- 30 seconds: the cadence is the backend's call, not a Dart constant.
    'refresh_ms', 30000);
end $fn$;

revoke all on function public.dashboard_v2(date, smallint) from public, anon;
grant execute on function public.dashboard_v2(date, smallint) to authenticated;

-- Rebuild the snapshot now so the four tones are live the moment this lands.
select public.dashboard_ops_refresh();

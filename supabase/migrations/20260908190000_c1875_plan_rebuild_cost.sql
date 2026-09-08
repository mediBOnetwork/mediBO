-- CMD #1875 — Route plans: rebuild from the CURRENT S Leads, and a ₹ cost per
-- route / per converted lead.
--
-- Two gaps this closes.
--
-- 1. A plan was a photograph. route_plan_build() froze city + classes + visit
--    filter at build time and _route_plan_build_road() re-read scraped_leads
--    with its OWN four conditions — which know nothing about the S Leads list
--    an admin actually works from: archived leads (#1869), non-targets,
--    already-matched shops and the header zone/date (#1868) were all still
--    routed. So a rep was sent to shops the admin had archived that morning.
--    route_plan_rebuild(plan_id) re-runs the builder over exactly the leads
--    the S Leads default list would show RIGHT NOW, in admin_active_zone() on
--    admin_active_date(). The old plan is kept (status 'superseded',
--    superseded_by -> the new id) so its routes, assignments and check-ins
--    survive as the previous version; the new plan is the active one.
--
--    The lead set is handed to the builder as ROWS (route_plan_pool), not as
--    another set of filter arguments — the whole point is that the pool is the
--    S Leads answer, not a re-derivation of it that can drift again.
--
-- 2. Nobody could say what a route COST. route_km_rate / route_hour_rate live
--    in app_settings (Om sets them; changing one is an UPDATE, never a deploy)
--    and every cost string — per route, per plan and per converted lead — is
--    formatted here in INR and printed verbatim by Flutter.
--
-- Idempotent: add-column-if-not-exists, create-if-not-exists, CREATE OR
-- REPLACE and ON CONFLICT DO NOTHING only.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Rates (backend-owned, editable without a deploy)
-- ─────────────────────────────────────────────────────────────────────────
insert into app_settings(key, value) values
  ('route_km_rate',   '12'::jsonb),
  ('route_hour_rate', '150'::jsonb)
on conflict (key) do nothing;

-- Whole-rupee money: inr_money() always prints paise, and a route cost of
-- "₹1,284.00" reads like an invoice line it is not.
create or replace function public._c1875_money(p numeric)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select regexp_replace(public.inr_money(round(coalesce(p, 0))), '\.00$', '');
$function$;

create or replace function public._c1875_km_rate()
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  select greatest(0, coalesce(
    (select nullif(value #>> '{}', '')::numeric from app_settings where key = 'route_km_rate'), 0));
$function$;

create or replace function public._c1875_hour_rate()
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  select greatest(0, coalesce(
    (select nullif(value #>> '{}', '')::numeric from app_settings where key = 'route_hour_rate'), 0));
$function$;

-- cost = km_rate x km + hour_rate x hours. One place, used by every caller.
create or replace function public._c1875_cost(p_km numeric, p_min integer)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  select round(
      public._c1875_km_rate()   * coalesce(p_km, 0)
    + public._c1875_hour_rate() * (coalesce(p_min, 0)::numeric / 60.0), 2);
$function$;

create or replace function public.route_rates_get()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_copy jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'routes.rates%';
  return jsonb_build_object(
    'ok',          true,
    'km_rate',     public._c1875_km_rate(),
    'hour_rate',   public._c1875_hour_rate(),
    'km_label',    coalesce(v_copy->>'routes.rates_km',    'Cost per km (₹)'),
    'hour_label',  coalesce(v_copy->>'routes.rates_hour',  'Cost per hour (₹)'),
    'title',       coalesce(v_copy->>'routes.rates_title', 'Route cost rates'),
    'hint',        coalesce(v_copy->>'routes.rates_hint',
                     'Used for every route cost. A change applies to all plans at once.'),
    'save_label',  coalesce(v_copy->>'routes.rates_save',   'Save'),
    'cancel_label',coalesce(v_copy->>'routes.rates_cancel', 'Cancel'),
    'current_label', replace(replace(
                       coalesce(v_copy->>'routes.rates_current', '{km} per km · {hour} per hour'),
                       '{km}',   public._c1875_money(public._c1875_km_rate())),
                       '{hour}', public._c1875_money(public._c1875_hour_rate())));
end;
$function$;

create or replace function public.route_rates_set(p_km_rate numeric, p_hour_rate numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_km numeric; v_hr numeric;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  v_km := greatest(0, round(coalesce(p_km_rate,   0), 2));
  v_hr := greatest(0, round(coalesce(p_hour_rate, 0), 2));

  insert into app_settings(key, value, updated_at, updated_by)
  values ('route_km_rate', to_jsonb(v_km), now(), auth.uid())
  on conflict (key) do update set value = excluded.value,
                                  updated_at = excluded.updated_at,
                                  updated_by = excluded.updated_by;
  insert into app_settings(key, value, updated_at, updated_by)
  values ('route_hour_rate', to_jsonb(v_hr), now(), auth.uid())
  on conflict (key) do update set value = excluded.value,
                                  updated_at = excluded.updated_at,
                                  updated_by = excluded.updated_by;

  return public.route_rates_get()
       || jsonb_build_object('toast',
            coalesce(public._c('routes.rates_saved'), 'Route cost rates updated'));
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Plan versions + the explicit lead pool
-- ─────────────────────────────────────────────────────────────────────────
alter table public.route_plans
  add column if not exists parent_plan_id uuid references public.route_plans(id) on delete set null,
  add column if not exists superseded_by  uuid references public.route_plans(id) on delete set null,
  add column if not exists version        integer not null default 1,
  add column if not exists source         text    not null default 'filters';

create table if not exists public.route_plan_pool (
  plan_id uuid   not null references public.route_plans(id)   on delete cascade,
  lead_id bigint not null references public.scraped_leads(id) on delete cascade,
  primary key (plan_id, lead_id)
);
alter table public.route_plan_pool enable row level security;

create index if not exists route_plan_pool_plan_idx on public.route_plan_pool(plan_id);
create index if not exists route_plans_parent_idx   on public.route_plans(parent_plan_id);

-- ─────────────────────────────────────────────────────────────────────────
-- 3. The S Leads pool — the SAME predicates get_scraped_leads() applies by
--    default, plus the two a route needs (a location, and visit eligibility).
--    Kept in one function so the list and the plan can never disagree again.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._c1875_sleads_pool(
  p_city    text,
  p_classes text[],
  p_visit   text[],
  p_min_score integer)
returns table(lead_id bigint)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select s.id
    from scraped_leads s
   where s.lat is not null
     and (p_city is null or s.city ilike p_city)
     -- header zone (NULL = all zones) and header date — never parameters
     and (public.admin_active_zone() is null
          or public.zone_resolve(s.district, s.city, false) = public.admin_active_zone())
     and (s.scraped_at is null
          or (s.scraped_at at time zone 'Asia/Kolkata')::date <= public.admin_active_date())
     -- S Leads defaults: archived out (#1869), non-targets out, matched out,
     -- permanently closed out.
     and s.status is distinct from 'archived'
     and coalesce(s.is_target, false)
     and s.matched_customer_id is null
     and s.matched_supplier_id is null
     and coalesce(s.business_status, 'OPERATIONAL') = 'OPERATIONAL'
     and coalesce(s.lead_score, 0) >= greatest(
           coalesce(p_min_score, 0),
           coalesce((select (value->'min_score'->>'default')::int
                       from app_settings where key = 'sleads_filters'), 0))
     -- the effective class is the one S Leads shows: a manual reclassify wins
     and (p_classes is null or coalesce(array_length(p_classes, 1), 0) = 0
          or coalesce(nullif(btrim(s.manual_class), ''), s.lead_class, 'other') = any(p_classes))
     -- revisit-eligible leads are IN (#1874 owns that rule)
     and public._c1874_visit_eligible(p_visit, s.visit_count, s.last_visit_status, s.revisit_after);
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The road builder honours a pool when the plan has one.
--    Same function, same algorithm — only the row source changes.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._route_plan_build_road(p_plan uuid, p_city text, p_classes text[], p_visit text[], p_k integer, p_min_score integer, p_dow integer, p_start_min integer, p_dwell integer DEFAULT 10)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '300s'
AS $function$
declare
  v_n int; v_k int;
  v_hub_lat numeric; v_hub_lng numeric;
  v_min_lat numeric; v_max_lat numeric; v_min_lng numeric; v_max_lng numeric;
  x bigint; v_tour bigint[];
  v_slice int; v_route uuid;
  v_seq int; v_cum_m int; v_closed int; v_leg_m int;
  v_arrive int; v_wait int; v_open boolean; v_no int; v_t int;
  v_prev bigint;
  v_total_km numeric; v_total_min int; v_home_m int;
  seg bigint[]; lead_row record; i int; v_from int; v_to int;
  GRID int := 1024;
  v_pool boolean := false;   -- CMD #1875
begin
  delete from route_plan_stops  where plan_id = p_plan;
  delete from route_plan_routes where plan_id = p_plan;
  select lat, lng into v_hub_lat, v_hub_lng from lead_hub where id = 1;

  create temp table _pts (
    lead_id bigint primary key, lat numeric, lng numeric, hours jsonb, hidx bigint, done boolean default false
  ) on commit drop;

  -- CMD #1875 — a plan built by route_plan_rebuild() carries its OWN lead set
  -- (route_plan_pool): exactly the leads the S Leads default list shows for
  -- the header zone and date. When there is no pool this is the original
  -- filter build, unchanged.
  select exists (select 1 from route_plan_pool q where q.plan_id = p_plan) into v_pool;

  insert into _pts (lead_id, lat, lng, hours)
  select s2.id, s2.lat, s2.lng, s2.hours_json
  from scraped_leads s2
  where s2.lat is not null
    and case when v_pool
      then exists (select 1 from route_plan_pool q
                    where q.plan_id = p_plan and q.lead_id = s2.id)
      else s2.city ilike p_city
       and s2.business_status = 'OPERATIONAL'
       and s2.lead_class = any(p_classes)
       and coalesce(s2.lead_score,0) >= p_min_score
       and public._c1874_visit_eligible(p_visit, s2.visit_count, s2.last_visit_status, s2.revisit_after)
    end;

  select count(*) into v_n from _pts;
  if v_n = 0 then raise exception 'no_leads_match_filters'; end if;
  v_k := greatest(1, least(p_k, v_n));
  update route_plans set speed_kmh = 46, total_leads = v_n where id = p_plan;

  select min(lat),max(lat),min(lng),max(lng) into v_min_lat,v_max_lat,v_min_lng,v_max_lng from _pts;

  -- Hilbert order for compact SLICING
  update _pts p set hidx = public._hilbert_d(
    least(GRID-1, floor((p.lng - v_min_lng) / nullif(v_max_lng - v_min_lng,0) * GRID)::int),
    least(GRID-1, floor((p.lat - v_min_lat) / nullif(v_max_lat - v_min_lat,0) * GRID)::int), 10);

  select array_agg(lead_id order by hidx, lat, lng) into v_tour from _pts;

  for v_slice in 1..v_k loop
    v_from := ((v_slice - 1) * v_n / v_k) + 1;
    v_to   := (v_slice * v_n / v_k);
    if v_to < v_from then continue; end if;
    seg := v_tour[v_from : v_to];
    if coalesce(array_length(seg,1),0) = 0 then continue; end if;

    -- RE-ORDER this slice nearest-neighbour by ROAD distance, starting from hub
    declare ordered bigint[] := '{}'; cur bigint := 0; nxt bigint; remaining bigint[] := seg;
    begin
      while array_length(remaining,1) > 0 loop
        -- nearest remaining by road distance from cur
        select r into nxt from unnest(remaining) r
        order by public._road_m(cur, r) limit 1;
        ordered := ordered || nxt;
        remaining := array_remove(remaining, nxt);
        cur := nxt;
      end loop;
      seg := public._tour_oropt_road(ordered, 6);   -- or-opt on road matrix
    end;

    insert into route_plan_routes (plan_id, seq, center_lat, center_lng)
    select p_plan, v_slice, avg(p.lat), avg(p.lng)
    from _pts p where p.lead_id = any(seg)
    returning id into v_route;

    v_prev := 0; v_t := p_start_min; v_seq := 0; v_cum_m := 0; v_closed := 0;

    for i in 1..array_length(seg,1) loop
      select p.hours into lead_row from _pts p where p.lead_id = seg[i];
      v_seq := v_seq + 1;
      v_leg_m := public._road_m(v_prev, seg[i]);   -- REAL road distance
      v_cum_m := v_cum_m + v_leg_m;
      v_arrive := v_t + ceil(public._road_s(v_prev, seg[i]) / 60.0)::int;
      v_wait := 0;
      v_open := lead_is_open_at(lead_row.hours, p_dow, least(v_arrive,1439)::int);
      if v_open is false then
        v_no := lead_next_open(lead_row.hours, p_dow, least(v_arrive,1439)::int);
        if v_no is not null and v_no > v_arrive and (v_no - v_arrive) <= 120 then
          v_wait := v_no - v_arrive; v_arrive := v_no; v_open := true;
        else v_closed := v_closed + 1; end if;
      end if;
      insert into route_plan_stops (plan_id, route_id, lead_id, seq,
                                    leg_km, cum_km, eta_min, wait_min, open_at_eta)
      values (p_plan, v_route, seg[i], v_seq,
              round(v_leg_m/1000.0,2), round(v_cum_m/1000.0,2), v_arrive, v_wait, coalesce(v_open,true));
      v_prev := seg[i];
    end loop;

    v_home_m := public._road_m(v_prev, 0);
    v_total_km := round((v_cum_m + v_home_m)/1000.0, 2);
    v_total_min := (v_t + ceil(public._road_s(v_prev,0)/60.0)::int) - p_start_min;

    update route_plan_routes rr set
      n_stops = v_seq, total_km = v_total_km, total_min = v_total_min, closed_count = v_closed,
      label = 'R' || v_slice || ' · ' ||
              coalesce((select mode() within group (order by sl.area)
                          from unnest(seg) ll join scraped_leads sl on sl.id = ll
                         where sl.area is not null), 'Zone')
    where rr.id = v_route;
  end loop;

  return v_n;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Copy. Every string this feature shows is here, so re-wording it is an
--    UPDATE on ui_copy and never a deploy.
-- ─────────────────────────────────────────────────────────────────────────
insert into ui_copy(key, value) values
  ('routes.rebuild_btn',        '"Rebuild from current leads"'::jsonb),
  ('routes.rebuild_title',      '"Rebuild from current leads"'::jsonb),
  ('routes.rebuild_body',       '"{n} leads pass the current S Leads filters for {zone} on {date}. This plan is kept as v{old}; the rebuilt plan becomes v{new}."'::jsonb),
  ('routes.rebuild_body_one',   '"1 lead passes the current S Leads filters for {zone} on {date}. This plan is kept as v{old}; the rebuilt plan becomes v{new}."'::jsonb),
  ('routes.rebuild_confirm',    '"Rebuild"'::jsonb),
  ('routes.rebuild_cancel',     '"Cancel"'::jsonb),
  ('routes.rebuild_empty',      '"No leads pass the current S Leads filters for this zone and date."'::jsonb),
  ('routes.rebuild_queued',     '"Rebuilding — v{n} is queued."'::jsonb),
  ('routes.rebuild_hint',       '"Uses the S Leads list as it stands now: archived, non-target and matched leads are left out."'::jsonb),
  ('routes.version_label',      '"v{n}"'::jsonb),
  ('routes.superseded_label',   '"Replaced by v{n}"'::jsonb),
  ('routes.cost_chip',          '"{cost} route cost"'::jsonb),
  ('routes.cost_plan',          '"{cost} plan cost"'::jsonb),
  ('routes.per_converted',      '"{cost} per converted lead"'::jsonb),
  ('routes.per_converted_none', '"No conversions yet"'::jsonb),
  ('routes.converted_n',        '"{n} converted"'::jsonb),
  ('routes.rates_btn',          '"Rates"'::jsonb),
  ('routes.rates_title',        '"Route cost rates"'::jsonb),
  ('routes.rates_km',           '"Cost per km (₹)"'::jsonb),
  ('routes.rates_hour',         '"Cost per hour (₹)"'::jsonb),
  ('routes.rates_hint',         '"Used for every route cost. A change applies to all plans at once."'::jsonb),
  ('routes.rates_save',         '"Save"'::jsonb),
  ('routes.rates_cancel',       '"Cancel"'::jsonb),
  ('routes.rates_current',      '"{km} per km · {hour} per hour"'::jsonb),
  ('routes.rates_saved',        '"Route cost rates updated"'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. The cost block — one shape, used by the route card and the plan summary.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._c1875_cost_block(
  p_km numeric, p_min integer, p_converted integer, p_scope text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cost numeric := public._c1875_cost(p_km, p_min);
  v_conv integer := greatest(0, coalesce(p_converted, 0));
  v_per  numeric := case when v_conv > 0 then round(v_cost / v_conv, 2) end;
begin
  return jsonb_build_object(
    'cost_inr',   v_cost,
    'cost_label', replace(
       coalesce(public._c(case when p_scope = 'plan' then 'routes.cost_plan'
                               else 'routes.cost_chip' end),
                case when p_scope = 'plan' then '{cost} plan cost' else '{cost} route cost' end),
       '{cost}', public._c1875_money(v_cost)),
    'converted', v_conv,
    'converted_label', case when v_conv > 0 then
       replace(coalesce(public._c('routes.converted_n'), '{n} converted'), '{n}', v_conv::text) end,
    'cost_per_converted', v_per,
    'cost_per_converted_label', case
       when v_per is not null then
         replace(coalesce(public._c('routes.per_converted'), '{cost} per converted lead'),
                 '{cost}', public._c1875_money(v_per))
       else coalesce(public._c('routes.per_converted_none'), 'No conversions yet') end,
    'has_conversions', v_conv > 0);
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. Rebuild — preview, then act.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.route_plan_rebuild_preview(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  pl      route_plans%rowtype;
  v_n     integer;
  v_zone  text;
  v_date  text;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  select * into pl from route_plans where id = p_plan_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'plan_not_found'); end if;

  select count(*) into v_n
    from public._c1875_sleads_pool(pl.city, pl.classes, pl.visit_filter, pl.min_score);

  v_zone := coalesce((select z.name from zones z where z.id = public.admin_active_zone()),
                     coalesce(public._c('routes_today.zone_all'), 'All zones'));
  v_date := to_char(public.admin_active_date(), 'DD/MM/YY');

  return jsonb_build_object(
    'ok',            true,
    'plan_id',       pl.id,
    'leads',         v_n,
    'can_rebuild',   v_n > 0,
    'title',         coalesce(public._c('routes.rebuild_title'), 'Rebuild from current leads'),
    'body', case when v_n = 0
      then coalesce(public._c('routes.rebuild_empty'),
                    'No leads pass the current S Leads filters for this zone and date.')
      else replace(replace(replace(replace(replace(
             case when v_n = 1
               then coalesce(public._c('routes.rebuild_body_one'),
                      '1 lead passes the current S Leads filters for {zone} on {date}. This plan is kept as v{old}; the rebuilt plan becomes v{new}.')
               else coalesce(public._c('routes.rebuild_body'),
                      '{n} leads pass the current S Leads filters for {zone} on {date}. This plan is kept as v{old}; the rebuilt plan becomes v{new}.') end,
             '{n}',    v_n::text),
             '{zone}', v_zone),
             '{date}', v_date),
             '{old}',  coalesce(pl.version, 1)::text),
             '{new}',  (coalesce(pl.version, 1) + 1)::text) end,
    'hint',          coalesce(public._c('routes.rebuild_hint'), ''),
    'confirm_label', coalesce(public._c('routes.rebuild_confirm'), 'Rebuild'),
    'cancel_label',  coalesce(public._c('routes.rebuild_cancel'), 'Cancel'));
end;
$function$;

create or replace function public.route_plan_rebuild(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  pl    route_plans%rowtype;
  v_new uuid;
  v_n   integer;
  v_ver integer;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  select * into pl from route_plans where id = p_plan_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'plan_not_found'); end if;

  select count(*) into v_n
    from public._c1875_sleads_pool(pl.city, pl.classes, pl.visit_filter, pl.min_score);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_leads_match_filters',
      'message', coalesce(public._c('routes.rebuild_empty'),
                          'No leads pass the current S Leads filters for this zone and date.'));
  end if;

  v_ver := coalesce(pl.version, 1) + 1;

  insert into route_plans (city, classes, visit_filter, min_score, k, dow, start_min,
                           speed_kmh, dwell_min, total_leads, created_by,
                           status, build_stage, parent_plan_id, version, source)
  values (pl.city, pl.classes, pl.visit_filter, pl.min_score,
          greatest(1, coalesce(public.route_auto_k(v_n), pl.k, 1)),
          pl.dow, pl.start_min, pl.speed_kmh, pl.dwell_min, v_n, auth.uid(),
          'queued', 'Queued', pl.id, v_ver, 'sleads')
  returning id into v_new;

  insert into route_plan_pool (plan_id, lead_id)
  select v_new, s.lead_id
    from public._c1875_sleads_pool(pl.city, pl.classes, pl.visit_filter, pl.min_score) s
  on conflict do nothing;

  -- The old plan is KEPT — its routes, assignments and check-ins are the
  -- previous version, not rubbish to be deleted.
  update route_plans
     set status = 'superseded', superseded_by = v_new
   where id = pl.id;

  return jsonb_build_object(
    'ok',       true,
    'plan_id',  v_new,
    'version',  v_ver,
    'leads',    v_n,
    'toast',    replace(coalesce(public._c('routes.rebuild_queued'),
                                 'Rebuilding — v{n} is queued.'), '{n}', v_ver::text));
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. route_plan_get — same payload, plus the version line, the Rebuild
--    affordance and the ₹ cost on every route and on the plan summary.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.route_plan_get(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  pl route_plans%ROWTYPE; h lead_hub%ROWTYPE;
  v_km numeric; v_min integer; v_conv integer;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO pl FROM route_plans WHERE id = p_plan_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','plan_not_found'); END IF;
  SELECT * INTO h FROM lead_hub WHERE id = 1;

  -- plan totals over the INCLUDED routes only — the same set the summary counts
  SELECT coalesce(sum(r.total_km),0), coalesce(sum(r.total_min),0)
    INTO v_km, v_min
    FROM route_plan_routes r WHERE r.plan_id = pl.id AND r.included;
  SELECT count(*) INTO v_conv
    FROM route_plan_stops st
   WHERE st.plan_id = pl.id AND st.visit_status = 'converted';

  RETURN jsonb_build_object(
    'plan_id', pl.id,
    'header', jsonb_build_object(
      'city', pl.city,
      'title', pl.city || ' · ' || pl.k || ' routes · ' || pl.total_leads || ' leads',
      'types_label', array_to_string(pl.classes, ', '),
      'filter_label', array_to_string(pl.visit_filter, ' + '),
      'start_label', 'Start ' || hhmm(pl.start_min) || ' from ' || h.name,
      'day_label', to_char(now() AT TIME ZONE 'Asia/Kolkata', 'Day'),
      'status', pl.status,
      'build_stage', pl.build_stage,
      'version', coalesce(pl.version, 1),
      'version_label', replace(coalesce(public._c('routes.version_label'), 'v{n}'),
                               '{n}', coalesce(pl.version, 1)::text),
      'superseded_label', (SELECT replace(
             coalesce(public._c('routes.superseded_label'), 'Replaced by v{n}'),
             '{n}', coalesce(np.version, 1)::text)
           FROM route_plans np WHERE np.id = pl.superseded_by),
      'can_rebuild', true,
      'rebuild_label', coalesce(public._c('routes.rebuild_btn'), 'Rebuild from current leads'),
      'rates_label',   coalesce(public._c('routes.rates_btn'),   'Rates')),
    'summary', (SELECT jsonb_build_object(
      'routes',       (SELECT count(*) FROM route_plan_routes WHERE plan_id=pl.id AND included),
      'stops',        (SELECT count(*) FROM route_plan_stops  WHERE plan_id=pl.id AND included),
      'dropped',      (SELECT count(*) FROM route_plan_stops  WHERE plan_id=pl.id AND NOT included),
      'total_km_label', (SELECT round(sum(total_km),1)::text || ' km total'
                           FROM route_plan_routes WHERE plan_id=pl.id AND included),
      'unfit_routes', (SELECT count(*) FROM route_plan_routes
                        WHERE plan_id=pl.id AND included AND total_min > 480),
      'warning', (SELECT CASE WHEN count(*) > 0
                    THEN count(*) || ' route(s) exceed an 8-hour day. Use more routes.' END
                  FROM route_plan_routes WHERE plan_id=pl.id AND included AND total_min > 480),
      'rates_label', (public.route_rates_get()->>'current_label'))
      || public._c1875_cost_block(v_km, v_min, v_conv, 'plan')),
    'routes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'route_id',  r.id,
        'seq',       r.seq,
        'title',     r.label,
        'subtitle',  r.n_stops || ' stops · ' || round(r.total_km,1) || ' km · '
                     || (r.total_min/60) || 'h ' || lpad((r.total_min%60)::text,2,'0') || 'm',
        'n_stops',   r.n_stops,
        'total_km',  r.total_km,
        'fits_day',  (r.total_min <= 480),
        'day_warning', CASE WHEN r.total_min > 480
                            THEN 'Longer than an 8-hour day' END,
        'closed_label', CASE WHEN r.closed_count > 0
                             THEN r.closed_count || ' shut on arrival' END,
        'included',  r.included,
        'google_optimized', COALESCE(r.google_optimized, false),
        'worker',    (SELECT w.name FROM lead_workers w WHERE w.id = r.worker_id),
        'assigned',  (r.assignment_id IS NOT NULL),
        'stops', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'stop_id',  st.id,
            'lead_id',  st.lead_id,
            'seq',      st.seq,
            'name',     sl.name,
            'photo_url',sl.photo_url,
            'area',     COALESCE(NULLIF(concat_ws(', ', sl.area, sl.locality),''), sl.address),
            'score_label', COALESCE(sl.lead_score,0)::text || '/100',
            'band',     CASE WHEN sl.lead_score >= 80 THEN 'hot'
                             WHEN sl.lead_score >= 60 THEN 'warm' ELSE 'cold' END,
            'phone',    sl.phone,
            'call_link',CASE WHEN _phone10(sl.phone) IS NOT NULL
                             THEN 'tel:+91' || _phone10(sl.phone) END,
            'wa_link',  CASE WHEN _phone10(sl.phone) IS NOT NULL
                             THEN 'https://wa.me/91' || _phone10(sl.phone) END,
            'nav_link', 'https://www.google.com/maps/dir/?api=1&travelmode=driving&destination='
                        || sl.lat || ',' || sl.lng,
            'eta_label',   hhmm(st.eta_min),
            'wait_label',  CASE WHEN st.wait_min > 0
                                THEN 'wait ' || st.wait_min || ' min for it to open' END,
            'open_label',  CASE WHEN st.open_at_eta IS TRUE  THEN 'Open on arrival'
                                WHEN st.open_at_eta IS FALSE THEN 'SHUT on arrival'
                                ELSE 'Hours unknown' END,
            'open_ok',     COALESCE(st.open_at_eta, true),
            'today_hours', NULLIF(regexp_replace(COALESCE(sl.hours_text[1],''),'^[A-Za-z]+:\s*',''),''),
            'leg_label',   round(st.leg_km,1)::text || ' km',
            'cum_label',   round(st.cum_km,1)::text || ' km so far',
            'included',    st.included
          ) ORDER BY st.seq)
          FROM route_plan_stops st JOIN scraped_leads sl ON sl.id = st.lead_id
          WHERE st.route_id = r.id), '[]'::jsonb)
      ) || public._c1875_cost_block(
             r.total_km, r.total_min,
             (SELECT count(*)::int FROM route_plan_stops st2
               WHERE st2.route_id = r.id AND st2.visit_status = 'converted'),
             'route')
      ORDER BY r.seq)
      FROM route_plan_routes r WHERE r.plan_id = pl.id), '[]'::jsonb));
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. route_plan_list — the past-plans rows carry the version chip so a
--    rebuilt plan is legible as "v2 of that plan", not a mystery duplicate.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.route_plan_list(p_limit integer default 20, p_offset integer default 0)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy   jsonb;
  v_rows   jsonb := '[]'::jsonb;
  v_total  bigint := 0;
  v_n      integer := 0;
  v_limit  integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_next   integer;
  v_more   boolean;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'routes.%';

  select count(*) into v_total
    from route_plans where status is distinct from 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id',    p.id,
           'city',       p.city,
           'title',      p.city || ' · ' || p.k || 'R · ' || p.total_leads || ' leads',
           'types',      array_to_string(p.classes, ', '),
           'when_label', to_char(p.created_at at time zone 'Asia/Kolkata', 'DD/MM/YY HH24:MI'),
           'status',     p.status,
           'version',    coalesce(p.version, 1),
           'version_label', case when coalesce(p.version, 1) > 1
             then replace(coalesce(v_copy->>'routes.version_label', 'v{n}'),
                          '{n}', coalesce(p.version, 1)::text) end,
           'cost_label', (public._c1875_cost_block(
                            coalesce((select sum(r.total_km)  from route_plan_routes r
                                       where r.plan_id = p.id and r.included), 0),
                            coalesce((select sum(r.total_min) from route_plan_routes r
                                       where r.plan_id = p.id and r.included), 0)::int,
                            (select count(*)::int from route_plan_stops st
                              where st.plan_id = p.id and st.visit_status = 'converted'),
                            'plan')->>'cost_label')
         ) order by p.created_at desc), '[]'::jsonb),
         count(*)
    into v_rows, v_n
    from (select * from route_plans
           where status is distinct from 'cancelled'
           order by created_at desc
           limit v_limit offset v_offset) p;

  v_next := v_offset + v_n;
  v_more := v_next < v_total;

  return jsonb_build_object(
    'ok',          true,
    'page_size',   v_limit,
    'offset',      v_offset,
    'rows',        v_rows,
    'total',       v_total,
    'count_label', replace(case when v_total = 1
                            then coalesce(v_copy->>'routes.count_one',  '{n} route plan')
                            else coalesce(v_copy->>'routes.count_many', '{n} route plans') end,
                          '{n}', to_char(v_total, 'FM999,999,999')),
    'has_more',    v_more,
    'next_offset', case when v_more then v_next end,
    'empty_label', coalesce(v_copy->>'routes.empty', 'No saved route plans yet'),
    'more_label',  coalesce(v_copy->>'routes.loading_more', 'Loading more…'),
    'end_label',   case when v_total > 0 and not v_more
                     then replace(coalesce(v_copy->>'routes.end', 'All {n} route plans shown'),
                                  '{n}', to_char(v_total, 'FM999,999,999')) end
  );
end;
$function$;

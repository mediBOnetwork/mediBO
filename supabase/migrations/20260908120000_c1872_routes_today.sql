-- CMD #1872 — Routes tab opens on TODAY'S assigned route.
--
-- Before this, the Routes tab landed on the plan BUILDER and a worker had to
-- find the "My route" toggle himself. my_route() rebuilt a route from scratch
-- with _lead_plan_route_core() every call and knew nothing about the route the
-- admin actually assigned him (route_plan_routes.worker_id / assignment_id),
-- nothing about admin_active_zone() and nothing about admin_active_date().
--
-- routes_today() is the tab's landing payload: the route ASSIGNED to the
-- logged-in worker for the active date in the active zone; every route for
-- that date (with worker names) for an admin / super admin. Every string —
-- title, progress line, Navigate caption, empty state, the "All plans"
-- secondary link — is built here and printed verbatim by Flutter.
--
-- Idempotent: CREATE OR REPLACE + ON CONFLICT DO NOTHING only.

-- ── Copy (backend-owned; wording changes are an UPDATE, never a deploy) ────
insert into ui_copy(key, value) values
  ('routes_today.title',         '"Today''s route"'::jsonb),
  ('routes_today.title_admin',   '"Today''s routes"'::jsonb),
  ('routes_today.header',        '"{date} · {zone}"'::jsonb),
  ('routes_today.zone_all',      '"All zones"'::jsonb),
  ('routes_today.count_one',     '"1 route today"'::jsonb),
  ('routes_today.count_many',    '"{n} routes today"'::jsonb),
  ('routes_today.progress',      '"{done} of {total} stops · {km} km left · ETA {eta}"'::jsonb),
  ('routes_today.progress_done', '"All {total} stops done · {km} km"'::jsonb),
  ('routes_today.progress_empty','"No stops on this route yet"'::jsonb),
  ('routes_today.next',          '"Next: {name}"'::jsonb),
  ('routes_today.nav',           '"Navigate"'::jsonb),
  ('routes_today.nav_done',      '"All stops visited"'::jsonb),
  ('routes_today.worker_none',   '"Unassigned"'::jsonb),
  ('routes_today.empty_worker',  '"No route assigned to you for this date."'::jsonb),
  ('routes_today.empty_admin',   '"No route is assigned to a worker for this date in this zone."'::jsonb),
  ('routes_today.link_today',    '"Today"'::jsonb),
  ('routes_today.link_plans',    '"All plans"'::jsonb),
  ('routes_today.link_myroute',  '"Check in"'::jsonb),
  ('routes_today.route_label',   '"Route {seq}"'::jsonb)
on conflict (key) do nothing;

-- ── The app zone of a route ───────────────────────────────────────────────
-- zones (smallint, the app's delivery zones) and lead_zones (bigint, the
-- k-means clusters the route planner builds) are DIFFERENT tables. The only
-- honest bridge is the city: zones.name is the city name ('Raipur' = RPR) and
-- both route_plans.city and lead_zones.city carry it. NULL p_zone (a super
-- admin with no zone picked) means "all zones" and matches everything.
create or replace function public._c1872_zone_match(
  p_zone smallint, p_plan_city text, p_lead_zone bigint)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p_zone is null
      or exists (
           select 1 from zones z
            where z.id = p_zone
              and (lower(btrim(z.name)) = lower(btrim(coalesce(p_plan_city,'')))
                or lower(btrim(z.name)) = lower(btrim(coalesce(
                     (select lz.city from lead_zones lz where lz.id = p_lead_zone), '')))));
$function$;

-- ── Today's route(s) — the Routes tab's landing payload ───────────────────
create or replace function public.routes_today()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy    jsonb;
  v_role    text     := coalesce(get_my_role(), '');
  v_worker  uuid     := my_worker_id();
  v_admin   boolean;
  v_date    date     := admin_active_date();
  v_zone    smallint := admin_active_zone();
  v_zonelbl text;
  v_rows    jsonb    := '[]'::jsonb;
  v_n       integer  := 0;
  v_links   jsonb    := '[]'::jsonb;
  r         record;
  v_total   integer;
  v_done    integer;
  v_kmdone  numeric;
  v_kmleft  numeric;
  v_etamin  integer;
  v_etalbl  text;
  v_prog    text;
  nx        record;
  v_navuri  text;
  v_allowed boolean;
begin
  v_admin := v_role in ('admin','super_admin');
  -- Partner staff reach the Routes tab through tabCanView but are neither an
  -- admin nor a lead worker. Raising here took the WHOLE tab down with the
  -- new call, so an unauthorised caller gets an honest ok:false payload with
  -- the secondary links instead — the loop below would return them no routes
  -- anyway (worker_id = null matches nothing), so nothing is leaked.
  v_allowed := v_admin or v_worker is not null;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'routes_today.%';

  -- A worker has no zone picker: his header names the zone his own route is
  -- in, not the admin's "all zones".
  v_zonelbl := (select z.name from zones z where z.id = v_zone);
  if v_zonelbl is null and not v_admin then
    select pp.city into v_zonelbl
      from route_plan_routes rr
      join route_plans      pp on pp.id = rr.plan_id
      join lead_assignments aa on aa.id = rr.assignment_id
     where rr.worker_id = v_worker and aa.for_date = v_date and rr.included
     order by rr.seq limit 1;
  end if;
  v_zonelbl := coalesce(v_zonelbl, v_copy->>'routes_today.zone_all', 'All zones');

  for r in
    select rr.id            as route_id,
           rr.plan_id,
           rr.seq,
           rr.label,
           rr.total_km,
           rr.total_min,
           rr.worker_id,
           rr.assignment_id as assign_id,
           pp.city,
           pp.start_min,
           aa.zone_id       as lead_zone_id,
           ww.name          as worker_name
      from route_plan_routes rr
      join route_plans       pp on pp.id = rr.plan_id
      join lead_assignments  aa on aa.id = rr.assignment_id
      left join lead_workers ww on ww.id = rr.worker_id
     where rr.included
       and aa.for_date = v_date
       and v_allowed
       and (v_admin or rr.worker_id = v_worker)
       and public._c1872_zone_match(v_zone, pp.city, aa.zone_id)
     order by ww.name nulls last, rr.seq
  loop
    select count(*),
           count(*) filter (where s.visited),
           coalesce(max(s.cum_km) filter (where s.visited), 0),
           max(s.eta_min)
      into v_total, v_done, v_kmdone, v_etamin
      from (
        select st.cum_km, st.eta_min,
               exists (select 1 from lead_visits v
                        where v.lead_id = st.lead_id
                          and (v.assignment_id = r.assign_id
                            or (r.worker_id is not null
                                and v.worker_id = r.worker_id
                                and (v.checked_in_at at time zone 'Asia/Kolkata')::date = v_date))
                      ) as visited
          from route_plan_stops st
         where st.route_id = r.route_id and st.included
      ) s;

    v_total  := coalesce(v_total, 0);
    v_done   := coalesce(v_done, 0);
    v_kmleft := greatest(coalesce(r.total_km, 0) - coalesce(v_kmdone, 0), 0);
    v_etamin := coalesce(r.start_min, 0) + coalesce(v_etamin, coalesce(r.total_min, 0));
    v_etalbl := to_char((time '00:00' + make_interval(mins => v_etamin))::time,
                        'FMHH12:MI AM');

    if v_total = 0 then
      v_prog := coalesce(v_copy->>'routes_today.progress_empty', 'No stops on this route yet');
    elsif v_done >= v_total then
      v_prog := replace(replace(
                  coalesce(v_copy->>'routes_today.progress_done', 'All {total} stops done · {km} km'),
                  '{total}', v_total::text),
                  '{km}', to_char(coalesce(r.total_km, 0), 'FM990.0'));
    else
      v_prog := replace(replace(replace(replace(
                  coalesce(v_copy->>'routes_today.progress',
                           '{done} of {total} stops · {km} km left · ETA {eta}'),
                  '{done}',  v_done::text),
                  '{total}', v_total::text),
                  '{km}',    to_char(v_kmleft, 'FM990.0')),
                  '{eta}',   v_etalbl);
    end if;

    -- The next UNVISITED stop, in route order — its stored directions URI is
    -- what Navigate opens. Nothing about this link is built in Dart.
    select st.seq, l.name, l.short_address, l.address,
           coalesce(nullif(btrim(l.maps_directions_uri), ''),
                    nullif(btrim(l.maps_uri), ''),
                    case when l.lat is not null and l.lng is not null
                      then 'https://www.google.com/maps/dir/?api=1&destination='
                           || l.lat::text || ',' || l.lng::text end) as uri
      into nx
      from route_plan_stops st
      join scraped_leads l on l.id = st.lead_id
     where st.route_id = r.route_id and st.included
       and not exists (select 1 from lead_visits v
                        where v.lead_id = st.lead_id
                          and (v.assignment_id = r.assign_id
                            or (r.worker_id is not null
                                and v.worker_id = r.worker_id
                                and (v.checked_in_at at time zone 'Asia/Kolkata')::date = v_date)))
     order by st.seq
     limit 1;

    v_navuri := nx.uri;

    v_rows := v_rows || jsonb_build_object(
      'route_id',      r.route_id,
      'plan_id',       r.plan_id,
      'assignment_id', r.assign_id,
      'title',         coalesce(nullif(btrim(r.label), ''),
                                replace(coalesce(v_copy->>'routes_today.route_label', 'Route {seq}'),
                                        '{seq}', r.seq::text)),
      'subtitle',      coalesce(r.city, ''),
      'worker_label',  case when v_admin
                         then coalesce(r.worker_name,
                                       coalesce(v_copy->>'routes_today.worker_none','Unassigned'))
                       end,
      'progress_label', v_prog,
      'done',          v_done,
      'total',         v_total,
      'next_label',    case when nx.name is not null
                         then replace(coalesce(v_copy->>'routes_today.next', 'Next: {name}'),
                                      '{name}', nx.name) end,
      'next_sub',      coalesce(nullif(btrim(nx.short_address), ''), nx.address),
      'nav_uri',       v_navuri,
      'nav_label',     case when v_navuri is not null
                         then coalesce(v_copy->>'routes_today.nav', 'Navigate')
                         else coalesce(v_copy->>'routes_today.nav_done', 'All stops visited') end,
      'can_navigate',  v_navuri is not null
    );
    v_n := v_n + 1;
  end loop;

  -- The tab's own mode row. 'today' is the landing mode, the rest are the
  -- secondary links; Flutter prints these captions and never writes its own.
  if v_allowed then
    v_links := v_links || jsonb_build_object(
      'key',   'today',
      'label', coalesce(v_copy->>'routes_today.link_today', 'Today'));
  end if;
  v_links := v_links || jsonb_build_object(
    'key',   'all_plans',
    'label', coalesce(v_copy->>'routes_today.link_plans', 'All plans'));
  -- 'Check in' stays for EVERY caller: before this change the tab's own row
  -- always offered "My route", and dropping it for an admin would be a
  -- regression dressed up as a new feature.
  v_links := v_links || jsonb_build_object(
    'key',   'my_route',
    'label', coalesce(v_copy->>'routes_today.link_myroute', 'Check in'));

  return jsonb_build_object(
    'ok',           v_allowed,
    'role',         case when v_admin then v_role else 'worker' end,
    'is_admin',     v_admin,
    'date',         v_date,
    'zone_id',      v_zone,
    'title',        case when v_admin
                      then coalesce(v_copy->>'routes_today.title_admin', 'Today''s routes')
                      else coalesce(v_copy->>'routes_today.title', 'Today''s route') end,
    'header_label', replace(replace(
                      coalesce(v_copy->>'routes_today.header', '{date} · {zone}'),
                      '{date}', to_char(v_date, 'FMDy DD Mon')),
                      '{zone}', v_zonelbl),
    'count_label',  case when v_n = 1
                      then coalesce(v_copy->>'routes_today.count_one', '1 route today')
                      else replace(coalesce(v_copy->>'routes_today.count_many', '{n} routes today'),
                                   '{n}', v_n::text) end,
    'count',        v_n,
    'routes',       v_rows,
    'empty_label',  case when v_n = 0 then
                      case when v_admin
                        then coalesce(v_copy->>'routes_today.empty_admin',
                                      'No route is assigned to a worker for this date in this zone.')
                        else coalesce(v_copy->>'routes_today.empty_worker',
                                      'No route assigned to you for this date.') end
                    end,
    'links',        v_links
  );
end;
$function$;

grant execute on function public.routes_today() to authenticated;
grant execute on function public._c1872_zone_match(smallint, text, bigint) to authenticated;

-- ── Assignment carries its lead zone ──────────────────────────────────────
-- route_plan_assign() inserted lead_assignments with zone_id NULL, so nothing
-- downstream could tell which cluster a day's work belonged to. The zone is
-- the modal lead zone of the route's own stops — derived, never typed.
create or replace function public.route_plan_assign(
  p_route_id uuid, p_worker_id uuid, p_for_date date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_a uuid; d date; r route_plan_routes%ROWTYPE; v_zone bigint;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO r FROM route_plan_routes WHERE id = p_route_id;
  d := COALESCE(p_for_date, public.admin_active_date());

  SELECT l.zone_id INTO v_zone
    FROM route_plan_stops s
    JOIN scraped_leads l ON l.id = s.lead_id
   WHERE s.route_id = p_route_id AND s.included AND l.zone_id IS NOT NULL
   GROUP BY l.zone_id
   ORDER BY count(*) DESC
   LIMIT 1;

  INSERT INTO lead_assignments (zone_id, worker_id, assigned_by, for_date,
                                target_stops, min_score)
  VALUES (v_zone, p_worker_id, auth.uid(), d, r.n_stops, 1)
  RETURNING id INTO v_a;

  UPDATE route_plan_routes SET worker_id = p_worker_id, assignment_id = v_a
   WHERE id = p_route_id;

  RETURN jsonb_build_object('ok', true, 'assignment_id', v_a,
    'message', (SELECT w.name FROM lead_workers w WHERE w.id = p_worker_id)
      || ' assigned ' || r.n_stops || ' stops on ' || r.label);
END;
$function$;

grant execute on function public.route_plan_assign(uuid, uuid, date) to authenticated;

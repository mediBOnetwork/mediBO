-- CMD #2057 — Route stops list: locked route order, full-width cards, no drag.
-- Long-press removes a stop from the plan (pin + card gone, remaining stops
-- renumbered to close the gap) and restores it within 5 minutes.
--
-- Idempotent: every statement is IF NOT EXISTS / CREATE OR REPLACE, so the
-- deploy-time replay on live can run it as many times as it likes.

-- ── 1. The removal state, on the stop row itself ────────────────────────────
alter table public.route_plan_stops
  add column if not exists removed_at  timestamptz,
  add column if not exists removed_by  uuid,
  add column if not exists removed_seq integer;

create index if not exists route_plan_stops_removed_idx
  on public.route_plan_stops (route_id, removed_at);

-- ── 2. The audit row every removal / restore writes ─────────────────────────
create table if not exists public.route_stop_audit (
  id         bigserial primary key,
  route_id   uuid        not null,
  stop_id    uuid        not null,
  lead_id    bigint,
  action     text        not null,
  seq_before integer,
  actor      uuid,
  at         timestamptz not null default now(),
  meta       jsonb       not null default '{}'::jsonb
);

create index if not exists route_stop_audit_route_idx
  on public.route_stop_audit (route_id, at desc);

alter table public.route_stop_audit enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'route_stop_audit'
                    and policyname = 'route_stop_audit_admin_read') then
    create policy route_stop_audit_admin_read on public.route_stop_audit
      for select using (public.get_my_role() in ('admin','super_admin'));
  end if;
end $$;

-- ── 3. The copy. Wording is an UPDATE, never a deploy. ──────────────────────
insert into public.ui_copy (key, value)
select k, to_jsonb(v) from (values
  ('route_stop.remove_stop',    'Remove from route'),
  ('route_stop.removed_msg',    '{name} removed from the route. {n} stops left.'),
  ('route_stop.restore_stop',   'Restore {name} to stop {seq}'),
  ('route_stop.restored_msg',   '{name} is back on the route at stop {seq}.'),
  ('route_stop.restore_expired','That removal can no longer be undone.'),
  ('route_stop.remove_blocked', 'A stop that is already checked in cannot be removed.'),
  ('route_stop.menu_title_fb',  'Stop options'),
  ('route_stop.locked_hint',    'Route order is fixed. Long-press a stop for options.')
) as t(k, v)
on conflict (key) do nothing;

-- ── 4. Re-sequencing ignores removed stops entirely ─────────────────────────
-- A removed stop holds no place in the day and no place in the tail: it is
-- not on the route at all until it is restored.
create or replace function public._c1874_resequence(p_route_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_plan   record;
  r        record;
  v_prev   bigint  := 0;      -- 0 is the hub in the distance matrix
  v_seq    integer := 0;
  v_cum_m  integer := 0;
  v_closed integer := 0;
  v_start  integer;
  v_t      integer;
  v_leg_m  integer;
  v_arrive integer;
  v_wait   integer;
  v_open   boolean;
  v_next   integer;
  v_home_m integer;
begin
  select pp.dow, coalesce(pp.start_min, 0) as start_min,
         coalesce(pp.dwell_min, 10) as dwell
    into v_plan
    from route_plan_routes rr
    join route_plans pp on pp.id = rr.plan_id
   where rr.id = p_route_id;
  if not found then return; end if;

  v_start := v_plan.start_min;
  v_t     := v_start;

  for r in
    select st.id, st.lead_id, sl.hours_json as hours
      from route_plan_stops st
      join scraped_leads sl on sl.id = st.lead_id
     where st.route_id = p_route_id and st.included
       and st.skipped_at is null and st.removed_at is null
     order by st.seq, st.id
  loop
    v_seq    := v_seq + 1;
    v_leg_m  := public._dm(v_prev, r.lead_id);
    v_cum_m  := v_cum_m + v_leg_m;
    v_arrive := v_t + ceil(public._ds(v_prev, r.lead_id) / 60.0)::int;
    v_wait   := 0;
    v_open   := lead_is_open_at(r.hours, v_plan.dow, least(v_arrive, 1439)::int);
    if v_open is false then
      v_next := lead_next_open(r.hours, v_plan.dow, least(v_arrive, 1439)::int);
      if v_next is not null and v_next > v_arrive and (v_next - v_arrive) <= 120 then
        v_wait := v_next - v_arrive; v_arrive := v_next; v_open := true;
      else
        v_closed := v_closed + 1;
      end if;
    end if;

    update route_plan_stops set
      seq         = v_seq,
      leg_km      = round(v_leg_m / 1000.0, 2),
      cum_km      = round(v_cum_m / 1000.0, 2),
      eta_min     = v_arrive,
      wait_min    = v_wait,
      open_at_eta = coalesce(v_open, true)
     where id = r.id;

    v_t    := v_arrive + v_plan.dwell;
    v_prev := r.lead_id;
  end loop;

  -- Skipped / excluded stops keep their order relative to each other but hold
  -- no place in the day: no leg, no ETA, nothing for a rep to read as a plan.
  with tail as (
    select st.id, row_number() over (order by st.seq, st.id) as k
      from route_plan_stops st
     where st.route_id = p_route_id
       and st.removed_at is null
       and (st.skipped_at is not null or not st.included))
  update route_plan_stops st set
    seq = v_seq + tail.k, leg_km = null, cum_km = null,
    eta_min = null, wait_min = 0, open_at_eta = null
   from tail where tail.id = st.id;

  v_home_m := case when v_seq > 0 then public._dm(v_prev, 0) else 0 end;

  update route_plan_routes rr set
    n_stops      = v_seq,
    total_km     = round((v_cum_m + v_home_m) / 1000.0, 2),
    total_min    = case when v_seq > 0
                     then (v_t + ceil(public._ds(v_prev, 0) / 60.0)::int) - v_start
                     else 0 end,
    closed_count = v_closed
   where rr.id = p_route_id;
end;
$function$;

-- ── 5. Remove one stop from the plan ────────────────────────────────────────
-- No re-optimisation: the surviving stops keep the order Google gave them and
-- are simply renumbered, so the leg that ran through the removed stop closes
-- up and the next stop becomes current.
create or replace function public.route_stop_remove(p_stop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy jsonb;
  v_st   record;
  v_left integer;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  select s.id, s.route_id, s.lead_id, s.seq, s.visit_status, s.removed_at, l.name
    into v_st
    from route_plan_stops s
    join scraped_leads l on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found or v_st.removed_at is not null then
    return jsonb_build_object('ok', false, 'error', 'stop_not_found',
      'message', coalesce(v_copy->>'route_stop.not_found',
                          'That stop is no longer on this route.'));
  end if;

  if not public._c1917_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot change this route.'));
  end if;

  if v_st.visit_status is not null then
    return jsonb_build_object('ok', false, 'error', 'already_visited',
      'message', coalesce(v_copy->>'route_stop.remove_blocked',
                          'A stop that is already checked in cannot be removed.'));
  end if;

  update route_plan_stops set
    removed_at  = now(),
    removed_by  = auth.uid(),
    removed_seq = seq,
    leg_km      = null,
    cum_km      = null,
    eta_min     = null,
    wait_min    = 0,
    open_at_eta = null
   where id = p_stop_id;

  insert into route_stop_audit (route_id, stop_id, lead_id, action, seq_before, actor, meta)
  values (v_st.route_id, p_stop_id, v_st.lead_id, 'remove', v_st.seq, auth.uid(),
          jsonb_build_object('name', v_st.name));

  perform public._c1874_resequence(v_st.route_id);

  select count(*) into v_left
    from route_plan_stops
   where route_id = v_st.route_id and included
     and skipped_at is null and removed_at is null;

  return jsonb_build_object(
    'ok',      true,
    'stop_id', p_stop_id,
    'removed', true,
    'left',    v_left,
    'message', replace(replace(
                 coalesce(v_copy->>'route_stop.removed_msg',
                          '{name} removed from the route. {n} stops left.'),
                 '{name}', coalesce(v_st.name, '')),
                 '{n}', v_left::text));
end;
$function$;

-- ── 6. Put a removed stop back, within the undo window ──────────────────────
create or replace function public.route_stop_restore(p_stop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy jsonb;
  v_st   record;
  v_win  interval := interval '5 minutes';
  v_seq  integer;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  select s.id, s.route_id, s.lead_id, s.removed_at,
         coalesce(s.removed_seq, s.seq) as back_to, l.name
    into v_st
    from route_plan_stops s
    join scraped_leads l on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found or v_st.removed_at is null then
    return jsonb_build_object('ok', false, 'error', 'not_removed',
      'message', coalesce(v_copy->>'route_stop.restore_expired',
                          'That removal can no longer be undone.'));
  end if;

  if not public._c1917_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot change this route.'));
  end if;

  if v_st.removed_at <= now() - v_win then
    return jsonb_build_object('ok', false, 'error', 'undo_expired',
      'message', coalesce(v_copy->>'route_stop.restore_expired',
                          'That removal can no longer be undone.'));
  end if;

  -- Open the slot it used to hold, then drop it back in.
  update route_plan_stops set seq = seq + 1
   where route_id = v_st.route_id and removed_at is null
     and included and skipped_at is null and seq >= v_st.back_to;

  update route_plan_stops set
    removed_at = null, removed_by = null, removed_seq = null, seq = v_st.back_to
   where id = p_stop_id;

  insert into route_stop_audit (route_id, stop_id, lead_id, action, seq_before, actor, meta)
  values (v_st.route_id, p_stop_id, v_st.lead_id, 'restore', v_st.back_to, auth.uid(),
          jsonb_build_object('name', v_st.name));

  perform public._c1874_resequence(v_st.route_id);

  select seq into v_seq from route_plan_stops where id = p_stop_id;

  return jsonb_build_object(
    'ok',      true,
    'stop_id', p_stop_id,
    'removed', false,
    'seq',     v_seq,
    'message', replace(replace(
                 coalesce(v_copy->>'route_stop.restored_msg',
                          '{name} is back on the route at stop {seq}.'),
                 '{name}', coalesce(v_st.name, '')),
                 '{seq}', coalesce(v_seq, 0)::text));
end;
$function$;

grant execute on function public.route_stop_remove(uuid)  to authenticated;
grant execute on function public.route_stop_restore(uuid) to authenticated;

-- ── 7. route_map: a removed stop has no pin, no waypoint, no path point ──
CREATE OR REPLACE FUNCTION public.route_map(p_route_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  h lead_hub%ROWTYPE;
  r route_plan_routes%ROWTYPE;
  v_stops jsonb;
  v_min_lat double precision; v_max_lat double precision;
  v_min_lng double precision; v_max_lng double precision;
  v_legs jsonb;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;

  SELECT * INTO h FROM lead_hub WHERE id = 1;
  SELECT * INTO r FROM route_plan_routes WHERE id = p_route_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','route_not_found'); END IF;

  -- ---------- MARKERS ----------
  SELECT jsonb_agg(jsonb_build_object(
           'seq',        st.seq,
           'lead_id',    sl.id,
           'name',       sl.name,
           'lat',        sl.lat,
           'lng',        sl.lng,
           'address',    sl.address,
           'area',       sl.area,
           'phone',      sl.phone,
           'marker_label', st.seq::text,
           'title',      st.seq || '. ' || sl.name,
           'subtitle',   COALESCE(sl.area || ' · ', '')
                         || 'ETA ' || to_char((st.eta_min || ' minutes')::interval, 'FMHH12:MI AM')
                         || CASE WHEN st.wait_min > 0
                                 THEN ' (wait ' || st.wait_min || 'm)' ELSE '' END,
           'eta_label',  to_char((st.eta_min || ' minutes')::interval, 'FMHH12:MI AM'),
           'leg_label',  round(st.leg_km,1) || ' km',
           'cum_label',  round(st.cum_km,1) || ' km total',
           'open',       st.open_at_eta,
           'open_label', CASE WHEN st.open_at_eta IS FALSE THEN 'Likely CLOSED at arrival' END,
           'tone',       CASE WHEN st.open_at_eta IS FALSE THEN 'bad' ELSE 'ok' END,
           -- ⭐ one-tap navigation to THIS shop
           'navigate_url','https://www.google.com/maps/dir/?api=1&destination='
                          || sl.lat || ',' || sl.lng || '&travelmode=driving',
           'navigate_label','Navigate'
         ) ORDER BY st.seq),
       min(sl.lat), max(sl.lat), min(sl.lng), max(sl.lng)
  INTO v_stops, v_min_lat, v_max_lat, v_min_lng, v_max_lng
  FROM route_plan_stops st
  JOIN scraped_leads sl ON sl.id = st.lead_id
  WHERE st.route_id = p_route_id AND st.removed_at IS NULL;

  IF v_stops IS NULL THEN RETURN jsonb_build_object('error','no_stops'); END IF;

  -- ---------- LEGS: chunks of 10 stops -> a Google Maps directions URL each ----------
  SELECT jsonb_agg(jsonb_build_object(
           'leg', q.leg,
           'from_seq', q.first_seq, 'to_seq', q.last_seq,
           'label','Stops ' || q.first_seq || '–' || q.last_seq,
           'stops', q.n,
           'url', 'https://www.google.com/maps/dir/?api=1'
                  || '&origin=' || CASE WHEN q.leg = 1
                                        THEN h.lat || ',' || h.lng
                                        ELSE q.first_lat || ',' || q.first_lng END
                  || '&destination=' || q.last_lat || ',' || q.last_lng
                  || CASE WHEN q.waypoints IS NOT NULL AND q.waypoints <> ''
                          THEN '&waypoints=' || q.waypoints ELSE '' END
                  || '&travelmode=driving'
         ) ORDER BY q.leg)
  INTO v_legs
  FROM (
    SELECT ((st.seq - 1) / 10) + 1 AS leg,
           min(st.seq) AS first_seq, max(st.seq) AS last_seq, count(*) AS n,
           (array_agg(sl.lat ORDER BY st.seq))[1]                       AS first_lat,
           (array_agg(sl.lng ORDER BY st.seq))[1]                       AS first_lng,
           (array_agg(sl.lat ORDER BY st.seq DESC))[1]                  AS last_lat,
           (array_agg(sl.lng ORDER BY st.seq DESC))[1]                  AS last_lng,
           string_agg(sl.lat || ',' || sl.lng, '|' ORDER BY st.seq)
             FILTER (WHERE st.seq > (SELECT min(s2.seq) FROM route_plan_stops s2
                                      WHERE s2.route_id = p_route_id AND s2.removed_at IS NULL
                                        AND ((s2.seq - 1)/10) = ((st.seq - 1)/10))
                       AND st.seq < (SELECT max(s2.seq) FROM route_plan_stops s2
                                      WHERE s2.route_id = p_route_id AND s2.removed_at IS NULL
                                        AND ((s2.seq - 1)/10) = ((st.seq - 1)/10)))
                                                                        AS waypoints
    FROM route_plan_stops st
    JOIN scraped_leads sl ON sl.id = st.lead_id
    WHERE st.route_id = p_route_id AND st.removed_at IS NULL
    GROUP BY ((st.seq - 1) / 10) + 1
  ) q;

  RETURN jsonb_build_object(
    'route_id',   p_route_id,
    'label',      r.label,
    'summary',    r.n_stops || ' stops · ' || round(r.total_km,1) || ' km · '
                  || (r.total_min / 60) || 'h ' || lpad((r.total_min % 60)::text,2,'0') || 'm',
    'n_stops',    r.n_stops,
    'closed_label', CASE WHEN r.closed_count > 0
                    THEN r.closed_count || ' stop(s) likely closed at arrival' END,

    -- CHANGE #485: expose the Google-optimized road polyline (if this route
    -- has been optimized) so the client can decode + draw it instead of the
    -- straight-line/OSRM fallback.
    'road_polyline',    r.road_polyline,
    'google_optimized', COALESCE(r.google_optimized, false),

    -- ---------- the hub (start + end pin) ----------
    'hub', jsonb_build_object(
      'name', COALESCE(h.name,'mediBO'),
      'lat',  h.lat, 'lng', h.lng,
      'address', h.address,
      'marker_label','H',
      'title','Start · ' || COALESCE(h.name,'mediBO')),

    -- ---------- map framing (Flutter just applies it) ----------
    'center', jsonb_build_object(
      'lat', (v_min_lat + v_max_lat) / 2,
      'lng', (v_min_lng + v_max_lng) / 2),
    'bounds', jsonb_build_object(
      'south', LEAST(v_min_lat, h.lat), 'north', GREATEST(v_max_lat, h.lat),
      'west',  LEAST(v_min_lng, h.lng), 'east',  GREATEST(v_max_lng, h.lng)),

    'stops', v_stops,
    'legs',  COALESCE(v_legs, '[]'::jsonb),

    -- polyline for the on-map line: the stop order, hub -> stops -> hub
    'path', (SELECT jsonb_agg(jsonb_build_object('lat', p.lat, 'lng', p.lng) ORDER BY p.o)
             FROM (
               SELECT 0 AS o, h.lat, h.lng
               UNION ALL
               SELECT st.seq, sl.lat, sl.lng
               FROM route_plan_stops st JOIN scraped_leads sl ON sl.id = st.lead_id
               WHERE st.route_id = p_route_id AND st.removed_at IS NULL
               UNION ALL
               SELECT 9999, h.lat, h.lng
             ) p)
  );
END;
$function$;

-- ── 8. route_view: locked order, removed stops gone, remove/restore menu ──
CREATE OR REPLACE FUNCTION public.route_view(p_route_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy    jsonb;
  v_admin   boolean := coalesce(get_my_role(), '') in ('admin','super_admin');
  v_date    date    := admin_active_date();
  r         record;
  v_rows    jsonb   := '[]'::jsonb;
  v_windows jsonb   := '[]'::jsonb;
  v_n       integer := 0;
  v_act     integer := 0;
  v_total   integer := 0;
  v_done    integer := 0;
  v_conv    integer := 0;
  v_kmdone  numeric := 0;
  v_kmleft  numeric;
  v_etamin  integer;
  v_prog    text;
  nx        record;
  v_navuri  text;
  s         record;
  v_meta    jsonb;
  v_shut    boolean;
  v_acts    jsonb;
  v_menu    jsonb;
  v_from    integer;
  v_to      integer;
  v_i       integer;
  v_undo    record;
  v_undo_lbl text;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_view.%' or key like 'route_stop.%'
                                or key like 'routes_today.%' or key like 'routes.%';

  if not public._c1917_route_ok(p_route_id) then
    return jsonb_build_object(
      'ok', false, 'route_id', p_route_id, 'stops', '[]'::jsonb,
      'windows', '[]'::jsonb, 'map', null,
      'stops_title', coalesce(v_copy->>'route_view.stops_title', 'Stops'),
      'empty_label', coalesce(v_copy->>'route_view.locked',
                              'This route is not in the active zone.'));
  end if;

  select rr.id, rr.plan_id, rr.seq, rr.label, rr.total_km, rr.total_min,
         rr.worker_id, rr.assignment_id, rr.included, rr.n_stops,
         coalesce(rr.google_optimized, false) as google_optimized,
         rr.closed_count, pp.city, pp.start_min,
         aa.for_date, ww.name as worker_name
    into r
    from route_plan_routes rr
    join route_plans       pp on pp.id = rr.plan_id
    left join lead_assignments aa on aa.id = rr.assignment_id
    left join lead_workers ww on ww.id = rr.worker_id
   where rr.id = p_route_id;

  -- ── progress, exactly as routes_today words it ──────────────────────────
  select count(*), count(*) filter (where q.visited),
         coalesce(max(q.cum_km) filter (where q.visited), 0), max(q.eta_min)
    into v_total, v_done, v_kmdone, v_etamin
    from (
      select st.cum_km, st.eta_min,
             (st.visit_status is not null
              or exists (select 1 from lead_visits v
                          where v.lead_id = st.lead_id
                            and (v.assignment_id = r.assignment_id
                              or (r.worker_id is not null
                                  and v.worker_id = r.worker_id
                                  and (v.checked_in_at at time zone 'Asia/Kolkata')::date
                                      = coalesce(r.for_date, v_date))))) as visited
        from route_plan_stops st
       where st.route_id = p_route_id and st.included and st.removed_at is null
    ) q;

  v_total  := coalesce(v_total, 0);
  v_done   := coalesce(v_done, 0);
  v_kmleft := greatest(coalesce(r.total_km, 0) - coalesce(v_kmdone, 0), 0);
  v_etamin := coalesce(v_etamin, coalesce(r.start_min, 0) + coalesce(r.total_min, 0));

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
                '{done}', v_done::text), '{total}', v_total::text),
                '{km}',   to_char(v_kmleft, 'FM990.0')),
                '{eta}',  to_char((time '00:00' + make_interval(mins => v_etamin))::time,
                                  'FMHH12:MI AM'));
  end if;

  select count(*)::int into v_conv
    from route_plan_stops st
   where st.route_id = p_route_id and st.removed_at is null
     and st.visit_status = 'converted';

  -- next unvisited stop -> the Navigate link, server-built
  select st.seq, l.name, l.short_address, l.address,
         coalesce(nullif(btrim(l.maps_directions_uri), ''), nullif(btrim(l.maps_uri), ''),
                  case when l.lat is not null and l.lng is not null
                    then 'https://www.google.com/maps/dir/?api=1&destination='
                         || l.lat::text || ',' || l.lng::text end) as uri
    into nx
    from route_plan_stops st
    join scraped_leads l on l.id = st.lead_id
   where st.route_id = p_route_id and st.included and st.removed_at is null
     and st.skipped_at is null and st.visit_status is null
   order by st.seq limit 1;
  v_navuri := nx.uri;

  -- ── CMD #2057: the one removal that can still be undone ────────────────
  -- Five minutes, the backend's window. Its entry rides in EVERY stop's
  -- long-press menu, because a removed stop no longer has a card of its own.
  select st.id as stop_id, coalesce(st.removed_seq, st.seq) as back_to, l.name
    into v_undo
    from route_plan_stops st
    join scraped_leads    l on l.id = st.lead_id
   where st.route_id = p_route_id
     and st.removed_at is not null
     and st.removed_at > now() - interval '5 minutes'
   order by st.removed_at desc
   limit 1;

  if v_undo.stop_id is not null then
    v_undo_lbl := replace(replace(
      coalesce(v_copy->>'route_stop.restore_stop', 'Restore {name} to stop {seq}'),
      '{name}', coalesce(v_undo.name, '')),
      '{seq}',  coalesce(v_undo.back_to, 0)::text);
  end if;

  -- ── stops: route_stops_today's rows PLUS lead_stop_card's card ──────────
  for s in
    select st.id as stop_id, st.lead_id, st.seq, st.eta_min, st.open_at_eta,
           st.visit_status, st.visited_at, st.note, st.photo_url as proof_url,
           st.skipped_at, st.included, st.leg_km, st.cum_km,
           l.name,
           coalesce(nullif(btrim(l.short_address), ''), nullif(btrim(l.address), ''),
                    concat_ws(', ', nullif(l.area,''), nullif(l.locality,''))) as addr,
           nullif(btrim(l.photo_url), '') as lead_photo,
           l.lead_score, nullif(btrim(l.phone10), '') as phone10, l.lat, l.lng,
           nullif(btrim(l.maps_directions_uri), '') as dir_uri,
           (l.matched_customer_id is not null) as already_customer
      from route_plan_stops st
      join scraped_leads    l on l.id = st.lead_id
     where st.route_id = p_route_id and st.included and st.removed_at is null
     order by (st.skipped_at is not null), st.seq
  loop
    v_meta := public._c1873_status_meta(s.visit_status);
    v_shut := (s.open_at_eta is false) and s.visit_status is null and s.skipped_at is null;

    -- THE five actions. Identical set, identical order, on BOTH screens.
    -- enabled=false is drawn greyed, never hidden, so the row never changes
    -- shape between two stops.
    v_acts := jsonb_build_array(
      jsonb_build_object('key','call',
        'label',   coalesce(v_copy->>'route_view.act_call', 'Call'),
        'enabled', (s.phone10 is not null),
        'uri',     case when s.phone10 is not null then 'tel:+91' || s.phone10 end,
        'reason',  case when s.phone10 is null
                     then coalesce(v_copy->>'route_view.no_phone', '') end),
      jsonb_build_object('key','whatsapp',
        'label',   coalesce(v_copy->>'route_view.act_whatsapp', 'WhatsApp'),
        'enabled', (s.phone10 is not null),
        'uri',     case when s.phone10 is not null then 'https://wa.me/91' || s.phone10 end,
        'reason',  case when s.phone10 is null
                     then coalesce(v_copy->>'route_view.no_phone', '') end),
      jsonb_build_object('key','navigate',
        'label',   coalesce(v_copy->>'route_view.act_navigate', 'Navigate'),
        'enabled', (s.dir_uri is not null or s.lat is not null),
        'uri',     coalesce(s.dir_uri,
                     case when s.lat is not null then
                       'https://www.google.com/maps/dir/?api=1&destination='
                       || s.lat::text || ',' || s.lng::text end),
        'reason',  case when s.dir_uri is null and s.lat is null
                     then coalesce(v_copy->>'route_view.no_coords', '') end),
      jsonb_build_object('key','checkin',
        'label',   case when s.visit_status is null
                     then coalesce(v_copy->>'route_view.act_checkin', 'Check in')
                     else coalesce(v_copy->>'route_view.act_recheckin', 'Change') end,
        'enabled', (s.skipped_at is null)),
      jsonb_build_object('key','import_customer',
        'label',   case when s.already_customer
                     then coalesce(v_copy->>'route_view.act_imported', 'Customer')
                     else coalesce(v_copy->>'route_view.act_import', 'Import customer') end,
        'enabled', (not s.already_customer),
        'lead_id', s.lead_id,
        'reason',  case when s.already_customer
                     then coalesce(v_copy->>'route_view.already_customer', '') end));

    -- CMD #2057 — the long-press menu. Every entry names the RPC that runs
    -- it and the stop it runs on, so adding an action is a payload change.
    if s.skipped_at is null then
      v_menu := jsonb_build_array(jsonb_build_object(
        'key','stop_skip',
        'label',   coalesce(v_copy->>'route_stop.skip_stop', 'Skip this stop'),
        'rpc',     'route_stop_skip',
        'stop_id', s.stop_id,
        'enabled', true,
        'skipped', true, 'tone', 'warning'));
      v_act := v_act + 1;
    else
      v_menu := jsonb_build_array(jsonb_build_object(
        'key','stop_unskip',
        'label',   coalesce(v_copy->>'route_stop.unskip_stop', 'Put back on the route'),
        'rpc',     'route_stop_skip',
        'stop_id', s.stop_id,
        'enabled', true,
        'skipped', false, 'tone', 'brand'));
    end if;

    -- Remove from route — beside Skip. Refused for a stop already checked in,
    -- and drawn disabled there rather than hidden, so the menu never changes
    -- shape between two stops.
    v_menu := v_menu || jsonb_build_array(jsonb_build_object(
      'key','stop_remove',
      'label',   coalesce(v_copy->>'route_stop.remove_stop', 'Remove from route'),
      'rpc',     'route_stop_remove',
      'stop_id', s.stop_id,
      'enabled', (s.visit_status is null),
      'reason',  case when s.visit_status is not null
                   then coalesce(v_copy->>'route_stop.remove_blocked', '') end,
      'tone',    'danger'));

    if v_undo.stop_id is not null then
      v_menu := v_menu || jsonb_build_array(jsonb_build_object(
        'key','stop_restore',
        'label',   v_undo_lbl,
        'rpc',     'route_stop_restore',
        'stop_id', v_undo.stop_id,
        'enabled', true,
        'tone',    'brand'));
    end if;

    v_rows := v_rows || jsonb_build_object(
      'stop_id',   s.stop_id,
      'lead_id',   s.lead_id,
      'seq',       s.seq,
      'seq_label', case when s.skipped_at is null then s.seq::text else '–' end,
      'name',      coalesce(nullif(btrim(s.name), ''), 'Unnamed shop'),
      'address',   coalesce(s.addr, ''),
      'photo_url', s.lead_photo,
      'proof_url', s.proof_url,
      'photo_label', case when s.proof_url is not null
                       then coalesce(v_copy->>'route_stop.photo_open', 'View photo') end,
      'score_label', coalesce(s.lead_score, 0)::text || '/100',
      'eta_label', case when s.eta_min is not null and s.skipped_at is null then
                     replace(coalesce(v_copy->>'route_stop.eta', 'ETA {eta}'), '{eta}',
                       to_char((time '00:00' + make_interval(mins => s.eta_min))::time,
                               'FMHH12:MI AM')) end,
      'closed_label', case when v_shut then
                        coalesce(v_copy->>'route_stop.closed_at_eta', 'Closed at ETA') end,
      'is_closed_at_eta', v_shut,
      'skipped',  (s.skipped_at is not null),
      'skipped_label', case when s.skipped_at is not null then
                        coalesce(v_copy->>'route_stop.skipped_chip', 'Skipped') end,
      'can_drag', (s.skipped_at is null),
      'status_key',   s.visit_status,
      'status_label', case when v_meta is not null then
                        replace(replace(
                          coalesce(v_copy->>'route_stop.done_at', '{status} · {time}'),
                          '{status}', v_meta->>'label'),
                          '{time}', to_char(s.visited_at at time zone 'Asia/Kolkata',
                                            'FMHH12:MI AM'))
                      else coalesce(v_copy->>'route_stop.pending', 'Not checked in') end,
      'status_tone',  coalesce(v_meta->>'tone', 'neutral'),
      'note_label',   case when nullif(btrim(coalesce(s.note, '')), '') is not null then
                        replace(coalesce(v_copy->>'route_stop.note_line', 'Note: {note}'),
                                '{note}', btrim(s.note)) end,
      'already_customer', s.already_customer,
      'actions',    v_acts,
      'menu',       v_menu,
      'menu_title', replace(coalesce(v_copy->>'route_stop.menu_title', '{name}'),
                            '{name}', coalesce(s.name, '')),
      'menu_hint',  coalesce(v_copy->>'route_stop.menu_hint', ''),
      'menu_cancel', coalesce(v_copy->>'route_stop.menu_cancel', 'Cancel'));
    v_n := v_n + 1;
  end loop;

  -- ── jump windows: "Stops 1–10 / 11–20 / 21–25", server-sized ────────────
  if v_n > 10 then
    v_i := 0; v_from := 1;
    while v_from <= v_n loop
      v_to := least(v_from + 9, v_n);
      v_windows := v_windows || jsonb_build_object(
        'index', v_i, 'from', v_from, 'to', v_to,
        'label', replace(replace(coalesce(v_copy->>'route_view.window', 'Stops {from}–{to}'),
                                 '{from}', v_from::text), '{to}', v_to::text));
      v_i := v_i + 1; v_from := v_from + 10;
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'route_id', p_route_id,
    'plan_id',  r.plan_id,
    'assignment_id', r.assignment_id,
    'is_admin', v_admin,
    'stop_signature', md5(coalesce((select string_agg(x.stop_id::text, ',' order by x.ord)
                                      from (select st.id as stop_id,
                                                   row_number() over (order by (st.skipped_at is not null), st.seq) as ord
                                              from route_plan_stops st
                                             where st.route_id = p_route_id and st.included and st.removed_at is null) x), '')),
    'header', jsonb_build_object(
      'title',    coalesce(nullif(btrim(r.label), ''),
                    replace(coalesce(v_copy->>'routes_today.route_label', 'Route {seq}'),
                            '{seq}', coalesce(r.seq, 0)::text)),
      'subtitle', case when coalesce(r.n_stops, v_n) is not null then
                    coalesce(r.n_stops, v_n)::text || ' stops · '
                    || round(coalesce(r.total_km, 0), 1)::text || ' km · '
                    || (coalesce(r.total_min, 0) / 60)::text || 'h '
                    || lpad((coalesce(r.total_min, 0) % 60)::text, 2, '0') || 'm' end,
      'city',     coalesce(r.city, ''),
      'worker_label',  case when v_admin then coalesce(r.worker_name,
                         coalesce(v_copy->>'routes_today.worker_none', 'Unassigned')) end,
      'worker',        r.worker_name,
      'assigned',      (r.assignment_id is not null and r.worker_id is not null),
      'assign_label',  coalesce(v_copy->>'route_view.assign', 'Assign'),
      'can_assign',    v_admin,
      'msg_stops_label', coalesce(v_copy->>'routes.msg_stops_btn', ''),
      'progress_label', v_prog,
      'done', v_done, 'total', v_total,
      'fits_day',    (coalesce(r.total_min, 0) <= 480),
      'day_warning', case when coalesce(r.total_min, 0) > 480
                       then coalesce(v_copy->>'route_view.day_warning',
                                     'Longer than an 8-hour day') end,
      'closed_label', case when coalesce(r.closed_count, 0) > 0
                        then replace(coalesce(v_copy->>'route_view.closed_count',
                                              '{n} shut on arrival'),
                                     '{n}', r.closed_count::text) end,
      'google_optimized', r.google_optimized,
      'next_label', case when nx.name is not null
                      then replace(coalesce(v_copy->>'routes_today.next', 'Next: {name}'),
                                   '{name}', nx.name) end,
      'next_sub',   coalesce(nullif(btrim(nx.short_address), ''), nx.address),
      'nav_uri',    v_navuri,
      'nav_label',  case when v_navuri is not null
                      then coalesce(v_copy->>'routes_today.nav', 'Navigate')
                      else coalesce(v_copy->>'routes_today.nav_done', 'All stops visited') end,
      'can_navigate', v_navuri is not null)
      || public._c1875_cost_block(r.total_km, r.total_min, v_conv, 'route'),
    'map',         public._c1917_relabel_legs(public.route_map(p_route_id), v_copy),
    'map_expand_label',   coalesce(v_copy->>'route_view.map_expand', ''),
    'map_collapse_label', coalesce(v_copy->>'route_view.map_collapse', ''),
    'map_empty_label',    coalesce(v_copy->>'route_view.map_none', ''),
    -- Rule 4: mini = 180 px, large = 60% of the viewport. Both are the
    -- BACKEND's numbers, so re-tuning the map is an ui_copy UPDATE.
    'map_mini_h',   coalesce((v_copy->>'route_view.map_mini_h')::numeric, 180),
    'map_large_vh', coalesce((v_copy->>'route_view.map_large_vh')::numeric, 0.60),
    'windows',     v_windows,
    'stops',       v_rows,
    'stops_title', coalesce(v_copy->>'route_view.stops_title', 'Stops'),
    'count_label', case when v_act = 1
                     then coalesce(v_copy->>'route_stop.stops_one', '1 stop')
                     else replace(coalesce(v_copy->>'route_stop.stops_many', '{n} stops'),
                                  '{n}', v_act::text) end,
    'count',       v_n,
    'active',      v_act,
    -- CMD #2057 — the optimised order IS the order. Nothing re-orders it, so
    -- the client is told so once and draws no handle and no drag target.
    'can_reorder',  false,
    'order_locked', true,
    'reorder_hint', case when v_act > 0
                      then coalesce(v_copy->>'route_stop.locked_hint',
                                    'Route order is fixed. Long-press a stop for options.') end,
    'empty_label', case when v_n = 0 then
                     coalesce(v_copy->>'route_view.stops_empty',
                              'No stops on this route yet.') end);
end;
$function$;

-- CMD #1917 (follow-up) — the jump chips and the Maps legs read as two
-- different things.
--
-- route_map() has labelled its Google-Maps chunks 'Stops 1–10' since #1875,
-- and route_view()'s own jump windows use the same wording. Stacked in the
-- one panel the live screen showed the row twice and neither row said what
-- it did. The leg is a link OUT to Maps; the window jumps within the list.
--
-- The wording stays in the backend: route_view relabels each leg from
-- ui_copy 'route_view.leg', so re-wording it is an UPDATE, not a deploy.
-- Idempotent: re-runnable, and it only rewrites the label it is given.

insert into public.ui_copy (key, value) values
  ('route_view.leg', '"Open stops {from}–{to} in Maps"'::jsonb)
on conflict (key) do nothing;

create or replace function public._c1917_relabel_legs(p_map jsonb, p_copy jsonb)
returns jsonb language sql immutable set search_path = public as $fn$
  select case
    when p_map is null or coalesce(jsonb_typeof(p_map->'legs'), 'none') <> 'array' then p_map
    else jsonb_set(p_map, '{legs}', (
      select coalesce(jsonb_agg(
               case when l ? 'from_seq' and l ? 'to_seq'
                    then jsonb_set(l, '{label}', to_jsonb(
                           replace(replace(
                             coalesce(nullif(p_copy->>'route_view.leg', ''),
                                      'Open stops {from}–{to} in Maps'),
                             '{from}', l->>'from_seq'), '{to}', l->>'to_seq')))
                    else l end
               order by (l->>'leg')::int), '[]'::jsonb)
        from jsonb_array_elements(p_map->'legs') l))
  end;
$fn$;

grant execute on function public._c1917_relabel_legs(jsonb, jsonb) to authenticated;

create or replace function public.route_view(p_route_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
       where st.route_id = p_route_id and st.included
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
   where st.route_id = p_route_id and st.visit_status = 'converted';

  -- next unvisited stop -> the Navigate link, server-built
  select st.seq, l.name, l.short_address, l.address,
         coalesce(nullif(btrim(l.maps_directions_uri), ''), nullif(btrim(l.maps_uri), ''),
                  case when l.lat is not null and l.lng is not null
                    then 'https://www.google.com/maps/dir/?api=1&destination='
                         || l.lat::text || ',' || l.lng::text end) as uri
    into nx
    from route_plan_stops st
    join scraped_leads l on l.id = st.lead_id
   where st.route_id = p_route_id and st.included
     and st.skipped_at is null and st.visit_status is null
   order by st.seq limit 1;
  v_navuri := nx.uri;

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
     where st.route_id = p_route_id and st.included
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

    -- the long-press menu is #1874's, unchanged
    if s.skipped_at is null then
      v_menu := jsonb_build_array(jsonb_build_object(
        'key','stop_skip',
        'label',   coalesce(v_copy->>'route_stop.skip_stop', 'Skip this stop'),
        'skipped', true, 'tone', 'warning'));
      v_act := v_act + 1;
    else
      v_menu := jsonb_build_array(jsonb_build_object(
        'key','stop_unskip',
        'label',   coalesce(v_copy->>'route_stop.unskip_stop', 'Put back on the route'),
        'skipped', false, 'tone', 'brand'));
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
                                             where st.route_id = p_route_id and st.included) x), '')),
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
    'can_reorder', (v_act > 1),
    'reorder_hint', case when v_act > 1
                      then coalesce(v_copy->>'route_stop.reorder_hint',
                                    'Drag a stop to move it. Long-press for more.') end,
    'empty_label', case when v_n = 0 then
                     coalesce(v_copy->>'route_view.stops_empty',
                              'No stops on this route yet.') end);
end;
$$;

grant execute on function public.route_view(uuid) to authenticated;

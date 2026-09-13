-- CMD #1878 — Routes: worker live location dot + offline check-ins that sync later.
--
-- Three things, all decided in the backend:
--   1. A lead worker's device pings route_worker_ping(); route_worker_dots()
--      answers, zone- and date-scoped, with the dots to draw. A worker sees
--      only himself; an admin sees every worker on a route in the active zone.
--   2. route_stop_checkin() takes the DEVICE's own timestamp and is idempotent
--      on (stop_id, client_ts), so a queue replayed after airplane mode lands
--      each check-in exactly once — the second call returns the FIRST call's
--      own payload.
--   3. route_offline_bundle() is the one call the device caches on open: the
--      assigned routes, their stops, nav URIs, ETAs, and every string the
--      offline screen needs (including the "N check-ins pending sync" ladder,
--      pre-worded so Dart never pluralises anything).
--
-- Idempotent: safe to replay on live.

-- ── 1. the hot location row ────────────────────────────────────────────────
create table if not exists public.lead_worker_locations (
  worker_id   uuid primary key references public.lead_workers(id) on delete cascade,
  user_id     uuid,
  lat         numeric not null,
  lng         numeric not null,
  accuracy    numeric,
  heading     numeric,
  speed_kmh   numeric,
  moved_m     numeric,
  zone_id     bigint,
  route_id    uuid,
  for_date    date,
  updated_at  timestamptz not null default now()
);

create index if not exists lead_worker_locations_date_idx
  on public.lead_worker_locations (for_date, zone_id);

alter table public.lead_worker_locations enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='lead_worker_locations'
                    and policyname='c1878_worker_loc_read') then
    create policy c1878_worker_loc_read on public.lead_worker_locations
      for select using (
        public.get_my_role() in ('admin','super_admin')
        or worker_id = public.my_worker_id());
  end if;
end $$;

-- Realtime: the dot moves without a poll where the socket is up.
do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname='supabase_realtime' and schemaname='public'
                        and tablename='lead_worker_locations') then
    execute 'alter publication supabase_realtime add table public.lead_worker_locations';
  end if;
end $$;

-- ── 2. the check-in idempotency ledger ─────────────────────────────────────
-- One row per (stop, device clock reading). The stored payload is what the
-- FIRST call returned, so a replay is byte-identical and the rep never sees a
-- second toast worded differently from the one he already read.
create table if not exists public.route_stop_checkin_log (
  stop_id     uuid not null,
  client_ts   timestamptz not null,
  worker_id   uuid,
  status      text,
  result      jsonb,
  created_at  timestamptz not null default now(),
  primary key (stop_id, client_ts)
);

-- ── 3. copy ────────────────────────────────────────────────────────────────
-- Every string this command can put on screen. Wording is an UPDATE here, not
-- a deploy.
insert into public.ui_copy (key, value) values
  ('route_live.title',           to_jsonb('Live on the road'::text)),
  ('route_live.empty',           to_jsonb('No worker is sharing a location right now.'::text)),
  ('route_live.count_one',       to_jsonb('1 worker live'::text)),
  ('route_live.count_many',      to_jsonb('{n} workers live'::text)),
  ('route_live.me_label',        to_jsonb('You'::text)),
  ('route_live.age_now',         to_jsonb('just now'::text)),
  ('route_live.age_min',         to_jsonb('{n} min ago'::text)),
  ('route_live.age_hr',          to_jsonb('{n} hr ago'::text)),
  ('route_live.stale',           to_jsonb('last seen {age}'::text)),
  ('route_live.share_on',        to_jsonb('Sharing your location'::text)),
  ('route_live.share_off',       to_jsonb('Share my location'::text)),
  ('route_live.share_hint',      to_jsonb('Your route admin sees your dot while you are on the road.'::text)),
  ('route_live.denied',          to_jsonb('Location is blocked for this site. Allow it in the browser to share your dot.'::text)),
  ('route_live.not_a_worker',    to_jsonb('Only a lead worker on a route shares a location.'::text)),
  ('route_live.saved',           to_jsonb('Location shared.'::text)),
  ('route_sync.offline_banner',  to_jsonb('Offline — showing your saved route.'::text)),
  ('route_sync.queued',          to_jsonb('Saved on this device. It syncs when you are back online.'::text)),
  ('route_sync.synced',          to_jsonb('All check-ins synced.'::text)),
  ('route_sync.syncing',         to_jsonb('Syncing…'::text)),
  ('route_sync.retry',           to_jsonb('Sync now'::text)),
  ('route_sync.pending_one',     to_jsonb('1 check-in pending sync'::text)),
  ('route_sync.pending_many',    to_jsonb('{n} check-ins pending sync'::text)),
  ('route_sync.cached_at',       to_jsonb('Saved route from {time}'::text)),
  ('route_stop.duplicate',       to_jsonb('Already checked in.'::text))
on conflict (key) do nothing;

-- ── 4. helpers ─────────────────────────────────────────────────────────────
create or replace function public._c1878_copy()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from public.ui_copy
   where key like 'route_live.%' or key like 'route_sync.%';
$fn$;

-- "just now" / "7 min ago" / "2 hr ago" — worded here, once.
create or replace function public._c1878_age(p_ts timestamptz, p_copy jsonb)
returns text language sql stable security definer set search_path to 'public' as $fn$
  select case
    when p_ts is null then ''
    when extract(epoch from (now() - p_ts)) < 90
      then coalesce(p_copy->>'route_live.age_now', 'just now')
    when extract(epoch from (now() - p_ts)) < 5400
      then replace(coalesce(p_copy->>'route_live.age_min', '{n} min ago'),
                   '{n}', floor(extract(epoch from (now() - p_ts)) / 60)::int::text)
    else replace(coalesce(p_copy->>'route_live.age_hr', '{n} hr ago'),
                 '{n}', floor(extract(epoch from (now() - p_ts)) / 3600)::int::text)
  end;
$fn$;

-- Marker text for one worker: the initials the map draws. Never computed in Dart.
create or replace function public._c1878_initials(p_name text)
returns text language sql immutable set search_path to 'public' as $fn$
  select coalesce(nullif(upper(substr(regexp_replace(coalesce(p_name,''), '[^A-Za-z]', '', 'g'), 1, 2)), ''), '?');
$fn$;

-- The pre-worded pending-sync ladder. The device is offline when it needs
-- these, so every count it can realistically show is worded HERE and looked up
-- by key; only a count past the ladder falls back to the template.
create or replace function public._c1878_sync_block(p_copy jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_labels jsonb := '{}'::jsonb;
  i integer;
begin
  for i in 1..30 loop
    v_labels := v_labels || jsonb_build_object(
      i::text,
      case when i = 1
        then coalesce(p_copy->>'route_sync.pending_one', '1 check-in pending sync')
        else replace(coalesce(p_copy->>'route_sync.pending_many', '{n} check-ins pending sync'),
                     '{n}', i::text) end);
  end loop;
  return jsonb_build_object(
    'labels',          v_labels,
    'labels_fallback', coalesce(p_copy->>'route_sync.pending_many', '{n} check-ins pending sync'),
    'synced_label',    coalesce(p_copy->>'route_sync.synced', 'All check-ins synced.'),
    'syncing_label',   coalesce(p_copy->>'route_sync.syncing', 'Syncing…'),
    'retry_label',     coalesce(p_copy->>'route_sync.retry', 'Sync now'),
    'queued_message',  coalesce(p_copy->>'route_sync.queued',
                                'Saved on this device. It syncs when you are back online.'),
    'offline_banner',  coalesce(p_copy->>'route_sync.offline_banner',
                                'Offline — showing your saved route.'),
    'cached_at_tpl',   coalesce(p_copy->>'route_sync.cached_at', 'Saved route from {time}'));
end;
$fn$;

-- ── 5. the ping ────────────────────────────────────────────────────────────
-- The worker's device posts a fix. The route it belongs to, the zone, the
-- speed and every label are decided here.
create or replace function public.route_worker_ping(
  p_lat numeric,
  p_lng numeric,
  p_accuracy numeric default null,
  p_heading numeric default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_copy   jsonb := public._c1878_copy();
  v_worker uuid  := public.my_worker_id();
  v_name   text;
  v_date   date  := public.admin_active_date();
  v_prev   record;
  v_moved  numeric;
  v_dt     numeric;
  v_speed  numeric;
  v_route  uuid;
  v_zone   bigint;
  v_now    timestamptz := now();
begin
  if v_worker is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_worker',
      'message', coalesce(v_copy->>'route_live.not_a_worker',
                          'Only a lead worker on a route shares a location.'));
  end if;
  if p_lat is null or p_lng is null then
    return jsonb_build_object('ok', false, 'error', 'no_fix', 'message', '');
  end if;

  select w.name into v_name from public.lead_workers w where w.id = v_worker;

  -- The route he is actually on today, and the zone that route sits in.
  select rr.id, aa.zone_id into v_route, v_zone
    from public.route_plan_routes rr
    join public.lead_assignments  aa on aa.id = rr.assignment_id
   where rr.worker_id = v_worker and rr.included and aa.for_date = v_date
   order by rr.seq
   limit 1;

  select lat, lng, updated_at into v_prev
    from public.lead_worker_locations where worker_id = v_worker;

  v_moved := case when v_prev.lat is null then null
                  else public._geo_m(v_prev.lat, v_prev.lng, p_lat, p_lng) end;
  v_dt    := case when v_prev.updated_at is null then null
                  else extract(epoch from (v_now - v_prev.updated_at)) end;
  v_speed := case when v_dt is null or v_dt <= 0 or v_moved is null then null
                  else round((v_moved / v_dt) * 3.6, 1) end;

  insert into public.lead_worker_locations as t
    (worker_id, user_id, lat, lng, accuracy, heading, speed_kmh, moved_m,
     zone_id, route_id, for_date, updated_at)
  values (v_worker, auth.uid(), p_lat, p_lng, p_accuracy, p_heading, v_speed,
          v_moved, v_zone, v_route, v_date, v_now)
  on conflict (worker_id) do update set
    user_id = excluded.user_id, lat = excluded.lat, lng = excluded.lng,
    accuracy = excluded.accuracy, heading = excluded.heading,
    speed_kmh = excluded.speed_kmh, moved_m = excluded.moved_m,
    zone_id = excluded.zone_id, route_id = excluded.route_id,
    for_date = excluded.for_date, updated_at = excluded.updated_at;

  return jsonb_build_object(
    'ok', true,
    'worker_id', v_worker,
    'route_id',  v_route,
    'label',     coalesce(v_copy->>'route_live.me_label', 'You'),
    'age_label', coalesce(v_copy->>'route_live.age_now', 'just now'),
    'message',   coalesce(v_copy->>'route_live.saved', 'Location shared.'));
end;
$fn$;

-- ── 6. the dots ────────────────────────────────────────────────────────────
-- Zone- and date-scoped, exactly like every other Routes read: an admin sees
-- every worker with a route in admin_active_zone() on admin_active_date(); a
-- worker sees his own dot and nobody else's.
create or replace function public.route_worker_dots()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_copy   jsonb := public._c1878_copy();
  v_role   text  := coalesce(public.get_my_role(), '');
  v_admin  boolean;
  v_worker uuid  := public.my_worker_id();
  v_date   date  := public.admin_active_date();
  v_zone   smallint := public.admin_active_zone();
  v_dots   jsonb := '[]'::jsonb;
  v_n      integer := 0;
  v_stale  integer := 600;   -- a fix older than this is drawn muted
  r        record;
  v_age    text;
begin
  v_admin := v_role in ('admin','super_admin');
  if not v_admin and v_worker is null then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'dots', '[]'::jsonb, 'count_label', '',
      'title', coalesce(v_copy->>'route_live.title', 'Live on the road'),
      'empty_label', coalesce(v_copy->>'route_live.not_a_worker', ''),
      'poll_ms', 20000, 'ping_ms', 15000, 'stale_after_s', v_stale,
      'channel', 'lead_worker_locations');
  end if;

  for r in
    select loc.worker_id, loc.lat, loc.lng, loc.updated_at, loc.speed_kmh,
           loc.route_id, w.name,
           coalesce(loc.worker_id = v_worker, false) as is_me,
           rr.label as route_label
      from public.lead_worker_locations loc
      join public.lead_workers w on w.id = loc.worker_id
      left join public.route_plan_routes rr on rr.id = loc.route_id
      left join public.route_plans       pp on pp.id = rr.plan_id
      left join public.lead_assignments  aa on aa.id = rr.assignment_id
     where loc.for_date = v_date
       and (v_admin or loc.worker_id = v_worker)
       and (rr.id is null
            or public._c1872_zone_match(v_zone, pp.city, aa.zone_id))
       and (v_admin is false or rr.id is not null)
     order by coalesce(loc.worker_id = v_worker, false) desc, w.name
  loop
    v_age := public._c1878_age(r.updated_at, v_copy);
    v_dots := v_dots || jsonb_build_object(
      'worker_id',    r.worker_id,
      'label',        case when r.is_me
                        then coalesce(v_copy->>'route_live.me_label', 'You')
                        else coalesce(r.name, '') end,
      'sub_label',    coalesce(r.route_label, ''),
      'age_label',    v_age,
      'marker_label', public._c1878_initials(
                        case when r.is_me then coalesce(r.name, 'You') else r.name end),
      'lat',          r.lat,
      'lng',          r.lng,
      'is_me',        r.is_me,
      'route_id',     r.route_id,
      'tone',         case when extract(epoch from (now() - r.updated_at)) > v_stale
                        then 'muted' when r.is_me then 'brand' else 'info' end,
      'stale',        extract(epoch from (now() - r.updated_at)) > v_stale);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object(
    'ok',            true,
    'title',         coalesce(v_copy->>'route_live.title', 'Live on the road'),
    'dots',          v_dots,
    'count',         v_n,
    'count_label',   case when v_n = 0 then ''
                       when v_n = 1 then coalesce(v_copy->>'route_live.count_one', '1 worker live')
                       else replace(coalesce(v_copy->>'route_live.count_many', '{n} workers live'),
                                    '{n}', v_n::text) end,
    'empty_label',   coalesce(v_copy->>'route_live.empty',
                              'No worker is sharing a location right now.'),
    'share_on_label',  coalesce(v_copy->>'route_live.share_on', 'Sharing your location'),
    'share_off_label', coalesce(v_copy->>'route_live.share_off', 'Share my location'),
    'share_hint',      coalesce(v_copy->>'route_live.share_hint', ''),
    'denied_label',    coalesce(v_copy->>'route_live.denied', ''),
    'can_share',     (v_worker is not null),
    'is_admin',      v_admin,
    'poll_ms',       20000,
    'ping_ms',       15000,
    'stale_after_s', v_stale,
    'channel',       'lead_worker_locations');
end;
$fn$;

-- ── 7. the idempotent check-in ─────────────────────────────────────────────
-- The 4-argument version is DROPPED before the 5-argument one is created:
-- leaving both would make every existing 4-named-argument call ambiguous
-- (PostgREST resolves by name, and both candidates match).
drop function if exists public.route_stop_checkin(uuid, text, text, text);

create or replace function public.route_stop_checkin(
  p_stop_id uuid,
  p_status text,
  p_note text default null,
  p_photo text default null,
  p_client_ts timestamptz default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_copy   jsonb;
  v_st     record;
  v_meta   jsonb;
  v_url    text;
  v_base   text;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_worker uuid := public.my_worker_id();
  v_lead   scraped_leads%rowtype;
  v_msg    text;
  v_next   jsonb;
  v_prev   jsonb;
  v_out    jsonb;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  -- CMD #1878 — a queue replayed after airplane mode sends the SAME
  -- (stop_id, client_ts) twice. The second call never writes: it returns the
  -- first call's own payload, so the rep reads one toast, the lead gets one
  -- visit row, and the day summary counts the stop once.
  if p_client_ts is not null then
    select result into v_prev
      from route_stop_checkin_log
     where stop_id = p_stop_id and client_ts = p_client_ts;
    if v_prev is not null then
      return v_prev || jsonb_build_object('duplicate', true);
    end if;
  end if;

  v_meta := public._c1873_status_meta(p_status);
  if v_meta is null then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', coalesce(v_copy->>'route_stop.bad_status', 'Unknown outcome.'));
  end if;

  select s.id, s.route_id, s.lead_id, rr.assignment_id, l.name
    into v_st
    from route_plan_stops s
    join route_plan_routes rr on rr.id = s.route_id
    join scraped_leads     l  on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'stop_not_found',
      'message', coalesce(v_copy->>'route_stop.not_found',
                          'That stop is no longer on this route.'));
  end if;

  if not public._c1873_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot check in on this route.'));
  end if;

  if nullif(btrim(coalesce(p_photo, '')), '') is not null then
    v_base := coalesce((select value #>> '{}' from app_settings where key='storage_public_base'),
                       'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public');
    v_url  := v_base || '/lead-photos/' || btrim(p_photo);
  end if;

  update route_plan_stops set
    visit_status = p_status,
    visited_at   = now(),
    visited_by   = auth.uid(),
    note         = v_note,
    photo_url    = coalesce(v_url, photo_url)
  where id = p_stop_id;

  insert into lead_visits (lead_id, worker_id, assignment_id, status, note,
                           photo_url, verified, suspicious)
  values (v_st.lead_id, v_worker, v_st.assignment_id, p_status, v_note,
          v_url, true, false);

  select * into v_lead from scraped_leads where id = v_st.lead_id;

  if p_status = 'not_interested' and v_lead.revisit_after is not null then
    v_msg := replace(replace(replace(
               coalesce(v_copy->>'route_stop.saved_revisit',
                        '{name} — {status}. Back on a route after {date}.'),
               '{name}',   coalesce(v_st.name, '')),
               '{status}', v_meta->>'label'),
               '{date}',   to_char(v_lead.revisit_after, 'FMDD Mon YYYY'));
  else
    v_msg := replace(replace(
               coalesce(v_copy->>'route_stop.saved', '{name} — {status}.'),
               '{name}',   coalesce(v_st.name, '')),
               '{status}', v_meta->>'label');
  end if;

  if p_status = 'converted' and v_lead.matched_customer_id is null then
    v_next := jsonb_build_object(
      'key',     'add_customer',
      'lead_id', v_st.lead_id,
      'label',   coalesce(v_copy->>'route_stop.add_customer', 'Add customer'),
      'hint',    coalesce(v_copy->>'route_stop.add_customer_hint', ''));
  end if;

  v_out := jsonb_build_object(
    'ok',            true,
    'stop_id',       p_stop_id,
    'lead_id',       v_st.lead_id,
    'status',        p_status,
    'status_label',  v_meta->>'label',
    'status_tone',   v_meta->>'tone',
    'photo_url',     v_url,
    'visit_count',   v_lead.visit_count,
    'revisit_after', v_lead.revisit_after,
    'next_action',   v_next,
    'message',       v_msg);

  if p_client_ts is not null then
    -- The ledger is the idempotency key AND the replay's answer. A race that
    -- loses the insert means another connection already wrote this exact
    -- check-in, so its stored payload wins.
    insert into route_stop_checkin_log (stop_id, client_ts, worker_id, status, result)
    values (p_stop_id, p_client_ts, v_worker, p_status, v_out)
    on conflict (stop_id, client_ts) do nothing;
  end if;

  return v_out;
end;
$fn$;

-- ── 8. the offline bundle ──────────────────────────────────────────────────
-- ONE call, cached on the device the moment the Routes tab opens. Everything
-- the screen needs with no network: the routes, their stops, the nav URIs and
-- ETAs the cards print, and the sync/offline copy. The device re-renders this
-- payload verbatim when it cannot reach the server.
create or replace function public.route_offline_bundle()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_copy   jsonb := public._c1878_copy();
  v_today  jsonb;
  v_stops  jsonb := '{}'::jsonb;
  v_sheets jsonb := '{}'::jsonb;
  v_one    jsonb;
  r        jsonb;
  v_rid    text;
  v_sid    text;
begin
  begin
    v_today := public.routes_today();
  exception when others then
    v_today := jsonb_build_object('ok', false, 'routes', '[]'::jsonb);
  end;

  for r in select jsonb_array_elements(coalesce(v_today->'routes', '[]'::jsonb))
  loop
    v_rid := r->>'route_id';
    if v_rid is not null then
      v_one := public.route_stops_today(v_rid::uuid);
      v_stops := v_stops || jsonb_build_object(v_rid, v_one);
      -- The CHECK-IN SHEET itself is cached too. Without this the rep can see
      -- his stops in airplane mode but cannot open one, which is the whole
      -- point of the offline lane.
      for v_sid in
        select jsonb_array_elements(coalesce(v_one->'stops', '[]'::jsonb))->>'stop_id'
      loop
        if v_sid is not null then
          v_sheets := v_sheets || jsonb_build_object(
            v_sid, public.route_stop_sheet(v_sid::uuid));
        end if;
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'ok',         true,
    'cached_key', 'c1878_route_bundle',
    'server_time', to_char(now() at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM'),
    'today',      coalesce(v_today, '{}'::jsonb),
    'stops',      v_stops,
    'sheets',     v_sheets,
    'live',       public.route_worker_dots(),
    'sync',       public._c1878_sync_block(v_copy));
end;
$fn$;

grant execute on function public.route_worker_ping(numeric, numeric, numeric, numeric) to authenticated;
grant execute on function public.route_worker_dots() to authenticated;
grant execute on function public.route_offline_bundle() to authenticated;
grant execute on function public.route_stop_checkin(uuid, text, text, text, timestamptz) to authenticated;

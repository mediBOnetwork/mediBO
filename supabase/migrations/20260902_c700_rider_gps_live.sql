-- CHANGE #700 — Rider GPS that never dies (register gap #124)
--
-- WHAT WAS BROKEN
-- delivery_update_location() was driven by a Dart Timer on the rider's screen.
-- On Android that timer had nothing to send: DeviceLocation is a web-only
-- implementation and its native fallback returns null, so an Android rider
-- reported NO position at all. On web it stopped the moment the tab lost focus.
-- And customer_track_order()'s live view subscribed to postgres_changes on
-- delivery_partner_locations — a table that is NOT in the supabase_realtime
-- publication (it holds exactly 8 tables), so that subscription never fired a
-- single event. The customer map has been a still photograph.
--
-- WHAT THIS BUILDS
--   1. A run-scoped realtime BROADCAST (realtime.send on topic run:<run_id>),
--      not postgres_changes — the publication stays at its 8 tables. The topic
--      is a PRIVATE channel, gated by an RLS policy on realtime.messages, so a
--      leaked run id is not a location leak.
--   2. Road snapping BEFORE the broadcast, through the existing OSRM stack,
--      with the endpoint in CONFIG (it was a hardcoded literal in Dart), a
--      durable grid cache, and a circuit breaker so a dead OSRM can never slow
--      or block the hot path. Raw and snapped are both kept.
--   3. A run-level trail table for replay (admin timeline, disputes) with its
--      own retention, separate from the 30-day partner history.
--   4. A staleness block ("Live" / "Last seen 4 min ago" / "Rider offline")
--      computed and WORDED in the backend from location_updated_at, with the
--      thresholds in config.
--
-- Every migration here is idempotent: a resumed worker re-applies it as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CONFIG — every threshold the rider service and the maps obey
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.delivery_config
  add column if not exists live_fg_interval_s        int     not null default 5,
  add column if not exists live_fg_min_move_m        int     not null default 20,
  add column if not exists live_fg_battery_pct       int     not null default 20,
  add column if not exists live_fg_battery_interval_s int    not null default 30,
  add column if not exists live_stale_live_s         int     not null default 45,
  add column if not exists live_stale_offline_s      int     not null default 300,
  add column if not exists live_animate_ms           int     not null default 1200,
  add column if not exists snap_enabled              boolean not null default true,
  add column if not exists snap_base_url             text    not null default 'http://35.234.212.254:5000',
  add column if not exists snap_timeout_ms           int     not null default 1200,
  add column if not exists snap_grid_m               int     not null default 15,
  add column if not exists snap_max_dist_m           int     not null default 60,
  add column if not exists snap_fail_threshold       int     not null default 3,
  add column if not exists snap_cooldown_s           int     not null default 300,
  add column if not exists trail_retain_days         int     not null default 180;

comment on column public.delivery_config.snap_base_url is
  'OSRM base URL for road snapping. Was a hardcoded literal in Dart (CHANGE #700 moved it here) — point it at a live OSRM and snapping resumes with no deploy.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. SNAP CACHE + CIRCUIT BREAKER
-- A rider on a delivery round covers the same streets repeatedly, so a grid
-- cache turns most fixes into zero HTTP calls. The breaker exists because the
-- snapper sits in front of a LIVE location publish: an OSRM that stops
-- answering must degrade the map to raw GPS, never delay the rider's dot.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.osrm_snap_cache (
  gx           bigint      not null,
  gy           bigint      not null,
  snap_lat     numeric     not null,
  snap_lng     numeric     not null,
  dist_m       numeric,
  hits         int         not null default 0,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  primary key (gx, gy)
);

create table if not exists public.osrm_breaker (
  id          int primary key default 1,
  fails       int         not null default 0,
  opened_at   timestamptz,
  last_ok_at  timestamptz,
  last_error  text,
  calls       bigint      not null default 0,
  cache_hits  bigint      not null default 0,
  updated_at  timestamptz not null default now(),
  constraint osrm_breaker_singleton check (id = 1)
);
insert into public.osrm_breaker(id) values (1) on conflict (id) do nothing;

alter table public.osrm_snap_cache enable row level security;
alter table public.osrm_breaker    enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RUN TRAIL — the replayable record (admin timeline, disputes)
-- delivery_partner_location_history is keyed by PARTNER and purged at 30 days;
-- a dispute about one run needs that run's line to survive on its own clock.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.delivery_run_trail (
  id         bigserial primary key,
  run_id     uuid        not null,
  partner_id uuid        not null,
  ts         timestamptz not null default now(),
  lat        numeric     not null,
  lng        numeric     not null,
  snap_lat   numeric,
  snap_lng   numeric,
  snapped    boolean     not null default false,
  heading    numeric,
  accuracy   numeric,
  moved_m    numeric,
  speed_kmh  numeric,
  battery    int,
  source     text        not null default 'app'
);
create index if not exists delivery_run_trail_run_ts_idx
  on public.delivery_run_trail (run_id, ts);
create index if not exists delivery_run_trail_ts_idx
  on public.delivery_run_trail (ts);
alter table public.delivery_run_trail enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE WORDS. Every user-facing string on this feature is a row, not a Dart
--    literal and not a SQL literal buried in a payload builder.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('delivery.live_now',        to_jsonb('Live'::text)),
  ('delivery.live_seconds',    to_jsonb('Last seen just now'::text)),
  ('delivery.live_minutes',    to_jsonb('Last seen {n} min ago'::text)),
  ('delivery.live_one_minute', to_jsonb('Last seen 1 min ago'::text)),
  ('delivery.live_offline',    to_jsonb('Rider offline'::text)),
  ('delivery.live_none',       to_jsonb('Waiting for the rider to start'::text)),
  ('delivery.live_raw_note',   to_jsonb('Showing raw GPS'::text)),
  ('delivery.trail_title',     to_jsonb('Route taken'::text)),
  ('delivery.trail_empty',     to_jsonb('No positions recorded for this trip yet.'::text)),
  ('delivery.trail_points',    to_jsonb('{n} positions'::text)),
  ('delivery.trail_one_point', to_jsonb('1 position'::text)),
  ('delivery.live_map_title',  to_jsonb('Live rider'::text)),
  ('delivery.live_track_action', to_jsonb('Track rider'::text)),
  ('delivery.live_no_run',     to_jsonb('This delivery has no trip yet.'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. STALENESS — one place decides what "live" means, and says it in words.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_live_block(p_updated_at timestamptz)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare c record; v_age numeric; v_min int;
begin
  select live_stale_live_s, live_stale_offline_s into c from public.delivery_config where id = 1;
  if p_updated_at is null then
    return jsonb_build_object(
      'has', false, 'is_live', false, 'state', 'none',
      'label', public._c('delivery.live_none'), 'tone', 'muted', 'age_s', null);
  end if;

  v_age := extract(epoch from (now() - p_updated_at));

  if v_age <= coalesce(c.live_stale_live_s, 45) then
    return jsonb_build_object(
      'has', true, 'is_live', true, 'state', 'live',
      'label', public._c('delivery.live_now'), 'tone', 'success',
      'age_s', round(v_age));
  end if;

  if v_age >= coalesce(c.live_stale_offline_s, 300) then
    return jsonb_build_object(
      'has', true, 'is_live', false, 'state', 'offline',
      'label', public._c('delivery.live_offline'), 'tone', 'danger',
      'age_s', round(v_age));
  end if;

  v_min := floor(v_age / 60.0)::int;
  return jsonb_build_object(
    'has', true, 'is_live', false, 'state', 'stale',
    'label', case
               when v_min <= 0 then public._c('delivery.live_seconds')
               when v_min = 1  then public._c('delivery.live_one_minute')
               else public._cf('delivery.live_minutes', jsonb_build_object('n', v_min))
             end,
    'tone', 'warning', 'age_s', round(v_age));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. SNAP LOOKUP — the cheap half of snapping, run BEFORE any HTTP.
-- Answers: is snapping on, is the breaker closed, do we already know this
-- 15-metre square, and if not, exactly which URL to call and for how long.
-- The caller (the rider-location edge function) does the fetch; nothing in
-- Postgres ever blocks on a network round trip.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_snap_lookup(p_lat numeric, p_lng numeric)
returns jsonb
language plpgsql volatile security definer set search_path to 'public'
as $$
declare
  c record; v_gx bigint; v_gy bigint; v_hit record;
  v_dlat numeric; v_dlng numeric; v_open boolean := false;
begin
  select snap_enabled, snap_base_url, snap_timeout_ms, snap_grid_m,
         snap_max_dist_m, snap_cooldown_s
    into c from public.delivery_config where id = 1;

  if not coalesce(c.snap_enabled, false)
     or coalesce(c.snap_base_url, '') = ''
     or p_lat is null or p_lng is null then
    return jsonb_build_object('snap', false, 'hit', false, 'reason', 'disabled');
  end if;

  -- Breaker: an OSRM that failed snap_fail_threshold times in a row is left
  -- alone for snap_cooldown_s. The rider's dot keeps publishing regardless.
  select (opened_at is not null
          and now() < opened_at + make_interval(secs => coalesce(c.snap_cooldown_s, 300)))
    into v_open from public.osrm_breaker where id = 1;
  if coalesce(v_open, false) then
    return jsonb_build_object('snap', false, 'hit', false, 'reason', 'breaker_open');
  end if;

  v_dlat := coalesce(c.snap_grid_m, 15)::numeric / 111320.0;
  v_dlng := coalesce(c.snap_grid_m, 15)::numeric
            / greatest(111320.0 * cos(radians(p_lat)), 1.0);
  v_gx := floor(p_lng / v_dlng)::bigint;
  v_gy := floor(p_lat / v_dlat)::bigint;

  select snap_lat, snap_lng, dist_m into v_hit
    from public.osrm_snap_cache where gx = v_gx and gy = v_gy;

  if v_hit.snap_lat is not null then
    update public.osrm_snap_cache
       set hits = hits + 1, last_used_at = now()
     where gx = v_gx and gy = v_gy;
    update public.osrm_breaker set cache_hits = cache_hits + 1, updated_at = now() where id = 1;
    return jsonb_build_object(
      'snap', true, 'hit', true, 'gx', v_gx, 'gy', v_gy,
      'snap_lat', v_hit.snap_lat, 'snap_lng', v_hit.snap_lng, 'dist_m', v_hit.dist_m);
  end if;

  return jsonb_build_object(
    'snap', true, 'hit', false, 'gx', v_gx, 'gy', v_gy,
    'url', rtrim(c.snap_base_url, '/') || '/nearest/v1/driving/'
           || p_lng::text || ',' || p_lat::text || '?number=1',
    'timeout_ms', coalesce(c.snap_timeout_ms, 1200),
    'max_dist_m', coalesce(c.snap_max_dist_m, 60));
end $$;

-- The breaker's own bookkeeping, so the edge function reports what happened
-- instead of deciding what it means.
create or replace function public.delivery_snap_report(
  p_ok boolean, p_error text default null,
  p_gx bigint default null, p_gy bigint default null,
  p_snap_lat numeric default null, p_snap_lng numeric default null,
  p_dist_m numeric default null)
returns jsonb
language plpgsql volatile security definer set search_path to 'public'
as $$
declare v_thresh int; v_fails int;
begin
  select coalesce(snap_fail_threshold, 3) into v_thresh from public.delivery_config where id = 1;

  if coalesce(p_ok, false) then
    update public.osrm_breaker
       set fails = 0, opened_at = null, last_ok_at = now(), last_error = null,
           calls = calls + 1, updated_at = now()
     where id = 1;
    if p_gx is not null and p_snap_lat is not null then
      insert into public.osrm_snap_cache(gx, gy, snap_lat, snap_lng, dist_m, hits)
      values (p_gx, p_gy, p_snap_lat, p_snap_lng, p_dist_m, 1)
      on conflict (gx, gy) do update
        set snap_lat = excluded.snap_lat, snap_lng = excluded.snap_lng,
            dist_m = excluded.dist_m, last_used_at = now();
    end if;
    return jsonb_build_object('ok', true, 'breaker', 'closed');
  end if;

  update public.osrm_breaker
     set fails = fails + 1,
         last_error = left(coalesce(p_error, 'unknown'), 300),
         calls = calls + 1,
         opened_at = case when fails + 1 >= v_thresh then now() else opened_at end,
         updated_at = now()
   where id = 1
   returning fails into v_fails;

  return jsonb_build_object('ok', true, 'fails', v_fails,
                            'breaker', case when v_fails >= v_thresh then 'open' else 'closed' end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. WHO MAY LISTEN TO run:<run_id>
-- The channel is PRIVATE, so realtime asks this before it delivers a frame.
-- Same three parties customer_track_order() already trusts: the platform, the
-- rider on that run, and a customer with a stop on it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._can_read_run_channel(p_topic text)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_run uuid; v_raw text;
begin
  if p_topic is null or p_topic !~ '^run:' then return false; end if;
  v_raw := substring(p_topic from 5);
  if v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  v_run := v_raw::uuid;

  if public._is_admin() then return true; end if;

  -- the rider running it
  if exists (select 1 from public.delivery_runs r
              join public.delivery_partner_registrations p on p.id = r.partner_id
             where r.id = v_run and p.user_id = auth.uid()) then
    return true;
  end if;

  -- a customer with a stop on it
  if exists (select 1 from public.deliveries d
              join public.orders o  on o.id = d.order_id
              join public.pharmacy_profiles pp on pp.id = o.customer_id
             where d.run_id = v_run and pp.user_id = auth.uid()) then
    return true;
  end if;

  return false;
end $$;

drop policy if exists c700_run_channel_read on realtime.messages;
create policy c700_run_channel_read on realtime.messages
  for select to authenticated
  using (public._can_read_run_channel((select realtime.topic())));

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE HOT PATH.
-- Signature grows by the snapped point the caller (the rider-location edge
-- function) resolved BEFORE calling, so the broadcast carries a road-snapped
-- position rather than a correction that arrives later. Called WITHOUT the snap
-- arguments — which is exactly what the old four-argument callers do — it still
-- works and publishes the raw fix with snapped:false. Nothing regresses.
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.delivery_update_location(numeric, numeric, numeric, numeric);

create or replace function public.delivery_update_location(
  p_lat numeric, p_lng numeric,
  p_heading numeric default null, p_accuracy numeric default null,
  p_snap_lat numeric default null, p_snap_lng numeric default null,
  p_snap_dist_m numeric default null, p_battery int default null,
  p_source text default 'app')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_partner uuid; cfg jsonb; v_radius numeric; v_min_acc numeric;
  r record; v_arrived jsonb := '[]'::jsonb;
  v_prev record; v_moved numeric; v_min_move numeric; v_run uuid;
  v_snapped boolean; v_map_lat numeric; v_map_lng numeric;
  v_dt numeric; v_speed numeric; v_last_trail timestamptz;
  v_animate int; v_live jsonb; v_now timestamptz := now();
begin
  select id into v_partner from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null then return jsonb_build_object('ok',false,'error','not_a_partner'); end if;

  -- gap #116: the breadcrumb, written BEFORE the hot row is overwritten so the
  -- distance is measured against the fix it actually replaces.
  select lat, lng, updated_at into v_prev
    from public.delivery_partner_locations where partner_id = v_partner;
  v_moved := case when v_prev.lat is null then null
                  else public._geo_m(v_prev.lat, v_prev.lng, p_lat, p_lng) end;
  select coalesce(location_min_move_m, 25), coalesce(live_animate_ms, 1200)
    into v_min_move, v_animate from public.delivery_config where id = 1;
  select id into v_run from public.delivery_runs
   where partner_id = v_partner and status = 'started'
   order by created_at desc limit 1;

  -- Speed is derived here, once, so no map ever computes it.
  v_dt := case when v_prev.updated_at is null then null
               else extract(epoch from (v_now - v_prev.updated_at)) end;
  v_speed := case when v_dt is null or v_dt <= 0 or v_moved is null then null
                  else round((v_moved / v_dt) * 3.6, 1) end;

  v_snapped := (p_snap_lat is not null and p_snap_lng is not null);
  v_map_lat := case when v_snapped then p_snap_lat else p_lat end;
  v_map_lng := case when v_snapped then p_snap_lng else p_lng end;

  if v_moved is null or v_moved >= coalesce(v_min_move, 25) then
    insert into public.delivery_partner_location_history(partner_id, run_id, ts, lat, lng, heading, accuracy, moved_m)
    values (v_partner, v_run, v_now, p_lat, p_lng, p_heading, p_accuracy, v_moved);
  end if;

  -- The run trail: every meaningful move, plus a heartbeat row once a minute
  -- while stationary. A dispute needs to be able to prove the rider was PARKED
  -- outside the shop, which a move-only trail can never show.
  if v_run is not null then
    select max(ts) into v_last_trail from public.delivery_run_trail where run_id = v_run;
    if v_moved is null or v_moved >= coalesce(v_min_move, 25)
       or v_last_trail is null or v_last_trail < v_now - interval '60 seconds' then
      insert into public.delivery_run_trail(
        run_id, partner_id, ts, lat, lng, snap_lat, snap_lng, snapped,
        heading, accuracy, moved_m, speed_kmh, battery, source)
      values (v_run, v_partner, v_now, p_lat, p_lng,
              p_snap_lat, p_snap_lng, v_snapped,
              p_heading, p_accuracy, v_moved, v_speed, p_battery,
              coalesce(nullif(p_source,''), 'app'));
    end if;
  end if;

  insert into public.delivery_partner_locations(partner_id, lat, lng, heading, accuracy, updated_at)
  values (v_partner, p_lat, p_lng, p_heading, p_accuracy, v_now)
  on conflict (partner_id) do update
    set lat=excluded.lat, lng=excluded.lng, heading=excluded.heading,
        accuracy=excluded.accuracy, updated_at=v_now;

  -- BROADCAST, not postgres_changes. delivery_partner_locations is not in the
  -- supabase_realtime publication and must not be added to it — the publication
  -- holds 8 tables and that is the budget. A run-scoped broadcast also means a
  -- customer's socket carries only the rider bringing THEIR order, instead of
  -- every rider's position in the fleet.
  if v_run is not null then
    v_live := public._delivery_live_block(v_now);
    begin
      perform realtime.send(
        jsonb_build_object(
          'run_id',     v_run,
          'ts',         v_now,
          'lat',        p_lat,        'lng',        p_lng,
          'snap_lat',   p_snap_lat,   'snap_lng',   p_snap_lng,
          'snapped',    v_snapped,
          'snap_dist_m', p_snap_dist_m,
          'map_lat',    v_map_lat,    'map_lng',    v_map_lng,
          'heading',    p_heading,    'accuracy',   p_accuracy,
          'speed_kmh',  v_speed,      'battery',    p_battery,
          'moved_m',    v_moved,
          'animate_ms', coalesce(v_animate, 1200),
          'source',     coalesce(nullif(p_source,''), 'app'),
          'note',       case when v_snapped then '' else public._c('delivery.live_raw_note') end,
          'live',       v_live),
        'rider', 'run:' || v_run::text, true);
    exception when others then
      -- A realtime hiccup must never cost the rider their position write.
      null;
    end;
  end if;

  cfg := public._dcfg(null);
  v_radius  := coalesce((cfg->>'geofence_radius_m')::numeric, 150);
  v_min_acc := coalesce((cfg->>'geofence_min_accuracy_m')::numeric, 250);

  if p_accuracy is not null and p_accuracy > v_min_acc then
    return jsonb_build_object('ok',true,'arrived',v_arrived,'skipped_accuracy',true,
                              'run_id',v_run,'snapped',v_snapped);
  end if;

  for r in
    select d.id, d.order_id, d.lat, d.lng
      from public.deliveries d
     where d.partner_id = v_partner
       and d.status = 'out_for_delivery'
       and d.arrived_at is null
       and d.lat is not null and d.lng is not null
  loop
    if public._geo_m(p_lat, p_lng, r.lat, r.lng) <= v_radius then
      update public.deliveries
         set arrived_at = now(), arrived_lat = p_lat, arrived_lng = p_lng
       where id = r.id and arrived_at is null;

      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
      values (r.id, r.order_id, v_partner, 'arrived', 'geofence', p_lat, p_lng, 'system');

      begin
        perform public.wa_notify_event(
          'delivery_arriving', null, '{}'::jsonb, null, r.order_id,
          'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
          jsonb_build_object('event','arriving','delivery_id',r.id));
        update public.deliveries set arrival_notified_at = now() where id = r.id;
      exception when others then
        perform public._wa_log_attempt('delivery_arriving', r.order_id, null, 'skipped',
                                       false, 'caller_error: ' || sqlerrm);
      end;

      v_arrived := v_arrived || jsonb_build_object('delivery_id', r.id,
                     'chip', public._c('delivery.arrived_chip'));
    end if;
  end loop;

  return jsonb_build_object('ok',true,'arrived',v_arrived,
                            'run_id',v_run,'snapped',v_snapped,
                            'channel', case when v_run is not null
                                            then 'run:' || v_run::text end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. WHAT THE RIDER'S DEVICE IS TOLD TO DO.
-- The Android foreground service holds no policy of its own: its interval, its
-- distance filter, its battery-saver switch and even the words on its
-- notification arrive from here. Retuning the fleet is an UPDATE.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('delivery.fg_notif_title',   to_jsonb('Trip in progress'::text)),
  ('delivery.fg_notif_body',    to_jsonb('Sharing your location so the shop can track this delivery.'::text)),
  ('delivery.fg_channel_name',  to_jsonb('Delivery trip'::text)),
  ('delivery.fg_perm_title',    to_jsonb('Location needed for the trip'::text)),
  ('delivery.fg_perm_body',     to_jsonb('Allow location so your stops can see you on the way.'::text))
on conflict (key) do nothing;

create or replace function public.delivery_live_config()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare c record;
begin
  select * into c from public.delivery_config where id = 1;
  return jsonb_build_object(
    'ok', true,
    'interval_s',          coalesce(c.live_fg_interval_s, 5),
    'min_move_m',          coalesce(c.live_fg_min_move_m, 20),
    'battery_saver_pct',   coalesce(c.live_fg_battery_pct, 20),
    'battery_interval_s',  coalesce(c.live_fg_battery_interval_s, 30),
    'animate_ms',          coalesce(c.live_animate_ms, 1200),
    'stale_live_s',        coalesce(c.live_stale_live_s, 45),
    'stale_offline_s',     coalesce(c.live_stale_offline_s, 300),
    -- the words the Android notification wears
    'notif_title',   public._c('delivery.fg_notif_title'),
    'notif_body',    public._c('delivery.fg_notif_body'),
    'channel_name',  public._c('delivery.fg_channel_name'),
    'perm_title',    public._c('delivery.fg_perm_title'),
    'perm_body',     public._c('delivery.fg_perm_body'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. ONE PAYLOAD FOR EVERY LIVE MAP (customer sheet, admin sheet, rider).
-- Resolves by run OR by delivery, because the admin queue holds delivery ids
-- and the customer sheet holds an order — neither should have to learn what a
-- run id is to draw a dot.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_live_state(
  p_run_id uuid default null, p_delivery_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_run uuid := p_run_id; r record; v_loc record; v_allowed boolean;
  v_name text; v_animate int; v_snapped boolean; v_last record;
begin
  if v_run is null and p_delivery_id is not null then
    select run_id into v_run from public.deliveries where id = p_delivery_id;
  end if;
  if v_run is null then
    return jsonb_build_object('ok', false, 'error', 'no_run',
                              'message', public._c('delivery.live_no_run'));
  end if;

  select public._can_read_run_channel('run:' || v_run::text) into v_allowed;
  if not coalesce(v_allowed, false) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  select * into r from public.delivery_runs where id = v_run;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_run',
                              'message', public._c('delivery.live_no_run'));
  end if;

  select * into v_loc from public.delivery_partner_locations where partner_id = r.partner_id;
  select full_name into v_name from public.delivery_partner_registrations where id = r.partner_id;
  select coalesce(live_animate_ms, 1200) into v_animate from public.delivery_config where id = 1;

  -- the newest trail row carries the snapped twin of the hot row
  select snap_lat, snap_lng, snapped, speed_kmh, battery into v_last
    from public.delivery_run_trail where run_id = v_run order by ts desc limit 1;
  v_snapped := coalesce(v_last.snapped, false)
               and v_last.snap_lat is not null and v_last.snap_lng is not null;

  return jsonb_build_object(
    'ok', true,
    'run_id',       v_run,
    'channel',      'run:' || v_run::text,
    'run_status',   r.status,
    'partner_name', coalesce(v_name, ''),
    'title',        public._c('delivery.live_map_title'),
    'has_rider',    (v_loc.lat is not null),
    'lat',          v_loc.lat, 'lng', v_loc.lng,
    'snap_lat',     case when v_snapped then v_last.snap_lat end,
    'snap_lng',     case when v_snapped then v_last.snap_lng end,
    'snapped',      v_snapped,
    'map_lat',      case when v_snapped then v_last.snap_lat else v_loc.lat end,
    'map_lng',      case when v_snapped then v_last.snap_lng else v_loc.lng end,
    'heading',      v_loc.heading,
    'accuracy',     v_loc.accuracy,
    'speed_kmh',    v_last.speed_kmh,
    'battery',      v_last.battery,
    'animate_ms',   v_animate,
    'note',         case when v_snapped then '' else public._c('delivery.live_raw_note') end,
    'updated_at',   v_loc.updated_at,
    'live',         public._delivery_live_block(v_loc.updated_at));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. REPLAY — the run's own line, for the admin timeline and disputes.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_run_trail_get(
  p_run_id uuid, p_limit int default 2000)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_allowed boolean; v_pts jsonb; v_n int;
begin
  select public._can_read_run_channel('run:' || p_run_id::text) into v_allowed;
  if not coalesce(v_allowed, false) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  select count(*) into v_n from public.delivery_run_trail where run_id = p_run_id;

  select coalesce(jsonb_agg(x order by x_ts), '[]'::jsonb) into v_pts
    from (
      select to_jsonb(t) - 'partner_id' as x, t.ts as x_ts
        from (
          select id, ts, lat, lng, snap_lat, snap_lng, snapped, heading,
                 accuracy, moved_m, speed_kmh, battery, source, partner_id,
                 to_char(ts at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM') as ts_label
            from public.delivery_run_trail
           where run_id = p_run_id
           order by ts
           limit greatest(coalesce(p_limit, 2000), 1)
        ) t
    ) s;

  return jsonb_build_object(
    'ok', true,
    'run_id', p_run_id,
    'title',  public._c('delivery.trail_title'),
    'count',  v_n,
    'count_label', case when v_n = 1 then public._c('delivery.trail_one_point')
                        else public._cf('delivery.trail_points',
                                        jsonb_build_object('n', v_n)) end,
    'empty_label', public._c('delivery.trail_empty'),
    'points', v_pts);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. RETENTION — the trail keeps its own clock (a dispute outlives 30 days).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_location_purge_tick()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_days int; v_trail_days int; v_n int := 0; v_t int := 0; v_c int := 0;
begin
  select coalesce(location_retain_days, 30), coalesce(trail_retain_days, 180)
    into v_days, v_trail_days from public.delivery_config where id = 1;

  delete from public.delivery_partner_location_history
   where ts < now() - make_interval(days => v_days);
  get diagnostics v_n = row_count;

  delete from public.delivery_run_trail
   where ts < now() - make_interval(days => v_trail_days);
  get diagnostics v_t = row_count;

  -- a snap cache entry nobody has hit in 30 days is a street nobody rides
  delete from public.osrm_snap_cache where last_used_at < now() - interval '30 days';
  get diagnostics v_c = row_count;

  return jsonb_build_object('ok', true, 'deleted', v_n, 'retain_days', v_days,
                            'trail_deleted', v_t, 'trail_retain_days', v_trail_days,
                            'snap_cache_deleted', v_c);
end $$;

grant execute on function public.delivery_update_location(numeric,numeric,numeric,numeric,numeric,numeric,numeric,int,text) to authenticated, service_role, postgres;
grant execute on function public.delivery_live_config() to authenticated, service_role, postgres;
grant execute on function public.delivery_live_state(uuid, uuid) to authenticated, service_role, postgres;
grant execute on function public.delivery_run_trail_get(uuid, int) to authenticated, service_role, postgres;
grant execute on function public._delivery_live_block(timestamptz) to authenticated, service_role, postgres;
grant execute on function public._can_read_run_channel(text) to authenticated, service_role, postgres;
grant execute on function public.delivery_location_purge_tick() to authenticated, service_role, postgres;
-- The snapper is SERVICE-ROLE ONLY on purpose: delivery_snap_lookup hands back
-- the OSRM endpoint, which is internal infrastructure and has no business
-- reaching a client. The rider-location edge function is the only caller.
revoke all on function public.delivery_snap_lookup(numeric, numeric) from public, anon, authenticated;
revoke all on function public.delivery_snap_report(boolean, text, bigint, bigint, numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function public.delivery_snap_lookup(numeric, numeric) to service_role, postgres;
grant execute on function public.delivery_snap_report(boolean, text, bigint, bigint, numeric, numeric, numeric) to service_role, postgres;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. THE CUSTOMER'S PAYLOAD gains the live block, the channel to listen on,
-- and the snapped position. The previous shape is preserved field for field —
-- rider_lat/rider_lng still mean exactly what they meant — so nothing that
-- reads this RPC today has to change to keep working.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.customer_track_order(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid())
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
    ) into v_allowed;
  if not coalesce(v_allowed,false) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_tl := public.order_timeline(p_order_id);

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null then
    return jsonb_build_object('ok',true,'tracking',false,'status','preparing',
      'status_label','Preparing your order', 'timeline', v_tl,
      'has_channel', false,
      'live', public._delivery_live_block(null));
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(live_animate_ms, 1200) into v_animate from delivery_config where id = 1;

  select snap_lat, snap_lng, snapped, speed_kmh into v_last
    from delivery_run_trail where run_id = d.run_id order by ts desc limit 1;
  v_snapped := coalesce(v_last.snapped,false)
               and v_last.snap_lat is not null and v_last.snap_lng is not null;

  select count(*) into v_ahead from deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  -- CHANGE #462 (gap 104)
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  -- The staleness sentence is only meaningful while a rider is supposed to be
  -- moving. On a delivered or failed stop the map is history, not a live feed,
  -- so no "Rider offline" is ever shown for an order that already arrived.
  v_live := case when d.status in ('assigned','out_for_delivery')
                 then public._delivery_live_block(v_loc.updated_at)
                 else public._delivery_live_block(null) end;

  return jsonb_build_object(
    'ok', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', d.status,
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    -- CHANGE #463 (register row 117's deferred half, unblocked by row 121):
    -- the rider's verified face, for the buyer at whose door they are standing.
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    'stops_ahead', coalesce(v_ahead,0),
    'stops_ahead_label', case when d.status not in ('assigned','out_for_delivery') then null
                              when coalesce(v_ahead,0) = 0 then 'You are next'
                              when v_ahead = 1 then '1 stop before you'
                              else v_ahead::text || ' stops before you' end,
    'rider_lat', case when d.status in ('assigned','out_for_delivery') then v_loc.lat end,
    'rider_lng', case when d.status in ('assigned','out_for_delivery') then v_loc.lng end,
    -- CHANGE #700: the road-snapped twin, and the one pair a map should plot.
    'rider_snap_lat', case when d.status in ('assigned','out_for_delivery') and v_snapped
                           then v_last.snap_lat end,
    'rider_snap_lng', case when d.status in ('assigned','out_for_delivery') and v_snapped
                           then v_last.snap_lng end,
    'rider_snapped', (d.status in ('assigned','out_for_delivery')) and v_snapped,
    'map_lat', case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lat else v_loc.lat end end,
    'map_lng', case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lng else v_loc.lng end end,
    'speed_kmh', case when d.status in ('assigned','out_for_delivery') then v_last.speed_kmh end,
    'animate_ms', coalesce(v_animate, 1200),
    'note', case when d.status in ('assigned','out_for_delivery') and not v_snapped
                 then public._c('delivery.live_raw_note') else '' end,
    'live', v_live,
    -- CHANGE #700: the run-scoped broadcast this customer may listen to. The
    -- old view subscribed to postgres_changes on a table that is not in the
    -- publication, so it never received one event.
    'has_channel', (d.run_id is not null and d.status in ('assigned','out_for_delivery')),
    'channel', case when d.run_id is not null and d.status in ('assigned','out_for_delivery')
                    then 'run:' || d.run_id::text end,
    'location_updated_at', v_loc.updated_at,
    'destination_lat', d.lat, 'destination_lng', d.lng,
    'rider_arrived', (d.arrived_at is not null),
    'qr_token', case when v_show_qr then d.qr_token end,
    'delivered_at', d.delivered_at, 'proof_method', d.proof_method,
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    'timeline', v_tl);
end $$;

grant execute on function public.customer_track_order(uuid) to anon, authenticated, service_role, postgres;

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. CLOSING A LEAK THE JOURNEY CAUGHT (qa-424-237).
--
-- That journey asserts "no shop-id engine function is client-reachable", and it
-- was red: nineteen internal SECURITY DEFINER helpers that take an arbitrary
-- shop uuid were EXECUTE-able by any signed-in client through PostgREST, and
-- several of them WRITE (_khata_post, _c417_reserve, _khata_post_sale). Any
-- pharmacy could have posted a khata entry against another pharmacy's books.
--
-- The cause is a familiar one: 20260901_c423_bill_vault.sql revoked EXECUTE
-- from anon and authenticated, but not from PUBLIC — and PUBLIC EXECUTE is
-- Postgres's DEFAULT for every new function, so `authenticated` inherited the
-- privilege straight back through PUBLIC. Revoking a role by name does not
-- remove the PUBLIC grant sitting underneath it.
--
-- Safe: no Dart caller exists (there is no rpc('_…') anywhere in lib/), and
-- every in-database caller is itself SECURITY DEFINER, so it executes as the
-- owner and never consults these grants.
do $$
declare r record; n int := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname like '\_%'
       and p.prosecdef
       and pg_get_function_identity_arguments(p.oid) ~ '(p_shop|p_pharmacy_id|p_shop_id)'
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    n := n + 1;
  end loop;
  raise notice 'c700: revoked PUBLIC execute on % shop-id helper(s)', n;
end $$;

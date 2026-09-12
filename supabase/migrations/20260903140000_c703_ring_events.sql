-- CHANGE #703 (QA round 2) — finding 459: `arrived` must mean arrived.
--
-- #703 widened delivery_update_location's `arrived` array to carry every
-- geofence ring, so at 500 m it returned [{ring:'approach', ...}] while the
-- stop's arrived_at was still NULL. The key shape survived, but its MEANING
-- changed under a name that promises the opposite -- a consumer counting
-- `arrived` as completed stops would report a rider half a kilometre away as
-- delivered. QA verified no Dart consumer reads the key today (grep across
-- lib/ = 0 hits), so this is a latent trap, and a latent trap is cheapest to
-- close before something starts reading it.
--
-- `arrived` is filtered back to ring='arrived' only; the full event list moves
-- to `ring_events`, which is additive and breaks nothing.
--
-- Idempotent: a single CREATE OR REPLACE. Re-applying is a no-op.

CREATE OR REPLACE FUNCTION public.delivery_update_location(p_lat numeric, p_lng numeric, p_heading numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_snap_lat numeric DEFAULT NULL::numeric, p_snap_lng numeric DEFAULT NULL::numeric, p_snap_dist_m numeric DEFAULT NULL::numeric, p_battery integer DEFAULT NULL::integer, p_source text DEFAULT 'app'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_partner uuid; cfg jsonb; v_min_acc numeric;
  r record; v_arrived jsonb := '[]'::jsonb; v_events jsonb := '[]'::jsonb;
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

  -- CHANGE #703 — the fix is now judged twice: once for the run (speeding and
  -- off-route are visible in this single fix) and once for every live stop
  -- (the 500 m, 50 m and exit rings). Both are idempotent, so a rider whose
  -- app posts the same position ten times fires exactly one alert.
  begin
    perform public._c703_anomaly_on_fix(v_partner, v_run, p_lat, p_lng, v_speed);
  exception when others then
    null;  -- an anomaly rule must never cost the rider their position write.
  end;

  cfg := public._dcfg(null);
  v_min_acc := coalesce((cfg->>'geofence_min_accuracy_m')::numeric, 250);

  if p_accuracy is not null and p_accuracy > v_min_acc then
    return jsonb_build_object('ok',true,'arrived',v_arrived,'ring_events',v_arrived,
                              'skipped_accuracy',true,
                              'run_id',v_run,'snapped',v_snapped);
  end if;

  -- CHANGE #703 (QA round 2) — one evaluator owns every ring, but the two
  -- audiences are no longer conflated. `arrived` means what it has always
  -- meant and what its name promises: the stops this fix ARRIVED at. The
  -- approach ring (500 m, stop not arrived) and the missed handover go in
  -- `ring_events` alongside it. #703 originally returned all three under
  -- `arrived`, so a caller reading it as "stops arrived at" would have counted
  -- a rider still 500 m away as delivered. Nothing in lib/ reads either key
  -- today, which is exactly why this is cheap to fix now and expensive later.
  v_events := public._c703_geofence_eval(v_partner, p_lat, p_lng);
  v_arrived := coalesce((
    select jsonb_agg(e) from jsonb_array_elements(v_events) e
     where e->>'ring' = 'arrived'
  ), '[]'::jsonb);

  return jsonb_build_object('ok',true,'arrived',v_arrived,'ring_events',v_events,
                            'run_id',v_run,'snapped',v_snapped,
                            'channel', case when v_run is not null
                                            then 'run:' || v_run::text end);
end $function$;

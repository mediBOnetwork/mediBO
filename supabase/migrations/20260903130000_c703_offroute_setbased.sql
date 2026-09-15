-- CHANGE #703 (QA round 1, part 2) — the off-route lookback stops re-decoding
-- the road polyline once per trail row. Behaviour is unchanged; only cost is.

-- CHANGE #703 (QA round 1) — the off-route lookback, decoded once.
--
-- The lookback asks "what is the earliest fix in this window that sat further
-- than the limit from the route", and asked it by calling _c703_route_offset_m
-- inside a WHERE clause. That helper decodes the entire road polyline on every
-- call, so a window holding N trail rows decoded the polyline N times -- the
-- scalar-helper-scan this project has already paid for once on MEDICINE.
--
-- Same answer, same bounded slice (one run, the configured lookback), one
-- decode. The sanity ceiling from _c703_route_offset_m is kept here too, so a
-- corrupt polyline still judges nothing rather than accusing every fix.
create or replace function public._c703_offroute_since(
  p_run uuid, p_poly text, p_lim numeric, p_mins int)
returns timestamptz
language plpgsql stable set search_path to 'public' as $function$
declare
  v_lat double precision[]; v_lng double precision[]; v_n int; i int;
  r record;
  v_mx double precision; v_my double precision := 110540.0;
  px double precision; py double precision;
  a_x double precision; a_y double precision; b_x double precision; b_y double precision;
  dx double precision; dy double precision; t double precision;
  d double precision; v_best double precision;
begin
  if coalesce(p_poly,'') = '' or p_run is null then return null; end if;

  select array_agg(lat order by ord), array_agg(lng order by ord)
    into v_lat, v_lng
    from public._c701_poly_decode(p_poly)
   where lat is not null and lng is not null
     and abs(lat) <= 90.0 and abs(lng) <= 180.0;

  v_n := coalesce(array_length(v_lat, 1), 0);
  if v_n = 0 then return null; end if;

  for r in
    select ts, lat, lng
      from public.delivery_run_trail
     where run_id = p_run
       and ts >= now() - make_interval(mins => p_mins * 3)
       and lat is not null and lng is not null
     order by ts
  loop
    -- Each fix is projected at its OWN latitude, exactly as the per-row helper
    -- did, so the answer does not move.
    v_mx := cos(radians(r.lat::double precision)) * 111320.0;
    px := r.lng::double precision * v_mx;
    py := r.lat::double precision * v_my;

    v_best := null;
    if v_n = 1 then
      v_best := sqrt((px - v_lng[1]*v_mx)^2 + (py - v_lat[1]*v_my)^2);
    else
      for i in 1 .. v_n - 1 loop
        a_x := v_lng[i]   * v_mx; a_y := v_lat[i]   * v_my;
        b_x := v_lng[i+1] * v_mx; b_y := v_lat[i+1] * v_my;
        dx := b_x - a_x; dy := b_y - a_y;
        if dx = 0 and dy = 0 then
          d := sqrt((px-a_x)^2 + (py-a_y)^2);
        else
          t := ((px-a_x)*dx + (py-a_y)*dy) / (dx*dx + dy*dy);
          t := greatest(0.0, least(1.0, t));
          d := sqrt((px - (a_x + t*dx))^2 + (py - (a_y + t*dy))^2);
        end if;
        if v_best is null or d < v_best then v_best := d; end if;
      end loop;
    end if;

    -- Past the ceiling the polyline is wrong, not the driving (see
    -- _c703_route_offset_m) -- such a fix accuses nobody.
    if v_best is not null and v_best <= 100000.0
       and v_best > p_lim::double precision then
      return r.ts;   -- ordered by ts, so the first match IS min(ts)
    end if;
  end loop;

  return null;
end $function$;

revoke execute on function public._c703_offroute_since(uuid, text, numeric, int)
  from public, anon, authenticated;

create or replace function public._c703_anomaly_on_fix(
  p_partner uuid, p_run uuid, p_lat numeric, p_lng numeric, p_speed numeric)
returns void
language plpgsql security definer set search_path to 'public' as $function$
declare
  cfg jsonb; v_zone smallint; v_poly text; v_off numeric; v_limit numeric;
  v_off_lim numeric; v_off_min int; v_since timestamptz; v_stop uuid;
begin
  if p_run is null then return; end if;

  select zone_id, road_polyline into v_zone, v_poly
    from public.delivery_runs where id = p_run;
  cfg := public._dcfg(v_zone);
  if not coalesce((cfg->>'anomaly_enabled')::boolean, true) then return; end if;

  select id into v_stop from public.deliveries
   where run_id = p_run and status = 'out_for_delivery'
   order by coalesce(seq, 999999) limit 1;

  -- A fix at all means the rider is neither silent nor parked.
  perform public._c703_anomaly_clear(p_run, 'gps_silent');
  perform public._c703_anomaly_clear(p_run, 'stationary');

  -- Speeding: instantaneous and self-evident, so it opens on the fix itself.
  v_limit := coalesce((cfg->>'anomaly_speed_kmh')::numeric, 80);
  if p_speed is not null and p_speed > v_limit then
    perform public._c703_anomaly_open(p_run, p_partner, v_stop, v_zone, 'overspeed',
      jsonb_build_object('speed_kmh', p_speed, 'limit_kmh', v_limit));
  else
    perform public._c703_anomaly_clear(p_run, 'overspeed');
  end if;

  -- Off route: it must PERSIST past the configured minutes before it is real,
  -- so one bad fix or a legitimate detour around a closed road raises nothing.
  v_off_lim := coalesce((cfg->>'anomaly_offroute_m')::numeric, 400);
  v_off_min := coalesce((cfg->>'anomaly_offroute_min')::int, 3);
  v_off := public._c703_route_offset_m(v_poly, p_lat, p_lng);

  if v_off is not null and v_off > v_off_lim then
    -- CHANGE #703 (QA round 1) — one decode, not one per row.
    -- This was _c703_route_offset_m(v_poly, lat, lng) called inside the WHERE,
    -- which re-decoded the whole polyline once per trail row: the project's own
    -- documented scalar-helper-scan anti-pattern. The helper below decodes the
    -- polyline ONCE and walks the same bounded slice, returning the identical
    -- min(ts).
    v_since := public._c703_offroute_since(p_run, v_poly, v_off_lim, v_off_min);

    if v_since is not null and v_since <= now() - make_interval(mins => v_off_min) then
      perform public._c703_anomaly_open(p_run, p_partner, v_stop, v_zone, 'off_route',
        jsonb_build_object('offset_m', v_off, 'limit_m', v_off_lim,
                           'since', v_since, 'minutes', v_off_min));
    end if;
  else
    perform public._c703_anomaly_clear(p_run, 'off_route');
  end if;
end $function$;

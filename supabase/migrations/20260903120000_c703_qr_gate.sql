-- CHANGE #703 (QA round 1) — the hostile QA pass on CHANGE #1047 found the
-- buyer's handover QR travelling to the RIDER inside the same block that
-- carefully withholds the OTP, and an off-route measurement that failed OPEN on
-- a polyline it could not decode. Both are fixed here, and the proof function
-- that enshrined the first one is corrected so it can never be re-introduced.
--
-- Nothing in this file is new logic; it re-states three functions from
-- 20260903110000_c703_geofence_arrival.sql with those two defects removed.

create or replace function public._c703_arrival_block(
  p_delivery_id uuid, p_show_otp boolean default false)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  d public.deliveries%rowtype; v_name text; v_wait int; v_state text; v_otp text;
  v_qr text;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('has', false, 'state','none'); end if;

  if d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('has', false, 'state', 'done');
  end if;

  v_state := case
    when d.arrived_at is not null            then 'here'
    when d.approach_notified_at is not null  then 'approaching'
    else 'enroute' end;

  if v_state = 'enroute' then
    return jsonb_build_object('has', false, 'state', 'enroute');
  end if;

  select coalesce(nullif(full_name,''),'') into v_name
    from public.delivery_partner_registrations where id = d.partner_id;

  -- CHANGE #703 (QA round 1) — the QR is a CREDENTIAL, not a label.
  --
  -- #354 gated the OTP so a rider could never read the code they are supposed
  -- to be told at the door. The QR token is the SAME secret in the other
  -- alphabet: delivery_scan_qr(token, lat, lng) completes the handover, so a
  -- rider holding it can close their own delivery without the buyer ever
  -- opening the app. Shipping it beside a carefully gated OTP defeated the
  -- control. The rider does not need it in a payload -- they point a camera at
  -- the buyer's screen -- so both credentials now travel on the SAME flag.
  if coalesce(p_show_otp,false) then
    select nullif(o.code,'') into v_otp from public.delivery_otp o
     where o.delivery_id = d.id and o.verified_at is null;
    v_qr := nullif(d.qr_token,'');
  end if;

  v_wait := case when d.dwell_started_at is null then null
                 else floor(extract(epoch from (now() - d.dwell_started_at)) / 60.0)::int end;

  return jsonb_build_object(
    'has', true,
    'state', v_state,
    'chip', case when v_state = 'here' then public._c('delivery.here_chip')
                 else public._c('delivery.approach_chip') end,
    'heading', case when v_state = 'here' then public._c('delivery.here_heading')
                    else public._c('delivery.approach_heading') end,
    'body', case when v_state = 'here'
        then public._cf('delivery.here_body', jsonb_build_object('rider', v_name))
        else public._cf('delivery.approach_body',
               jsonb_build_object('rider', v_name,
                 'mins', coalesce((public._dcfg(d.zone_id)->>'approach_eta_min')::int, 3))) end,
    'partner_name', v_name,
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    'waiting_label', case
        when v_state <> 'here' or v_wait is null then ''
        when v_wait <= 0 then public._c('delivery.here_waiting_now')
        when v_wait = 1  then public._c('delivery.here_waiting_one')
        else public._cf('delivery.here_waiting_many', jsonb_build_object('n', v_wait)) end,
    'waiting_min', coalesce(v_wait, 0),
    -- The handover credentials open at the APPROACH ring, which is the whole
    -- point of the ring: the buyer gets three minutes to find their phone.
    'handover', jsonb_build_object(
      'has',       true,
      'qr_label',  public._c('delivery.handover_qr_label'),
      'has_qr',    (v_qr is not null),
      'qr_token',  v_qr,
      'has_otp',   (v_otp is not null),
      'otp_label', public._c('delivery.handover_otp_label'),
      'otp_hint',  public._c('delivery.handover_otp_hint'),
      'otp',       v_otp),
    'tone', case when v_state = 'here' then 'success' else 'info' end,
    'arrived_at', d.arrived_at,
    'dwell_started_at', d.dwell_started_at);
end $function$;

create or replace function public._c703_route_offset_m(
  p_polyline text, p_lat numeric, p_lng numeric)
returns numeric
language plpgsql immutable as $function$
declare
  v_best double precision := null;
  v_lat0 double precision := p_lat::double precision;
  v_mx double precision := cos(radians(p_lat::double precision)) * 111320.0;
  v_my double precision := 110540.0;
  px double precision; py double precision;
  a_x double precision; a_y double precision; b_x double precision; b_y double precision;
  dx double precision; dy double precision; t double precision; d double precision;
  prev record; cur record; v_n int := 0;
begin
  if coalesce(p_polyline,'') = '' then return null; end if;
  px := p_lng::double precision * v_mx; py := v_lat0 * v_my;

  -- CHANGE #703 (QA round 1) — fail CLOSED on a polyline we cannot read.
  --
  -- _c701_poly_decode never throws. Fed '   ' or 'AAAA' it does not return
  -- nonsense degrees, which is what makes this dangerous: it returns a tidy
  -- little route at (1e-05, 1e-05) -- null island -- which is perfectly
  -- in-range and sits ~8,540 km from a rider in Bengaluru. Every fix then
  -- measured permanently past the 400 m limit, so a corrupt road_polyline
  -- bought a false off_route anomaly no amount of correct driving could clear.
  --
  -- So the guard is not "is this a legal coordinate" (null island passes) but
  -- "can this polyline plausibly be THIS run's route". A rider is never 100 km
  -- from their own route: past that ceiling the polyline is the thing that is
  -- wrong, not the driving, and the honest answer is null -- which
  -- _c703_geofence_eval's `v_off is not null` guard turns into no anomaly at
  -- all rather than a permanent one.
  prev := null;
  for cur in select * from public._c701_poly_decode(p_polyline) order by ord loop
    if cur.lat is null or cur.lng is null
       or abs(cur.lat) > 90.0 or abs(cur.lng) > 180.0 then
      continue;
    end if;
    v_n := v_n + 1;
    if prev is not null then
      a_x := prev.lng * v_mx; a_y := prev.lat * v_my;
      b_x := cur.lng  * v_mx; b_y := cur.lat  * v_my;
      dx := b_x - a_x; dy := b_y - a_y;
      if dx = 0 and dy = 0 then
        d := sqrt((px-a_x)^2 + (py-a_y)^2);
      else
        t := ((px-a_x)*dx + (py-a_y)*dy) / (dx*dx + dy*dy);
        t := greatest(0.0, least(1.0, t));
        d := sqrt((px - (a_x + t*dx))^2 + (py - (a_y + t*dy))^2);
      end if;
      if v_best is null or d < v_best then v_best := d; end if;
    end if;
    prev := cur;
  end loop;

  -- A one-point polyline has no segment; fall back to that single vertex.
  if v_best is null and v_n = 1 then
    for cur in select * from public._c701_poly_decode(p_polyline)
                where abs(lat) <= 90.0 and abs(lng) <= 180.0 order by ord limit 1 loop
      v_best := sqrt((px - cur.lng*v_mx)^2 + (py - cur.lat*v_my)^2);
    end loop;
  end if;

  -- Past the sanity ceiling this is a corrupt or mismatched polyline, not a
  -- detour. Say "cannot judge" (null), never "maximally off route".
  if v_best is not null and v_best > 100000.0 then return null; end if;

  return case when v_best is null then null else round(v_best::numeric, 1) end;
end $function$;

create or replace function public.c703_geofence_proof()
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_partner uuid; v_order uuid; v_run uuid; v_del uuid; v_cust uuid;
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  -- Raipur, and a destination ~5 km away. The polyline is the straight leg
  -- between them, so "off route" has something real to be off.
  v_dlat numeric := 21.2514; v_dlng numeric := 81.6296;
  d public.deliveries%rowtype; v_n int; v_open int; v_ev int;


begin
  select id into v_partner from public.delivery_partner_registrations
   where coalesce(is_synthetic,false) order by created_at limit 1;
  if v_partner is null then
    return jsonb_build_object('ok', false, 'error', 'no_synthetic_rider',
      'note', 'seed a synthetic delivery partner before running this proof');
  end if;

  -- enforce_order_approval admits a synthetic order only against an approved
  -- synthetic pharmacy, which is the guard doing exactly its job.
  select id into v_cust from public.pharmacy_profiles
   where is_synthetic and approved and coalesce(is_deleted,false) = false limit 1;
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'no_synthetic_customer',
      'note', 'seed an approved synthetic pharmacy before running this proof');
  end if;

  -- ── fixtures ─────────────────────────────────────────────────────────────
  -- placed_by_admin: the order-hours gate is a CUSTOMER gate, and this row is
  -- placed by a proof, not by a pharmacy at 11 pm. Nothing else is bypassed.
  insert into public.orders (id, customer_id, fulfillment_status, dispatch_ready, source,
                             unfulfilled_count, is_synthetic, placed_by_admin, order_code)
  values (gen_random_uuid(), v_cust, 'shipped', false, 'website', 0, true, true, 'C703-PROOF')
  returning id into v_order;

  insert into public.delivery_runs (id, partner_id, run_date, status, started_at,
                                    zone_id, is_synthetic, road_polyline)
  values (gen_random_uuid(), v_partner, current_date, 'started', now() - interval '30 minutes',
          null, true, public._c703_test_polyline(v_dlat, v_dlng))
  returning id into v_run;

  insert into public.deliveries (id, order_id, run_id, partner_id, status, accept_status,
                                 attempt_no, seq, lat, lng, zone_id, is_synthetic,
                                 qr_token, started_at)
  values (gen_random_uuid(), v_order, v_run, v_partner, 'out_for_delivery', 'accepted',
          1, 1, v_dlat, v_dlng, null, true, 'c703proof', now() - interval '30 minutes')
  returning id into v_del;

  -- CHANGE #354: the code lives here, never on the deliveries row the rider reads.
  insert into public.delivery_otp (delivery_id, code, sent_at, attempts)
  values (v_del, '4321', now(), 0)
  on conflict (delivery_id) do update set code = excluded.code, verified_at = null;

  -- ── 1. far away: nothing fires ───────────────────────────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.030, v_dlng);  -- ~3.3 km
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('3 km out: no approach alert',
                d.approach_notified_at is null);

  -- ── 2. cross the 500 m ring: the buyer is told, once ─────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0030, v_dlng);  -- ~333 m
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('inside 500 m: approach stamped',
                d.approach_notified_at is not null);
  v_checks := v_checks || public._c703_assert('inside 500 m: not arrived yet',
                d.arrived_at is null);

  select count(*) into v_ev from public.delivery_events
   where delivery_id = v_del and event = 'approaching';
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0029, v_dlng);
  select count(*) into v_n from public.delivery_events
   where delivery_id = v_del and event = 'approaching';
  v_checks := v_checks || public._c703_assert('approach fires exactly once', v_n = v_ev and v_n = 1);

  -- the handover opens at the approach ring
  v_checks := v_checks || public._c703_assert('handover QR offered at approach',
                (public._c703_arrival_block(v_del, true) -> 'handover' ->> 'qr_token') = 'c703proof');
  v_checks := v_checks || public._c703_assert('arrival block state = approaching',
                (public._c703_arrival_block(v_del, true) ->> 'state') = 'approaching');

  -- ── 3. cross the 50 m ring: arrival auto-stamped, dwell started ──────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0003, v_dlng);  -- ~33 m
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('inside 50 m: arrived_at stamped',
                d.arrived_at is not null);
  v_checks := v_checks || public._c703_assert('inside 50 m: dwell timer started',
                d.dwell_started_at is not null);
  v_checks := v_checks || public._c703_assert('arrival block state = here',
                (public._c703_arrival_block(v_del, true) ->> 'state') = 'here');
  v_checks := v_checks || public._c703_assert('the buyer is given the OTP',
                (public._c703_arrival_block(v_del, true) -> 'handover' ->> 'otp') = '4321');
  -- CHANGE #354's line, held down here: the same block, asked for by the rider.
  v_checks := v_checks || public._c703_assert('the rider is NOT given the OTP',
                (public._c703_arrival_block(v_del, false) -> 'handover' ->> 'otp') is null
                and not ((public._c703_arrival_block(v_del, false) -> 'handover' ->> 'has_otp')::boolean));
  v_checks := v_checks || public._c703_assert('the rider is NOT given the buyer''s QR token',
                (public._c703_arrival_block(v_del, false) -> 'handover' ->> 'qr_token') is null
                and not ((public._c703_arrival_block(v_del, false) -> 'handover' ->> 'has_qr')::boolean));
  v_checks := v_checks || public._c703_assert('the buyer IS given the QR to show',
                (public._c703_arrival_block(v_del, true) -> 'handover' ->> 'qr_token') = 'c703proof'
                and ((public._c703_arrival_block(v_del, true) -> 'handover' ->> 'has_qr')::boolean));
  v_checks := v_checks || public._c703_assert('an unreadable polyline judges nothing',
                public._c703_route_offset_m('AAAA', v_dlat, v_dlng) is null
                and public._c703_route_offset_m('   ', v_dlat, v_dlng) is null);
  v_checks := v_checks || public._c703_assert('doorbell heading is backend copy',
                coalesce(public._c703_arrival_block(v_del, true) ->> 'heading','') <> '');

  -- ── 4. leave without completing: missed handover ─────────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0150, v_dlng);  -- ~1.6 km
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('left the door: missed handover flagged',
                d.missed_handover_at is not null);
  select count(*) into v_n from public._exception_rows()
   where reason_code = 'missed_handover' and ref_id = v_del::text;
  v_checks := v_checks || public._c703_assert('missed handover reaches the exceptions console', v_n = 1);

  -- ── 5. come back: the flag clears itself ─────────────────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0002, v_dlng);
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('returned to the door: flag cleared',
                d.missed_handover_at is null);

  -- ── 6. anomalies: raised once, then cleared ──────────────────────────────
  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat, v_dlng, 95);
  select count(*) into v_open from public.delivery_anomaly
   where run_id = v_run and kind = 'overspeed' and cleared_at is null;
  v_checks := v_checks || public._c703_assert('95 km/h raises overspeed', v_open = 1);

  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat, v_dlng, 97);
  select count(*) into v_open from public.delivery_anomaly
   where run_id = v_run and kind = 'overspeed' and cleared_at is null;
  v_checks := v_checks || public._c703_assert('a second speeding fix does not raise a second row', v_open = 1);

  select count(*) into v_n from public._exception_rows() where reason_code = 'rider_anomaly';
  v_checks := v_checks || public._c703_assert('the anomaly reaches the exceptions console', v_n >= 1);

  v_checks := v_checks || public._c703_assert('the rider is nudged in their own words',
                (public._c703_rider_nudge_block(v_run) ->> 'has')::boolean
                and coalesce(public._c703_rider_nudge_block(v_run) -> 'items' -> 0 ->> 'body','') <> '');

  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat, v_dlng, 40);
  select count(*) into v_open from public.delivery_anomaly
   where run_id = v_run and kind = 'overspeed' and cleared_at is null;
  v_checks := v_checks || public._c703_assert('slowing down clears the anomaly', v_open = 0);

  -- off route: 3 km from a polyline that runs straight to the door
  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat + 0.0300, v_dlng + 0.0300, 30);
  v_checks := v_checks || public._c703_assert('off-route distance is measured against the polyline',
                public._c703_route_offset_m(
                  (select road_polyline from public.delivery_runs where id = v_run),
                  v_dlat + 0.0300, v_dlng + 0.0300) > 400);
  v_checks := v_checks || public._c703_assert('a point ON the route is not off route',
                public._c703_route_offset_m(
                  (select road_polyline from public.delivery_runs where id = v_run),
                  v_dlat, v_dlng) < 50);

  -- ── 7. cold chain: elapsed vs window, then the breach ────────────────────
  update public.deliveries
     set is_cold_chain = true, started_at = now() - interval '30 minutes',
         missed_handover_at = null
   where id = v_del;
  v_checks := v_checks || public._c703_assert('cold-chain card shows elapsed, not breached',
                (public._c703_cold_block(v_del) ->> 'has')::boolean
                and not (public._c703_cold_block(v_del) ->> 'breach')::boolean);

  update public.deliveries set started_at = now() - interval '400 minutes' where id = v_del;
  perform public.delivery_cold_chain_tick();
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('past the window: delivery flagged',
                d.cold_breach_at is not null);
  v_checks := v_checks || public._c703_assert('cold-chain card says breach in the backend''s words',
                (public._c703_cold_block(v_del) ->> 'breach')::boolean
                and coalesce(public._c703_cold_block(v_del) ->> 'breach_label','') <> '');
  select count(*) into v_n from public._exception_rows()
   where reason_code = 'cold_chain_breach' and ref_id = v_del::text;
  v_checks := v_checks || public._c703_assert('cold breach reaches the exceptions console', v_n = 1);

  -- ── 8. completion clears the doorbell ────────────────────────────────────
  update public.deliveries set status = 'delivered', delivered_at = now() where id = v_del;
  v_checks := v_checks || public._c703_assert('delivered: the doorbell is gone',
                not (public._c703_arrival_block(v_del, true) ->> 'has')::boolean);

  -- ── cleanup ──────────────────────────────────────────────────────────────
  delete from public.delivery_otp where delivery_id = v_del;
  delete from public.delivery_anomaly where run_id = v_run;
  delete from public.delivery_events where delivery_id = v_del;
  delete from public.deliveries where id = v_del;
  delete from public.delivery_runs where id = v_run;
  delete from public.orders where id = v_order;

  select count(*) filter (where (x->>'ok')::boolean),
         count(*) filter (where not (x->>'ok')::boolean)
    into v_pass, v_fail
    from jsonb_array_elements(v_checks) x;

  return jsonb_build_object('ok', v_fail = 0, 'passed', v_pass, 'failed', v_fail,
                            'checks', v_checks);
end $function$;

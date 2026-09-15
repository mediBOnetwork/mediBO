-- CHANGE #703 (QA round 2) — the proof learns finding 459.
--
-- The fix is a filter on `ring`, so an assertion that the eval actually tags
-- each ring is the thing that keeps the fix honest: rename the tag and the
-- filter silently returns nothing, which would look exactly like a quiet run.
-- Three assertions, on the fixture that already crosses both rings.
--
-- Idempotent: CREATE OR REPLACE. Re-applying is a no-op.

CREATE OR REPLACE FUNCTION public.c703_geofence_proof()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_partner uuid; v_order uuid; v_run uuid; v_del uuid; v_cust uuid;
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  -- Raipur, and a destination ~5 km away. The polyline is the straight leg
  -- between them, so "off route" has something real to be off.
  v_dlat numeric := 21.2514; v_dlng numeric := 81.6296;
  d public.deliveries%rowtype; v_n int; v_open int; v_ev int;
  -- CHANGE #703 (QA round 2) — the ring events the eval hands back, kept so the
  -- split delivery_update_location performs on them can be asserted, not assumed.
  v_rings jsonb;


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
  v_rings := public._c703_geofence_eval(v_partner, v_dlat + 0.0030, v_dlng);  -- ~333 m
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('inside 500 m: approach stamped',
                d.approach_notified_at is not null);
  v_checks := v_checks || public._c703_assert('inside 500 m: not arrived yet',
                d.arrived_at is null);

  -- QA round 2, finding 459: the approach ring is an approach, and it must not
  -- be able to pass for an arrival. delivery_update_location filters on exactly
  -- this tag, so the tag is the contract worth holding down.
  v_checks := v_checks || public._c703_assert('approach ring is tagged approach',
                exists (select 1 from jsonb_array_elements(v_rings) e
                         where e->>'ring' = 'approach'
                           and (e->>'delivery_id')::uuid = v_del));
  v_checks := v_checks || public._c703_assert('approach ring is NOT an arrival',
                not exists (select 1 from jsonb_array_elements(v_rings) e
                             where e->>'ring' = 'arrived'));

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
  v_rings := public._c703_geofence_eval(v_partner, v_dlat + 0.0003, v_dlng);  -- ~33 m
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('inside 50 m: arrived_at stamped',
                d.arrived_at is not null);
  v_checks := v_checks || public._c703_assert('inside 50 m: dwell timer started',
                d.dwell_started_at is not null);

  -- ...and the arrival ring IS one, so the same filter that drops the approach
  -- keeps this. Together these two are the whole of `arrived` meaning arrived.
  v_checks := v_checks || public._c703_assert('arrival ring is tagged arrived',
                exists (select 1 from jsonb_array_elements(v_rings) e
                         where e->>'ring' = 'arrived'
                           and (e->>'delivery_id')::uuid = v_del));
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

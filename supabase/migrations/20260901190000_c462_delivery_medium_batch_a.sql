-- CHANGE #462 — MEDIUM severity delivery defects, batch A (feature_gaps 104–110).
--
-- Seven approved audit rows, each reproduced against the live schema before it
-- was touched. Every fix lands in the backend; the app keeps rendering payloads
-- verbatim. Idempotent throughout — a resumed worker re-applies this as a no-op.
--
--   104  a customer could close their own stop from the tracking link
--   105  completion had no state machine (a failed/rto/cancelled stop delivered)
--   106  delivered_lat/lng were written and never read
--   107  delivery_apply_google erased stop grouping and miscounted the run
--   108  rejecting a stop left total_stops stale and cost the rider nothing
--   109  the signup form's pincode and zone were thrown away
--   110  delivery_partner_register was anon-executable with no duplicate guard

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Config knobs. Every threshold below is data, so Om can retune the rules
--    with an UPDATE instead of a deploy.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.delivery_config
  add column if not exists customer_scan_requires_arrival boolean not null default true,
  add column if not exists completion_geofence_action text not null default 'flag',
  add column if not exists reject_cooldown_min integer not null default 240,
  add column if not exists reject_cap_per_day integer not null default 5;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_config_geofence_action_chk') then
    alter table public.delivery_config
      add constraint delivery_config_geofence_action_chk
      check (completion_geofence_action in ('off','flag','block'));
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Columns the fixes need.
-- ─────────────────────────────────────────────────────────────────────────────
-- 106: the completion distance stops being write-only.
alter table public.deliveries
  add column if not exists delivered_distance_m integer,
  add column if not exists geofence_ok boolean,
  add column if not exists completion_flagged boolean not null default false;

-- 109: the pincode the form has always posted now has somewhere to land.
alter table public.delivery_partner_registrations
  add column if not exists pincode text;

create index if not exists deliveries_completion_flagged_idx
  on public.deliveries (completion_flagged) where completion_flagged;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Backend copy. Not one of these strings is allowed to exist in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('delivery.bad_state_title',        '"Cannot be delivered"'::jsonb),
  ('delivery.bad_state_msg',          '"This stop is no longer out for delivery. Reopen it before marking it delivered."'::jsonb),
  ('delivery.rider_not_arrived_title','"Rider has not arrived yet"'::jsonb),
  ('delivery.rider_not_arrived_msg',  '"You can confirm this delivery once the rider reaches your address."'::jsonb),
  ('delivery.too_far_title',          '"Too far from the address"'::jsonb),
  ('delivery.too_far_msg',            '"You are outside the delivery radius for this stop. Move to the address and try again."'::jsonb),
  ('delivery.reject_capped_title',    '"Rejection limit reached"'::jsonb),
  ('delivery.reject_capped_msg',      '"You have rejected too many stops today. Contact your agency to continue."'::jsonb),
  ('delivery.reg_no_session',         '"Sign in before applying so we can attach the application to your account."'::jsonb),
  ('delivery.reg_phone_taken',        '"An application already exists for this phone number."'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. _dcfg carries the new knobs, so every caller reads one config surface.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._dcfg(p_zone smallint default null::smallint)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'promise_window_min',        coalesce(z.promise_window_min,        d.promise_window_min),
    'on_time_grace_min',         coalesce(z.on_time_grace_min,         d.on_time_grace_min),
    'charge_amount',             coalesce(z.charge_amount,             d.charge_amount),
    'free_above_amount',         coalesce(z.free_above_amount,         d.free_above_amount),
    'charge_gst_pct',            coalesce(z.charge_gst_pct,            d.charge_gst_pct),
    'cost_per_drop',             coalesce(z.cost_per_drop,             d.default_cost_per_drop),
    'geofence_radius_m',         coalesce(z.geofence_radius_m,         d.geofence_radius_m),
    'geofence_min_accuracy_m',   d.geofence_min_accuracy_m,
    'doc_expiry_remind_days',    d.doc_expiry_remind_days,
    'doc_expiry_blocks',         d.doc_expiry_blocks,
    'cold_chain_priority_boost', d.cold_chain_priority_boost,
    'cold_chain_photo_required', d.cold_chain_photo_required,
    'handover_required',         d.handover_required,
    'handover_enforced_from',    d.handover_enforced_from,
    'payout_period_days',        d.payout_period_days,
    'rating_poor_at_or_below',   d.rating_poor_at_or_below,
    'unknown_pincode_mode',      d.unknown_pincode_mode,
    'otp_max_attempts',          d.otp_max_attempts,
    'otp_lock_minutes',          d.otp_lock_minutes,
    'otp_ttl_minutes',           d.otp_ttl_minutes,
    -- CHANGE #462
    'customer_scan_requires_arrival', d.customer_scan_requires_arrival,
    'completion_geofence_action',     d.completion_geofence_action,
    'reject_cooldown_min',            d.reject_cooldown_min,
    'reject_cap_per_day',             d.reject_cap_per_day,
    'zone_serviceable',          coalesce(z.is_serviceable, true),
    'zone_id',                   p_zone)
  from public.delivery_config d
  left join public.zone_delivery_config z on z.zone_id = p_zone
  where d.id = 1;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. GAP 107 — total_stops gets ONE definition, in one place.
--    It used to be three: assign counted distinct coalesce(stop_group,0) over
--    every row (so a run with no grouping yet counted 1), the optimiser counted
--    distinct stop_group, and delivery_apply_google counted raw open stops. A
--    run's size is its number of distinct drop points, and an ungrouped stop is
--    its own drop point.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_run_recount(p_run_id uuid)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_n integer;
begin
  if p_run_id is null then return 0; end if;
  select count(*) into v_n from (
    select distinct coalesce(stop_group::text, 'u:' || id::text) g
      from public.deliveries where run_id = p_run_id
  ) t;
  update public.delivery_runs set total_stops = coalesce(v_n,0) where id = p_run_id;
  return coalesce(v_n,0);
end $function$;

-- The 150 m co-location rule, extracted so the optimiser and the Google apply
-- path cannot drift apart again.
create or replace function public._delivery_regroup_run(p_run_id uuid)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare r record; v_grp int := 0;
begin
  update public.deliveries set stop_group = null
   where run_id = p_run_id and status not in ('delivered','cancelled');

  for r in
    select id, lat, lng from public.deliveries
     where run_id = p_run_id and status not in ('delivered','cancelled')
     order by seq nulls last, lat nulls last, lng
  loop
    if (select stop_group from public.deliveries where id = r.id) is not null then continue; end if;
    v_grp := v_grp + 1;
    update public.deliveries set stop_group = v_grp
     where run_id = p_run_id and stop_group is null
       and status not in ('delivered','cancelled')
       and (id = r.id
            or (r.lat is not null and lat is not null
                and public._geo_m(r.lat, r.lng, lat, lng) <= 150));
  end loop;
  return v_grp;
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. GAP 105 + GAP 106 — the door: a state machine, and a distance that is read.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_complete(
  p_delivery_id uuid, p_method text, p_lat numeric, p_lng numeric,
  p_receiver text default null::text, p_photo text default null::text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  d public.deliveries%rowtype;
  v_actor text := coalesce(auth.jwt()->>'email','system');
  v_cfg jsonb; v_radius numeric; v_action text;
  v_dist numeric; v_dist_m integer; v_ok boolean; v_flag boolean := false;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if d.status = 'delivered' then
    return jsonb_build_object('ok',true,'already',true,'message','Already delivered',
      'delivered_at', d.delivered_at);
  end if;

  -- CHANGE #462 (gap 105): completion is a TRANSITION, not an assignment. Only
  -- a stop that is actually out with a rider can be closed. 'failed', 'rto',
  -- 'cancelled' and 'unassigned' are terminal or unowned here — a failed stop
  -- comes back through delivery_redeliver, which is what that function is for.
  if d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('ok',false,'error','bad_state','status', d.status,
      'title',   public._c('delivery.bad_state_title'),
      'message', public._c('delivery.bad_state_msg'));
  end if;

  -- CHANGE #309 (1): custody must be on record before a delivery can be closed.
  if d.handover_at is null and not public._handover_exempt(d) then
    return jsonb_build_object('ok',false,'error','handover_required',
      'title',   public._c('delivery.handover_required_title'),
      'message', public._c('delivery.handover_required_msg'));
  end if;

  -- CHANGE #309 (10): a temperature-sensitive parcel needs a photo at the door.
  if d.is_cold_chain
     and coalesce((public._dcfg(d.zone_id)->>'cold_chain_photo_required')::boolean, true)
     and nullif(btrim(coalesce(p_photo,'')),'') is null
     and nullif(btrim(coalesce(d.proof_photo_path,'')),'') is null then
    return jsonb_build_object('ok',false,'error','cold_chain_photo_required',
      'title',   public._c('delivery.cold_chain_badge'),
      'message', public._c('delivery.cold_chain_photo_required'));
  end if;

  -- CHANGE #462 (gap 106): the coordinates the app has always sent are finally
  -- compared with the stop. Default action is FLAG, not block — a rider with a
  -- bad GPS fix must never be stranded at a customer's door — but the run now
  -- carries the evidence, and an admin can switch the knob to 'block'.
  v_cfg    := public._dcfg(d.zone_id);
  v_radius := nullif((v_cfg->>'geofence_radius_m')::numeric, 0);
  v_action := coalesce(v_cfg->>'completion_geofence_action', 'flag');

  if p_lat is not null and p_lng is not null and d.lat is not null and d.lng is not null then
    v_dist   := public._geo_m(d.lat, d.lng, p_lat, p_lng);
    v_dist_m := round(v_dist)::int;
    v_ok     := (v_radius is null) or (v_dist <= v_radius);
    if not v_ok and v_action = 'block' then
      return jsonb_build_object('ok',false,'error','outside_geofence',
        'distance_m', v_dist_m, 'radius_m', v_radius,
        'title',   public._c('delivery.too_far_title'),
        'message', public._c('delivery.too_far_msg'));
    end if;
    v_flag := (not coalesce(v_ok,true)) and v_action <> 'off';
  end if;

  update public.deliveries
     set status='delivered', delivered_at=now(), proof_method=p_method,
         delivered_lat=p_lat, delivered_lng=p_lng,
         delivered_distance_m=v_dist_m,
         geofence_ok=v_ok,
         completion_flagged=v_flag,
         receiver_name=coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name),
         proof_photo_path=coalesce(p_photo, proof_photo_path)
   where id = p_delivery_id;

  update public.orders set shipped_at = coalesce(shipped_at, now()) where id = d.order_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'delivered', p_method, p_lat, p_lng, v_actor);

  if v_flag then
    insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'geofence_flag',
            v_dist_m::text || 'm from the stop (radius ' || coalesce(v_radius::text,'-') || 'm)',
            p_lat, p_lng, v_actor);
  end if;

  -- CHANGE #295: window-gated. Free-form only while the window is open.
  begin
    perform public.wa_notify_event(
      'delivery_delivered', null, '{}'::jsonb, null, d.order_id,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
      jsonb_build_object('event','delivered','delivery_id',p_delivery_id));
  exception when others then
    perform public._wa_log_attempt('delivery_delivered', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok',true,'status','delivered','method',p_method,
    'message','Delivered', 'delivered_at', now(),
    'distance_m', v_dist_m, 'geofence_ok', v_ok, 'flagged', v_flag);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. GAP 104 — a customer cannot close a stop the rider has not reached.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_scan_qr(
  p_token text, p_lat numeric default null::numeric, p_lng numeric default null::numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  d public.deliveries%rowtype; v_me uuid := auth.uid();
  v_is_rider boolean; v_is_cust boolean;
begin
  select * into d from public.deliveries where qr_token = btrim(coalesce(p_token,''));
  if d.id is null then
    return jsonb_build_object('ok',false,'error','bad_qr','title','Unknown code',
      'message','This QR does not match any delivery.');
  end if;
  if d.accept_status <> 'accepted' then
    return jsonb_build_object('ok',false,'error','not_accepted',
      'title','Not accepted yet','message','The delivery partner has not accepted this yet.');
  end if;

  select exists(select 1 from public.delivery_partner_registrations
                 where id = d.partner_id and user_id = v_me) into v_is_rider;
  select exists(select 1 from public.orders o
                  join public.pharmacy_profiles pp on pp.id = o.customer_id
                 where o.id = d.order_id and pp.user_id = v_me) into v_is_cust;

  if not (v_is_rider or v_is_cust or public.get_my_role() in ('admin','super_admin','worker')) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'title','Not allowed','message','Only the assigned rider or the customer can scan this.');
  end if;

  -- CHANGE #309 (1): the same token, read in the state the parcel is actually
  -- in. Custody first; the door second. A customer can never take custody.
  if d.handover_at is null and not public._handover_exempt(d) and not v_is_cust then
    return public.delivery_handover_scan(p_token, p_lat, p_lng, 'qr')
           || jsonb_build_object('phase','handover');
  end if;

  -- CHANGE #462 (gap 104): the customer's half of the QR closes the stop, so it
  -- must wait for the rider to actually be there. arrived_at is stamped by
  -- delivery_update_location when the rider enters the stop's geofence; until
  -- that lands, a customer holding the tracking link cannot mark themselves
  -- delivered. Riders and admins are unaffected.
  if v_is_cust and not v_is_rider
     and coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true)
     and d.arrived_at is null
     and public.get_my_role() not in ('admin','super_admin','worker') then
    return jsonb_build_object('ok',false,'error','rider_not_arrived',
      'title',   public._c('delivery.rider_not_arrived_title'),
      'message', public._c('delivery.rider_not_arrived_msg'),
      'phase','waiting');
  end if;

  return public._delivery_complete(d.id,
           case when v_is_cust then 'qr_customer' else 'qr_agent' end, p_lat, p_lng, null, null)
         || jsonb_build_object('phase','delivered');
end $function$;

-- The same rule on both tracking payloads: the confirm code appears when the
-- rider is at the door, not for the whole trip.
create or replace function public.customer_track_order(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
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
      'status_label','Preparing your order', 'timeline', v_tl);
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;

  select count(*) into v_ahead from deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  -- CHANGE #462 (gap 104)
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

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
    'stops_ahead', coalesce(v_ahead,0),
    'stops_ahead_label', case when d.status not in ('assigned','out_for_delivery') then null
                              when coalesce(v_ahead,0) = 0 then 'You are next'
                              when v_ahead = 1 then '1 stop before you'
                              else v_ahead::text || ' stops before you' end,
    'rider_lat', case when d.status in ('assigned','out_for_delivery') then v_loc.lat end,
    'rider_lng', case when d.status in ('assigned','out_for_delivery') then v_loc.lng end,
    'location_updated_at', v_loc.updated_at,
    'destination_lat', d.lat, 'destination_lng', d.lng,
    'rider_arrived', (d.arrived_at is not null),
    'qr_token', case when v_show_qr then d.qr_token end,
    'delivered_at', d.delivered_at, 'proof_method', d.proof_method,
    'timeline', v_tl);
end $function$;

create or replace function public.delivery_track_public(p_token text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  d deliveries%rowtype; v_loc delivery_partner_locations%rowtype;
  v_ahead int; v_name text; v_code text; v_show_qr boolean;
begin
  select * into d from deliveries where qr_token = btrim(coalesce(p_token,''));
  if d.id is null then
    return jsonb_build_object(
      'ok', false, 'found', false, 'tracking', false,
      'title', 'Tracking link not found',
      'message', 'This tracking link is not valid any more.',
      'status', '', 'status_label', '', 'partner_name', '',
      'stops_ahead', 0, 'stops_ahead_label', '', 'has_stops_ahead', false,
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(order_code,'') into v_code from orders where id = d.order_id;

  select count(*) into v_ahead from deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  -- CHANGE #462 (gap 104): same rule as customer_track_order.
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  return jsonb_build_object(
    'ok', true, 'found', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', coalesce(d.status,''),
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'title', 'Track your order',
    'message', '',
    'partner_name', coalesce(v_name,''),
    'order_code', v_code,
    'stops_ahead', coalesce(v_ahead,0),
    'has_stops_ahead', (d.status in ('assigned','out_for_delivery')),
    'stops_ahead_label', case when d.status not in ('assigned','out_for_delivery') then ''
                              when coalesce(v_ahead,0) = 0 then 'You are next'
                              when v_ahead = 1 then '1 stop before you'
                              else v_ahead::text || ' stops before you' end,
    'rider_lat', coalesce(case when d.status in ('assigned','out_for_delivery')
                               then v_loc.lat end, 0),
    'rider_lng', coalesce(case when d.status in ('assigned','out_for_delivery')
                               then v_loc.lng end, 0),
    'has_rider_location', (d.status in ('assigned','out_for_delivery')
                           and v_loc.lat is not null and v_loc.lng is not null),
    'location_updated_at', coalesce(v_loc.updated_at::text,''),
    'destination_lat', coalesce(d.lat, 0),
    'destination_lng', coalesce(d.lng, 0),
    'has_destination', (d.lat is not null and d.lng is not null),
    'rider_arrived', (d.arrived_at is not null),
    -- CHANGE #462: the confirm code is released when the rider is at the door,
    -- so a link holder can no longer close the stop from anywhere.
    'qr_token', case when v_show_qr then coalesce(d.qr_token,'') else '' end,
    'delivered_at', coalesce(d.delivered_at::text,''));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. GAP 107 — the Google apply path stops erasing the grouping.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_apply_google(
  p_run_id uuid, p_optimised_delivery_ids uuid[], p_polyline text default null::text,
  p_leg_meters integer[] default null::integer[], p_leg_seconds integer[] default null::integer[],
  p_origin_lat numeric default null::numeric, p_origin_lng numeric default null::numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_open int; v_n int; i int; v_seq int := 0; v_cum_m numeric := 0;
  v_leg_m numeric; v_leg_s numeric; v_t numeric := 0; v_partner uuid; v_groups int;
begin
  select partner_id into v_partner from delivery_runs where id = p_run_id;
  if v_partner is null then return jsonb_build_object('ok',false,'error','run_not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = v_partner and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_n := coalesce(array_length(p_optimised_delivery_ids,1),0);
  select count(*) into v_open from deliveries
   where run_id = p_run_id and status not in ('delivered','cancelled');
  -- same guard the Route tab uses: the returned list must match the open stops
  if v_n <> v_open then
    return jsonb_build_object('ok',false,'error','stop_count_mismatch',
      'expected', v_open, 'got', v_n,
      'message','The optimised list does not match this run''s stops.');
  end if;

  for i in 1..v_n loop
    v_seq := v_seq + 1;
    v_leg_m := case when p_leg_meters  is not null and i <= array_length(p_leg_meters,1)
                    then p_leg_meters[i] end;
    v_leg_s := case when p_leg_seconds is not null and i <= array_length(p_leg_seconds,1)
                    then p_leg_seconds[i] end;
    v_cum_m := v_cum_m + coalesce(v_leg_m,0);
    v_t := v_t + coalesce(v_leg_s,0);

    update deliveries
       set seq = v_seq,
           leg_km  = case when v_leg_m is not null then round(v_leg_m/1000.0,2) end,
           cum_km  = round(v_cum_m/1000.0,2),
           eta_min = case when p_leg_seconds is not null then ceil(v_t/60.0)::int end
     where id = p_optimised_delivery_ids[i] and run_id = p_run_id;
  end loop;

  -- CHANGE #462 (gap 107): the comment used to say co-located stops stay
  -- together while the loop handed every stop its own group, erasing the 150 m
  -- grouping the optimiser had just built. Re-derive it by the SAME rule, in
  -- the new Google order, from the one function that owns that rule.
  v_groups := public._delivery_regroup_run(p_run_id);

  update delivery_runs
     set road_polyline = coalesce(p_polyline, road_polyline),
         google_optimized = true,
         optimized_at = now(),
         total_km = round(v_cum_m/1000.0,2),
         total_min = case when p_leg_seconds is not null then ceil(v_t/60.0)::int end
   where id = p_run_id;

  -- ...and total_stops means the same thing here as everywhere else.
  perform public._delivery_run_recount(p_run_id);

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops',v_seq,
    'stop_groups', v_groups,
    'total_km', round(v_cum_m/1000.0,2),
    'total_min', case when p_leg_seconds is not null then ceil(v_t/60.0)::int end,
    'optimized', true, 'has_polyline', (p_polyline is not null),
    'method','google');
end $function$;

-- The optimiser now delegates both the grouping rule and the count.
create or replace function public._delivery_optimize_run_unchecked(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_seq int := 0; r record; v_cur_lat numeric; v_cur_lng numeric; v_partner uuid;
begin
  select partner_id into v_partner from delivery_runs where id = p_run_id;
  if v_partner is null then return jsonb_build_object('ok',false,'error','run_not_found'); end if;

  select lat, lng into v_cur_lat, v_cur_lng
    from delivery_partner_locations where partner_id = v_partner;

  update deliveries set seq = null
   where run_id = p_run_id and status not in ('delivered','cancelled');

  perform public._delivery_regroup_run(p_run_id);

  if v_cur_lat is null then
    select lat, lng into v_cur_lat, v_cur_lng from deliveries
     where run_id = p_run_id and lat is not null limit 1;
  end if;

  loop
    select d.stop_group AS stop_group, min(d.lat) AS lat, min(d.lng) AS lng into r
    from deliveries d
    where d.run_id = p_run_id and d.seq is null and d.stop_group is not null
      and d.status not in ('delivered','cancelled')
    group by d.stop_group
    order by coalesce(public._geo_m(v_cur_lat, v_cur_lng, min(d.lat), min(d.lng)), 1e12), d.stop_group
    limit 1;
    exit when r.stop_group is null;
    v_seq := v_seq + 1;
    update deliveries set seq = v_seq where run_id = p_run_id and stop_group = r.stop_group;
    v_cur_lat := r.lat; v_cur_lng := r.lng;
  end loop;

  -- CHANGE #309 (10): cold-chain stops re-rank to the front of the finished route.
  with ranked as (
    select d.stop_group,
           bool_or(d.is_cold_chain) cold,
           min(d.seq) cur_seq
      from deliveries d
     where d.run_id = p_run_id and d.seq is not null
       and d.status not in ('delivered','cancelled')
     group by d.stop_group),
  renum as (
    select stop_group,
           row_number() over (order by cold desc, cur_seq) new_seq
      from ranked)
  update deliveries d
     set seq = q.new_seq
    from renum q
   where d.run_id = p_run_id and d.stop_group = q.stop_group
     and d.status not in ('delivered','cancelled');

  update delivery_runs set optimized_at = now() where id = p_run_id;
  perform public._delivery_run_recount(p_run_id);

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops',v_seq,'method','nearest_neighbour');
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. GAP 108 — a rejection now costs the rider something and fixes the run.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_respond(
  p_delivery_id uuid, p_action text, p_reason text default null::text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  d deliveries%rowtype; v_me uuid := auth.uid(); v_partner uuid; v_wave jsonb;
  v_run uuid; v_cap int; v_today int;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  select id into v_partner from delivery_partner_registrations
   where id = d.partner_id
     and (user_id = v_me
          or parent_agency_id in (select id from delivery_partner_registrations where user_id = v_me));
  if v_partner is null and get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  if lower(coalesce(p_action,'')) = 'accept' then
    update deliveries set accept_status='accepted', accepted_at=now(), status='assigned'
     where id = p_delivery_id;
    insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'accepted', coalesce(auth.jwt()->>'email','partner'));
    if d.wave_id is not null then
      perform public._wave_log(d.wave_id, null, d.order_id, d.partner_id, d.id,
        'stop_accepted', 'Rider accepted the stop.', '{}'::jsonb,
        coalesce(auth.jwt()->>'email','partner'));
    end if;
    return jsonb_build_object('ok',true,'accept_status','accepted','message','Delivery accepted');

  elsif lower(coalesce(p_action,'')) = 'reject' then
    -- CHANGE #462 (gap 108): rejecting used to be free. It now has a daily cap,
    -- read from delivery_config so Om retunes it without a deploy. Admins are
    -- not capped — an admin rejecting on a rider's behalf is a correction.
    v_cap := coalesce((public._dcfg(d.zone_id)->>'reject_cap_per_day')::int, 5);
    if d.partner_id is not null and v_cap > 0
       and get_my_role() not in ('admin','super_admin') then
      select count(*) into v_today from delivery_events
       where partner_id = d.partner_id and event = 'rejected'
         and created_at >= (now() at time zone 'Asia/Kolkata')::date::timestamptz;
      if coalesce(v_today,0) >= v_cap then
        return jsonb_build_object('ok',false,'error','reject_capped',
          'rejected_today', v_today, 'cap', v_cap,
          'title',   public._c('delivery.reject_capped_title'),
          'message', public._c('delivery.reject_capped_msg'));
      end if;
    end if;

    v_run := d.run_id;

    update deliveries set accept_status='rejected', rejected_at=now(),
           reject_reason=nullif(btrim(coalesce(p_reason,'')),''),
           status='unassigned', partner_id=null, run_id=null
     where id = p_delivery_id;
    insert into delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'rejected', p_reason,
            coalesce(auth.jwt()->>'email','partner'));

    -- CHANGE #462 (gap 108): the run no longer counts a stop it does not have.
    perform public._delivery_run_recount(v_run);

    -- CHANGE #405 — a wave stop returns to its wave and is reallocated.
    if d.wave_id is not null then
      v_wave := public.delivery_wave_reallocate(p_delivery_id, d.partner_id, p_reason,
                  coalesce(auth.jwt()->>'email','partner'));
      return jsonb_build_object('ok',true,'accept_status','rejected',
        'message','Delivery rejected — back in the wave for another rider.',
        'rejected_today', coalesce(v_today,0) + 1, 'cap', v_cap,
        'wave', v_wave);
    end if;

    return jsonb_build_object('ok',true,'accept_status','rejected',
      'rejected_today', coalesce(v_today,0) + 1, 'cap', v_cap,
      'message','Delivery rejected — back in the admin queue');
  end if;
  return jsonb_build_object('ok',false,'error','bad_action');
end $function$;

-- ...and the suggestion engine stops handing the same order straight back to
-- the rider who just refused it.
create or replace function public.delivery_suggest_partner(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_zone smallint; v_best jsonb; v_cool int;
begin
  select coalesce(o.zone_id, pp.zone_id) into v_zone
  from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id=p_order_id;

  -- CHANGE #462 (gap 108): a rejection is remembered for a cooldown window.
  v_cool := coalesce((public._dcfg(v_zone)->>'reject_cooldown_min')::int, 240);

  select jsonb_build_object('partner_id',p.id,'name',p.full_name,
           'open_stops',c.n,'capacity',p.max_stops,'zone_id',p.zone_id,
           'reason','Lightest load in this zone')
    into v_best
  from delivery_partner_registrations p
  cross join lateral (select count(*) n from deliveries d
                       where d.partner_id=p.id and d.status in ('assigned','out_for_delivery')) c
  where p.is_active and coalesce(p.is_deleted,false)=false
    and coalesce(p.zone_id, v_zone) = v_zone            -- never cross zones
    and (p.max_stops is null or c.n < p.max_stops)
    and not exists (select 1 from delivery_events e
                     where e.order_id = p_order_id and e.partner_id = p.id
                       and e.event = 'rejected'
                       and v_cool > 0
                       and e.created_at >= now() - make_interval(mins => v_cool))
  order by c.n, p.full_name
  limit 1;

  return coalesce(v_best, jsonb_build_object('partner_id',null,
    'reason','No active partner with spare capacity in this zone'));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. GAP 109 + GAP 110 — registration keeps what the form sends, and refuses
--     an application that has nobody behind it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_partner_register(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_id uuid; v_ocr jsonb := coalesce(p->'ocr_payload','{}'::jsonb); r record; v_name text;
  v_phone text; v_pincode text; v_zone_txt text; v_zone_id smallint;
begin
  -- CHANGE #462 (gap 110): an anonymous caller used to create a row with
  -- user_id null — invisible to every RLS policy and claimable by no rider.
  if auth.uid() is null then
    return jsonb_build_object('ok',false,'error','not_signed_in',
      'message', public.uic('delivery.reg_no_session',
        'Sign in before applying so we can attach the application to your account.'));
  end if;

  if exists(select 1 from delivery_partner_registrations
             where user_id = auth.uid() and coalesce(is_deleted,false)=false
               and coalesce(status,'') <> 'rejected') then
    return jsonb_build_object('ok',false,'error','already_registered',
      'message', public.uic('delivery.reg_already','You have already applied — check the status below.'));
  end if;

  v_phone := coalesce(nullif(btrim(coalesce(p->>'phone','')),''),
                      nullif(btrim(coalesce(v_ocr->>'phone','')),''));

  -- CHANGE #462 (gap 110): and the same phone cannot carry two live applications.
  if v_phone is not null and exists(
       select 1 from delivery_partner_registrations
        where phone = v_phone and coalesce(is_deleted,false)=false
          and coalesce(status,'') <> 'rejected') then
    return jsonb_build_object('ok',false,'error','phone_taken',
      'message', public.uic('delivery.reg_phone_taken',
        'An application already exists for this phone number.'));
  end if;

  -- CHANGE #462 (gap 109): the pincode the form has always posted (and the OCR
  -- prefilled) is stored, and the free-text zone is RESOLVED to a zone_id — via
  -- the pincode map first, the zone's own code/name second, the default zone
  -- last — so the assign queue can actually see this rider.
  v_pincode := coalesce(nullif(btrim(coalesce(p->>'pincode','')),''),
                        nullif(btrim(coalesce(v_ocr->>'pincode','')),''));
  v_zone_txt := nullif(btrim(coalesce(p->>'delivery_zone','')),'');

  if v_pincode is not null then
    select s.zone_id into v_zone_id from delivery_serviceability s
     where s.pincode = v_pincode and coalesce(s.is_active,true) limit 1;
  end if;
  if v_zone_id is null and v_zone_txt is not null then
    select z.id into v_zone_id from zones z
     where coalesce(z.is_active,true)
       and (lower(btrim(z.code)) = lower(v_zone_txt) or lower(btrim(z.name)) = lower(v_zone_txt))
     limit 1;
  end if;
  if v_zone_id is null then
    select z.id into v_zone_id from zones z where coalesce(z.is_default,false) limit 1;
  end if;

  insert into delivery_partner_registrations(
    user_id, full_name, phone, email, vehicle_type, delivery_zone, zone_id, pincode,
    address, city, state,
    id_proof_type, id_doc_type, id_doc_number, id_doc_path, ocr_payload,
    partner_type, status, is_active, submitted_at)
  values (auth.uid(),
    coalesce(nullif(btrim(coalesce(p->>'full_name','')),''), nullif(btrim(coalesce(v_ocr->>'name','')),'')),
    v_phone,
    nullif(btrim(coalesce(p->>'email','')),''),
    nullif(btrim(coalesce(p->>'vehicle_type','')),''),
    v_zone_txt,
    v_zone_id,
    v_pincode,
    coalesce(nullif(btrim(coalesce(p->>'address','')),''), nullif(btrim(coalesce(v_ocr->>'address','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'city','')),''), nullif(btrim(coalesce(v_ocr->>'city','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'state','')),''), nullif(btrim(coalesce(v_ocr->>'state','')),'')),
    nullif(btrim(coalesce(p->>'id_doc_type','')),''),
    nullif(btrim(coalesce(p->>'id_doc_type','')),''),
    coalesce(nullif(btrim(coalesce(p->>'id_doc_number','')),''), nullif(btrim(coalesce(v_ocr->>'id_number','')),'')),
    nullif(btrim(coalesce(p->>'id_doc_path','')),''),
    v_ocr,
    coalesce(nullif(btrim(coalesce(p->>'partner_type','')),''),'boy'),
    'pending', false, now())
  returning id, full_name into v_id, v_name;

  -- the admin alert the audit found missing: one inbox row per admin account
  for r in select a.email, u.id as uid from admins a
             left join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
  loop
    perform public._delivery_inbox(r.uid, r.email, 'delivery_partner_applied',
      public.uic('delivery.reg_admin_title','New rider application'),
      coalesce(v_name,'') , '/admin?tab=delivery');
  end loop;

  perform public._delivery_inbox(auth.uid(), null, 'delivery_partner_submitted',
    public.uic('delivery.reg_submitted_title','Application submitted'),
    public.uic('delivery.reg_submitted_body','An admin will review it and you will see the decision here.'),
    '/delivery-register');

  return jsonb_build_object('ok',true,'registration_id',v_id,
    'zone_id', v_zone_id, 'pincode', coalesce(v_pincode,''),
    'message', public.uic('delivery.reg_submitted_toast','Registration submitted — an admin will review it'));
end $function$;

-- CHANGE #462 (gap 110): an unauthenticated caller has no business here at all.
revoke execute on function public.delivery_partner_register(jsonb) from anon;

-- A partial unique index is the structural half of the same guard: two live
-- applications can never share a user, whatever the code path.
create unique index if not exists delivery_reg_one_live_per_user_idx
  on public.delivery_partner_registrations (user_id)
  where user_id is not null and coalesce(is_deleted,false) = false
        and coalesce(status,'') <> 'rejected';

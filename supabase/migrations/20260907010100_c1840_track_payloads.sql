-- CMD #1840 — the two customer tracking payloads carry the live map.
--
-- customer_track_order() and delivery_track_public() are re-emitted with three
-- new blocks each: `map` (the persistence contract — two heights and the two
-- words), `trust` (live / arriving / updating / stale / offline / done, plus
-- the `stream` flag that tells the client to CLOSE its location subscription)
-- and `rider_card` (name, face, vehicle, masked call, WhatsApp, stops before
-- you). The public page additionally gains the `live` block, the road-snapped
-- pair and animate_ms it never had, so both surfaces render the identical
-- widget from identical data.
--
-- Nothing existing is removed: every key both functions already returned is
-- still returned, so no caller of either RPC can break.

begin;

CREATE OR REPLACE FUNCTION public.customer_track_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
        v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb; v_is_buyer boolean;
        -- CMD #1840 — the map contract, the trust line and the rider card.
        v_map jsonb; v_trust jsonb; v_rider_card jsonb;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid())
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
      -- CHANGE #704: the agency holding the stop can read its own tracking too.
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations ap on ap.id = dd.agency_id
                 where dd.order_id = p_order_id and ap.user_id = auth.uid())
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
      'eta', public._delivery_eta_for_order(p_order_id),
      'proof', jsonb_build_object('has', false, 'heading', public._c('delivery.proof_heading')),
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
      -- CMD #1840 — nothing to track yet: the map contract still travels (the
      -- card renders no map because tracking is false), the trust line says
      -- 'done' so no subscription is opened, and there is no rider to card.
      'map', public._c1840_map_block('preparing'),
      'trust', public._c1840_trust_block(null, 'preparing', '{}'::jsonb),
      'rider_card', jsonb_build_object('has', false),
      'live', public._delivery_live_block(null));
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(live_animate_ms, 1200) into v_animate from delivery_config where id = 1;

  select snap_lat, snap_lng, snapped, speed_kmh into v_last
    from delivery_run_trail where run_id = d.run_id order by ts desc limit 1;
  v_snapped := coalesce(v_last.snapped,false)
               and v_last.snap_lat is not null and v_last.snap_lng is not null;

  -- CHANGE #691: the stop count and the arrival window now come from ONE block,
  -- so the tracker, the public page and the Orders card cannot disagree.
  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(p_order_id);
  -- CHANGE #703: the doorbell and the cold box. Both are whole payloads —
  -- the tracker prints them and decides nothing, not even whether the QR shows.
  -- CHANGE #703 / #354: this RPC admits the RIDER as well as the buyer, and
  -- the handover OTP is the one thing the rider must never be handed. Who is
  -- asking is decided here, once, and the block obeys it.
  select (public._is_admin()
          or exists (select 1 from orders o2 join pharmacy_profiles pp2 on pp2.id = o2.customer_id
                      where o2.id = p_order_id and pp2.user_id = auth.uid()))
    into v_is_buyer;
  v_arrival := public._c703_arrival_block(d.id, coalesce(v_is_buyer,false));
  v_cold    := public._c703_cold_block(d.id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CHANGE #462 (gap 104)
  -- CHANGE #703: the approach ring is what opens the handover, so the buyer has
  -- the three minutes the alert promised them rather than three seconds at the
  -- door. Arrival still opens it for a rider who appeared inside 50 m.
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or d.approach_notified_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  -- The staleness sentence is only meaningful while a rider is supposed to be
  -- moving. On a delivered or failed stop the map is history, not a live feed,
  -- so no "Rider offline" is ever shown for an order that already arrived.
  v_live := case when d.status in ('assigned','out_for_delivery')
                 then public._delivery_live_block(v_loc.updated_at)
                 else public._delivery_live_block(null) end;

  -- CMD #1840 — the three blocks the live map is made of. Every height, word,
  -- tone and threshold in them is decided here; the app renders them.
  v_map        := public._c1840_map_block(d.status);
  v_trust      := public._c1840_trust_block(v_loc.updated_at, d.status, v_arrival);
  v_rider_card := public._c1840_rider_card(d.id, v_eta);

  return jsonb_build_object(
    'ok', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', d.status,
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        -- CHANGE #704: before the agency names a rider there IS no rider to
        -- show, and the buyer is told exactly that rather than nothing.
        when 'agency_pending' then public._c('agency.track_pending')
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    'assigned_to', jsonb_build_object(
        'has',  (d.agency_id is not null or d.partner_id is not null),
        'kind', case when d.partner_id is not null then 'rider'
                     when d.agency_id is not null then 'agency' else 'none' end,
        'name', case when d.partner_id is not null then coalesce(v_name,'')
                     else coalesce((select ag.full_name
                                      from delivery_partner_registrations ag
                                     where ag.id = d.agency_id), '') end,
        'label', case when d.partner_id is not null then coalesce(v_name,'')
                      when d.agency_id is not null then public._c('agency.track_pending')
                      else '' end),
    -- CHANGE #463 (register row 117's deferred half, unblocked by row 121):
    -- the rider's verified face, for the buyer at whose door they are standing.
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    -- CHANGE #691 (gap 122 / 126)
    'eta',   v_eta,
    'proof', v_proof,
    -- CHANGE #703 (spec 1, 3 and 4)
    'arrival', v_arrival,
    'cold_chain', v_cold,
    'stops_ahead', v_ahead,
    'stops_ahead_label', nullif(v_eta->>'stops_ahead_label',''),
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
    -- CHANGE #701 — the route to THIS door and nothing else: the segment from
    -- where the rider is to this stop, the road distance along it, and the
    -- stops in front named by postal area only. The rest of the run passes
    -- other pharmacies' doors and is cut in _c701_route_segment.
    'route', public._c701_route_block(d.id),
    -- CHANGE #701 — "share live link with staff". The BACKEND decides who is
    -- offered it (a live stop with a token), so the public /track page — which
    -- has no identity to authorise a send — simply never receives the block.
    'share', jsonb_build_object(
      'has',   (d.status in ('assigned','out_for_delivery')
                and coalesce(d.track_token,'') <> ''),
      'label', public._c('delivery.share_staff'),
      'rpc',   'delivery_share_track_link',
      'order_id', d.order_id::text),
    'track_token', case when d.status in ('assigned','out_for_delivery')
                        then d.track_token end,
    -- CMD #1840 — the persistent map's contract, the trustworthy pin and the
    -- rider + vehicle card, in the same payload the sheet already reads.
    'map', v_map,
    'trust', v_trust,
    'rider_card', v_rider_card,
    'timeline', v_tl);
end $function$;

CREATE OR REPLACE FUNCTION public.delivery_track_public(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d deliveries%rowtype; v_loc delivery_partner_locations%rowtype;
  v_ahead int; v_name text; v_code text; v_show_qr boolean;
  v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb;
  v_last record; v_snapped boolean; v_animate int;
  v_map jsonb; v_trust jsonb; v_rider_card jsonb;
begin
  -- CHANGE #701 — the public link is `track_token`, never `qr_token`. The QR
  -- token proves DELIVERY; using it as the tracking link meant one forwarded
  -- WhatsApp message carried the proof secret too, and never went stale.
  select * into d from deliveries where track_token = btrim(coalesce(p_token,''));

  -- Expired is its own answer, in the backend's own words — not "not found",
  -- which would tell a customer their order had vanished.
  if d.id is not null and d.track_token_expires_at is not null
     and d.track_token_expires_at <= now() then
    return jsonb_build_object(
      'ok', false, 'found', false, 'expired', true, 'tracking', false,
      'title', public._c('delivery.link_expired_title'),
      'message', public._c('delivery.link_expired'),
      'status', '', 'status_label', '', 'partner_name', '',
      'stops_ahead', 0, 'stops_ahead_label', '', 'has_stops_ahead', false,
      'eta', jsonb_build_object('has', false, 'state','none','label','',
                                'window_label','','countdown_label',''),
      'proof', jsonb_build_object('has', false),
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
      'route', jsonb_build_object('has', false, 'polyline','', 'km_label',''),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'map', jsonb_build_object('has', false),
      'trust', jsonb_build_object('has', false, 'state','done','stream','stop'),
      'rider_card', jsonb_build_object('has', false),
      'live', jsonb_build_object('has', false, 'is_live', false, 'state','none',
                                 'label','', 'tone','muted'),
      'map_lat', 0, 'map_lng', 0, 'rider_snapped', false, 'animate_ms', 1200,
      'note', '', 'has_channel', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;
  if d.id is null then
    return jsonb_build_object(
      'ok', false, 'found', false, 'tracking', false,
      'title', 'Tracking link not found',
      'message', 'This tracking link is not valid any more.',
      'status', '', 'status_label', '', 'partner_name', '',
      'stops_ahead', 0, 'stops_ahead_label', '', 'has_stops_ahead', false,
      'eta', jsonb_build_object('has', false, 'state','none','label','',
                                'window_label','','countdown_label',''),
      'proof', jsonb_build_object('has', false),
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
      'route', jsonb_build_object('has', false, 'polyline','', 'km_label',''),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'map', jsonb_build_object('has', false),
      'trust', jsonb_build_object('has', false, 'state','done','stream','stop'),
      'rider_card', jsonb_build_object('has', false),
      'live', jsonb_build_object('has', false, 'is_live', false, 'state','none',
                                 'label','', 'tone','muted'),
      'map_lat', 0, 'map_lng', 0, 'rider_snapped', false, 'animate_ms', 1200,
      'note', '', 'has_channel', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(order_code,'') into v_code from orders where id = d.order_id;

  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(d.order_id);
  -- CHANGE #703: the same two blocks the in-app tracker draws, so the link a
  -- buyer forwards to their counter staff shows the identical doorbell.
  v_arrival := public._c703_arrival_block(d.id);
  v_cold    := public._c703_cold_block(d.id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CMD #1840 — the public page draws the SAME map, trust line and rider card
  -- as the signed-in popup. The only thing it cannot have is the private run
  -- channel (no identity to pass its RLS check), so it keeps its refetch.
  select coalesce(live_animate_ms, 1200) into v_animate from public.delivery_config where id = 1;
  select snap_lat, snap_lng, snapped into v_last
    from public.delivery_run_trail where run_id = d.run_id order by ts desc limit 1;
  v_snapped := coalesce(v_last.snapped,false)
               and v_last.snap_lat is not null and v_last.snap_lng is not null;

  v_map        := public._c1840_map_block(d.status);
  v_trust      := public._c1840_trust_block(v_loc.updated_at, d.status, v_arrival);
  v_rider_card := public._c1840_rider_card(d.id, v_eta);

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
    -- CHANGE #691 (gap 122 / 126)
    'eta',   v_eta,
    'proof', v_proof,
    'arrival', v_arrival,
    'cold_chain', v_cold,
    'stops_ahead', v_ahead,
    'has_stops_ahead', (d.status in ('assigned','out_for_delivery')),
    'stops_ahead_label', coalesce(v_eta->>'stops_ahead_label',''),
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
    -- CHANGE #701 — same block the signed-in tracker prints, so the two pages
    -- cannot disagree about the route, the distance or who is ahead.
    'route', public._c701_route_block(d.id),
    -- CMD #1840 — same three blocks, same words, same thresholds.
    'map', v_map,
    'trust', v_trust,
    'rider_card', v_rider_card,
    'live', case when d.status in ('assigned','out_for_delivery')
                 then public._delivery_live_block(v_loc.updated_at)
                 else public._delivery_live_block(null) end,
    'map_lat', coalesce(case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lat else v_loc.lat end end, 0),
    'map_lng', coalesce(case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lng else v_loc.lng end end, 0),
    'rider_snapped', ((d.status in ('assigned','out_for_delivery')) and v_snapped),
    'animate_ms', coalesce(v_animate, 1200),
    'note', case when d.status in ('assigned','out_for_delivery') and not v_snapped
                 then public._c('delivery.live_raw_note') else '' end,
    'has_channel', false,
    'delivered_at', coalesce(d.delivered_at::text,''));
end $function$;

commit;

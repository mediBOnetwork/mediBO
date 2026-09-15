-- CHANGE #701 — customer tracking map: the route to YOUR door, and a link that expires.
--
-- Register #125 + the gap it names: delivery_run_map() has the road polyline but
-- is admin/rider only; customer_track_order() and delivery_track_public() return
-- bare points; and the public link was the QR token, which never expired and
-- never rotated — one screenshot of a WhatsApp message tracked that pharmacy for
-- ever, and the same token also unlocked the delivery QR.
--
-- Three things land here:
--   1. The customer is sent the SEGMENT of the run from the rider's current
--      position to their own stop. Never the whole run: the rest of the polyline
--      passes other pharmacies' doors, and stops ahead are named by AREA only.
--   2. Remaining road distance along that segment, as a finished string.
--   3. `track_token` is its own column with its own expiry: rotated whenever the
--      stop is (re)assigned, and dead two hours after delivered/failed.
--
-- Idempotent throughout.

-- ── 1. the polyline codec ──────────────────────────────────────────────────
-- Google's encoded-polyline algorithm, both directions, in SQL. The frontend
-- already decodes this exact format (delivery_run_map_panel.dart), so sending a
-- re-encoded SEGMENT means the customer map needs no new drawing code.
create or replace function public._c701_poly_decode(p_encoded text)
 returns table(ord int, lat double precision, lng double precision)
 language plpgsql immutable
as $function$
declare
  i int := 1; n int := length(coalesce(p_encoded,''));
  b int; shift int; result int; dlat int; dlng int;
  cur_lat int := 0; cur_lng int := 0; k int := 0;
begin
  while i <= n loop
    shift := 0; result := 0;
    loop
      b := ascii(substr(p_encoded, i, 1)) - 63; i := i + 1;
      result := result | ((b & 31) << shift);
      shift := shift + 5;
      exit when b < 32 or i > n + 1;
    end loop;
    dlat := case when (result & 1) = 1 then ~((result >> 1)) else (result >> 1) end;
    cur_lat := cur_lat + dlat;

    shift := 0; result := 0;
    loop
      b := ascii(substr(p_encoded, i, 1)) - 63; i := i + 1;
      result := result | ((b & 31) << shift);
      shift := shift + 5;
      exit when b < 32 or i > n + 1;
    end loop;
    dlng := case when (result & 1) = 1 then ~((result >> 1)) else (result >> 1) end;
    cur_lng := cur_lng + dlng;

    k := k + 1;
    ord := k; lat := cur_lat / 1e5; lng := cur_lng / 1e5;
    return next;
  end loop;
end $function$;

create or replace function public._c701_poly_encode(p_pts jsonb)
 returns text
 language plpgsql immutable
as $function$
declare
  r jsonb; out text := ''; prev_lat int := 0; prev_lng int := 0;
  cur_lat int; cur_lng int; d int; v int;
begin
  for r in select * from jsonb_array_elements(coalesce(p_pts,'[]'::jsonb)) loop
    cur_lat := round((r->>'lat')::numeric * 1e5);
    cur_lng := round((r->>'lng')::numeric * 1e5);
    foreach d in array array[cur_lat - prev_lat, cur_lng - prev_lng] loop
      v := case when d < 0 then ~(d << 1) else (d << 1) end;
      while v >= 32 loop
        out := out || chr(((32 | (v & 31)) + 63));
        v := v >> 5;
      end loop;
      out := out || chr(v + 63);
    end loop;
    prev_lat := cur_lat; prev_lng := cur_lng;
  end loop;
  return out;
end $function$;
-- ── 2. the segment a customer may see ──────────────────────────────────────
-- The rider's position and THIS stop, and only the polyline between them. The
-- run's remaining shape passes other pharmacies' doors, so it is cut here, in
-- the database, and never sent.
create or replace function public._c701_route_segment(
  p_run_id uuid, p_from_lat double precision, p_from_lng double precision,
  p_to_lat double precision, p_to_lng double precision)
 returns jsonb
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
declare
  v_poly text; v_i0 int; v_i1 int; v_pts jsonb; v_km numeric;
begin
  if p_from_lat is null or p_from_lng is null
     or p_to_lat is null or p_to_lng is null then
    return jsonb_build_object('has', false, 'polyline', '', 'km', null);
  end if;

  select road_polyline into v_poly from delivery_runs where id = p_run_id;

  -- No optimised route yet (or a run that was never sent to Google): the honest
  -- answer is a straight line between the two points the customer can already
  -- see, not a fabricated road shape.
  if coalesce(btrim(v_poly),'') = '' then
    v_pts := jsonb_build_array(
      jsonb_build_object('lat', p_from_lat, 'lng', p_from_lng),
      jsonb_build_object('lat', p_to_lat,   'lng', p_to_lng));
    return jsonb_build_object(
      'has', true, 'straight', true,
      'polyline', public._c701_poly_encode(v_pts),
      'km', round(public._km(p_from_lat,p_from_lng,p_to_lat,p_to_lng)::numeric, 1));
  end if;

  with pts as (select * from public._c701_poly_decode(v_poly))
  select (select ord from pts order by public._km(lat,lng,p_from_lat,p_from_lng) limit 1),
         (select ord from pts order by public._km(lat,lng,p_to_lat,p_to_lng)   limit 1)
    into v_i0, v_i1;

  if v_i0 is null or v_i1 is null then
    return jsonb_build_object('has', false, 'polyline', '', 'km', null);
  end if;

  -- A stop the rider has already passed still gets a line — from where they are
  -- to where the door is — rather than a reversed slice of the run.
  if v_i1 <= v_i0 then
    v_pts := jsonb_build_array(
      jsonb_build_object('lat', p_from_lat, 'lng', p_from_lng),
      jsonb_build_object('lat', p_to_lat,   'lng', p_to_lng));
    return jsonb_build_object(
      'has', true, 'straight', true,
      'polyline', public._c701_poly_encode(v_pts),
      'km', round(public._km(p_from_lat,p_from_lng,p_to_lat,p_to_lng)::numeric, 1));
  end if;

  -- The exact rider point and the exact door bracket the slice, so the drawn
  -- line starts and ends on the two pins instead of near them.
  select jsonb_build_object('lat',p_from_lat,'lng',p_from_lng)
         || '{}'::jsonb
    into v_pts;
  select jsonb_build_array(jsonb_build_object('lat',p_from_lat,'lng',p_from_lng))
         || coalesce(jsonb_agg(jsonb_build_object('lat',p.lat,'lng',p.lng) order by p.ord), '[]'::jsonb)
         || jsonb_build_array(jsonb_build_object('lat',p_to_lat,'lng',p_to_lng))
    into v_pts
    from public._c701_poly_decode(v_poly) p
   where p.ord > v_i0 and p.ord < v_i1;

  -- Road distance along the slice we actually drew.
  select round(sum(public._km(
           (a->>'lat')::double precision, (a->>'lng')::double precision,
           (b->>'lat')::double precision, (b->>'lng')::double precision))::numeric, 1)
    into v_km
    from jsonb_array_elements(v_pts) with ordinality x(a, i)
    join jsonb_array_elements(v_pts) with ordinality y(b, j) on j = i + 1;

  return jsonb_build_object(
    'has', true, 'straight', false,
    'polyline', public._c701_poly_encode(v_pts),
    'km', v_km);
end $function$;
-- ── 3. a tracking token of its own ─────────────────────────────────────────
-- The public link was `qr_token` — the SAME secret the customer scans to prove
-- delivery. It never expired and never rotated, so one forwarded WhatsApp
-- message tracked that pharmacy for ever and also carried the proof token.
alter table public.deliveries add column if not exists track_token text;
alter table public.deliveries add column if not exists track_token_expires_at timestamptz;
create unique index if not exists deliveries_track_token_key
  on public.deliveries (track_token) where track_token is not null;

comment on column public.deliveries.track_token is
  'CHANGE #701 — the PUBLIC tracking link secret. Separate from qr_token (which '
  'proves delivery), rotated on every (re)assignment and dead 2 h after the stop '
  'finishes.';

-- Rotation + expiry, stated as one trigger so no write path can forget it.
create or replace function public._c701_track_token_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  -- (Re)assignment mints a new secret: whoever held the old link stops seeing a
  -- rider who is no longer coming to them.
  if tg_op = 'INSERT'
     or new.partner_id is distinct from old.partner_id
     or new.run_id     is distinct from old.run_id then
    new.track_token := encode(gen_random_bytes(18), 'hex');
    new.track_token_expires_at := null;
  end if;

  -- A finished stop keeps its link alive just long enough to read the proof.
  if new.status in ('delivered','failed','rto')
     and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    new.track_token_expires_at := now() + interval '2 hours';
  elsif new.status not in ('delivered','failed','rto') then
    new.track_token_expires_at := null;
  end if;

  if new.track_token is null then
    new.track_token := encode(gen_random_bytes(18), 'hex');
  end if;
  return new;
end $function$;

drop trigger if exists _c701_track_token_trg on public.deliveries;
create trigger _c701_track_token_trg
  before insert or update on public.deliveries
  for each row execute function public._c701_track_token_trg();

-- Backfill: every live stop gets a token now, and finished ones are already past
-- their two hours, so they are minted expired rather than left link-less.
update public.deliveries
   set track_token = encode(gen_random_bytes(18), 'hex'),
       track_token_expires_at = case when status in ('delivered','failed','rto')
                                     then coalesce(delivered_at, created_at, now()) + interval '2 hours'
                                     end
 where track_token is null;
-- ── 4. stops ahead, named by postal area only ──────────────────────────────
-- pharmacy_profiles has no locality column: `address` and `address_local` are
-- full street addresses, which are exactly what this change exists to keep
-- private. City + pincode is a real neighbourhood-level name and leaks no door.
create or replace function public._c701_stops_ahead(p_delivery_id uuid)
 returns jsonb
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_rows jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null or d.run_id is null or d.seq is null then
    return jsonb_build_object('has', false, 'count', 0, 'label', '', 'areas', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(x.area order by x.seq), '[]'::jsonb) into v_rows
  from (
    select o2.seq,
           btrim(coalesce(pp.city,'') || ' ' || coalesce(pp.pincode,'')) as area
      from deliveries o2
      join orders ord on ord.id = o2.order_id
      left join pharmacy_profiles pp on pp.id = ord.customer_id
     where o2.run_id = d.run_id
       and o2.seq is not null and o2.seq < d.seq
       and o2.status not in ('delivered','failed','rto','cancelled')
  ) x
  where coalesce(x.area,'') <> '';

  return jsonb_build_object(
    'has',   jsonb_array_length(v_rows) > 0,
    'count', jsonb_array_length(v_rows),
    'areas', v_rows,
    'label', case when jsonb_array_length(v_rows) = 0 then ''
                  else replace(public._c('delivery.stops_ahead_areas'),
                               '{n}', jsonb_array_length(v_rows)::text) end);
end $function$;

insert into public.ui_copy (key, value) values
  ('delivery.stops_ahead_areas', '"{n} stop(s) before yours"'::jsonb),
  ('delivery.route_distance',    '"{km} km away by road"'::jsonb),
  ('delivery.route_heading',     '"Route to your shop"'::jsonb),
  ('delivery.link_expired',      '"This tracking link has expired. Your order page always has the latest."'::jsonb),
  ('delivery.share_staff',       '"Share live link with staff"'::jsonb),
  ('delivery.share_staff_sent',  '"Live link sent to {n} staff number(s)."'::jsonb),
  ('delivery.share_staff_none',  '"No staff numbers are saved for this pharmacy yet."'::jsonb)
on conflict (key) do nothing;

-- The one block both trackers print, so the customer page and the public page
-- can never disagree about the route, the distance or who is ahead.
create or replace function public._c701_route_block(p_delivery_id uuid)
 returns jsonb
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
declare
  d deliveries%rowtype; v_loc delivery_partner_locations%rowtype;
  v_last record; v_lat double precision; v_lng double precision;
  v_seg jsonb; v_ahead jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  v_ahead := public._c701_stops_ahead(p_delivery_id);

  if d.id is null or d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('has', false, 'polyline', '', 'km_label', '',
                              'heading', public._c('delivery.route_heading'),
                              'stops_ahead', v_ahead);
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select snap_lat, snap_lng, snapped into v_last
    from delivery_run_trail where run_id = d.run_id order by ts desc limit 1;

  v_lat := case when coalesce(v_last.snapped,false) and v_last.snap_lat is not null
                then v_last.snap_lat else v_loc.lat end;
  v_lng := case when coalesce(v_last.snapped,false) and v_last.snap_lng is not null
                then v_last.snap_lng else v_loc.lng end;

  v_seg := public._c701_route_segment(d.run_id, v_lat, v_lng, d.lat, d.lng);

  return jsonb_build_object(
    'has',      coalesce((v_seg->>'has')::boolean, false),
    'heading',  public._c('delivery.route_heading'),
    'polyline', coalesce(v_seg->>'polyline',''),
    'straight', coalesce((v_seg->>'straight')::boolean, false),
    'km',       v_seg->'km',
    'km_label', case when v_seg->>'km' is null then ''
                     else replace(public._c('delivery.route_distance'),
                                  '{km}', to_char((v_seg->>'km')::numeric,'FM999990.0')) end,
    'stops_ahead', v_ahead);
end $function$;
create or replace function public.customer_track_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
        v_eta jsonb; v_proof jsonb;
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
      'eta', public._delivery_eta_for_order(p_order_id),
      'proof', jsonb_build_object('has', false, 'heading', public._c('delivery.proof_heading')),
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
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

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
    -- CHANGE #691 (gap 122 / 126)
    'eta',   v_eta,
    'proof', v_proof,
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
    'timeline', v_tl);
end $function$

;
create or replace function public.delivery_track_public(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d deliveries%rowtype; v_loc delivery_partner_locations%rowtype;
  v_ahead int; v_name text; v_code text; v_show_qr boolean;
  v_eta jsonb; v_proof jsonb;
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
      'route', jsonb_build_object('has', false, 'polyline','', 'km_label',''),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
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
      'route', jsonb_build_object('has', false, 'polyline','', 'km_label',''),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(order_code,'') into v_code from orders where id = d.order_id;

  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(d.order_id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

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
    'delivered_at', coalesce(d.delivered_at::text,''));
end $function$

;
-- ── 5. share the live link with the pharmacy's own staff ───────────────────
-- The same expiring link, to the counter staff who will actually receive the
-- boxes. It sends to the numbers already saved against this pharmacy — the
-- caller never supplies a phone, so this cannot be turned into a way to text a
-- stranger a customer's tracking link.
create or replace function public.delivery_share_track_link(p_order_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  d deliveries%rowtype; v_cust uuid; v_allowed boolean; v_link text;
  v_site text; v_n int := 0; r record; v_code text;
begin
  select o.customer_id, coalesce(o.order_code,'') into v_cust, v_code
    from orders o where o.id = p_order_id;

  -- Only this pharmacy (or an admin) may hand its own link around.
  select (public._is_admin()
          or exists (select 1 from pharmacy_profiles pp
                      where pp.id = v_cust and pp.user_id = auth.uid())
          or exists (select 1 from customer_users cu
                      where cu.customer_id = v_cust and cu.auth_user_id = auth.uid()
                        and cu.is_active))
    into v_allowed;
  if not coalesce(v_allowed,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._c('access.denied_view'));
  end if;

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null or coalesce(d.track_token,'') = ''
     or d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('ok', false, 'error','not_trackable',
                              'message', public._c('delivery.link_expired'));
  end if;

  v_site := coalesce(nullif(public._c('app.site_url'),''), 'https://medibo.in');
  v_link := v_site || '/track/' || d.track_token;

  for r in
    select distinct public._phone10(cu.identity) as ph
      from customer_users cu
     where cu.customer_id = v_cust and cu.is_active
       -- _phone10 returns '' for a non-numeric identity (staff log in with an
       -- email as often as a number), so length is the test, not NOT NULL.
       and length(public._phone10(cu.identity)) = 10
  loop
    perform public.wa_send_event('delivery_out', v_cust,
              jsonb_build_object('delivery_tracking_link', v_link,
                                 'order_code', v_code),
              r.ph, p_order_id);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object(
    'ok', true, 'sent', v_n, 'link', v_link,
    'message', case when v_n = 0 then public._c('delivery.share_staff_none')
                    else replace(public._c('delivery.share_staff_sent'), '{n}', v_n::text) end);
end $function$;

revoke all on function public.delivery_share_track_link(uuid) from public, anon;
grant execute on function public.delivery_share_track_link(uuid) to authenticated, service_role;
-- CHANGE #701 fix — gen_random_bytes lives in the `extensions` schema (pgcrypto)
-- and this trigger pins `search_path to 'public'`, so every INSERT/UPDATE on
-- deliveries raised "function gen_random_bytes(integer) does not exist". Four
-- delivery behaviour guards caught it within a minute. gen_random_uuid() is
-- CORE Postgres (13+), is already this table's own id default, and needs no
-- extension on the path.
create or replace function public._c701_track_token_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_new text;
begin
  v_new := replace(gen_random_uuid()::text, '-', '')
        || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

  if tg_op = 'INSERT'
     or new.partner_id is distinct from old.partner_id
     or new.run_id     is distinct from old.run_id then
    new.track_token := v_new;
    new.track_token_expires_at := null;
  end if;

  if new.status in ('delivered','failed','rto')
     and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    new.track_token_expires_at := now() + interval '2 hours';
  elsif new.status not in ('delivered','failed','rto') then
    new.track_token_expires_at := null;
  end if;

  if new.track_token is null then
    new.track_token := v_new;
  end if;
  return new;
end $function$;

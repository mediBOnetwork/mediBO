-- CHANGE #309 step 8a — my_delivery_run emits handover, SLA and cold-chain per stop.
CREATE OR REPLACE FUNCTION public.my_delivery_run(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid(); v_partner delivery_partner_registrations%rowtype;
  v_date date; v_run delivery_runs%rowtype; v_stops jsonb; v_n int; v_batches jsonb;
begin
  select * into v_partner from delivery_partner_registrations
   where user_id = v_me and is_active and coalesce(is_deleted,false)=false limit 1;
  if v_partner.id is null then
    return jsonb_build_object('allowed', false, 'is_partner', false,
      'empty_title','Not a delivery account',
      'empty_note','This login is not registered as a delivery partner.');
  end if;
  v_date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);

  select * into v_run from delivery_runs
   where partner_id = v_partner.id and run_date = v_date
   order by created_at desc limit 1;

  select coalesce(jsonb_agg(x order by (x->>'seq')::int nulls last, x->>'pharmacy_name'), '[]'::jsonb),
         count(*)
    into v_stops, v_n
  from (
    select jsonb_build_object(
      'delivery_id', d.id, 'order_id', o.id, 'order_code', coalesce(o.order_code,''),
      'seq', d.seq, 'stop_group', d.stop_group,
      'pharmacy_name', coalesce(o.pharmacy_name, pp.pharmacy_name,''),
      'address', coalesce(pp.address,''),
      'phone', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''),''),
      'lat', d.lat, 'lng', d.lng,
      'image_url', (select m.image_url_1 from order_items oi join "MEDICINE" m on m.id=oi.product_id
                     where oi.order_id=o.id and coalesce(oi.unfulfillable,false)=false
                       and m.image_url_1 is not null limit 1),
      'item_count', (select count(*) from order_items oi
                      where oi.order_id=o.id and coalesce(oi.unfulfillable,false)=false),
      'total_display', public.inr_money(coalesce(o.total_amount,0)),
      'status', d.status, 'accept_status', d.accept_status,
      'needs_response', (d.accept_status = 'pending'),
      'status_label', case d.status
          when 'delivered' then 'Delivered' when 'failed' then 'Failed'
          when 'out_for_delivery' then 'Out for delivery'
          when 'rto' then 'Returned' else 'Pending' end,
      -- Om's pin/stop colours: delivered green, not delivered yellow, failed red
      'pin_color', case d.status when 'delivered' then '#1B7A43'
                                 when 'failed' then '#B42318'
                                 when 'rto' then '#B42318' else '#F59E0B' end,
      'status_colors', case d.status
          when 'delivered' then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
          when 'failed' then jsonb_build_object('bg','#FBE9E7','fg','#B42318')
          when 'rto' then jsonb_build_object('bg','#FBE9E7','fg','#B42318')
          else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
      -- CHANGE #309 (1): a parcel that has not been collected cannot be
      -- delivered. can_deliver is the BACKEND's answer, so the rider's Deliver
      -- button and the server's own gate can never disagree.
      'can_deliver', (d.status in ('assigned','out_for_delivery')
                      and d.accept_status='accepted'
                      and (d.handover_at is not null or public._handover_exempt(d))),
      'needs_handover', (d.accept_status='accepted'
                         and d.status in ('assigned','out_for_delivery')
                         and d.handover_at is null
                         and not public._handover_exempt(d)),
      'handover', jsonb_build_object(
         'done', (d.handover_at is not null),
         'at', d.handover_at,
         'chip', case when d.handover_at is not null
                      then public._c('delivery.handover_done_chip')
                      else public._c('delivery.handover_pending_chip') end,
         'colors', case when d.handover_at is not null
                        then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
                        else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
         'button_label', public._c('delivery.handover_button'),
         'received_by', coalesce(d.handover_to_name,''),
         'handed_over_by', coalesce(d.handover_by_name,'')),
      -- CHANGE #309 (2) and (10): the promise and the cold-chain badge, both
      -- rendered verbatim by the stop card.
      'sla', public._sla_block(d),
      'cold_chain', public._cold_chain_block(d.is_cold_chain),
      'arrived_at', d.arrived_at,
      'arrived_chip', case when d.arrived_at is not null
                           then public._c('delivery.arrived_chip') else '' end,
      'qr_token', d.qr_token,
      'otp_sent', (d.otp_sent_at is not null),
      'delivered_at', d.delivered_at, 'fail_reason', d.fail_reason,
      'actions', jsonb_build_object(
         'call_number', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''),''),
         'whatsapp_number', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''),''),
         'directions_url', case when d.lat is not null then
             'https://www.google.com/maps/dir/?api=1&destination=' || d.lat || ',' || d.lng end)
    ) as x
    from deliveries d
    join orders o on o.id = d.order_id
    left join pharmacy_profiles pp on pp.id = o.customer_id
    where d.partner_id = v_partner.id
      and (v_run.id is null or d.run_id = v_run.id)
      and d.status not in ('cancelled')
  ) s;

  -- batch chips: 1-10 | 11-20 | 21-30
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', g, 'label', ((g-1)*10+1)::text || '-' || (g*10)::text,
           'from', (g-1)*10+1, 'to', g*10) order by g), '[]'::jsonb)
    into v_batches
  from generate_series(1, greatest(ceil(coalesce(v_n,0)/10.0)::int,1)) g
  where coalesce(v_n,0) > 0;

  return jsonb_build_object(
    'allowed', true, 'is_partner', true,
    'partner_id', v_partner.id,
    'partner_name', coalesce(v_partner.full_name,''),
    'partner_type', v_partner.partner_type,
    'is_agency', (v_partner.partner_type = 'agency'),
    'the_date', v_date,
    'run_id', v_run.id, 'run_status', coalesce(v_run.status,'none'),
    'stop_count', coalesce(v_n,0),
    'delivered_count', (select count(*) from deliveries where partner_id=v_partner.id
                          and (v_run.id is null or run_id=v_run.id) and status='delivered'),
    'pending_count', (select count(*) from deliveries where partner_id=v_partner.id
                        and (v_run.id is null or run_id=v_run.id)
                        and status in ('assigned','out_for_delivery')),
    'can_start', (coalesce(v_run.status,'none') = 'planned'
                 and exists (select 1 from deliveries d2 where d2.run_id = v_run.id
                              and d2.accept_status = 'accepted' and d2.status = 'assigned')),
    'can_finish', (coalesce(v_run.status,'none') = 'started'),
    'trip_action', case
        when coalesce(v_run.status,'none') = 'started' then 'finish'
        when coalesce(v_run.status,'none') = 'planned'
             and exists (select 1 from deliveries d3 where d3.run_id = v_run.id
                          and d3.accept_status = 'accepted' and d3.status = 'assigned') then 'start'
        else 'none' end,
    'trip_button_label', case
        when coalesce(v_run.status,'none') = 'started' then 'Finish trip'
        when coalesce(v_run.status,'none') = 'planned'
             and exists (select 1 from deliveries d4 where d4.run_id = v_run.id
                          and d4.accept_status = 'accepted' and d4.status = 'assigned') then 'Start trip'
        when coalesce(v_run.status,'none') = 'completed' then 'Trip completed'
        else 'Nothing to deliver' end,
    'trip_button_enabled', (
        coalesce(v_run.status,'none') = 'started'
        or (coalesce(v_run.status,'none') = 'planned'
            and exists (select 1 from deliveries d5 where d5.run_id = v_run.id
                         and d5.accept_status = 'accepted' and d5.status = 'assigned'))),
    'batches', v_batches,
    'stops', v_stops,
    'empty_title','No deliveries assigned',
    'empty_note','Assigned deliveries will appear here.');
end $function$

;

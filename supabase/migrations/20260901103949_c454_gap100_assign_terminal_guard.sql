-- CMD #454 — feature_gaps #100
-- "Re-assigning an order silently resurrects a completed delivery"
--
-- _delivery_assign_core's upsert did "on conflict (order_id) do update set
-- accept_status='pending', status='assigned', rejected_at=null" and looked at
-- nothing else. Assigning an already-delivered order flipped it back to
-- 'assigned' while delivered_at, proof_method, proof_photo_path,
-- otp_verified_at and handover_at stayed in place — the order re-entered a run
-- as an open stop carrying somebody else's completed proof.
--
-- Fix: a terminal delivery (delivered / rto) is REFUSED by the ordinary assign
-- path, and the only way past it is delivery_redeliver(), which is explicit,
-- clears every proof field, and logs its own event. Signature of
-- delivery_assign is deliberately unchanged — an added default argument would
-- make the PostgREST overload ambiguous.

insert into public.ui_copy(key, value) values
  ('delivery.assign_terminal_reason', to_jsonb('Already completed — use Re-deliver'::text)),
  ('delivery.redeliver_not_terminal', to_jsonb('That delivery is still open — assign it normally.'::text)),
  ('delivery.redeliver_toast',        to_jsonb('Re-delivery created — the earlier proof is cleared'::text)),
  ('delivery.redeliver_not_found',    to_jsonb('No delivery on that order yet.'::text))
on conflict (key) do nothing;

create or replace function public._delivery_assign_core(
  p_order_ids uuid[], p_partner_id uuid,
  p_actor text default 'engine', p_wave_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  r record; v_ok int := 0; v_blocked jsonb := '[]'::jsonb; v_elig jsonb;
  v_partner delivery_partner_registrations%rowtype; v_run uuid; v_did uuid;
  v_ozone smallint; v_docs jsonb; v_train jsonb; v_existing text;
begin
  select * into v_partner from delivery_partner_registrations
   where id = p_partner_id and is_active and coalesce(is_deleted,false)=false;
  if v_partner.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message','That delivery partner is not active.');
  end if;

  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title',   v_docs->>'block_title',
      'message', v_docs->>'block_message',
      'docs',    v_docs->'docs');
  end if;

  v_train := public.delivery_training_state(p_partner_id);
  if coalesce((v_train->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','training_pending',
      'title',   v_train->>'block_title',
      'message', v_train->>'block_message',
      'modules', v_train->'modules');
  end if;

  select id into v_run from delivery_runs
   where partner_id = p_partner_id
     and run_date = (now() at time zone 'Asia/Kolkata')::date
     and status in ('planned','started')
   order by created_at desc limit 1;
  if v_run is null then
    insert into delivery_runs(partner_id, zone_id) values (p_partner_id, v_partner.zone_id)
    returning id into v_run;
  end if;

  for r in select unnest(p_order_ids) as oid loop
    -- gap #100: a finished delivery is never silently reopened.
    select status into v_existing from deliveries where order_id = r.oid;
    if v_existing in ('delivered','rto') then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason', public.uic('delivery.assign_terminal_reason',
                                          'Already completed — use Re-deliver'));
      continue;
    end if;

    select coalesce(o.zone_id, pp.zone_id) into v_ozone
    from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id = r.oid;

    if v_partner.zone_id is not null and v_ozone is not null
       and v_partner.zone_id <> v_ozone then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason','Different zone — this partner works another zone');
      continue;
    end if;

    v_elig := public.delivery_eligibility(r.oid);
    if coalesce((v_elig->>'can_assign')::boolean,false) is not true then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason', v_elig->>'blocked_label');
      continue;
    end if;

    insert into deliveries(order_id, run_id, partner_id, assigned_by, assigned_at,
                           accept_status, status, qr_token, lat, lng, zone_id, wave_id)
    select r.oid, v_run, p_partner_id, auth.uid(), now(), 'pending', 'assigned',
           encode(gen_random_bytes(9),'hex'), pp.latitude, pp.longitude, v_ozone,
           p_wave_id
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
    where o.id = r.oid
    on conflict (order_id) do update
      set run_id = excluded.run_id, partner_id = excluded.partner_id,
          assigned_by = excluded.assigned_by, assigned_at = now(),
          accept_status = 'pending', status = 'assigned',
          rejected_at = null, reject_reason = null,
          qr_token = coalesce(deliveries.qr_token, excluded.qr_token),
          lat = excluded.lat, lng = excluded.lng, zone_id = excluded.zone_id,
          wave_id = coalesce(excluded.wave_id, deliveries.wave_id)
    returning id into v_did;

    insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
    values (v_did, r.oid, p_partner_id, 'assigned', p_actor);

    -- gap #114: the rider is told, on the same transaction that assigns them.
    perform public._delivery_notify_assigned(v_did);
    v_ok := v_ok + 1;
  end loop;

  update delivery_runs set total_stops =
    (select count(distinct coalesce(stop_group, 0)) from deliveries where run_id = v_run)
   where id = v_run;

  return jsonb_build_object('ok', true, 'assigned', v_ok, 'run_id', v_run,
    'delivery_id', v_did,
    'partner_name', coalesce(v_partner.full_name,''),
    'blocked', v_blocked,
    'title', 'Assigned ' || v_ok || case when v_ok = 1 then ' order' else ' orders' end);
end $function$;

-- The explicit way past the guard. Clears every proof field, so a re-attempt
-- can never inherit the previous attempt's photo, OTP or handover.
create or replace function public.delivery_redeliver(p_order_id uuid, p_partner_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare d deliveries%rowtype;
begin
  if public.partner_scope_orders(array[p_order_id], 'partner.assign_delivery', 'write')
     not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public.uic('delivery.redeliver_not_found','No delivery on that order yet.'));
  end if;
  if d.status not in ('delivered','rto') then
    return jsonb_build_object('ok',false,'error','not_terminal',
      'message', public.uic('delivery.redeliver_not_terminal',
                            'That delivery is still open — assign it normally.'));
  end if;

  insert into delivery_events(delivery_id, order_id, partner_id, event, note, actor)
  values (d.id, d.order_id, d.partner_id, 'redeliver_reset',
          'previous attempt closed as ' || d.status,
          coalesce(auth.jwt()->>'email','admin'));

  update deliveries
     set status='pending_reassign', delivered_at=null, delivered_lat=null, delivered_lng=null,
         proof_method=null, proof_photo_path=null, signature_path=null, receiver_name=null,
         otp_code=null, otp_sent_at=null, otp_verified_at=null,
         handover_at=null, handover_by=null, handover_to=null,
         handover_by_name=null, handover_to_name=null,
         handover_lat=null, handover_lng=null, handover_method=null,
         delivered_qty=null, returned_qty=null, partial_note=null,
         rto_at=null, rto_received_at=null, arrived_at=null, arrival_notified_at=null,
         fail_reason=null, next_attempt_on=null
   where id = d.id;

  return public._delivery_assign_core(array[p_order_id], p_partner_id,
           coalesce(auth.jwt()->>'email','admin'), null)
       || jsonb_build_object('redeliver', true,
            'message', public.uic('delivery.redeliver_toast',
                                  'Re-delivery created — the earlier proof is cleared'));
end $function$;

grant execute on function public.delivery_redeliver(uuid, uuid) to authenticated;

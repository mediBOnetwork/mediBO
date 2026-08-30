-- CHANGE #309 step 6b — the document gate on BOTH assignment doors, plus
-- custody reset on reassignment. Both definitions are the live ones with
-- surgical edits, not retyped copies.

CREATE OR REPLACE FUNCTION public.delivery_assign(p_order_ids uuid[], p_partner_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record; v_ok int := 0; v_blocked jsonb := '[]'::jsonb; v_elig jsonb;
  v_partner delivery_partner_registrations%rowtype; v_run uuid; v_did uuid;
  v_ozone smallint; v_actor text := coalesce(auth.jwt() ->> 'email','admin');
  v_docs jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into v_partner from delivery_partner_registrations
   where id = p_partner_id and is_active and coalesce(is_deleted,false)=false;
  if v_partner.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message','That delivery partner is not active.');
  end if;

  -- CHANGE #309 (6): an expired licence, insurance or RC blocks assignment.
  -- Checked here, at the door, rather than in the admin UI: delivery_assign is
  -- reachable from the queue screen, the suggest-partner flow and the API, and
  -- a rule that only lives in one screen is not a rule.
  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title',   v_docs->>'block_title',
      'message', v_docs->>'block_message',
      'docs',    v_docs->'docs');
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
    select coalesce(o.zone_id, pp.zone_id) into v_ozone
    from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id = r.oid;

    -- a delivery may never cross a zone boundary
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
                           accept_status, status, qr_token, lat, lng, zone_id)
    select r.oid, v_run, p_partner_id, auth.uid(), now(), 'pending', 'assigned',
           encode(gen_random_bytes(9),'hex'), pp.latitude, pp.longitude, v_ozone
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
    where o.id = r.oid
    on conflict (order_id) do update
      set run_id = excluded.run_id, partner_id = excluded.partner_id,
          assigned_by = excluded.assigned_by, assigned_at = now(),
          accept_status = 'pending', status = 'assigned',
          rejected_at = null, reject_reason = null,
          qr_token = coalesce(deliveries.qr_token, excluded.qr_token),
          lat = excluded.lat, lng = excluded.lng, zone_id = excluded.zone_id
    returning id into v_did;

    insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
    values (v_did, r.oid, p_partner_id, 'assigned', v_actor);
    v_ok := v_ok + 1;
  end loop;

  update delivery_runs set total_stops =
    (select count(distinct coalesce(stop_group, 0)) from deliveries where run_id = v_run)
   where id = v_run;

  return jsonb_build_object('ok', true, 'assigned', v_ok, 'run_id', v_run,
    'partner_name', coalesce(v_partner.full_name,''),
    'blocked', v_blocked,
    'title', 'Assigned ' || v_ok || case when v_ok = 1 then ' order' else ' orders' end);
end $function$

;

CREATE OR REPLACE FUNCTION public.delivery_reassign(p_delivery_id uuid, p_partner_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_run uuid; v_docs jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into d from deliveries where id=p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if d.status='delivered' then
    return jsonb_build_object('ok',false,'error','already_delivered','message','Already delivered.');
  end if;

  -- CHANGE #309 (6): the same document gate as delivery_assign. Reassignment is
  -- the other door into a rider's run, and a rule with one door open is not a
  -- rule. A reassignment that also CLEARS custody resets handover_at below, so
  -- the new rider must scan the parcel for themselves.
  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title',   v_docs->>'block_title',
      'message', v_docs->>'block_message',
      'docs',    v_docs->'docs');
  end if;

  select id into v_run from delivery_runs
   where partner_id=p_partner_id and run_date=(now() at time zone 'Asia/Kolkata')::date
     and status in ('planned','started') order by created_at desc limit 1;
  if v_run is null then
    insert into delivery_runs(partner_id) values (p_partner_id) returning id into v_run;
  end if;

  update deliveries set partner_id=p_partner_id, run_id=v_run, accept_status='pending',
         status='assigned', seq=null, accepted_at=null, rejected_at=null, reject_reason=null,
         -- CHANGE #309 (1): custody is personal. Handing the stop to a different
         -- rider clears the handover, so the parcel is scanned again by whoever
         -- actually takes it — otherwise rider B inherits rider A's alibi.
         handover_at=null, handover_by=null, handover_to=null,
         handover_by_name=null, handover_to_name=null, handover_method=null
   where id=p_delivery_id;
  insert into delivery_events(delivery_id,order_id,partner_id,event,note,actor)
  values (p_delivery_id,d.order_id,p_partner_id,'reassigned',
          'from '||coalesce(d.partner_id::text,'-'),coalesce(auth.jwt()->>'email','admin'));
  return jsonb_build_object('ok',true,'run_id',v_run,'message','Reassigned');
end $function$

;

-- CMD #454 — feature_gaps #102
-- "Nothing restocks or refunds on return-to-origin."
--
-- delivery_rto_receive ran one UPDATE and one event insert. Now the parcel
-- coming back has consequences: every still-owed line is returned through the
-- returns engine (credit) and put back on the shelf (stock), the order is moved
-- out of 'shipped' so it is not counted as delivered, and the customer is told.
-- delivery_finish_run's bulk path stops being silent as well.

insert into public.wa_event_routes(event_key, label, description, audience, enabled,
                                   push_enabled, push_title, push_body)
values ('delivery_rto', 'Order returned to origin',
        'The parcel came back undelivered — the customer is told and a credit is raised.',
        'customer', true, true,
        'Your order came back', 'It could not be delivered and is back with us. A credit note has been raised.')
on conflict (event_key) do nothing;

create or replace function public.delivery_rto_receive(p_delivery_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  d deliveries%rowtype; v_lines jsonb; v_ret jsonb;
begin
  if public.partner_scope_delivery(p_delivery_id, 'partner.assign_delivery', 'write')
     not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into d from deliveries where id=p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  -- Already checked back in? Idempotent — say so and change nothing.
  if d.rto_received_at is not null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('delivery.rto_done',
        'Parcel checked back in — stock returned and a credit raised'));
  end if;

  update deliveries set status='rto', rto_at=coalesce(rto_at,now()), rto_received_at=now()
   where id=p_delivery_id;

  -- every line still owed on this order is physically back in the warehouse
  select coalesce(jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'qty', q.returnable)), '[]'::jsonb)
    into v_lines
    from order_items oi
    cross join lateral (select public._return_returnable_qty(oi.id) as returnable) q
   where oi.order_id = d.order_id
     and coalesce(oi.fulfillment_state,'') <> 'cancelled'
     and q.returnable > 0;

  v_ret := public._delivery_return_lines(p_delivery_id, v_lines, 'rto_undelivered',
             public.uic('delivery.rto_customer_title','Your order came back'), null);

  -- the order stops counting as shipped
  update orders
     set fulfillment_status = 'returned', shipped_at = null
   where id = d.order_id;

  insert into delivery_events(delivery_id,order_id,partner_id,event,note,actor)
  values (p_delivery_id,d.order_id,d.partner_id,'rto_received',
          trim_scale(coalesce((v_ret->>'returned_qty')::numeric,0))||' unit(s) back to stock',
          coalesce(auth.jwt()->>'email','admin'));

  begin
    perform public.wa_notify_event('delivery_rto', null, '{}'::jsonb, null, d.order_id, null, null);
  exception when others then
    perform public._wa_log_attempt('delivery_rto', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok',true,'returns',v_ret,
    'message', public.uic('delivery.rto_done',
      'Parcel checked back in — stock returned and a credit raised'));
end $function$;

-- The bulk path was the quieter half of the same defect: it flipped every open
-- stop to 'rto' with no event at all, so nothing downstream could even see it.
create or replace function public.delivery_finish_run(p_run_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_run uuid; v_partner uuid; v_left int; r record;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  select coalesce(p_run_id, (select id from delivery_runs
      where partner_id=v_partner and status='started' order by created_at desc limit 1)) into v_run;
  if v_run is null then return jsonb_build_object('ok',false,'error','no_run'); end if;
  if not public._delivery_run_owned(v_run) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public.uic('delivery.not_your_run','This trip belongs to another rider.'));
  end if;

  select count(*) into v_left from deliveries
   where run_id=v_run and status in ('assigned','out_for_delivery');
  update delivery_runs set status='completed', completed_at=now() where id=v_run;

  for r in select id, order_id, partner_id from deliveries
            where run_id=v_run and status in ('assigned','out_for_delivery')
  loop
    update deliveries set status='rto', rto_at=now() where id = r.id;
    insert into delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (r.id, r.order_id, r.partner_id, 'rto',
            'trip finished with the parcel still on board', 'system');
  end loop;

  return jsonb_build_object('ok',true,'run_id',v_run,'returned',v_left,
    'message', case when v_left=0 then 'Trip completed'
                    else 'Trip completed — ' || v_left || ' parcel(s) marked for return' end);
end $function$;

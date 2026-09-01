-- CMD #454 — min(uuid) does not exist; pick the single line with array_agg.
create or replace function public.delivery_partial(
  p_delivery_id uuid, p_delivered_qty integer, p_returned_qty integer,
  p_note text default null, p_lat numeric default null, p_lng numeric default null,
  p_photo text default null, p_receiver text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare d deliveries%rowtype; v_lines int; v_item uuid;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if coalesce(p_returned_qty,0) <= 0 then
    if not exists(select 1 from delivery_partner_registrations
                   where id = d.partner_id and user_id = auth.uid())
       and not public._is_admin() then
      return jsonb_build_object('ok',false,'error','not_authorized');
    end if;
    if nullif(btrim(coalesce(p_photo,'')),'') is null then
      return jsonb_build_object('ok',false,'error','photo_required',
        'title','Photo needed','message','A partial handover must be photographed.');
    end if;
    update deliveries set delivered_qty = p_delivered_qty, returned_qty = 0,
           partial_note = nullif(btrim(coalesce(p_note,'')),'')
     where id = p_delivery_id;
    return public._delivery_complete(p_delivery_id,'photo',p_lat,p_lng,p_receiver,p_photo);
  end if;

  select count(*), (array_agg(id order by created_at, id))[1]
    into v_lines, v_item
    from order_items
   where order_id = d.order_id and coalesce(fulfillment_state,'') <> 'cancelled';

  if v_lines <> 1 then
    return jsonb_build_object('ok', false, 'error', 'lines_required',
      'message', public.uic('delivery.partial_lines_required',
                            'Tell us which items are coming back.'));
  end if;

  return public.delivery_partial_lines(
    p_delivery_id,
    jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'qty', p_returned_qty)),
    p_note, p_lat, p_lng, p_photo, p_receiver, 'refused_at_door');
end $function$;

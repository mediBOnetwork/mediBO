-- CMD #454 — feature_gaps #101 and #102
--
-- #101 "A partial delivery records two numbers on the parcel and returns nothing
--      to stock": delivery_partial wrote delivered_qty / returned_qty — two
--      scalars on the deliveries row — then closed the stop as 'delivered'. A
--      12-line order returning 3 strips was stored as "9/3" with a free-text
--      note. Because the stop was 'delivered', delivery_rto_receive could never
--      touch it, so nothing ever came back to stock or to the bill.
-- #102 "Nothing restocks or refunds on return-to-origin": delivery_rto_receive
--      only set status='rto' and wrote one event. No inventory movement, no
--      order state change, no credit, no word to the customer. And
--      delivery_finish_run bulk-RTO'd every open stop without even an event row.
--
-- Both are the SAME missing edge, so both are fixed by the SAME core, and that
-- core reuses the returns engine that already exists (_order_return_add_core →
-- order_return_approve → credit_total → gst_ledger_build_credit_notes) rather
-- than inventing a second money path.

insert into public.order_reason_option(scope, code, label, sort, active, requires_photo, tone, customer_visible)
values ('return','refused_at_door','Refused at the door', 70, true, true,  'warning', true),
       ('return','rto_undelivered','Returned to origin — never handed over', 71, true, false, 'danger', true)
on conflict (scope, code) do update set label = excluded.label, active = true;

insert into public.ui_copy(key, value) values
  ('delivery.partial_lines_required', to_jsonb('Tell us which items are coming back.'::text)),
  ('delivery.partial_line_not_on_order', to_jsonb('That item is not on this order.'::text)),
  ('delivery.rto_done', to_jsonb('Parcel checked back in — stock returned and a credit raised'::text)),
  ('delivery.rto_customer_title', to_jsonb('Your order came back'::text)),
  ('delivery.restock_note', to_jsonb('returned from delivery'::text))
on conflict (key) do nothing;

-- ── restock: one line's quantity goes back on the shelf ──────────────────────
create or replace function public._delivery_restock_line(
  p_order_item_id uuid, p_qty numeric, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_item order_items%rowtype; v_lot bigint; v_note text;
begin
  if coalesce(p_qty,0) <= 0 then
    return jsonb_build_object('ok', false, 'error', 'qty_invalid');
  end if;
  select * into v_item from order_items where id = p_order_item_id;
  if v_item.id is null then
    return jsonb_build_object('ok', false, 'error', 'line_not_found');
  end if;
  v_note := coalesce(nullif(btrim(coalesce(p_note,'')),''),
                     public.uic('delivery.restock_note','returned from delivery'));

  if v_item.stock_lot_id is not null then
    -- it left this lot; it goes back to the same lot, same batch, same expiry
    update stock_lot
       set qty_out = greatest(coalesce(qty_out,0) - p_qty, 0),
           status  = case when qty_in - greatest(coalesce(qty_out,0) - p_qty, 0) > 0
                          then 'available' else status end,
           updated_at = now()
     where id = v_item.stock_lot_id
    returning id into v_lot;
  else
    -- it came straight from a supplier: it becomes a lot of its own, so the
    -- shelf and stock_on_hand() can see it
    insert into stock_lot(product_id, product_name, batch_no, expiry, supplier_name,
                          source_kind, source_order_id, source_order_item_id,
                          qty_in, qty_out, trade_rate, received_at, zone_id, status, note)
    values (v_item.product_id, v_item.product_name, v_item.batch_no, v_item.expiry,
            nullif(btrim(coalesce(v_item.assigned_supplier,'')),''),
            'delivery_return', v_item.order_id, v_item.id,
            p_qty, 0, v_item.price, now(), v_item.zone_id, 'available', v_note)
    returning id into v_lot;
  end if;

  insert into stock_movement(lot_id, kind, qty, order_id, order_item_id, actor, note)
  values (v_lot, 'return_in', p_qty, v_item.order_id, v_item.id,
          coalesce(auth.uid()::text, 'system'), v_note);

  return jsonb_build_object('ok', true, 'lot_id', v_lot, 'qty', p_qty);
end $function$;

-- ── the shared core: lines come back, stock moves, a credit is raised ────────
create or replace function public._delivery_return_lines(
  p_delivery_id uuid, p_lines jsonb, p_reason_code text,
  p_note text default null, p_photo text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  d deliveries%rowtype; l jsonb; v_item uuid; v_qty numeric;
  v_add jsonb; v_stock jsonb; v_out jsonb := '[]'::jsonb;
  v_total numeric := 0; v_credit numeric := 0;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_item := nullif(l->>'order_item_id','')::uuid;
    v_qty  := coalesce((l->>'qty')::numeric, 0);
    if v_item is null or v_qty <= 0 then continue; end if;

    if not exists (select 1 from order_items where id = v_item and order_id = d.order_id) then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'order_item_id', v_item, 'ok', false, 'error', 'line_not_on_order',
        'message', public.uic('delivery.partial_line_not_on_order','That item is not on this order.')));
      continue;
    end if;

    -- the credit, through the engine that already owns return money
    v_add := public._order_return_add_core(
               d.order_id, v_item, v_qty, p_reason_code, null,
               p_note, p_photo, null, null, auth.uid(), 'delivery');

    -- the stock, whether or not the credit was accepted (goods are physically back)
    v_stock := public._delivery_restock_line(v_item, v_qty, p_note);

    if coalesce((v_add->>'ok')::boolean, false) then
      v_credit := v_credit + coalesce((v_add->'preview'->>'total')::numeric, 0);
    end if;
    v_total := v_total + v_qty;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'order_item_id', v_item, 'qty', v_qty,
      'ok', coalesce((v_add->>'ok')::boolean, false),
      'return_id', v_add->>'id',
      'error', v_add->>'error',
      'message', v_add->>'message',
      'credit', v_add->'preview',
      'restock', v_stock));
  end loop;

  return jsonb_build_object('ok', true, 'lines', v_out,
    'returned_qty', v_total, 'credit_total', v_credit);
end $function$;

-- ── #101: the rider records WHICH items came back ────────────────────────────
create or replace function public.delivery_partial_lines(
  p_delivery_id uuid, p_lines jsonb, p_note text default null,
  p_lat numeric default null, p_lng numeric default null,
  p_photo text default null, p_receiver text default null,
  p_reason_code text default 'refused_at_door')
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare d deliveries%rowtype; v_res jsonb; v_ret jsonb; v_delivered numeric;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if nullif(btrim(coalesce(p_photo,'')),'') is null then
    return jsonb_build_object('ok',false,'error','photo_required',
      'title','Photo needed','message','A partial handover must be photographed.');
  end if;
  if coalesce(jsonb_array_length(coalesce(p_lines,'[]'::jsonb)),0) = 0 then
    return jsonb_build_object('ok',false,'error','lines_required',
      'message', public.uic('delivery.partial_lines_required',
                            'Tell us which items are coming back.'));
  end if;

  v_ret := public._delivery_return_lines(p_delivery_id, p_lines, p_reason_code,
             nullif(btrim(coalesce(p_note,'')),''), p_photo);

  select greatest(coalesce(sum(quantity),0) - coalesce((v_ret->>'returned_qty')::numeric,0), 0)
    into v_delivered from order_items
   where order_id = d.order_id and coalesce(fulfillment_state,'') <> 'cancelled';

  update deliveries
     set delivered_qty = v_delivered,
         returned_qty  = coalesce((v_ret->>'returned_qty')::numeric,0),
         partial_note  = nullif(btrim(coalesce(p_note,'')),'')
   where id = p_delivery_id;

  v_res := public._delivery_complete(p_delivery_id,'photo',p_lat,p_lng,p_receiver,p_photo);

  insert into delivery_events(delivery_id,order_id,partner_id,event,note,lat,lng,actor)
  values (p_delivery_id,d.order_id,d.partner_id,'partial',
          trim_scale(v_delivered)||' delivered / '||trim_scale(coalesce((v_ret->>'returned_qty')::numeric,0))||' returned',
          p_lat,p_lng, coalesce(auth.jwt()->>'email','rider'));

  return v_res || jsonb_build_object('partial', true, 'returns', v_ret,
    'message', public._cf('delivery.partial_recorded',
                 jsonb_build_object('qty', trim_scale(coalesce((v_ret->>'returned_qty')::numeric,0))::text)));
end $function$;

-- The two-scalar call stays, but it can no longer pretend to know which lines
-- came back: with exactly one billable line it derives it, otherwise it names
-- the RPC that can.
create or replace function public.delivery_partial(
  p_delivery_id uuid, p_delivered_qty integer, p_returned_qty integer,
  p_note text default null, p_lat numeric default null, p_lng numeric default null,
  p_photo text default null, p_receiver text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare d deliveries%rowtype; v_lines int; v_item uuid;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  select count(*), min(id) into v_lines, v_item from order_items
   where order_id = d.order_id and coalesce(fulfillment_state,'') <> 'cancelled';

  if coalesce(p_returned_qty,0) > 0 and v_lines <> 1 then
    return jsonb_build_object('ok', false, 'error', 'lines_required',
      'message', public.uic('delivery.partial_lines_required',
                            'Tell us which items are coming back.'));
  end if;

  return public.delivery_partial_lines(
    p_delivery_id,
    case when coalesce(p_returned_qty,0) > 0
         then jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'qty', p_returned_qty))
         else '[]'::jsonb end,
    p_note, p_lat, p_lng, p_photo, p_receiver, 'refused_at_door');
end $function$;

grant execute on function public.delivery_partial_lines(uuid, jsonb, text, numeric, numeric, text, text, text) to authenticated;

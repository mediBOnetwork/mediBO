-- CMD #454 — issue auto-solved while proving gaps #101/#102.
-- stock_lot carries a unique key on (source_kind, source_order_item_id), so a
-- line that comes back twice (a partial today, the rest on the RTO tomorrow)
-- raised 23505 on the second return and lost the goods. The return lot is now
-- upserted: the second return ADDS to the lot the first one opened.
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
    update stock_lot
       set qty_out = greatest(coalesce(qty_out,0) - p_qty, 0),
           status  = case when qty_in - greatest(coalesce(qty_out,0) - p_qty, 0) > 0
                          then 'available' else status end,
           updated_at = now()
     where id = v_item.stock_lot_id
    returning id into v_lot;
  else
    insert into stock_lot(product_id, product_name, batch_no, expiry, supplier_name,
                          source_kind, source_order_id, source_order_item_id,
                          qty_in, qty_out, trade_rate, received_at, zone_id, status, note)
    values (v_item.product_id, v_item.product_name, v_item.batch_no, v_item.expiry,
            nullif(btrim(coalesce(v_item.assigned_supplier,'')),''),
            'delivery_return', v_item.order_id, v_item.id,
            p_qty, 0, v_item.price, now(), v_item.zone_id, 'available', v_note)
    on conflict (source_kind, source_order_item_id) where source_order_item_id is not null do update
      set qty_in = stock_lot.qty_in + excluded.qty_in,
          status = 'available', updated_at = now()
    returning id into v_lot;
  end if;

  insert into stock_movement(lot_id, kind, qty, order_id, order_item_id, actor, note)
  values (v_lot, 'return_in', p_qty, v_item.order_id, v_item.id,
          coalesce(auth.uid()::text, 'system'), v_note);

  return jsonb_build_object('ok', true, 'lot_id', v_lot, 'qty', p_qty);
end $function$;

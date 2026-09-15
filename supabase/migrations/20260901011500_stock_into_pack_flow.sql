-- CHANGE #396 part 2c — stock feeds the bag/pack flow.
--
-- The inquiry engine already computes an inquiry's quantity from the order
-- lines that are NOT at_warehouse / packed / received (see
-- inquiry_start_batch_for_order). So the cleanest way to make the next
-- matching order consume existing stock BEFORE a supplier is asked is not to
-- rewrite the waterfall — it is to mark the line received from stock. The
-- quantity then leaves the inquiry by itself, and the line flows on into bag
-- allocation and Pack exactly like a supplier receipt.

alter table public.order_items add column if not exists stock_lot_id bigint;

insert into public.ui_copy (key, value) values
  ('stock.supplier_label', to_jsonb('mediBO stock'::text)),
  ('stock.precheck_title', to_jsonb('Fill from existing stock first'::text)),
  ('stock.precheck_none',  to_jsonb('No item on this order matches warehouse stock.'::text)),
  ('stock.precheck_some',  to_jsonb('{matched} of {open} items can be filled from stock before any supplier is asked.'::text)),
  ('stock.filled_toast',   to_jsonb('Filled from stock — this quantity leaves the supplier inquiry.'::text)),
  ('stock.fill_short',     to_jsonb('Not enough in that lot.'::text)),
  ('stock.fill_notfound',  to_jsonb('That lot is no longer available.'::text))
on conflict (key) do nothing;
-- stock_precheck_for_order + stock_fill_item follow (applied live; definitions below)

create or replace function public.stock_precheck_for_order(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_rows jsonb; v_open int; v_match int;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.admins_only','Admins only.'));
  end if;

  select count(*)::int into v_open
    from order_items i
   where i.order_id = p_order_id
     and coalesce(i.fulfillment_state,'') <> 'cancelled'
     and coalesce(i.at_warehouse,false) = false
     and coalesce(i.packed,false) = false
     and coalesce(i.received_qty,0) < coalesce(i.quantity,0);

  select jsonb_agg(x order by ord), count(*)::int into v_rows, v_match from (
    select i.id as ord,
      jsonb_build_object(
        'order_item_id', i.id,
        'product_id',    i.product_id,
        'product_name',  i.product_name,
        'need_qty',      greatest(coalesce(i.quantity,0) - coalesce(i.received_qty,0), 0),
        'need_label',    trim(to_char(greatest(coalesce(i.quantity,0) - coalesce(i.received_qty,0),0),'FM999999990.##')),
        'lots', (select jsonb_agg(jsonb_build_object(
                    'lot_id', l.id,
                    'qty', l.qty_available,
                    'qty_label', trim(to_char(l.qty_available,'FM999999990.##')),
                    'age_label', case when l.age_days = 1 then '1 day' else l.age_days || ' days' end,
                    'source_label', public._stk_copy('stock.src_' || l.source_kind, l.source_kind),
                    'batch_label', coalesce(nullif(btrim(l.batch_no),''),
                                    public._stk_copy('stock.batch_unknown','Batch not recorded')),
                    'value_display', public._stk_money(l.value_at_trade),
                    'cta', public._stk_copy('stock.consume_cta','Fill from stock'))
                    order by l.age_days desc nulls last)
                  from stock_lot_v l
                 where l.status='available' and l.qty_available > 0
                   and l.product_id = i.product_id)) as x
      from order_items i
     where i.order_id = p_order_id
       and coalesce(i.fulfillment_state,'') <> 'cancelled'
       and coalesce(i.at_warehouse,false) = false
       and coalesce(i.packed,false) = false
       and coalesce(i.received_qty,0) < coalesce(i.quantity,0)
       and exists (select 1 from stock_lot_v l
                    where l.status='available' and l.qty_available > 0
                      and l.product_id = i.product_id)
  ) s;

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'title', public._stk_copy('stock.precheck_title','Fill from existing stock first'),
    'has_match', coalesce(v_match,0) > 0,
    'open_items', v_open,
    'matched_items', coalesce(v_match,0),
    'headline', case when coalesce(v_match,0) = 0
                     then public._stk_copy('stock.precheck_none','')
                     else replace(replace(public._stk_copy('stock.precheck_some',
                            '{matched} of {open} items can be filled from stock.'),
                            '{matched}', coalesce(v_match,0)::text), '{open}', v_open::text) end,
    'items', coalesce(v_rows,'[]'::jsonb));
end $fn$;

create or replace function public.stock_fill_item(
  p_order_item_id uuid, p_lot_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_lot record; v_item record; v_qty numeric;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.admins_only','Admins only.'));
  end if;

  select l.*, greatest(l.qty_in - l.qty_out,0) as avail into v_lot
    from stock_lot l where l.id = p_lot_id for update;
  if v_lot.id is null or v_lot.status <> 'available' or v_lot.avail <= 0 then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.fill_notfound','That lot is no longer available.'));
  end if;

  select i.* into v_item from order_items i where i.id = p_order_item_id;
  if v_item.id is null then
    return jsonb_build_object('ok', false, 'message', 'Order line not found.');
  end if;

  v_qty := least(
    coalesce(nullif(p_qty,0), greatest(coalesce(v_item.quantity,0) - coalesce(v_item.received_qty,0), 0)),
    v_lot.avail,
    greatest(coalesce(v_item.quantity,0) - coalesce(v_item.received_qty,0), 0));
  if coalesce(v_qty,0) <= 0 then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.fill_short','Not enough in that lot.'));
  end if;

  update stock_lot
     set qty_out = qty_out + v_qty,
         status  = case when qty_in - (qty_out + v_qty) > 0 then 'available' else 'consumed' end,
         updated_at = now()
   where id = p_lot_id;

  insert into stock_movement (lot_id, kind, qty, order_id, order_item_id, actor, note)
  values (p_lot_id, 'consume', v_qty, v_item.order_id, p_order_item_id,
          coalesce(auth.uid()::text,'admin'), 'filled from stock');

  update order_items
     set received_qty  = coalesce(received_qty,0) + v_qty,
         at_warehouse  = true,
         fulfillment_state = 'received',
         received_at   = coalesce(received_at, now()),
         received_by   = 'stock',
         stock_lot_id  = p_lot_id,
         assigned_supplier = coalesce(nullif(btrim(assigned_supplier),''),
                                      public._stk_copy('stock.supplier_label','mediBO stock'))
   where id = p_order_item_id;

  update inquiry i
     set quantity = coalesce((select sum(oi.quantity) from order_items oi
                               where oi.inquiry_id = i.id
                                 and oi.fulfillment_state <> 'cancelled'
                                 and coalesce(oi.at_warehouse,false) = false
                                 and coalesce(oi.packed,false) = false
                                 and oi.fulfillment_state <> 'received'), 0)
   where i.id = v_item.inquiry_id;

  return jsonb_build_object('ok', true, 'qty', v_qty, 'lot_id', p_lot_id,
    'order_item_id', p_order_item_id,
    'message', public._stk_copy('stock.filled_toast','Filled from stock.'));
end $fn$;

grant execute on function public.stock_precheck_for_order(uuid) to authenticated;
grant execute on function public.stock_fill_item(uuid,bigint,numeric) to authenticated;

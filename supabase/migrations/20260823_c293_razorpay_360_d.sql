-- CHANGE #293 — Part D: order placement knows which of the three paths it is.
--
-- #291 shipped the QR but never touched checkout, so "Pay & Place Order" did
-- not exist and an admin acting as a customer got no QR at all. Both order
-- entry points now return checkout_action() with the order, and the two
-- admin-driven paths push the QR to the customer over WhatsApp themselves.
--
-- placed_by_admin was hardcoded false on the customer entry point even under
-- View As, which contradicted the spec's own definition of the acting-as path.
-- It is now the server-side acting-as signal, the same one my_session() uses.

create or replace function public._place_order_v2_core()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_sess jsonb := public.my_session();
  v_cart jsonb;
  v_cust uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_act  uuid := public.my_acting_as();
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_net numeric; v_id uuid; v_code text;
  v_addr text; v_copy jsonb;
  v_offer_item record;
  v_confirm    jsonb;
  v_has_offers boolean := false;
  v_checkout   jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated'
      using hint = 'Session missing or expired; sign in again and retry.';
  end if;

  if (v_sess->>'can_place_order') is distinct from 'true' then
    raise exception 'order_gate_blocked'
      using hint = coalesce(v_sess->'order_gate'->>'message', 'Ordering is not available.');
  end if;

  v_cart := public.cart_state(null);
  v_items := coalesce(v_cart->'items', '[]'::jsonb);
  if jsonb_array_length(v_items) = 0 then
    raise exception 'empty_cart' using hint = 'No items to order.';
  end if;

  for v_offer_item in
    select ci.offer_listing_id, ci.quantity
    from cart_items ci
    where (case when v_cust is not null then ci.customer_id=v_cust else ci.user_id=v_uid end)
      and ci.offer_listing_id is not null
      and ci.quantity > 0
  loop
    v_has_offers := true;
    v_confirm := public._offer_confirm_qty(v_offer_item.offer_listing_id, v_offer_item.quantity);
    if not (v_confirm->>'ok')::boolean then
      raise exception 'offer_qty_exhausted'
        using hint = 'One or more offers sold out — remove them and retry.',
              detail = v_confirm::text;
    end if;
  end loop;

  v_net := coalesce((v_cart->>'subtotal')::numeric, (v_cart->>'mrp_total')::numeric, 0);

  select * into pp from pharmacy_profiles where id = v_cust;

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id)
  values
    (v_uid, v_cust, coalesce(pp.pharmacy_name,''), v_items, v_net,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending',
     'website',
     -- #293: an admin acting as a customer IS an admin-placed order. It was
     -- hardcoded false, which is the flag the whole payment split keys on.
     (v_act is not null),
     public.next_order_number())
  returning id, order_code into v_id, v_code;

  if v_has_offers then
    update order_items oi
       set assigned_supplier = coalesce(sp.supplier_name, sc.supplier_company,
                                        sc.supplier_name, oi.assigned_supplier)
      from public.supplier_offer_listings sol
      left join supplier_profiles sp
             on sp.user_id = sol.supplier_id
            and coalesce(sp.is_deleted,false) = false
      left join supplier_company sc on sc.supplier_id = sol.supplier_id
     where oi.order_id = v_id
       and oi.offer_listing_id = sol.id;

    update public.offer_reservations r
       set order_id = v_id
     where r.customer_id = v_cust and r.order_id is null
       and r.status = 'consumed'
       and r.listing_id in (select oi.offer_listing_id from order_items oi
                             where oi.order_id = v_id and oi.offer_listing_id is not null);

    update public.offer_near_expiry_disclosures d
       set order_id = v_id
     where d.customer_id = v_cust and d.order_id is null
       and d.listing_id in (select oi.offer_listing_id from order_items oi
                             where oi.order_id = v_id and oi.offer_listing_id is not null);
  end if;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);

  -- #293 — which of the three placement paths is this, and what happens next.
  v_checkout := public.checkout_action();

  -- Acting-as in gateway mode: the admin cannot pay, so the customer gets the
  -- QR on their own phone. A WhatsApp failure must never fail the order.
  if (v_checkout->>'acting_as')::boolean
     and (v_checkout->>'collection_mode') = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object(
    'ok',              true,
    'id',              coalesce(v_id::text,''),
    'order_code',      coalesce(v_code,''),
    'amount',          v_net,
    'amount_display',  public.inr_money(v_net),
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);
end
$function$;

create or replace function public.admin_writeas_place_order_v2(
  p_customer_id uuid, p_product_ids text[] default null::text[])
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_total numeric; v_id uuid; v_code text; v_addr text;
  v_copy jsonb; v_checkout jsonb;
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'forbidden' using hint = 'Only an admin may place an order for a customer.';
  end if;

  select * into pp from pharmacy_profiles where id = p_customer_id;
  if not found then raise exception 'customer_not_found'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  ci.product_id,
           'product_name',coalesce(ci.product_name,''),
           'quantity',    coalesce(ci.quantity,0),
           'price',       coalesce(ci.price,0),
           'mrp',         coalesce(ci.mrp,0),
           'gst_percent', coalesce(ci.gst_percent,0),
           'line_total',  round(coalesce(ci.quantity,0) * coalesce(ci.price,0), 2))), '[]'::jsonb),
         coalesce(sum(round(coalesce(ci.quantity,0) * coalesce(ci.price,0), 2)), 0)
    into v_items, v_total
  from cart_items ci
  where ci.customer_id = p_customer_id
    and coalesce(ci.removed_by_admin,false) = false
    and (p_product_ids is null or ci.product_id = any(p_product_ids));

  if jsonb_array_length(v_items) = 0 then
    raise exception 'no_lines_selected';
  end if;

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id)
  values
    (pp.user_id, p_customer_id, coalesce(pp.pharmacy_name,''), v_items, v_total,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending', 'website', true,
     public.next_order_number())
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where customer_id = p_customer_id
     and (p_product_ids is null or product_id = any(p_product_ids));

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);

  -- Always the admin path: never "Pay & Place", always the WhatsApp QR.
  v_checkout := jsonb_build_object(
    'ok', true,
    'collection_mode', public.payment_collection_mode(),
    'provider', case when public.payment_collection_mode() = 'gateway'
                     then 'razorpay_qr' else 'upi_manual' end,
    'acting_as', true, 'placed_by_admin', true, 'pay_now', false,
    'button_label',  public._rzp_copy('checkout_btn_place'),
    'actingas_note', case when public.payment_collection_mode() = 'gateway'
                          then public._rzp_copy('checkout_actingas_note') else '' end);

  if public.payment_collection_mode() = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', coalesce(v_id::text,''),
    'order_code', coalesce(v_code,''),
    'amount', v_total,
    'amount_display', public.inr_money(v_total),
    'title', coalesce(v_copy->>'title',''),
    'note', coalesce(v_copy->>'note',''),
    'done_label', coalesce(v_copy->>'done_label',''),
    'item_count', jsonb_array_length(v_items),
    'checkout', v_checkout);
end $function$;

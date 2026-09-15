\set ON_ERROR_STOP on
begin;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub','d3684a1d-a695-40e2-b4f0-46bcdaafc6d7','role','authenticated')::text, true);

do $$
declare v_cart jsonb; v_res jsonb; v_pid bigint; v_name text; v_mrp numeric; v_cust uuid;
begin
  v_cust := public.my_customer_id();
  raise notice 'customer_id=%', v_cust;

  select m.id, m.product_name, coalesce(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),'')::numeric,10) into v_pid, v_name, v_mrp
    from public."MEDICINE" m where nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),'')::numeric > 0 order by m.id limit 1;

  insert into public.cart_items(user_id, customer_id, product_id, product_name, quantity, mrp, price, added_by)
  values ('d3684a1d-a695-40e2-b4f0-46bcdaafc6d7', v_cust, v_pid::text, v_name, 2, v_mrp, v_mrp, 'probe');

  v_cart := public.cart_state(null);
  raise notice 'cart items=% units=% mrp_total=%',
    jsonb_array_length(v_cart->'items'), v_cart->>'units', v_cart->>'mrp_total';
  if jsonb_array_length(v_cart->'items') < 1 then raise exception 'PROBE FAIL: cart_state returned no lines'; end if;
  if (v_cart->'items'->0) ? 'offer_listing_id' then raise exception 'PROBE FAIL: cart_state still emits offer keys'; end if;

  perform * from public._cart_unavailable_lines();
  raise notice '_cart_unavailable_lines ran clean';

  v_res := public.place_order_v2();
  if not coalesce((v_res->>'ok')::boolean,false) then
    raise exception 'PROBE FAIL: place_order_v2 -> %', v_res::text;
  end if;
  raise notice 'ORDER PLACED ok code=% amount=% items=%',
    v_res->>'order_code', v_res->>'amount_display', v_res->>'item_count';

  if (select count(*) from public.order_items where order_id = (v_res->>'id')::uuid) < 1 then
    raise exception 'PROBE FAIL: explode_order_items produced no lines';
  end if;
  raise notice 'order_items exploded: %', (select count(*) from public.order_items where order_id=(v_res->>'id')::uuid);

  perform public.inquiry_start_batch_for_order((v_res->>'id')::uuid);
  raise notice 'inquiry_start_batch_for_order ran clean';
  -- oi_rollup_to_inquiry is a trigger fn: it already fired on the order_items
  -- insert above. Exercise the remaining two edited core functions directly.
  perform public._oa_release_and_cancel((v_res->>'id')::uuid, 'probe', 'runner-4');
  if (select status from public.orders where id=(v_res->>'id')::uuid) <> 'cancelled' then
    raise exception 'PROBE FAIL: _oa_release_and_cancel did not cancel';
  end if;
  raise notice '_oa_release_and_cancel ran clean (order cancelled)';
  perform public.rebuild_all_supplier_orders(current_date);
  raise notice 'rebuild_all_supplier_orders ran clean';

  raise notice 'ALL PROBE STEPS GREEN';
end $$;
rollback;

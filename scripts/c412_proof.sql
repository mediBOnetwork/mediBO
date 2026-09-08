-- CMD #412 — end-to-end proof for pharmacy auto-inventory.
--
-- Everything runs inside ONE transaction that ends in ROLLBACK, so proving the
-- delivery trigger costs the live system nothing: no order is really placed, no
-- WhatsApp goes out, no shelf is really written. Run it with
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f scripts/c412_proof.sql
-- and a green run means every assertion below held.
--
-- What it proves, in the spec's own order:
--   1. delivered order -> stock rows carrying batch, expiry and cost
--   2. POS sale        -> FEFO decrement, earliest expiry first
--   3. oversell        -> negative lot, flagged, never refused
--   4. adjustment      -> audited with reason AND the auth user who did it

\set ON_ERROR_STOP on
begin;

-- The signed-in pharmacy for every caller-facing RPC below: the real test
-- customer, so my_customer_id() resolves exactly as it does in the browser.
select set_config('request.jwt.claims',
  json_build_object('sub','371d5289-c2e1-4475-9215-8f603e72ca9e',
                    'email','test.cust1@medibo.in',
                    'role','authenticated')::text, true);

do $$
declare
  v_shop   uuid := '3f1c9a10-4b6e-4c9a-9f22-5a0d7e8b1c33';  -- mediBO Test Pharmacy
  v_order  uuid;
  v_item   uuid;
  v_med    bigint;
  v_name   text;
  v_sale   uuid;
  v_line1  uuid;
  v_lot_a  uuid; v_lot_b uuid;
  v_qty_a  numeric; v_qty_b numeric;
  v_n      integer;
  v_res    jsonb;
  v_home   jsonb;
  v_neg    numeric;
  v_moves  jsonb;
begin
  -- ── 0. a clean slate for this shop, inside the doomed transaction ─────────
  delete from public.pharmacy_stock_move where pharmacy_id = v_shop;
  delete from public.pharmacy_stock       where pharmacy_id = v_shop;

  -- ── 1. A DELIVERED ORDER BECOMES SHELF STOCK ─────────────────────────────
  -- Borrow a real order that already has lines, and point it at the test shop.
  -- An order whose lines already carry a trade rate, because the point of the
  -- proof is that the RATE THE PHARMACY WAS BILLED becomes the cost of the
  -- stock. Nothing here touches `price`: _oi_resolve_price would only re-resolve
  -- it and the fixture would stop being a real bill line.
  select o.id into v_order
    from public.orders o
    join public.order_items i on i.order_id = o.id
   where coalesce(i.unfulfillable,false) = false and i.price > 0
   group by o.id
  having count(*) >= 2
   order by count(*) desc limit 1;
  if v_order is null then raise exception 'PROOF: no priced order to work from'; end if;

  update public.orders set customer_id = v_shop where id = v_order;

  -- #129's columns, filled the way a supplier bill fills them.
  with numbered as (
    select id, row_number() over (order by id) rn
      from public.order_items where order_id = v_order
  )
  update public.order_items oi
     set batch_no = 'BATCH-' || lpad(n.rn::text, 3, '0'),
         expiry   = case when n.rn % 2 = 1 then '09/27' else '03/28' end
    from numbered n where n.id = oi.id;

  -- The rider's proof. The trigger is what runs; nothing here calls the intake
  -- function by hand, because the point is that a delivery does it by itself.
  insert into public.deliveries(order_id, status, delivered_at, proof_method, receiver_name)
  values (v_order, 'delivered', now(), 'otp', 'PROOF');

  select count(*) into v_n from public.pharmacy_stock where pharmacy_id = v_shop;
  if v_n = 0 then
    raise exception 'PROOF 1 FAILED: a delivered order created no shelf stock';
  end if;

  if not exists (select 1 from public.pharmacy_stock
                  where pharmacy_id = v_shop
                    and batch_no like 'BATCH-%' and expiry in ('09/27','03/28')
                    and expiry_on is not null and unit_cost is not null and qty > 0) then
    raise exception 'PROOF 1 FAILED: lots exist but carry no batch/expiry/cost';
  end if;

  if not exists (select 1 from public.pharmacy_stock_move
                  where pharmacy_id = v_shop and kind = 'receipt_order'
                    and ref_kind = 'order_item') then
    raise exception 'PROOF 1 FAILED: no receipt movement was written';
  end if;
  raise notice 'PROOF 1 OK — delivered order created % lot(s) with batch, expiry and cost', v_n;

  -- Re-firing the same delivery must change NOTHING. This is the guarantee that
  -- a retried webhook or a resumed worker cannot double the shelf.
  perform public.pharmacy_stock_ingest_order(v_order);
  select count(*) into v_n from public.pharmacy_stock_move
   where pharmacy_id = v_shop and kind = 'receipt_order';
  if v_n <> (select count(*) from public.order_items
              where order_id = v_order and coalesce(unfulfillable,false) = false
                and coalesce(nullif(packed_qty,0), nullif(received_qty,0), quantity, 0) > 0) then
    raise exception 'PROOF 1 FAILED: re-ingesting the order duplicated movements (% rows)', v_n;
  end if;
  raise notice 'PROOF 1b OK — re-ingesting the same order wrote nothing (% movements)', v_n;

  -- ── 2. A POS SALE LEAVES BY EARLIEST EXPIRY ──────────────────────────────
  -- Two lots of ONE medicine: the later expiry received FIRST, so a FIFO
  -- implementation would take the wrong one and this proof would go red.
  select id, product_name into v_med, v_name from public."MEDICINE" limit 1;

  v_lot_b := public._phs_apply(v_shop, v_med, v_name, '1x10', 'LATE-01', '12/28',
               10, 9.00, 20.00, 'receipt_outside', 'outside',
               null, null, 'proof', 'late-lot');
  v_lot_a := public._phs_apply(v_shop, v_med, v_name, '1x10', 'SOON-01', '01/27',
               4, 8.00, 20.00, 'receipt_outside', 'outside',
               null, null, 'proof', 'soon-lot');

  -- A 6-unit sale: it must empty the 4 that expire in Jan 27 and take 2 from the
  -- Dec 28 lot — never the other way round.
  insert into public.pos_sales(pharmacy_id, fy, invoice_seq, invoice_no, sold_on,
                               payment_mode, net_amount, client_action_id)
  values (v_shop, '2026-27', 9001, 'PROOF/9001', public._phs_today(),
          'cash', 0, gen_random_uuid())
  returning id into v_sale;

  insert into public.pos_sale_lines(sale_id, line_no, medicine_id, product_name,
                                    pack_label, qty, mrp, amount)
  values (v_sale, 1, v_med, v_name, '1x10', 6, 20.00, 120.00)
  returning id into v_line1;

  insert into public.pos_sale_event(sale_id, pharmacy_id, event_type, payload)
  values (v_sale, v_shop, 'sale.completed', jsonb_build_object('proof', true));

  select qty into v_qty_a from public.pharmacy_stock where id = v_lot_a;
  select qty into v_qty_b from public.pharmacy_stock where id = v_lot_b;

  if v_qty_a <> 0 then
    raise exception 'PROOF 2 FAILED: the earliest-expiry lot still holds % (FEFO not applied)', v_qty_a;
  end if;
  if v_qty_b <> 8 then
    raise exception 'PROOF 2 FAILED: the later lot should hold 8, holds %', v_qty_b;
  end if;
  raise notice 'PROOF 2 OK — FEFO drained Jan-27 to 0 and took 2 from Dec-28 (8 left)';

  -- The event carries its own receipt, so the POS screen and #416 can both see
  -- that the shelf was decremented without asking this layer.
  select consumed->'stock' into v_res from public.pos_sale_event
   where sale_id = v_sale and event_type = 'sale.completed';
  if coalesce(v_res->>'ok','false') <> 'true' then
    raise exception 'PROOF 2 FAILED: the sale event was not marked consumed (%)', v_res;
  end if;
  raise notice 'PROOF 2b OK — pos_sale_event.consumed->stock = %', v_res;

  -- ── 3. OVERSELL IS ALLOWED, AND LOUD ─────────────────────────────────────
  -- 20 more of a medicine with 8 on the shelf. The bill must go through and the
  -- shortfall must show up as negative stock, not as a refusal.
  insert into public.pos_sales(pharmacy_id, fy, invoice_seq, invoice_no, sold_on,
                               payment_mode, net_amount, client_action_id)
  values (v_shop, '2026-27', 9002, 'PROOF/9002', public._phs_today(),
          'cash', 0, gen_random_uuid())
  returning id into v_sale;

  insert into public.pos_sale_lines(sale_id, line_no, medicine_id, product_name,
                                    pack_label, qty, mrp, amount)
  values (v_sale, 1, v_med, v_name, '1x10', 20, 20.00, 400.00);

  insert into public.pos_sale_event(sale_id, pharmacy_id, event_type, payload)
  values (v_sale, v_shop, 'sale.completed', jsonb_build_object('proof', true));

  select coalesce(sum(qty),0) into v_neg
    from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med and qty < 0;
  if v_neg >= 0 then
    raise exception 'PROOF 3 FAILED: overselling produced no negative lot';
  end if;
  raise notice 'PROOF 3 OK — oversold by %, recorded as negative stock instead of a refusal', abs(v_neg);

  -- ── 3b. A LINE TYPED BY NAME FINDS THE SHELF ─────────────────────────────
  -- The counter prices a hand-typed line with NO medicine_id, so its key is
  -- name-shaped while a lot that came off a mediBO delivery is id-shaped. Until
  -- pharmacy_stock carried a name_key too, a 9-unit sale walked straight past 6
  -- units sitting right there and invented a negative lot beside them. Caught
  -- on the live seed; pinned here so it cannot come back.
  select id, product_name into v_med, v_name from public."MEDICINE"
   where product_name is not null and btrim(product_name) <> '' offset 7 limit 1;

  v_lot_a := public._phs_apply(v_shop, v_med, v_name, '1x10', 'NAMEKEY-1', '06/28',
               6, 5.00, 11.00, 'opening', 'opening', null, null, 'proof', 'namekey');

  insert into public.pos_sales(pharmacy_id, fy, invoice_seq, invoice_no, sold_on,
                               payment_mode, net_amount, client_action_id)
  values (v_shop, '2026-27', 9003, 'PROOF/9003', public._phs_today(),
          'cash', 0, gen_random_uuid())
  returning id into v_sale;

  -- medicine_id deliberately NULL: this is the hand-typed line.
  insert into public.pos_sale_lines(sale_id, line_no, medicine_id, product_name,
                                    pack_label, qty, mrp, amount)
  values (v_sale, 1, null, v_name, '1x10', 9, 11.00, 99.00);

  insert into public.pos_sale_event(sale_id, pharmacy_id, event_type, payload)
  values (v_sale, v_shop, 'sale.completed', jsonb_build_object('proof', true));

  select qty into v_qty_a from public.pharmacy_stock where id = v_lot_a;
  if v_qty_a <> 0 then
    raise exception 'PROOF 3b FAILED: a name-only sale line ignored the id-keyed lot (still holds %)', v_qty_a;
  end if;
  if (select coalesce(sum(qty),0) from public.pharmacy_stock
       where pharmacy_id = v_shop and name_key = 'n:' || public._norm_name(v_name)) <> -3 then
    raise exception 'PROOF 3b FAILED: the shortfall should be exactly 3';
  end if;
  raise notice 'PROOF 3b OK — a hand-typed line drained the id-keyed lot first, short by exactly 3';

  -- ── 4. THE SCREEN SEES IT, AND SAYS SO ───────────────────────────────────
  v_home := public.pharmacy_stock_home(null, 'all', 40, 0);
  if coalesce(v_home->>'ok','false') <> 'true' then
    raise exception 'PROOF 4 FAILED: pharmacy_stock_home refused the pharmacy: %', v_home;
  end if;
  if v_home->>'negative_note' is null then
    raise exception 'PROOF 4 FAILED: negative stock exists but the screen has no note about it';
  end if;
  if jsonb_array_length(v_home->'rows') = 0 then
    raise exception 'PROOF 4 FAILED: the shelf has stock but the screen renders no rows';
  end if;
  raise notice 'PROOF 4 OK — % row(s), value tile %, negative note: %',
    jsonb_array_length(v_home->'rows'),
    v_home->'tiles'->0->>'value',
    left(v_home->>'negative_note', 60);

  -- The negative filter must isolate exactly the negative lots.
  v_home := public.pharmacy_stock_home(null, 'negative', 40, 0);
  if jsonb_array_length(v_home->'rows') = 0 then
    raise exception 'PROOF 4 FAILED: the negative filter hides the negative lot';
  end if;
  raise notice 'PROOF 4b OK — the negative filter isolates % row(s)',
    jsonb_array_length(v_home->'rows');

  -- ── 5. AN ADJUSTMENT IS AUDITED, WITH A REASON AND A NAME ────────────────
  v_res := public.pharmacy_stock_adjust(v_lot_b, 5, 'damage', 'two strips crushed in the box');
  if coalesce(v_res->>'ok','false') <> 'true' then
    raise exception 'PROOF 5 FAILED: adjustment refused: %', v_res;
  end if;
  select qty into v_qty_b from public.pharmacy_stock where id = v_lot_b;
  if v_qty_b <> 5 then
    raise exception 'PROOF 5 FAILED: adjusted to 5 but the lot holds %', v_qty_b;
  end if;
  if not exists (select 1 from public.pharmacy_stock_move
                  where stock_id = v_lot_b and kind = 'adjust'
                    and reason_code = 'damage'
                    and actor_user_id = '371d5289-c2e1-4475-9215-8f603e72ca9e') then
    raise exception 'PROOF 5 FAILED: the adjustment carries no reason or no actor';
  end if;

  -- A reason is not optional, and neither is a real change.
  v_res := public.pharmacy_stock_adjust(v_lot_b, 3, 'not_a_reason', null);
  if coalesce(v_res->>'ok','true') <> 'false' then
    raise exception 'PROOF 5 FAILED: an unknown reason was accepted';
  end if;
  v_res := public.pharmacy_stock_adjust(v_lot_b, 5, 'damage', null);
  if coalesce(v_res->>'ok','true') <> 'false' then
    raise exception 'PROOF 5 FAILED: a no-op adjustment was accepted';
  end if;

  v_moves := public.pharmacy_stock_moves(v_lot_b, 20);
  if jsonb_array_length(v_moves->'rows') < 3 then
    raise exception 'PROOF 5 FAILED: the batch history is missing movements: %', v_moves;
  end if;
  raise notice 'PROOF 5 OK — adjustment audited (reason + actor), history shows % movement(s)',
    jsonb_array_length(v_moves->'rows');

  -- ── 6. OPENING STOCK, BY CSV, REVIEWED BEFORE IT IS BELIEVED ─────────────
  v_res := public.pharmacy_stock_import_start('csv', null, null);
  if coalesce(v_res->>'ok','false') <> 'true' then
    raise exception 'PROOF 6 FAILED: could not start an import: %', v_res;
  end if;
  v_res := public.pharmacy_stock_import_csv((v_res->>'import_id')::uuid,
E'Product,Batch,Expiry,Qty,Rate,MRP\nDolo 650 Tablet,DL-77,11/27,25,1.20,2.18\n"Azithral 500, Tablet",AZ-11,05/28,6,58.00,74.00\n');
  if jsonb_array_length(v_res->'rows') <> 2 then
    raise exception 'PROOF 6 FAILED: the CSV parsed % rows, expected 2 (quoted comma?)',
      jsonb_array_length(v_res->'rows');
  end if;
  if v_res->>'can_apply' <> 'true' then
    raise exception 'PROOF 6 FAILED: a read CSV is not applyable: %', v_res;
  end if;

  select count(*) into v_n from public.pharmacy_stock where pharmacy_id = v_shop;
  v_res := public.pharmacy_stock_import_apply((v_res->>'import_id')::uuid);
  if coalesce(v_res->>'ok','false') <> 'true' or (v_res->>'rows')::int <> 2 then
    raise exception 'PROOF 6 FAILED: applying the import did not add 2 rows: %', v_res;
  end if;
  if (select count(*) from public.pharmacy_stock where pharmacy_id = v_shop) <> v_n + 2 then
    raise exception 'PROOF 6 FAILED: the shelf did not grow by the imported rows';
  end if;
  raise notice 'PROOF 6 OK — CSV read 2 rows (quoted comma survived) and applied them as opening stock';

  raise notice '════ ALL PROOFS GREEN ════';
end $$;

rollback;

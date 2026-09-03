\set ON_ERROR_STOP on
begin;
do $t$
declare
  v_oi public.order_items%rowtype; v_so public.supplier_orders%rowtype;
  v_ret uuid; v_item uuid; m jsonb; r public.supplier_return%rowtype;
  v_tok text; v_form jsonb; v_sub jsonb; v_deb jsonb; v_no text;
  v_bag_before numeric; v_bag_after numeric; v_rq_after numeric; v_stats jsonb; v_doc jsonb;
begin
  select * into v_oi from public.order_items
   where coalesce(received_qty,0) >= 3 and assigned_supplier = 'Sagar Medicals'
   order by created_at desc limit 1;
  if not found then raise exception 'E2E: no seed order item'; end if;

  select * into v_so from public.supplier_orders
   where supplier_name = v_oi.assigned_supplier
     and coalesce(order_date,(created_at at time zone 'Asia/Kolkata')::date) = v_oi.order_date
   limit 1;

  insert into public.supplier_return
    (zone_id, supplier_id, supplier_name, supplier_order_id, status, is_synthetic)
  values (coalesce(v_so.zone_id, 1), coalesce(v_so.supplier_id,
            (select id from public.supplier_profiles where lower(supplier_name)=lower(v_oi.assigned_supplier) limit 1)),
          v_oi.assigned_supplier, v_so.id, 'drafted', true)
  returning id into v_ret;

  -- returnable base falls back to received_qty when no bill was imported
  if public._c710_returnable_qty(v_oi.id) < 2 then
    raise exception 'E2E: returnable_qty fallback broken (got %)', public._c710_returnable_qty(v_oi.id);
  end if;

  m := public._c710_line_money(v_oi.id, 2);
  insert into public.supplier_return_item
    (return_id, order_item_id, order_id, product_id, product_name, batch_no, expiry,
     pending_bill_id, reason_code, qty, rate, gst_percent, taxable, gst_amount, line_total)
  values (v_ret, v_oi.id, v_oi.order_id, v_oi.product_id, coalesce(v_oi.product_name,''),
          coalesce(v_oi.batch_no,''), coalesce(v_oi.expiry,''),
          nullif(m->>'pending_bill_id','')::uuid, 'damaged_on_receipt', 2,
          coalesce((m->>'rate')::numeric,0), coalesce((m->>'gst_pct')::numeric,0),
          coalesce((m->>'taxable')::numeric,0), coalesce((m->>'gst')::numeric,0),
          coalesce((m->>'total')::numeric,0))
  returning id into v_item;

  perform public._c710_retotal(v_ret);
  select * into r from public.supplier_return where id = v_ret;
  if r.item_count <> 1 or r.qty_total <> 2 then
    raise exception 'E2E: retotal wrong (% items, % qty)', r.item_count, r.qty_total;
  end if;

  -- number series: per zone per FY, and it moves
  v_no := public._c710_next_debit_no(coalesce(r.zone_id,0)::smallint, true);
  if v_no !~ '^TEST/Z[0-9]+/TEST-[0-9]{4}-[0-9]{2}/[0-9]{4}$' then
    raise exception 'E2E: debit no shape wrong: %', v_no;
  end if;

  update public.supplier_return
     set status='sent', sent_at=now(), debit_no=v_no, fy=public._fy_ist(),
         ack_token = encode(gen_random_bytes(16),'hex')
   where id = v_ret;

  -- stock leaves the bag ledger and the received count
  select coalesce(sum(qty),0) into v_bag_before from public.bag_item_counts
   where assigned_supplier = r.supplier_name and product_id = v_oi.product_id;
  perform public._c710_release_stock(v_item);
  select coalesce(sum(qty),0) into v_bag_after from public.bag_item_counts
   where assigned_supplier = r.supplier_name and product_id = v_oi.product_id;
  select received_qty into v_rq_after from public.order_items where id = v_oi.id;
  if v_rq_after <> coalesce(v_oi.received_qty,0) - 2 then
    raise exception 'E2E: received_qty not reduced (% -> %)', v_oi.received_qty, v_rq_after;
  end if;
  if v_bag_before > 0 and v_bag_after > v_bag_before - 2 then
    raise exception 'E2E: bag ledger not re-derived down (% -> %)', v_bag_before, v_bag_after;
  end if;
  if not exists (select 1 from public.receiving_log where order_item_id = v_oi.id and action='supplier_return') then
    raise exception 'E2E: no receiving_log row';
  end if;

  -- re-inquiry fires for a reason that still needs the stock
  perform public._c710_reinquire(v_item);
  if not (select reinquiry_fired from public.supplier_return_item where id = v_item) then
    raise exception 'E2E: reinquiry not marked';
  end if;

  -- the debit note document
  v_doc := public._c710_doc_payload(v_ret);
  if coalesce(v_doc->>'ok','') <> 'true'
     or jsonb_array_length(v_doc->'doc'->'sections'->0->'rows') <> 1
     or (v_doc->>'file_name') not like 'DN-%' then
    raise exception 'E2E: doc payload wrong: %', v_doc;
  end if;

  -- the public acknowledge page, then the submit
  select ack_token into v_tok from public.supplier_return where id = v_ret;
  v_form := public.supplier_return_ack_form(v_tok);
  if coalesce(v_form->>'ok','') <> 'true' or (v_form->>'already')::boolean then
    raise exception 'E2E: ack form wrong: %', v_form;
  end if;
  if public.supplier_return_ack_form('nope-not-a-token')->>'error' <> 'invalid' then
    raise exception 'E2E: bad token not refused';
  end if;

  v_sub := public.supplier_return_ack_submit(v_tok, 'agreed');
  if coalesce(v_sub->>'ok','') <> 'true' then raise exception 'E2E: ack submit failed: %', v_sub; end if;
  select * into r from public.supplier_return where id = v_ret;
  if r.status <> 'credited' or r.acknowledged_at is null then
    raise exception 'E2E: not credited after ack (status %)', r.status;
  end if;
  if r.applied_amount + r.carried_amount <> r.grand_total then
    raise exception 'E2E: credit split does not add up (% + % <> %)',
      r.applied_amount, r.carried_amount, r.grand_total;
  end if;
  if (public.supplier_return_ack_form(v_tok)->>'already')::boolean is not true then
    raise exception 'E2E: second visit not marked already';
  end if;

  -- the bill sees it
  v_deb := public._c710_order_debits(v_so.id);
  if coalesce((v_deb->>'total')::numeric,0) <> r.grand_total then
    raise exception 'E2E: order debits total wrong (% vs %)', v_deb->>'total', r.grand_total;
  end if;

  -- the SPN input sees it
  v_stats := public.supplier_returns_stats(r.supplier_name, 30);
  if (v_stats->>'has')::boolean is not true or (v_stats->>'count_value') = '0' then
    raise exception 'E2E: returns stats blind: %', v_stats;
  end if;

  raise notice 'E2E OK  debit_no=%  total=%  applied=%  carried=%  bag % -> %  rq % -> %',
    r.debit_no, r.grand_total, r.applied_amount, r.carried_amount,
    v_bag_before, v_bag_after, v_oi.received_qty, v_rq_after;
end $t$;
rollback;

\set ON_ERROR_STOP on
begin;
do $t$
declare
  v_oi public.order_items%rowtype; v_pb uuid; v_bl uuid; m jsonb;
  v_ret uuid; v_item uuid; r public.supplier_return%rowtype; v_doc jsonb; v_sub jsonb;
  v_so public.supplier_orders%rowtype; v_deb jsonb;
begin
  select * into v_oi from public.order_items
   where coalesce(received_qty,0) >= 3 and assigned_supplier = 'Sagar Medicals'
   order by created_at desc limit 1;
  select * into v_so from public.supplier_orders
   where supplier_name = v_oi.assigned_supplier
     and coalesce(order_date,(created_at at time zone 'Asia/Kolkata')::date) = v_oi.order_date limit 1;

  -- a verified supplier bill line, allocated to this order line
  insert into public.pending_bills (id, file_path, file_name, supplier_name, supplier_id, status, imported_at, received_at, scan_result, is_synthetic)
  values (gen_random_uuid(), 'e2e/c710.pdf', 'c710.pdf', v_oi.assigned_supplier,
          (select id::text from public.supplier_profiles where lower(supplier_name)=lower(v_oi.assigned_supplier) limit 1),
          'imported', now(), now(), '{"invoice_no":"E2E-1","total":"1000"}'::jsonb, true)
  returning id into v_pb;

  insert into public.bill_lines
    (id, pending_bill_id, supplier_order_id, supplier_name, raw_name, product_id,
     batch_no, expiry, qty, mrp, ptr, gst_pct, line_amount, verified, is_synthetic)
  values (gen_random_uuid(), v_pb, v_so.id, v_oi.assigned_supplier, v_oi.product_name, v_oi.product_id,
          'B710', '12/27', 3, 100, 80, 12, 240, true, true)
  returning id into v_bl;

  -- a trigger already allocates a matched bill line to its order item; make the
  -- allocated quantity deterministic for the assertion below either way.
  insert into public.bill_line_allocations (bill_line_id, order_id, order_item_id, product_id, qty)
  values (v_bl, v_oi.order_id, v_oi.id, v_oi.product_id, 3)
  on conflict (bill_line_id, order_item_id) do update set qty = 3;
  delete from public.bill_line_allocations a
   where a.order_item_id = v_oi.id and a.bill_line_id <> v_bl;

  m := public._c710_line_money(v_oi.id, 2);
  if coalesce((m->>'has_rate')::boolean,false) is not true then
    raise exception 'E2E money: rate not picked up: %', m;
  end if;
  if round(coalesce((m->>'taxable')::numeric,0)) <> 160 then
    raise exception 'E2E money: taxable should be 2 x 80 = 160, got %', m->>'taxable';
  end if;
  if round(coalesce((m->>'gst')::numeric,0)) <> 19 then
    raise exception 'E2E money: gst should be 12%% of 160 = 19.2, got %', m->>'gst';
  end if;
  if (m->>'pending_bill_id')::uuid <> v_pb then
    raise exception 'E2E money: debit note not linked to the supplier bill';
  end if;

  -- returnable is now the BILLED qty, not the received qty
  if public._c710_returnable_qty(v_oi.id) <> 3 then
    raise exception 'E2E money: returnable should follow the bill (got %)',
      public._c710_returnable_qty(v_oi.id);
  end if;

  insert into public.supplier_return
    (zone_id, supplier_id, supplier_name, supplier_order_id, status, is_synthetic)
  values (coalesce(v_so.zone_id,1), v_so.supplier_id, v_oi.assigned_supplier, v_so.id, 'drafted', true)
  returning id into v_ret;

  insert into public.supplier_return_item
    (return_id, order_item_id, order_id, product_id, product_name, batch_no, expiry,
     pending_bill_id, reason_code, qty, rate, gst_percent, taxable, gst_amount, line_total)
  values (v_ret, v_oi.id, v_oi.order_id, v_oi.product_id, v_oi.product_name, 'B710','12/27',
          v_pb, 'near_expiry', 2, (m->>'rate')::numeric, (m->>'gst_pct')::numeric,
          (m->>'taxable')::numeric, (m->>'gst')::numeric, (m->>'total')::numeric)
  returning id into v_item;
  perform public._c710_retotal(v_ret);
  select * into r from public.supplier_return where id = v_ret;
  if round(r.grand_total) <> 179 then
    raise exception 'E2E money: debit note total should be 160 + 19.2, got %', r.grand_total;
  end if;

  -- a second line on the same order item may not exceed what is left
  if public._c710_returnable_qty(v_oi.id) <> 1 then
    raise exception 'E2E money: prior return not deducted (got %)', public._c710_returnable_qty(v_oi.id);
  end if;

  update public.supplier_return set status='sent', sent_at=now(), debit_no='DN/Z1/E2E/0001',
         ack_token = encode(gen_random_bytes(16),'hex') where id = v_ret;

  v_doc := public._c710_doc_payload(v_ret);
  if (v_doc->'doc'->'sections'->0->'rows'->0->>'amount') <> public.inr_money(r.grand_total) then
    raise exception 'E2E money: doc line amount not the backend string: %',
      v_doc->'doc'->'sections'->0->'rows'->0;
  end if;

  v_deb := public._c710_order_debits(v_so.id);
  if round((v_deb->>'total')::numeric) <> 179 then
    raise exception 'E2E money: bill does not see the debit (%)', v_deb->>'total';
  end if;
  if coalesce(v_deb->>'note','') = '' then
    raise exception 'E2E money: bill note empty';
  end if;

  -- acknowledge -> credited, split into applied + carried
  v_sub := public.supplier_return_ack_submit((select ack_token from public.supplier_return where id=v_ret), 'ok');
  select * into r from public.supplier_return where id = v_ret;
  if r.status <> 'credited' then raise exception 'E2E money: not credited'; end if;
  if r.applied_amount + r.carried_amount <> r.grand_total then
    raise exception 'E2E money: split wrong % + % <> %', r.applied_amount, r.carried_amount, r.grand_total;
  end if;
  if not exists (select 1 from public.supplier_return_credit_ledger where return_id = v_ret) then
    raise exception 'E2E money: no ledger row';
  end if;

  raise notice 'E2E MONEY OK  total=%  applied=%  carried=%  open_credit=%',
    r.grand_total, r.applied_amount, r.carried_amount,
    public.supplier_return_credit_open(r.supplier_id);
end $t$;
rollback;

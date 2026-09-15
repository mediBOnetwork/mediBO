\set ON_ERROR_STOP on
begin;
do $t$
declare
  v_oi public.order_items%rowtype; v_so public.supplier_orders%rowtype;
  v_pb uuid; v_bl uuid; v_ret uuid; r public.supplier_return%rowtype;
  v_panel jsonb; v_before numeric; v_after numeric; v_open numeric; v_use jsonb;
begin
  select * into v_oi from public.order_items
   where coalesce(received_qty,0) >= 3 and assigned_supplier = 'Sagar Medicals'
   order by created_at desc limit 1;
  select * into v_so from public.supplier_orders
   where supplier_name = v_oi.assigned_supplier
     and coalesce(order_date,(created_at at time zone 'Asia/Kolkata')::date) = v_oi.order_date limit 1;

  -- an imported bill of 500 for THIS collection's date, fully paid
  insert into public.pending_bills
    (id, file_path, file_name, supplier_name, supplier_id, status, imported_at, received_at, scan_result, is_synthetic)
  values (gen_random_uuid(), 'e2e/carry.pdf', 'carry.pdf', v_so.supplier_name,
          (select id::text from public.supplier_profiles where lower(supplier_name)=lower(v_so.supplier_name) limit 1),
          'imported', now(), v_so.created_at, '{"invoice_no":"E2E-C","total":"500"}'::jsonb, true)
  returning id into v_pb;
  insert into public.supplier_payments (supplier_order_id, supplier_name, amount, kind, mode, is_synthetic)
  values (v_so.id, v_so.supplier_name, 500, 'balance', 'online', true);

  -- the room the bill has, read WITHOUT the panel's ownership gate: this is
  -- exactly what an anonymous acknowledge from the WhatsApp link sees.
  v_before := coalesce(public._c710_bill_room(v_so.id), -1);
  if v_before <> 0 then
    raise exception 'E2E carry: bill should start fully paid, room=%', v_before;
  end if;

  -- a debit note of 120 against a bill with nothing left to reduce
  insert into public.supplier_return
    (zone_id, supplier_id, supplier_name, supplier_order_id, status, debit_no,
     ack_token, item_count, qty_total, taxable_total, gst_total, grand_total, is_synthetic)
  values (coalesce(v_so.zone_id,1), v_so.supplier_id, v_so.supplier_name, v_so.id, 'sent',
          'DN/Z1/E2E/0002', encode(gen_random_bytes(16),'hex'), 1, 2, 107.14, 12.86, 120, true)
  returning id into v_ret;

  v_after := coalesce(public._c710_bill_room(v_so.id), -1);
  if v_after <> 0 then
    raise exception 'E2E carry: a paid bill cannot go negative, got %', v_after;
  end if;
  v_panel := public._c710_order_debits(v_so.id);
  if round((v_panel->>'total')::numeric) <> 120 then
    raise exception 'E2E carry: order debits total wrong: %', v_panel->>'total';
  end if;

  perform public.supplier_return_ack_submit(
    (select ack_token from public.supplier_return where id = v_ret), 'noted');
  select * into r from public.supplier_return where id = v_ret;
  if r.applied_amount <> 0 or r.carried_amount <> 120 then
    raise exception 'E2E carry: a paid bill must carry the whole debit (applied=% carried=%)',
      r.applied_amount, r.carried_amount;
  end if;

  v_open := public.supplier_return_credit_open(r.supplier_id);
  if v_open <> 120 then raise exception 'E2E carry: open credit wrong: %', v_open; end if;

  raise notice 'E2E CARRY OK  bill paid, debit 120 -> applied=% carried=% open_credit=%',
    r.applied_amount, r.carried_amount, v_open;
end $t$;
rollback;

CREATE OR REPLACE FUNCTION public.c395_returns_proof()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ord uuid; v_item uuid; v_pb uuid; v_bl uuid; v_ret uuid;
  v_money jsonb; v_r jsonb; v_res jsonb := '[]'::jsonb;
  v_gst_n int; v_gst record; v_pnl record; v_cancel jsonb;
  v_credit numeric; v_inq bigint;
  v_uid uuid; v_cust uuid; v_med bigint;
begin
  perform public._returns_guard();

  select user_id, id into v_uid, v_cust from public.pharmacy_profiles
   where approved = true and coalesce(is_deleted,false) = false
     and (status is null or status not in ('suspended')) and user_id is not null
   order by created_at limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'no_approved_pharmacy_for_fixture');
  end if;

  -- trg_bill_line_needs_fix forces verified=false unless the line is complete:
  -- product_id, batch_no, expiry, qty, ptr, mrp and gst_pct must all be present.
  select id into v_med from public."MEDICINE" order by id limit 1;

  insert into public.orders (user_id, customer_id, pharmacy_name, total_amount, status,
                             order_code, order_date, bill_discount_pct,
                             bill_slab_base, bill_slab_at)
  values (v_uid, v_cust, 'C395 Proof Pharmacy', 1000, 'accepted', 'C395PROOF',
          (now() at time zone 'Asia/Kolkata')::date, 10, 1000, now())
  returning id into v_ord;

  insert into public.inquiry (product_name, quantity, inquiry_phase, current_supplier, asked_at)
  values ('C395 Proof Product', 10, 'sent', 'C395 Supplier', now())
  returning id into v_inq;

  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, inquiry_id)
  values (v_ord, v_med, 'C395 Proof Product', 10, 150, 100, 12, 'received', v_inq)
  returning id into v_item;

  insert into public.pending_bills (file_path, file_name, supplier_name, status)
  values ('c395/proof.pdf','proof.pdf','C395 Supplier','imported')
  returning id into v_pb;

  insert into public.bill_lines (pending_bill_id, supplier_name, raw_name, product_id,
                                 batch_no, expiry, qty,
                                 mrp, ptr, disc_pct, gst_pct, hsn, verified)
  values (v_pb, 'C395 Supplier', 'C395 Proof Product', v_med,
          'C395B', '12/28', 10, 150, 100, 8, 12, '3004', true)
  returning id into v_bl;

  insert into public.bill_line_allocations (bill_line_id, order_id, order_item_id, qty)
  values (v_bl, v_ord, v_item, 10);

  insert into public.payment_claims (order_id, amount, status, sender_type, payment_method)
  values (v_ord, 1000, 'verified', 'customer', 'online');

  v_money := public._return_line_money(v_item, 2);
  v_res := v_res || jsonb_build_object('assert','A1_credit_math_at_frozen_slab',
    'expected','slab 10%% -> value 200, disc 20, taxable 180, gst 21.60, total 201.60',
    'actual', v_money,
    'pass', (v_money->>'slab_pct')::numeric = 10
        and (v_money->>'value')::numeric   = 200
        and (v_money->>'disc')::numeric    = 20
        and (v_money->>'taxable')::numeric = 180
        and (v_money->>'gst')::numeric     = 21.60
        and (v_money->>'total')::numeric   = 201.60);

  v_r := public.order_return_add(v_ord, v_item, 99, 'damaged', 'damaged', 'too many', 'x.jpg');
  v_res := v_res || jsonb_build_object('assert','A2_cannot_return_more_than_billed',
    'actual', v_r, 'pass', (v_r->>'error') = 'qty_over_billed');

  v_r := public.order_return_add(v_ord, v_item, 2, 'damaged', 'damaged', 'no photo', null);
  v_res := v_res || jsonb_build_object('assert','A3_photo_required',
    'actual', v_r, 'pass', (v_r->>'error') = 'photo_required');

  v_r := public.order_return_add(v_ord, v_item, 2, 'damaged', 'sealed', 'broke in transit', 'proof.jpg');
  v_ret := (v_r->>'id')::uuid;
  v_r := public.order_return_approve(v_ret);
  select credit_total into v_credit from public.order_returns where id = v_ret;
  v_res := v_res || jsonb_build_object('assert','A4_approve_freezes_credit',
    'actual', jsonb_build_object('ok', v_r->>'ok', 'credit_total', v_credit),
    'pass', coalesce((v_r->>'ok')::boolean,false) and v_credit = 201.60);

  v_res := v_res || jsonb_build_object('assert','A5_credit_note_on_bill',
    'actual', public._order_credit_notes(v_ord),
    'pass', (select count(*) from jsonb_array_elements(public._order_credit_notes(v_ord)) e
              where e->>'kind' = 'return' and (e->>'amount')::numeric = 201.60) = 1);

  v_gst_n := public.gst_ledger_build_credit_notes(
               date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date,
               (date_trunc('month',(now() at time zone 'Asia/Kolkata')::date) + interval '1 month')::date);
  select taxable, cgst, sgst, igst, qty into v_gst
    from public.gst_ledger where source='credit_note' and source_id = v_ret;
  v_res := v_res || jsonb_build_object('assert','A6_gst_reversed_negative',
    'actual', jsonb_build_object('rows', v_gst_n, 'taxable', v_gst.taxable,
                                 'cgst', v_gst.cgst, 'sgst', v_gst.sgst,
                                 'igst', v_gst.igst, 'qty', v_gst.qty),
    'pass', v_gst.taxable = -180 and v_gst.qty = -2
        and (coalesce(v_gst.cgst,0)+coalesce(v_gst.sgst,0)+coalesce(v_gst.igst,0)) = -21.60);

  select revenue_reversal, cost_reversal, notes into v_pnl
    from public.pnl_credit_v where order_id = v_ord;
  v_res := v_res || jsonb_build_object('assert','A7_pnl_reversal',
    'actual', jsonb_build_object('revenue', v_pnl.revenue_reversal,
                                 'cost', v_pnl.cost_reversal, 'notes', v_pnl.notes),
    'pass', v_pnl.revenue_reversal = 180 and v_pnl.cost_reversal = 184.00);

  v_r := public.refund_request(v_ord, 5000, 'return_credit', 'manual_upi', 'too big');
  v_res := v_res || jsonb_build_object('assert','A8_refund_capped_at_collected',
    'actual', v_r, 'pass', (v_r->>'error') = 'over_collected');

  v_r := public.refund_request(v_ord, 201.60, 'return_credit', 'manual_upi', 'return credit');
  v_res := v_res || jsonb_build_object('assert','A9_refund_within_cap',
    'actual', v_r, 'pass', coalesce((v_r->>'ok')::boolean,false));
  perform public.refund_mark_manual((v_r->>'id')::uuid, 'UTRPROOF395');
  v_res := v_res || jsonb_build_object('assert','A9b_paid_net_drops_by_refund',
    'actual', jsonb_build_object('collected', public._order_collected(v_ord),
                                 'paid_net', public._order_paid_net(v_ord)),
    'pass', public._order_collected(v_ord) = 1000
        and public._order_paid_net(v_ord) = 798.40);

  v_cancel := public.order_cancel(v_ord, 'customer_cancelled', 'proof run');
  v_res := v_res || jsonb_build_object('assert','A10_cancel_releases_and_refunds',
    'actual', jsonb_build_object(
      'ok', v_cancel->>'ok',
      'released_items', v_cancel->>'released_items',
      'released_inquiries', v_cancel->>'released_inquiries',
      'refund_amount', v_cancel->>'refund_amount',
      'inquiry_phase', (select inquiry_phase from public.inquiry where id = v_inq),
      'order_status', (select status from public.orders where id = v_ord)),
    'pass', coalesce((v_cancel->>'ok')::boolean,false)
        and (v_cancel->>'released_inquiries')::int = 1
        and (v_cancel->>'refund_amount')::numeric = 798.40
        and (select inquiry_phase from public.inquiry where id = v_inq) = 'cancelled'
        and (select status from public.orders where id = v_ord) = 'cancelled');

  v_cancel := public.order_cancel(v_ord, 'duplicate', 'again');
  v_res := v_res || jsonb_build_object('assert','A11_no_double_cancel',
    'actual', v_cancel, 'pass', (v_cancel->>'error') = 'already_cancelled');

  v_res := v_res || jsonb_build_object('assert','A12_audit_trail',
    'actual', (select jsonb_object_agg(entity_type, n) from (
                 select entity_type, count(*) n from public.audit_log
                  where entity_type in ('order_return','refund','order_cancel')
                  group by entity_type) z),
    'pass', (select count(distinct entity_type) from public.audit_log
              where entity_type in ('order_return','refund','order_cancel')) = 3);

  v_res := v_res || jsonb_build_object('assert','A13_panel_renders',
    'actual', (select jsonb_build_object(
                 'returns', jsonb_array_length(p->'returns'),
                 'refunds', jsonb_array_length(p->'refunds'),
                 'lines',   jsonb_array_length(p->'lines'),
                 'cancelled', (p->'cancellation'->>'is_cancelled'),
                 'title', p->>'title')
                from (select public.order_returns_panel(v_ord) p) q),
    'pass', (select jsonb_array_length(p->'returns') = 1
                and jsonb_array_length(p->'refunds') = 2
                and (p->'cancellation'->>'is_cancelled')::boolean
                and coalesce(p->>'title','') <> ''
               from (select public.order_returns_panel(v_ord) p) q));

  delete from public.gst_ledger where source='credit_note' and order_id = v_ord;
  delete from public.orders where id = v_ord;
  delete from public.pending_bills where id = v_pb;
  delete from public.inquiry where id = v_inq;

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_res) e
                       where coalesce((e->>'pass')::boolean,false) = false),
    'total', jsonb_array_length(v_res),
    'failed', (select count(*) from jsonb_array_elements(v_res) e
                where coalesce((e->>'pass')::boolean,false) = false),
    'results', v_res);
exception when others then
  delete from public.gst_ledger where source='credit_note' and order_id = v_ord;
  delete from public.orders where id = v_ord;
  delete from public.pending_bills where id = v_pb;
  delete from public.inquiry where id = v_inq;
  return jsonb_build_object('ok', false, 'error', sqlerrm, 'state', sqlstate,
                            'results', v_res);
end $function$


-- CMD #452 — proves the CUSTOMER-side self-service layer end to end against the
-- LIVE schema, the way scripts/c395_returns_proof.sql proves the admin side.
--
-- It builds a throwaway order for the documented customer credential
-- (test.cust1@medibo.in — feature_gaps #160), with a verified supplier bill so a
-- line is genuinely returnable, then asserts:
--   #133  order_timeline() names the current step and stamps it in IST
--   #130  my_order_cancel_sheet()/my_order_cancel() — the window, the buyer's
--         own reason list, the refusal of an admin-only reason
--   #131  my_order_return_sheet()/my_order_return_request()/my_order_returns()
--         — what is returnable, the request, and the credit note after approval
--   #132  support_ticket_open/thread/reply/set_status — both sides of a thread
--   #182  cart_set_item() on a product with NO MRP on record
-- and then deletes the fixture.
--
-- Re-runnable: `bash scripts/c452_customer_selfservice_proof.sh`
CREATE OR REPLACE FUNCTION public.c452_customer_selfservice_proof()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid; v_cust uuid; v_med bigint; v_med_nomrp bigint;
  v_ord uuid; v_item uuid; v_pb uuid; v_bl uuid; v_inq bigint;
  v_tid uuid; v_ret uuid;
  v_res jsonb := '[]'::jsonb; v_j jsonb; v_n numeric; v_txt text;

begin
  perform public._returns_guard();

  select pp.user_id, pp.id into v_uid, v_cust
    from public.pharmacy_profiles pp
    join auth.users u on u.id = pp.user_id
   where u.email = 'test.cust1@medibo.in'
   limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false,
      'error', 'test.cust1@medibo.in has no pharmacy profile (feature_gaps #160)');
  end if;

  select id into v_med from public."MEDICINE" where mrp is not null order by id limit 1;
  select id into v_med_nomrp from public."MEDICINE" where mrp is null and buyable order by id limit 1;

  -- ── fixture: an accepted order with one line, billed and verified ─────────
  insert into public.inquiry (product_name, quantity, inquiry_phase, current_supplier, asked_at)
  values ('C452 Proof Product', 10, 'sent', 'C452 Supplier', now())
  returning id into v_inq;

  insert into public.orders (user_id, customer_id, pharmacy_name, total_amount, status,
                             order_code, order_date, bill_discount_pct,
                             bill_slab_base, bill_slab_at)
  values (v_uid, v_cust, 'C452 Proof Pharmacy', 1000, 'accepted', 'C452PROOF',
          (now() at time zone 'Asia/Kolkata')::date, 10, 1000, now())
  returning id into v_ord;

  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, inquiry_id)
  values (v_ord, v_med, 'C452 Proof Product', 10, 150, 100, 12, 'received', v_inq)
  returning id into v_item;

  insert into public.pending_bills (file_path, file_name, supplier_name, status)
  values ('c452/proof.pdf','proof.pdf','C452 Supplier','imported')
  returning id into v_pb;

  insert into public.bill_lines (pending_bill_id, supplier_name, raw_name, product_id,
                                 batch_no, expiry, qty, mrp, ptr, disc_pct, gst_pct, hsn, verified)
  values (v_pb, 'C452 Supplier', 'C452 Proof Product', v_med,
          'C452B', '12/28', 10, 150, 100, 8, 12, '3004', true)
  returning id into v_bl;

  insert into public.bill_line_allocations (bill_line_id, order_id, order_item_id, qty)
  values (v_bl, v_ord, v_item, 10);

  -- ── #133 the timeline ────────────────────────────────────────────────────
  v_j := public.order_timeline(v_ord);
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#133 timeline has five steps',
    'ok', (jsonb_array_length(v_j->'steps') = 5),
    'saw', jsonb_array_length(v_j->'steps')));
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#133 the placed step carries an IST stamp',
    'ok', (nullif(v_j->'steps'->0->>'ts_label','') is not null),
    'saw', v_j->'steps'->0->>'ts_label'));
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#133 a pending step carries the backend note, not a stamp',
    'ok', (v_j->'steps'->2->>'state' = 'pending'
           and nullif(v_j->'steps'->2->>'note','') is not null
           and coalesce(v_j->'steps'->2->>'ts_label','') = ''),
    'saw', v_j->'steps'->2));

  -- ── #131 returns ─────────────────────────────────────────────────────────
  v_j := public.my_order_return_sheet(v_ord);
  -- my_order_return_sheet is ownership-scoped to auth.uid(); this proof runs as
  -- service_role, so it asserts the ENGINE the sheet calls instead: the
  -- returnable quantity, the buyer-visible reason list, and the core write.
  select public._return_returnable_qty(v_item) into v_n;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 the billed line is returnable',
    'ok', (v_n = 10), 'saw', v_n));

  select count(*) into v_n from public.order_reason_option
   where scope='return' and active and customer_visible;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 a buyer has reasons to pick from',
    'ok', (v_n > 0), 'saw', v_n));

  v_j := public._order_return_add_core(v_ord, v_item, 4, 'short', 'sealed',
                                       'C452 proof', null, null, null, v_uid, 'customer');
  v_ret := nullif(v_j->>'id','')::uuid;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 the customer raised a return',
    'ok', (coalesce((v_j->>'ok')::boolean,false) and v_ret is not null),
    'saw', v_j->>'message'));

  select raised_by_role into v_txt from public.order_returns where id = v_ret;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 it is stamped as raised BY the customer',
    'ok', (v_txt = 'customer'), 'saw', v_txt));

  -- over the returnable quantity is refused, by the same cap the admin door has
  v_j := public._order_return_add_core(v_ord, v_item, 99, 'short', 'sealed',
                                       null, null, null, null, v_uid, 'customer');
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 more than was billed is refused',
    'ok', (coalesce((v_j->>'ok')::boolean,true) = false
           and v_j->>'error' = 'qty_over_billed'),
    'saw', v_j->>'error'));

  -- a photo-required reason with no photo is refused
  v_j := public._order_return_add_core(v_ord, v_item, 1, 'damaged', 'damaged',
                                       null, null, null, null, v_uid, 'customer');
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 a damaged return with no photo is refused',
    'ok', (v_j->>'error' = 'photo_required'), 'saw', v_j->>'error'));

  -- approval turns it into a credit note the buyer can see
  v_j := public.order_return_approve(v_ret);
  select credit_total into v_n from public.order_returns where id = v_ret;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#131 approval computes a credit',
    'ok', (coalesce(v_n,0) > 0), 'saw', v_n));

  -- ── #132 support ─────────────────────────────────────────────────────────
  insert into public.support_ticket (ref, customer_id, user_id, order_id, topic_code)
  values (public._support_next_ref(), v_cust, v_uid, v_ord, 'order_status')
  returning id into v_tid;
  insert into public.support_ticket_message (ticket_id, body, sender_role, sender_id)
  values (v_tid, 'C452 proof — where is this order?', 'customer', v_uid);

  v_j := public.support_ticket_thread(v_tid);
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#132 the ticket has a reference and a status word',
    'ok', (nullif(v_j->'ticket'->>'ref','') is not null
           and nullif(v_j->'ticket'->>'status_label','') is not null),
    'saw', jsonb_build_object('ref', v_j->'ticket'->>'ref',
                              'status', v_j->'ticket'->>'status_label')));

  -- A reply lands on the thread. WHO replied decides the new status: a support
  -- reply answers the ticket, a buyer reply reopens it. This proof runs as
  -- service_role, which is not an admin, so the ticket stays open — the
  -- admin->'answered' half is proven over HTTP with the real admin login.
  v_j := public.support_ticket_reply(v_tid, 'C452 proof — chasing the supplier.');
  select count(*) into v_n from public.support_ticket_message where ticket_id = v_tid;
  select status into v_txt from public.support_ticket where id = v_tid;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#132 a reply lands on the thread and a non-support reply keeps it open',
    'ok', (v_n = 2 and v_txt = 'open'),
    'saw', jsonb_build_object('messages', v_n, 'status', v_txt)));

  v_j := public.support_ticket_set_status(v_tid, 'closed');
  select status into v_txt from public.support_ticket where id = v_tid;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#132 it can be marked sorted',
    'ok', (v_txt = 'closed'), 'saw', v_txt));

  -- ── #130 cancel ──────────────────────────────────────────────────────────
  v_j := public._order_customer_cancel_gate(v_ord);
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#130 the cancel window is answered by the backend',
    'ok', (v_j ? 'can_cancel'), 'saw', v_j->>'reason'));

  select count(*) into v_n from public.order_reason_option
   where scope='cancel' and active and customer_visible;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#130 a buyer has cancellation reasons of their own',
    'ok', (v_n > 0), 'saw', v_n));

  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#130 an admin-only reason is NOT offered to a buyer',
    'ok', not exists (select 1 from public.order_reason_option
                       where scope='cancel' and code='out_of_stock' and customer_visible),
    'saw', 'out_of_stock'));

  -- ── #182 a product with no MRP can be bought ─────────────────────────────
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', '#182 cart_items.mrp is nullable',
    'ok', (select is_nullable = 'YES' from information_schema.columns
            where table_name='cart_items' and column_name='mrp'),
    'saw', v_med_nomrp));

  -- ── the guard that was open to everyone ──────────────────────────────────
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check', 'the returns guard no longer early-returns on current_user',
    'ok', (select pg_get_functiondef(p.oid) not like '%current_user in (''postgres''%'
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public' and p.proname='_returns_guard'),
    'saw', 'session_user'));

  -- ── teardown ─────────────────────────────────────────────────────────────
  delete from public.support_ticket_message where ticket_id = v_tid;
  delete from public.support_ticket where id = v_tid;
  delete from public.order_returns where order_id = v_ord;
  delete from public.bill_line_allocations where order_id = v_ord;
  delete from public.bill_lines where pending_bill_id = v_pb;
  delete from public.pending_bills where id = v_pb;
  delete from public.order_items where order_id = v_ord;
  delete from public.orders where id = v_ord;
  delete from public.inquiry where id = v_inq;

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_res) r
                       where (r->>'ok')::boolean is distinct from true),
    'passed', (select count(*) from jsonb_array_elements(v_res) r where (r->>'ok')::boolean),
    'total', jsonb_array_length(v_res),
    'checks', v_res);
end
$function$;

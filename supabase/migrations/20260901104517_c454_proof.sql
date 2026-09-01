-- CMD #454 — per-row proof for feature_gaps 99,100,101,102,103,114,115,116.
-- Builds a two-line billed order + an approved rider, drives every fixed path,
-- asserts the observable consequence, then tears the fixture down. 29 checks.
create or replace function public.c454_delivery_high_b_proof()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_uid uuid; v_cust uuid; v_med bigint; v_med2 bigint;
  v_ord uuid; v_item uuid; v_item2 uuid; v_pb uuid; v_bl uuid; v_bl2 uuid; v_inq bigint;
  v_partner uuid; v_del uuid; v_run uuid; v_admin uuid; v_admin_email text;
  v_res jsonb := '[]'::jsonb; v_j jsonb; v_t text;
  v_lots_before int; v_lots_after int; v_hist_before int; v_hist_after int;
begin
  -- This proof runs from psql, which carries no JWT, so every guarded RPC
  -- below would answer not_authorized on an empty auth.uid(). Adopt the
  -- super-admin's claims for the duration: the guards are then exercised for
  -- real rather than bypassed.
  select a.email, u.id into v_admin_email, v_admin
    from public.admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   order by a.email limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'email', v_admin_email,
                      'role', 'authenticated')::text, true);

  select pp.user_id, pp.id into v_uid, v_cust
    from public.pharmacy_profiles pp join auth.users u on u.id = pp.user_id
   where u.email = 'test.cust1@medibo.in' limit 1;
  select id into v_med  from public."MEDICINE" order by id limit 1;
  select id into v_med2 from public."MEDICINE" order by id offset 1 limit 1;

  -- ── #99 PII ───────────────────────────────────────────────────────────────
  insert into public.delivery_partner_registrations(
    full_name, phone, status, is_active, partner_type, submitted_at,
    id_doc_type, id_doc_number, dl_number, id_doc_path, ocr_payload, zone_id,
    user_id, email, reviewed_at, training_override_at, training_override_by)
  values ('C454 Proof Rider','9000000454','approved', true, 'boy', now(),
          'aadhaar','2345 6789 0123','CG04 20110012345','c454/proof.jpg',
          '{"name":"C454 Proof Rider","id_number":"234567890123","raw_text":"AADHAAR 2345 6789 0123"}'::jsonb,
          (select id from public.zones order by id limit 1),
          v_admin, 'c454.proof.rider@medibo.in', now(), now(), v_admin)
  returning id into v_partner;

  select id_doc_number into v_t from public.delivery_partner_registrations where id = v_partner;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',99,
    'check','the stored Aadhaar number is masked to its last 4',
    'ok', (v_t = '••••••••0123'), 'saw', v_t));

  select dl_number into v_t from public.delivery_partner_registrations where id = v_partner;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',99,
    'check','the DL number is masked too', 'ok', (v_t like '•%'), 'saw', v_t));

  select ocr_payload::text into v_t from public.delivery_partner_registrations where id = v_partner;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',99,
    'check','the raw number is nowhere in the stored ocr_payload',
    'ok', (v_t not like '%234567890123%' and v_t not like '%2345 6789 0123%'), 'saw', v_t));

  select id_doc_hash into v_t from public.delivery_partner_registrations where id = v_partner;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',99,
    'check','a de-duplication hash was kept instead of the number',
    'ok', (v_t = public._pii_hash_doc('234567890123')), 'saw', left(coalesce(v_t,''),12)));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',99,
    'check','a retention job exists for the raw document image',
    'ok', exists(select 1 from public.cron_task where name='delivery_id_doc_purge' and enabled),
    'saw', (select run_at_ist::text from public.cron_task where name='delivery_id_doc_purge')));

  -- ── fixture: an order with TWO billed, verified lines ─────────────────────
  insert into public.inquiry (product_name, quantity, inquiry_phase, current_supplier, asked_at)
  values ('C454 Proof Product', 10, 'sent', 'C454 Supplier', now()) returning id into v_inq;

  insert into public.orders (user_id, customer_id, pharmacy_name, total_amount, status,
                             order_code, order_date, bill_discount_pct, bill_slab_base, bill_slab_at,
                             fulfillment_status)
  values (v_uid, v_cust, 'C454 Proof Pharmacy', 1500, 'accepted', 'C454PROOF',
          (now() at time zone 'Asia/Kolkata')::date, 10, 1500, now(), 'open')
  returning id into v_ord;

  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, inquiry_id)
  values (v_ord, v_med, 'C454 Proof Product', 10, 150, 100, 12, 'received', v_inq)
  returning id into v_item;
  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, inquiry_id)
  values (v_ord, v_med2, 'C454 Proof Product Two', 5, 90, 60, 12, 'received', v_inq)
  returning id into v_item2;

  insert into public.pending_bills (file_path, file_name, supplier_name, status)
  values ('c454/proof.pdf','proof.pdf','C454 Supplier','imported') returning id into v_pb;

  insert into public.bill_lines (pending_bill_id, supplier_name, raw_name, product_id,
                                 batch_no, expiry, qty, mrp, ptr, disc_pct, gst_pct, hsn, verified)
  values (v_pb,'C454 Supplier','C454 Proof Product', v_med,'C454B','12/28',10,150,100,8,12,'3004',true)
  returning id into v_bl;
  insert into public.bill_lines (pending_bill_id, supplier_name, raw_name, product_id,
                                 batch_no, expiry, qty, mrp, ptr, disc_pct, gst_pct, hsn, verified)
  values (v_pb,'C454 Supplier','C454 Proof Product Two', v_med2,'C454C','12/28',5,90,60,8,12,'3004',true)
  returning id into v_bl2;

  insert into public.bill_line_allocations (bill_line_id, order_id, order_item_id, qty)
  values (v_bl, v_ord, v_item, 10), (v_bl2, v_ord, v_item2, 5);

  insert into public.delivery_runs(partner_id, zone_id, status)
  values (v_partner, (select zone_id from public.delivery_partner_registrations where id=v_partner), 'started')
  returning id into v_run;

  -- handover_at is stamped because the custody gate (CHANGE #309) is upstream
  -- of everything this proof is about; without it _delivery_complete refuses and
  -- the partial can never close.
  insert into public.deliveries(order_id, run_id, partner_id, assigned_at, accept_status, status,
                                qr_token, handover_at, handover_method)
  values (v_ord, v_run, v_partner, now(), 'accepted', 'out_for_delivery',
          encode(extensions.gen_random_bytes(9),'hex'), now(), 'qr')
  returning id into v_del;

  -- ── #101 partial ──────────────────────────────────────────────────────────
  v_j := public.delivery_partial(v_del, 12, 3, 'legacy two-number call', null, null, 'c454/x.jpg', null);
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',101,
    'check','a multi-line order can no longer be closed on two scalars',
    'ok', (v_j->>'error') = 'lines_required', 'saw', coalesce(v_j->>'error', v_j->>'ok')));

  select count(*) into v_lots_before from public.stock_lot;
  v_j := public.delivery_partial_lines(v_del,
           jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'qty', 3)),
           'customer took the rest', null, null, 'delivery-proofs/c454.jpg', 'Proof Receiver');
  select count(*) into v_lots_after from public.stock_lot;

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',101,
    'check','the partial names the LINE that came back, not just a number',
    'ok', exists(select 1 from public.order_returns
                  where order_id = v_ord and order_item_id = v_item and qty = 3),
    'saw', (select coalesce(string_agg(order_item_id::text||' x '||trim_scale(qty), ','),'none')
              from public.order_returns where order_id = v_ord)));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',101,
    'check','the returned 3 units moved back into stock',
    'ok', exists(select 1 from public.stock_movement
                  where order_item_id = v_item and kind = 'return_in' and qty = 3),
    'saw', (v_lots_after - v_lots_before)::text || ' new lot(s)'));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',101,
    'check','a credit was priced for the returned line (PTR, never MRP)',
    'ok', coalesce((v_j->'returns'->>'credit_total')::numeric,0) > 0
          and coalesce((v_j->'returns'->>'credit_total')::numeric,0) < 3 * 150,
    'saw', v_j->'returns'->>'credit_total'));

  -- ── #100 assign ───────────────────────────────────────────────────────────
  v_j := public._delivery_assign_core(array[v_ord], v_partner, 'c454_proof', null);
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',100,
    'check','assigning a delivered order is blocked, not resurrected',
    'ok', (v_j->'blocked'->0->>'reason') is not null and coalesce((v_j->>'assigned')::int,0) = 0,
    'saw', coalesce(v_j->'blocked'->0->>'reason', v_j->>'error')));

  select proof_photo_path into v_t from public.deliveries where id = v_del;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',100,
    'check','the completed proof survived the refused assign',
    'ok', v_t is not null, 'saw', coalesce(v_t,'(null)')));

  v_j := public.delivery_redeliver(v_ord, v_partner);
  select coalesce(proof_photo_path,'') || '|' || coalesce(delivered_at::text,'') into v_t
    from public.deliveries where id = v_del;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',100,
    'check','the explicit re-deliver path clears every proof field',
    'ok', v_t = '|', 'saw', v_t));

  -- ── #102 RTO ──────────────────────────────────────────────────────────────
  update public.deliveries set status='out_for_delivery', rto_received_at=null where id=v_del;
  v_j := public.delivery_rto_receive(v_del);
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',102,
    'check','RTO returns every still-owed line to stock (7 of line 1 + 5 of line 2)',
    'ok', coalesce((v_j->'returns'->>'returned_qty')::numeric,0) = 12,
    'saw', v_j->'returns'->>'returned_qty'));

  select fulfillment_status into v_t from public.orders where id = v_ord;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',102,
    'check','the order stops counting as shipped',
    'ok', v_t = 'returned', 'saw', coalesce(v_t,'(null)')));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',102,
    'check','a credit was raised for the returned parcel',
    'ok', coalesce((v_j->'returns'->>'credit_total')::numeric,0) > 0,
    'saw', v_j->'returns'->>'credit_total'));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',102,
    'check','the customer has a notification route for it',
    'ok', exists(select 1 from public.wa_event_routes where event_key='delivery_rto' and enabled),
    'saw', 'delivery_rto'));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',102,
    'check','the bulk finish_run path now logs an rto event per stop',
    'ok', (select pg_get_functiondef(p.oid) like '%trip finished with the parcel still on board%'
             from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.proname='delivery_finish_run'),
    'saw','delivery_finish_run'));

  -- ── #103 reattempt ────────────────────────────────────────────────────────
  update public.deliveries
     set status='failed', attempt_no=1, next_attempt_on=(now() at time zone 'Asia/Kolkata')::date - 1,
         rto_received_at=null, rto_at=null
   where id=v_del;
  v_j := public.delivery_reattempt_tick();
  select status into v_t from public.deliveries where id=v_del;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',103,
    'check','a failure whose next_attempt_on has arrived is re-queued',
    'ok', coalesce((v_j->>'requeued')::int,0) >= 1 and v_t <> 'failed',
    'saw', coalesce(v_j->>'requeued','0')||' requeued, status='||coalesce(v_t,'')));

  update public.deliveries
     set status='failed', attempt_no=99, next_attempt_on=(now() at time zone 'Asia/Kolkata')::date - 1,
         rto_at=null
   where id=v_del;
  v_j := public.delivery_reattempt_tick();
  select status into v_t from public.deliveries where id=v_del;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',103,
    'check','past the attempt cap it auto-RTOs instead of looping',
    'ok', v_t = 'rto' and coalesce((v_j->>'auto_rto')::int,0) >= 1,
    'saw','status='||coalesce(v_t,'')||', cap='||coalesce(v_j->>'cap','')));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',103,
    'check','the cron row that finally reads next_attempt_on exists',
    'ok', exists(select 1 from public.cron_task where name='delivery_reattempt' and enabled),
    'saw', (select work_sql from public.cron_task where name='delivery_reattempt')));

  -- ── #114 the rider is told ────────────────────────────────────────────────
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',114,
    'check','assignment calls the rider notifier',
    'ok', (select pg_get_functiondef(p.oid) like '%_delivery_notify_assigned%'
             from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.proname='_delivery_assign_core'),
    'saw','_delivery_assign_core'));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',114,
    'check','the rider push route exists, enabled, audience=delivery',
    'ok', exists(select 1 from public.wa_event_routes
                  where event_key='delivery_assigned' and push_enabled and audience='delivery'),
    'saw', (select push_title from public.wa_event_routes where event_key='delivery_assigned')));

  update public.deliveries set status='assigned', accept_status='pending', partner_id=v_partner,
         run_id=v_run, assigned_at=now(), rto_at=null where id=v_del;
  perform public._delivery_notify_assigned(v_del);
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',114,
    'check','the rider gets an in-app row the moment they are assigned',
    'ok', exists(select 1 from public.notification_log
                  where event_key='delivery_assigned' and channel='inapp'
                    and created_at > now() - interval '2 minutes'),
    'saw', (select coalesce(string_agg(title,','),'none') from public.notification_log
             where event_key='delivery_assigned' and channel='inapp'
               and created_at > now() - interval '2 minutes')));

  -- ── #115 accept window ────────────────────────────────────────────────────
  update public.deliveries set assigned_at = now() - interval '3 hours',
         accept_status='pending', status='assigned' where id = v_del;
  v_j := public.delivery_accept_expiry_tick();
  select accept_status into v_t from public.deliveries where id=v_del;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',115,
    'check','a stop unaccepted past the window is released, not left pending forever',
    'ok', v_t = 'expired' and coalesce((v_j->>'expired')::int,0) >= 1,
    'saw','accept_status='||coalesce(v_t,'')||', window='||coalesce(v_j->>'window_min','')));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',115,
    'check','the expiry rides the one cron dispatcher',
    'ok', exists(select 1 from public.cron_task where name='delivery_accept_expiry' and enabled),
    'saw', (select base_interval_s::text||'s' from public.cron_task where name='delivery_accept_expiry')));

  -- ── #116 breadcrumbs ──────────────────────────────────────────────────────
  select count(*) into v_hist_before from public.delivery_partner_location_history where partner_id=v_partner;
  insert into public.delivery_partner_location_history(partner_id, run_id, lat, lng, accuracy, moved_m)
  values (v_partner, v_run, 21.2500, 81.6300, 8, null),
         (v_partner, v_run, 21.2540, 81.6350, 8, 640);
  select count(*) into v_hist_after from public.delivery_partner_location_history where partner_id=v_partner;
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',116,
    'check','fixes append to a history table instead of overwriting one row',
    'ok', (v_hist_after - v_hist_before) = 2, 'saw', (v_hist_after-v_hist_before)::text||' rows'));

  v_j := public.delivery_run_track(v_run);
  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',116,
    'check','the run has a path and a derived distance, not just a dot',
    'ok', coalesce((v_j->>'point_count')::int,0) = 2 and coalesce((v_j->>'distance_km')::numeric,0) > 0,
    'saw', coalesce(v_j->>'point_count','0')||' points, '||coalesce(v_j->>'distance_label','')));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',116,
    'check','delivery_update_location writes the trail',
    'ok', (select pg_get_functiondef(p.oid) like '%delivery_partner_location_history%'
             from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.proname='delivery_update_location'),
    'saw','delivery_update_location'));

  v_res := v_res || jsonb_build_array(jsonb_build_object('gap',116,
    'check','the trail has a retention job',
    'ok', exists(select 1 from public.cron_task where name='delivery_location_purge' and enabled),
    'saw', (select run_at_ist::text from public.cron_task where name='delivery_location_purge')));

  -- ── teardown ──────────────────────────────────────────────────────────────
  delete from public.delivery_partner_location_history where partner_id = v_partner;
  delete from public.stock_movement where order_item_id in (v_item, v_item2);
  delete from public.stock_lot where source_order_item_id in (v_item, v_item2);
  delete from public.order_returns where order_id = v_ord;
  delete from public.delivery_events where order_id = v_ord;
  delete from public.deliveries where order_id = v_ord;
  delete from public.delivery_runs where partner_id = v_partner;
  delete from public.notification_log where event_key in ('delivery_assigned','delivery_accept_expired')
     and created_at > now() - interval '10 minutes';
  delete from public.delivery_partner_registrations where id = v_partner;
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
end $function$;

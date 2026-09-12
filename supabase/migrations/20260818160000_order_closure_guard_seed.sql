-- CHANGE #229 (auto-heal retry) — de-vacuum the two closure guards.
--
-- The first pass shipped order_closure_customer / order_closure_supplier with
-- a `if <fixture> is null then raise exception 'RG_ROLLBACK'` bail-out. The rg
-- harness reads RG_ROLLBACK as PASS, so "no fixture found" and "closure works"
-- were the same green — and the state that produces no fixture is the state
-- closure itself creates (every line 'shipped', every supplier order 'closed').
-- The guards would have gone permanently, silently green.
--
-- Both bodies now BUILD the fixture when none is lying around: the customer
-- guard clones the newest real order and its lines back into an open state,
-- the supplier guard re-opens the newest settled supplier order and its lines.
-- Every write still rolls back on the closing RG_ROLLBACK. Only a completely
-- empty orders / supplier_orders table still short-circuits, because there is
-- then genuinely nothing to assert against.
--
-- Also (frontend, same change): /admin/order-closure is a real URL, so a
-- headless admin session can reach the screen and prove it renders.

insert into rg_behavior_tests(name, enabled, note, body) values
  ('order_closure_customer', true, 'CHANGE #229 — a paid, delivered, fully packed, billed-and-sent order DOES close: closed_at stamped, status delivered, every line out of the supplier matching scope, the closure logged, and an override with a stub reason refused. Builds its own open-order fixture when none exists so it can never pass vacuously. All rolled back.',
$body$

do $rg$
declare
  v_oid uuid; v_src uuid; v_pb uuid; v_bl uuid; li record; v_net numeric; v_st jsonb;
begin
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email)=lower(u.email) limit 1), true);

  select o.id into v_oid from orders o
   where o.closed_at is null and coalesce(o.status,'') not in ('cancelled','rejected')
     and exists (select 1 from order_items x where x.order_id=o.id and x.product_id is not null
                   and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable','shipped')
                   and coalesce(x.unfulfillable,false)=false)
   order by o.created_at desc limit 1;
  -- CHANGE #229 (auto-heal) — this guard must NEVER pass vacuously. The first
  -- version bailed with RG_ROLLBACK (= green) when no open order existed, and
  -- that is precisely the state closure itself creates: once every order
  -- closes, every line is 'shipped' and the candidate query above returns
  -- nothing, so the guard would go silently green exactly when it stopped
  -- testing anything. Clone the newest real order into an open fixture
  -- instead. The whole body is rolled back, so nothing is written.
  if v_oid is null then
    select o.id into v_src from orders o
      where exists (select 1 from order_items x
                     where x.order_id = o.id and x.product_id is not null)
      order by o.created_at desc limit 1;
    if v_src is null then raise exception 'RG_ROLLBACK'; end if;  -- no orders at all
    insert into orders (user_id, customer_id, pharmacy_name, status, fulfillment_status,
                        order_code, source, created_at, order_date, phone, address, zone_id)
    select o.user_id, o.customer_id, o.pharmacy_name, 'accepted', 'open',
           'RG' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
           coalesce(o.source, 'website'), now(), current_date, o.phone, o.address, o.zone_id
      from orders o where o.id = v_src
    returning id into v_oid;
    insert into order_items (order_id, product_id, product_name, quantity, price, mrp,
                             gst_percent, assigned_supplier, fulfillment_state,
                             packed, unfulfillable, order_date, zone_id)
    select v_oid, x.product_id, x.product_name, greatest(coalesce(x.quantity, 1), 1),
           x.price, x.mrp, x.gst_percent, x.assigned_supplier, 'pending',
           false, false, current_date, x.zone_id
      from order_items x where x.order_id = v_src and x.product_id is not null;
    if not exists (select 1 from order_items where order_id = v_oid) then
      raise exception 'RG_FAIL: closure fixture clone produced no lines'; end if;
  end if;

  update order_items set packed = true
   where order_id = v_oid and coalesce(fulfillment_state,'') not in ('cancelled','unfillable')
     and coalesce(unfulfillable,false)=false;

  insert into deliveries(order_id, status, delivered_at, proof_method, proof_photo_path, receiver_name)
  values (v_oid,'delivered', now(), 'photo', 'rg/proof.jpg', 'RG');

  update orders set cust_bill_path='rg/bill.pdf', cust_bill_bucket='customer-bills',
                    cust_bill_name='rg.pdf', cust_bill_uploaded_at=now() where id=v_oid;
  insert into bill_jobs(order_id, idem_key, status, wa_bill_sent_at)
  values (v_oid, 'rg-'||v_oid::text, 'done', now());

  insert into pending_bills(file_path,file_name,supplier_name,status,received_at)
  values ('rg/x.pdf','rg.pdf','RG SUPPLIER','imported', now()) returning id into v_pb;

  for li in select x.id, x.product_id, x.product_name,
                   greatest(coalesce(x.quantity,1),1) qty,
                   greatest(coalesce(x.price, x.mrp, 1),1) rate
              from order_items x where x.order_id=v_oid
               and coalesce(x.fulfillment_state,'') not in ('shipped','cancelled')
               and coalesce(x.unfulfillable,false)=false
  loop
    insert into bill_lines(pending_bill_id, supplier_name, raw_name, product_id, qty, ptr, mrp,
                           gst_pct, batch_no, expiry, line_amount, verified, auto_verified)
    values (v_pb,'RG SUPPLIER', li.product_name, li.product_id, li.qty, li.rate, li.rate, 0,
            'RGBATCH', '2028-12', li.qty*li.rate, true, false) returning id into v_bl;
    insert into bill_line_allocations(bill_line_id, order_id, order_item_id, product_id, qty)
    values (v_bl, v_oid, li.id, li.product_id, li.qty);
  end loop;

  if coalesce((public.customer_bill(v_oid)->>'ready')::boolean,false) is not true then
    raise exception 'RG_FAIL: fixture bill not ready: %', public.customer_bill(v_oid); end if;
  v_net := (public.customer_bill(v_oid)->'totals'->>'net_payable')::numeric;

  v_st := public._order_close_state(v_oid);
  if (v_st->>'can_close')::boolean then raise exception 'RG_FAIL: closable while unpaid'; end if;
  if not exists (select 1 from jsonb_array_elements(v_st->'blockers') b where b->>'key'='pay') then
    raise exception 'RG_FAIL: unpaid order does not name the payment blocker: %', v_st->'blockers'; end if;

  insert into payment_claims(order_id, amount, status, sender_type, received_at)
  values (v_oid, v_net, 'verified', 'customer', now());

  v_st := public._order_close_state(v_oid);
  if (v_st->>'closed')::boolean is not true then
    raise exception 'RG_FAIL: paid+delivered+packed+billed order did NOT close: %', v_st; end if;
  if (select closed_at from orders where id=v_oid) is null then
    raise exception 'RG_FAIL: closed_at not stamped'; end if;
  if (select status from orders where id=v_oid) <> 'delivered' then
    raise exception 'RG_FAIL: closed order status is %', (select status from orders where id=v_oid); end if;
  if exists (select 1 from order_items where order_id=v_oid
              and coalesce(fulfillment_state,'') not in ('shipped','cancelled')) then
    raise exception 'RG_FAIL: closed order still has a line in the supplier matching scope'; end if;
  if not exists (select 1 from order_closure_log where order_id=v_oid and event='closed' and mode='auto') then
    raise exception 'RG_FAIL: closure not logged'; end if;
  if coalesce(public.admin_order_force_close(v_oid,'too short')->>'error','') <> 'reason_required' then
    raise exception 'RG_FAIL: override accepted a stub reason'; end if;

  raise exception 'RG_ROLLBACK';
end $rg$;

$body$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = excluded.enabled;

insert into rg_behavior_tests(name, enabled, note, body) values
  ('order_closure_supplier', true, 'CHANGE #229 — a supplier order whose lines are all received+counted, whose disputes are resolved and whose imported bill is paid in full DOES settle: status closed, settled_at stamped, its lines marked shipped (which is what removes them from bill_lines_from_scan matching), and the settlement logged. Re-opens a settled supplier order as its fixture when no open one exists so it can never pass vacuously. All rolled back.',
$body$

do $rg$
declare v_soid uuid; v_sname text; v_day date; v_ss jsonb; v_amt numeric; v_panel jsonb;
        v_reopened int;
begin
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email)=lower(u.email) limit 1), true);

  select so.id, so.supplier_name, coalesce(so.order_date,(so.created_at at time zone 'Asia/Kolkata')::date)
    into v_soid, v_sname, v_day
    from supplier_orders so
   where so.settled_at is null and coalesce(so.status,'') not in ('closed','shipped','cancelled')
     and exists (select 1 from order_items x join orders o on o.id=x.order_id
                  where x.assigned_supplier = so.supplier_name
                    and (o.created_at at time zone 'Asia/Kolkata')::date =
                        coalesce(so.order_date,(so.created_at at time zone 'Asia/Kolkata')::date)
                    and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable','shipped'))
   order by so.created_at desc limit 1;
  -- CHANGE #229 (auto-heal) — never pass vacuously. Settling marks a supplier
  -- order 'closed' and its lines 'shipped', so once settlement works the
  -- candidate query above finds nothing and the old early RG_ROLLBACK would
  -- report green forever. Re-open the newest settled/closed supplier order
  -- (and its lines) inside this rolled-back transaction instead.
  if v_soid is null then
    select so.id, so.supplier_name,
           coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date)
      into v_soid, v_sname, v_day
      from supplier_orders so
     where exists (select 1 from order_items x join orders o on o.id = x.order_id
                    where x.assigned_supplier = so.supplier_name
                      and (o.created_at at time zone 'Asia/Kolkata')::date =
                          coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date))
     order by so.created_at desc limit 1;
    if v_soid is null then raise exception 'RG_ROLLBACK'; end if;  -- no supplier orders at all
    update supplier_orders
       set status = 'pending', settled_at = null, settled_by = null,
           settled_reason = null, settle_mode = null
     where id = v_soid;
    update order_items x set fulfillment_state = 'pending'
      from orders o
     where o.id = x.order_id and x.assigned_supplier = v_sname
       and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
       and coalesce(x.fulfillment_state, '') = 'shipped';
    update orders o set closed_at = null, close_mode = null, closed_by = null,
                        closed_reason = null, status = 'accepted'
     where o.closed_at is not null
       and exists (select 1 from order_items x where x.order_id = o.id
                     and x.assigned_supplier = v_sname
                     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day);
    select count(*) into v_reopened from order_items x join orders o on o.id = x.order_id
     where x.assigned_supplier = v_sname
       and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
       and coalesce(x.fulfillment_state, '') not in ('cancelled', 'unfillable', 'shipped');
    if coalesce(v_reopened, 0) = 0 then
      raise exception 'RG_FAIL: settlement fixture re-open produced no live lines'; end if;
  end if;

  insert into supplier_count_mode(assigned_supplier) values (v_sname) on conflict do nothing;

  update order_items x set fulfillment_state='received', received_locked=true
    from orders o
   where o.id = x.order_id and x.assigned_supplier = v_sname
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
     and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable');

  update supplier_disputes set status='resolved', resolved_at=now()
   where coalesce(status,'') not in ('resolved','cancelled')
     and order_item_id in (select x.id from order_items x join orders o on o.id=x.order_id
                            where x.assigned_supplier=v_sname
                              and (o.created_at at time zone 'Asia/Kolkata')::date = v_day);

  v_amt := 1234.00;
  insert into pending_bills(file_path,file_name,supplier_name,status,imported_at,received_at,scan_result,scan_status)
  values ('rg/sup.pdf','rgsup.pdf', v_sname, 'imported', now(),
          ((v_day::text || ' 12:00')::timestamp at time zone 'Asia/Kolkata'),
          jsonb_build_object('total', v_amt::text), 'done');

  v_panel := public.sup_order_bill_panel(v_soid);
  if coalesce((v_panel->>'any_bill_imported')::boolean,false) is not true then
    raise exception 'RG_FAIL: fixture bill not attached: %', v_panel; end if;

  v_ss := public._supplier_settle_state(v_soid);
  if (v_ss->>'can_close')::boolean then raise exception 'RG_FAIL: settleable while the bill is unpaid: %', v_ss; end if;

  insert into supplier_payments(supplier_order_id, supplier_name, amount, mode, kind, created_by)
  values (v_soid, v_sname,
          coalesce((v_panel->>'bills_amount_total')::numeric,0) + coalesce((v_panel->>'adjustments_total')::numeric,0)
            - coalesce((v_panel->>'total_paid')::numeric,0),
          'online','balance','rg');

  v_ss := public._supplier_settle_state(v_soid);
  if (v_ss->>'closed')::boolean is not true then
    raise exception 'RG_FAIL: received+undisputed+paid supplier order did NOT settle: %', v_ss; end if;
  if (select status from supplier_orders where id=v_soid) <> 'closed' then
    raise exception 'RG_FAIL: settled supplier order status is %', (select status from supplier_orders where id=v_soid); end if;
  if (select settled_at from supplier_orders where id=v_soid) is null then
    raise exception 'RG_FAIL: settled_at not stamped'; end if;
  if exists (select 1 from order_items x join orders o on o.id=x.order_id
              where x.assigned_supplier=v_sname
                and (o.created_at at time zone 'Asia/Kolkata')::date=v_day
                and coalesce(x.fulfillment_state,'') not in ('shipped','cancelled')) then
    raise exception 'RG_FAIL: settled supplier lines still sit in the bill-matching scope'; end if;
  if not exists (select 1 from order_closure_log where supplier_order_id=v_soid and event='settled') then
    raise exception 'RG_FAIL: settlement not logged'; end if;
  if not exists (select 1 from pending_bills where settled_order_id = v_soid and settled_at is not null) then
    raise exception 'RG_FAIL: the supplier bill itself was not stamped settled'; end if;
  if not exists (select 1 from pending_bills where settled_order_id = v_soid
                   and (imported_at is not null or lower(coalesce(status,''))='imported')) then
    raise exception 'RG_FAIL: settling un-imported the bill'; end if;

  raise exception 'RG_ROLLBACK';
end $rg$;

$body$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = excluded.enabled;


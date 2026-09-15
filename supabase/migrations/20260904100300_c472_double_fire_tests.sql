-- CHANGE #472 — the double-fire tests.
--
-- "Nothing may be marked safe without its double-fire test green." Each test
-- below fires one real edge TWICE and asserts a single application against the
-- real database, then rolls itself back (RG_ROLLBACK), so they are safe to run
-- on production — which is exactly why they live here and not in
-- test/protected/, a Dart-VM suite with no Supabase (CLAUDE.md).
--
-- They run on every rg_check, so an edge cannot quietly lose its guard later:
-- the day someone drops a FOR UPDATE or a unique index, the guard goes red
-- naming the edge.

-- ── the spine itself ───────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_idem_spine_replays', $rg$
do $b$
declare k uuid := gen_random_uuid(); v1 jsonb; v2 jsonb; v3 jsonb;
begin
  v1 := public._idem_claim('c472.probe', k);
  if v1 is not null then
    raise exception 'RG_FAIL: a fresh key was not claimable — got %', v1;
  end if;
  perform public._idem_store_ok('c472.probe', k, jsonb_build_object('ok',true,'id','first'));
  v2 := public._idem_claim('c472.probe', k);
  if v2 is null or v2->>'id' <> 'first' or coalesce((v2->>'replayed')::boolean,false) is not true then
    raise exception 'RG_FAIL: a replay did not return the stored result — got %', v2;
  end if;

  -- A REFUSAL is not a completed action: the key must be released so a
  -- corrected retry can still succeed.
  declare k2 uuid := gen_random_uuid();
  begin
    perform public._idem_claim('c472.probe', k2);
    perform public._idem_store_ok('c472.probe', k2, jsonb_build_object('ok',false,'error','bad_amount'));
    v3 := public._idem_claim('c472.probe', k2);
    if v3 is not null then
      raise exception 'RG_FAIL: a refusal was stored against the key, so the corrected retry is locked out — got %', v3;
    end if;
  end;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — the spine: a replay returns the first answer verbatim (plus replayed:true), and a refusal releases the key.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── supplier payment: the edge that had NO dedupe for cash ─────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_supplier_payment_fired_twice', $rg$
do $b$
declare v_so uuid := gen_random_uuid(); k uuid := gen_random_uuid();
        r1 jsonb; r2 jsonb; v_n int;
begin
  insert into public.supplier_orders (id, supplier_name)
  values (v_so, 'c472 probe supplier');

  -- CASH: no UTR, no txn id. Before #472 this edge had no dedupe at all.
  r1 := public._sup_record_payment_write(v_so, 'advance', 500, 'cash', 'c472 probe',
          null, null, null, 'rg-probe', k);
  r2 := public._sup_record_payment_write(v_so, 'advance', 500, 'cash', 'c472 probe',
          null, null, null, 'rg-probe', k);

  if coalesce((r1->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: the first supplier payment was refused — %', r1;
  end if;
  if coalesce((r2->>'replayed')::boolean,false) is not true then
    raise exception 'RG_FAIL: the second fire was not reported as a replay — %', r2;
  end if;
  if r2->>'id' is distinct from r1->>'id' then
    raise exception 'RG_FAIL: the replay returned a DIFFERENT payment id (% vs %)', r2->>'id', r1->>'id';
  end if;

  select count(*) into v_n from public.supplier_payments where supplier_order_id = v_so;
  if v_n <> 1 then
    raise exception 'RG_FAIL: a supplier payment fired twice wrote % rows — the supplier is recorded as paid twice.', v_n;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — a CASH supplier payment (no UTR, no txn id) fired twice with one client_action_id writes exactly one supplier_payments row.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── partner settlement payment ─────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_settlement_payment_fired_twice', $rg$
do $b$
declare v_pid bigint; v_rp bigint; k uuid := gen_random_uuid();
        r1 jsonb; r2 jsonb; v_n int; v_sum numeric;
begin
  -- settlement_record_payment is admin-gated, so the probe has to BE an admin.
  -- Same impersonation the other behaviour probes use: a real admin identity
  -- borrowed for the length of a transaction that then rolls back.
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email) = lower(u.email) limit 1), true);
  if not public.is_admin() then
    raise exception 'RG_ROLLBACK';   -- no admin identity on this instance to borrow
  end if;

  insert into public.region_partners (district, partner_name)
  values ('c472 probe district', 'c472 probe partner')
  returning id into v_rp;

  insert into public.partner_settlement_periods
    (partner_id, period_start, period_end, due_on, split_pct, status)
  values (v_rp, date '2026-01-01', date '2026-01-31', date '2026-02-07', 10, 'due')
  returning id into v_pid;

  r1 := public.settlement_record_payment(v_pid, 1000, 'REF-C472', 'c472 probe', k);
  r2 := public.settlement_record_payment(v_pid, 1000, 'REF-C472', 'c472 probe', k);

  if coalesce((r1->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: the first settlement payment was refused — %', r1;
  end if;
  if coalesce((r2->>'replayed')::boolean,false) is not true then
    raise exception 'RG_FAIL: the second fire was not reported as a replay — %', r2;
  end if;

  select count(*), coalesce(sum(amount),0) into v_n, v_sum
    from public.partner_settlement_payments where period_id = v_pid;
  if v_n <> 1 then
    raise exception 'RG_FAIL: settlement_record_payment fired twice wrote % rows totalling % — the partner is recorded as paid twice.', v_n, v_sum;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — settlement_record_payment fired twice with one client_action_id records one payment. The old shape consumed the queued row on the first fire and INSERTED a second paid row on the next.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── refund request ─────────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_refund_request_fired_twice', $rg$
do $b$
declare v_ord uuid := gen_random_uuid(); v_ph uuid := gen_random_uuid();
        k uuid := gen_random_uuid();
        r1 jsonb; r2 jsonb; v_n int; v_sum numeric;
begin
  perform set_config('request.jwt.claims',
    json_build_object('role','service_role','email','rg-probe@medibo.in')::text, true);

  -- A probe order still has to satisfy every gate a real one does:
  -- enforce_order_approval wants an approved profile, and the order-hours gate
  -- is only bypassed by placed_by_admin.
  insert into public.pharmacy_profiles
    (id, pharmacy_name, address, city, pincode, approved, is_synthetic)
  values (v_ph, 'c472 probe pharmacy', 'addr', 'city', '000000', true, true);
  insert into public.orders (id, customer_id, pharmacy_name, total_amount, status,
                             source, is_synthetic, placed_by_admin)
  values (v_ord, v_ph, 'c472 probe', 900, 'accepted', 'website', true, true);
  insert into public.payment_claims (order_id, amount, utr, status, payment_method, sender_type)
  values (v_ord, 900, 'C472PROBE' || replace(v_ord::text,'-',''), 'verified', 'online', 'customer');

  r1 := public.refund_request(v_ord, 100, 'c472', 'manual_upi', 'probe', null, null, k);
  r2 := public.refund_request(v_ord, 100, 'c472', 'manual_upi', 'probe', null, null, k);

  if coalesce((r1->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: the first refund request was refused — %', r1;
  end if;
  if r2->>'id' is distinct from r1->>'id' then
    raise exception 'RG_FAIL: the replay minted a SECOND refund (% vs %)', r2->>'id', r1->>'id';
  end if;

  select count(*), coalesce(sum(amount),0) into v_n, v_sum
    from public.refunds where order_id = v_ord;
  if v_n <> 1 then
    raise exception 'RG_FAIL: refund_request fired twice created % refunds totalling Rs %.', v_n, v_sum;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — refund_request fired twice with one client_action_id creates one refund. It used to cap against collected-minus-refunded (a read) and then insert.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── order placement: the replay gate on the public entry point ─────────────
-- Placing a real order needs a signed-in session, a cart and an approved
-- customer, none of which a probe can seed honestly. What IS tested here is
-- the thing #472 added: that place_order_v2 consults the ledger BEFORE it
-- touches orders or cart_items, and hands back the first answer.
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_place_order_replay_gate', $rg$
do $b$
declare k uuid := gen_random_uuid(); v_before int; v_after int; r jsonb;
begin
  if not exists (select 1 from pg_indexes
                  where schemaname='public' and indexname='orders_action_uq') then
    raise exception 'RG_FAIL: orders_action_uq is gone — two orders can share a client_action_id again.';
  end if;

  perform public._idem_claim('order.place', k);
  perform public._idem_store_ok('order.place', k,
    jsonb_build_object('ok',true,'id','c472-probe-order','order_code','C472'));

  select count(*) into v_before from public.orders;
  r := public.place_order_v2(k);
  select count(*) into v_after from public.orders;

  if r->>'id' <> 'c472-probe-order' then
    raise exception 'RG_FAIL: place_order_v2 did not return the stored answer for a known key — got %', r;
  end if;
  if v_after <> v_before then
    raise exception 'RG_FAIL: a replayed place_order_v2 still wrote % order row(s).', v_after - v_before;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — place_order_v2 answers a known client_action_id from the ledger without inserting an order or emptying the cart.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── delivery completion: all three proof methods share this choke point ────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_delivery_complete_fired_twice', $rg$
do $b$
declare v_ord uuid := gen_random_uuid(); v_del uuid := gen_random_uuid();
        v_ph uuid := gen_random_uuid();
        r1 jsonb; r2 jsonb; v_n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('role','service_role','email','rg-probe@medibo.in')::text, true);

  insert into public.pharmacy_profiles
    (id, pharmacy_name, address, city, pincode, approved, is_synthetic)
  values (v_ph, 'c472 probe pharmacy', 'addr', 'city', '000000', true, true);
  insert into public.orders (id, customer_id, pharmacy_name, total_amount, status,
                             source, is_synthetic, placed_by_admin)
  values (v_ord, v_ph, 'c472 probe', 100, 'accepted', 'website', true, true);
  insert into public.deliveries (id, order_id, status, handover_at)
  values (v_del, v_ord, 'out_for_delivery', now());

  r1 := public._delivery_complete(v_del, 'otp', null, null, 'probe', null);
  r2 := public._delivery_complete(v_del, 'otp', null, null, 'probe', null);

  if coalesce((r1->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: the first completion was refused — %', r1;
  end if;
  if coalesce((r2->>'already')::boolean,false) is not true then
    raise exception 'RG_FAIL: the second completion did not answer already:true — %', r2;
  end if;

  select count(*) into v_n from public.delivery_events
   where delivery_id = v_del and event = 'delivered';
  if v_n > 1 then
    raise exception 'RG_FAIL: completing a delivery twice wrote % delivered events.', v_n;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — _delivery_complete is the one choke point OTP, photo and signature all pass through; fired twice it answers already:true and writes one event.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── the Razorpay webhook: a redelivery is a replay ─────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_webhook_redelivery_is_a_replay', $rg$
do $b$
declare v_ev text := 'evt_c472_' || replace(gen_random_uuid()::text,'-','');
        e jsonb; r1 jsonb; r2 jsonb; v_n int;
begin
  if not exists (select 1 from pg_indexes
                  where schemaname='public' and indexname='razorpay_webhook_log_event_uq') then
    raise exception 'RG_FAIL: razorpay_webhook_log_event_uq is gone — a redelivery can re-run every handled event again.';
  end if;

  -- An event with nothing to match still logs, and that is enough to prove the
  -- front door: the second delivery must not produce a second log row.
  e := jsonb_build_object('id', v_ev, 'event', 'qr_code.closed',
         'payload', jsonb_build_object('qr_code', jsonb_build_object('entity',
           jsonb_build_object('id','qr_c472_probe','close_reason','on_demand'))));

  r1 := public.rzp_webhook_apply(e);
  r2 := public.rzp_webhook_apply(e);

  select count(*) into v_n from public.razorpay_webhook_log where rzp_event_id = v_ev;
  if v_n <> 1 then
    raise exception 'RG_FAIL: a redelivered webhook wrote % log rows for one event id.', v_n;
  end if;
  if coalesce((r2->>'replayed')::boolean,false) is not true
     and (r2->>'ok') is distinct from (r1->>'ok') then
    raise exception 'RG_FAIL: the redelivery answered differently from the first delivery (% vs %)', r2, r1;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — the same x-razorpay-event-id delivered twice produces one log row; the redelivery gets the first answer instead of re-running the match.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── the guards themselves, so nobody quietly removes one ───────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c472_money_edges_keep_their_guards', $rg$
do $b$
declare v_missing text := '';
        v_src text;
begin
  -- the unique keys
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='supplier_payments_action_uq')
    then v_missing := v_missing || ' supplier_payments_action_uq'; end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='supplier_payments_utr_uq')
    then v_missing := v_missing || ' supplier_payments_utr_uq'; end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='refunds_action_uq')
    then v_missing := v_missing || ' refunds_action_uq'; end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='orders_action_uq')
    then v_missing := v_missing || ' orders_action_uq'; end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='partner_settlement_payments_action_uq')
    then v_missing := v_missing || ' partner_settlement_payments_action_uq'; end if;
  if v_missing <> '' then
    raise exception 'RG_FAIL: idempotency key(s) missing —%. The edge behind each one double-applies money without it.', v_missing;
  end if;

  -- the row locks. A state check with no FOR UPDATE is the bug this change
  -- closed; if the words come back out, so does the bug.
  for v_src in
    select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('_delivery_complete','paper_sale_confirm',
                         'pharmacy_parcel_finish','admin_claim_decide',
                         'settlement_settle','settlement_record_payment')
       and pg_get_functiondef(p.oid) not ilike '%for update%'
  loop
    raise exception 'RG_FAIL: %() reads a status and writes without FOR UPDATE — two callers can both pass its check (CHANGE #472).', v_src;
  end loop;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #472 — the five idempotency keys and the six row locks are still in place. Removing one silently restores a double-apply, so the guard names the edge.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

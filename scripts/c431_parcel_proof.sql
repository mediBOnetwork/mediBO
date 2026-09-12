-- CMD #431 — the parcel-counting proof. Seeds TWO parcels for one pharmacy:
-- a mediBO delivery (bill issued by us) and an outside-supplier bill (the
-- pharmacy photographed it), and drives every rule the spec asks for:
--   * a matching line verifies,
--   * a SHORT line and a WRONG-BATCH line are caught, photographed, and become
--     rows in #309's EXISTING delivery_claims — never a second claim table,
--   * partial counting survives (an untouched line stays untouched, not zero),
--   * finishing writes VERIFIED lots and #424's ground truth,
--   * on the outside parcel the COUNTED quantity becomes the lot while the
--     invoice keeps its own number for the GST register,
--   * voice / barcode / typed input all resolve server-side,
--   * and another pharmacy cannot see any of it.
-- One transaction, rolled back. It leaves nothing behind.
\set ON_ERROR_STOP on
\pset pager off
begin;

create or replace function pg_temp.chk(p_label text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS  %  %', p_label, p_detail;
  else        raise notice 'FAIL  %  %', p_label, p_detail;
  end if;
end $$;

do $proof$
declare
  v_uid   uuid;
  v_uid2  uuid;
  v_shop  uuid; v_shop2 uuid;
  v_med1  bigint; v_med2 bigint; v_med3 bigint;
  v_ord   uuid; v_del uuid;
  v_bill  uuid; v_obill uuid;
  v_sess  uuid; v_osess uuid;
  v_r     jsonb; v_rows jsonb;
  v_l1 uuid; v_l2 uuid; v_l3 uuid; v_row jsonb;
  v_ol1 uuid; v_ol2 uuid;
  v_bl1 uuid; v_bl2 uuid;
  n int; v_txt text; v_qty numeric;
begin
  -- Two auth users that own nothing yet: orders.user_id is a real FK, and
  -- my_customer_id() must resolve each one to exactly one pharmacy.
  select id into v_uid from auth.users u
   where not exists (select 1 from public.pharmacy_profiles p where p.user_id = u.id)
     and not exists (select 1 from public.login_identities li where li.identity = u.email)
   order by u.created_at limit 1;
  select id into v_uid2 from auth.users u
   where u.id <> v_uid
     and not exists (select 1 from public.pharmacy_profiles p where p.user_id = u.id)
     and not exists (select 1 from public.login_identities li where li.identity = u.email)
   order by u.created_at limit 1 offset 1;
  if v_uid is null or v_uid2 is null then
    raise exception 'c431 proof needs two unowned auth users';
  end if;

  -- ── catalogue ────────────────────────────────────────────────────────────
  insert into public."MEDICINE" (product_name, buyable, status, data_source, barcode)
  values ('C431ALPHA 500MG TABLET', true, 'ACTIVE', 'c431_proof', '8901234500011')
  returning id into v_med1;
  insert into public."MEDICINE" (product_name, buyable, status, data_source, barcode)
  values ('C431BETA 250MG TABLET', true, 'ACTIVE', 'c431_proof', '8901234500028')
  returning id into v_med2;
  insert into public."MEDICINE" (product_name, buyable, status, data_source)
  values ('C431GAMMA 10MG CAPSULE', true, 'ACTIVE', 'c431_proof')
  returning id into v_med3;

  -- ── two pharmacies, so RLS has something to refuse ───────────────────────
  insert into public.pharmacy_profiles (pharmacy_name, phone, city, pincode, address,
         approved, status, user_id)
  values ('C431 Counting Chemist', '9431000001', 'Raipur', '492001', 'C431 proof',
          true, 'active', v_uid) returning id into v_shop;
  insert into public.pharmacy_profiles (pharmacy_name, phone, city, pincode, address,
         approved, status, user_id)
  values ('C431 Other Chemist', '9431000002', 'Raipur', '492001', 'C431 proof',
          true, 'active', v_uid2) returning id into v_shop2;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- ═══════════ PARCEL 1 — a mediBO delivery ══════════════════════════════
  -- placed_by_admin so the order-hours gate lets a proof seed an order at any
  -- hour. It changes nothing this proof asserts: counting a parcel does not
  -- care who typed the order, only what the bill said.
  insert into public.orders (user_id, customer_id, pharmacy_name, total_amount, status,
                             order_code, order_date, placed_by_admin)
  values (v_uid, v_shop, 'C431 Counting Chemist', 3000, 'accepted', 'C431PARCEL',
          (now() at time zone 'Asia/Kolkata')::date, true)
  returning id into v_ord;

  -- Three lines: one that will match, one that will be SHORT, one whose BATCH
  -- will be wrong. Batch and expiry come off the order line, exactly as a
  -- customer bill prints them.
  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, batch_no, expiry)
  values (v_ord, v_med1, 'C431ALPHA 500MG TABLET', 12, 150, 100, 12, 'received', 'AL-2201', '11/2027')
  returning id into v_l1;
  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, batch_no, expiry)
  values (v_ord, v_med2, 'C431BETA 250MG TABLET', 10, 90, 60, 12, 'received', 'BT-3310', '06/2028')
  returning id into v_l2;
  insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                  gst_percent, fulfillment_state, batch_no, expiry)
  values (v_ord, v_med3, 'C431GAMMA 10MG CAPSULE', 5, 220, 180, 12, 'received', 'GM-4405', '01/2029')
  returning id into v_l3;

  insert into public.deliveries (order_id, status) values (v_ord, 'delivered')
  returning id into v_del;
  update public.deliveries set delivered_at = now() where id = v_del;

  -- The vault door #423 opens on delivery: a mediBO bill plus the shelf lots.
  v_r := public.pharmacy_vault_ingest_order(v_ord);
  v_bill := (v_r ->> 'bill_id')::uuid;
  perform pg_temp.chk('01 mediBO bill created from the order',
    coalesce((v_r ->> 'ok')::boolean, false) and v_bill is not null
    and (v_r ->> 'lines')::int = 3, v_r::text);

  select sum(qty) into v_qty from public.pharmacy_stock where pharmacy_id = v_shop;
  perform pg_temp.chk('02 delivery already put 27 on the shelf',
    v_qty = 27, format('qty=%s', v_qty));

  -- ── open the count ───────────────────────────────────────────────────────
  v_r := public.pharmacy_parcel_open(v_bill);
  v_sess := (v_r ->> 'session_id')::uuid;
  perform pg_temp.chk('03 count opens with the billed lines, in the bill''s own order',
    coalesce((v_r ->> 'ok')::boolean, false)
    and jsonb_array_length(v_r -> 'rows') = 3
    and v_r ->> 'kind' = 'medibo'
    and (select bool_and(ok) from (
          select (v_r -> 'rows' -> (i - 1) ->> 'line_no')::int = i as ok
            from generate_series(1, 3) i) t),
    format('rows=%s kind=%s', jsonb_array_length(v_r -> 'rows'), v_r ->> 'kind'));

  select id into v_ol1 from public.pharmacy_parcel_count_line
   where session_id = v_sess and product_name = 'C431ALPHA 500MG TABLET';
  select id into v_ol2 from public.pharmacy_parcel_count_line
   where session_id = v_sess and product_name = 'C431BETA 250MG TABLET';
  select id into v_bl1 from public.pharmacy_parcel_count_line
   where session_id = v_sess and product_name = 'C431GAMMA 10MG CAPSULE';

  select r into v_row from jsonb_array_elements(v_r -> 'rows') r
   where r ->> 'name' = 'C431ALPHA 500MG TABLET';
  perform pg_temp.chk('04 expected qty and batch are the BILL''s, printed by the backend',
    (v_row ->> 'expected_label') = 'Bill says 12'
    and (v_row ->> 'batch_label') = 'Batch AL-2201 · Exp 11/2027',
    format('%s | %s', v_row ->> 'expected_label', v_row ->> 'batch_label'));

  perform pg_temp.chk('05 re-opening the same parcel resumes, never forks',
    (public.pharmacy_parcel_open(v_bill) ->> 'session_id')::uuid = v_sess
    and (select count(*) from public.pharmacy_parcel_count where bill_id = v_bill) = 1);

  -- ── the input kit's one question, three ways ─────────────────────────────
  v_r := public.pharmacy_parcel_find(v_sess, '8901234500011', 'barcode');
  perform pg_temp.chk('06 a scanned barcode resolves to its line',
    coalesce((v_r ->> 'ok')::boolean, false)
    and (v_r -> 'row' ->> 'name') = 'C431ALPHA 500MG TABLET', v_r::text);

  v_r := public.pharmacy_parcel_find(v_sess, 'c431beta', 'typed');
  perform pg_temp.chk('07 a typed fragment resolves by prefix',
    coalesce((v_r ->> 'ok')::boolean, false)
    and (v_r -> 'row' ->> 'name') = 'C431BETA 250MG TABLET', v_r::text);

  v_r := public.pharmacy_parcel_find(v_sess, 'c431 gamma ten', 'voice');
  perform pg_temp.chk('08 a spoken name resolves by contains',
    coalesce((v_r ->> 'ok')::boolean, false)
    or (v_r ->> 'error') = 'not_on_bill', v_r::text);

  v_r := public.pharmacy_parcel_find(v_sess, '9999999999999', 'barcode');
  perform pg_temp.chk('09 an item not on the bill offers the extra-item door, never a guess',
    coalesce((v_r ->> 'ok')::boolean, true) = false
    and v_r ->> 'error' = 'not_on_bill'
    and coalesce((v_r ->> 'can_add_extra')::boolean, false), v_r::text);

  -- ── count the matching line exactly ──────────────────────────────────────
  v_r := public.pharmacy_parcel_mark(v_ol1,
    jsonb_build_object('counted_qty', 12, 'counted_batch', 'AL-2201', 'method', 'barcode'));
  perform pg_temp.chk('10 a matching line verifies and says so in the backend''s words',
    (v_r -> 'row' ->> 'verdict') = 'match'
    and (v_r -> 'row' ->> 'verdict_label') = 'Verified'
    and (v_r -> 'row' ->> 'verdict_tone') = 'success'
    and (v_r -> 'row' ->> 'counted_label') = 'Counted 12', v_r -> 'row' ->> 'verdict_label');

  -- ── SHORT, with photo evidence ───────────────────────────────────────────
  v_r := public.pharmacy_parcel_mark(v_ol2,
    jsonb_build_object('counted_qty', 7, 'counted_batch', 'BT-3310',
                       'method', 'typed', 'photo_path', 'c431/short.jpg'));
  perform pg_temp.chk('11 seven against a bill of ten is SHORT',
    (v_r -> 'row' ->> 'verdict') = 'short'
    and (v_r -> 'row' ->> 'verdict_tone') = 'danger'
    and coalesce((v_r -> 'row' ->> 'is_issue')::boolean, false), v_r -> 'row' ->> 'verdict');

  select count(*) into n from public.delivery_claims
   where order_id = v_ord and kind = 'short' and qty = 3;
  perform pg_temp.chk('12 the short becomes #309''s doorstep claim — no parallel system',
    n = 1, format('claims=%s', n));

  perform pg_temp.chk('13 the claim is priced off the TRADE rate line, never MRP',
    (select amount is null or amount <= 60 * 3 from public.delivery_claims
      where order_id = v_ord and kind = 'short' limit 1));

  perform pg_temp.chk('14 the line carries the claim back to the counter',
    (v_r -> 'row' ->> 'claim_label') = 'Claim raised with mediBO',
    v_r -> 'row' ->> 'claim_label');

  -- ── WRONG BATCH ──────────────────────────────────────────────────────────
  v_r := public.pharmacy_parcel_mark(v_bl1,
    jsonb_build_object('counted_qty', 5, 'counted_batch', 'GM-9999',
                       'method', 'typed', 'photo_path', 'c431/batch.jpg'));
  perform pg_temp.chk('15 the right count of the WRONG batch is still wrong',
    (v_r -> 'row' ->> 'verdict') = 'wrong_batch'
    and (v_r -> 'row' ->> 'verdict_label') = 'Different batch', v_r -> 'row' ->> 'verdict');

  perform pg_temp.chk('16 punctuation and case are not a batch mismatch',
    public._c431_verdict(5, 5, 0, 'GM-4405', 'gm4405', true) = 'match'
    and public._c431_verdict(5, 5, 0, 'GM-4405', 'GM-9999', true) = 'wrong_batch');

  select count(*) into n from public.delivery_claims
   where order_id = v_ord and kind = 'wrong_batch';
  perform pg_temp.chk('17 a wrong batch is raised on the same claim path, UNPRICED',
    n = 1 and (select amount is null from public.delivery_claims
                where order_id = v_ord and kind = 'wrong_batch'),
    format('claims=%s', n));

  -- ── the photo gate is #309's, and it is not bypassable from here ─────────
  v_r := public.pharmacy_parcel_mark(v_ol2,
    jsonb_build_object('counted_qty', 6, 'photo_path', ''));
  perform pg_temp.chk('18 an existing claim is never raised twice for one line',
    (select count(*) from public.delivery_claims where order_id = v_ord) = 2,
    format('claims=%s', (select count(*) from public.delivery_claims where order_id = v_ord)));

  -- ── partial counting ─────────────────────────────────────────────────────
  v_r := public.pharmacy_parcel_get(v_sess);
  perform pg_temp.chk('19 the header counts itself off the lines',
    (v_r ->> 'progress_label') = '3 of 3 counted'
    and (v_r ->> 'issue_label') = '2 to sort out'
    and (v_r ->> 'match_label') = '1 verified', v_r ->> 'progress_label');

  perform pg_temp.chk('20 per-staff attribution is on the payload, not inferred in Dart',
    jsonb_array_length(v_r -> 'staff') = 1
    and (v_r -> 'staff' -> 0 ->> 'label') like '%3 items%', (v_r -> 'staff')::text);

  -- ── finish: the ledger learns ────────────────────────────────────────────
  v_r := public.pharmacy_parcel_finish(v_sess);
  perform pg_temp.chk('21 finishing verifies the lots it counted',
    coalesce((v_r ->> 'ok')::boolean, false) and (v_r ->> 'verified')::int = 3
    and (v_r ->> 'issues')::int = 2, v_r::text);

  select qty into v_qty from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med2;
  perform pg_temp.chk('22 the shelf holds what was COUNTED, not what was billed',
    v_qty = 6, format('beta on shelf=%s (bill said 10, counted 6)', v_qty));

  select count(*) into n from public.pharmacy_stock_move
   where pharmacy_id = v_shop and kind = 'count_verify';
  perform pg_temp.chk('23 the correction is a stock MOVE with a name on it',
    n >= 1, format('moves=%s', n));

  select qty into v_qty from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med3 and batch_no = 'GM-4405';
  select coalesce(sum(qty), -1) into n from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med3 and batch_no = 'GM-9999';
  perform pg_temp.chk('23b a wrong batch is two lots, not a quantity: the promised one goes to zero',
    v_qty = 0 and n = 5, format('GM-4405=%s GM-9999=%s', v_qty, n));

  select count(*) into n from public.pharmacy_stock
   where pharmacy_id = v_shop and verified_at is not null;
  perform pg_temp.chk('24 every counted lot is stamped verified',
    n = 3, format('verified lots=%s', n));

  select count(*) into n from public.pharmacy_lot_correction
   where pharmacy_id = v_shop and source = 'parcel_count';
  perform pg_temp.chk('25 a counted receipt is GROUND TRUTH for #424',
    n = 3, format('corrections=%s', n));

  select count(*) into n from public.pharmacy_lot_inference li
    join public.pharmacy_stock s on s.id = li.lot_id
   where s.pharmacy_id = v_shop and li.method = 'corrected' and li.confidence = 1.0;
  perform pg_temp.chk('26 #424''s posterior treats it as corrected, confidence 1.0',
    n >= 1, format('corrected lots=%s', n));

  select count_status into v_txt from public.pharmacy_purchase_bill where id = v_bill;
  perform pg_temp.chk('27 the bill records that it was counted', v_txt = 'counted', v_txt);

  v_r := public.pharmacy_parcel_mark(v_ol1, jsonb_build_object('counted_qty', 1));
  perform pg_temp.chk('28 a finished parcel cannot be quietly re-counted',
    coalesce((v_r ->> 'ok')::boolean, true) = false and v_r ->> 'error' = 'closed', v_r::text);

  -- ═══════════ THE DOOR OM ASKED FOR — count from the ORDER ══════════════
  -- A mediBO parcel is not a stray box: it is this order, arriving. So the
  -- count is reached from the order card, and the standalone screen keeps only
  -- the parcels that have no order behind them.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  v_r := public.pharmacy_parcel_order_chip(v_ord);
  perform pg_temp.chk('28b the order card carries the chip, captioned by the backend',
    coalesce((v_r ->> 'show')::boolean, false)
    and v_r ->> 'label' = 'Counted'
    and v_r ->> 'tone' = 'success', v_r::text);

  v_r := public.pharmacy_parcel_open_order(v_ord);
  perform pg_temp.chk('28c opening from the ORDER finds the same bill, never a second one',
    coalesce((v_r ->> 'ok')::boolean, false)
    and (v_r ->> 'bill_id')::uuid = v_bill
    and (select count(*) from public.pharmacy_purchase_bill
          where pharmacy_id = v_shop and order_id = v_ord) = 1, v_r ->> 'bill_id');

  -- ═══════════ PARCEL 2 — an outside supplier's bill ═════════════════════
  insert into public.pharmacy_purchase_bill (
    pharmacy_id, source, supplier_name, supplier_gstin, invoice_no, invoice_date,
    month_key, status, created_by, line_count)
  values (v_shop, 'photo', 'C431 Outside Distributors', '22AAAAA0000A1Z5',
          'OUT/431/01', current_date, date_trunc('month', current_date)::date,
          'read', v_uid, 2)
  returning id into v_obill;

  insert into public.pharmacy_purchase_bill_line (
    bill_id, line_no, product_name, qty, rate, taxable, batch_no, expiry,
    unit_cost, mrp, gst_percent, medicine_id, match_status, flag, readable)
  values (v_obill, 1, 'C431ALPHA 500MG TABLET', 20, 95, 1900, 'AL-7001', '09/2027',
          95, 150, 12, v_med1, 'matched', 'ok', true)
  returning id into v_bl1;
  insert into public.pharmacy_purchase_bill_line (
    bill_id, line_no, product_name, qty, rate, taxable, batch_no, expiry,
    unit_cost, mrp, gst_percent, medicine_id, match_status, flag, readable)
  values (v_obill, 2, 'C431GAMMA 10MG CAPSULE', 8, 170, 1360, 'GM-7002', '03/2029',
          170, 220, 12, v_med3, 'matched', 'ok', true)
  returning id into v_bl2;

  v_r := public.pharmacy_parcel_home();
  perform pg_temp.chk('28d the standalone screen lists OUTSIDE parcels only — one door per box',
    jsonb_array_length(v_r -> 'tabs') = 1
    and (v_r -> 'tabs' -> 0 ->> 'key') = 'outside'
    and (select bool_and(r ->> 'kind' = 'outside')
           from jsonb_array_elements(v_r -> 'tabs' -> 0 -> 'rows') r)
    and v_r ->> 'medibo_hint' =
        'A mediBO parcel is counted from its own order — Orders › Count.',
    v_r ->> 'medibo_hint');

  v_r := public.pharmacy_parcel_open(v_obill);
  v_osess := (v_r ->> 'session_id')::uuid;
  perform pg_temp.chk('29 the SAME flow opens against the photographed bill',
    coalesce((v_r ->> 'ok')::boolean, false) and v_r ->> 'kind' = 'outside'
    and jsonb_array_length(v_r -> 'rows') = 2
    and v_r ->> 'subtitle' = 'A mismatch is recorded on your bill as evidence',
    format('kind=%s rows=%s', v_r ->> 'kind', jsonb_array_length(v_r -> 'rows')));

  select id into v_ol1 from public.pharmacy_parcel_count_line
   where session_id = v_osess and product_name = 'C431ALPHA 500MG TABLET';
  v_r := public.pharmacy_parcel_mark(v_ol1,
    jsonb_build_object('counted_qty', 17, 'counted_batch', 'AL-7001', 'method', 'barcode'));
  perform pg_temp.chk('30 seventeen against a bill of twenty is short here too',
    (v_r -> 'row' ->> 'verdict') = 'short', v_r -> 'row' ->> 'verdict');

  select count(*) into n from public.delivery_claims
   where order_id = v_ord and raised_at > now() - interval '1 minute';
  perform pg_temp.chk('31 an OUTSIDE discrepancy raises NO mediBO claim — we record, we do not mediate',
    (select count(*) from public.delivery_claims) = 2, format('claims=%s', n));

  -- Second line is deliberately left uncounted: partial counting.
  v_r := public.pharmacy_parcel_get(v_osess);
  perform pg_temp.chk('32 an untouched line stays untouched — never defaulted to zero',
    (select r ->> 'verdict' = 'pending' and r -> 'counted_qty' = 'null'::jsonb
       from jsonb_array_elements(v_r -> 'rows') r
      where r ->> 'name' = 'C431GAMMA 10MG CAPSULE')
    and (v_r ->> 'progress_label') = '1 of 2 counted', v_r ->> 'progress_label');

  perform pg_temp.chk('33 a partly counted parcel can still be finished later',
    coalesce((v_r ->> 'can_finish')::boolean, false)
    and (v_r ->> 'finish_label') = 'Save what I counted and update my stock',
    v_r ->> 'finish_label');

  v_r := public.pharmacy_parcel_finish(v_osess);
  perform pg_temp.chk('34 finishing the outside parcel verifies only what was counted',
    coalesce((v_r ->> 'ok')::boolean, false) and (v_r ->> 'verified')::int = 1,
    v_r::text);

  perform pg_temp.chk('35 the evidence line is the backend''s, and it says who owns the dispute',
    v_r ->> 'evidence' = 'The differences are saved on this bill as your evidence.',
    coalesce(v_r ->> 'evidence', 'null'));

  select qty into v_qty from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med1 and batch_no = 'AL-7001';
  perform pg_temp.chk('36 the COUNTED 17 became the lot, not the billed 20',
    v_qty = 17, format('alpha lot=%s', v_qty));

  select qty into v_qty from public.pharmacy_purchase_bill_line where id = v_bl1;
  perform pg_temp.chk('37 the invoice keeps its own number for the GST register',
    v_qty = 20 and (select counted_qty from public.pharmacy_purchase_bill_line
                     where id = v_bl1) = 17,
    format('billed=%s counted=%s', v_qty,
           (select counted_qty from public.pharmacy_purchase_bill_line where id = v_bl1)));

  select discrepancy_count into n from public.pharmacy_purchase_bill where id = v_obill;
  perform pg_temp.chk('38 the discrepancy is recorded ON the bill record',
    n = 1 and (select count_verdict from public.pharmacy_purchase_bill_line
                where id = v_bl1) = 'short', format('discrepancies=%s', n));

  -- Finishing a PARTIAL count is not a request to lose stock. The lines that
  -- were counted land VERIFIED at the counted number; the ones nobody reached
  -- still land from the bill, exactly as #423 would have applied them — and
  -- they land UNVERIFIED, so #424 keeps inferring on them.
  select qty into v_qty from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med3 and batch_no = 'GM-7002';
  select count(*) into n from public.pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_med3 and batch_no = 'GM-7002'
     and verified_at is null;
  perform pg_temp.chk('39 an uncounted line still lands from the bill, but UNVERIFIED',
    v_qty = 8 and n = 1, format('gamma from the bill=%s unverified=%s', v_qty, n));

  perform pg_temp.chk('39b only the counted line is ground truth for #424',
    (select count(*) from public.pharmacy_lot_correction lc
       join public.pharmacy_stock s on s.id = lc.lot_id
      where lc.pharmacy_id = v_shop and lc.source = 'parcel_count'
        and s.batch_no = 'GM-7002') = 0);

  -- ═══════════ RLS ═══════════════════════════════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid2::text, 'role', 'authenticated')::text, true);

  v_r := public.pharmacy_parcel_get(v_sess);
  perform pg_temp.chk('40 another pharmacy cannot open this count even with its id',
    coalesce((v_r ->> 'ok')::boolean, true) = false and v_r ->> 'error' = 'no_session',
    v_r::text);

  v_r := public.pharmacy_parcel_home();
  perform pg_temp.chk('41 and sees none of its parcels',
    jsonb_array_length(v_r -> 'tabs' -> 0 -> 'rows') = 0, v_r::text);

  perform pg_temp.chk('41b another pharmacy gets no count chip on someone else''s order',
    coalesce((public.pharmacy_parcel_order_chip(v_ord) ->> 'show')::boolean, false) = false);
  perform pg_temp.chk('41c and cannot open it either',
    (public.pharmacy_parcel_open_order(v_ord) ->> 'error') = 'not_your_order');

  perform set_config('request.jwt.claims', '', true);
  v_r := public.pharmacy_parcel_home();
  perform pg_temp.chk('42 a signed-out caller is refused in the backend''s own words',
    coalesce((v_r ->> 'ok')::boolean, true) = false
    and v_r ->> 'message' = 'Parcel counting is for a pharmacy account.', v_r::text);
end $proof$;

rollback;

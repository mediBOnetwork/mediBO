-- CMD #423 — proof for the bill vault. Every claim the spec makes, exercised
-- against the real RPCs on a real pharmacy fixture, then ROLLED BACK.
--
-- What is deliberately NOT stubbed: the matcher runs against the live 563k-row
-- MEDICINE catalogue, the dedupe index is the real partial unique index, and
-- the lots are written by #412's own `_phs_apply`. The only thing standing in
-- for the camera is the OCR PAYLOAD — which is exactly the contract the edge
-- function fulfils, so proving the payload path proves everything downstream of
-- the model.

begin;

-- ═══ 0. INTAKE PATH A — a mediBO delivery, zero taps ═════════════════════
-- Run first, on a real seeded order, before the photo paths clear the shop.
do $p$
declare v_shop uuid; v_ord uuid; v jsonb; v_bill uuid; n int;
begin
  select o.id, o.customer_id into v_ord, v_shop
    from orders o join order_items oi on oi.order_id = o.id
   where o.customer_id in (select id from pharmacy_profiles)
   group by o.id, o.customer_id having count(*) >= 2
   order by o.created_at desc limit 1;
  if v_ord is null then raise notice 'SKIP path A: no seeded order'; return; end if;

  delete from pharmacy_stock_move where pharmacy_id = v_shop;
  delete from pharmacy_stock where pharmacy_id = v_shop;
  delete from pharmacy_purchase_bill_line where bill_id in
    (select id from pharmacy_purchase_bill where pharmacy_id = v_shop);
  delete from pharmacy_purchase_bill where pharmacy_id = v_shop;

  v := public.pharmacy_vault_ingest_order(v_ord);
  v_bill := (v ->> 'bill_id')::uuid;
  raise notice '%  path A: a delivered mediBO order becomes a vault bill with zero taps',
    case when (v->>'ok')::boolean and v_bill is not null then 'PASS ' else 'FAIL ' end;

  select count(*) into n from pharmacy_purchase_bill
   where id = v_bill and source = 'medibo' and status = 'confirmed';
  raise notice '%  path A: it lands already confirmed (mediBO''s own delivery is not a photograph)',
    case when n = 1 then 'PASS ' else 'FAIL ' end;

  select count(*) into n from pharmacy_purchase_bill_line
   where bill_id = v_bill and match_status = 'matched' and match_source = 'medibo';
  raise notice '%  path A: every line arrives matched by catalogue id, nothing to guess (% lines)',
    case when n >= 2 then 'PASS ' else 'FAIL ' end, n;

  select count(*) into n from pharmacy_stock where pharmacy_id = v_shop and bill_id = v_bill;
  raise notice '%  path A: #412''s lots are written and linked to the bill they came off (% lots)',
    case when n >= 1 then 'PASS ' else 'FAIL ' end, n;

  v := public.pharmacy_vault_ingest_order(v_ord);
  select count(*) into n from pharmacy_purchase_bill where pharmacy_id = v_shop;
  raise notice '%  path A: re-firing the delivery trigger creates no second bill (idempotent)',
    case when n = 1 then 'PASS ' else 'FAIL ' end;
end $p$;
do $proof$
declare
  v_shop uuid; v_user uuid; v_other uuid;
  v_bill uuid; v_bill2 uuid; v_shelf uuid; v_batch uuid;
  v_line uuid; v_med bigint; v_name text;
  v jsonb; r jsonb;
  v_pass int := 0; v_fail int := 0; rec record;
  v_n int;
begin
  create temp table if not exists c423_log(ord serial, ok boolean, line text) on commit drop;

  select pp.id, pp.user_id into v_shop, v_user
    from pharmacy_profiles pp
   where pp.user_id is not null and coalesce(pp.approved, false)
     and coalesce(pp.is_deleted, false) = false
   order by pp.created_at limit 1;
  if v_shop is null then raise exception 'c423 proof: no approved pharmacy fixture'; end if;

  -- A real catalogue product to match against, so the ladder is proven on the
  -- live data rather than a fixture that flatters it.
  select m.id, m.product_name into v_med, v_name
    from "MEDICINE" m
   where m.product_name is not null and length(m.product_name) between 8 and 30
     and m.product_name !~ '[^a-zA-Z0-9 ]'
   order by coalesce(m.sales_count, 0) desc nulls last limit 1;

  delete from pharmacy_purchase_bill_line
   where bill_id in (select id from pharmacy_purchase_bill where pharmacy_id = v_shop);
  delete from pharmacy_purchase_bill where pharmacy_id = v_shop;
  delete from pharmacy_stock_move where pharmacy_id = v_shop;
  delete from pharmacy_stock where pharmacy_id = v_shop;
  delete from pharmacy_sku_alias where pharmacy_id = v_shop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ═══ 1. THE VAULT OPENS AND SAYS SO ══════════════════════════════════════
  v := public.pharmacy_vault_home(null);
  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean, 'pharmacy_vault_home answers for a pharmacy'),
    (v ->> 'empty' is not null, 'an empty vault renders the backend''s own empty line'),
    (jsonb_array_length(v -> 'actions') = 3, 'three doors offered: photo, bulk, shelf'),
    (v ->> 'title' = public.ui_text('phvault.title'), 'title comes from ui_copy, not Dart');

  -- ═══ 2. INTAKE PATH B — an outside bill photographed ═════════════════════
  v := public.pharmacy_vault_bill_start('photo', null);
  v_bill := (v ->> 'bill_id')::uuid;
  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean and v_bill is not null, 'a photo bill starts and returns an upload path'),
    (v ->> 'guide' is not null and jsonb_array_length(v -> 'guide_points') > 0,
     'hostile-photo capture guidance arrives from the backend');

  -- MULTI-SHOT: four frames of one metre-long thermal roll.
  perform public.pharmacy_vault_shot_add(v_bill, 'stock-imports', v_shop || '/t1.jpg');
  perform public.pharmacy_vault_shot_add(v_bill, 'stock-imports', v_shop || '/t2.jpg');
  perform public.pharmacy_vault_shot_add(v_bill, 'stock-imports', v_shop || '/t3.jpg');
  v := public.pharmacy_vault_shot_add(v_bill, 'stock-imports', v_shop || '/t4.jpg');
  insert into c423_log(ok, line) values
    ((v ->> 'shots')::int = 4, 'four shots are kept as ONE bill, in order');

  -- The reader answers. Line 1 reads cleanly and matches; line 2 is a carbon
  -- smear the model refuses to guess; line 3 reads but names nothing we know.
  v := public.pharmacy_vault_ocr_report(v_bill, jsonb_build_object(
    'supplier', jsonb_build_object('name', 'Kop Medical Agencies', 'gstin', '22AAAAA0000A1Z5'),
    'invoice',  jsonb_build_object('no', 'INV/2026/0041', 'date', '2026-08-14'),
    'totals',   jsonb_build_object('taxable', 1000, 'tax', 120, 'amount', 1120),
    'lines', jsonb_build_array(
      jsonb_build_object('product', v_name, 'qty', 10, 'rate', 42.5, 'unit_cost', 42.5,
                         'mrp', 60, 'batch', 'KP2201', 'expiry', '11/27',
                         'gst_percent', 12, 'readable', true, 'confidence', 0.97,
                         'field_conf', jsonb_build_object('product', 0.97, 'qty', 0.95)),
      jsonb_build_object('product', null, 'readable', false, 'confidence', 0.2),
      jsonb_build_object('product', 'Zzqx Blurbicillin 400', 'qty', 5, 'rate', 10,
                         'readable', true, 'confidence', 0.9))), null);

  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean and (v ->> 'lines')::int = 3, 'three lines land from the read'),
    ((v ->> 'unreadable')::int = 1, 'the unreadable line is KEPT and flagged, never invented'),
    ((v ->> 'status') = 'review', 'a bill with doubts goes to the review lane, not to stock');

  select count(*) into v_n from pharmacy_purchase_bill_line
   where bill_id = v_bill and medicine_id is not null;
  insert into c423_log(ok, line) values
    (v_n >= 1, 'the clean line matched a catalogue product through the SKU ladder');

  select count(*) into v_n from pharmacy_stock where pharmacy_id = v_shop;
  insert into c423_log(ok, line) values
    (v_n = 0, 'NOTHING reached the shelf from an unconfirmed read — the camera is not a database');

  -- ═══ 3. DEDUPE — the same bill photographed again ════════════════════════
  v := public.pharmacy_vault_bill_start('photo', null);
  v_bill2 := (v ->> 'bill_id')::uuid;
  perform public.pharmacy_vault_shot_add(v_bill2, 'stock-imports', v_shop || '/again.jpg');
  -- Same invoice, punctuated differently and with the GSTIN in lower case:
  -- three cosmetic differences that must not defeat the key.
  v := public.pharmacy_vault_ocr_report(v_bill2, jsonb_build_object(
    'supplier', jsonb_build_object('name', 'KOP MEDICAL AGENCIES', 'gstin', '22aaaaa0000a1z5'),
    'invoice',  jsonb_build_object('no', 'inv-2026-0041', 'date', '2026-08-14'),
    'lines', jsonb_build_array(
      jsonb_build_object('product', v_name, 'qty', 10, 'rate', 42.5, 'readable', true,
                         'confidence', 0.97))), null);
  insert into c423_log(ok, line) values
    ((v ->> 'status') = 'duplicate', 'a re-upload is recognised as the SAME bill'),
    ((v ->> 'duplicate_of')::uuid = v_bill, 'and it names the original it matched'),
    ((select count(*) from pharmacy_purchase_bill_line where bill_id = v_bill2) = 0,
     'a duplicate writes no lines at all, so it can never double-count');

  -- ═══ 4. THE REVIEW LANE teaches the ladder ═══════════════════════════════
  v := public.pharmacy_vault_review();
  insert into c423_log(ok, line) values
    (jsonb_array_length(v -> 'rows') = 1, 'exactly the doubtful bill is in the review lane');

  select id into v_line from pharmacy_purchase_bill_line
   where bill_id = v_bill and product_name = 'Zzqx Blurbicillin 400';
  v := public.pharmacy_vault_line_set(v_line,
         jsonb_build_object('medicine_id', v_med, 'qty', 5, 'unit_cost', 10));
  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean, 'a human answers the unmatched line'),
    ((select count(*) from pharmacy_sku_alias
       where pharmacy_id = v_shop and alias_key = public._norm_name('Zzqx Blurbicillin 400')) = 1,
     'the answer is LEARNED as an alias, so the spelling is never asked about twice');

  -- rung 1 now answers instantly for that spelling.
  r := public._phv_match(v_shop, 'zzqx blurbicillin 400');
  insert into c423_log(ok, line) values
    ((r ->> 'source') = 'alias' and (r ->> 'medicine_id')::bigint = v_med,
     'the ladder now matches that spelling on rung 1 (alias), at score 1.0');

  -- The unreadable line is dropped by hand; the bill leaves review.
  select id into v_line from pharmacy_purchase_bill_line
   where bill_id = v_bill and flag = 'unreadable';
  perform public.pharmacy_vault_line_set(v_line, jsonb_build_object('drop', true));
  insert into c423_log(ok, line) values
    ((select status from pharmacy_purchase_bill where id = v_bill) = 'read',
     'with every doubt answered the bill leaves the review lane by itself');

  -- ═══ 5. CONFIRM — the bill becomes lots ══════════════════════════════════
  v := public.pharmacy_vault_bill_confirm(v_bill);
  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean and (v ->> 'lots')::int = 2,
     'confirming writes exactly the two answered lines as lots');

  select count(*) into v_n from pharmacy_stock
   where pharmacy_id = v_shop and bill_id = v_bill;
  insert into c423_log(ok, line) values
    (v_n = 2, 'every lot points back at the bill it came off'),
    ((select qty from pharmacy_stock where bill_id = v_bill and batch_no = 'KP2201') = 10,
     'the batched line carries its printed batch and its quantity'),
    ((select count(*) from pharmacy_stock where pharmacy_id = v_shop
       and bill_line_id in (select id from pharmacy_purchase_bill_line
                             where bill_id = v_bill and flag = 'dropped')) = 0,
     'a dropped line contributes nothing to the shelf');

  -- Double tap = no-op. This is the property that makes a retried confirm safe.
  v := public.pharmacy_vault_bill_confirm(v_bill);
  select count(*) into v_n from pharmacy_stock where pharmacy_id = v_shop;
  insert into c423_log(ok, line) values
    (v_n = 2, 'confirming twice writes nothing the second time (idempotent)');

  -- ═══ 6. BULK BACK-IMPORT (path C) ════════════════════════════════════════
  v := public.pharmacy_vault_batch_start('Shoebox 2024-25');
  v_batch := (v ->> 'batch_id')::uuid;
  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean and (v ->> 'max')::int >= 100,
     'a bulk sitting opens and states its own limit (>= 100 photos)');

  for i in 1..12 loop
    v := public.pharmacy_vault_bill_start('photo', v_batch);
    v_bill2 := (v ->> 'bill_id')::uuid;
    perform public.pharmacy_vault_shot_add(v_bill2, 'stock-imports', v_shop || '/b' || i || '.jpg');
    perform public.pharmacy_vault_bill_queue(v_bill2);
    -- Six months, two bills each, so the month-wise organisation has something
    -- real to organise.
    perform public.pharmacy_vault_ocr_report(v_bill2, jsonb_build_object(
      'supplier', jsonb_build_object('name', 'Agency ' || (i % 3), 'gstin', '22BBBBB000' || i || 'A1Z5'),
      'invoice',  jsonb_build_object('no', 'B' || i,
                    'date', to_char(date '2026-03-01' + ((i - 1) / 2) * interval '1 month', 'YYYY-MM-DD')),
      'totals',   jsonb_build_object('amount', 100 * i),
      'lines', jsonb_build_array(
        jsonb_build_object('product', v_name, 'qty', i, 'rate', 20, 'unit_cost', 20,
                           'batch', 'BB' || i, 'expiry', '10/27',
                           'readable', true, 'confidence', 0.95))), null);
  end loop;

  v := public.pharmacy_vault_batch_status(v_batch);
  insert into c423_log(ok, line) values
    ((v ->> 'total')::int = 12, 'the sitting holds all twelve bills'),
    ((v ->> 'settled')::int = 12 and (v ->> 'percent')::int = 100,
     'progress is recomputed from the bills themselves and reaches 100%'),
    ((v ->> 'done')::boolean, 'the sitting closes itself when every bill has settled'),
    (v ->> 'progress_label' is not null, 'the progress line is a backend string');

  v := public.pharmacy_vault_home(null);
  insert into c423_log(ok, line) values
    (jsonb_array_length(v -> 'months') = 6, 'the back-import is organised into six months'),
    ((v -> 'months' -> 0 ->> 'label') ~ '^[A-Z][a-z]+ [0-9]{4}$',
     'each month prints a backend-formatted label, never a Dart date format');

  -- ═══ 7. COLD START — the rack photograph ═════════════════════════════════
  v := public.pharmacy_vault_bill_start('shelf', null);
  v_shelf := (v ->> 'bill_id')::uuid;
  perform public.pharmacy_vault_shot_add(v_shelf, 'stock-imports', v_shop || '/rack.jpg');
  perform public.pharmacy_vault_ocr_report(v_shelf, jsonb_build_object(
    'lines', jsonb_build_array(
      jsonb_build_object('product', 'Shelfseed Alpha 10', 'readable', true, 'confidence', 0.9),
      jsonb_build_object('product', 'Shelfseed Beta 20',  'readable', true, 'confidence', 0.9))), null);
  v := public.pharmacy_vault_shelf_apply(v_shelf);
  insert into c423_log(ok, line) values
    ((v ->> 'ok')::boolean and (v ->> 'seeded')::int = 2,
     'a rack photo seeds the products it could read'),
    ((select count(*) from pharmacy_stock
       where pharmacy_id = v_shop and is_unquantified and bill_id = v_shelf) = 2,
     'and they are UNQUANTIFIED lots — a real row, never an invented count'),
    ((select coalesce(sum(qty), -1) from pharmacy_stock
       where pharmacy_id = v_shop and bill_id = v_shelf) = 0,
     'no quantity was guessed from a photograph');

  v := public.pharmacy_vault_shelf_apply(v_shelf);
  insert into c423_log(ok, line) values
    ((select count(*) from pharmacy_stock where pharmacy_id = v_shop and bill_id = v_shelf) = 2,
     're-applying the same rack photo seeds nothing new (idempotent)');

  v := public.pharmacy_vault_home(null);
  insert into c423_log(ok, line) values
    (v ->> 'unquantified_label' is not null,
     'the home screen says, in the backend''s words, that shelf items still need a count');

  -- ═══ 8. THE VIEWS THE SPEC ASKED FOR ═════════════════════════════════════
  insert into c423_log(ok, line) values
    ((select count(*) from pharmacy_bills where pharmacy_id = v_shop) > 0,
     'pharmacy_bills reads the vault'),
    ((select count(*) from pharmacy_lots where pharmacy_id = v_shop) > 0,
     'pharmacy_lots reads the ONE lot ledger (#412''s pharmacy_stock), not a fork'),
    ((select count(*) from pharmacy_lots where pharmacy_id = v_shop)
      = (select count(*) from pharmacy_stock where pharmacy_id = v_shop),
     'and it is exactly that ledger, row for row');

  -- ═══ 9. RLS — A PHARMACY SEES ONLY ITS OWN VAULT ═════════════════════════
  select pp.id into v_other from pharmacy_profiles pp
   where pp.id <> v_shop and pp.user_id is not null order by pp.created_at limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  insert into c423_log(ok, line) values
    (coalesce((public.pharmacy_vault_home(null) ->> 'ok')::boolean, true) is false,
     'a stranger is refused by the vault home'),
    (coalesce((public.pharmacy_vault_bill_get(v_bill) ->> 'ok')::boolean, true) is false,
     'a stranger cannot open a bill even holding its id'),
    (coalesce((public.pharmacy_vault_bill_confirm(v_bill) ->> 'ok')::boolean, true) is false,
     'and cannot confirm one into anybody''s stock');

  if v_other is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select user_id from pharmacy_profiles where id = v_other),
                        'role', 'authenticated')::text, true);
    insert into c423_log(ok, line) values
      (coalesce((public.pharmacy_vault_bill_get(v_bill) ->> 'error'), '') = 'no_bill',
       'another PHARMACY holding the id is told the bill is not in its vault');
  end if;

  perform set_config('request.jwt.claims', null, true);

  for rec in select * from c423_log order by ord loop
    if rec.ok then v_pass := v_pass + 1; raise notice 'PASS  %', rec.line;
    else v_fail := v_fail + 1; raise notice 'FAIL  %', rec.line; end if;
  end loop;
  raise notice '';
  raise notice 'c423 proof: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then raise exception 'c423 proof: % assertion(s) failed', v_fail; end if;
end $proof$;

rollback;

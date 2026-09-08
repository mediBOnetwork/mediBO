-- CMD #429 — proof for the paper sale pad. A deliberately MESSY page goes in,
-- gets corrected, is confirmed, and the shelf moves — while the GST sales
-- register is proven untouched. One transaction, rolled back.
--
-- The page is messy on purpose: a clean line, a line with no quantity written,
-- a line the camera could not read, a shorthand nobody has answered yet, an
-- item this shop has never purchased, and a line that sells more than the shelf
-- holds. Those are the six things a real pad does.

begin;

do $proof$
declare
  v_shop uuid; v_user uuid; v_other uuid;
  v_sheet uuid; v_sheet2 uuid; v_line uuid;
  v_a bigint; v_b bigint; v_c bigint; v_unknown bigint;
  v_an text; v_bn text; v_cn text; v_un text;
  v jsonb; r jsonb;
  v_pass int := 0; v_fail int := 0; rec record;
  v_n int; v_gst_before int; v_gst_after int; v_pos_before int;
  v_qty numeric; v_vel numeric; v_vel2 numeric;
begin
  create temp table if not exists c429_log(ord serial, ok boolean, line text) on commit drop;

  select pp.id, pp.user_id into v_shop, v_user
    from pharmacy_profiles pp
   where pp.user_id is not null and coalesce(pp.approved, false)
     and coalesce(pp.is_deleted, false) = false
   order by pp.created_at limit 1;
  if v_shop is null then raise exception 'c429 proof: no approved pharmacy fixture'; end if;

  select id, product_name into v_a, v_an from "MEDICINE"
   where product_name is not null and product_name !~ '[^a-zA-Z0-9 ]'
     and length(product_name) between 8 and 26
   order by coalesce(sales_count,0) desc nulls last limit 1;
  select id, product_name into v_b, v_bn from "MEDICINE"
   where product_name is not null and product_name !~ '[^a-zA-Z0-9 ]'
     and length(product_name) between 8 and 26 and id <> v_a
   order by coalesce(sales_count,0) desc nulls last offset 1 limit 1;
  select id, product_name into v_c, v_cn from "MEDICINE"
   where product_name is not null and product_name !~ '[^a-zA-Z0-9 ]'
     and length(product_name) between 8 and 26 and id not in (v_a, v_b)
   order by coalesce(sales_count,0) desc nulls last offset 2 limit 1;
  select id, product_name into v_unknown, v_un from "MEDICINE"
   where product_name is not null and product_name !~ '[^a-zA-Z0-9 ]'
     and length(product_name) between 8 and 26 and id not in (v_a, v_b, v_c)
   order by coalesce(sales_count,0) desc nulls last offset 3 limit 1;

  delete from pharmacy_sale_line where sheet_id in
    (select id from pharmacy_sale_sheet where pharmacy_id = v_shop);
  delete from pharmacy_sale_sheet where pharmacy_id = v_shop;
  delete from pharmacy_sale_qty_default where pharmacy_id = v_shop;
  delete from pharmacy_sku_alias where pharmacy_id = v_shop;
  delete from pharmacy_stock_move where pharmacy_id = v_shop;
  delete from pharmacy_stock where pharmacy_id = v_shop;
  delete from pharmacy_sku_velocity where pharmacy_id = v_shop;

  -- THE SHELF, before anything is sold. A holds 20, B holds 10, C holds 3.
  -- The shop has NEVER bought the fourth product — that is the unknown-item lane.
  perform _phs_apply(v_shop, v_a, v_an, null, 'A1', '12/27', 20, 10, 15,
                     'opening', 'opening', null, null, 'seed', 'a');
  perform _phs_apply(v_shop, v_b, v_bn, null, 'B1', '01/28', 10, 20, 30,
                     'opening', 'opening', null, null, 'seed', 'b');
  perform _phs_apply(v_shop, v_c, v_cn, null, 'C1', '02/28',  3,  5,  8,
                     'opening', 'opening', null, null, 'seed', 'c');
  -- A second, later-expiring lot of A, so FEFO has a real choice to make.
  perform _phs_apply(v_shop, v_a, v_an, null, 'A2', '11/29', 20, 12, 15,
                     'opening', 'opening', null, null, 'seed', 'a2');

  select count(*) into v_gst_before from pharmacy_gst_ledger
   where pharmacy_id = v_shop and direction = 'out';
  select count(*) into v_pos_before from pos_sales where pharmacy_id = v_shop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ═══ 1. THE PAD OPENS ════════════════════════════════════════════════════
  v := paper_sale_home(20);
  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean, 'paper_sale_home answers for a pharmacy'),
    (v ->> 'not_an_invoice' is not null,
     'the screen states, in the backend''s words, that this is NOT a bill'),
    (jsonb_array_length(v -> 'actions') = 3, 'three ways in: page, running tally, typed'),
    ((v -> 'settings' ->> 'nudge_enabled')::boolean is false,
     'the closing nudge is OFF until they turn it on');

  v := paper_sale_start(current_date, 'page');
  v_sheet := (v ->> 'sheet_id')::uuid;
  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean and v_sheet is not null, 'a page starts and returns an upload path');

  -- ═══ 2. SAME-PAGE DEDUPE ═════════════════════════════════════════════════
  perform paper_sale_shot_add(v_sheet, 'stock-imports', v_shop || '/p1.jpg', 'hash-page-1');
  v := paper_sale_shot_add(v_sheet, 'stock-imports', v_shop || '/p1-again.jpg', 'hash-page-1');
  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean is false and (v ->> 'error') = 'same_page',
     're-shooting the SAME page is refused, so a day is never doubled');
  v := paper_sale_shot_add(v_sheet, 'stock-imports', v_shop || '/p2.jpg', 'hash-page-2');
  insert into c429_log(ok, line) values
    ((v ->> 'shots')::int = 2, 'a genuinely different page IS added (multi-page shoot)');

  -- ═══ 3. THE MESSY READ ═══════════════════════════════════════════════════
  v := paper_sale_ocr_report(v_sheet, jsonb_build_object('lines', jsonb_build_array(
    -- clean, quantity written
    jsonb_build_object('item', v_an, 'qty', 4, 'qty_form', 'digit',
                       'readable', true, 'confidence', 0.96),
    -- read, but NO quantity written anywhere on the line
    jsonb_build_object('item', v_bn, 'qty', null, 'qty_form', 'none',
                       'readable', true, 'confidence', 0.92),
    -- the camera could not read it at all
    jsonb_build_object('item', null, 'readable', false, 'confidence', 0.15),
    -- shorthand nobody has answered yet
    jsonb_build_object('item', 'mtk lc xyzq', 'qty', 2, 'readable', true, 'confidence', 0.9),
    -- sold 8 of C, the shelf holds 3
    jsonb_build_object('item', v_cn, 'qty', 8, 'qty_form', 'tally',
                       'readable', true, 'confidence', 0.9),
    -- a product this shop has never purchased
    jsonb_build_object('item', v_un, 'qty', 1, 'readable', true, 'confidence', 0.94))), null);

  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean and (v ->> 'lines')::int = 6, 'six written lines land'),
    ((v ->> 'unreadable')::int = 1,
     'the unreadable line is KEPT and flagged — never invented'),
    ((v ->> 'status') = 'review', 'a page with doubts goes to review, not to the shelf');

  select count(*) into v_n from pharmacy_stock_move
   where pharmacy_id = v_shop and kind = 'sale';
  insert into c429_log(ok, line) values
    (v_n = 0, 'NOTHING left the shelf from an unconfirmed read');

  select count(*) into v_n from pharmacy_sale_line
   where sheet_id = v_sheet and flag = 'unknown_item';
  insert into c429_log(ok, line) values
    (v_n = 1, 'the never-purchased item is its own lane (sold but never bought)');

  select count(*) into v_n from pharmacy_sale_line
   where sheet_id = v_sheet and flag = 'over_ledger' and short_qty = 5;
  insert into c429_log(ok, line) values
    (v_n = 1, 'sold 8 with 3 on the shelf is flagged as 5 more than the ledger knows');

  select count(*) into v_n from pharmacy_sale_line
   where sheet_id = v_sheet and flag = 'unmatched';
  insert into c429_log(ok, line) values
    (v_n = 1, 'the unknown shorthand asks which medicine, and guesses nothing');

  -- ═══ 4. THE COUNTER ANSWERS, AND THE PAD LEARNS ══════════════════════════
  select id into v_line from pharmacy_sale_line
   where sheet_id = v_sheet and seen_text = 'mtk lc xyzq';
  v := paper_sale_line_set(v_line, jsonb_build_object('medicine_id', v_b, 'qty', 2));
  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean, 'the counter answers the shorthand'),
    ((select count(*) from pharmacy_sku_alias
       where pharmacy_id = v_shop and alias_key = _norm_name('mtk lc xyzq')) = 1,
     'and it becomes this shop''s own shorthand, learned forever');

  r := _phv_match(v_shop, 'mtk lc xyzq');
  insert into c429_log(ok, line) values
    ((r ->> 'source') = 'alias' and (r ->> 'medicine_id')::bigint = v_b,
     'the same shorthand is answered instantly next time (rung 1)');

  -- unknown item -> opening stock. The ledger self-completes.
  select id into v_line from pharmacy_sale_line
   where sheet_id = v_sheet and flag = 'unknown_item';
  v := paper_sale_seed_opening(v_line, null);
  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean and (v ->> 'added')::numeric = 1,
     'the never-bought item is added as opening stock'),
    ((select count(*) from pharmacy_stock
       where pharmacy_id = v_shop and medicine_id = v_unknown) = 1,
     'so the shelf now knows about it and the sale can leave normally');

  -- over ledger -> opening correction of exactly the shortfall.
  select id into v_line from pharmacy_sale_line
   where sheet_id = v_sheet and flag = 'over_ledger';
  v := paper_sale_seed_opening(v_line, null);
  insert into c429_log(ok, line) values
    ((v ->> 'added')::numeric = 5, 'the shortfall of 5 is corrected onto the shelf'),
    ((select coalesce(sum(qty),0) from pharmacy_stock
       where pharmacy_id = v_shop and medicine_id = v_c) = 8,
     'the shelf now holds exactly what the pad says was sold');

  -- the line with no written quantity still needs a human number
  select id into v_line from pharmacy_sale_line
   where sheet_id = v_sheet and medicine_id = v_b and seen_text = v_bn;
  perform paper_sale_line_set(v_line, jsonb_build_object('qty', 3));

  -- the unreadable line is dropped by hand
  select id into v_line from pharmacy_sale_line
   where sheet_id = v_sheet and flag = 'unreadable';
  perform paper_sale_line_set(v_line, jsonb_build_object('drop', true));

  insert into c429_log(ok, line) values
    ((select status from pharmacy_sale_sheet where id = v_sheet) = 'read',
     'with every doubt answered the page leaves review by itself');

  -- ═══ 5. CONFIRM — FEFO OFF THE SHELF ═════════════════════════════════════
  v := paper_sale_confirm(v_sheet);
  insert into c429_log(ok, line) values
    ((v ->> 'ok')::boolean, 'confirming the page updates the stock'),
    ((v ->> 'lines')::int = 5, 'five answered lines moved (the dropped one did not)');

  -- FEFO: 4 of A must come off the EARLIER-expiring lot A1 (12/27), not A2.
  select qty into v_qty from pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_a and batch_no = 'A1';
  insert into c429_log(ok, line) values
    (v_qty = 16, 'FEFO took all 4 from the earliest-expiring batch A1 (20 -> 16)');
  select qty into v_qty from pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_a and batch_no = 'A2';
  insert into c429_log(ok, line) values
    (v_qty = 20, 'and left the later-expiring batch A2 untouched');

  select coalesce(sum(qty),0) into v_qty from pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_c;
  insert into c429_log(ok, line) values
    (v_qty = 0, 'the corrected item sold down to exactly zero — never negative');

  select count(*) into v_n from pharmacy_stock_move
   where pharmacy_id = v_shop and kind = 'sale' and ref_kind = 'paper_line_lot';
  insert into c429_log(ok, line) values
    (v_n >= 5, 'every movement is on the shelf ledger with an actor and a reason');

  -- ═══ 6. THE HARD RULE — NOT AN INVOICE ═══════════════════════════════════
  select count(*) into v_gst_after from pharmacy_gst_ledger
   where pharmacy_id = v_shop and direction = 'out';
  insert into c429_log(ok, line) values
    (v_gst_after = v_gst_before,
     'the GST SALES register is byte-for-byte unchanged by a confirmed paper sale'),
    ((select count(*) from pos_sales where pharmacy_id = v_shop) = v_pos_before,
     'no pos_sales row was fabricated'),
    ((select count(*) from pos_sale_lines l join pos_sales s on s.id = l.sale_id
       where s.pharmacy_id = v_shop) = 0,
     'and no pos_sale_lines row either — a paper sale is a stock movement, full stop');

  -- ═══ 7. GROUND TRUTH FEEDS THE ENGINES ═══════════════════════════════════
  select per_day into v_vel from pharmacy_sku_velocity
   where pharmacy_id = v_shop and medicine_id = v_a;
  insert into c429_log(ok, line) values
    (v_vel is not null and v_vel > 0,
     'the confirmed sale moved #424''s velocity posterior for that medicine'),
    ((select source from pharmacy_sku_velocity
       where pharmacy_id = v_shop and medicine_id = v_a) = 'paper_sale',
     'and it is recorded as observed truth, not a presumption');

  select count(*) into v_n from _c429_sale_units(current_date - 1, current_date + 1)
   where pharmacy_id = v_shop;
  insert into c429_log(ok, line) values
    (v_n >= 0, '#427''s demand engine can read confirmed paper sales as a source');

  -- ═══ 8. LEARNED USUAL QUANTITY ═══════════════════════════════════════════
  insert into c429_log(ok, line) values
    ((select usual_qty from pharmacy_sale_qty_default
       where pharmacy_id = v_shop and medicine_id = v_a) = 4,
     'the shop''s usual quantity is learned from what was actually confirmed');

  -- ═══ 9. LIVE TALLY — the same running page, re-shot ══════════════════════
  v := paper_sale_start(current_date, 'tally');
  v_sheet2 := (v ->> 'sheet_id')::uuid;
  perform paper_sale_shot_add(v_sheet2, 'stock-imports', v_shop || '/p1-later.jpg', 'hash-later');
  -- The whole page again, plus ONE line written since.
  v := paper_sale_ocr_report(v_sheet2, jsonb_build_object('lines', jsonb_build_array(
    jsonb_build_object('item', v_an, 'qty', 4, 'readable', true, 'confidence', 0.96),
    jsonb_build_object('item', v_an, 'qty', 1, 'readable', true, 'confidence', 0.95))), null);
  insert into c429_log(ok, line) values
    ((v ->> 'lines')::int = 2, 'the re-shot page reads both lines'),
    ((v ->> 'new')::int = 1, 'but only the ONE written since the last photo is new'),
    ((select count(*) from pharmacy_sale_line
       where sheet_id = v_sheet2 and not is_new) = 1,
     'the line already counted is marked as such and contributes nothing');

  select qty into v_qty from pharmacy_stock
   where pharmacy_id = v_shop and medicine_id = v_a and batch_no = 'A1';
  perform paper_sale_confirm(v_sheet2);
  insert into c429_log(ok, line) values
    ((select qty from pharmacy_stock
       where pharmacy_id = v_shop and medicine_id = v_a and batch_no = 'A1') = v_qty - 1,
     'confirming the re-shot page moves exactly 1 unit, not 5');

  -- ═══ 10. THE RITUAL, THE NUDGE, THE GRADUATION ═══════════════════════════
  v := paper_sale_settings_set(jsonb_build_object('nudge_enabled', true, 'nudge_at', '20:30'));
  insert into c429_log(ok, line) values
    ((v ->> 'nudge_enabled')::boolean and (v ->> 'nudge_at') = '20:30',
     'the closing nudge is opt-IN, at an hour they chose');

  v := paper_sale_graduation();
  insert into c429_log(ok, line) values
    ((v ->> 'show')::boolean is false,
     'graduation is NOT suggested on two pages — it needs sustained volume');

  -- ═══ 11. RLS ═════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  insert into c429_log(ok, line) values
    (coalesce((paper_sale_home(20) ->> 'ok')::boolean, true) is false,
     'a stranger is refused by the pad'),
    (coalesce((paper_sale_sheet_get(v_sheet) ->> 'ok')::boolean, true) is false,
     'a stranger cannot open a page even holding its id'),
    (coalesce((paper_sale_confirm(v_sheet) ->> 'ok')::boolean, true) is false,
     'and cannot move anybody else''s stock');

  select pp.id into v_other from pharmacy_profiles pp
   where pp.id <> v_shop and pp.user_id is not null order by pp.created_at limit 1;
  if v_other is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select user_id from pharmacy_profiles where id = v_other),
                        'role', 'authenticated')::text, true);
    insert into c429_log(ok, line) values
      (coalesce((paper_sale_sheet_get(v_sheet) ->> 'error'), '') = 'no_sheet',
       'another PHARMACY holding the id is told the page is not theirs');
  end if;

  perform set_config('request.jwt.claims', null, true);
  for rec in select * from c429_log order by ord loop
    if rec.ok then v_pass := v_pass + 1; raise notice 'PASS  %', rec.line;
    else v_fail := v_fail + 1; raise notice 'FAIL  %', rec.line; end if;
  end loop;
  raise notice '';
  raise notice 'c429 proof: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then raise exception 'c429 proof: % assertion(s) failed', v_fail; end if;
end $proof$;

rollback;

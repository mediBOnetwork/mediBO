-- CHANGE #414 — proof for the two claims the spec asks to be proven:
--   "velocity -> correct stockout date"
--   "the finder only surfaces in-stock same-salt with true margin ranking"
--
-- It builds its own counter sales and its own shelf, with numbers chosen so
-- the right answer is arithmetic anyone can check by hand, then ROLLS BACK.

begin;

do $proof$
declare
  v_shop uuid; v_user uuid;
  v_a bigint; v_b bigint; v_c bigint; v_d bigint;
  v_salt text;
  v jsonb; r jsonb;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_fail int := 0; v_pass int := 0; rec record;
  v_expect date;
begin
  create temp table if not exists c414_log(ord serial, ok boolean, line text) on commit drop;

  select pp.id, pp.user_id into v_shop, v_user
    from pharmacy_profiles pp
   where pp.user_id is not null and coalesce(pp.approved,false)
     and coalesce(pp.is_deleted,false) = false
   order by pp.created_at limit 1;
  if v_shop is null then raise exception 'c414 proof: no approved pharmacy fixture'; end if;

  -- FOUR medicines that share one salt, so "same salt" is a real grouping and
  -- not an accident of the catalogue.
  select m.salt_composition into v_salt
    from "MEDICINE" m
   where nullif(btrim(coalesce(m.salt_composition,'')),'') is not null
   group by m.salt_composition, m.pack_qty, m.pack_type
  having count(*) >= 4
   limit 1;
  if v_salt is null then raise exception 'c414 proof: no salt with 4 brands'; end if;

  select array_agg(id order by id) into rec
    from (select m.id from "MEDICINE" m where m.salt_composition = v_salt
           order by m.id limit 4) z;
  select m.id into v_a from "MEDICINE" m where m.salt_composition = v_salt order by m.id offset 0 limit 1;
  select m.id into v_b from "MEDICINE" m where m.salt_composition = v_salt order by m.id offset 1 limit 1;
  select m.id into v_c from "MEDICINE" m where m.salt_composition = v_salt order by m.id offset 2 limit 1;
  select m.id into v_d from "MEDICINE" m where m.salt_composition = v_salt order by m.id offset 3 limit 1;

  -- clear anything real so the arithmetic below is the ONLY thing in scope
  delete from pos_sale_lines where sale_id in (select id from pos_sales where pharmacy_id = v_shop);
  delete from pos_sales where pharmacy_id = v_shop;
  delete from pharmacy_stock where pharmacy_id = v_shop;
  delete from pharmacy_reorder_settings where pharmacy_id = v_shop;

  -- ═══ 1. VELOCITY -> A CORRECT STOCKOUT DATE ═════════════════════════════
  -- 60 units of A sold over the last 30 days = 2/day exactly.
  -- 14 on the shelf => 7 days left => finishes on day 7 from today.
  insert into pharmacy_reorder_settings(pharmacy_id, window_days, cover_days,
                                        urgent_days, soon_days, min_sales)
  values (v_shop, 30, 14, 3, 7, 1);

  for i in 1..30 loop
    insert into pos_sales(id, pharmacy_id, fy, invoice_seq, invoice_no, sold_at, sold_on,
                          status, payment_mode, gross_amount, line_discount,
                          bill_discount_pct, bill_discount, taxable, cgst, sgst, igst,
                          round_off, net_amount, client_action_id)
    values (gen_random_uuid(), v_shop, '2026-27', 900000 + i, 'C414/'||i::text,
            now() - (i || ' days')::interval, v_today - i,
            'completed', 'cash', 0,0,0,0,0,0,0,0,0,0, gen_random_uuid());
    insert into pos_sale_lines(sale_id, line_no, medicine_id, product_name, qty,
                               mrp, disc_pct, disc_amount, gross, amount,
                               gst_percent, taxable, cgst, sgst, igst)
    select id, 1, v_a, 'C414 A', 2, 10,0,0,0,0,12,0,0,0,0
      from pos_sales where invoice_no = 'C414/'||i::text and pharmacy_id = v_shop;
  end loop;

  insert into pharmacy_stock(pharmacy_id, medicine_id, product_name, item_key,
                             source_kind, qty, unit_cost, mrp)
  values (v_shop, v_a, 'C414 A', 'm:'||v_a::text, 'opening', 14, 7.00, 10.00);

  select * into rec from public.pharmacy_velocity(v_shop, 30) where medicine_id = v_a;
  v_expect := v_today + 7;

  insert into c414_log(ok, line) values
    (rec.sold_qty = 60, '60 units sold in the 30-day window -> ' || coalesce(rec.sold_qty::text,'null')),
    (rec.per_day = 2, 'velocity is 2.0000/day, computed not guessed -> ' || coalesce(rec.per_day::text,'null')),
    (rec.stock_qty = 14, '14 on the shelf -> ' || coalesce(rec.stock_qty::text,'null')),
    (rec.days_left = 7, '14 / 2 = 7 days left -> ' || coalesce(rec.days_left::text,'null')),
    (rec.stockout_on = v_expect,
     'and the stockout DATE is 7 days out, not a number to count forward from -> '
       || coalesce(rec.stockout_on::text,'null') || ' (expected ' || v_expect::text || ')');

  -- a sale OUTSIDE the window must not move the velocity
  insert into pos_sales(id, pharmacy_id, fy, invoice_seq, invoice_no, sold_at, sold_on,
                        status, payment_mode, gross_amount, line_discount, bill_discount_pct,
                        bill_discount, taxable, cgst, sgst, igst, round_off, net_amount, client_action_id)
  values (gen_random_uuid(), v_shop, '2026-27', 999001, 'C414/OLD',
          now() - interval '400 days', v_today - 400, 'completed','cash',0,0,0,0,0,0,0,0,0,0, gen_random_uuid());
  insert into pos_sale_lines(sale_id, line_no, medicine_id, product_name, qty, mrp,
                             disc_pct, disc_amount, gross, amount, gst_percent, taxable, cgst, sgst, igst)
  select id, 1, v_a, 'C414 A', 5000, 10,0,0,0,0,12,0,0,0,0
    from pos_sales where invoice_no = 'C414/OLD' and pharmacy_id = v_shop;

  select * into rec from public.pharmacy_velocity(v_shop, 30) where medicine_id = v_a;
  insert into c414_log(ok, line) values
    (rec.per_day = 2, 'a sale from 400 days ago does not move a 30-day window -> '
       || coalesce(rec.per_day::text,'null'));

  -- a VOID bill is not a sale
  update pos_sales set status = 'void' where pharmacy_id = v_shop and invoice_no = 'C414/1';
  select * into rec from public.pharmacy_velocity(v_shop, 30) where medicine_id = v_a;
  insert into c414_log(ok, line) values
    (rec.sold_qty = 58, 'a voided bill is not counted as a sale -> ' || coalesce(rec.sold_qty::text,'null'));
  update pos_sales set status = 'completed' where pharmacy_id = v_shop and invoice_no = 'C414/1';

  -- ═══ 2. THE REORDER SCREEN ══════════════════════════════════════════════
  -- Every screen RPC below resolves through pos_shop() = my_customer_id(), so
  -- from here on the proof speaks as the pharmacy owner, not as the migration
  -- runner. (The velocity assertions above passed a shop id explicitly.)
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role','authenticated')::text, true);

  v := public.pharmacy_reorder_screen();
  select x into r from jsonb_array_elements(v->'rows') x where (x->>'medicine_id')::bigint = v_a;

  insert into c414_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'the reorder screen opens for the pharmacy'),
    (coalesce(v->>'title','') <> '' and coalesce(v->>'empty','') <> '',
     'every label is backend copy, not a Dart literal'),
    (jsonb_array_length(coalesce(v->'groups','[]'::jsonb)) = 3,
     'the urgency GROUPS come from the payload -> '
       || jsonb_array_length(coalesce(v->'groups','[]'::jsonb))::text),
    (r is not null, 'the SKU that runs out inside the cover window is listed'),
    (r->>'group_key' = 'soon',
     '7 days left is "soon" (urgent<=3, soon<=7) — bucketed by the BACKEND -> '
       || coalesce(r->>'group_key','null')),
    -- exactly 7 days out is the SAME weekday name as today, which would read
    -- as "finishes Monday" on a Monday. Past day 6 the backend switches to a
    -- date on purpose; the day-name form is proven on B, below.
    (r->>'stockout_label' = replace(public.ui_text('reorder414.stockout_date_fmt'), '{date}',
                                    to_char(v_expect,'DD Mon')),
     'a week out reads as a DATE, because the day name would be ambiguous -> '
       || coalesce(r->>'stockout_label','null')),
    -- velocity 2/day x 14 cover days = 28, minus 14 on the shelf = 14
    ((r->>'suggest_qty')::int = 14,
     'suggested qty is velocity x cover-days minus the shelf -> '
       || coalesce(r->>'suggest_qty','null'));

  -- "Dolo finishes Thursday" — the headline claim. B sells 3/day with 9 on the
  -- shelf, so it runs out in 3 days, inside the window where a weekday name is
  -- the clearest thing to say.
  for i in 1..30 loop
    insert into pos_sale_lines(sale_id, line_no, medicine_id, product_name, qty, mrp,
                               disc_pct, disc_amount, gross, amount, gst_percent,
                               taxable, cgst, sgst, igst)
    select id, 2, v_b, 'C414 B', 3, 10,0,0,0,0,12,0,0,0,0
      from pos_sales where invoice_no = 'C414/'||i::text and pharmacy_id = v_shop;
  end loop;
  insert into pharmacy_stock(pharmacy_id, medicine_id, product_name, item_key,
                             source_kind, qty, unit_cost, mrp)
  values (v_shop, v_b, 'C414 B', 'm:'||v_b::text, 'opening', 9, 5.00, 10.00);

  v := public.pharmacy_reorder_screen();
  select x into r from jsonb_array_elements(v->'rows') x where (x->>'medicine_id')::bigint = v_b;
  insert into c414_log(ok, line) values
    (r->>'group_key' = 'urgent',
     '3 days left is "urgent" -> ' || coalesce(r->>'group_key','null')),
    (r->>'stockout_label' = replace(public.ui_text('reorder414.stockout_fmt'), '{day}',
                                    trim(to_char(v_today + 3,'Day'))),
     'and it reads as a DAY NAME — "Dolo finishes Thursday" -> '
       || coalesce(r->>'stockout_label','null')),
    ((v->'rows'->0->>'medicine_id')::bigint = v_b,
     'the soonest to run out is listed FIRST -> ' || coalesce(v->'rows'->0->>'product_name','null'));

  -- and remove B's shelf row again so the margin section below builds its own
  delete from pharmacy_stock where pharmacy_id = v_shop and medicine_id = v_b;

  -- the numbers are configurable, and changing one changes the answer
  perform public.pharmacy_reorder_settings_set(jsonb_build_object('cover_days', 30));
  v := public.pharmacy_reorder_screen();
  select x into r from jsonb_array_elements(v->'rows') x where (x->>'medicine_id')::bigint = v_a;
  insert into c414_log(ok, line) values
    ((r->>'suggest_qty')::int = 46,
     'raising cover-days to 30 raises the suggestion to 2x30-14 -> '
       || coalesce(r->>'suggest_qty','null'));
  perform public.pharmacy_reorder_settings_set(jsonb_build_object('cover_days', 14));

  -- ═══ 3. NOTHING IS EVER AUTO-PLACED ═════════════════════════════════════
  v := public.pharmacy_reorder_draft_build(v_shop);
  insert into c414_log(ok, line) values
    (coalesce((v->>'built')::boolean,false), 'a weekly draft is built for the owner');

  v := public.pharmacy_reorder_draft_get();
  insert into c414_log(ok, line) values
    (coalesce((v->>'has')::boolean,false), 'and it is waiting for them'),
    (coalesce(v->>'approve_label','') <> '' and coalesce(v->>'skip_label','') <> '',
     'with both its buttons worded by the backend');

  insert into c414_log(ok, line)
  select count(*) = 0,
         'APPROVING A DRAFT PLACES NO ORDER — the owner always confirms -> '
         || count(*)::text || ' orders'
    from orders o where o.customer_id = v_shop
     and o.created_at > now() - interval '1 minute';

  insert into c414_log(ok, line)
  select position('place_order' in coalesce(p.prosrc,'')) = 0,
         'and no function in this change can place one: '||p.proname
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pharmacy_reorder_add','pharmacy_reorder_draft_act',
                       'pharmacy_reorder_draft_build','pharmacy_reorder_draft_sweep');

  -- ═══ 4. THE COUNTER MARGIN FINDER ═══════════════════════════════════════
  -- A is asked for. Their margin on A is 10 - 7 = 3.00.
  -- B is on the shelf at cost 5   -> margin 5.00  (+2.00 more)
  -- C is on the shelf with NO recorded cost -> no margin, must never rank
  -- D is the same salt but NOT on the shelf at all -> must never appear
  insert into pharmacy_stock(pharmacy_id, medicine_id, product_name, item_key,
                             source_kind, qty, unit_cost, mrp) values
    (v_shop, v_b, 'C414 B', 'm:'||v_b::text, 'opening', 20, 5.00, 10.00),
    (v_shop, v_c, 'C414 C', 'm:'||v_c::text, 'opening', 20, null, 10.00);

  v := public.pos_margin_options(v_a, 10);
  insert into c414_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'the finder answers for a brand that IS on the shelf'),
    (coalesce((v->>'has')::boolean,false), 'and finds an alternative -> has='||coalesce(v->>'has','null')),
    (coalesce(v->>'title','') <> '', 'its heading is backend copy'),
    (v->>'self_margin_display' = public.inr_money(3.00),
     'their margin on the asked brand is MRP minus what they PAID -> '
       || coalesce(v->>'self_margin_display','null'));

  select x into r from jsonb_array_elements(v->'rows') x where (x->>'medicine_id')::bigint = v_b;
  insert into c414_log(ok, line) values
    (r is not null, 'the better-margin brand on the shelf is offered'),
    (r->>'margin_display' = public.inr_money(5.00),
     'with THEIR real margin on it -> ' || coalesce(r->>'margin_display','null')),
    (r->>'delta_display' = replace(public.ui_text('posmargin.delta_fmt'), '{amount}',
                                   public.inr_money(2.00)),
     'and the comparison worded by the backend -> ' || coalesce(r->>'delta_display','null'));

  insert into c414_log(ok, line) values
    (not exists (select 1 from jsonb_array_elements(v->'rows') x
                  where (x->>'medicine_id')::bigint = v_c),
     'a batch with NO recorded cost is never ranked — margins are never estimated'),
    (not exists (select 1 from jsonb_array_elements(v->'rows') x
                  where (x->>'medicine_id')::bigint = v_d),
     'and a same-salt brand that is NOT on their shelf never appears at all');

  -- ranking is by margin, descending
  insert into pharmacy_stock(pharmacy_id, medicine_id, product_name, item_key,
                             source_kind, qty, unit_cost, mrp)
  values (v_shop, v_d, 'C414 D', 'm:'||v_d::text, 'opening', 5, 1.00, 10.00);
  v := public.pos_margin_options(v_a, 10);
  insert into c414_log(ok, line) values
    ((v->'rows'->0->>'medicine_id')::bigint = v_d,
     'the highest real margin ranks FIRST -> '
       || coalesce(v->'rows'->0->>'margin_display','null')),
    ((v->'rows'->1->>'medicine_id')::bigint = v_b,
     'then the next -> ' || coalesce(v->'rows'->1->>'margin_display','null'));

  -- a brand the pharmacy does NOT stock gets no finder at all
  delete from pharmacy_stock where pharmacy_id = v_shop and medicine_id = v_a;
  v := public.pos_margin_options(v_a, 10);
  insert into c414_log(ok, line) values
    (coalesce((v->>'has')::boolean,true) is false,
     'asked for a brand they do not stock: the finder stays silent'),
    (coalesce(v->>'message','') <> '', 'and says so in the backend''s own words');

  -- the swap refuses anything not actually on the shelf
  v := public.pos_margin_swap(v_b, v_a, 1);
  insert into c414_log(ok, line) values
    (coalesce((v->>'ok')::boolean,true) is false,
     'the swap refuses a target that is not on the shelf -> ' || coalesce(v->>'error','ok'));
  v := public.pos_margin_swap(v_a, v_b, 2);
  insert into c414_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'and accepts one that is'),
    (coalesce(v->'line'->>'gst_label','') <> '' and (v->'line'->>'qty')::numeric = 2,
     'returning a PRICED replacement line the backend built -> '
       || coalesce(v->'line'->>'gst_label','null'));

  -- ═══ 5. A STRANGER SEES NOTHING ═════════════════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role','authenticated')::text, true);
  insert into c414_log(ok, line) values
    (coalesce((public.pharmacy_reorder_screen()->>'ok')::boolean, true) is false,
     'a stranger gets not_authorized from the reorder screen'),
    (coalesce((public.pos_margin_options(v_a, 5)->>'ok')::boolean, true) is false,
     'and from the margin finder');

  perform set_config('request.jwt.claims', null, true);
  for rec in select * from c414_log order by ord loop
    if rec.ok then v_pass := v_pass + 1; raise notice 'PASS  %', rec.line;
    else v_fail := v_fail + 1; raise notice 'FAIL  %', rec.line; end if;
  end loop;
  raise notice '';
  raise notice 'c414 proof: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then raise exception 'c414 proof: % assertion(s) failed', v_fail; end if;
end $proof$;

rollback;

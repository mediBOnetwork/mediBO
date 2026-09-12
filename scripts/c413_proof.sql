-- CMD #413 — the proof, on the live database, with seeded shelf stock.
--
-- Shop under test: 8f493db7 (has real POS sales from #411 with staff stamps, so
-- the theft radar has genuine movement to attribute rather than invented rows).
-- Everything this script seeds is scoped to that shop and to order
-- ea9df513-…, and re-running it is a no-op.
\set ON_ERROR_STOP on
\pset pager off

\set shop '''8f493db7-ef88-48b6-8c71-c84d0a6a7311'''
\set ord  '''ea9df513-387e-4772-922b-a404c1da3896'''

-- ── 0. clean the previous run of THIS script only ───────────────────────────
delete from public.pharmacy_count_session where pharmacy_id = :shop;
delete from public.pharmacy_return_list    where pharmacy_id = :shop;
delete from public.pharmacy_expiry_alert_log where pharmacy_id = :shop;
delete from public.order_returns
 where note like '%CMD #413%' and order_id = :ord;
delete from public.bill_line_allocations
 where bill_line_id in (select id from public.bill_lines where raw_name = 'C413 PROOF LINE');
delete from public.bill_lines where raw_name = 'C413 PROOF LINE';
delete from public.pharmacy_stock where pharmacy_id = :shop;

-- ── 1. a verified bill line + allocation, so the returns engine has something
--       returnable. This is #131/#395 machinery, seeded, not bypassed:
--       _return_returnable_qty reads exactly this pair. Two plain statements —
--       a data-modifying CTE writing to both tables did not survive here.
insert into public.bill_lines
  (supplier_name, raw_name, product_id, batch_no, expiry, qty, mrp, ptr, gst_pct,
   line_amount, verified, match_confidence, matched_by)
select 'Shree Distributors', 'C413 PROOF LINE', oi.product_id, 'B413A',
       to_char((now() at time zone 'Asia/Kolkata')::date + 120, 'MM/YYYY'),
       oi.quantity::numeric, 92.00, 71.20, 12, 356.00, true, 1, 'c413_proof'
  from public.order_items oi
 where oi.order_id = :ord and oi.product_id = 473032
 limit 1;

insert into public.bill_line_allocations (bill_line_id, order_id, order_item_id, product_id, qty)
select bl.id, oi.order_id, oi.id, oi.product_id, bl.qty
  from public.bill_lines bl, public.order_items oi
 where bl.raw_name = 'C413 PROOF LINE'
   and oi.order_id = :ord and oi.product_id = 473032;

\echo '   returnable on that line (the returns engine\'s own number):'
select oi.id, public._return_returnable_qty(oi.id) as returnable
  from public.order_items oi where oi.order_id = :ord and oi.product_id = 473032;

-- ── 2. the shelf. Four rows, one per bucket, plus one that is already past its
--       return window — the case the money is already lost on, which must NOT
--       be alerted about and must NOT go on the return list.
insert into public.pharmacy_stock
  (pharmacy_id, medicine_id, item_key, product_name, pack_label, batch_no, expiry, expiry_on,
   qty, unit_cost, mrp, source_kind, supplier_label, first_order_id, received_on)
select :shop, v.mid, v.mid::text, v.nm, v.pack, v.batch,
       to_char(((now() at time zone 'Asia/Kolkata')::date + v.days), 'MM/YYYY'),
       ((now() at time zone 'Asia/Kolkata')::date + v.days),
       v.qty, v.cost, v.mrp, v.src, v.sup,
       case when v.src = 'medibo_order' then :ord::uuid end,
       (now() at time zone 'Asia/Kolkata')::date - 20
  from (values
    -- bought on mediBO, expiring in 120 days: the default window (180→90 days
    -- before expiry) is OPEN and closes in 30 — the row the one-tap list is for,
    -- and the one that proves the order LINE resolves for the mediBO prefill.
    (473032, 'Isojol Tablet',                'Strip of 10', 'B413A', 120, 40::numeric,  71.20::numeric,  92::numeric, 'medibo_order', 'Shree Distributors'),
    -- this shop negotiated 120→45 with Local Agency, so at 48 days out the
    -- window closes in THREE days: the urgent ping.
    (511188, 'Azimax 100 Dry Syrup',         'Bottle',      'B413B',  48, 12::numeric, 118.00::numeric, 149::numeric, 'outside',      'Local Agency'),
    -- 80 days out on the default window: already CLOSED. It sits in the 90-day
    -- bucket (the owner should see the money) but must not be alerted on and
    -- must not go on the return list — that trip would be wasted.
    (260942, 'Oriprim DS 800mg/160mg Tablet','Strip of 10', 'B413C',  80, 30::numeric,  46.50::numeric,  60::numeric, 'outside',      'Shree Distributors'),
    -- 25 days out: deep in the 30-day bucket, window long closed. Money lost.
    (252328, 'SyNtraN 200 Capsule',          'Strip of 10', 'B413D',  25,  8::numeric, 210.00::numeric, 268::numeric, 'outside',      'Shree Distributors'),
    -- the two products the POS actually sold, so the radar has movement
    (255470, 'Paracad 150mg Injection',      'Vial',        'B413E', 300, 40::numeric,  11.00::numeric,  16::numeric, 'outside',      'Shree Distributors'),
    (241444, 'Paracad Plus Oral Suspension', 'Bottle',      'B413F', 330, 25::numeric,  12.50::numeric,  18::numeric, 'outside',      'Local Agency')
  ) as v(mid, nm, pack, batch, days, qty, cost, mrp, src, sup);

-- a shop-specific return window that is TIGHTER than the admin default, to
-- prove the four-deep resolution actually resolves.
insert into public.pharmacy_return_window
  (pharmacy_id, supplier_key, supplier_name, opens_days, closes_days, updated_by, note)
values (:shop, 'local agency', 'Local Agency', 120, 45, 'c413_proof',
        'CMD #413 proof — this shop negotiated a shorter window with this agency.')
on conflict (pharmacy_id, supplier_key) where pharmacy_id is not null do update
  set opens_days = excluded.opens_days, closes_days = excluded.closes_days;

\echo '── 1. the resolver: bucket, value at cost, window state ────────────────'
select product_name, expiry, qty, unit_cost, value_at_cost, bucket_key,
       supplier_name, window_state, days_to_close,
       (source_order_item_id is not null) as line_resolved
  from public._c413_rows(:shop) order by expiry_on;

\echo ''
\echo '── 2-4. home, return list, spot count, report — the real builders ──────'
create temporary table c413_run as select public.c413_proof_run(:shop) as r;

\echo '   money headline (at COST, never MRP):'
select r->'home'->>'headline' as headline, r->'home'->>'cost_note' as note from c413_run;

\echo '   buckets:'
select b->>'label' as bucket, b->>'count_label' as items, b->>'value_display' as value, b->>'tone' as tone
  from c413_run, jsonb_array_elements(r->'home'->'buckets') b;

\echo '   return-window alerts (closed windows must NOT appear):'
select w->>'product_name' as product, w->>'supplier_label' as supplier,
       w->>'closes_label' as closes, w->>'value_display' as value, w->>'tone' as tone
  from c413_run, jsonb_array_elements(r->'home'->'windows') w;

\echo '   the return list, grouped by supplier:'
select g->>'supplier_label' as supplier, g->>'count_label' as items, g->>'value_display' as value,
       i->>'product_name' as product, i->>'source_label' as source,
       i->>'qty_label' as on_shelf, i->>'medibo_qty_label' as returnable,
       i->>'medibo_status' as raised, i->>'medibo_message' as engine_said
  from c413_run, jsonb_array_elements(r->'sent'->'groups') g, jsonb_array_elements(g->'items') i;

\echo '   raised on mediBO:'
select r->'sent'->>'raised' as raised, r->'sent'->>'refused' as refused,
       r->'sent'->>'status' as list_status, r->'sent'->>'photo_required' as photo_required
  from c413_run;
select ret.status, ret.reason_code, ret.qty, ret.credit_total, left(ret.note,44) note
  from public.order_returns ret where ret.note like '%CMD #413%';

\echo '   the OPEN count sheet must expose no expected number:'
select l->>'product_name' as product, l->>'has_expected' as has_expected,
       coalesce(l->>'expected_label','(hidden)') as expected
  from c413_run, jsonb_array_elements(r->'sheet_open'->'lines') l;

\echo '   after submitting, opening + received - sold vs counted:'
select l->>'product_name' as product, l->>'opening_label' as opening, l->>'received_label' as recvd,
       l->>'sold_label' as sold, l->>'expected_label' as expected, l->>'counted_label' as counted,
       l->>'variance_label' as diff, l->>'state_label' as state, l->>'tone' as tone
  from c413_run, jsonb_array_elements(r->'submitted'->'lines') l;

\echo '   per shift:'
select st->>'staff_label' as staff, st->>'sold_label' as sold, st->>'share_label' as share,
       st->>'variance_label' as diff, st->>'value_display' as value
  from c413_run, jsonb_array_elements(r->'submitted'->'staff') st;

\echo '   the weekly report headline sentence:'
select it->>'headline' as sentence, it->>'value_display' as value, it->>'tone' as tone
  from c413_run, jsonb_array_elements(r->'report'->'items') it;
select r->'report'->>'leaked_display' as value_of_difference,
       r->'report'->>'cause_note' as calm_wording from c413_run;

\echo ''
\echo '── 5. the watcher: two pings, then a re-run that sends nothing ─────────'
select public.pharmacy_expiry_scan(40) as first_run;
select public.pharmacy_expiry_scan(40) as second_run_must_be_zero;

\echo ''
\echo '── 6. the security fence ───────────────────────────────────────────────'
select jsonb_pretty(public.c413_qa_report());

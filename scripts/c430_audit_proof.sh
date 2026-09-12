#!/usr/bin/env bash
# CHANGE #430 — end-to-end proof of the stock audit, on the mediBO Test Pharmacy.
#
# It runs the REAL auth-scoped RPCs by setting request.jwt.claims, first as the
# shop owner and then as a second staff login, because the one rule this feature
# turns on — a discrepancy is confirmed by somebody ELSE, blind — cannot be
# proven from a single session.
#
#   1. blind: the count sheet payload carries NO expected quantity
#   2. freeze-free: a sale during the count is allowed for, not charged as a loss
#   3. variance: counted vs expected per batch, with value at stake
#   4. the same person may NOT confirm their own count
#   5. two counts that agree = truth; two that disagree = owner review
#   6. accept moves the ledger and attributes every adjustment
#   7. the sealed log verifies, and a tampered entry is caught at its own seq
#
# Usage: bash scripts/c430_audit_proof.sh
set -euo pipefail
DBURL="$(cat "$HOME/.medibo/dburl")"

psql "$DBURL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
\set QUIET on
\pset pager off
\set shop   '3f1c9a10-4b6e-4c9a-9f22-5a0d7e8b1c33'
\set owner  '371d5289-c2e1-4475-9215-8f603e72ca9e'
\set staff  'c4300000-0000-4000-8000-000000000002'

-- ── 0. clean slate, test pharmacy only ──────────────────────────────────────
delete from pharmacy_count_session where pharmacy_id = :'shop';
delete from pharmacy_audit_log      where pharmacy_id = :'shop';
delete from pharmacy_cycle_plan     where pharmacy_id = :'shop';
delete from customer_users          where customer_id = :'shop' and display_name = 'C430 Second Counter';
delete from pharmacy_stock          where pharmacy_id = :'shop' and batch_no in ('AUD-1','AUD-2','AUD-3');
delete from pharmacy_stock_move     where ref_kind = 'c430_proof';

insert into customer_users (customer_id, identity, display_name, access_key, auth_user_id, is_active)
select :'shop', 'c430-second-counter', 'C430 Second Counter',
       (select access_key from customer_access_preset order by access_key limit 1),
       :'staff', true;

-- three lots: one that will match, one short, one with no expiry on the books
insert into pharmacy_stock (id, pharmacy_id, medicine_id, product_name, pack_label,
       item_key, batch_no, expiry, expiry_on, qty, unit_cost, mrp, source_kind,
       supplier_label, rack_label, received_on)
values
 ('c4300000-0000-4000-8000-00000000aa01', :'shop', 311063, 'Pan 40 Tablet AUD', '15 tablets',
  'c430-pan', 'AUD-1', '11/2026', '2026-11-30', 20, 8.50, 12, 'outside', 'SAI GANESH PHARMA', 'Rack A',
  (now() at time zone 'Asia/Kolkata')::date - 40),
 ('c4300000-0000-4000-8000-00000000aa02', :'shop', 312838, 'Azithral 500 AUD', '5 tablets',
  'c430-azi', 'AUD-2', '09/2027', '2027-09-30', 12, 45.00, 60, 'outside', 'SAI GANESH PHARMA', 'Rack A',
  (now() at time zone 'Asia/Kolkata')::date - 30),
 ('c4300000-0000-4000-8000-00000000aa03', :'shop', 231612, 'Augmentin AUD', '10 tablets',
  'c430-aug', 'AUD-3', null, null, 6, 15.30, 20, 'outside', 'SAI GANESH PHARMA', 'Rack A',
  (now() at time zone 'Asia/Kolkata')::date - 20);

-- the inference engine's view, so expected comes from the layer that owns it
insert into pharmacy_lot_inference (lot_id, pharmacy_id, medicine_id, expiry_on, qty_in,
  inferred_sold, inferred_left, left_low, left_high, confidence, method, per_day, days_live)
values
 ('c4300000-0000-4000-8000-00000000aa01', :'shop', 311063, '2026-11-30', 20, 0, 20, 18, 20, 0.7, 'inferred', 0.4, 40),
 ('c4300000-0000-4000-8000-00000000aa02', :'shop', 312838, '2027-09-30', 12, 0, 12, 10, 12, 0.3, 'inferred', 0.2, 30),
 ('c4300000-0000-4000-8000-00000000aa03', :'shop', 231612, null,          6,  0,  6,  5,  6, 0.9, 'inferred', 0.1, 20)
on conflict (lot_id) do update set inferred_left = excluded.inferred_left,
  per_day = excluded.per_day, confidence = excluded.confidence, qty_in = excluded.qty_in;

-- ── 1. the owner starts a partial audit of Rack A ───────────────────────────
select set_config('request.jwt.claims',
  json_build_object('sub', :'owner', 'role','authenticated')::text, false);

\echo '--- start: a partial (one rack) audit'
select pharmacy_audit_start('partial','rack','Rack A', 100) as started \gset res_
select :'res_started'::jsonb ->> 'ok' as ok, :'res_started'::jsonb ->> 'lines' as lines;
select (:'res_started'::jsonb ->> 'session_id') as sid \gset

\echo '--- BLIND: the count sheet payload carries no expected quantity at all'
select jsonb_path_query_array(pharmacy_audit_sheet(:'sid'::uuid), '$.rows[*].expected_qty') as expected_in_payload,
       jsonb_path_query_array(pharmacy_audit_sheet(:'sid'::uuid), '$.rows[*].has_expected') as has_expected,
       (pharmacy_audit_sheet(:'sid'::uuid) ->> 'blind') as blind_flag;

-- ── 2. a sale happens WHILE the count runs ──────────────────────────────────
insert into pharmacy_stock_move (pharmacy_id, stock_id, item_key, kind, qty_delta,
       qty_after, unit_cost, reason_code, note, actor_label, ref_kind, ref_id)
values (:'shop', 'c4300000-0000-4000-8000-00000000aa01', 'c430-pan', 'sale', -3, 17, 8.50,
        null, 'sold at the counter mid-count', 'POS', 'c430_proof', 'sale-1');

\echo '--- count: voice, barcode and typing, with an expiry captured on the strip'
select pharmacy_audit_count(:'sid'::uuid, jsonb_build_array(
  jsonb_build_object('stock_id','c4300000-0000-4000-8000-00000000aa01','qty',17,'method','voice'),
  jsonb_build_object('stock_id','c4300000-0000-4000-8000-00000000aa02','qty',9, 'method','barcode'),
  jsonb_build_object('stock_id','c4300000-0000-4000-8000-00000000aa03','qty',6, 'method','type',
                     'expiry','07/2027')
)) as counted;

select product_name, expiry_on as expiry_now_on_the_shelf
  from pharmacy_stock where id = 'c4300000-0000-4000-8000-00000000aa03';

\echo '--- close: variance, with the mid-count sale allowed for'
select pharmacy_audit_close(:'sid'::uuid) as closed;
select product_name, counted_qty, expected_qty, sold_qty, variance_qty, variance_value, status
  from pharmacy_count_line where session_id = :'sid'::uuid order by product_name;

-- ── 3. the second count ─────────────────────────────────────────────────────
\echo '--- recount by the SAME person is refused'
select (pharmacy_audit_recount(
   (select id from pharmacy_count_round where session_id = :'sid'::uuid limit 1), 9)
 ->> 'message') as same_person_refusal;

\echo '--- recount by a DIFFERENT staff member, blind (no first count in the payload)'
select set_config('request.jwt.claims',
  json_build_object('sub', :'staff', 'role','authenticated')::text, false);
select jsonb_path_query_array(pharmacy_audit_recount_sheet(:'sid'::uuid),
                              '$.rows[*].product_name') as to_recount,
       (pharmacy_audit_recount_sheet(:'sid'::uuid) -> 'rows' -> 0 ? 'counted_qty') as leaks_first_count;

select (pharmacy_audit_recount(
   (select cr.id from pharmacy_count_round cr join pharmacy_count_line cl on cl.id = cr.line_id
     where cr.session_id = :'sid'::uuid and cl.batch_no = 'AUD-2'), 9) ->> 'message') as agreed;

select status from pharmacy_count_line where session_id = :'sid'::uuid and batch_no = 'AUD-2';

-- ── 4. accept: the ledger moves, every adjustment attributed ────────────────
select set_config('request.jwt.claims',
  json_build_object('sub', :'owner', 'role','authenticated')::text, false);

\echo '--- accept'
select pharmacy_audit_accept(:'sid'::uuid) as accepted;
select cl.product_name, ca.variance_qty, ca.variance_value, ca.staff_label
  from pharmacy_count_attribution ca join pharmacy_count_line cl on cl.id = ca.line_id
 where ca.session_id = :'sid'::uuid order by cl.product_name;
select product_name, inferred_left as ledger_after
  from pharmacy_lot_inference i join pharmacy_stock s on s.id = i.lot_id
 where i.lot_id in ('c4300000-0000-4000-8000-00000000aa01','c4300000-0000-4000-8000-00000000aa02');

\echo '--- the sealed record'
select (pharmacy_audit_verify(null) ->> 'label') as seal_label,
       (pharmacy_audit_verify(null) ->> 'intact') as intact,
       (pharmacy_audit_verify(null) ->> 'entries') as entries;

\echo '--- tamper test (rolled back): editing one entry breaks the chain at its own seq'
begin;
  update pharmacy_audit_log set payload = payload || '{"lines":999}'::jsonb
   where pharmacy_id = :'shop' and event = 'lines_counted';
  select (pharmacy_audit_verify(null) ->> 'intact') as intact_after_tamper,
         (pharmacy_audit_verify(null) ->> 'broken_at') as broken_at_seq,
         (pharmacy_audit_verify(null) ->> 'label') as label_after_tamper;
rollback;

\echo '--- certificate, next actions, cycle plan'
select (pharmacy_audit_certificate(:'sid'::uuid) ->> 'line') as certificate_line,
       (pharmacy_audit_certificate(:'sid'::uuid) ->> 'note') as certificate_note;
select jsonb_path_query_array(pharmacy_audit_actions(:'sid'::uuid), '$.rows[*].label') as next_actions;
select jsonb_array_length(pharmacy_audit_cycle_plan() -> 'rows') as cycle_items;

\echo '--- VERDICT'
select
  (select count(*) from pharmacy_count_line
    where session_id = :'sid'::uuid and counted_qty is not null)          as counted_lines,
  (select count(*) from pharmacy_count_line
    where session_id = :'sid'::uuid and sold_qty = 3)                     as freeze_free_allowed,
  (select count(*) from pharmacy_count_line
    where session_id = :'sid'::uuid and status = 'confirmed')             as second_count_confirmed,
  (select count(*) from pharmacy_count_attribution
    where session_id = :'sid'::uuid)                                      as adjustments_attributed,
  (select count(*) from pharmacy_stock
    where id = 'c4300000-0000-4000-8000-00000000aa03' and expiry_on is not null) as expiry_captured,
  ((pharmacy_audit_verify(null) ->> 'intact')::boolean)                   as seal_intact;
SQL

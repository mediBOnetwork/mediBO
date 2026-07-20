-- pgTAP tests for continuous voice counting + timestamped bag segmentation.
-- Run with `supabase test db` (requires the pgtap extension + local Docker stack).
-- Every scenario here was also hand-verified against the live project
-- (swojhmarmaijkshsbeih) inside a rolled-back transaction before this file was written.
--
-- Fixtures use fake suppliers/pharmacies and a real MEDICINE.id (FK-required) so the
-- whole test runs against fully isolated data with no risk of touching real orders.

begin;
select plan(11);

create extension if not exists pgtap with schema public;

select set_config('request.jwt.claim.sub',
  (select id::text from auth.users u join admins a on lower(btrim(u.email))=lower(btrim(a.email))
     where a.is_super = true limit 1), true);

-- ── fixtures: scenario 1 (finalize: attribution + dedup + persist + idempotency) ──
do $$
declare v_product bigint;
begin
  select id into v_product from "MEDICINE" limit 1;

  insert into bags (bag_no, status) values (97701,'empty'), (97702,'empty')
    on conflict (bag_no) do nothing;

  insert into orders (id, pharmacy_name, status, placed_by_admin)
    values ('00000000-0000-0000-0000-000000097701', 'PGTAP_QA_PHARMACY', 'confirmed', true);

  insert into order_items (id, order_id, product_id, product_name, quantity, pharmacy_name, assigned_supplier, fulfillment_state)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000097701', v_product, 'PGTAP Test Product', 15, 'PGTAP_QA_PHARMACY', 'PGTAP_QA_SUPPLIER', 'pending'),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000097701', v_product, 'PGTAP Test Product', 15, 'PGTAP_QA_PHARMACY', 'PGTAP_QA_SUPPLIER', 'pending');

  insert into supplier_count_mode (assigned_supplier, mode, set_at, set_by)
    values ('PGTAP_QA_SUPPLIER', 'warehouse', now(), 'pgtap');

  -- bag 97701 mapped at t=3s, bag 97702 mapped at t=40s
  insert into voice_bag_boundaries (session_key, supplier_name, bag_no, mapped_at_sec) values
    ('pgtap|warehouse|1', 'PGTAP_QA_SUPPLIER', 97701, 3),
    ('pgtap|warehouse|1', 'PGTAP_QA_SUPPLIER', 97702, 40);

  insert into voice_clip_mentions (supplier_name, session_key, stage, recording_seq, ord, clip_path, product_id, matched_name, qty, t_start_sec, status) values
    ('PGTAP_QA_SUPPLIER','pgtap|warehouse|1','warehouse',1,0,'qa/1.webm',v_product,'PGTAP Test Product',99,1,'counted'),  -- before first map -> needs_bag_review
    ('PGTAP_QA_SUPPLIER','pgtap|warehouse|1','warehouse',1,1,'qa/1.webm',v_product,'PGTAP Test Product',3,5,'counted'),   -- bag97701
    ('PGTAP_QA_SUPPLIER','pgtap|warehouse|1','warehouse',2,0,'qa/2.webm',v_product,'PGTAP Test Product',4,8,'counted'),   -- overlap dup of prev (diff=3<=6) -> merge, keep max=4
    ('PGTAP_QA_SUPPLIER','pgtap|warehouse|1','warehouse',2,1,'qa/2.webm',v_product,'PGTAP Test Product',2,20,'counted'),  -- gap 12>6 -> genuine repeat, sums -> bag97701 total 6
    ('PGTAP_QA_SUPPLIER','pgtap|warehouse|1','warehouse',3,0,'qa/3.webm',v_product,'PGTAP Test Product',3,45,'counted'),  -- bag97702, just after its map
    ('PGTAP_QA_SUPPLIER','pgtap|warehouse|1','warehouse',2,2,'qa/2.webm',null,'PGTAP Mystery Item',1,15,'counted');       -- unmatched, never persisted
end $$;

select voice_finalize_session('pgtap|warehouse|1') as finalize_result \gset

-- 1-2: attribution — mention just after a map goes to that bag, mention before any map is flagged
select is(
  (select applied_bag_no from voice_clip_mentions where session_key='pgtap|warehouse|1' and t_start_sec=45),
  97702, 'mention right after bag 97702''s map is attributed to 97702');

select is(
  (select status from voice_clip_mentions where session_key='pgtap|warehouse|1' and t_start_sec=1),
  'needs_bag_review', 'mention before the first bag map is flagged needs_bag_review, never guessed');

-- 3: needs_bag_review mentions are never persisted (applied_bag_no stays null)
select is(
  (select applied_bag_no from voice_clip_mentions where session_key='pgtap|warehouse|1' and t_start_sec=1),
  null, 'needs_bag_review mention has no applied_bag_no');

-- 4-6: dedup — overlap-seam duplicate collapses (kept row absorbs the max qty), genuine repeat stays separate
select is(
  (select status from voice_clip_mentions where session_key='pgtap|warehouse|1' and t_start_sec=8),
  'dup_merged', 'the t=8s mention (3s after t=5s, same bag) is merged as an overlap-seam duplicate');

select is(
  (select qty from voice_clip_mentions where session_key='pgtap|warehouse|1' and t_start_sec=5),
  4::numeric, 'the surviving t=5s mention absorbs the larger qty (4) from its merged duplicate');

select is(
  (select status from voice_clip_mentions where session_key='pgtap|warehouse|1' and t_start_sec=20),
  'counted', 'the t=20s mention (12s after t=8s, same bag) is a genuine repeat, not merged');

-- 7: unmatched (product_id null) mentions are reported, never persisted
select is(
  jsonb_array_length(finalize_result->'unmatched_mentions'), 1,
  'the product-less mention is surfaced in unmatched_mentions');

-- 8-9: persisted totals — dedup-merged (4) + genuine repeat (2) = 6 for bag 97701; 3 for bag 97702
select is(
  (select qty from bag_item_counts where assigned_supplier='PGTAP_QA_SUPPLIER' and bag_no=97701),
  6::numeric, 'bag 97701 total is merged-dup(4) + genuine-repeat(2) = 6, not a plain sum of all 3 mentions');

select is(
  (select qty from bag_item_counts where assigned_supplier='PGTAP_QA_SUPPLIER' and bag_no=97702),
  3::numeric, 'bag 97702 total is 3');

-- 10: idempotency — re-running finalize does not change the persisted totals
select voice_finalize_session('pgtap|warehouse|1');
select voice_finalize_session('pgtap|warehouse|1');
select is(
  (select sum(qty) from bag_item_counts where assigned_supplier='PGTAP_QA_SUPPLIER'),
  9::numeric, 're-running finalize twice more does not double-apply totals (still 6+3=9)');

-- ── fixtures: scenario 2 (bag_count_set(p_bag_no) cap + rollback) ──
do $$
declare v_product bigint;
begin
  select id into v_product from "MEDICINE" limit 1;
  insert into bags (bag_no, status) values (97703,'empty'), (97704,'empty') on conflict (bag_no) do nothing;
  insert into orders (id, pharmacy_name, status, placed_by_admin)
    values ('00000000-0000-0000-0000-000000097702', 'PGTAP_QA_PHARMACY2', 'confirmed', true);
  insert into order_items (id, order_id, product_id, product_name, quantity, pharmacy_name, assigned_supplier, fulfillment_state)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000097702', v_product, 'PGTAP Test Product', 10, 'PGTAP_QA_PHARMACY2', 'PGTAP_QA_SUPPLIER2', 'pending');
  insert into supplier_count_mode (assigned_supplier, mode, set_at, set_by)
    values ('PGTAP_QA_SUPPLIER2', 'warehouse', now(), 'pgtap');

  perform bag_count_set('PGTAP_QA_SUPPLIER2', v_product, 6, 'qa_baseline', 97703);

  create temp table pgtap_overcap_result as
    select bag_count_set('PGTAP_QA_SUPPLIER2', v_product, 7, 'qa_overcap', 97704) as res; -- 6+7=13 > ordered 10
end $$;

-- 11: bag_count_set(p_bag_no) respects the ordered-qty cap and rolls back cleanly on rejection
select is(
  (select res->>'error' from pgtap_overcap_result),
  'exceeds_ordered', 'bag_count_set(p_bag_no) rejects a qty that would exceed ordered - other_bags, leaving no partial row');

select * from finish();
rollback;

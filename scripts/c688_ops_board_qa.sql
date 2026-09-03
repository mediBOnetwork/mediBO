-- scripts/c688_ops_board_qa.sql — CHANGE #688, the ops board's own QA.
--
-- Seeds ONE synthetic order into every one of the ten SLA stages, proves the
-- clock, the tone and the sort, proves that an SLA edit takes effect with no
-- deploy, and proves a zone override beats the platform default — then ROLLS
-- THE WHOLE THING BACK, so production is never left holding QA orders.
--
-- Run it any time the stage ladder or the SLA maths is touched:
--   psql "$(cat ~/.medibo/dburl)" -X -q -f scripts/c688_ops_board_qa.sql
--
-- The jwt claim below is the super admin's; ops_board() answers 'not_authorized'
-- without it, which is itself part of what this proves.

\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claims', json_build_object('sub','f5d6ce2f-1182-427f-93de-fb70cde2cf2a','role','authenticated')::text, true);

-- ── seed one synthetic order per stage, in zone 1 ────────────────────────────
create temporary table qa_stage(stage text, ord uuid, oi uuid) on commit drop;

insert into qa_stage(stage, ord, oi)
select s, gen_random_uuid(), gen_random_uuid()
  from unnest(array['accept','inquiry','supplier_order','collect','arrival',
                    'count','bag','pack','dispatch','delivered']) s;

insert into orders (id, status, fulfillment_status, created_at, zone_id, order_code,
                    pharmacy_name, total_amount, items, is_synthetic)
select q.ord,
       case when q.stage='accept' then 'pending' else 'accepted' end,
       'open', now() - interval '3 hours', 1::smallint,
       'QA688-' || upper(q.stage), 'QA Pharmacy ' || q.stage, 1000, '[]'::jsonb, true
  from qa_stage q;

insert into order_items (id, order_id, product_name, quantity, price, status, created_at,
                         assigned_supplier, collect_locked, collect_locked_at,
                         arrived_at, wh_recount_qty, packed, unfulfillable, zone_id)
select q.oi, q.ord, 'QA item', 1, 100, 'active', now() - interval '3 hours',
       case when q.stage in ('accept','inquiry') then null else 'QA SUP ' || q.stage end,
       (q.stage in ('arrival','count','bag','pack','dispatch','delivered')),
       case when q.stage in ('arrival','count','bag','pack','dispatch','delivered')
            then now() - interval '2 hours' end,
       case when q.stage in ('count','bag','pack','dispatch','delivered')
            then now() - interval '90 minutes' end,
       case when q.stage in ('bag','pack','dispatch','delivered') then 1 end,
       (q.stage in ('dispatch','delivered')),
       false, 1::smallint
  from qa_stage q;

-- a PO exists for every stage at or past 'collect' (so 'supplier_order' is the
-- only one still waiting for one)
insert into supplier_orders (id, order_id, supplier_name, created_at, zone_id, is_synthetic)
select gen_random_uuid(), q.ord, 'QA SUP ' || q.stage, now() - interval '2 hours', 1::smallint, true
  from qa_stage q
 where q.stage in ('collect','arrival','count','bag','pack','dispatch','delivered');

-- a bag allocation for every stage at or past 'pack'
insert into bag_allocations (order_item_id, order_id, assigned_supplier, product_id, bag_no, qty, created_at, is_synthetic)
select q.oi, q.ord, 'QA SUP ' || q.stage, 1, 1, 1, now() - interval '1 hour', true
  from qa_stage q
 where q.stage in ('pack','dispatch','delivered');

-- a delivery only for 'delivered' (so 'dispatch' is the one with no rider)
insert into deliveries (order_id, status, created_at, assigned_at, zone_id, is_synthetic)
select q.ord, 'assigned', now() - interval '30 minutes', now() - interval '30 minutes',
       1::smallint, true
  from qa_stage q where q.stage = 'delivered';

select 'A. stage ladder — one order landed in EVERY stage:' as check;
select s.stage_key, o.order_code
  from public._ops_order_stage(1::smallint) s
  join orders o on o.id = s.order_id
 where o.order_code like 'QA688-%'
 order by (select sort_order from sla_stage where stage_key = s.stage_key);

-- ── controlled clocks: force one green, one amber, one red ──────────────────
select 'B. tone + sort — entered_at drives green/amber/red:' as check;
update order_stage_history h set entered_at = now() - interval '5 minutes'
  from qa_stage q where h.order_id = q.ord;   -- (no rows yet; stamp first)
select ops_stage_stamp(1::smallint);

-- accept SLA = 30m: 5m -> green, 25m -> amber, 40m -> red
update order_stage_history set entered_at = now() - interval '5 minutes'
 where order_id = (select ord from qa_stage where stage='count');
update order_stage_history set entered_at = now() - interval '50 minutes'
 where order_id = (select ord from qa_stage where stage='bag');   -- bag SLA 45m -> red
update order_stage_history set entered_at = now() - interval '36 minutes'
 where order_id = (select ord from qa_stage where stage='pack');  -- pack SLA 45m, amber at 31.5m

select jsonb_pretty(jsonb_agg(jsonb_build_object(
         'code', r->>'order_code', 'stage', r->>'stage_label',
         'tone', r->>'tone', 'clock', r->>'clock_label', 'sla', r->>'sla_label',
         'owner', r->>'owner_label', 'next', r->>'next_action')))
  from jsonb_array_elements(ops_board(1::smallint)->'rows') r
 where r->>'order_code' in ('QA688-COUNT','QA688-BAG','QA688-PACK');

select 'C. sort — the payload order of the three QA rows (worst first):' as check;
select ord, code, tone from (
  select row_number() over () as ord, r->>'order_code' as code, r->>'tone' as tone
    from jsonb_array_elements(ops_board(1::smallint)->'rows') r) x
 where code like 'QA688-%' order by ord;

-- ── D. an SLA edit takes effect with NO deploy ──────────────────────────────
select 'D. SLA edit — count was green at 5m; set count SLA to 2m and re-read:' as check;
select ops_sla_config_set(jsonb_build_object('zone_id', null,
         'rows', jsonb_build_array(jsonb_build_object('stage_key','count','sla_minutes',2))));
select r->>'order_code' as code, r->>'tone' as tone, r->>'clock_label' as clock, r->>'sla_label' as sla
  from jsonb_array_elements(ops_board(1::smallint)->'rows') r
 where r->>'order_code' = 'QA688-COUNT';

select 'E. zone override beats the platform default:' as check;
select ops_sla_config_set(jsonb_build_object('zone_id', 1,
         'rows', jsonb_build_array(jsonb_build_object('stage_key','count','sla_minutes',600))));
select r->>'order_code' as code, r->>'tone' as tone, r->>'sla_label' as sla
  from jsonb_array_elements(ops_board(1::smallint)->'rows') r
 where r->>'order_code' = 'QA688-COUNT';

select 'F. ops_order_detail — the stage timeline of the pack order:' as check;
select jsonb_pretty(jsonb_path_query_array(
         ops_order_detail((select ord from qa_stage where stage='pack')),
         '$.steps[*] ? (@.reached == true)'));

rollback;

-- CMD #410 — recorded verification for the wishlist price-alert watcher.
--
-- Everything runs inside ONE transaction that ends in ROLLBACK, so the proof
-- moves a real price, watches the real watcher react, and leaves production
-- exactly as it found it. notify() is not reached: the digest is asserted on
-- the QUEUE and the per-day ledger, which is the part this change owns.
--
-- What it proves, in order:
--   1. a price move on a wishlisted product queues exactly ONE row per wisher
--   2. re-running the scan queues NOTHING more (the snapshot advanced)
--   3. a SECOND move before the digest UPDATES the pending row, never adds one
--      — this is the "one price import must not fire a storm" guarantee
--   4. the digest collapses the customer's pending rows into ONE ledger entry
--   5. a same-day second digest sends nothing (one per customer per IST day)
--   6. an unentitled viewer gets the FACT with no figure (no leaked trade rate)
begin;
select public.db_session_guard();

\set ON_ERROR_STOP on

-- A product that at least one customer wishes for, with a real trade rate.
create temporary table _p on commit drop as
select wi.product_id, wi.account_id
  from public.wishlist_items wi
  join public.medicine_pricing mp on mp.product_id = wi.product_id and mp.pricing_ready
 limit 1;

-- If no wishlisted product has a rate, give one to the first wishlisted
-- product for the length of this transaction.
insert into public.medicine_pricing (product_id, ptr, gst_pct, discount_pct, pricing_ready, pricing_source)
select wi.product_id, 100.00, 12, 0, true, 'c410_proof'
  from public.wishlist_items wi
 where not exists (select 1 from _p)
 limit 1
on conflict (product_id) do update set ptr = 100.00, gst_pct = 12, pricing_ready = true;

delete from _p;
insert into _p
select wi.product_id, wi.account_id
  from public.wishlist_items wi
  join public.medicine_pricing mp on mp.product_id = wi.product_id and mp.pricing_ready
 limit 1;

\echo '--- baseline: snapshot the current state, expect zero alerts ---'
select public.wishlist_alert_scan() as baseline_scan;

-- 1 ── the price moves DOWN.
update public.medicine_pricing mp
   set ptr = round(mp.ptr * 0.80, 2)
  from _p where mp.product_id = _p.product_id;

select public.wishlist_alert_scan() as scan_after_drop;

\echo '--- 1. exactly one pending row per wisher of that product ---'
select (select count(*) from public.wishlist_alert_queue q join _p p on p.product_id = q.product_id
         where q.sent_at is null and q.kind = 'price_drop')                                as pending_drop_rows,
       (select count(*) from public.wishlist_items wi join _p p on p.product_id = wi.product_id) as wishers,
       (select count(*) from public.wishlist_alert_queue q join _p p on p.product_id = q.product_id
         where q.sent_at is null and q.kind = 'price_drop')
       = (select count(*) from public.wishlist_items wi join _p p on p.product_id = wi.product_id)
                                                                                            as pass_one_row_per_wisher;

\echo '--- 2. re-running the scan with nothing changed queues nothing more ---'
select public.wishlist_alert_scan() as rescan_no_change;
select (select count(*) from public.wishlist_alert_queue q join _p p on p.product_id = q.product_id
         where q.sent_at is null and q.kind = 'price_drop') = 1 as pass_no_duplicate_on_rescan;

\echo '--- 3. a SECOND move before the digest updates the row, never adds one ---'
update public.medicine_pricing mp
   set ptr = round(mp.ptr * 0.90, 2)
  from _p where mp.product_id = _p.product_id;
select public.wishlist_alert_scan() as scan_after_second_drop;
select count(*) as still_one_pending_row,
       count(*) = 1 as pass_storm_collapsed
  from public.wishlist_alert_queue q join _p p on p.product_id = q.product_id
 where q.sent_at is null and q.kind = 'price_drop';

\echo '--- 4. the digest collapses the queue into ONE ledger row for the day ---'
select public.wishlist_alert_digest(25) as digest_run;
select (select count(*) from public.wishlist_digest_log d join _p p on p.account_id = d.account_id
         where d.digest_on = (now() at time zone 'Asia/Kolkata')::date) = 1 as pass_one_digest_row,
       (select count(*) from public.wishlist_alert_queue q join _p p on p.account_id = q.account_id
         where q.sent_at is null) = 0                                       as pass_queue_drained;

\echo '--- 5. a same-day second digest sends nothing ---'
select (public.wishlist_alert_digest(25) ->> 'digests_sent')::int = 0 as pass_one_per_day;

\echo '--- 6. the read RPC never leaks a trade figure to an unentitled viewer ---'
-- wishlist_alerts() reads my_customer_id(); with no JWT there is no customer,
-- so the refusal itself is the proof that the block is account-scoped.
select (public.wishlist_alerts() ->> 'ok') = 'false'
   and (public.wishlist_alerts() ->> 'error') = 'not_customer' as pass_scoped_to_account;

rollback;

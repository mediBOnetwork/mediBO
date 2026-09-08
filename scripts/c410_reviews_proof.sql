-- CMD #410 — recorded verification for reviews, Q&A and moderation.
--
-- Runs inside ONE transaction that ends in ROLLBACK, against the real schema,
-- the real RPCs and a real signed-in identity: `request.jwt.claims` is set so
-- auth.uid() / my_customer_id() / get_my_role() answer exactly as they do for
-- a browser session. That is the point — the purchaser gate and the
-- moderation gate are only worth anything if they hold under a real identity,
-- not under a SECURITY DEFINER script that bypasses both.
--
-- Sixteen assertions, in the order a real submission travels.
begin;
select public.db_session_guard();
\set ON_ERROR_STOP on

create temporary table _fx on commit drop as
select pp.user_id                                       as cust_uid,
       pp.id                                            as cust_id,
       (select pp2.user_id from public.pharmacy_profiles pp2
         where pp2.approved and pp2.user_id is not null
           and coalesce(pp2.is_deleted,false)=false and pp2.id <> pp.id
         order by pp2.id limit 1)                       as other_uid,
       (select u.id from public.admins a
          join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
         where a.is_super limit 1)                      as admin_uid,
       (select m.id from public."MEDICINE" m where m.buyable is true order by m.id limit 1)      as bought_pid,
       (select m.id from public."MEDICINE" m where m.buyable is true order by m.id desc limit 1) as never_pid
  from public.pharmacy_profiles pp
 where pp.approved and pp.user_id is not null and coalesce(pp.is_deleted,false)=false
 order by pp.id limit 1;

-- A DELIVERED order containing bought_pid. Delivery, not order status, is what
-- the gate reads.
-- Three separate statements, not one CTE chain: order_items carries BEFORE
-- triggers whose effect is not visible to a sibling CTE, and the fixture must
-- be REAL for the gate proof to mean anything.
insert into public.orders (user_id, customer_id, pharmacy_name, total_amount, status, order_code, order_date)
select f.cust_uid, f.cust_id, 'C410 Proof Pharmacy', 100, 'accepted', 'C410PROOF',
       (now() at time zone 'Asia/Kolkata')::date
  from _fx f;

insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price, gst_percent)
select o.id, f.bought_pid, 'C410 Proof Product', 1, 100, 90, 12
  from public.orders o, _fx f where o.order_code = 'C410PROOF';

insert into public.deliveries (order_id, status, delivered_at, proof_method)
select o.id, 'delivered', now(), 'otp' from public.orders o where o.order_code = 'C410PROOF';

-- The fixture must actually exist, or every assertion below is vacuous.
select (select count(*) from public.order_items oi join public.orders o on o.id = oi.order_id
         where o.order_code = 'C410PROOF') = 1 as fixture_line_present,
       (select count(*) from public.deliveries d join public.orders o on o.id = d.order_id
         where o.order_code = 'C410PROOF' and d.delivered_at is not null) = 1 as fixture_delivered;

-- ── sign in as the customer ────────────────────────────────────────────────
select set_config('request.jwt.claims',
       json_build_object('sub', (select cust_uid from _fx), 'role','authenticated')::text, true);

\echo '--- 1-2. the purchaser gate reads DELIVERY, and only for what was delivered ---'
select public._product_purchase_proof((select bought_pid from _fx), (select cust_id from _fx)) as pass_bought_is_verified,
       public._product_purchase_proof((select never_pid  from _fx), (select cust_id from _fx)) = false as pass_unbought_is_not;

\echo '--- 3. a review of a product never received is refused, in the backend words ---'
select (public.review_submit((select never_pid from _fx), 5, 'nope') ->> 'ok') = 'false'
   and (public.review_submit((select never_pid from _fx), 5, 'nope') ->> 'error') = 'not_purchased'
   and (public.review_submit((select never_pid from _fx), 5, 'nope') ->> 'message')
       = (select value from public.storefront_ui_label where key='rv_gate_not_bought') as pass_refusal_is_backend_copy;

\echo '--- 4. a review of a received product is accepted, and starts PENDING ---'
select (public.review_submit((select bought_pid from _fx), 4, 'Good supply, pack intact.') ->> 'status') = 'pending' as pass_starts_pending;

\echo '--- 5. a pending review is NOT in the public aggregate ---'
select (public.product_rating_summary((select bought_pid from _fx)) ->> 'has') = 'false' as pass_pending_not_aggregated;

\echo '--- 6. but its own author sees it, with the backend note ---'
select (select count(*) from jsonb_array_elements(public.product_reviews((select bought_pid from _fx)) -> 'items') i
         where (i->>'is_mine')::boolean and i->>'status' = 'pending'
           and i->>'note' = (select value from public.storefront_ui_label where key='rv_pending_note')) = 1 as pass_author_sees_own_pending;

\echo '--- 7. a customer cannot reach the moderation queue ---'
select (public.review_moderation_queue('pending') ->> 'error') = 'not_authorized' as pass_queue_is_admin_only;

-- ── sign in as the super admin ─────────────────────────────────────────────
select set_config('request.jwt.claims',
       json_build_object('sub', (select admin_uid from _fx), 'role','authenticated')::text, true);

\echo '--- 8. the queue shows the pending row to an admin ---'
select (public.review_moderation_queue('pending') ->> 'ok') = 'true'
   and exists (select 1 from jsonb_array_elements(public.review_moderation_queue('pending') -> 'rows') r
                where r->>'kind' = 'review' and r->>'body' = 'Good supply, pack intact.') as pass_admin_sees_queue;

\echo '--- 9. a rejection with no reason is refused (never a silent deletion) ---'
select (public.review_moderate('review',
          (select id from public.product_review where body = 'Good supply, pack intact.'),
          'reject', '') ->> 'error') = 'reason_required' as pass_reason_required;

\echo '--- 10-11. approval publishes it, and the aggregate appears ---'
select (public.review_moderate('review',
          (select id from public.product_review where body = 'Good supply, pack intact.'),
          'approve') ->> 'ok') = 'true' as pass_approve;
select (public.product_rating_summary((select bought_pid from _fx)) ->> 'has') = 'true'
   and (public.product_rating_summary((select bought_pid from _fx)) ->> 'count') = '1'
   and (public.product_rating_summary((select bought_pid from _fx)) ->> 'count_label')
       = (select value from public.storefront_ui_label where key='rv_count_one') as pass_aggregate_public;

\echo '--- 12. the compare table reads the SAME aggregate block ---'
select exists (
  select 1 from jsonb_array_elements(public.product_compare(array[(select bought_pid from _fx)]::bigint[]) -> 'rows') r
   where r->>'key' = 'rating' and (r->'cells'->0->>'has')::boolean) as pass_compare_reads_rating;

-- ── a DIFFERENT customer ───────────────────────────────────────────────────
select set_config('request.jwt.claims',
       json_build_object('sub', (select other_uid from _fx), 'role','authenticated')::text, true);

\echo '--- 13. another pharmacy sees the approved review but cannot write one ---'
select (public.product_reviews((select bought_pid from _fx)) ->> 'can_write') = 'false'
   and (public.product_reviews((select bought_pid from _fx)) ->> 'gate_note')
       = (select value from public.storefront_ui_label where key='rv_gate_not_bought')
   and jsonb_array_length(public.product_reviews((select bought_pid from _fx)) -> 'items') = 1 as pass_reader_gated;

\echo '--- 14. the abuse flag counts, and floats the row into the Reported tab ---'
select (public.content_flag_raise('review',
          (select id from public.product_review where body = 'Good supply, pack intact.'), 'spam') ->> 'ok') = 'true' as pass_flag_ok;
select (select flag_count from public.product_review where body = 'Good supply, pack intact.') = 1 as pass_flag_counted;

-- ── back to the author ─────────────────────────────────────────────────────
select set_config('request.jwt.claims',
       json_build_object('sub', (select cust_uid from _fx), 'role','authenticated')::text, true);

\echo '--- 15. editing an APPROVED review sends it back to pending (no unmoderated publish) ---'
select (public.review_submit((select bought_pid from _fx), 1, 'Edited after approval.') ->> 'status') = 'pending' as pass_edit_returns_to_pending;
select (public.product_rating_summary((select bought_pid from _fx)) ->> 'has') = 'false' as pass_edit_leaves_public_view;

\echo '--- 16. the Q&A path uses the same gate ---'
select (public.question_submit((select never_pid from _fx), 'Which pack?') ->> 'error') = 'not_purchased'
   and (public.question_submit((select bought_pid from _fx), 'Which pack?') ->> 'status') = 'pending' as pass_qna_same_gate;

rollback;

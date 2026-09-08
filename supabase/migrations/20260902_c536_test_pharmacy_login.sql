-- CHANGE #536, QA round 4 (finding 296).
-- Spec item 4 says "verify as the pharmacy test account: every one of the built
-- features opens and works". It could not be proven: test.cust1@medibo.in owns
-- no pharmacy at all, so my_customer_id() returned null and every My Shop tile
-- painted the backend's refusal. The ROUTING was proven; the WORKING half was not.
--
-- The fix is a test fixture, not a data change: bind that documented credential
-- as a staff login on the pharmacy the synthetic harness already maintains
-- ("TST TEST PHARMACY - SYNTHETIC (DO NOT USE)", is_synthetic = true, so the
-- _synthetic_outbound_gate / _synthetic_books_block guards keep it out of
-- WhatsApp, books and payments). customer_users.auth_user_id is the staff-login
-- path my_customer_id() already honours (CHANGE #408), so no pharmacy_profiles
-- row is created, no real customer row is touched, and this is one reversible row.
--
-- Idempotent: re-applying is a no-op.
do $$
declare
  v_uid  uuid;
  v_shop uuid;
begin
  select id into v_uid from auth.users where email = 'test.cust1@medibo.in';
  select id into v_shop from pharmacy_profiles
   where is_synthetic and coalesce(is_deleted, false) = false
   order by created_at limit 1;

  if v_uid is null or v_shop is null then
    raise notice 'c536: test user or synthetic shop absent - nothing to bind';
    return;
  end if;

  if exists (select 1 from customer_users
              where customer_id = v_shop and auth_user_id = v_uid) then
    raise notice 'c536: test.cust1 already bound to the synthetic shop';
    return;
  end if;

  insert into customer_users
    (customer_id, identity, display_name, access_key, auth_user_id, is_active, created_by)
  values
    (v_shop, 'test.cust1@medibo.in', 'mediBO test pharmacy login',
     'full', v_uid, true, 'CHANGE #536 QA round 4')
  on conflict (identity) do update
     set customer_id  = excluded.customer_id,
         auth_user_id = excluded.auth_user_id,
         access_key   = excluded.access_key,
         is_active    = true;
end $$;

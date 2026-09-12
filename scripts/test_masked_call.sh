#!/usr/bin/env bash
# CHANGE #404 — the masking layer, proved end to end against the STUB provider.
#
# Everything the layer decides is SQL, so this exercises SQL directly: the allow
# matrix (both an allowed pair and a denied one), session creation and reuse,
# the inbound (caller, DID) match from BOTH legs, TTL expiry, closure on
# delivery, and the refusal that an expired session produces.
#
# It buys no telephony and dials nothing: the stub DID (+919000000000) is the
# only number involved, and no supplier number is ever touched (the spec's
# standing rule — supplier numbers are dummy 9000000xxx during the build).
#
# Everything happens inside ONE transaction that is ROLLED BACK, so the live
# tables are unchanged whether the run is green or red.
set -uo pipefail

PGURL="${SUPABASE_DB_URL:-$(cat "$HOME/.medibo/dburl" 2>/dev/null)}"
if [ -z "$PGURL" ]; then
  echo "test_masked_call: no database url (SUPABASE_DB_URL or ~/.medibo/dburl)" >&2
  exit 1
fi

OUT="$(psql "$PGURL" -v ON_ERROR_STOP=1 -At <<'SQL' 2>&1
begin;
set local search_path to public;

-- A throwaway order and two throwaway parties. Real rows are never touched.
create temporary table t_ids (k text primary key, val text) on commit drop;

do $$
declare
  v_order uuid;
  v_cust  uuid;
  v_rider uuid;
  v_uid   uuid;
begin
  -- One borrowed auth identity plays both legs. Actor resolution puts
  -- 'delivery' ahead of 'customer', so this uid resolves as the RIDER — which
  -- is the caller every test below uses.
  select id into v_uid from auth.users order by created_at limit 1;
  if v_uid is null then raise exception 'no auth user to borrow'; end if;

  -- The pharmacy has to exist and be approved BEFORE the order: orders carries
  -- enforce_order_approval(), and a test that disabled it would be testing a
  -- different table than production has.
  insert into pharmacy_profiles (id, user_id, pharmacy_name, address, city, pincode,
                                 phone, status, approved)
  values (gen_random_uuid(), v_uid, 'CHANGE404 Test Pharmacy', 'Test Address',
          'Raipur', '492001', '9811100011', 'approved', true)
  returning id into v_cust;

  insert into orders (id, user_id, customer_id, status, created_at)
  values (gen_random_uuid(), v_uid, v_cust, 'placed', now())
  returning id into v_order;

  insert into delivery_partner_registrations (id, user_id, full_name, phone, status, is_active)
  values (gen_random_uuid(), v_uid, 'CHANGE404 Test Rider', '9811100022', 'approved', true)
  returning id into v_rider;

  insert into deliveries (id, order_id, partner_id, status, assigned_at)
  values (gen_random_uuid(), v_order, v_rider, 'assigned', now());

  insert into t_ids values ('order', v_order::text), ('cust', v_cust::text),
                           ('rider', v_rider::text), ('uid', v_uid::text);
end $$;

-- Force the stub provider for the duration of the test.
update call_config set provider = 'stub', enabled = true, session_ttl_min = 240 where id;

-- ── 1. the view resolves both fresh parties, in E.164 ─────────────────────
select 'T1 parties ' || case when
  (select phone_e164 from call_parties
    where party_role='customer' and party_id=(select val from t_ids where k='cust')) = '+919811100011'
  and (select phone_e164 from call_parties
    where party_role='delivery' and party_id=(select val from t_ids where k='rider')) = '+919811100022'
  then 'PASS' else 'FAIL' end;

-- ── 2. the allow matrix, both answers, straight off the table ─────────────
select 'T2 allow_matrix ' || case when
      _call_allowed('delivery','customer')      -- seeded true
  and _call_allowed('partner','supplier')       -- the ONLY supplier edge
  and not _call_allowed('customer','supplier')  -- seeded false, explicitly
  and not _call_allowed('delivery','supplier')  -- seeded false
  and not _call_allowed('customer','nonsense')  -- absent row = denied
  then 'PASS' else 'FAIL' end;

-- ── 3. an actor who is no party at all is refused before anything is read ─
do $$
declare v jsonb;
begin
  v := call_mask_prepare(gen_random_uuid(),
                         (select val from t_ids where k='order')::uuid, 'customer');
  insert into t_ids values ('prep1', v::text);
end $$;

select 'T3 unknown_actor ' || case when
      ((select val from t_ids where k='prep1')::jsonb ->> 'error') = 'not_a_party'
  and ((select val from t_ids where k='prep1')::jsonb ->> 'message') = _c('call.not_allowed')
  and (select count(*) from call_sessions
        where order_id = (select val from t_ids where k='order')::uuid) = 0
  then 'PASS' else 'FAIL' end;

-- ── the ALLOWED path: rider -> customer mints a session on the stub DID, and
--    the app-visible half of that reply carries a DID and no real number ─────
do $$
declare v jsonb;
begin
  v := call_mask_prepare((select val from t_ids where k='uid')::uuid,
                         (select val from t_ids where k='order')::uuid, 'customer');
  insert into t_ids values ('prep2', v::text);
end $$;

select 'T4 session_created ' || case when
      ((select val from t_ids where k='prep2')::jsonb ->> 'ok') = 'true'
  and ((select val from t_ids where k='prep2')::jsonb ->> 'did') = '+919000000000'
  and ((select val from t_ids where k='prep2')::jsonb ->> 'provider') = 'stub'
  and ((select val from t_ids where k='prep2')::jsonb #>> '{callee,phone}') = '+919811100011'
  then 'PASS' else 'FAIL' end;

-- ── 4. a second tap REUSES the live session instead of burning a DID ──────
do $$
declare v jsonb;
begin
  v := call_mask_prepare((select val from t_ids where k='uid')::uuid,
                         (select val from t_ids where k='order')::uuid, 'customer');
  insert into t_ids values ('prep3', v::text);
end $$;

select 'T5 session_reuse ' || case when
  ((select val from t_ids where k='prep2')::jsonb ->> 'session_id')
   = ((select val from t_ids where k='prep3')::jsonb ->> 'session_id')
  and (select count(*) from call_sessions
        where order_id = (select val from t_ids where k='order')::uuid) = 1
  then 'PASS' else 'FAIL' end;

-- ── 5. a DENIED pair never reaches a target lookup ────────────────────────
do $$
declare v jsonb;
begin
  v := call_mask_prepare((select val from t_ids where k='uid')::uuid,
                         (select val from t_ids where k='order')::uuid, 'supplier');
  insert into t_ids values ('deny', v::text);
end $$;

select 'T6 denied_pair ' || case when
      ((select val from t_ids where k='deny')::jsonb ->> 'ok') = 'false'
  and ((select val from t_ids where k='deny')::jsonb ->> 'error') = 'not_allowed'
  and ((select val from t_ids where k='deny')::jsonb ->> 'message') = _c('call.not_allowed')
  and (select count(*) from call_sessions
        where order_id = (select val from t_ids where k='order')::uuid) = 1
  then 'PASS' else 'FAIL' end;

-- ── 6. inbound matching, from EITHER leg, on the DID ──────────────────────
select 'T7 inbound_caller_leg ' || case when
      (call_inbound_match('9811100022', '+919000000000') ->> 'action') = 'connect'
  and (call_inbound_match('9811100022', '+919000000000') ->> 'connect_to') = '+919811100011'
  then 'PASS' else 'FAIL' end;

select 'T8 inbound_callee_leg ' || case when
      (call_inbound_match('+919811100011', '9000000000') ->> 'action') = 'connect'
  and (call_inbound_match('+919811100011', '9000000000') ->> 'connect_to') = '+919811100022'
  then 'PASS' else 'FAIL' end;

select 'T9 inbound_stranger ' || case when
      (call_inbound_match('9876500000', '+919000000000') ->> 'action') = 'reject'
  and (call_inbound_match('9876500000', '+919000000000') ->> 'message') = _c('call.expired')
  then 'PASS' else 'FAIL' end;

-- every leg above was logged, connected and rejected alike
select 'T10 legs_logged ' || case when
  (select count(*) from masked_calls where leg = 'inbound') >= 5
  then 'PASS' else 'FAIL' end;

-- ── 7. expiry — the clock, then the sweep, then the refusal ───────────────
update call_sessions set expires_at = now() - interval '1 minute'
 where order_id = (select val from t_ids where k='order')::uuid;

-- Two statements, not one: inside a single SELECT the status subquery reads the
-- statement's own snapshot and would see the row as it was BEFORE the sweep ran.
do $$
begin
  insert into t_ids values ('sweep', call_expire_sweep()::text);
end $$;

select 'T11 expiry_sweep ' || case when
      (((select val from t_ids where k='sweep')::jsonb ->> 'expired')::int) >= 1
  and (select status from call_sessions
        where order_id = (select val from t_ids where k='order')::uuid) = 'expired'
  then 'PASS' else 'FAIL' end;

select 'T12 expired_rejects_inbound ' || case when
      (call_inbound_match('9811100022', '+919000000000') ->> 'action') = 'reject'
  and (call_inbound_match('9811100022', '+919000000000') ->> 'error') = 'no_session'
  then 'PASS' else 'FAIL' end;

-- ── 8. delivery closes every live session on the order ────────────────────
do $$
declare v jsonb;
begin
  v := call_mask_prepare((select val from t_ids where k='uid')::uuid,
                         (select val from t_ids where k='order')::uuid, 'customer');
  insert into t_ids values ('prep4', v::text);
end $$;

update deliveries set delivered_at = now()
 where order_id = (select val from t_ids where k='order')::uuid;

select 'T13 delivered_closes ' || case when
  (select status from call_sessions
    where id = ((select val from t_ids where k='prep4')::jsonb ->> 'session_id')::uuid) = 'closed'
  then 'PASS' else 'FAIL' end;

-- ── 9. a closed order refuses a NEW session, with the backend's words ─────
update orders set closed_at = now() where id = (select val from t_ids where k='order')::uuid;

do $$
declare v jsonb;
begin
  v := call_mask_prepare((select val from t_ids where k='uid')::uuid,
                         (select val from t_ids where k='order')::uuid, 'customer');
  insert into t_ids values ('prep5', v::text);
end $$;

select 'T14 closed_order_refused ' || case when
      ((select val from t_ids where k='prep5')::jsonb ->> 'error') = 'order_closed'
  and ((select val from t_ids where k='prep5')::jsonb ->> 'message') = _c('call.session_closed')
  then 'PASS' else 'FAIL' end;

-- ── 10. no supplier number was dialled, matched or logged, ever ───────────
select 'T15 no_supplier_touched ' || case when
  not exists (
    select 1 from masked_calls mc
    join call_sessions cs on cs.id = mc.session_id
    where cs.callee_role = 'supplier' or cs.caller_role = 'supplier')
  then 'PASS' else 'FAIL' end;

rollback;
SQL
)"

echo "$OUT"

FAILED="$(printf '%s\n' "$OUT" | grep -c 'FAIL' || true)"
PASSED="$(printf '%s\n' "$OUT" | grep -c 'PASS' || true)"

if printf '%s\n' "$OUT" | grep -qi '^ERROR\|ERROR:'; then
  echo "test_masked_call: SQL error — see output above" >&2
  exit 1
fi
if [ "$FAILED" -gt 0 ] || [ "$PASSED" -lt 15 ]; then
  echo "test_masked_call: $PASSED passed, $FAILED failed (expected 15 passing)" >&2
  exit 1
fi
echo "test_masked_call: $PASSED/15 passed (stub provider, rolled back)"

#!/usr/bin/env bash
# CMD #1849 — the outbound sandbox, proven.
#
# This is the test spec items 5 and 6 ask for, and it FAILS if a Razorpay
# endpoint is reachable while a human test session is live, or if the ordinary
# path stops behaving exactly as it did.
#
#   bash scripts/c1849_outbound_proof.sh <cmd-id>     # a build branch DB
#   MEDIBO_DBURL=<url> bash scripts/c1849_outbound_proof.sh
#
# Everything runs inside ONE transaction that is ROLLED BACK, so it leaves no
# session, no order and no receipt behind on whatever database it is pointed at.
set -uo pipefail

CMD="${1:-}"
if [ -n "${MEDIBO_DBURL:-}" ]; then
  URL="$MEDIBO_DBURL"
elif [ -n "$CMD" ]; then
  URL="$(~/mediBO-runner/devcmd.sh dburl "$CMD")"
else
  echo "c1849 proof: pass a command id or set MEDIBO_DBURL" >&2; exit 2
fi

OUT="$(psql "$URL" -X -v ON_ERROR_STOP=1 -Atq <<'SQL'
begin;

-- A person's live test session, and one order stamped with it.
insert into public.test_sessions (label, scope, status, started_at, expires_at, origin, token)
values ('c1849 proof', 'global', 'live', now(), now() + interval '1 hour', 'human', 'c1849-proof-token')
returning id \gset

-- The order gate #1848 installed refuses a test order from a device that is
-- not in test mode, so the header goes on FIRST.
set local request.headers = '{"x-medibo-test-session":"c1849-proof-token"}';

-- An approved pharmacy is what the order gate asks for; the order itself is
-- stamped with the session, so it is this session's row and nobody else's.
select coalesce((select pp.user_id from public.pharmacy_profiles pp
                  join auth.users u on u.id = pp.user_id
                 where pp.approved = true and coalesce(pp.is_deleted,false) = false
                   and (pp.status is null or pp.status <> 'suspended')
                 limit 1),
                '00000000-0000-0000-0000-00000c184900'::uuid) as uid \gset

-- On an empty build branch there is no approved pharmacy to borrow, so the
-- proof makes its own. Every row here dies with the rollback.
insert into auth.users (id, aud, role, email, created_at, updated_at)
select :'uid'::uuid, 'authenticated', 'authenticated', 'c1849-proof@medibo.in', now(), now()
 where not exists (select 1 from auth.users where id = :'uid'::uuid);

insert into public.pharmacy_profiles (user_id, pharmacy_name, address, city, pincode, approved)
select :'uid'::uuid, 'C1849 Proof Pharmacy', '-', '-', '000000', true
 where not exists (select 1 from public.pharmacy_profiles where user_id = :'uid'::uuid);

insert into public.orders (order_code, user_id, test_session_id, is_synthetic)
values ('C1849PROOF', :'uid'::uuid, :id, true) returning id as oid \gset

-- ===========================================================================
-- A. A LIVE SESSION ON THIS CONNECTION. Nothing leaves; everything is recorded.
-- ===========================================================================
select count(*) as net_before from net.http_request_queue \gset

select 'A1 whatsapp sandboxed = ' ||
       ((public.notify('order_ready','9999999999','{}'::jsonb)->>'path') = 'sandbox')::text;

select 'A2 razorpay checkout refused = ' ||
       ((public.rzp_checkout_prepare(:'oid'::uuid,'advance')->>'error') = 'test_mode_outbound_blocked')::text;

select 'A3 razorpay qr refused = ' ||
       ((public.rzp_qr_prepare(:'oid'::uuid,'advance')->>'error') = 'test_mode_outbound_blocked')::text;

select 'A4 razorpay qr-on-whatsapp refused = ' ||
       ((public.rzp_send_order_qr_wa(:'oid'::uuid)->>'error') = 'test_mode_outbound_blocked')::text;

select 'A5 razorpay reconcile refused = ' ||
       ((public.rzp_reconcile_tick()->>'path') <> 'send')::text;

select 'A6 razorpay refund refused = ' ||
       ((public.outbound_payment_gate('refund.create', :'oid'::uuid, 100)->>'allowed') = 'false')::text;

select 'A7 razorpay account refused = ' ||
       ((public.outbound_payment_gate('account.create', null, null)->>'allowed') = 'false')::text;

select 'A8 push sandboxed = ' ||
       ((public.notif_push_send('order_ready','9999999999',null,:'oid'::uuid)->>'path') = 'sandbox')::text;

select 'A9 email sandboxed = ' ||
       ((public.notif_send_email('order_ready','nobody@medibo.in','{}'::jsonb,null,:'oid'::uuid)->>'path') = 'sandbox')::text;

select 'A10 admin paging sandboxed = ' ||
       ((public.notify_partner('order_ready', jsonb_build_object('order_id', :'oid'::text))->>'path') = 'sandbox')::text;

select 'A11 retry queue never enqueued = ' ||
       (public.notify_enqueue_retry('order_ready','9999999999','{}'::jsonb,'proof',:'oid'::uuid) is null)::text;

-- The whole point: silence would have proved nothing. Count the receipt.
select 'A12 receipt has every line = ' ||
       ((select count(*) from public.outbound_receipt where session_id = :id) >= 10)::text;

select 'A13 nothing reached the wire = ' ||
       ((select count(*) from net.http_request_queue) = :net_before)::text;

select 'A14 transcript renders = ' ||
       ((public.test_session_receipt(:id)->>'has') = 'true'
        and (public.test_session_receipt(:id)->>'count')::int >= 10
        and jsonb_array_length(public.test_session_receipt(:id)->'groups') >= 3)::text;

select 'A15 every line is a backend sentence = ' ||
       (not exists (select 1 from jsonb_array_elements(public.test_session_receipt(:id)->'lines') l
                     where coalesce(l->>'line','') = '' or coalesce(l->>'channel_label','') = ''))::text;

-- ===========================================================================
-- B. NO HEADER (the cron lane). The ROW decides.
-- ===========================================================================
set local request.headers = '{}';

select 'B1 stamped order is sandboxed from cron = ' ||
       ((public.outbound_dispatch('whatsapp','order_ready',null,null,null,:'oid'::uuid)->>'decision') = 'sandbox')::text;

-- ===========================================================================
-- C. FAIL CLOSED. A named ref that resolves to nothing must NOT send.
-- ===========================================================================
select 'C1 unresolvable ref is held, not sent = ' ||
       ((public.outbound_dispatch('whatsapp','order_ready',null,null,null,
          '00000000-0000-0000-0000-0000000c1849'::uuid)->>'decision') = 'hold')::text;

select 'C2 a held send is recorded and alerted = ' ||
       (exists (select 1 from public.outbound_receipt where verdict = 'held')
        and exists (select 1 from public.rg_alerts where kind = 'outbound_held'))::text;

-- ===========================================================================
-- D. THE REAL PATH, UNCHANGED. No session anywhere.
-- ===========================================================================
select 'D1 an unref-scoped send still goes = ' ||
       ((public.outbound_dispatch('whatsapp','admin_digest')->>'decision') = 'send')::text;

select count(*) as log_before from public.notification_log \gset

-- The raw body runs, reaches its own unknown-event branch and writes the same
-- ledger row it always wrote. If the wrapper had swallowed it, this is 0.
-- Two statements on purpose: a count in the SAME statement as the send reads
-- the statement's own snapshot and would never see the row the send just wrote.
select public.notify('__c1849_no_such_event__','9999999999','{}'::jsonb)->>'reason' as d2reason \gset

select 'D2 the raw body still runs and logs identically = ' ||
       (:'d2reason' = 'unknown_event'
        and (select count(*) from public.notification_log) = :log_before + 1)::text;

-- ===========================================================================
-- E. NO CALL SITE IS UNROUTED.
-- ===========================================================================
select 'E1 every outbound call site is routed = ' || (public.outbound_leak_scan()->>'ok');

rollback;
SQL
)"
RC=$?
echo "$OUT"
if [ $RC -ne 0 ]; then
  echo "c1849 proof: FAILED — psql exited $RC" >&2
  exit 1
fi
FAILED=$(printf '%s\n' "$OUT" | grep -c '= false$' || true)
TOTAL=$(printf '%s\n' "$OUT" | grep -Ec '= (true|false)$' || true)
echo "----"
if [ "$FAILED" -ne 0 ] || [ "$TOTAL" -eq 0 ]; then
  echo "c1849 proof: FAILED — $FAILED of $TOTAL assertions false" >&2
  exit 1
fi
echo "c1849 proof: PASSED — $TOTAL assertions"

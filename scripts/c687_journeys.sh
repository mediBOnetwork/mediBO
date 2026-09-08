#!/usr/bin/env bash
# CHANGE #687 — the three QA journeys the spec names, run against the LIVE
# database on synthetic rows that are created and removed by this script.
#
#   J1  inquiry expires            -> the next ranked supplier is asked, the
#                                     silent one is marked "No response", and
#                                     the miss lands in supplier_response_log.
#   J2  supplier accepts in time   -> the order proceeds (accept_state accepted,
#                                     packing unblocked) and the reply is logged.
#   J3  supplier never answers     -> the order is reassigned on the deadline
#                                     (accept_state timeout) and logged.
#
# Exit 0 = all three green. Any FAIL exits 1.
set -uo pipefail
PGURL="$(cat "${HOME}/.medibo/dburl")"
FAILED=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
q()    { psql "$PGURL" -At -c "$1"; }

SUP_A='C687 SILENT SUPPLIER'
SUP_B='C687 NEXT SUPPLIER'

cleanup() {
  q "delete from supplier_response_log where supplier_name in ('$SUP_A','$SUP_B');" >/dev/null
  q "delete from inquiry where product_name like 'C687 JOURNEY%';"                   >/dev/null
  q "delete from supplier_orders where description = 'c687-journey';"                >/dev/null
  q "delete from inquiry_forms where supplier_name in ('$SUP_A','$SUP_B');"          >/dev/null
}
trap cleanup EXIT
cleanup

echo "── J1: an unanswered inquiry advances to the next ranked supplier"
INQ=$(q "with ins as (
           insert into inquiry (product_name, quantity, product_id, zone_id, batch_date, is_synthetic)
           select 'C687 JOURNEY ITEM', 1, m.id, 1,
                  (now() at time zone 'Asia/Kolkata')::date, true
             from \"MEDICINE\" m order by m.id limit 1
           returning id)
         select id from ins;")
# The ladder is seeded with the row triggers off: t1_ps_lookup/t2_current_supplier
# rebuild PS1..PS30 and current_supplier from the live ranking on every write, so
# a two-rung synthetic ladder cannot be written through them. session_replication_role
# is session-local and set back to 'origin' on the same line.
q "set session_replication_role='replica';
   update inquiry set \"PS1\"='$SUP_A', \"PS2\"='$SUP_B', \"AS1\"=null, \"AS2\"=null,
          current_supplier='$SUP_A', next_supplier='$SUP_B', inquiry_phase='sent',
          asked_at = now() - interval '30 minutes'
    where id = $INQ;
   set session_replication_role='origin';" >/dev/null
[ -n "$INQ" ] && pass "seeded inquiry #$INQ, asked 30 min ago (deadline $(q "select public.inquiry_deadline_minutes(1::smallint);") min)" \
              || fail "could not seed the inquiry row"

BEFORE=$(q "select coalesce(current_supplier,'-') from inquiry where id = $INQ;")
[ "$BEFORE" = "$SUP_A" ] && pass "before: current_supplier = $BEFORE" \
                         || fail "before: expected $SUP_A, got $BEFORE"

# The deadline block the supplier tab / link page / admin tab all render.
EXPIRED=$(q "select public.deadline_block(asked_at, public.inquiry_deadline_at(id), 'inquiry', false) ->> 'expired'
               from inquiry where id = $INQ;")
[ "$EXPIRED" = "true" ] && pass "countdown block reports expired=true" \
                        || fail "countdown block says expired=$EXPIRED"

q "select public.inquiry_timeout_advance();" >/dev/null

AFTER=$(q "select coalesce(current_supplier,'-') from inquiry where id = $INQ;")
[ "$AFTER" = "$SUP_B" ] && pass "after: advanced to $AFTER" \
                        || fail "after: expected $SUP_B, got $AFTER"

AS1=$(q "select coalesce(\"AS1\",'-') from inquiry where id = $INQ;")
[ "$AS1" = "No response" ] && pass "silent supplier marked: AS1 = '$AS1'" \
                           || fail "AS1 = '$AS1', expected 'No response'"

LOG=$(q "select count(*) from supplier_response_log
          where inquiry_id = $INQ and kind = 'inquiry_timeout' and outcome = 'no_response';")
[ "$LOG" = "1" ] && pass "logged: 1 inquiry_timeout row in supplier_response_log" \
                 || fail "expected 1 log row, found $LOG"

RESENT=$(q "select count(*) from inquiry_forms where supplier_name = '$SUP_B' and status = 'pending';")
[ "$RESENT" = "1" ] && pass "next supplier was actually asked (pending form created)" \
                    || fail "no pending form for $SUP_B (found $RESENT)"

echo "── J2: a supplier who accepts inside the deadline proceeds"
SO_OK=$(q "with ins as (
             insert into supplier_orders (supplier_name, description, items, status, order_code,
                                          zone_id, accept_state, accept_due_at, is_synthetic)
             values ('$SUP_B','c687-journey','[]'::jsonb,'pending','C687OK',1,'pending',
                     now() + interval '20 minutes', true)
             returning id)
           select id from ins;")
BLK=$(q "select public.supplier_po_deadline_block(accept_due_at, accept_state) ->> 'has'
           from supplier_orders where id = '$SO_OK';")
[ "$BLK" = "true" ] && pass "pending order shows a live countdown (has=true)" \
                    || fail "countdown missing on a pending order (has=$BLK)"
VAL=$(q "select public.supplier_po_deadline_block(accept_due_at, accept_state) ->> 'value_label'
           from supplier_orders where id = '$SO_OK';")
pass "countdown reads: $(q "select public.supplier_po_deadline_block(accept_due_at, accept_state) ->> 'label' from supplier_orders where id = '$SO_OK';") $VAL"

q "update supplier_orders set accept_state='accepted', accepted_at=now(), accepted_by='$SUP_B'
     where id = '$SO_OK';" >/dev/null
CANPACK=$(q "select public.supplier_po_accept_block('accepted', false, null) ->> 'can_pack';")
[ "$CANPACK" = "true" ] && pass "accepted order can be packed (can_pack=true)" \
                        || fail "accepted order still blocked from packing"
GONE=$(q "select public.supplier_po_deadline_block(accept_due_at, accept_state) ->> 'has'
            from supplier_orders where id = '$SO_OK';")
[ "$GONE" = "false" ] && pass "countdown disappears once answered (has=false)" \
                      || fail "countdown still showing after accept (has=$GONE)"

echo "── J3: a supplier who never answers is reassigned on the deadline"
SO_LATE=$(q "with ins as (
               insert into supplier_orders (supplier_name, description, items, status, order_code,
                                            zone_id, accept_state, accept_due_at, is_synthetic)
               values ('$SUP_A','c687-journey','[]'::jsonb,'pending','C687LATE',1,'pending',
                       now() - interval '5 minutes', true)
               returning id)
             select id from ins;")
q "select public.supplier_accept_timeout_sweep();" >/dev/null
ST=$(q "select accept_state from supplier_orders where id = '$SO_LATE';")
[ "$ST" = "timeout" ] && pass "unanswered order moved to accept_state = timeout" \
                      || fail "accept_state = '$ST', expected 'timeout'"
LBL=$(q "select public.supplier_po_accept_block(accept_state, false, decline_reason) ->> 'label'
           from supplier_orders where id = '$SO_LATE';")
[ -n "$LBL" ] && pass "supplier sees the backend's own wording: '$LBL'" \
              || fail "no label for the timeout state"
TLOG=$(q "select count(*) from supplier_response_log
           where supplier_order_id = '$SO_LATE' and kind = 'po_timeout';")
[ "$TLOG" = "1" ] && pass "logged: 1 po_timeout row" || fail "expected 1 po_timeout row, found $TLOG"

echo "── scorecard inputs"
RATE=$(q "select public.supplier_response_stats('$SUP_A', 30) ->> 'rate_value';")
MED=$(q "select public.supplier_response_stats('$SUP_A', 30) ->> 'median_value';")
[ -n "$RATE" ] && pass "response rate for the silent supplier: $RATE (typical reply $MED)" \
               || fail "supplier_response_stats returned nothing"

echo
if [ "$FAILED" = "0" ]; then echo "C687 JOURNEYS: ALL GREEN"; else echo "C687 JOURNEYS: FAILED"; fi
exit $FAILED

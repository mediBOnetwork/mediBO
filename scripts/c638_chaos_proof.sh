#!/usr/bin/env bash
# CHANGE #638 — proves the chaos lane and the recording lane against the LIVE
# database, in the order the spec asks for them. It writes only into the
# synthetic lane (a test session, a chaos run, one recording) and cleans up
# after itself; it never touches a real order, payment or journey.
#
#   bash scripts/c638_chaos_proof.sh
#
# Exit 0 = every scenario degraded safely AND a recorded walkthrough became a
# permanent journey on the control plane. Anything else exits non-zero.
set -euo pipefail

PROD_URL="${PROD_DBURL:-$(cat "$HOME/.medibo/dburl")}"
DEV_URL="${DEV_DBURL:-$(cat "$HOME/.medibo/dev_dburl")}"
q() { psql "$PROD_URL" -Atc "$1"; }
qd() { psql "$DEV_URL" -Atc "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "── 1. the seven scenarios ──────────────────────────────────────────────"
RUN=$(q "select (public.chaos_run_all('c638 proof'))->'run'->>'id'")
[ -n "$RUN" ] || fail "chaos_run_all returned no run id"
q "select scenario_key||'  '||verdict||'  '||summary from chaos_result where run_id=$RUN order by id"
BROKE=$(q "select failed from chaos_run where id=$RUN")
TOTAL=$(q "select total from chaos_run where id=$RUN")
[ "$TOTAL" -ge 7 ] || fail "only $TOTAL scenarios ran, expected at least 7"
[ "$BROKE" = "0" ] || fail "$BROKE scenario(s) did not degrade safely"

echo "── 2. artifacts are stored WITH the run ────────────────────────────────"
KEYS=$(q "select count(*) from jsonb_object_keys((select artifacts from chaos_run where id=$RUN)) k")
[ "$KEYS" = "$TOTAL" ] || fail "the run holds $KEYS artifacts for $TOTAL scenarios"
q "select 'artifact keys: '||string_agg(k,', ') from jsonb_object_keys((select artifacts from chaos_run where id=$RUN)) k"

echo "── 3. a walkthrough is recorded, then becomes a permanent test ─────────"
q "select public.test_session_start('chaos: c638 proof', 1)" >/dev/null
REC=$(q "select (public.recording_start('c638 proof walkthrough'))->>'recording_id'")
[ -n "$REC" ] || fail "recording_start refused"
q "select public.recording_step_add($REC,'nav','/admin/dev-queue','Opened Dev Queue','{}'::jsonb,true)" >/dev/null
q "select public.recording_step_add($REC,'nav','/chaos-lab','Opened Chaos & recording','{}'::jsonb,true)" >/dev/null
q "select public.recording_step_add($REC,'render','chaos_scenarios','Scenario list rendered','{}'::jsonb,false)" >/dev/null
q "select public.recording_stop($REC,'broke','c638 proof: the third step was red')" >/dev/null
GAP=$(q "select count(*) from feature_gaps where source='recording' and feature_key='recording.$REC'")
[ "$GAP" = "1" ] || fail "a broken walkthrough filed $GAP gaps, expected 1"

NAME=$(q "select (public.recording_promote($REC,'c638 proof walkthrough','platform'))->>'journey_name'")
[ -n "$NAME" ] || fail "recording_promote returned no journey name"
sleep 6
LANDED=$(qd "select count(*) from dev_journeys where name='$NAME'")
[ "$LANDED" = "1" ] || fail "journey $NAME never reached the control plane"
qd "select 'journey: '||name||' · '||area||' · '||kind||' · required='||required||' · '||jsonb_array_length(steps)||' steps' from dev_journeys where name='$NAME'"
REQ=$(qd "select required from dev_journeys where name='$NAME'")
[ "$REQ" = "f" ] || fail "a brand-new journey came back required=true; it only becomes required after two green passes"

echo "── 4. cleanup ──────────────────────────────────────────────────────────"
qd "delete from dev_journeys where name='$NAME'" >/dev/null
q "delete from feature_gaps where source='recording' and feature_key='recording.$REC'" >/dev/null
q "delete from test_recording where id=$REC" >/dev/null

echo "PASS — $TOTAL scenarios degraded safely, artifacts stored with run #$RUN,"
echo "       and a recorded walkthrough became a permanent journey."

#!/usr/bin/env bash
# CHANGE #571 — the staged proof for completion integrity.
#
# Three failure modes were seen live on #536. Each one is reproduced here on
# throwaway rows and asserted, so a regression fails loudly instead of costing
# another build:
#
#   1) A completion that cannot reach the database LANDS ANYWAY, from the local
#      spool, on a later retry. (The row is never left un-finished.)
#   2) A lease-blocked command PARKS and RESUMES. It is never failed, its work
#      is never discarded, and the watchdog leaves it alone.
#   3) A completion — and a final summary — with an OPEN SPEC ITEM is REFUSED.
#
# Usage: bash scripts/c571_completion_integrity_proof.sh
# Needs: ~/.medibo/dburl (scratch-row setup) and ~/mediBO-runner/devcmd.sh
#        (every RPC under test goes through the real runner door).
set -uo pipefail

DEVCMD="$HOME/mediBO-runner/devcmd.sh"
PGCONN="$(cat "$HOME/.medibo/dburl")"
PASS=0; FAIL=0
IDS=()

ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
q()    { psql "$PGCONN" -tAc "$1" 2>/dev/null; }

# Scratch rows are identified by their title prefix, never by a captured id —
# a cleanup that depends on the thing that went wrong cleans nothing.
cleanup() {
  q "delete from dev_command_spec_item where command_id in
       (select id from dev_commands where title like '[c571-proof]%');
     delete from file_leases where command_id in
       (select id from dev_commands where title like '[c571-proof]%');
     delete from dev_command_messages where command_id in
       (select id from dev_commands where title like '[c571-proof]%');
     delete from deploy_queue where command_id in
       (select id from dev_commands where title like '[c571-proof]%');
     delete from dev_commands where title like '[c571-proof]%';" >/dev/null
  # ONLY this proof's own spool entries. Wiping the spool would throw away a
  # real worker's finished build — the exact loss #571 exists to prevent.
  for id in "${IDS[@]:-}"; do
    [ -n "${id:-}" ] && rm -f "$HOME/mediBO-runner/.complete.spool/$id.json"
  done
  rm -f /tmp/c571_bad.env
}
trap cleanup EXIT

# A scratch row that no runner can ever claim: it is born `paused`, then moved
# to `building` under a proof-only agent name (which is also what fires the
# spec-item derivation trigger, exactly as a real claim does).
mkrow() { # <title> <spec> -> prints id
  local t="$1" s="$2" id
  id=$(psql "$PGCONN" -qtAX -c "insert into dev_commands (title, spec, status, kind, route, area, qa_required, targets_web)
        values ('[c571-proof] $t', \$spec\$$s\$spec\$, 'paused', 'dev', 'opus', 'runner', false, false)
        returning id;")
  id="$(echo "$id" | tr -d '[:space:]')"
  q "update dev_commands set status='building', claimed_by='c571-proof',
        started_at=now(), heartbeat_at=now(), steps='[\"one\"]'::jsonb,
        steps_total=1, steps_done=1 where id=$id;" >/dev/null
  IDS+=("$id"); echo "$id"
}

echo "── 1. A COMPLETION SURVIVES A DEAD DATABASE ───────────────────────────"
# The failure: dev_cmd_complete timed out under load and the finished build had
# no way to register that it was finished. Staged by pointing devcmd at an
# unreachable host, so every call fails at the transport — the worst case.
ID1=$(mkrow "retryable completion" "prose spec, no enumerated items")
sed 's#^SUPABASE_URL=.*#SUPABASE_URL=http://127.0.0.1:1#' \
  "$HOME/mediBO-runner/runner.env" > /tmp/c571_bad.env
chmod 600 /tmp/c571_bad.env

OUT=$(DEVRUNNER_ENV=/tmp/c571_bad.env DEVCMD_COMPLETE_DEADLINE=5 \
      DEVCMD_MAXTIME=3 DEVCMD_CONNECT_TIMEOUT=2 \
      "$DEVCMD" complete "$ID1" "proof: result written while the DB was unreachable" 999 '[]' 2>/dev/null)
[ "$(jq -r '.spooled // false' <<<"$OUT" 2>/dev/null)" = "true" ] \
  && ok "the unreachable-DB completion returns spooled:true instead of failing" \
  || bad "expected spooled:true, got: $(head -c 200 <<<"$OUT")"
[ -s "$HOME/mediBO-runner/.complete.spool/$ID1.json" ] \
  && ok "the completion is on disk — nothing was lost with the session" \
  || bad "no spool entry at .complete.spool/$ID1.json"
[ "$(q "select status from dev_commands where id=$ID1")" = "building" ] \
  && ok "the row is untouched while the write is still pending" \
  || bad "row moved before the write landed"

# Same entry, database reachable again: the retry lands it. Nothing is re-typed
# by a human and no second `complete` is issued by the agent.
# FLUSH_AFTER=0 because this proof IS the retry: in production a background
# flush leaves an entry alone for two minutes so it never races the worker that
# is still retrying it in the foreground.
DEVCMD_COMPLETE_FLUSH_AFTER=0 "$DEVCMD" complete_flush >/dev/null 2>&1
[ "$(q "select status from dev_commands where id=$ID1")" = "completed" ] \
  && ok "the spooled completion LANDED on the retry (status=completed)" \
  || bad "the spool did not land the completion"
[ "$(q "select web_deploy_no from dev_commands where id=$ID1")" = "999" ] \
  && ok "phase 1 carried the change number through" \
  || bad "change number lost"
[ -n "$(q "select result_summary from dev_commands where id=$ID1")" ] \
  && ok "phase 2 wrote the rich result after the status flip" \
  || bad "result_summary missing after flush"
[ ! -f "$HOME/mediBO-runner/.complete.spool/$ID1.json" ] \
  && ok "the spool entry cleared itself once both phases landed" \
  || bad "spool entry still present after success"
# Idempotence: the retry that arrives late must be a no-op, never an error.
AG=$("$DEVCMD" rpc dev_cmd_complete_fast "{\"p_id\":$ID1}")
[ "$(jq -r '.already // false' <<<"$AG")" = "true" ] \
  && ok "a late retry answers already:true — retries are always safe" \
  || bad "a repeat completion was not idempotent: $(head -c 160 <<<"$AG")"

echo
echo "── 2. A LEASE-BLOCKED COMMAND PARKS, IT DOES NOT FAIL ─────────────────"
# The failure: #536 was marked FAILED with every test green and the work
# committed, because two files were leased by #460 and its deploy was evicted.
ID2=$(mkrow "wait is not failure" "prose spec, no enumerated items")
ID3=$(mkrow "lease holder" "prose spec, no enumerated items")
q "insert into file_leases (command_id, worker, path)
   values ($ID3, 'c571-proof-other', 'lib/screens/c571_proof_contended.dart')
   on conflict do nothing;" >/dev/null

OUT=$("$DEVCMD" fail "$ID2" \
  "cannot proceed: lib/screens/c571_proof_contended.dart is leased by #$ID3" 2>/dev/null)
[ "$(jq -r '.parked // false' <<<"$OUT")" = "true" ] \
  && ok "dev_cmd_fail on lease contention PARKED the row" \
  || bad "expected parked:true, got: $(head -c 200 <<<"$OUT")"
[ "$(jq -r 'if has("failed") then .failed else "missing" end' <<<"$OUT")" = "false" ] \
  && ok "…and explicitly did NOT fail it" || bad "the row was failed"
[ "$(jq -r '.classified.kind // ""' <<<"$OUT")" = "lease" ] \
  && ok "the classifier named the blocker: lease" \
  || bad "wrong classification: $(jq -c '.classified' <<<"$OUT")"
[ "$(q "select status from dev_commands where id=$ID2")" = "building" ] \
  && ok "status stays building — the work is still owned" \
  || bad "status left building"
[ "$(q "select wait_state from dev_commands where id=$ID2")" = "parked" ] \
  && ok "the row carries a visible wait state" || bad "wait_state not set"
[ -n "$(q "select wait_reason from dev_commands where id=$ID2")" ] \
  && ok "…with the backend's own reason for the card" || bad "no wait_reason"
CHIP=$("$DEVCMD" rpc dev_cmd_list '{"p_limit":500}' \
        | jq -r --argjson i "$ID2" '.rows[]|select(.id==$i)|.wait_chip')
[ -n "$CHIP" ] && ok "the queue card renders it: \"$CHIP\"" \
  || bad "dev_cmd_list sent no wait_chip"
# The watchdog is what turned a silent row into a failure before #571.
q "update dev_commands set heartbeat_at = now() - interval '30 minutes', retry_count = 1
    where id=$ID2;" >/dev/null
"$DEVCMD" rpc dev_cmd_watchdog '{}' >/dev/null 2>&1
[ "$(q "select status from dev_commands where id=$ID2")" = "building" ] \
  && ok "the watchdog left the parked row alone (it would have FAILED it before)" \
  || bad "the watchdog failed a parked row — the #536 bug is back"

# Blocker clears → the sweep resumes it, with its plan and branch intact.
q "delete from file_leases where command_id=$ID3;
   update dev_commands set wait_until = now() - interval '1 minute',
     wait_blocker = jsonb_build_object('paths',
       jsonb_build_array('lib/screens/c571_proof_contended.dart'))
   where id=$ID2;" >/dev/null
"$DEVCMD" rpc dev_cmd_wait_sweep '{}' >/dev/null 2>&1
[ "$(q "select status from dev_commands where id=$ID2")" = "pending" ] \
  && ok "the sweep RESUMED it the moment the lease freed (back to pending)" \
  || bad "the parked row did not resume"
[ -z "$(q "select coalesce(wait_state,'') from dev_commands where id=$ID2")" ] \
  && ok "the wait state cleared on resume" || bad "wait_state still set"
[ "$(q "select steps_done from dev_commands where id=$ID2")" = "1" ] \
  && ok "its step plan survived the park — no work is redone" \
  || bad "step progress lost across the park"

echo
echo "── 3. AN OPEN SPEC ITEM REFUSES THE FINISH ────────────────────────────"
# The failure: #536 declared success with core spec items unbuilt.
ID4=$(mkrow "spec-gated finish" "Do these:
1) First deliverable that must actually be built
2) Second deliverable that must actually be built
3) Third deliverable that must actually be built")
N=$("$DEVCMD" spec "$ID4" | jq -r '.total')
[ "$N" = "3" ] && ok "the spec became a 3-item checklist on its own" \
  || bad "expected 3 derived items, got $N"

OUT=$("$DEVCMD" rpc dev_cmd_complete_fast "{\"p_id\":$ID4}")
[ "$(jq -r '.blocked_by // ""' <<<"$OUT")" = "spec_items" ] \
  && ok "dev_cmd_complete_fast REFUSED the completion" \
  || bad "the fast path completed with open spec items: $(head -c 200 <<<"$OUT")"
[ "$(jq -r 'if has("retryable") then .retryable else "missing" end' <<<"$OUT")" = "false" ] \
  && ok "…and marked it non-retryable, so the spool hands it back to the agent" \
  || bad "a refusal must never be retried forever"

OUT=$("$DEVCMD" rpc dev_cmd_result_write \
      "{\"p_id\":$ID4,\"p_result\":\"all three delivered\"}")
[ "$(jq -r '.blocked_by // ""' <<<"$OUT")" = "spec_items" ] \
  && ok "a FINAL SUMMARY is refused on the same condition" \
  || bad "a final summary was accepted with open spec items"

FS=$("$DEVCMD" finish_state "$ID4")
grep -q 'spec item' <<<"$(jq -r '.blocker_text' <<<"$FS")" \
  && ok "the finish detector names the open items in its own words" \
  || bad "finish_state did not block on the spec: $(jq -r '.blocker_text' <<<"$FS")"

# Closing the checklist honestly — two built, one dropped WITH A REASON.
"$DEVCMD" spec_done "$ID4" 1 "landed in the migration" >/dev/null
"$DEVCMD" spec_done "$ID4" 2 "landed in the migration" >/dev/null
OUT=$("$DEVCMD" spec_drop "$ID4" 3 "" 2>/dev/null)
[ "$(jq -r 'if has("ok") then .ok else "missing" end' <<<"$OUT")" = "false" ] \
  && ok "a drop with no reason is refused — silence is not an option" \
  || bad "an item was dropped with no reason"
"$DEVCMD" spec_drop "$ID4" 3 "out of scope: covered by a follow-up" >/dev/null
[ "$(q "select count(*) from dev_commands where id=$ID4
         and decisions::text like '%out of scope%'")" = "1" ] \
  && ok "the drop is logged as a decision Om can read" || bad "the drop was silent"

OUT=$("$DEVCMD" rpc dev_cmd_complete_fast "{\"p_id\":$ID4,\"p_deploy_no\":998}")
[ "$(jq -r '.ok // false' <<<"$OUT")" = "true" ] \
  && ok "with the checklist closed, the completion goes through" \
  || bad "completion still blocked: $(head -c 200 <<<"$OUT")"

echo
echo "───────────────────────────────────────────────────────────────────────"
echo "CHANGE #571 proof: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

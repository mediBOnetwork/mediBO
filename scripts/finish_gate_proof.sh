#!/usr/bin/env bash
# CHANGE #369 — proof that the finish gate closes a finished command and NEVER
# closes an unfinished one.
#
# The rule this repo learned the hard way (bugloop.enforce) is that you never
# arm a gate that completes commands until the whole chain has been rehearsed
# end to end on a harmless row. This is that rehearsal, kept as a script so it
# can be re-run after any change to dev_cmd_finish_state / dev_cmd_autofinish.
#
# It creates its OWN synthetic dev_commands rows, asserts the verdict for each,
# and deletes them. It never touches a real command.
#
#   bash scripts/finish_gate_proof.sh
#
# Exit 0 = every assertion held.
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
Q() { psql "$PGURL" -Atq -c "$1"; }
FAIL=0
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAIL=1; }

mkrow() { # <label> <steps_done> <steps_total> <qa_required> <question> → id
  Q "insert into dev_commands (title, spec, status, kind, route, area, qa_required,
        qa_status, targets_web, steps, steps_done, steps_total, claimed_by,
        needs_input_question, started_at, heartbeat_at)
     values ('c369 proof — $1','proof row','building','dev','sonnet','infra',$4,
        'pending', false, '[\"one\",\"two\"]'::jsonb, $2, $3, 'runner-proof',
        nullif('$5',''), now(), now())
     returning id;"
}
verdict() { "$HOME/mediBO-runner/devcmd.sh" finish_state "$1" | jq -r '.ready'; }
blockers() { "$HOME/mediBO-runner/devcmd.sh" finish_state "$1" | jq -r '.blocker_text'; }
drop() { Q "delete from dev_command_messages where command_id=$1; delete from dev_commands where id=$1;" >/dev/null; }

echo "── it must NOT fire early ──────────────────────────────────────────────"
id=$(mkrow "half the steps" 1 2 false "")
[ "$(verdict "$id")" = "false" ] && ok "steps 1/2 stays open — $(blockers "$id")" || bad "steps 1/2 was judged ready"
drop "$id"

id=$(mkrow "no plan at all" 0 0 false "")
[ "$(verdict "$id")" = "false" ] && ok "no step plan stays open — $(blockers "$id")" || bad "a row with no plan was judged ready"
drop "$id"

id=$(mkrow "question open" 2 2 false "which colour?")
[ "$(verdict "$id")" = "false" ] && ok "unanswered question stays open — $(blockers "$id")" || bad "a needs_input row was judged ready"
drop "$id"

id=$(mkrow "qa never ran" 2 2 true "")
[ "$(verdict "$id")" = "false" ] && ok "qa_required + qa pending stays open — $(blockers "$id")" || bad "a row with no QA was judged ready"
drop "$id"

echo "── it MUST fire when everything is observed ────────────────────────────"
id=$(mkrow "backend only, all steps landed" 2 2 false "")
if [ "$(verdict "$id")" = "true" ]; then
  ok "every condition observed → ready"
else
  bad "a finished row was NOT judged ready — $(blockers "$id")"
fi
out=$("$HOME/mediBO-runner/devcmd.sh" rpc dev_cmd_autofinish "{\"p_id\":$id,\"p_source\":\"harness\"}")
if [ "$(jq -r '.completed' <<<"$out")" = "true" ]; then
  ok "harness completed it server-side"
else
  bad "autofinish refused a ready row: $(jq -c '.' <<<"$out")"
fi
st=$(Q "select status from dev_commands where id=$id")
[ "$st" = "completed" ] && ok "row status is completed" || bad "row status is '$st'"
af=$(Q "select auto_finished||'/'||coalesce(auto_finish_source,'') from dev_commands where id=$id")
[ "$af" = "true/harness" ] && ok "stamped auto_finished=t source=harness" || bad "auto_finish stamp is '$af'"
echo "  ── the summary the model never had to write ──"
Q "select result_summary from dev_commands where id=$id" | sed 's/^/     /'
Q "select plain_summary from dev_commands where id=$id" | sed 's/^/     /'
words=$(Q "select array_length(string_to_array(regexp_replace(result_summary,'\s+',' ','g'),' '),1) from dev_commands where id=$id")
lines=$(Q "select array_length(string_to_array(result_summary, chr(10)),1) from dev_commands where id=$id")
[ "$lines" -le 10 ] && ok "$lines lines (limit 10)" || bad "$lines lines — over Om's limit"
[ "$words" -le 50 ] && ok "$words words (limit 50)" || bad "$words words — over Om's limit"
drop "$id"

echo "── the watchdog honours its grace window ───────────────────────────────"
id=$(mkrow "watchdog grace" 2 2 false "")
out=$("$HOME/mediBO-runner/devcmd.sh" rpc dev_cmd_autofinish "{\"p_id\":$id,\"p_source\":\"watchdog\"}")
[ "$(jq -r '.waiting_grace // false' <<<"$out")" = "true" ] \
  && ok "first sighting arms the clock instead of completing" \
  || bad "the watchdog completed on first sight: $(jq -c '.' <<<"$out")"
Q "update dev_commands set finish_ready_at = now() - interval '5 minutes' where id=$id" >/dev/null
out=$("$HOME/mediBO-runner/devcmd.sh" rpc dev_cmd_autofinish "{\"p_id\":$id,\"p_source\":\"watchdog\"}")
[ "$(jq -r '.completed' <<<"$out")" = "true" ] \
  && ok "past the grace window it completes server-side" \
  || bad "the watchdog never completed a stale-ready row: $(jq -c '.' <<<"$out")"
drop "$id"

echo
[ "$FAIL" = "0" ] && echo "FINISH GATE: all assertions held." || echo "FINISH GATE: FAILED."
exit "$FAIL"

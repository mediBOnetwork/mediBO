#!/usr/bin/env bash
# CHANGE #1023 — behaviour test for the two lies this change ends.
#
#   1. A retry must never spend LESS effort than Om asked for. #1016 was added
#      as claude-fable-5-1 / extra; dev_cmd_fail's retry branch wrote
#      effort='high' as a literal and the card read "Fable 5 · High effort"
#      from then on.
#   2. A build whose Claude session has died must not keep saying `building`.
#      #1016 held it for 32 minutes: the runner's heartbeat is a bash subshell
#      that outlives the session it was started for, so every guard that reads
#      heartbeat_at stayed quiet.
#
# Real rows, real RPCs, no mocks. Everything it creates it deletes. Guarded
# RPCs go through devcmd.sh (service_role) because that is the identity the
# trigger is meant to refuse; setup and assertions go through psql, which is
# the DBA identity the trigger must NOT refuse.
#
# Usage: bash scripts/test_effort_ladder.sh
set -uo pipefail
DEVCMD="$HOME/mediBO-runner/devcmd.sh"
PGURL="$(cat "$HOME/.medibo/dburl")"
Q() { psql "$PGURL" -X -q -t -A -c "$1"; }
fails=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
is()   { [ "$2" = "$3" ] && ok "$1 ($3)" || bad "$1 — expected '$3', got '$2'"; }

NONCE="$(date +%s)-$$"; SEQ=0
mk() { # <effort> <model> → id ; created through the real add path
  # p_force:true is required, not laziness: dev_cmd_bulk_add dedupes on TITLE
  # similarity, and "…probe high" vs "…probe extra" is close enough that the
  # second probe is silently dropped as a duplicate of the first.
  SEQ=$((SEQ+1))
  "$DEVCMD" rpc dev_cmd_bulk_add "$(jq -nc --arg e "$1" --arg m "$2" --arg n "$NONCE-$SEQ" \
     '{p_items:[{title:("c1023 ladder probe "+$e+" "+$n),
                 spec:("c1023 behaviour probe "+$n+" — created and deleted by scripts/test_effort_ladder.sh"),
                 effort:$e, model:$m, kind:"dev", qa_required:false}], p_force:true}')" \
    | jq -r '.added[0].id // empty'
}
rm_row() { Q "delete from dev_commands where id=$1;" >/dev/null; }

echo "── 1. the retry ladder never lowers ────────────────────────────────────"
X=$(mk extra claude-fable-5-1); H=$(mk high claude-opus-5)
if [ -z "$X" ] || [ -z "$H" ]; then echo "could not create probe rows (X='$X' H='$H')"; exit 1; fi
Q "update dev_commands set status='building', claimed_by='c1023-test' where id in ($X,$H);" >/dev/null

"$DEVCMD" fail "$X" "flutter build failed: compilation error in lib/probe.dart" >/dev/null 2>&1
"$DEVCMD" fail "$H" "flutter build failed: compilation error in lib/probe.dart" >/dev/null 2>&1
is "an extra-effort command comes back from a retry as extra" "$(Q "select effort from dev_commands where id=$X;")" "extra"
is "a high-effort command escalates to extra"                 "$(Q "select effort from dev_commands where id=$H;")" "extra"
is "the retried extra row is pending again"                   "$(Q "select status from dev_commands where id=$X;")" "pending"
is "the model is untouched by the retry"                      "$(Q "select model from dev_commands where id=$X;")" "claude-fable-5-1"
case "$(Q "select route_reason from dev_commands where id=$X;")" in
  *"retry kept"*) ok "route_reason says the retry KEPT the effort" ;;
  *) bad "route_reason still claims an escalation: $(Q "select route_reason from dev_commands where id=$X;")" ;;
esac

echo "── 2. the ladder itself ────────────────────────────────────────────────"
is "escalate(unset) → high"  "$(Q "select _dev_effort_escalate(null);")"      "high"
is "escalate(high)  → extra" "$(Q "select _dev_effort_escalate('high');")"    "extra"
is "escalate(extra) → extra" "$(Q "select _dev_effort_escalate('extra');")"   "extra"
is "max(extra,high) → extra" "$(Q "select _dev_effort_max('extra','high');")" "extra"
is "max(high,extra) → extra" "$(Q "select _dev_effort_max('high','extra');")" "extra"

echo "── 3. the runner cannot lower it, whatever writes it ───────────────────"
DOWN=$("$DEVCMD" rpc dev_cmd_update "$(jq -nc --argjson i "$X" '{p_id:$i,p_patch:{effort:"high"}}')" 2>&1)
case "$DOWN" in
  *"CHANGE #1023"*) ok "a service_role downgrade is refused by the trigger" ;;
  *) bad "a service_role downgrade was NOT refused: $DOWN" ;;
esac
is "and the row still reads extra" "$(Q "select effort from dev_commands where id=$X;")" "extra"
SWAP=$("$DEVCMD" rpc dev_cmd_update "$(jq -nc --argjson i "$X" '{p_id:$i,p_patch:{model:"claude-opus-5"}}')" 2>&1)
case "$SWAP" in
  *"CHANGE #1023"*) ok "a service_role model swap is refused too" ;;
  *) bad "a service_role model swap was NOT refused: $SWAP" ;;
esac
# The DBA/admin identity must still be able to change both — a guard that locks
# Om out of his own card is a worse bug than the one it fixes.
Q "update dev_commands set effort='high', model='claude-opus-5' where id=$X;" >/dev/null
is "an admin/DBA CAN lower it" "$(Q "select effort||'/'||model from dev_commands where id=$X;")" "high/claude-opus-5"

echo "── 4. an UNREACHABLE session is re-queued in minutes, not in forty ────"
L=$(mk high claude-opus-5)
Q "update dev_commands set status='building', claimed_by='c1023-test', heartbeat_at=now(),
          agent_alive_at=now() - interval '6 minutes', agent_pane_alive=false,
          agent_rc_session='rc-c1023-test' where id=$L;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "a fresh heartbeat with an unreachable session goes back to pending" \
   "$(Q "select status from dev_commands where id=$L;")" "pending"
is "the worker is released with it" "$(Q "select coalesce(claimed_by,'-') from dev_commands where id=$L;")" "-"
is "and Om is told why, in a system message" \
   "$(Q "select count(*) from dev_command_messages where command_id=$L and sender='system' and body like '%Re-queued%';")" "1"
is "the loss is counted" "$(Q "select session_lost_count from dev_commands where id=$L;")" "1"
is "model and effort survive the re-queue untouched" \
   "$(Q "select effort||'/'||model from dev_commands where id=$L;")" "high/claude-opus-5"

echo "── 5. a CONNECTED agent is never re-queued for being quiet ─────────────"
# This is the guard against the obvious wrong fix. #692 sat 4m20s at its prompt
# with four background shells while it waited for the merge worker; a rule that
# reads silence as death throws that finished build away.
A=$(mk high claude-opus-5)
Q "update dev_commands set status='building', claimed_by='c1023-test',
          agent_alive_at=now() - interval '20 minutes', agent_pane_alive=true where id=$A;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "20 minutes quiet but reachable is STILL building" "$(Q "select status from dev_commands where id=$A;")" "building"
is "…and the amber chip is raised instead"            "$(Q "select agent_silent_flagged from dev_commands where id=$A;")" "t"
case "$(Q "select dev_cmd_agent_chip('building', true, now() - interval '6 minutes', true);")" in
  *"agent silent"*) ok "a reachable session reads 'agent silent'" ;;
  *) bad "wrong chip for a reachable silent agent" ;;
esac
case "$(Q "select dev_cmd_agent_chip('building', true, now() - interval '6 minutes', false);")" in
  *"disconnected"*) ok "an unreachable one says 'disconnected'" ;;
  *) bad "wrong chip for an unreachable agent" ;;
esac
# A speaking agent clears the flag again on the next sweep.
Q "update dev_commands set agent_alive_at=now() where id=$A;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "a fresh turn clears the amber" "$(Q "select agent_silent_flagged from dev_commands where id=$A;")" "f"

# A row that never reported liveness at all must never be judged on it.
N=$(mk high claude-opus-5)
Q "update dev_commands set status='building', claimed_by='c1023-test', agent_alive_at=null where id=$N;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "a runner that reports no liveness degrades to the old guards" \
   "$(Q "select status from dev_commands where id=$N;")" "building"

echo "── 6. a momentary blip does not kill a live build ──────────────────────"
P=$(mk high claude-opus-5)
Q "update dev_commands set status='building', claimed_by='c1023-test',
          agent_alive_at=now(), agent_pane_alive=false where id=$P;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "unreachable but speaking one second ago survives the grace minute" \
   "$(Q "select status from dev_commands where id=$P;")" "building"
is "…while still going amber straight away" \
   "$(Q "select agent_silent_flagged from dev_commands where id=$P;")" "t"
Q "update dev_commands set agent_alive_at=now() - interval '2 minutes' where id=$P;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "and is re-queued once the grace minute has passed" \
   "$(Q "select status from dev_commands where id=$P;")" "pending"

echo "── 7. a parked row is a known wait, never a lost session ───────────────"
K=$(mk high claude-opus-5)
Q "update dev_commands set status='building', claimed_by='c1023-test', wait_state='parked',
          agent_alive_at=now() - interval '30 minutes', agent_pane_alive=false where id=$K;" >/dev/null
Q "select dev_cmd_liveness_sweep();" >/dev/null
is "a parked build is left alone" "$(Q "select status from dev_commands where id=$K;")" "building"

echo "── 8. a HEADLESS slot is reachable — the probe reads the real session ──"
# The rule above is only as good as the fact it is fed. _liveness asked exactly
# one question — "is there an rc-<agent> tmux session?" — and a headless worker
# (runner.sh -> timeout -> claude --print, in its own claude-N session) never
# has one. Every headless build therefore reported pane_alive=false and section
# 6 re-queued it on the dot: #1023 itself was thrown back to pending four times
# WHILE IT WAS BUILDING. So assert the probe on real tmux sessions.
if command -v tmux >/dev/null 2>&1; then
  # Load the helpers out of devcmd.sh without running its dispatcher.
  eval "$(sed -n "1,/^cmd=\"\${1:-}\"/p" "$DEVCMD" | head -n -1)"
  S_BARE="c1023probe-bare-$$"
  S_LIVE="c1023probe-live-$$"
  tmux new-session -d -s "$S_BARE" 'sleep 60' 2>/dev/null
  # A session whose pane merely SITS there is what a dead CLI leaves behind
  # (_spawn ends its command with `; sleep infinity`), and it must read dead.
  if _claude_under "$S_BARE"; then bad "a session with no CLI under it reads alive"
  else ok "a session with no CLI under its pane is dead"; fi
  # And the session this test is running in does hold one — unless the suite is
  # being run by hand outside tmux, in which case there is nothing to assert.
  S_SELF="$(tmux display-message -p '#S' 2>/dev/null || true)"
  if [ -n "$S_SELF" ] && [ "$S_SELF" != "$S_BARE" ]; then
    if _claude_under "$S_SELF"; then ok "the live session running this test reads alive"
    else ok "run outside a Claude session — nothing to prove here"; fi
  fi
  tmux kill-session -t "$S_BARE" 2>/dev/null || true
  # The reachability answer must not depend on an rc- companion existing.
  if grep -q '_claude_under' "$DEVCMD"; then ok "_liveness falls back to the worker's own session"
  else bad "_liveness still asks only about rc-<agent>"; fi
else
  ok "no tmux on this box — reachability probe not applicable"
fi
# The grid must show a build even when its slot sits above the pool cap: the
# snapshot used to loop `seq 1 $active` and omit the worker entirely.
SUP="$HOME/mediBO-runner/supervisor.sh"
if [ -r "$SUP" ]; then
  if grep -q 'seq 1 "\$max_slots"' "$SUP"; then ok "pool snapshot covers slots above the cap"
  else bad "pool snapshot still stops at the active cap"; fi
fi

for id in $X $H $L $A $N $P $K; do [ -n "${id:-}" ] && rm_row "$id"; done
psql "$PGURL" -X -q -c "delete from dev_commands where title like 'c1023 ladder probe %$NONCE%';" >/dev/null 2>&1
echo
if [ "$fails" -eq 0 ]; then echo "c1023 effort/liveness behaviour: ALL GREEN"; exit 0; fi
echo "c1023 effort/liveness behaviour: $fails FAILED"; exit 1

#!/usr/bin/env bash
# wait_sleep_proof.sh — CHANGE #1817. Proves that waiting costs nothing.
#
# #1812 finished its code, queued behind deploy batch 594 and spent 159,555
# tokens polling the lane and re-thinking between polls. The batch took 17
# minutes and cost nothing. This script is the standing measurement of the fix:
#
#   1. the state machine  — the journey probe, on a scratch row it rolls back
#   2. the shell loop     — N polls inside ONE blocking call, zero model turns
#   3. the ledger         — every real wait since the change, its burn and its
#                           wake-ups, read out of dev_context_event
#
#   bash scripts/wait_sleep_proof.sh            # 1 and 3 (fast, read-only)
#   bash scripts/wait_sleep_proof.sh <cmd-id>   # also 2, against a live command
set -uo pipefail
DEVCMD="${DEVCMD:-$HOME/mediBO-runner/devcmd.sh}"
CMD="${1:-}"
fail=0
say() { printf '%s\n' "$*"; }
ok()  { printf '  ✓ %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; fail=1; }

say "── 1. the state machine (journey qa-1817-wait-sleeps) ─────────────────"
# the dev lane, because this probe reads the queue tables #1761 moved to the
# control plane; `devcmd.sh probe` is the only sanctioned hand-run of a journey.
probe=$("$DEVCMD" probe qa-1817-wait-sleeps dev 2>/dev/null)
if [ "$(jq -r '.status // "?"' <<<"$probe" 2>/dev/null)" = "passed" ]; then
  ok "begin → poll → wake-up → poll → backstop → end, all six assertions"
else
  bad "probe: $(jq -r '.evidence.db_proof // .status // "no answer"' <<<"$probe" 2>/dev/null)"
fi

if [ -n "$CMD" ]; then
  say ""
  say "── 2. the shell loop on #$CMD — one blocking call, no model turns ─────"
  before=$("$DEVCMD" rpc dev_wait_poll "$(jq -nc --argjson i "$CMD" '{p_id:$i}')" 2>/dev/null)
  say "  $(jq -r '.hold_line // .reason // "not waiting"' <<<"$before" 2>/dev/null)"
  polls=$(jq -r '.polls // 0' <<<"$before" 2>/dev/null)
  turns=$(jq -r '.turns // 0' <<<"$before" 2>/dev/null)
  burn=$(jq  -r '.burn  // 0' <<<"$before" 2>/dev/null)
  [ "${polls:-0}" -gt 0 ] && ok "$polls poll(s) taken by the loop" || say "  · no wait open on this command"
  if [ "${turns:-0}" -eq 0 ]; then ok "0 wake-ups — no model turn was taken while asleep"
  else bad "$turns wake-up(s) burning $burn tokens — the agent thought while waiting"; fi
fi

say ""
say "── 3. every wait since the change ─────────────────────────────────────"
led=$("$DEVCMD" rpc dev_context_metrics '{}' 2>/dev/null)
row=$(jq -c '.rows[]? | select(.label=="Waiting")' <<<"$led" 2>/dev/null)
if [ -n "$row" ]; then
  say "  Waiting · $(jq -r '.value' <<<"$row") · $(jq -r '.sub' <<<"$row")"
  case "$(jq -r '.tone' <<<"$row")" in
    danger) bad "the Context economy panel is red: a command thought while it waited" ;;
    *)      ok  "the Context economy panel is not red" ;;
  esac
else
  bad "dev_context_metrics has no Waiting row — the panel cannot show this"
fi

say ""
if [ "$fail" -eq 0 ]; then say "WAIT PROOF: green — waiting is a shell sleep."; else say "WAIT PROOF: RED."; fi
exit "$fail"

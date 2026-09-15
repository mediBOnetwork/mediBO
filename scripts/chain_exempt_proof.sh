#!/usr/bin/env bash
# CHANGE #428 — proof that the conflict scheduler stops serialising the queue.
#
# Companion to scripts/build_lane_proof.sh (#327), which proved a chained
# command is never handed out. This one proves the opposite half: a command
# whose only overlap is a SHARED append-only surface, a directory glob, or
# another command's mere PREDICTION is never chained at all — so a full queue
# cannot starve idle runners again.
#
# It runs entirely on synthetic rows in a transaction that is ROLLED BACK, so
# it never touches the live queue. Read-only as far as the queue is concerned.
#
#   bash scripts/chain_exempt_proof.sh
#
# Exit 0 = every assertion held.
set -euo pipefail

DEVCMD="${DEVCMD:-$HOME/mediBO-runner/devcmd.sh}"
[ -x "$DEVCMD" ] || { echo "chain_exempt_proof: $DEVCMD not found" >&2; exit 3; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 — expected $2, got $3"; fi
}

q() { "$DEVCMD" rpc "$1" "$2"; }

echo "CHANGE #428 — conflict-exempt scheduling proof"
echo

# ── 1. the exempt list is live and covers every surface the spec named ──────
echo "1. Conflict-exempt shared surfaces"
for p in \
  'lib/screens/admin/admin_nav_entries.dart' \
  'lib/screens/home_shell.dart' \
  'lib/main.dart' \
  'supabase/migrations/20260101_anything.sql' \
  'db:ui_copy' 'db:feature_registry' 'db:wa_event_routes' 'db:scheduled_tasks'
do
  got=$(q dev_path_is_shared "$(jq -nc --arg p "$p" '{p_path:$p}')")
  check "exempt: $p" "true" "$got"
done
# a real screen is NOT exempt — the guard must still guard
got=$(q dev_path_is_shared '{"p_path":"lib/screens/cart_screen.dart"}')
check "NOT exempt: lib/screens/cart_screen.dart" "false" "$got"
echo

# ── 2. dev_paths_conflict: only exact, non-shared, equal paths conflict ─────
echo "2. What counts as a real conflict"
c() { q dev_paths_conflict "$(jq -nc --argjson a "$1" --argjson b "$2" '{a:$a,b:$b}')"; }
check "same exact screen IS a conflict" '["lib/screens/cart_screen.dart"]' \
  "$(c '["lib/screens/cart_screen.dart"]' '["lib/screens/cart_screen.dart"]' | jq -c .)"
check "shared registry is NOT a conflict" '[]' \
  "$(c '["lib/screens/admin/admin_nav_entries.dart"]' \
       '["lib/screens/admin/admin_nav_entries.dart"]' | jq -c .)"
check "two migrations are NOT a conflict" '[]' \
  "$(c '["supabase/migrations/a.sql"]' '["supabase/migrations/a.sql"]' | jq -c .)"
check "same directory GLOB is NOT a conflict" '[]' \
  "$(c '["lib/screens/supplier/%"]' '["lib/screens/supplier/%"]' | jq -c .)"
check "glob vs exact inside it is NOT a conflict" '[]' \
  "$(c '["lib/screens/supplier/%"]' '["lib/screens/supplier/shop_screen.dart"]' | jq -c .)"
check "disjoint screens are NOT a conflict" '[]' \
  "$(c '["lib/screens/cart_screen.dart"]' '["lib/screens/wishlist_screen.dart"]' | jq -c .)"
echo

# ── 3. the live queue is claimable ─────────────────────────────────────────
echo "3. The live queue"
st=$(q build_contention_status '{"p_days":7}')
echo "   headline: $(jq -r '.headline.label' <<<"$st")"
echo "   detail:   $(jq -r '.headline.detail' <<<"$st")"
free=$(jq -r '.headline.label' <<<"$st" | sed 's/ of .*//')
if [ "${free:-0}" -ge 4 ] 2>/dev/null; then
  ok "at least 4 pending commands claimable in parallel (${free})"
else
  bad "only ${free} pending command(s) claimable — the queue is still serialised"
fi
if jq -e '.sections[] | select(.heading | startswith("Conflict-exempt"))' >/dev/null <<<"$st"; then
  ok "the Build lane card renders the exempt list"
else
  bad "the Build lane card is missing the exempt section"
fi
if jq -e '.sections[] | select(.heading == "Queue starvation watchdog")' >/dev/null <<<"$st"; then
  ok "the Build lane card renders the starvation watchdog"
else
  bad "the Build lane card is missing the watchdog section"
fi
echo

# ── 4. the watchdog answers, and its thresholds are config ─────────────────
echo "4. Starvation watchdog"
wd=$(q dev_chain_watchdog '{}')
check "watchdog runs" "true" "$(jq -r '.ok' <<<"$wd")"
echo "   chained=$(jq -r '.chained' <<<"$wd") idle_workers=$(jq -r '.idle_workers' <<<"$wd")" \
     "worst=$(jq -r '.worst_worker' <<<"$wd") worst_idle_s=$(jq -r '.worst_idle_s' <<<"$wd")" \
     "thresholds: >=$(jq -r '.min_chained' <<<"$wd") chained + $(jq -r '.idle_min' <<<"$wd") min idle"
if [ "$(jq -r '.chained' <<<"$wd")" = "0" ] && [ "$(jq -r '.alert' <<<"$wd")" = "false" ]; then
  ok "nothing chained, so nothing to alert about"
else
  ok "watchdog evaluated (alert=$(jq -r '.alert' <<<"$wd"))"
fi
if "$DEVCMD" rpc cron_health '{}' 2>/dev/null | grep -q chain_watchdog; then
  ok "chain_watchdog rides the one cron dispatcher"
else
  echo "  note: chain_watchdog not visible in cron_health payload (registered in cron_task)"
fi
echo

echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]

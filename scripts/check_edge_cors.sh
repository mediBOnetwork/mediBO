#!/usr/bin/env bash
# check_edge_cors.sh — every edge function the WEB app invokes must answer a
# CORS preflight, or the browser silently blocks the real request.
#
# CHANGE #225. The VM on/off toggle "was not wired" for days. It was wired: the
# Dart routed correctly, dev_ctl_set returned call_edge, the AWS key held all
# three EC2 permissions. What failed was invisible from every one of those
# angles — medibo.in and *.supabase.co are different origins, so the browser
# sends an OPTIONS preflight first, vm-control had no CORS at all, the preflight
# fell through to its am_i_super() check and came back 403 with no
# Access-Control-Allow-Origin, and the POST that would have called EC2 was never
# sent. The only trace was `OPTIONS | 403` rows in function_edge_logs.
#
# OFF still appeared to work, which is what made it so confusing: that path does
# not need the edge function at all — dev_ctl_set (PostgREST, which does send
# CORS) writes desired_state.vm='off' and the supervisor ON the box shuts it
# down. A stopped box cannot start itself, so ON had no such fallback.
#
# The function list is READ FROM THE DART, not hardcoded: any new
# `functions.invoke('x')` is covered the day it is written.
#
# Usage:  bash scripts/check_edge_cors.sh
# Exit:   0 = every invoked function preflights cleanly
#         1 = at least one would be blocked in the browser
set -uo pipefail

cd ~/mediBO || { echo "check_edge_cors: cannot cd ~/mediBO"; exit 1; }

# SUPABASE_URL only — this script needs no credential. A preflight carries no
# Authorization header by design; that is the entire point of the check.
: "${SUPABASE_URL:=$(grep -m1 '^SUPABASE_URL=' ~/mediBO-runner/runner.env 2>/dev/null | cut -d= -f2-)}"
[ -n "${SUPABASE_URL:-}" ] || { echo "check_edge_cors: SUPABASE_URL unknown"; exit 1; }

FNS=$(grep -rhoP "functions\.invoke\(\s*'[^']+'" lib | sed "s/.*'\(.*\)'/\1/" | sort -u)
[ -n "$FNS" ] || { echo "check_edge_cors: no functions.invoke() calls found in lib/"; exit 1; }

BAD=()
for f in $FNS; do
  hdrs=$(curl -s -o /dev/null -D - -X OPTIONS "$SUPABASE_URL/functions/v1/$f" \
           -H 'Origin: https://medibo.in' \
           -H 'Access-Control-Request-Method: POST' \
           -H 'Access-Control-Request-Headers: authorization,content-type' \
           -w '%{http_code}' 2>/dev/null)
  code=$(printf '%s' "$hdrs" | tail -1)
  # The browser needs BOTH: a 2xx preflight and an allow-origin header.
  if printf '%s' "$hdrs" | grep -qi '^access-control-allow-origin:' && [ "${code:0:1}" = "2" ]; then
    printf '  OK    %-24s preflight %s + allow-origin\n' "$f" "$code"
  else
    printf '  BLOCK %-24s preflight %s, allow-origin missing\n' "$f" "$code"
    BAD+=("$f")
  fi
done

echo
if [ ${#BAD[@]} -eq 0 ]; then
  echo "check_edge_cors: GREEN — all $(echo "$FNS" | wc -w) invoked functions preflight cleanly"
  exit 0
fi
echo "check_edge_cors: RED — the browser will block: ${BAD[*]}"
echo "Fix: answer OPTIONS with 204 + the cors header set BEFORE any auth check,"
echo "     and put those headers on every reply (see supabase/functions/vm-control)."
exit 1

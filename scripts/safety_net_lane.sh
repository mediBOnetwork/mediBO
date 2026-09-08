#!/usr/bin/env bash
# CHANGE #636 — the nightly drain for the machine-generated safety net.
#
# The safety net is minutes of SQL, so it cannot live on cron_dispatch()'s tick:
# run there it cancelled at the 15 s dblink budget and took every other
# scheduled task with it, which is why #1808 disabled it. The cron task now only
# ENQUEUES (test_run_request_add 'safety_net'); this is what drains it.
#
# --kinds safety_net is the whole point of claiming through
# test_run_request_claim_kind: the head of the queue may be #634's 'full'
# request — the entire hostile suite against production — and a timer that is
# only allowed to run ONE job must never take it by accident.
#
# Quiet by design: no request waiting is a normal exit 0, not a failure. The
# 21:10 UTC window is 02:40 IST, inside the heavy-work window the DB lane rule
# reserves, and the run takes the exclusive DB lane so it never lands on top of
# another agent's migration.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
runner="${MEDIBO_RUNNER_DIR:-$HOME/mediBO-runner}"
devcmd="$runner/devcmd.sh"
log() { echo "[safety-net-lane] $*"; }

# One drain at a time, whoever starts it.
exec 9>"$runner/.safety_net_lane.lock"
flock -n 9 || { log "another drain holds the lock — nothing to do"; exit 0; }

token=""
if [ -x "$devcmd" ]; then
  out=$("$devcmd" dblock safety-net-lane exclusive "nightly safety net" 3600 2>/dev/null || echo '{}')
  token=$(printf '%s' "$out" | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("token") or "")' 2>/dev/null || echo "")
  if [ -z "$token" ]; then
    log "DB lane busy — leaving the request queued for the next window"
    exit 0
  fi
fi
release() { [ -n "$token" ] && [ -x "$devcmd" ] && "$devcmd" dbunlock "$token" >/dev/null 2>&1 || true; }
trap release EXIT

log "claiming a safety_net request"
bash "$repo/scripts/autotest.sh" --if-requested --kinds safety_net
rc=$?
log "finished rc=$rc"
exit "$rc"

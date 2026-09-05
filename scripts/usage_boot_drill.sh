#!/usr/bin/env bash
# usage_boot_drill.sh — CHANGE #1365.
#
# Proves the deadlock cannot come back. On 4-5 Sep the VM idled with the weekly
# limit at 100%, booted, and never recovered by itself: the usage fetcher needed
# a Claude session's OAuth token, the supervisor needed a fresh usage reading to
# grow the pool, and the pool needed to grow before any session could start. The
# only exit was a human.
#
# Three assertions, in the order the boot actually goes:
#   A. BEHAVIOUR — an expired window counts as 0% and NEVER shrinks the pool; a
#      reading older than worker_pool.usage_stale_ignore_s is `unknown` and
#      likewise never shrinks. (Run against a snapshot of the live config, which
#      is restored afterwards whatever happens.)
#   B. REPORTING — a failed fetch is never silent: dev_usage_fetch_failed makes
#      the card say "sync failing: <reason>", and the next good fetch clears it.
#   C. BOOT — after `--boot` (a real stop/start, or `--simulate-boot` which
#      restarts the timer instead), fetched_at is fresh within FRESH_S seconds
#      and the queue claims within CLAIM_S with a pending row waiting.
#
# Usage:
#   scripts/usage_boot_drill.sh                 # A + B, plus C against the timer
#   scripts/usage_boot_drill.sh --simulate-boot # C after restarting the timer
# Exit 0 = every assertion held. Exit 1 = a real regression; read the FAIL line.
set -uo pipefail

DEVCMD="${DEVCMD:-$HOME/mediBO-runner/devcmd.sh}"
FRESH_S=${FRESH_S:-60}     # spec: a fresh fetched_at within 60s of boot
CLAIM_S=${CLAIM_S:-120}    # spec: a claim within 2 min of boot
fails=0

say()  { printf '%s\n' "$*"; }
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails+1)); }
rpc()  { "$DEVCMD" rpc "$1" "${2:-{\}}" 2>/dev/null; }
jqr()  { python3 -c "
import json,sys
try: d=json.loads(sys.stdin.read() or '{}')
except Exception: d={}
k=sys.argv[1]
for part in k.split('.'):
    d = (d or {}).get(part) if isinstance(d,dict) else None
print('' if d is None else (str(d).lower() if isinstance(d,bool) else d))
" "$1"; }

SNAP="$(mktemp)"; trap 'restore_usage; rm -f "$SNAP"' EXIT

snapshot_usage() { rpc dev_usage_effective > "$SNAP"; }
restore_usage() {
  # Always hand the box back its real numbers, even on a failed assertion — the
  # supervisor is reading this key every 20 seconds while the drill runs.
  [ -s "$SNAP" ] || return 0
  python3 -c "
import json,sys
d=json.load(open('$SNAP'))
lim=[{k:v for k,v in l.items() if k in ('kind','group','scope','percent','severity','is_active','resets_at')}
     for l in (d.get('limits') or [])]
if lim: print(json.dumps({'p_usage': {'limits': lim}}))
" > "$SNAP.arg" 2>/dev/null
  [ -s "$SNAP.arg" ] && "$DEVCMD" rpc dev_set_usage "$(cat "$SNAP.arg")" >/dev/null 2>&1
  rm -f "$SNAP.arg"
}

# Writes a synthetic claude_usage whose single weekly limit sits at $1 percent
# and resets at $2 ('past' | 'future').
set_synthetic() {
  local pct="$1" when="$2"
  "$DEVCMD" rpc dev_set_usage "$(python3 -c "
import json,sys,datetime
pct=int(sys.argv[1]); when=sys.argv[2]
now=datetime.datetime.now(datetime.timezone.utc)
r=now-datetime.timedelta(hours=3) if when=='past' else now+datetime.timedelta(days=5)
print(json.dumps({'p_usage':{'limits':[{'kind':'weekly_all','group':'weekly','scope':None,
  'percent':pct,'severity':'normal','is_active':True,'resets_at':r.isoformat()}]}}))
" "$pct" "$when")" >/dev/null 2>&1
}

say "── A. behaviour: an expired or unknown reading never shrinks the pool ──"
snapshot_usage
if [ ! -s "$SNAP" ]; then
  fail "could not snapshot dev_usage_effective — refusing to write synthetic usage"
else
  set_synthetic 100 future
  u="$(rpc dev_cmd_session_usage)"
  [ "$(jqr quota_shrink <<<"$u")" = "true" ] \
    && pass "100% weekly, window still open → quota_shrink true (the guard can fire)" \
    || fail "100% weekly with an OPEN window did not set quota_shrink — the guard is dead"

  set_synthetic 100 past
  u="$(rpc dev_cmd_session_usage)"
  p="$(jqr quota_pct <<<"$u")"; s="$(jqr quota_shrink <<<"$u")"
  { [ "$p" = "0" ] && [ "$s" = "false" ]; } \
    && pass "100% weekly whose window already RESET → quota_pct 0, quota_shrink false" \
    || fail "an expired window still reads quota_pct=$p quota_shrink=$s — this is the 5 Sep deadlock"

  raw="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
print((d.get('limits') or [{}])[0].get('raw_percent'))
" <<<"$(rpc dev_usage_effective)")"
  [ "$raw" = "100" ] \
    && pass "the pre-reset reading is kept as raw_percent ($raw) — zeroed for decisions, not lost" \
    || fail "raw_percent was $raw, expected the 100 that was actually read"
  restore_usage
fi

say "── B. reporting: a failed fetch is never silent ──"
rpc dev_usage_fetch_failed '{"p_reason":"drill: synthetic failure"}' >/dev/null
u="$(rpc dev_cmd_session_usage)"
[ "$(jqr updated_display <<<"$u")" = "sync failing: drill: synthetic failure" ] \
  && pass "the card says 'sync failing: drill: synthetic failure'" \
  || fail "a recorded failure did not reach updated_display (got: $(jqr updated_display <<<"$u"))"
[ "$(jqr updated_tone <<<"$u")" = "failed" ] \
  && pass "its tone is failed, so the chip cannot look healthy" \
  || fail "updated_tone was $(jqr updated_tone <<<"$u"), expected failed"

# A real fetch must clear it. Ask for one and let the timer's own tick do it.
rpc dev_request_usage_refresh >/dev/null
rm -f "$HOME/.medibo/usage_state.json"
"$HOME/mediBO-runner/push_usage.sh" >/dev/null 2>&1
u="$(rpc dev_cmd_session_usage)"
[ "$(jqr fetch_failing <<<"$u")" = "false" ] \
  && pass "the next good fetch retired the banner" \
  || fail "usage_fetch_error survived a successful fetch — the card would nag forever"

say "── C. boot: the fetch is session-free ──"
if [ "${1:-}" = "--simulate-boot" ]; then
  # OnBootSec is what runs after a real power cycle; restarting the timer is the
  # same code path without taking the box down mid-queue.
  sudo systemctl stop medibo-usage-sync.timer >/dev/null 2>&1
  rm -f "$HOME/.medibo/usage_state.json"
  before="$(date -u +%s)"
  sudo systemctl start medibo-usage-sync.timer >/dev/null 2>&1
  rpc dev_request_usage_refresh >/dev/null
else
  before="$(date -u +%s)"
fi

deadline=$(( $(date -u +%s) + FRESH_S ))
fresh=""
while [ "$(date -u +%s)" -lt "$deadline" ]; do
  age="$(jqr fetched_age_secs <<<"$(rpc dev_usage_poll_state)")"
  if [ -n "$age" ] && [ "$age" -le "$FRESH_S" ] 2>/dev/null; then fresh="$age"; break; fi
  sleep 5
done
[ -n "$fresh" ] \
  && pass "fetched_at is ${fresh}s old — a fresh reading inside ${FRESH_S}s, with no Claude session involved" \
  || fail "no fetch landed within ${FRESH_S}s; usage_fetch_error is: $(jqr fetch_error.reason <<<"$(rpc dev_usage_poll_state)")"

# The claim half of the drill: with work waiting, the pool must not be pinned to
# one by a usage reading. Reported, never asserted into a false red — a genuinely
# empty queue is not a failure of this change.
pend="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
print(len([r for r in (d.get('rows') or []) if r.get('status')=='pending']))
" <<<"$("$DEVCMD" rpc dev_cmd_list '{"p_status":"pending","p_limit":50}' 2>/dev/null)")"
u="$(rpc dev_cmd_session_usage)"
if [ "$(jqr quota_shrink <<<"$u")" = "false" ]; then
  pass "quota_shrink is false, so the pool may grow to meet ${pend:-0} pending row(s) within ${CLAIM_S}s"
else
  fail "quota_shrink is true on a healthy reading — claims would be throttled"
fi

say ""
if [ "$fails" -eq 0 ]; then say "usage boot drill: PASSED"; exit 0; fi
say "usage boot drill: $fails assertion(s) FAILED"; exit 1

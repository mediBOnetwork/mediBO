#!/usr/bin/env bash
# CHANGE #641 — the never-again probe, run before every deploy.
#
# On 2026-09-01 dev_cmd_complete_fast opened with rg_check_cached(900,false),
# whose miss path is a 10-25 minute scan. The runner's curl gave up at 70 s, the
# SERVER kept scanning, the runner retried, and three commands were retried 98
# times for roughly 18 hours of database time: CPU 98%, a PostgREST schema-cache
# 503 loop, the whole fleet in standby.
#
# Two guards close that class. Both live in rg_behavior_tests (the only place
# they can touch the real database — test/protected/ is Dart-VM-only, no
# Supabase, per CLAUDE.md) and both are cheap enough to run here as well as in
# the two-hourly rg_check, so a regression is caught in the command that caused
# it rather than up to two hours later:
#
#   c641_complete_fast_under_2s  seeds a building command on a reserved id,
#                                times dev_cmd_complete_fast, fails over 2 s,
#                                and rolls the whole thing back.
#   c641_no_rg_in_http_rpcs      no dev_cmd_%/dev_ctl_%/merge_% function may
#                                call rg_check*/rg_baseline*/dev_journeys_run.
#
# Exit 0 both green · 1 a guard failed · 2 backend unreachable (never treated as
# red — an unreachable database must not wedge the deploy lane).
set -uo pipefail

DEVCMD="${DEVCMD:-$HOME/mediBO-runner/devcmd.sh}"
GUARDS=(c641_complete_fast_under_2s c641_no_rg_in_http_rpcs)

[ -x "$DEVCMD" ] || { echo "complete_fast probe: devcmd not found at $DEVCMD — UNREACHABLE"; exit 2; }

rc=0
for g in "${GUARDS[@]}"; do
  out="$("$DEVCMD" rpc rg_run_behavior "$(printf '{"p_name":"%s"}' "$g")" 2>/dev/null)"
  if [ -z "$out" ] || ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    echo "  $g: UNREACHABLE (no reply)"; exit 2
  fi
  if [ "$(jq -r '.ok // false' <<<"$out")" = "true" ]; then
    echo "  $g: GREEN"
  else
    echo "  $g: RED — $(jq -r '.error // .message // "unknown"' <<<"$out")"
    rc=1
  fi
done
exit $rc

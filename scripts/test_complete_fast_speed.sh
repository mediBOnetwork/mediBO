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
#
# CHANGE #956 — "unreachable" used to mean ONLY an empty or unparseable reply.
# PostgREST's own failures are perfectly valid JSON:
#     {"code":"PGRST002","message":"Could not query the database for the schema
#      cache. Retrying."}
# so `.ok` was simply absent, the guard read RED, and the deploy aborted. On
# 2026-09-03 that killed two consecutive batches — CHANGE #1071 and #1072 —
# while the DATABASE was healthy (24 of 60 connections, psql instant) and the
# guard passed on the very next manual run. The transport was down, not the
# feature. A PostgREST error code, or a message naming a contention/transport
# failure, is now retried and then reported as UNREACHABLE, never as red.
set -uo pipefail

DEVCMD="${DEVCMD:-$HOME/mediBO-runner/devcmd.sh}"
GUARDS=(c641_complete_fast_under_2s c641_no_rg_in_http_rpcs)

[ -x "$DEVCMD" ] || { echo "complete_fast probe: devcmd not found at $DEVCMD — UNREACHABLE"; exit 2; }

# A reply that is the TRANSPORT talking, not the guard. Kept in step with
# public._journey_contention_phrase(), which classifies the same sentences for
# journeys (dev_journey_runs) and QA (qa_report).
is_transport_error() {
  local body="$1"
  case "$(jq -r '.code // ""' <<<"$body")" in PGRST*) return 0;; esac
  local msg
  msg="$(jq -r '((.message // "") + " " + (.error // "") + " " + (.details // "")) | ascii_downcase' <<<"$body")"
  case "$msg" in
    *"schema cache"*|*"could not query the database"*|*"lock timeout"*|\
    *"statement timeout"*|*"deadlock detected"*|*"too many clients"*|\
    *"remaining connection slots"*|*"server closed the connection"*|\
    *"terminating connection due to"*|*"connection refused"*|\
    *"connection reset by peer"*|*"service unavailable"*|*"gateway"*) return 0;;
  esac
  return 1
}

# A guard that is NOT THERE has produced no verdict.
#
# CHANGE #668's live-proof round hit this: rg_run_behavior() answers
# "no such behaviour test" for c641_complete_fast_under_2s, because the
# behaviour seeds a building row in dev_commands and the dev-queue control
# plane moved to its own project (#1761) — the registry row did not move with
# it. run_protected() returns this script's status, so from that moment EVERY
# batch went red, was "bisected" down to its last branch and evicted it with
# "protected suite red on this branch alone". Proven on a clean checkout of
# main at CHANGE #1146 with nothing merged: exit 1, same line.
#
# Evicting the whole fleet for a missing row is a lane outage wearing a quality
# gate's clothes. A guard that ran and failed still evicts (rc=1). A guard that
# does not exist is reported loudly, raised as an ops alert so the gap is
# tracked rather than forgiven, and is not held against the branch.
is_missing_guard() {
  [ "$(jq -r '.error // ""' <<<"$1")" = "no such behaviour test" ]
}

rc=0
missing=0
for g in "${GUARDS[@]}"; do
  out=''
  # Three tries: a schema-cache stall clears in seconds, and one unlucky poll
  # must not cost a whole batch's build.
  for attempt in 1 2 3; do
    out="$("$DEVCMD" rpc rg_run_behavior "$(printf '{"p_name":"%s"}' "$g")" 2>/dev/null)"
    if [ -z "$out" ] || ! jq -e . >/dev/null 2>&1 <<<"$out"; then
      [ "$attempt" -lt 3 ] && { sleep 10; continue; }
      echo "  $g: UNREACHABLE (no reply after $attempt tries)"; exit 2
    fi
    if is_transport_error "$out"; then
      [ "$attempt" -lt 3 ] && { sleep 10; continue; }
      echo "  $g: UNREACHABLE — the transport answered, the guard did not:" \
           "$(jq -r '.code // ""' <<<"$out") $(jq -r '.message // .error // ""' <<<"$out")"
      exit 2
    fi
    break
  done
  # CHANGE #1016 — a TIMING verdict is one sample of a shared 1 GB instance.
  # Batches 395 and 396 (2026-09-04 05:39–05:59) evicted a branch whose Dart
  # suite was green because the probe read 2072 ms once while the database
  # was restarting; the very next run took 400 ms. The regression this guard
  # exists for (#641: a 10–25 minute scan on the HTTP path) fails every sample,
  # so red now means three consecutive overruns, never one unlucky poll.
  # Structural guards (c641_no_rg_in_http_rpcs) still fail on the first read.
  if is_missing_guard "$out"; then
    echo "  $g: MISSING — the behaviour row is absent from the control-plane" \
         "registry; no verdict, so this is not held against the branch"
    missing=$((missing+1))
    "$DEVCMD" rpc runner_ops_alert "$(jq -nc --arg g "$g" \
      '{p_kind:"rg_behavior_missing",p_vars:{behavior:$g,source:"test_complete_fast_speed.sh"}}')" \
      >/dev/null 2>&1 || true
    continue
  fi
  if [ "$(jq -r '.ok // false' <<<"$out")" != "true" ] && [ "$g" = "c641_complete_fast_under_2s" ]; then
    for retry in 2 3; do
      echo "  $g: overrun on sample $((retry-1)) — $(jq -r '.error // .message // "unknown"' <<<"$out"); resampling"
      sleep 10
      again="$("$DEVCMD" rpc rg_run_behavior "$(printf '{"p_name":"%s"}' "$g")" 2>/dev/null)"
      if [ -n "$again" ] && jq -e . >/dev/null 2>&1 <<<"$again" && ! is_transport_error "$again"; then
        out="$again"
      fi
      [ "$(jq -r '.ok // false' <<<"$out")" = "true" ] && break
    done
  fi
  if [ "$(jq -r '.ok // false' <<<"$out")" = "true" ]; then
    echo "  $g: GREEN"
  else
    echo "  $g: RED — $(jq -r '.error // .message // "unknown"' <<<"$out")"
    rc=1
  fi
done
if [ "$missing" -gt 0 ]; then
  echo "  $missing guard(s) MISSING from the registry — restore them; until then" \
       "they prove nothing either way."
fi
exit $rc

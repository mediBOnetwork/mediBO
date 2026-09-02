#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# scripts/selftest.sh — CHANGE #222 — THE FOLD-IN TEST GATE.
#
# WHY THIS EXISTS
# Before #222, "run flutter test test/protected/ before every deploy" was PROSE
# in CLAUDE.md and nothing else. deploy.sh never ran a single test. So a build
# with a red suite deployed happily, the bug surfaced after the fact, QA failed,
# and a "Debug pass — verify & fix #N" twin was born to clean it up — a second
# full-price build for a bug the first build could have caught in-session.
#
# This script is the fix: testing is FOLDED INTO the build, in the SAME worker
# session, BEFORE anything ships. deploy.sh calls it as a hard gate. Red tests
# mean no bundle is ever built, so there is nothing to roll back and no twin to
# pay for.
#
# FOUR PHASES, ALL MUST BE GREEN
#   TWO phases gate the build (the third moved off it — see below):
#   1. protected — flutter test test/protected/  (the regression suite)
#   2. focused   — the command's OWN test(s), auto-detected from the git diff
#                  (any *_test.dart changed vs origin/main, staged, unstaged or
#                  untracked) so a builder gets this for free with zero config
#   3. rg        — MOVED OUT (CHANGE #273). rg_check() is a heavy read against
#                  production and firing it from the pre-build gate is what put
#                  a 13.5-second guard query on top of the per-minute cron burst
#                  at 10:01:24 UTC on 2026-08-18, 33 seconds before Postgres
#                  went silent. It now runs AFTER the deploy, from
#                  scripts/rg_after_deploy.sh. Still mandatory — dev_cmd_complete()
#                  raises on a red guard — just no longer on the build path.
#                  --rg re-enables it here for a manual run.
#
# ATTEMPT CAP (spec #222.3): a worker fixes red tests in-session and re-runs.
# After `--attempt-cap` consecutive red runs for the same command (default 3)
# the gate STOPS trying, files qa_report(failed) and exits 2. It never loops
# forever and it never silently deploys.
#
# EXIT CODES
#   0  all requested phases green — deploy may proceed
#   1  at least one phase red — DO NOT DEPLOY (fix and re-run)
#   2  red AND the attempt cap was reached — qa_status set to 'failed', stop
#
# USAGE
#   scripts/selftest.sh [--cmd <id>] [--focus <path>]... [--rg] [--no-rg]
#                       [--attempt-cap <n>] [--reset]
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

# CHANGE #352 — test the tree that is being DEPLOYED, not the shared checkout.
# The merge worker (#324) builds from its own worktree and exports MEDIBO_REPO;
# this line hardcoded ~/mediBO, the checkout five runners share and constantly
# switch branches in. So the gate that is supposed to prove the MERGED tree is
# green was running the protected suite against whatever branch happened to be
# checked out next door — red for another command's in-flight literals, or
# green for code that was never in the batch. Same trap as ~/deploy.sh's
# hardcoded path, one directory up.
MEDIBO_REPO="${MEDIBO_REPO:-$HOME/mediBO}"
cd "$MEDIBO_REPO" || { echo "selftest: cannot cd $MEDIBO_REPO"; exit 1; }
export PATH="$PATH:$HOME/flutter/bin"

DEVCMD="$HOME/mediBO-runner/devcmd.sh"
STATE_DIR="$HOME/mediBO-runner"
CMD_ID=""
# CHANGE #273: OFF by default. rg_check() runs post-deploy, not pre-build.
RUN_RG=0
ATTEMPT_CAP=3
RESET=0
FOCUS_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cmd)          CMD_ID="${2:-}"; shift 2 ;;
    --focus)        FOCUS_ARGS+=("${2:-}"); shift 2 ;;
    --rg)           RUN_RG=1; shift ;;
    --no-rg)        RUN_RG=0; shift ;;
    --attempt-cap)  ATTEMPT_CAP="${2:-3}"; shift 2 ;;
    --reset)        RESET=1; shift ;;
    *)              echo "selftest: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

# Env fallbacks so a caller can drive this without editing the call site.
[ -z "$CMD_ID" ] && CMD_ID="${DEV_CMD_ID:-}"
if [ ${#FOCUS_ARGS[@]} -eq 0 ] && [ -n "${SELFTEST_FOCUS:-}" ]; then
  # shellcheck disable=SC2206
  FOCUS_ARGS=(${SELFTEST_FOCUS})
fi

say() { echo "[selftest] $*"; }
rule() { echo "──────────────────────────────────────────────────────────────"; }

ATTEMPT_FILE="$STATE_DIR/.selftest_attempts_${CMD_ID:-none}"
[ "$RESET" = "1" ] && rm -f "$ATTEMPT_FILE"

PROTECTED_OK=skipped
FOCUS_OK=skipped
RG_OK=skipped
FAILED_PHASES=()
LOG="$(mktemp)"

# ── PHASE 1: the protected regression suite ────────────────────────────────
rule; say "PHASE 1/4 — protected suite (flutter test test/protected/)"
if timeout 900 flutter test test/protected/ >"$LOG" 2>&1; then
  PROTECTED_OK=passed
  say "protected: PASSED — $(grep -oE '\+[0-9]+' "$LOG" | tail -1 | tr -d '+') tests"
else
  PROTECTED_OK=failed
  FAILED_PHASES+=("protected")
  say "protected: FAILED"
  tail -40 "$LOG"
fi

# ── PHASE 2: this command's own focused test(s) ────────────────────────────
# Auto-detected so a builder never has to remember to wire it: every changed or
# new *_test.dart outside test/protected/ (already covered by phase 1).
rule; say "PHASE 2/4 — focused test(s) for this change"
FOCUS_FILES=()
if [ ${#FOCUS_ARGS[@]} -gt 0 ]; then
  for f in "${FOCUS_ARGS[@]}"; do [ -f "$f" ] && FOCUS_FILES+=("$f"); done
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    case "$f" in test/protected/*) continue ;; esac
    FOCUS_FILES+=("$f")
  done < <(
    {
      git diff --name-only origin/main...HEAD -- 'test/*_test.dart' 'test/**/*_test.dart' 2>/dev/null
      git diff --name-only HEAD              -- 'test/*_test.dart' 'test/**/*_test.dart' 2>/dev/null
      git ls-files --others --exclude-standard -- 'test/*_test.dart' 'test/**/*_test.dart' 2>/dev/null
    } | sort -u
  )
fi

if [ ${#FOCUS_FILES[@]} -eq 0 ]; then
  say "focused: none detected (no changed/new *_test.dart outside test/protected/)"
else
  say "focused: running ${#FOCUS_FILES[@]} file(s) — ${FOCUS_FILES[*]}"
  if timeout 900 flutter test "${FOCUS_FILES[@]}" >"$LOG" 2>&1; then
    FOCUS_OK=passed
    say "focused: PASSED"
  else
    FOCUS_OK=failed
    FAILED_PHASES+=("focused")
    say "focused: FAILED"
    tail -40 "$LOG"
  fi
fi

# ── PHASE 3: schema/RPC regression guard ───────────────────────────────────
rule; say "PHASE 3/4 — rg_check() (post-deploy since CHANGE #273)"
if [ "$RUN_RG" = "1" ]; then
  RG_RAW="$("$DEVCMD" rgcheck 2>/dev/null | tr -d '[:space:]')"
  if [ "$RG_RAW" = "true" ]; then
    RG_OK=passed; say "rg_check: GREEN"
  elif [ -z "$RG_RAW" ]; then
    # Unreachable backend must not wedge the lane; phases 1-2 still stand.
    RG_OK=unreachable; say "rg_check: UNREACHABLE (network/auth) — not treated as red"
  else
    RG_OK=failed; FAILED_PHASES+=("rg_check")
    say "rg_check: RED — rebaseline intentional schema changes first"
  fi
else
  say "rg_check: deferred to scripts/rg_after_deploy.sh (CHANGE #273)"
fi

# ── PHASE 4: the RPC-budget guards (CHANGE #641) ───────────────────────────
# Cheap (~1 s), and the one class of regression that took the whole fleet down
# for eleven hours. It runs on EVERY self-test, not only in the two-hourly
# rg_check, so it fails the command that caused it. An unreachable backend is
# never treated as red.
rule; say "PHASE 4/4 — RPC budget guards (CHANGE #641)"
CFS_OUT="$(bash "$(dirname "$0")/test_complete_fast_speed.sh" 2>&1)"; CFS_RC=$?
say "$CFS_OUT"
if [ "$CFS_RC" -eq 1 ]; then
  FAILED_PHASES+=("rpc_budget")
  say "rpc budget: RED — an HTTP RPC is doing heavy work again"
elif [ "$CFS_RC" -eq 2 ]; then
  say "rpc budget: UNREACHABLE (network/auth) — not treated as red"
else
  say "rpc budget: GREEN"
fi

rm -f "$LOG"
rule

# ── VERDICT ────────────────────────────────────────────────────────────────
OK=true
[ ${#FAILED_PHASES[@]} -gt 0 ] && OK=false

# Record the run so the completion gate can prove tests actually ran.
# Best-effort: a reporting outage must never turn a GREEN build red.
if [ -n "$CMD_ID" ]; then
  "$DEVCMD" rpc selftest_report "$(jq -nc \
      --argjson id "$CMD_ID" --argjson ok "$OK" \
      --arg p "$PROTECTED_OK" --arg f "$FOCUS_OK" --arg r "$RG_OK" \
      --arg c "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      --arg files "${FOCUS_FILES[*]:-}" \
      '{p_command_id:$id,p_ok:$ok,p_detail:{protected:$p,focused:$f,rg:$r,commit:$c,focus_files:$files}}')" \
    >/dev/null 2>&1 || say "warn: selftest_report did not record (continuing)"
else
  "$DEVCMD" rpc selftest_report "$(jq -nc --argjson ok "$OK" \
      --arg p "$PROTECTED_OK" --arg f "$FOCUS_OK" --arg r "$RG_OK" \
      --arg c "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      '{p_ok:$ok,p_detail:{protected:$p,focused:$f,rg:$r,commit:$c}}')" \
    >/dev/null 2>&1 || say "warn: selftest_report did not record (continuing)"
fi

if [ "$OK" = "true" ]; then
  rm -f "$ATTEMPT_FILE"
  say "GREEN — protected=$PROTECTED_OK focused=$FOCUS_OK rg=$RG_OK. Deploy may proceed."
  exit 0
fi

# ── RED ────────────────────────────────────────────────────────────────────
ATTEMPTS=$(( $(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$ATTEMPTS" > "$ATTEMPT_FILE"
say "RED — failed phase(s): ${FAILED_PHASES[*]} (attempt $ATTEMPTS of $ATTEMPT_CAP)"

if [ "$ATTEMPTS" -ge "$ATTEMPT_CAP" ] && [ -n "$CMD_ID" ]; then
  say "attempt cap reached — filing qa_report(failed) and stopping. NOT deploying."
  "$DEVCMD" rpc qa_report "$(jq -nc --argjson id "$CMD_ID" \
      --arg ph "${FAILED_PHASES[*]}" --argjson n "$ATTEMPTS" \
      '{p_command_id:$id,p_verdict:"failed",p_findings:[{
          title:"Self-test gate red after \($n) in-session attempts",
          detail:"Failed phase(s): \($ph). The build was NOT deployed.",
          severity:"high"}]}')" >/dev/null 2>&1 || true
  exit 2
fi

say "fix the failure(s) in THIS session and re-run scripts/selftest.sh. Do NOT deploy."
exit 1

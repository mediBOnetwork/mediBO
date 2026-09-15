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

# ── CMD #1973: THE GREEN RECEIPT — one suite run per tree, not per caller ───
# This gate is called twice for every direct deploy: once by direct_deploy.sh as
# its own prep phase, and once by deploy.sh, which calls it as a hard gate before
# it builds. Both ran the full protected suite on the SAME bytes, so every ship
# paid six minutes twice — and until CMD #1973 the second six minutes were spent
# inside the deploy lock.
#
# The fix is NOT a skip flag. #222 is explicit that an opt-out is how a gate
# quietly stops being a gate, and this keeps that: there is no env escape hatch
# and no --skip. The receipt is CONTENT-ADDRESSED — it records that this exact
# tree (HEAD's tree, plus any uncommitted diff, plus untracked test/lib files,
# plus the Flutter SDK it would run on) was green, and it is only ever written
# by a real green run of these phases. A reuse therefore asserts exactly what a
# re-run would have asserted. Any byte that differs is a different tree and a
# different receipt, so the suite runs.
RECEIPT_DIR="$STATE_DIR/work/selftest-green"
RECEIPT_TTL_S="${SELFTEST_RECEIPT_TTL_S:-21600}"   # 6 h — a tree is only worth trusting for a session
_tree_id() {
  { git rev-parse 'HEAD^{tree}' 2>/dev/null || echo no-git
    git diff HEAD 2>/dev/null
    cat "$HOME/flutter/version" 2>/dev/null
    git ls-files --others --exclude-standard -- lib test 2>/dev/null | sort | while IFS= read -r f; do
      [ -f "$f" ] && sha256sum "$f"
    done
  } | sha256sum | cut -c1-40
}
TREE_ID="$(_tree_id)"
RECEIPT="$RECEIPT_DIR/$TREE_ID"
REUSED=0
if [ -f "$RECEIPT" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$RECEIPT" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$RECEIPT_TTL_S" ]; then
    REUSED=1
    say "green receipt for tree $TREE_ID (${age}s old) — phases 1 and 2 were run on these exact bytes: $(cat "$RECEIPT" 2>/dev/null | head -1)"
  else
    say "green receipt for tree $TREE_ID is ${age}s old (> ${RECEIPT_TTL_S}s) — running the suite again"
    rm -f "$RECEIPT"
  fi
fi

# ── PHASE 1: the protected regression suite ────────────────────────────────
#
# CMD #1974 — THE 900 s WALL WAS MANUFACTURING RED SUITES.
# This box runs a worker POOL, and nothing stopped four preps from running
# `flutter test test/protected/` at the same time. At load 13 with no swap a
# 5-minute suite stretches to 15, `timeout 900` then killed flutter_tools
# mid-stream, and the harness died printing
#   loading <whatever file was next> [E]
#   Bad state: Cannot close sink while adding stream
#       package:flutter_tools/src/test/flutter_platform.dart  _startTest
# — so the gate reported a REGRESSION, naming an innocent test file, on trees
# whose only change was one SQL migration. #1947 died on
# customer360_stock_test.dart at 14:29 and #1974 on wa_campaigns_screen_test.dart
# at 14:52: different files, same wall, and both files pass on their own.
#
# Three things, in order of how much they matter:
#   1. QUEUE, don't collide — the suite takes a fleet-wide flock, so the
#      contention that tripled the runtime does not happen. The wait is bounded
#      (`-w`) and failing to get the lock is NOT fatal: it runs anyway, because a
#      gate that can be blocked by a stale lock file has stopped being a gate.
#   2. A wall a contended run still fits inside.
#   3. Say TIMED OUT when it times out. A timeout is not a regression, and the
#      file named in the output is the victim, not the cause.
SELFTEST_PROTECTED_TIMEOUT_S="${SELFTEST_PROTECTED_TIMEOUT_S:-1500}"
SELFTEST_SEM_WAIT_S="${SELFTEST_SEM_WAIT_S:-1200}"
SELFTEST_SEM="${SELFTEST_SEM:-$HOME/mediBO-runner/.selftest.sem}"

rule; say "PHASE 1/4 — protected suite (flutter test test/protected/)"
if [ "$REUSED" = "1" ]; then
  PROTECTED_OK=reused
  say "protected: REUSED — green on this exact tree, see the receipt above"
else
  _prc=0
  _sem_held=0
  ( flock -w "$SELFTEST_SEM_WAIT_S" 9 && echo "selftest: suite semaphore held" \
      || echo "selftest: suite semaphore busy for ${SELFTEST_SEM_WAIT_S}s — running anyway"
    timeout "$SELFTEST_PROTECTED_TIMEOUT_S" flutter test test/protected/
  ) >"$LOG" 2>&1 9>"$SELFTEST_SEM" || _prc=$?
  grep -q 'semaphore held' "$LOG" && _sem_held=1
  if [ "$_prc" = 0 ]; then
    PROTECTED_OK=passed
    say "protected: PASSED — $(grep -oE '\+[0-9]+' "$LOG" | tail -1 | tr -d '+') tests$([ "$_sem_held" = 1 ] || echo ' (semaphore not held — the box was busy)')"
  elif [ "$_prc" = 124 ]; then
    PROTECTED_OK=failed
    FAILED_PHASES+=("protected")
    say "protected: TIMED OUT after ${SELFTEST_PROTECTED_TIMEOUT_S}s — a contended box, NOT a regression. The file named below is the one that was loading when the harness was killed; it is the victim. Re-run the deploy."
    tail -40 "$LOG"
  else
    PROTECTED_OK=failed
    FAILED_PHASES+=("protected")
    say "protected: FAILED"
    tail -40 "$LOG"
  fi
fi

# ── PHASE 2: this command's own focused test(s) ────────────────────────────
# Auto-detected so a builder never has to remember to wire it: every changed or
# new *_test.dart outside test/protected/ (already covered by phase 1).
rule; say "PHASE 2/4 — focused test(s) for this change"
FOCUS_FILES=()
if [ "$REUSED" = "1" ]; then
  FOCUS_OK=reused
  say "focused: REUSED — the receipt covers phase 2 on this tree as well"
elif [ ${#FOCUS_ARGS[@]} -gt 0 ]; then
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

if [ "$REUSED" = "1" ]; then
  :
elif [ ${#FOCUS_FILES[@]} -eq 0 ]; then
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
  # CMD #1973 — bank the receipt, but only for a run that actually executed the
  # suite. A reused run must never refresh its own receipt: that would turn a
  # 6-hour TTL into an unbounded one, one deploy at a time.
  if [ "$PROTECTED_OK" = "passed" ]; then
    mkdir -p "$RECEIPT_DIR" 2>/dev/null || true
    printf 'tree=%s green_at=%s repo=%s commit=%s protected=%s focused=%s\n' \
      "$TREE_ID" "$(date -u +%FT%TZ)" "$MEDIBO_REPO" \
      "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      "$PROTECTED_OK" "$FOCUS_OK" > "$RECEIPT" 2>/dev/null || true
    # keep the shelf small: receipts are worthless once their tree is gone
    find "$RECEIPT_DIR" -type f -mmin +1440 -delete 2>/dev/null || true
  fi
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

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# post_deploy_checks.sh — everything a finished deploy still owes, and NOTHING
# that needs the deploy lock.  (CMD #1973)
#
# Until #1973 this block lived inline at the end of deploy.sh's upload phase,
# which means it ran while direct_deploy.sh was still holding deploy_lock.
# Measured on CHANGE #1333: the lock was held 890s, and 12m of that was here —
# the disk prune, a SECOND verify_live.sh (direct_deploy runs its own as the
# verdict), the regression guard, and a `timeout 900` responsive sweep that
# renders the top screens at five widths against the LIVE site. None of it can
# change what shipped: the bundle is already on the edge and the live-assert
# has already passed. Every one of these steps only reads production.
#
# So the lane no longer pays for them. deploy.sh runs this itself on a normal
# `all`/`upload` run; direct_deploy.sh sets MEDIBO_DEFER_POST=1 and calls this
# script AFTER deploy_lock_release, so the next command in the register starts
# its own upload while these run.
#
# Usage:  bash scripts/post_deploy_checks.sh [command-id]
# Never fails the caller — the deploy is live; these write verdicts.
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "${MEDIBO_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/mediBO")}" || exit 0
CMD_ID="${1:-${DEPLOY_CMD_ID:-}}"

echo "[post-deploy] running the lock-free checks in $(pwd)"

# ── SELF-PRUNE — stop disk creeping between nightly cleanups ────────────────
# build/ is deliberately NOT deleted: build/web is git-tracked, so removing it
# leaves main dirty with ~71 deletions and the NEXT deploy's `git pull --ff-only`
# refuses to run.
#
# .dart_tool is gitignored and safe to drop — but dropping it forces the next
# build to be a full one, and after #1973 the next build is INCREMENTAL by
# design. So it is dropped only when the disk actually needs it; a healthy box
# keeps the incremental state it just paid to produce.
git worktree prune 2>/dev/null || true
FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
PRUNE_BELOW_MB="${MEDIBO_PRUNE_DART_TOOL_BELOW_MB:-8192}"
if [ "$FREE_MB" -lt "$PRUNE_BELOW_MB" ]; then
  rm -rf "$(pwd)/.dart_tool" 2>/dev/null || true
  FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
  echo "[self-prune] .dart_tool dropped (disk was under ${PRUNE_BELOW_MB}MB) — free ${FREE_MB}MB"
else
  echo "[self-prune] worktrees pruned; .dart_tool kept for the next incremental build — free ${FREE_MB}MB"
fi
if [ "$FREE_MB" -lt 2048 ]; then
  echo "[self-prune] under 2GB — invoking cleanup_vm.sh"
  # cleanup_vm.sh is lock-aware. If the caller gave us a lock token, hand it
  # straight through: without it cleanup would either see lane_busy=true and
  # skip, or try to take a lock we are already holding.
  DEPLOY_LOCK_TOKEN="${DEPLOY_LOCK_TOKEN:-}" bash scripts/cleanup_vm.sh \
    || echo "⚠️   cleanup_vm.sh returned non-zero (the deploy itself is fine)"
fi

# The verdict. direct_deploy.sh runs its own verify_live.sh under the lock, so
# it sets MEDIBO_SKIP_VERIFY_LIVE=1 here rather than paying for it twice.
if [ "${MEDIBO_SKIP_VERIFY_LIVE:-0}" != "1" ]; then
  bash scripts/verify_live.sh || true
fi

# CHANGE #273: the schema/RPC guard runs AFTER the bundle is live, not in the
# pre-build gate. It never fails the deploy (the bundle already shipped);
# dev_cmd_complete() is what refuses a red guard.
bash scripts/rg_after_deploy.sh "$CMD_ID" || true

# CMD #1950: MOBILE-FIRST. 99% of mediBO users are on phones, so every deploy
# re-proves the phone layout. Neither step can fail a deploy that is already
# live — they write a VERDICT, and rg_check's behaviour tests
# (mobile_first_rule_present / responsive_no_overflow) are what turn red.
bash scripts/mobile_first_check.sh || true
# CMD #2075: the feature-journey gate must stay wired end to end (rule, gate
# condition, prompt line, devcmd door, preview + live hooks, runner). Writes the
# verdict rg_check's feature_journey_rule_present asserts.
bash scripts/feature_journey_check.sh || true

# CMD #2018 — the rule that decides what the sweep is allowed to call a failure
# had a test (CMD #2012) that nothing ever ran. It needs no browser and no
# network; run it where the sweep runs, so a broken rule is loud instead of
# silently turning the guard red on the next unreadable screen.
node scripts/test_responsive_verdict.js \
  || echo "⚠️   responsive verdict rule is broken — scripts/lib/responsive_verdict.js"
if [ "${MEDIBO_SKIP_RESPONSIVE_SWEEP:-0}" != "1" ]; then
  timeout 900 node scripts/responsive_sweep.js --quiet \
    || echo "⚠️   responsive sweep reported a phone-layout problem — see rg_runner_verdict"
fi

echo "[post-deploy] lock-free checks done"
exit 0

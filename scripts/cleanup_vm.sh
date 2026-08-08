#!/bin/bash
# cleanup_vm.sh — parallel-safe VM disk reclaimer.
#
# Runs nightly from cron (03:30 IST) and opportunistically from deploy.sh when
# free disk drops below 2 GB. Its entire job is to delete things that can be
# regenerated, and to refuse — loudly and early — to touch anything that cannot.
#
# WHY THIS IS SAFE TO RUN WHILE OTHER AGENTS ARE WORKING
# ------------------------------------------------------
# Several Claude Code agents share this VM, each in its own git worktree, each
# possibly mid-build or mid-deploy. Three rules make concurrent execution safe:
#
#   RULE A  A worktree is deleted only when it is provably dead. Every check
#           below must pass; a single failure means SKIP. Skipping is always
#           correct — tomorrow's run gets another chance.
#   RULE B  Destructive work happens under the Postgres deploy lock, never bare.
#   RULE C  Only our own build artefacts are removed (~/mediBO). Another agent's
#           worktree build/ directory is off limits — deleting it mid-build
#           corrupts their deploy.
#
# TOKEN PASSTHROUGH: deploy.sh already holds the deploy lock when it calls us.
# Re-locking would deadlock, so it exports DEPLOY_LOCK_TOKEN and we then neither
# acquire nor release the lock — the caller owns its lifecycle.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/flutter/bin"
REPO="$HOME/mediBO"
WTROOT="$REPO/.claude/worktrees"
LOG="$HOME/cleanup.log"
JKS="$HOME/medibo-release.jks"
KEYPROPS="$HOME/medibo-key.properties"
SUPA_URL="https://swojhmarmaijkshsbeih.supabase.co"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

trim_log() {
  [ -f "$LOG" ] || return 0
  tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

free_mb()  { df -Pm / | awk 'NR==2{print $4}'; }
total_mb() { df -Pm / | awk 'NR==2{print $2}'; }
wt_count() { git -C "$REPO" worktree list 2>/dev/null | wc -l; }

# The anon key is public and RLS-protected; it is read from the app config so it
# can never drift out of sync. The service_role key is deliberately NOT on this
# machine (removed 2026-08-06) and must not be reintroduced — every RPC used
# here is SECURITY DEFINER and executable by anon.
anon_key() {
  grep -A2 'static const String anonKey' "$REPO/lib/supabase_config.dart" 2>/dev/null \
    | grep -oE "eyJ[A-Za-z0-9_.=-]+" | head -1
}

rpc() { # rpc <function> <json-body>
  local fn="$1" body="$2" key
  key="$(anon_key)"
  [ -z "$key" ] && { log "WARN: anon key unreadable — skipping RPC $fn"; return 1; }
  curl -sf --max-time 20 -X POST "$SUPA_URL/rest/v1/rpc/$fn" \
    -H "apikey: $key" -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" --data "$body" 2>/dev/null
}

# ── GUARD 1: the irreplaceable files ────────────────────────────────────────
# The release keystore cannot be regenerated. Losing it means no future APK can
# ever install over an already-installed app. Refuse to delete anything at all
# until both files are confirmed present.
if [ ! -f "$JKS" ] || [ ! -f "$KEYPROPS" ]; then
  log "ABORT: keystore missing (jks=$([ -f "$JKS" ] && echo ok || echo MISSING) props=$([ -f "$KEYPROPS" ] && echo ok || echo MISSING)) — refusing to delete anything"
  trim_log
  exit 1
fi

BEFORE=$(free_mb)
log "=== cleanup start — free ${BEFORE}MB, worktrees $(wt_count) ==="

# ── GUARD 2: never fight a deploy (RULE B) ──────────────────────────────────
OWN_TOKEN="${DEPLOY_LOCK_TOKEN:-}"
TOKEN=""
RELEASE_LOCK=0

if [ -n "$OWN_TOKEN" ]; then
  # Caller (deploy.sh) already holds the lock; do not re-lock, do not release.
  TOKEN="$OWN_TOKEN"
  log "using caller-supplied deploy lock token (no re-lock)"
else
  STATUS="$(rpc deploy_status '{}' || true)"
  if printf '%s' "$STATUS" | grep -q '"lane_busy"[[:space:]]*:[[:space:]]*true'; then
    log "skipped: lane busy"
    trim_log
    exit 0
  fi
  LOCK="$(rpc deploy_lock_try '{"p_agent":"cron-cleanup","p_title":"nightly disk cleanup","p_ttl_minutes":20}' || true)"
  TOKEN="$(printf '%s' "$LOCK" | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | grep -oE '[0-9a-f-]{36}' | head -1)"
  if [ -z "$TOKEN" ]; then
    log "skipped: could not take deploy lock"
    trim_log
    exit 0
  fi
  RELEASE_LOCK=1
  log "deploy lock acquired"
fi

release_lock() {
  [ "$RELEASE_LOCK" = "1" ] && [ -n "$TOKEN" ] || return 0
  rpc deploy_lock_release "{\"p_token\":\"$TOKEN\",\"p_change_no\":null,\"p_commit\":null,\"p_status\":\"released\"}" >/dev/null || true
  log "deploy lock released"
}
trap 'release_lock; trim_log' EXIT

# ── STEP 1: prune dead worktrees (RULE A) ───────────────────────────────────
REMOVED=0; SKIPPED=0
if [ -d "$WTROOT" ]; then
  git -C "$REPO" fetch --prune origin >/dev/null 2>&1 || log "WARN: git fetch failed — merged-ness may be stale"

  # One lsof pass over the whole tree, not one per worktree: 140 recursive lsof
  # calls take tens of minutes, a single pass takes seconds.
  INUSE="$(timeout 120 lsof +D "$WTROOT" 2>/dev/null | awk 'NR>1{print $NF}' | sed "s|^$WTROOT/||" | cut -d/ -f1 | sort -u || true)"
  # A process whose cwd sits in a worktree holds it just as surely as an open fd.
  CWDS="$(for p in /proc/[0-9]*; do t=$(readlink "$p/cwd" 2>/dev/null) || continue
          case "$t" in "$WTROOT"/*) printf '%s\n' "${t#$WTROOT/}" | cut -d/ -f1;; esac
        done | sort -u)"
  LOCKED="$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{p=$2} /^locked/{print p}')"
  NOW=$(date +%s)

  while IFS=' ' read -r path ref; do
    [ -z "$path" ] && continue
    name="$(basename "$path")"
    br="${ref#refs/heads/}"

    # Never the main working tree.
    [ "$path" = "$REPO" ] && continue

    # git-locked means a claude session claimed it. Honour the claim.
    if printf '%s\n' "$LOCKED" | grep -qxF "$path"; then
      log "SKIPPED $name (git-locked)"; SKIPPED=$((SKIPPED+1)); continue
    fi
    # Held open by a live process.
    if printf '%s\n' "$INUSE" | grep -qxF "$name" || printf '%s\n' "$CWDS" | grep -qxF "$name"; then
      log "SKIPPED $name (in use by a running process)"; SKIPPED=$((SKIPPED+1)); continue
    fi
    # Touched in the last hour — an agent is probably mid-task.
    mt=$(stat -c %Y "$path" 2>/dev/null || echo "$NOW")
    age=$(( (NOW - mt) / 60 ))
    if [ "$age" -lt 60 ]; then
      log "SKIPPED $name (modified ${age}min ago)"; SKIPPED=$((SKIPPED+1)); continue
    fi
    # Uncommitted work. build/ is excluded deliberately: deploy.sh commits
    # build/web, so a worktree that merely ran `flutter clean` shows ~50 tracked
    # deletions under build/ and would otherwise look "dirty" forever — that
    # single detail is why every worktree on this VM was uncleanable.
    if [ -n "$(git -C "$path" status --porcelain 2>/dev/null | grep -v -E '^.. build/')" ]; then
      log "SKIPPED $name (uncommitted source work)"; SKIPPED=$((SKIPPED+1)); continue
    fi
    # Only remove branches whose work has landed on origin/main. A branch that
    # is merely absent from origin may hold unpushed commits, so it stays.
    if ! git -C "$REPO" merge-base --is-ancestor "$br" origin/main 2>/dev/null; then
      log "SKIPPED $name (branch $br not merged into origin/main)"; SKIPPED=$((SKIPPED+1)); continue
    fi

    if git -C "$REPO" worktree remove "$path" --force >/dev/null 2>&1; then
      log "REMOVED $name (merged: $br)"; REMOVED=$((REMOVED+1))
    else
      log "SKIPPED $name (worktree remove failed)"; SKIPPED=$((SKIPPED+1))
    fi
  done <<<"$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{p=$2} /^branch /{print p" "$2}')"

  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  # Only branches already merged into origin/main, and never one still checked
  # out in a surviving worktree.
  git -C "$REPO" branch --merged origin/main --format='%(refname:short) %(worktreepath)' 2>/dev/null \
    | while IFS=' ' read -r b wt; do
        [ "$b" = "main" ] && continue
        [ -n "$wt" ] && continue
        git -C "$REPO" branch -D "$b" >/dev/null 2>&1 || true
      done
fi

# ── STEP 2: our own build artefacts only (RULE C) ───────────────────────────
# Guarded on "no build is running": deleting .dart_tool or the Gradle cache out
# from under a live flutter/gradle process corrupts that build.
if pgrep -f "dart|flutter" >/dev/null 2>&1; then
  log "SKIPPED .dart_tool (a dart/flutter process is running)"
else
  rm -rf "$REPO/.dart_tool" 2>/dev/null || true
fi
if pgrep -f "GradleDaemon|gradle" >/dev/null 2>&1; then
  log "SKIPPED gradle caches (a gradle process is running)"
else
  # transforms is the runaway one (4.3 GB observed); modules-2 is kept because
  # it is downloaded dependencies and expensive to refetch.
  rm -rf "$HOME/.gradle/caches"/*/transforms "$HOME/.gradle/caches"/build-cache-* \
         "$HOME/.gradle/daemon" 2>/dev/null || true
  rm -rf "$REPO/android/.gradle" "$REPO/android/app/build" "$REPO/android/build" 2>/dev/null || true
fi
# NOTE: $REPO/build is NOT deleted here. build/web is git-tracked, so removing it
# leaves main dirty with ~71 deletions, which makes the next deploy's
# `git pull --ff-only` refuse. deploy.sh runs `flutter clean` itself anyway.

# ── STEP 3: caches and stray release artefacts ──────────────────────────────
# APKs are hosted in Supabase Storage (bucket app-releases), never served from
# the VM, so a local copy is always a leftover.
find "$HOME" -maxdepth 3 \( -name '*.apk' -o -name '*.aab' \) -type f -delete 2>/dev/null || true
rm -rf "$HOME/.cache/pip" "$HOME/.cache/puppeteer" "$HOME/.npm/_cacache" 2>/dev/null || true
if sudo -n true 2>/dev/null; then
  sudo -n apt-get clean >/dev/null 2>&1 || true
  sudo -n journalctl --vacuum-size=100M >/dev/null 2>&1 || true
fi

# ── STEP 4: report ──────────────────────────────────────────────────────────
AFTER=$(free_mb); TOTAL=$(total_mb); WT=$(wt_count)
rpc vm_disk_report "{\"p_free_mb\":$AFTER,\"p_total_mb\":$TOTAL,\"p_worktrees\":$WT,\"p_host\":\"medibo\"}" >/dev/null \
  || log "WARN: vm_disk_report failed"
log "=== cleanup done — free ${BEFORE}MB -> ${AFTER}MB, removed ${REMOVED}, skipped ${SKIPPED}, worktrees ${WT} ==="

exit 0

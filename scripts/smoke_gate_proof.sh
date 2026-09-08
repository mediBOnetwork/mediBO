#!/usr/bin/env bash
# CHANGE #1823 — PROOF THAT A RED CRITICAL PATH FAILS THE BATCH AND DEPLOYS NOTHING.
#
# Before this change every batch ended "critical-path smoke could not run
# (exit 2) — not treated as a failure": the run found two real reds, crashed
# on a duplicate-key in test_result_report, and shipped. The gate now runs on a
# Pages preview of the built bundle BEFORE the production upload, and a red or
# crashed smoke fails the batch with nothing uploaded. This script proves it
# with a tree that is knowingly red AT THE SMOKE: the app boots and paints, but
# RenderLog drops the c325_deep_link key, so the three deep-link journeys of the
# critical path (admin.khata, cust.my_account, identity.logout) wait for a
# render-log key that never comes and fail. Batch 619 (6 Sep) taught why the red
# must boot: a tree whose index.html never loaded flutter_bootstrap.js was
# stopped by deploy.sh's OWN boot gate before the smoke ever ran — "no smoke
# verdict recorded", which proves nothing about the gate under test.
#
#   bash scripts/smoke_gate_proof.sh           # run it (≈8-12 min: one full build)
#   bash scripts/smoke_gate_proof.sh --keep    # leave the proof branch behind
#
# It needs the lane IDLE (queue empty, no batch in flight): the merge worker
# batches a proof branch ALONE (merge_worker.sh, CHANGE #1823) — with company
# it is evicted and this script re-pushes it, so a real command can never be
# sunk by the proof's red.
#
# Asserts, in order:
#   A. the queue entry ends FAILED (never deployed)
#   B. the batch's smoke verdict is 'failed' and its sentence says "not deployed"
#   C. the batch itself is recorded failed with the smoke as the reason
#   D. https://medibo.in/version.json is byte-identical before and after
set -uo pipefail
D="$HOME/mediBO-runner/devcmd.sh"
REPO="${MEDIBO_REPO:-$HOME/mediBO}"
KEEP="${1:-}"
T0=$(date +%s)
j() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d'"$1"')' 2>/dev/null; }
say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { say "FAIL — $*"; exit 1; }

say "── precondition: the lane must be idle ─────────────────────────────────"
QS="$("$D" queue_status)"
waiting=$(j '["queue"]["count"]' <<<"$QS"); inflight=$(j '["batch"]' <<<"$QS")
if [ "${waiting:-1}" != "0" ] || [ "$inflight" != "None" ]; then
  say "lane busy: $waiting waiting, batch in flight: ${inflight:0:80}"
  say "run this when the lane is idle (exit 2)"; exit 2
fi

BEFORE="$(curl -fsS --max-time 15 "https://medibo.in/version.json?cb=$RANDOM" || true)"
[ -n "$BEFORE" ] || fail "could not read https://medibo.in/version.json before the run"
say "live before: $BEFORE"

say "── the knowingly red tree ─────────────────────────────────────────────"
BR="proof-smoke-red-$(date +%s)"
BASE=$(git -C "$REPO" rev-parse --verify -q refs/heads/deployed || git -C "$REPO" rev-parse main)
WT=$(mktemp -d /tmp/smoke-proof.XXXXXX)
git -C "$REPO" worktree add -q "$WT" -b "$BR" "$BASE" || fail "could not create the proof worktree"
RL="$WT/lib/utils/render_log.dart"
MARK='smoke-gate proof: deliberately red'
python3 - "$RL" "$MARK" <<'PY' || fail "render_log.dart did not take the red edit"
import sys
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
sig = '  static void write(String key, dynamic value) {\n'
assert sig in s, 'RenderLog.write signature not found'
s = s.replace(sig, sig + "    if (key == 'c325_deep_link') return; // " + mark + "\n", 1)
open(p, 'w').write(s)
PY
grep -q "$MARK" "$RL" || fail "render_log.dart did not take the red edit"
git -C "$WT" commit -q -am "smoke-gate proof: deliberately red — the deep-link render-log key is never written" || fail "commit failed"
SHA=$(git -C "$WT" rev-parse --short HEAD)
git -C "$REPO" worktree remove --force "$WT"
say "branch $BR @ $SHA (boots and paints; c325_deep_link never written — the deep-link journeys go red)"

push() {
  local out; out=$("$D" queue_push null smoke-gate-proof "[smoke-gate proof] deliberately red critical path" "$BR" "$SHA")
  ENTRY=$(j '["entry_id"]' <<<"$out")
  [ -n "$ENTRY" ] && [ "$ENTRY" != "None" ] || fail "queue_push did not return an entry: ${out:0:200}"
  say "queued as entry $ENTRY"
}
push

say "── waiting for the merge worker (build + preview + smoke ≈ 8-12 min) ───"
deadline=$(( $(date +%s) + 2700 ))
status=""; batch_id=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  E="$("$D" rpc deploy_queue_entry "$(jq -nc --argjson i "$ENTRY" '{p_id:$i}')" 2>/dev/null || echo '{}')"
  status=$(j '["entry"]["status"]' <<<"$E"); [ -n "$status" ] || status=$(j '["status"]' <<<"$E")
  batch_id=$(j '["batch"]["id"]' <<<"$E")
  case "$status" in
    deployed|failed) break ;;
    evicted)
      reason=$(j '["entry"]["reason"]' <<<"$E")
      say "evicted ($reason) — the lane had company; re-pushing"
      sleep 60; push ;;
  esac
  sleep 30
done
say "entry $ENTRY ended '$status' in batch ${batch_id:-?} after $(( $(date +%s) - T0 ))s"

say "── assertions ─────────────────────────────────────────────────────────"
ok=1
if [ "$status" = "failed" ]; then say "A ✓ entry recorded FAILED"; else say "A ✗ entry is '$status' (wanted failed)"; ok=0; fi

LS="$("$D" rpc deploy_lane_status '{}')"
sv=$(j '["smoke"]["verdict"]' <<<"$LS"); sb=$(j '["smoke"]["batch_id"]' <<<"$LS"); sl=$(j '["smoke"]["label"]' <<<"$LS")
if [ "$sv" = "failed" ] && [ "$sb" = "$batch_id" ] && [[ "$sl" == *"not deployed"* ]]; then
  say "B ✓ smoke verdict on batch $sb: $sl"
else
  say "B ✗ smoke block: verdict=$sv batch=$sb label=$sl"; ok=0
fi

E="$("$D" rpc deploy_queue_entry "$(jq -nc --argjson i "$ENTRY" '{p_id:$i}')" 2>/dev/null || echo '{}')"
bs=$(j '["batch"]["status"]' <<<"$E"); bn=$(j '["batch"]["note"]' <<<"$E")
if [ "$bs" = "failed" ] && [[ "$bn" == *smoke* ]]; then say "C ✓ batch $batch_id failed: $bn"; else say "C ✗ batch status=$bs note=$bn"; ok=0; fi

AFTER="$(curl -fsS --max-time 15 "https://medibo.in/version.json?cb=$RANDOM" || true)"
if [ "$AFTER" = "$BEFORE" ]; then say "D ✓ live unchanged: $AFTER"; else say "D ✗ live moved: $BEFORE → $AFTER"; ok=0; fi

if [ "$KEEP" != "--keep" ]; then git -C "$REPO" branch -D "$BR" >/dev/null 2>&1 || true; fi
if [ "$ok" = "1" ]; then say "PASS — a red critical path failed the batch and deployed nothing ($(( $(date +%s) - T0 ))s)"; exit 0; fi
say "FAIL — see the ✗ lines above"; exit 1

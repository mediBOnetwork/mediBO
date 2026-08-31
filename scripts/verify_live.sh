#!/usr/bin/env bash
# verify_live.sh — autonomous post-deploy verification for mediBO
# Usage: bash scripts/verify_live.sh [COMMIT_HASH]
#
# Exit codes:
#   0 = VERIFIED: version.json matches + render-log shows boot_status=painted
#   1 = BROKEN: HTTP check failed (deploy did not land or app is broken)
#   2 = DEPLOYED BUT UNCONFIRMED: HTTP passed but render-log not yet updated
#       (no browser has loaded the new build yet — not a failure)
#   3 = NOT THIS TREE: the site is healthy and fully live, but on a DIFFERENT
#       commit than this checkout. Since CHANGE #324 the merge worker deploys
#       from its OWN worktree (~/medibo-merge), so a runner's local HEAD is
#       almost never the deployed commit — that is normal, not a broken site.
#       Still non-zero, so the merge worker (whose tree MUST be the live one)
#       keeps refusing to stamp deployed_at on a mismatch.

set -euo pipefail

COMMIT="${1:-}"

# Auto-detect commit from version.json in the local build if not passed.
if [ -z "$COMMIT" ]; then
  COMMIT=$(python3 -c "import json,sys; print(json.load(open('build/web/version.json'))['commit'])" 2>/dev/null || true)
fi

# Fall back to current git HEAD.
if [ -z "$COMMIT" ]; then
  COMMIT=$(git rev-parse HEAD 2>/dev/null || true)
fi

if [ -z "$COMMIT" ]; then
  echo "ERROR: could not determine commit hash — pass it as the first argument"
  exit 1
fi

BASE_URL="https://medibo.in"

echo "=== verify_live.sh: target commit=${COMMIT} ==="
echo ""

# ── Step 1: fingerprinted bundle must be 200 + full size (>1 MB) ────────────
# C353 fix: bundles are fingerprinted (main.<commit>.dart.js); the legacy
# /main.dart.js path now returns the SPA shell and always failed this check.
echo "→ [1/3] checking main.${COMMIT}.dart.js..."
# CHANGE #602: retry. Immediately after a deploy an edge node can serve a
# PARTIAL response — #601 read 71,561b for a bundle that is 7,873,501b — and a
# verifier that fails on healthy deploys trains you to ignore it.
HTTP_CODE=""; SIZE=0
for attempt in 1 2 3 4 5 6; do
  RESULT=$(curl -s -H 'Cache-Control: no-cache' -o /dev/null \
             -w "%{http_code} %{size_download}" \
             "${BASE_URL}/main.${COMMIT}.dart.js?cb=${RANDOM}${attempt}" || echo "000 0")
  HTTP_CODE=$(echo "$RESULT" | cut -d' ' -f1)
  SIZE=$(echo "$RESULT" | cut -d' ' -f2)
  { [ "$HTTP_CODE" = "200" ] && [ "${SIZE:-0}" -ge 1000000 ]; } && break
  echo "   poll ${attempt}/6: http=${HTTP_CODE} size=${SIZE}b — edge may still be propagating…"
  sleep 10
done
if [ "$HTTP_CODE" != "200" ] || [ "${SIZE:-0}" -lt 1000000 ]; then
  echo "   FAIL: main.dart.js http=${HTTP_CODE} size=${SIZE}b (need 200 + >1 MB) after 6 tries"
  echo ""
  # CHANGE #324 — tell "the site is broken" apart from "this is not the tree
  # that shipped". The merge worker deploys from its own worktree, so a runner
  # running this by hand in ~/mediBO asks the edge for a fingerprint that was
  # never uploaded and gets the SPA shell (71 kB) six times — which read as
  # BROKEN on a perfectly healthy site, and a verifier that cries wolf is a
  # verifier people stop reading. Only after the propagation retries are
  # exhausted do we ask what IS live, and only a bundle that is genuinely
  # healthy on another commit downgrades the verdict.
  LIVE_OTHER=$(curl -s -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                 "${BASE_URL}/version.json?cb=${RANDOM}" 2>/dev/null \
               | python3 -c "import json,sys; print(json.load(sys.stdin).get('commit',''))" \
               2>/dev/null || true)
  if [ -n "$LIVE_OTHER" ] && [ "$LIVE_OTHER" != "$COMMIT" ]; then
    OTHER=$(curl -s -H 'Cache-Control: no-cache' -o /dev/null \
              -w "%{http_code} %{size_download}" \
              "${BASE_URL}/main.${LIVE_OTHER}.dart.js?cb=${RANDOM}" || echo "000 0")
    OTHER_CODE=$(echo "$OTHER" | cut -d' ' -f1)
    OTHER_SIZE=$(echo "$OTHER" | cut -d' ' -f2)
    if [ "$OTHER_CODE" = "200" ] && [ "${OTHER_SIZE:-0}" -ge 1000000 ]; then
      echo "   live commit is ${LIVE_OTHER} and ITS bundle is healthy"
      echo "     (http=${OTHER_CODE} size=${OTHER_SIZE}b)"
      echo ""
      echo "=== RESULT: NOT THIS TREE (site healthy on ${LIVE_OTHER}, this checkout is ${COMMIT}) ==="
      echo "    The site is fine. This checkout simply is not what shipped —"
      echo "    since #324 the merge worker deploys from ~/medibo-merge."
      echo "    To verify the LIVE build: bash scripts/verify_live.sh ${LIVE_OTHER}"
      exit 3
    fi
  fi
  echo "=== RESULT: BROKEN (HTTP check failed) ==="
  exit 1
fi
echo "   OK: http=${HTTP_CODE} size=${SIZE}b"

# ── Step 2: version.json commit must match ───────────────────────────────────
#
# CHANGE #590: cache-bust and retry. This fetched version.json with no
# cache-buster immediately after a deploy, so it regularly read a STALE edge
# copy and reported "BROKEN (wrong commit live)" for a deploy that was fine —
# exactly what happened on CHANGE #583, seconds after live-assert had passed.
# A verifier that cries wolf gets ignored, which is how a real stale deploy
# slips through.
echo "→ [2/3] checking version.json..."
LIVE_COMMIT=""
for attempt in 1 2 3 4 5 6; do
  LIVE_COMMIT=$(curl -s -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                  "${BASE_URL}/version.json?cb=${RANDOM}${attempt}" \
                | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('commit',''))" 2>/dev/null || echo "")
  [ "$LIVE_COMMIT" = "$COMMIT" ] && break
  echo "   poll ${attempt}/6: live='${LIVE_COMMIT}' want='${COMMIT}' — edge may still be propagating…"
  sleep 10
done
if [ "$LIVE_COMMIT" != "$COMMIT" ]; then
  echo "   FAIL: version.json shows commit=${LIVE_COMMIT}, expected ${COMMIT} after 6 tries"
  echo ""
  echo "=== RESULT: BROKEN (wrong commit live) ==="
  exit 1
fi
echo "   OK: version.json commit=${LIVE_COMMIT}"

# ── Step 3: poll render-log for build=COMMIT + boot_status=painted ──────────
echo "→ [3/3] polling render-log (12 × 15 s = 3 min max)..."
MAX_POLLS=12
POLL=0
while [ $POLL -lt $MAX_POLLS ]; do
  LOG=$(curl -s "${BASE_URL}/render-log" 2>/dev/null || echo "")
  BUILD_IN_LOG=$(echo "$LOG" | grep "^build=" | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
  BOOT_STATUS=$(echo "$LOG" | grep "^boot_status=" | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)

  echo "   poll $((POLL+1))/${MAX_POLLS}: build=${BUILD_IN_LOG:-<none>} boot_status=${BOOT_STATUS:-<none>}"

  if [ "$BUILD_IN_LOG" = "$COMMIT" ] && [ "$BOOT_STATUS" = "painted" ]; then
    echo ""
    echo "=== VERIFIED LIVE ==="
    echo "    commit      : ${COMMIT}"
    echo "    build_hash  : ${BUILD_IN_LOG}"
    echo "    boot_status : ${BOOT_STATUS}"
    exit 0
  fi

  POLL=$((POLL+1))
  if [ $POLL -lt $MAX_POLLS ]; then
    sleep 15
  fi
done

echo ""
echo "=== DEPLOYED BUT UNCONFIRMED ==="
echo "    commit      : ${COMMIT}"
echo "    build on log: ${BUILD_IN_LOG:-<none>}"
echo "    boot_status : ${BOOT_STATUS:-<none>}"
echo ""
echo "HTTP + version.json PASSED — the correct build is live."
echo "render-log still shows the previous session (no real browser has loaded yet)."
echo "This is NOT a failure. Ask Om to open medibo.in, then re-run this script."
exit 2

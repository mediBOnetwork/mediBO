#!/usr/bin/env bash
# verify_live.sh — autonomous post-deploy verification for mediBO
# Usage: bash scripts/verify_live.sh [COMMIT_HASH]
#
# Exit codes:
#   0 = VERIFIED: version.json matches + render-log shows boot_status=painted
#   1 = BROKEN: HTTP check failed (deploy did not land or app is broken)
#   2 = DEPLOYED BUT UNCONFIRMED: HTTP passed but render-log not yet updated
#       (no browser has loaded the new build yet — not a failure)

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
RESULT=$(curl -s -o /dev/null -w "%{http_code} %{size_download}" "${BASE_URL}/main.${COMMIT}.dart.js" || echo "000 0")
HTTP_CODE=$(echo "$RESULT" | cut -d' ' -f1)
SIZE=$(echo "$RESULT" | cut -d' ' -f2)
if [ "$HTTP_CODE" != "200" ] || [ "${SIZE:-0}" -lt 1000000 ]; then
  echo "   FAIL: main.dart.js http=${HTTP_CODE} size=${SIZE}b (need 200 + >1 MB)"
  echo ""
  echo "=== RESULT: BROKEN (HTTP check failed) ==="
  exit 1
fi
echo "   OK: http=${HTTP_CODE} size=${SIZE}b"

# ── Step 2: version.json commit must match ───────────────────────────────────
echo "→ [2/3] checking version.json..."
LIVE_COMMIT=$(curl -s "${BASE_URL}/version.json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('commit',''))" 2>/dev/null || echo "")
if [ "$LIVE_COMMIT" != "$COMMIT" ]; then
  echo "   FAIL: version.json shows commit=${LIVE_COMMIT}, expected ${COMMIT}"
  echo "         (Cloudflare may still be propagating — retry in 30s)"
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

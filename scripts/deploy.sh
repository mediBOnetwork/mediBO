#!/bin/bash
# CHANGE #583 — THE deploy script, versioned with the code it deploys.
#
# This lived at ~/deploy.sh, outside git, which meant the fix for the
# stale-alias trap (#582) was one `rm` away from being lost and no reviewer
# could see it. ~/deploy.sh is now a thin wrapper that execs this file.
set -euo pipefail
cd ~/mediBO
export PATH="$PATH:$HOME/flutter/bin"

# ── Load Cloudflare token (required for wrangler direct upload) ──────────────
if [ ! -f ~/.medibo/cf.env ]; then
  echo "❌  ~/.medibo/cf.env missing — run: mkdir -p ~/.medibo && echo 'export CLOUDFLARE_API_TOKEN=<token>' > ~/.medibo/cf.env && chmod 600 ~/.medibo/cf.env"
  exit 1
fi
set -a; source ~/.medibo/cf.env; set +a
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "❌  CLOUDFLARE_API_TOKEN not set in ~/.medibo/cf.env"
  exit 1
fi

# ── CHANGE #424: PULL-FIRST GUARD — never build/commit/push on a stale local
# main. If a PR was merged on GitHub since the last deploy, this incorporates
# it instead of a later force-push silently erasing it (see #422 incident).
# NOTE (#425): plain --ff-only (no --rebase) is deliberate — `pull --rebase`
# forces git's rebase dirty-tree precondition even in the trivial "already
# up to date" case, which broke deploy.sh's normal flow of building/committing
# uncommitted source edits still sitting in the working tree.
git fetch origin --prune
if ! git pull --ff-only origin main; then
  echo "❌  DEPLOY ABORTED: local main is behind or diverged from origin/main."
  echo "    A PR may have been merged on GitHub. Resolve with: git fetch origin && git rebase origin/main"
  exit 1
fi

# ── CHANGE #424: dynamic CHANGE #N — kills the hardcoded/stale-label trap.
# Pass it explicitly: ./deploy.sh 424.
#
# CHANGE #531 FIX: the no-arg path used to REUSE the number already stamped in
# web/version.json, so every argument-less deploy re-published the same CHANGE #
# (two separate deploys both went out as "530" on 2026-07-25 — indistinguishable
# in history and in the live version.json). The fallback now AUTO-INCREMENTS the
# last stamped value, so each deploy gets a unique number whether or not an
# explicit N is passed.
if [ -n "${1:-}" ]; then
  N="$1"
else
  LAST_N=$(grep -o '"change"[^0-9]*[0-9]\+' web/version.json | grep -o '[0-9]\+' | tail -1)
  if [ -n "$LAST_N" ]; then
    N=$((LAST_N + 1))
    echo "[change] no N given — auto-incrementing ${LAST_N} → ${N}"
  else
    N=""
  fi
fi
if [ -z "$N" ]; then
  echo "❌  DEPLOY ABORTED: no CHANGE #N given and none found in web/version.json."
  echo "    Run: ./deploy.sh <N>"
  exit 1
fi
python3 -c "
import json
d = json.load(open('web/version.json'))
d['change'] = '${N}'
json.dump(d, open('web/version.json', 'w'))
"
CHANGE_LABEL="$N"

# Build release — flutter clean is MANDATORY: skipping it produces a corrupt dart2js
# bundle (different byte count, fails to boot) even with identical source code.
flutter clean
flutter build web --release
# NOTE: the downloadable Android APK is NOT bundled here. At 82 MB it exceeds
# Cloudflare Pages' 25 MB-per-file limit, so it is hosted on Supabase Storage
# (public bucket app-releases) and its URL is published via app_release_publish
# / returned by app_update_check. Nothing to copy into build/web at deploy time.
cp web/_redirects build/web/_redirects
cp web/_headers  build/web/_headers
cp web/_routes.json build/web/_routes.json

# Commit first so HEAD reflects the new state
git add -A
git commit -m "CHANGE #${N}: deploy" || echo "nothing to commit (continuing)"

# Capture the just-made commit hash
SHORT=$(git rev-parse --short HEAD)
BUILT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WEB="build/web"

echo "Build fingerprint: $SHORT ($BUILT)"

# ── CHANGE #58: Fingerprint the bundle ──────────────────────────────────────
# Rename main.dart.js → main.<commit>.dart.js so its URL is unique per deploy.
# No browser cache, CDN, or SW can serve the old file under this new URL.
if [ -f "$WEB/main.dart.js" ]; then
  H="main.$SHORT.dart.js"
  mv "$WEB/main.dart.js" "$WEB/$H"
  # Rewrite every reference in bootstrap + index
  for f in "$WEB/flutter_bootstrap.js" "$WEB/index.html"; do
    [ -f "$f" ] && sed -i "s#main\.dart\.js#$H#g" "$f"
  done
  # Rename sourcemap if present
  if [ -f "$WEB/main.dart.js.map" ]; then
    mv "$WEB/main.dart.js.map" "$WEB/$H.map"
    sed -i "s#main\.dart\.js\.map#$H.map#g" "$WEB/$H"
  fi
  echo "[deploy] fingerprinted -> $H"
else
  echo "[deploy] WARN: main.dart.js not found in build output"
fi

# ── CHANGE #240: write kill-SW to build output (overwrite Flutter's generated version) ──
cat > "$WEB/flutter_service_worker.js" << 'SWEOF'
// mediBO self-destruct service worker — unregisters itself and purges all caches.
// c409_sw_autoupdate: clients.claim() so an activating instance takes control of
// already-open tabs immediately, making the forced client.navigate() below reach
// every open tab reliably.
self.addEventListener('install', function (e) { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil((async function () {
    try {
      await self.clients.claim();
    } catch (err) {}
    try {
      var keys = await caches.keys();
      await Promise.all(keys.map(function (k) { return caches.delete(k); }));
    } catch (err) {}
    try {
      await self.registration.unregister();
    } catch (err) {}
    try {
      var clients = await self.clients.matchAll({ type: 'window' });
      clients.forEach(function (c) { c.navigate(c.url); });
    } catch (err) {}
  })());
});
self.addEventListener('fetch', function (e) { return; });
SWEOF
if [ -f "$WEB/flutter_bootstrap.js" ]; then
  sed -i 's/"serviceWorkerVersion":[^,}]*/"serviceWorkerVersion":null/g' "$WEB/flutter_bootstrap.js" || true
fi
sed -i "s#navigator\.serviceWorker\.register('flutter_service_worker[^']*'[^)]*);##g" "$WEB/index.html" || true
echo "[deploy] kill-SW written to build output (self-unregisters on activate)"

# ── Stamp version.json ───────────────────────────────────────────────────────
cat > "$WEB/version.json" <<JSON
{"commit":"$SHORT","built":"$BUILT","change":"${CHANGE_LABEL}"}
JSON

# ── CHANGE #220: stamp build commit into index.html for PWA version check ───
sed -i "s|__MEDIBO_BUILD_COMMIT__|$SHORT|g" "$WEB/index.html"
sed -i "s|flutter_bootstrap\.js?v=[^\"'&]*|flutter_bootstrap.js?v=$SHORT|g" "$WEB/index.html"

# ── Inject <meta name="build-commit"> into index.html ───────────────────────
sed -i 's|<meta name="build-commit"[^>]*>||g' "$WEB/index.html"
sed -i "s|<head>|<head>\n  <meta name=\"build-commit\" content=\"$SHORT\">|" "$WEB/index.html"

# ── CHANGE #491: _headers comes ONLY from web/_headers (already cp'd above,
# line ~58) — the single source of truth: git-tracked, documented, and
# already hardened (max-age=86400+must-revalidate on the fingerprinted bundle,
# not `immutable` — see the "2026-07-13 outage" comment in web/_headers).
# This used to re-generate _headers here via a hardcoded heredoc that
# silently OVERWROTE the cp'd file (cat > truncates) with an older, less-safe
# ruleset — notably `immutable, max-age=31536000` on /*.dart.js, i.e. exactly
# the Fault-2 regression the hardening was meant to prevent. Confirmed live on
# medibo.in on 2026-07-15: every recently-deployed fingerprinted bundle was
# still being served `immutable, max-age=31536000` despite web/_headers
# saying otherwise, because this heredoc — not the cp — was what actually
# reached Cloudflare. The heredoc is gone; re-cp here is just cheap insurance
# against anything upstream touching the file between the two points.
cp web/_headers "$WEB/_headers"

# ── Guard: verify build output before boot gate ──────────────────────────────
echo "[guard] checking build output…"
if [ ! -f "$WEB/index.html" ]; then
  echo "❌  build/web/index.html missing — build failed"; exit 1
fi
if ! grep -q 'base href="/"' "$WEB/index.html" 2>/dev/null; then
  echo "❌  build/web/index.html missing base href='/' — wrong base-href or bad build"; exit 1
fi
BUNDLE="$WEB/main.$SHORT.dart.js"
if [ ! -f "$BUNDLE" ]; then
  echo "❌  $BUNDLE missing — fingerprint step failed"; exit 1
fi
BUNDLE_SIZE=$(wc -c < "$BUNDLE")
if [ "$BUNDLE_SIZE" -lt 1500000 ]; then
  echo "❌  $BUNDLE is only ${BUNDLE_SIZE} bytes — corrupt/partial build (must be >1.5MB). Run flutter clean and retry."; exit 1
fi
if [ ! -f "$WEB/assets/AssetManifest.bin" ] && [ ! -f "$WEB/assets/AssetManifest.json" ]; then
  echo "❌  build/web/assets/AssetManifest* missing — half-built assets dir"; exit 1
fi
LIVE_CHANGE=$(python3 -c "import json,sys; print(json.load(open('$WEB/version.json')).get('change',''))" 2>/dev/null || true)
if [ "$LIVE_CHANGE" != "$CHANGE_LABEL" ]; then
  echo "❌  build/web/version.json has '$LIVE_CHANGE', expected '$CHANGE_LABEL' — aborting"; exit 1
fi
# ── CHANGE #491: regression guard for the Fault-2 hardening (see cp comment
# above) — refuse to ship if _headers ever again lacks the hardened
# fingerprinted-bundle rule, or has `immutable` on it.
if ! grep -q '^/main\.\*\.dart\.js$' "$WEB/_headers"; then
  echo "❌  build/web/_headers missing the hardened /main.*.dart.js rule — aborting (would regress the 2026-07-13 outage fix)"; exit 1
fi
if grep -A1 '^/main\.\*\.dart\.js$' "$WEB/_headers" | grep -qi 'immutable'; then
  echo "❌  build/web/_headers has 'immutable' on the fingerprinted-bundle rule — this is the exact Fault-2 regression, aborting"; exit 1
fi
echo "[guard] index.html ✓  bundle=${BUNDLE_SIZE}b ✓  assets ✓  version=${CHANGE_LABEL} ✓  headers ✓"

# ── Boot gate — reject corrupt bundles BEFORE they reach production ──────────
echo "[boot-gate] running bundle validation…"
if ! node ~/boot_check.js "$WEB" 2>&1; then
  echo "❌  BOOT GATE FAILED — bundle would hang on load. NOT deploying. Fix the build and retry."
  exit 1
fi
echo "[boot-gate] PASSED — bundle is safe to deploy"

# ── Amend git commit with fingerprinted artifacts (background history only) ─
cp web/_redirects "$WEB/_redirects"
cp web/_routes.json "$WEB/_routes.json"
git add "$WEB/version.json" "$WEB/index.html" "$WEB/flutter_bootstrap.js" "$WEB/_redirects" "$WEB/_routes.json"
git add functions/_middleware.js 2>/dev/null || true
git add "$WEB/main.$SHORT.dart.js" 2>/dev/null || true
git add "$WEB/main.$SHORT.dart.js.map" 2>/dev/null || true
git add "$WEB/flutter_service_worker.js" 2>/dev/null || true
git commit --amend --no-edit

# ── LIVE DEPLOY: wrangler Direct Upload — bypasses Cloudflare Pages git queue ──
echo ""
echo "⬆  Uploading build/web to Cloudflare Pages (project=medibo, branch=main)…"
DEPLOY_START=$(date +%s)
WRANGLER_OUTPUT=$(npx wrangler pages deploy "$WEB" \
  --project-name=medibo \
  --branch=main \
  --commit-dirty=true 2>&1)
DEPLOY_STATUS=$?
echo "$WRANGLER_OUTPUT"
DEPLOY_END=$(date +%s)
DEPLOY_SECS=$((DEPLOY_END - DEPLOY_START))

if [ $DEPLOY_STATUS -ne 0 ]; then
  echo "❌  wrangler deploy failed (exit $DEPLOY_STATUS)"
  exit 1
fi

DEPLOY_URL=$(echo "$WRANGLER_OUTPUT" | grep -oE 'https://[a-z0-9-]+\.medibo(-[0-9a-z]+)?\.pages\.dev[^ ]*' | head -1 || true)

# ── Cache purge — MUST succeed. A silently-failing purge lets a bad response
# cached as `immutable` (main.*.dart.js, see web/_headers) survive at that edge
# node for a full year with no way to clear it. This is what caused the
# 2026-07-13 outage: this block was using $CLOUDFLARE_API_TOKEN (the
# Pages/Wrangler-scoped token from ~/.medibo/cf.env) instead of the dedicated
# $CF_API_TOKEN from ~/.medibo_secrets, so the purge silently failed on every
# deploy (code 10000, "Authentication error") for days without anyone noticing.
[ -f ~/.medibo_secrets ] && . ~/.medibo_secrets
if [ -z "${CF_ZONE_ID:-}" ] || [ -z "${CF_API_TOKEN:-}" ]; then
  echo "❌  CACHE PURGE SKIPPED — CF_ZONE_ID or CF_API_TOKEN missing from ~/.medibo_secrets."
  echo "    The site IS already live via wrangler, but edge caches were not purged."
  echo "    Fix ~/.medibo_secrets (needs a token with Zone -> Cache Purge -> Purge"
  echo "    permission for the medibo.in zone) before trusting this deploy is live everywhere."
  exit 1
fi
PURGE_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"purge_everything":true}')
PURGE_OK=$(echo "$PURGE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('success') else 'fail')" 2>/dev/null || echo "fail")
if [ "$PURGE_OK" = "ok" ]; then
  echo "[purge] ok"
else
  echo "❌  CACHE PURGE FAILED — response: $PURGE_RESP"
  echo "    The site IS already live via wrangler, but edge caches were not purged."
  echo "    A stale/bad response cached as immutable at any edge node will NOT clear on its own."
  echo "    Fix the Cloudflare token/zone in ~/.medibo_secrets before trusting this deploy."
  exit 1
fi

# ── CHANGE #424: git push — NEVER --force. If origin/main moved since the
# pull-first guard above (another deploy raced in), abort loudly instead of
# clobbering it. The site is already live via wrangler at this point, so a
# push failure here means "reconcile git, don't re-run blindly" — not a
# failed deploy.
if ! git push origin main; then
  echo "❌  DEPLOY ABORTED (git only — site is already live): push rejected, origin/main moved."
  echo "    Run: git pull --rebase origin main, then re-run ./deploy.sh ${N} to sync history."
  exit 1
fi
echo "[git] pushed $SHORT to origin"

# ── CHANGE #582: RE-UPLOAD AFTER THE PUSH — the stale-alias trap.
#
# This project is Git-connected ("Git Provider: Yes"). Pushing to main starts
# Cloudflare's OWN Pages build, and that build FAILS every time (it has no
# Flutter toolchain). The wrangler direct upload above had already produced a
# good Production deployment — but the failing Git build lands AFTER it and
# leaves medibo.in pinned to the last successful build.
#
# Symptom this caused: deploy reported success, version.json on the preview URL
# showed the new change, and medibo.in silently kept serving the previous one.
# CHANGE #570 sat live while #572 and #581 both reported "deployed".
#
# Fix: upload once more AFTER the push, so the last Production deployment for
# this project is always ours, not Cloudflare's failed build.
echo ""
echo "⬆  Re-uploading after git push (beats the failing Git-triggered build)…"
npx wrangler pages deploy "$WEB" \
  --project-name=medibo \
  --branch=main \
  --commit-dirty=true >/dev/null 2>&1 \
  && echo "[reupload] ok" \
  || echo "⚠️   re-upload failed — check medibo.in/version.json before trusting this deploy"

# ── Poll version.json until live (max 90s — wrangler is fast) ───────────────
echo "Waiting for propagation…"
MAX=9
DELAY=10
for i in $(seq 1 $MAX); do
  LIVE=$(curl -sf --max-time 8 "https://medibo.in/version.json" 2>/dev/null \
         | python3 -c "import sys,json; print(json.load(sys.stdin).get('commit',''))" 2>/dev/null || true)
  if [ "$LIVE" = "$SHORT" ]; then
    echo ""
    echo "✅  DEPLOYED ${CHANGE_LABEL} via wrangler in ${DEPLOY_SECS}s → ${DEPLOY_URL:-medibo.in}"
    echo "✅  live version.json commit = $SHORT"

    # ── §3.2 Live boot assert ──────────────────────────────────────────────
    # Retry up to 3x with 5s gaps because different CF edge nodes propagate at
    # slightly different speeds (version.json can be live before bootstrap).
    echo "[live-assert] verifying edge serves the NEW bundle…"
    IDX_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://medibo.in/)
    BS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://medibo.in/flutter_bootstrap.js?cb=${RANDOM}")
    MAIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://medibo.in/main.${SHORT}.dart.js")
    # CHANGE #604: retry. version.json propagates PER EDGE NODE — the poll loop
    # above can succeed on one node while this check hits another that is still
    # serving the old copy. #603 failed exactly that way on a healthy deploy.
    LIVE_CHANGE_CHECK=""
    for _vc in 1 2 3 4 5; do
      LIVE_CHANGE_CHECK=$(curl -sf --max-time 8 -H 'Cache-Control: no-cache' \
        "https://medibo.in/version.json?cb=${RANDOM}${_vc}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('change',''))" 2>/dev/null || true)
      [ "$LIVE_CHANGE_CHECK" = "$CHANGE_LABEL" ] && break
      [ "$_vc" -lt 5 ] && sleep 6
    done
    # Confirm the live flutter_bootstrap.js references the NEW bundle — retry 3x
    LIVE_BUNDLE_REF=""
    for _bsr in 1 2 3; do
      # CHANGE #600: cache-bust. Without it this reads a CACHED bootstrap and
      # fails a healthy deploy — exactly what happened on #599, where
      # version.json already showed the new commit.
      LIVE_BUNDLE_REF=$(curl -s -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "https://medibo.in/flutter_bootstrap.js?cb=${RANDOM}${_bsr}" 2>/dev/null \
        | grep -o "main\.[a-f0-9]*\.dart\.js" | head -1 || true)
      [ "$LIVE_BUNDLE_REF" = "main.${SHORT}.dart.js" ] && break
      [ "$_bsr" -lt 3 ] && sleep 5
    done
    SHELL_CC=$(curl -sI https://medibo.in/ | grep -i "cache-control" | head -1 | tr -d '\r')
    MAIN_CC=$(curl -sI "https://medibo.in/main.${SHORT}.dart.js" | grep -i "cache-control" | head -1 | tr -d '\r')

    ASSERT_FAIL=0
    [ "$IDX_CODE"   != "200" ] && { echo "❌  live-assert: index=$IDX_CODE (want 200)"; ASSERT_FAIL=1; }
    [ "$BS_CODE"    != "200" ] && { echo "❌  live-assert: flutter_bootstrap.js=$BS_CODE (want 200)"; ASSERT_FAIL=1; }
    [ "$MAIN_CODE"  != "200" ] && { echo "❌  live-assert: main.${SHORT}.dart.js=$MAIN_CODE (want 200)"; ASSERT_FAIL=1; }
    [ "$LIVE_BUNDLE_REF" != "main.${SHORT}.dart.js" ] && {
      echo "❌  live-assert: live bootstrap refs '$LIVE_BUNDLE_REF' but we built 'main.${SHORT}.dart.js' — stale/preview bundle on edge"
      ASSERT_FAIL=1
    }
    [ "$LIVE_CHANGE_CHECK" != "$CHANGE_LABEL" ] && {
      echo "❌  live-assert: version.json change='$LIVE_CHANGE_CHECK' but built '$CHANGE_LABEL'"
      ASSERT_FAIL=1
    }
    if [ "$ASSERT_FAIL" -eq 1 ]; then
      echo "❌  LIVE ASSERT FAILED — deploy may have gone to preview or stale CDN. Investigate."
      exit 1
    fi

    echo "[live-assert] index=${IDX_CODE} bootstrap=${BS_CODE} main=${MAIN_CODE} ✓"
    echo "[live-assert] live bundle ref = ${LIVE_BUNDLE_REF} ✓"
    echo "[live-assert] version change = ${LIVE_CHANGE_CHECK} ✓"
    echo "[live-assert] shell cache: ${SHELL_CC}"
    echo "[live-assert] bundle cache: ${MAIN_CC}"

    # ── Update lastgood.txt ────────────────────────────────────────────────
    mkdir -p ~/.medibo
    echo "commit=${SHORT} size=${BUNDLE_SIZE} change=${CHANGE_LABEL} built=${BUILT}" > ~/.medibo/lastgood.txt
    echo "[lastgood] updated: commit=${SHORT} size=${BUNDLE_SIZE}"

    bash scripts/verify_live.sh
    exit 0
  fi
  echo "  poll $i/$MAX: live='$LIVE', want='$SHORT' — retrying in ${DELAY}s…"
  sleep $DELAY
done

# ── CHANGE #583: the timeout path is a FAILURE, not a warning ──────────────
#
# This used to `exit 2` — "deployed but unconfirmed". That is precisely the
# state that let CHANGE #570 sit live while #572 and #581 both reported
# success: the upload worked, the alias never moved, and the script shrugged.
# A deploy that cannot prove the live alias matches the commit it just built
# has not deployed.
echo ""
echo "❌  DEPLOY FAILED: version.json never matched the uploaded commit."
LIVE_NOW=$(curl -sf --max-time 8 "https://medibo.in/version.json" 2>/dev/null || echo '{}')
echo "    wanted commit : $SHORT (change ${CHANGE_LABEL})"
echo "    live serving  : $LIVE_NOW"
echo "    preview url   : ${DEPLOY_URL:-?}"
echo ""
echo "    The upload succeeded but the LIVE ALIAS did not move. Most likely the"
echo "    Git-connected Pages build (which fails — no Flutter toolchain) landed"
echo "    after the wrangler upload and pinned the alias to the last good build."
echo "    Re-run this script; it re-uploads after the push to win that race."
exit 1

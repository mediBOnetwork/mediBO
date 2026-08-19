#!/usr/bin/env bash
# publish_play.sh — build, sign, upload, describe and SUBMIT a mediBO release to
# Google Play, with no manual step anywhere in the chain.
#
#   bash scripts/publish_play.sh              # drain one queued play_release row
#   bash scripts/publish_play.sh --now        # queue one for this build and run it
#   bash scripts/publish_play.sh --now --track internal --draft   # rehearsal
#
# CHANGE #280. Before this, shipping meant: build an AAB by hand, open the Play
# Console, upload it, type release notes, click through the review dialog, then
# separately build an APK and insert the app_releases row so in-app phones see
# the same version. Every one of those steps is below.
#
# THE CHAIN
#   1. credential + keystore preflight (both from the Vault, never from disk)
#   2. version: next code = (highest code Play has EVER seen) + 1 — never reused
#   3. signed AAB, then the #278 gates: 16 KB page alignment + the full ABI set
#   4. signing-certificate gate: the artifact must carry the upload cert Play
#      expects for in.medibo.app, or the upload is refused HERE, not by Play
#   5. Play: upload bundle → en-US release notes → full rollout → commit
#   6. APK for the direct-download channel + the app_releases row
#   7. every stage written back to play_release, so the app renders progress
#
# FAIL LOUDLY. A wrong signing key, a duplicate version code and a Play
# rejection each stop the run, mark the row 'failed', and store Play's own error
# body verbatim. There is no "continue anyway" path and nothing is ever asked.
#
# SECRETS. PLAY_PUBLISHER_JSON is materialised into a chmod-600 file on /dev/shm
# (tmpfs — never touches the disk) and shredded by the EXIT trap on every path.
# Nothing here echoes key material, and the Play error bodies it does print
# contain the request, never the credential.
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
DEVCMD="$HOME/mediBO-runner/devcmd.sh"
RUNNER="$HOME/mediBO-runner"
LOG="${PLAY_LOG:-$RUNNER/play_publish.log}"

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$HOME/flutter/bin:$PATH"

# The upload certificate Play expects for in.medibo.app. An artifact signed with
# anything else CANNOT be published to this listing — CHANGE #276/#277 were the
# rescue mission that recovered this exact key, so the check is a hard gate.
EXPECT_SHA1="CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55"
ABIS="arm64-v8a,armeabi-v7a,x86_64"       # the full 3-ABI bundle from #278

TRACK="production"; MODE="serve"; DRAFT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now)     MODE="now" ;;
    --track)   TRACK="${2:?--track needs a value}"; shift ;;
    --draft)   DRAFT="--draft" ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "publish_play: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
tail_log() { tail -c 2000 "$LOG" 2>/dev/null; }

SA=""; REL_ID=""
cleanup() { [ -n "$SA" ] && { shred -u "$SA" 2>/dev/null || rm -f "$SA"; }; }
trap cleanup EXIT

# progress <status> <json-patch>
progress() {
  [ -z "$REL_ID" ] && return 0
  jq -nc --argjson id "$REL_ID" --arg s "$1" --argjson p "${2:-{\}}" \
     '{p_id:$id,p_status:$s,p_patch:$p}' > /dev/shm/.play_prog.$$
  "$DEVCMD" rpc play_publish_progress "$(cat /dev/shm/.play_prog.$$)" >/dev/null 2>&1
  rm -f /dev/shm/.play_prog.$$
}

# die <human-message> [play-error-body]
die() {
  local msg="$1" body="${2:-}"
  log "FAILED: $msg"
  [ -n "$body" ] && log "$body"
  if [ -n "$REL_ID" ]; then
    jq -nc --argjson id "$REL_ID" \
       --arg e "$msg${body:+
$body}" --arg t "$(tail_log)" \
       '{p_id:$id,p_ok:false,p_patch:{play_error:$e,log_tail:$t}}' > /dev/shm/.play_fin.$$
    "$DEVCMD" rpc play_publish_finish "$(cat /dev/shm/.play_fin.$$)" >/dev/null 2>&1
    rm -f /dev/shm/.play_fin.$$
  fi
  echo "{\"ok\":false,\"error\":$(jq -Rs . <<<"$msg")}"
  exit 1
}

# ── 0. the queue row ────────────────────────────────────────────────────────
if [ "$MODE" = "now" ]; then
  q=$("$DEVCMD" rpc play_publish_request "$(jq -nc --arg t "$TRACK" '{p_track:$t}')")
  [ "$(jq -r '.ok' <<<"$q")" = "true" ] || { echo "$q"; exit 1; }
fi
claim=$("$DEVCMD" rpc play_publish_claim '{"p_worker":"publish_play.sh"}')
if [ "$(jq -r '.empty // false' <<<"$claim")" = "true" ]; then
  log "no queued release — nothing to do"; echo '{"ok":true,"idle":true}'; exit 0
fi
REL_ID=$(jq -r '.id' <<<"$claim")
TRACK=$(jq -r '.track' <<<"$claim")
NOTES_FILE=$(mktemp /dev/shm/notes.XXXX)
jq -r '.release_notes // ""' <<<"$claim" > "$NOTES_FILE"
log "── play_release #$REL_ID → track $TRACK ──"

# ── 1. credential + keystore ────────────────────────────────────────────────
umask 077
SA=$(mktemp /dev/shm/play_sa.XXXX.json)
"$DEVCMD" rpc secret_get_runner '{"p_name":"PLAY_PUBLISHER_JSON"}' \
  | jq -r 'if type=="string" then . else empty end' > "$SA"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["type"]=="service_account"' "$SA" 2>/dev/null \
  || die "PLAY_PUBLISHER_JSON is missing or not a service-account key. Store it with secret_set and re-run."

if [ ! -f android/key.properties ]; then
  log "key.properties absent — restoring the upload keystore from the Vault"
  bash "$RUNNER/restore_keystore.sh" >>"$LOG" 2>&1 \
    || die "cannot restore the upload keystore from the Vault (ANDROID_UPLOAD_KEYSTORE_B64)"
fi
STORE=$(sed -n 's/^storeFile=//p' android/key.properties | head -1)
ALIAS=$(sed -n 's/^keyAlias=//p'  android/key.properties | head -1)
KS_SHA1=$(keytool -list -v -keystore "android/$STORE" -alias "$ALIAS" \
            -storepass "$(sed -n 's/^storePassword=//p' android/key.properties | head -1)" 2>/dev/null \
          | sed -n 's/.*SHA1: //p' | head -1)
[ -n "$KS_SHA1" ] || die "the upload keystore is unreadable (wrong alias or store password)"
[ "$KS_SHA1" = "$EXPECT_SHA1" ] \
  || die "WRONG SIGNING KEY: keystore SHA-1 $KS_SHA1 is not the upload certificate Play expects for in.medibo.app ($EXPECT_SHA1). Refusing to build an unpublishable artifact."
log "upload key verified ($KS_SHA1)"

# ── 2. version — never reuse a code ─────────────────────────────────────────
progress building '{}'
MAX=$(python3 scripts/play_publish.py maxcode --sa "$SA" 2>/dev/null | jq -r '.highest_version_code // empty')
[ -n "$MAX" ] || die "could not read the published version codes from Play (see the log for the API error)"
CODE=$((MAX + 1))

CUR_CODE=$(grep -oP 'versionCode = \K\d+' android/app/build.gradle.kts | head -1)
CUR_NAME=$(grep -oP 'versionName = "\K[^"]+' android/app/build.gradle.kts | head -1)
if [ "$CUR_CODE" = "$CODE" ]; then
  # Someone (a previous command) already staged exactly this release — keep the
  # name they chose rather than renaming their work.
  NAME="$CUR_NAME"
else
  # Bump the patch of the name in the tree — it is never behind what Play has,
  # and the code above already came from Play's own answer.
  IFS=. read -r MA MI PA <<<"$CUR_NAME"
  PA=$(( ${PA:-0} + 1 ))
  NAME="${MA:-1}.${MI:-0}.$PA"
fi
log "version: $NAME ($CODE)   [Play's highest so far: $MAX; tree: $CUR_NAME ($CUR_CODE)]"
progress building "$(jq -nc --arg n "$NAME" --argjson c "$CODE" '{version_name:$n,version_code:($c|tostring)}')"

# versionCode lives in TWO files and they must stay in lockstep — the in-app
# updater compares the backend's latest code against kAndroidVersionCode.
sed -i "s/versionCode = .*/versionCode = $CODE/; s/versionName = \".*\"/versionName = \"$NAME\"/" \
  android/app/build.gradle.kts
sed -i "s/const int kAndroidVersionCode = .*/const int kAndroidVersionCode = $CODE;/" \
  lib/services/android_update_check.dart
grep -q "versionCode = $CODE" android/app/build.gradle.kts \
  && grep -q "kAndroidVersionCode = $CODE;" lib/services/android_update_check.dart \
  || die "version bump did not apply to both files — refusing to build out of lockstep"

# ── 3. the signed bundle + the #278 gates ───────────────────────────────────
AAB="build/app/outputs/bundle/release/app-release.aab"
rm -f "$AAB"
mkdir -p /dev/shm/gtmp
log "flutter build appbundle --release …"
if ! flutter build appbundle --release >>"$LOG" 2>&1; then
  die "the AAB build failed" "$(tail -c 2500 "$LOG")"
fi
[ -f "$AAB" ] || die "the build produced no AAB"
AAB_BYTES=$(stat -c%s "$AAB")
log "AAB $AAB ($AAB_BYTES bytes)"

# Play refuses an upload whose 64-bit .so are aligned below 16384, and warns when
# a release supports fewer devices than the last one. Both are properties of the
# artifact, so they are asserted on the artifact (#278).
python3 scripts/check_16kb.py "$AAB" --abis "$ABIS" >>"$LOG" 2>&1 \
  || die "16 KB page-size / ABI gate failed on the AAB" "$(tail -c 1500 "$LOG")"
log "16 KB + ABI gate passed ($ABIS)"

# The bundle is signed with the release config; prove it is THE upload key.
AAB_SHA1=$(keytool -printcert -jarfile "$AAB" 2>/dev/null | sed -n 's/.*SHA1: //p' | head -1)
[ -n "$AAB_SHA1" ] || die "the AAB is unsigned — refusing to upload"
[ "$AAB_SHA1" = "$EXPECT_SHA1" ] \
  || die "WRONG SIGNING KEY on the built AAB: $AAB_SHA1 (expected $EXPECT_SHA1). Play would reject this upload."
log "AAB signature verified against the upload certificate"

# ── 4. Play: upload → notes → full rollout → commit ─────────────────────────
progress uploading "$(jq -nc --argjson b "$AAB_BYTES" '{aab_bytes:($b|tostring)}')"
log "uploading to Play (track $TRACK)…"
OUT=$(mktemp /dev/shm/play_out.XXXX); ERR=$(mktemp /dev/shm/play_err.XXXX)
if ! python3 scripts/play_publish.py publish --sa "$SA" --aab "$AAB" \
        --notes-file "$NOTES_FILE" --track "$TRACK" $DRAFT >"$OUT" 2>"$ERR"; then
  BODY=$(cat "$ERR"); rm -f "$OUT" "$ERR"
  die "Google Play rejected the release" "$BODY"
fi
PLAY_CODE=$(jq -r '.version_code' "$OUT")
EDIT_ID=$(jq -r '.committed_edit // ""' "$OUT")
REVIEW=$(jq -r '[.track_state.releases[]? | "\(.status): \(.name // "")"] | join("; ")' "$OUT")
NOTES=$(cat "$NOTES_FILE")
log "Play accepted version code $PLAY_CODE on $TRACK — $REVIEW"
cat "$OUT" >> "$LOG"; rm -f "$OUT" "$ERR"

[ "$PLAY_CODE" = "$CODE" ] \
  || log "note: Play reported code $PLAY_CODE for an artifact built as $CODE"

# ── 5. the APK channel + the app_releases row ───────────────────────────────
# The direct-download APK is arm64-only (~38 MB); a fat APK is ~110 MB and these
# are pharmacies on mobile data.
APK="build/app/outputs/flutter-apk/app-release.apk"
APK_URL=""
rm -f "$APK"
log "flutter build apk --release --target-platform android-arm64 …"
if flutter build apk --release --target-platform android-arm64 >>"$LOG" 2>&1 && [ -f "$APK" ]; then
  if python3 scripts/check_16kb.py "$APK" --abis arm64-v8a >>"$LOG" 2>&1; then
    source "$RUNNER/runner.env"
    P="medibo-$NAME.apk"
    if curl -fsS -X POST "$SUPABASE_URL/storage/v1/object/app-releases/$P" \
         -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
         -H "Content-Type: application/vnd.android.package-archive" \
         -H "x-upsert: true" --data-binary "@$APK" >>"$LOG" 2>&1; then
      APK_URL="$SUPABASE_URL/storage/v1/object/public/app-releases/$P"
      log "APK published → $APK_URL"
    else
      log "WARNING: APK upload failed; the Play release still stands"
    fi
  else
    log "WARNING: the APK failed the 16 KB gate; not publishing it"
  fi
else
  log "WARNING: the APK build failed; the Play release still stands"
fi

# play_publish_finish writes the app_releases row itself, so the in-app reminder
# serves exactly the version Play just took.
jq -nc --argjson id "$REL_ID" --arg n "$NAME" --arg c "$PLAY_CODE" --arg u "$APK_URL" \
   --arg e "$EDIT_ID" --arg r "$REVIEW" --arg t "$(tail_log)" --arg no "$NOTES" \
   '{p_id:$id,p_ok:true,p_patch:({version_name:$n,version_code:$c,edit_id:$e,
      review_status:$r,release_notes:$no,log_tail:$t}
      + (if $u=="" then {} else {apk_url:$u} end))}' > /dev/shm/.play_fin.$$
"$DEVCMD" rpc play_publish_finish "$(cat /dev/shm/.play_fin.$$)" >/dev/null
rm -f /dev/shm/.play_fin.$$ "$NOTES_FILE"

# ── 6. the report ───────────────────────────────────────────────────────────
jq -nc --argjson id "$REL_ID" --arg n "$NAME" --arg c "$PLAY_CODE" --arg tr "$TRACK" \
   --arg r "$REVIEW" --arg u "$APK_URL" --arg no "$NOTES" \
   '{ok:true,release_id:$id,version_name:$n,version_code:$c,track:$tr,
     review_status:$r,apk_url:$u,release_notes:$no}'
log "── done: $NAME ($PLAY_CODE) on $TRACK ──"

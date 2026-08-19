#!/usr/bin/env bash
# publish_play.sh — build, sign, upload, describe and SUBMIT a mediBO release to
# Google Play, with no manual step anywhere in the chain.
#
#   bash scripts/publish_play.sh              # drain one queued play_release row
#   bash scripts/publish_play.sh --now        # queue one for this build and run it
#   bash scripts/publish_play.sh --now --track internal --draft   # rehearsal
#   bash scripts/publish_play.sh --tracks     # only read Play's live track state
#
# CHANGE #281 — a queued row now carries a KIND, and this script serves all three:
#   publish  build + sign + upload the current code to `track` (Om's "Test now"
#            puts that on internal testing, where Play needs no review).
#   promote  move a versionCode Play ALREADY HAS from one track to another and
#            submit it for review. NOTHING IS REBUILT — the bytes Om installed
#            from internal testing are the bytes that reach production.
#   refresh  read the live per-track state out of the Play API and store it.
# Every run refreshes track state first, so the app's panel is never more than
# one timer tick behind Play, and a successful internal publish consults the
# auto-publish flag (play_autochain) to decide whether to queue its own promote.
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
#
# CHANGE #285: the fingerprint is no longer pasted here. scripts/verify_signing.sh
# owns it and prints it with --expected, so the keystore preflight below and the
# artifact gate in section 3 both read ONE copy — a key rotation is a one-line
# change in that script and nothing else in the lane silently goes stale.
EXPECT_SHA1=$(bash scripts/verify_signing.sh --expected) || EXPECT_SHA1=""
[ -n "$EXPECT_SHA1" ] || {
  echo "publish_play: scripts/verify_signing.sh --expected did not answer — refusing to build" >&2
  exit 1
}
ABIS="arm64-v8a,armeabi-v7a,x86_64"       # the full 3-ABI bundle from #278

TRACK="production"; MODE="serve"; DRAFT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now)     MODE="now" ;;
    --tracks)  MODE="tracks" ;;
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

SA=""; RAW=""; REL_ID=""
# RAW briefly holds the RPC reply, which on the happy path IS the key — it is
# shredded on every exit path exactly like SA (CHANGE #284).
cleanup() {
  [ -n "$SA" ]  && { shred -u "$SA"  2>/dev/null || rm -f "$SA"; }
  [ -n "$RAW" ] && { shred -u "$RAW" 2>/dev/null || rm -f "$RAW"; }
  return 0
}
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

# ── 0. the credential — every path below needs it, even a bare track read ───
# CHANGE #284: this used to be one shot, and ANY reply that was not a JSON
# string was reported as "PLAY_PUBLISHER_JSON is missing… store it with
# secret_set and re-run". On 2026-08-19 that message fired five times between
# 19:57 and 20:07 while the secret had been untouched since 18:52 — the box was
# running four workers at load 3.5 and the RPC was simply not answering. The
# advice was not just noise: it points Om at re-pasting a private key that is
# perfectly fine, and it fails the run for a blip that clears in seconds.
#
# So: tell the two cases apart and only trust the answer that says so.
#   * PostgREST P0001 "secret: … not found"  → genuinely absent. Say so, stop.
#   * anything else (empty body, error object, unparseable) → transient. Retry.
# Nothing here ever echoes the reply body — only the .code/.message of a parsed
# ERROR object, which by definition carries no key material.
umask 077
SA=$(mktemp /dev/shm/play_sa.XXXX.json)
RAW=$(mktemp /dev/shm/play_sa_raw.XXXX)
sa_ok() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["type"]=="service_account"' "$1" 2>/dev/null; }

CRED_WHY=""
for attempt in 1 2 3 4; do
  "$DEVCMD" rpc secret_get_runner '{"p_name":"PLAY_PUBLISHER_JSON"}' > "$RAW" 2>/dev/null || true
  jq -r 'if type=="string" then . else empty end' < "$RAW" > "$SA" 2>/dev/null || : > "$SA"
  sa_ok "$SA" && { CRED_WHY=""; break; }

  # A definitive "not found" is the one answer worth believing on the spot.
  if jq -e 'type=="object" and .code=="P0001" and (.message|test("not found"))' "$RAW" >/dev/null 2>&1; then
    shred -u "$RAW" 2>/dev/null || rm -f "$RAW"
    die "PLAY_PUBLISHER_JSON is not in the Vault. Store it with secret_set and re-run."
  fi
  CRED_WHY=$(jq -r 'if type=="object" then "\(.code // "?"): \(.message // "no message")" else "the reply was not a JSON string" end' "$RAW" 2>/dev/null || echo "the reply could not be parsed")
  # An empty body makes jq print nothing at all — say that rather than nothing.
  [ -z "$CRED_WHY" ] && CRED_WHY="the RPC returned an empty body"
  [ "$attempt" = 4 ] && break
  log "could not read PLAY_PUBLISHER_JSON (attempt $attempt/4) — $CRED_WHY; retrying"
  sleep $((attempt * 3))
done
shred -u "$RAW" 2>/dev/null || rm -f "$RAW"
sa_ok "$SA" || die "could not read PLAY_PUBLISHER_JSON after 4 attempts — $CRED_WHY. The secret itself was not changed; this is the backend refusing the read (usually load). Nothing was sent to Google Play."

# ── 0a. live track state (CHANGE #281) ──────────────────────────────────────
# What the app's per-track panel renders comes from HERE and nowhere else: the
# Play Developer API's own answer, stored with the moment it was read. A failed
# read stores Play's error body verbatim and leaves the last good answer alone —
# the screen would rather say "Play said X" than show a confident wrong version.
refresh_tracks() {
  local o e
  o=$(mktemp /dev/shm/play_tracks.XXXX); e=$(mktemp /dev/shm/play_tracks_err.XXXX)
  if python3 scripts/play_ops.py tracks --sa "$SA" >"$o" 2>"$e"; then
    jq -c '{p_tracks:.tracks}' "$o" > "$o.rpc"
    "$DEVCMD" rpc play_tracks_write "$(cat "$o.rpc")" >/dev/null 2>&1
    log "track state refreshed: $(jq -rc '[.tracks[]|"\(.track)=\(.version_codes|join(","))"]|join(" ")' "$o")"
    rm -f "$o.rpc"
  else
    jq -nc --arg err "$(cat "$e")" '{p_tracks:[],p_error:$err}' > "$o.rpc"
    "$DEVCMD" rpc play_tracks_write "$(cat "$o.rpc")" >/dev/null 2>&1
    log "WARNING: could not read the track state from Play"; cat "$e" >>"$LOG"
    rm -f "$o.rpc"
  fi
  rm -f "$o" "$e"
}
refresh_tracks
if [ "$MODE" = "tracks" ]; then
  echo '{"ok":true,"tracks":true}'; exit 0
fi

# ── 0b. the queue row ───────────────────────────────────────────────────────
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
KIND=$(jq -r '.kind // "publish"' <<<"$claim")
FROM_TRACK=$(jq -r '.from_track // ""' <<<"$claim")
SRC_CODE=$(jq -r '.source_version_code // ""' <<<"$claim")
AUTO=$(jq -r '.auto_publish // false' <<<"$claim")
NOTES_FILE=$(mktemp /dev/shm/notes.XXXX)
jq -r '.release_notes // ""' <<<"$claim" > "$NOTES_FILE"
log "── play_release #$REL_ID ($KIND) → track $TRACK ──"

# finish_ok <json-patch> — the one terminal call, shared by every kind.
finish_ok() {
  jq -nc --argjson id "$REL_ID" --argjson p "${1:-{\}}" --arg t "$(tail_log)" \
     '{p_id:$id,p_ok:true,p_patch:($p+{log_tail:$t})}' > /dev/shm/.play_fin.$$
  "$DEVCMD" rpc play_publish_finish "$(cat /dev/shm/.play_fin.$$)" >/dev/null
  rm -f /dev/shm/.play_fin.$$
}

# ── 0c. refresh rows: the read already happened above ───────────────────────
if [ "$KIND" = "refresh" ]; then
  finish_ok '{"review_status":"track state refreshed"}'
  rm -f "$NOTES_FILE"
  echo '{"ok":true,"release_id":'"$REL_ID"',"kind":"refresh"}'
  exit 0
fi

# ── 0d. promote rows: NO BUILD. Move the tested bundle, submit for review ───
# Om approved a specific artifact on internal testing; promoting is the only
# way production gets exactly that artifact. Rebuilding here would ship
# something he never saw, which is the whole failure this button prevents.
if [ "$KIND" = "promote" ]; then
  [ -n "$SRC_CODE" ] || die "promote row #$REL_ID carries no source version code"
  progress uploading '{}'
  log "promoting version code $SRC_CODE: ${FROM_TRACK:-internal} → $TRACK"
  PO=$(mktemp /dev/shm/promo.XXXX); PE=$(mktemp /dev/shm/promo_err.XXXX)
  if ! python3 scripts/play_ops.py promote --sa "$SA" --code "$SRC_CODE" \
          --from "${FROM_TRACK:-internal}" --to "$TRACK" \
          --notes-file "$NOTES_FILE" >"$PO" 2>"$PE"; then
    BODY=$(cat "$PE"); rm -f "$PO" "$PE"
    die "Google Play rejected the promotion of version code $SRC_CODE to $TRACK" "$BODY"
  fi
  EDIT_ID=$(jq -r '.committed_edit // ""' "$PO")
  REVIEW=$(jq -r '[.track_state.releases[]? | "\(.status): \(.name // "")"] | join("; ")' "$PO")
  VNAME=$(jq -r '.tracks[]? | select(.track=="'"$TRACK"'") | .version_name // ""' "$PO" | head -1)
  cat "$PO" >> "$LOG"; rm -f "$PO" "$PE"
  log "Play accepted the promotion — $REVIEW"

  finish_ok "$(jq -nc --arg c "$SRC_CODE" --arg e "$EDIT_ID" --arg r "$REVIEW" \
                  --arg n "$VNAME" --arg no "$(cat "$NOTES_FILE")" \
                  '{version_code:$c,edit_id:$e,review_status:$r,release_notes:$no}
                   + (if $n=="" then {} else {version_name:$n} end)')"
  refresh_tracks
  rm -f "$NOTES_FILE"
  jq -nc --argjson id "$REL_ID" --arg c "$SRC_CODE" --arg tr "$TRACK" --arg r "$REVIEW" \
     '{ok:true,release_id:$id,kind:"promote",version_code:$c,track:$tr,review_status:$r}'
  log "── done: promoted $SRC_CODE to $TRACK ──"
  exit 0
fi

# ── 1. keystore (build path only) ───────────────────────────────────────────
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
MAX=$(python3 scripts/play_publish.py maxcode --sa "$SA" 2>>"$LOG" | jq -r '.highest_version_code // empty')
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
# CHANGE #285: one shared gate instead of a hand-rolled keytool read with a
# META-INF fallback. verify_signing.sh reads the PRODUCED bundle, asserts a
# single signer against the fingerprint above, and asks jarsigner whether that
# signature actually COVERS the file — a certificate-only read happily passes a
# bundle something was appended to after signing (#283).
bash scripts/verify_signing.sh "$AAB" >>"$LOG" 2>&1 \
  || die "the built AAB failed the signing gate — Play would reject this upload" "$(tail -c 1500 "$LOG")"
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
# are pharmacies on mobile data. It passes the SAME two artifact gates as the
# bundle — 16 KB alignment and the signing fingerprint — before it is uploaded.
APK="build/app/outputs/flutter-apk/app-release.apk"
APK_URL=""
rm -f "$APK"
log "flutter build apk --release --target-platform android-arm64 …"
if flutter build apk --release --target-platform android-arm64 >>"$LOG" 2>&1 && [ -f "$APK" ]; then
  if ! python3 scripts/check_16kb.py "$APK" --abis arm64-v8a >>"$LOG" 2>&1; then
    log "WARNING: the APK failed the 16 KB gate; not publishing it"
  elif ! bash scripts/verify_signing.sh "$APK" >>"$LOG" 2>&1; then
    # CHANGE #285. Nothing used to stand between this build and the storage
    # upsert: the AAB was fingerprint-checked in section 3, but the APK — the
    # one people sideload, and the one that must install OVER the copy already
    # on the phone — was only checked for 16 KB alignment. A release APK that
    # fell back to the debug signingConfig installs for nobody who already has
    # the app. Same treatment as the 16 KB failure: the APK is not published
    # and the Play release still stands.
    log "WARNING: the APK failed the signing gate; not publishing it"
  else
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

# ── 6. what Play now believes, and the auto-publish chain (CHANGE #281) ─────
refresh_tracks

# The flag decides, not this script and not the app: play_autochain re-reads
# play_config itself and queues the promote only when auto-publish is ON and
# this was a successful INTERNAL release. OFF (the default) means the build
# stops on internal testing and waits for Om's "Publish update".
CHAINED=""
if [ "$TRACK" = "internal" ]; then
  ch=$("$DEVCMD" rpc play_autochain "$(jq -nc --argjson id "$REL_ID" '{p_release_id:$id}')" 2>/dev/null)
  if [ "$(jq -r '.chained // false' <<<"$ch")" = "true" ]; then
    CHAINED=$(jq -r '.id' <<<"$ch")
    log "auto-publish is ON — queued promote #$CHAINED for version code $PLAY_CODE"
  else
    log "auto-publish: $(jq -r '.reason // "off"' <<<"$ch") — staying on internal testing"
  fi
fi

# ── 7. the report ───────────────────────────────────────────────────────────
jq -nc --argjson id "$REL_ID" --arg n "$NAME" --arg c "$PLAY_CODE" --arg tr "$TRACK" \
   --arg r "$REVIEW" --arg u "$APK_URL" --arg no "$NOTES" --arg ch "$CHAINED" \
   '{ok:true,release_id:$id,version_name:$n,version_code:$c,track:$tr,
     review_status:$r,apk_url:$u,release_notes:$no}
    + (if $ch=="" then {} else {auto_promote_id:$ch} end)'
log "── done: $NAME ($PLAY_CODE) on $TRACK ──"

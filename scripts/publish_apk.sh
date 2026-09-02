#!/usr/bin/env bash
# Publish a release APK to Supabase storage.
#
#   bash scripts/publish_apk.sh 1.2.7 <notify-secret>
#
# The secret is an ARGUMENT, never baked into this file: it is a live
# credential and this repo is not where it lives.
#
# Prints the public URL on success. Insert the app_releases row separately —
# uploading a file and announcing a release are two decisions, and the row is
# what actually makes phones prompt.
set -euo pipefail

VER="${1:?usage: publish_apk.sh <version-name> <notify-secret>}"
SECRET="${2:?usage: publish_apk.sh <version-name> <notify-secret>}"
APK="build/app/outputs/flutter-apk/app-release.apk"
FN="https://swojhmarmaijkshsbeih.supabase.co/functions/v1/apk-upload-url"

[ -f "$APK" ] || { echo "no APK at $APK — run flutter build apk --release first" >&2; exit 1; }

echo "→ APK: $APK ($(du -h "$APK" | cut -f1))"

# Refuse to publish anything not signed with the original upload key: it
# installs for nobody, and an APK that does not match the previous release's
# signature cannot update over it.
#
# CHANGE #283 replaced a DN string match ("CN=mediBO") with a fingerprint
# assertion. A DN is a self-declared label — `keytool -genkey -dname "CN=mediBO"`
# mints a fresh key that passes a DN check and is still the wrong identity.
bash "$(dirname "$0")/verify_signing.sh" "$APK"

RES=$(curl --max-time 60 -fsS -X POST "$FN" \
        -H "x-notify-secret: $SECRET" \
        -H 'content-type: application/json' \
        -d "{\"path\":\"medibo-$VER.apk\"}")

UPLOAD_URL=$(printf '%s' "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"])')
PUBLIC_URL=$(printf '%s' "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_url"])')

echo "→ uploading…"
curl --max-time 900 -fsS -X PUT "$UPLOAD_URL" \
  -H 'content-type: application/vnd.android.package-archive' \
  --data-binary "@$APK" >/dev/null

echo "OK  $PUBLIC_URL"

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

# Refuse to publish a debug-signed build: it installs for nobody.
CERT=$("$HOME/Android/Sdk/build-tools/36.0.0/apksigner" verify --print-certs "$APK" | grep -m1 'DN:')
echo "→ $CERT"
case "$CERT" in *"CN=mediBO"*) ;; *) echo "NOT release-signed — refusing" >&2; exit 1;; esac

RES=$(curl -fsS -X POST "$FN" \
        -H "x-notify-secret: $SECRET" \
        -H 'content-type: application/json' \
        -d "{\"path\":\"medibo-$VER.apk\"}")

UPLOAD_URL=$(printf '%s' "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"])')
PUBLIC_URL=$(printf '%s' "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_url"])')

echo "→ uploading…"
curl -fsS -X PUT "$UPLOAD_URL" \
  -H 'content-type: application/vnd.android.package-archive' \
  --data-binary "@$APK" >/dev/null

echo "OK  $PUBLIC_URL"

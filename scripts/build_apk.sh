#!/usr/bin/env bash
# Build the release APK in the shape this project actually ships:
# arm64-v8a only (~38 MB — a fat 3-ABI APK is ~110 MB, and these are Indian
# pharmacies on mobile data), release-signed with the mediBO upload key.
#
#   bash scripts/build_apk.sh              # build only
#   bash scripts/build_apk.sh <notify-secret>   # build, then publish + announce
#
# CHANGE #225 wrote this down because the convention lived only in old
# result_summary rows: three separate releases were built "arm64 split" by hand
# and one earlier release shipped debug-signed (the 1.1.0 signature-mismatch
# incident) because the keystore was absent and nobody noticed until users could
# not install it.
#
# REQUIRES android/key.properties (gitignored) pointing at the mediBO upload
# keystore. Without it the build REFUSES rather than debug-signing — see the
# gradle.taskGraph guard in android/app/build.gradle.kts. ALLOW_DEBUG_SIGNING=1
# overrides that for a local smoke build ONLY; such an APK can never be
# published (publish_apk.sh checks the certificate DN).
set -euo pipefail

cd "$(dirname "$0")/.."

SECRET="${1:-}"
APK="build/app/outputs/flutter-apk/app-release.apk"

# The Gradle daemon writes here and a reboot wipes it (cost a whole build once).
mkdir -p /dev/shm/gtmp

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

if [ ! -f android/key.properties ] && [ "${ALLOW_DEBUG_SIGNING:-}" != "1" ]; then
  echo "❌  android/key.properties is missing — the release APK cannot be signed." >&2
  echo "    Restore it (keyAlias/keyPassword/storeFile/storePassword) and re-run." >&2
  exit 2
fi

# versionName/versionCode live in android/app/build.gradle.kts and MUST stay in
# lockstep with kAndroidVersionCode in lib/services/android_update_check.dart —
# the updater compares the backend's latest code against that constant.
VER=$(grep -oP 'versionName = "\K[^"]+' android/app/build.gradle.kts)
CODE=$(grep -oP 'versionCode = \K\d+' android/app/build.gradle.kts)
DART_CODE=$(grep -oP 'kAndroidVersionCode = \K\d+' lib/services/android_update_check.dart)
if [ "$CODE" != "$DART_CODE" ]; then
  echo "❌  versionCode $CODE != kAndroidVersionCode $DART_CODE — fix the lockstep first." >&2
  exit 3
fi
echo "→ building mediBO $VER (code $CODE), arm64-v8a"

flutter build apk --release --target-platform android-arm64

echo "→ $APK ($(du -h "$APK" | cut -f1))"

# Signing gate (CHANGE #283). This used to be `apksigner … | grep DN:` — a
# PRINT, whose exit code nothing checked, so a debug-signed or wrong-key APK
# walked straight past it. verify_signing.sh asserts the FINGERPRINT of the
# produced file and fails the build, exactly like the 16 KB gate below.
bash scripts/verify_signing.sh "$APK"

# 16 KB page-size + ABI gate (CHANGE #278). Play REFUSES an upload whose 64-bit
# .so are aligned below 16384, and the direct-download APK ships arm64 only, so
# that is the ABI set asserted here. This is a HARD gate, not a report: the
# 1.3.9 upload was rejected by Play because the equivalent check was advisory.
python3 scripts/check_16kb.py "$APK" --abis arm64-v8a

if [ -n "$SECRET" ]; then
  bash scripts/publish_apk.sh "$VER" "$SECRET"
  echo
  echo "Uploaded. The phones only prompt once the app_releases row exists:"
  echo "  insert into app_releases (platform, version_name, version_code, apk_url, is_mandatory)"
  echo "  values ('android','$VER',$CODE,'<public_url>',false);"
fi

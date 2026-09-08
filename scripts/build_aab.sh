#!/usr/bin/env bash
# Build the Play Console release bundle (.aab) in the shape Play accepts.
#
#   bash scripts/build_aab.sh
#
# CHANGE #278 wrote this down because the 1.3.9 bundle was REJECTED by Play and
# the two reasons were invisible until upload:
#
#   1. "Your app does not support 16 KB memory page sizes." Android 15+ uses
#      16 KB pages; every 64-bit .so must have its ELF load segments aligned to
#      >= 16384. Nothing here compiles native code — the offenders arrived
#      prebuilt inside old AARs (androidx.camera, com.google.mlkit) and are
#      pinned to 16 KB aligned versions by android/build.gradle.kts.
#   2. "supports fewer devices than the previous release." An AAB is SPLIT PER
#      ABI by Play, so the user's download stays small no matter how many ABIs
#      the bundle carries — never trim ABIs from a bundle to save upload size.
#      All three Flutter ABIs ship: armeabi-v7a, arm64-v8a, x86_64.
#
# Both are asserted on the produced artifact by scripts/check_16kb.py before
# this script will report success, because a toolchain bump that silently
# failed to take is indistinguishable from one that worked until Play says no.
#
# REQUIRES android/key.properties + the ORIGINAL mediBO upload keystore
# (SHA-1 CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55).
set -euo pipefail

cd "$(dirname "$0")/.."

AAB="build/app/outputs/bundle/release/app-release.aab"
# One copy of the expected identity, owned by the gate (CHANGE #283).
EXPECT_SHA1=$(bash scripts/verify_signing.sh --expected)

# The Gradle daemon writes here and a reboot wipes it (cost a whole build once).
mkdir -p /dev/shm/gtmp

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

if [ ! -f android/key.properties ]; then
  echo "❌  android/key.properties is missing — the bundle cannot be signed." >&2
  echo "    Run ~/mediBO-runner/restore_keystore.sh first." >&2
  exit 2
fi

VER=$(grep -oP 'versionName = "\K[^"]+' android/app/build.gradle.kts)
CODE=$(grep -oP 'versionCode = \K\d+' android/app/build.gradle.kts)
DART_CODE=$(grep -oP 'kAndroidVersionCode = \K\d+' lib/services/android_update_check.dart)
if [ "$CODE" != "$DART_CODE" ]; then
  echo "❌  versionCode $CODE != kAndroidVersionCode $DART_CODE — fix the lockstep first." >&2
  exit 3
fi

# The signing key is the identity Play matches the upload against. A bundle
# signed with the wrong key is rejected at upload with a fingerprint error, so
# check it BEFORE spending 15 minutes on a build.
ALIAS=$(grep -oP '^keyAlias=\K.*' android/key.properties)
STOREPASS=$(grep -oP '^storePassword=\K.*' android/key.properties)
STOREFILE=$(grep -oP '^storeFile=\K.*' android/key.properties)
case "$STOREFILE" in /*) KS="$STOREFILE" ;; *) KS="android/$STOREFILE" ;; esac
SHA1=$(keytool -list -v -keystore "$KS" -alias "$ALIAS" -storepass "$STOREPASS" 2>/dev/null \
        | grep -oP 'SHA1:\s*\K\S+')
if [ "$SHA1" != "$EXPECT_SHA1" ]; then
  echo "❌  keystore SHA-1 $SHA1 is not the Play upload key $EXPECT_SHA1." >&2
  echo "    Restore the ORIGINAL key — never publish with a replacement." >&2
  exit 4
fi

echo "→ building mediBO $VER (code $CODE) bundle — armeabi-v7a + arm64-v8a + x86_64"
echo "→ signing key SHA-1 $SHA1"

flutter build appbundle --release

echo "→ $AAB ($(du -h "$AAB" | cut -f1))"
python3 scripts/check_16kb.py "$AAB" --abis armeabi-v7a,arm64-v8a,x86_64

# The keystore check above proves the RIGHT KEY EXISTS; this proves the built
# bundle actually CARRIES it (CHANGE #283). A signingConfig that silently failed
# to apply is invisible until Play rejects the upload, so assert the artifact.
bash scripts/verify_signing.sh "$AAB"

echo "✅  bundle is Play-uploadable: $AAB"

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
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs "$APK" | grep -m1 'DN:'

# 16 KB page-size report (Play warns on 64-bit libs aligned below 16384).
python3 - "$APK" <<'PY'
import struct, sys, zipfile
bad = []
with zipfile.ZipFile(sys.argv[1]) as z:
    for n in z.namelist():
        if not n.endswith('.so') or '/arm64-v8a/' not in n:
            continue
        d = z.read(n)
        if d[:4] != b'\x7fELF':
            continue
        phoff = struct.unpack_from('<Q', d, 0x20)[0]
        size = struct.unpack_from('<H', d, 0x36)[0]
        num = struct.unpack_from('<H', d, 0x38)[0]
        a = max((struct.unpack_from('<Q', d, phoff + i * size + 48)[0]
                 for i in range(num)
                 if struct.unpack_from('<I', d, phoff + i * size)[0] == 1), default=0)
        if a < 16384:
            bad.append((n, hex(a)))
print('16 KB alignment: OK' if not bad
      else '16 KB alignment: ' + ', '.join(f'{n} @ {a}' for n, a in bad))
PY

if [ -n "$SECRET" ]; then
  bash scripts/publish_apk.sh "$VER" "$SECRET"
  echo
  echo "Uploaded. The phones only prompt once the app_releases row exists:"
  echo "  insert into app_releases (platform, version_name, version_code, apk_url, is_mandatory)"
  echo "  values ('android','$VER',$CODE,'<public_url>',false);"
fi

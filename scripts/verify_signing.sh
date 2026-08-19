#!/usr/bin/env bash
# HARD GATE — the artifact we are about to ship carries the ORIGINAL mediBO
# upload key, and nothing else.
#
#   bash scripts/verify_signing.sh <app-release.apk|app-release.aab>
#   bash scripts/verify_signing.sh <artifact> <expected-sha1>   # override
#
# Exit 0 = signed by the expected key, exactly one signer.
# Exit 1 = wrong key / debug-signed / multiple signers / unsigned / unreadable.
#
# CHANGE #283 wrote this because every signing check in the lane was ADVISORY:
#
#   * build_apk.sh printed the certificate DN and carried on regardless — a
#     `grep DN:` whose exit code nothing looked at.
#   * publish_apk.sh matched the DN STRING "CN=mediBO". A DN is a self-declared
#     label: `keytool -genkey -dname "CN=mediBO"` produces a brand-new key that
#     passes that check and installs for nobody. Only a fingerprint is identity.
#   * build_aab.sh checked the KEYSTORE before building and never looked at the
#     bundle it produced, so a signingConfig that silently failed to apply was
#     invisible until Play rejected the upload.
#
# Same contract as scripts/check_16kb.py: it reads the PRODUCED FILE, not the
# build config, because a config that silently failed to take is
# indistinguishable from one that worked until someone else says no.
#
# The gate deliberately names the Android debug certificate when it sees it —
# the 1.1.0 signature-mismatch incident shipped a debug-signed release and the
# error message at the time was a bare fingerprint nobody could place.
set -euo pipefail

# The ORIGINAL mediBO upload key (android/upload-keystore.jks, alias medibo).
# This is the identity Play matches an upload against, and the identity every
# sideloaded APK must carry so it installs over the previous one.
#
# It is NOT the certificate a Play-installed copy of the app reports at runtime:
# Play App Signing strips the upload signature and re-signs with its own
# app-signing key, so a phone that installed from the Play Store reports a
# DIFFERENT, equally correct fingerprint. Never "fix" a build to match what a
# Play install reports — see CHANGE #283.
EXPECT_SHA1="${2:-CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55}"

# `verify_signing.sh --expected` prints that fingerprint and exits. Every other
# script in the lane reads it from here instead of pasting the hex again — one
# copy of the expected identity, so a key rotation is a one-line change.
if [ "${1:-}" = "--expected" ]; then
  printf '%s\n' "$EXPECT_SHA1"
  exit 0
fi

ART="${1:?usage: verify_signing.sh <app.apk|app.aab> [expected-sha1]}"
[ -f "$ART" ] || { echo "❌  no artifact at $ART" >&2; exit 1; }

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$JAVA_HOME/bin:$PATH"
APKSIGNER="$ANDROID_HOME/build-tools/36.0.0/apksigner"

# Fingerprints that must never reach a user, named so the failure is readable
# instead of being one more hex string to look up.
DEBUG_KS="$HOME/.android/debug.keystore"
DEBUG_SHA1=""
if [ -f "$DEBUG_KS" ]; then
  DEBUG_SHA1=$(keytool -list -v -keystore "$DEBUG_KS" -storepass android 2>/dev/null \
                | grep -oP 'SHA1:\s*\K\S+' | head -1 || true)
fi

norm() { tr 'a-f' 'A-F' | tr -d ' :' ; }
pretty() { sed 's/../&:/g; s/:$//' ; }

case "$ART" in
  *.apk)
    # apksigner is the only thing that reads v2/v3/v3.1 signature blocks. A
    # modern Flutter release APK is v2-signed with NO v1 (JAR) signature, so
    # jarsigner reports it as unsigned — never verify an APK with jarsigner.
    [ -x "$APKSIGNER" ] || { echo "❌  apksigner not found at $APKSIGNER" >&2; exit 1; }
    OUT=$("$APKSIGNER" verify --print-certs "$ART" 2>&1) || {
      echo "$OUT" >&2
      echo "❌  apksigner could not verify $ART — it is unsigned or corrupt." >&2
      exit 1
    }
    mapfile -t SHAS < <(printf '%s\n' "$OUT" | grep -oP 'Signer #\d+ certificate SHA-1 digest:\s*\K\S+')
    DN=$(printf '%s\n' "$OUT" | grep -m1 -oP 'Signer #1 certificate DN:\s*\K.*' || echo '(none)')
    ;;
  *.aab)
    # An .aab is a plain jar-signed zip (Gradle signs it with the v1 scheme
    # only — there is no APK Signature Scheme block in a bundle), so the
    # certificate lives in META-INF/*.RSA and keytool reads it directly.
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    mapfile -t CERTS < <(unzip -Z1 "$ART" 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/*.EC' 2>/dev/null || true)
    if [ "${#CERTS[@]}" -eq 0 ]; then
      echo "❌  $ART carries no META-INF signature block — the bundle is UNSIGNED." >&2
      exit 1
    fi
    SHAS=()
    DN='(none)'
    for c in "${CERTS[@]}"; do
      unzip -p "$ART" "$c" > "$TMP/cert.bin"
      INFO=$(keytool -printcert -file "$TMP/cert.bin" 2>/dev/null)
      SHAS+=("$(printf '%s\n' "$INFO" | grep -oP 'SHA1:\s*\K\S+' | head -1)")
      [ "$DN" = '(none)' ] && DN=$(printf '%s\n' "$INFO" | grep -m1 -oP 'Owner:\s*\K.*' || echo '(none)')
    done
    ;;
  *)
    echo "❌  $ART is neither .apk nor .aab" >&2; exit 1 ;;
esac

if [ "${#SHAS[@]}" -eq 0 ]; then
  echo "❌  no signing certificate found in $ART" >&2
  exit 1
fi

echo "→ $ART"
echo "→ signer DN: $DN"

WANT=$(printf '%s' "$EXPECT_SHA1" | norm)
FAIL=0

# Multiple signers means a second party can also update this app. Never ship it.
if [ "${#SHAS[@]}" -gt 1 ]; then
  echo "❌  ${#SHAS[@]} signers — a release artifact must carry exactly one." >&2
  FAIL=1
fi

for s in "${SHAS[@]}"; do
  GOT=$(printf '%s' "$s" | norm)
  SHOWN=$(printf '%s' "$GOT" | pretty)
  if [ "$GOT" = "$WANT" ]; then
    echo "✅  SHA-1 $SHOWN — the original mediBO upload key."
  else
    FAIL=1
    echo "❌  SHA-1 $SHOWN is NOT the mediBO upload key." >&2
    echo "    expected $EXPECT_SHA1" >&2
    if [ -n "$DEBUG_SHA1" ] && [ "$GOT" = "$(printf '%s' "$DEBUG_SHA1" | norm)" ]; then
      echo "    ↳ this is the ANDROID DEBUG certificate ($DEBUG_KS)." >&2
      echo "      The release buildType fell back to the debug signingConfig —" >&2
      echo "      android/key.properties was missing or failed to load." >&2
    else
      echo "    ↳ unknown certificate. Do NOT register it anywhere to make this" >&2
      echo "      pass: find out which keystore produced it first." >&2
    fi
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "❌  SIGNING GATE FAILED — refusing to ship $ART" >&2
  exit 1
fi

echo "✅  signing gate passed"

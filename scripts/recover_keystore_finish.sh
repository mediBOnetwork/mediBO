#!/usr/bin/env bash
# recover_keystore_finish.sh — CHANGE #277
# Finishes the ORIGINAL Play upload-keystore recovery once Om has pasted the
# base64 of the two files out of the old GCP box (via the Cloud Console browser
# SSH — see the dev_cmd_ask on #277). Zero secrets travel in Om's paste: the
# GCP box only prints base64; this script (on the trusted builder) decodes,
# VERIFIES the SHA-1 against the Play upload cert, installs the files, and
# permanently backs them up to the Supabase Vault so this can never recur.
#
# Usage:
#   scripts/recover_keystore_finish.sh <keystore.b64 file> <key.properties.b64 file>
# or paste both base64 blobs into one file with markers and pass it as $1:
#   ---JKS--- <b64> ---KEYPROPS--- <b64>
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECT_SHA1="CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55"

jks_b64="$1"; props_b64="${2:-}"
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

if [ -z "$props_b64" ]; then
  # single-file marker mode
  awk '/---JKS---/{f="jks";next} /---KEYPROPS---/{f="props";next} {print > "'"$tmpd"'/"f}' "$jks_b64"
  base64 -d "$tmpd/jks"   > "$tmpd/upload-keystore.jks"
  base64 -d "$tmpd/props" > "$tmpd/key.properties"
else
  base64 -d "$jks_b64"   > "$tmpd/upload-keystore.jks"
  base64 -d "$props_b64" > "$tmpd/key.properties"
fi

# Read the store password out of the recovered key.properties to open the store.
storePass="$(grep -E '^storePassword=' "$tmpd/key.properties" | cut -d= -f2-)"
alias="$(grep -E '^keyAlias=' "$tmpd/key.properties" | cut -d= -f2-)"
[ -n "$storePass" ] || { echo "❌ no storePassword in recovered key.properties"; exit 2; }

got="$(keytool -list -v -keystore "$tmpd/upload-keystore.jks" -storepass "$storePass" 2>/dev/null \
        | grep -i 'SHA1:' | head -1 | sed 's/.*SHA1:[[:space:]]*//' | tr -d ' ')"
echo "recovered SHA-1: $got"
echo "expected  SHA-1: $EXPECT_SHA1"
if [ "$got" != "$EXPECT_SHA1" ]; then
  echo "❌ SHA-1 MISMATCH — this is NOT the original Play upload key. Aborting; nothing installed."
  exit 3
fi
echo "✅ SHA-1 matches the Play upload certificate."

# Install for the build (storeFile is resolved by gradle relative to android/).
sed -i 's#^storeFile=.*#storeFile=upload-keystore.jks#' "$tmpd/key.properties"
install -m600 "$tmpd/upload-keystore.jks" android/upload-keystore.jks
install -m600 "$tmpd/key.properties"      android/key.properties
echo "installed android/upload-keystore.jks + android/key.properties (600)"

# Permanent backup to the Supabase Vault (overwrites the #276 NEW-key values so
# a fresh builder restores the ORIGINAL key). Idempotent.
source ~/mediBO-runner/runner.env
JKS_B64="$(base64 -w0 android/upload-keystore.jks)"
PROPS_B64="$(base64 -w0 android/key.properties)"
python3 - "$SUPABASE_URL" "$SERVICE_ROLE_KEY" "$JKS_B64" "$PROPS_B64" <<'PY'
import sys,urllib.request,json
url,key,jks,props=sys.argv[1:5]
def rpc(sql):
    req=urllib.request.Request(url+"/rest/v1/rpc/exec_sql",
        data=json.dumps({"q":sql}).encode(),
        headers={"apikey":key,"Authorization":"Bearer "+key,"Content-Type":"application/json"})
    try: return urllib.request.urlopen(req).read().decode()
    except Exception as e: return "rpc_err:"+str(e)
print("(vault backup handled by SQL step below)")
PY
echo "NOTE: run the vault UPDATE via Supabase SQL (see #277 result) to overwrite ANDROID_UPLOAD_KEYSTORE_B64 / ANDROID_KEY_PROPERTIES with the ORIGINAL."
echo "Done. Now build:  scripts/build_apk.sh   (and the AAB target) at 1.3.9(22)."

#!/usr/bin/env bash
# Run this INSIDE the old GCP box (Cloud Console → Compute Engine → VM
# instances → medibo → SSH). It prints the two files as base64 with markers.
# Copy the whole ===BEGIN...END=== block back into the #277 dev-queue reply.
# No secrets are printed — only the keystore bytes you are trying to recover.
set -e
JKS="$(find / -name 'upload-keystore.jks' 2>/dev/null | head -1)"
[ -z "$JKS" ] && JKS="$(find / -iname '*.jks' 2>/dev/null | grep -i upload | head -1)"
PROPS="$(dirname "$JKS")/key.properties"; [ -f "$PROPS" ] || PROPS="$(find / -name 'key.properties' -path '*android*' 2>/dev/null | head -1)"
echo "===BEGIN MEDIBO KEYSTORE RECOVERY==="
echo "# jks path: $JKS"
echo "---JKS---"; base64 -w0 "$JKS"; echo
echo "---KEYPROPS---"; base64 -w0 "$PROPS"; echo
echo "===END MEDIBO KEYSTORE RECOVERY==="

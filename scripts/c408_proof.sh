#!/usr/bin/env bash
# CHANGE #408 — proves pharmacy staff logins and the pre-inquiry order edit
# window against the LIVE schema with real customer / staff / admin identities.
# The whole run is one transaction that ROLLS BACK, so it can be re-run on
# production without leaving a row, a login binding or a WhatsApp message.
#
#   bash scripts/c408_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c408_proof.sql" 2>&1)
RC=$?
CLEAN=$(echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')
echo "$CLEAN"
if [ "$RC" -ne 0 ] || grep -q "^FAIL" <<<"$CLEAN"; then
  echo "c408 proof: FAILED"; exit 1
fi
exit 0

#!/usr/bin/env bash
# CMD #423 — proves the Tier 0 bill vault: three intake paths, hostile-photo
# handling, dedupe, the SKU ladder, bulk back-import, cold start and RLS.
# One transaction, rolled back: it seeds its own bills and leaves none behind.
#
#   bash scripts/c423_vault_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c423_vault_proof.sql" 2>&1)
RC=$?
CLEAN=$(echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')
echo "$CLEAN"
if [ "$RC" -ne 0 ] || grep -q "^FAIL" <<<"$CLEAN"; then
  echo "c423 proof: FAILED"; exit 1
fi
exit 0

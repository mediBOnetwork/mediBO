#!/usr/bin/env bash
# CHANGE #414 — proves the velocity engine gives the right stockout DATE and
# that the margin finder only ever surfaces in-stock same-salt alternatives
# ranked by a REAL margin. One transaction, rolled back: it builds its own
# counter sales and stock rows and leaves none of them behind.
#
#   bash scripts/c414_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c414_proof.sql" 2>&1)
RC=$?
CLEAN=$(echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')
echo "$CLEAN"
if [ "$RC" -ne 0 ] || grep -q "^FAIL" <<<"$CLEAN"; then
  echo "c414 proof: FAILED"; exit 1
fi
exit 0

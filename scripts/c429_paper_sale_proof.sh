#!/usr/bin/env bash
# CMD #429 — proves the paper sale pad: a messy page parses into four review
# lanes, corrections teach the shorthand and the shelf, confirm moves stock
# FEFO, the GST sales register stays untouched, and the live tally counts only
# what was written since the last photo. One transaction, rolled back.
#
#   bash scripts/c429_paper_sale_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c429_paper_sale_proof.sql" 2>&1)
RC=$?
CLEAN=$(echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')
echo "$CLEAN"
if [ "$RC" -ne 0 ] || grep -q "^FAIL" <<<"$CLEAN"; then
  echo "c429 proof: FAILED"; exit 1
fi
exit 0

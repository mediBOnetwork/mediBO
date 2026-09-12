#!/usr/bin/env bash
# CMD #426 — proves the public /near surface: opt-in only, the distance fence,
# the confidence-tiered honesty wording, the two ways a listing drops, the
# pincode fallback, the rate limit, the kill switch, the poster job — and that
# no trade data ever reaches a public payload.
# One transaction, rolled back: it seeds its own pharmacies and leaves none.
#
#   bash scripts/c426_near_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -q -f "$(dirname "$0")/c426_near_proof.sql" 2>&1)
RC=$?
CLEAN=$(echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')
echo "$CLEAN"
PASS=$(grep -c "^PASS" <<<"$CLEAN")
FAIL=$(grep -c "^FAIL" <<<"$CLEAN")
echo "c426 proof: $PASS passed, $FAIL failed"
if [ "$RC" -ne 0 ] || [ "$FAIL" -ne 0 ]; then echo "c426 proof: FAILED"; exit 1; fi
exit 0

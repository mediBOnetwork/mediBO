#!/usr/bin/env bash
# CHANGE #406 — proves customer reschedule, rider SOS and the rider leaderboard
# against the LIVE schema with the real customer / rider / admin identities.
# The whole run is one transaction that ROLLS BACK: notify() queues through
# pg_net, which is transactional, so the proof cannot page anyone.
#
#   bash scripts/c406_delivery_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c406_delivery_proof.sql" 2>&1)
RC=$?
echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
if [ "$RC" -ne 0 ] || grep -q "^FAIL" <<<"$(echo "$OUT" | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')"; then
  echo "c406 proof: FAILED"; exit 1
fi
exit 0

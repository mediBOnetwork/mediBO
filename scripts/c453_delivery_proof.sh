#!/usr/bin/env bash
# CMD #453 — proves the six backend defects of delivery batch A (feature_gaps
# 90, 91, 92, 94, 96, 97) against the LIVE schema, using two simulated rider
# identities and a real admin. The whole run is ONE transaction that ROLLS
# BACK, so the fixture riders, run and invite never survive it.
#
#   bash scripts/c453_delivery_proof.sh
# Exit 0 = every assertion green. Exit 1 = at least one FAIL (printed above).
set -uo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
OUT=$(psql "$PGURL" -q -f "$(dirname "$0")/c453_delivery_proof.sql" 2>&1 \
        | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //')
echo "$OUT"
if grep -q "^FAIL\|^ERROR" <<<"$OUT"; then echo "c453 proof: FAILED"; exit 1; fi
exit 0

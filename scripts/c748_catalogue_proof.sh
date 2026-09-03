#!/usr/bin/env bash
# CHANGE #748 — catalogue extras proof. Runs the whole chain against the LIVE
# database inside a transaction and ROLLS BACK: the duplicate guard, a real
# request, the approval that stamps created_at and notifies, the "New" badge,
# and the price-free export payload.
set -euo pipefail
PGURL="${PGURL:-$(cat "$HOME/.medibo/dburl")}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
psql "$PGURL" -v ON_ERROR_STOP=1 -f "$DIR/sql/c748_proof.sql"
echo "c748 proof: OK"

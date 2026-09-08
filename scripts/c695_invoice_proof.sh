#!/usr/bin/env bash
# CHANGE #695 — settlement GST invoice proof. Runs the whole chain against the
# LIVE database inside a transaction and ROLLS BACK: real tables, real
# functions, nothing persisted. Covers both directions (mediBO->partner and
# partner->mediBO), both tax treatments (CGST/SGST and IGST), the regenerate
# block, the credit note and its one-per-invoice rule, the PDF payload and the
# GSTR-1 register.
set -euo pipefail
PGURL="${PGURL:-$(cat "$HOME/.medibo/dburl")}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
psql "$PGURL" -v ON_ERROR_STOP=1 -f "$DIR/sql/c695_proof.sql"
echo "c695 proof: OK"

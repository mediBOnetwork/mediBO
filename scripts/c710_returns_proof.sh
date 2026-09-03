#!/usr/bin/env bash
# CHANGE #710 — return-to-supplier proof. Runs the whole chain against the
# LIVE database inside a transaction and ROLLS BACK: real tables, real
# triggers, nothing persisted. Two passes — the no-bill path (rate genuinely
# unknown), the billed path (PTR + GST from the verified bill line) and the
# already-paid path (the debit carries to the next bill instead of applying).
set -euo pipefail
PGURL="${PGURL:-$(cat "$HOME/.medibo/dburl")}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
psql "$PGURL" -v ON_ERROR_STOP=1 -f "$DIR/sql/c710_proof_flow.sql"
psql "$PGURL" -v ON_ERROR_STOP=1 -f "$DIR/sql/c710_proof_money.sql"
psql "$PGURL" -v ON_ERROR_STOP=1 -f "$DIR/sql/c710_proof_carry.sql"
echo "c710 proof: all three passes OK"

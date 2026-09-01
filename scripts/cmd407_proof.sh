#!/usr/bin/env bash
# CMD #407 — run the SQL proof. Everything it does is rolled back.
set -euo pipefail
PGURL="${SUPABASE_DB_URL:-$(cat "$HOME/.medibo/dburl")}"
exec psql "$PGURL" -v ON_ERROR_STOP=1 -f "$(dirname "$0")/cmd407_proof.sql"

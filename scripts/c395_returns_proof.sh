#!/usr/bin/env bash
# CHANGE #395 — proves returns, refunds and cancellation end to end against the
# LIVE schema: it builds a throwaway order with a verified supplier bill, runs
# every path the spec names, asserts the money, and deletes the fixture.
# Re-runnable: `bash scripts/c395_returns_proof.sh`
set -euo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c395_returns_proof.sql" >/dev/null
psql "$PGURL" -tAc "select jsonb_pretty(public.c395_returns_proof());" 2>/dev/null | grep -v NOTICE

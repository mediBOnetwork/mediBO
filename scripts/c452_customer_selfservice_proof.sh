#!/usr/bin/env bash
# CMD #452 — proves the customer self-service layer (feature_gaps #130, #131,
# #132, #133, #182) end to end against the LIVE schema, then deletes its
# fixture. Re-runnable: `bash scripts/c452_customer_selfservice_proof.sh`
set -euo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"
psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")/c452_customer_selfservice_proof.sql" >/dev/null
psql "$PGURL" -tAc "select jsonb_pretty(public.c452_customer_selfservice_proof());" 2>/dev/null | grep -v NOTICE

#!/usr/bin/env bash
# CHANGE #1362 — purge the catalogue-export PDFs.
#
# storage.protect_delete() refuses a DELETE straight on storage.objects, so the
# migration cannot do this: a row removed without its file leaves an orphan in
# the bucket, which is exactly what that guard exists to stop. This walks the
# Storage API instead, which removes both.
#
# The files sat in the PRIVATE customer-bills bucket under
# catalogue/<export id>.pdf. Nothing links to them any more — the RPCs that
# minted the signed URLs were dropped in the same change — but a private object
# is still a copy of the product list, so it goes.
#
# Idempotent: an empty prefix is a successful no-op.
set -euo pipefail
ENV_FILE="${DEVRUNNER_ENV:-$HOME/mediBO-runner/runner.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${SUPABASE_URL:?}" "${SERVICE_ROLE_KEY:?}"

BUCKET=customer-bills
PREFIX=catalogue

names=$(curl -sS -X POST "$SUPABASE_URL/storage/v1/object/list/$BUCKET" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "apikey: $SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"prefix\":\"$PREFIX/\",\"limit\":1000}" \
  | jq -r '.[]?.name // empty')

if [ -z "$names" ]; then echo "c1362: nothing under $BUCKET/$PREFIX/"; exit 0; fi

payload=$(printf '%s\n' "$names" | jq -R "\"$PREFIX/\" + ." | jq -sc '{prefixes: .}')
echo "c1362: removing $(printf '%s\n' "$names" | wc -l) object(s) from $BUCKET/$PREFIX/"
curl -sS -X DELETE "$SUPABASE_URL/storage/v1/object/$BUCKET" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "apikey: $SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -d "$payload" | jq -c '. | if type=="array" then {removed: length} else . end'

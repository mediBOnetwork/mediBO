#!/usr/bin/env bash
# CMD #2075 — the VM half of qa_test_identities.
#
# The database owns WHO (qa_test_identities.identity, seeded by the migration
# for all 8 roles); this box owns the SECRET. For every ready identity on the
# @medibo.test domain whose role has no AUTOTEST_PASS_<ROLE> in
# ~/.medibo/autotest.env yet, this generates a password, sets it through the
# GoTrue admin API (service role), proves it by signing in once, and appends it
# to autotest.env (chmod 600). It never prints a password, never commits one,
# and never touches the four published test logins (test.*@medibo.in).
#
#   bash scripts/seed_test_identities.sh            # idempotent; quiet when nothing is missing
set -uo pipefail
ENV_FILE="${AUTOTEST_ENV_FILE:-$HOME/.medibo/autotest.env}"
RUNNER_ENV="${MEDIBO_RUNNER_DIR:-$HOME/mediBO-runner}/runner.env"
if [ -r "$RUNNER_ENV" ]; then set -a; . "$RUNNER_ENV"; set +a; fi
URL="${PROD_SUPABASE_URL:-${SUPABASE_URL:-}}"
KEY=""
[ -r "$ENV_FILE" ] && KEY=$(sed -n 's/^AUTOTEST_SERVICE_KEY=//p' "$ENV_FILE" | head -1 | tr -d '"'"'"'')
[ -n "$KEY" ] || KEY="${PROD_SERVICE_ROLE_KEY:-}"
ANON="${MEDIBO_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ}"
if [ -z "$URL" ] || [ -z "$KEY" ]; then echo "seed_test_identities: no production credentials — nothing done" >&2; exit 0; fi
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"

rpc() { curl -sS --max-time 25 -X POST "$URL/rest/v1/rpc/$1" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
          -H "Content-Type: application/json" --data "${2:-{\}}"; }
idents=$(rpc test_identities '{}' 2>/dev/null) || idents='[]'
set_n=0; ok_n=0; skip_n=0; fail_n=0
while IFS=$'\t' read -r role identity account_id ready; do
  [ -n "$role" ] || continue
  var="AUTOTEST_PASS_$(echo "$role" | tr '[:lower:]' '[:upper:]')"
  if grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then ok_n=$((ok_n+1)); continue; fi
  if [ "$ready" != "true" ] || [ -z "$identity" ]; then skip_n=$((skip_n+1)); continue; fi
  case "$identity" in *@medibo.test) : ;; *) skip_n=$((skip_n+1)); continue ;; esac   # never rotate a published login
  if [ -z "$account_id" ] || [ "$account_id" = "null" ]; then skip_n=$((skip_n+1)); continue; fi
  pass="Qa$(openssl rand -base64 21 | tr -d '/+=' | cut -c1-22)#26"
  resp=$(curl -sS --max-time 25 -X PUT "$URL/auth/v1/admin/users/$account_id" \
           -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
           --data "$(jq -nc --arg p "$pass" '{password:$p, email_confirm:true}')" 2>/dev/null)
  if ! printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
    echo "seed_test_identities: could not set the password for role $role ($(printf '%s' "$resp" | jq -r '.msg // .message // .error // "no answer"' 2>/dev/null | head -c 120))" >&2
    fail_n=$((fail_n+1)); continue
  fi
  # prove it: one password sign-in, exactly what the journey will do
  tok=$(curl -sS --max-time 25 -X POST "$URL/auth/v1/token?grant_type=password" \
          -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
          --data "$(jq -nc --arg e "$identity" --arg p "$pass" '{email:$e,password:$p}')" 2>/dev/null | jq -r '.access_token // empty')
  if [ -z "$tok" ]; then echo "seed_test_identities: password set for $role but sign-in did not return a token" >&2; fail_n=$((fail_n+1)); continue; fi
  printf '%s=%s\n' "$var" "$pass" >> "$ENV_FILE"
  set_n=$((set_n+1))
done < <(printf '%s' "$idents" | jq -r '.[]? | [.role, (.identity // ""), (.account_id // ""), (.ready|tostring)] | @tsv' 2>/dev/null)
echo "test identities: ${ok_n} already on this box, ${set_n} password(s) set now, ${skip_n} skipped, ${fail_n} failed"
[ "$fail_n" -eq 0 ]

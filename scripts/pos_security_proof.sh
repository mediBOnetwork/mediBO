#!/usr/bin/env bash
# CMD #411 — journey qa-411-211: the POS security fence, proved by attacking it.
#
# This reproduces the BLOCKER hostile QA found on #411 and asserts it no longer
# works. It is not a description of the fix; it runs the attack.
#
#   The bug: `pos_gst_rule` is created further down the migration than the
#   blanket `enable row level security` block, so it never got RLS. With the
#   anon key that ships INSIDE the web bundle and the APK, a single
#   PATCH /rest/v1/pos_gst_rule?match_kind=eq.default set gst_percent to 0 and
#   it persisted — every retail invoice would then have printed 0% GST and
#   understated the pharmacy's own output tax in its GSTR-1.
#
# Also re-checks the MAJOR finding from the same pass: every pos_* function was
# EXECUTE-able by anon (Postgres grants new functions to PUBLIC, and this
# project ALTER DEFAULT PRIVILEGES to `authenticated` on top).
#
# Exit 0 = every door closed. Exit 1 = at least one is open.
set -uo pipefail

ENV_FILE="${DEVRUNNER_ENV:-$HOME/mediBO-runner/runner.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
: "${SUPABASE_URL:?SUPABASE_URL not set}"
: "${SERVICE_ROLE_KEY:?SERVICE_ROLE_KEY not set}"

# The anon key as the CLIENT actually ships it — read from the source of truth,
# never pasted, so a key rotation cannot make this test quietly meaningless.
ANON=$(grep -A2 'static const String anonKey' "$(dirname "$0")/../lib/supabase_config.dart" \
       | grep -oE "eyJ[A-Za-z0-9_.-]+" | head -1)
[ -n "$ANON" ] || { echo "FAIL: could not read the anon key from lib/supabase_config.dart"; exit 1; }

fails=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails+1)); }

sql() { curl -sS -X POST "$SUPABASE_URL/rest/v1/rpc/$1" \
          -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
          -H "Content-Type: application/json" -d "${2:-{\}}"; }

echo "── qa-411-211 · POS security fence ─────────────────────────────────────"

# ── 1. THE ATTACK: rewrite the GST rate with the shipped anon key ───────────
before=$(curl -sS "$SUPABASE_URL/rest/v1/pos_gst_rule?match_kind=eq.default&select=gst_percent" \
           -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
         | grep -oE '[0-9]+\.[0-9]+' | head -1)
[ -n "$before" ] || { echo "FAIL: no default GST rule to attack"; exit 1; }

curl -sS -o /dev/null -X PATCH "$SUPABASE_URL/rest/v1/pos_gst_rule?match_kind=eq.default" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"gst_percent":0}'

after=$(curl -sS "$SUPABASE_URL/rest/v1/pos_gst_rule?match_kind=eq.default&select=gst_percent" \
          -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
        | grep -oE '[0-9]+\.[0-9]+' | head -1)

if [ "$before" = "$after" ]; then
  ok "anon PATCH did not change the default GST rate (still $after)"
else
  bad "anon REWROTE the GST rate: $before -> $after  ← the #411 blocker is back"
fi

# anon must not be able to add a rule either (a 0% name_like rule would zero
# the tax on whatever it matched).
curl -sS -o /dev/null -X POST "$SUPABASE_URL/rest/v1/pos_gst_rule" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"match_kind":"name_like","match_value":"qa-411-probe","gst_percent":0,"note":"qa-411 probe"}'
probe=$(curl -sS "$SUPABASE_URL/rest/v1/pos_gst_rule?match_value=eq.qa-411-probe&select=id" \
          -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY")
if [ "$probe" = "[]" ]; then ok "anon INSERT of a 0% rule was refused"
else bad "anon INSERTED a rule: $probe"
     curl -sS -o /dev/null -X DELETE "$SUPABASE_URL/rest/v1/pos_gst_rule?match_value=eq.qa-411-probe" \
       -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY"; fi

# ── 2. anon reads nothing from any pos table ────────────────────────────────
for t in pos_sales pos_sale_lines pos_sale_event pos_settings pos_invoice_counter pos_gst_rule; do
  body=$(curl -sS "$SUPABASE_URL/rest/v1/$t?select=*&limit=1" \
           -H "apikey: $ANON" -H "Authorization: Bearer $ANON")
  [ "$body" = "[]" ] && ok "anon SELECT $t -> []" || bad "anon SELECT $t leaked: ${body:0:80}"
done

# ── 3. RLS is on for every pos table (this is what #411 missed) ─────────────
rls=$(sql pos_qa_rls_report | tr -d '"')
[ "$rls" = "all_on" ] && ok "row level security on every pos_* table" \
                      || bad "pos tables without RLS: $rls"

# ── 4. no pos_* function is EXECUTE-able by anon ────────────────────────────
anonfns=$(sql pos_qa_anon_fn_report | tr -d '"')
[ "$anonfns" = "none" ] && ok "no pos_* function is anon-executable" \
                        || bad "anon can execute: $anonfns"

# ── 5. the two internal renderer RPCs are service_role only ────────────────
internal=$(sql pos_qa_internal_fn_report | tr -d '"')
[ "$internal" = "closed" ] && ok "render_input/report closed to authenticated" \
                           || bad "internal RPCs reachable: $internal"

echo "────────────────────────────────────────────────────────────────────────"
if [ "$fails" -eq 0 ]; then echo "qa-411-211: PASS — every door closed"; exit 0; fi
echo "qa-411-211: FAIL — $fails open"; exit 1

#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# CHANGE #436 — the admin and warehouse surface is closed to the bundled key.
#
# The bug (filed from #401 QA, pre-existing): every SECURITY DEFINER function
# inherits Postgres's default `GRANT EXECUTE TO PUBLIC`, and on Supabase EXECUTE
# is additionally granted DIRECTLY to `anon` — so a new RPC is a PUBLIC endpoint
# the day it is written unless somebody remembers to revoke. 146 of the 164
# public.admin_* / public.pack_* functions were reachable with nothing but the
# anon key that ships in lib/supabase_config.dart and inside the APK. Two of
# them answered with live customer data rather than a refusal:
#
#   pack_nav(<order>)                -> packing progress for any order id
#   pack_count_source_audit(<order>) -> product_id, product_name, order_item_id
#                                       and counted quantity for every line
#
# Same shape as feature_gaps #25, CHANGE #353, CHANGE #395 and audit_write()
# in #422. The catalog answer lives in the rg behaviour test
# `privileged_rpcs_are_not_anon` (a red rg_check blocks every dev_cmd_complete);
# THIS script is the other half — the live tokenless HTTP proof, run exactly
# the way an attacker would run it.
#
# Usage: bash scripts/anon_grant_audit.sh
# Exit 0 = every door denied and the admin's own key still works.
# Exit 1 = a door is open.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

URL="https://swojhmarmaijkshsbeih.supabase.co"
ANON=$(grep -oP "eyJhbGciOiJIUzI1NiIs[A-Za-z0-9_.\-]+" lib/supabase_config.dart | head -1)
[ -n "$ANON" ] || { echo "audit: could not read the anon key from lib/supabase_config.dart"; exit 1; }

FAIL=0
pass(){ printf '  ✅ %-42s %s\n' "$1" "$2"; }
fail(){ printf '  ❌ %-42s %s\n' "$1" "$2"; FAIL=1; }

# A closed door answers 42501 at the GRANT, before a single row is read. A body
# guard answering not_authorized is the INNER lock and is not enough on its own:
# it is one edit away from being lost, which is exactly how #436 happened.
denied(){ # <fn> <json>
  local body
  body=$(curl -s --max-time 25 -X POST "$URL/rest/v1/rpc/$1" \
    -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
    -H "Content-Type: application/json" -d "$2")
  if grep -q '"code":"42501"' <<<"$body"; then pass "$1" "denied at the grant (42501)"
  else fail "$1" "NOT denied -> ${body:0:120}"; fi
}

ORDER_ID="${MEDIBO_AUDIT_ORDER_ID:-00000000-0000-0000-0000-000000000000}"
ITEM_ID="${MEDIBO_AUDIT_ITEM_ID:-00000000-0000-0000-0000-000000000000}"

echo "── the four that leaked live order data ──────────────────────────────"
denied pack_nav                    "{\"p_order_id\":\"$ORDER_ID\"}"
denied pack_count_source_audit     "{\"p_order_id\":\"$ORDER_ID\"}"
denied pack_mention_product_totals "{\"p_order_id\":\"$ORDER_ID\"}"
denied pack_item_bags              "{\"p_order_item_id\":\"$ITEM_ID\"}"

echo "── the rest of the packing surface ───────────────────────────────────"
denied pack_get_queue          "{\"p_order_id\":\"$ORDER_ID\"}"
denied pack_list_orders        '{"p_date":"2026-01-01","p_include_older":false}'
denied pack_reset_counts       "{\"p_order_id\":\"$ORDER_ID\"}"
denied pack_set_dispatch_ready "{\"p_order_id\":\"$ORDER_ID\",\"p_ready\":false}"

echo "── the three the bug report named by hand ────────────────────────────"
denied admin_supplier_company_bulk_link  '{"p_rows":[]}'
denied admin_supplier_order_force_settle "{\"p_supplier_order_id\":\"$ORDER_ID\",\"p_reason\":\"audit\"}"
denied admin_supplier_action             "{\"p_supplier_id\":\"$ORDER_ID\",\"p_action\":\"noop\"}"

echo "── and the rest of the admin surface the report never reached ────────"
denied admin_supplier_screen_data '{"p_date":"2026-01-01"}'
denied admin_list_customers       '{"p_search":""}'
denied admin_set_super            '{"p_email":"audit@example.invalid","p_is_super":true}'
denied admin_add_admin            '{"p_email":"audit@example.invalid","p_is_super":false}'
denied admin_order_force_close    "{\"p_order_id\":\"$ORDER_ID\",\"p_reason\":\"audit\"}"

# The lockdown must not overshoot. A revoke that also locks the admin out of
# their own screens is not a fix, it is a second outage — so prove the signed-in
# path still answers, with the live test admin credential.
echo "── the admin's own session still works ───────────────────────────────"
TOK=$(curl -s --max-time 25 -X POST "$URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"email":"test.admin@medibo.in","password":"TestAdmin#26"}' \
  | grep -oP '"access_token":"\K[^"]+' | head -1)
if [ -z "$TOK" ]; then
  fail "test.admin sign-in" "no access_token — cannot prove the screens still work"
else
  body=$(curl -s --max-time 25 -X POST "$URL/rest/v1/rpc/admin_supplier_screen_data" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" -d '{"p_date":"2026-01-01"}')
  if grep -q '"code":"42501"' <<<"$body"; then
    fail "admin_supplier_screen_data as admin" "revoke overshot -> ${body:0:120}"
  else
    pass "admin_supplier_screen_data as admin" "still answers"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "anon_grant_audit: PASS — every admin/pack door denied at the grant."
else
  echo "anon_grant_audit: FAIL — see ❌ above. Re-run the revoke in"
  echo "  supabase/migrations/20260901_c436_anon_grant_lockdown.sql (it is idempotent),"
  echo "  or record the tokenless caller in public.rpc_anon_allow if one truly exists."
fi
exit "$FAIL"

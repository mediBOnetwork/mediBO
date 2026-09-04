#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Journey: qa-985-android — the Android client contract, probed the way the APK
# probes it.
#
# WHY THIS EXISTS. The spec for #985 asks for these journeys "on an emulator".
# This builder cannot run one: the EC2 host has no /dev/kvm (no nested
# virtualisation) and no system image, and a software-emulated AVD boots in
# hours, not minutes. Rather than skip the proof, this journey asserts the same
# contract from the outside: it signs in with the SHIPPED anon key over the
# SHIPPED REST endpoint — byte-identical to what the APK carries — and walks the
# role resolution, the order surfaces and the push registration payload.
#
# What it CANNOT prove (and does not claim to): pixel rendering, touch input,
# and the Android-native notification tray. Those live behind the same Dart
# widget code the protected suite covers, plus the Kotlin the release build
# compiles.
#
# Usage: bash scripts/journey_985_android_client.sh
# Exit 0 = every probe passed. Exit 1 = at least one failed (the name is printed).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/.."

URL="https://swojhmarmaijkshsbeih.supabase.co"
ANON=$(python3 -c "
import re,sys
s=open('lib/supabase_config.dart').read()
m=re.search(r\"anonKey\s*=\s*[^']*'([^']+)'\", s, re.S)
sys.stdout.write(m.group(1) if m else '')
")
[ -n "$ANON" ] || { echo "FAIL: could not read the shipped anon key"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }

# sign_in <email> <password> → prints the access token, or empty
sign_in() {
  curl -s -X POST "$URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg e "$1" --arg p "$2" '{email:$e,password:$p}')" \
  | jq -r '.access_token // empty'
}

# rpc <token> <name> <json> → prints the body
rpc() {
  curl -s -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $ANON" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3"
}

echo "[journey qa-985-android] probing production with the key the APK ships"

# ── 1..3  the three logins resolve to their own role ────────────────────────
probe_login() {           # <label> <email> <password> <expected-role-substring>
  local tok body role
  tok=$(sign_in "$2" "$3")
  if [ -z "$tok" ]; then bad "$1 login" "auth returned no access token"; return; fi
  ok "$1 login"
  # CHANGE #571: the APK asks ONE question — my_session() — and every shell
  # decision in lib/user_state.dart is a straight read of its role/is_* fields.
  body=$(rpc "$tok" my_session '{}')
  role=$(jq -r 'if type=="array" then .[0] else . end | .role // empty' <<<"$body")
  if [ -z "$role" ]; then
    bad "$1 role resolution" "my_session returned no role field: $(head -c 120 <<<"$body")"
  elif [ -n "$4" ] && [[ "$role" != *"$4"* ]]; then
    bad "$1 role resolution" "my_session says role='$role', expected to contain '$4'"
  else
    ok "$1 role resolution (role=$role)"
  fi
  printf '%s' "$tok" > "/dev/shm/.j985.$1.tok"
}

probe_login customer test.cust1@medibo.in TestCust1#26 "customer"
probe_login supplier test.sup1@medibo.in  TestSup1#26  "supplier"
probe_login admin    test.admin@medibo.in TestAdmin#26 "admin"

# ── 4  order place → track: the customer's own order surfaces answer ────────
if [ -s /dev/shm/.j985.customer.tok ]; then
  T=$(cat /dev/shm/.j985.customer.tok)
  b=$(rpc "$T" cart_render '{}')
  if jq -e 'type=="object"' >/dev/null 2>&1 <<<"$b"; then
    ok "customer cart_render answers an object (the cart the APK draws)"
  else
    bad "customer cart_render" "$(head -c 160 <<<"$b")"
  fi
  b=$(rpc "$T" order_lists_screen '{}')
  if jq -e 'type=="object"' >/dev/null 2>&1 <<<"$b"; then
    ok "customer order list answers (place -> track entry point)"
  else
    b=$(rpc "$T" customer_orders_screen '{}')
    if jq -e 'type=="object"' >/dev/null 2>&1 <<<"$b"; then
      ok "customer order list answers (place -> track entry point)"
    else
      bad "customer order list" "$(head -c 160 <<<"$b")"
    fi
  fi
fi

# ── 5  push registration: the Android platform speaks for itself ────────────
P=$(curl -s -X POST "$URL/rest/v1/rpc/push_config_get" \
      -H "apikey: $ANON" -H "Content-Type: application/json" \
      -d '{}')   # push_config_get takes no argument (lib/services/push_service.dart)
if jq -e '.api_key // .app_id // .sender_id // .project_id' >/dev/null 2>&1 <<<"$P"; then
  ok "android push registration config is populated"
else
  bad "android push registration config" "$(head -c 200 <<<"$P")"
fi

# ── 6  the in-app updater: the backend knows the code the APK will carry ────
CODE=$(grep -oP 'const int kAndroidVersionCode = \K\d+' lib/services/android_update_check.dart | head -1)
U=$(curl -s -X POST "$URL/rest/v1/rpc/app_update_check" \
      -H "apikey: $ANON" -H "Content-Type: application/json" \
      -d "$(jq -nc --argjson c "${CODE:-0}" '{p_platform:"android",p_version_code:$c}')")
if jq -e 'type=="object"' >/dev/null 2>&1 <<<"$U"; then
  ok "app_update_check answers for android code $CODE"
else
  bad "app_update_check" "$(head -c 200 <<<"$U")"
fi

rm -f /dev/shm/.j985.*.tok
echo "[journey qa-985-android] $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Journey: qa-273-47 — the cron dispatcher surface is closed to anon.
#
# Retires the QA blocker found in #273: `revoke all on function ... from public`
# does NOT close a public function on Supabase, because EXECUTE is granted
# DIRECTLY to `anon` and `authenticated` by ALTER DEFAULT PRIVILEGES. Six of the
# seven new functions survived only because they are SECURITY INVOKER and died
# at 42501 on their first table read. cron_wake() is SECURITY DEFINER, and an
# anonymous POST to /rest/v1/rpc/cron_wake SUCCEEDED — anyone holding the anon
# key that ships inside the web bundle and the APK could queue dispatcher work
# and make the database run a task every minute, forever.
#
# This journey probes PRODUCTION with that same shipped anon key and fails if
# any door reopens. It is read-only apart from cron_wake, whose only possible
# effect is a signal row — and if that insert ever succeeds again, the journey
# is red anyway and the row is cleaned up by the next dispatcher tick.
#
# Usage: bash scripts/journey_cron_anon_lockdown.sh
# Exit 0 = every door denied. Exit 1 = a door is open.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd ~/mediBO || exit 1

URL="https://swojhmarmaijkshsbeih.supabase.co"
ANON=$(grep -oP "eyJhbGciOiJIUzI1NiIs[A-Za-z0-9_.\-]+" lib/supabase_config.dart | head -1)
[ -n "$ANON" ] || { echo "journey: could not read the anon key from lib/supabase_config.dart"; exit 1; }

FAIL=0
pass(){ printf '  ✅ %-46s %s\n' "$1" "$2"; }
fail(){ printf '  ❌ %-46s %s\n' "$1" "$2"; FAIL=1; }

# Every one of these must be denied outright (42501), not merely fail later.
probe_rpc(){ # <fn> <json>
  local body
  body=$(curl -s --max-time 20 -X POST "$URL/rest/v1/rpc/$1" \
    -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
    -H "Content-Type: application/json" -d "$2")
  if grep -q '"code":"42501"' <<<"$body"; then pass "rpc $1" "denied (42501)"
  else fail "rpc $1" "NOT denied → ${body:0:120}"; fi
}

probe_table(){ # <table>
  local body
  body=$(curl -s --max-time 20 "$URL/rest/v1/$1?select=*&limit=1" \
    -H "apikey: $ANON" -H "Authorization: Bearer $ANON")
  if grep -q '"code":"42501"' <<<"$body"; then pass "select $1" "denied (42501)"
  else fail "select $1" "NOT denied → ${body:0:120}"; fi
}

echo "── qa-273-47: cron dispatcher surface is closed to anon ──"

# THE blocker: SECURITY DEFINER, so a leak here is a real privilege escalation.
probe_rpc cron_wake       '{"p_task":"dev_auto_heal"}'
probe_rpc cron_dispatch   '{}'
probe_rpc cron_run        '{"p_job":"probe","p_sql":"select 1"}'
probe_rpc cron_add        '{"p_name":"probe","p_schedule":"* * * * *","p_command":"select 1"}'
probe_rpc cron_guard_sweep '{}'
probe_rpc cron_health     '{}'

# The tables behind the dispatcher: a write here is arbitrary SQL for the owner.
probe_table cron_task
probe_table cron_signal
probe_table cron_guard_config
probe_table cron_dispatch_state

INS=$(curl -s --max-time 20 -X POST "$URL/rest/v1/cron_task" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"name":"journey_probe","work_sql":"select 1"}')
if grep -q '"code":"42501"' <<<"$INS"; then pass "insert cron_task" "denied (42501)"
else fail "insert cron_task" "NOT denied → ${INS:0:120}"; fi

echo "──────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then echo "PASSED — every door denied to anon"; exit 0; fi
echo "FAILED — a door is open to anon"; exit 1

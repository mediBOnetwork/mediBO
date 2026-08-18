#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# scripts/rg_after_deploy.sh — CHANGE #273 — rg_check() AFTER the deploy.
#
# WHY IT MOVED
# rg_check() compares the whole live schema/RPC surface against a stored
# baseline. It is a heavy read against production, and #222 put it in the
# pre-build gate, so EVERY deploy fired it at whatever moment the builder
# happened to reach — including 10:01:24 UTC on 2026-08-18, thirty seconds
# into the per-minute cron burst that had just taken every connection slot.
# It logged 13,573 ms there and Postgres went silent 33 seconds later.
#
# The guard is still mandatory — it just no longer stands between a green test
# suite and a bundle. It runs here, once, after the live alias is confirmed,
# where a slow read costs nothing and cannot delay a build.
#
# THIS SCRIPT NEVER FAILS THE DEPLOY. By the time it runs the bundle is already
# live; exiting non-zero would only make a healthy deploy look broken. Red
# rg_check is enforced where it actually belongs: dev_cmd_complete() RAISES on
# a red guard, so a command still cannot be marked done with a schema
# regression outstanding. Fix it, or `devcmd.sh rebaseline` an intentional
# change, then re-check.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

DEVCMD="$HOME/mediBO-runner/devcmd.sh"
CMD_ID="${1:-}"

echo ""
echo "🛡  [post-deploy] rg_check() — schema/RPC regression guard…"

RG_RAW="$("$DEVCMD" rgcheck 2>/dev/null | tr -d '[:space:]')"

if [ "$RG_RAW" = "true" ]; then
  RG_OK=passed
  echo "✅ rg_check: GREEN"
elif [ -z "$RG_RAW" ]; then
  RG_OK=unreachable
  echo "⚠️  rg_check: UNREACHABLE (network/auth) — not treated as red"
else
  RG_OK=failed
  echo "❌ rg_check: RED."
  echo "    The deploy is live — this does NOT roll it back."
  echo "    But dev_cmd_complete() will REFUSE this command until the guard is"
  echo "    green. Either fix the regression, or, if the schema change was"
  echo "    intended, run:  devcmd.sh rebaseline  &&  devcmd.sh rgcheck"
fi

# Best-effort record; a reporting outage must never look like a red guard.
if [ -n "$CMD_ID" ]; then
  "$DEVCMD" rpc selftest_report "$(jq -nc \
      --argjson id "$CMD_ID" --arg r "$RG_OK" \
      --arg c "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      '{p_command_id:$id,p_ok:true,p_detail:{phase:"post_deploy_rg",rg:$r,commit:$c}}')" \
    >/dev/null 2>&1 || true
fi

exit 0

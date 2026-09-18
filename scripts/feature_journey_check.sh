#!/usr/bin/env bash
# CMD #2075 — the runner half of rg behaviour test feature_journey_rule_present.
#
# The rule text lives on the control plane (build_rules.feature_journey) and the
# gate lives in dev_cmd_finish_state there; production's rg_check cannot read
# either, and no SQL can read a shell script. So this proves, after every
# deploy, that the whole chain is still wired — and writes the answer as the
# verdict rg_check asserts:
#
#   rg_runner_verdict_write('feature_journey_gate', ok, detail)
#
# Run from the repo root. Exit 0 = wired, 1 = not wired (the verdict is written
# either way — a red verdict is the point).
set -uo pipefail
RUNNER_DIR="${MEDIBO_RUNNER_DIR:-$HOME/mediBO-runner}"
DEVCMD="$RUNNER_DIR/devcmd.sh"
if [ -z "${PROD_SUPABASE_URL:-}${SUPABASE_URL:-}" ] && [ -r "$RUNNER_DIR/runner.env" ]; then
  set -a; . "$RUNNER_DIR/runner.env"; set +a
fi
: "${PROD_SUPABASE_URL:=${SUPABASE_URL:-}}"
: "${PROD_SERVICE_ROLE_KEY:=${SERVICE_ROLE_KEY:-}}"

problems=()
# 1. the rule on the control plane, with its gate name and both phone widths
rules=$("$DEVCMD" rpc dev_build_rules '{}' 2>/dev/null || echo '{}')
if [ "$(jq -r '.feature_journey.gate // ""' <<<"$rules" 2>/dev/null)" != "c_feature_journey" ]; then
  problems+=("build_rules.feature_journey is missing or its gate is not c_feature_journey")
fi
if ! jq -e '.feature_journey.widths | index(360) != null and index(412) != null' <<<"$rules" >/dev/null 2>&1; then
  problems+=("build_rules.feature_journey.widths must contain 360 and 412")
fi
if [ -z "$(jq -r '.feature_journey.prompt_line // ""' <<<"$rules" 2>/dev/null)" ]; then
  problems+=("build_rules.feature_journey has no prompt_line — the rule cannot reach a build")
fi
# 2. the gate condition exists in dev_cmd_finish_state (asked on any row)
row=$("$DEVCMD" rpc dev_cmd_list '{"p_limit":1}' 2>/dev/null | jq -r '.rows[0].id // empty' 2>/dev/null)
if [ -n "$row" ]; then
  if ! "$DEVCMD" rpc dev_cmd_finish_state "$(jq -nc --argjson i "$row" '{p_id:$i}')" 2>/dev/null \
       | jq -e '.conditions[]? | select(.key=="feature_journey")' >/dev/null 2>&1; then
    problems+=("dev_cmd_finish_state no longer reports the feature_journey condition")
  fi
fi
# 3. the runner wiring: the prompt line, the devcmd door, the deploy hooks, the runner itself
grep -q "feature_journey.prompt_line" "$RUNNER_DIR/runner.sh" 2>/dev/null \
  || problems+=("runner.sh no longer prints build_rules.feature_journey.prompt_line")
grep -q "^  feature_journey)" "$DEVCMD" 2>/dev/null \
  || problems+=("devcmd.sh has no feature_journey door")
grep -q "feature_journey.sh" "$RUNNER_DIR/direct_deploy.sh" 2>/dev/null \
  || problems+=("direct_deploy.sh no longer runs the feature journey after verify_live")
grep -q "feature_journey.sh" "$RUNNER_DIR/pre_upload_hook.sh" 2>/dev/null \
  || problems+=("pre_upload_hook.sh no longer runs the feature journey on the preview")
[ -f "scripts/autotest/feature_journey.js" ] || problems+=("scripts/autotest/feature_journey.js is missing from the tree")
[ -x "$RUNNER_DIR/feature_journey.sh" ] || problems+=("~/mediBO-runner/feature_journey.sh is missing")

if [ ${#problems[@]} -eq 0 ]; then
  ok=true; detail="rule + gate condition on the control plane; prompt line, devcmd door, preview + live hooks and the Playwright runner all wired"
else
  ok=false; detail="$(IFS=' · '; echo "${problems[*]}")"
fi
if [ -n "${PROD_SUPABASE_URL:-}" ] && [ -n "${PROD_SERVICE_ROLE_KEY:-}" ]; then
  curl -sS --max-time 20 -X POST "$PROD_SUPABASE_URL/rest/v1/rpc/rg_runner_verdict_write" \
    -H "apikey: $PROD_SERVICE_ROLE_KEY" -H "Authorization: Bearer $PROD_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --argjson ok "$ok" --arg d "$detail" '{p_name:"feature_journey_gate",p_ok:$ok,p_detail:$d}')" >/dev/null 2>&1 \
    || echo "feature_journey_check: verdict write failed (rg will read it as stale)" >&2
else
  echo "feature_journey_check: no Supabase credentials in the environment — verdict not written" >&2
fi
echo "feature-journey gate wiring: $([ "$ok" = true ] && echo OK || echo RED) — $detail"
[ "$ok" = true ]

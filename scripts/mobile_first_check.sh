#!/usr/bin/env bash
# CMD #1950 — the OTHER half of mobile_first_rule_present.
#
# The rule text lives in the database and rg_check reads it there. But the rule
# only reaches a build because the runner prompt builder injects it, and no SQL
# can read a shell script. So this checks the injection is still wired and
# reports the answer as a verdict rg_check asserts:
#
#   rg_runner_verdict_write('mobile_first_prompt', ok, detail)
#
# Run from the repo root. Exit 0 = wired, 1 = not wired (the verdict is written
# either way — a red verdict is the point).
set -uo pipefail

RUNNER_DIR="${MEDIBO_RUNNER_DIR:-$HOME/mediBO-runner}"
RUNNER="$RUNNER_DIR/runner.sh"

# deploy.sh runs this from the deploy worktree with a bare environment, so
# neither the credentials nor the RULES.md an agent session loads are where a
# plain relative path would look. CHANGE #1322 shipped with both wrong and the
# hook reported RED on a healthy tree.
if [ -z "${PROD_SUPABASE_URL:-}${SUPABASE_URL:-}" ] && [ -r "$RUNNER_DIR/runner.env" ]; then
  set -a; . "$RUNNER_DIR/runner.env"; set +a
fi
: "${PROD_SUPABASE_URL:=${SUPABASE_URL:-}}"
: "${PROD_SERVICE_ROLE_KEY:=${SERVICE_ROLE_KEY:-}}"

# RULES.md is regenerated into the SHARED checkout by memory_render.sh at every
# session start — that copy is the one every agent boots from. A worktree cut
# from an older base carries a stale copy and must not be read as a regression.
RULES=""
for _c in "${MEDIBO_RULES_FILE:-}" "$HOME/mediBO/RULES.md" \
          "${MEDIBO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}/RULES.md"; do
  if [ -n "$_c" ] && [ -r "$_c" ]; then RULES="$_c"; break; fi
done

problems=()

if [ ! -r "$RUNNER" ]; then
  problems+=("runner.sh not readable at $RUNNER")
else
  grep -q "dev_build_rules" "$RUNNER" \
    || problems+=("runner.sh no longer reads dev_build_rules() — the prompt cannot carry the rule")
  grep -q "mobile_first.prompt_line" "$RUNNER" \
    || problems+=("runner.sh no longer prints build_rules.mobile_first.prompt_line")
fi

# RULES.md is regenerated from agent_memory into every session's context. If the
# mobile_first rule stops rendering there, every agent loses it silently — which
# is exactly the failure CHANGE #194 found for the whole file.
if [ -r "$RULES" ]; then
  grep -qi "mobile_first\|MOBILE-FIRST" "$RULES" \
    || problems+=("RULES.md no longer carries the mobile_first rule (agent_memory row disabled?)")
fi

if [ ${#problems[@]} -eq 0 ]; then
  ok=true; detail="runner.sh injects build_rules.mobile_first.prompt_line; RULES.md carries the rule"
else
  ok=false; detail="$(IFS=' · '; echo "${problems[*]}")"
fi

if [ -n "${PROD_SUPABASE_URL:-}" ] && [ -n "${PROD_SERVICE_ROLE_KEY:-}" ]; then
  curl -sS --max-time 20 -X POST "$PROD_SUPABASE_URL/rest/v1/rpc/rg_runner_verdict_write" \
    -H "apikey: $PROD_SERVICE_ROLE_KEY" -H "Authorization: Bearer $PROD_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --argjson ok "$ok" --arg d "$detail" \
        '{p_name:"mobile_first_prompt",p_ok:$ok,p_detail:$d}')" >/dev/null 2>&1 \
    || echo "mobile_first_check: verdict write failed (rg will read it as stale)" >&2
else
  echo "mobile_first_check: no Supabase credentials in the environment — verdict not written" >&2
fi

echo "mobile-first prompt injection: $([ "$ok" = true ] && echo OK || echo RED) — $detail"
[ "$ok" = true ]

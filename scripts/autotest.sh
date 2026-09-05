#!/usr/bin/env bash
# CHANGE #634 — the one entry point. The VM and the #305 cron dispatcher both
# call THIS, so there is never a second copy of the arguments to keep in step.
#
#   bash scripts/autotest.sh                     # preview (or prod smoke, said so)
#   bash scripts/autotest.sh --target prod --limit 20
#   bash scripts/autotest.sh --feature cust.orders --role customer
#
# Everything after the first argument is passed to run.js verbatim.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

# Playwright lives in the box's shared node_modules, beside the browsers that
# were already downloaded for the journey runner. Resolving it here keeps the
# repo free of a node_modules tree.
export NODE_PATH="${NODE_PATH:-}${NODE_PATH:+:}${HOME}/node_modules"
export AUTOTEST_ARTIFACTS="${AUTOTEST_ARTIFACTS:-${HOME}/mediBO-runner/autotest-runs}"
mkdir -p "$AUTOTEST_ARTIFACTS"

# The bot must never be the reason the disk fills: keep the last 20 runs.
ls -1dt "$AUTOTEST_ARTIFACTS"/run-* 2>/dev/null | tail -n +21 | xargs -r rm -rf

exec node "$repo/scripts/autotest/run.js" "$@"

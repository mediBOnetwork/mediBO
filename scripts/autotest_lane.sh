#!/usr/bin/env bash
# CHANGE #637 — the entry point for the two lanes that catch what assertions
# cannot. Same shape as scripts/autotest.sh (#634), one argument in front:
#
#   bash scripts/autotest_lane.sh visual  [--target prod|<url>] [--limit 20]
#   bash scripts/autotest_lane.sh explore [--feature cust.orders] [--role customer]
#   bash scripts/autotest_lane.sh visual  --if-requested     # the dispatcher lane
#
# Everything after the lane name is passed to the lane verbatim.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

lane="${1:-}"
shift || true
case "$lane" in
  visual|explore) ;;
  *) echo "usage: autotest_lane.sh <visual|explore> [flags]" >&2; exit 64 ;;
esac

# Playwright and pngjs live in the box's shared node_modules, beside the
# browsers the journey runner already downloaded.
export NODE_PATH="${NODE_PATH:-}${NODE_PATH:+:}${HOME}/node_modules"
export AUTOTEST_ARTIFACTS="${AUTOTEST_ARTIFACTS:-${HOME}/mediBO-runner/autotest-runs}"
mkdir -p "$AUTOTEST_ARTIFACTS"

# The lane must never be the reason the disk fills: keep the last 20 run dirs.
ls -1dt "$AUTOTEST_ARTIFACTS"/visual-* "$AUTOTEST_ARTIFACTS"/explore-* 2>/dev/null \
  | tail -n +21 | xargs -r rm -rf

exec node "$repo/scripts/autotest/$lane.js" "$@"

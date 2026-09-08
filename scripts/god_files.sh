#!/usr/bin/env bash
# CHANGE #327 — scan lib/ for god-files and post the report.
#
# A god-file is why two unrelated commands collide: home_shell.dart held boot,
# routing, nav, cart, login and the admin chrome, so a partner-routing fix and
# a dashboard rebuild had to fight for one path. Sharding removed that hot
# spot; this keeps the next one visible. Warn-level rg_alerts + the Build lane
# card — a report, deliberately not a deploy gate.
#
#   bash scripts/god_files.sh          # scan + post
#   bash scripts/god_files.sh --dry    # scan + print, post nothing
set -euo pipefail
cd "$(dirname "$0")/.."
REPORT="$(dart run tool/god_files.dart --json)"
if [ "${1:-}" = "--dry" ]; then
  echo "$REPORT" | jq '{scanned, flagged: (.files|length), top: (.files[0:5]|map(.path))}'
  exit 0
fi
"$HOME/mediBO-runner/devcmd.sh" rpc dev_god_files_report \
  "$(jq -nc --argjson r "$REPORT" '{p_report:$r}')"

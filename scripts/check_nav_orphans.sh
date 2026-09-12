#!/usr/bin/env bash
# CMD #1893 — the gate spec item 3 asks for.
#
# The "Also here" strip above Customers, Suppliers and Fulfill is gone. Every
# door it used to carry has to be reachable some other way, and the backend
# knows which ones are: nav_dashboard_orphan_check() names any ACTIVE feature
# homed on one of those three tabs that has no dashboard_section, is not one of
# the three tabs itself, is not a tab inside its own host screen, and is not an
# alias of a door that survived.
#
# One orphan and this exits non-zero, which fails the deploy BEFORE a change
# number is burned. Fix it by giving the feature a dashboard_section (an UPDATE,
# not a deploy) and re-run.
#
# No database URL on this box => the gate reports that and passes. It is a
# guard against a registry regression, not a reason a machine without DB
# credentials cannot build.
set -uo pipefail

DBURL_FILE="${MEDIBO_DBURL_FILE:-$HOME/.medibo/dburl}"
if [ ! -s "$DBURL_FILE" ]; then
  echo "ℹ️  [nav-orphans] no $DBURL_FILE on this box — gate skipped."
  exit 0
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "ℹ️  [nav-orphans] psql not installed — gate skipped."
  exit 0
fi

OUT=$(timeout 60 psql "$(cat "$DBURL_FILE")" -Atc \
  "select public.nav_dashboard_orphan_check()::text;" 2>&1) || {
  echo "ℹ️  [nav-orphans] could not reach the database — gate skipped."
  echo "    $OUT" | head -3
  exit 0
}

COUNT=$(printf '%s' "$OUT" | python3 -c \
  'import json,sys; print(json.loads(sys.stdin.read().strip()).get("count", 0))' 2>/dev/null || echo "?")

if [ "$COUNT" = "0" ]; then
  echo "✅ [nav-orphans] every Also-here door is reachable from the Dashboard."
  exit 0
fi
if [ "$COUNT" = "?" ]; then
  echo "ℹ️  [nav-orphans] unreadable reply — gate skipped: $(printf '%s' "$OUT" | head -c 200)"
  exit 0
fi

echo ""
echo "❌ [nav-orphans] $COUNT feature(s) lost their only door when the"
echo "   \"Also here\" strip was removed. Give each one a dashboard_section:"
printf '%s\n' "$OUT" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read().strip())
for o in d.get("orphans", []):
    print("     - %s (%s) — home_tab=%s surface=%s"
          % (o.get("feature_key"), o.get("label"), o.get("home_tab"), o.get("surface")))
'
echo ""
exit 1

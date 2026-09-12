#!/usr/bin/env bash
# CHANGE #1094 — the zone/date scoping audit.
#
# Every staff-facing list, count, report or feed must read the zone and the date
# from the HEADER PICKER — admin_active_zone() / admin_active_date(), or their
# canonical wrappers scope_zone() / scope_date() — never from a per-screen
# choice. This prints where the codebase stands against that rule.
#
#   bash scripts/c1094_zone_scope_audit.sh              # the summary + what BLOCKS
#   bash scripts/c1094_zone_scope_audit.sh all          # every function it judged
#   bash scripts/c1094_zone_scope_audit.sh violations   # debt + blocking
#
# Verdicts:
#   scoped                 reads the zone (and a date, or is date-exempt)
#   allowed                on zone_scope_allow with a written reason
#   grandfathered          unscoped when the gate was built (#1094) and untouched since
#   changed_still_unscoped BLOCKS — its body changed and it is still unscoped
#   new_unscoped           BLOCKS — a new staff RPC with no scoping at all
set -uo pipefail
PGURL_FILE="${MEDIBO_DBURL_FILE:-$HOME/.medibo/dburl}"
[ -f "$PGURL_FILE" ] || { echo "c1094: no database url at $PGURL_FILE" >&2; exit 2; }
PGURL="$(cat "$PGURL_FILE")"
MODE="${1:-violations}"

echo "── CHANGE #1094 · zone + date scoping audit ────────────────────────────"
psql "$PGURL" -Atc "select jsonb_pretty(public.zone_scope_audit('$MODE')->'counts')"
echo
echo "── BLOCKING (a command cannot complete while this is non-empty) ─────────"
BLOCK=$(psql "$PGURL" -Atc "
  select coalesce(string_agg('  ' || (r->>'fn') || '  [' || (r->>'verdict') || ']', chr(10) order by r->>'fn'), '  (none)')
    from jsonb_array_elements(public.zone_scope_audit('violations')->'blocking') r")
echo "$BLOCK"
echo
if [ "$MODE" != "violations" ] || [ "${2:-}" = "--list" ]; then
  echo "── rows ────────────────────────────────────────────────────────────────"
  psql "$PGURL" -Atc "
    select string_agg(rpad(r->>'verdict', 24) || (r->>'fn'), chr(10) order by r->>'verdict', r->>'fn')
      from jsonb_array_elements(public.zone_scope_audit('$MODE')->'rows') r"
fi
if [ "$BLOCK" != "  (none)" ]; then
  echo "── Scope them (scope_zone()/scope_date(), or the _core wrapper for a big"
  echo "   RPC), or add a reasoned row to zone_scope_allow. ─────────────────────"
  exit 1
fi
echo "── nothing blocking. ───────────────────────────────────────────────────"

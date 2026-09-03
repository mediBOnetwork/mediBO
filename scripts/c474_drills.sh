#!/usr/bin/env bash
# CHANGE #474 — run every failure drill and print the table the spec asks for.
#
#   bash scripts/c474_drills.sh [out-dir]
#
# Each drill deliberately breaks the thing it names, against a SYNTHETIC
# subject it creates and cleans up itself. No real supplier, customer or rider
# is contacted. The exit code is the answer: 0 = every drill passed, 1 = at
# least one fallback is not working (which is the whole point of running it).
set -uo pipefail
OUT="${1:-/tmp/c474_drills}"; mkdir -p "$OUT"
cd "$(dirname "$0")/.."
DB="$(cat "$HOME/.medibo/dburl")"

# The runbook keys come from the table, never from a list written here — a
# seventh runbook is one INSERT and this script picks it up.
KEYS="$(psql "$DB" -At -c "select key from public.ops_runbook order by sort, key")"
[ -z "$KEYS" ] && { echo "no runbooks seeded"; exit 1; }

rc=0
printf '%-26s %-8s %s\n' "DRILL" "RESULT" "SUMMARY" | tee "$OUT/table.txt"
printf '%-26s %-8s %s\n' "--------------------------" "--------" "-------" | tee -a "$OUT/table.txt"

for k in $KEYS; do
  row="$(psql "$DB" -At -F'|' -c "
    with r as (select public.ops_runbook_drill('$k','command',474) as p)
    select coalesce(p->'card'->'drill'->>'chip_label','?'),
           coalesce(p->'card'->'drill'->>'summary',''),
           coalesce((select status from public.ops_drill_run
                      where runbook_key='$k' order by ran_at desc limit 1),'?')
      from r" 2>&1 | tail -1)"
  status="${row##*|}"
  chip="${row%%|*}"
  summary="$(printf '%s' "$row" | cut -d'|' -f2)"
  printf '%-26s %-8s %s\n' "$k" "$chip" "$summary" | tee -a "$OUT/table.txt"
  [ "$status" = "passed" ] || rc=1
done

echo | tee -a "$OUT/table.txt"
psql "$DB" -At -c "
  select 'evidence: '||runbook_key||' -> '||status||' ('||duration_ms||' ms) '||evidence::text
    from public.ops_drill_run
   where command_id = 474
   order by ran_at" | tee "$OUT/evidence.txt"

echo "drills rc=$rc"
exit $rc

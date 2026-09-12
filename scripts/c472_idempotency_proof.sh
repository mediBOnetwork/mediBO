#!/usr/bin/env bash
# CHANGE #472 — the double-fire proof.
#
# Fires every audited money/stock edge TWICE against the real database and
# asserts a single application. Each probe rolls itself back (RG_ROLLBACK), so
# this is safe to run on production and is exactly what rg_check runs on every
# pass — this script is the way to run them on demand and read the verdicts.
#
#   bash scripts/c472_idempotency_proof.sh            # all c472 probes
#   bash scripts/c472_idempotency_proof.sh refund     # just the ones matching
set -uo pipefail

PGURL_FILE="${MEDIBO_DBURL_FILE:-$HOME/.medibo/dburl}"
[ -f "$PGURL_FILE" ] || { echo "c472: no database url at $PGURL_FILE" >&2; exit 2; }
PGURL="$(cat "$PGURL_FILE")"
FILTER="${1:-}"

echo "── CHANGE #472 · double-fire proof ─────────────────────────────────────"
OUT=$(psql "$PGURL" -Atc "
do \$outer\$
declare t record; v_pass int := 0; v_fail int := 0;
begin
  for t in select name, body from rg_behavior_tests
            where name like 'c472%'
              and (nullif('${FILTER}','') is null or name like '%${FILTER}%')
            order by name loop
    begin
      execute t.body;
      v_fail := v_fail + 1;
      raise notice 'FAIL  %  (no RG_ROLLBACK — the probe never reached its assertions)', t.name;
    exception when others then
      if sqlerrm like '%RG_ROLLBACK%' then
        v_pass := v_pass + 1; raise notice 'PASS  %', t.name;
      else
        v_fail := v_fail + 1; raise notice 'FAIL  %  %', t.name, sqlerrm;
      end if;
    end;
  end loop;
  raise notice 'TOTAL pass=% fail=%', v_pass, v_fail;
end \$outer\$;" 2>&1)

echo "$OUT" | sed 's/^NOTICE:  //'
if echo "$OUT" | grep -q 'FAIL '; then
  echo "── an edge double-applied. Fix the edge, never the probe. ──────────────"
  exit 1
fi
if ! echo "$OUT" | grep -q 'TOTAL pass='; then
  echo "── the probe runner itself did not report. ─────────────────────────────"
  exit 2
fi
echo "── every audited edge survived being fired twice. ──────────────────────"

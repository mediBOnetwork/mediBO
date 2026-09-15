#!/usr/bin/env bash
# CHANGE #301 — proof that the DB lane serialises ONLY the migration step.
#
# Om's hard constraint: overall build time must stay ~unchanged, and only the
# rare exclusive operations may ever queue — never coding, flutter tests, web
# builds or ordinary small queries.
#
# Two workers run the same three-phase job concurrently:
#   phase A  "coding"        — no lock, fully parallel
#   phase M  migration       — DDL + a write; the ONLY phase that takes the lane
#   phase C  "tests + build" — no lock, fully parallel
# Run once WITHOUT the lane (today's behaviour) and once WITH it. The difference
# between the two totals is the entire cost of the fix.
#
#   bash scripts/db_lane_parallel_proof.sh [code_seconds] [test_seconds]
set -uo pipefail
D="$HOME/mediBO-runner/devcmd.sh"
set -a; . "$HOME/.medibo/pgenv"; set +a
CODE_S="${1:-20}"; TEST_S="${2:-20}"
OUT="${TMPDIR:-/tmp}/c301_proof.$$"; mkdir -p "$OUT"

migration() { # <n> — a real exclusive step: DDL + a write + an index
  psql -qAt -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
create table if not exists public._c301_proof_$1 (id int primary key, payload text);
truncate public._c301_proof_$1;
insert into public._c301_proof_$1 select g, md5(g::text) from generate_series(1,40000) g;
create index if not exists _c301_proof_${1}_idx on public._c301_proof_$1 (payload);
analyze public._c301_proof_$1;
drop table public._c301_proof_$1;
SQL
}

worker() { # <n> <lane|nolane>
  local n="$1" mode="$2" t0 m0 m1 t1 w0 r tok ok w waited=0
  t0=$(date +%s)
  sleep "$CODE_S"                              # phase A — never locked
  w0=$(date +%s)
  if [ "$mode" = lane ]; then
    while :; do
      r=$("$D" dblock "proof-$n" exclusive "#301 proof migration $n" 5 301)
      ok=$(jq -r '.ok // false' <<<"$r")
      [ "$ok" = "true" ] && break
      w=$(jq -r '.retry_after_seconds // 45' <<<"$r")
      echo "  worker $n: lane busy, waiting ${w}s" >&2
      sleep "$w"
    done
    tok=$(jq -r .token <<<"$r")
  fi
  waited=$(( $(date +%s) - w0 ))
  m0=$(date +%s); migration "$n"; m1=$(date +%s)
  [ "$mode" = "lane" ] && "$D" dbunlock "$tok" >/dev/null 2>&1
  sleep "$TEST_S"                              # phase C — never locked
  t1=$(date +%s)
  echo "$n $mode total=$((t1-t0)) waited_for_lane=${waited} migration=$((m1-m0))" > "$OUT/w$n.$mode"
}

run_pair() { # <lane|nolane> -> prints total wall seconds
  local mode="$1" s e
  s=$(date +%s)
  worker 1 "$mode" & worker 2 "$mode" &
  wait
  e=$(date +%s)
  echo $((e-s))
}

echo "== CHANGE #301 — DB lane parallel proof =="
echo "phases per worker: coding ${CODE_S}s (no lock) · migration 40k-row DDL+write (lane) · tests+build ${TEST_S}s (no lock)"
echo
echo "-- run 1: WITHOUT the lane (today's behaviour) --"
BASE=$(run_pair nolane); cat "$OUT"/w*.nolane
echo "total wall time: ${BASE}s"
echo
echo "-- run 2: WITH the lane --"
LANE=$(run_pair lane); cat "$OUT"/w*.lane
echo "total wall time: ${LANE}s"
echo
DELTA=$((LANE-BASE))
echo "delta: ${DELTA}s  (only the migration phase can queue; coding, tests and builds never wait)"

# Put the delta in proportion against what a real command actually costs, read
# live from the registry rather than asserted.
MED=$(psql -qAt -c "select round(percentile_cont(0.5) within group (order by extract(epoch from (finished_at - started_at)))/60)::int
                      from public.dev_commands
                     where status='completed' and started_at is not null and finished_at > started_at
                       and finished_at > now() - interval '14 days';" 2>/dev/null)
if [ -n "${MED:-}" ] && [ "${MED:-0}" -gt 0 ]; then
  echo "in proportion: the median completed command takes ${MED} min, so a contended migration costs about $(( DELTA * 100 / (MED * 60) ))% of one build — and only for the worker that collided."
fi
rm -rf "$OUT"

#!/usr/bin/env bash
# CHANGE #755 — proof for the self-healing runner breaker.
#
# Runs the rg behaviour `c755_self_healing_breaker` against the LIVE controller
# and the LIVE config, inside a subtransaction that always rolls back, then
# prints today's trip/resume log and the probe's run counters.
#
# It proves three things, in the order the spec asked for them:
#   1. ten DB timeouts drive the score into the black band -> semaphore 0,
#      Workflow paused, and ONE deduped "Slow call: <fn> — bound it" filed,
#   2. a database that comes back green auto-resumes the fleet by itself,
#   3. a MANUAL Workflow OFF survives both, and a second trip inside the
#      cooldown window doubles the green streak the resume has to wait for.
#
# Usage: bash scripts/c755_breaker_proof.sh
set -euo pipefail
PGURL="$(cat "$HOME/.medibo/dburl")"

echo "── behaviour: c755_self_healing_breaker ─────────────────────────────"
psql "$PGURL" -Xqt -A -v ON_ERROR_STOP=1 <<'SQL'
do $proof$
declare t record; v_ok boolean; v_err text;
begin
  select * into t from public.rg_behavior_tests where name = 'c755_self_healing_breaker';
  if t.name is null then raise exception 'c755: the behaviour test is not registered'; end if;
  if not t.enabled then raise exception 'c755: the behaviour test is disabled'; end if;
  begin
    execute t.body;
    raise exception 'RG_NO_MARKER';
  exception when others then
    if    sqlerrm = 'RG_ROLLBACK'  then v_ok := true;  v_err := null;
    elsif sqlerrm = 'RG_NO_MARKER' then v_ok := false; v_err := 'body did not roll back';
    else  v_ok := false; v_err := sqlerrm; end if;
  end;
  if not v_ok then raise exception 'c755 PROOF FAILED: %', v_err; end if;
  raise notice 'c755 PROOF PASSED — pause, auto-resume and manual-OFF all held';
end $proof$;
SQL

echo
echo "── probe cadence (the bound: zero runs while the queue is idle) ─────"
psql "$PGURL" -Xqt -A -F' | ' -c "
  select name, enabled, base_interval_s || 's base', max_interval_s || 's idle ceiling',
         current_interval_s || 's now', 'runs=' || runs, 'skips=' || skips,
         coalesce(last_result,'-')
    from public.cron_task where name = 'runner_health_probe';"

echo
echo "── the bound: the gate is FALSE the moment the queue goes idle ──────"
# Om's rule is that the probe stops entirely when the queue is idle. That is a
# property of the cron row's own gate, so this runs the STORED gate verbatim
# and then runs it again with only the queue term forced false. A false gate is
# a `skips`, never a `runs` — which is why an idle hour reads runs=+0.
psql "$PGURL" -Xqt -A -v ON_ERROR_STOP=1 <<'SQL'
do $gate$
declare g text; v_live boolean; v_idle boolean;
begin
  select gate_sql into g from public.cron_task where name = 'runner_health_probe';
  execute g into v_live;
  execute replace(g,
    'exists (select 1 from public.dev_commands where status in (''pending'',''building''))',
    'false') into v_idle;
  raise notice 'gate with the queue as it is now : %', v_live;
  raise notice 'gate with an IDLE queue          : %', v_idle;
  if v_idle is not false then
    raise exception 'c755 PROOF FAILED: the probe would keep running on an idle queue';
  end if;
end $gate$;
SQL

echo
echo "── health score, latest ─────────────────────────────────────────────"
psql "$PGURL" -Xqt -A -F' | ' -c "
  select to_char(at at time zone 'Asia/Kolkata','DD Mon HH24:MI') , 'score=' || score,
         'sem=' || coalesce(semaphore::text,'-'), 'streak=' || green_streak,
         'timeouts=' || timeouts_5min, 'p95=' || coalesce(latency_p95_ms::text,'-') || 'ms',
         action
    from public.dev_runner_health order by at desc limit 5;"

echo
echo "── trips & resumes today (IST) ──────────────────────────────────────"
psql "$PGURL" -Xqt -A -F' | ' -c "
  select to_char(at at time zone 'Asia/Kolkata','DD Mon HH24:MI'), kind,
         coalesce(score::text,'-'), coalesce(semaphore::text,'-'), reason
    from public.dev_runner_breaker_event
   where at >= (date_trunc('day', now() at time zone 'Asia/Kolkata')) at time zone 'Asia/Kolkata'
   order by at;"

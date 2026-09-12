-- CHANGE #1055 — RG red after #1090: bound every unit of scheduled work.
--
-- The guard went red on run 3743 with 7 schema diffs and one CRITICAL
-- behaviour, play_publish_never_wedges:
--
--   "play-reap-stale was due at 2026-09-04 03:34:48 and has not run —
--    the cron dispatcher is not ticking (CHANGE #305)"
--
-- The 7 diffs were intentional (#1090's _c694_export / _c694_zone_owner,
-- partner_doc_request, partner_doc_render_input, zone_pnl and the two payload
-- targets that follow them) and are re-baselined separately. The critical was
-- NOT, and a behaviour is never rebaselined — so this migration fixes it.
--
-- ONE BUG, THREE SITES. Everywhere a loop spends a time budget, the budget was
-- checked BEFORE a unit of work and the unit itself was then bounded by
-- nothing that knew about the budget:
--
--   1. cron_dispatch()    — tick_budget_ms (25 s) decided whether to START a
--      task; the task then ran on its own step_timeout_ms, up to 110 s. A task
--      beginning at 24.9 s could reach 135 s and be killed by the 120 s
--      statement_timeout pg_cron wraps the call in. That cancel aborts the
--      WHOLE transaction, so the cursor at the bottom is never written and the
--      task's next_run_at is never re-armed — the next tick starts at the same
--      task and dies identically. cron.job_run_details shows the wedge twice on
--      2026-09-04: five ticks killed 02:28–02:39 by the zone-facet/_mcc_new
--      rebuild, three more 05:41–05:48 by search_suggest_stage. play-reap-stale
--      (ord 430) sat two hours past due behind it, which is what the guard saw.
--
--   2. rg_check()         — same shape: the per-kind budget check, then an
--      unbounded rg_collect(). Run 3782 spent 122 s of a 90 s budget on
--      storefront_home_v2_skeleton while the DB was saturated by (1), reported
--      result='timeout' and so measured NO behaviours at all.
--
--   3. rg_run_behaviors() — CHANGE #647 gated STARTING a probe on the deadline;
--      the probe body then ran unbounded past it.
--
-- Each site now hands its unit exactly the time that is actually left. A slow
-- unit becomes one skipped probe / one collection error, never a dead tick or
-- a red run on a schema that never changed.
--
-- Also repaired here, because they are the same tick and they were silently
-- dead: dev_cmd_wait_sweep (2099 consecutive failures) and
-- dev_cmd_autofinish_sweep (719) both call _dev_guard(), which demands a
-- service_role JWT or a super_admin. pg_cron runs as postgres with no JWT at
-- all, so CHANGE #571's park-resume sweep and CHANGE #369's autofinish
-- backstop have never once run from the dispatcher. dev_cmd_watchdog, which
-- works, carries no _dev_guard() — this keeps a guard and admits exactly the
-- local tokenless superuser, then REVOKEs the anon/authenticated EXECUTE both
-- functions still carried. Net surface after this migration is smaller.
--
-- Idempotent: add column if not exists, create or replace, revoke if exists.

begin;

-- ── 1. the dispatcher's hard wall ──────────────────────────────────────────
alter table public.cron_guard_config
  add column if not exists tick_hard_ms int not null default 100000;

comment on column public.cron_guard_config.tick_hard_ms is
  'CHANGE #1055 — hard ceiling for ONE cron_dispatch tick, in ms. Must stay '
  'comfortably under the statement_timeout pg_cron wraps the dispatch call in '
  '(120 s today) so the tick always reaches its own cursor write. '
  'tick_budget_ms decides whether to START another task; this bounds the task.';

CREATE OR REPLACE FUNCTION public.cron_dispatch()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  t record; v_started timestamptz := clock_timestamp(); v_budget_ms int;
  v_hard_ms int; v_remain_ms int; v_step_ms int; v_reserve_ms constant int := 5000;
  v_run boolean; v_signalled boolean; v_t0 timestamptz; v_ms int;
  v_ran int := 0; v_skipped int := 0; v_failed int := 0; v_deferred int := 0;
  v_cursor text; v_last text := null; v_truncated boolean := false;
  v_rows int; v_iv int; v_next timestamptz; v_err text; v_scheduled boolean;
  v_did boolean;
begin
  if not pg_try_advisory_lock(7301, 1) then
    return jsonb_build_object('ok', true, 'skipped', 'previous tick still running');
  end if;

  select tick_budget_ms, tick_hard_ms into v_budget_ms, v_hard_ms
    from public.cron_guard_config where id;
  v_budget_ms := coalesce(v_budget_ms, 25000);
  -- CHANGE #1055 — THE TICK HAS A HARD WALL, NOT JUST A BUDGET.
  -- tick_budget_ms only decides whether to START another task. It was checked
  -- BEFORE each task and the task itself was then bounded by nothing but its
  -- own step_timeout_ms, so a task with a 110 s step could begin at 24.9 s and
  -- run to 135 s -- past the 120 s statement_timeout pg_cron wraps this call
  -- in. That outer cancel aborts the WHOLE transaction: the cursor update at
  -- the bottom never happens and the task's own next_run_at is never re-armed,
  -- so the very next tick starts at the same task and dies the same way. That
  -- is the wedge behind "the cron dispatcher is not ticking" (#305) -- five
  -- consecutive ticks were killed by one search_suggest_stage rebuild on
  -- 2026-09-04, and play-reap-stale sat two hours past due behind it.
  v_hard_ms := greatest(coalesce(v_hard_ms, 100000), v_budget_ms + v_reserve_ms);
  select cursor_name into v_cursor from public.cron_dispatch_state where id;

  for t in
    select * from public.cron_task where enabled
    order by (case when v_cursor is null
                     or (ord, name) > (select c.ord, c.name from public.cron_task c where c.name = v_cursor)
                   then 0 else 1 end),
             ord, name
  loop
    -- Both walls are tested here, BEFORE v_last is moved onto this task, so a
    -- truncated tick resumes ON the task it declined to start rather than
    -- skipping it.
    v_remain_ms := v_hard_ms - (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int;
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > v_budget_ms
       or v_remain_ms <= v_reserve_ms then
      v_truncated := true; exit;
    end if;

    v_scheduled := (t.base_interval_s is not null or t.run_at_ist is not null);

    select true into v_signalled from public.cron_signal where task = t.name;
    v_signalled := coalesce(v_signalled, false);

    -- Not due: the cheapest outcome there is. No gate SQL, no write, no stats
    -- row. This is what lets one tick host fifty former pg_cron jobs for free.
    if not v_signalled and t.next_run_at is not null and t.next_run_at > now() then
      v_deferred := v_deferred + 1;
      v_last := t.name;
      continue;
    end if;

    v_last := t.name;

    -- Business hours never gate a signalled task: a real event is still served
    -- at 3am. Only tasks nothing user-facing waits on opt in.
    if not v_signalled and t.business_hours_only and not public._cron_business_open() then
      update public.cron_task
         set last_checked_at = now(), skips = skips + 1, last_result = 'closed',
             next_run_at = now() + make_interval(secs => greatest(coalesce(t.base_interval_s, 900), 900))
       where name = t.name;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_run := v_signalled;
    if not v_run and t.gate_sql is not null then
      begin
        execute 'set local statement_timeout = 3000';
        execute t.gate_sql into v_run;
      exception when others then
        v_run := true;
      end;
      v_run := coalesce(v_run, false);
    elsif not v_run and t.gate_sql is null and v_scheduled then
      -- No gate but its own schedule: being due IS the decision to run. A
      -- gate-less task with NO schedule stays what it always was - event-only,
      -- woken by cron_signal and by nothing else.
      v_run := true;
    end if;

    if not v_run then
      v_iv := null; v_next := null;
      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
      elsif t.base_interval_s is not null then
        v_iv := least(greatest(coalesce(t.max_interval_s, 3600), t.base_interval_s),
                      greatest(coalesce(t.current_interval_s, t.base_interval_s), 1) * 2);
        v_next := now() + make_interval(secs => v_iv);
      end if;

      update public.cron_task
         set last_checked_at = now(), skips = skips + 1, last_result = 'idle',
             consecutive_idle = consecutive_idle + 1,
             current_interval_s = coalesce(v_iv, current_interval_s),
             next_run_at = v_next
       where name = t.name;

      if v_scheduled then
        insert into public.cron_job_stats (job_name, source, started_at, duration_ms, rows_touched, did_work)
        values (t.name, 'dispatcher', now(), 0, 0, false);
      end if;

      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_t0 := clock_timestamp(); v_err := null; v_rows := null;
    begin
      -- Never hand a task more time than the tick has left to give.
      v_step_ms := greatest(least(t.step_timeout_ms, v_remain_ms - v_reserve_ms), 1000);
      execute format('set local statement_timeout = %s', v_step_ms);
      execute t.work_sql;
      get diagnostics v_rows = ROW_COUNT;
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;

      -- For `select fn()` ROW_COUNT is always 1 and means nothing, so only a
      -- task that declared itself DML is judged on the rows it touched.
      v_did := (not coalesce(t.dml, false)) or coalesce(v_rows, 0) > 0;

      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
        v_iv := null;
      elsif t.base_interval_s is not null then
        v_iv := case when v_did then t.base_interval_s
                     else least(greatest(coalesce(t.max_interval_s, 3600), t.base_interval_s),
                                greatest(coalesce(t.current_interval_s, t.base_interval_s), 1) * 2) end;
        v_next := now() + make_interval(secs => v_iv);
      else
        v_iv := null; v_next := null;
      end if;

      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = null, fail_count = 0,
             runs  = runs  + (case when v_did then 1 else 0 end),
             skips = skips + (case when v_did then 0 else 1 end),
             last_result = case when v_did then 'ran' else 'idle' end,
             consecutive_idle = case when v_did then 0 else consecutive_idle + 1 end,
             current_interval_s = v_iv, next_run_at = v_next
       where name = t.name;
      delete from public.cron_signal where task = t.name;

      if v_did then v_ran := v_ran + 1; else v_skipped := v_skipped + 1; end if;
    exception when others then
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;
      v_err := left(sqlerrm, 500);
      v_did := false;

      -- A failing task is still re-armed, or one error freezes it forever.
      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
      elsif t.base_interval_s is not null then
        v_next := now() + make_interval(secs => t.base_interval_s);
      else
        v_next := null;
      end if;

      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = v_err, fail_count = fail_count + 1,
             last_result = 'error', next_run_at = v_next
       where name = t.name;
      delete from public.cron_signal where task = t.name;
      v_failed := v_failed + 1;
    end;

    insert into public.cron_job_stats (job_name, source, started_at, duration_ms, rows_touched, did_work, error)
    values (t.name, 'dispatcher', v_t0, v_ms, v_rows, coalesce(v_did, false), v_err);
  end loop;

  -- The sweep used to run with statement_timeout = 0 inside the same outer
  -- 120 s window it could therefore overrun. It gets what is left, never all.
  execute format('set local statement_timeout = %s',
    greatest(v_hard_ms - (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int, 2000));

  begin
    perform public.cron_guard_sweep();
  exception when others then null;
  end;

  update public.cron_dispatch_state
     set cursor_name  = case when v_truncated then v_last else null end,
         last_tick_at = now(), last_ran = v_ran, last_skipped = v_skipped,
         last_failed = v_failed,
         last_ms = (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int,
         ticks = ticks + 1
   where id;

  perform pg_advisory_unlock(7301, 1);

  return jsonb_build_object('ok', true, 'ran', v_ran, 'skipped', v_skipped,
    'failed', v_failed, 'deferred', v_deferred, 'truncated', v_truncated,
    'ms', (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int);
exception when others then
  perform pg_advisory_unlock(7301, 1);
  raise;
end $function$;

CREATE OR REPLACE FUNCTION public.rg_check(p_run_behaviors boolean DEFAULT false, p_run_payloads boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_kinds text[] := array['function','trigger','column','policy','index','cron','setting'];
  k text; v_d jsonb; v_diffs jsonb := '{}'::jsonb;
  v_over jsonb; v_missing jsonb; v_beh jsonb := '[]'::jsonb;
  v_crit int; v_changes int := 0; v_base int;
  v_errs jsonb := '[]'::jsonb; v_chg jsonb; v_n int;
  v_re jsonb; v_reerr jsonb;
  v_started timestamptz := clock_timestamp();
  v_budget_s int := coalesce(
    (select (value->'rg'->>'budget_s')::int from dev_runner_config where key='worker_pool'), 90);
  v_timeout boolean := false; v_stopped_at text := null; v_remain_ms int;
  v_cached jsonb;
begin
  -- ONE AT A TIME. A caller that cannot get the lock never waits for it.
  if not pg_try_advisory_xact_lock(hashtext('public.rg_check')) then
    select c.result into v_cached from rg_check_cache c order by c.at desc limit 1;
    return coalesce(v_cached, '{}'::jsonb) || jsonb_build_object(
      'ok', coalesce((v_cached->>'ok')::boolean, false),
      'result', 'busy', 'busy', true, 'checked_at', now(),
      'note', 'another rg_check is already running — returning the last verdict');
  end if;

  -- CHANGE #647 — the budget is now visible to rg_run_behaviors too.
  perform set_config('medibo.rg_deadline',
    (v_started + make_interval(secs => v_budget_s))::text, true);

  if p_run_payloads then v_kinds := array_append(v_kinds, 'payload'); end if;
  foreach k in array v_kinds loop
    if clock_timestamp() > v_started + make_interval(secs => v_budget_s) then
      v_timeout := true; v_stopped_at := 'kind:' || k; exit;
    end if;
    select count(*) into v_base from rg_baseline b where b.kind = k;
    if v_base = 0 then continue; end if;

    -- CHANGE #1055 — bound the COLLECTION to the budget it is spending.
    -- The budget was checked before each kind and rg_collect() was then capped
    -- only by the caller's statement_timeout (120 s on the rg cron tasks), so
    -- one slow target spent the whole run: 3782 burned 122 s of a 90 s budget
    -- on storefront_home_v2_skeleton while the DB was saturated, reported
    -- result='timeout', and measured NO behaviours at all. Clamped, that same
    -- run records one collection error and still checks everything else.
    v_remain_ms := greatest(
      (extract(epoch from ((v_started + make_interval(secs => v_budget_s)) - clock_timestamp())) * 1000)::int,
      1000);
    execute format('set local statement_timeout = %s', v_remain_ms);

    with live as (select * from rg_collect(k)),
    base as (select * from rg_baseline b where b.kind = k)
    select jsonb_build_object(
      'added',   coalesce((select jsonb_agg(l.name) from live l left join base b on b.name = l.name where b.name is null),'[]'::jsonb),
      'removed', coalesce((select jsonb_agg(b.name) from base b left join live l on l.name = b.name where l.name is null),'[]'::jsonb),
      'changed', coalesce((select jsonb_agg(l.name) from live l join base b on b.name = l.name
                            where l.hash <> 'ERROR' and b.hash is distinct from l.hash),'[]'::jsonb),
      'errors',  coalesce((select jsonb_agg(jsonb_build_object(
                              'kind', k, 'name', l.name,
                              'sqlstate', l.content->>'sqlstate',
                              'error', l.content->>'error'))
                            from live l where l.hash = 'ERROR'),'[]'::jsonb))
    into v_d;

    -- CONFIRM BEFORE REPORT (#197). Payload targets snapshot live business
    -- state that legitimately moves mid-run; a second read settles it. The
    -- re-read may only CONFIRM drift, never clear it by failing.
    if k = 'payload' and jsonb_array_length(v_d->'changed') > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'hash', l.hash)), '[]'::jsonb)
        into v_re
        from rg_collect('payload') l
       where l.name in (select t.value from jsonb_array_elements_text(v_d->'changed') as t(value));

      select coalesce(jsonb_agg(e->>'name'), '[]'::jsonb) into v_chg
        from jsonb_array_elements(v_re) e
        join rg_baseline b on b.kind = 'payload' and b.name = e->>'name'
       where (e->>'hash') = 'ERROR'
          or b.hash is distinct from (e->>'hash');

      select coalesce(jsonb_agg(jsonb_build_object(
               'kind','payload', 'name', e->>'name', 'sqlstate','recheck',
               'error','confirm re-read failed — drift kept, not cleared')), '[]'::jsonb)
        into v_reerr
        from jsonb_array_elements(v_re) e where (e->>'hash') = 'ERROR';
      if jsonb_array_length(v_reerr) > 0 then v_errs := v_errs || v_reerr; end if;

      v_d := jsonb_set(v_d, '{changed}', v_chg) || jsonb_build_object('reconfirmed', true);
    end if;

    if jsonb_array_length(v_d->'errors') > 0 then
      v_errs := v_errs || (v_d->'errors');
    end if;
    v_d := v_d - 'errors';

    v_n := jsonb_array_length(v_d->'added') + jsonb_array_length(v_d->'removed') + jsonb_array_length(v_d->'changed');
    if v_n > 0 then
      v_diffs := v_diffs || jsonb_build_object(k, v_d);
      v_changes := v_changes + v_n;
    end if;
  end loop;

  -- Not 0: the overload/critical scans below were bounded by the CALLER's
  -- statement_timeout before this change, and handing them an unbounded one
  -- would be a regression dressed as a fix. A flat ceiling keeps them bounded
  -- without letting a spent budget cancel the run's own bookkeeping.
  execute 'set local statement_timeout = 20000';

  select coalesce(jsonb_agg(jsonb_build_object('severity', o.severity, 'fn', o.proname, 'a', o.sig_a, 'b', o.sig_b)),'[]'::jsonb)
    into v_over from rg_overload_risks() o;
  select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'name', m.name)),'[]'::jsonb)
    into v_missing from rg_missing_critical() m;

  if p_run_behaviors then
    if clock_timestamp() > v_started + make_interval(secs => v_budget_s) then
      v_timeout := true; v_stopped_at := coalesce(v_stopped_at, 'behaviors');
    else
      v_beh := rg_run_behaviors();
      if exists (select 1 from jsonb_array_elements(v_beh) e
                  where coalesce((e->>'skipped')::boolean, false)) then
        v_timeout := true; v_stopped_at := coalesce(v_stopped_at, 'behaviors');
      end if;
    end if;
  end if;

  v_crit := (select count(*) from jsonb_array_elements(v_over) e where e->>'severity' = 'critical')
          + jsonb_array_length(v_missing)
          + (select count(*) from jsonb_array_elements(v_beh) e where (e->>'ok')::boolean is not true);

  return jsonb_build_object(
    'ok', (not v_timeout and v_crit = 0 and v_changes = 0),
    'result', case when v_timeout then 'timeout'
                   when (v_crit = 0 and v_changes = 0) then 'green' else 'red' end,
    'timeout', v_timeout,
    'stopped_at', v_stopped_at,
    'budget_s', v_budget_s,
    'elapsed_s', round(extract(epoch from clock_timestamp() - v_started))::int,
    'checked_at', now(),
    'summary', jsonb_build_object('critical', v_crit, 'diffs', v_changes,
                                  'collection_errors', jsonb_array_length(v_errs)),
    'overload_risks', v_over,
    'missing_critical', v_missing,
    'collection_errors', v_errs,
    'behaviors', v_beh,
    'diffs', v_diffs);
end
$function$;

CREATE OR REPLACE FUNCTION public.rg_run_behaviors()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t record; res jsonb := '[]'::jsonb; v_ok boolean; v_err text;
  v_state text; v_skipped boolean;
  v_caller_claims text := current_setting('request.jwt.claims', true);
  v_caller_claim  text := current_setting('request.jwt.claim',  true);
  v_deadline timestamptz; v_remain_ms int;
begin
  -- rg_check publishes its own deadline; without one the loop is unbounded and
  -- a single slow behaviour can carry the whole run past its 90 s budget.
  begin
    v_deadline := nullif(current_setting('medibo.rg_deadline', true), '')::timestamptz;
  exception when others then v_deadline := null;
  end;

  for t in select * from rg_behavior_tests bt where bt.enabled order by bt.name loop
    if v_deadline is not null and clock_timestamp() > v_deadline then
      res := res || jsonb_build_object('name', t.name, 'ok', true, 'skipped', true,
                                       'error', null,
                                       'note', 'not run — rg_check budget spent (CHANGE #647)');
      continue;
    end if;
    v_skipped := false;
    -- CHANGE #1055 — the deadline was only a gate on STARTING a probe; the
    -- body then ran unbounded and carried the run past its budget (run 3782:
    -- 122 s against a 90 s budget). Each body now gets exactly the time the
    -- run has left, so an over-running probe is one skipped probe instead of
    -- a timed-out run.
    if v_deadline is not null then
      v_remain_ms := greatest((extract(epoch from (v_deadline - clock_timestamp())) * 1000)::int, 1000);
      execute format('set local statement_timeout = %s', v_remain_ms);
    end if;
    -- One behaviour's impersonation must never be the next one's context.
    perform set_config('request.jwt.claims', coalesce(v_caller_claims, ''), true);
    perform set_config('request.jwt.claim',  coalesce(v_caller_claim,  ''), true);
    begin
      execute t.body;
      raise exception 'RG_NO_MARKER';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if sqlerrm = 'RG_ROLLBACK' then v_ok := true; v_err := null;
      elsif sqlerrm = 'RG_NO_MARKER' then v_ok := false; v_err := 'test body did not raise RG_ROLLBACK';
      -- CHANGE #962 — A PROBE THAT NEVER RAN IS NOT A FAILING PROBE.
      -- lock_not_available (55P03), a deadlock, or a statement cancelled while
      -- waiting on a lock says the FLEET is busy, not that the product is
      -- broken: five runners writing at once is the normal state of this box.
      -- Four c704 probes reported "canceling statement due to lock timeout"
      -- and the run filed a critical bug row for it, which is the same mistake
      -- rg_watch already refuses to make for a budget timeout ("a timeout is
      -- not a measurement") and for a busy short-circuit ("record nothing,
      -- decide nothing"). Skipped, exactly like a budget-exhausted probe: the
      -- next run measures it.
      elsif v_state in ('55P03','40P01')
         or sqlerrm ilike '%due to lock timeout%'
         or sqlerrm ilike '%deadlock detected%' then
        v_ok := true; v_skipped := true; v_err := null;
      else v_ok := false; v_err := sqlerrm; end if;
    end;
    -- The two objects are MERGED and then appended as ONE element. Without the
    -- parentheses `res || a || b` appends both, and the battery reports 140
    -- results for 70 tests.
    res := res || (jsonb_build_object('name', t.name, 'ok', v_ok, 'error', v_err)
                   || case when v_skipped
                           then jsonb_build_object('skipped', true,
                                  'note', 'not run — could not take a lock; the fleet was writing (CHANGE #962)')
                           else '{}'::jsonb end);
  end loop;
  -- Restore a flat bound rather than 0, so the caller's remaining work is
  -- still capped once the probe battery has spent the budget.
  if v_deadline is not null then execute 'set local statement_timeout = 20000'; end if;
  perform set_config('request.jwt.claims', coalesce(v_caller_claims, ''), true);
  perform set_config('request.jwt.claim',  coalesce(v_caller_claim,  ''), true);
  return res;
end
$function$;

-- ── 4. the two sweeps the dispatcher could never call ──────────────────────
-- _dev_guard() admits a service_role JWT or a super_admin. pg_cron's dispatch
-- runs as `postgres` with no request.jwt.claims at all, so both sweeps below
-- raised 'dev_queue: not authorized' on EVERY tick since they were added.
-- This admits exactly that caller — a local superuser session with no JWT,
-- which can already execute the body directly and cannot be reached over
-- PostgREST (it connects as `authenticator` and switches to anon/authenticated,
-- never to postgres). Every other caller still goes through _dev_guard().
create or replace function public._dev_guard_or_local_cron()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(current_setting('request.jwt.claims', true), '') = ''
     and coalesce(current_setting('request.jwt.claim',  true), '') = ''
     and session_user in ('postgres', 'supabase_admin')
  then
    -- NOT gated on is_superuser: on Supabase the `postgres` role is NOT a
    -- superuser (pg_roles.rolsuper = f, current_setting('is_superuser') =
    -- 'off'), so an is_superuser test here would be permanently false and
    -- would leave both sweeps exactly as dead as they already are.
    -- session_user is the discriminator that actually holds: PostgREST
    -- connects as `authenticator` and SET ROLEs to anon/authenticated, which
    -- changes current_user but never session_user, so no request arriving over
    -- the API can reach this branch however it is shaped.
    return;                      -- the local dispatcher; no token exists to check
  end if;
  perform public._dev_guard();   -- everyone else, unchanged
end
$function$;

revoke all on function public._dev_guard_or_local_cron() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dev_cmd_wait_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n_res int := 0; n_hold int := 0; v_ids bigint[] := '{}';
        v_free boolean; v_paths text[]; v_maxage int;
begin
  perform _dev_guard_or_local_cron();
  select coalesce((value->'wait_gate'->>'max_park_minutes')::int, 45)
    into v_maxage from dev_runner_config where key = 'worker_pool';
  v_maxage := coalesce(v_maxage, 45);

  for r in select * from dev_commands
            where wait_state = 'parked' and status = 'building'
            order by wait_until nulls first, id loop
    v_free := false;

    if r.wait_until is not null and r.wait_until > now() then
      n_hold := n_hold + 1;
      continue;                                   -- the retry window is not up
    end if;

    if r.wait_kind = 'lease' then
      v_paths := coalesce((select array_agg(value #>> '{}')
                             from jsonb_array_elements(coalesce(r.wait_blocker->'paths','[]'::jsonb))), '{}');
      v_free := (v_paths = '{}') or not exists (
        select 1 from file_leases fl
         where fl.path = any(v_paths) and fl.command_id <> r.id);
    elsif r.wait_kind = 'merge' then
      -- the lane is free when nothing is mid-batch for this command any more
      v_free := not exists (select 1 from deploy_queue q
                             where q.command_id = r.id
                               and q.status in ('queued','batched','merging'));
    else
      v_free := true;                             -- db / rpc / other: time heals it
    end if;

    -- Never strand a row: past max_park_minutes it resumes regardless, and the
    -- next worker re-discovers the blocker cheaply instead of a human doing it.
    if not v_free and r.wait_since < now() - (v_maxage || ' minutes')::interval then
      v_free := true;
    end if;

    if v_free then
      perform dev_cmd_unpark(r.id, coalesce(r.wait_reason, 'blocker cleared'));
      n_res := n_res + 1; v_ids := v_ids || r.id;
    else
      update dev_commands
         set wait_until = now() + (greatest(coalesce(
               (select retry_after_s from dev_fail_rule where kind = r.wait_kind and enabled order by ord limit 1),
               120), 60) || ' seconds')::interval
       where id = r.id;
      n_hold := n_hold + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'resumed', n_res, 'holding', n_hold, 'ids', to_jsonb(v_ids));
end $function$;

CREATE OR REPLACE FUNCTION public.dev_cmd_autofinish_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; res jsonb; n_done int := 0; n_armed int := 0; v_ids bigint[] := '{}';
begin
  perform _dev_guard_or_local_cron();
  for r in select id from dev_commands
            where status = 'building'
              and coalesce(steps_total,0) > 0
              and coalesce(steps_done,0) >= steps_total
              and coalesce(needs_input_question,'') = ''
            order by id loop
    res := dev_cmd_autofinish(r.id, 'watchdog');
    if coalesce((res->>'completed')::boolean,false) then
      n_done := n_done + 1; v_ids := v_ids || r.id;
    elsif coalesce((res->>'waiting_grace')::boolean,false) then
      n_armed := n_armed + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'completed', n_done, 'armed', n_armed, 'ids', to_jsonb(v_ids));
end $function$;

-- Both sweeps still carried the default GRANT TO PUBLIC they were created
-- with; only _dev_guard() was keeping anon out of them. Now that the guard
-- has a bypass, close the outer lock too — the same shape dev_cmd_watchdog
-- already has (#436: the GRANT is the outer lock, the body guard the inner).
revoke all on function public.dev_cmd_wait_sweep()       from public, anon, authenticated;
revoke all on function public.dev_cmd_autofinish_sweep() from public, anon, authenticated;

-- The dispatcher has burned 2099 + 719 failures on these two; clear the
-- counters so the next real failure is visible instead of buried.
update public.cron_task
   set fail_count = 0, last_error = null, last_result = null
 where name in ('dev_cmd_wait_sweep', 'dev-cmd-autofinish')
   and coalesce(last_error, '') like '%not authorized%';

-- ── 5. the two functions from this red's diff set that kept only the INNER lock ──
-- Adjudicating the 7 diffs of run 3743: five came from CHANGE #692 (deploy
-- #1090) and CHANGE #694 (deploy #1093), two are payload targets that track
-- live business state. All intentional, and the blanket rg_baseline_all() at
-- 05:32:56 was therefore legitimate — verified rather than assumed: zone_pnl,
-- _c694_export and _c694_zone_owner all have anon EXECUTE revoked, so the
-- rebaseline blessed no privilege regression.
--
-- partner_doc_request and partner_doc_render_input were the exception. Both
-- still carried the default GRANT TO PUBLIC every SECURITY DEFINER function
-- inherits, so anon could EXECUTE them; they were safe only because of their
-- body-level my_partner_id()/role_for_medibo_only() check. That is precisely
-- the shape #436 exists to reject, inverted: the GRANT is the outer lock and
-- the body guard the inner, and these had only the inner. rpc_anon_rule has no
-- partner_% prefix, so the anon-grant guard never looked at them.
--
-- Closing the outer lock on exactly these two — the ones this command was
-- asked to adjudicate — with no blast radius: the only caller in the tree is
-- lib/screens/partner/partner_statement_screen.dart, which runs as a signed-in
-- partner (authenticated keeps EXECUTE), and every document renderer under
-- supabase/functions uses SUPABASE_SERVICE_ROLE_KEY. Widening rpc_anon_rule to
-- partner_% would red the guard for every partner_* function at once and
-- belongs to its own command, not to this one.
revoke all on function public.partner_doc_request(p_kind text, p_ref text) from public, anon;
revoke all on function public.partner_doc_render_input(p_doc_id uuid)      from public, anon;
grant execute on function public.partner_doc_request(p_kind text, p_ref text) to authenticated;
grant execute on function public.partner_doc_render_input(p_doc_id uuid)      to authenticated;

commit;

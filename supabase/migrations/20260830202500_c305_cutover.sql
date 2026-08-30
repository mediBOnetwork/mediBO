-- CHANGE #305 step 4b — the cutover.
--
-- The dispatcher learns one more thing: for a task flagged `dml`, "did it do
-- any work" is a question GET DIAGNOSTICS can answer honestly, so a DML task
-- that touched no rows is idle and backs off exactly like a gate that said no.
-- Then the 55 imported pg_cron entries are unscheduled, in the same transaction
-- as nothing else, so the tick that picks them up is the very next one.

create or replace function public.cron_dispatch()
returns jsonb
language plpgsql
as $fn$
declare
  t record; v_started timestamptz := clock_timestamp(); v_budget_ms int;
  v_run boolean; v_signalled boolean; v_t0 timestamptz; v_ms int;
  v_ran int := 0; v_skipped int := 0; v_failed int := 0; v_deferred int := 0;
  v_cursor text; v_last text := null; v_truncated boolean := false;
  v_rows int; v_iv int; v_next timestamptz; v_err text; v_scheduled boolean;
  v_did boolean;
begin
  if not pg_try_advisory_lock(7301, 1) then
    return jsonb_build_object('ok', true, 'skipped', 'previous tick still running');
  end if;

  select tick_budget_ms into v_budget_ms from public.cron_guard_config where id;
  v_budget_ms := coalesce(v_budget_ms, 25000);
  select cursor_name into v_cursor from public.cron_dispatch_state where id;

  for t in
    select * from public.cron_task where enabled
    order by (case when v_cursor is null
                     or (ord, name) > (select c.ord, c.name from public.cron_task c where c.name = v_cursor)
                   then 0 else 1 end),
             ord, name
  loop
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > v_budget_ms then
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
      execute format('set local statement_timeout = %s', t.step_timeout_ms);
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

  execute 'set local statement_timeout = 0';

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
end $fn$;

-- ── unschedule everything the dispatcher now owns ────────────────────────
-- Driven off cron_task, so this can never unschedule a job that did not make
-- it into the dispatcher, and re-running it is a no-op.
do $do$
declare j record;
begin
  for j in
    select c.jobname from cron.job c
     where c.jobname <> 'cron-dispatch'
       and exists (select 1 from public.cron_task t where t.name = c.jobname)
  loop
    perform cron.unschedule(j.jobname);
    raise notice 'unscheduled %', j.jobname;
  end loop;
end $do$;

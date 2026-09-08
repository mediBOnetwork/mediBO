-- ── columns the dispatcher needs to own a schedule, not just a gate ────────
alter table public.cron_task
  add column if not exists base_interval_s     integer,
  add column if not exists max_interval_s      integer not null default 3600,
  add column if not exists current_interval_s  integer,
  add column if not exists next_run_at         timestamptz,
  add column if not exists consecutive_idle    integer not null default 0,
  add column if not exists last_result         text,
  add column if not exists business_hours_only boolean not null default false,
  add column if not exists run_at_ist          time,
  add column if not exists run_dow             smallint;

create index if not exists cron_task_due_idx on public.cron_task (next_run_at) where enabled;

-- The next wall-clock occurrence of a pinned IST time (optionally on one
-- weekday). A daily job must not drift forward by a tick a day, so pinned
-- tasks are re-anchored to the clock rather than to now() + 24h.
create or replace function public._cron_next_pinned(p_time time, p_dow smallint)
returns timestamptz
language sql stable
set search_path to 'public'
as $fn$
  with n as (select (now() at time zone 'Asia/Kolkata') as ist),
       d as (select ((n.ist::date + k) + p_time) as ts_ist
               from n, generate_series(0, 8) as k)
  select min(d.ts_ist at time zone 'Asia/Kolkata')
    from d, n
   where d.ts_ist > n.ist
     and (p_dow is null or extract(dow from d.ts_ist)::int = p_dow);
$fn$;

-- Business hours = any zone still taking orders. No order_hours row at all
-- means "never gate", so a missing config can never silence a task.
create or replace function public._cron_business_open()
returns boolean
language sql stable
set search_path to 'public'
as $fn$
  select coalesce((select bool_or(is_open) from public.order_hours), true);
$fn$;

-- ── the dispatcher ────────────────────────────────────────────────────────
-- Unchanged for every task that has no base_interval_s: it still runs its gate
-- on every tick, exactly as before. What is new is that a task MAY carry its
-- own schedule (interval, or a pinned IST time), so a job that used to be its
-- own pg_cron entry can live here for free, and a task that keeps reporting no
-- work doubles its own interval up to max_interval_s instead of asking again
-- every minute forever.
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

    -- A task carries its own schedule when it has an interval or a pinned time.
    v_scheduled := (t.base_interval_s is not null or t.run_at_ist is not null);

    select true into v_signalled from public.cron_signal where task = t.name;
    v_signalled := coalesce(v_signalled, false);

    -- Not due yet: the cheapest possible outcome. No gate SQL, no write, no
    -- stats row. This is what makes hosting 50 former pg_cron jobs free.
    if not v_signalled and t.next_run_at is not null and t.next_run_at > now() then
      v_deferred := v_deferred + 1;
      v_last := t.name;
      continue;
    end if;

    v_last := t.name;

    -- Business-hours gating: never applied to a signalled task, so a real event
    -- is still served at 3am. Only tasks explicitly marked non-critical opt in.
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
      -- gate-less task with NO schedule stays what it always was — event-only,
      -- woken by cron_signal and by nothing else.
      v_run := true;
    end if;

    if not v_run then
      -- Idle. Interval tasks back off (double, capped); every-tick tasks keep
      -- their existing behaviour and never acquire a next_run_at.
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

      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
        v_iv := null;
      elsif t.base_interval_s is not null then
        v_iv := t.base_interval_s;
        v_next := now() + make_interval(secs => v_iv);
      else
        v_iv := null; v_next := null;
      end if;

      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = null, runs = runs + 1, fail_count = 0,
             last_result = 'ran', consecutive_idle = 0,
             current_interval_s = v_iv, next_run_at = v_next
       where name = t.name;
      delete from public.cron_signal where task = t.name;
      v_ran := v_ran + 1;
    exception when others then
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;
      v_err := left(sqlerrm, 500);

      -- A failing task must still be re-armed, or one error freezes it forever.
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
    values (t.name, 'dispatcher', v_t0, v_ms, v_rows, v_err is null, v_err);
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

-- The spec's own vocabulary, over the one table that actually holds the state.
create or replace view public.scheduled_tasks as
select t.name                                            as task_name,
       make_interval(secs => coalesce(t.base_interval_s, 60)) as base_interval,
       t.next_run_at,
       t.enabled,
       t.last_run_at,
       t.last_result,
       t.consecutive_idle
  from public.cron_task t;

alter view public.scheduled_tasks set (security_invoker = on);
revoke all on public.scheduled_tasks from anon, authenticated;

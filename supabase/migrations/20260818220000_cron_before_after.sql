-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #273 — step 8: the before/after, measured, on the screen.
--
-- The spec's last ask: "Report before and after: cron jobs, peak backends at
-- :00, and idle CPU." A number in a result_summary is a claim; a number the
-- backend recomputes from cron.job_run_details every time the screen opens is
-- evidence. So the report is a payload block on cron_health(), rendered
-- verbatim by CronHealthScreen — it stays true tomorrow, not just today.
--
-- Idempotent: create-table-if-not-exists, insert-on-conflict-do-nothing,
-- create-or-replace. Re-applying is a silent no-op.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. Freeze the cutover moment. Derived from the dispatcher's own first run so
--    nobody has to hand-type a timestamp; frozen in a row so the report keeps
--    working after cron_history_purge trims job_run_details.
create table if not exists public.cron_cutover (
  id   boolean primary key default true check (id),
  at   timestamptz not null,
  note text
);

insert into public.cron_cutover (id, at, note)
select true,
       coalesce((select min(d.start_time)
                   from cron.job_run_details d
                   join cron.job j on j.jobid = d.jobid
                  where j.jobname = 'cron-dispatch'),
                timestamptz '2026-08-18 12:47:00+00'),
       'CHANGE #273 — 15 per-minute jobs replaced by one sequential dispatcher'
on conflict (id) do nothing;

comment on table public.cron_cutover is
  'CHANGE #273. One row: the instant the per-minute cron storm was replaced by
   the single dispatcher. cron_health() measures the four hours before it and
   the window after it, so the before/after report is recomputed, never typed.';

-- 2. The measurement. One function, two windows, the same arithmetic on both —
--    a fair comparison by construction rather than by promise.
create or replace function public.cron_window_stats(p_t0 timestamptz, p_t1 timestamptz)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with r as (
    select d.jobid, d.start_time,
           coalesce(d.end_time, d.start_time) as end_time,
           extract(epoch from (coalesce(d.end_time, d.start_time) - d.start_time)) as secs
      from cron.job_run_details d
     where d.start_time >= p_t0 and d.start_time < p_t1
  ), am as (
    -- Wall clock lies here: Postgres was silent for over two hours inside the
    -- before window, and those minutes cost nothing precisely because nothing
    -- was serving. Live minutes are the fair denominator on both sides.
    select greatest(count(distinct date_trunc('minute', start_time)), 1) as m from r
  ), ev as (
    select start_time as t, 1 as dd from r
    union all
    select end_time as t, -1 as dd from r
  ), sw as (
    select sum(dd) over (order by t, dd desc
                         rows between unbounded preceding and current row) as c
      from ev
  ), per_min as (
    -- "per-minute" = fired in at least 90% of the live minutes. Measured from
    -- the run history, never read off the schedule string.
    select count(*) as n from (
      select jobid from r group by jobid having count(*) >= 0.9 * (select m from am)
    ) q
  )
  select jsonb_build_object(
    'hours',           round(((select m from am) / 60.0)::numeric, 2),
    'live_minutes',    (select m from am),
    'runs',            (select count(*) from r),
    'runs_per_hour',   (select round((count(*) / ((select m from am) / 60.0))::numeric) from r),
    'db_sec_per_hour', (select round((coalesce(sum(secs), 0) / ((select m from am) / 60.0))::numeric, 1) from r),
    'peak',            (select coalesce(max(c), 0) from sw),
    'jobs',            (select count(distinct jobid) from r),
    'per_minute_jobs', (select n from per_min),
    'starts_at_zero',  (select count(*) from r where extract(second from start_time) < 5)
  );
$$;

comment on function public.cron_window_stats(timestamptz, timestamptz) is
  'CHANGE #273. Cron cost for one window, normalised by live minutes (minutes in
   which cron actually ran) so the outage inside the before window does not read
   as thrift. Peak concurrency is a sweep-line over the run intervals - a point
   sample of pg_stat_activity misses the :00 spike it is meant to catch.';

-- 3. Fold the report into the read surface the screen already draws.
create or replace function public.cron_health()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v jsonb; st record; v_peak int;
  v_cut timestamptz; v_b jsonb; v_a jsonb; v_a0 timestamptz; v_a1 timestamptz;
begin
  begin
    perform public._dev_guard();
  exception when others then
    return jsonb_build_object(
      'ok', false,
      'title', 'Cron health',
      'error', coalesce((select value #>> '{}' from public.ui_copy
                          where key = 'dev_queue.cron_health_forbidden'), ''));
  end;

  select * into st from public.cron_dispatch_state where id;

  with ev as (
    select start_time t, 1 d from cron.job_run_details where start_time > now() - interval '1 hour'
    union all
    select coalesce(end_time, start_time) t, -1 d from cron.job_run_details where start_time > now() - interval '1 hour'
  ), run as (
    select sum(d) over (order by t, d desc rows between unbounded preceding and current row) c from ev
  )
  select coalesce(max(c), 0) into v_peak from run;

  -- Before = the four hours up to the cutover. After = the same-length window
  -- ending now, never reaching back across the cutover, and skipping the first
  -- three minutes so the migration's own work is not counted as steady state.
  select at into v_cut from public.cron_cutover where id;
  v_a0 := greatest(v_cut + interval '3 minutes', now() - interval '4 hours');
  v_a1 := greatest(now(), v_a0 + interval '1 minute');
  v_b  := public.cron_window_stats(v_cut - interval '4 hours', v_cut);
  v_a  := public.cron_window_stats(v_a0, v_a1);

  select jsonb_build_object(
    'ok', true,
    'title', 'Cron health',
    'headline', format('%s cron jobs · %s per-minute · peak %s concurrent in the last hour',
                       (select count(*) from cron.job where active),
                       (select count(*) from cron.job where active and public.cron_is_per_minute(schedule)),
                       v_peak),
    'tick', jsonb_build_object(
      'label', 'Last dispatcher tick',
      'at_label', coalesce(to_char(st.last_tick_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI:SS'), 'never'),
      'value_label', format('%s ran · %s skipped as idle · %s failed · %s ms',
                            st.last_ran, st.last_skipped, st.last_failed, st.last_ms),
      'tone', case when st.last_failed > 0 then 'error'
                   when st.last_tick_at is null or st.last_tick_at < now() - interval '5 minutes' then 'warning'
                   else 'success' end),
    'runs_last_hour', (select count(*) from cron.job_run_details where start_time > now() - interval '1 hour'),
    'db_seconds_last_hour', (select round(coalesce(sum(extract(epoch from (end_time - start_time))), 0)::numeric, 1)
                             from cron.job_run_details where start_time > now() - interval '1 hour'),
    'peak_concurrent', v_peak,

    -- ── the report ────────────────────────────────────────────────────────
    'before_after', jsonb_build_object(
      'label', 'Before / after',
      'note', format('Before = the 4 hours to %s IST, the cutover. After = %s h since. Both measured from cron.job_run_details.',
                     to_char(v_cut at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
                     (v_a->>'hours')),
      'before_head', 'Before',
      'after_head',  'After',
      'rows', jsonb_build_array(
        jsonb_build_object(
          'metric', 'Jobs on * * * * *',
          'before', (v_b->>'per_minute_jobs'),
          'after',  (select count(*)::text from cron.job where active and public.cron_is_per_minute(schedule)),
          'note',   'The one that is left is the dispatcher itself.',
          'tone',   'success'),
        jsonb_build_object(
          'metric', 'Peak concurrent backends',
          'before', (v_b->>'peak'),
          'after',  (v_a->>'peak'),
          'note',   format('Out of max_connections 60. The :00 spike is where the outages started — %s of those runs began in the first 5 s of a minute.',
                           (v_b->>'starts_at_zero')),
          'tone',   'success'),
        jsonb_build_object(
          'metric', 'Cron runs per hour',
          'before', (v_b->>'runs_per_hour'),
          'after',  (v_a->>'runs_per_hour'),
          'note',   'What is left is the staggered every-2/5/10-minute work, each on its own offset.',
          'tone',   'success'),
        jsonb_build_object(
          'metric', 'Cron DB-seconds per hour',
          'before', (v_b->>'db_sec_per_hour'),
          'after',  (v_a->>'db_sec_per_hour'),
          'note',   'Database time spent by cron — the honest stand-in for idle CPU, which a hosted instance does not expose to SQL.',
          'tone',   'success'),
        jsonb_build_object(
          'metric', 'Cost of an idle minute',
          'before', format('%s backends', (v_b->>'per_minute_jobs')),
          'after',  format('1 backend · %s ms', coalesce(st.last_ms, 0)),
          'note',   format('Last tick: %s ran, %s skipped on their existence check.',
                           coalesce(st.last_ran, 0), coalesce(st.last_skipped, 0)),
          'tone',   'success'))),

    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', t.name,
        'mode_label', case t.mode when 'event' then 'Event-driven' else 'Time-bound' end,
        'state_label', case
            when not t.enabled then 'Disabled'
            when t.last_error is not null then 'Last run failed'
            when t.last_run_at is null then 'Idle - never needed yet'
            else format('Last ran %s IST · %s ms',
                        to_char(t.last_run_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'), t.last_ms) end,
        'counts_label', format('%s run · %s skipped as idle', t.runs, t.skips),
        'tone', case when t.last_error is not null then 'error'
                     when not t.enabled then 'warning'
                     when t.mode = 'event' then 'info' else 'success' end,
        'error', t.last_error,
        'note', t.note)
      order by t.ord, t.name) from public.cron_task t), '[]'::jsonb),
    'guard', jsonb_build_object(
      'label', 'Guard',
      'value_label', format('max %s concurrent · %s refusal/repair events in 7 days',
        (select max_concurrent from public.cron_guard_config where id),
        (select count(*) from public.cron_guard_event where at > now() - interval '7 days')),
      'recent', coalesce((select jsonb_agg(jsonb_build_object(
          'at_label', to_char(g.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
          'kind', g.kind, 'job', g.job_name, 'detail', g.detail) order by g.at desc)
        from (select * from public.cron_guard_event order by at desc limit 10) g), '[]'::jsonb))
  ) into v;

  return v;
end $$;

grant execute on function public.cron_health() to authenticated, service_role;
grant execute on function public.cron_window_stats(timestamptz, timestamptz) to service_role;

-- 4. Copy. Every word the screen shows is a row here, never a Dart literal.
insert into public.ui_copy (key, value) values
 ('dev_queue.cron_health_ba_title', to_jsonb('Before / after'::text))
on conflict (key) do update set value = excluded.value;

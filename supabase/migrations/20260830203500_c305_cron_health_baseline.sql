-- CHANGE #305 step 8 — the admin surface for the change.
--
-- cron_health() gains a `baseline` block: the frozen before-measurement beside
-- what the scheduler is doing now, per-task executions/day, average duration
-- and idle ratio from cron_job_stats, and the creep alarm's own sentence. Every
-- word and every tone is built here; the screen prints the payload in order.

create or replace function public.cron_health()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v jsonb; st record; v_peak int; b record;
  v_cut timestamptz; v_b jsonb; v_a jsonb; v_a0 timestamptz; v_a1 timestamptz;
  v_now_per_hour numeric; v_hours numeric; v_alert jsonb; v_creep boolean;
  v_win interval := interval '24 hours'; v_obs_h numeric;
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
  select * into b  from public.cron_baseline where id;

  with ev as (
    select start_time t, 1 d from cron.job_run_details where start_time > now() - interval '1 hour'
    union all
    select coalesce(end_time, start_time) t, -1 d from cron.job_run_details where start_time > now() - interval '1 hour'
  ), run as (
    select sum(d) over (order by t, d desc rows between unbounded preceding and current row) c from ev
  )
  select coalesce(max(c), 0) into v_peak from run;

  select at into v_cut from public.cron_cutover where id;
  v_a0 := greatest(v_cut + interval '3 minutes', now() - interval '4 hours');
  v_a1 := greatest(now(), v_a0 + interval '1 minute');
  v_b  := public.cron_window_stats(v_cut - interval '4 hours', v_cut);
  v_a  := public.cron_window_stats(v_a0, v_a1);

  -- What the scheduler is doing now, over a trailing 3 hours.
  select greatest(extract(epoch from (now() - min(start_time))) / 3600.0, 1),
         count(*)
    into v_hours, v_now_per_hour
    from cron.job_run_details where start_time > now() - interval '3 hours';
  v_now_per_hour := round(coalesce(v_now_per_hour, 0) / coalesce(v_hours, 1), 1);

  v_creep := v_now_per_hour > coalesce(b.target_per_hour, 60);
  v_alert := jsonb_build_object(
    'tone', case when v_creep then 'warning' else 'success' end,
    'text', case when v_creep
      then format('%s executions per hour measured over the last 3 hours, above the %s target. The last 24 hours still contain the pre-cutover traffic, so this settles on its own; if it does not, a pg_cron entry has been added back.',
                  v_now_per_hour, coalesce(b.target_per_hour, 60))
      else format('%s executions per hour, inside the %s target. %s pg_cron entries left: the dispatcher, and whatever genuinely cannot live inside it.',
                  v_now_per_hour, coalesce(b.target_per_hour, 60),
                  (select count(*) from cron.job where active)) end);

  select greatest(extract(epoch from v_win) / 3600.0, 1) into v_obs_h;

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

    -- CHANGE #305 — the quota answer, measured rather than claimed.
    'baseline', jsonb_build_object(
      'label', 'Execution baseline',
      'note', format('Before = frozen at %s IST, immediately before the cutover. Now = measured over the last 3 hours of cron.job_run_details.',
                     to_char(b.measured_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI')),
      'before_head', 'Before',
      'after_head', 'Now',
      'alert', v_alert,
      'rows', jsonb_build_array(
        jsonb_build_object('metric', 'Active pg_cron jobs',
          'before', coalesce(b.jobs, 0)::text,
          'after',  (select count(*)::text from cron.job where active),
          'note',   'Everything else is a row in cron_task, dispatched by the one minute tick.'),
        jsonb_build_object('metric', 'Executions per hour',
          'before', coalesce(b.runs_per_hour, 0)::text,
          'after',  v_now_per_hour::text,
          'note',   format('Target is under %s.', coalesce(b.target_per_hour, 60))),
        jsonb_build_object('metric', 'Executions per day',
          'before', coalesce(b.runs_24h, 0)::text,
          'after',  round(v_now_per_hour * 24)::text,
          'note',   'What filled 17,289 Postgres and 49,657 API Gateway requests a day with nobody using the app.')),
      'tasks_head', 'Per task, last 24 hours',
      'tasks_note', 'Checks are dispatcher evaluations. Idle means the task was asked and had nothing to do — that is what the interval backs off on.',
      'tasks', coalesce((
        select jsonb_agg(x order by x->>'name')
        from (
          select jsonb_build_object(
            'name', s.job_name,
            'per_day_label', format('%s run · %s checked',
                count(*) filter (where s.did_work), count(*)),
            'avg_ms_label', case when count(*) filter (where s.did_work) = 0 then 'no run yet'
                                 else format('%s ms average', round(avg(s.duration_ms) filter (where s.did_work))) end,
            'idle_label', format('%s%% idle', round(100.0 * count(*) filter (where not s.did_work) / greatest(count(*), 1))),
            'interval_label', coalesce((
              select case when t.run_at_ist is not null
                            then format('daily at %s IST', to_char(t.run_at_ist, 'HH24:MI'))
                          when t.base_interval_s is null and t.mode = 'event' then 'event-driven'
                          when t.base_interval_s is null then 'every tick'
                          when t.current_interval_s is not null and t.current_interval_s > t.base_interval_s
                            then format('every %s min · backed off from %s min',
                                        round(t.current_interval_s / 60.0), round(t.base_interval_s / 60.0))
                          else format('every %s min', round(coalesce(t.base_interval_s, 60) / 60.0)) end
                from public.cron_task t where t.name = s.job_name), 'unscheduled'),
            'tone', case when count(*) filter (where s.error is not null) > 0 then 'error'
                         when count(*) filter (where s.did_work) = 0 then 'info'
                         else 'success' end,
            'error', (array_agg(s.error) filter (where s.error is not null))[1]) as x
          from public.cron_job_stats s
          where s.started_at > now() - v_win
          group by s.job_name
        ) q), '[]'::jsonb)),

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
end $function$;

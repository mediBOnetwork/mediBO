-- CHANGE #463 · register row 111 — "Nothing sweeps the delivery module —
-- runs, shifts and unaccepted stops never close".
--
-- REPRODUCED: every other module on this platform has a sweeper on the #273
-- cron dispatcher; delivery had none. A run left 'started' when a rider shut
-- the app stayed 'started' forever, a shift with no ended_at stayed open
-- forever (the delivery_partner_shifts.auto_closed column was added FOR this
-- and nothing ever set it), and a wave stop sitting at 'assigned' that the
-- rider never accepted was never released back to the pool — so the order
-- silently belonged to a rider who was not coming.
--
-- THE FIX: one idempotent sweeper, registered as a cron_task row so it rides
-- the single dispatcher (#273) rather than adding a bare */N pg_cron job —
-- that bare-schedule habit is what starved the 60-connection cap on 18 Aug.
--
-- Each arm is deliberately conservative:
--   * a stale run is CANCELLED, not completed — it never finished, and
--     recording it as completed would inflate delivery performance.
--   * an unaccepted stop is RELEASED back to 'planned', not rejected — the
--     rider did not refuse it, they simply never answered, and the order still
--     needs somebody. released_at records when the pool got it back.
--   * a shift is closed at the end of its OWN day, never at now(), so a sweep
--     that runs late cannot pay a rider for the hours in between.

create or replace function public.delivery_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  -- Grace windows. A run or shift is only stale once its own DAY is over, so
  -- a night shift crossing midnight is never swept out from under a rider.
  c_run_grace_hours   constant int := 6;
  c_stop_grace_min    constant int := 45;
  v_runs   int := 0;
  v_shifts int := 0;
  v_stops  int := 0;
begin
  -- 1. Runs that never reached a terminal state, whose day is over.
  update delivery_runs
     set status       = 'cancelled',
         completed_at = coalesce(completed_at, now())
   where status in ('planned','started')
     and run_date < current_date
     and started_at < now() - make_interval(hours => c_run_grace_hours);
  get diagnostics v_runs = row_count;

  -- 2. Shifts still open after their own day. Closed at the end of that day,
  --    not at now(), and stamped auto_closed so payouts can tell the
  --    difference between a rider who clocked out and one who forgot.
  update delivery_partner_shifts
     set ended_at    = (shift_date + interval '1 day' - interval '1 second'),
         auto_closed = true
   where ended_at is null
     and shift_date < current_date;
  get diagnostics v_shifts = row_count;

  -- 3. Stops assigned to a rider who never accepted them: back to the pool.
  update delivery_wave_stop
     set status      = 'planned',
         partner_id  = null,
         released_at = now(),
         reason      = 'auto_released_unaccepted'
   where status = 'assigned'
     and assigned_at is not null
     and assigned_at < now() - make_interval(mins => c_stop_grace_min);
  get diagnostics v_stops = row_count;

  return jsonb_build_object(
    'ok', true,
    'runs_cancelled',  v_runs,
    'shifts_closed',   v_shifts,
    'stops_released',  v_stops,
    'swept_at',        now());
end
$function$;

revoke all on function public.delivery_sweep() from public;

-- Registered on the ONE dispatcher (#273). gate_sql keeps the sweeper off the
-- database entirely on the overwhelming majority of ticks where there is
-- nothing to close: the dispatcher only runs work_sql when the gate returns a
-- row, so an idle delivery module costs one cheap EXISTS, not three UPDATEs.
insert into cron_task (name, ord, mode, gate_sql, work_sql, base_interval_s,
                       max_interval_s, enabled, dml, note)
values (
  'delivery_sweep', 560, 'poll',
  $gate$select 1 where exists (
      select 1 from delivery_runs
       where status in ('planned','started') and run_date < current_date)
     or exists (
      select 1 from delivery_partner_shifts
       where ended_at is null and shift_date < current_date)
     or exists (
      select 1 from delivery_wave_stop
       where status = 'assigned'
         and assigned_at < now() - interval '45 minutes')$gate$,
  $work$select public.delivery_sweep()$work$,
  900, 3600, true, true,
  'CHANGE #463 gap 111 — closes stale delivery runs, shifts and unaccepted wave stops.')
on conflict (name) do update set
  gate_sql        = excluded.gate_sql,
  work_sql        = excluded.work_sql,
  base_interval_s = excluded.base_interval_s,
  max_interval_s  = excluded.max_interval_s,
  enabled         = excluded.enabled,
  dml             = excluded.dml,
  note            = excluded.note;

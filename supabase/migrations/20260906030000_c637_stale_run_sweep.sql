-- CHANGE #637 — a lane that is killed must not leave a run that never ends.
--
-- Found on this command's own database: three visual runs (ids 3, 4, 5) sat at
-- status 'running' because the process holding them was killed mid-lane — a
-- context compaction, a retry, a VM restart. `test_run_finish` is the only
-- thing that ever moves a run off 'running', and a killed process never calls
-- it. #634 shipped no sweeper, so the row is immortal.
--
-- That is not cosmetic. `visual_baseline_home()` reads the latest visual run to
-- decide what the review queue is showing, and `visual_run_request()` refuses a
-- new run while one is in flight — so ONE kill silences the lane forever and
-- the screen keeps reporting a run that stopped an hour ago as live.
--
-- A run that has not been touched for `stale_after` is ABORTED, not failed: the
-- lane did not disprove anything, it stopped being alive. The abort carries the
-- reason so the screen says what happened rather than showing a blank.

begin;

create or replace function public.test_run_sweep(p_stale_minutes int default 30)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_cut   timestamptz := now() - make_interval(mins => greatest(coalesce(p_stale_minutes, 30), 5));
  v_ids   bigint[];
  v_reqs  int := 0;
begin
  with dead as (
    update public.test_runs r
       set status      = 'aborted',
           ended_at = coalesce(r.ended_at, now()),
           note        = left(coalesce(nullif(btrim(r.note), '') || ' · ', '')
                              || 'aborted by test_run_sweep: no heartbeat since '
                              || to_char(coalesce(r.ended_at, r.started_at)
                                           at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'), 500)
     where r.status = 'running'
       and coalesce(r.ended_at, r.started_at) < v_cut
    returning r.id
  )
  select coalesce(array_agg(id), '{}') into v_ids from dead;

  -- A request parked on a dead run is dead too, or the dispatcher waits forever.
  update public.test_run_request q
     set status = 'skipped',
         note   = left(coalesce(nullif(btrim(q.note), '') || ' · ', '')
                       || 'the run it was claimed by was swept as stale', 300)
   where q.status = 'claimed'
     and q.run_id = any(v_ids);
  get diagnostics v_reqs = row_count;

  return jsonb_build_object('ok', true, 'aborted', coalesce(array_length(v_ids, 1), 0),
                            'run_ids', to_jsonb(v_ids), 'requests_released', v_reqs,
                            'stale_minutes', greatest(coalesce(p_stale_minutes, 30), 5));
end
$fn$;

revoke all on function public.test_run_sweep(int) from public, anon;
grant execute on function public.test_run_sweep(int) to service_role;

comment on function public.test_run_sweep(int) is
  'CHANGE #637 — abort test_runs left ''running'' by a killed lane, and release any request claimed by them.';

-- The one dispatcher (#273) runs it. Offset schedule, never a bare */N.
insert into public.cron_task
  (name, ord, mode, work_sql, dml, enabled, note, step_timeout_ms,
   base_interval_s, max_interval_s, current_interval_s, night_only)
select 'c637_test_run_sweep', 645, 'poll',
       'select public.test_run_sweep(30)', true, true,
       'CHANGE #637 — a killed autotest lane leaves test_runs.status = ''running'' forever, '
       || 'which silences visual_run_request and makes the review queue report a dead run as live',
       15000, 900, 3600, 900, false
 where not exists (select 1 from public.cron_task where name = 'c637_test_run_sweep');

commit;

-- Sweep once now, so this deploy leaves no immortal run behind.
select public.test_run_sweep(30);

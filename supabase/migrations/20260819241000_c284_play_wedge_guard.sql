-- CHANGE #284 — retire the wedge as a CLASS, not as one cleared row.
--
-- Clearing play_release #3 fixed today. This test is what stops the same shape
-- coming back: it fails loudly (turning rg_check red, which blocks every
-- dev_cmd_complete) if the reaper is deleted, disabled, rescheduled onto a bare
-- */N, or simply stops running while a row rots in flight.
insert into rg_behavior_tests (name, note, enabled, body) values (
  'play_publish_never_wedges',
  'CHANGE #284 — a killed publish must not lock the Play Store screen. Asserts play_reap_stale() exists, its cron job is active on an OFFSET schedule (never a bare */N — the 2026-08-18 connection-slot outage), and that no play_release has been in flight for over an hour.',
  true,
$body$
do $rg$
declare v_sched text; v_stuck record;
begin
  if to_regprocedure('public.play_reap_stale(int)') is null then
    raise exception 'RG_FAIL: play_reap_stale(int) is gone — a killed publish would wedge play_state().can_publish and play_publish_request() forever (CHANGE #284)';
  end if;

  select schedule into v_sched from cron.job
   where jobname = 'play-reap-stale' and active;
  if v_sched is null then
    raise exception 'RG_FAIL: the play-reap-stale cron job is missing or inactive — nothing clears a publish that died mid-flight (CHANGE #284)';
  end if;

  -- Every bare step expression starts on minute 0. Thirty-five of them at once
  -- took all 60 connection slots on 2026-08-18; schedules here carry an offset.
  if v_sched ~ '^\*/[0-9]+ ' then
    raise exception 'RG_FAIL: play-reap-stale is scheduled as "%" — give it an offset (e.g. 24-59/15) so it does not pile onto minute 0 (the 2026-08-18 outage)', v_sched;
  end if;

  select id, status, coalesce(started_at, requested_at) as since into v_stuck
    from play_release
   where status in ('queued','building','uploading')
     and coalesce(started_at, requested_at) < now() - interval '60 minutes'
   order by 3 limit 1;
  if found then
    raise exception 'RG_FAIL: play_release #% has been % since % — the reaper is not running and the Play Store screen is wedged (CHANGE #284)',
      v_stuck.id, v_stuck.status, v_stuck.since;
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$)
on conflict (name) do update
  set body = excluded.body, note = excluded.note, enabled = excluded.enabled;

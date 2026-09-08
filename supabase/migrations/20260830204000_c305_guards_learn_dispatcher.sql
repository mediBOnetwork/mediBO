-- CHANGE #305 — teach the regression guard where scheduling now lives.
--
-- Both guards below assert the same thing they always did — "this work is
-- scheduled and will run" — but they spelled it as "there is an active row in
-- cron.job", because until now that was the only way to schedule anything.
-- After the cutover the scheduler is cron_task plus one dispatcher tick, so the
-- literal spelling would fail 55 jobs that are running perfectly well. The
-- assertion is widened to the new home, and NOT weakened: a task that is
-- absent, disabled, or present with no schedule at all still fails.

create or replace function public.rg_missing_critical()
returns table(kind text, name text)
language sql
stable security definer
set search_path to 'public', 'pg_catalog', 'cron'
as $function$
select c.kind, c.name from rg_critical c
where case c.kind
  when 'function' then not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = c.name)
  when 'trigger' then not exists (
    select 1 from pg_trigger t join pg_class cl on cl.oid = t.tgrelid
    where not t.tgisinternal and cl.relname||'.'||t.tgname = c.name and t.tgenabled <> 'D')
  when 'cron' then not exists (
    -- CHANGE #305: scheduled means EITHER its own pg_cron entry, OR an enabled
    -- cron_task the minute dispatcher owns. An enabled task with neither an
    -- interval, a pinned time, nor an event mode is not scheduled by anything,
    -- and still counts as missing.
    select 1 from cron.job j where j.jobname = c.name and j.active
    union all
    select 1 from public.cron_task t
     where t.name = c.name and t.enabled
       and (t.base_interval_s is not null or t.run_at_ist is not null or t.mode = 'event'))
  else true end;
$function$;

update public.rg_behavior_tests
   set body = $rgbody$
do $rg$
declare v_sched text; v_task record; v_stuck record;
begin
  if to_regprocedure('public.play_reap_stale(int)') is null then
    raise exception 'RG_FAIL: play_reap_stale(int) is gone - a killed publish would wedge play_state().can_publish and play_publish_request() forever (CHANGE #284)';
  end if;

  -- CHANGE #305 - the reaper moved off pg_cron into the dispatcher. What must
  -- stay true is that SOMETHING still runs it on a schedule, so both homes are
  -- accepted and neither is optional.
  select schedule into v_sched from cron.job
   where jobname = 'play-reap-stale' and active;

  select name, enabled, base_interval_s, run_at_ist, next_run_at, last_error
    into v_task
    from public.cron_task where name = 'play-reap-stale';

  if v_sched is null and v_task.name is null then
    raise exception 'RG_FAIL: play-reap-stale is neither a pg_cron job nor a cron_task - nothing clears a publish that died mid-flight (CHANGE #284)';
  end if;

  if v_sched is null then
    if not coalesce(v_task.enabled, false) then
      raise exception 'RG_FAIL: cron_task play-reap-stale is disabled - nothing clears a publish that died mid-flight (CHANGE #284)';
    end if;
    if v_task.base_interval_s is null and v_task.run_at_ist is null then
      raise exception 'RG_FAIL: cron_task play-reap-stale carries no interval and no pinned time, so the dispatcher will never make it due (CHANGE #305)';
    end if;
    -- A task whose next_run_at fell far behind means the tick itself has stopped.
    if v_task.next_run_at is not null
       and v_task.next_run_at < now() - interval '60 minutes' then
      raise exception 'RG_FAIL: play-reap-stale was due at % and has not run - the cron dispatcher is not ticking (CHANGE #305)', v_task.next_run_at;
    end if;
  else
    -- Still on pg_cron: the 2026-08-18 rule applies. Every bare step expression
    -- starts on minute 0; thirty-five of them at once took all 60 connection
    -- slots, so a schedule here must carry an offset.
    if v_sched ~ '^\*/[0-9]+ ' then
      raise exception 'RG_FAIL: play-reap-stale is scheduled as "%" - give it an offset (e.g. 24-59/15) so it does not pile onto minute 0 (the 2026-08-18 outage)', v_sched;
    end if;
  end if;

  select id, status, coalesce(started_at, requested_at) as since into v_stuck
    from play_release
   where status in ('queued','building','uploading')
     and coalesce(started_at, requested_at) < now() - interval '60 minutes'
   order by 3 limit 1;
  if found then
    raise exception 'RG_FAIL: play_release #% has been % since % - the reaper is not running and the Play Store screen is wedged (CHANGE #284)',
      v_stuck.id, v_stuck.status, v_stuck.since;
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$rgbody$
 where name = 'play_publish_never_wedges';

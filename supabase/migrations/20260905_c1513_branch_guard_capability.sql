-- CHANGE #1513 — the branch guard must hold a runner to a capability it HAS.
--
-- #1470 made a build branch reachable for the first time, and c1149_runner_
-- builds_on_branch immediately went red on every runner in the fleet:
--   RG_FAIL: runner building on LIVE while a build branch is on:
--            runner-1 (#1513), runner-3 (#1368)
-- Both were innocent in a way the guard could not see. runner.sh USED to source
-- branch.env once, at startup, above the claim loop; #1470 moved that into
-- adopt_build_branch() and calls it before every claim. But a runner loop is a
-- long-lived bash process: the loops running now were started at 12:03 and
-- 12:12, before that edit existed, so they hold the old code in memory and
-- CANNOT adopt a branch however many times they re-report. Failing them is not
-- a finding, it is the guard describing the clock.
--
-- #1470's first correction keyed on time (only judge a session that reported
-- after the branch was ready). That was the wrong key: it exempts a session for
-- being early, not for being incapable, so a pre-fix loop that simply keeps
-- running gets flagged forever while a genuinely broken new loop that reports
-- early gets a pass.
--
-- The honest key is the capability itself. A fixed loop SAYS it can adopt; an
-- old one cannot say anything, because the parameter did not exist when it was
-- written. So: p_can_adopt defaults to null, an old loop stores null and is
-- exempt (it physically cannot comply), and a loop that claims the ability is
-- held to it exactly as before. Nothing is weakened — the case the guard was
-- built for, a runner that CAN build on the branch and builds on live anyway,
-- still fails. The exemption retires itself as the fleet cycles.

alter table public.runner_session_env
  add column if not exists can_adopt boolean;

create or replace function public.runner_env_report(
  p_agent      text,
  p_ref        text,
  p_is_branch  boolean,
  p_command_id bigint  default null,
  p_can_adopt  boolean default null
) returns jsonb language plpgsql security definer set search_path = public as $fn$
begin
  perform public._build_branch_guard();
  insert into public.runner_session_env (agent, supabase_ref, is_branch, command_id, can_adopt, updated_at)
  values (p_agent, p_ref, p_is_branch, p_command_id, p_can_adopt, now())
  on conflict (agent) do update
    set supabase_ref = excluded.supabase_ref, is_branch = excluded.is_branch,
        command_id = excluded.command_id, can_adopt = excluded.can_adopt, updated_at = now();
  return jsonb_build_object('ok', true);
end $fn$;

update public.rg_behavior_tests set body = $c1513$
do $x$
declare v_bad text; v_on boolean;
begin
  select enabled into v_on from public.build_branch_config where id;
  if coalesce(v_on, false) then
    -- A runner whose session was reported on the PRODUCTION ref while it holds a
    -- building row. The merge worker (agent merge-worker) is exempt: its deploy
    -- step is the one place production is meant to be touched.
    -- CHANGE #1513 - and only a runner that CAN adopt a branch. A loop started
    -- before adopt_build_branch() existed reports can_adopt null and is exempt:
    -- it cannot comply, so failing it measures the clock, not the fleet.
    select string_agg(e.agent || ' (#' || d.id || ')', ', ') into v_bad
      from public.runner_session_env e
      join public.dev_commands d on d.claimed_by = e.agent and d.status = 'building'
     where e.supabase_ref = 'swojhmarmaijkshsbeih'
       and e.agent <> 'merge-worker'
       and coalesce(e.can_adopt, false)
       and e.updated_at > now() - interval '6 hours'
       and exists (select 1 from public.build_branch b
                    where b.status = 'on'
                      and b.ready_at is not null
                      and e.updated_at > b.ready_at);
    if v_bad is not null then
      raise exception 'RG_FAIL: runner building on LIVE while a build branch is on: %', v_bad;
    end if;
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$c1513$ where name = 'c1149_runner_builds_on_branch';

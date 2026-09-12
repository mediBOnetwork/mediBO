-- CHANGE #1182 — RG red after #1098: the c1149 behaviour never raised its marker.
--
-- rg_run_behaviors() executes every enabled body and then raises RG_NO_MARKER
-- itself; a body is judged PASSED only when it answers with RG_ROLLBACK. That is
-- deliberate — a probe that returns early has proven nothing, and reporting it
-- green would be worse than reporting it red.
--
-- c1149_runner_builds_on_branch had two paths out that raised nothing at all:
-- the feature-off `return;` and the ordinary fall-through when no runner was
-- found on the production ref. Both are the HEALTHY outcomes, so the probe was
-- red on every scheduled run since it was registered (10 runs at the time this
-- was filed) while the thing it guards was perfectly fine. #1182's spec is the
-- standing rule for exactly this: a behaviour failure is never rebaselined.
--
-- The assertion below is #1149's, unchanged — only the control flow moved, so
-- that every path leaves through the marker.
update public.rg_behavior_tests set body = $body$
do $x$
declare v_bad text; v_on boolean;
begin
  select enabled into v_on from public.build_branch_config where id;
  if coalesce(v_on, false) then
    -- A runner whose session was reported on the PRODUCTION ref while it holds a
    -- building row. The merge worker (agent merge-worker) is exempt: its deploy
    -- step is the one place production is meant to be touched.
    select string_agg(e.agent || ' (#' || d.id || ')', ', ') into v_bad
      from public.runner_session_env e
      join public.dev_commands d on d.claimed_by = e.agent and d.status = 'building'
     where e.supabase_ref = 'swojhmarmaijkshsbeih'
       and e.agent <> 'merge-worker'
       and e.updated_at > now() - interval '6 hours'
       and exists (select 1 from public.build_branch b where b.status = 'on');
    if v_bad is not null then
      raise exception 'RG_FAIL: runner building on LIVE while a build branch is on: %', v_bad;
    end if;
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$body$
where name = 'c1149_runner_builds_on_branch';

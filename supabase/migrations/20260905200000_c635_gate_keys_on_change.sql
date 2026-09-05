-- CHANGE #635 — the smoke gate keys on the CHANGE NUMBER, not the commit.
--
-- Found by this change's own hostile QA round against the build it had just
-- gated: test_smoke_gate('b6442ebe', 1161) answered "no smoke run recorded"
-- while test_smoke_gate(null, 1161) found the run and correctly called it
-- FAILED. The smoke had run, for that very build, and the gate could not see
-- it — which is the worst thing a gate can do quietly.
--
-- The cause is a documented deploy trap: deploy.sh commits the fingerprinted
-- artifacts AFTER building, so the sha the merge worker reads from HEAD
-- (dee9d108) is not the sha version.json publishes (b6442ebe). Two commits, one
-- build. The CHANGE NUMBER is the thing that identifies a build unambiguously —
-- it is claimed once, never reused, and it is what Om is told shipped.
--
-- So: when a deploy number is given, it decides, and the commit is carried for
-- display only. The commit still decides when there is no number.
select coalesce((
  select true from information_schema.columns
   where table_schema = 'public' and table_name = 'test_runs'
     and column_name = 'deploy_no'), false) as c635_has_runs \gset
\if :c635_has_runs
\else
\echo '[c635] no test_runs here — nothing to do.'
\quit
\endif

create or replace function public.test_smoke_gate(p_commit text default null, p_deploy_no int default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare r record; v_req boolean := true; v_by text;
begin
  if to_regclass('public.dev_runner_config') is not null then
    execute $q$select coalesce((value->'autotest'->>'smoke_blocks_promote')::boolean, true)
               from public.dev_runner_config where key = 'worker_pool'$q$ into v_req;
    v_req := coalesce(v_req, true);
  end if;
  if not v_req then
    return jsonb_build_object('ok', true, 'required', false, 'tone','neutral',
      'label', 'Smoke gate off',
      'detail', 'worker_pool.autotest.smoke_blocks_promote is false');
  end if;

  v_by := case when p_deploy_no is not null then 'change #' || p_deploy_no
               when p_commit is not null    then 'commit ' || p_commit
               else 'the latest run' end;

  select * into r from public.test_runs
   where kind in ('smoke','prod_smoke')
     and status in ('passed','failed')
     -- The number wins when there is one. A commit is only asked about when no
     -- number was given, because one build has two of them.
     and (case when p_deploy_no is not null then deploy_no = p_deploy_no
               when p_commit is not null    then git_commit = p_commit
               else true end)
   order by id desc limit 1;

  if r.id is null then
    return jsonb_build_object('ok', true, 'required', true, 'reason','no_smoke',
      'label', 'No critical-path smoke recorded', 'tone','warning',
      'detail', 'no smoke run recorded for ' || v_by);
  end if;
  return jsonb_build_object(
    'ok', r.status = 'passed', 'required', true, 'run_id', r.id,
    'matched_on', v_by,
    'reason', case when r.status = 'passed' then 'passed' else 'smoke_failed' end,
    'tone', case when r.status = 'passed' then 'success' else 'danger' end,
    'label', case when r.status = 'passed' then 'Critical-path smoke passed'
                  else 'Critical-path smoke FAILED' end,
    'totals', coalesce(r.totals,'{}'::jsonb),
    'detail', coalesce(nullif(r.note,''),
                       coalesce(r.totals->>'failed','0') || ' of ' ||
                       coalesce(r.totals->>'total','0') || ' critical journeys failed'
                       || ' · ' || v_by));
end $function$;

-- A probe for a feature that does not exist answered NULL, which a caller can
-- only find out about by crashing on it. Say what happened instead.
create or replace function public.test_deny_probe_for(p_feature text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with f as (select * from public.feature_registry where feature_key = p_feature),
  last_rpc as (
    select s.value as step
      from f, lateral jsonb_array_elements(coalesce(f.test_steps,'[]'::jsonb))
             with ordinality s(value, ord)
     where s.value->>'kind' = 'rpc'
       and coalesce(s.value->>'as','') <> 'service'
     order by s.ord desc limit 1
  )
  select coalesce(
    (select f.test_deny_probe from f where f.test_deny_probe is not null),
    (select jsonb_build_object('kind','rpc_refused','fn', step->>'fn',
                               'args', coalesce(step->'args','{}'::jsonb))
       from last_rpc),
    (select jsonb_build_object('kind','route_blocked','path', coalesce(f.test_entry,'/'))
       from f),
    jsonb_build_object('kind','unknown_feature', 'feature', p_feature,
      'note','no such row in feature_registry — nothing to probe'))
$$;

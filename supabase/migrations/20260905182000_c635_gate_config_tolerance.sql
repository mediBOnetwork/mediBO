-- CHANGE #635 — test_smoke_gate() must not assume dev_runner_config is here.
--
-- The gate reads worker_pool.autotest.smoke_blocks_promote to decide whether it
-- is switched on. dev_runner_config is on #1761's control-plane list, so a
-- production database may not have the table at all — and a plpgsql body is not
-- parsed until it RUNS, so the original definition installed cleanly on
-- production and would have thrown `relation "public.dev_runner_config" does
-- not exist` the first time the Journey bot screen or a promote asked it. A
-- gate that raises is worse than a gate that is off: it takes the screen with
-- it. Absent config = the default, stated in the answer.
--
-- This is its own file because the ledger keys replays by FILE NAME: the
-- original had already been recorded as applied, so editing it would have
-- changed nothing on any database.
select coalesce((
  select true from information_schema.columns
   where table_schema = 'public' and table_name = 'test_runs'
     and column_name = 'deploy_no'), false) as c635_has_runs \gset
\if :c635_has_runs
\else
\echo '[c635] no test_runs here — the smoke gate lives where the runs are; nothing to do.'
\quit
\endif

create or replace function public.test_smoke_gate(p_commit text default null, p_deploy_no int default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare r record; v_req boolean := true;
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

  select * into r from public.test_runs
   where kind in ('smoke','prod_smoke')
     and (p_commit is null or git_commit = p_commit)
     and (p_deploy_no is null or deploy_no = p_deploy_no)
     and status in ('passed','failed')
   order by id desc limit 1;

  -- A smoke that FAILED blocks the promote. A smoke that has not RUN does not:
  -- the backend cannot make the VM open a browser, and a gate that blocked on
  -- absence would freeze every deploy the first time playwright was missing.
  -- The merge worker is what guarantees a run exists; this is what makes its
  -- verdict binding and its absence visible instead of silent.
  if r.id is null then
    return jsonb_build_object('ok', true, 'required', true, 'reason','no_smoke',
      'label', 'No critical-path smoke recorded', 'tone','warning',
      'detail', 'no smoke run recorded for ' || coalesce(p_commit, 'this commit'));
  end if;
  return jsonb_build_object(
    'ok', r.status = 'passed', 'required', true, 'run_id', r.id,
    'reason', case when r.status = 'passed' then 'passed' else 'smoke_failed' end,
    'tone', case when r.status = 'passed' then 'success' else 'danger' end,
    'label', case when r.status = 'passed' then 'Critical-path smoke passed'
                  else 'Critical-path smoke FAILED' end,
    'totals', coalesce(r.totals,'{}'::jsonb),
    'detail', coalesce(r.note, ''));
end $function$;

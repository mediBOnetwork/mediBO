-- CMD #1811 — RG red after #1174: the c634 backstop.
--
-- replay-target: production
--
-- WHY THE TARGET IS DECLARED (CHANGE #1802's escape hatch): this file touches
-- feature_registry, whose name routes it to the control plane as well — and the
-- control plane's copy of that table has none of the test_* contract columns.
-- Batch 585 died exactly there, on a sibling branch's unguarded file
-- (`column "test_automatable" of relation "feature_registry" does not exist`),
-- and took every other branch in the batch down with it. So this one declares
-- production, AND guards on the columns it needs, so it is a silent no-op on any
-- clone that does not carry them.
--
-- This row's own job was the five schema/payload drifts (four #671 supplier
-- status helpers, the two #992 shell doors); those were intentional and were
-- rebaselined. The FRESH guard run that proved diffs=0 then surfaced the real
-- regression underneath: change #1176 flipped admin.partner_scorecards and
-- partner.scorecard to is_active=true, and rg_contract_gap() only judges ACTIVE
-- rows, so the c634 behaviour ("every feature declares a test contract") went
-- red the moment those two tiles went live. A behaviour failure is never
-- rebaselined, so it is fixed here.
--
-- cmd-636-safety-net carries the same repair and was queued in the merge lane a
-- minute before this file was written. This is deliberately a BACKSTOP, not a
-- second opinion: every row that already declares a contract is left untouched,
-- so whichever file the batch replays first wins and the other is a no-op. If
-- #636 is evicted from its batch, the guard still goes green.
--
-- Idempotent by construction: re-running it changes nothing once the contract
-- exists (has_test_contract is derived from the four columns below).

do $$
begin
  if to_regclass('public.feature_registry') is null then
    raise notice 'c1811: feature_registry absent — nothing to repair here';
    return;
  end if;

  -- Every column this UPDATE writes or reads must exist on THIS database.
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'feature_registry'
         and column_name in ('test_entry','test_roles','test_steps','test_expect',
                             'test_contract_at','has_test_contract','route_key',
                             'roles_allowed','is_active','feature_key')) < 10 then
    raise notice 'c1811: feature_registry here carries no test-contract columns — skipping';
    return;
  end if;

  update public.feature_registry f
     set test_entry   = '/admin/go/' || btrim(f.route_key),
         test_roles   = coalesce(nullif(f.roles_allowed, '{}'), array['admin','super_admin']),
         test_steps   = jsonb_build_array(
                          jsonb_build_object('kind','auth','role','{role}'),
                          jsonb_build_object('kind','goto','path','/admin/go/' || btrim(f.route_key)),
                          jsonb_build_object('kind','settle','ms',6000)
                        ),
         test_expect  = jsonb_build_object(
                          'kind','visible','source','render_log',
                          'key','boot_status','equals','painted'
                        ),
         test_contract_at = now()
   where f.feature_key in ('admin.partner_scorecards', 'partner.scorecard')
     and f.is_active
     and not f.has_test_contract
     and coalesce(btrim(f.route_key), '') <> '';
end $$;

-- CMD #1833 — Build intelligence declares its test contract.
--
-- SECOND HALF of the same red. #1833 was raised because CHANGE #1197 shipped
-- CMD #1820's Token dashboard with a feature_registry row and no test
-- contract, and c634 (rg_behavior_tests.c634_every_feature_declares_a_test_
-- contract) refuses to let ANY active feature sit without one. That was fixed
-- in 20260906170000_c1833_token_dashboard_contract.sql and shipped in
-- CHANGE #1199 — and the very next rg run came back critical-red again, this
-- time naming devtool.build_intelligence: CHANGE #1199 also carried CMD
-- #1824's Build intelligence dashboard, which registered the feature and
-- stopped at exactly the same line. Same class of miss, same fix; a behaviour
-- failure is never rebaselined, the contract IS the fix.
--
-- The contract is the shape every other dev tool carries (see
-- devtool.cron_health / devtool.token_dashboard): the door is the deep link
-- /admin/go/<route_key>, main.dart writes the resolved key into the render log
-- as c325_deep_link, and home_shell.dart opens any key in kDevToolKeys —
-- 'build_intelligence' is in that set (dev_queue_screen.dart) and
-- openDevTool() pushes BuildIntelligenceScreen, so this describes a journey
-- that really runs rather than one that merely type-checks.
--
-- Idempotent on purpose (the merge worker replays it on live, and it may run
-- on a build branch that already has a contract): the UPDATE is fenced on
-- `not has_test_contract`, so it fills a GAP and never overwrites a contract
-- somebody else authored.
do $c1833b$
declare v_n int := 0;
begin
  if to_regclass('public.feature_registry') is null then
    raise notice 'c1833: no feature_registry here — nothing to declare';
    return;
  end if;

  update public.feature_registry f
     set test_entry       = '/admin/go/build_intelligence',
         test_roles       = array['super_admin']::text[],
         test_steps       = jsonb_build_array(
                              jsonb_build_object('kind','auth','role','{role}'),
                              jsonb_build_object('kind','goto','path','/admin/go/build_intelligence'),
                              jsonb_build_object('kind','settle','ms',6000)
                            ),
         test_expect      = jsonb_build_object(
                              'kind','visible','source','render_log',
                              'key','c325_deep_link','equals','build_intelligence'
                            ),
         test_automatable = true,
         test_contract_at = now()
   where f.feature_key = 'devtool.build_intelligence'
     and not f.has_test_contract;
  get diagnostics v_n = row_count;

  -- the coverage ledger is what the journey bot reads; keep it in step.
  if v_n > 0 and to_regprocedure('public.test_coverage_sync(text)') is not null then
    perform public.test_coverage_sync('devtool.build_intelligence');
  end if;

  raise notice 'c1833: build intelligence contract rows updated: %', v_n;
end
$c1833b$;

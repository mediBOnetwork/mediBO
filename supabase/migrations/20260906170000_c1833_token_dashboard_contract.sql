-- CMD #1833 — the Token dashboard declares its test contract.
--
-- CHANGE #1197 shipped CMD #1820's Token dashboard, which registered
-- devtool.token_dashboard in feature_registry and stopped there. c634's gate
-- (rg_behavior_tests.c634_every_feature_declares_a_test_contract) says no
-- ACTIVE feature may be without a contract, so the very next scheduled rg run
-- came back critical-red with "1 active feature(s) have no test contract:
-- devtool.token_dashboard". A behaviour failure is never rebaselined — the
-- contract is the fix.
--
-- The contract is the same shape every other dev tool carries (see
-- devtool.cron_health / devtool.bug_report): the door is the deep link
-- /admin/go/<route_key>, main.dart writes the resolved key to the render log
-- as c325_deep_link, and home_shell.dart opens any key in kDevToolKeys —
-- 'token_dashboard' is in that set and openDevTool() pushes
-- TokenDashboardScreen, so this contract describes a journey that really runs.
--
-- Idempotent on purpose (the merge worker replays it on live, and it may run
-- on a build branch that already has a contract): the UPDATE is fenced on
-- `not has_test_contract`, so it fills a GAP and never overwrites a contract
-- somebody else authored.
do $c1833$
declare v_n int := 0;
begin
  if to_regclass('public.feature_registry') is null then
    raise notice 'c1833: no feature_registry here — nothing to declare';
    return;
  end if;

  update public.feature_registry f
     set test_entry       = '/admin/go/token_dashboard',
         test_roles       = array['super_admin']::text[],
         test_steps       = jsonb_build_array(
                              jsonb_build_object('kind','auth','role','{role}'),
                              jsonb_build_object('kind','goto','path','/admin/go/token_dashboard'),
                              jsonb_build_object('kind','settle','ms',6000)
                            ),
         test_expect      = jsonb_build_object(
                              'kind','visible','source','render_log',
                              'key','c325_deep_link','equals','token_dashboard'
                            ),
         test_automatable = true,
         test_contract_at = now()
   where f.feature_key = 'devtool.token_dashboard'
     and not f.has_test_contract;
  get diagnostics v_n = row_count;

  -- the coverage ledger is what the journey bot reads; keep it in step.
  if v_n > 0 and to_regprocedure('public.test_coverage_sync(text)') is not null then
    perform public.test_coverage_sync('devtool.token_dashboard');
  end if;

  raise notice 'c1833: token dashboard contract rows updated: %', v_n;
end
$c1833$;

-- replay-target: production
--   feature_registry is in scripts/control_plane_tables.txt, so the replay
--   heuristic routes any file naming that table to BOTH databases — and the
--   control plane's copy has no test_* columns at all, so a control-plane pass
--   dies on `column "test_automatable" does not exist` and takes the WHOLE
--   batch down with it (that is what happened to #992 in batch 585). The test
--   contract is a production concern either way: the guard that reads it,
--   rg_contract_gap(), only exists there.
--
-- CMD #639 — devtool.triage declares its test contract.
--
-- 20260906060000_c639_triage_loop.sql inserted the feature row is_active, and
-- activating a feature_registry row is not free: rg_check's behaviour test
-- c634_every_feature_declares_a_test_contract asserts that NO active feature is
-- without a contract, so the guard went red in the same command that added it
-- with "1 active feature(s) have no test contract: devtool.triage". That is the
-- gate doing its job — this file is the answer, not a workaround.
--
-- test_roles is {super_admin} alone, even though roles_allowed names the same
-- single role: triage_inbox() runs _dev_guard() and triage_approve() refuses
-- anyone who is not a signed-in super admin, so a contract naming 'admin' would
-- be a contract that fails by design.
--
-- test_expect names the screen's OWN render key rather than boot_status:
-- boot_status is painted by the shell for ANY route, including the
-- fall-through that renders "route unavailable", so it cannot tell a live door
-- from a dead one. c639_triage is written by TriageInboxScreen itself, on both
-- the loaded and the refused path.

UPDATE public.feature_registry
   SET test_automatable = true,
       test_entry       = '/admin/go/triage',
       test_roles       = array['super_admin']::text[],
       test_steps       = '[{"kind":"auth","role":"{role}"},
                            {"kind":"goto","path":"/admin/go/triage"},
                            {"kind":"settle","ms":6000}]'::jsonb,
       test_expect      = '{"kind":"visible","source":"render_log",
                            "key":"c639_triage","equals":"painted"}'::jsonb
 WHERE feature_key = 'devtool.triage';

-- CMD #992 — the two scorecard features declare their test contract.
--
-- Activating a feature_registry row is not free: rg_check's behaviour test
-- c634_every_feature_declares_a_test_contract asserts that NO active feature
-- is without one, so the moment 20260906021500 flipped is_active the guard
-- went red with "2 active feature(s) have no test contract". #693 could not
-- have written this — it left both rows dark precisely because the doors had
-- not shipped, and a contract naming a route the shell could not open would
-- have been a lie. The doors shipped in CHANGE #1175, so the contract can be
-- written from what was actually observed on the live build rather than from
-- what the screens are supposed to do.
--
-- test_roles is {super_admin} and not {admin,super_admin} on purpose, even
-- though roles_allowed names both. access_effective() gives a non-super admin
-- coalesce(access_grant, access_role_default, false), and #693's
-- access_role_default rows say admin/can_view=false for both features — so
-- _handleAdminNav refuses an admin with c653_nav_denied and the render key
-- never appears. Naming 'admin' here would be a contract that fails by design.
-- super_admin is v=true unconditionally, which is the session that proved both
-- routes on fe6fb395.
--
-- test_expect names the screen's OWN key rather than boot_status: boot_status
-- is painted by the shell for any route at all, including the fall-through
-- that renders "route unavailable", so it cannot tell a live door from a dead
-- one. c693_admin_scorecards / c693_partner_scorecard are written by the two
-- screens themselves.
update public.feature_registry
   set test_automatable = true,
       test_entry       = '/admin/go/partner_scorecards',
       test_roles       = array['super_admin']::text[],
       test_steps       = '[{"kind":"auth","role":"{role}"},
                            {"kind":"goto","path":"/admin/go/partner_scorecards"},
                            {"kind":"settle","ms":6000}]'::jsonb,
       test_expect      = '{"kind":"visible","source":"render_log",
                            "key":"c693_admin_scorecards","equals":"painted"}'::jsonb
 where feature_key = 'admin.partner_scorecards';

update public.feature_registry
   set test_automatable = true,
       test_entry       = '/admin/go/partner_scorecard',
       test_roles       = array['super_admin']::text[],
       test_steps       = '[{"kind":"auth","role":"{role}"},
                            {"kind":"goto","path":"/admin/go/partner_scorecard"},
                            {"kind":"settle","ms":6000}]'::jsonb,
       test_expect      = '{"kind":"visible","source":"render_log",
                            "key":"c693_partner_scorecard","equals":"painted"}'::jsonb
 where feature_key = 'partner.scorecard';

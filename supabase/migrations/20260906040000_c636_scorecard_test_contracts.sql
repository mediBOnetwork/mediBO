-- CHANGE #636 — the two partner-scorecard features declare a test contract.
--
-- Not this command's feature, but this command's red guard: #992 flipped
-- admin.partner_scorecards and partner.scorecard to is_active=true, and
-- rg_contract_gap() only judges ACTIVE rows — so the moment those tiles went
-- live the c634 behaviour went red for every runner trying to complete, this
-- one included. Repairing it is cheaper than routing around it, and the
-- contract below is the same three-step shape every other dashboard feature
-- already carries (auth as the role, goto the registry's own /admin/go door,
-- settle, then assert the render-log painted).
--
-- Written as an UPDATE that only fills the gap: a row that already declares a
-- contract (because #992 or a later command got there first) is left exactly
-- as it stands, so replaying this file can never overwrite a better answer.
-- Idempotent by construction and safe on both databases.

update public.feature_registry f
   set test_entry   = '/admin/go/' || f.route_key,
       test_roles   = coalesce(nullif(f.roles_allowed, '{}'), array['admin','super_admin']),
       test_steps   = jsonb_build_array(
                        jsonb_build_object('kind','auth','role','{role}'),
                        jsonb_build_object('kind','goto','path','/admin/go/' || f.route_key),
                        jsonb_build_object('kind','settle','ms',6000)
                      ),
       test_expect  = jsonb_build_object(
                        'kind','visible','source','render_log',
                        'key','boot_status','equals','painted'
                      ),
       test_contract_at = now()
 where f.feature_key in ('admin.partner_scorecards', 'partner.scorecard')
   and not f.has_test_contract
   and coalesce(btrim(f.route_key), '') <> '';

-- CHANGE #1149 — branch seed. Applied to a fresh build branch right after it
-- is created. Only the synthetic cast: test mode, the QA identities and the
-- test fixtures. NEVER customer, supplier, order or bill rows. Idempotent.
-- Regenerate: bash scripts/branch_seed_regen.sh (writes this file from live).
begin;
insert into public.test_mode_config (id, enabled, session_hours, allow_outbound, test_phone) values (1, true, 12, false, null) on conflict (id) do update set enabled = true, allow_outbound = false, test_phone = null;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('super_admin', NULL, NULL, 'seed a test-only super_admin account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('admin', NULL, NULL, 'seed a test-only admin account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('supplier', NULL, NULL, 'seed a test-only supplier account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('customer', NULL, NULL, 'seed a test-only customer account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('company', NULL, NULL, 'seed a test-only company account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('mr', NULL, NULL, 'seed a test-only mr account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('delivery', NULL, NULL, 'seed a test-only delivery account, set account_id + ready', 'f') on conflict do nothing;
insert into public.qa_test_identities (role, account_id, identity, note, ready) values ('worker', NULL, NULL, 'seed a test-only worker account, set account_id + ready', 'f') on conflict do nothing;
insert into public.test_fixture (key, kind, entity_id, label, detail) values ('pharmacy', 'customer', '12e3b6ba-3358-47a7-832e-3ce175dd7825', 'TST TEST PHARMACY - SYNTHETIC (DO NOT USE)', '{"zone_id": 99}'::jsonb) on conflict (key) do update set kind = excluded.kind, entity_id = excluded.entity_id, label = excluded.label, detail = excluded.detail;
insert into public.test_fixture (key, kind, entity_id, label, detail) values ('supplier', 'supplier', '769a7b1d-43f3-4b13-91c6-b849eb405a3c', 'TST TEST SUPPLIER - SYNTHETIC (DO NOT USE)', '{"zone_id": 99}'::jsonb) on conflict (key) do update set kind = excluded.kind, entity_id = excluded.entity_id, label = excluded.label, detail = excluded.detail;
insert into public.test_fixture (key, kind, entity_id, label, detail) values ('rider', 'delivery', 'a87bfed5-a066-42b1-9da2-54494852a80e', 'TST TEST RIDER - SYNTHETIC (DO NOT USE)', '{"zone_id": 99}'::jsonb) on conflict (key) do update set kind = excluded.kind, entity_id = excluded.entity_id, label = excluded.label, detail = excluded.detail;
insert into public.test_fixture (key, kind, entity_id, label, detail) values ('zone', 'zone', NULL, 'Zone tst', '{"note": "the synthetic cast is pinned to one zone so a test order never routes elsewhere", "zone_id": 99}'::jsonb) on conflict (key) do update set kind = excluded.kind, entity_id = excluded.entity_id, label = excluded.label, detail = excluded.detail;
commit;

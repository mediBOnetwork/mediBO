-- CHANGE #394 — the proof, run against production by scripts/audit_perm_proof.sh.
--
-- Two claims, both made the hard way (as the ACTUAL admin, through the RPC,
-- with RLS on) rather than by reading the source:
--   A. an admin without a permission gets nothing from the RPC;
--   B. every listed action writes exactly ONE audit row, with before/after.
--
-- Everything it writes it rolls back, so it is safe to re-run on production.

\set ON_ERROR_STOP on
begin;

-- The three characters: a super admin, a non-super admin, and the feature.
create temporary table t_ids as
select (select id from admins where is_super order by email limit 1)      as super_id,
       (select id from admins where not coalesce(is_super,false)
          and email = 'test.admin@medibo.in' limit 1)                     as plain_id;

-- Become that admin the way a real login does: admins.id is NOT the auth user
-- id (they are separate rows), so the session claims must carry the AUTH id —
-- exactly what a browser session carries — or get_my_role() resolves nothing
-- and the proof would be measuring its own harness.
create or replace function pg_temp.be(p uuid) returns void
language plpgsql as $$
declare v_email text; v_uid uuid;
begin
  select lower(btrim(a.email)) into v_email from public.admins a where a.id = p;
  select u.id into v_uid from auth.users u where lower(btrim(u.email)) = v_email;
  perform set_config('request.jwt.claims',
    json_build_object('sub', coalesce(v_uid, p)::text, 'email', v_email,
                      'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

\echo '=== A1. plain admin, no grant → admin_access = none, RPC refuses ==='
select pg_temp.be((select plain_id from t_ids));
select admin_access('admin.discount_slabs')             as access_expect_none,
       admin_can('admin.discount_slabs','read')         as can_read_expect_f,
       (admin_discount_slabs() ->> 'ok')                as slabs_ok_expect_false,
       (admin_discount_slabs() ->> 'error')             as slabs_error_expect_not_authorized;

\echo '=== A2. same admin, granted read → list opens, WRITE still refused ==='
reset role;
select set_config('request.jwt.claims', null, true);
insert into admin_permissions(admin_id, feature_key, access, updated_by)
select plain_id, 'admin.discount_slabs', 'read', 'proof' from t_ids
on conflict (admin_id, feature_key) do update set access = 'read';

select pg_temp.be((select plain_id from t_ids));
select admin_access('admin.discount_slabs')      as access_expect_read,
       admin_can('admin.discount_slabs','read')  as can_read_expect_t,
       admin_can('admin.discount_slabs','write') as can_write_expect_f,
       (admin_discount_slabs() ->> 'ok')         as slabs_ok_expect_true,
       (admin_discount_slab_set_active(
          (select id from discount_slabs order by id limit 1), true) ->> 'error')
                                                 as write_error_expect_not_authorized;

\echo '=== A3. the super admin override still sees everything ==='
reset role;
select set_config('request.jwt.claims', null, true);
select pg_temp.be((select super_id from t_ids));
select admin_access('admin.dev_queue')      as super_dev_queue_expect_write,
       admin_access('admin.audit_log')      as super_audit_expect_write,
       admin_can('admin.discount_slabs','write') as super_write_expect_t;

\echo '=== A4. a NEW screen defaults to none for a granted admin (never opt-out) ==='
reset role;
select set_config('request.jwt.claims', null, true);
select pg_temp.be((select plain_id from t_ids));
select admin_access('admin.audit_log') as new_screen_expect_none,
       admin_access('admin.dev_queue') as dev_queue_expect_none;

\echo '=== B1. row trigger: one grant change → exactly one audit row, before/after ==='
reset role;
select set_config('request.jwt.claims', null, true);
create temporary table t_mark as select coalesce(max(id),0) as id from audit_log;

select pg_temp.be((select super_id from t_ids));
select admin_perm_set('test.admin@medibo.in', 'admin.discount_slabs', 'write') ->> 'ok' as perm_set_ok;

reset role;
select set_config('request.jwt.claims', null, true);
select count(*)                                   as rows_written_expect_1,
       min(action)                                as action,
       min(entity_type)                           as entity_type,
       min(actor_email)                           as actor_email,
       min(before ->> 'access')                   as before_access_expect_read,
       min(after  ->> 'access')                   as after_access_expect_write,
       min(array_to_string(changed_keys, ','))    as changed_keys
  from audit_log where id > (select id from t_mark);

\echo '=== B2. a direct table write is audited exactly like the RPC (un-bypassable) ==='
update t_mark set id = (select max(id) from audit_log);
update discount_slabs set discount_pct = discount_pct
 where id = (select id from discount_slabs order by id limit 1);
select count(*) as rows_expect_0_no_real_change from audit_log where id > (select id from t_mark);

update discount_slabs set note = coalesce(note,'') || ' (proof)'
 where id = (select id from discount_slabs order by id limit 1);
select count(*)                                as rows_expect_1,
       min(action)                             as action_expect_discount_slab_update,
       min(array_to_string(changed_keys, ',')) as changed_keys_expect_note
  from audit_log where id > (select id from t_mark);

\echo '=== B3. audit_write(): an ACTION event, not a row diff ==='
update t_mark set id = (select max(id) from audit_log);
select audit_write('order.cancel','order','00000000-0000-0000-0000-000000000000',
                   '{"status":"packing"}'::jsonb, '{"status":"cancelled"}'::jsonb) > 0 as wrote;
select count(*) as rows_expect_1, min(action) as action, min(array_to_string(changed_keys,',')) as changed
  from audit_log where id > (select id from t_mark);

\echo '=== B4. the log is append-only — UPDATE and DELETE both raise ==='
do $$
declare v_id bigint := (select max(id) from audit_log); v_upd text; v_del text;
begin
  begin update audit_log set action = 'tampered' where id = v_id;
  exception when others then v_upd := sqlerrm; end;
  begin delete from audit_log where id = v_id;
  exception when others then v_del := sqlerrm; end;
  raise notice 'update blocked: %', coalesce(v_upd,'NOT BLOCKED — BUG');
  raise notice 'delete blocked: %', coalesce(v_del,'NOT BLOCKED — BUG');
end $$;

\echo '=== B5. the screen RPC renders it, and is itself permission-gated ==='
select pg_temp.be((select super_id from t_ids));
select (admin_audit_screen('{}'::jsonb) ->> 'ok')                      as screen_ok,
       jsonb_array_length(admin_audit_screen('{}'::jsonb) -> 'rows')   as rows_rendered,
       (admin_audit_screen('{}'::jsonb) -> 'rows' -> 0 ->> 'title')    as first_row_title;
reset role;
select set_config('request.jwt.claims', null, true);
select pg_temp.be((select plain_id from t_ids));
select (admin_audit_screen('{}'::jsonb) ->> 'ok')    as screen_ok_expect_false,
       (admin_audit_screen('{}'::jsonb) ->> 'error') as screen_error_expect_not_authorized;

rollback;

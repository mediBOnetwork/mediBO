-- CHANGE #394 — the proof. Rewritten by CHANGE #422 (debug pass).
--
-- Two claims, both made the hard way (as the ACTUAL admin, through the RPC,
-- with RLS on) rather than by reading the source:
--   A. an admin without a permission gets nothing from the RPC;
--   B. every listed action writes exactly ONE audit row, with before/after.
--
-- Everything it writes it rolls back, so it is safe to re-run on production.
--
-- ── why this file was rewritten ────────────────────────────────────────────
-- The first version could not fail, and by the time #422 ran it it was
-- printing the OPPOSITE of what its own column names claimed:
--
--   access_expect_none  | slabs_ok_expect_false | new_screen_expect_none
--   write               | true                  | read
--
-- Two faults, and the second is the one that matters:
--
--   1. It ASSUMED its non-super admin had no grants — while the sibling
--      migration in the same change (…093000_admin_perm_backfill_existing)
--      deliberately granted every existing admin the full preset. The premise
--      was contradicted by its own change on the day it shipped.
--   2. Every claim was a bare SELECT with the expectation written into the
--      COLUMN NAME. \set ON_ERROR_STOP only catches SQL errors, so a false
--      claim printed quietly and the script still exited 0. A proof that
--      cannot go red is not a proof — it is a report nobody reads.
--
-- So: the harness now MAKES the condition it is testing (it deletes the plain
-- admin's grants inside the transaction it rolls back) instead of hoping
-- production is in the right shape, and every claim is an assert() that raises
-- — which ON_ERROR_STOP turns into a non-zero exit.

\set ON_ERROR_STOP on
begin;

-- ── assertions that actually fail ──────────────────────────────────────────
create or replace function pg_temp.ok(p_claim text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'PROOF FAILED — % : expected %, got %',
      p_claim, coalesce(p_want::text,'<null>'), coalesce(p_got::text,'<null>');
  end if;
  raise notice '  ok  %  (= %)', p_claim, coalesce(p_got::text,'<null>');
end $$;

-- The three characters: a super admin, a non-super admin, and the feature.
create temporary table t_ids as
select (select id from admins where is_super order by email limit 1)      as super_id,
       (select id from admins where not coalesce(is_super,false)
          and email = 'test.admin@medibo.in' limit 1)                     as plain_id;

do $$ begin
  if (select plain_id from t_ids) is null or (select super_id from t_ids) is null then
    raise exception 'PROOF FAILED — the harness needs one super admin and test.admin@medibo.in';
  end if;
end $$;

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

create or replace function pg_temp.nobody() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

-- ── the condition under test, MADE not assumed ─────────────────────────────
-- #394's own backfill gives every existing admin the full preset, so "an
-- admin with no grant" does not exist in production and cannot be borrowed.
-- The harness creates it here, inside the transaction it rolls back.
delete from admin_permissions where admin_id = (select plain_id from t_ids);

\echo '=== A1. plain admin, no grant → admin_access = none, RPC refuses ==='
select pg_temp.be((select plain_id from t_ids));
do $$ begin
  perform pg_temp.ok('ungranted admin: admin_access(admin.discount_slabs)',
                     admin_access('admin.discount_slabs'), 'none');
  perform pg_temp.ok('ungranted admin: admin_can(read)',
                     admin_can('admin.discount_slabs','read'), false);
  perform pg_temp.ok('ungranted admin: the slab RPC refuses',
                     admin_discount_slabs() ->> 'ok', 'false');
  perform pg_temp.ok('ungranted admin: and says why',
                     admin_discount_slabs() ->> 'error', 'not_authorized');
  perform pg_temp.ok('ungranted admin: the audit screen refuses',
                     admin_audit_screen('{}'::jsonb) ->> 'error', 'not_authorized');
  perform pg_temp.ok('ungranted admin: one entity history refuses',
                     admin_audit_entity('order','x') ->> 'error', 'not_authorized');
  perform pg_temp.ok('ungranted admin: the roles editor is super-only',
                     admin_roles_screen() ->> 'error', 'not_authorized');
  perform pg_temp.ok('ungranted admin: nav shows no tile at all',
                     jsonb_array_length(coalesce(nav_registry() -> 'sections','[]'::jsonb)), 0);
  perform pg_temp.ok('ungranted admin: RLS hides the audit log',
                     (select count(*) from audit_log), 0::bigint);
  perform pg_temp.ok('ungranted admin: RLS hides the grant table',
                     (select count(*) from admin_permissions), 0::bigint);
end $$;

\echo '=== A2. same admin, granted read → list opens, WRITE still refused ==='
select pg_temp.nobody();
insert into admin_permissions(admin_id, feature_key, access, updated_by)
select plain_id, 'admin.discount_slabs', 'read', 'proof' from t_ids
on conflict (admin_id, feature_key) do update set access = 'read';

select pg_temp.be((select plain_id from t_ids));
do $$ begin
  perform pg_temp.ok('granted read: access is read', admin_access('admin.discount_slabs'), 'read');
  perform pg_temp.ok('granted read: may read',  admin_can('admin.discount_slabs','read'),  true);
  perform pg_temp.ok('granted read: may NOT write', admin_can('admin.discount_slabs','write'), false);
  perform pg_temp.ok('granted read: the list opens', admin_discount_slabs() ->> 'ok', 'true');
  perform pg_temp.ok('granted read: the mutation is still refused',
    admin_discount_slab_set_active((select id from discount_slabs order by id limit 1), true) ->> 'error',
    'not_authorized');
end $$;

\echo '=== A3. the super admin override still sees everything ==='
select pg_temp.nobody();
select pg_temp.be((select super_id from t_ids));
do $$ begin
  perform pg_temp.ok('super: dev queue',   admin_access('admin.dev_queue'), 'write');
  perform pg_temp.ok('super: audit log',   admin_access('admin.audit_log'), 'write');
  perform pg_temp.ok('super: may write',   admin_can('admin.discount_slabs','write'), true);
end $$;

\echo '=== A4. a NEW screen defaults to none for a granted admin (never opt-out) ==='
select pg_temp.nobody();
select pg_temp.be((select plain_id from t_ids));
do $$ begin
  -- the admin now holds a grant (A2) — a screen nobody granted is still none.
  perform pg_temp.ok('granted admin: audit log was never granted',
                     admin_access('admin.audit_log'), 'none');
  perform pg_temp.ok('granted admin: dev queue was never granted',
                     admin_access('admin.dev_queue'), 'none');
end $$;

\echo '=== A5. anon reaches none of it ==='
select pg_temp.nobody();
select set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
do $$ begin
  perform pg_temp.ok('anon: access is none', admin_access('admin.audit_log'), 'none');
  perform pg_temp.ok('anon: the audit screen refuses',
                     admin_audit_screen('{}'::jsonb) ->> 'error', 'not_authorized');
  perform pg_temp.ok('anon: the roles editor refuses',
                     admin_roles_screen() ->> 'error', 'not_authorized');
  -- CHANGE #422: audit_write() is SECURITY DEFINER and shipped with the
  -- default PUBLIC grant, so the anon key in the web bundle could forge rows
  -- into a log that is append-only BY DESIGN and can never be cleaned.
  perform pg_temp.ok('anon: cannot EXECUTE audit_write',
    has_function_privilege('anon','public.audit_write(text,text,text,jsonb,jsonb)','execute'), false);
  perform pg_temp.ok('anon: cannot EXECUTE the audit row trigger fn',
    has_function_privilege('anon','public.audit_row_trg()','execute'), false);
  perform pg_temp.ok('anon: cannot EXECUTE the access answer either',
    has_function_privilege('anon','public.admin_access(text,uuid)','execute'), false);
  perform pg_temp.ok('signed-in: cannot EXECUTE audit_write either',
    has_function_privilege('authenticated','public.audit_write(text,text,text,jsonb,jsonb)','execute'), false);
end $$;

-- The catalog answer above is authoritative, but a grant table and a live call
-- have disagreed before — and this one is worth watching actually fail. psql
-- runs at the top level, so it can become anon for real; the rg guard cannot
-- (`set role` is illegal inside a SECURITY DEFINER function), which is exactly
-- why the live half lives here.
select set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
set local role anon;
do $$
declare v bigint; v_msg text;
begin
  begin
    select public.audit_write('forged','probe','anon','{}'::jsonb,'{}'::jsonb) into v;
    v_msg := 'WROTE ROW ' || v::text;
  exception when insufficient_privilege then
    v_msg := 'refused';
  end;
  perform pg_temp.ok('anon: a live audit_write call is refused', v_msg, 'refused');
end $$;
reset role;

\echo '=== B1. row trigger: one grant change → exactly one audit row, before/after ==='
select pg_temp.nobody();
create temporary table t_mark as select coalesce(max(id),0) as id from audit_log;

select pg_temp.be((select super_id from t_ids));
select admin_perm_set('test.admin@medibo.in', 'admin.discount_slabs', 'write') ->> 'ok' as perm_set_ok;

select pg_temp.nobody();
do $$
declare r record;
begin
  select count(*) as n, min(action) as action, min(entity_type) as entity_type,
         min(before ->> 'access') as before_access, min(after ->> 'access') as after_access,
         min(array_to_string(changed_keys, ',')) as keys
    into r from audit_log where id > (select id from t_mark);
  perform pg_temp.ok('one grant change writes exactly one row', r.n, 1::bigint);
  perform pg_temp.ok('…named for the entity', r.action, 'admin_permission.update');
  perform pg_temp.ok('…with the entity type', r.entity_type, 'admin_permission');
  perform pg_temp.ok('…carrying the BEFORE value', r.before_access, 'read');
  perform pg_temp.ok('…and the AFTER value',      r.after_access,  'write');
  perform pg_temp.ok('…and naming what changed',  r.keys, 'access,updated_by');
end $$;

\echo '=== B2. a direct table write is audited exactly like the RPC (un-bypassable) ==='
update t_mark set id = (select max(id) from audit_log);
update discount_slabs set discount_pct = discount_pct
 where id = (select id from discount_slabs order by id limit 1);
do $$ begin
  perform pg_temp.ok('an UPDATE that changes nothing writes nothing',
                     (select count(*) from audit_log where id > (select id from t_mark)), 0::bigint);
end $$;

update discount_slabs set note = coalesce(note,'') || ' (proof)'
 where id = (select id from discount_slabs order by id limit 1);
do $$
declare r record;
begin
  select count(*) as n, min(action) as action,
         min(array_to_string(changed_keys, ',')) as keys
    into r from audit_log where id > (select id from t_mark);
  perform pg_temp.ok('a direct table write is audited', r.n, 1::bigint);
  perform pg_temp.ok('…as the row trigger, not an RPC', r.action, 'discount_slab.update');
  perform pg_temp.ok('…naming only the column that moved', r.keys, 'note');
end $$;

\echo '=== B3. audit_write(): an ACTION event, not a row diff ==='
update t_mark set id = (select max(id) from audit_log);
do $$
declare r record;
begin
  perform pg_temp.ok('audit_write returns a row id',
    audit_write('order.cancel','order','00000000-0000-0000-0000-000000000000',
                '{"status":"packing"}'::jsonb, '{"status":"cancelled"}'::jsonb) > 0, true);
  select count(*) as n, min(action) as action,
         min(array_to_string(changed_keys,',')) as keys
    into r from audit_log where id > (select id from t_mark);
  perform pg_temp.ok('one action event, one row', r.n, 1::bigint);
  perform pg_temp.ok('…under its own action name', r.action, 'order.cancel');
  perform pg_temp.ok('…diffed from before/after',  r.keys, 'status');
end $$;

\echo '=== B4. the log is append-only — UPDATE and DELETE both raise ==='
do $$
declare v_id bigint := (select max(id) from audit_log); v_upd text; v_del text;
begin
  begin update audit_log set action = 'tampered' where id = v_id;
  exception when others then v_upd := sqlerrm; end;
  begin delete from audit_log where id = v_id;
  exception when others then v_del := sqlerrm; end;
  perform pg_temp.ok('UPDATE is refused', v_upd, 'audit_log is append-only: UPDATE is not permitted');
  perform pg_temp.ok('DELETE is refused', v_del, 'audit_log is append-only: DELETE is not permitted');
end $$;

\echo '=== B5. the screen RPC renders it, and is itself permission-gated ==='
select pg_temp.be((select super_id from t_ids));
do $$
declare v jsonb := admin_audit_screen('{}'::jsonb);
begin
  perform pg_temp.ok('super: the audit screen opens', v ->> 'ok', 'true');
  perform pg_temp.ok('super: and it rendered rows',
                     jsonb_array_length(v -> 'rows') > 0, true);
  perform pg_temp.ok('super: every row arrives pre-titled by the backend',
                     (v -> 'rows' -> 0 ->> 'title') is not null, true);
end $$;

select pg_temp.nobody();
select pg_temp.be((select plain_id from t_ids));
do $$ begin
  -- the plain admin holds admin.discount_slabs (A2/B1) and nothing else: the
  -- audit screen is a DIFFERENT feature and must still be shut.
  perform pg_temp.ok('a granted admin without THIS grant is refused',
                     admin_audit_screen('{}'::jsonb) ->> 'ok', 'false');
  perform pg_temp.ok('…with the backend''s own reason',
                     admin_audit_screen('{}'::jsonb) ->> 'error', 'not_authorized');
end $$;

select pg_temp.nobody();
\echo '=== PROOF GREEN — every claim above asserted, nothing left in the database ==='
rollback;

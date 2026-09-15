-- CHANGE #422 — debug pass on #394: the audit log was writable by anyone.
--
-- #394 built the log correctly in every way but one. audit_write() is
-- SECURITY DEFINER (it has to be — it writes a table nobody may write) and it
-- was created without a grant statement, so it kept the default PUBLIC EXECUTE
-- that every new function inherits. Proven against production inside a rolled
-- back transaction:
--
--     set local role anon;
--     select audit_write('payout.pay','payout_period','forged-by-anon',
--                        '{"paid":false}','{"paid":true}');
--     -- → 152, one row, actor_role 'none', source 'anon'
--
-- The anon key is printed in the web bundle, so that is a public endpoint. And
-- because the log is append-only BY DESIGN, a forged row can never be removed:
-- the property that makes the trail trustworthy is the same property that
-- makes poisoning it permanent. An audit trail a stranger can write to is
-- worse than no audit trail, because it is believed.
--
-- This is the shape of feature_gaps #25 and of #353's four money functions —
-- a new SECURITY DEFINER function inherits PUBLIC EXECUTE — which is why the
-- fix ends with an rg behaviour test rather than a revoke nobody re-checks.
--
-- Nothing internal breaks: audit_write() and audit_row_trg() are only ever
-- reached from inside SECURITY DEFINER functions and triggers, which execute
-- as the owner and do not consult the caller's grants. Verified first: no RLS
-- policy and no SECURITY INVOKER function in public references any of these.

-- ── the writers and the definer-chain internals: backend only ─────────────
-- EXECUTE is revoked from every client role. Each of these is reached only
-- from inside a SECURITY DEFINER function or a trigger, which run as the owner
-- and never consult the caller's grants — verified first: no RLS policy and no
-- SECURITY INVOKER function in public references any of them.
--
-- The writers are matched by PATTERN (audit_write%), not by name. While this
-- migration was being written a parallel change added audit_write_ex() — a
-- second SECURITY DEFINER writer into the same append-only log, anon-callable
-- within minutes of the first one being closed. A revoke written as a list of
-- names only ever closes the hole it was written for.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'audit\_write%'
            or p.proname in ('audit_actor','audit_row_trg','audit_log_immutable',
                             '_slab_can_admin','_audit_row','_audit_val','_audit_when'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ── the read-only access answers: signed-in only ──────────────────────────
-- These five only ever answer about the CALLER (a super admin may name another
-- admin; nobody else can), so they leak nothing to a signed-in user and are
-- deliberately left callable by `authenticated`: over-revoking a read-only
-- helper breaks invoker-side callers for no security gain. An ANONYMOUS caller
-- has no admin identity to ask about, so anon loses them.
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_access(text,uuid)',
    'public.admin_can(text,text)',
    'public.admin_require(text,text)',
    'public.admin_guard(text)',
    'public.my_admin_id()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- ── the five screen RPCs the app actually calls: signed-in only ────────────
-- Each one is already gated internally (admin_require / _is_super), so this is
-- depth, not the fence: an anonymous caller should not reach an admin RPC at
-- all, the way #353 left the supplier money surface.
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_audit_screen(jsonb)',
    'public.admin_audit_entity(text,text)',
    'public.admin_roles_screen()',
    'public.admin_perm_set(text,text,text)',
    'public.admin_perm_apply_preset(text,text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- ── and the guard that notices if it is ever handed back ───────────────────
insert into public.rg_behavior_tests(name, body, enabled, note) values (
'audit_log_write_is_not_public',
$rg$
do $body$
declare f record; v_id bigint;
begin
  -- The rg runner executes this inside a SECURITY DEFINER function, where
  -- `set role` is illegal — so the live anon call lives in
  -- scripts/audit_perm_proof.sql (psql, top level) and this guard asks the
  -- catalog, which is the authoritative answer about a GRANT anyway.
  --
  -- Deliberately a PATTERN, not a list. #422 closed audit_write(); the very
  -- next change added audit_write_ex(), which would have inherited the same
  -- default PUBLIC EXECUTE. A guard written as a list of names only ever
  -- catches the bug it was written for.
  for f in
    select p.oid,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'audit\_write%' or p.proname in
            ('audit_actor','audit_row_trg','audit_log_immutable'))
  loop
    if has_function_privilege('anon', f.oid, 'execute') then
      raise exception 'RG_FAIL: anon can EXECUTE % — the anon key ships in the web bundle, so that is a public endpoint writing an APPEND-ONLY log whose forged rows can never be removed (#422, same shape as #25/#353)', f.sig;
    end if;
    if has_function_privilege('authenticated', f.oid, 'execute') then
      raise exception 'RG_FAIL: authenticated can EXECUTE % — any signed-in customer could forge audit entries (#422)', f.sig;
    end if;
  end loop;

  -- the permission internals and the admin screens: closed to anon.
  for f in
    select p.oid,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('admin_access','admin_can','admin_require','admin_guard',
                         'my_admin_id','admin_audit_screen','admin_audit_entity',
                         'admin_roles_screen','admin_perm_set','admin_perm_apply_preset')
  loop
    if has_function_privilege('anon', f.oid, 'execute') then
      raise exception 'RG_FAIL: anon can EXECUTE % — an anonymous caller has no admin identity to ask about (#422)', f.sig;
    end if;
  end loop;

  -- the table itself stays unwritable by a client role.
  if has_table_privilege('anon','public.audit_log','insert')
     or has_table_privilege('authenticated','public.audit_log','insert') then
    raise exception 'RG_FAIL: a client role can INSERT into audit_log directly (#422)';
  end if;
  if has_table_privilege('anon','public.audit_log','select') then
    raise exception 'RG_FAIL: anon can SELECT audit_log (#394)';
  end if;

  -- and the trail is still append-only for everyone, the owner included.
  select max(id) into v_id from public.audit_log;
  if v_id is not null then
    begin
      update public.audit_log set action = 'tampered' where id = v_id;
      raise exception 'RG_FAIL: audit_log accepted an UPDATE — it is not append-only (#394/#422)';
    exception when others then
      if sqlerrm like 'RG_FAIL%' then raise; end if;
    end;
  end if;

  raise exception 'RG_ROLLBACK';
end $body$;
$rg$,
true,
'CHANGE #422 (debug pass on #394) — audit_write() is SECURITY DEFINER and shipped with the default PUBLIC EXECUTE, so the anon key in the web bundle could forge rows into an append-only log that can never be cleaned. Same shape as feature_gaps #25 and #353. Matches audit_write% by PATTERN so a sibling writer added later is covered too.'
) on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

comment on function public.audit_write(text,text,text,jsonb,jsonb) is
  'CHANGE #394 — action-shaped audit entries. BACKEND ONLY: EXECUTE is revoked '
  'from public/anon/authenticated (#422) because SECURITY DEFINER + the default '
  'PUBLIC grant made the append-only log forgeable with the web bundle key. '
  'Callers are SECURITY DEFINER RPCs and triggers, which run as the owner.';

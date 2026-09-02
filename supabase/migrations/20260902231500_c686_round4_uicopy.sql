-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #686 — ROUND 4. Two majors from hostile QA round 3.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. the belt-and-braces role check was dead code ─────────────────────
-- Round 3 added `and current_user not in ('postgres', …)` as a second layer
-- under the revoke. But the function is SECURITY DEFINER owned by postgres, so
-- INSIDE the body current_user is ALWAYS 'postgres' — the conjunct was
-- permanently false and the whole AND could never fire. QA proved it: restore
-- the grant in a transaction, `set local role authenticated`, and the RPC
-- happily deleted and rewrote the table. The revoke was doing all the work.
--
-- The signal that actually identifies a PostgREST caller is the JWT role
-- claim; session_user identifies a direct psql/service connection. current_user
-- is meaningless here and is gone.
create or replace function public.ui_copy_param_drift_report(p_report jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_n int; v_role text;
begin
  v_role := coalesce(current_setting('request.jwt.claim.role', true), '');
  if v_role = '' then
    begin
      v_role := coalesce(
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
    exception when others then
      v_role := '';
    end;
  end if;
  -- An explicit non-service JWT role is refused outright, whatever the
  -- connection underneath says — that is the PostgREST caller, and it is also
  -- the only form of this check that can be PROVEN from a psql session, where
  -- session_user is postgres no matter what role is SET. An absent claim means
  -- a direct connection, which must then be a service one.
  if v_role <> '' and v_role is distinct from 'service_role' then
    raise exception 'ui_copy_param_drift_report: service_role only (role=%)', v_role;
  end if;
  if v_role = '' and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'ui_copy_param_drift_report: service_role only (session=%)', session_user;
  end if;

  delete from public.ui_copy_param_drift;   -- the scan is always a full picture
  insert into public.ui_copy_param_drift (kind, key, param, file, line, template)
  select f->>'kind', f->>'key', f->>'param', f->>'file',
         coalesce((f->>'line')::int, 0), coalesce(f->>'template', '')
    from jsonb_array_elements(coalesce(p_report->'findings', '[]'::jsonb)) f
  on conflict (kind, key, param) do nothing;
  select count(*) into v_n from public.ui_copy_param_drift;
  return jsonb_build_object('ok', true, 'count', v_n);
end $fn$;
revoke all on function public.ui_copy_param_drift_report(jsonb)
  from public, anon, authenticated;
grant execute on function public.ui_copy_param_drift_report(jsonb) to service_role;

-- ── 2. one trailing space defeated the bare-expression rule ─────────────
create or replace function public.ui_copy_bare_expression(p_value text)
returns boolean language sql immutable as $fn$
  select btrim(coalesce(p_value, '')) ~ '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$';
$fn$;

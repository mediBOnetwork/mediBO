-- replay-target: production
-- CMD #1982 — the regression guard went red and one CRITICAL signal was
-- behaviour c634_every_feature_declares_a_test_contract:
--     "c634: 1 active feature(s) have no test contract: advance_slabs"
--
-- The row was inserted by CMD #1932 (supabase/migrations/
-- 20260913093000_c1932_advance_ladder.sql, live as CHANGE #1353) with a label,
-- an icon, a route and role defaults — but with test_entry '', test_roles NULL,
-- test_steps [] and test_expect {}. has_test_contract is a GENERATED column, so
-- the guard saw the gap the moment the feature went active. A behaviour failure
-- is never rebaselined (CHANGE #634 is the whole point): the fix is the
-- contract itself.
--
-- The shape is the one every other admin dashboard door already uses
-- (devtool.triage, devtool.token_dashboard): authenticate as the role, open
-- /admin/go/<route_key> — a real deep link since #325, resolved in
-- lib/main.dart and dispatched by lib/screens/shell/shell_extra_routes.dart —
-- let it settle, and assert the screen's OWN render key.
--
-- test_expect names advance_slab_screen rather than boot_status because the
-- shell paints boot_status for ANY route including the "route unavailable"
-- fall-through, so boot_status cannot tell a live door from a dead one (the
-- #639 note, verbatim). AdminAdvanceSlabsScreen writes
-- RenderLog.write('advance_slab_screen', _ok ? 'ok' : 'denied'), so 'ok' is
-- both "the door opened" and "advance_slabs_list() let this role in".
--
-- test_roles is {super_admin} alone even though access_role_default grants
-- admin and partner can_view: _advance_slab_can_write() and the access matrix
-- decide what the other two roles see, and a contract that names them would
-- assert a permission this command does not own.
--
-- Idempotent: one UPDATE of four contract fields, by feature_key, guarded on
-- the gap still being open, and a no-op on a database where CMD #1932's row
-- does not exist (a fresh build branch).

update public.feature_registry set
  test_automatable  = true,
  test_skip_reason  = null,
  test_entry        = '/admin/go/advance_slabs',
  test_roles        = array['super_admin']::text[],
  test_steps        = '[{"kind": "auth", "role": "{role}"},
                        {"kind": "goto", "path": "/admin/go/advance_slabs"},
                        {"ms": 6000, "kind": "settle"}]'::jsonb,
  test_expect       = '{"key": "advance_slab_screen", "kind": "visible",
                        "equals": "ok", "source": "render_log"}'::jsonb,
  test_contract_at  = now()
where feature_key = 'advance_slabs'
  and coalesce(btrim(test_entry), '') = '';

-- Prove the row this migration owns carries a contract now, and only NOTICE
-- about any other uncontracted feature — a row that belongs to another command
-- must not take this deploy hostage (the CMD #1923 rule).
do $c1982$
declare v_mine text; v_rest text; v_has boolean;
begin
  select exists (select 1 from public.feature_registry where feature_key = 'advance_slabs')
    into v_has;
  if not v_has then
    raise notice 'c1982/c634: feature advance_slabs is not on this database — nothing to contract';
    return;
  end if;

  select coalesce(string_agg(feature_key, ', ' order by feature_key), '')
    into v_mine
    from public.rg_contract_gap()
   where feature_key = 'advance_slabs';
  if coalesce(v_mine, '') <> '' then
    raise exception 'c1982/c634: the contract did not take for %', v_mine;
  end if;

  select coalesce(string_agg(feature_key, ', ' order by feature_key), '')
    into v_rest
    from public.rg_contract_gap();
  if coalesce(v_rest, '') <> '' then
    raise notice 'c1982/c634: other active feature(s) still have no test contract: %', left(v_rest, 400);
  end if;
end
$c1982$;

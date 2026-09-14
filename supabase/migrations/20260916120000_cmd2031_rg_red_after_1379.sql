-- CMD #2031 — RG red after #1379: the three critical behaviours, fixed.
--
-- The 163 schema diffs on that run were NOT a regression: every one belongs to
-- CMD #2016 (20260916090000_c2016_order_alert_popup) and CMD #2017
-- (20260914213000_cmd2017_zone99_hard_wall) — both committed, both replayed on
-- live, and the 137 "changed" functions are #2017's own dynamic sweep setting
-- search_path to mode,public on every zone-scoped reader. Those get a
-- rebaseline, not a code change.
--
-- The three CRITICAL signals are real and are what this migration repairs. A
-- failing behaviour is never rebaselined.
--
--   1. privileged_rpcs_are_not_anon — zone_test_id() shipped without its
--      revoke, so the anon key inside the web bundle and the APK could execute
--      it (#436's class of bug).
--   2. c712_customer_events_fire_once — "invalid input syntax for type bigint:
--      {"ok": false, "reason": "synthetic_walled"}". #2017's outbound injector
--      pasted a JSONB early-return into every *_raw send function carrying a
--      p_order_id, including notify_enqueue_retry_raw, which RETURNS BIGINT.
--      The rewrite compiled (plpgsql resolves the return at run time) so the
--      injector's own exception handler never saw it; the wall then threw on
--      every walled call. The wall stays — it just returns a value of the
--      declared type.
--   3. c634_every_feature_declares_a_test_contract — admin.cart_bill (CMD
--      #2014) went active with no test contract at all.
--
-- Idempotent throughout: re-running finds nothing left to change.

-- ─────────── 1 · zone_test_id() is not a public endpoint ───────────
do $anon$
declare v_oid oid := to_regprocedure('public.zone_test_id()');
begin
  -- to_regprocedure, never a cast: a ::regprocedure throws on exactly the
  -- database that has not got the function yet (lesson #263).
  if v_oid is null then return; end if;
  revoke execute on function public.zone_test_id() from public;
  revoke execute on function public.zone_test_id() from anon;
  -- the lockdown must not lock the signed-in roles out of their own RPC: the
  -- same guard that forbids anon also asserts authenticated can still execute.
  grant execute on function public.zone_test_id()
    to authenticated, service_role, postgres;
end $anon$;

-- ─────────── 2 · the hard wall returns the type it declares ───────────
do $wall$
declare r record; v_new text; v_ledger boolean;
begin
  v_ledger := to_regclass('public.mode_guard_path') is not null
          and to_regclass('public.mode_guard_grandfather') is not null;
  for r in
    select p.oid, p.proname,
           pg_get_functiondef(p.oid) as def,
           pg_catalog.format_type(p.prorettype, null) as rettype
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and pg_catalog.format_type(p.prorettype, null) <> 'jsonb'
       and position(
             'return jsonb_build_object(''ok'', false, ''reason'', ''synthetic_walled'');'
             in pg_get_functiondef(p.oid)) > 0
  loop
    v_new := replace(r.def,
      'return jsonb_build_object(''ok'', false, ''reason'', ''synthetic_walled''); end if;',
      'return null::' || r.rettype
        || '; end if;  -- CMD #2031: walled, typed (was a jsonb object)');

    if v_new = r.def then
      -- the anchor moved: say so in the ledger rather than silently passing.
      if v_ledger then
        insert into public.mode_guard_grandfather(proname, reason)
        values (r.proname,
                'cmd2031: a jsonb wall return sits in a ' || r.rettype
                || ' function and the anchor line no longer matches')
        on conflict (proname) do nothing;
      end if;
      continue;
    end if;

    execute v_new;
    if v_ledger then
      insert into public.mode_guard_path(proname, family, how, note)
      values (r.proname, 'cmd2031', 'guard_call',
              'CMD #2017 outbound wall kept; the early return is now null::'
              || r.rettype || ' so a walled call no longer throws (CMD #2031)')
      on conflict (proname, family)
        do update set how = 'guard_call', note = excluded.note;
    end if;
  end loop;
end $wall$;

-- ─────────── 3 · admin.cart_bill declares its test contract ───────────
-- has_test_contract is a STORED GENERATED column: filling the four fields is
-- what flips it, and what empties rg_contract_gap().
-- The replay also lands this file on the control plane, which carries no
-- feature_registry — so the table is asked for, never assumed (lesson #265).
do $contract$
begin
  if to_regclass('public.feature_registry') is null then return; end if;
  update public.feature_registry f
     set test_entry = '/admin/go/' || f.route_key,
         test_roles = f.roles_allowed,
         test_steps = jsonb_build_array(
           jsonb_build_object('kind', 'auth', 'role', '{role}'),
           jsonb_build_object('kind', 'goto', 'path', '/admin/go/' || f.route_key),
           jsonb_build_object('kind', 'settle', 'ms', 6000)),
         test_expect = jsonb_build_object(
           'kind', 'visible', 'source', 'render_log',
           'key', 'boot_status', 'equals', 'painted'),
         test_contract_at = coalesce(f.test_contract_at, now())
   where f.feature_key = 'admin.cart_bill'
     and f.is_active
     and coalesce(f.route_key, '') <> ''
     and coalesce(cardinality(f.roles_allowed), 0) > 0
     and not f.has_test_contract;
end $contract$;

-- ─────────── 4 · the three fixes, asserted on the database that ran them ──────
do $assert$
declare v_bad int; v_gap int; v_names text;
begin
  if to_regprocedure('public.zone_test_id()') is not null
     and has_function_privilege('anon', 'public.zone_test_id()', 'execute') then
    raise exception 'cmd2031: anon can still execute zone_test_id()';
  end if;

  select count(*) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and pg_catalog.format_type(p.prorettype, null) <> 'jsonb'
     and position(
           'return jsonb_build_object(''ok'', false, ''reason'', ''synthetic_walled'');'
           in pg_get_functiondef(p.oid)) > 0;
  if v_bad > 0 then
    raise exception 'cmd2031: % function(s) still return the jsonb wall object from a non-jsonb signature', v_bad;
  end if;

  -- rg_contract_gap() is production's guard. Absent here means this is not the
  -- database the guard runs on, not that the gate passed. And this migration
  -- asserts the row IT fixed: a build branch carries its own registry rows, and
  -- a gap that belongs to somebody else's feature is not this file's to fail on
  -- (the branch's notif_trail row is how that was learned).
  if to_regprocedure('public.rg_contract_gap()') is null then return; end if;
  select count(*), coalesce(string_agg(feature_key, ', ' order by feature_key), '')
    into v_gap, v_names from public.rg_contract_gap() g
   where g.feature_key = 'admin.cart_bill';
  if v_gap > 0 then
    raise exception 'cmd2031: admin.cart_bill still has no test contract: %', v_names;
  end if;
end $assert$;

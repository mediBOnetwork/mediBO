-- CMD #1984 — the regression guard went red after CHANGE #1357.
--
-- Five CRITICAL behaviours failed and ZERO schema diffs were reported, so
-- nothing here is a schema rebaseline: a behaviour failure is a bug in the
-- code that caused it (rule: behaviour failures and missing_critical are never
-- rebaselined). Each failure traces to a migration replayed on live this
-- morning, and the run-by-run history names which one:
--
--   06:52  green behaviours
--   07:02  replay 20260913140000_c1930_payment_alerts_admin
--   07:17  c1094_staff_rpcs_are_zone_scoped: admin_money_home only
--   07:30  replay 20260914120000_test_mode_read_isolation  (CMD #1964)
--   07:30  replay 20260914070000_c1956_update_gate_versioncode (CMD #1956)
--   07:51  c1094: admin_money_home + 9 mode-scoped RPCs
--          c704_agency_is_a_candidate / c704_agency_chain_is_visible
--          release_version_name_unique
--
--   1. admin_money_home            #1930 added the payment-alert badge to it
--   2. nine mode-scoped RPCs       #1964 rewrote their bodies mechanically
--   3. the two c704 behaviours     #1964 hid their synthetic fixture from them
--   4. release_version_name_unique #1956 shipped a body with no RG_ROLLBACK
--
-- (responsive_no_overflow is not touched here: the post-deploy sweep wrote a
-- green verdict at 07:55:43, four minutes after the 07:51 run read the stale
-- red one — "40 screen/width combinations clean at 320/360/412/480/768px".)
--
-- Idempotent: safe to replay on live, and safe to replay twice.

begin;

-- ═══════════════════════════════════════════════════════════════════════
-- 1. c1094 — admin_money_home is a global money surface, on purpose.
-- ═══════════════════════════════════════════════════════════════════════
--
-- admin_money_home() was grandfathered by zone_scope_baseline: unscoped, but
-- untouched, so it could not block. CMD #1930 added the payment-alerts link
-- and its badge to the body, which is exactly the moment the rule stops
-- grandfathering it ('changed_still_unscoped').
--
-- The fix is NOT a zone clamp. Every one of the four tabs this home opens is
-- global, and a badge that promises work the screen then hides is the bug
-- CHANGE #1094 exists to stop:
--
--   receivables  admin_receivables() counts open orders across every zone —
--                money owed is owed by a CUSTOMER, not by a zone, and chasing
--                it is office work.
--   claims / unmatched  payment_claims has no zone column at all: a forwarded
--                payment arrives before anyone knows which order it belongs
--                to, let alone which zone.
--   bills        pending_bills has no zone column either — supplier bills
--                arrive by email per supplier, the same reason nav_badge_counts
--                left flagged_bills global in CMD #1939.
--
-- So the surface is global on purpose, which is the case zone_scope_allow is
-- for, and the reason is recorded with it — dimension 'both', because a zone
-- it does not have cannot be clamped and a day's ledger is not what money owed
-- is: an unpaid order stays owed until it is paid, not until the date picker
-- moves off the day it was placed.
insert into public.zone_scope_allow (fn_pattern, dimension, reason, added_by)
values ('admin_money_home', 'both',
        'The Money home is an office-wide financial overview and every tab it '
        || 'opens is global: admin_receivables() counts open orders across all '
        || 'zones because money is owed by a customer rather than by a zone, '
        || 'and payment_claims and pending_bills carry no zone column at all — '
        || 'a forwarded payment arrives before anyone knows its order, and a '
        || 'supplier bill arrives by email per supplier. Clamping the badges '
        || 'to admin_active_zone()/admin_active_date() would make them promise '
        || 'work the screens then hide. Recorded in CMD #1984 after CMD #1930 '
        || 'added the payment-alert badge and ended its grandfathering.',
        'cmd-1984')
on conflict (fn_pattern) do update set
  dimension = excluded.dimension,
  reason    = excluded.reason,
  added_by  = excluded.added_by;

-- ═══════════════════════════════════════════════════════════════════════
-- 2. c1094 — a mechanical mode rewrite is not an edit of the function.
-- ═══════════════════════════════════════════════════════════════════════
--
-- CMD #1964 pointed every RPC in mode_scoped_rpc_seed at schema `mode` by
-- de-qualifying `public.<table>` in its body and setting its search_path to
-- 'mode','public'. Nothing else about those functions moved — not a predicate,
-- not a join, not a single line of their own logic — but the body md5 moved,
-- and zone_scope_audit reads the body md5 to decide whether a grandfathered
-- function has been touched. Nine of them were grandfathered, so nine turned
-- 'changed_still_unscoped' at 07:30 without anybody editing anything.
--
-- The proof that the rewrite is all that happened is in the runs themselves:
-- at 07:19 the blocking list was admin_money_home ALONE, at 07:30 the replay
-- landed, and at 07:51 the same nine names arrived together — every one of
-- them a row in mode_scoped_rpc, stamped by that replay.
--
-- So the grandfather is carried forward for exactly those nine, and the
-- carry-forward is made part of mode_scope_rpcs() itself (§2b) so the next
-- re-apply — it is documented as "re-run after any of them is redeployed" —
-- cannot red this guard again.
do $c1984_zs$
declare v_n int := 0; r record;
begin
  if to_regclass('public.zone_scope_baseline') is null
     or to_regclass('public.mode_scoped_rpc') is null then
    raise notice 'CMD #1984: zone_scope_baseline / mode_scoped_rpc absent here — skipping';
    return;
  end if;
  for r in
    select b.fn_name,
           (select md5(regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g'))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = b.fn_name limit 1) as live_md5
      from public.zone_scope_baseline b
     where b.fn_name in ('admin_order_payment_view','delivery_run_map','delivery_scan_qr',
                         'delivery_suggest_partner','fw_get_bag_items','fw_get_state',
                         'fw_issue_qty_rules','fw_search_bag_items','fw_supplier_modes')
       and exists (select 1 from public.mode_scoped_rpc m
                    where m.proname = b.fn_name and m.note is null)
  loop
    if r.live_md5 is null then continue; end if;
    update public.zone_scope_baseline
       set body_md5   = r.live_md5,
           captured_at = now(),
           note = 'CHANGE #1094 grandfather carried forward by CMD #1984: CMD #1964 '
               || 'rewrote this body mechanically (de-qualify public.<table>, '
               || 'search_path mode,public) and changed nothing else about it.'
     where fn_name = r.fn_name and body_md5 is distinct from r.live_md5;
    v_n := v_n + 1;
  end loop;
  raise notice 'CMD #1984: zone_scope grandfather carried forward for % function(s)', v_n;
end $c1984_zs$;

-- ── 2b. the same carry-forward, from now on, inside the rewriter itself ────
-- mode_scope_rpcs() is the documented one-call re-apply. Every time it runs it
-- rewrites bodies, so every time it runs it can end a grandfather it had no
-- opinion about. It now carries the grandfather across its OWN rewrite, and
-- only that: the baseline row is moved forward ONLY when the body it is about
-- to replace still matched the baseline exactly. A body a human had already
-- edited does not match, so the edit still blocks — which is the whole point
-- of the rule.
create or replace function public.mode_scope_rpcs()
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare
  r record; t record; v_new text; n int := 0; v_fail jsonb := '[]'::jsonb; v_tabs text;
  v_old_md5 text; v_was_baseline boolean; v_new_md5 text;
begin
  for r in
    select p.oid, p.proname,
           pg_get_function_identity_arguments(p.oid) as args,
           pg_get_functiondef(p.oid) as src,
           s.surface
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join public.mode_scoped_rpc_seed s on s.proname = p.proname
     where n.nspname = 'public' and p.prokind = 'f'
     order by p.proname
  loop
    v_new  := r.src;
    v_tabs := null;
    for t in select table_name from public.mode_scoped_table order by length(table_name) desc loop
      if v_new ~* ('\ypublic\.' || t.table_name || '\y')
         or v_new ~* ('\y(from|join)\s+' || t.table_name || '\y') then
        v_tabs := coalesce(v_tabs || ',', '') || t.table_name;
      end if;
      v_new := regexp_replace(v_new, '\ypublic\.' || t.table_name || '\y', t.table_name, 'gi');
    end loop;
    if v_tabs is null then
      -- reads nothing scoped (the RPC moved on): leave it exactly as it is
      continue;
    end if;
    -- CMD #1984 — remember whether this body was still the grandfathered one
    -- BEFORE the rewrite touches it.
    v_old_md5 := md5(regexp_replace(r.src, '--[^' || chr(10) || ']*', '', 'g'));
    v_was_baseline := to_regclass('public.zone_scope_baseline') is not null
      and exists (select 1 from public.zone_scope_baseline b
                   where b.fn_name = r.proname and b.body_md5 = v_old_md5);
    begin
      execute v_new;
      execute format('alter function public.%I(%s) set search_path to %L, %L',
                     r.proname, r.args, 'mode', 'public');
      insert into public.mode_scoped_rpc(proname, args, surface, tables, scoped_at)
      values (r.proname, r.args, r.surface, v_tabs, now())
      on conflict (proname, args)
        do update set tables = excluded.tables, surface = excluded.surface,
                      scoped_at = now(), note = null;
      n := n + 1;
      -- CMD #1984 — the rewrite is mechanical, so the grandfather survives it.
      if v_was_baseline then
        select md5(regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g'))
          into v_new_md5
          from pg_proc p join pg_namespace nn on nn.oid = p.pronamespace
         where nn.nspname = 'public' and p.proname = r.proname
           and pg_get_function_identity_arguments(p.oid) = r.args;
        if v_new_md5 is not null and v_new_md5 <> v_old_md5 then
          update public.zone_scope_baseline
             set body_md5 = v_new_md5, captured_at = now(),
                 note = 'CHANGE #1094 grandfather carried across the CMD #1964 '
                     || 'mode rewrite by mode_scope_rpcs() (CMD #1984).'
           where fn_name = r.proname and body_md5 = v_old_md5;
        end if;
      end if;
    exception when others then
      v_fail := v_fail || jsonb_build_object('rpc', r.proname, 'args', r.args, 'error', sqlerrm);
      insert into public.mode_scoped_rpc(proname, args, surface, tables, note)
      values (r.proname, r.args, r.surface, v_tabs, 'not scoped: ' || sqlerrm)
      on conflict (proname, args) do update set note = excluded.note;
    end;
  end loop;
  return jsonb_build_object('ok', jsonb_array_length(v_fail) = 0, 'scoped', n, 'failed', v_fail);
end $fn$;
comment on function public.mode_scope_rpcs() is
  'CMD #1964 — points every RPC in mode_scoped_rpc_seed at schema mode. Re-run after any of them is redeployed. CMD #1984: carries a CHANGE #1094 grandfather across its own mechanical rewrite.';

-- ═══════════════════════════════════════════════════════════════════════
-- 3. c704 — the mode views must honour the bypass the write guard honours.
-- ═══════════════════════════════════════════════════════════════════════
--
-- CMD #1964's own words: "Exempt: a machine caller (no auth.uid — cron, the
-- purge lane, the bot lane), an rg probe, and anything that has deliberately
-- set medibo.mode_bypass." That exemption was written into the WRITE guard
-- (_test_mode_cross_guard) and left out of the READ views, and the regression
-- guard's own fixtures are the first thing that fell through the gap:
--
--   _c704_fixture() builds an is_synthetic order, agency and riders and rolls
--   them back. delivery_suggest_partner and customer_track_order are both in
--   mode_scoped_rpc_seed, so after 07:30 they read mode.orders, whose
--   predicate is is_synthetic = test_mode_on() — false for a cron caller with
--   no session. The fixture's own order became invisible to the RPCs the test
--   was written to prove, and the two tests failed with "kind: none" and
--   "<absent>" respectively.
--
-- So the views learn the same bypass, and _c704_fixture sets it (§3b) —
-- transaction-local, rolled back with the test. Note what is NOT done here:
-- medibo.rg_probe is deliberately NOT a read bypass. test_mode_read_isolation
-- check (g) — "this session has no header, so every mode view must be showing
-- real rows only" — runs under rg_probe and must keep proving exactly that.
create or replace function public._mode_bypass()
returns boolean language sql stable parallel safe security definer set search_path to 'public'
as $fn$
  select coalesce(current_setting('medibo.mode_bypass', true), '') = 'on';
$fn$;
comment on function public._mode_bypass() is
  'CMD #1984 — true when this transaction has deliberately set medibo.mode_bypass=on. The read half of the exemption _test_mode_cross_guard already honours. Read as (select _mode_bypass()) so it is an InitPlan, not a per-row call.';

create or replace function public.mode_views_refresh()
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare
  r record; v_sql text; v_sess boolean; n int := 0; skipped jsonb := '[]'::jsonb;
begin
  execute 'create schema if not exists mode';
  for r in
    select m.table_name
      from public.mode_scoped_table m
     where exists (select 1 from information_schema.columns c
                    where c.table_schema='public' and c.table_name=m.table_name
                      and c.column_name='is_synthetic')
     order by m.table_name
  loop
    v_sess := exists (select 1 from information_schema.columns c
                       where c.table_schema='public' and c.table_name=r.table_name
                         and c.column_name='test_session_id');
    v_sql := format(
      'create or replace view mode.%1$I as select t.* from public.%1$I t '
      'where (select public._mode_bypass()) '
      'or (coalesce(t.is_synthetic,false) = (select public.test_mode_on())%2$s)',
      r.table_name,
      case when v_sess then
        ' and (t.test_session_id is null or t.test_session_id'
        ' = coalesce((select public.test_mode_session()), t.test_session_id))'
      else '' end);
    begin
      execute v_sql;
    exception when others then
      -- a column was added or dropped on the base table since the view was
      -- made: CREATE OR REPLACE cannot reshape a view, so rebuild it.
      begin
        execute format('drop view if exists mode.%I cascade', r.table_name);
        execute v_sql;
      exception when others then
        skipped := skipped || jsonb_build_object('table', r.table_name, 'error', sqlerrm);
        continue;
      end;
    end;
    n := n + 1;
  end loop;
  execute 'grant usage on schema mode to postgres, authenticated, anon, service_role';
  execute 'grant select on all tables in schema mode to postgres, authenticated, anon, service_role';
  return jsonb_build_object('ok', jsonb_array_length(skipped) = 0, 'views', n, 'skipped', skipped);
end $fn$;
comment on function public.mode_views_refresh() is
  'CMD #1964 — rebuilds schema mode from mode_scoped_table. Run after any column change on a scoped table. CMD #1984: the views honour medibo.mode_bypass, the same exemption the write guard has.';

select public.mode_views_refresh();

-- ── 3b. the fixture declares itself ────────────────────────────────────────
-- One line, at the top, before the first synthetic insert: everything this
-- fixture builds and everything the test then reads back is deliberately
-- cross-mode. set_config(..., true) is transaction-local, so it dies with the
-- RG_ROLLBACK that ends every behaviour test.
create or replace function public._c704_fixture()
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_ag uuid; v_r1 uuid; v_r2 uuid; v_solo uuid; v_oid uuid;
        v_pid bigint; v_uid uuid; v_cust uuid; v_ph text;
begin
  -- CMD #1984 — this fixture IS synthetic data, and the test reads it back
  -- through RPCs that CMD #1964 pointed at schema mode. Without the bypass the
  -- mode views hide the fixture from the very functions under test.
  perform set_config('medibo.mode_bypass', 'on', true);

  select id into v_uid from auth.users where email = 'test.sup1@medibo.in' limit 1;
  select id into v_cust from pharmacy_profiles
   where is_synthetic and approved and coalesce(is_deleted,false)=false limit 1;
  select mp.product_id into v_pid from medicine_pricing mp where mp.ptr is not null limit 1;
  -- A phone is a unique login identity (_login_identities_sync), so the
  -- fixture must never reuse one a PERMANENT row already holds — including
  -- the seeded test agency. Four numbers off one random stem, inside a
  -- transaction that is rolled back either way.
  v_ph := '9' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  if v_cust is null or v_pid is null then
    raise exception 'RG_FAIL: no synthetic pharmacy / priced product fixture — CHANGE #704 proofs cannot run';
  end if;

  insert into delivery_partner_registrations(full_name, phone, partner_type, zone_id, is_active,
      status, is_synthetic, user_id, training_override_at, submitted_at)
  values ('C704 Agency', left(v_ph,9)||'0', 'agency', 99, true, 'approved', true, v_uid, now(), now())
  returning id into v_ag;

  insert into delivery_partner_registrations(full_name, phone, partner_type, parent_agency_id,
      zone_id, is_active, status, is_synthetic, max_stops, training_override_at, submitted_at)
  values ('C704 Agency Rider One', left(v_ph,9)||'1', 'boy', v_ag, 99, true, 'approved', true, 5, now(), now())
  returning id into v_r1;

  insert into delivery_partner_registrations(full_name, phone, partner_type, parent_agency_id,
      zone_id, is_active, status, is_synthetic, max_stops, training_override_at, submitted_at)
  values ('C704 Agency Rider Two', left(v_ph,9)||'2', 'boy', v_ag, 99, true, 'approved', true, 5, now(), now())
  returning id into v_r2;

  insert into delivery_partner_registrations(full_name, phone, partner_type, zone_id, is_active,
      status, is_synthetic, max_stops, training_override_at, submitted_at)
  values ('C704 Solo Rider', left(v_ph,9)||'3', 'boy', 99, true, 'approved', true, 5, now(), now())
  returning id into v_solo;

  -- Both agency riders are punched in, so the agency has pooled spare capacity.
  insert into delivery_partner_shifts(partner_id, shift_date, started_at)
  values (v_r1, (now() at time zone 'Asia/Kolkata')::date, now()),
         (v_r2, (now() at time zone 'Asia/Kolkata')::date, now());

  insert into orders(customer_id, order_code, status, dispatch_ready, cust_bill_path,
                     zone_id, is_synthetic, placed_by_admin)
  values (v_cust, 'C704FIXTURE', 'confirmed', true, 'test/bill.pdf', 99, true, true)
  returning id into v_oid;
  insert into order_items(order_id, product_id, product_name, quantity, mrp,
                          assigned_supplier, fulfillment_state, zone_id, bag_no)
  values (v_oid, v_pid, 'C704 fixture line', 1, 10, 'C704 SUPPLIER', 'pending', 99, 1);
  insert into payment_claims(order_id, amount, status) values (v_oid, 100000, 'verified');

  return jsonb_build_object('agency', v_ag, 'rider1', v_r1, 'rider2', v_r2,
                            'solo', v_solo, 'order_id', v_oid, 'agency_user', v_uid);
end $function$;
comment on function public._c704_fixture() is
  'CHANGE #704 proof fixture. CMD #1984: sets medibo.mode_bypass so the CMD #1964 mode views do not hide its own synthetic rows from the RPCs under test.';

-- ═══════════════════════════════════════════════════════════════════════
-- 4. release_version_name_unique — a behaviour test must end in RG_ROLLBACK.
-- ═══════════════════════════════════════════════════════════════════════
--
-- rg_run_behavior() executes the body and then raises RG_NO_MARKER; a body
-- that returns normally is reported as "test body did not raise RG_ROLLBACK"
-- and counts as a CRITICAL failure. CMD #1956 shipped this body without the
-- marker, so it has failed on every run since it existed — the guard was red
-- for a test that was in fact finding nothing wrong.
update public.rg_behavior_tests
   set body = $rgb$
do $vnu$
declare
  v_from int;
  v_dupe text;
begin
  -- Codes 43-46 genuinely shipped to Play as 1.3.25. That is history and is
  -- not rewritten; the guard ratchets from the watermark this change recorded.
  select coalesce((value->>'version_code')::int, 0) into v_from
    from public.app_settings where key = 'c1956_name_unique_from';
  v_from := coalesce(v_from, 0);

  select string_agg(t.line, '; ') into v_dupe from (
    select r.platform || ' ' || r.version_name || ' → codes ' ||
           string_agg(r.version_code::text, ',' order by r.version_code) as line
      from public.app_releases r
     where r.version_code > v_from
       and coalesce(btrim(r.version_name), '') <> ''
     group by r.platform, r.version_name
    having count(*) > 1) t;

  if v_dupe is not null then
    raise exception 'release_version_name_unique: two releases share a version_name — %. One bump function must move versionCode AND versionName together (app_release_next_version).', v_dupe;
  end if;

  -- The bump function itself must never be able to hand back a name in use.
  if exists (select 1 from public.app_releases a
              where a.platform = 'android'
                and a.version_name = (public.app_release_next_version('android', null)->>'version_name')) then
    raise exception 'release_version_name_unique: app_release_next_version() proposed a version_name that is already recorded';
  end if;

  -- CMD #1984 — every behaviour test ends here: rg_run_behavior() reads
  -- RG_ROLLBACK as "the body ran and found nothing", and a body that simply
  -- returns is reported as a failure.
  raise exception 'RG_ROLLBACK';
end $vnu$;
$rgb$
 where name = 'release_version_name_unique'
   and body !~ 'RG_ROLLBACK';

commit;

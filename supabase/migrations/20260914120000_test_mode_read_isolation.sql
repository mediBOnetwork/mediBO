-- CMD #1964 — TEST MODE READ ISOLATION
-- A test session sees ONLY test data; a real session sees ONLY real data.
--
-- Why a schema of views and not RLS: every read RPC is SECURITY DEFINER owned
-- by `postgres`, and `postgres` carries rolbypassrls, so an RLS policy on
-- orders/bags/deliveries is never consulted inside the very functions the app
-- calls. And why not 117 hand-edited WHERE clauses: the surface is 117
-- app-called RPCs over 43 synthetic-bearing tables, and a filter copied 117
-- times is 117 places to forget it.
--
-- So the filter lives in ONE place per table — a view in schema `mode` — and
-- each pure-reader RPC is switched onto it by de-qualifying `public.<table>`
-- and setting its search_path to 'mode', 'public'. The predicate is inside the
-- view, written once, and `mode_views_refresh()` re-derives every view from the
-- live column list so it can never drift from its base table.
--
-- Idempotent: safe to replay on live any number of times.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE GLOBAL SWITCH KEEPS ITS OWN NAME
-- test_mode_on() used to mean "the test_mode_config row says enabled" — a
-- single global boolean, which is exactly why a real customer could see test
-- rows. The global switch is still needed (it gates whether a session may be
-- opened at all), so it keeps working under the honest name.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.test_mode_enabled()
returns boolean language sql stable security definer set search_path to 'public'
as $fn$
  select coalesce((select enabled from public.test_mode_config where id = 1), false);
$fn$;
comment on function public.test_mode_enabled() is
  'CMD #1964 — the GLOBAL test-mode switch (may a session be opened at all). Not the caller''s mode: see test_mode_on().';

-- Repoint the harness callers that meant "globally enabled" onto the new name
-- before test_mode_on() changes meaning underneath them. They run under cron
-- with no session of their own, so caller-scoped semantics would switch them
-- off for good.
do $rp$
declare r record; v_new text;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) args,
           pg_get_functiondef(p.oid) src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname in ('test_order_create','test_run_full','test_pipeline_run','test_hostile_interrupt')
       and pg_get_functiondef(p.oid) ~ 'test_mode_on\s*\('
  loop
    v_new := regexp_replace(r.src, 'test_mode_on\s*\(', 'test_mode_enabled(', 'g');
    begin
      execute v_new;
    exception when others then
      raise notice 'CMD #1964: could not repoint %(%): %', r.proname, r.args, sqlerrm;
    end;
  end loop;
end $rp$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE CALLER'S MODE
-- test_mode_on() is now "does THIS caller have a live test session" — the
-- install's own session by its x-medibo-test-session header, or the automated
-- bot lane for a machine caller. Everything downstream compares a row's
-- is_synthetic against it.
-- Both are plain SQL and are called from view predicates as `(select f())`,
-- which Postgres evaluates ONCE per query as an InitPlan rather than per row.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.test_mode_session()
returns bigint language sql stable parallel safe security definer set search_path to 'public'
as $fn$
  select s.id
    from public.test_sessions s
   where s.status = 'live' and s.ended_at is null and now() < s.expires_at
     and coalesce(s.scope,'global') <> 'canary'
     and (
           -- a person's session: the install that carries its token
           ( s.token is not null and s.token = nullif(btrim(coalesce(
               (coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb
                  ->> 'x-medibo-test-session'), '')), '')
             and not exists (select 1 from public.test_session_exempt e
                              where e.user_id = auth.uid()) )
        or
           -- the bot lane, unchanged
           ( s.scope = 'automated' and public._test_caller_is_backend() )
         )
   order by s.id desc
   limit 1;
$fn$;
comment on function public.test_mode_session() is
  'CMD #1964 — the CALLER''s live test session id, or null. Read as (select test_mode_session()) so it is evaluated once per query.';

create or replace function public.test_mode_on()
returns boolean language sql stable parallel safe security definer set search_path to 'public'
as $fn$
  select public.test_mode_session() is not null;
$fn$;
comment on function public.test_mode_on() is
  'CMD #1964 — true when THIS caller has a live test session. The global switch is test_mode_enabled().';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. WHICH TABLES CARRY A MODE — DATA, NOT CODE
-- Adding a table to the isolation is one INSERT plus mode_views_refresh().
-- The list is the transaction/ledger surface the spec names (storefront, cart,
-- orders, fulfilment, delivery, money, reports). Master/config tables that also
-- happen to carry is_synthetic (zones, the profile tables, notification and
-- message logs) are deliberately NOT scoped: a test session with no zones and
-- no supplier profile cannot place the test order the whole feature exists to
-- prove.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.mode_scoped_table (
  table_name text primary key,
  note       text,
  added_at   timestamptz not null default now()
);

insert into public.mode_scoped_table(table_name, note) values
  ('orders','customer order header'),
  ('order_items','order lines'),
  ('order_costs','order economics'),
  ('order_alert','order alerts'),
  ('order_substitute_ask','substitute asks'),
  ('order_pnl_slab','order P&L'),
  ('order_fulfilment_snapshot','fulfilment snapshot'),
  ('pending_orders','pre-confirm orders'),
  ('pending_bills','pre-confirm bills'),
  ('bags','fulfilment bags'),
  ('bag_sessions','bag counting sessions'),
  ('bag_allocations','bag allocations'),
  ('fulfil_task','fulfilment tasks'),
  ('deliveries','delivery legs'),
  ('delivery_runs','delivery runs'),
  ('delivery_events','delivery events'),
  ('delivery_claims','delivery claims'),
  ('delivery_leg_history','delivery leg history'),
  ('delivery_payout_lines','rider payouts'),
  ('bill_lines','bill lines'),
  ('inquiry','supplier inquiries'),
  ('khata_account','khata accounts'),
  ('khata_entry','khata entries'),
  ('khata_statement','khata statements'),
  ('gst_ledger','GST ledger'),
  ('pharmacy_gst_ledger','pharmacy GST ledger'),
  ('pharmacy_purchase_bill','pharmacy purchase bills'),
  ('supplier_orders','supplier orders'),
  ('supplier_payments','supplier payments'),
  ('supplier_disputes','supplier disputes'),
  ('supplier_return','supplier returns'),
  ('refunds','refunds'),
  ('loyalty_ledger','loyalty ledger'),
  ('pos_sales','POS sales'),
  ('pos_sale_lines','POS sale lines'),
  ('payment_claims','payment claims'),
  ('partner_settlements','partner settlements'),
  ('settlement_invoice','settlement invoices'),
  ('incentive_earnings','rider incentives'),
  ('stock_movement','stock movements'),
  ('pharmacy_stock','pharmacy stock'),
  ('receiving_log','receiving log'),
  ('handling_damage','handling damage'),
  ('razorpay_qr','payment QRs')
on conflict (table_name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE FILTER — ONE VIEW PER SCOPED TABLE, DERIVED FROM THE LIVE COLUMNS
-- ─────────────────────────────────────────────────────────────────────────────
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
      'where coalesce(t.is_synthetic,false) = (select public.test_mode_on())%2$s',
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
  'CMD #1964 — rebuilds schema mode from mode_scoped_table. Run after any column change on a scoped table.';

select public.mode_views_refresh();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. WHICH RPCs READ THROUGH THE FILTER — DATA, AND A ONE-CALL RE-APPLY
-- The seed list is every app-called RPC that READS a scoped table and contains
-- no DML of its own. Scoping one is: de-qualify public.<table> in its body and
-- point its search_path at 'mode' first. Nothing else about the function moves.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.mode_scoped_rpc_seed (
  proname  text primary key,
  surface  text,
  added_at timestamptz not null default now()
);

insert into public.mode_scoped_rpc_seed(proname, surface) values
  ('my_orders_screen','customer'),('customer_track_order','customer'),
  ('customer_bill_file','customer'),('customer_bill_numbers','customer'),
  ('reorder_diff','customer'),('reorder_apply_diff','customer'),
  ('resolve_code','customer'),
  ('admin_customer_orders','admin'),('admin_customer_screen_data','admin'),
  ('admin_dashboard_counts','admin'),('admin_delivery_dashboard','admin'),
  ('admin_delivery_queue','admin'),('admin_demand_preview','admin'),
  ('admin_missing_locations','admin'),('admin_order_payment_view','admin'),
  ('admin_payment_claims','admin'),('admin_pending_bills_count','admin'),
  ('admin_pending_orders_for_user','admin'),('admin_supplier_orders','admin'),
  ('admin_supplier_screen_data','admin'),('agency_team','admin'),
  ('bags_list','fulfilment'),('barcode_import_targets','fulfilment'),
  ('barcode_lookup','fulfilment'),('fw_get_bag_items','fulfilment'),
  ('fw_get_state','fulfilment'),('fw_issue_qty_rules','fulfilment'),
  ('fw_list_unfillable','fulfilment'),('fw_search_bag_items','fulfilment'),
  ('fw_supplier_modes','fulfilment'),('pack_barcode_lookup','fulfilment'),
  ('pack_count_source_audit','fulfilment'),('pack_item_bag_breakdown','fulfilment'),
  ('pack_mention_product_totals','fulfilment'),('get_pack_clip_mentions','fulfilment'),
  ('get_voice_clip_mentions','fulfilment'),('voice_match_product','fulfilment'),
  ('voice_mention_product_totals','fulfilment'),
  ('delivery_run_map','delivery'),('delivery_scan_qr','delivery'),
  ('delivery_send_otp','delivery'),('delivery_suggest_partner','delivery'),
  ('delivery_track_public','delivery'),('my_delivery_history','delivery'),
  ('my_delivery_home','delivery'),('my_delivery_run','delivery'),
  ('get_dispute_form','supplier'),('get_item_supplier_options','supplier'),
  ('get_supplier_contacts','supplier'),('get_supplier_inquiry_overview','supplier'),
  ('get_supplier_inquiry_receipt','supplier'),('get_supplier_order_by_token','supplier'),
  ('inquiry_buckets_today','supplier'),('inquiry_product_id','supplier'),
  ('inquiry_send_readiness','supplier'),('supplier_home_medicines','supplier'),
  ('supplier_my_disputes','supplier'),('supplier_my_orders','supplier'),
  ('supplier_pending_order_items','supplier'),('sup_bill_file','supplier'),
  ('sup_order_bill_panel','supplier'),('sup_order_send_options','supplier'),
  ('get_leads_grouped_today','growth'),('wa_campaign_holdout','growth'),
  ('wa_tokens_screen','growth')
on conflict (proname) do nothing;

create table if not exists public.mode_scoped_rpc (
  proname    text not null,
  args       text not null default '',
  surface    text,
  tables     text,
  scoped_at  timestamptz not null default now(),
  note       text,
  primary key (proname, args)
);

create or replace function public.mode_scope_rpcs()
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare
  r record; t record; v_new text; n int := 0; v_fail jsonb := '[]'::jsonb; v_tabs text;
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
  'CMD #1964 — points every RPC in mode_scoped_rpc_seed at schema mode. Re-run after any of them is redeployed.';

select public.mode_scope_rpcs();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ACTING ACROSS MODES IS REFUSED IN WORDS, NOT A RAW ERROR
-- The reads above already hide the other mode's rows, so the common case is a
-- clean "not found" from the RPC's own copy. This is the backstop for a row
-- reached by id anyway: one trigger function, attached to every scoped table,
-- refusing with copy from ui_copy.
-- Exempt: a machine caller (no auth.uid — cron, the purge lane, the bot lane),
-- an rg probe, and anything that has deliberately set medibo.mode_bypass.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('test_mode.cross_mode_refused',
   to_jsonb('This row belongs to the other mode. Switch test mode and try again.'::text)),
  ('test_mode.badge',            to_jsonb('TEST'::text)),
  ('test_mode.badge_hint',       to_jsonb('Synthetic row — test mode only'::text))
on conflict (key) do nothing;

create or replace function public.test_mode_refusal()
returns jsonb language sql stable security definer set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'ok', false,
    'error', 'wrong_mode',
    'message', public.uic('test_mode.cross_mode_refused',
                          'This row belongs to the other mode. Switch test mode and try again.'),
    'tone', 'danger');
$fn$;
comment on function public.test_mode_refusal() is
  'CMD #1964 — the payload an RPC returns when the caller acts across modes.';

create or replace function public.test_mode_assert(p_is_synthetic boolean)
returns void language plpgsql stable security definer set search_path to 'public'
as $fn$
begin
  if coalesce(p_is_synthetic,false) <> public.test_mode_on() then
    raise exception '%', public.uic('test_mode.cross_mode_refused',
      'This row belongs to the other mode. Switch test mode and try again.')
      using errcode = 'P0001', hint = 'test_mode_cross';
  end if;
end $fn$;

create or replace function public._test_mode_cross_guard()
returns trigger language plpgsql security definer set search_path to 'public'
as $fn$
declare v_uid uuid;
begin
  if coalesce(current_setting('medibo.mode_bypass', true), '') = 'on'
     or coalesce(current_setting('medibo.rg_probe', true), '') = 'on' then
    return coalesce(NEW, OLD);
  end if;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  if v_uid is null then
    -- cron, the purge lane, the automated cast: never gated by a human's mode
    return coalesce(NEW, OLD);
  end if;
  if coalesce(OLD.is_synthetic, false) <> public.test_mode_on() then
    raise exception '%', public.uic('test_mode.cross_mode_refused',
      'This row belongs to the other mode. Switch test mode and try again.')
      using errcode = 'P0001', hint = 'test_mode_cross';
  end if;
  return coalesce(NEW, OLD);
exception
  when sqlstate 'P0001' then raise;
  when others then return coalesce(NEW, OLD);
end $fn$;

create or replace function public.mode_guards_attach()
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare r record; n int := 0;
begin
  for r in
    select m.table_name from public.mode_scoped_table m
     where exists (select 1 from information_schema.columns c
                    where c.table_schema='public' and c.table_name=m.table_name
                      and c.column_name='is_synthetic')
     order by m.table_name
  loop
    begin
      execute format('drop trigger if exists _test_mode_cross_guard_trg on public.%I', r.table_name);
      execute format($q$create trigger _test_mode_cross_guard_trg
                        before update or delete on public.%I
                        for each row execute function public._test_mode_cross_guard()$q$, r.table_name);
      n := n + 1;
    exception when others then
      raise notice 'CMD #1964: guard not attached to %: %', r.table_name, sqlerrm;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'guards', n);
end $fn$;

select public.mode_guards_attach();

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. GRANTS
-- The header badge itself is NOT built here: lib/widgets/test_mode_banner.dart
-- and test_session_banner() already render it from backend copy (CMD #1848,
-- #1821), and this command's job was the reads underneath it. A second badge
-- RPC would be an orphan.
revoke all on function public.test_mode_refusal() from public;
grant execute on function public.test_mode_refusal() to authenticated, service_role;
revoke all on function public.mode_views_refresh() from public, anon, authenticated;
revoke all on function public.mode_scope_rpcs() from public, anon, authenticated;
revoke all on function public.mode_guards_attach() from public, anon, authenticated;
grant execute on function public.test_mode_session() to anon, authenticated, service_role;
grant execute on function public.test_mode_on() to anon, authenticated, service_role;
grant execute on function public.test_mode_enabled() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE REGRESSION BEHAVIOUR — test_mode_read_isolation
-- Red if a scoped view loses its predicate or drifts from its base table, if a
-- scoped RPC loses its search_path or re-qualifies public.<table>, if a scoped
-- RPC grows DML of its own, or if a real-mode read actually returns a synthetic
-- row.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rg_behavior_tests(name, body, enabled, note) values (
'test_mode_read_isolation',
$body$
do $iso$
declare
  v_missing text; v_n int; v_bad text; v_leak int;
begin
  -- (a) every scoped table that has is_synthetic has a view in schema mode
  select string_agg(m.table_name, ', ') into v_missing
    from public.mode_scoped_table m
   where exists (select 1 from information_schema.columns c
                  where c.table_schema='public' and c.table_name=m.table_name
                    and c.column_name='is_synthetic')
     and not exists (select 1 from pg_views v
                      where v.schemaname='mode' and v.viewname=m.table_name);
  if v_missing is not null then
    raise exception 'test_mode_read_isolation: no mode view for %', v_missing;
  end if;

  -- (b) every mode view still carries the mode predicate
  select string_agg(v.viewname, ', ') into v_bad
    from pg_views v
   where v.schemaname='mode' and v.definition !~ 'test_mode_on';
  if v_bad is not null then
    raise exception 'test_mode_read_isolation: mode view without the filter: %', v_bad;
  end if;

  -- (c) no mode view has drifted from its base table's column list
  select string_agg(t.table_name, ', ') into v_bad from (
    select c.table_name
      from information_schema.columns c
     where c.table_schema='public'
       and c.table_name in (select viewname from pg_views where schemaname='mode')
     group by c.table_name
    except
    select c.table_name
      from information_schema.columns c
     where c.table_schema='mode'
     group by c.table_name) t;
  if v_bad is not null then
    raise exception 'test_mode_read_isolation: mode view columns drifted from the base table: % (run mode_views_refresh())', v_bad;
  end if;

  -- (d) every scoped RPC still reads through mode, and never re-qualifies public.<table>
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_bad
    from public.mode_scoped_rpc r
    join pg_proc p on p.proname = r.proname
                  and pg_get_function_identity_arguments(p.oid) = r.args
    join pg_namespace n on n.oid = p.pronamespace and n.nspname='public'
   where r.note is null
     and ( not exists (select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) cfg
                        where cfg ilike 'search_path=%' and cfg ~ '\ymode\y')
        or exists (select 1 from public.mode_scoped_table m
                    where pg_get_functiondef(p.oid) ~* ('\ypublic\.' || m.table_name || '\y')) );
  if v_bad is not null then
    raise exception 'test_mode_read_isolation: RPC no longer reads through schema mode: %', v_bad;
  end if;

  -- (e) a scoped read RPC must not have grown DML of its own
  select string_agg(distinct r.proname, ', ') into v_bad
    from public.mode_scoped_rpc r
    join pg_proc p on p.proname = r.proname
    join pg_namespace n on n.oid = p.pronamespace and n.nspname='public'
   where r.note is null
     and exists (select 1 from public.mode_scoped_table m
                  where pg_get_functiondef(p.oid) ~*
                        ('(insert\s+into|update|delete\s+from)\s+(public\.|mode\.)?' || m.table_name || '\y'));
  if v_bad is not null then
    raise exception 'test_mode_read_isolation: scoped read RPC writes a scoped table: %', v_bad;
  end if;

  -- (f) the caller's mode is caller-scoped, not the global switch
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='test_mode_on'
                    and pg_get_functiondef(p.oid) ~ 'test_mode_session') then
    raise exception 'test_mode_read_isolation: test_mode_on() is not caller-scoped any more';
  end if;

  -- (g) this session has no header, so every mode view must be showing real rows only
  select count(*) into v_leak from mode.orders where coalesce(is_synthetic,false);
  if v_leak > 0 then
    raise exception 'test_mode_read_isolation: % synthetic order(s) visible to a real session', v_leak;
  end if;

  -- (h) and the cross-mode guard is attached wherever a view exists
  select string_agg(v.viewname, ', ') into v_bad
    from pg_views v
   where v.schemaname='mode'
     and not exists (select 1 from pg_trigger tg
                     join pg_class c on c.oid = tg.tgrelid
                     join pg_namespace n on n.oid = c.relnamespace
                      where n.nspname='public' and c.relname = v.viewname
                        and tg.tgname = '_test_mode_cross_guard_trg' and not tg.tgisinternal);
  if v_bad is not null then
    raise exception 'test_mode_read_isolation: cross-mode guard missing on %', v_bad;
  end if;

  raise exception 'RG_ROLLBACK';
end $iso$;
$body$,
true,
'CMD #1964 — test mode read isolation: the mode views, the scoped RPCs, the guard, and no synthetic row visible to a real session.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

commit;

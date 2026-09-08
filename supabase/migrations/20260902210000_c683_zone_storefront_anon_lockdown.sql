-- CHANGE #683 — the default PUBLIC EXECUTE grant, closed on the zone/storefront
-- maintenance surface.
--
-- Bug (filed from #682 QA; PRE-EXISTING, not introduced by #986/#990/#995): the
-- zone and storefront cluster inherits Postgres's default `GRANT EXECUTE TO
-- PUBLIC`, and `anon` is a member of PUBLIC — so every one of them is a public
-- endpoint reachable with the anon key that ships inside lib/supabase_config.dart,
-- the web bundle and the APK. Same class as feature_gaps #25, CHANGE #353, #395,
-- #422 and #436 (cmd #436 built the machinery this migration reuses).
--
-- REPRODUCED live on 2026-09-02 with nothing but the bundled anon key:
--   _sf_category_counts()            -> 200, every catalogue category + its count
--   zone_supplier_names(1)           -> 200, the live supplier roster by name
--   availability_contract_check(f)   -> 200, an internal integrity audit
--   _viewer_zone_or_null()           -> 200
--   zone_counts_are_settling()       -> 200
--
-- And the two the report called unauthenticated WRITES are not: zone_add() and
-- zone_contact_save() both answered 200 but with their own body guard
-- (`get_my_role() <> 'super_admin'` / `role_for_medibo_only() not in
-- ('admin','super_admin')`), so an anon caller gets {"error":"not_authorized"}
-- and nothing is written. The report overstated those two; the finding that
-- stands is the compute surface and the reads.
--
-- What is actually dangerous here, on a 1 GB instance:
--   * zone_full_rebuild, availability_heal_batch, zone_sync_medicine_batch,
--     zone_sync_medicine, zone_sync_company, zone_sync_by_key, zone_resync_drain,
--     zone_backfill_tick, zone_avail_counts_tick, zone_sup_sync_tick,
--     zone_build_company_lookup, zone_build_marketer_keys, zone_readd_responders,
--     storefront_home_warm_tick and every refresh_* job are VOLATILE SECURITY
--     DEFINER with NO body guard. Tokenless, repeatable, unbounded compute — the
--     same slot-starvation shape as the 2026-08-18 outage, but on demand.
--   * zone_supplier_names / _sf_* / storefront_gate leak B2B catalogue and
--     supplier data to a caller with no identity at all.
--
-- This migration fixes the CLASS, not the names, exactly as #436 did:
--   1. nine rpc_anon_rule prefixes — the rule is DATA, so the next hot surface
--      in this cluster is one INSERT and not a deploy,
--   2. rpc_anon_allow rows for the eighteen names that genuinely have a
--      tokenless caller (the public storefront), each with that caller recorded,
--   3. a catalog-driven revoke+grant over every rule-matched function,
--   4. journey bug-683, the permanent linked journey, wired into
--      dev_journey_probe.
--
-- The existing rg behaviour `privileged_rpcs_are_not_anon` (#436) then enforces
-- this forever with no further code: it fails rg_check the moment any function
-- matching a rule is anon-executable, and rg_check red blocks every
-- dev_cmd_complete on this box.
--
-- Trigger functions are revoked alongside the rest and re-granted to
-- authenticated. That is deliberate and safe: EXECUTE on a trigger function is
-- checked at CREATE TRIGGER time, never when the trigger fires, and PostgREST
-- will not expose a function returning trigger — so _zone_set_customer and
-- friends were never callable, and revoking them cannot break a trigger.
--
-- Every statement is idempotent: a resumed worker re-applies this as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE RULE IS DATA.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rpc_anon_rule (prefix, note) values
  ('storefront\_%',      'CHANGE #683 — the storefront surface. The public reads keep anon through rpc_anon_allow; the config write (storefront_save), the warm tick and the WhatsApp AI pair do not.'),
  ('zone\_%',            'CHANGE #683 — the zone surface. Every sync/rebuild/tick job here is unguarded SECURITY DEFINER compute, and zone_supplier_names was returning the supplier roster to the bundled anon key.'),
  ('\_zone\_%',          'CHANGE #683 — zone internals. Helpers and trigger functions; no client has ever called one.'),
  ('\_viewer\_zone\_%',  'CHANGE #683 — the viewer-zone resolver. Read by storefront RPCs as their own definer, never by a client.'),
  ('\_supplier\_zone\_%','CHANGE #683 — supplier-zone internals.'),
  ('refresh\_%',         'CHANGE #683 — every catalogue/zone refresh job. These are cron work: unbounded recompute over MEDICINE (~563k rows) on a 1 GB instance, tokenless.'),
  ('availability\_%',    'CHANGE #683 — availability_heal_batch (a bulk write) and availability_contract_check (an integrity audit that scans on demand).'),
  ('\_sf\_%',            'CHANGE #683 — the storefront feed internals. _sf_category_counts was returning the whole category census to anon.'),
  ('sf\_%',              'CHANGE #683 — storefront formatters. The four pack/label formatters keep anon through rpc_anon_allow.')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE EXCEPTIONS, EACH WITH ITS TOKENLESS CALLER NAMED.
--    A signed-out visitor really does open the storefront, so these must stay
--    reachable with the anon key. Everything here is SECURITY DEFINER (or a
--    pure formatter) and answers with catalogue data the storefront already
--    shows on the page.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rpc_anon_allow (fn_name, reason) values
  ('storefront_page',           'lib/screens/public/storefront_screen.dart — the public grid a signed-out visitor lands on.'),
  ('storefront_search_page',    'the public storefront search box.'),
  ('storefront_product',        'the public product page; c678_anon_sees_everything_available asserts anon sees every sellable product.'),
  ('storefront_home_v2',        'the public home feed.'),
  ('storefront_home_more',      'paging on the public home feed.'),
  ('storefront_company_page',   'the public company page.'),
  ('storefront_labels',         'the storefront copy layer — labels only, no rows.'),
  ('storefront_theme',          'the storefront theme tokens — no rows.'),
  ('storefront_cta',            'the Add-to-cart block every public card renders.'),
  ('storefront_pricing',        'the price block every public card renders (both signatures).'),
  ('storefront_barcode_resolve','lib/widgets/scan_mic_search_controls.dart via storefront_fast_order — scanning on the public storefront.'),
  ('storefront_request_submit', 'lib/screens/public/storefront_screen.dart — the token-gated public request form; the token is the guard.'),
  ('storefront_margin_page',    'lib/data/medicine_repository.dart — a public catalogue browse; the margin itself is withheld by the entitlement layer (storefront_margin_filters returns has:false to anon), which storefront_ptr_entitlement guards.'),
  ('storefront_margin_filters', 'same browse; already returns an empty option list to anon.'),
  ('sf_label',                  'a pure label lookup used by the public storefront.'),
  ('sf_pack_badge',             'a pure formatter — IMMUTABLE, reads nothing.'),
  ('sf_pack_qty_label',         'a pure formatter — IMMUTABLE, reads nothing.'),
  ('sf_pack_type_label',        'a pure formatter — IMMUTABLE, reads nothing.')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE REVOKE, DRIVEN BY THE CATALOG.
--    Nested calls are unaffected: the closed functions are SECURITY DEFINER, so
--    a storefront read still reaches its own helpers as the owner.
-- ─────────────────────────────────────────────────────────────────────────────
do $c683grants$
declare r record; v_closed int := 0; v_kept int := 0;
begin
  for r in
    select 'public.' || quote_ident(p.proname) || '('
           || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and exists (select 1 from public.rpc_anon_rule x where p.proname like x.prefix)
       and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    execute 'revoke execute on function ' || r.sig || ' from public, anon';
    execute 'grant execute on function '  || r.sig || ' to authenticated, service_role';
    v_closed := v_closed + 1;
  end loop;

  -- The allowed ones are granted EXPLICITLY rather than left on the PUBLIC
  -- default, so a future blanket `revoke ... from public` cannot silently close
  -- the storefront to the visitors it exists for.
  for r in
    select 'public.' || quote_ident(p.proname) || '('
           || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and exists (select 1 from public.rpc_anon_rule x where p.proname like x.prefix)
       and exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    execute 'grant execute on function ' || r.sig || ' to anon, authenticated, service_role';
    v_kept := v_kept + 1;
  end loop;

  raise notice 'c683: closed % function(s) to anon, kept % public', v_closed, v_kept;
end
$c683grants$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE PERMANENT JOURNEY.
--    Six assertions. a1 exists because a bool_and over a vanished function is
--    silently true — that is how a security journey stops asserting anything.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._journey_bug683()
returns jsonb language plpgsql security definer set search_path to 'public'
as $c683journey$
declare
  v_total int; v_open int; v_no_auth int; v_allow_blank int; v_public_missing int;
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
  v_ok boolean;
  c_public constant text[] := array['storefront_page','storefront_product',
                                    'storefront_search_page','storefront_home_v2'];
  c_closed constant text[] := array['zone_full_rebuild','availability_heal_batch',
                                    'zone_sync_medicine_batch','refresh_storefront_feed',
                                    'refresh_medicine_count_cache','zone_supplier_names',
                                    'zone_add','zone_contact_save','storefront_save',
                                    '_sf_category_counts'];
begin
  -- a1: the cluster still EXISTS. Guards against a vacuous pass.
  select count(*) into v_total
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix
                   and r.prefix in ('storefront\_%','zone\_%','\_zone\_%','\_viewer\_zone\_%',
                                    '\_supplier\_zone\_%','refresh\_%','availability\_%',
                                    '\_sf\_%','sf\_%'));
  v_a1 := v_total >= 70;

  -- a2: not one of them is reachable with the key that ships in the bundle.
  select count(*) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_open = 0;

  -- a3: the ten this bug named by hand — the rebuild, the heal, the batch sync,
  --     two refresh jobs, the supplier roster, the two zone writes, the
  --     storefront config write and the feed helper that leaked the census.
  select count(*) = 0 into v_a3
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proname = any (c_closed)
     and has_function_privilege('anon', p.oid, 'execute');

  -- a4: and the storefront a signed-out visitor came for still opens. A
  --     lockdown that closes the shop is a bug, not a fix.
  select count(*) into v_public_missing
    from unnest(c_public) as t(fn)
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = t.fn
        and has_function_privilege('anon', p.oid, 'execute'));
  v_a4 := v_public_missing = 0;

  -- a5: the revoke did not lock the signed-in app out of its own RPCs.
  select count(*) into v_no_auth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not has_function_privilege('authenticated', p.oid, 'execute');
  v_a5 := v_no_auth = 0;

  -- a6: every exception names the caller that earns it. An allow row with an
  --     empty reason is how this class comes back wearing a permit.
  select count(*) into v_allow_blank
    from public.rpc_anon_allow a where btrim(coalesce(a.reason,'')) = '';
  v_a6 := v_allow_blank = 0;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4 and v_a5 and v_a6;
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'zone/storefront RPCs present='||v_total::text||' (>=70)='||v_a1::text||
      ' | anon EXECUTE holes='||v_open::text||' -> none='||v_a2::text||
      ' | the 10 named jobs/reads denied to anon='||v_a3::text||
      ' | the public storefront still open to anon='||v_a4::text||
      ' | authenticated still holds EXECUTE everywhere='||v_a5::text||
      ' | every allow row states its caller='||v_a6::text));
end
$c683journey$;

-- Wire it into the probe without restating the probe: patch the dispatch table
-- in place, guarded so a re-run is a no-op.
do $c683wire$
declare v_src text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';

  if v_src is null or position('_journey_bug683' in v_src) > 0 then
    return;
  end if;

  v_src := replace(v_src,
    '  if p_name = ''bug-436'' then return public._journey_bug436(); end if;',
    '  if p_name = ''bug-436'' then return public._journey_bug436(); end if;' || E'\n' ||
    '  -- CHANGE #683 — the same default-PUBLIC-grant class on the zone and' || E'\n' ||
    '  -- storefront maintenance surface: unguarded refresh/rebuild jobs are' || E'\n' ||
    '  -- tokenless compute on a 1 GB instance, and zone_supplier_names was' || E'\n' ||
    '  -- handing the supplier roster to the bundled anon key.' || E'\n' ||
    '  if p_name = ''bug-683'' then return public._journey_bug683(); end if;');

  if position('_journey_bug683' in v_src) = 0 then
    raise exception 'c683: could not find the bug-436 dispatch line in dev_journey_probe — wire bug-683 by hand rather than shipping an unwired journey';
  end if;

  execute 'create or replace function public.dev_journey_probe(p_name text) '
       || 'returns jsonb language plpgsql security definer set search_path to ''public'' '
       || 'as $c683probe$' || v_src || '$c683probe$';
end
$c683wire$;

-- The journey row was auto-created empty when the bug was filed. Give it the
-- assertions it is going to be judged on.
update public.dev_journeys
   set area = 'security',
       kind = 'api',
       assertions = jsonb_build_array(
         'the zone/storefront cluster still exists (>=70 functions match the rules)',
         'anon holds EXECUTE on none of them except the recorded public storefront reads',
         'the ten named jobs and reads are denied to anon by name',
         'a signed-out visitor can still open storefront_page/product/search/home',
         'authenticated holds EXECUTE on every rule-matched function',
         'every rpc_anon_allow row states the tokenless caller that earns it'),
       enabled = true
 where name = 'bug-683';

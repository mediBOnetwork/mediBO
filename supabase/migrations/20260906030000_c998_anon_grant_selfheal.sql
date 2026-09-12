-- replay-target: production
-- CMD #998 — the anon-grant guards SELF-HEAL instead of being remembered.
--
-- WHY THIS FILE EXISTS. Three journeys that the finish gate marks REQUIRED for
-- the supplier area — bug-436, qa-395-183, qa-706-473 — assert that the anon
-- key shipped inside the web bundle and the APK cannot EXECUTE an admin, pack,
-- returns/refunds or KYC RPC. All three are green on production and all three
-- are RED on every build branch, which blocks completion for reasons that have
-- nothing to do with the command being built.
--
-- The cause is the one #1094/#1160 already wrote down: every SECURITY DEFINER
-- function inherits Postgres's default GRANT TO PUBLIC, and each of these
-- lockdowns was applied ONCE — by a migration that runs early (#447), or by
-- hand on production (#1160). A build branch is a schema restore that then
-- replays the migration files, so every later `create or replace function`
-- hands PUBLIC back and nothing runs afterwards to take it away. Measured on
-- branch pavaxgskqxnoyutwumvh at the time of writing: 249 of 249 admin_*/pack_*
-- functions were anon-executable, rpc_anon_rule and rpc_anon_allow were EMPTY
-- (0 and 0 against production's 11 and 18), and all five privileged KYC RPCs
-- were open to anon AND authenticated.
--
-- So the lockdown stops being a line somebody has to remember and becomes the
-- LAST migration: it re-seeds the two rule tables, then re-runs the sweep and
-- the two hand-listed lockdowns. Idempotent by construction — a REVOKE of a
-- grant that is gone and a GRANT of one already held are both no-ops, and every
-- loop reads the live catalog rather than naming a function, so it cannot fail
-- on a database where one of them does not exist yet. Verified against
-- production before writing: rule-matched anon holes 0, returns anon holes 0,
-- unguarded-helper authenticated holes 0, KYC anon/authenticated holes 0 — this
-- file changes NOTHING there and repairs every branch.
--
-- This is the outer lock only. Every one of these functions keeps its own
-- body-level role check (is_admin() / get_my_role() / _returns_guard()), and
-- #436 exists precisely because one had only the outer lock. Never read this
-- file as a substitute for that.

-- ── 1. the rule tables the sweep is driven by ────────────────────────────────
-- Both are tiny lookup tables, and a branch restore is exactly where a tiny
-- lookup table goes missing (the same class as ui_icon/staff_nav_tab in #1016).
-- Seeded as upserts so production keeps its own notes.
create table if not exists public.rpc_anon_rule(
  prefix text primary key, note text, created_at timestamptz not null default now());
create table if not exists public.rpc_anon_allow(
  fn_name text primary key, reason text, created_at timestamptz not null default now());

insert into public.rpc_anon_rule(prefix, note) values
  ('\_sf\_%',            'CHANGE #683 - the storefront feed internals.'),
  ('\_supplier\_zone\_%','CHANGE #683 - supplier-zone internals.'),
  ('\_viewer\_zone\_%',  'CHANGE #683 - the viewer-zone resolver; read by storefront RPCs as their own definer, never by a client.'),
  ('\_zone\_%',          'CHANGE #683 - zone internals; helpers and trigger functions.'),
  ('admin\_%',           'CHANGE #436 - every admin screen RPC. An anonymous caller has no admin identity to ask about.'),
  ('availability\_%',    'CHANGE #683 - a bulk write and an on-demand integrity audit.'),
  ('pack\_%',            'CHANGE #436 - the warehouse packing surface.'),
  ('refresh\_%',         'CHANGE #683 - catalogue/zone refresh jobs; unbounded recompute over MEDICINE on a 1 GB instance.'),
  ('sf\_%',              'CHANGE #683 - storefront formatters; the four public ones keep anon through rpc_anon_allow.'),
  ('storefront\_%',      'CHANGE #683 - the storefront surface; the public reads keep anon through rpc_anon_allow.'),
  ('zone\_%',            'CHANGE #683 - the zone surface; sync/rebuild/tick jobs.')
on conflict (prefix) do nothing;

insert into public.rpc_anon_allow(fn_name, reason) values
  ('sf_label',                     'a pure label lookup used by the public storefront.'),
  ('sf_pack_badge',                'a pure formatter - IMMUTABLE, reads nothing.'),
  ('sf_pack_qty_label',            'a pure formatter - IMMUTABLE, reads nothing.'),
  ('sf_pack_type_label',           'a pure formatter - IMMUTABLE, reads nothing.'),
  ('storefront_barcode_resolve',   'scanning on the public storefront.'),
  ('storefront_company_page',      'the public company page.'),
  ('storefront_cta',               'the Add-to-cart block every public card renders.'),
  ('storefront_home_more',         'paging on the public home feed.'),
  ('storefront_home_v2',           'the public home feed.'),
  ('storefront_labels',            'the storefront copy layer - labels only, no rows.'),
  ('storefront_margin_filters',    'same browse; already returns an empty option list to anon.'),
  ('storefront_margin_page',       'a public catalogue browse; the margin itself is withheld by the entitlement layer.'),
  ('storefront_page',              'the public grid a signed-out visitor lands on.'),
  ('storefront_pricing',           'the price block every public card renders (both signatures).'),
  ('storefront_product',           'the public product page.'),
  ('storefront_request_submit',    'the token-gated public request form; the token is the guard.'),
  ('storefront_search_page',       'the public storefront search box.'),
  ('storefront_theme',             'the storefront theme tokens - no rows.')
on conflict (fn_name) do nothing;

-- ── 2. the #447 sweep, re-run as the LAST word ───────────────────────────────
do $$
declare f record; n int := 0;
begin
  for f in
    select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public' and p.prokind = 'f'
       and exists (select 1 from public.rpc_anon_rule  r where p.proname like r.prefix)
       and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    execute format('revoke execute on function public.%s from public, anon', f.sig);
    execute format('grant  execute on function public.%s to authenticated, service_role', f.sig);
    n := n + 1;
  end loop;
  raise notice 'c998: anon-grant sweep locked % privileged RPC(s)', n;
end $$;

-- ── 3. the KYC five (qa-706-473) ─────────────────────────────────────────────
-- These are the OCR pipeline and the verification write. They are cron/service
-- work: no client role has any business holding EXECUTE, which is why this pair
-- of roles is revoked and not just anon. The two doc_id READERS
-- (kyc_verify_panel / kyc_verify_evaluate) deliberately stay open to a signed-in
-- user and are scoped in their own bodies by kyc_verify_scope_ok(uuid) instead.
do $$
declare f record; n int := 0;
begin
  for f in
    select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and (p.proname like 'kyc\_ocr\_%'
            or p.proname in ('kyc_verify_doc','kyc_identity_claim_set'))
  loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f.sig);
    execute format('grant  execute on function public.%s to service_role', f.sig);
    n := n + 1;
  end loop;
  raise notice 'c998: KYC lockdown closed % RPC(s)', n;
end $$;

-- ── 4. the returns / refunds / cancellation surface (qa-395-183) ─────────────
-- _order_cancel_core is deliberately UNGUARDED so the token-based order-alert
-- path can reach it as its own definer. anon EXECUTE on it means the key in the
-- web bundle can cancel ANY order, release its stock, open supplier inquiry
-- lines and fire an automatic refund. The eleven helpers below are the same
-- shape; only the RPCs that call _returns_guard() themselves may keep
-- authenticated.
do $$
declare f record; n int := 0; m int := 0;
begin
  for f in
    select p.proname,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel')
  loop
    execute format('revoke execute on function public.%s from public, anon', f.sig);
    execute format('grant  execute on function public.%s to service_role', f.sig);
    n := n + 1;
    if f.proname in ('_order_cancel_core','_return_line_money','_return_returnable_qty',
                     '_order_collected','_order_refunded','_order_paid_net',
                     '_order_rzp_payment_id','_rzp_refund_apply',
                     'gst_ledger_build_credit_notes','refund_prepare','refund_store') then
      execute format('revoke execute on function public.%s from authenticated', f.sig);
      m := m + 1;
    else
      execute format('grant execute on function public.%s to authenticated', f.sig);
    end if;
  end loop;
  raise notice 'c998: returns/refunds lockdown closed % RPC(s), % of them to authenticated too', n, m;
end $$;

-- ── 5. and the money ledgers themselves ──────────────────────────────────────
-- RLS is the second lock on a money ledger, never the only one.
do $$
declare t text;
begin
  foreach t in array array['order_returns','refunds','order_cancellations'] loop
    if to_regclass('public.' || t) is not null then
      execute format('revoke insert, update, delete on table public.%I from public, anon', t);
    end if;
  end loop;
end $$;

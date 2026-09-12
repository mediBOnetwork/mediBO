-- CHANGE #745 — the two hostile-QA blockers, turned into journeys that can be
-- re-run by any future command instead of re-tested by hand.
--
-- Round 1 filed two blockers against the payload-driven customer menu:
--   qa-745-425  Logout vanished for a signed-in account with no pharmacy row.
--   qa-745-426  One failed RPC emptied the whole Account group, with no retry.
-- Both were fixed, and both were left as journeys whose only step read
-- "TODO implement before completing #745". A journey that asserts nothing
-- retires nothing, so this migration gives each one its real steps, its real
-- assertions, and a proof function the runner actually executes.
--
-- The backend half lives here. The client half is pinned by
-- test/protected/customer_menu_placement_test.dart, which runs before every
-- deploy — the two halves together are what the journey reports.
--
-- Idempotent: create or replace, and updates keyed on the journey name.

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof. Read-only: it reads the registry, reads the RPC's own source, and
-- calls customer_surfaces() under a borrowed session, restoring the caller's
-- claims before it returns.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.c745_customer_menu_proof()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $fn$
declare
  v_saved   text := current_setting('request.jwt.claims', true);
  v_src     text;
  v_uid     uuid;
  v_subject text := 'none';
  v_owner   text := 'none';
  v_menu    jsonb;
  v_logout  int;
  v_rows    int;
  v_note    text;
  -- qa-745-425
  v_425_registry  boolean := false;   -- the registry exempts Logout from the account gate
  v_425_gate      boolean := false;   -- the RPC honours that exemption
  v_425_predicate boolean := false;   -- the same predicate, evaluated with no account
  v_425_live      text    := 'no_subject';
  -- qa-745-426
  v_426_note      boolean := false;   -- the staleness sentence is ui_copy, not Dart
  v_426_never_bad boolean := false;   -- the RPC has no ok:false path to cache
  v_426_live      text    := 'no_subject';
  v_426_carries   boolean := false;   -- a real account's payload carries the note
  r record;
begin
  select p.prosrc into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_surfaces';

  -- ── qa-745-425 ────────────────────────────────────────────────────────────
  -- The registry, not a Dart branch, is what makes Logout unconditional.
  select exists (
    select 1
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     where cp.placement = 'profile_account'
       and cp.feature_key = 'cust.logout'
       and cp.is_active and f.is_active
       and cp.needs_account = false
       and 'customer' = any (f.roles_allowed))
    into v_425_registry;

  -- The RPC still carries the account gate that lets an account-free entry
  -- through. Deleting it is how the blocker comes back.
  v_425_gate := coalesce(v_src, '') like '%v_has or not cp.needs_account%';

  -- The gate's own predicate, evaluated as it is for a caller with no pharmacy
  -- row (v_has = false). Logout must survive it; the rows that need an account
  -- must not.
  select count(*) filter (where cp.feature_key = 'cust.logout'),
         count(*)
    into v_logout, v_rows
    from public.customer_feature_placement cp
    join public.feature_registry f on f.feature_key = cp.feature_key
   where cp.placement = 'profile_account'
     and cp.is_active and f.is_active
     and 'customer' = any (f.roles_allowed)
     and (false or not cp.needs_account);
  v_425_predicate := (v_logout = 1);

  -- And the live answer: borrow a real signed-in account that has no pharmacy
  -- row and ask the real RPC for its profile menu.
  for r in
    select u.id
      from auth.users u
     where not exists (select 1 from public.pharmacy_profiles p where p.user_id = u.id)
       and not exists (select 1 from public.admins a
                        where lower(btrim(a.email)) = lower(btrim(u.email)))
     limit 25
  loop
    perform set_config('request.jwt.claims',
             json_build_object('sub', r.id, 'role', 'authenticated')::text, true);
    if public.get_my_role() = 'customer' and public.my_customer_id() is null then
      v_uid := r.id; exit;
    end if;
  end loop;

  if v_uid is not null then
    v_subject := 'signed-in customer, no pharmacy row';
    perform set_config('request.jwt.claims',
             json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    v_menu := public.customer_surfaces();
    v_425_live := case
      when coalesce((v_menu->>'ok')::boolean, false)
       and coalesce((v_menu->>'has_account')::boolean, true) = false
       and exists (select 1
                     from jsonb_array_elements(v_menu->'placements'->'profile_account') e
                    where e->>'feature_key' = 'cust.logout')
      then 'passed' else 'FAILED' end;
  end if;

  -- ── qa-745-426 ────────────────────────────────────────────────────────────
  -- The customer is told what they are looking at in the BACKEND's sentence.
  v_note := public._c('cust_menu.offline_note');
  v_426_note := coalesce(btrim(v_note), '') <> '';

  -- customer_surfaces() has no ok:false answer at all — absence is explicit
  -- (has_account:false), so there is no bad payload for the device to cache.
  v_426_never_bad := coalesce(v_src, '') not like '%''ok'', false%';

  -- A real pharmacy's payload: the Account group is non-empty AND it carries
  -- the staleness sentence, so a cached repaint can say so without Dart words.
  select p.user_id into v_uid
    from public.pharmacy_profiles p
    join auth.users u on u.id = p.user_id
   limit 1;
  if v_uid is not null then
    v_owner := 'signed-in pharmacy account';
    perform set_config('request.jwt.claims',
             json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    v_menu := public.customer_surfaces();
    v_426_carries := coalesce(btrim(v_menu->>'offline_note'), '') = coalesce(btrim(v_note), '')
                 and coalesce(btrim(v_menu->>'offline_note'), '') <> '';
    v_426_live := case
      when coalesce((v_menu->>'ok')::boolean, false)
       and jsonb_array_length(coalesce(v_menu->'placements'->'profile_account','[]'::jsonb)) > 0
       and v_426_carries
      then 'passed' else 'FAILED' end;
  end if;

  -- Hand the session back exactly as it was found.
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);

  return jsonb_build_object(
    'ok', v_425_registry and v_425_gate and v_425_predicate
          and v_425_live <> 'FAILED'
          and v_426_note and v_426_never_bad and v_426_live <> 'FAILED',
    'at', now(),
    'qa-745-425', jsonb_build_object(
      'ok', v_425_registry and v_425_gate and v_425_predicate and v_425_live <> 'FAILED',
      'subject', v_subject,
      'registry_exempts_logout', v_425_registry,
      'rpc_honours_the_exemption', v_425_gate,
      'predicate_without_an_account_keeps_logout', v_425_predicate,
      'account_free_rows', v_rows,
      'live_rpc', v_425_live),
    'qa-745-426', jsonb_build_object(
      'ok', v_426_note and v_426_never_bad and v_426_live <> 'FAILED',
      'subject', v_owner,
      'staleness_sentence_is_ui_copy', v_426_note,
      'offline_note', coalesce(v_note, ''),
      'rpc_has_no_ok_false_answer', v_426_never_bad,
      'payload_carries_the_sentence', v_426_carries,
      'live_rpc', v_426_live));
end
$fn$;

revoke all on function public.c745_customer_menu_proof() from public;
revoke all on function public.c745_customer_menu_proof() from anon, authenticated;
grant execute on function public.c745_customer_menu_proof() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- The journeys themselves — real steps, real assertions, right area.
-- ─────────────────────────────────────────────────────────────────────────────
update public.dev_journeys set
  area = 'storefront',
  kind = 'api',
  steps = to_jsonb(array[
    'A signed-in account with NO pharmacy row asks customer_surfaces() for its profile menu.',
    'The Account group it gets back must still contain cust.logout — the registry exempts it from the account gate (needs_account=false) and the RPC honours that exemption.',
    'The rows that DO need an account stay out, so the exemption is a gate and not a hole.',
    'ProfileAccountMenu offers Logout even when the payload describes none, and never offers it twice when the payload does.'
  ]),
  assertions = to_jsonb(array[
    'c745_customer_menu_proof()->''qa-745-425''->>''ok'' = true',
    'cust.logout is an active profile_account placement with needs_account=false for role customer',
    'customer_surfaces() source still carries the (v_has or not cp.needs_account) gate',
    'test/protected/customer_menu_placement_test.dart group "a signed-in account can ALWAYS sign out" is green'
  ])
where name = 'qa-745-425';

update public.dev_journeys set
  area = 'storefront',
  kind = 'api',
  steps = to_jsonb(array[
    'customer_surfaces() fails or times out on a shop''s flaky connection.',
    'The last good menu is repainted from the device cache BEFORE the network is asked, so the Account group is never blank.',
    'A bad answer (not a map, or ok<>true, or a thrown RPC) is discarded before the notifier is written — it never replaces a good one, and never clears the cache.',
    'The customer is told they are looking at a saved menu, in the backend''s own sentence (ui_copy cust_menu.offline_note) — and no sentence is invented when the payload sent none.'
  ]),
  assertions = to_jsonb(array[
    'c745_customer_menu_proof()->''qa-745-426''->>''ok'' = true',
    'ui_copy cust_menu.offline_note is non-empty and is what the payload carries',
    'customer_surfaces() has no ok:false answer for a signed-in account — absence is has_account:false',
    'test/protected/customer_menu_placement_test.dart group "a failed refresh never empties the Account group" is green'
  ])
where name = 'qa-745-426';


-- ─────────────────────────────────────────────────────────────────────────────
-- The two probes the runner actually executes. Each one re-reads the shared
-- proof and adds the assertion that belongs to its own blocker, so a green
-- run is a statement about the registry and the RPC — not about a screenshot.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._journey_c745_logout_always()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_p     jsonb := public.c745_customer_menu_proof() -> 'qa-745-425';
  v_free  int;
  v_gated int;
  v_ok    boolean;
begin
  -- The exemption is a gate, not a hole: exactly ONE account-free row on the
  -- profile surface (Logout), and the rows that need an account still do.
  select count(*) filter (where not cp.needs_account),
         count(*) filter (where cp.needs_account)
    into v_free, v_gated
    from public.customer_feature_placement cp
    join public.feature_registry f on f.feature_key = cp.feature_key
   where cp.placement = 'profile_account'
     and cp.is_active and f.is_active
     and 'customer' = any (f.roles_allowed);

  v_ok := coalesce((v_p->>'ok')::boolean, false)
      and v_free = 1
      and v_gated > 0;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'registry exempts Logout=' || coalesce(v_p->>'registry_exempts_logout','?') ||
      ' | RPC honours the exemption=' || coalesce(v_p->>'rpc_honours_the_exemption','?') ||
      ' | predicate with no account keeps Logout=' ||
        coalesce(v_p->>'predicate_without_an_account_keeps_logout','?') ||
      ' | account-free profile rows=' || v_free::text || ' (must be 1: cust.logout)' ||
      ' | rows still gated on an account=' || v_gated::text ||
      ' | live customer_surfaces() for ' || coalesce(v_p->>'subject','no subject') ||
        '=' || coalesce(v_p->>'live_rpc','?')));
end $fn$;

create or replace function public._journey_c745_offline_menu()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_p       jsonb := public.c745_customer_menu_proof() -> 'qa-745-426';
  v_src     text;
  v_by_key  boolean;
  v_literal boolean;
  v_ok      boolean;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_surfaces';

  -- The staleness sentence is looked up by KEY. Inlining the words here would
  -- move the copy out of ui_copy and back into a deploy.
  v_by_key  := coalesce(v_src, '') like '%cust_menu.offline_note%';
  v_literal := coalesce(v_src, '') ilike '%last saved menu%';

  v_ok := coalesce((v_p->>'ok')::boolean, false)
      and v_by_key
      and not v_literal;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'ui_copy cust_menu.offline_note=' || coalesce(nullif(v_p->>'offline_note',''), '<empty>') ||
      ' | payload carries that sentence=' || coalesce(v_p->>'payload_carries_the_sentence','?') ||
      ' | RPC looks the sentence up by ui_copy key=' || v_by_key::text ||
      ' | RPC hardcodes the sentence=' || v_literal::text || ' (must be false)' ||
      ' | RPC has no ok:false answer=' || coalesce(v_p->>'rpc_has_no_ok_false_answer','?') ||
      ' | live customer_surfaces() for ' || coalesce(v_p->>'subject','no subject') ||
        '=' || coalesce(v_p->>'live_rpc','?')));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Route the two names at the probe.
--
-- dev_journey_probe is 35 KB and every command that files a journey adds two
-- lines to it, so five runners re-emitting the whole body is the god-file
-- contention of CHANGE #327 in a single function: whoever replays last silently
-- deletes everyone else's routing. This patches only the dispatch, keyed on the
-- guard call that every version of the function opens with, and does nothing at
-- all once the routing is present — so it is safe to replay, and safe to land
-- beside another command that is editing the same body for its own journey.
--
-- Without it the two names fall through to the external-proof branch at the
-- bottom and report "skipped — browser runner needs 2 more run(s)" forever: no
-- browser can prove a statement about a registry row or an RPC's own source.
-- ─────────────────────────────────────────────────────────────────────────────
do $patch$
declare
  v_src text;
  v_anchor constant text := 'perform public._dev_guard();';
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';

  if v_src is null then
    raise notice 'c745: dev_journey_probe absent — routing skipped';
    return;
  end if;
  if position('_journey_c745_logout_always' in v_src) > 0 then
    return;                                   -- already routed; nothing to do
  end if;
  if position(v_anchor in v_src) = 0 then
    raise exception 'c745: dev_journey_probe no longer opens with %, refusing to guess', v_anchor;
  end if;

  v_src := replace(v_src, v_anchor, v_anchor || E'\n'
    || '  if p_name = ''qa-745-425'' then return public._journey_c745_logout_always(); end if;' || E'\n'
    || '  if p_name = ''qa-745-426'' then return public._journey_c745_offline_menu();  end if;');

  execute format(
    'create or replace function public.dev_journey_probe(p_name text) returns jsonb '
    'language plpgsql security definer set search_path to ''public'' as %L', v_src);
end $patch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- And close the grant class these two were about to join (bug-436 / bug-683).
--
-- A journey helper is an internal probe: dev_journey_probe calls it as the
-- definer, and nothing in lib/ or supabase/functions/ calls it at all. They
-- were nevertheless created with PostgreSQL's default PUBLIC EXECUTE, so anon
-- could run a SECURITY DEFINER function that borrows a real signed-in session.
-- Fixed for the family rather than for the two rows this command added.
-- ─────────────────────────────────────────────────────────────────────────────
do $lockdown$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like '\_journey\_%'
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $lockdown$;

-- CMD #1857 — THE REGRESSION GUARD WENT RED: NINE BEHAVIOURS, ONE MISSING nullif
--
-- rg run 11172 (2026-09-07 08:08 UTC) reported 109 diffs and 10 critical
-- signals. The 109 diffs are CHANGE #1228 doing exactly what it said: #1850
-- added test_clock_at to all 53 tables in _test_session_tables(), plus the
-- clock/recording tables, their indexes, their policies and their RPCs. Those
-- are intentional and are rebaselined.
--
-- The nine BEHAVIOUR failures are not. Every one of them died with the same
-- five words — "invalid input syntax for type json" — and every one of them
-- died inside audit_row_trg() -> audit_actor() on the first INSERT into an
-- audited table:
--
--   c472_refund_request_fired_twice      c704_agency_timeout_falls_back
--   c472_settlement_payment_fired_twice  c704_wave_can_pick_an_agency
--   c704_agency_assign_dispatch_deliver  c712_customer_events_fire_once
--   c704_agency_chain_is_visible         order_closure_customer
--   c704_agency_is_a_candidate
--
-- THE CAUSE. A custom GUC that has never been touched reads back as NULL, and
-- NULL::jsonb is NULL — harmless. But the moment ANYTHING sets it, even
-- transaction-locally and even in a transaction that then rolls back, the
-- placeholder exists for the rest of that SESSION and reverts to its default,
-- which is the EMPTY STRING. And ''::jsonb is not NULL, it is an error:
--
--   select current_setting('request.headers', true) is null;   -- t
--   begin; select set_config('request.headers','{"a":1}',true); rollback;
--   select current_setting('request.headers', true) is null;   -- f  (it is '')
--   select public.audit_actor();  -- ERROR: invalid input syntax for type json
--
-- rg_run_behaviors() runs all 80 behaviours down one session in name order.
-- CHANGE #1228 added the first two behaviours that ever set request.headers —
-- c1850_clock_is_one_sessions_own and c1850_clock_unpinned_is_identical, which
-- sort eighth and ninth. From the tenth behaviour onward the header GUC was ''
-- , so every later behaviour that wrote an audited row hit the unguarded cast
-- in audit_actor(). That is the whole of the red: the ordering made a latent
-- bug reachable, it is not a fault in #1228.
--
-- This is NOT a test-only problem. _recording_replay_plan() (CHANGE #1851,
-- live since 07:59 today) sets request.headers transaction-locally on a real
-- PostgREST connection. From then until that pooled connection is recycled,
-- request.headers reads '' and EVERY audited INSERT/UPDATE on it would throw.
-- The guard found a production landmine, which is what it is for.
--
-- THE FIX. Guard the cast, the way auth.uid(), auth.jwt(), auth.role() and
-- auth.email() have always guarded theirs: nullif(current_setting(...), '').
-- audit_actor() is replaced explicitly below because it is the one that fired.
-- The sweep after it closes the same hole in the three other functions that
-- carry an unguarded cast of a request.* GUC — and those read
-- request.jwt.claims, which rg_run_behavior() itself sets to '' after every
-- single behaviour, so they were one call away from the identical crash.
--
-- Idempotent: CREATE OR REPLACE, and a sweep that finds nothing to do on a
-- second run. It asserts at the end, so a replay that half-worked fails loudly.

begin;

-- ---------------------------------------------------------------------------
-- 1. THE ONE THAT FIRED
-- ---------------------------------------------------------------------------
-- Byte-identical to what is live except for the nullif on the last line.
CREATE OR REPLACE FUNCTION public.audit_actor()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'email',   public.my_login_email(),
    'role',    coalesce(public.get_my_role(), 'none'),
    'zone_id', (select a.zone_id from public.admins a
                 where a.id = auth.uid()
                    or lower(btrim(a.email)) = public.my_login_email()
                 limit 1),
    'source',  coalesce(nullif(auth.jwt() ->> 'role', ''), 'anon'),
    -- CMD #1857 — an untouched GUC is NULL, a touched-and-reverted one is ''.
    -- Without this nullif the audit trigger crashes every write on the
    -- connection for the rest of its life.
    'ip',      nullif(btrim(split_part(
                 coalesce((nullif(current_setting('request.headers', true), '')::jsonb
                             ->> 'x-forwarded-for'), ''),
                 ',', 1)), '')
  )
$function$;

comment on function public.audit_actor() is
  'CMD #1857 — the actor block every audit_row_trg() row carries. Every '
  'request.* GUC it reads is nullif-guarded: a GUC that has been set and '
  'rolled back reads back as the empty string, and ''''::jsonb is an error, '
  'not NULL.';

-- ---------------------------------------------------------------------------
-- 2. THE SAME HOLE, EVERYWHERE ELSE IT IS OPEN
-- ---------------------------------------------------------------------------
-- catalogue_mirror_next, catalogue_mirror_report and wa_event_diagnosis all
-- cast request.jwt.claims without a nullif. Their bodies are long and belong
-- to other changes, so this rewrites ONLY the offending literal — the exact
-- text `current_setting('request.<name>', true)::json[b]` becomes
-- `nullif(current_setting('request.<name>', true), '')::json[b]` — and leaves
-- every other byte of the definition alone. A function that is already
-- guarded does not match and is not touched.
do $sweep$
declare
  r record;
  v_src text;
  v_new text;
  v_n   int := 0;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosrc ~ 'current_setting\( *''request\.[a-z._]+'' *, *true *\) *::[ ]*jsonb?'
       and p.prosrc !~ 'exception +when'
     order by p.proname
  loop
    v_src := r.def;
    v_new := regexp_replace(
               v_src,
               'current_setting\( *(''request\.[a-z._]+'') *, *true *\) *:: *(jsonb|json)\M',
               'nullif(current_setting(\1, true), '''')::\2',
               'g');
    if v_new is distinct from v_src then
      execute v_new;
      v_n := v_n + 1;
      raise notice 'CMD #1857 — guarded request.* cast in public.%', r.proname;
    end if;
  end loop;
  raise notice 'CMD #1857 — % function(s) guarded', v_n;
end $sweep$;

-- ---------------------------------------------------------------------------
-- 3. THE ASSERTION. A half-applied replay is a failed replay, not a warning.
-- ---------------------------------------------------------------------------
do $assert$
declare v_left text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_left
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosrc ~ 'current_setting\( *''request\.[a-z._]+'' *, *true *\) *::[ ]*jsonb?'
     and p.prosrc !~ 'exception +when';
  if v_left is not null then
    raise exception 'CMD #1857: unguarded request.* json cast still present in: %', v_left;
  end if;

  -- And the actual failure mode, reproduced: a header GUC that has been set
  -- and rolled back must not be able to break an audited write again.
  perform set_config('request.headers', '', true);
  perform public.audit_actor();
  perform set_config('request.headers', '', true);
  perform public.audit_actor();
end $assert$;

commit;

-- ---------------------------------------------------------------------------
-- 4. THE CLASS, RETIRED. A behaviour test, so it can never come back quietly.
-- ---------------------------------------------------------------------------
-- Nine red behaviours all pointed at one missing nullif. The next unguarded
-- cast of a request.* GUC should be caught the run it is written, by name,
-- instead of surfacing as nine unrelated-looking failures in whichever
-- behaviours happen to sort after whoever touched the GUC first.
begin;

insert into public.rg_behavior_tests (name, body, enabled, note) values (
  'c1857_request_gucs_are_nullif_guarded',
$rgb$
do $b$
declare v_left text;
begin
  -- A custom GUC that has been set and rolled back reads back as the EMPTY
  -- STRING for the rest of the session, and ''::jsonb raises. Anything that
  -- casts a request.* setting must nullif it (or catch), the way auth.uid(),
  -- auth.jwt(), auth.role() and auth.email() all do.
  select string_agg(p.proname, ', ' order by p.proname) into v_left
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosrc ~ 'current_setting\( *''request\.[a-z._]+'' *, *true *\) *::[ ]*jsonb?'
     and p.prosrc !~ 'exception +when';
  if v_left is not null then
    raise exception 'RG_FAIL: unguarded request.* json cast (add nullif(...,'''')): %', v_left;
  end if;

  -- And the failure itself, end to end: the audit trigger's actor block must
  -- survive an empty header GUC. This is what took nine behaviours down.
  perform set_config('request.headers', '', true);
  if public.audit_actor() is null then
    raise exception 'RG_FAIL: audit_actor() returned nothing under an empty request.headers';
  end if;

  raise exception 'RG_ROLLBACK';
end $b$;
$rgb$,
  true,
  'CMD #1857 — nine behaviours went red on one missing nullif in audit_actor(). '
  'This names the offender on the run it lands instead.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

commit;

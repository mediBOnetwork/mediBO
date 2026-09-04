-- CHANGE #1149 (G) — the journey that retires the class, not the photograph.
--
-- The QA blocker on this command was: the merge worker's replay keyed on
-- supabase_migrations.schema_migrations, which holds 43 of the 332 version
-- prefixes in main, so at its next restart it would have applied 289 historical
-- migration files to PRODUCTION. This probe asserts the properties that make
-- that impossible, so any future change that reintroduces the shape fails here.
create or replace function public._journey_qa_1149_508()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_pk_is_file  boolean;
  v_files       bigint;
  v_by_file     boolean;
  v_mode        jsonb;
  v_mode_ok     boolean;
  v_closed      boolean;
  v_record_src  text;
  v_writes_ledger boolean;
  v_writes_cli  boolean;
  v_ok          boolean;
begin
  -- (a) the ledger is keyed by the full FILE basename. A version key is what
  -- made 20260904_ ambiguous across several files in the first place.
  select (a.attname = 'file') into v_pk_is_file
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.conrelid = 'public.migration_replay_ledger'::regclass and c.contype = 'p'
     and array_length(c.conkey, 1) = 1;

  -- (b) it was SEEDED from the tree, so history is already "applied" and can
  -- never be pending. An empty ledger is the exact state that replays history.
  select count(*) into v_files from public.migration_replay_ledger;

  -- (c) the door the script asks answers by file, not only by version.
  v_by_file := to_regprocedure('public.migration_replay_applied(text[],text[])') is not null;

  -- (d) while no build branch has carried builds, the worker RECORDS and
  -- applies nothing — today's behaviour, unchanged.
  v_mode := public.migration_replay_mode();
  v_mode_ok := (v_mode->>'mode') in ('record','replay')
    and ((v_mode->>'built_24h')::int > 0) = ((v_mode->>'mode') = 'replay');

  -- (e) neither door is reachable over HTTP by a browser role.
  select not exists (
    select 1 from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     cross join (values ('anon'),('authenticated')) r(rolname)
    where n.nspname = 'public'
      and p.proname in ('migration_replay_applied','migration_replay_record',
                        'migration_replay_seed','migration_replay_mode')
      and has_function_privilege(r.rolname, p.oid, 'execute'))
    into v_closed;

  -- (f) recording writes the ledger, never the CLI table the repo never fed.
  select p.prosrc into v_record_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'migration_replay_record';
  v_writes_ledger := coalesce(v_record_src,'') like '%migration_replay_ledger%';
  v_writes_cli    := coalesce(v_record_src,'') like '%supabase_migrations.schema_migrations%';

  v_ok := coalesce(v_pk_is_file,false) and v_files >= 500 and v_by_file
      and v_mode_ok and v_closed and v_writes_ledger and not v_writes_cli;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'ledger primary key is the file basename=' || coalesce(v_pk_is_file::text,'?') ||
      ' | ledger seeded from the tree=' || v_files || ' file(s) (must be >= 500)' ||
      ' | migration_replay_applied answers by file=' || v_by_file::text ||
      ' | mode=' || coalesce(v_mode->>'mode','?') ||
        ' with built_24h=' || coalesce(v_mode->>'built_24h','?') ||
        ' consistent=' || v_mode_ok::text ||
      ' | replay doors closed to anon/authenticated=' || coalesce(v_closed::text,'?') ||
      ' | record writes the ledger=' || v_writes_ledger::text ||
      ' | record writes supabase_migrations.schema_migrations=' || v_writes_cli::text ||
        ' (must be false)'));
end $$;
revoke all on function public._journey_qa_1149_508() from public, anon, authenticated;
grant execute on function public._journey_qa_1149_508() to service_role;

-- Replace the auto-generated TODO stub with what the journey actually holds.
update public.dev_journeys
   set steps = jsonb_build_array(
         'The merge worker restarts and picks up a batch whose tree carries migration files.',
         'It asks the ledger which of those files live has already had, keyed by the FULL file basename.',
         'While no build branch has carried builds, it RECORDS the new files and applies nothing to production.',
         'Once a branch has carried builds, and only then, it applies the pending files on live in one exclusive DB-lane slot.',
         'A historical file that was applied by hand months ago is never pending, because the ledger was seeded from the tree.'),
       assertions = jsonb_build_array(
         'migration_replay_ledger is keyed by the full file basename, not the version prefix (20260904_ is shared by several files)',
         'the ledger was seeded from the deploying tree, so the 289 files that predate this change can never be pending',
         'migration_replay_applied answers by file, not only by version',
         'migration_replay_mode() returns record while build_branch shows no branch carrying builds in 24h, and replay only when one does',
         'none of the four replay doors is executable by anon or authenticated',
         'migration_replay_record writes the ledger and never supabase_migrations.schema_migrations')
 where name = 'qa-1149-508';

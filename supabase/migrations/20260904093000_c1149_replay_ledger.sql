-- CHANGE #1149 (D) — the replay ledger is keyed by FILE and seeded from the tree.
--
-- Why: supabase_migrations.schema_migrations held 43 of the 332 version prefixes
-- in main (this repo's files were applied to live by hand, never through the
-- CLI ledger). Keyed on that table, migration_replay.sh would have replayed
-- 289 old files on production at the first deploy after the merge worker
-- restarted. The ledger now lives in its own table, keyed by the full file
-- basename (bare-date prefixes like 20260904_ are shared by several files), and
-- is seeded once with every file already in the tree — so replay only ever
-- touches files that arrive AFTER this change.
create table if not exists public.migration_replay_ledger (
  file        text primary key,
  version     text not null,
  name        text not null,
  applied_at  timestamptz not null default now(),
  applied_by  text not null default 'seed'
);
create index if not exists migration_replay_ledger_version_idx on public.migration_replay_ledger (version);
alter table public.migration_replay_ledger enable row level security;
revoke all on public.migration_replay_ledger from public, anon, authenticated;

drop function if exists public.migration_replay_applied(text[]);
create or replace function public.migration_replay_applied(p_versions text[] default '{}', p_files text[] default '{}')
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ok', true,
    'applied', coalesce((select jsonb_agg(distinct l.version) from public.migration_replay_ledger l
                          where l.version = any (p_versions)), '[]'::jsonb),
    'applied_files', coalesce((select jsonb_agg(l.file) from public.migration_replay_ledger l
                                where l.file = any (p_files)), '[]'::jsonb),
    'ledger_files', (select count(*) from public.migration_replay_ledger));
$$;

create or replace function public.migration_replay_record(p_version text, p_name text, p_sql text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
begin
  perform public._build_branch_guard();
  insert into public.migration_replay_ledger (file, version, name, applied_by)
  values (p_version || '_' || p_name, p_version, p_name, 'merge-worker')
  on conflict (file) do nothing;
  return jsonb_build_object('ok', true, 'file', p_version || '_' || p_name);
end $$;

-- Seed: every basename handed in is ALREADY on live (applied by the runner that
-- wrote it). Idempotent; only new names insert.
create or replace function public.migration_replay_seed(p_files text[])
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare v_n int;
begin
  perform public._build_branch_guard();
  with f as (select distinct regexp_replace(x, '\.sql$', '') as b from unnest(p_files) x),
  ins as (
    insert into public.migration_replay_ledger (file, version, name, applied_by)
    select b, split_part(b, '_', 1), substr(b, length(split_part(b, '_', 1)) + 2), 'seed'
      from f where b ~ '^[0-9]{8,}_.+'
    on conflict (file) do nothing
    returning 1)
  select count(*) into v_n from ins;
  return jsonb_build_object('ok', true, 'inserted', v_n,
    'ledger_files', (select count(*) from public.migration_replay_ledger));
end $$;

revoke all on function public.migration_replay_applied(text[], text[]) from public, anon, authenticated;
revoke all on function public.migration_replay_record(text, text, text) from public, anon, authenticated;
revoke all on function public.migration_replay_seed(text[]) from public, anon, authenticated;
grant execute on function public.migration_replay_applied(text[], text[]) to service_role;
grant execute on function public.migration_replay_record(text, text, text) to service_role;
grant execute on function public.migration_replay_seed(text[]) to service_role;

-- The behaviour test must END with RG_ROLLBACK (rg_run_behavior's marker); a
-- bare `return` reads as "did not raise RG_ROLLBACK" and turns the guard red.
update public.rg_behavior_tests
   set body = replace(replace(body,
       'if not coalesce(v_on, false) then return; end if;',
       'if not coalesce(v_on, false) then raise exception ''RG_ROLLBACK''; end if;'),
       E'end $x$;', E'  raise exception ''RG_ROLLBACK'';\nend $x$;')
 where name = 'c1149_runner_builds_on_branch'
   and body not like '%raise exception ''RG_ROLLBACK''%';

-- replay-target: control-plane
-- CHANGE #1847 (repair) — the replay window was measured from the WRONG column.
--
-- #1149 decided record-vs-replay from `build_branch.created_at > now() - 24h`.
-- Branch 39 (pavaxgskqxnoyutwumvh) was created 2026-09-05 12:19 and is STILL the
-- build target: 71 builds, the last of them minutes ago. At 2026-09-06 12:24 it
-- aged out of that window and migration_replay_mode() started answering
--   "no runner built on a Supabase branch in the last 24 h (0 branch(es), 0 builds)"
-- while every runner in the fleet was building on it. From that minute the merge
-- worker RECORDED each new migration file as "applied to live by its runner" and
-- applied nothing: #1847's five files are in the ledger and none of their objects
-- exist on production. A runner that obeys the build-branch rule ships a frontend
-- onto a schema that has never seen its DDL — silently, because the ledger says
-- the file landed.
--
-- A branch does not stop being the build target because it got old. The window
-- now measures the last BUILD, and a branch that is on with builds on it counts
-- whatever its age: those are the two facts that actually mean "live has not seen
-- this DDL yet".
create or replace function public.migration_replay_mode()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with b as (
    select count(*) filter (
             where coalesce(builds, 0) > 0
               and (status = 'on'
                    or coalesce(last_build_at, created_at) > now() - interval '24 hours')
           ) as built,
           count(*) filter (
             where status = 'on'
                or greatest(created_at, coalesce(last_build_at, created_at)) > now() - interval '24 hours'
           ) as any_branch
      from public.build_branch
     where deleted_at is null)
  select jsonb_build_object('ok', true,
    'mode', case when b.built > 0 then 'replay' else 'record' end,
    'reason', case when b.built > 0
      then b.built || ' build branch(es) carried builds in the last 24 h — live has not seen that DDL; replaying pending files'
      else 'no runner built on a Supabase branch in the last 24 h (' || b.any_branch || ' branch(es), 0 builds) — files were applied to live by their runners; recording only' end,
    'branches_24h', b.any_branch, 'built_24h', b.built)
  from b;
$$;
revoke all on function public.migration_replay_mode() from public, anon, authenticated;
grant execute on function public.migration_replay_mode() to service_role;

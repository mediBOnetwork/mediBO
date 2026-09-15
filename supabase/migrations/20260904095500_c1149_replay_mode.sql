-- CHANGE #1149 (E) — the replay has two modes, and the BACKEND picks one.
--
-- record : no runner has built on a Supabase branch in the last 24 h (the
--          capability is off, or a branch existed with builds = 0). Runners
--          applied their files to live themselves, exactly as before this
--          change — so the merge worker only RECORDS the new files in the
--          ledger and applies nothing. Today's behaviour, unchanged.
-- replay : a branch with builds > 0 existed in the last 24 h, so live has
--          not seen that DDL yet — the merge worker applies the pending
--          files on live, once per batch.
create or replace function public.migration_replay_mode()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with b as (
    select count(*) filter (where coalesce(builds, 0) > 0) as built,
           count(*) as any_branch
      from public.build_branch
     where created_at > now() - interval '24 hours')
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

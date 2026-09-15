-- CHANGE #1197 (follow-up) — dev_ctl_get() must stay cheap.
--
-- The #1197 wrapper appended dev_context_metrics() to dev_ctl_get(). That RPC
-- is the single most-polled call in the fleet: every worker, the supervisor and
-- the app hit it on a short interval. The metrics function runs four aggregates
-- over dev_commands and dev_context_event, so the wrapper turned a constant-time
-- read into four scans per poll. Measured in production at 28.6 SECONDS per
-- dev_ctl_get and it exhausted the connection pool.
--
-- The numbers describe a 20-command window and move minutes apart at best, so
-- computing them per call was never necessary. Serve them from a cache refreshed
-- at most once a minute, and never let a metrics failure take dev_ctl_get down.

create table if not exists public.dev_context_metrics_cache (
  id         int primary key default 1,
  payload    jsonb not null default '{}'::jsonb,
  computed_at timestamptz not null default now(),
  constraint dev_context_metrics_cache_singleton check (id = 1)
);

-- The window queries order by finished_at and filter on status; the resume
-- average filters on resume_note_at. Give all three an index so even a cold
-- refresh is cheap.
create index if not exists dev_commands_finished_at_idx
  on public.dev_commands (finished_at desc) where status = 'completed';
create index if not exists dev_commands_resume_note_at_idx
  on public.dev_commands (resume_note_at) where resume_note_at is not null;
create index if not exists dev_context_event_at_idx
  on public.dev_context_event (at desc);

create or replace function public.dev_context_metrics_cached(p_max_age_s int default 60)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_row record; v jsonb;
begin
  select * into v_row from dev_context_metrics_cache where id = 1;
  if found and v_row.computed_at > now() - make_interval(secs => greatest(p_max_age_s, 5)) then
    return v_row.payload;
  end if;

  -- A refresh must never be the reason a poll fails. If the recompute cannot
  -- run (lock timeout, contention), serve the stale payload rather than raising
  -- into dev_ctl_get.
  begin
    v := public.dev_context_metrics();
  exception when others then
    return coalesce(v_row.payload, jsonb_build_object('ok', false, 'has', false));
  end;

  insert into dev_context_metrics_cache (id, payload, computed_at)
       values (1, v, now())
  on conflict (id) do update set payload = excluded.payload, computed_at = excluded.computed_at;
  return v;
end $$;

-- Same wrapper, cheap body.
create or replace function public.dev_ctl_get()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v jsonb; v_ctx jsonb;
begin
  v := public.dev_ctl_get_core();
  begin
    v_ctx := public.dev_context_metrics_cached(60);
  exception when others then
    v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  return v || jsonb_build_object('context', v_ctx);
end $$;

grant execute on function public.dev_context_metrics_cached(int) to service_role;
revoke all on public.dev_context_metrics_cache from anon, authenticated;

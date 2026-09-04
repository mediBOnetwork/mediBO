-- CHANGE #1149 — Build on a Supabase branch, never on live.
--
-- WHY. Every runner's DDL makes PostgREST reload its schema cache on the
-- Micro: ~1 min of 503 / PGRST002 each time, 4,513 of them in one ten-minute
-- window on 3 Sep 18:00 UTC, and the live app hangs on loading while it
-- happens. The fix has three legs: runners build on a preview BRANCH (this
-- table + the supervisor own its lifecycle), production takes ONE migration
-- replay per batch deploy (the merge worker), and the app keeps rendering the
-- last payload it saw when the backend is briefly gone (ResilientClient).
--
-- This file is the backend leg: the branch record, its lifecycle RPCs, the cost
-- guard, the per-session ref ledger the rg guard reads, the words, and the
-- migration-replay ledger door. Idempotent throughout.

-- ── 1. THE BRANCH RECORD ─────────────────────────────────────────────────────
create table if not exists public.build_branch (
  id            bigserial primary key,
  branch_id     text,                         -- Supabase branch id (Management API)
  project_ref   text,                         -- the branch's own project ref
  api_url       text,                         -- https://<ref>.supabase.co
  status        text not null default 'creating'
                check (status in ('creating','on','deleting','off','failed')),
  created_at    timestamptz not null default now(),
  ready_at      timestamptz,
  deleted_at    timestamptz,
  last_build_at timestamptz,
  builds        int  not null default 0,
  hours         numeric(8,2),
  reason        text not null default '',
  created_by    text not null default 'supervisor'
);
create index if not exists build_branch_status_idx on public.build_branch (status, created_at desc);
alter table public.build_branch enable row level security;

create table if not exists public.build_branch_config (
  id                 boolean primary key default true check (id),
  enabled            boolean not null default true,
  idle_delete_min    int     not null default 5,     -- mirrors worker_pool.idle_shutdown_min
  cost_guard_hours   numeric not null default 20,    -- alive this long with no build → delete + WhatsApp
  hourly_usd         numeric not null default 0.01344,
  seed_sql_path      text    not null default 'scripts/branch_seed.sql',
  updated_at         timestamptz not null default now()
);
insert into public.build_branch_config (id) values (true) on conflict (id) do nothing;

-- Which Supabase ref each runner session is actually pointed at. runner.sh
-- writes this on every claim; the rg guard below reads it.
create table if not exists public.runner_session_env (
  agent        text primary key,
  supabase_ref text not null,
  is_branch    boolean not null default false,
  command_id   bigint,
  updated_at   timestamptz not null default now()
);
alter table public.runner_session_env enable row level security;

-- ── 2. THE WORDS ─────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value)
select k, to_jsonb(v) from (values
  ('dev_queue.branch_on',       'branch: on · {age}'),
  ('dev_queue.branch_creating', 'branch: starting…'),
  ('dev_queue.branch_deleting', 'branch: closing…'),
  ('dev_queue.branch_off',      'branch: off'),
  ('dev_queue.branch_failed',   'branch: failed — {reason}'),
  ('dev_queue.branch_no_token', 'branch: off — save SUPABASE_ACCESS_TOKEN in the vault'),
  ('app.reconnecting',          'Reconnecting… showing what we last saw'),
  ('app.reconnected',           'Back online')
) t(k, v)
on conflict (key) do nothing;

-- ── 3. LIFECYCLE RPCs (runner only) ───────────────────────────────────────────
create or replace function public._build_branch_guard()
returns void language plpgsql stable security definer set search_path to 'public' as $$
declare v_role text;
begin
  -- PostgREST 12 exposes the JWT as request.jwt.claims (json); the dotted
  -- request.jwt.claim.role setting is the pre-12 spelling and is absent here.
  begin v_role := coalesce(auth.jwt() ->> 'role', ''); exception when others then v_role := ''; end;
  if v_role = 'service_role'
     or coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
     or session_user in ('postgres','supabase_admin','service_role') then return; end if;
  raise exception 'build_branch: runner only';
end $$;

create or replace function public._build_branch_age_label(p_from timestamptz)
returns text language sql immutable as $$
  select case
    when p_from is null then ''
    when now() - p_from < interval '1 hour'
      then greatest(1, floor(extract(epoch from now() - p_from) / 60))::int || 'm'
    else floor(extract(epoch from now() - p_from) / 3600)::int || 'h '
         || lpad((floor(extract(epoch from now() - p_from) / 60)::int % 60)::text, 2, '0') || 'm'
  end
$$;

-- The current branch, rendered. `display` is what the Runner control card
-- prints verbatim; the supervisor forwards it inside pool_status_write.
create or replace function public.build_branch_state()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare b public.build_branch; cfg public.build_branch_config; v_disp text; v_age text;
begin
  select * into cfg from public.build_branch_config where id;
  select * into b from public.build_branch
   where status in ('creating','on','deleting') order by created_at desc limit 1;
  v_age := public._build_branch_age_label(coalesce(b.ready_at, b.created_at));
  v_disp := case coalesce(b.status,'off')
    when 'on'       then replace(public._c('dev_queue.branch_on'), '{age}', v_age)
    when 'creating' then public._c('dev_queue.branch_creating')
    when 'deleting' then public._c('dev_queue.branch_deleting')
    else public._c('dev_queue.branch_off') end;
  return jsonb_build_object(
    'ok', true, 'enabled', cfg.enabled,
    'status', coalesce(b.status,'off'),
    'id', b.id, 'branch_id', b.branch_id, 'project_ref', b.project_ref, 'api_url', b.api_url,
    'created_at', b.created_at, 'ready_at', b.ready_at, 'last_build_at', b.last_build_at,
    'builds', coalesce(b.builds,0), 'age_label', v_age, 'display', v_disp,
    'idle_delete_min', cfg.idle_delete_min, 'cost_guard_hours', cfg.cost_guard_hours,
    'hourly_usd', cfg.hourly_usd);
end $$;

-- One row per lifecycle transition. creating → on → deleting → off. Every
-- create and delete is an audit row with the hours it lived.
create or replace function public.build_branch_mark(
  p_status text, p_branch_id text default null, p_project_ref text default null,
  p_api_url text default null, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare b public.build_branch; v_hours numeric; cfg public.build_branch_config;
begin
  perform public._build_branch_guard();
  select * into cfg from public.build_branch_config where id;
  select * into b from public.build_branch
   where status in ('creating','on','deleting') order by created_at desc limit 1;

  if p_status = 'creating' then
    if b.id is not null then
      return jsonb_build_object('ok', true, 'already', true, 'id', b.id, 'status', b.status);
    end if;
    insert into public.build_branch (status, reason) values ('creating', coalesce(p_reason,''))
    returning * into b;
    insert into public.dev_audit_log (actor, action, subject, detail)
    values ('supervisor', 'build_branch.create', b.id::text,
            jsonb_build_object('reason', coalesce(p_reason,'')));
    return jsonb_build_object('ok', true, 'id', b.id, 'status', 'creating');
  end if;

  if b.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_live_branch');
  end if;

  if p_status = 'on' then
    update public.build_branch
       set status = 'on', ready_at = coalesce(ready_at, now()),
           branch_id = coalesce(p_branch_id, branch_id),
           project_ref = coalesce(p_project_ref, project_ref),
           api_url = coalesce(p_api_url, api_url),
           reason = coalesce(p_reason, reason)
     where id = b.id returning * into b;
    insert into public.dev_audit_log (actor, action, subject, detail)
    values ('supervisor', 'build_branch.ready', b.id::text,
            jsonb_build_object('project_ref', b.project_ref, 'branch_id', b.branch_id,
                               'create_seconds', round(extract(epoch from (now() - b.created_at)))));
  elsif p_status = 'deleting' then
    update public.build_branch set status = 'deleting', reason = coalesce(p_reason, reason)
     where id = b.id returning * into b;
  elsif p_status in ('off','failed') then
    v_hours := round(extract(epoch from (now() - b.created_at)) / 3600.0, 2);
    update public.build_branch
       set status = p_status, deleted_at = now(), hours = v_hours,
           reason = coalesce(p_reason, reason)
     where id = b.id returning * into b;
    insert into public.dev_audit_log (actor, action, subject, detail)
    values ('supervisor', 'build_branch.' || p_status, b.id::text,
            jsonb_build_object('project_ref', b.project_ref, 'branch_id', b.branch_id,
                               'hours', v_hours, 'builds', b.builds,
                               'usd', round(v_hours * cfg.hourly_usd, 4),
                               'reason', coalesce(p_reason,'')));
  else
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'status', b.status, 'hours', b.hours);
end $$;

-- A build started on the branch. Bumps the counter the cost guard reads.
create or replace function public.build_branch_touch(p_command_id bigint default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  perform public._build_branch_guard();
  update public.build_branch set last_build_at = now(), builds = builds + 1
   where status = 'on' returning id into v_id;
  return jsonb_build_object('ok', v_id is not null, 'id', v_id);
end $$;

-- The one decision the supervisor asks every tick: should the branch exist?
--   want:  true when the queue holds claimable work and the feature is on
--   idle:  true when nothing has been pending/building for idle_delete_min
--   cost_guard: true when the branch has lived past cost_guard_hours without a
--          single build — delete it and tell Om (WhatsApp, admin route)
create or replace function public.build_branch_decide()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare cfg public.build_branch_config; b public.build_branch;
        v_pend int; v_build int; v_last_activity timestamptz; v_idle boolean; v_guard boolean;
        v_idle_min int;
begin
  perform public._build_branch_guard();
  select * into cfg from public.build_branch_config where id;
  select * into b from public.build_branch
   where status in ('creating','on','deleting') order by created_at desc limit 1;

  select count(*) filter (where status = 'pending'),
         count(*) filter (where status = 'building')
    into v_pend, v_build from public.dev_commands;
  select max(greatest(coalesce(heartbeat_at, '-infinity'), coalesce(started_at, '-infinity')))
    into v_last_activity from public.dev_commands
   where status in ('pending','building') or heartbeat_at > now() - interval '1 day';

  v_idle_min := coalesce(
    (select (value->>'idle_shutdown_min')::int from public.dev_runner_config where key = 'worker_pool'),
    cfg.idle_delete_min);
  v_idle := v_pend = 0 and v_build = 0
            and coalesce(v_last_activity, '-infinity') < now() - make_interval(mins => v_idle_min);
  v_guard := b.status = 'on' and coalesce(b.builds, 0) = 0
             and b.created_at < now() - make_interval(hours => cfg.cost_guard_hours::int);

  return jsonb_build_object(
    'ok', true, 'enabled', cfg.enabled,
    'status', coalesce(b.status, 'off'),
    'want', cfg.enabled and (v_pend > 0 or v_build > 0),
    'idle', v_idle, 'cost_guard', coalesce(v_guard, false),
    'pending', v_pend, 'building', v_build, 'idle_min', v_idle_min,
    'branch_id', b.branch_id, 'project_ref', b.project_ref,
    'age_label', public._build_branch_age_label(coalesce(b.ready_at, b.created_at)));
end $$;

-- runner.sh reports where each session is pointed, every claim.
create or replace function public.runner_env_report(
  p_agent text, p_ref text, p_is_branch boolean, p_command_id bigint default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
begin
  perform public._build_branch_guard();
  insert into public.runner_session_env (agent, supabase_ref, is_branch, command_id, updated_at)
  values (p_agent, p_ref, p_is_branch, p_command_id, now())
  on conflict (agent) do update
    set supabase_ref = excluded.supabase_ref, is_branch = excluded.is_branch,
        command_id = excluded.command_id, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- The branch log an operator reads: every create/delete with hours and cost.
create or replace function public.build_branch_log(p_days int default 1)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb; v_hours numeric; v_usd numeric; cfg public.build_branch_config;
begin
  select * into cfg from public.build_branch_config where id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'status', b.status, 'project_ref', coalesce(b.project_ref,'—'),
           'created', to_char(b.created_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
           'deleted', case when b.deleted_at is null then '—'
                      else to_char(b.deleted_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') end,
           'hours', coalesce(b.hours, round(extract(epoch from (now() - b.created_at))/3600.0, 2)),
           'builds', b.builds, 'reason', b.reason) order by b.created_at desc), '[]'::jsonb),
         coalesce(sum(coalesce(b.hours, extract(epoch from (now() - b.created_at))/3600.0)), 0)
    into v_rows, v_hours
    from public.build_branch b where b.created_at > now() - make_interval(days => p_days);
  v_usd := round(v_hours * cfg.hourly_usd, 4);
  return jsonb_build_object('ok', true, 'days', p_days, 'rows', v_rows,
    'hours_billed', round(v_hours, 2), 'usd', v_usd,
    'hours_label', round(v_hours, 2) || ' h · $' || v_usd);
end $$;

revoke all on function public.build_branch_state() from public;
revoke all on function public.build_branch_mark(text,text,text,text,text) from public;
revoke all on function public.build_branch_touch(bigint) from public;
revoke all on function public.build_branch_decide() from public;
revoke all on function public.runner_env_report(text,text,boolean,bigint) from public;
revoke all on function public.build_branch_log(int) from public;
grant execute on function public.build_branch_state() to authenticated, service_role;
grant execute on function public.build_branch_log(int) to authenticated, service_role;
grant execute on function public.build_branch_mark(text,text,text,text,text) to service_role;
grant execute on function public.build_branch_touch(bigint) to service_role;
grant execute on function public.build_branch_decide() to service_role;
grant execute on function public.runner_env_report(text,text,boolean,bigint) to service_role;

-- ── 4. THE COST GUARD'S VOICE — a WhatsApp to Om, on the admin route ─────────
insert into public.wa_event_routes (event_key, label, description, audience, enabled, auto_manage,
                                    push_enabled, email_enabled, push_title, push_body, wa_category)
values ('build_branch_cost_alert', 'Build branch left running',
        'The Supabase build branch lived {hours} h without a single build and was deleted to stop the bill.',
        'admin', true, true, true, true,
        'Build branch deleted', 'Build branch {ref} ran {hours} h with no builds — deleted (≈${usd}).',
        'utility')
on conflict (event_key) do update
  set label = excluded.label, description = excluded.description, audience = 'admin',
      push_title = excluded.push_title, push_body = excluded.push_body;

-- ── 5. THE MIGRATION-REPLAY LEDGER DOOR ──────────────────────────────────────
-- The merge worker applies each batch's migration files on live once, then
-- records them here so a resumed batch (or the next one) never replays them.
create or replace function public.migration_replay_record(p_version text, p_name text, p_sql text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
begin
  perform public._build_branch_guard();
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (p_version, p_name, case when p_sql is null then null else array[p_sql] end)
  on conflict (version) do nothing;
  return jsonb_build_object('ok', true, 'version', p_version);
end $$;
create or replace function public.migration_replay_applied(p_versions text[])
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ok', true,
    'applied', coalesce((select jsonb_agg(m.version) from supabase_migrations.schema_migrations m
                          where m.version = any (p_versions)), '[]'::jsonb));
$$;
revoke all on function public.migration_replay_record(text,text,text) from public;
revoke all on function public.migration_replay_applied(text[]) from public;
grant execute on function public.migration_replay_record(text,text,text) to service_role;
grant execute on function public.migration_replay_applied(text[]) to service_role;

-- ── 6. THE GUARD — rg red when a BUILDING runner is pointed at live ──────────
insert into public.rg_behavior_tests (name, body, enabled, note)
values ('c1149_runner_builds_on_branch', $body$
do $x$
declare v_bad text; v_on boolean;
begin
  select enabled into v_on from public.build_branch_config where id;
  if not coalesce(v_on, false) then raise exception 'RG_ROLLBACK'; end if;   -- feature off: nothing to guard
  -- A runner whose session was reported on the PRODUCTION ref while it holds a
  -- building row. The merge worker (agent merge-worker) is exempt: its deploy
  -- step is the one place production is meant to be touched.
  select string_agg(e.agent || ' (#' || d.id || ')', ', ') into v_bad
    from public.runner_session_env e
    join public.dev_commands d on d.claimed_by = e.agent and d.status = 'building'
   where e.supabase_ref = 'swojhmarmaijkshsbeih'
     and e.agent <> 'merge-worker'
     and e.updated_at > now() - interval '6 hours'
     and exists (select 1 from public.build_branch b where b.status = 'on');
  if v_bad is not null then
    raise exception 'RG_FAIL: runner building on LIVE while a build branch is on: %', v_bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$body$, true, 'CHANGE #1149 — builds happen on the Supabase branch, production only takes the batch replay')
on conflict (name) do update set body = excluded.body, enabled = true, note = excluded.note;

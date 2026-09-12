-- CHANGE #1570 — builds must actually RUN on the build branch, and the runner
-- strip must be one card that says so.
--
-- #1149 built the branch, #1470 made runner.sh re-adopt it per command, and the
-- counter still read 0 at 12:50 on 5 Sep with the branch 26 minutes old and two
-- commands (#1513, #1368) claimed after it was ready. Two independent reasons,
-- both invisible from SQL:
--   1. runner.sh is a long-lived bash process. Its `while` body is parsed once,
--      at start; the two live loops began 12:03 and 12:12, before branch.env
--      existed (12:19) and before #1470 edited the file (12:54). The
--      per-command adopt_build_branch that #1470 added simply is not in the
--      code those processes are running.
--   2. Even after a restart it could not have worked: the build happens inside
--      a `rc-<agent>` TMUX pane, and a tmux pane inherits the tmux SERVER's
--      environment, not the exports of whatever process asked for the session.
--      `env` in a live build session carries no MEDIBO_* at all.
-- So the target database can never be a process environment variable. It has to
-- be RESOLVED, from here, at the moment a build asks — which is what
-- build_branch_env() below is. Everything else follows from that: the counter
-- counts distinct commands that actually resolved the branch, and a build that
-- resolves LIVE while a branch is on is refused and the refusal is a row.

-- ── 1. the build ledger — one row per (branch, command), so `builds` counts ──
-- commands, not RPC calls. #1470's build_branch_touch incremented on every
-- claim, which would have made the number meaningless the moment it moved.
create table if not exists public.build_branch_build (
  id          bigserial primary key,
  branch_id   text        not null,
  project_ref text,
  command_id  bigint,
  agent       text,
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  calls       integer     not null default 1
);
create unique index if not exists build_branch_build_uq
  on public.build_branch_build (branch_id, coalesce(command_id, -1));

-- ── 2. the refusal log — a build that would have run on production ──────────
create table if not exists public.build_branch_refusal (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  agent      text,
  command_id bigint,
  reason     text        not null,
  ref        text,
  branch_ref text
);
create index if not exists build_branch_refusal_at on public.build_branch_refusal (at desc);

-- ── 3. per-worker actions the strip can ask for (kill / restart) ────────────
create table if not exists public.runner_action_queue (
  id           bigserial primary key,
  agent        text        not null,
  action       text        not null,
  requested_at timestamptz not null default now(),
  requested_by uuid,
  taken_at     timestamptz,
  taken_by     text,
  done_at      timestamptz,
  result       text
);
create index if not exists runner_action_queue_open
  on public.runner_action_queue (requested_at) where done_at is null;

-- #1470 added runner_session_env.can_adopt on LIVE at 12:43; the build branch
-- was cut at 12:19 and therefore does not have it. A branch is a SNAPSHOT, so
-- every column a later change added has to be asserted here, idempotently, or
-- the first query on the branch dies on a column production has had for hours.
alter table public.runner_session_env add column if not exists can_adopt boolean;

-- ── 4. the resolver every build calls instead of reading an env var ─────────
-- Returns the database this command must use, decided HERE. `target` is the
-- whole answer: 'branch' or 'live'. When it is 'branch' the ledger row is
-- written and build_branch.builds moves — once per command, however many times
-- the resolver is called.
create or replace function public.build_branch_env(
  p_agent text default null, p_command_id bigint default null,
  p_can_adopt boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare b public.build_branch; cfg public.build_branch_config;
        v_new boolean := false; v_builds int;
begin
  perform public._build_branch_guard();
  select * into cfg from public.build_branch_config where id;
  select * into b from public.build_branch where status = 'on' order by created_at desc limit 1;

  if p_agent is not null then
    insert into public.runner_session_env (agent, supabase_ref, is_branch, command_id, can_adopt, updated_at)
    values (p_agent, coalesce(b.project_ref, 'swojhmarmaijkshsbeih'), b.id is not null,
            p_command_id, p_can_adopt, now())
    on conflict (agent) do update
      set supabase_ref = excluded.supabase_ref, is_branch = excluded.is_branch,
          command_id   = excluded.command_id,   can_adopt  = excluded.can_adopt,
          updated_at   = now();
  end if;

  if b.id is null then
    return jsonb_build_object(
      'ok', true, 'on', false, 'target', 'live',
      'ref', 'swojhmarmaijkshsbeih', 'api_url', null, 'dburl_file', '.medibo/dburl',
      'builds', 0,
      'note', public._c_or('dev_queue.branch_env_live',
              'No build branch is up — this build writes to LIVE.'));
  end if;

  insert into public.build_branch_build (branch_id, project_ref, command_id, agent)
  values (b.branch_id, b.project_ref, p_command_id, p_agent)
  on conflict (branch_id, coalesce(command_id, -1)) do update
    set last_at = now(), calls = build_branch_build.calls + 1
  returning (xmax = 0) into v_new;

  if coalesce(v_new, false) then
    update public.build_branch
       set builds = coalesce(builds, 0) + 1, last_build_at = now()
     where id = b.id
    returning builds into v_builds;
  else
    v_builds := b.builds;
    update public.build_branch set last_build_at = now() where id = b.id;
  end if;

  return jsonb_build_object(
    'ok', true, 'on', true, 'target', 'branch',
    'ref', b.project_ref, 'branch_id', b.branch_id, 'api_url', b.api_url,
    'dburl_file', '.medibo/build_dburl', 'builds', coalesce(v_builds, 0),
    'counted', coalesce(v_new, false),
    'note', replace(public._c_or('dev_queue.branch_env_branch',
            'Build branch {ref} — every migration, test and query goes here; production takes only the merge.'),
            '{ref}', coalesce(b.project_ref, '')));
end $fn$;

-- build_branch_touch keeps its name (runner.sh calls it) but stops being a
-- counter of its own — it is the resolver, with the answer thrown away.
create or replace function public.build_branch_touch(p_command_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb;
begin
  v := public.build_branch_env(null, p_command_id, true);
  return jsonb_build_object('ok', coalesce((v->>'on')::boolean, false),
                            'builds', coalesce((v->>'builds')::int, 0));
end $fn$;

-- ── 5. refusing a production build while a branch is on ────────────────────
create or replace function public.build_branch_refuse(
  p_agent text, p_command_id bigint default null, p_reason text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare b public.build_branch; v_n int;
begin
  perform public._build_branch_guard();
  select * into b from public.build_branch where status = 'on' order by created_at desc limit 1;
  insert into public.build_branch_refusal (agent, command_id, reason, ref, branch_ref)
  values (p_agent, p_command_id, coalesce(nullif(p_reason,''), 'unstated'),
          'swojhmarmaijkshsbeih', b.project_ref);
  select count(*) into v_n from public.build_branch_refusal where at > now() - interval '24 hours';

  insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
  values ('c1570_build_on_live', 'warn', 'build_branch', 'build refused on live',
          jsonb_build_object('agent', p_agent, 'command_id', p_command_id,
                             'reason', coalesce(p_reason,''), 'branch_ref', b.project_ref))
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
        detail = excluded.detail;

  return jsonb_build_object('ok', true, 'refusals_24h', v_n,
    'message', replace(public._c_or('dev_queue.branch_refused',
        'Refused to build on production: a build branch is on. {reason}'),
        '{reason}', coalesce(p_reason,'')));
end $fn$;

-- ── 6. the state the card reads — now carries the counter and the refusals ──
create or replace function public.build_branch_state()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare b public.build_branch; cfg public.build_branch_config;
        v_disp text; v_age text; v_tone text; v_blocked text;
        v_ref_n int; v_ref_at timestamptz; v_builds int; v_off int;
begin
  select * into cfg from public.build_branch_config where id;
  select * into b from public.build_branch
   where status in ('creating','on','deleting') order by created_at desc limit 1;
  v_age := public._build_branch_age_label(coalesce(b.ready_at, b.created_at));
  v_blocked := nullif(trim(coalesce(cfg.blocked_reason, '')), '');
  v_builds := coalesce(b.builds, 0);

  select count(*), max(at) into v_ref_n, v_ref_at
    from public.build_branch_refusal where at > now() - interval '24 hours';

  -- Sessions that are building RIGHT NOW and last reported a non-branch ref.
  select count(*) into v_off
    from public.runner_session_env e
    join public.dev_commands c on c.id = e.command_id and c.status = 'building'
   where coalesce(e.is_branch, false) = false and e.updated_at > now() - interval '30 minutes';

  if coalesce(b.status,'off') = 'on' then
    v_disp := replace(public._c('dev_queue.branch_on'), '{age}', v_age); v_tone := 'completed';
  elsif b.status = 'creating' then
    v_disp := public._c('dev_queue.branch_creating'); v_tone := 'building';
  elsif b.status = 'deleting' then
    v_disp := public._c('dev_queue.branch_deleting'); v_tone := 'building';
  elsif v_blocked is not null then
    v_disp := replace(public._c('dev_queue.branch_blocked'), '{reason}', v_blocked);
    v_tone := 'failed';
  else
    v_disp := public._c('dev_queue.branch_off'); v_tone := 'cancelled';
  end if;

  return jsonb_build_object(
    'ok', true, 'enabled', cfg.enabled,
    'status', coalesce(b.status,'off'),
    'id', b.id, 'branch_id', b.branch_id, 'project_ref', b.project_ref, 'api_url', b.api_url,
    'created_at', b.created_at, 'ready_at', b.ready_at, 'last_build_at', b.last_build_at,
    'builds', v_builds, 'age_label', v_age, 'display', v_disp, 'tone', v_tone,
    'builds_label', case
      when coalesce(b.status,'off') <> 'on' then ''
      when v_builds = 0 then public._c_or('dev_queue.branch_builds_none','No build has used it yet')
      when v_builds = 1 then public._c_or('dev_queue.branch_builds_one','1 build on the branch')
      else replace(public._c_or('dev_queue.branch_builds_many','{n} builds on the branch'), '{n}', v_builds::text)
      end,
    'builds_tone', case when coalesce(b.status,'off') <> 'on' then 'neutral'
                        when v_builds = 0 then 'warning' else 'success' end,
    'on_live_now', v_off,
    'refusals_24h', coalesce(v_ref_n,0), 'last_refusal_at', v_ref_at,
    'refusal_label', case when coalesce(v_ref_n,0) = 0 then ''
      else replace(public._c_or('dev_queue.branch_refusals','{n} build(s) refused on production'),
                   '{n}', v_ref_n::text) end,
    'blocked', v_blocked is not null, 'blocked_reason', v_blocked,
    'last_attempt_at', cfg.last_attempt_at, 'last_attempt_phase', cfg.last_attempt_phase,
    'last_attempt_ok', cfg.last_attempt_ok,
    'idle_delete_min', cfg.idle_delete_min, 'cost_guard_hours', cfg.cost_guard_hours,
    'hourly_usd', cfg.hourly_usd);
end $fn$;

-- ── 7. per-worker kill / restart, one tap ──────────────────────────────────
create or replace function public.runner_action_request(p_agent text, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint; v_open int;
begin
  perform public._dev_guard();
  if p_action not in ('kill','restart') then
    return jsonb_build_object('ok', false,
      'toast', public._c_or('dev_queue.worker_action_unknown','That action does not exist.'));
  end if;
  select count(*) into v_open from public.runner_action_queue
   where agent = p_agent and done_at is null and requested_at > now() - interval '5 minutes';
  if v_open > 0 then
    return jsonb_build_object('ok', false,
      'toast', public._c_or('dev_queue.worker_action_pending','Already asked — waiting for the supervisor.'));
  end if;
  insert into public.runner_action_queue (agent, action, requested_by)
  values (p_agent, p_action, auth.uid()) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'toast', replace(replace(public._c_or('dev_queue.worker_action_sent','{action} queued for {agent}'),
             '{action}', case p_action when 'kill' then public._c_or('dev_queue.worker_kill','Stop')
                                       else public._c_or('dev_queue.worker_restart','Restart') end),
             '{agent}', p_agent));
end $fn$;

create or replace function public.runner_action_pop(p_host text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r public.runner_action_queue;
begin
  perform public._build_branch_guard();
  update public.runner_action_queue q
     set taken_at = now(), taken_by = coalesce(p_host, 'supervisor')
   where q.id = (select id from public.runner_action_queue
                  where done_at is null and taken_at is null
                  order by requested_at limit 1 for update skip locked)
  returning * into r;
  if r.id is null then return jsonb_build_object('ok', true, 'has', false); end if;
  return jsonb_build_object('ok', true, 'has', true, 'id', r.id,
                            'agent', r.agent, 'action', r.action);
end $fn$;

create or replace function public.runner_action_done(p_id bigint, p_result text default 'done')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  perform public._build_branch_guard();
  update public.runner_action_queue set done_at = now(), result = p_result where id = p_id;
  return jsonb_build_object('ok', true);
end $fn$;

-- ── 8. the gauges row — five facts the box already reports, said in words ───
create or replace function public.strip_v3_gauges()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare g jsonb := '[]'::jsonb; ps jsonb; gs jsonb; cu jsonb; wp jsonb;
        v_disk_pct int; v_ram int; v_cpu int; v_quota int; v_qtone text;
        v_verdict text; v_boot_at timestamptz; v_pend int; v_build int;
        v_workers int; v_med numeric; v_hrs numeric;
begin
  select value into ps from dev_runner_config where key = 'pool_state';
  select value into gs from dev_runner_config where key = 'gcp_status';
  select value into cu from dev_runner_config where key = 'claude_usage';
  select value into wp from dev_runner_config where key = 'worker_pool';
  ps := coalesce(ps,'{}'::jsonb); gs := coalesce(gs,'{}'::jsonb);
  cu := coalesce(cu,'{}'::jsonb); wp := coalesce(wp,'{}'::jsonb);

  -- disk
  v_disk_pct := nullif(gs->>'disk_pct','')::int;
  g := g || jsonb_build_array(jsonb_build_object(
    'key','disk', 'label', public._c_or('dev_queue.g_disk','Disk'),
    'value', coalesce(nullif(v_disk_pct::text,'') || '%', '—'),
    'sub',   coalesce(nullif(gs->>'disk',''), ''),
    'tone',  case when v_disk_pct is null then 'neutral'
                  when v_disk_pct >= 90 then 'danger'
                  when v_disk_pct >= 75 then 'warning' else 'success' end));

  -- memory (and the load that goes with it)
  v_ram := nullif(ps->>'ram_pct','')::int; v_cpu := nullif(ps->>'cpu_pct','')::int;
  g := g || jsonb_build_array(jsonb_build_object(
    'key','ram', 'label', public._c_or('dev_queue.g_ram','Memory'),
    'value', coalesce(v_ram::text || '%', '—'),
    'sub',   case when v_cpu is null then ''
             else replace(replace(public._c_or('dev_queue.g_ram_sub','CPU {c}% · load {l}'),
                  '{c}', v_cpu::text), '{l}', coalesce(ps->>'load','—')) end,
    'tone',  case when v_ram is null then 'neutral'
                  when v_ram >= 90 then 'danger'
                  when v_ram >= 75 then 'warning' else 'success' end));

  -- Claude quota: the ACTIVE window, which is the one that can stop a build.
  select max((l->>'percent')::int) into v_quota
    from jsonb_array_elements(coalesce(cu->'limits','[]'::jsonb)) l
   where coalesce((l->>'is_active')::boolean, false);
  if v_quota is null then
    select max((l->>'percent')::int) into v_quota
      from jsonb_array_elements(coalesce(cu->'limits','[]'::jsonb)) l;
  end if;
  v_qtone := case when v_quota is null then 'neutral'
                  when v_quota >= coalesce((wp->>'quota_shrink_pct')::int, 80) then 'danger'
                  when v_quota >= 60 then 'warning' else 'success' end;
  g := g || jsonb_build_array(jsonb_build_object(
    'key','quota', 'label', public._c_or('dev_queue.g_quota','Claude quota'),
    'value', coalesce(v_quota::text || '%', '—'),
    'sub',   coalesce(nullif(public._ist_age(nullif(cu#>>'{five_hour,resets_at}','')::timestamptz),''), ''),
    'tone',  v_qtone));

  -- last boot verdict
  select verdict, at into v_verdict, v_boot_at
    from runner_boot_event order by at desc limit 1;
  g := g || jsonb_build_array(jsonb_build_object(
    'key','boot', 'label', public._c_or('dev_queue.g_boot','Last boot'),
    'value', coalesce(initcap(v_verdict), '—'),
    'sub',   coalesce(public._ist_age(v_boot_at), ''),
    'tone',  case lower(coalesce(v_verdict,'')) when 'green' then 'success'
                  when 'amber' then 'warning' when 'red' then 'danger' else 'neutral' end));

  -- queue forecast: what is waiting, and how long it takes at today's pace
  select count(*) filter (where status='pending'), count(*) filter (where status='building')
    into v_pend, v_build from dev_commands;
  v_workers := greatest(coalesce((wp->>'max_workers')::int, 1), 1);
  select percentile_cont(0.5) within group (
           order by extract(epoch from (finished_at - started_at))/60.0)
    into v_med
    from dev_commands
   where status = 'completed' and finished_at > now() - interval '3 days'
     and started_at is not null and finished_at > started_at;
  v_hrs := case when v_med is null or v_med <= 0 then null
                else round((v_pend * v_med) / (v_workers * 60.0), 1) end;
  g := g || jsonb_build_array(jsonb_build_object(
    'key','forecast', 'label', public._c_or('dev_queue.g_forecast','Queue'),
    'value', replace(public._c_or('dev_queue.g_forecast_v','{n} waiting'), '{n}', coalesce(v_pend,0)::text),
    'sub',   case when v_hrs is null then ''
             else replace(replace(public._c_or('dev_queue.g_forecast_sub','~{h}h at {w} runner(s)'),
                  '{h}', v_hrs::text), '{w}', v_workers::text) end,
    'tone',  case when coalesce(v_pend,0) = 0 then 'success'
                  when coalesce(v_hrs,0) >= 12 then 'warning' else 'neutral' end));
  return g;
end $fn$;

-- ── 9. the worker rows, each with its own two taps ──────────────────────────
create or replace function public.strip_v3_workers()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare ps jsonb; out_j jsonb := '[]'::jsonb; w jsonb; v_pend int;
begin
  select value into ps from dev_runner_config where key = 'pool_state';
  ps := coalesce(ps, '{}'::jsonb);
  for w in select value from jsonb_array_elements(coalesce(ps->'workers','[]'::jsonb)) loop
    select count(*) into v_pend from runner_action_queue
     where agent = w->>'id' and done_at is null;
    out_j := out_j || jsonb_build_array(jsonb_build_object(
      'agent',  w->>'id',
      'label',  coalesce(nullif(w->>'id',''), '—'),
      'status', coalesce(w->>'status',''),
      'title',  coalesce(w->>'title',''),
      'sub',    trim(both ' ·' from concat_ws(' · ', nullif(w->>'meta',''),
                     case when (w->>'command_id') is null then null else '#'||(w->>'command_id') end,
                     nullif(w->>'eta_display',''))),
      'tone',   case coalesce(w->>'status','') when 'building' then 'info'
                     when 'idle' then 'neutral' when 'offline' then 'danger' else 'neutral' end,
      'busy',   v_pend > 0,
      'actions', jsonb_build_array(
        jsonb_build_object('key','restart',
          'label', public._c_or('dev_queue.worker_restart','Restart'), 'tone','neutral',
          'confirm', public._c_or('dev_queue.worker_restart_confirm','Restart this worker? Its command goes back to the queue.')),
        jsonb_build_object('key','kill',
          'label', public._c_or('dev_queue.worker_kill','Stop'), 'tone','danger',
          'confirm', public._c_or('dev_queue.worker_kill_confirm','Stop this worker? Its command goes back to the queue.')))));
  end loop;
  return out_j;
end $fn$;

-- ── 10. one card. The v3 strip absorbs what v2 held (toggles, usage, the
-- worker grid) and adds what v2 could never say: whether a build is actually
-- ON the branch, and what the box's gauges read. dev_queue_screen.dart drops
-- the second card in the same change, so there is one runner card, not two.
--
-- The bug this also fixes: branch_status is build_branch_state().status, whose
-- "up" value is 'on'. This function compared it to 'ready', so with a branch 42
-- minutes old and healthy the card printed "Build branch off" AND raised
-- "Branch wanted for 23 command(s), not created yet". Both were false.
create or replace function public.strip_v3_card()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare d jsonb; a jsonb; wp jsonb; v_blocked jsonb := '[]'::jsonb; v_add text;
        v_max int; v_drain jsonb; v_branch_want jsonb; v_toggles jsonb;
        v_bs jsonb; v_on boolean;
begin
  perform _dev_guard();
  select value into d  from dev_runner_config where key='desired_state';
  select value into wp from dev_runner_config where key='worker_pool';
  select value into v_drain from dev_runner_config where key='drain_after';
  d := coalesce(d,'{}'::jsonb); wp := coalesce(wp,'{}'::jsonb);
  v_drain := coalesce(v_drain,'{}'::jsonb);
  a := strip_v3_actual();
  v_max := greatest(coalesce((wp->>'max_workers')::int, (wp->>'build_semaphore')::int, 3), 1);

  begin v_branch_want := build_branch_decide();
  exception when others then v_branch_want := '{}'::jsonb;
  end;
  begin v_bs := build_branch_state();
  exception when others then v_bs := '{}'::jsonb;
  end;
  v_on := coalesce(a->>'branch_status','') in ('on','ready');

  if coalesce(d->>'vm','off') <> 'on' then
    v_blocked := v_blocked || jsonb_build_array(_c_or('dev_queue.v3_vm_off','The VM is off, so nothing can build'));
  end if;

  if (a->>'rc_sessions') is not null and (a->>'rc_sessions')::int = 0
     and coalesce(d->>'vm','off') = 'on' then
    v_blocked := v_blocked || jsonb_build_array(_c_or('dev_queue.v3_rc_off',''));
  end if;

  if coalesce((v_branch_want->>'want')::boolean,false) and not v_on then
    v_add := replace(_c_or('dev_queue.v3_branch_wanted','Branch wanted for {n} command(s), not created yet'),
               '{n}', (coalesce((v_branch_want->>'pending')::int,0)
                     + coalesce((v_branch_want->>'building')::int,0))::text);
    v_blocked := v_blocked || jsonb_build_array(v_add);
  end if;

  -- A branch that is up and carrying nothing is the #1570 failure, stated.
  if v_on and coalesce((v_bs->>'on_live_now')::int,0) > 0 then
    v_blocked := v_blocked || jsonb_build_array(
      replace(_c_or('dev_queue.v3_branch_bypassed','{n} build(s) running on production while the branch is on'),
              '{n}', (v_bs->>'on_live_now')));
  elsif v_on and coalesce((v_bs->>'builds')::int,0) = 0
        and coalesce((a->>'building')::int,0) > 0 then
    v_blocked := v_blocked || jsonb_build_array(
      _c_or('dev_queue.v3_branch_unused','A build branch is on but no build has used it'));
  end if;

  if coalesce(v_bs->>'refusal_label','') <> '' then
    v_blocked := v_blocked || jsonb_build_array(v_bs->>'refusal_label');
  end if;

  if coalesce(a->>'usage_error','') <> '' then
    v_blocked := v_blocked || jsonb_build_array(
      replace(_c_or('dev_queue.v3_usage_stale','Usage sync failing: {reason}'),
              '{reason}', a->>'usage_error'));
  end if;

  v_toggles := jsonb_build_array(
    jsonb_build_object('key','vm', 'label', _c_or('dev_queue.v3_vm','VM'),
      'desired', coalesce(d->>'vm','off') = 'on',
      'actual',  coalesce((a->>'sessions')::int,0) > 0,
      'actual_label', _c_or('dev_queue.v3_running','running'),
      'not_actual_label', _c_or('dev_queue.v3_not_running','not running'),
      'sub', ''),
    jsonb_build_object('key','claude', 'label', _c_or('dev_queue.v3_start','Start building'),
      'desired', coalesce(d->>'claude','off') = 'on',
      'actual',  coalesce((a->>'building')::int,0) > 0,
      'actual_label', _c_or('dev_queue.v3_running','running'),
      'not_actual_label', _c_or('dev_queue.v3_not_running','not running'),
      'sub', _c_or('dev_queue.v3_start_sub','')),
    jsonb_build_object('key','workflow', 'label', _c_or('dev_queue.v3_parallel','Parallel building'),
      'desired', coalesce(d->>'workflow','off') = 'on',
      'actual',  coalesce((a->>'building')::int,0) > 1,
      'actual_label', _c_or('dev_queue.v3_running','running'),
      'not_actual_label', _c_or('dev_queue.v3_not_running','not running'),
      'sub', replace(_c_or('dev_queue.v3_parallel_sub',''), '{n}', v_max::text)));

  return jsonb_build_object(
    'has', true,
    'title', _c_or('dev_queue.v3_title','Runners'),
    'toggles', v_toggles,
    'gauges', strip_v3_gauges(),
    'workers', strip_v3_workers(),
    'workers_title', _c_or('dev_queue.v3_workers','Workers'),
    'workers_empty', _c_or('dev_queue.v3_workers_empty','No worker has reported yet.'),
    'building_label', case when coalesce((a->>'building')::int,0) = 0
      then _c_or('dev_queue.v3_building_none','Nothing building right now.')
      else replace(_c_or('dev_queue.v3_building','Building {ids}'), '{ids}', a->>'building_ids') end,
    'building_ids', a->>'building_ids',
    'branch_label', case when v_on
        then replace(_c_or('dev_queue.v3_branch_on','Build branch on · {age}'), '{age}', coalesce(a->>'branch_age',''))
      else _c_or('dev_queue.v3_branch_off','Build branch off') end,
    'branch', jsonb_build_object(
      'has',   v_on,
      'label', case when v_on
          then replace(_c_or('dev_queue.v3_branch_on','Build branch on · {age}'), '{age}', coalesce(a->>'branch_age',''))
        else _c_or('dev_queue.v3_branch_off','Build branch off') end,
      'ref',           coalesce(v_bs->>'project_ref',''),
      'builds',        coalesce((v_bs->>'builds')::int, 0),
      'builds_label',  coalesce(v_bs->>'builds_label',''),
      'builds_tone',   coalesce(v_bs->>'builds_tone','neutral'),
      'refusal_label', coalesce(v_bs->>'refusal_label',''),
      'tone', case when not v_on then 'neutral'
                   when coalesce((v_bs->>'builds')::int,0) = 0 then 'warning'
                   else 'success' end),
    'blocked', v_blocked,
    'headline', case when jsonb_array_length(v_blocked) = 0
      then _c_or('dev_queue.v3_ok','Running as asked.')
      else replace(_c_or('dev_queue.v3_blocked','Blocked: {reason}'),
                   '{reason}', v_blocked->>0) end,
    'tone', case when jsonb_array_length(v_blocked) = 0 then 'success' else 'warning' end,
    'drain_label', case when (v_drain->>'id') is null then ''
      else replace(_c_or('dev_queue.v3_drain_on','Draining: will stop after #{id}'), '{id}', v_drain->>'id') end,
    'actual', a,
    'zone', admin_active_zone(),
    'date', admin_active_date());
end $fn$;

-- ── 11. the words ──────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('dev_queue.branch_env_live',       to_jsonb('No build branch is up — this build writes to LIVE.'::text)),
  ('dev_queue.branch_env_branch',     to_jsonb('Build branch {ref} — every migration, test and query goes here; production takes only the merge.'::text)),
  ('dev_queue.branch_builds_none',    to_jsonb('No build has used it yet'::text)),
  ('dev_queue.branch_builds_one',     to_jsonb('1 build on the branch'::text)),
  ('dev_queue.branch_builds_many',    to_jsonb('{n} builds on the branch'::text)),
  ('dev_queue.branch_refusals',       to_jsonb('{n} build(s) refused on production'::text)),
  ('dev_queue.branch_refused',        to_jsonb('Refused to build on production: a build branch is on. {reason}'::text)),
  ('dev_queue.v3_branch_bypassed',    to_jsonb('{n} build(s) running on production while the branch is on'::text)),
  ('dev_queue.v3_branch_unused',      to_jsonb('A build branch is on but no build has used it'::text)),
  ('dev_queue.v3_workers',            to_jsonb('Workers'::text)),
  ('dev_queue.v3_workers_empty',      to_jsonb('No worker has reported yet.'::text)),
  ('dev_queue.worker_kill',           to_jsonb('Stop'::text)),
  ('dev_queue.worker_restart',        to_jsonb('Restart'::text)),
  ('dev_queue.worker_kill_confirm',   to_jsonb('Stop this worker? Its command goes back to the queue.'::text)),
  ('dev_queue.worker_restart_confirm',to_jsonb('Restart this worker? Its command goes back to the queue.'::text)),
  ('dev_queue.worker_action_sent',    to_jsonb('{action} queued for {agent}'::text)),
  ('dev_queue.worker_action_pending', to_jsonb('Already asked — waiting for the supervisor.'::text)),
  ('dev_queue.worker_action_unknown', to_jsonb('That action does not exist.'::text)),
  ('dev_queue.g_disk',                to_jsonb('Disk'::text)),
  ('dev_queue.g_ram',                 to_jsonb('Memory'::text)),
  ('dev_queue.g_ram_sub',             to_jsonb('CPU {c}% · load {l}'::text)),
  ('dev_queue.g_quota',               to_jsonb('Claude quota'::text)),
  ('dev_queue.g_boot',                to_jsonb('Last boot'::text)),
  ('dev_queue.g_forecast',            to_jsonb('Queue'::text)),
  ('dev_queue.g_forecast_v',          to_jsonb('{n} waiting'::text)),
  ('dev_queue.g_forecast_sub',        to_jsonb('~{h}h at {w} runner(s)'::text)),
  ('dev_queue.v3_running',            to_jsonb('running'::text)),
  ('dev_queue.v3_not_running',        to_jsonb('not running'::text)),
  ('dev_queue.v3_action_go',          to_jsonb('Do it'::text))
on conflict (key) do nothing;

grant execute on function public.build_branch_env(text, bigint, boolean) to service_role;
grant execute on function public.build_branch_refuse(text, bigint, text)  to service_role;
grant execute on function public.runner_action_pop(text)                  to service_role;
grant execute on function public.runner_action_done(bigint, text)         to service_role;
grant execute on function public.runner_action_request(text, text)        to authenticated, service_role;
grant execute on function public.strip_v3_gauges()                        to authenticated, service_role;
grant execute on function public.strip_v3_workers()                       to authenticated, service_role;

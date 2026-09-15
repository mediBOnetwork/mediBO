-- CHANGE #1662 — Remote Control sessions must stop churning.
--
-- SYMPTOM (5 Sep 19:25 IST): ~20 Claude-app notifications in two minutes —
-- runner-N connected → standby → disconnected → connected, over and over, for
-- slots that were not building anything.
--
-- THREE CAUSES, ALL VISIBLE IN dev_agent_session:
--
--   1. THE 'stale' RELEASE WAS A GUESS, NOT A FACT. dev_agent_register swept
--      EVERY row whose last_seen_at was older than 15 minutes, on every claim by
--      any slot. But a runner only beats at the top of its loop and on a
--      terminal state — so a slot in the middle of a 40-minute build never beat,
--      went "stale", was released, and re-registered as a NEW row on its next
--      claim. runner-3 session $26 did exactly that four times in five hours
--      while its tmux pane never once died.
--   2. NOBODY EVER SENT A PID. Every row on this box has pid NULL, so there was
--      nothing to check the guess against even in principle.
--   3. A RELEASED SESSION ID CAME BACK AS A NEW ROW. Same host, same tmux
--      session id, same pane — a fresh insert, a fresh "registered" event.
--
-- THE FIX IS TO MOVE THE DECISION TO WHERE THE EVIDENCE IS. Pids live on the
-- box, so the box reports which sessions are genuinely alive
-- (dev_agent_sweep) and that report both beats the live ones and releases the
-- gone ones as 'pane_gone'. SQL keeps only a HARD ttl (default 60 min) for a
-- host that has stopped reporting at all, released as 'stale_hard' so the two
-- causes are never again confused in the history.
--
-- And because an open/close storm is a fact worth refusing rather than
-- describing, dev_rc_gate caps opens per agent per window and says
-- "Remote Control flapping — <reason>" for the card to print verbatim.

create table if not exists dev_rc_event (
  id          bigserial primary key,
  agent       text not null,
  host        text,
  kind        text not null,           -- open | close | blocked | flapping
  reason      text,
  created_at  timestamptz not null default now()
);
create index if not exists dev_rc_event_agent_at_idx on dev_rc_event(agent, created_at desc);
-- RLS on with no policy, exactly like dev_agent_session and dev_commands: the
-- only readers are SECURITY DEFINER RPCs and service_role. Agent names and
-- hosts are not for a logged-in customer to read.
alter table dev_rc_event enable row level security;

alter table dev_agent_session add column if not exists rc_opens int not null default 0;

-- ── config defaults (change with pool_set, no deploy) ──────────────────────
update dev_runner_config
   set value = jsonb_set(value, '{remote_control}',
        coalesce(value->'remote_control','{}'::jsonb)
        || jsonb_build_object(
             'flap_max',       coalesce(value->'remote_control'->'flap_max',       to_jsonb(2)),
             'flap_window_min',coalesce(value->'remote_control'->'flap_window_min',to_jsonb(10)),
             'stale_min',      coalesce(value->'remote_control'->'stale_min',      to_jsonb(5)),
             'hard_stale_min', coalesce(value->'remote_control'->'hard_stale_min', to_jsonb(60))))
 where key = 'worker_pool';

create or replace function public._rc_cfg(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((value->'remote_control'->>p_key)::numeric, p_default)
    from dev_runner_config where key = 'worker_pool'
$$;

-- ── REGISTRATION IS IDEMPOTENT (spec 2) ────────────────────────────────────
-- A slot with a live, reachable session must not re-register or rename, and no
-- event is emitted when nothing changed. `changed` is the caller's cue to stay
-- quiet: refreshing an existing row is not news.
create or replace function public.dev_agent_register(
  p_agent text, p_session_id text, p_tmux text default null,
  p_host text default null, p_pid integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_live record; v_mine record; v_hard int;
begin
  perform _dev_guard();
  if coalesce(btrim(p_agent),'') = '' or coalesce(btrim(p_session_id),'') = '' then
    return jsonb_build_object('ok', false, 'label', 'agent and session_id are required');
  end if;

  -- The ONLY TTL release left in SQL. It is deliberately long and named
  -- 'stale_hard': it is for a host that stopped reporting entirely, never for a
  -- build that simply took longer than a heartbeat window (#1662).
  v_hard := greatest(_rc_cfg('hard_stale_min', 60)::int, 15);
  update dev_agent_session set released_at = now(), release_reason = 'stale_hard'
   where released_at is null and last_seen_at < now() - make_interval(mins => v_hard);

  -- Same session id, already live → refresh in place. Nothing changed.
  select * into v_mine from dev_agent_session
   where agent = p_agent and session_id = p_session_id and released_at is null limit 1;
  if found then
    update dev_agent_session set last_seen_at = now(),
           tmux_session = coalesce(p_tmux, tmux_session), host = coalesce(p_host, host),
           pid = coalesce(p_pid, pid)
     where id = v_mine.id;
    return jsonb_build_object('ok', true, 'refreshed', true, 'changed', false,
      'agent', p_agent, 'session_id', p_session_id, 'label', p_agent || ' still registered');
  end if;

  select * into v_live from dev_agent_session
   where agent = p_agent and released_at is null limit 1;
  if found then
    perform dev_agent_incident_log('duplicate_agent_id', p_agent, p_session_id, null,
      'session ' || p_session_id || ' asked for ' || p_agent ||
      ', already held by ' || v_live.session_id);
    return jsonb_build_object('ok', false, 'taken', true, 'changed', false, 'agent', p_agent,
      'held_by', v_live.session_id, 'held_since', v_live.registered_at,
      'label', p_agent || ' is already registered to another live session',
      'next_step', 'Start this session under a free agent id, or release the other session first.');
  end if;

  -- The SAME pane coming back (same session id, previously released) re-opens
  -- its own row rather than minting a new one. A row per reconnect is what made
  -- the history read like a storm.
  select * into v_mine from dev_agent_session
   where agent = p_agent and session_id = p_session_id and released_at is not null
   order by registered_at desc limit 1;
  if found and v_mine.released_at > now() - interval '6 hours' then
    update dev_agent_session
       set released_at = null, release_reason = null, last_seen_at = now(),
           tmux_session = coalesce(p_tmux, tmux_session), host = coalesce(p_host, host),
           pid = coalesce(p_pid, pid)
     where id = v_mine.id;
    return jsonb_build_object('ok', true, 'reopened', true, 'changed', true,
      'agent', p_agent, 'session_id', p_session_id,
      'label', p_agent || ' re-attached to its existing session');
  end if;

  insert into dev_agent_session(agent, session_id, tmux_session, host, pid)
  values (p_agent, p_session_id, p_tmux, p_host, p_pid);
  return jsonb_build_object('ok', true, 'registered', true, 'changed', true, 'agent', p_agent,
    'session_id', p_session_id, 'label', p_agent || ' registered');
end $$;

-- ── THE PANE IS THE EVIDENCE (spec 4) ──────────────────────────────────────
-- The supervisor runs every 20s on the box that owns the panes. It sends the
-- session ids it can actually see, with their pids. Those get beaten (so a long
-- build can never go stale again) and anything else on that host, past the soft
-- window, is released as 'pane_gone' — a fact, not a missed beat.
create or replace function public.dev_agent_sweep(p_host text, p_alive jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_beat int := 0; v_rel int := 0; v_soft int; v_ids text[];
begin
  perform _dev_guard();
  if coalesce(btrim(p_host),'') = '' then
    return jsonb_build_object('ok', false, 'label', 'host is required');
  end if;
  v_soft := greatest(_rc_cfg('stale_min', 5)::int, 2);

  select coalesce(array_agg(x->>'session_id'), '{}')
    into v_ids from jsonb_array_elements(coalesce(p_alive,'[]'::jsonb)) x
   where coalesce(x->>'session_id','') <> '';

  update dev_agent_session s set last_seen_at = now(),
         pid = coalesce(nullif(a.pid,0), s.pid),
         tmux_session = coalesce(nullif(a.tmux,''), s.tmux_session)
    from (select x->>'session_id' as sid, (x->>'pid')::int as pid, x->>'tmux' as tmux
            from jsonb_array_elements(coalesce(p_alive,'[]'::jsonb)) x) a
   where s.session_id = a.sid and s.released_at is null;
  get diagnostics v_beat = row_count;

  update dev_agent_session set released_at = now(), release_reason = 'pane_gone'
   where released_at is null and host = p_host
     and not (session_id = any(v_ids))
     and last_seen_at < now() - make_interval(mins => v_soft);
  get diagnostics v_rel = row_count;

  return jsonb_build_object('ok', true, 'beat', v_beat, 'released', v_rel,
    'alive', coalesce(array_length(v_ids,1),0), 'stale_min', v_soft);
end $$;

-- ── FLAP GATE (spec 3) ─────────────────────────────────────────────────────
-- Asked BEFORE every spawn, and it draws the line the symptom actually needs
-- drawn: a session opened FOR A BUILD is never refused (refusing it would cost
-- a build to save a notification, and spec 5 wants exactly one card per active
-- build), while a HEAL open — the supervisor deciding an idle slot looks
-- unreachable and reopening it — is capped at flap_max inside flap_window_min.
-- That is precisely the population Om watched churn: slots that were not
-- building anything.
create or replace function public.dev_rc_gate(
  p_agent text, p_host text default null, p_kind text default 'open', p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_max int; v_win int; v_n int; v_kind text;
begin
  perform _dev_guard();
  v_kind := coalesce(nullif(btrim(p_kind),''), 'open');
  v_max  := greatest(_rc_cfg('flap_max', 2)::int, 1);
  v_win  := greatest(_rc_cfg('flap_window_min', 10)::int, 1);

  if v_kind <> 'open' then
    insert into dev_rc_event(agent, host, kind, reason) values (p_agent, p_host, v_kind, p_reason);
    return jsonb_build_object('ok', true, 'allowed', true, 'flapping', false, 'kind', v_kind);
  end if;

  select count(*) into v_n from dev_rc_event
   where agent = p_agent and kind = 'open'
     and created_at > now() - make_interval(mins => v_win);

  if v_n >= v_max then
    insert into dev_rc_event(agent, host, kind, reason)
    values (p_agent, p_host, 'blocked',
            coalesce(p_reason, v_n || ' reopens in ' || v_win || ' min'));
    return jsonb_build_object('ok', true, 'allowed', false, 'flapping', true, 'kind', v_kind,
      'opens', v_n, 'max', v_max, 'window_min', v_win,
      'reason', p_agent || ' reopened ' || v_n || ' times in ' || v_win || ' min',
      'label', 'Remote Control flapping — ' || p_agent || ' reopened ' || v_n ||
               ' times in ' || v_win || ' min');
  end if;

  insert into dev_rc_event(agent, host, kind, reason) values (p_agent, p_host, 'open', p_reason);
  return jsonb_build_object('ok', true, 'allowed', true, 'flapping', false, 'kind', v_kind,
    'opens', v_n + 1, 'max', v_max, 'window_min', v_win);
end $$;

-- ── THE BANNER (spec 3, rendered verbatim) ─────────────────────────────────
create or replace function public.dev_rc_health()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_win int; v_max int; v_worst record; v_n int;
begin
  v_win := greatest(_rc_cfg('flap_window_min', 10)::int, 1);
  v_max := greatest(_rc_cfg('flap_max', 2)::int, 1);

  select e.agent,
         count(*) filter (where e.kind = 'open')    as opens,
         count(*) filter (where e.kind = 'blocked') as blocked
    into v_worst
    from dev_rc_event e
   where e.created_at > now() - make_interval(mins => v_win)
   group by e.agent
   having count(*) filter (where e.kind = 'blocked') > 0
      or  count(*) filter (where e.kind = 'open') > v_max
   order by count(*) filter (where e.kind = 'blocked') desc, count(*) desc
   limit 1;

  if not found then
    return jsonb_build_object('has', false);
  end if;

  v_n := greatest(v_worst.opens, v_max);
  return jsonb_build_object(
    'has', true,
    'rc_banner', 'Remote Control flapping — ' || v_worst.agent || ' reopened ' ||
                 v_n || ' times in ' || v_win || ' min; reopening is paused',
    'rc_banner_tone', 'warning',
    'agent', v_worst.agent, 'opens', v_worst.opens, 'blocked', v_worst.blocked,
    'window_min', v_win, 'max', v_max);
end $$;

-- ── the banner rides the payload the worker card already reads ─────────────
create or replace function public.dev_ctl_get()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb; v_auth jsonb; v_branch jsonb; v_rc jsonb;
begin
  v := public.dev_ctl_get_core();
  begin v_ctx := public.dev_context_metrics_cached(60);
  exception when others then v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  begin v_blocked := public.runner_blocked_badge();
  exception when others then v_blocked := jsonb_build_object('has', false);
  end;
  begin v_disk := public.runner_disk_state();
  exception when others then v_disk := jsonb_build_object('has', false);
  end;
  begin v_auth := public.claude_auth_status();
  exception when others then v_auth := jsonb_build_object('has', false);
  end;
  begin v_branch := public.build_branch_card();
  exception when others then v_branch := jsonb_build_object('has', false);
  end;
  -- CHANGE #1662 — Remote Control health sits INSIDE pool.state, next to
  -- shrink_display, because that is the card that already draws a banner.
  begin v_rc := public.dev_rc_health();
  exception when others then v_rc := jsonb_build_object('has', false);
  end;
  if coalesce((v->'health'->>'ok')::boolean, false) then
    v := jsonb_set(v, '{health,metrics}',
           coalesce(v->'health'->'metrics','[]'::jsonb)
           || jsonb_build_array(public.runner_health_disk_metric()));
  end if;
  if coalesce((v_rc->>'has')::boolean, false) and v ? 'pool' then
    v := jsonb_set(v, '{pool,state}',
           coalesce(v->'pool'->'state','{}'::jsonb)
           || jsonb_build_object('rc_banner', v_rc->>'rc_banner',
                                 'rc_banner_tone', v_rc->>'rc_banner_tone'));
  end if;

  return v || jsonb_build_object('context', v_ctx, 'blocked', v_blocked, 'disk', v_disk,
                                 'claude_auth', v_auth, 'build_branch', v_branch,
                                 'rc_health', v_rc);
end $$;

grant execute on function public.dev_agent_sweep(text, jsonb) to service_role;
grant execute on function public.dev_rc_gate(text, text, text, text) to service_role;
grant execute on function public.dev_rc_health() to service_role, authenticated;
grant execute on function public._rc_cfg(text, numeric) to service_role;

-- CHANGE #1268 — One runner = one building command, and one agent id = one live
-- session. Two independent failures shared a root cause: a slot could be handed
-- a second spec while still building (runner-4: #850 then #985), and two live
-- sessions could both register as runner-1, so the steering bridge typed one
-- session's replies into the other (#1016 on claude-5, #1055 on claude-6).
-- Four guards, each able to stop it alone: the runner lockfile, this claim
-- refusal, the session registry, and the unique index Om already added.

alter table public.dev_commands add column if not exists claim_session_id text;

create table if not exists public.dev_agent_session (
  id            bigserial primary key,
  agent         text        not null,
  session_id    text        not null,
  tmux_session  text,
  host          text,
  pid           integer,
  command_id    bigint,
  registered_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  released_at   timestamptz,
  release_reason text
);
create unique index if not exists dev_agent_session_one_live
  on public.dev_agent_session (agent) where released_at is null;
create unique index if not exists dev_agent_session_one_live_sid
  on public.dev_agent_session (session_id) where released_at is null;

create table if not exists public.dev_agent_incident (
  id         bigserial primary key,
  kind       text not null,
  agent      text,
  session_id text,
  command_id bigint,
  detail     text,
  created_at timestamptz not null default now()
);

create or replace function public.dev_agent_incident_log(
  p_kind text, p_agent text, p_session_id text, p_command_id bigint, p_detail text)
returns bigint language plpgsql security definer set search_path=public as $fn$
declare v_id bigint;
begin
  insert into dev_agent_incident(kind, agent, session_id, command_id, detail)
  values (p_kind, p_agent, p_session_id, p_command_id, left(coalesce(p_detail,''), 2000))
  returning id into v_id;
  return v_id;
end $fn$;

-- Registration is the gate the supervisor reads: an agent id belongs to exactly
-- one LIVE session. A repeat call from the SAME session is a refresh, not a
-- conflict, so a restarted loop inside one session never locks itself out.
create or replace function public.dev_agent_register(
  p_agent text, p_session_id text, p_tmux text default null,
  p_host text default null, p_pid integer default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_live record; v_ttl int := 15;
begin
  perform _dev_guard();
  if coalesce(btrim(p_agent),'') = '' or coalesce(btrim(p_session_id),'') = '' then
    return jsonb_build_object('ok', false, 'label', 'agent and session_id are required');
  end if;

  -- A session that stopped beating for longer than the TTL is not alive; free
  -- its id rather than stranding the slot forever after a crash.
  update dev_agent_session set released_at = now(), release_reason = 'stale'
   where released_at is null and last_seen_at < now() - make_interval(mins => v_ttl);

  select * into v_live from dev_agent_session
   where agent = p_agent and released_at is null limit 1;

  if found and v_live.session_id <> p_session_id then
    perform dev_agent_incident_log('duplicate_agent_id', p_agent, p_session_id, null,
      'session ' || p_session_id || ' asked for ' || p_agent ||
      ', already held by ' || v_live.session_id);
    return jsonb_build_object('ok', false, 'taken', true, 'agent', p_agent,
      'held_by', v_live.session_id, 'held_since', v_live.registered_at,
      'label', p_agent || ' is already registered to another live session',
      'next_step', 'Start this session under a free agent id, or release the other session first.');
  end if;

  if found then
    update dev_agent_session set last_seen_at = now(),
           tmux_session = coalesce(p_tmux, tmux_session), host = coalesce(p_host, host),
           pid = coalesce(p_pid, pid)
     where id = v_live.id;
    return jsonb_build_object('ok', true, 'refreshed', true, 'agent', p_agent,
      'session_id', p_session_id, 'label', p_agent || ' still registered');
  end if;

  insert into dev_agent_session(agent, session_id, tmux_session, host, pid)
  values (p_agent, p_session_id, p_tmux, p_host, p_pid);
  return jsonb_build_object('ok', true, 'registered', true, 'agent', p_agent,
    'session_id', p_session_id, 'label', p_agent || ' registered');
end $fn$;

create or replace function public.dev_agent_release(
  p_session_id text, p_reason text default 'exit')
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_n int;
begin
  perform _dev_guard();
  update dev_agent_session set released_at = now(), release_reason = coalesce(p_reason,'exit')
   where session_id = p_session_id and released_at is null;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'released', v_n);
end $fn$;

create or replace function public.dev_agent_beat(
  p_session_id text, p_command_id bigint default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
begin
  perform _dev_guard();
  update dev_agent_session set last_seen_at = now(),
         command_id = coalesce(p_command_id, command_id)
   where session_id = p_session_id and released_at is null;
  return jsonb_build_object('ok', true);
end $fn$;

-- The screen prints this verbatim: one row per live session, plus whatever the
-- guards have caught. Every label, tone and sub-line is decided here.
create or replace function public.dev_agent_sessions_status()
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_rows jsonb; v_inc jsonb; v_dupes int; v_live int;
begin
  select count(*) into v_live from dev_agent_session where released_at is null;

  select coalesce(jsonb_agg(x order by x->>'agent'), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'agent', s.agent,
      'session_id', s.session_id,
      'label', s.agent,
      'sub', case when c.id is null then 'Idle — no open build'
                  else 'Building #' || c.id || ' · ' || left(coalesce(c.title,''), 60) end,
      'value', case when c.id is null then 'idle' else '#' || c.id end,
      'tone', case when c.id is null then 'neutral'
                   when s.last_seen_at < now() - interval '15 minutes' then 'warning'
                   else 'success' end,
      'beat', to_char(s.last_seen_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
      'tmux', coalesce(s.tmux_session, '—')
    ) as x
    from dev_agent_session s
    left join dev_commands c on c.claimed_by = s.agent and c.status = 'building'
    where s.released_at is null
  ) t;

  select count(*) into v_dupes from dev_agent_incident
   where created_at > now() - interval '24 hours';

  select coalesce(jsonb_agg(jsonb_build_object(
      'label', i.kind, 'sub', left(coalesce(i.detail,''), 120),
      'value', to_char(i.created_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
      'tone', 'danger') order by i.created_at desc), '[]'::jsonb)
    into v_inc
    from (select * from dev_agent_incident order by created_at desc limit 5) i;

  return jsonb_build_object(
    'ok', true,
    'has', v_live > 0 or jsonb_array_length(v_inc) > 0,
    'title', 'Runner sessions',
    'sub', v_live || ' live · one command each',
    'rows', v_rows,
    'incidents', v_inc,
    'incident_label', case when v_dupes = 0 then 'No conflicts in 24h'
                           else v_dupes || ' conflict(s) caught in 24h' end,
    'incident_tone', case when v_dupes = 0 then 'success' else 'warning' end,
    'footnote', 'One agent id per live session; one building command per agent.');
end $fn$;

CREATE OR REPLACE FUNCTION public.dev_cmd_claim(p_agent text, p_routes text[] DEFAULT NULL::text[], p_prefer_area text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_hold bigint; v_hold_t text; v jsonb; v_res jsonb; v_blocked int; v_adm jsonb; v_scope jsonb;
        v_fact boolean; v_msg text;
BEGIN
  PERFORM _dev_guard();

  -- CHANGE #1268 — ONE RUNNER, ONE BUILDING COMMAND. A slot that still holds an
  -- open build is refused here, before it can load a second spec into the same
  -- context (runner-4 held #850 and was handed #985; two specs, one context,
  -- wrong token attribution). The DB index dev_commands_one_build_per_agent is
  -- the backstop; this is the polite answer the claim loop reads.
  SELECT dc.id, dc.title INTO v_hold, v_hold_t
    FROM dev_commands dc WHERE dc.claimed_by = p_agent AND dc.status = 'building'
    ORDER BY dc.started_at LIMIT 1;
  IF v_hold IS NOT NULL THEN
    RETURN jsonb_build_object('empty', true, 'busy', true, 'holding', v_hold,
      'label', 'Already building #' || v_hold,
      'detail', coalesce(v_hold_t,''),
      'next_step', 'Finish #' || v_hold || ' with complete/fail/ask, or release it, then claim again.');
  END IF;
  IF (_sec_cfg()->>'frozen')::boolean THEN RETURN jsonb_build_object('empty',true,'frozen',true); END IF;
  IF (sec_check_budget()->>'over')::boolean THEN RETURN jsonb_build_object('empty',true,'budget_paused',true); END IF;

  -- CMD #368 — admission control. Refuse BEFORE the runner boots a context, so
  -- an overloaded instance costs a 45 s sleep instead of an hour of crawling.
  v_adm := db_admission_check(p_agent);
  IF coalesce((v_adm->>'admit')::boolean, true) = false THEN
    RETURN jsonb_build_object('empty', true, 'db_busy', true,
      'retry_after_seconds', coalesce((v_adm->>'retry_after_seconds')::int, 45),
      'reason', v_adm->>'label', 'admission', v_adm);
  END IF;

  SELECT coalesce((value->'chain'->>'require_lease')::boolean, true) INTO v_fact
    FROM dev_runner_config WHERE key='worker_pool';
  v_fact := coalesce(v_fact, true);

  UPDATE dev_commands dc SET status='building', claimed_by=p_agent, claim_session_id=(SELECT s.session_id FROM dev_agent_session s WHERE s.agent=p_agent AND s.released_at IS NULL ORDER BY s.registered_at DESC LIMIT 1), started_at=now(), heartbeat_at=now(),
         resume_count = resume_count + CASE WHEN dc.steps_done > 0 THEN 1 ELSE 0 END
  WHERE dc.id = (
    SELECT c.id FROM dev_commands c
    WHERE c.status='pending'
      AND (p_routes IS NULL OR c.route = ANY(p_routes))
      AND NOT EXISTS (SELECT 1 FROM dev_commands d WHERE d.id = ANY(c.depends_on) AND d.status <> 'completed')
      -- CHANGE #428 — a REAL conflict only: two exact, non-shared, equal paths,
      -- and (by default) against what the other build actually HOLDS, not what
      -- it was guessed to touch. Anything looser and one broad prediction
      -- freezes the whole queue.
      AND NOT EXISTS (
        SELECT 1 FROM dev_commands b
        WHERE b.status = 'building' AND b.id <> c.id
          AND coalesce(array_length(
                dev_paths_conflict(
                  CASE WHEN v_fact THEN dev_cmd_leased_footprint(b.id)
                       ELSE dev_cmd_footprint(b.id) END,
                  c.predicted_files), 1), 0) > 0)
    ORDER BY c.urgent DESC,
             (p_prefer_area IS NOT NULL AND c.area IS NOT DISTINCT FROM p_prefer_area) DESC,
             c.priority, c.id
    FOR UPDATE OF c SKIP LOCKED LIMIT 1
  )
  RETURNING to_jsonb(dc) INTO v;
  IF v IS NULL THEN
    SELECT count(*) INTO v_blocked FROM dev_commands c
     WHERE c.status='pending' AND (p_routes IS NULL OR c.route = ANY(p_routes));
    SELECT value#>>'{}' INTO v_msg FROM ui_copy
     WHERE key = CASE WHEN v_blocked > 0 THEN 'dev_queue.claim_blocked' ELSE 'dev_queue.claim_empty' END;
    RETURN jsonb_build_object('empty', true, 'pending_blocked', v_blocked,
      'reason', coalesce(v_msg, CASE WHEN v_blocked > 0
        THEN 'Every pending command is held behind a file another build is holding right now.'
        ELSE 'Queue empty.' END));
  END IF;
  v_res := _dev_resume_block(v);
  -- CMD #368 — grade the QA depth from real scope the moment the row is owned,
  -- and hand the runner the guardrails its session is already running under.
  v_scope := dev_qa_scope((v->>'id')::bigint);
  RETURN v || jsonb_build_object('resume', v_res,
                                 'is_resume', coalesce((v_res->>'is_resume')::boolean, false),
                                 'qa_scope', v_scope,
                                 'session_guard', db_guard_check(), 'run_flags', dev_cmd_run_flags(v->>'model', v->>'effort'));
END $function$;

drop function if exists public.dev_cmd_heartbeat(bigint,text,bigint,bigint,text,text,text,integer,integer,text,timestamptz,boolean,text);

CREATE OR REPLACE FUNCTION public.dev_cmd_heartbeat(p_id bigint, p_log_tail text DEFAULT NULL::text, p_tokens_in bigint DEFAULT 0, p_tokens_out bigint DEFAULT 0, p_model text DEFAULT NULL::text, p_effort text DEFAULT NULL::text, p_mode text DEFAULT NULL::text, p_eta_total_s integer DEFAULT NULL::integer, p_eta_left_s integer DEFAULT NULL::integer, p_eta_note text DEFAULT NULL::text, p_agent_turn_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_pane_alive boolean DEFAULT NULL::boolean, p_rc_session text DEFAULT NULL::text, p_session_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_claim_sess text; v_owner text; v_cfg jsonb; v_rates jsonb; v_model text; v_mode text; v_in_usd numeric; v_out_usd numeric; v_fx numeric;
        v_budget bigint; v_extra bigint; v_tokens bigint; v_class text;
BEGIN
  PERFORM _dev_guard();

  -- CHANGE #1268 — a beat may only come from the session that CLAIMED the row.
  -- Two sessions registered as the same agent used to beat (and steer) the same
  -- build; the loser now learns it immediately instead of writing to a row that
  -- is not its own.
  IF p_session_id IS NOT NULL THEN
    SELECT dc.claim_session_id, dc.claimed_by INTO v_claim_sess, v_owner
      FROM dev_commands dc WHERE dc.id = p_id;
    IF v_claim_sess IS NOT NULL AND v_claim_sess <> p_session_id THEN
      PERFORM dev_agent_incident_log('heartbeat_wrong_session', v_owner, p_session_id, p_id,
        'beat from ' || p_session_id || ' but #' || p_id || ' was claimed by session ' || v_claim_sess);
      RETURN jsonb_build_object('ok', false, 'wrong_session', true, 'command_id', p_id,
        'expected_session', v_claim_sess, 'got_session', p_session_id,
        'label', 'This session does not own #' || p_id);
    END IF;
  END IF;
  SELECT value INTO v_cfg FROM dev_runner_config WHERE key='model_rates';
  UPDATE dev_commands SET
    heartbeat_at = now(),
    build_log = right(build_log || coalesce(E'\n'||p_log_tail,''), 200000),
    cost_input_tokens = cost_input_tokens + p_tokens_in,
    cost_output_tokens = cost_output_tokens + p_tokens_out,
    -- CHANGE #656: the REQUEST is never overwritten; the observation lands in actual_*.
    actual_model  = coalesce(CASE WHEN p_model LIKE 'claude-%' THEN p_model END, actual_model),
    actual_effort = coalesce(CASE WHEN p_effort IN ('low','medium','high','xhigh','max','extra') THEN p_effort END, actual_effort),
    price_mode = coalesce(p_mode, price_mode, 'standard'),
    eta_total_s = coalesce(p_eta_total_s, eta_total_s),
    eta_left_s = coalesce(p_eta_left_s, eta_left_s),
    eta_note = coalesce(p_eta_note, eta_note),
    -- CHANGE #1023 — liveness of the AGENT, not of the bash loop reporting it.
    agent_alive_at   = coalesce(p_agent_turn_at, agent_alive_at),
    agent_pane_alive = coalesce(p_pane_alive, agent_pane_alive),
    agent_rc_session = coalesce(nullif(p_rc_session,''), agent_rc_session),
    -- any fresh agent turn clears the amber chip immediately
    agent_silent_flagged = CASE WHEN p_agent_turn_at IS NOT NULL THEN false ELSE agent_silent_flagged END,
    agent_silent_at      = CASE WHEN p_agent_turn_at IS NOT NULL THEN NULL  ELSE agent_silent_at END
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'kill', true, 'reason','row not building'); END IF;

  SELECT coalesce(nullif(actual_model,''), model), price_mode, cost_input_tokens+cost_output_tokens, token_budget_extra, size_class
    INTO v_model, v_mode, v_tokens, v_extra, v_class FROM dev_commands WHERE id=p_id;
  v_rates := coalesce(v_cfg->'models'->v_model, v_cfg->'models'->'claude-opus-5', v_cfg->'models'->'claude-opus-4-8');
  v_fx := coalesce((v_cfg->>'usd_inr')::numeric, 88);
  IF v_mode='fast' AND v_rates ? 'fast_in' THEN v_in_usd:=(v_rates->>'fast_in')::numeric; v_out_usd:=(v_rates->>'fast_out')::numeric;
  ELSE v_in_usd:=(v_rates->>'in')::numeric; v_out_usd:=(v_rates->>'out')::numeric; END IF;
  UPDATE dev_commands SET cost_inr = round((cost_input_tokens*v_in_usd + cost_output_tokens*v_out_usd) * v_fx / 1000000.0, 2) WHERE id=p_id;

  v_budget := coalesce((SELECT (value->'token_budget_by_class'->>coalesce(v_class,'normal'))::bigint FROM dev_runner_config WHERE key='worker_pool'), 1500000)
              + coalesce(v_extra,0);
  IF v_tokens > v_budget THEN
    UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
      needs_input_question='Token budget for a '||coalesce(v_class,'normal')||' build hit ('||v_tokens||' > '||v_budget||'). Reply yes for one more window, or refine/split the spec.'
    WHERE id=p_id AND status='building';
    INSERT INTO dev_command_messages (command_id, sender, body) VALUES (p_id,'system','⛔ Auto-stopped: '||coalesce(v_class,'normal')||' token budget '||v_budget||' exceeded ('||v_tokens||').');
    PERFORM _lease_release_internal(p_id);
    PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',p_id::text,'reason','token budget ('||coalesce(v_class,'normal')||')','tokens',v_tokens::text), NULL, NULL);
    RETURN jsonb_build_object('ok', true, 'kill', true, 'reason','token_budget');
  END IF;
  RETURN jsonb_build_object('ok', true, 'model', v_model, 'mode', coalesce(v_mode,'standard'));
END $function$;


grant execute on function public.dev_agent_register(text,text,text,text,integer) to service_role;
grant execute on function public.dev_agent_release(text,text) to service_role;
grant execute on function public.dev_agent_beat(text,bigint) to service_role;
grant execute on function public.dev_agent_incident_log(text,text,text,bigint,text) to service_role;
grant execute on function public.dev_agent_sessions_status() to service_role, authenticated;

-- Same shape as dev_commands: RLS on, no policies. Nothing reaches these tables
-- except the security-definer RPCs above and service_role, which bypasses RLS.
-- Without this the registry would be world-readable through PostgREST.
alter table public.dev_agent_session  enable row level security;
alter table public.dev_agent_incident enable row level security;

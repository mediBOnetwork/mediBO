-- CHANGE #1856 — A MERGE-LANE PARK MUST HOLD THE SESSION, NOT RESTART IT.
--
-- #1848 burned 9.7M tokens because it parked and was resumed COLD four times
-- (a db restart, then merge-lane entries 883, 884 and 886). Every one of those
-- resumes re-read the whole context from scratch. The wait itself was free;
-- the RE-ENTRY was not.
--
-- #1819 gave the waiter two modes: sleep (under sleep_max_s, 60 s) and park
-- (anything longer — release the runner and end the session). There was nothing
-- in between, so a 17-minute merge-lane queue — the single commonest blocker in
-- the fleet, and one that clears by itself — always took the expensive door.
--
-- This adds the middle mode, HOLD:
--   free  — already clear, carry on.
--   sleep — under sleep_max_s: one blocking shell sleep.
--   hold  — under hold_max_s and the runner is not wanted elsewhere: the row
--           stays BUILDING, claimed by the same agent, and the session idles in
--           chunked blocking sleeps. Idling costs nothing; a cold resume costs
--           a whole context.
--   park  — long blocker, a lease (held by another BUILD, i.e. minutes of real
--           work), or a runner another command needs: release, cold resume.
--
-- and it makes the difference COUNTABLE: hold_count / cold_resume_count on the
-- command, a 'wait_hold' context event beside the existing 'wait_park', a
-- message log that says which one happened, and two rows on the Waiting lane.
-- =============================================================================

-- ── 1. The counters. A cold resume is a cost, so it gets a number. ───────────
-- First, a gap this build fell into: #1817 uses dev_commands.wait_started_tokens
-- in five functions but its migration only ever added wait_turns / wait_turn_tokens /
-- wait_polls — the column was added by hand on production, so every REPLAY of the
-- migration set (a build branch, a rebuilt environment) got functions that abort
-- with 'column wait_started_tokens does not exist'. Repaired here, idempotently.
alter table dev_commands add column if not exists wait_started_tokens bigint;

alter table dev_commands add column if not exists hold_count        int not null default 0;
alter table dev_commands add column if not exists cold_resume_count int not null default 0;
alter table dev_commands add column if not exists hold_total_s      int not null default 0;

comment on column dev_commands.hold_count is
  'CHANGE #1856 — times this command waited with its session HELD (no context re-read).';
comment on column dev_commands.cold_resume_count is
  'CHANGE #1856 — times this command was parked and had to be resumed COLD (full context re-read).';
comment on column dev_commands.hold_total_s is
  'CHANGE #1856 — seconds spent holding, i.e. waiting without releasing the runner.';

-- ── 2. Config. Every threshold is a knob, none is a literal in a script. ─────
update dev_runner_config
   set value = jsonb_set(value, '{wait_gate}',
         coalesce(value->'wait_gate','{}'::jsonb)
         || jsonb_build_object(
              'hold_enabled',     true,
              'hold_max_s',       1800,
              'hold_kinds',       jsonb_build_array('merge','db','rpc','batch','other'),
              'hold_turn_tokens', 25000,
              'note', 'CHANGE #1856 — free / sleep (< sleep_max_s) / hold (< hold_max_s, session kept alive) / park (long, a lease, or the runner is needed elsewhere). turn_tokens is the sleeping allowance; hold_turn_tokens is the holding one, because a chunk boundary legitimately re-sends the context once.'))
 where key = 'worker_pool';

-- ── 3. Config reader — one place, so nothing re-derives a threshold. ─────────
create or replace function public._dev_wait_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
           'poll_s',           coalesce((value->'wait_gate'->>'poll_s')::int, 60),
           'max_wait_s',       coalesce((value->'wait_gate'->>'max_wait_s')::int, 540),
           'sleep_max_s',      coalesce((value->'wait_gate'->>'sleep_max_s')::int, 60),
           'turn_tokens',      coalesce((value->'wait_gate'->>'turn_tokens')::bigint, 2000),
           'hold_enabled',     coalesce((value->'wait_gate'->>'hold_enabled')::boolean, true),
           'hold_max_s',       coalesce((value->'wait_gate'->>'hold_max_s')::int, 1800),
           'hold_turn_tokens', coalesce((value->'wait_gate'->>'hold_turn_tokens')::bigint, 25000),
           'hold_kinds',       coalesce(value->'wait_gate'->'hold_kinds',
                                        jsonb_build_array('merge','db','rpc','batch','other')),
           'park_enabled',     coalesce((value->'wait_gate'->>'park_enabled')::boolean, true),
           'grace',            coalesce((value->>'waiting_token_grace')::bigint, 150000))
    from dev_runner_config where key = 'worker_pool'
$fn$;

-- ── 4. "Is this runner needed by another command?" ───────────────────────────
-- The one reason to tear a session down even for a SHORT blocker. A held
-- session occupies a worker slot; that is only wasteful when the queue has
-- claimable work and no free slot to put it in.
create or replace function public._dev_wait_runner_needed(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_cap int; v_building int; v_pending int;
begin
  select coalesce((value->>'cap')::int, 6) into v_cap
    from dev_runner_config where key = 'worker_pool';

  select count(*) into v_building from dev_commands where status = 'building';

  -- Claimable = pending, not fenced behind its own blocker, and not chained
  -- behind a command that has not finished. A row nobody can claim is not a
  -- reason to give up a runner.
  select count(*) into v_pending
    from dev_commands d
   where d.status = 'pending'
     and coalesce(d.wait_state,'') <> 'parked'
     and d.id <> p_id
     and not exists (
       select 1 from unnest(coalesce(d.depends_on, '{}'::bigint[])) dep(id)
        join dev_commands b on b.id = dep.id
       where b.status in ('pending','building'));

  return jsonb_build_object(
    'needed',   v_pending > 0 and v_building >= coalesce(v_cap,6),
    'pending',  v_pending,
    'building', v_building,
    'cap',      coalesce(v_cap,6),
    'why',      case when v_pending > 0 and v_building >= coalesce(v_cap,6)
                     then format('%s command(s) waiting for a runner and all %s slots are busy', v_pending, v_cap)
                     else format('%s free slot(s) — nobody is waiting for this runner', greatest(coalesce(v_cap,6) - v_building, 0)) end);
end $fn$;

-- ── 5. Begin / continue a HOLD. Re-entrant, exactly like dev_wait_begin. ─────
create or replace function public._dev_wait_hold_begin(
  p_id bigint, p_agent text, p_kind text, p_reason text, p_blocker jsonb, p_eta_s int)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_tok bigint; v_cont boolean; v_chunk int; v_held int;
begin
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  v_cfg   := _dev_wait_cfg();
  v_tok   := coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0);
  v_chunk := (v_cfg->>'max_wait_s')::int;
  -- A continuation of the SAME hold keeps wait_since and the token mark, so the
  -- burn that is measured — and killed on — is the burn of the WHOLE wait.
  v_cont  := coalesce(r.wait_state,'') = 'holding' and coalesce(r.wait_kind,'') = coalesce(p_kind,'other');
  v_held  := case when v_cont then greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int) else 0 end;

  update dev_commands
     set wait_state          = 'holding',
         wait_kind           = coalesce(p_kind,'other'),
         wait_reason         = p_reason,
         wait_blocker        = coalesce(p_blocker,'{}'::jsonb),
         wait_since          = case when v_cont then coalesce(wait_since, now()) else now() end,
         -- For a lane the POLL decides (merge/lease read the lane itself); for
         -- everything else this deadline IS the condition, so it is the eta,
         -- not the chunk — a 2-minute db wait must not be held for 9.
         wait_until          = case when v_cont then wait_until
                                    else now() + (greatest(coalesce(p_eta_s,120), 5) || ' seconds')::interval end,
         wait_count          = case when v_cont then coalesce(wait_count,0) else coalesce(wait_count,0) + 1 end,
         hold_count          = case when v_cont then coalesce(hold_count,0) else coalesce(hold_count,0) + 1 end,
         wait_started_tokens = case when v_cont then coalesce(wait_started_tokens, v_tok) else v_tok end,
         wait_turn_tokens    = case when v_cont then coalesce(wait_turn_tokens, v_tok) else v_tok end,
         wait_turns          = case when v_cont then coalesce(wait_turns,0) else 0 end,
         wait_polls          = case when v_cont then coalesce(wait_polls,0) else 0 end,
         -- Holding is ALIVE and it is deliberate: the heartbeat and the agent's
         -- liveness both stay fresh, or the 15-minute release sweep would undo
         -- the very thing this change exists to do.
         heartbeat_at        = now(),
         agent_alive_at      = now(),
         agent_silent_flagged = false,
         eta_note            = 'holding: ' || p_reason
   where id = p_id;

  if not v_cont then
    insert into dev_context_event (command_id, agent, kind, ok, detail)
    values (p_id, coalesce(p_agent, r.claimed_by), 'wait_hold', true,
            jsonb_build_object('mode','hold', 'wait_kind', coalesce(p_kind,'other'),
                               'reason', p_reason, 'blocker', coalesce(p_blocker,'{}'::jsonb),
                               'eta_s', p_eta_s, 'tokens_at_start', v_tok,
                               'steps_done', coalesce(r.steps_done,0)));
    insert into dev_command_messages (command_id, sender, body)
    values (p_id, 'system', replace(replace(
      _c_or('dev_queue.wait_hold_msg',
            '⏸ Holding — {reason}. The session is kept alive and idles until the blocker clears, so it resumes with NO context re-read (checked every {after}s).'),
      '{reason}', p_reason), '{after}', (v_cfg->>'poll_s')));
  end if;

  return jsonb_build_object('ok', true, 'continuing', v_cont, 'held_s', v_held,
                            'chunk_s', v_chunk, 'poll_s', (v_cfg->>'poll_s')::int);
end $fn$;

-- ── 6. THE DOOR. free / sleep / hold / park, decided in one place. ───────────
create or replace function public.dev_wait_enter(
  p_id bigint, p_agent text, p_kind text, p_reason text default null, p_blocker jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_free jsonb; v_eta int; v_sleep int;
        v_reason text; v_park jsonb; v_hold jsonb; v_need jsonb; v_held int;
        v_holdable boolean; v_why text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', true, 'mode', 'stop',
      'line', format('#%s is %s, not building — stop here and let the queue hand it out again.', p_id, r.status));
  end if;

  v_cfg    := _dev_wait_cfg();
  v_reason := coalesce(nullif(p_reason,''), 'queued in the ' || coalesce(p_kind,'lane') || ' lane');
  v_free   := _dev_wait_free(p_id, p_kind, p_blocker);

  -- Never sleep on nothing. A blocker that is already gone is a straight carry-on.
  if coalesce((v_free->>'free')::boolean, false) and coalesce(p_kind,'other') in ('merge','lease') then
    -- A hold that ends is an END, not an abandonment: close it so the seconds
    -- and the burn land on the row instead of leaking into the next wait.
    if coalesce(r.wait_state,'') = 'holding' then perform dev_wait_end(p_id, v_free->>'why'); end if;
    return jsonb_build_object('ok', true, 'mode', 'free', 'reason', v_free->>'why',
      'line', format('Not blocked — %s. Carry on from your next step.', v_free->>'why'));
  end if;

  v_eta   := _dev_wait_eta_s(p_id, p_kind, p_blocker);
  v_sleep := (v_cfg->>'sleep_max_s')::int;

  -- SHORT: one blocking shell sleep inside a single Bash call. Nothing changes.
  if v_eta <= v_sleep and coalesce((v_cfg->>'park_enabled')::boolean, true) then
    perform dev_wait_begin(p_id, p_agent, p_kind, v_reason, p_blocker);
    return jsonb_build_object('ok', true, 'mode', 'sleep',
      'sleep_s', least(greatest(v_eta, 5), v_sleep),
      'poll_s',  least((v_cfg->>'poll_s')::int, v_sleep),
      'eta_s',   v_eta,
      'line', format('Short wait (~%ss) — sleeping in the shell, no session released.', v_eta));
  end if;

  if not coalesce((v_cfg->>'park_enabled')::boolean, true) then
    perform dev_wait_begin(p_id, p_agent, p_kind, v_reason, p_blocker);
    return jsonb_build_object('ok', true, 'mode', 'sleep',
      'sleep_s', (v_cfg->>'max_wait_s')::int,
      'poll_s',  (v_cfg->>'poll_s')::int, 'eta_s', v_eta,
      'line', 'Park is off (wait_gate.park_enabled=false) — sleeping instead.');
  end if;

  -- ── MIDDLE: HOLD. The whole point of CHANGE #1856. ────────────────────────
  v_held := case when coalesce(r.wait_state,'') = 'holding'
                  and coalesce(r.wait_kind,'') = coalesce(p_kind,'other')
                 then greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int)
                 else 0 end;
  v_need := _dev_wait_runner_needed(p_id);

  v_holdable := coalesce((v_cfg->>'hold_enabled')::boolean, true)
            and (v_cfg->'hold_kinds') ? coalesce(p_kind,'other')
            and v_eta <= (v_cfg->>'hold_max_s')::int
            and v_held < (v_cfg->>'hold_max_s')::int
            and not coalesce((v_need->>'needed')::boolean, false);

  v_why := case
    when not coalesce((v_cfg->>'hold_enabled')::boolean, true) then 'holding is off'
    when not ((v_cfg->'hold_kinds') ? coalesce(p_kind,'other'))
      then format('a %s blocker is held by another build, not by the clock', coalesce(p_kind,'other'))
    when v_eta > (v_cfg->>'hold_max_s')::int
      then format('~%ss is longer than a session should idle', v_eta)
    when v_held >= (v_cfg->>'hold_max_s')::int
      then format('already held %s', _fmt_dur(v_held))
    when coalesce((v_need->>'needed')::boolean, false) then v_need->>'why'
    else 'holdable' end;

  if v_holdable then
    v_hold := _dev_wait_hold_begin(p_id, p_agent, p_kind, v_reason, p_blocker, v_eta);
    return jsonb_build_object('ok', true, 'mode', 'hold', 'eta_s', v_eta,
      'sleep_s', (v_cfg->>'max_wait_s')::int,
      'poll_s',  (v_cfg->>'poll_s')::int,
      'held_s',  v_held,
      'runner_needed', v_need,
      'line', format('Holding — %s (~%ss). The session stays alive and idles; %s. Do NOT plan, summarise or re-read anything.',
                     v_reason, v_eta,
                     case when v_held > 0 then 'held ' || _fmt_dur(v_held) || ' so far, nothing re-read'
                          else 'no context will be re-read' end));
  end if;

  -- ── LONG / NEEDED ELSEWHERE: park and RELEASE. This is a COLD resume. ─────
  if coalesce(r.wait_state,'') = 'holding' then perform dev_wait_end(p_id, 'hold expired — parking'); end if;
  v_park := dev_cmd_park(p_id, coalesce(p_kind,'other'), v_reason, coalesce(p_blocker,'{}'::jsonb), v_eta);
  return jsonb_build_object('ok', true, 'mode', 'park', 'eta_s', v_eta, 'park', v_park,
    'cold', true, 'park_why', v_why, 'runner_needed', v_need,
    'line', coalesce(v_park->>'agent_line',
      format('Parked — %s (~%ss). The runner is free; this row resumes itself at its saved step.', v_reason, v_eta)));
end $fn$;

-- ── 7. Poll / end / burn-check must all know 'holding'. ──────────────────────
create or replace function public._dev_wait_turn_log(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_now bigint; v_mark bigint; v_delta bigint;
        v_allow bigint; v_mode text;
begin
  select * into r from dev_commands where id = p_id;
  if not found or coalesce(r.wait_state,'') not in ('sleeping','parked','holding') then
    return jsonb_build_object('waiting', false);
  end if;
  v_cfg  := _dev_wait_cfg();
  v_now  := coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0);
  v_mark := coalesce(r.wait_turn_tokens, r.wait_started_tokens, v_now);
  v_delta := v_now - v_mark;
  -- A HELD session wakes once per chunk on purpose — that wake-up re-sends the
  -- context once and is the mechanism, not a bug. It gets its own, larger
  -- allowance; a sleeping or parked row keeps the strict one.
  v_mode  := case when coalesce(r.wait_state,'') = 'holding' then 'hold' else 'cold' end;
  v_allow := case when v_mode = 'hold' then (v_cfg->>'hold_turn_tokens')::bigint
                  else (v_cfg->>'turn_tokens')::bigint end;
  if v_delta <= v_allow then
    return jsonb_build_object('waiting', true, 'delta', v_delta, 'logged', false, 'mode', v_mode);
  end if;

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, r.claimed_by, 'wait_turn', false,
          jsonb_build_object(
            'delta', v_delta, 'mode', v_mode, 'allowance', v_allow,
            'wait_kind', coalesce(r.wait_kind,'unknown'),
            'wait_reason', coalesce(r.wait_reason,''),
            'waited_s', greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int),
            'burn_total', v_now - coalesce(r.wait_started_tokens, v_now)));
  update dev_commands
     set wait_turn_tokens = v_now, wait_turns = coalesce(wait_turns,0) + 1
   where id = p_id;
  return jsonb_build_object('waiting', true, 'delta', v_delta, 'logged', true, 'mode', v_mode);
end $fn$;

create or replace function public.dev_wait_poll(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_f jsonb; v_free boolean; v_why text;
        v_waited int; v_burn bigint; v_hold text; v_args text; v_holding boolean;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', true, 'free', true, 'reason', 'command is ' || r.status,
                              'status', r.status);
  end if;
  if coalesce(r.wait_state,'') not in ('sleeping','holding') then
    return jsonb_build_object('ok', true, 'free', true, 'reason', 'not asleep any more');
  end if;
  v_holding := coalesce(r.wait_state,'') = 'holding';

  v_cfg := _dev_wait_cfg();
  perform _dev_wait_turn_log(p_id);

  if coalesce(r.wait_kind,'other') in ('merge','lease') then
    v_f    := _dev_wait_free(p_id, r.wait_kind, r.wait_blocker);
    v_free := coalesce((v_f->>'free')::boolean,false);
    v_why  := v_f->>'why';
  else
    v_free := r.wait_until is not null and now() >= r.wait_until;
    v_why  := case when v_free then 'wait window elapsed' else 'waiting out ' || coalesce(r.wait_kind,'other') end;
  end if;

  v_waited := greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int);
  update dev_commands
     set wait_polls    = coalesce(wait_polls,0) + 1,
         heartbeat_at  = now(),          -- asleep is ALIVE
         -- ...and HELD is alive in the stronger sense: the session itself is
         -- still there, so the agent-silence flag must not fire on it either.
         agent_alive_at       = case when v_holding then now() else agent_alive_at end,
         agent_silent_flagged = case when v_holding then false else agent_silent_flagged end
   where id = p_id;
  select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) - coalesce(wait_started_tokens,0)
    into v_burn from dev_commands where id = p_id;

  v_args := case coalesce(r.wait_kind,'other')
              when 'merge' then coalesce(' ' || (r.wait_blocker->>'entry_id'), '')
              when 'lease' then coalesce((select ' ' || string_agg(value #>> '{}', ' ')
                                            from jsonb_array_elements(coalesce(r.wait_blocker->'paths','[]'::jsonb))), '')
              else coalesce(' ' || quote_literal(r.wait_reason), '')
            end;
  v_hold := format('Still %s after %s — %s. %s again: devcmd.sh wait %s %s%s. Do NOT plan, summarise or re-read anything.',
                   case when v_holding then 'holding' else 'waiting' end,
                   _fmt_dur(v_waited), v_why,
                   case when v_holding then 'Hold' else 'Sleep' end,
                   p_id, coalesce(r.wait_kind,'other'), v_args);

  return jsonb_build_object('ok', true, 'free', v_free, 'reason', v_why,
    'mode', case when v_holding then 'hold' else 'sleep' end,
    'holding', v_holding,
    'polls', coalesce(r.wait_polls,0) + 1, 'waited_s', v_waited,
    'waited_label', _fmt_dur(v_waited),
    'burn', greatest(0, coalesce(v_burn,0)), 'turns', coalesce(r.wait_turns,0),
    'hold_line', v_hold,
    'poll_s', (v_cfg->>'poll_s')::int);
end $fn$;

create or replace function public.dev_wait_end(p_id bigint, p_outcome text default 'free')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_secs int; v_burn bigint; v_line text;
        v_next text; v_holding boolean;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if coalesce(r.wait_state,'') not in ('sleeping','holding') then
    return jsonb_build_object('ok', true, 'resume_line', 'Not asleep — carry on.', 'waited_s', 0, 'burn', 0);
  end if;
  v_holding := coalesce(r.wait_state,'') = 'holding';

  v_cfg  := _dev_wait_cfg();
  v_secs := greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int);
  v_burn := greatest(0, (coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0))
                        - coalesce(r.wait_started_tokens,0));

  select s->>'title' into v_next
    from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
   where coalesce(s->>'status','pending') <> 'done'
   order by coalesce((s->>'n')::int, 999) limit 1;

  v_line := format('%s after %s — %s. %s%s; nothing else changed, do not re-read the spec.',
                   case when coalesce(r.wait_kind,'') = 'merge' then 'Merge lane free'
                        when coalesce(r.wait_kind,'') = 'lease' then 'Lease free'
                        else 'Wait over' end,
                   _fmt_dur(v_secs),
                   coalesce(nullif(p_outcome,''), 'free'),
                   case when v_holding then 'Carry straight on — the session was held, so nothing was re-read'
                        else 'Resume' end,
                   coalesce(' at step: ' || v_next, ''));

  update dev_commands
     set wait_state          = null,
         wait_until          = null,
         wait_started_tokens = null,
         wait_turn_tokens    = null,
         wait_total_s        = coalesce(wait_total_s,0) + v_secs,
         hold_total_s        = coalesce(hold_total_s,0) + case when v_holding then v_secs else 0 end,
         heartbeat_at        = now(),
         eta_note            = case when coalesce(eta_note,'') ~ '^(asleep|holding):' then '' else eta_note end
   where id = p_id;

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, r.claimed_by, 'wait_end',
          v_burn <= (case when v_holding then (v_cfg->>'hold_turn_tokens')::bigint
                          else (v_cfg->>'turn_tokens')::bigint end),
          jsonb_build_object('seconds', v_secs, 'burn', v_burn,
                             'mode', case when v_holding then 'hold' else 'sleep' end,
                             'polls', coalesce(r.wait_polls,0), 'turns', coalesce(r.wait_turns,0),
                             'wait_kind', coalesce(r.wait_kind,'other'), 'outcome', coalesce(p_outcome,'free')));

  return jsonb_build_object('ok', true, 'resume_line', v_line, 'waited_s', v_secs,
    'waited_label', _fmt_dur(v_secs), 'burn', v_burn,
    'mode', case when v_holding then 'hold' else 'sleep' end,
    'turns', coalesce(r.wait_turns,0), 'polls', coalesce(r.wait_polls,0));
end $fn$;

create or replace function public._wait_burn_check(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_grace bigint; v_waiting boolean; v_burn bigint;
begin
  select * into r from dev_commands where id = p_id;
  if not found or r.status <> 'building' then return jsonb_build_object('kill', false); end if;

  select coalesce((value->>'waiting_token_grace')::bigint, 150000) into v_grace
    from dev_runner_config where key = 'worker_pool';

  v_waiting := coalesce(r.wait_state, '') in ('parked','sleeping','holding')
    or coalesce(r.eta_note, '') ~* '(asleep|holding|merge lane|deploy lane|waiting on the batch|waiting on entry|lease|queue waiter)';

  if not v_waiting then
    if r.wait_started_tokens is not null then
      update dev_commands set wait_started_tokens = null, wait_turn_tokens = null where id = p_id;
    end if;
    return jsonb_build_object('kill', false, 'waiting', false);
  end if;

  if r.wait_started_tokens is null then
    update dev_commands
       set wait_started_tokens = coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0),
           wait_turn_tokens    = coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0)
     where id = p_id;
    return jsonb_build_object('kill', false, 'waiting', true, 'burn', 0);
  end if;

  perform _dev_wait_turn_log(p_id);

  v_burn := (coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0)) - r.wait_started_tokens;
  if v_burn > v_grace then
    update dev_commands
       set status = 'needs_input', claimed_by = NULL, wait_started_tokens = NULL, wait_turn_tokens = NULL,
           needs_input_kind = 'waiting_burn',
           needs_input_question = format('Stopped: this build spent %s tokens while WAITING (%s). Waiting must cost nothing — use `devcmd.sh wait <id> <kind>`, which sleeps in the shell. Reply yes to hand it out again once the lane is free.',
                                          v_burn, coalesce(nullif(r.eta_note,''), 'a lane/lease'))
     where id = p_id and status = 'building';
    insert into dev_command_messages(command_id, sender, body)
    values (p_id, 'system', format('⛔ Killed while waiting — %s tokens burned doing nothing (grace %s). %s',
                                    v_burn, v_grace, coalesce(nullif(r.eta_note,''), '')));
    perform _lease_release_internal(p_id);
    perform _audit('system','waiting_burn_kill', p_id::text,
                   jsonb_build_object('burn', v_burn, 'grace', v_grace, 'note', r.eta_note));
    return jsonb_build_object('kill', true, 'reason', 'waiting_burn', 'burn', v_burn);
  end if;

  return jsonb_build_object('kill', false, 'waiting', true, 'burn', v_burn);
end $fn$;

-- ── 8. A park is a COLD RESUME, and it now says so and counts itself. ───────
create or replace function public.dev_cmd_park(
  p_id bigint, p_kind text, p_reason text, p_blocker jsonb default '{}'::jsonb,
  p_retry_after_s integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_after int; v_label text; v_tok bigint; v_next text; v_line text; v_cold int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building', 'status', r.status);
  end if;
  v_after := coalesce(p_retry_after_s,
    (select retry_after_s from dev_fail_rule where kind = p_kind and enabled order by ord limit 1), 120);
  v_label := coalesce(nullif(p_reason,''),
    (select label from dev_fail_rule where kind = p_kind and enabled order by ord limit 1),
    _c_or('dev_queue.wait_generic','Waiting on a blocker'));
  v_tok  := coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0);
  v_cold := coalesce(r.cold_resume_count,0) + 1;

  select s->>'title' into v_next
    from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
   where coalesce(s->>'status','pending') <> 'done'
   order by coalesce((s->>'n')::int, 999) limit 1;

  update dev_commands set
    status       = 'pending',
    claimed_by   = null,
    released_at  = now(),
    release_reason = 'parked: ' || v_label,
    wait_state   = 'parked',
    wait_kind    = coalesce(nullif(p_kind,''), 'other'),
    wait_reason  = v_label,
    wait_blocker = coalesce(p_blocker, '{}'::jsonb),
    wait_since   = now(),
    wait_until   = now() + (v_after || ' seconds')::interval,
    wait_count   = coalesce(wait_count,0) + 1,
    -- CHANGE #1856 — every park IS a cold resume: the session is torn down and
    -- whoever picks the row up next re-reads the whole context. Counting them
    -- is how that cost stops being invisible.
    cold_resume_count = v_cold,
    wait_started_tokens = v_tok,
    wait_turn_tokens    = v_tok,
    eta_note     = 'parked: ' || v_label
  where id = p_id;

  perform _lease_release_internal(p_id);

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, coalesce(r.claimed_by,'unknown'), 'wait_park', true,
          jsonb_build_object('mode', 'cold', 'wait_kind', coalesce(p_kind,'other'), 'reason', v_label,
                             'blocker', coalesce(p_blocker,'{}'::jsonb),
                             'retry_after_s', v_after, 'tokens_at_park', v_tok,
                             'cold_resume_count', v_cold,
                             'steps_done', coalesce(r.steps_done,0)));

  perform _audit('system','dev_cmd_park', p_id::text,
    jsonb_build_object('kind', p_kind, 'reason', v_label, 'blocker', p_blocker,
                       'mode', 'cold', 'cold_resume_count', v_cold,
                       'retry_after_s', v_after, 'released_agent', r.claimed_by));
  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(replace(replace(
    _c_or('dev_queue.wait_msg','⏸ Parked (COLD resume #{cold}) — {reason}. The work is committed and untouched; it resumes automatically when the blocker clears (checked every {after}s), but the next session re-reads the whole context.'),
    '{reason}', v_label), '{after}', v_after::text), '{cold}', v_cold::text));

  v_line := format('Parked — %s. Your leases and this runner are released; #%s is back in the queue at its own priority and resumes itself%s. This is COLD resume #%s: the next session re-reads everything. STOP NOW: finish this turn with no further tool calls, no summary and no re-read.',
                   v_label, p_id, coalesce(' at step: ' || v_next, ''), v_cold);

  return jsonb_build_object('ok', true, 'parked', true, 'id', p_id, 'mode', 'cold',
    'kind', p_kind, 'reason', v_label, 'retry_after_s', v_after,
    'released_agent', r.claimed_by, 'next_step', v_next, 'cold_resume_count', v_cold,
    'agent_line', v_line,
    'note', 'the row is pending-but-fenced; dev_cmd_claim skips it until the blocker clears');
end $fn$;

-- ── 9. The Waiting lane says hold vs cold, in the backend's own words. ───────
create or replace function public.dev_wait_report(p_hours integer default 24)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_cfg jsonb; v_base jsonb; v_rows jsonb := '[]'::jsonb; k text; v_kinds text[];
        v_since timestamptz; v_ev record; v_b jsonb; v_kills int; v_parks int;
        v_tot bigint := 0; v_n int := 0; v_med numeric; v_prev numeric;
        v_tone text; v_sub text; v_grace bigint; v_names jsonb;
        v_landed timestamptz; v_kills_since int; v_holds int; v_held_s bigint; v_cold_cmds int;
begin
  perform _dev_guard();
  v_since := now() - make_interval(hours => greatest(coalesce(p_hours,24),1));
  select value->'wait_gate', coalesce((value->>'waiting_token_grace')::bigint,150000)
    into v_cfg, v_grace from dev_runner_config where key='worker_pool';
  v_base := coalesce(v_cfg->'baseline', '{}'::jsonb);
  v_kinds := array['merge','lease','db','rpc','grant','other'];
  v_names := jsonb_build_object('merge','Merge lane waits','lease','File lease waits',
                                'db','Database lane waits','rpc','RPC / timeout waits',
                                'grant','Journey grant waits','other','Other waits');

  foreach k in array v_kinds loop
    select count(*) filter (where e.kind in ('wait_end','wait_resume'))            as ends,
           coalesce(sum((e.detail->>'burn')::bigint) filter (where e.kind in ('wait_end','wait_resume')),0) as burn,
           coalesce(max((e.detail->>'burn')::bigint) filter (where e.kind in ('wait_end','wait_resume')),0) as worst,
           count(*) filter (where e.kind = 'wait_park')                            as parks,
           count(*) filter (where e.kind = 'wait_hold')                            as holds
      into v_ev
      from dev_context_event e
     where e.at >= v_since
       and e.kind in ('wait_end','wait_resume','wait_park','wait_hold')
       and coalesce(e.detail->>'wait_kind','other') = k;

    v_b := coalesce(v_base->k, '{}'::jsonb);
    v_tot := v_tot + coalesce(v_ev.burn,0);
    v_n   := v_n + coalesce(v_ev.ends,0);
    v_tone := case when coalesce(v_ev.worst,0) > 5000 then 'danger'
                   when coalesce(v_ev.worst,0) > 0    then 'warning'
                   else 'success' end;
    v_sub := format('%s wait(s) · %s held · %s cold · worst %s tokens · before: %s',
                    coalesce(v_ev.ends,0), coalesce(v_ev.holds,0), coalesce(v_ev.parks,0),
                    coalesce(v_ev.worst,0), coalesce(v_b->>'label','not measured'));
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key', k,
      'label', coalesce(v_names->>k, initcap(k) || ' waits'),
      'value', coalesce(v_ev.burn,0)::text || ' tokens',
      'sub', v_sub,
      'tone', v_tone));
  end loop;

  select count(*) into v_kills from dev_commands
   where needs_input_kind = 'waiting_burn' and coalesce(finished_at, heartbeat_at, created_at) >= v_since;
  v_landed := coalesce((v_base->>'landed_at')::timestamptz, now());
  select count(*) into v_kills_since from dev_commands
   where needs_input_kind = 'waiting_burn' and coalesce(finished_at, heartbeat_at, created_at) >= v_landed;
  select count(*) into v_parks from dev_context_event
   where kind = 'wait_park' and at >= v_since;
  select count(*) into v_holds from dev_context_event
   where kind = 'wait_hold' and at >= v_since;
  select coalesce(sum((detail->>'seconds')::bigint),0) into v_held_s from dev_context_event
   where kind = 'wait_end' and at >= v_since and detail->>'mode' = 'hold';
  select count(distinct command_id) into v_cold_cmds from dev_context_event
   where kind = 'wait_park' and at >= v_since;

  select percentile_cont(0.5) within group (order by secs) into v_med from (
    select extract(epoch from (finished_at - started_at)) as secs
      from dev_commands where status='completed' and finished_at is not null and started_at is not null
     order by finished_at desc limit 20) a;
  select percentile_cont(0.5) within group (order by secs) into v_prev from (
    select extract(epoch from (finished_at - started_at)) as secs
      from dev_commands where status='completed' and finished_at is not null and started_at is not null
     order by finished_at desc offset 20 limit 20) b;

  v_rows := v_rows || jsonb_build_array(
    jsonb_build_object('key','kills','label','Killed while waiting',
      'value', v_kills::text,
      'sub', format('%s since park-and-release landed (%s) · grace %s tokens · target 0',
                    v_kills_since, to_char(v_landed at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST', v_grace),
      'tone', case when v_kills_since = 0 then 'success' else 'danger' end),
    -- CHANGE #1856 — the two numbers the change exists to move.
    jsonb_build_object('key','holds','label','Held — session kept alive',
      'value', v_holds::text,
      'sub', format('%s of idling with no context re-read · a hold is free, a cold resume is a whole context',
                    _fmt_dur(v_held_s::int)),
      'tone', case when v_holds > 0 then 'success' else 'neutral' end),
    jsonb_build_object('key','cold','label','Cold resumes — context re-read',
      'value', v_parks::text,
      'sub', format('across %s command(s) · each one tore a session down and re-read everything · target 0 for lane and db waits',
                    v_cold_cmds),
      'tone', case when v_parks = 0 then 'success'
                   when v_holds >= v_parks then 'warning' else 'danger' end),
    jsonb_build_object('key','speed','label','Median claim → complete',
      'value', coalesce(_fmt_dur(v_med::int), '—'),
      'sub', format('previous 20: %s', coalesce(_fmt_dur(v_prev::int),'—')),
      'tone', case when v_med is null or v_prev is null then 'neutral'
                   when v_med <= v_prev * 1.05 then 'success' else 'warning' end));

  return jsonb_build_object(
    'has', true,
    'title', 'Waiting economy',
    'chip', format('%s tokens across %s wait(s)', v_tot, v_n),
    'chip_tone', case when v_tot <= 5000 * greatest(v_n,1) then 'success' else 'danger' end,
    'since_line', format('Last %sh · sleep under %ss · hold under %ss (session kept) · park beyond it',
                         greatest(coalesce(p_hours,24),1),
                         coalesce((v_cfg->>'sleep_max_s')::int,60),
                         coalesce((v_cfg->>'hold_max_s')::int,1800)),
    'rows', v_rows,
    'footnote', 'A wait must cost under 5,000 tokens. A hold costs nothing; a cold resume costs a whole context re-read, which is why they are counted separately.');
end $fn$;

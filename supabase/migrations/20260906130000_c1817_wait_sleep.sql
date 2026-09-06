-- replay-target: control-plane
--
-- THE PRODUCTION PASS RUNS ON THIS FILE TOO — SO THE FILE SAYS NO ITSELF.
-- `-- replay-target: control-plane` above only ADDS the control-plane pass;
-- scripts/migration_replay.sh applies every pending file to production first,
-- whatever it declares. #1761 moved dev_commands, dev_context_event and
-- dev_journeys to the control plane and dropped them from production, so this
-- file died there on `relation "dev_commands" does not exist` — at CREATE time,
-- because plpgsql resolves `dev_commands%rowtype` when the function is compiled.
-- It took batch 599 down with it, and #1816, #1818 and #1819 went with it: one
-- mis-placed file blocks every branch beside it.
-- So: no dev_commands on this database, nothing here belongs on it, exit 0.
select case when to_regclass('public.dev_commands') is null then 'true' else 'false' end
  as c1817_not_control_plane \gset
\if :c1817_not_control_plane
\echo 'c1817: no dev_commands on this database — control-plane migration, nothing to apply'
\quit
\endif
-- CHANGE / CMD #1817 — A WAITING AGENT MUST SLEEP, NOT THINK.
--
-- 6 Sep 2026: #1812 finished its code at 11/11, queued behind deploy batch 594
-- and then spent 159,555 tokens doing nothing but polling the lane and
-- re-thinking between polls. The batch itself took 17 minutes and cost nothing.
-- _wait_burn_check killed the row (needs_input, kind waiting_burn) — the
-- backstop worked, which is exactly the problem: the backstop should never be
-- the thing that notices.
--
-- The fix is that waiting stops being a sequence of model turns and becomes ONE
-- blocking shell call:
--
--   devcmd.sh wait <id> merge <entry_id>     # sleep N, check, sleep N …
--
-- while the agent's turn is suspended inside the Bash tool. This migration is
-- the backend half of that loop:
--
--   dev_wait_begin  — mark the row asleep, remember the token mark, hand back
--                     the poll interval and the ceiling from worker_pool.
--   dev_wait_poll   — ONE cheap call per sleep: is the blocker free, keep the
--                     row alive for the liveness sweep, and log a wait_turn if
--                     tokens moved while the row was supposed to be asleep.
--   dev_wait_end    — clear the wait, bank the seconds, and return the ONE
--                     LINE the agent resumes on (never a re-read).
--
-- A model turn taken while a command is waiting is a BUG, and it is now
-- visible: dev_context_event kind='wait_turn' carries the token delta, and the
-- Context economy panel prints the running total. The proof this change is
-- asking for is a 15-minute wait with a token delta under 5,000, no wait_turn
-- rows, and _wait_burn_check never firing again.
--
-- Idempotent by construction: every statement is create-or-replace or guarded,
-- because the merge worker replays this file on production too, where
-- dev_commands and dev_context_event do not exist at all (#1761 moved them to
-- the control plane). Table DDL is wrapped; plpgsql bodies are not name-checked
-- at creation, so the functions land harmlessly on either database.

-- ── 1. the row remembers its own sleep ──────────────────────────────────────
do $c1817$
begin
  if to_regclass('public.dev_commands') is null then
    raise notice 'c1817: no dev_commands here (production) — skipping column DDL';
    return;
  end if;
  alter table public.dev_commands
    add column if not exists wait_turns       int    not null default 0,
    add column if not exists wait_turn_tokens bigint,
    add column if not exists wait_polls       int    not null default 0;
end
$c1817$;

-- ── 2. the knobs live in worker_pool, never in a script ─────────────────────
-- poll_s        how long the shell sleeps between checks (spec default 60 s)
-- max_wait_s    how long ONE call of the waiter may sleep. It is 540 s, not
--               "the whole wait", because a Claude Code Bash call is capped at
--               ten minutes: a waiter that tried to sleep for 17 minutes would
--               be killed by the tool and the agent would wake up with no line
--               to read, which is the exact state that makes it start thinking.
--               So a long wait is CHUNKED — the loop returns one line saying
--               "still queued, run the same command again", the agent re-runs
--               it, and dev_wait_begin keeps the original wait_since and token
--               mark so the accounting spans the whole wait, not the chunk.
--               A 17-minute lane wait is therefore two model turns of a few
--               hundred tokens, against #1812's 159,555.
-- turn_tokens   a token delta bigger than this, while asleep, is a model turn
update public.dev_runner_config
   set value = jsonb_set(value, '{wait_gate}',
         coalesce(value->'wait_gate','{}'::jsonb)
         || jsonb_build_object(
              'poll_s',      coalesce(value->'wait_gate'->'poll_s',      to_jsonb(60)),
              'max_wait_s',  coalesce(value->'wait_gate'->'max_wait_s',  to_jsonb(540)),
              'turn_tokens', coalesce(value->'wait_gate'->'turn_tokens', to_jsonb(2000)),
              'note', to_jsonb('CHANGE #1817 — waiting is a shell sleep, not a model turn. poll_s is how long the wait loop sleeps between checks; turn_tokens is the delta that makes a wait_turn event; waiting_token_grace (worker_pool root) stays the kill backstop.'::text)),
         true)
 where key = 'worker_pool';

create or replace function public._dev_wait_cfg()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
           'poll_s',      coalesce((value->'wait_gate'->>'poll_s')::int, 60),
           'max_wait_s',  coalesce((value->'wait_gate'->>'max_wait_s')::int, 540),
           'turn_tokens', coalesce((value->'wait_gate'->>'turn_tokens')::bigint, 2000),
           'grace',       coalesce((value->>'waiting_token_grace')::bigint, 150000))
    from dev_runner_config where key = 'worker_pool'
$function$;

-- ── 3. dev_context_event learns the three wait kinds ────────────────────────
create or replace function public.dev_context_event(p_command_id bigint, p_agent text, p_kind text, p_pct numeric DEFAULT NULL::numeric, p_ok boolean DEFAULT true, p_detail jsonb DEFAULT '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id bigint;
begin
  perform _dev_guard();
  -- wait_start / wait_end / wait_turn are #1817's. wait_turn is the only kind
  -- in this table that is written to record a BUG: a model turn taken while the
  -- command was supposed to be asleep.
  if p_kind not in ('compact','compact_failed','clear','resume','threshold',
                    'wait_start','wait_end','wait_turn') then
    return jsonb_build_object('ok', false, 'error', 'unknown kind: ' || coalesce(p_kind,'null'));
  end if;
  insert into dev_context_event (command_id, agent, kind, pct, ok, detail)
  values (p_command_id, p_agent, p_kind, p_pct, coalesce(p_ok,true), coalesce(p_detail,'{}'::jsonb))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'kind', p_kind, 'pct', p_pct);
end
$function$;

-- ── 4. the one place that decides "a model turn happened while waiting" ─────
-- Called from the wait loop (dev_wait_poll) AND from the backstop
-- (_wait_burn_check), so an agent that ignores the loop and polls by hand is
-- still caught. wait_turn_tokens is the high-water mark, which makes it
-- idempotent: the same tokens are never reported as two turns.
create or replace function public._dev_wait_turn_log(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_cfg jsonb; v_now bigint; v_mark bigint; v_delta bigint;
begin
  select * into r from dev_commands where id = p_id;
  if not found or coalesce(r.wait_state,'') not in ('sleeping','parked') then
    return jsonb_build_object('waiting', false);
  end if;
  v_cfg  := _dev_wait_cfg();
  v_now  := coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0);
  v_mark := coalesce(r.wait_turn_tokens, r.wait_started_tokens, v_now);
  v_delta := v_now - v_mark;
  if v_delta <= (v_cfg->>'turn_tokens')::bigint then
    return jsonb_build_object('waiting', true, 'delta', v_delta, 'logged', false);
  end if;

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, r.claimed_by, 'wait_turn', false,
          jsonb_build_object(
            'delta', v_delta,
            'wait_kind', coalesce(r.wait_kind,'unknown'),
            'wait_reason', coalesce(r.wait_reason,''),
            'waited_s', greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int),
            'burn_total', v_now - coalesce(r.wait_started_tokens, v_now)));
  update dev_commands
     set wait_turn_tokens = v_now, wait_turns = coalesce(wait_turns,0) + 1
   where id = p_id;
  return jsonb_build_object('waiting', true, 'delta', v_delta, 'logged', true);
end
$function$;

-- ── 5. begin / poll / end — the loop's three calls ──────────────────────────
create or replace function public.dev_wait_begin(p_id bigint, p_agent text, p_kind text,
                                                 p_reason text DEFAULT NULL, p_blocker jsonb DEFAULT '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_cfg jsonb; v_tok bigint; v_reason text; v_cont boolean;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building: ' || r.status);
  end if;

  v_cfg   := _dev_wait_cfg();
  v_tok   := coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0);
  v_reason := coalesce(nullif(p_reason,''), 'queued in the ' || coalesce(p_kind,'lane') || ' lane');

  -- RE-ENTRANT ON PURPOSE. One call of the waiter sleeps for max_wait_s and
  -- then hands back a line; the agent re-runs it and lands here again. If this
  -- is a continuation of the SAME wait, wait_since and the token mark are kept,
  -- so the burn that gets measured (and killed on) is the burn of the whole
  -- wait, not of the last chunk — otherwise a builder could poll for ever, a
  -- chunk at a time, and never trip the grace.
  v_cont := coalesce(r.wait_state,'') = 'sleeping' and coalesce(r.wait_kind,'') = coalesce(p_kind,'other');

  update dev_commands
     set wait_state          = 'sleeping',
         wait_kind           = coalesce(p_kind,'other'),
         wait_reason         = v_reason,
         wait_since          = case when v_cont then coalesce(wait_since, now()) else now() end,
         wait_until          = now() + ((v_cfg->>'max_wait_s')::int || ' seconds')::interval,
         wait_blocker        = coalesce(p_blocker,'{}'::jsonb),
         wait_count          = case when v_cont then coalesce(wait_count,0) else coalesce(wait_count,0) + 1 end,
         wait_started_tokens = case when v_cont then coalesce(wait_started_tokens, v_tok) else v_tok end,
         wait_turn_tokens    = case when v_cont then coalesce(wait_turn_tokens, v_tok) else v_tok end,
         wait_turns          = case when v_cont then coalesce(wait_turns,0) else 0 end,
         wait_polls          = case when v_cont then coalesce(wait_polls,0) else 0 end,
         heartbeat_at        = now(),
         eta_note            = 'asleep: ' || v_reason
   where id = p_id;

  if not v_cont then
    insert into dev_context_event (command_id, agent, kind, ok, detail)
    values (p_id, coalesce(p_agent, r.claimed_by), 'wait_start', true,
            jsonb_build_object('wait_kind', coalesce(p_kind,'other'),
                               'reason', v_reason,
                               'blocker', coalesce(p_blocker,'{}'::jsonb),
                               'tokens_at_start', v_tok));
  end if;

  return jsonb_build_object('ok', true,
    'continuing', v_cont,
    'poll_s',      (v_cfg->>'poll_s')::int,
    'max_wait_s',  (v_cfg->>'max_wait_s')::int,
    'turn_tokens', (v_cfg->>'turn_tokens')::bigint,
    'started_tokens', case when v_cont then coalesce(r.wait_started_tokens, v_tok) else v_tok end,
    'label', 'asleep — ' || v_reason);
end
$function$;

-- ── 5a. the shared free-checker ─────────────────────────────────────────────
-- One helper answers "is the blocker gone?" for the poller and for the sweep,
-- so the two can never disagree. #1819 owns it; this file creates it only when
-- it is absent, so replay order between the two commands cannot regress it.
do $c1817f$
begin
  if to_regprocedure('public._dev_wait_free(bigint, text, jsonb)') is not null then
    return;
  end if;
  execute $fn$
    create or replace function public._dev_wait_free(p_id bigint, p_kind text, p_blocker jsonb)
    returns jsonb language plpgsql security definer set search_path to 'public'
    as $body$
    declare v_entry bigint; v_st text; v_paths text[]; v_free boolean; v_why text; v_holder text;
    begin
      if coalesce(p_kind,'other') = 'merge' then
        v_entry := nullif(p_blocker->>'entry_id','')::bigint;
        if v_entry is not null then
          select status into v_st from deploy_queue where id = v_entry;
          v_free := v_st is null or v_st in ('deployed','evicted','failed');
          v_why  := 'entry ' || v_entry || ' is ' || coalesce(v_st,'gone');
        else
          v_free := not exists (select 1 from deploy_queue q
                                 where q.command_id = p_id
                                   and q.status not in ('deployed','evicted','failed'));
          v_why  := case when v_free then 'nothing of this command is in the lane'
                         else 'still queued in the merge lane' end;
        end if;
      elsif coalesce(p_kind,'') = 'lease' then
        v_paths := coalesce((select array_agg(value #>> '{}')
                               from jsonb_array_elements(coalesce(p_blocker->'paths','[]'::jsonb))), '{}');
        if v_paths = '{}' then
          v_free := true; v_why := 'no path named';
        else
          select fl.worker into v_holder from file_leases fl
           where fl.path = any(v_paths) and fl.command_id is distinct from p_id limit 1;
          v_free := v_holder is null;
          v_why  := case when v_free then 'every path is free'
                         else 'a path is still leased by ' || v_holder end;
        end if;
      else
        v_free := true;
        v_why  := 'waiting out ' || coalesce(p_kind,'other');
      end if;
      return jsonb_build_object('free', coalesce(v_free,false), 'why', v_why);
    end $body$;
  $fn$;
end
$c1817f$;

create or replace function public.dev_wait_poll(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_cfg jsonb; v_f jsonb; v_free boolean := false; v_why text;
        v_waited int; v_burn bigint; v_hold text; v_args text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  -- The command stopped being ours to wait on (released, killed, completed):
  -- free, so the loop exits instead of sleeping against a dead row.
  if r.status <> 'building' then
    return jsonb_build_object('ok', true, 'free', true, 'reason', 'command is ' || r.status,
                              'status', r.status);
  end if;
  if coalesce(r.wait_state,'') <> 'sleeping' then
    return jsonb_build_object('ok', true, 'free', true, 'reason', 'not asleep any more');
  end if;

  v_cfg := _dev_wait_cfg();
  perform _dev_wait_turn_log(p_id);

  -- WHO IS STILL HOLDING THIS? The decision lives in _dev_wait_free (#1819),
  -- one helper shared by the poller and the sweep, so the two can never drift
  -- into disagreeing about whether a lane is open. It names the CLOSED states
  -- positively (deployed / evicted / failed) rather than listing the open ones
  -- — this file's first cut listed ('queued','batched','merging') and would
  -- have woken a command the moment an entry sat in 'waiting', which is the
  -- state deploy_queue actually parks a fresh push in.
  if coalesce(r.wait_kind,'other') in ('merge','lease') then
    v_f    := _dev_wait_free(p_id, r.wait_kind, r.wait_blocker);
    v_free := coalesce((v_f->>'free')::boolean, false);
    v_why  := v_f->>'why';
  else
    -- db / rpc / batch / grant / other: only time heals it, so the wait window
    -- itself is the condition.
    v_free := r.wait_until is not null and now() >= r.wait_until;
    v_why  := case when v_free then 'wait window elapsed' else 'waiting out ' || coalesce(r.wait_kind,'other') end;
  end if;

  v_waited := greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int);

  update dev_commands
     set wait_polls = coalesce(wait_polls,0) + 1,
         heartbeat_at = now()          -- asleep is ALIVE: never let the liveness sweep steal the row
   where id = p_id;

  select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) - coalesce(wait_started_tokens,0)
    into v_burn from dev_commands where id = p_id;

  -- The ONE LINE the agent reads when a chunk of sleep ends without the lane
  -- freeing. It is a backend string on purpose: the whole point of this change
  -- is that the agent narrates nothing while it waits.
  -- the re-run must be copy-pasteable, so it carries the blocker back with it
  v_args := case coalesce(r.wait_kind,'other')
              when 'merge' then coalesce(' ' || (r.wait_blocker->>'entry_id'), '')
              when 'lease' then coalesce((select ' ' || string_agg(value #>> '{}', ' ')
                                            from jsonb_array_elements(coalesce(r.wait_blocker->'paths','[]'::jsonb))), '')
              else coalesce(' ' || quote_literal(r.wait_reason), '')
            end;
  v_hold := format('Still waiting after %s — %s. Sleep again: devcmd.sh wait %s %s%s. Do NOT plan, summarise or re-read anything.',
                   _fmt_dur(v_waited), v_why, p_id, coalesce(r.wait_kind,'other'), v_args);

  return jsonb_build_object('ok', true, 'free', v_free, 'reason', v_why,
    'polls', coalesce(r.wait_polls,0) + 1, 'waited_s', v_waited,
    'waited_label', _fmt_dur(v_waited),
    'burn', greatest(0, coalesce(v_burn,0)), 'turns', coalesce(r.wait_turns,0),
    'hold_line', v_hold,
    'poll_s', (v_cfg->>'poll_s')::int);
end
$function$;

create or replace function public.dev_wait_end(p_id bigint, p_outcome text DEFAULT 'free')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_cfg jsonb; v_secs int; v_burn bigint; v_line text; v_next text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if coalesce(r.wait_state,'') <> 'sleeping' then
    return jsonb_build_object('ok', true, 'resume_line', 'Not asleep — carry on.', 'waited_s', 0, 'burn', 0);
  end if;

  v_cfg  := _dev_wait_cfg();
  v_secs := greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int);
  v_burn := greatest(0, (coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0))
                        - coalesce(r.wait_started_tokens,0));

  -- The resume is ONE LINE, and it names the next step so nothing is re-read.
  select s->>'title' into v_next
    from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
   where coalesce(s->>'status','pending') <> 'done'
   order by coalesce((s->>'n')::int, 999) limit 1;

  v_line := format('%s after %s — %s. Resume%s; nothing else changed, do not re-read the spec.',
                   case when coalesce(r.wait_kind,'') = 'merge' then 'Merge lane free'
                        when coalesce(r.wait_kind,'') = 'lease' then 'Lease free'
                        else 'Wait over' end,
                   _fmt_dur(v_secs),
                   coalesce(nullif(p_outcome,''), 'free'),
                   coalesce(' at step: ' || v_next, ''));

  update dev_commands
     set wait_state          = null,
         wait_until          = null,
         wait_started_tokens = null,
         wait_turn_tokens    = null,
         wait_total_s        = coalesce(wait_total_s,0) + v_secs,
         heartbeat_at        = now(),
         eta_note            = case when coalesce(eta_note,'') like 'asleep:%' then '' else eta_note end
   where id = p_id;

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, r.claimed_by, 'wait_end', v_burn <= (v_cfg->>'turn_tokens')::bigint,
          jsonb_build_object('seconds', v_secs, 'burn', v_burn,
                             'polls', coalesce(r.wait_polls,0), 'turns', coalesce(r.wait_turns,0),
                             'wait_kind', coalesce(r.wait_kind,'other'), 'outcome', coalesce(p_outcome,'free')));

  return jsonb_build_object('ok', true, 'resume_line', v_line, 'waited_s', v_secs,
    'waited_label', _fmt_dur(v_secs), 'burn', v_burn,
    'turns', coalesce(r.wait_turns,0), 'polls', coalesce(r.wait_polls,0));
end
$function$;

-- ── 6. the backstop keeps its job, and now sees a sleeping row too ──────────
-- Unchanged in intent: waiting_token_grace still kills a runaway. Two additions
-- — 'sleeping' counts as waiting, and every check routes through
-- _dev_wait_turn_log so a hand-rolled poll loop is recorded as wait_turn
-- events long before it reaches the grace.
create or replace function public._wait_burn_check(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_grace bigint; v_waiting boolean; v_burn bigint;
begin
  select * into r from dev_commands where id = p_id;
  if not found or r.status <> 'building' then return jsonb_build_object('kill', false); end if;

  select coalesce((value->>'waiting_token_grace')::bigint, 150000) into v_grace
    from dev_runner_config where key = 'worker_pool';

  v_waiting := coalesce(r.wait_state, '') in ('parked','sleeping')
    or coalesce(r.eta_note, '') ~* '(asleep|merge lane|deploy lane|waiting on the batch|waiting on entry|lease|queue waiter)';

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

  -- CHANGE #1817 — make the burn VISIBLE while it is small, instead of only
  -- fatal when it is enormous.
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
end
$function$;

-- ── 7. a sleeping row is swept the same way a parked one is ─────────────────
-- If the shell loop dies (VM reboot, killed pane), nothing would ever clear
-- wait_state and the row would look asleep for ever. The existing sweep already
-- knows how to decide a blocker is gone; it just could not see 'sleeping'.
create or replace function public.dev_cmd_wait_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; n_res int := 0; n_hold int := 0; n_sleep int := 0; v_ids bigint[] := '{}';
        v_free boolean; v_paths text[]; v_maxage int;
begin
  perform _dev_guard_or_local_cron();
  select coalesce((value->'wait_gate'->>'max_park_minutes')::int, 45)
    into v_maxage from dev_runner_config where key = 'worker_pool';
  v_maxage := coalesce(v_maxage, 45);

  -- CHANGE #1817 — a sleeping row whose loop went silent. The loop stamps
  -- heartbeat_at on every poll, so a stale stamp means the shell is gone, not
  -- that the lane is slow. Ending the wait is enough: the row stays building
  -- and the agent (or the liveness sweep) picks it up normally.
  for r in select * from dev_commands
            where wait_state = 'sleeping' and status = 'building'
              and coalesce(heartbeat_at, wait_since) < now() - interval '10 minutes' loop
    perform dev_wait_end(r.id, 'waiter went silent');
    n_sleep := n_sleep + 1;
  end loop;

  for r in select * from dev_commands
            where wait_state = 'parked' and status = 'building'
            order by wait_until nulls first, id loop
    v_free := false;

    if r.wait_until is not null and r.wait_until > now() then
      n_hold := n_hold + 1;
      continue;                                   -- the retry window is not up
    end if;

    if r.wait_kind = 'lease' then
      v_paths := coalesce((select array_agg(value #>> '{}')
                             from jsonb_array_elements(coalesce(r.wait_blocker->'paths','[]'::jsonb))), '{}');
      v_free := (v_paths = '{}') or not exists (
        select 1 from file_leases fl
         where fl.path = any(v_paths) and fl.command_id <> r.id);
    elsif r.wait_kind = 'merge' then
      v_free := not exists (select 1 from deploy_queue q
                             where q.command_id = r.id
                               and q.status in ('queued','batched','merging'));
    else
      v_free := true;                             -- db / rpc / other: time heals it
    end if;

    if not v_free and r.wait_since < now() - (v_maxage || ' minutes')::interval then
      v_free := true;
    end if;

    if v_free then
      perform dev_cmd_unpark(r.id, coalesce(r.wait_reason, 'blocker cleared'));
      n_res := n_res + 1; v_ids := v_ids || r.id;
    else
      update dev_commands
         set wait_until = now() + (greatest(coalesce(
               (select retry_after_s from dev_fail_rule where kind = r.wait_kind and enabled order by ord limit 1),
               120), 60) || ' seconds')::interval
       where id = r.id;
      n_hold := n_hold + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'resumed', n_res, 'holding', n_hold,
                            'sleepers_ended', n_sleep, 'ids', to_jsonb(v_ids));
end
$function$;

-- ── 8. the Context economy panel gets the row that proves it ───────────────
-- The panel is a PRINTER (test/protected/context_economy_test.dart): it lays
-- rows out and prints the backend's strings. So the whole frontend of #1817 is
-- this one extra row — no Dart change, and the number Om reads is the number
-- the database measured.
--
--   Waiting  |  17m asleep · 340 tokens  |  3 waits · 0 wake-ups · target 0
--
-- "wake-ups" is the wait_turn count: every model turn taken while a command was
-- supposed to be asleep. The target is zero, and the tone says so.
create or replace function public.dev_context_metrics(p_window integer DEFAULT NULL::integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cfg jsonb; v_since timestamptz; v_w int;
        v_before numeric; v_after numeric; v_after_n int; v_before_n int;
        v_compact int; v_clear int; v_failed int; v_resume_words numeric; v_resume_n int;
        v_rb numeric; v_ra numeric; v_rb_n int; v_ra_n int;
        v_delta numeric; v_rows jsonb; v_tone text; v_delta_label text;
        v_rlabel text; v_rtone text; v_rsub text;
        v_waits int; v_wait_s bigint; v_wait_burn bigint; v_turns int; v_turn_burn bigint;
        v_wlabel text; v_wsub text; v_wtone text;
begin
  perform _dev_guard();
  v_cfg   := dev_context_cfg();
  v_w     := coalesce(p_window, (v_cfg->>'metric_window')::int, 20);
  v_since := coalesce((v_cfg->>'since')::timestamptz, now());

  select avg(t), count(*) into v_before, v_before_n from (
    select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) t
      from dev_commands
     where status='completed' and finished_at < v_since
       and coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) > 0
     order by finished_at desc limit v_w) b;

  select avg(t), count(*) into v_after, v_after_n from (
    select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) t
      from dev_commands
     where status='completed' and finished_at >= v_since
       and coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) > 0
     order by finished_at asc limit v_w) a;

  select count(*) filter (where kind='compact' and ok),
         count(*) filter (where kind='clear'),
         count(*) filter (where kind in ('compact_failed') or (kind='compact' and not ok))
    into v_compact, v_clear, v_failed
    from dev_context_event where at >= v_since;

  select avg(resume_note_words), count(*) into v_resume_words, v_resume_n
    from dev_commands where resume_note_words is not null and resume_note_at >= v_since;

  select avg(tokens_added), count(*) into v_rb, v_rb_n
    from public.dev_resume_ledger where closed_at is not null and closed_at <  v_since and tokens_added > 0;
  select avg(tokens_added), count(*) into v_ra, v_ra_n
    from public.dev_resume_ledger where closed_at is not null and closed_at >= v_since and tokens_added > 0;

  -- CHANGE #1817 — what waiting actually cost.
  select count(*), coalesce(sum((detail->>'seconds')::bigint),0), coalesce(sum((detail->>'burn')::bigint),0)
    into v_waits, v_wait_s, v_wait_burn
    from dev_context_event where kind = 'wait_end' and at >= v_since;
  select count(*), coalesce(sum((detail->>'delta')::bigint),0)
    into v_turns, v_turn_burn
    from dev_context_event where kind = 'wait_turn' and at >= v_since;

  if coalesce(v_waits,0) = 0 then
    v_wlabel := 'no waits yet';
    v_wsub   := 'a queued command sleeps in the shell — target 0 wake-ups';
    v_wtone  := 'info';
  else
    v_wlabel := _fmt_dur(coalesce(v_wait_s,0)) || ' asleep · ' || _dev_num_short(coalesce(v_wait_burn,0)) || ' tokens';
    v_wsub   := v_waits || ' wait(s) · ' || coalesce(v_turns,0) || ' wake-up(s)'
                || case when coalesce(v_turns,0) > 0
                        then ' burning ' || _dev_num_short(coalesce(v_turn_burn,0)) || ' — target 0'
                        else ' · target 0' end;
    v_wtone  := case when coalesce(v_turns,0) = 0 then 'success' else 'danger' end;
  end if;

  if v_before is not null and v_after is not null and v_before > 0 then
    v_delta := round(((v_after - v_before) / v_before) * 100.0, 1);
    v_delta_label := case when v_delta > 0 then '+' else '' end || trim(to_char(v_delta,'FM9990.0')) || '%';
    v_tone := case when v_delta <= 0 then 'success' else 'warning' end;
  else
    v_delta_label := 'measuring…'; v_tone := 'info';
  end if;

  if coalesce(v_ra_n,0) = 0 then
    v_rlabel := case when coalesce(v_rb_n,0) = 0 then 'measuring…'
                     else _dev_num_short(round(coalesce(v_rb,0))) || ' → measuring…' end;
    v_rtone  := 'info';
    v_rsub   := coalesce(v_rb_n,0) || ' resume(s) before · none since';
  else
    v_rlabel := case when coalesce(v_rb_n,0) = 0 then _dev_num_short(round(v_ra))
                     else _dev_num_short(round(v_rb)) || ' → ' || _dev_num_short(round(v_ra)) end;
    v_rtone  := case when coalesce(v_rb_n,0) = 0 then 'info'
                     when v_ra <= v_rb then 'success' else 'warning' end;
    v_rsub   := coalesce(v_rb_n,0) || ' before · ' || v_ra_n || ' since · lower is better';
  end if;

  v_rows := jsonb_build_array(
    jsonb_build_object('label','Tokens / command — before',
      'value', _dev_num_short(round(coalesce(v_before,0))),
      'sub',   v_before_n || ' commands', 'tone','info'),
    jsonb_build_object('label','Tokens / command — after',
      'value', case when v_after_n = 0 then '—' else _dev_num_short(round(coalesce(v_after,0))) end,
      'sub',   v_after_n || ' of ' || v_w || ' commands', 'tone','info'),
    jsonb_build_object('label','Change',
      'value', v_delta_label, 'sub', 'lower is better', 'tone', v_tone),
    jsonb_build_object('label','Tokens / resume',
      'value', v_rlabel, 'sub', v_rsub, 'tone', v_rtone),
    jsonb_build_object('label','Waiting',
      'value', v_wlabel, 'sub', v_wsub, 'tone', v_wtone),
    jsonb_build_object('label','/compact vs /clear',
      'value', coalesce(v_compact,0) || ' · ' || coalesce(v_clear,0),
      'sub',   case when coalesce(v_failed,0) > 0 then v_failed || ' compact failed → cleared' else 'compact first, clear only on failure' end,
      'tone',  case when coalesce(v_clear,0) > coalesce(v_compact,0) then 'warning' else 'success' end),
    jsonb_build_object('label','Average resume size',
      'value', case when v_resume_n = 0 then '—' else trim(to_char(round(coalesce(v_resume_words,0)),'FM9990')) || ' words' end,
      'sub',   'cap ' || coalesce((v_cfg->>'resume_words')::int, 200) || ' words · ' || v_resume_n || ' rows',
      'tone',  case when coalesce(v_resume_words,0) > coalesce((v_cfg->>'resume_words')::int, 200) then 'warning' else 'success' end));

  return jsonb_build_object(
    'ok', true, 'has', true,
    'title', 'Context economy',
    'since', v_since,
    'since_label', 'since ' || to_char(v_since at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
    'threshold_label', 'compact at ' || coalesce((v_cfg->>'compact_pct')::int, 70) || '% context',
    'window', v_w,
    'rows', v_rows,
    'footnote', 'Measured over the ' || v_w || ' commands completed on each side of the change. Tokens / resume is measured per resumed segment, not guessed from the total. Waiting is measured from the wait itself: a wake-up is a model turn taken while the command was asleep.');
end
$function$;

-- ── 9. grants ───────────────────────────────────────────────────────────────
do $c1817g$
begin
  if to_regclass('public.dev_commands') is null then return; end if;
  grant execute on function public.dev_wait_begin(bigint, text, text, text, jsonb) to service_role, authenticated;
  grant execute on function public.dev_wait_poll(bigint)              to service_role, authenticated;
  grant execute on function public.dev_wait_end(bigint, text)         to service_role, authenticated;
  grant execute on function public._dev_wait_cfg()                    to service_role, authenticated;
end
$c1817g$;

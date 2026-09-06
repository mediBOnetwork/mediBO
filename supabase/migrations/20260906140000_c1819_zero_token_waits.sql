-- replay-target: control-plane
-- CHANGE #1819 — WAITING COSTS ZERO TOKENS.
--
-- #1817 made a wait a shell sleep instead of a model turn. It was not enough:
-- a sleeping session is still a HELD session, so the row stays 'building' with
-- claimed_by set, dev_cmd_claim answers the runner "Already building #N", and
-- the slot cannot take other work for the whole wait. Measured over 48 h that
-- cost 2.03M tokens across 8 merge-lane events and 58 lease events.
--
-- So a wait longer than wait_gate.sleep_max_s now PARKS AND RELEASES: the step
-- state is already on the row, the leases go back, the AGENT goes back, and the
-- Claude session exits. The row is 'pending' with wait_state='parked', which is
-- invisible to dev_cmd_claim until the blocker clears — no new status value, so
-- every card, chip and sweep that already keys off wait_state keeps working.
--
-- Neither lock is weakened: db_work_lock and the deploy/merge lock serialise
-- exactly as before. Only the WAITING changes.
--
-- Every statement is idempotent, and every table reference is guarded so the
-- production leg of migration_replay.sh (which always runs) is a clean no-op on
-- a database that carries no dev-queue tables.

do $mig$
begin
if to_regclass('public.dev_commands') is null or to_regclass('public.dev_runner_config') is null then
  raise notice 'c1819: no dev-queue tables here — control-plane only, skipping';
  return;
end if;

-- ── config: the sleep/park threshold, editable with pool_set(), no deploy ──
update dev_runner_config
   set value = jsonb_set(value, '{wait_gate}',
         coalesce(value->'wait_gate','{}'::jsonb) || jsonb_build_object(
           'sleep_max_s', 60,
           'park_enabled', true,
           'resume_grace_s', 5,
           'note', 'CHANGE #1819 — a wait under sleep_max_s is a shell sleep; anything longer parks and RELEASES the runner. poll_s is the sleep step; turn_tokens is the delta that makes a wait_turn event; waiting_token_grace (root) stays the backstop.'))
 where key = 'worker_pool';
end
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. ONE PREDICATE FOR "IS THE BLOCKER GONE?"
--    #1817 wrote it three times (poll, sweep, burn check) and each copy tested
--    deploy_queue for status in ('queued','batched','merging') — statuses this
--    lane has never used. A freshly pushed entry is 'waiting', which matched
--    nothing, so every merge wait read as ALREADY FREE and the sleeper woke
--    straight back into a model turn. That single typo is most of the 1.60M.
-- ═══════════════════════════════════════════════════════════════════════════
do $fns$
begin
-- Every function below is control-plane work. migration_replay.sh always runs the
-- PRODUCTION pass first, and production carries no dev_commands — so creating them
-- there would add dead RPCs to the surface rg_check baselines. EXECUTE inside one
-- guard keeps the production leg a genuine no-op.
if to_regclass('public.dev_commands') is null then
  raise notice 'c1819: no dev_commands here — control-plane only, nothing created';
  return;
end if;

execute $w$
create or replace function public._dev_wait_free(p_id bigint, p_kind text, p_blocker jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_entry bigint; v_st text; v_paths text[]; v_free boolean; v_why text; v_holder text;
begin
  if coalesce(p_kind,'other') = 'merge' then
    v_entry := nullif(p_blocker->>'entry_id','')::bigint;
    if v_entry is not null then
      select status into v_st from deploy_queue where id = v_entry;
      -- OPEN statuses, named positively. 'deployed' / 'evicted' / 'failed' are
      -- the only ends of the lane; anything else still owes this command a pass.
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
    -- db / rpc / batch / grant / other: only time heals it, so the window is
    -- the condition and the caller owns the clock.
    v_free := true;
    v_why  := 'waiting out ' || coalesce(p_kind,'other');
  end if;
  return jsonb_build_object('free', coalesce(v_free,false), 'why', v_why);
end $fn$
$w$;

execute $w$
create or replace function public._dev_wait_eta_s(p_id bigint, p_kind text, p_blocker jsonb)
returns int language plpgsql security definer set search_path to 'public' as $fn$
declare v_eta int; v_entry bigint; v_pushed timestamptz; v_med numeric; v_holder bigint;
begin
  if coalesce(p_kind,'other') = 'merge' then
    -- median lifetime of the last 20 deploy_queue entries, minus what this
    -- entry has already waited.
    select percentile_cont(0.5) within group (order by extract(epoch from (coalesce(finished_at, closed_at, now()) - pushed_at)))
      into v_med
      from (select q.pushed_at, q.finished_at, b.closed_at
              from deploy_queue q left join deploy_batch b on b.id = q.batch_id
             where q.pushed_at > now() - interval '14 days'
             order by q.id desc limit 20) s;
    v_entry := nullif(p_blocker->>'entry_id','')::bigint;
    select pushed_at into v_pushed from deploy_queue where id = v_entry;
    v_eta := greatest(coalesce(v_med, 600)::int
                      - coalesce(extract(epoch from (now() - v_pushed))::int, 0), 30);
  elsif coalesce(p_kind,'') = 'lease' then
    -- a file lease is held by a BUILD, and a build is minutes, never seconds.
    select fl.command_id into v_holder from file_leases fl
     where fl.path = any(coalesce((select array_agg(value #>> '{}')
                                     from jsonb_array_elements(coalesce(p_blocker->'paths','[]'::jsonb))), '{}'))
       and fl.command_id is distinct from p_id limit 1;
    v_eta := case when v_holder is null then 0 else 900 end;
  else
    v_eta := coalesce((select retry_after_s from dev_fail_rule
                        where kind = p_kind and enabled order by ord limit 1), 120);
  end if;
  return greatest(coalesce(v_eta,120), 0);
end $fn$
$w$;

execute $w$
create or replace function public.dev_wait_enter(p_id bigint, p_agent text, p_kind text,
                                                 p_reason text default null, p_blocker jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_free jsonb; v_eta int; v_sleep int; v_reason text; v_park jsonb;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', true, 'mode', 'stop',
      'line', format('#%s is %s, not building — stop here and let the queue hand it out again.', p_id, r.status));
  end if;

  v_cfg   := _dev_wait_cfg();
  v_reason := coalesce(nullif(p_reason,''), 'queued in the ' || coalesce(p_kind,'lane') || ' lane');
  v_free  := _dev_wait_free(p_id, p_kind, p_blocker);

  -- Never sleep on nothing. A blocker that is already gone is a straight carry-on.
  if coalesce((v_free->>'free')::boolean, false) and coalesce(p_kind,'other') in ('merge','lease') then
    return jsonb_build_object('ok', true, 'mode', 'free', 'reason', v_free->>'why',
      'line', format('Not blocked — %s. Carry on from your next step.', v_free->>'why'));
  end if;

  v_eta   := _dev_wait_eta_s(p_id, p_kind, p_blocker);
  v_sleep := coalesce((v_cfg->>'sleep_max_s')::int, 60);

  if v_eta <= v_sleep and coalesce((v_cfg->>'park_enabled')::boolean, true) then
    -- SHORT: one blocking shell sleep, no park, no session churn (item 7).
    perform dev_wait_begin(p_id, p_agent, p_kind, v_reason, p_blocker);
    return jsonb_build_object('ok', true, 'mode', 'sleep',
      'sleep_s', least(greatest(v_eta, 5), v_sleep),
      'poll_s',  least(coalesce((v_cfg->>'poll_s')::int, 60), v_sleep),
      'eta_s',   v_eta,
      'line', format('Short wait (~%ss) — sleeping in the shell, no session released.', v_eta));
  end if;

  if not coalesce((v_cfg->>'park_enabled')::boolean, true) then
    perform dev_wait_begin(p_id, p_agent, p_kind, v_reason, p_blocker);
    return jsonb_build_object('ok', true, 'mode', 'sleep',
      'sleep_s', coalesce((v_cfg->>'max_wait_s')::int, 540),
      'poll_s',  coalesce((v_cfg->>'poll_s')::int, 60), 'eta_s', v_eta,
      'line', 'Park is off (wait_gate.park_enabled=false) — sleeping instead.');
  end if;

  -- LONG: park and RELEASE. Nothing is held, so nothing can burn.
  v_park := dev_cmd_park(p_id, coalesce(p_kind,'other'), v_reason, coalesce(p_blocker,'{}'::jsonb), v_eta);
  return jsonb_build_object('ok', true, 'mode', 'park', 'eta_s', v_eta, 'park', v_park,
    'line', coalesce(v_park->>'agent_line',
      format('Parked — %s (~%ss). The runner is free; this row resumes itself at its saved step.', v_reason, v_eta)));
end $fn$
$w$;

execute $w$
create or replace function public.dev_cmd_park(p_id bigint, p_kind text, p_reason text,
                                               p_blocker jsonb default '{}'::jsonb,
                                               p_retry_after_s integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_after int; v_label text; v_tok bigint; v_next text; v_line text;
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
  v_tok := coalesce(r.cost_input_tokens,0) + coalesce(r.cost_output_tokens,0);

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
    wait_started_tokens = v_tok,
    wait_turn_tokens    = v_tok,
    eta_note     = 'parked: ' || v_label
  where id = p_id;

  -- The leases go back the moment we park: holding a file while waiting on a
  -- DIFFERENT blocker is how one park becomes a fleet-wide queue.
  perform _lease_release_internal(p_id);

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, coalesce(r.claimed_by,'unknown'), 'wait_park', true,
          jsonb_build_object('wait_kind', coalesce(p_kind,'other'), 'reason', v_label,
                             'blocker', coalesce(p_blocker,'{}'::jsonb),
                             'retry_after_s', v_after, 'tokens_at_park', v_tok,
                             'steps_done', coalesce(r.steps_done,0)));

  perform _audit('system','dev_cmd_park', p_id::text,
    jsonb_build_object('kind', p_kind, 'reason', v_label, 'blocker', p_blocker,
                       'retry_after_s', v_after, 'released_agent', r.claimed_by));
  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(replace(
    _c_or('dev_queue.wait_msg','⏸ Parked — {reason}. The work is committed and untouched; it resumes automatically when the blocker clears (checked every {after}s).'),
    '{reason}', v_label), '{after}', v_after::text));

  v_line := format('Parked — %s. Your leases and this runner are released; #%s is back in the queue at its own priority and resumes itself%s. STOP NOW: finish this turn with no further tool calls, no summary and no re-read. Waiting costs nothing only if you exit.',
                   v_label, p_id, coalesce(' at step: ' || v_next, ''));

  return jsonb_build_object('ok', true, 'parked', true, 'id', p_id,
    'kind', p_kind, 'reason', v_label, 'retry_after_s', v_after,
    'released_agent', r.claimed_by, 'next_step', v_next,
    'agent_line', v_line,
    'note', 'the row is pending-but-fenced; dev_cmd_claim skips it until the blocker clears');
end $fn$
$w$;

execute $w$
create or replace function public.dev_cmd_unpark(p_id bigint, p_reason text default 'blocker cleared'::text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_secs int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found or r.wait_state is distinct from 'parked' then
    return jsonb_build_object('ok', false, 'error', 'not parked');
  end if;
  v_secs := greatest(round(extract(epoch from now() - coalesce(r.wait_since, now())))::int, 0);
  update dev_commands set
    status       = case when status = 'building' then 'pending' else status end,
    claimed_by   = case when status = 'building' then null else claimed_by end,
    released_at  = coalesce(released_at, now()),
    wait_state   = null, wait_kind = null, wait_until = null,
    wait_reason  = null, wait_blocker = '{}'::jsonb,
    wait_started_tokens = null, wait_turn_tokens = null,
    wait_total_s = coalesce(wait_total_s,0) + v_secs,
    eta_note     = case when coalesce(eta_note,'') like 'parked:%' then '' else eta_note end
  where id = p_id;

  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, coalesce(r.claimed_by,'queue'), 'wait_resume', true,
          jsonb_build_object('seconds', v_secs, 'wait_kind', coalesce(r.wait_kind,'other'),
                             'reason', p_reason,
                             'burn', greatest(0, (coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0))
                                                 - coalesce(r.wait_started_tokens,
                                                            coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0)))));

  perform _audit('system','dev_cmd_unpark', p_id::text,
                 jsonb_build_object('reason', p_reason, 'waited_s', v_secs));
  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(_c_or('dev_queue.wait_clear_msg',
    '▶ Resuming — {reason}. Picking up at the first unfinished step.'), '{reason}', p_reason));
  return jsonb_build_object('ok', true, 'resumed', true, 'id', p_id, 'waited_s', v_secs);
end $fn$
$w$;

execute $w$
create or replace function public.dev_wait_resume_ready(p_kinds text[] default null, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_free jsonb; n int := 0; v_ids bigint[] := '{}'; v_maxage int;
begin
  select coalesce((value->'wait_gate'->>'max_park_minutes')::int, 45)
    into v_maxage from dev_runner_config where key = 'worker_pool';
  for r in select * from dev_commands
            where wait_state = 'parked'
              and status in ('pending','building')
              and (p_kinds is null or coalesce(wait_kind,'other') = any(p_kinds))
            order by wait_since loop
    v_free := _dev_wait_free(r.id, r.wait_kind, r.wait_blocker);
    if coalesce((v_free->>'free')::boolean,false)
       or p_force
       or (coalesce(r.wait_kind,'other') not in ('merge','lease')
           and r.wait_until is not null and now() >= r.wait_until)
       or r.wait_since < now() - (coalesce(v_maxage,45) || ' minutes')::interval then
      perform dev_cmd_unpark(r.id, coalesce(v_free->>'why', 'blocker cleared'));
      n := n + 1; v_ids := v_ids || r.id;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'resumed', n, 'ids', to_jsonb(v_ids));
end $fn$
$w$;

execute $w$
create or replace function public._dev_wait_kick() returns trigger
language plpgsql security definer set search_path to 'public' as $fn$
begin
  -- A lane event is the cheapest possible wake-up: no cron tick to wait for, no
  -- session to poll. Failure here must never break the lane it rode in on, so it
  -- is recorded as an alert rather than raised.
  begin
    if tg_table_name = 'file_leases' then
      perform dev_wait_resume_ready(array['lease']);
    else
      perform dev_wait_resume_ready(array['merge']);
    end if;
  exception when others then
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values ('c1819_wait_kick_' || tg_table_name, 'warn', 'runner', 'wait kick failed',
            jsonb_build_object('table', tg_table_name, 'error', sqlerrm))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end;
  return null;
end $fn$
$w$;

execute $w$
create or replace function public.dev_cmd_wait_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_res jsonb; n_sleep int := 0; n_hold int := 0;
begin
  perform _dev_guard_or_local_cron();

  -- A SLEEPING row whose shell went silent. The loop stamps heartbeat_at on
  -- every poll, so a stale stamp means the shell is gone, not that the lane is
  -- slow. Ending the wait is enough: the row stays building.
  for r in select * from dev_commands
            where wait_state = 'sleeping' and status = 'building'
              and coalesce(heartbeat_at, wait_since) < now() - interval '10 minutes' loop
    perform dev_wait_end(r.id, 'waiter went silent');
    n_sleep := n_sleep + 1;
  end loop;

  v_res := dev_wait_resume_ready();

  select count(*) into n_hold from dev_commands where wait_state = 'parked';
  return jsonb_build_object('ok', true,
    'resumed', coalesce((v_res->>'resumed')::int,0),
    'holding', greatest(n_hold - coalesce((v_res->>'resumed')::int,0), 0),
    'sleepers_ended', n_sleep, 'ids', v_res->'ids');
end $fn$
$w$;

execute $w$
create or replace function public.dev_wait_poll(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_cfg jsonb; v_f jsonb; v_free boolean; v_why text;
        v_waited int; v_burn bigint; v_hold text; v_args text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', true, 'free', true, 'reason', 'command is ' || r.status,
                              'status', r.status);
  end if;
  if coalesce(r.wait_state,'') <> 'sleeping' then
    return jsonb_build_object('ok', true, 'free', true, 'reason', 'not asleep any more');
  end if;

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
     set wait_polls = coalesce(wait_polls,0) + 1,
         heartbeat_at = now()          -- asleep is ALIVE
   where id = p_id;
  select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) - coalesce(wait_started_tokens,0)
    into v_burn from dev_commands where id = p_id;

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
end $fn$
$w$;

execute $w$
create or replace function public.merge_batch_absorb(p_token uuid, p_max integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_batch bigint; v_st text; v_max int; v_n int := 0; v_rows jsonb;
begin
  perform _dev_guard();
  select id, status into v_batch, v_st from deploy_batch
   where token = p_token order by id desc limit 1;
  if v_batch is null then
    return jsonb_build_object('ok', false, 'reason', 'no batch for this token');
  end if;
  if v_st <> 'merging' then
    return jsonb_build_object('ok', false, 'reason', 'batch is ' || v_st || ' — absorbing now would deploy an untested branch',
                              'batch_id', v_batch);
  end if;
  select coalesce(p_max, (_mq_cfg()->>'max_batch')::int, 10) into v_max;
  v_max := greatest(coalesce(v_max,10), 1);

  with room as (select greatest(v_max - coalesce((select entries from deploy_batch where id = v_batch),0), 0) as n),
  picked as (
    select q.id from deploy_queue q, room
     where q.status = 'waiting'
     order by q.pushed_at
     limit (select n from room)
     for update of q skip locked),
  upd as (
    update deploy_queue q
       set status = 'batched', batched_at = now(), batch_id = v_batch,
           wait_s = extract(epoch from now() - q.pushed_at)::int
      from picked p where q.id = p.id
    returning jsonb_build_object('id', q.id, 'branch', q.branch, 'commit', q.commit_sha,
                                 'title', q.title, 'command_id', q.command_id) as row)
  select coalesce(jsonb_agg(row order by row->>'id'), '[]'::jsonb) into v_rows from upd;

  v_n := jsonb_array_length(coalesce(v_rows,'[]'::jsonb));
  if v_n > 0 then
    update deploy_batch set entries = coalesce(entries,0) + v_n,
           log = coalesce(log,'[]'::jsonb) || jsonb_build_object(
                   'at', now(), 'phase', 'absorb', 'note', v_n || ' late branch(es) joined this batch')
     where id = v_batch;
  end if;
  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'added', v_n, 'entries', v_rows);
end $fn$
$w$;

execute $w$
create or replace function public.dev_wait_report(p_hours integer default 24)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_cfg jsonb; v_base jsonb; v_rows jsonb := '[]'::jsonb; k text; v_kinds text[];
        v_since timestamptz; v_ev record; v_b jsonb; v_kills int; v_parks int;
        v_worst bigint; v_tot bigint := 0; v_n int := 0; v_med numeric; v_prev numeric;
        v_tone text; v_sub text; v_grace bigint; v_names jsonb;
begin
  perform _dev_guard();
  v_since := now() - make_interval(hours => greatest(coalesce(p_hours,24),1));
  select value->'wait_gate', coalesce((value->>'waiting_token_grace')::bigint,150000)
    into v_cfg, v_grace from dev_runner_config where key='worker_pool';
  v_base := coalesce(v_cfg->'baseline', '{}'::jsonb);
  v_kinds := array['merge','lease','db','rpc','grant','other'];
  -- the six wait types the spec names, worded once, here.
  v_names := jsonb_build_object('merge','Merge lane waits','lease','File lease waits',
                                'db','Database lane waits','rpc','RPC / timeout waits',
                                'grant','Journey grant waits','other','Other waits');

  foreach k in array v_kinds loop
    select count(*) filter (where e.kind in ('wait_end','wait_resume'))            as ends,
           coalesce(sum((e.detail->>'burn')::bigint) filter (where e.kind in ('wait_end','wait_resume')),0) as burn,
           coalesce(max((e.detail->>'burn')::bigint) filter (where e.kind in ('wait_end','wait_resume')),0) as worst,
           count(*) filter (where e.kind = 'wait_park')                            as parks
      into v_ev
      from dev_context_event e
     where e.at >= v_since
       and e.kind in ('wait_end','wait_resume','wait_park')
       and coalesce(e.detail->>'wait_kind','other') = k;

    v_b := coalesce(v_base->k, '{}'::jsonb);
    v_tot := v_tot + coalesce(v_ev.burn,0);
    v_n   := v_n + coalesce(v_ev.ends,0);
    v_tone := case when coalesce(v_ev.worst,0) > 5000 then 'danger'
                   when coalesce(v_ev.worst,0) > 0    then 'warning'
                   else 'success' end;
    v_sub := format('%s wait(s) · %s park(s) · worst %s tokens · before: %s',
                    coalesce(v_ev.ends,0), coalesce(v_ev.parks,0), coalesce(v_ev.worst,0),
                    coalesce(v_b->>'label','not measured'));
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key', k,
      'label', coalesce(v_names->>k, initcap(k) || ' waits'),
      'value', coalesce(v_ev.burn,0)::text || ' tokens',
      'sub', v_sub,
      'tone', v_tone));
  end loop;

  select count(*) into v_kills from dev_commands
   where needs_input_kind = 'waiting_burn' and coalesce(finished_at, heartbeat_at, created_at) >= v_since;
  select count(*) into v_parks from dev_context_event
   where kind = 'wait_park' and at >= v_since;

  -- median claim→complete, last 20 completed vs the 20 before them (item 8)
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
      'sub', format('grace %s tokens · target 0 in %sh', v_grace, greatest(coalesce(p_hours,24),1)),
      'tone', case when v_kills = 0 then 'success' else 'danger' end),
    jsonb_build_object('key','parks','label','Parked and released',
      'value', v_parks::text,
      'sub', 'each one freed a runner instead of holding it asleep',
      'tone', 'neutral'),
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
    'since_line', format('Last %sh · park over %ss, sleep under it · both locks unchanged',
                         greatest(coalesce(p_hours,24),1), coalesce((v_cfg->>'sleep_max_s')::int,60)),
    'rows', v_rows,
    'footnote', 'A wait must cost under 5,000 tokens. Over that, the session was thinking while it should have exited.');
end $fn$
$w$;
end
$fns$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. HOW LONG IS THIS WAIT? — measured, never guessed.
--    Under sleep_max_s the agent sleeps in the shell (spec item 7); over it the
--    session is released. The estimate reads what this lane ACTUALLY did the
--    last 20 times, so the threshold cannot be argued with.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE DOOR THE AGENT KNOCKS ON — sleep, park, or carry on.
--    It answers with a MODE and one backend sentence. The agent decides
--    nothing: that is the whole point of a change about not thinking.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. PARK NOW MEANS RELEASE (spec items 1 + 3).
--    Before: status stayed 'building' with claimed_by set, so the runner's very
--    next dev_cmd_claim answered "Already building #N" and the slot idled for
--    the whole wait. Now the row goes back to 'pending' — its own priority, its
--    own urgent flag, its steps, its branch, its spec items all untouched — and
--    is fenced out of the claim pool by wait_state='parked' until the blocker
--    clears. No new status value: every consumer already reads wait_state.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. UNPARK = BACK IN THE POOL AT ITS OWN PRIORITY (spec item 2).
--    The old one forced urgent=true, which is not "its own priority" — a parked
--    chore jumped ahead of everything Om had actually marked urgent.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. THE MOMENT THE BLOCKER FREES (spec item 2) — event-driven, not polled.
-- ═══════════════════════════════════════════════════════════════════════════


do $trg$
begin
  if to_regclass('public.file_leases') is not null then
    drop trigger if exists trg_c1819_wait_kick_lease on file_leases;
    create trigger trg_c1819_wait_kick_lease
      after delete on file_leases
      for each statement execute function _dev_wait_kick();
  end if;
  if to_regclass('public.deploy_queue') is not null then
    drop trigger if exists trg_c1819_wait_kick_merge on deploy_queue;
    create trigger trg_c1819_wait_kick_merge
      after update of status on deploy_queue
      for each statement execute function _dev_wait_kick();
  end if;
end
$trg$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. THE SWEEP is now the BACKSTOP, not the mechanism.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. dev_wait_poll uses the shared predicate (the 'waiting' bug, fixed once).
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. THE FENCE: a parked row is pending, and pending is claimable — so the
--    claim must skip it until the blocker clears, or park-and-release becomes
--    park-and-instantly-take-it-back.
--    Patched into the live definitions rather than pasted over them: these two
--    functions are edited by other commands, and a verbatim re-paste here would
--    silently revert whatever landed last. It fails LOUDLY if the anchor is gone.
-- ═══════════════════════════════════════════════════════════════════════════
do $fence$
declare f text; d text; n text;
begin
  if to_regclass('public.dev_commands') is null then return; end if;
  foreach f in array array['public.dev_cmd_claim(text,text[],text)',
                           'public.dev_cmd_claim_batch(text,text[],text,integer)'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(to_regprocedure(f));
    if position('c1819_park_fence' in d) > 0 then continue; end if;
    if position('c.status=''pending''' in d) = 0 then
      raise exception 'c1819: % no longer contains the claim anchor — the park fence would be silent', f;
    end if;
    n := replace(d, 'c.status=''pending''',
                 'c.status=''pending'' AND coalesce(c.wait_state,'''') <> ''parked'' /* c1819_park_fence */');
    execute n;
  end loop;
end
$fence$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. BATCH MERGES (spec item 6): a branch that arrives while the worker is
--     still merging joins THIS batch instead of paying for a whole pass of its
--     own. Absorb runs in the merge phase only — everything that deploys was
--     tested together, which is the property the lane exists for.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 11. THE PROOF (spec item 8) — the panel Om reads, computed here, printed
--     verbatim there. Nothing in this payload is recomputed in Dart.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- 12. THE BASELINE IS DATA. The 48 h measurement this change was written from
--     lives in config, so the panel's "before" column is a fact with a date on
--     it and not a number somebody typed into a widget.
-- ═══════════════════════════════════════════════════════════════════════════
do $base$
begin
if to_regclass('public.dev_commands') is null then return; end if;
update dev_runner_config
   set value = jsonb_set(value, '{wait_gate,baseline}', jsonb_build_object(
     'measured_on', '2026-09-06',
     'window_h', 48,
     'total_tokens', 2030000,
     'merge', jsonb_build_object('tokens', 1600000, 'events', 8,  'worst', 942000,
              'label', '1.60M over 8 events (worst 942k on #1812 behind batch 594)'),
     'lease', jsonb_build_object('tokens', 427414,  'events', 58, 'worst', 244000,
              'label', '427,414 over 58 events (#992 on shell_extra_routes.dart, 244k + 183k)'),
     'db',    jsonb_build_object('tokens', 0, 'events', 0, 'label', 'folded into the lane totals'),
     'rpc',   jsonb_build_object('tokens', 0, 'events', 0, 'label', 'folded into the lane totals'),
     'grant', jsonb_build_object('tokens', 0, 'events', 0, 'label', 'journey grants, not separately metered'),
     'other', jsonb_build_object('tokens', 0, 'events', 0, 'label', 'deploy lane, rg_check, rebaseline')))
 where key = 'worker_pool';
end
$base$;

do $copy$
begin
if to_regclass('public.dev_commands') is null or to_regclass('public.ui_copy') is null then return; end if;
insert into ui_copy(key, value) values
  ('dev_queue.wait_msg', to_jsonb('⏸ Parked — {reason}. The runner is free and the work is committed; this command resumes itself at its saved step when the blocker clears (checked every {after}s).'::text)),
  ('dev_queue.wait_clear_msg', to_jsonb('▶ Resuming — {reason}. Picking up at the first unfinished step.'::text)),
  ('dev_queue.wait_panel_title', to_jsonb('Waiting economy'::text))
on conflict (key) do update set value = excluded.value;
end
$copy$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 13. THE RESUME BLOCK STILL TELLS THE OLD TRUTH (spec item 4).
--     It ends with "WHILE WAITING … sleep and poll", which is #1817's rule and
--     is now wrong: a wait longer than a minute must PARK and EXIT. Patched in
--     place — loudly, so a silent no-match can never leave the old sentence up.
-- ═══════════════════════════════════════════════════════════════════════════
do $res$
declare d text; n text;
begin
  if to_regprocedure('public._dev_resume_block(jsonb)') is null then return; end if;
  d := pg_get_functiondef(to_regprocedure('public._dev_resume_block(jsonb)'));
  if position('c1819' in d) > 0 then return; end if;
  -- the two halves are written as separate literals joined by ||, so each is
  -- matched on its own. A miss RAISES: a silent no-match would leave the old
  -- sentence up and the next resumed build would go back to sleeping.
  if position('WHILE WAITING (merge lane, lease, batch): sleep and poll' in d) = 0
     or position('tokens spent while waiting are wasted' in d) = 0 then
    raise exception 'c1819: the resume block no longer carries the #1817 waiting sentence — patch it by hand';
  end if;
  n := replace(d, 'WHILE WAITING (merge lane, lease, batch): sleep and poll — do not think, summarise or re-plan; ',
        'WHILE WAITING (merge lane, lease, batch, grant): run devcmd.sh wait <id> <kind> [arg] and obey the ONE line it prints — a short wait sleeps in the shell, a long one PARKS AND RELEASES this runner and your turn ends there; ');
  n := replace(n, 'tokens spent while waiting are wasted and the budget gate will refuse you a second window.',
        'a parked row comes back to you at this same step with nothing to re-read, so never think, summarise or poll by hand while you wait (c1819).');
  execute n;
end
$res$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 14. THE PANEL'S PAYLOAD JOINS THE ONE SNAPSHOT THE SCREEN ALREADY READS.
--     dev_ctl_get() is where every runner block on that screen comes from, so
--     the waiting report rides it rather than adding a second round trip. Same
--     text patch discipline as the claim fence: loud on a missed anchor.
-- ═══════════════════════════════════════════════════════════════════════════
do $ctl$
declare d text; n text;
begin
  if to_regprocedure('public.dev_ctl_get()') is null then return; end if;
  d := pg_get_functiondef(to_regprocedure('public.dev_ctl_get()'));
  if position('c1819_waiting' in d) > 0 then return; end if;
  if position('''rc_health'', v_rc)' in d) = 0 then
    raise exception 'c1819: dev_ctl_get no longer ends with rc_health — wire the waiting block by hand';
  end if;
  n := replace(d, 'declare v jsonb; v_ctx jsonb;', 'declare v_wait jsonb; v jsonb; v_ctx jsonb;');
  n := replace(n, '  v := public.dev_ctl_get_core();',
    '  v := public.dev_ctl_get_core();
  begin v_wait := public.dev_wait_report(24);   /* c1819_waiting */
  exception when others then v_wait := jsonb_build_object(''has'', false);
  end;');
  n := replace(n, '''rc_health'', v_rc)', '''rc_health'', v_rc, ''waiting'', v_wait)');
  execute n;
end
$ctl$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 15. THE BACKSTOP FOLLOWS THE ROW.
--     _wait_burn_check only ever looked at status='building', which was the
--     only place a waiting row could be. A parked row is now PENDING, and the
--     one thing that could still go wrong is a session that read "stop now" and
--     carried on anyway. That is no longer a kill (the row is not held, so
--     there is nothing to take away) — it is an ALERT, because a park that did
--     not end a turn is exactly the failure this change exists to prevent and
--     it must not be invisible.
-- ═══════════════════════════════════════════════════════════════════════════
do $burn$
begin
if to_regclass('public.dev_commands') is null then return; end if;

execute $w$
create or replace function public._wait_park_burn_check(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r dev_commands%rowtype; v_turn bigint; v_burn bigint;
begin
  select * into r from dev_commands where id = p_id;
  if not found or coalesce(r.wait_state,'') <> 'parked' or r.status <> 'pending' then
    return jsonb_build_object('ok', true, 'watched', false);
  end if;
  select coalesce((value->'wait_gate'->>'turn_tokens')::bigint, 2000) into v_turn
    from dev_runner_config where key='worker_pool';
  v_burn := (coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0))
            - coalesce(r.wait_started_tokens, coalesce(r.cost_input_tokens,0)+coalesce(r.cost_output_tokens,0));
  if v_burn <= coalesce(v_turn,2000) then
    return jsonb_build_object('ok', true, 'watched', true, 'burn', greatest(v_burn,0));
  end if;
  insert into dev_context_event (command_id, agent, kind, ok, detail)
  values (p_id, coalesce(r.claimed_by,'parked'), 'wait_turn', false,
          jsonb_build_object('burn', v_burn, 'wait_kind', coalesce(r.wait_kind,'other'),
                             'note', 'tokens moved on a PARKED row — the session did not end its turn'));
  insert into rg_alerts(fingerprint, severity, kind, name, detail)
  values ('c1819_park_not_exited_' || p_id, 'warn', 'runner',
          'a parked command is still spending tokens',
          jsonb_build_object('command_id', p_id, 'burn', v_burn,
                             'wait_kind', coalesce(r.wait_kind,'other')))
  on conflict (fingerprint) do update
     set last_seen = now(), seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;
  -- the mark moves up, so the next tick measures the NEXT delta and one long
  -- overrun does not alert every minute for ever.
  update dev_commands set wait_started_tokens = coalesce(cost_input_tokens,0)+coalesce(cost_output_tokens,0)
   where id = p_id;
  return jsonb_build_object('ok', true, 'watched', true, 'burn', v_burn, 'alerted', true);
end $fn$
$w$;

if to_regclass('public.cron_task') is not null then
  update cron_task
     set work_sql = 'select coalesce((select jsonb_agg(public._wait_burn_check(id)) from dev_commands where status=''building''), ''[]''::jsonb)'
                 || ' || coalesce((select jsonb_agg(public._wait_park_burn_check(id)) from dev_commands where status=''pending'' and wait_state=''parked''), ''[]''::jsonb)'
   where name = 'wait_burn_watch'
     and work_sql is distinct from
         'select coalesce((select jsonb_agg(public._wait_burn_check(id)) from dev_commands where status=''building''), ''[]''::jsonb)'
      || ' || coalesce((select jsonb_agg(public._wait_park_burn_check(id)) from dev_commands where status=''pending'' and wait_state=''parked''), ''[]''::jsonb)';
end if;
end
$burn$;

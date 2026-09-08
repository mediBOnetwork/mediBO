-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1866 — the wait gate must never park on the command's OWN deploy lock,
-- and must obey worker_pool.wait_gate.park_enabled = false.
--
-- WHAT HAPPENED (#1863, 07 Sep 15:52 IST). The direct deploy from CMD #1859
-- took deploy_lock for #1863's OWN deploy. dev_wait_enter answered mode
-- 'sleep' (park_enabled is false, so the park branch was skipped) — but the
-- SLEEP path in devcmd.sh ends in an unconditional dev_cmd_park once its
-- budget expires, so 541 s later the row was parked, the runner released and
-- the whole context cold-read 3 minutes later. resume_count 1, 4.4M tokens on
-- a five-control wiring job. Two independent holes:
--   * the gate could not tell "my own deploy" from "somebody else's lane",
--     because deploy_lock never recorded WHOSE deploy it was; and
--   * park_enabled=false was honoured in exactly one branch of one function
--     and nowhere else — not in dev_cmd_park, not in the runner.
--
-- THIS FILE runs on the CONTROL PLANE (brorshtqrkyqqdhmhclw), the project the
-- dev queue lives on — psql "$(cat ~/.medibo/dev_dburl)" -f <this file>.
-- It is idempotent: run it as often as you like.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- ── 1. THE LOCK REMEMBERS WHOSE DEPLOY IT IS ────────────────────────────────
alter table public.deploy_lock add column if not exists command_id bigint;

-- A defaulted 4th parameter beside the live 3-arg function is the overload
-- trap: PostgREST resolves by NAME, so {p_agent,p_title,p_ttl_minutes} would
-- match both and raise. Drop first, always.
drop function if exists public.deploy_lock_try(text, text, integer);

create or replace function public.deploy_lock_try(
  p_agent text,
  p_title text,
  p_ttl_minutes integer default 25,
  p_command_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare l deploy_lock%rowtype; v_token uuid := gen_random_uuid(); v_mine boolean;
begin
  -- a build needs ~2 GB of scratch; starting without it wastes an hour and fails at the end
  declare v_free int; v_at timestamptz;
  begin
    select h.free_mb, h.reported_at into v_free, v_at
      from vm_health h order by h.reported_at desc limit 1;
    if v_free is not null and v_at > now() - interval '6 hours' and v_free < 1024 then
      return jsonb_build_object('ok', false, 'reason','low_disk',
        'free_mb', v_free,
        'instruction','Only ' || v_free || ' MB free on the VM. Run scripts/cleanup_worktrees.sh, call vm_disk_report with the new figure, then retry deploy_lock_try.');
    end if;
  end;

  select * into l from deploy_lock where id = 1 for update;

  if l.token is not null and l.expires_at > now() then
    -- CMD #1866 — MY OWN LOCK IS NOT A BLOCKER. A re-run of direct_deploy.sh
    -- for the same command used to sit in its 60-second retry loop waiting for
    -- itself until LOCK_WAIT_MAX_S, then fail the deploy. Same command AND the
    -- same agent is re-entrant: the TTL is refreshed and the SAME token is
    -- handed back, so the release still closes exactly one lock.
    v_mine := p_command_id is not null
          and l.command_id is not distinct from p_command_id
          and l.holder is not distinct from p_agent;
    if v_mine then
      update deploy_lock
         set expires_at = now() + make_interval(mins => greatest(coalesce(p_ttl_minutes,25),5)),
             title      = coalesce(p_title, l.title),
             renewed_at = now()
       where id = 1;
      return jsonb_build_object('ok', true, 'token', l.token, 'reacquired', true, 'mine', true,
        'label', public.deploy_lock_holder(p_command_id)->>'label',
        'expires_at', now() + make_interval(mins => greatest(coalesce(p_ttl_minutes,25),5)),
        'next_step','This lock was already yours (same command, same agent) — TTL refreshed, same token. Carry on with the deploy.');
    end if;
    return jsonb_build_object('ok', false, 'reason','busy',
      'held_by', l.holder, 'held_title', l.title, 'held_by_command', l.command_id,
      'mine', false,
      'label', public.deploy_lock_holder(p_command_id)->>'label',
      'held_for_minutes', round(extract(epoch from now() - l.acquired_at)/60)::int,
      'frees_in_minutes', greatest(round(extract(epoch from l.expires_at - now())/60)::int, 0),
      'instruction','Another deploy is in progress. Keep your branch ready, wait 60s and retry deploy_lock_try. Do NOT merge to main while another agent holds the lane.');
  end if;

  update deploy_lock
     set token = v_token, holder = coalesce(p_agent,'agent'), title = p_title,
         command_id = p_command_id,
         acquired_at = now(), renewals = 0,
         expires_at = now() + make_interval(mins => greatest(coalesce(p_ttl_minutes,25),5))
   where id = 1;

  return jsonb_build_object('ok', true, 'token', v_token, 'mine', true,
    'label', public.deploy_lock_holder(p_command_id)->>'label',
    'expires_at', now() + make_interval(mins => greatest(coalesce(p_ttl_minutes,25),5)),
    'next_step','Now: rebase onto the live base, re-run protected tests, build, THEN call deploy_claim_number(token, title, branch, commit).');
end $function$;

-- ── 2. WHO HOLDS IT, IN THE BACKEND'S OWN WORDS ─────────────────────────────
-- "deploy lock — #1863 (own)" vs "deploy lock — #1864" vs "deploy lock — free".
-- Every surface (the gate line, the gate log, the Deploy lane card, the busy
-- reply) prints THIS string; nothing re-derives ownership from a holder name.
create or replace function public.deploy_lock_holder(p_for_command bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare l deploy_lock%rowtype; v_agent text; v_mine boolean; v_who text; v_held int;
begin
  select * into l from deploy_lock where id = 1;
  if l.token is null or l.expires_at <= now() then
    return jsonb_build_object('busy', false, 'mine', false, 'command_id', null,
      'holder', null, 'held_s', 0, 'title', null,
      'label', 'deploy lock — free', 'tone', 'success');
  end if;
  if p_for_command is not null then
    select claimed_by into v_agent from dev_commands where id = p_for_command;
  end if;
  v_mine := (p_for_command is not null and l.command_id is not distinct from p_for_command)
         or (v_agent is not null and l.holder is not distinct from v_agent);
  v_who  := coalesce('#' || l.command_id::text, nullif(l.holder,''), '?');
  v_held := greatest(extract(epoch from now() - coalesce(l.acquired_at, now()))::int, 0);
  return jsonb_build_object('busy', true, 'mine', v_mine, 'command_id', l.command_id,
    'holder', l.holder, 'held_s', v_held, 'title', l.title,
    'label', 'deploy lock — ' || v_who || case when v_mine then ' (own)' else '' end,
    'tone', case when v_mine then 'info' else 'warning' end);
end $function$;

-- ── 3. EVERY GATE DECISION IS RECORDED ──────────────────────────────────────
-- #1863's park was legible only by reading four dev_context_event rows and
-- inferring the mode from their shape. kind, holder and decision, one row.
create table if not exists public.dev_wait_gate_log (
  id          bigserial primary key,
  command_id  bigint,
  agent       text,
  kind        text,
  holder      text,
  decision    text,          -- mine | free | sleep | hold | park | park-refused | stop
  eta_s       integer,
  reason      text,
  detail      jsonb not null default '{}'::jsonb,
  at          timestamptz not null default now()
);
create index if not exists dev_wait_gate_log_at_idx  on public.dev_wait_gate_log (at desc);
create index if not exists dev_wait_gate_log_cmd_idx on public.dev_wait_gate_log (command_id, id desc);

create or replace function public._dev_wait_gate_log(
  p_id bigint, p_agent text, p_kind text, p_holder text,
  p_decision text, p_eta_s integer, p_reason text, p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into dev_wait_gate_log (command_id, agent, kind, holder, decision, eta_s, reason, detail)
  values (p_id, p_agent, coalesce(nullif(p_kind,''),'other'), p_holder,
          p_decision, p_eta_s, p_reason, coalesce(p_detail,'{}'::jsonb));
exception when others then null;   -- the gate must never fail on its own log
end $function$;

-- The render-ready block. Dart prints these strings verbatim, in this order.
create or replace function public.dev_wait_gate_recent(p_limit integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_cfg jsonb; v_parks int;
begin
  v_cfg := _dev_wait_cfg();
  select count(*) into v_parks from dev_wait_gate_log
   where decision = 'park' and at > now() - interval '24 hours';

  select coalesce(jsonb_agg(x order by x_id desc), '[]'::jsonb) into v_rows from (
    select g.id as x_id,
           jsonb_build_object(
             'label',  '#' || g.command_id || ' · ' || coalesce(g.kind,'other'),
             -- one sentence, built HERE: who held the blocker, why the gate
             -- was entered, how long it thought it would take, and when.
             'detail', coalesce(g.holder, 'no holder') ||
                       coalesce(' — ' || nullif(g.reason,''), '') ||
                       coalesce(' · ~' || g.eta_s || 's', '') ||
                       ' · ' || to_char(g.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
             'value',  g.decision,
             'tone',   case g.decision
                         when 'mine'         then 'success'
                         when 'free'         then 'success'
                         when 'park-refused' then 'info'
                         when 'hold'         then 'info'
                         when 'sleep'        then 'neutral'
                         when 'park'         then 'danger'
                         else 'neutral' end,
             'at_label', to_char(g.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI')
           ) as x
      from dev_wait_gate_log g
     order by g.id desc
     limit greatest(coalesce(p_limit,8), 1)
  ) s;

  return jsonb_build_object(
    'has', jsonb_array_length(v_rows) > 0,
    'title', 'Wait gate',
    'subtitle', case when coalesce((v_cfg->>'park_enabled')::boolean, true)
                     then 'Parking is ON — a long blocker releases the runner and the next session re-reads everything.'
                     else 'Parking is OFF (wait_gate.park_enabled=false) — a blocked session sleeps or holds; it is never released and nothing is ever re-read.' end,
    'chip', case when coalesce((v_cfg->>'park_enabled')::boolean, true) then 'park ON' else 'park OFF' end,
    'chip_tone', case when coalesce((v_cfg->>'park_enabled')::boolean, true) then 'warning' else 'success' end,
    'parks_24h_label', case when v_parks = 0 then 'No parks in the last 24h.'
                            else v_parks || ' park(s) in the last 24h.' end,
    'parks_24h_tone', case when v_parks = 0 then 'success' else 'danger' end,
    'empty', 'No gate decisions recorded yet.',
    'rows', v_rows);
end $function$;

commit;

begin;

-- ── 4. THE BLOCKER KNOWS WHETHER IT IS MINE ─────────────────────────────────
create or replace function public._dev_wait_free(p_id bigint, p_kind text, p_blocker jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_entry bigint; v_st text; v_paths text[]; v_free boolean; v_why text;
        v_holder text; v_mine boolean := false; d deploy_direct%rowtype;
begin
  if coalesce(p_kind,'other') = 'merge' then
    if not merge_lane_enabled() then
      -- CMD #1859: nothing will ever drain the queue — say what to do instead.
      return jsonb_build_object('free', true, 'mine', true,
        'why', format('the merge lane is OFF (worker_pool.merge_lane.enabled=false) — deploy your branch yourself: devcmd.sh deploy_direct %s <agent> "<title>" <branch>', p_id));
    end if;
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
  elsif coalesce(p_kind,'') = 'deploy' then
    -- CMD #1866 — a direct deploy is THIS COMMAND'S OWN work. It is still a
    -- thing to wait for, but it is never somebody else's lane and it must
    -- never cost a cold resume, so it is marked mine.
    select * into d from deploy_direct where command_id = p_id order by id desc limit 1;
    v_mine := true;
    if d.id is null then
      v_free := true;
      v_why  := format('no direct deploy is running for #%s — start it: devcmd.sh deploy_direct %s <agent> "<title>" <branch>', p_id, p_id);
    elsif d.status in ('deployed','failed') then
      v_free := true;
      v_why  := deploy_direct_line(d);
    else
      v_free := false;
      v_why  := deploy_direct_line(d);
    end if;
  elsif coalesce(p_kind,'') = 'lease' then
    v_paths := coalesce((select array_agg(value #>> '{}')
                           from jsonb_array_elements(coalesce(p_blocker->'paths','[]'::jsonb))), '{}');
    if v_paths = '{}' then
      v_free := true; v_why := 'no path named'; v_mine := true;
    else
      select fl.worker into v_holder from file_leases fl
       where fl.path = any(v_paths) and fl.command_id is distinct from p_id limit 1;
      v_free := v_holder is null;
      v_why  := case when v_free then 'every path is free'
                     else 'a path is still leased by ' || v_holder end;
      v_mine := v_free;
    end if;
  else
    v_free := true;
    v_why  := 'waiting out ' || coalesce(p_kind,'other');
  end if;
  return jsonb_build_object('free', coalesce(v_free,false), 'why', v_why,
                            'mine', coalesce(v_mine,false));
end $function$;

-- ── 5. THE GATE ─────────────────────────────────────────────────────────────
create or replace function public.dev_wait_enter(p_id bigint, p_agent text, p_kind text, p_reason text default null::text, p_blocker jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_cfg jsonb; v_free jsonb; v_eta int; v_sleep int;
        v_reason text; v_park jsonb; v_hold jsonb; v_need jsonb; v_held int;
        v_holdable boolean; v_why text;
        v_lock jsonb; v_holder text; v_mine boolean; v_can_park boolean;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  v_cfg      := _dev_wait_cfg();
  v_can_park := coalesce((v_cfg->>'park_enabled')::boolean, true);
  -- CMD #1866 — who holds the deploy lock, said once, in the backend's words.
  v_lock     := deploy_lock_holder(p_id);
  v_holder   := v_lock->>'label';

  if r.status <> 'building' then
    perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'stop', null, 'row is ' || r.status);
    return jsonb_build_object('ok', true, 'mode', 'stop', 'can_park', v_can_park, 'holder', v_holder,
      'line', format('#%s is %s, not building — stop here and let the queue hand it out again.', p_id, r.status));
  end if;

  v_reason := coalesce(nullif(p_reason,''), 'queued in the ' || coalesce(p_kind,'lane') || ' lane');
  v_free   := _dev_wait_free(p_id, p_kind, p_blocker);
  -- "Mine" = my own deploy (the lock carries my command id, or the agent
  -- holding it is the agent holding this row) or my own already-free blocker.
  v_mine   := coalesce((v_free->>'mine')::boolean, false)
           or coalesce((v_lock->>'mine')::boolean, false);

  -- Never sleep on nothing. A blocker that is already gone is a straight carry-on.
  if coalesce((v_free->>'free')::boolean, false) and coalesce(p_kind,'other') in ('merge','lease','deploy') then
    -- A hold that ends is an END, not an abandonment: close it so the seconds
    -- and the burn land on the row instead of leaking into the next wait.
    if coalesce(r.wait_state,'') = 'holding' then perform dev_wait_end(p_id, v_free->>'why'); end if;
    perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'free', 0, v_free->>'why');
    return jsonb_build_object('ok', true, 'mode', 'free', 'reason', v_free->>'why',
      'can_park', v_can_park, 'holder', v_holder, 'mine', v_mine,
      'line', format('Not blocked — %s. Carry on from your next step.', v_free->>'why'));
  end if;

  v_eta   := _dev_wait_eta_s(p_id, p_kind, p_blocker);
  v_sleep := (v_cfg->>'sleep_max_s')::int;
  v_need  := _dev_wait_runner_needed(p_id);
  v_held  := case when coalesce(r.wait_state,'') = 'holding'
                   and coalesce(r.wait_kind,'') = coalesce(p_kind,'other')
                  then greatest(0, extract(epoch from (now() - coalesce(r.wait_since, now())))::int)
                  else 0 end;

  -- SHORT: one blocking shell sleep inside a single Bash call. Nothing is
  -- released either way, so this no longer depends on park_enabled — it used
  -- to, which is why a short wait with park OFF skipped straight past it.
  if v_eta <= v_sleep then
    perform dev_wait_begin(p_id, p_agent, p_kind, v_reason, p_blocker);
    perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'sleep', v_eta, v_reason);
    return jsonb_build_object('ok', true, 'mode', 'sleep',
      'sleep_s', least(greatest(v_eta, 5), v_sleep),
      'poll_s',  least((v_cfg->>'poll_s')::int, v_sleep),
      'eta_s',   v_eta, 'can_park', v_can_park, 'holder', v_holder, 'mine', v_mine,
      'line', format('Short wait (~%ss) — sleeping in the shell, no session released.', v_eta));
  end if;

  -- ── MINE: MY OWN DEPLOY IS NOT A BLOCKER (CMD #1866) ──────────────────────
  -- #1863 parked on the deploy lock that its OWN direct deploy was holding and
  -- paid a full cold re-read for it. The lock now carries a command id, so the
  -- gate can tell "mine" from "somebody else's lane" — and mine can never park,
  -- whatever the eta says or whoever else wants a runner.
  if v_mine then
    v_hold := _dev_wait_hold_begin(p_id, p_agent, p_kind, v_reason, p_blocker, v_eta);
    perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'mine', v_eta, v_reason,
                               jsonb_build_object('lock', v_lock, 'held_s', v_held));
    return jsonb_build_object('ok', true, 'mode', 'hold', 'mine', true, 'eta_s', v_eta,
      'sleep_s', (v_cfg->>'max_wait_s')::int,
      'poll_s',  (v_cfg->>'poll_s')::int,
      'held_s',  v_held, 'can_park', false, 'holder', v_holder, 'lock', v_lock,
      'line', format('%s — this is your OWN work, not a blocker (~%ss). The session stays alive and idles; %s. Do NOT plan, summarise or re-read anything.',
                     v_holder, v_eta,
                     case when v_held > 0 then 'held ' || _fmt_dur(v_held) || ' so far, nothing re-read'
                          else 'nothing is released and nothing will be re-read' end));
  end if;

  -- ── MIDDLE: HOLD. The whole point of CHANGE #1856. ────────────────────────
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
    perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'hold', v_eta, v_reason,
                               jsonb_build_object('held_s', v_held, 'runner_needed', v_need));
    return jsonb_build_object('ok', true, 'mode', 'hold', 'eta_s', v_eta,
      'sleep_s', (v_cfg->>'max_wait_s')::int,
      'poll_s',  (v_cfg->>'poll_s')::int,
      'held_s',  v_held, 'can_park', v_can_park, 'holder', v_holder,
      'runner_needed', v_need,
      'line', format('Holding — %s (~%ss). The session stays alive and idles; %s. Do NOT plan, summarise or re-read anything.',
                     v_reason, v_eta,
                     case when v_held > 0 then 'held ' || _fmt_dur(v_held) || ' so far, nothing re-read'
                          else 'no context will be re-read' end));
  end if;

  -- ── PARK IS OFF: HOLD ANYWAY (CMD #1866, spec item 2) ─────────────────────
  -- park_enabled=false means exactly one thing — no cold resume, ever. The
  -- gate may only sleep or hold. It used to answer 'sleep' here and leave the
  -- parking to the runner, which is how #1863 parked with park off.
  if not v_can_park then
    v_hold := _dev_wait_hold_begin(p_id, p_agent, p_kind, v_reason, p_blocker, v_eta);
    perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'park-refused', v_eta, v_why,
                               jsonb_build_object('held_s', v_held, 'runner_needed', v_need));
    return jsonb_build_object('ok', true, 'mode', 'hold', 'eta_s', v_eta,
      'sleep_s', (v_cfg->>'max_wait_s')::int,
      'poll_s',  (v_cfg->>'poll_s')::int,
      'held_s',  v_held, 'can_park', false, 'park_why', v_why, 'holder', v_holder,
      'runner_needed', v_need,
      'line', format('Park is off (wait_gate.park_enabled=false) — holding instead of parking: %s (~%ss). The session stays alive and idles; nothing is released and nothing will be re-read. Do NOT plan, summarise or re-read anything.',
                     v_reason, v_eta));
  end if;

  -- ── LONG / NEEDED ELSEWHERE: park and RELEASE. This is a COLD resume. ─────
  if coalesce(r.wait_state,'') = 'holding' then perform dev_wait_end(p_id, 'hold expired — parking'); end if;
  v_park := dev_cmd_park(p_id, coalesce(p_kind,'other'), v_reason, coalesce(p_blocker,'{}'::jsonb), v_eta);
  perform _dev_wait_gate_log(p_id, p_agent, p_kind, v_holder, 'park', v_eta, v_why,
                             jsonb_build_object('runner_needed', v_need));
  return jsonb_build_object('ok', true, 'mode', 'park', 'eta_s', v_eta, 'park', v_park,
    'cold', true, 'park_why', v_why, 'runner_needed', v_need,
    'can_park', true, 'holder', v_holder,
    'line', coalesce(v_park->>'agent_line',
      format('Parked — %s (~%ss). The runner is free; this row resumes itself at its saved step.', v_reason, v_eta)));
end $function$;

commit;

begin;

-- ── 6. PARK REFUSES ITSELF WHILE PARKING IS OFF ─────────────────────────────
-- The gate above will not ASK for a park while park_enabled=false, but the
-- runner had three other places that called dev_cmd_park directly (the wait
-- door's expired-sleep tail, the bounded completion retry, the spool flush).
-- One switch, honoured in the one place every caller has to pass through.
create or replace function public.dev_cmd_park(p_id bigint, p_kind text, p_reason text, p_blocker jsonb default '{}'::jsonb, p_retry_after_s integer default null::integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; v_after int; v_label text; v_tok bigint; v_next text; v_line text; v_cold int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building', 'status', r.status);
  end if;

  v_label := coalesce(nullif(p_reason,''),
    (select label from dev_fail_rule where kind = p_kind and enabled order by ord limit 1),
    _c_or('dev_queue.wait_generic','Waiting on a blocker'));

  -- CMD #1866 — park_enabled=false means NO COLD RESUME, EVER. A park is the
  -- one thing that tears the session down and makes the next one re-read the
  -- whole context, so the switch has to bite here, not only in the gate.
  if not coalesce((_dev_wait_cfg()->>'park_enabled')::boolean, true) then
    perform _dev_wait_gate_log(p_id, r.claimed_by, p_kind,
              deploy_lock_holder(p_id)->>'label', 'park-refused', p_retry_after_s, v_label,
              jsonb_build_object('called', 'dev_cmd_park', 'blocker', coalesce(p_blocker,'{}'::jsonb)));
    return jsonb_build_object('ok', false, 'reason', 'park_disabled', 'id', p_id,
      'kind', coalesce(p_kind,'other'), 'parked', false, 'failed', false,
      'agent_line', format('Parking is off (wait_gate.park_enabled=false) — #%s stays yours and this session stays alive. Sleep on the blocker instead and re-run the identical command until it clears: devcmd.sh wait %s %s. Do NOT summarise, re-plan or re-read anything.',
                           p_id, p_id, coalesce(p_kind,'other')),
      'note', 'no cold resume while park_enabled=false — the gate holds instead');
  end if;

  v_after := coalesce(p_retry_after_s,
    (select retry_after_s from dev_fail_rule where kind = p_kind and enabled order by ord limit 1), 120);
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
end $function$;

-- ── 7. THE POLL PRINTS THE COMMAND THAT ACTUALLY RE-ENTERS ──────────────────
-- A hold is re-entered by running the IDENTICAL printed command. For kind
-- 'deploy' the line used to print the wait REASON as a shell argument
-- ("devcmd.sh wait 1866 deploy 'own deploy running…'"); the door for a direct
-- deploy is deploy_wait.
create or replace function public.dev_wait_poll(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r dev_commands%rowtype; v_cfg jsonb; v_f jsonb; v_free boolean; v_why text;
        v_waited int; v_burn bigint; v_hold text; v_args text; v_holding boolean;
        v_cmd text;
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

  if coalesce(r.wait_kind,'other') in ('merge','lease','deploy') then
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

  if coalesce(r.wait_kind,'other') = 'deploy' then
    v_cmd := format('devcmd.sh deploy_wait %s', p_id);
  else
    v_args := case coalesce(r.wait_kind,'other')
                when 'merge' then coalesce(' ' || (r.wait_blocker->>'entry_id'), '')
                when 'lease' then coalesce((select ' ' || string_agg(value #>> '{}', ' ')
                                              from jsonb_array_elements(coalesce(r.wait_blocker->'paths','[]'::jsonb))), '')
                else coalesce(' ' || quote_literal(r.wait_reason), '')
              end;
    v_cmd := format('devcmd.sh wait %s %s%s', p_id, coalesce(r.wait_kind,'other'), v_args);
  end if;

  v_hold := format('Still %s after %s — %s. %s again: %s. Do NOT plan, summarise or re-read anything.',
                   case when v_holding then 'holding' else 'waiting' end,
                   _fmt_dur(v_waited), v_why,
                   case when v_holding then 'Hold' else 'Sleep' end,
                   v_cmd);

  return jsonb_build_object('ok', true, 'free', v_free, 'reason', v_why,
    'mode', case when v_holding then 'hold' else 'sleep' end,
    'holding', v_holding,
    'mine', coalesce((v_f->>'mine')::boolean, false),
    'holder', deploy_lock_holder(p_id)->>'label',
    'polls', coalesce(r.wait_polls,0) + 1, 'waited_s', v_waited,
    'waited_label', _fmt_dur(v_waited),
    'burn', greatest(0, coalesce(v_burn,0)), 'turns', coalesce(r.wait_turns,0),
    'hold_line', v_hold,
    'poll_s', (v_cfg->>'poll_s')::int);
end $function$;

commit;

-- ── 8. THE DEPLOY LANE CARD SAYS WHO HOLDS THE LOCK, AND WHAT THE GATE DID ──
-- deploy_lane_status() is 180 lines of payload that nothing else in this file
-- touches, so it is PATCHED rather than retyped: two anchored insertions, and
-- the patch refuses to run twice (it looks for its own key first) and raises
-- if an anchor has moved instead of silently shipping the old payload.
do $patch$
declare v_def text; v_before text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p where p.proname = 'deploy_lane_status' and p.pronamespace = 'public'::regnamespace;
  if v_def is null then
    raise exception 'deploy_lane_status() not found on this database';
  end if;
  if position('lock_label' in v_def) > 0 then
    raise notice 'CMD #1866: deploy_lane_status already carries lock_label — nothing to patch';
    return;
  end if;

  v_before := v_def;
  v_def := replace(v_def,
    '      ''renewal_tone'', v_ren_tone),',
    '      ''renewal_tone'', v_ren_tone,' || E'\n' ||
    '      -- CMD #1866 — WHOSE deploy holds the lock, said once by the backend.' || E'\n' ||
    '      ''lock_label'', public.deploy_lock_holder(null)->>''label'',' || E'\n' ||
    '      ''lock_tone'',  public.deploy_lock_holder(null)->>''tone''),');
  if v_def = v_before then
    raise exception 'CMD #1866: the renewal_tone anchor moved in deploy_lane_status() — patch by hand';
  end if;

  v_before := v_def;
  v_def := replace(v_def,
    '    ''config'', cfg);',
    '    -- CMD #1866 — the wait gate''s own decisions: kind, holder, verdict.' || E'\n' ||
    '    ''gate'', case when to_regproc(''public.dev_wait_gate_recent'') is not null' || E'\n' ||
    '                  then public.dev_wait_gate_recent(8)' || E'\n' ||
    '                  else jsonb_build_object(''has'', false) end,' || E'\n' ||
    '    ''config'', cfg);');
  if v_def = v_before then
    raise exception 'CMD #1866: the config anchor moved in deploy_lane_status() — patch by hand';
  end if;

  execute v_def;
  raise notice 'CMD #1866: deploy_lane_status patched (lock_label + gate)';
end $patch$;

-- ── 9. PROOF, RUN AT APPLY TIME ─────────────────────────────────────────────
do $proof$
declare v jsonb;
begin
  v := public.deploy_lock_holder(null);
  if v->>'label' is null then raise exception 'deploy_lock_holder returned no label'; end if;
  raise notice 'lock: %', v->>'label';
  v := public.deploy_lane_status(3);
  if v->'lane'->>'lock_label' is null then raise exception 'deploy_lane_status has no lane.lock_label'; end if;
  if v->'gate' is null then raise exception 'deploy_lane_status has no gate block'; end if;
  raise notice 'lane.lock_label: % · gate.has: %', v->'lane'->>'lock_label', v->'gate'->>'has';
end $proof$;

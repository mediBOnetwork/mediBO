-- CHANGE #1836 — A DEAD WORKER IS NOT A FAILED BATCH.
--
-- 6 Sep, 10:41 → 11:42 UTC: batches 615, 616, 617, 618, 619 and 620 all read
-- 'failed' and nothing reached production for an hour, while every one of the
-- builds behind them had finished. Five separate things were wearing the word
-- "failed":
--
--   615  a real red journey (the smoke gate doing its job)
--   616  the merge worker SIGKILLed by systemd's 90 s stop-timeout mid-batch
--   617  swept by deploy_lane_sweep — same cause, no note saying so
--   618  swept by deploy_lane_sweep
--   619  deploy.sh exit 1 (boot-gate flake), the note carrying only the number
--   620  the smoke gate crashed on a 503 PGRST002 from its OWN reporting RPC
--
-- Only 615 was a failure. The other five were a dead worker, a flaky local
-- server and a PostgREST schema-cache reload — and each one burned an
-- `attempts` on every queue entry it held, so two of them in a row permanently
-- fail a branch that never failed once.
--
-- This migration separates the two states in the DATABASE, which is the only
-- place the lane agrees on anything:
--   * a swept batch is 'expired', never 'failed', and its entries go back to
--     'waiting' with `attempts` UNTOUCHED and a `sweeps` counter of its own
--   * merge_batch_error() puts the actual error line on the batch, so the note
--     stops being an exit code
--   * two genuine failures in a row raise a crit alert, once per streak
--   * merge_batch_reclaim() lets a restarted worker adopt what it was killed in
--   * deploy_lane_status() prints the recent batches and their real notes, so
--     an hour of this is visible on the card instead of only in the journal
--
-- Idempotent: every object is create-or-replace / add-column-if-not-exists.

-- ── the sweep counter: a dead worker must not spend a branch's attempts ─────
alter table deploy_queue add column if not exists sweeps integer not null default 0;
comment on column deploy_queue.sweeps is
  'CHANGE #1836 — how many times this entry was requeued because its BATCH died '
  '(worker killed, lane swept). Separate from attempts, which counts genuine '
  'failures, because a killed worker is not evidence about the branch.';

-- ── config defaults, so the knobs exist before anything reads them ──────────
insert into dev_runner_config(key, value)
values ('merge_queue', jsonb_build_object('max_sweeps', 5, 'fail_alert_streak', 2))
on conflict (key) do update
  set value = dev_runner_config.value
            || jsonb_build_object(
                 'max_sweeps',        coalesce(dev_runner_config.value->'max_sweeps', to_jsonb(5)),
                 'fail_alert_streak', coalesce(dev_runner_config.value->'fail_alert_streak', to_jsonb(2)));

-- ── 1. the error line lands ON the batch ───────────────────────────────────
-- merge_worker.sh reads .deploy_error (written by deploy.sh, CHANGE #1836) and
-- calls this. The note stops being "deploy.sh exit 1" and starts being the line
-- that actually stopped the deploy; the stderr tail goes in the log so the card
-- can show it without anyone opening merge_worker.journal.
create or replace function public.merge_batch_error(
  p_batch  bigint,
  p_step   text,
  p_exit   integer default null,
  p_error  text    default null,
  p_tail   text    default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare b deploy_batch%rowtype; v_line text;
begin
  perform _dev_guard();
  if coalesce(btrim(p_step), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'step_required');
  end if;
  v_line := nullif(btrim(coalesce(p_error, '')), '');
  update deploy_batch
     set touched_at = now(),
         note = case when v_line is null then note
                     else left(coalesce(p_step, 'deploy') || ': ' || v_line, 900) end,
         log  = coalesce(log, '[]'::jsonb) || jsonb_build_object(
                  'at', now(), 'phase', 'error', 'step', p_step, 'exit', p_exit,
                  'error', left(coalesce(v_line, ''), 900),
                  'stderr', left(coalesce(p_tail, ''), 4000))
   where id = p_batch
  returning * into b;
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'no_such_batch'); end if;
  return jsonb_build_object('ok', true, 'batch_id', b.id, 'step', p_step,
                            'exit', p_exit, 'note', b.note);
end $fn$;
revoke all on function public.merge_batch_error(bigint, text, integer, text, text) from public;
revoke all on function public.merge_batch_error(bigint, text, integer, text, text) from anon;

-- ── 2. two genuine failures in a row is an alert, not a pattern to notice ───
-- Streak counts only batches that actually reached a verdict: 'deployed' or
-- 'failed'. An 'expired' batch is neither — a dead worker must not be able to
-- either raise this alert or reset it.
create or replace function public._deploy_batch_fail_streak()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  with verdicts as (
    select id, status, closed_at, note,
           row_number() over (order by closed_at desc, id desc) as rn
      from deploy_batch
     where status in ('deployed','failed') and closed_at is not null),
  streak as (
    select count(*)::int as n
      from verdicts
     where rn <= coalesce((select min(rn) from verdicts where status = 'deployed'), 1000000) - 1)
  select jsonb_build_object(
    'streak', coalesce((select n from streak), 0),
    'batches', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', id, 'note', left(coalesce(note,''), 300), 'closed_at', closed_at)
                  order by id desc)
                 from verdicts
                where status = 'failed'
                  and rn <= coalesce((select min(rn) from verdicts where status = 'deployed'), 1000000) - 1),
               '[]'::jsonb));
$fn$;

create or replace function public._deploy_batch_fail_alert()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare cfg jsonb := _mq_cfg(); v jsonb; v_need int; v_streak int;
begin
  v_need := greatest(coalesce((cfg->>'fail_alert_streak')::int, 2), 2);
  v := public._deploy_batch_fail_streak();
  v_streak := coalesce((v->>'streak')::int, 0);
  if v_streak < v_need then
    return jsonb_build_object('ok', true, 'alerted', false, 'streak', v_streak, 'need', v_need);
  end if;
  -- One row per streak, not one per batch: the fingerprint names the OLDEST
  -- batch still in the streak, so a continuing outage keeps updating the same
  -- alert and a new outage opens a new one.
  insert into rg_alerts (fingerprint, severity, kind, name, detail)
  values (md5('deploy_lane|fail_streak|' ||
              coalesce((select min((e->>'id')::bigint)::text
                          from jsonb_array_elements(v->'batches') e), 'x')),
          'crit', 'deploy_lane',
          format('%s deploy batches failed in a row — nothing is reaching production', v_streak),
          jsonb_build_object('streak', v_streak, 'batches', v->'batches',
                             'hint', 'Each note is the real error line (CHANGE #1836). '
                                  || 'An expired batch is a dead worker and is not counted here.'))
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
        name = excluded.name, detail = excluded.detail, severity = 'crit';
  return jsonb_build_object('ok', true, 'alerted', true, 'streak', v_streak, 'need', v_need);
end $fn$;

-- ── 3. the sweep: expired, requeued, and never a failure ───────────────────
create or replace function public.deploy_lane_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare cfg jsonb := _mq_cfg(); v_ttl int; v_regs int := 0; v_locks int := 0;
        v_q int := 0; v_dead int := 0; v_lost int := 0;
        v_bucket text := to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24');
        v_names text; v_max_sweeps int;
begin
  v_ttl := greatest(coalesce((cfg->>'claim_ttl_minutes')::int, 20), 5);
  v_max_sweeps := greatest(coalesce((cfg->>'max_sweeps')::int, 5), 1);

  -- a registry row still 'claimed' past the TTL is a dead claim, not a build
  with dead as (
    select change_no, title, agent from deploy_registry
     where status = 'claimed' and claimed_at < now() - make_interval(mins => v_ttl))
  update deploy_registry r
     set status = 'expired', expired_at = now()
    from dead d where r.change_no = d.change_no;
  get diagnostics v_regs = row_count;

  -- an expired lock left behind by a killed worker
  update deploy_lock set token = null, holder = null, title = null,
                         acquired_at = null, expires_at = null,
                         renewals = 0, renewed_at = null
   where id = 1 and token is not null and expires_at < now();
  get diagnostics v_locks = row_count;

  -- WHICH batches are dead. Liveness is the newest of the log, touched_at (the
  -- CHANGE #1822 renewal ticker) and opened_at: a batch renewing its lane is
  -- alive however long its upload takes.
  create temp table if not exists _sweep_dead_batch(id bigint primary key) on commit drop;
  delete from _sweep_dead_batch;
  insert into _sweep_dead_batch(id)
  select id from deploy_batch
   where status in ('merging','testing','deploying')
     and greatest(coalesce((select max((e->>'at')::timestamptz)
                              from jsonb_array_elements(coalesce(log,'[]'::jsonb)) e), opened_at),
                  coalesce(touched_at, opened_at))
         < now() - make_interval(mins => v_ttl);

  -- THE FIX. These entries' batch died with its worker; the BRANCH said nothing
  -- either way, so `attempts` is not touched — `sweeps` is. Before #1836 two
  -- worker deaths (a systemd restart is enough for one) failed a branch that had
  -- never been tested, and its command's deploy number was gone with it.
  update deploy_queue q
     set status = case when q.sweeps + 1 >= v_max_sweeps then 'failed' else 'waiting' end,
         batch_id = null, batched_at = null, sweeps = q.sweeps + 1,
         reason = case when q.sweeps + 1 >= v_max_sweeps
                       then format('batch died under this branch %s times — giving up', q.sweeps + 1)
                       else format('batch %s died before it deployed (worker gone) — requeued, attempt count untouched', q.batch_id) end,
         finished_at = case when q.sweeps + 1 >= v_max_sweeps then now() end
   where q.status in ('batched','merged')
     and q.batch_id in (select id from _sweep_dead_batch);
  get diagnostics v_q = row_count;
  select count(*) into v_lost from deploy_queue
   where status = 'failed' and finished_at > now() - interval '5 seconds' and sweeps >= v_max_sweeps;

  -- 'expired' — a dead worker, not a verdict. merge_batch_tree() resumes from it
  -- (widened below), _deploy_batch_fail_streak() ignores it, and the card says so.
  update deploy_batch
     set status = 'expired', closed_at = now(), touched_at = now(),
         note = left(trim(coalesce(note,'') || ' · worker died mid-batch — no heartbeat for '
                || v_ttl || 'm; entries requeued for retry, not failed'), 900),
         log = coalesce(log,'[]'::jsonb) || jsonb_build_object(
                 'at', now(), 'phase', 'expired', 'ttl_minutes', v_ttl,
                 'note', 'swept by deploy_lane_sweep — worker liveness lost')
   where id in (select id from _sweep_dead_batch);
  get diagnostics v_dead = row_count;

  if (v_regs + v_locks + v_q + v_dead) > 0 and coalesce((cfg->>'sweep_alert')::boolean, true) then
    select string_agg(change_no::text, ', ' order by change_no) into v_names
      from deploy_registry where expired_at > now() - interval '2 minutes';
    insert into rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('deploy_lane|stale|' || v_bucket),
            case when v_lost > 0 then 'crit' else 'warn' end, 'deploy_lane',
            format('deploy lane swept %s stale claim(s), %s lock(s), %s queue entr(y/ies), %s dead batch(es)',
                   v_regs, v_locks, v_q, v_dead),
            jsonb_build_object('expired_changes', v_names, 'ttl_minutes', v_ttl,
                               'dead_batches', v_dead, 'requeued_entries', v_q,
                               'given_up_entries', v_lost, 'max_sweeps', v_max_sweeps,
                               'note', 'A swept batch is expired, not failed (CHANGE #1836) — '
                                    || 'its entries keep their attempt count and are retried.'))
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          severity = excluded.severity, name = excluded.name, detail = excluded.detail;
  end if;

  return jsonb_build_object('ok', true, 'expired_claims', v_regs,
    'released_locks', v_locks, 'requeued_entries', v_q, 'dead_batches', v_dead,
    'given_up_entries', v_lost, 'max_sweeps', v_max_sweeps, 'ttl_minutes', v_ttl);
end $fn$;

-- ── 4. a restarted worker adopts what it was killed in ─────────────────────
-- merge_worker.sh calls this on boot. Without it a SIGKILLed worker's batch sat
-- 'deploying' with the lane token held until the sweep noticed it up to 20
-- minutes later — batch 617 opened at 11:07 and was not closed until 11:31.
create or replace function public.merge_batch_reclaim(p_agent text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare cfg jsonb := _mq_cfg(); v_max_sweeps int; r record;
        v_batches jsonb := '[]'::jsonb; v_q int := 0; v_n int := 0; v_freed boolean := false;
begin
  perform _dev_guard();
  if coalesce(btrim(p_agent), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'agent_required');
  end if;
  v_max_sweeps := greatest(coalesce((cfg->>'max_sweeps')::int, 5), 1);

  for r in select * from deploy_batch
            where agent = p_agent and status in ('merging','testing','deploying')
            order by id loop
    update deploy_queue q
       set status = case when q.sweeps + 1 >= v_max_sweeps then 'failed' else 'waiting' end,
           batch_id = null, batched_at = null, sweeps = q.sweeps + 1,
           reason = format('batch %s was orphaned by a worker restart — requeued, attempt count untouched', r.id),
           finished_at = case when q.sweeps + 1 >= v_max_sweeps then now() end
     where q.batch_id = r.id and q.status in ('batched','merged');
    v_q := v_q + (select count(*)::int from deploy_queue where batch_id is null and sweeps > 0
                   and reason like 'batch ' || r.id || ' was orphaned%');
    update deploy_batch
       set status = 'expired', closed_at = now(), touched_at = now(),
           note = left(trim(coalesce(note,'') || ' · orphaned by a worker restart — reclaimed by '
                  || p_agent || ', entries requeued for retry'), 900),
           log = coalesce(log,'[]'::jsonb) || jsonb_build_object(
                   'at', now(), 'phase', 'expired', 'note', 'reclaimed on worker boot', 'agent', p_agent)
     where id = r.id;
    -- release the lane only if this dead batch still holds it
    update deploy_lock set token = null, holder = null, title = null, acquired_at = null,
                           expires_at = null, renewals = 0, renewed_at = null
     where id = 1 and token = r.token;
    if found then v_freed := true; end if;
    if r.change_no is not null then
      update deploy_registry set status = 'expired', expired_at = now()
       where change_no = r.change_no and status = 'claimed';
    end if;
    v_batches := v_batches || jsonb_build_object('id', r.id, 'change_no', r.change_no,
                                                 'status_was', r.status);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'reclaimed', v_n, 'batches', v_batches,
    'requeued_entries', v_q, 'lane_released', v_freed,
    'message', case when v_n = 0 then 'Nothing orphaned — clean start.'
      else format('%s orphaned batch(es) expired and their branches requeued; a killed worker is not a failed batch.', v_n) end);
end $fn$;
revoke all on function public.merge_batch_reclaim(text) from public;
revoke all on function public.merge_batch_reclaim(text) from anon;

-- ── 5. resume must look at expired batches too ─────────────────────────────
-- merge_batch_tree() searched for `status = 'failed'`. The moment a swept batch
-- became 'expired' that search would find nothing and every resume this change
-- depends on would silently stop working.
create or replace function public.merge_batch_tree(p_batch bigint, p_tree_sha text, p_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare b deploy_batch%rowtype; p deploy_batch%rowtype; v_done text[]; v_skip text[] := '{}';
        v_live int; v_reused boolean := false; v_copy jsonb := '[]'::jsonb; e jsonb;
        v_all text[] := array['merge','test','prenumber','lane_wait','migrate','deploy','smoke','verify'];
        v_next text := 'test';
begin
  perform _dev_guard();
  if coalesce(btrim(p_tree_sha), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'tree_sha_required');
  end if;
  select * into b from deploy_batch where id = p_batch for update;
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'no_such_batch'); end if;
  if b.status not in ('merging','testing') then
    return jsonb_build_object('ok', false, 'error', 'batch_not_open', 'status', b.status);
  end if;
  update deploy_batch set tree_sha = p_tree_sha, touched_at = now() where id = b.id;

  select * into p from deploy_batch
   where tree_sha = p_tree_sha and id < b.id and status in ('failed','expired')
     and opened_at > now() - interval '48 hours'
   order by id desc limit 1;
  if p.id is null then
    return jsonb_build_object('ok', true, 'resumed', false, 'skip', '[]'::jsonb,
      'tree_sha', p_tree_sha, 'change_no', b.change_no,
      'message', 'Fresh tree ' || left(p_tree_sha, 7) || ' — every phase runs.');
  end if;

  select coalesce(array_agg(x->>'phase' order by (x->>'at')::timestamptz), '{}')
    into v_done
    from jsonb_array_elements(coalesce(p.log, '[]'::jsonb)) x
   where x ? 'seconds' and (x->>'phase') = any(v_all);

  v_live := greatest(coalesce((select max(change_no) from deploy_registry where status = 'success'), 0),
                     coalesce((select change_no from app_version_state where id = 1), 0));
  if p.change_no is not null and p.change_no > v_live and b.change_no is null then
    update deploy_registry
       set batch_id = b.id, status = 'claimed', claimed_at = now(),
           agent = coalesce(p_agent, agent), deployed_at = null, expired_at = null
     where change_no = p.change_no;
    update deploy_batch set change_no = p.change_no where id = b.id;
    update deploy_queue set change_no = p.change_no where batch_id = b.id and status = 'batched';
    b.change_no := p.change_no;
    v_reused := true;
  end if;

  if 'test' = any(v_done) then v_skip := array_append(v_skip, 'test'); end if;
  if 'migrate' = any(v_done) then v_skip := array_append(v_skip, 'migrate'); end if;
  if 'deploy' = any(v_done) and v_reused then v_skip := array_append(v_skip, 'deploy'); end if;

  for e in select x from jsonb_array_elements(coalesce(p.log, '[]'::jsonb)) x
            where x ? 'seconds' and (x->>'phase') = any(v_skip)
  loop
    v_copy := v_copy || jsonb_build_object('at', now(), 'phase', e->>'phase',
                'seconds', coalesce((e->>'seconds')::int, 0),
                'locked', coalesce((e->>'locked')::boolean, false),
                'note', 'resumed from batch ' || p.id || ' — ' || coalesce(e->>'note', ''),
                'resumed_from', p.id);
  end loop;
  update deploy_batch set resumed_from = p.id, log = log || v_copy, touched_at = now()
   where id = b.id;

  v_next := case when not ('test' = any(v_skip)) then 'test'
                 when not ('migrate' = any(v_skip)) then 'migrate'
                 when not ('deploy' = any(v_skip)) then 'deploy'
                 else 'verify' end;
  return jsonb_build_object('ok', true, 'resumed', true, 'from_batch', p.id,
    'skip', to_jsonb(v_skip), 'done', to_jsonb(v_done), 'tree_sha', p_tree_sha,
    'change_no', b.change_no, 'change_reused', v_reused, 'next', v_next,
    'from_status', p.status,
    'message', format('Tree %s already reached %s in batch %s (%s) — resuming at %s%s.',
      left(p_tree_sha, 7), coalesce(array_to_string(v_done, ','), '(nothing)'), p.id, p.status, v_next,
      case when v_reused then ', CHANGE #' || b.change_no || ' reused' else '' end));
end $fn$;

-- ── 6. finish: 'expired' is closed, and a real failure raises the streak ────
create or replace function public.merge_batch_finish(
  p_token uuid, p_status text default 'success', p_commit text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare l deploy_lock%rowtype; b deploy_batch%rowtype; v_hold int; v_total int; v_ok boolean;
        v_holder boolean := false; v_released boolean := false; v_since timestamptz;
        v_alert jsonb := jsonb_build_object('alerted', false);
begin
  perform _dev_guard();
  if p_token is null then
    return jsonb_build_object('ok', false, 'error', 'no_token');
  end if;
  select * into b from deploy_batch where token = p_token order by id desc limit 1 for update;
  if b.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_token',
      'message', 'No batch carries this token.');
  end if;

  -- Idempotent. 'expired' joins the closed set: a worker that comes back after
  -- its batch was reclaimed must be told "already closed", not open it again.
  if b.status in ('deployed', 'failed', 'expired') then
    return jsonb_build_object('ok', true, 'already', true, 'batch_id', b.id,
      'change_no', b.change_no, 'hold_s', coalesce(b.hold_s, 0), 'deploy_hold_s', 0,
      'status', b.status, 'lane_released', false,
      'message', case when b.status = 'expired'
                      then 'This batch was reclaimed as a dead worker — its branches are already requeued.'
                      else 'Already recorded.' end,
      'target_hold_s', coalesce((_mq_cfg()->>'target_hold_s')::int, 60));
  end if;

  select * into l from deploy_lock where id = 1 for update;
  v_holder := l.token is not null and l.token = p_token;
  v_ok     := p_status in ('success','deployed');
  v_since  := case when v_holder then coalesce(l.acquired_at, b.relocked_at)
                   else coalesce(b.relocked_at, b.tested_at, b.merged_at, b.opened_at) end;
  v_hold   := greatest(extract(epoch from now() - coalesce(v_since, now()))::int, 0);
  v_total  := coalesce(b.hold_s, 0) + v_hold;

  update deploy_batch
     set status      = case when v_ok then 'deployed' else 'failed' end,
         deployed_at = case when v_ok then now() end,
         closed_at   = now(), hold_s = v_total,
         commit_sha  = coalesce(p_commit, commit_sha),
         note        = coalesce(p_note, note),
         touched_at  = now(),
         log         = log || jsonb_build_object('at', now(), 'phase','deployed', 'hold_s', v_hold,
                                                 'lane_held_at_finish', v_holder,
                                                 'renewals', coalesce(b.renewals, 0))
   where id = b.id;

  update deploy_queue
     set status = case when v_ok then 'deployed' else 'failed' end,
         finished_at = now(), reason = coalesce(p_note, reason)
   where batch_id = b.id and status in ('batched','merged');

  if b.change_no is not null then
    update deploy_registry
       set status      = case when v_ok then 'success' else 'failed' end,
           deployed_at = case when v_ok then now() end,
           commit_sha  = coalesce(p_commit, commit_sha),
           hold_s      = v_total,
           wait_s      = (select max(wait_s) from deploy_queue where batch_id = b.id)
     where change_no = b.change_no;
  end if;

  if v_holder then
    update deploy_lock set token = null, holder = null, title = null,
                           acquired_at = null, expires_at = null,
                           renewals = 0, renewed_at = null
     where id = 1 and token = p_token;
    v_released := true;
  end if;
  begin
    perform public.version_watch();
  exception when others then null;
  end;
  -- CHANGE #1836 — the streak is checked HERE, on the write that creates it.
  -- Nothing else in the fleet was watching, which is how six batches failed in
  -- a row over an hour with no alert anywhere.
  if not v_ok then
    begin
      v_alert := public._deploy_batch_fail_alert();
    exception when others then v_alert := jsonb_build_object('alerted', false, 'error', sqlerrm);
    end;
  end if;

  return jsonb_build_object('ok', true, 'already', false, 'batch_id', b.id, 'change_no', b.change_no,
    'hold_s', v_total, 'deploy_hold_s', v_hold, 'renewals', coalesce(b.renewals, 0),
    'status', case when v_ok then 'deployed' else 'failed' end,
    'lane_released', v_released,
    'fail_streak', v_alert,
    'lane_note', case when v_released then 'lane released'
                      when l.token is null then 'lane was already free (claim expired before finish)'
                      else 'lane held by ' || coalesce(l.holder, '?') || ' — left alone' end,
    'target_hold_s', coalesce((_mq_cfg()->>'target_hold_s')::int, 60));
end $fn$;

-- ── 7. the card: recent batches, their real notes, and the streak ──────────
create or replace function public.deploy_lane_batches(p_limit integer default 8)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v jsonb; v_streak jsonb; v_n int;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('has', false);
  end if;
  v_streak := public._deploy_batch_fail_streak();
  v_n := coalesce((v_streak->>'streak')::int, 0);
  select coalesce(jsonb_agg(jsonb_build_object(
           'batch_id', b.id,
           'label', 'Batch ' || b.id
                    || case when b.change_no is not null then ' · CHANGE #' || b.change_no else '' end
                    || ' · ' || b.entries || ' branch(es)',
           'status', b.status,
           'value_label', case b.status
              when 'deployed' then 'deployed'
              when 'expired'  then 'worker died — retried'
              when 'failed'   then 'failed'
              else b.status end,
           'tone', case b.status when 'deployed' then 'success'
                                 when 'expired'  then 'warning'
                                 when 'failed'   then 'error' else 'info' end,
           'sub_label', nullif(btrim(coalesce(b.note, '')), ''),
           'when_label', to_char(coalesce(b.closed_at, b.opened_at) at time zone 'Asia/Kolkata',
                                 'DD Mon HH24:MI') || ' IST')
         order by b.id desc), '[]'::jsonb)
    into v
    from (select * from deploy_batch order by id desc limit greatest(coalesce(p_limit, 8), 1)) b;
  return jsonb_build_object(
    'has', true,
    'heading', 'Recent batches',
    'empty_label', 'No batch has run yet.',
    'rows', v,
    'streak', v_n,
    'streak_label', case
       when v_n = 0 then 'Last batch deployed.'
       when v_n = 1 then 'Last batch failed — one in a row.'
       else v_n || ' batches failed in a row — nothing is reaching production.' end,
    'streak_tone', case when v_n = 0 then 'success'
                        when v_n = 1 then 'warning' else 'danger' end,
    'footnote', 'An expired batch is a worker that died, not a branch that failed — '
             || 'its branches keep their attempt count and go back in the queue.');
end $fn$;
revoke all on function public.deploy_lane_batches(integer) from anon;

CREATE OR REPLACE FUNCTION public.deploy_lane_status(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l deploy_lock%rowtype; cfg jsonb := _mq_cfg();
        v_wait int; v_target int; v_busy boolean;
        v_hold_avg numeric; v_wait_avg numeric; v_n int;
        v_touch int; v_held int; v_exp_in int; v_ren int;
        v_ren_label text; v_ren_chip text; v_ren_tone text; lb deploy_batch%rowtype;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Deploy lane is visible to super-admins only.');
  end if;
  select * into l from deploy_lock where id = 1;
  v_busy   := l.token is not null and l.expires_at > now();
  v_target := coalesce((cfg->>'target_hold_s')::int, 60);
  v_touch  := greatest(coalesce((cfg->>'touch_every_s')::int, 30), 5);
  select count(*) into v_wait from deploy_queue where status = 'waiting';

  select count(*), avg(hold_s), avg(wait_s) into v_n, v_hold_avg, v_wait_avg
    from deploy_registry
   where deployed_at is not null and deployed_at > now() - interval '7 days';

  -- CHANGE #1822 — THE RENEWAL LINE. A lane that is quietly expiring must be
  -- readable here, not inferred from a wall of failed batches.
  if v_busy then
    v_ren    := coalesce(l.renewals, 0);
    v_held   := extract(epoch from now() - coalesce(l.acquired_at, now()))::int;
    v_exp_in := greatest(extract(epoch from l.expires_at - now())::int, 0);
    v_ren_label := format('lane renewed %s, held %ss · expires in %ss',
                     case v_ren when 1 then 'once' else v_ren || ' times' end, v_held, v_exp_in);
    if v_exp_in <= v_touch then
      v_ren_chip := 'expiring'; v_ren_tone := 'danger';
      v_ren_label := v_ren_label || ' — renewals stopped';
    elsif v_ren = 0 and v_held > v_touch * 2 then
      v_ren_chip := 'not renewing'; v_ren_tone := 'warning';
    else
      v_ren_chip := v_ren || '×'; v_ren_tone := 'info';
    end if;
  else
    select * into lb from deploy_batch
     where closed_at is not null order by closed_at desc limit 1;
    if lb.id is not null and coalesce(lb.renewals, 0) > 0 then
      v_ren_label := format('last batch %s renewed %s, held %ss',
                       lb.id, case lb.renewals when 1 then 'once' else lb.renewals || ' times' end,
                       coalesce(lb.hold_s, 0));
      v_ren_chip := lb.renewals || '×';
      v_ren_tone := case lb.status when 'deployed' then 'success' else 'neutral' end;
    else
      v_ren_label := 'no lane renewals recorded yet';
      v_ren_chip := ''; v_ren_tone := 'neutral';
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    -- CHANGE #1836 — the recent batches and their REAL notes. Six batches
    -- failed in a row on 6 Sep and the card could only show the one that was
    -- open; the hour was legible in merge_worker.journal and nowhere else.
    'batches', public.deploy_lane_batches(8),
    'title', 'Deploy lane',
    'subtitle', case when coalesce((cfg->>'enabled')::boolean, true)
                     then 'Merge queue — runners push a branch and leave; one worker batches, tests once, deploys once.'
                     else 'Merge queue is OFF — runners fall back to holding the lane one at a time.' end,
    'mode_label', case when coalesce((cfg->>'enabled')::boolean, true) then 'MERGE QUEUE' else 'MUTEX (legacy)' end,
    'mode_tone',  case when coalesce((cfg->>'enabled')::boolean, true) then 'success' else 'warning' end,
    'lane', jsonb_build_object(
      'busy', v_busy,
      'label', case when v_busy then 'Lane held by ' || coalesce(l.holder,'?') else 'Lane free' end,
      'detail', case when v_busy
        then coalesce(l.title,'merge batch') || ' · held ' ||
             extract(epoch from now() - l.acquired_at)::int || 's'
        else 'Nothing merging right now.' end,
      'held_label', case when v_busy then extract(epoch from now() - l.acquired_at)::int || 's' else '—' end,
      'over_target', case when v_busy then extract(epoch from now() - l.acquired_at)::int > v_target else false end,
      'tone', case when not v_busy then 'success'
                   when extract(epoch from now() - l.acquired_at)::int > v_target then 'error'
                   else 'info' end,
      'renewals', case when v_busy then coalesce(l.renewals, 0) else 0 end,
      'expires_in_s', case when v_busy then v_exp_in end,
      'renewal_label', v_ren_label,
      'renewal_chip', v_ren_chip,
      'renewal_tone', v_ren_tone),
    'queue', jsonb_build_object(
      'count', v_wait,
      'label', case when v_wait = 0 then 'Queue empty'
                    when v_wait = 1 then '1 branch waiting'
                    else v_wait || ' branches waiting' end,
      'empty_hint', 'Runners push a branch here and go straight back to building. Nothing waits on a lock.',
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'entry_id', id, 'command_id', command_id,
                 'label', case when command_id is null then title else '#'||command_id||' · '||title end,
                 'detail', agent || ' · ' || branch,
                 'value_label', 'waiting ' || extract(epoch from now() - pushed_at)::int || 's',
                 'tone', 'info') order by pushed_at), '[]'::jsonb)
               from deploy_queue where status = 'waiting'),
      'window_label', (select case
          when coalesce((cfg->>'window_s')::int, 0) <= 0 then 'Batch window off — every branch deploys alone.'
          when v_wait = 0 then 'Batch window ' || (cfg->>'window_s') || 's · nothing waiting.'
          when v_wait >= greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1)
            then 'Batch window full — ' || v_wait || ' branch(es) ship together.'
          else 'Batch window open — ' || v_wait || ' of ' ||
               greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1) ||
               ' branch(es), up to ' || (cfg->>'window_s') || 's.' end)),
    'batch', (select jsonb_build_object(
                 'id', b.id, 'status', b.status,
                 'label', 'Batch ' || b.id || ' · ' || b.entries || ' branch(es)'
                          || case when b.resumed_from is not null then ' · resumed from ' || b.resumed_from else '' end,
                 'value_label', b.status,
                 'tone', case b.status when 'deployed' then 'success' when 'failed' then 'error' else 'info' end,
                 'change_no', b.change_no, 'evicted', b.evicted,
                 'phases', public.merge_batch_phases(b.id),
                 'slowest_label', coalesce((
                    select (e->>'phase') || ' · ' || (e->>'seconds') || 's'
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     order by (e->>'seconds')::int desc limit 1), '—'),
                 'locked_s', coalesce((
                    select sum((e->>'seconds')::int)
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     where (e->>'locked')::boolean), 0),
                 'renewals', coalesce(b.renewals, 0),
                 'renewal_label', case when coalesce(b.renewals, 0) = 0 then ''
                    else 'batch renewed the lane ' ||
                         case b.renewals when 1 then 'once' else b.renewals || ' times' end end)
               from deploy_batch b
              where b.status in ('merging','testing','deploying')
              order by b.id desc limit 1),
    'metrics', jsonb_build_object(
      'heading', 'Wait vs hold, last 7 days',
      'samples', v_n,
      'avg_hold_label', case when v_hold_avg is null then 'no hold time recorded yet'
                             else 'avg lane hold ' || round(v_hold_avg)::int || 's' end,
      'avg_wait_label', case when v_wait_avg is null then 'no queue wait recorded yet'
                             else 'avg queue wait ' || round(v_wait_avg)::int || 's' end,
      'target_label', 'target hold under ' || v_target || 's',
      'tone', case when v_hold_avg is null then 'info'
                   when v_hold_avg > v_target then 'warning' else 'success' end),
    'recent_heading', 'Recent deploys',
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', r.change_no,
                 'label', '#' || r.change_no || ' · ' || r.title,
                 'detail', coalesce(r.agent,'?'),
                 'value_label', case
                    when r.deployed_at is null and r.status = 'claimed'
                      then 'claimed ' || extract(epoch from now() - r.claimed_at)::int || 's ago · never released'
                    when r.deployed_at is null then r.status
                    else 'held ' || coalesce(r.hold_s, extract(epoch from r.deployed_at - r.claimed_at)::int) || 's'
                         || case when r.wait_s is not null then ' · waited ' || r.wait_s || 's' else '' end end,
                 'tone', case r.status when 'success' then 'success'
                                     when 'expired' then 'warning'
                                     when 'failed'  then 'error' else 'info' end
                 ) order by r.change_no desc), '[]'::jsonb)
               from (select * from deploy_registry order by change_no desc limit greatest(coalesce(p_limit,12),1)) r),
    'stale_heading', 'Stale claims',
    'stale_empty', 'No claim is holding a queue slot past its TTL.',
    'stale', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', change_no,
                 'label', '#' || change_no || ' · ' || title,
                 'detail', coalesce(agent,'?'),
                 'value_label', 'held since ' || to_char(claimed_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
                 'tone', 'warning')
                 order by change_no), '[]'::jsonb)
               from deploy_registry
              where status = 'claimed'
                and claimed_at < now() - make_interval(mins => greatest(coalesce((cfg->>'claim_ttl_minutes')::int,20),5))),
    -- CHANGE #1823 — the critical-path smoke verdict, printed verbatim by the
    -- Deploy lane card. Kept through #1822's follow-up; absent → has:false.
    'smoke', case when to_regproc('public.merge_batch_smoke_status') is not null
                  then public.merge_batch_smoke_status()
                  else jsonb_build_object('has', false) end,
    'config', cfg);
end $function$;

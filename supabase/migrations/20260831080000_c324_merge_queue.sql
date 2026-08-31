-- CHANGE #324 — the deploy lane becomes a MERGE QUEUE.
-- Repo copy of the four migrations applied on 2026-08-31 (idempotent:
-- create table if not exists / create or replace / insert-where-not-exists),
-- plus the deployed_at backfill note. Re-applying is a silent no-op.

-- ═══ 20260831075011 · c324_merge_queue_schema ═══
-- CHANGE #324 — the deploy lane becomes a MERGE QUEUE (schema).
alter table public.deploy_registry add column if not exists batch_id   bigint;
alter table public.deploy_registry add column if not exists wait_s     integer;
alter table public.deploy_registry add column if not exists hold_s     integer;
alter table public.deploy_registry add column if not exists expired_at timestamptz;

create table if not exists public.deploy_batch (
  id           bigserial primary key,
  status       text        not null default 'open',
  agent        text,
  token        uuid,
  change_no    integer,
  commit_sha   text,
  opened_at    timestamptz not null default now(),
  merged_at    timestamptz,
  tested_at    timestamptz,
  deployed_at  timestamptz,
  closed_at    timestamptz,
  entries      integer     not null default 0,
  evicted      integer     not null default 0,
  hold_s       integer,
  note         text,
  log          jsonb       not null default '[]'::jsonb
);
create index if not exists deploy_batch_status_idx on public.deploy_batch(status, opened_at desc);

create table if not exists public.deploy_queue (
  id           bigserial primary key,
  command_id   bigint,
  agent        text        not null,
  title        text        not null,
  branch       text        not null,
  commit_sha   text,
  preview_url  text,
  status       text        not null default 'waiting',
  pushed_at    timestamptz not null default now(),
  batched_at   timestamptz,
  finished_at  timestamptz,
  batch_id     bigint      references public.deploy_batch(id),
  change_no    integer,
  wait_s       integer,
  attempts     integer     not null default 0,
  reason       text
);
create index if not exists deploy_queue_waiting_idx on public.deploy_queue(status, pushed_at);
create index if not exists deploy_queue_cmd_idx     on public.deploy_queue(command_id);
create unique index if not exists deploy_queue_one_live_per_cmd
  on public.deploy_queue(command_id)
  where command_id is not null and status in ('waiting','batched','merged');

alter table public.deploy_queue enable row level security;
alter table public.deploy_batch enable row level security;

insert into public.dev_runner_config(key, value)
select 'merge_queue',
       jsonb_build_object(
         'enabled',            true,
         'max_batch',          10,
         'lock_ttl_minutes',   5,
         'target_hold_s',      60,
         'claim_ttl_minutes',  20,
         'sweep_alert',        true)
where not exists (select 1 from public.dev_runner_config where key = 'merge_queue');
;

-- ═══ 20260831075113 · c324_merge_queue_rpcs ═══
-- CHANGE #324 — merge-queue RPCs. Runners push and leave; one merge worker
-- batches, tests once, deploys once. The lock is held only for merge+promote.

-- ── config reader ──────────────────────────────────────────────────────────
create or replace function public._mq_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select value from dev_runner_config where key = 'merge_queue'),
                  '{}'::jsonb)
      || '{}'::jsonb
$$;

-- ── 1. PUSH: the runner's whole interaction with the lane ──────────────────
-- No lock, no wait, no rebase inside a lock. One live entry per command
-- (spec 3): a design-QA fix or a route marker UPDATES the entry it already
-- has instead of taking a second queue slot.
create or replace function public.deploy_queue_push(
  p_command_id bigint,
  p_agent      text,
  p_title      text,
  p_branch     text,
  p_commit     text default null,
  p_preview_url text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_new boolean := false; v_pos int; v_wait int;
begin
  perform _dev_guard();
  if coalesce(p_branch,'') = '' then
    return jsonb_build_object('ok', false, 'error','branch_required',
      'message','Push your branch to origin first, then call deploy_queue_push with its name.');
  end if;

  if p_command_id is not null then
    select id into v_id from deploy_queue
     where command_id = p_command_id and status in ('waiting','batched','merged')
     for update;
  end if;

  if v_id is null then
    insert into deploy_queue(command_id, agent, title, branch, commit_sha, preview_url)
    values (p_command_id, coalesce(p_agent,'agent'), coalesce(p_title,'(untitled)'),
            p_branch, p_commit, p_preview_url)
    returning id into v_id;
    v_new := true;
  else
    -- ONE CLAIM PER COMMAND: fold the follow-up into the slot it already owns.
    update deploy_queue
       set branch      = p_branch,
           commit_sha  = coalesce(p_commit, commit_sha),
           preview_url = coalesce(p_preview_url, preview_url),
           title       = coalesce(p_title, title),
           attempts    = attempts + 1,
           status      = case when status = 'waiting' then 'waiting' else status end
     where id = v_id;
  end if;

  select count(*) into v_wait from deploy_queue where status = 'waiting';
  select count(*) into v_pos  from deploy_queue q2
   where q2.status = 'waiting'
     and q2.pushed_at <= (select pushed_at from deploy_queue where id = v_id);

  return jsonb_build_object(
    'ok', true, 'entry_id', v_id, 'created', v_new,
    'position', v_pos, 'waiting', v_wait,
    'next_step', case when v_new
      then 'Queued. Do NOT hold the lane — the merge worker batches this with everything else waiting, tests once and deploys once. Poll deploy_queue_entry('||v_id||') for the change number.'
      else 'Folded into the queue slot this command already holds (one claim per command). Nothing re-queued.' end);
end $$;

-- ── 2. what happened to my entry ───────────────────────────────────────────
create or replace function public.deploy_queue_entry(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare q deploy_queue%rowtype; b deploy_batch%rowtype;
begin
  perform _dev_guard();
  select * into q from deploy_queue where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error','no_such_entry'); end if;
  if q.batch_id is not null then select * into b from deploy_batch where id = q.batch_id; end if;
  return jsonb_build_object('ok', true, 'entry', to_jsonb(q),
    'batch', case when b.id is null then null else to_jsonb(b) end,
    'done', q.status in ('deployed','evicted','failed','cancelled'));
end $$;

-- ── 3. OPEN A BATCH — the only place the lane is locked ────────────────────
create or replace function public.merge_batch_open(p_agent text, p_max int default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare l deploy_lock%rowtype; v_token uuid := gen_random_uuid();
        cfg jsonb := _mq_cfg(); v_max int; v_ttl int; v_batch bigint; v_n int;
begin
  perform _dev_guard();
  v_max := coalesce(p_max, (cfg->>'max_batch')::int, 10);
  v_ttl := coalesce((cfg->>'lock_ttl_minutes')::int, 5);

  if coalesce((cfg->>'enabled')::boolean, true) is not true then
    return jsonb_build_object('ok', false, 'reason','disabled');
  end if;
  if not exists (select 1 from deploy_queue where status = 'waiting') then
    return jsonb_build_object('ok', false, 'reason','empty', 'message','Nothing waiting.');
  end if;

  select * into l from deploy_lock where id = 1 for update;
  if l.token is not null and l.expires_at > now() then
    return jsonb_build_object('ok', false, 'reason','busy', 'held_by', l.holder,
      'frees_in_s', greatest(extract(epoch from l.expires_at - now())::int, 0));
  end if;

  update deploy_lock
     set token = v_token, holder = coalesce(p_agent,'merge-worker'),
         title = 'merge batch', acquired_at = now(),
         expires_at = now() + make_interval(mins => greatest(v_ttl, 2))
   where id = 1;

  insert into deploy_batch(status, agent, token) values ('merging', coalesce(p_agent,'merge-worker'), v_token)
  returning id into v_batch;

  with picked as (
    select id from deploy_queue where status = 'waiting'
     order by pushed_at limit v_max for update skip locked)
  update deploy_queue q
     set status = 'batched', batched_at = now(), batch_id = v_batch,
         wait_s = extract(epoch from now() - q.pushed_at)::int
    from picked p where q.id = p.id;
  get diagnostics v_n = row_count;

  update deploy_batch set entries = v_n where id = v_batch;

  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'token', v_token,
    'entries', (select coalesce(jsonb_agg(jsonb_build_object(
        'entry_id', id, 'command_id', command_id, 'agent', agent,
        'title', title, 'branch', branch, 'commit', commit_sha,
        'preview_url', preview_url, 'wait_s', wait_s) order by pushed_at), '[]'::jsonb)
      from deploy_queue where batch_id = v_batch and status = 'batched'),
    'count', v_n,
    'expires_at', now() + make_interval(mins => greatest(v_ttl, 2)),
    'next_step','Merge every branch onto main OUTSIDE any further lock, run the full protected suite ONCE on the merged tree, then merge_batch_number(token) and promote. On a red suite call merge_batch_evict per bisected branch and re-test.');
end $$;

-- ── 4. BISECT: evict one offending branch, keep the rest of the batch ──────
create or replace function public.merge_batch_evict(
  p_token uuid, p_entry_id bigint, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare l deploy_lock%rowtype; v_batch bigint; v_left int;
begin
  perform _dev_guard();
  select * into l from deploy_lock where id = 1 for update;
  if l.token is null or l.token <> p_token then
    return jsonb_build_object('ok', false, 'error','not_lock_holder');
  end if;

  update deploy_queue
     set status = 'evicted', finished_at = now(),
         reason = coalesce(p_reason,'evicted by bisect')
   where id = p_entry_id and status = 'batched'
  returning batch_id into v_batch;
  if v_batch is null then
    return jsonb_build_object('ok', false, 'error','not_in_open_batch');
  end if;

  select count(*) into v_left from deploy_queue where batch_id = v_batch and status = 'batched';
  update deploy_batch
     set evicted = evicted + 1, entries = v_left,
         log = log || jsonb_build_object('at', now(), 'evicted_entry', p_entry_id,
                                         'reason', coalesce(p_reason,'bisect'))
   where id = v_batch;

  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'remaining', v_left,
    'next_step', case when v_left = 0
      then 'Batch is empty — call merge_batch_finish(token, ''failed'') and release the lane.'
      else 'Re-run the protected suite on the remaining '||v_left||' branch(es).' end);
end $$;

-- ── 5. the change number, claimed once for the whole batch ─────────────────
create or replace function public.merge_batch_number(
  p_token uuid, p_title text default null, p_commit text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare l deploy_lock%rowtype; b deploy_batch%rowtype; v_no int; v_title text;
begin
  perform _dev_guard();
  select * into l from deploy_lock where id = 1 for update;
  if l.token is null or l.token <> p_token or l.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','lock_not_held');
  end if;
  select * into b from deploy_batch where token = p_token and status in ('merging','testing','deploying')
   order by id desc limit 1;
  if b.id is null then return jsonb_build_object('ok', false, 'error','no_open_batch'); end if;

  select greatest(coalesce((select max(change_no) from deploy_registry), 0),
                  coalesce((select change_no from app_version_state where id = 1), 0)) + 1
    into v_no;

  v_title := coalesce(p_title,
    (select string_agg('#'||command_id, ' + ' order by pushed_at)
       from deploy_queue where batch_id = b.id and status = 'batched'),
    'merge batch '||b.id);

  insert into deploy_registry(change_no, title, agent, branch, commit_sha, status, batch_id)
  values (v_no, v_title, l.holder, 'main', p_commit, 'claimed', b.id);

  update deploy_batch set change_no = v_no, status = 'deploying', tested_at = coalesce(tested_at, now()),
                          merged_at = coalesce(merged_at, now()), commit_sha = coalesce(p_commit, commit_sha)
   where id = b.id;
  update deploy_queue set change_no = v_no, status = 'merged'
   where batch_id = b.id and status = 'batched';

  return jsonb_build_object('ok', true, 'change_no', v_no, 'batch_id', b.id, 'title', v_title,
    'next_step','Stamp version.json with '||v_no||', deploy once, verify live, then merge_batch_finish(token, ''success'', commit).');
end $$;

-- ── 6. FINISH: stamp deployed_at everywhere, record hold_s, free the lane ──
create or replace function public.merge_batch_finish(
  p_token uuid, p_status text default 'success',
  p_commit text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare l deploy_lock%rowtype; b deploy_batch%rowtype; v_hold int; v_ok boolean;
begin
  perform _dev_guard();
  select * into l from deploy_lock where id = 1 for update;
  if l.token is null or l.token <> p_token then
    return jsonb_build_object('ok', false, 'error','not_lock_holder');
  end if;
  select * into b from deploy_batch where token = p_token order by id desc limit 1;

  v_ok   := p_status in ('success','deployed');
  v_hold := extract(epoch from now() - coalesce(l.acquired_at, now()))::int;

  if b.id is not null then
    update deploy_batch
       set status      = case when v_ok then 'deployed' else 'failed' end,
           deployed_at = case when v_ok then now() end,
           closed_at   = now(), hold_s = v_hold,
           commit_sha  = coalesce(p_commit, commit_sha),
           note        = coalesce(p_note, note)
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
             hold_s      = v_hold,
             wait_s      = (select max(wait_s) from deploy_queue where batch_id = b.id)
       where change_no = b.change_no;
    end if;
  end if;

  update deploy_lock set token = null, holder = null, title = null,
                         acquired_at = null, expires_at = null where id = 1;
  perform public.version_watch();

  return jsonb_build_object('ok', true, 'batch_id', b.id, 'change_no', b.change_no,
    'hold_s', v_hold, 'status', case when v_ok then 'deployed' else 'failed' end,
    'target_hold_s', coalesce((_mq_cfg()->>'target_hold_s')::int, 60));
end $$;
;

-- ═══ 20260831075155 · c324_deployed_at_fix_and_sweep ═══
-- CHANGE #324 (a) — the deployed_at bug.
-- deploy_lock_release stamped deployed_at only when p_status = 'deployed', but
-- every caller in the fleet (the preamble, deploy.sh, every runner) passes
-- 'success'. So all 177 registry rows carried deployed_at = NULL, including the
-- 85 marked success — hold time was unmeasurable and no watchdog could see a
-- stuck lane. Treat 'success' and 'deployed' as the same outcome, and record
-- hold_s while we still know when the lock was acquired.
create or replace function public.deploy_lock_release(
  p_token uuid, p_change_no integer default null,
  p_commit text default null, p_status text default 'deployed')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare l deploy_lock%rowtype; v_ok boolean; v_hold int;
begin
  select * into l from deploy_lock where id = 1 for update;
  if l.token is null or l.token <> p_token then
    return jsonb_build_object('ok', false, 'error','not_lock_holder');
  end if;

  v_ok   := coalesce(p_status,'deployed') in ('deployed','success');
  v_hold := extract(epoch from now() - coalesce(l.acquired_at, now()))::int;

  if p_change_no is not null then
    update deploy_registry
       set deployed_at = case when v_ok then now() else deployed_at end,
           commit_sha  = coalesce(p_commit, commit_sha),
           status      = coalesce(p_status,'deployed'),
           hold_s      = coalesce(hold_s, v_hold)
     where change_no = p_change_no;
  end if;

  update deploy_lock set token = null, holder = null, title = null,
                         acquired_at = null, expires_at = null where id = 1;
  perform public.version_watch();
  return jsonb_build_object('ok', true, 'released', true, 'hold_s', v_hold);
end $$;

-- ── (b) AUTO-EXPIRE: a claim silent past its TTL stops holding a queue slot ──
-- 827 (runner-2, 06:54) and 829 (runner-4, 07:12) were still status='claimed'
-- for finished work, holding queue position. Nothing swept them because nothing
-- could tell a live claim from a dead one. Now the sweep does, every minute,
-- and it alerts.
create or replace function public.deploy_lane_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb := _mq_cfg(); v_ttl int; v_regs int := 0; v_locks int := 0;
        v_q int := 0; v_bucket text := to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24');
        v_names text;
begin
  v_ttl := greatest(coalesce((cfg->>'claim_ttl_minutes')::int, 20), 5);

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
                         acquired_at = null, expires_at = null
   where id = 1 and token is not null and expires_at < now();
  get diagnostics v_locks = row_count;

  -- a queue entry whose batch died with its worker goes back to waiting once,
  -- then fails — a branch that cannot merge must not spin the lane forever
  update deploy_queue q
     set status = case when attempts >= 2 then 'failed' else 'waiting' end,
         batch_id = null, batched_at = null, attempts = attempts + 1,
         reason = 'batch expired before it deployed',
         finished_at = case when attempts >= 2 then now() end
   where status in ('batched','merged')
     and exists (select 1 from deploy_batch b
                  where b.id = q.batch_id
                    and b.status in ('merging','testing','deploying')
                    and b.opened_at < now() - make_interval(mins => v_ttl));
  get diagnostics v_q = row_count;

  update deploy_batch set status = 'failed', closed_at = now(),
                          note = coalesce(note,'') || ' expired by deploy_lane_sweep'
   where status in ('merging','testing','deploying')
     and opened_at < now() - make_interval(mins => v_ttl);

  if (v_regs + v_locks + v_q) > 0 and coalesce((cfg->>'sweep_alert')::boolean, true) then
    select string_agg(change_no::text, ', ' order by change_no) into v_names
      from deploy_registry where expired_at > now() - interval '2 minutes';
    insert into rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('deploy_lane|stale|' || v_bucket), 'warn', 'deploy_lane',
            format('deploy lane swept %s stale claim(s), %s lock(s), %s queue entr(y/ies)',
                   v_regs, v_locks, v_q),
            jsonb_build_object('expired_changes', v_names, 'ttl_minutes', v_ttl))
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          detail = excluded.detail;
  end if;

  return jsonb_build_object('ok', true, 'expired_claims', v_regs,
    'released_locks', v_locks, 'requeued_entries', v_q, 'ttl_minutes', v_ttl);
end $$;

-- run it on the ONE dispatcher (never a bare */N pg_cron schedule)
insert into public.cron_task(name, ord, mode, gate_sql, work_sql, enabled, max_interval_s, dml, note)
select 'deploy_lane_sweep', 6, 'poll',
       $g$select exists (select 1 from public.deploy_registry
                          where status = 'claimed' and claimed_at < now() - interval '20 minutes')
            or exists (select 1 from public.deploy_lock
                        where id = 1 and token is not null and expires_at < now())
            or exists (select 1 from public.deploy_batch
                        where status in ('merging','testing','deploying')
                          and opened_at < now() - interval '20 minutes')$g$,
       'select public.deploy_lane_sweep()', true, 3600, true,
       'CHANGE #324 — auto-expires a deploy claim silent past its TTL, frees an orphaned lane lock, requeues a dead batch, and alerts. Gate is false in the normal case, so it costs nothing.'
where not exists (select 1 from public.cron_task where name = 'deploy_lane_sweep');
;

-- ═══ 20260831075229 · c324_deploy_lane_status ═══
-- CHANGE #324 (c) — the render payload. Every label, tone, empty state and
-- duration string is built HERE; the Flutter section prints it verbatim.
create or replace function public.deploy_lane_status(p_limit int default 12)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare l deploy_lock%rowtype; cfg jsonb := _mq_cfg();
        v_wait int; v_target int; v_busy boolean;
        v_hold_avg numeric; v_wait_avg numeric; v_n int;
begin
  perform _dev_guard();
  select * into l from deploy_lock where id = 1;
  v_busy   := l.token is not null and l.expires_at > now();
  v_target := coalesce((cfg->>'target_hold_s')::int, 60);
  select count(*) into v_wait from deploy_queue where status = 'waiting';

  select count(*), avg(hold_s), avg(wait_s) into v_n, v_hold_avg, v_wait_avg
    from deploy_registry
   where deployed_at is not null and deployed_at > now() - interval '7 days';

  return jsonb_build_object(
    'ok', true,
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
      'held_s', case when v_busy then extract(epoch from now() - l.acquired_at)::int end,
      'over_target', case when v_busy then extract(epoch from now() - l.acquired_at)::int > v_target else false end,
      'tone', case when not v_busy then 'success'
                   when extract(epoch from now() - l.acquired_at)::int > v_target then 'danger'
                   else 'info' end),
    'queue', jsonb_build_object(
      'count', v_wait,
      'label', case when v_wait = 0 then 'Queue empty'
                    when v_wait = 1 then '1 branch waiting'
                    else v_wait || ' branches waiting' end,
      'empty_hint', 'Runners push a branch here and go straight back to building. Nothing waits on a lock.',
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'entry_id', id, 'command_id', command_id,
                 'label', case when command_id is null then title else '#'||command_id||' · '||title end,
                 'agent', agent, 'branch', branch,
                 'waiting_label', 'waiting ' || extract(epoch from now() - pushed_at)::int || 's',
                 'tone', 'info') order by pushed_at), '[]'::jsonb)
               from deploy_queue where status = 'waiting')),
    'batch', (select jsonb_build_object(
                 'id', b.id, 'status', b.status,
                 'label', 'Batch ' || b.id || ' · ' || b.entries || ' branch(es) · ' || b.status,
                 'tone', case b.status when 'deployed' then 'success' when 'failed' then 'danger' else 'info' end,
                 'change_no', b.change_no, 'evicted', b.evicted)
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
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', change_no, 'title', title, 'agent', agent,
                 'status', status,
                 'tone', case status when 'success' then 'success'
                                     when 'expired' then 'warning'
                                     when 'failed'  then 'danger' else 'info' end,
                 'timing_label', case
                    when deployed_at is null and status = 'claimed'
                      then 'claimed ' || extract(epoch from now() - claimed_at)::int || 's ago · never released'
                    when deployed_at is null then status
                    else 'held ' || coalesce(hold_s, extract(epoch from deployed_at - claimed_at)::int) || 's'
                         || case when wait_s is not null then ' · waited ' || wait_s || 's' else '' end end
                 ) order by change_no desc), '[]'::jsonb)
               from (select * from deploy_registry order by change_no desc limit greatest(coalesce(p_limit,12),1)) r),
    'stale', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', change_no, 'title', title, 'agent', agent,
                 'label', '#' || change_no || ' held since ' ||
                          to_char(claimed_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST')
                 order by change_no), '[]'::jsonb)
               from deploy_registry
              where status = 'claimed'
                and claimed_at < now() - make_interval(mins => greatest(coalesce((cfg->>'claim_ttl_minutes')::int,20),5))),
    'config', cfg);
end $$;
;


-- replay-target: control-plane
-- CHANGE #1822 — THE MERGE LANE NEVER LOSES ITS OWN FINISHED WORK.
--
-- Measured 6 Sep 2026 08:00 UTC, batches 589-601: thirteen opened in 4.5 h and
-- only six reached a CHANGE live line. The deploy phase ran 238-801 s against a
-- lock the worker took ONCE (merge_lane_relock) and never renewed, so the claim
-- expired mid-deploy, deploy_lane_sweep freed it, and merge_batch_finish then
-- answered not_lock_holder — the batch was swept as failed with the site
-- already serving it, and the whole protected-suite + build cycle was redone.
--
--   1. merge_lane_touch(batch, agent, token) — renew the live claim by
--      lock_ttl_minutes when the caller still holds the token. Conditional
--      UPDATE, no explicit lock, idempotent. Refuses past max_hold_s so a hung
--      worker cannot hold the lane forever.
--   2. merge_batch_finish no longer needs the lane. Recording a deploy that
--      already happened never depends on still holding the lock; the lane is
--      released only if this token still holds it. A second finish for the
--      same batch returns already:true and never touches the change number.
--   3. merge_batch_tree(batch, tree_sha) — RESUME, never restart. When a batch
--      reopens with the same merged tree sha as an earlier failed batch, the
--      phases that batch already stamped green (test, migrate, and deploy when
--      the change number could be reused) are copied in and returned as skip[].
--      A tree that tested GREEN never runs the protected suite twice.
--   4. deploy_lane_status prints the renewal line ("lane renewed 14 times,
--      held 470s · expires in 97s") so a quietly expiring lane is READABLE.
--   5. Knobs: lock_ttl_minutes 5 -> 2 (liveness holds the lane now),
--      window_s 90 -> 300, touch_every_s 30, max_hold_s 3600.
--
-- Every statement is idempotent. Control plane only (the dev-queue tables
-- moved there in #1761); the production pass of migration_replay.sh skips it.

-- ── 0. columns ──────────────────────────────────────────────────────────────
alter table public.deploy_lock  add column if not exists renewals   integer not null default 0;
alter table public.deploy_lock  add column if not exists renewed_at timestamptz;
alter table public.deploy_batch add column if not exists renewals     integer not null default 0;
alter table public.deploy_batch add column if not exists touched_at   timestamptz;
alter table public.deploy_batch add column if not exists relocked_at  timestamptz;
alter table public.deploy_batch add column if not exists tree_sha     text;
alter table public.deploy_batch add column if not exists resumed_from bigint;
create index if not exists deploy_batch_tree_sha_idx on public.deploy_batch (tree_sha) where tree_sha is not null;

-- ── 1. merge_lane_touch ─────────────────────────────────────────────────────
create or replace function public.merge_lane_touch(p_batch bigint, p_agent text, p_token uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare l deploy_lock%rowtype; cfg jsonb := _mq_cfg(); v_ttl int; v_max int;
        v_held int; v_status text; v_exp timestamptz; v_n int;
begin
  perform _dev_guard();
  v_ttl := greatest(coalesce((cfg->>'lock_ttl_minutes')::int, 2), 1);
  v_max := greatest(coalesce((cfg->>'max_hold_s')::int, 3600), 60);
  if p_token is null then
    return jsonb_build_object('ok', false, 'reason', 'no_token');
  end if;
  select * into l from deploy_lock where id = 1;
  if l.token is null then
    return jsonb_build_object('ok', false, 'reason', 'lane_free',
      'message', 'Nobody holds the lane; nothing to renew.');
  end if;
  if l.token <> p_token then
    return jsonb_build_object('ok', false, 'reason', 'not_lock_holder',
      'held_by', l.holder, 'title', l.title);
  end if;
  select status into v_status from deploy_batch where id = p_batch;
  if v_status is null then
    return jsonb_build_object('ok', false, 'reason', 'no_such_batch');
  end if;
  if v_status not in ('merging','testing','deploying') then
    return jsonb_build_object('ok', false, 'reason', 'batch_closed', 'status', v_status);
  end if;
  v_held := extract(epoch from now() - coalesce(l.acquired_at, now()))::int;
  if v_held > v_max then
    return jsonb_build_object('ok', false, 'reason', 'max_hold', 'held_s', v_held,
      'max_hold_s', v_max,
      'message', format('Lane held %ss, past max_hold_s %s — not renewing; the TTL frees it.', v_held, v_max));
  end if;
  v_exp := now() + make_interval(mins => v_ttl);
  -- the renewal is ONE conditional update: still the holder => extended.
  update deploy_lock
     set expires_at = v_exp, renewals = coalesce(renewals, 0) + 1, renewed_at = now(),
         holder = coalesce(holder, p_agent)
   where id = 1 and token = p_token
  returning * into l;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_lock_holder');
  end if;
  update deploy_batch
     set renewals = coalesce(renewals, 0) + 1, touched_at = now()
   where id = p_batch;
  return jsonb_build_object('ok', true, 'batch_id', p_batch, 'renewals', l.renewals,
    'held_s', v_held, 'expires_at', v_exp, 'expires_in_s', v_ttl * 60, 'ttl_minutes', v_ttl);
end $function$;

-- ── 2. merge_batch_open — reset the renewal counter on a fresh claim ────────
create or replace function public.merge_batch_open(p_agent text, p_max integer default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare l deploy_lock%rowtype; v_token uuid := gen_random_uuid();
        cfg jsonb := _mq_cfg(); v_max int; v_ttl int; v_batch bigint; v_n int;
        v_win int; v_minb int; v_waiting int; v_oldest timestamptz; v_left int;
begin
  perform _dev_guard();
  v_max := coalesce(p_max, (cfg->>'max_batch')::int, 10);
  v_ttl := coalesce((cfg->>'lock_ttl_minutes')::int, 2);

  if coalesce((cfg->>'enabled')::boolean, true) is not true then
    return jsonb_build_object('ok', false, 'reason','disabled');
  end if;

  select count(*), min(pushed_at) into v_waiting, v_oldest
    from deploy_queue where status = 'waiting';
  if coalesce(v_waiting,0) = 0 then
    return jsonb_build_object('ok', false, 'reason','empty', 'message','Nothing waiting.');
  end if;

  -- THE WINDOW (CHANGE #1674; #1822 raised window_s to 300): the OLDEST waiting
  -- branch owns the clock, so a lone branch waits up to window_s for company
  -- and never longer.
  v_win  := coalesce((cfg->>'window_s')::int, 300);
  v_minb := greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1);
  if v_win > 0 and v_waiting < v_minb and v_oldest > now() - make_interval(secs => v_win) then
    v_left := greatest(ceil(extract(epoch from (v_oldest + make_interval(secs => v_win)) - now()))::int, 0);
    return jsonb_build_object('ok', false, 'reason','window',
      'waiting', v_waiting, 'need', v_minb, 'window_s', v_win, 'window_left_s', v_left,
      'message', format('Batch window open — %s of %s branch(es), %ss left.', v_waiting, v_minb, v_left));
  end if;

  select * into l from deploy_lock where id = 1 for update;
  if not found then
    insert into deploy_lock(id) values (1) on conflict (id) do nothing;
    select * into l from deploy_lock where id = 1 for update;
  end if;
  if l.token is not null and l.expires_at > now() then
    return jsonb_build_object('ok', false, 'reason','busy', 'held_by', l.holder,
      'frees_in_s', greatest(extract(epoch from l.expires_at - now())::int, 0));
  end if;

  update deploy_lock
     set token = v_token, holder = coalesce(p_agent,'merge-worker'),
         title = 'merge batch', acquired_at = now(),
         expires_at = now() + make_interval(mins => greatest(v_ttl, 1)),
         renewals = 0, renewed_at = null
   where id = 1;

  insert into deploy_batch(status, agent, token, touched_at)
  values ('merging', coalesce(p_agent,'merge-worker'), v_token, now())
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
    'expires_at', now() + make_interval(mins => greatest(v_ttl, 1)),
    'touch_every_s', coalesce((cfg->>'touch_every_s')::int, 30),
    'next_step','Start the merge_lane_touch ticker, merge every branch onto main, call merge_batch_tree(batch, tree_sha) to learn what an earlier batch of this exact tree already finished, RELEASE the lane, then run the protected suite AND the flutter build unlocked. merge_batch_prenumber(batch) gives you the change number without the lock; take the lane back only for the migration replay, the upload and the verify — and keep touching it.');
end $function$;

-- ── 3. merge_lane_relock — the TTL is lock_ttl_minutes; the ticker holds it ─
create or replace function public.merge_lane_relock(p_batch bigint, p_agent text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare l deploy_lock%rowtype; v_token uuid := gen_random_uuid();
        cfg jsonb := _mq_cfg(); v_ttl int; b deploy_batch%rowtype; v_n int;
begin
  perform _dev_guard();
  v_ttl := greatest(coalesce((cfg->>'lock_ttl_minutes')::int, 2), 1);
  select * into b from deploy_batch where id = p_batch;
  if b.id is null or b.status not in ('testing','merging') then
    return jsonb_build_object('ok', false, 'error','batch_not_open',
      'status', coalesce(b.status,'(missing)'));
  end if;

  select * into l from deploy_lock where id = 1 for update;
  if not found then
    insert into deploy_lock(id) values (1) on conflict (id) do nothing;
    select * into l from deploy_lock where id = 1 for update;
  end if;
  if l.token is not null and l.expires_at > now() then
    return jsonb_build_object('ok', false, 'reason','busy', 'held_by', l.holder,
      'frees_in_s', greatest(extract(epoch from l.expires_at - now())::int, 0));
  end if;

  -- CHANGE #1822 — a SHORT TTL on purpose. The worker renews it every
  -- touch_every_s with merge_lane_touch while it works, so a live deploy never
  -- expires, and a dead holder frees the lane in lock_ttl_minutes instead of 15.
  update deploy_lock
     set token = v_token, holder = coalesce(p_agent, b.agent, 'merge-worker'),
         title = 'deploy batch ' || p_batch, acquired_at = now(),
         expires_at = now() + make_interval(mins => v_ttl),
         renewals = 0, renewed_at = null
   where id = 1;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error','lane_row_missing',
      'message','deploy_lock has no id=1 row — the lane cannot be held.');
  end if;

  update deploy_batch set token = v_token, status = 'deploying',
                          tested_at = coalesce(tested_at, now()),
                          relocked_at = now(), touched_at = now()
   where id = p_batch;

  return jsonb_build_object('ok', true, 'token', v_token, 'batch_id', p_batch,
    'ttl_minutes', v_ttl, 'touch_every_s', coalesce((cfg->>'touch_every_s')::int, 30),
    'next_step','Start the merge_lane_touch ticker NOW. merge_batch_number(token) (idempotent after prenumber), replay migrations, upload, verify, merge_batch_finish(token) — finish works even if the lane was lost.');
end $function$;

-- ── 4. merge_batch_finish — records the outcome, lane or no lane ────────────
create or replace function public.merge_batch_finish(p_token uuid, p_status text default 'success', p_commit text default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare l deploy_lock%rowtype; b deploy_batch%rowtype; v_hold int; v_total int; v_ok boolean;
        v_holder boolean := false; v_released boolean := false; v_since timestamptz;
begin
  perform _dev_guard();
  if p_token is null then
    return jsonb_build_object('ok', false, 'error', 'no_token');
  end if;
  -- The batch is found by ITS token, never by the lock's: the lock may have
  -- expired and been swept, or even be held by someone else by now. The
  -- deploy already happened; writing it down cannot depend on the lane.
  select * into b from deploy_batch where token = p_token order by id desc limit 1 for update;
  if b.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_token',
      'message', 'No batch carries this token.');
  end if;

  -- Idempotent: a second finish for the same batch reports what was recorded
  -- and claims nothing. (The token stays on the closed batch for exactly this.)
  if b.status in ('deployed', 'failed') then
    return jsonb_build_object('ok', true, 'already', true, 'batch_id', b.id,
      'change_no', b.change_no, 'hold_s', coalesce(b.hold_s, 0), 'deploy_hold_s', 0,
      'status', b.status, 'lane_released', false,
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

  -- Release the lane ONLY if this token still holds it. A lane that expired
  -- and was re-taken by someone else is theirs; a swept lane is already free.
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

  return jsonb_build_object('ok', true, 'already', false, 'batch_id', b.id, 'change_no', b.change_no,
    'hold_s', v_total, 'deploy_hold_s', v_hold, 'renewals', coalesce(b.renewals, 0),
    'status', case when v_ok then 'deployed' else 'failed' end,
    'lane_released', v_released,
    'lane_note', case when v_released then 'lane released'
                      when l.token is null then 'lane was already free (claim expired before finish)'
                      else 'lane held by ' || coalesce(l.holder, '?') || ' — left alone' end,
    'target_hold_s', coalesce((_mq_cfg()->>'target_hold_s')::int, 60));
end $function$;

-- ── 5. merge_batch_tree — resume a batch, never restart it ──────────────────
create or replace function public.merge_batch_tree(p_batch bigint, p_tree_sha text, p_agent text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
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

  -- the most recent earlier batch of EXACTLY this tree that did not finish
  select * into p from deploy_batch
   where tree_sha = p_tree_sha and id < b.id and status = 'failed'
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

  -- The change number the earlier batch reserved is reused ONLY while it is
  -- still ahead of what is live: version.json never goes backwards.
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
  -- the upload is skippable only when the SAME number is being published
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
    'message', format('Tree %s already reached %s in batch %s — resuming at %s%s.',
      left(p_tree_sha, 7), coalesce(array_to_string(v_done, ','), '(nothing)'), p.id, v_next,
      case when v_reused then ', CHANGE #' || b.change_no || ' reused' else '' end));
end $function$;

-- ── 6. deploy_lane_sweep — a touched batch is a live batch ──────────────────
create or replace function public.deploy_lane_sweep()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
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
                         acquired_at = null, expires_at = null,
                         renewals = 0, renewed_at = null
   where id = 1 and token is not null and expires_at < now();
  get diagnostics v_locks = row_count;

  -- a queue entry whose batch died with its worker goes back to waiting once,
  -- then fails — a branch that cannot merge must not spin the lane forever.
  -- CHANGE #1822: liveness is the newest of the log, touched_at (the renewal
  -- ticker) and opened_at — a batch that is renewing its lane is alive.
  update deploy_queue q
     set status = case when attempts >= 2 then 'failed' else 'waiting' end,
         batch_id = null, batched_at = null, attempts = attempts + 1,
         reason = 'batch expired before it deployed',
         finished_at = case when attempts >= 2 then now() end
   where status in ('batched','merged')
     and exists (select 1 from deploy_batch b
                  where b.id = q.batch_id
                    and b.status in ('merging','testing','deploying')
                    and greatest(coalesce((select max((e->>'at')::timestamptz) from jsonb_array_elements(coalesce(b.log,'[]'::jsonb)) e), b.opened_at),
                                 coalesce(b.touched_at, b.opened_at))
         < now() - make_interval(mins => v_ttl))  /* c1819_liveness c1822_touch */;
  get diagnostics v_q = row_count;

  update deploy_batch set status = 'failed', closed_at = now(),
                          note = coalesce(note,'') || ' expired by deploy_lane_sweep'
   where status in ('merging','testing','deploying')
     and greatest(coalesce((select max((e->>'at')::timestamptz) from jsonb_array_elements(coalesce(log,'[]'::jsonb)) e), opened_at),
                  coalesce(touched_at, opened_at))
         < now() - make_interval(mins => v_ttl);

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
end $function$;

-- ── 7. deploy_lane_status — the renewal line ────────────────────────────────
create or replace function public.deploy_lane_status(p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
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
    'config', cfg);
end $function$;

-- ── 8. knobs — pool_set()-able, no deploy needed to change them later ───────
insert into public.dev_runner_config(key, value)
values ('merge_queue', '{"enabled":true,"max_batch":10,"sweep_alert":true,"target_hold_s":180,"claim_ttl_minutes":20,"window_min_branches":3}'::jsonb)
on conflict (key) do nothing;
update public.dev_runner_config
   set value = value || jsonb_build_object('lock_ttl_minutes', 2, 'window_s', 300,
                                           'touch_every_s', 30, 'max_hold_s', 3600)
 where key = 'merge_queue';

grant execute on function public.merge_lane_touch(bigint, text, uuid) to service_role;
grant execute on function public.merge_batch_tree(bigint, text, text) to service_role;
notify pgrst, 'reload schema';

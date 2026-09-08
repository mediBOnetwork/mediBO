-- CHANGE #1674 — BUILD SPEED v2.
--
-- Measured on the ten commands completed on 5 Sep: the CODE takes 1-17 minutes
-- and the deploy lane holds 375-891 seconds per change against a 60 s target,
-- with a batch size of ONE almost every time. Every row graded xlarge off spec
-- LENGTH, so a two-file fix bought the same hostile QA as a schema rewrite.
-- Every resume re-read the whole spec. Every command re-ran every journey.
--
-- Five levers, all of them config-driven so a knob moves without a deploy:
--   1. the lane batches on a WINDOW and builds OUTSIDE the lock
--   2. QA is graded off the REAL diff, not the spec's character count
--   3. a resume is handed a brief, changed files and the last error — nothing else
--   4. a journey green on this exact commit inside the reuse window is reused
--   5. same-file commands chain at ADD time against pending rows as well as building ones
--
-- Idempotent: every object is create-or-replace / if-not-exists, and every
-- config write merges rather than overwrites.

-- ───────────────────────────────────────────────────────────────────────────
-- 0. CONFIG
-- ───────────────────────────────────────────────────────────────────────────
insert into dev_runner_config(key, value) values ('merge_queue', '{}'::jsonb)
  on conflict (key) do nothing;

update dev_runner_config
   set value = value
     || jsonb_build_object(
          -- Hold the lane open for late branches instead of deploying each one
          -- alone: one 3-minute deploy for three branches beats three of them.
          'window_s',            coalesce((value->>'window_s')::int, 90),
          'window_min_branches', coalesce((value->>'window_min_branches')::int, 3),
          -- The spec's own number. 60 s was unreachable while the BUILD ran
          -- inside the lock, and a target nothing can hit stops being read.
          'target_hold_s',       180)
 where key = 'merge_queue';

update dev_runner_config
   set value = jsonb_set(
         jsonb_set(value, '{qa}',   coalesce(value->'qa','{}'::jsonb)
              || jsonb_build_object('journey_reuse_min',
                   coalesce((value->'qa'->>'journey_reuse_min')::int, 60))),
         '{chain}', coalesce(value->'chain','{}'::jsonb)
              || jsonb_build_object('include_pending',
                   coalesce((value->'chain'->>'include_pending')::boolean, true),
                   'idle_alert', coalesce((value->'chain'->>'idle_alert')::boolean, true)))
 where key = 'worker_pool';

-- dev_qa_scope grades off this row; without it every command fell through to
-- 'standard' with a NULL round count.
insert into dev_qa_scope_config(id, enabled, targeted_max_files, targeted_max_spec_chars,
                                standard_max_files, deep_min_spec_chars,
                                rounds_targeted, rounds_standard, rounds_deep)
values (true, true, 4, 1200, 12, 4000, 1, 1, 3)
  on conflict (id) do nothing;

-- ───────────────────────────────────────────────────────────────────────────
-- 1. THE REAL DIFF LIVES ON THE ROW
-- ───────────────────────────────────────────────────────────────────────────
alter table dev_commands add column if not exists diff_files    int;
alter table dev_commands add column if not exists diff_rows     int;
alter table dev_commands add column if not exists grade_source  text;
alter table dev_commands add column if not exists grade_reason  text;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. LANE — batch window, pre-numbering, per-phase timings
-- ───────────────────────────────────────────────────────────────────────────
-- The lane is a singleton row. When it is MISSING every lock call silently
-- no-ops and still answers ok:true — merge_lane_relock "took" a lane that did
-- not exist during this build's own smoke test. One row closes it for good.
insert into deploy_lock(id) values (1) on conflict (id) do nothing;

create or replace function public.merge_batch_open(p_agent text, p_max integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare l deploy_lock%rowtype; v_token uuid := gen_random_uuid();
        cfg jsonb := _mq_cfg(); v_max int; v_ttl int; v_batch bigint; v_n int;
        v_win int; v_minb int; v_waiting int; v_oldest timestamptz; v_left int;
begin
  perform _dev_guard();
  v_max := coalesce(p_max, (cfg->>'max_batch')::int, 10);
  v_ttl := coalesce((cfg->>'lock_ttl_minutes')::int, 5);

  if coalesce((cfg->>'enabled')::boolean, true) is not true then
    return jsonb_build_object('ok', false, 'reason','disabled');
  end if;

  select count(*), min(pushed_at) into v_waiting, v_oldest
    from deploy_queue where status = 'waiting';
  if coalesce(v_waiting,0) = 0 then
    return jsonb_build_object('ok', false, 'reason','empty', 'message','Nothing waiting.');
  end if;

  -- ── THE WINDOW (CHANGE #1674) ────────────────────────────────────────────
  -- A batch of one pays the whole merge+test+deploy bill for one branch. The
  -- lane now waits window_s for company, and never longer: the OLDEST waiting
  -- branch owns the clock, so a lone branch still ships window_s later, not
  -- whenever a second one happens to arrive.
  v_win  := coalesce((cfg->>'window_s')::int, 90);
  v_minb := greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1);
  if v_win > 0 and v_waiting < v_minb and v_oldest > now() - make_interval(secs => v_win) then
    v_left := greatest(ceil(extract(epoch from (v_oldest + make_interval(secs => v_win)) - now()))::int, 0);
    return jsonb_build_object('ok', false, 'reason','window',
      'waiting', v_waiting, 'need', v_minb, 'window_s', v_win, 'window_left_s', v_left,
      'message', format('Batch window open — %s of %s branch(es), %ss left.', v_waiting, v_minb, v_left));
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
    'next_step','Merge every branch onto main, RELEASE the lane, then run the protected suite AND the flutter build unlocked. merge_batch_prenumber(batch) gives you the change number for version.json without the lock; take the lane back only for the migration replay, the upload and the verify.');
end $fn$;

-- The change number, claimed while the lane is FREE. Burning a number on a
-- failed batch costs nothing; holding the deploy lock across a six-minute
-- flutter build cost every other runner six minutes.
create or replace function public.merge_batch_prenumber(p_batch bigint, p_agent text default null,
                                                        p_commit text default null, p_title text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare b deploy_batch%rowtype; v_no int; v_title text;
begin
  perform _dev_guard();
  select * into b from deploy_batch where id = p_batch for update;
  if b.id is null then return jsonb_build_object('ok', false, 'error','no_such_batch'); end if;
  if b.status not in ('merging','testing','deploying') then
    return jsonb_build_object('ok', false, 'error','batch_not_open', 'status', b.status);
  end if;
  if b.change_no is not null then
    return jsonb_build_object('ok', true, 'change_no', b.change_no, 'batch_id', b.id,
                              'already', true);
  end if;

  select greatest(coalesce((select max(change_no) from deploy_registry), 0),
                  coalesce((select change_no from app_version_state where id = 1), 0)) + 1
    into v_no;

  v_title := coalesce(p_title,
    (select string_agg('#'||command_id, ' + ' order by pushed_at)
       from deploy_queue where batch_id = b.id and status in ('batched','merged')),
    'merge batch '||b.id);

  insert into deploy_registry(change_no, title, agent, branch, commit_sha, status, batch_id)
  values (v_no, v_title, coalesce(p_agent, b.agent, 'merge-worker'), 'main', p_commit, 'claimed', b.id);

  update deploy_batch set change_no = v_no, commit_sha = coalesce(p_commit, commit_sha)
   where id = b.id;
  update deploy_queue set change_no = v_no where batch_id = b.id and status = 'batched';

  return jsonb_build_object('ok', true, 'change_no', v_no, 'batch_id', b.id, 'title', v_title,
    'already', false,
    'next_step','Stamp version.json with '||v_no||' and BUILD now, lane free. Relock only for replay + upload + verify.');
end $fn$;

create or replace function public.merge_batch_number(p_token uuid, p_title text default null, p_commit text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
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

  -- CHANGE #1674 — idempotent. merge_batch_prenumber may already have claimed
  -- the number so the build could stamp version.json with the lane free.
  if b.change_no is not null then
    v_no := b.change_no;
    update deploy_batch set status = 'deploying', tested_at = coalesce(tested_at, now()),
                            merged_at = coalesce(merged_at, now()),
                            commit_sha = coalesce(p_commit, commit_sha)
     where id = b.id;
    update deploy_queue set change_no = v_no, status = 'merged'
     where batch_id = b.id and status = 'batched';
    return jsonb_build_object('ok', true, 'change_no', v_no, 'batch_id', b.id,
      'title', (select title from deploy_registry where change_no = v_no),
      'prenumbered', true,
      'next_step','Replay migrations, upload, verify, then merge_batch_finish(token, ''success'', commit).');
  end if;

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
    'prenumbered', false,
    'next_step','Stamp version.json with '||v_no||', deploy once, verify live, then merge_batch_finish(token, ''success'', commit).');
end $fn$;

-- Per-phase timing. Without it "held 891s" says nothing about WHICH half.
create or replace function public.merge_batch_phase(p_batch bigint, p_phase text,
                                                    p_seconds integer, p_note text default null,
                                                    p_locked boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare b deploy_batch%rowtype;
begin
  perform _dev_guard();
  if coalesce(btrim(p_phase),'') = '' then
    return jsonb_build_object('ok', false, 'error','phase_required');
  end if;
  update deploy_batch
     set log = coalesce(log, '[]'::jsonb) || jsonb_build_object(
                 'at', now(), 'phase', p_phase, 'seconds', greatest(coalesce(p_seconds,0),0),
                 'locked', coalesce(p_locked,false), 'note', p_note)
   where id = p_batch
  returning * into b;
  if b.id is null then return jsonb_build_object('ok', false, 'error','no_such_batch'); end if;
  return jsonb_build_object('ok', true, 'batch_id', b.id, 'phase', p_phase,
                            'seconds', greatest(coalesce(p_seconds,0),0),
                            'phases', public.merge_batch_phases(b.id));
end $fn$;

-- One reader for the phase log, so the card and the RPC agree.
create or replace function public.merge_batch_phases(p_batch bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'phase', e->>'phase',
           'seconds', coalesce((e->>'seconds')::int, 0),
           'locked', coalesce((e->>'locked')::boolean, false),
           'label', (e->>'phase') || ' · ' || coalesce((e->>'seconds')::int, 0) || 's'
                    || case when coalesce((e->>'locked')::boolean, false) then ' (lane held)' else '' end,
           'tone', case when coalesce((e->>'locked')::boolean, false) then 'warning' else 'info' end)
           order by (e->>'at')::timestamptz), '[]'::jsonb)
    from deploy_batch b, lateral jsonb_array_elements(coalesce(b.log, '[]'::jsonb)) e
   where b.id = p_batch and (e ? 'seconds');
$fn$;

-- A lane call that updates nothing must never answer ok:true. This is what let
-- the smoke test above "hold" a lane that had no row at all.
create or replace function public.merge_lane_relock(p_batch bigint, p_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare l deploy_lock%rowtype; v_token uuid := gen_random_uuid();
        cfg jsonb := _mq_cfg(); v_ttl int; b deploy_batch%rowtype; v_n int;
begin
  perform _dev_guard();
  v_ttl := coalesce((cfg->>'lock_ttl_minutes')::int, 5);
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

  -- The deploy is the short half now (replay + upload + verify), but the TTL
  -- stays generous: an expired lock mid-upload is worse than a slow lane.
  update deploy_lock
     set token = v_token, holder = coalesce(p_agent, b.agent, 'merge-worker'),
         title = 'deploy batch ' || p_batch, acquired_at = now(),
         expires_at = now() + make_interval(mins => greatest(v_ttl * 3, 10))
   where id = 1;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error','lane_row_missing',
      'message','deploy_lock has no id=1 row — the lane cannot be held.');
  end if;

  update deploy_batch set token = v_token, status = 'deploying',
                          tested_at = coalesce(tested_at, now())
   where id = p_batch;

  return jsonb_build_object('ok', true, 'token', v_token, 'batch_id', p_batch,
    'next_step','merge_batch_number(token) (idempotent after prenumber), replay migrations, upload, verify, merge_batch_finish(token).');
end $fn$;

-- ───────────────────────────────────────────────────────────────────────────
-- 3. QA, GRADED OFF THE REAL DIFF
-- ───────────────────────────────────────────────────────────────────────────
-- The runner reports what it actually changed (files + rows + danger) and the
-- BACKEND decides the grade. Spec length graded #1674 itself xlarge before a
-- line was written; the diff cannot lie about what a command touched.
create or replace function public.dev_cmd_grade(p_id bigint, p_files integer, p_rows integer,
                                                p_danger boolean default null,
                                                p_paths text[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; cfg public.dev_qa_scope_config%rowtype;
        v_files int; v_rows int; v_danger boolean; v_size text; v_why text;
        v_scope jsonb; v_mig boolean;
begin
  perform _dev_guard();
  select * into cfg from public.dev_qa_scope_config where id;
  select id, spec, is_danger, size_class, area, kind into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error','no such command'); end if;

  v_files  := greatest(coalesce(p_files, 0), 0);
  v_rows   := greatest(coalesce(p_rows,  0), 0);
  v_danger := coalesce(p_danger, r.is_danger, false);
  v_mig    := coalesce((select bool_or(f like 'supabase/%') from unnest(coalesce(p_paths,'{}')) f), false);

  -- Three bands, and DANGER always tops out. Rows matter as much as files: one
  -- file with 900 new lines is not a small command.
  v_size := case
    when v_danger or v_mig and v_rows >= 600 then 'xlarge'
    when v_files > coalesce(cfg.standard_max_files, 12) or v_rows >= 800 then 'xlarge'
    when v_files > coalesce(cfg.targeted_max_files, 4)  or v_rows >= 200 then 'normal'
    else 'small' end;

  v_why := format('Graded off the real diff: %s file(s), %s changed row(s)%s%s.',
             v_files, v_rows,
             case when v_mig then ', migration included' else '' end,
             case when v_danger then ', flagged dangerous' else '' end);

  update dev_commands
     set diff_files = v_files, diff_rows = v_rows,
         size_class = v_size, grade_source = 'diff', grade_reason = v_why
   where id = p_id;

  v_scope := public.dev_qa_scope(p_id);

  return jsonb_build_object('ok', true, 'command_id', p_id,
    'size_class', v_size, 'files', v_files, 'rows', v_rows,
    'danger', v_danger, 'has_migration', v_mig,
    'why', v_why,
    'chip', public._dev_grade_chip(v_size, v_scope->>'scope', (v_scope->>'rounds_max')::int),
    'scope', v_scope);
end $fn$;

create or replace function public._dev_grade_chip(p_size text, p_scope text, p_rounds integer)
returns text language sql immutable as $fn$
  select case
    when coalesce(p_size,'') = '' then ''
    else initcap(p_size) || ' · '
         || case coalesce(p_scope,'standard')
              when 'targeted' then 'targeted QA'
              when 'deep'     then 'hostile QA'
              else 'standard QA' end
         || ' · ' || coalesce(p_rounds, 1) || case when coalesce(p_rounds,1) = 1 then ' round' else ' rounds' end
  end;
$fn$;

-- dev_qa_scope now prefers the measured diff over the spec's character count,
-- and a small/normal grade never buys a hostile pass.
create or replace function public.dev_qa_scope(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  cfg   public.dev_qa_scope_config%rowtype;
  r     record;
  v_files text[];
  v_n int; v_chars int; v_mig boolean; v_dart boolean; v_rowsc int;
  v_scope text; v_why text; v_rounds int; v_graded boolean;
begin
  select * into cfg from public.dev_qa_scope_config where id;
  select id, spec, is_danger, kind, route, size_class, area, qa_required,
         diff_files, diff_rows, grade_source
    into r from public.dev_commands where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'not_found', true);
  end if;

  v_files  := coalesce(public.dev_cmd_footprint(p_id), '{}');
  v_graded := coalesce(r.grade_source,'') = 'diff';
  v_n      := case when v_graded then coalesce(r.diff_files, 0)
                   else coalesce(array_length(v_files, 1), 0) end;
  v_rowsc  := coalesce(r.diff_rows, 0);
  v_chars  := length(coalesce(r.spec, ''));
  v_mig    := exists (select 1 from unnest(v_files) f where f like 'supabase/%');
  v_dart   := exists (select 1 from unnest(v_files) f where f like '%.dart');

  if not coalesce(cfg.enabled, false) then
    v_scope := 'deep';
    v_why   := 'Scope grading is switched off — every command gets the deep treatment.';
  elsif r.is_danger then
    v_scope := 'deep';
    v_why   := 'Deep — the row is flagged dangerous, so QA gets the full hostile pass whatever its size.';
  elsif v_graded then
    -- CHANGE #1674: the diff has been measured, so the spec's length stops voting.
    v_scope := case r.size_class when 'xlarge' then 'deep'
                                 when 'small'  then 'targeted'
                                 else 'standard' end;
    v_why   := format('%s — graded off the real diff: %s file(s), %s changed row(s). The spec was %s characters and no longer votes.',
                      initcap(v_scope), v_n, v_rowsc, v_chars);
  elsif v_chars >= coalesce(cfg.deep_min_spec_chars, 4000) or v_n > coalesce(cfg.standard_max_files, 12) then
    v_scope := 'deep';
    v_why   := format('Deep — %s files touched and a %s-character spec: genuinely large work. No diff reported yet.', v_n, v_chars);
  elsif v_n > 0 and v_n <= coalesce(cfg.targeted_max_files, 4)
        and v_chars <= coalesce(cfg.targeted_max_spec_chars, 1200) then
    v_scope := 'targeted';
    v_why   := format('Targeted — %s file(s) touched, %s-character spec. One round against the preview is the right size.', v_n, v_chars);
  else
    v_scope := 'standard';
    v_why   := format('Standard — %s file(s) touched, %s-character spec.', v_n, v_chars);
  end if;

  v_rounds := case v_scope when 'targeted' then coalesce(cfg.rounds_targeted, 1)
                           when 'standard' then coalesce(cfg.rounds_standard, 1)
                           else coalesce(cfg.rounds_deep, 3) end;

  update public.dev_commands set qa_scope = v_scope where id = p_id;

  return jsonb_build_object(
    'ok', true, 'command_id', p_id,
    'scope', v_scope,
    'rounds_max', v_rounds,
    'files_touched', v_n,
    'diff_rows', v_rowsc,
    'graded_from', case when v_graded then 'diff' else 'spec' end,
    'spec_chars', v_chars,
    'has_migration', v_mig,
    'has_dart', v_dart,
    'size_class', r.size_class,
    'label', case v_scope
      when 'targeted' then format('Targeted QA · %s round', v_rounds)
      when 'standard' then format('Standard QA · %s round', v_rounds)
      else format('Deep QA · up to %s rounds', v_rounds) end,
    'grade_chip', public._dev_grade_chip(r.size_class, v_scope, v_rounds),
    'tone', case v_scope when 'targeted' then 'success' when 'standard' then 'info' else 'warning' end,
    'why', v_why,
    'checks', case v_scope
      when 'targeted' then jsonb_build_array('boot', 'version', 'area smoke')
      when 'standard' then jsonb_build_array('boot', 'version', 'api smoke', 'area smoke')
      else jsonb_build_array('boot', 'version', 'api smoke', 'area smoke', 'edge cases', 'spec promises') end,
    'instruction', format('Run %s QA round(s) against the PREVIEW. Hold no lane while testing — QA never takes the deploy lock or a DB lane.', v_rounds));
end $fn$;

-- ───────────────────────────────────────────────────────────────────────────
-- 4. RESUME ECONOMY — measure it, then stop paying for it
-- ───────────────────────────────────────────────────────────────────────────
-- #1361 burned 5.4M tokens, #1367 2.4M, #1570 2.8M, each across 1-3 resumes,
-- because every resume handed the session the whole spec again. The ledger
-- records what a resume ACTUALLY costs so the Context economy card can show
-- the number moving instead of an opinion about it.
create table if not exists public.dev_resume_ledger (
  id           bigserial primary key,
  command_id   bigint      not null,
  resume_no    int         not null,
  at           timestamptz not null default now(),
  tokens_at    bigint      not null default 0,
  tokens_added bigint,
  closed_at    timestamptz
);
create unique index if not exists dev_resume_ledger_uq   on public.dev_resume_ledger(command_id, resume_no);
create index        if not exists dev_resume_ledger_open on public.dev_resume_ledger(command_id) where closed_at is null;

create or replace function public._dev_resume_ledger_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_tok bigint;
begin
  v_tok := coalesce(new.cost_input_tokens,0) + coalesce(new.cost_output_tokens,0);

  if coalesce(new.resume_count,0) > coalesce(old.resume_count,0) then
    update public.dev_resume_ledger
       set tokens_added = greatest(v_tok - tokens_at, 0), closed_at = now()
     where command_id = new.id and closed_at is null;
    insert into public.dev_resume_ledger(command_id, resume_no, tokens_at)
    values (new.id, new.resume_count, v_tok)
    on conflict (command_id, resume_no) do nothing;
  elsif new.status in ('completed','failed') and old.status is distinct from new.status then
    update public.dev_resume_ledger
       set tokens_added = greatest(v_tok - tokens_at, 0), closed_at = now()
     where command_id = new.id and closed_at is null;
  end if;
  return null;
end $fn$;

drop trigger if exists trg_dev_resume_ledger on public.dev_commands;
create trigger trg_dev_resume_ledger
  after update on public.dev_commands
  for each row execute function public._dev_resume_ledger_trg();

-- The brief a resumed session is handed: steps, the files it touched, and the
-- last error. Never the spec — `devcmd.sh spec <id>` prints the checklist when
-- it is genuinely needed, and re-reading the prompt file is what this ends.
create or replace function public.dev_cmd_resume_brief(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_cap int; v_txt text; v_src text; v_open text; v_next text; v_dec int;
        v_files text[]; v_err text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  v_cap := coalesce((dev_context_cfg()->>'resume_words')::int, 200);

  v_files := coalesce(public.dev_cmd_footprint(p_id), '{}');
  v_err   := nullif(btrim(coalesce(right(r.error_log, 400), '')), '');

  if coalesce(btrim(r.resume_note),'') <> '' then
    v_txt := r.resume_note; v_src := 'state_file';
  else
    v_src := 'derived';
    select string_agg(n || '. ' || left(text, 90), '; ' order by n)
      into v_open from dev_command_spec_item
     where command_id = p_id and status = 'open';
    select s->>'title' into v_next
      from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
     where s->>'status' <> 'done' order by (s->>'n')::int limit 1;
    v_dec := coalesce(jsonb_array_length(coalesce(r.decisions,'[]'::jsonb)), 0);
    v_txt := concat_ws(' ',
      'RESUME #' || p_id || '.',
      coalesce(r.steps_done,0) || '/' || coalesce(r.steps_total,0) || ' steps landed on branch ' ||
        coalesce(nullif(r.resume_branch,''), 'main') ||
        case when coalesce(r.resume_commit,'') <> '' then ' @' || left(r.resume_commit,12) else '' end || '.',
      case when v_dec > 0 then v_dec || ' decisions logged.' else '' end,
      case when v_next is not null then 'Next step: ' || v_next || '.' else 'All steps landed.' end,
      case when v_open is not null then 'Spec still open: ' || v_open || '.' else 'Spec checklist clear.' end,
      'Verify what landed before trusting it; migrations are idempotent. Do NOT re-read the prompt file.');
    v_txt := _dev_words_cap(v_txt, v_cap);
  end if;

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'source', v_src, 'text', v_txt,
    'words', _dev_word_count(v_txt), 'cap_words', v_cap,
    'branch', r.resume_branch, 'commit', r.resume_commit,
    'files', to_jsonb(v_files),
    'files_label', case when coalesce(array_length(v_files,1),0) = 0 then ''
                        else 'Files this command owns: ' ||
                             array_to_string(v_files[1:12], ', ') ||
                             case when array_length(v_files,1) > 12
                                  then ' (+' || (array_length(v_files,1) - 12) || ' more)' else '' end end,
    'last_error', coalesce(v_err, ''),
    'last_error_label', case when v_err is null then '' else 'Last error: ' || v_err end,
    'resume_count', coalesce(r.resume_count,0),
    'steps_done', coalesce(r.steps_done,0), 'steps_total', coalesce(r.steps_total,0),
    'written_at', r.resume_note_at);
end $fn$;

-- One more row on the Context economy card: what a resume actually costs.
create or replace function public.dev_context_metrics(p_window integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_cfg jsonb; v_since timestamptz; v_w int;
        v_before numeric; v_after numeric; v_after_n int; v_before_n int;
        v_compact int; v_clear int; v_failed int; v_resume_words numeric; v_resume_n int;
        v_rb numeric; v_ra numeric; v_rb_n int; v_ra_n int;
        v_delta numeric; v_rows jsonb; v_tone text; v_delta_label text;
        v_rlabel text; v_rtone text; v_rsub text;
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

  -- CHANGE #1674 — tokens per resume, measured, both sides of the change.
  -- A resume that re-read the spec is a segment that cost as much as a build.
  select avg(tokens_added), count(*) into v_rb, v_rb_n
    from public.dev_resume_ledger where closed_at is not null and closed_at <  v_since and tokens_added > 0;
  select avg(tokens_added), count(*) into v_ra, v_ra_n
    from public.dev_resume_ledger where closed_at is not null and closed_at >= v_since and tokens_added > 0;

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
    'footnote', 'Measured over the ' || v_w || ' commands completed on each side of the change. Tokens / resume is measured per resumed segment, not guessed from the total.');
end $fn$;

-- ───────────────────────────────────────────────────────────────────────────
-- 5. JOURNEY DEDUPE — a probe green on THIS commit is not run again
-- ───────────────────────────────────────────────────────────────────────────
alter table public.dev_journey_runs add column if not exists commit_sha text;
alter table public.dev_journeys     add column if not exists files      text[];
create index if not exists dev_journey_runs_reuse
  on public.dev_journey_runs(journey_id, commit_sha, at desc) where status = 'passed';

create or replace function public.dev_journeys_run(p_command_id bigint, p_area text,
                                                   p_after_id bigint default null,
                                                   p_limit integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_claims text; j record; v jsonb; st text; v_ev jsonb;
  passed int := 0; failed int := 0; skipped int := 0; reused int := 0;
  v_cfg jsonb; v_limit int; v_budget int; v_reuse_min int;
  v_t0 timestamptz; v_p0 timestamptz; v_ms int;
  v_cursor bigint := coalesce(p_after_id, 0);
  v_last   bigint := coalesce(p_after_id, 0);
  v_scanned int := 0;
  v_stop text := 'complete';
  v_passed_ids bigint[] := '{}';
  promoted text[] := '{}';
  runs jsonb := '[]';
  v_more boolean;
  v_commit text; v_files text[]; v_prev timestamptz;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'dev_journeys_run: runner only';
  end if;
  v_claims := coalesce(current_setting('request.jwt.claims', true), '');

  select coalesce(value->'journeys', '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'worker_pool';
  v_cfg := coalesce(v_cfg, '{}'::jsonb);

  v_limit  := greatest(1,   least(coalesce(p_limit, nullif(v_cfg->>'max_per_run','')::int, 8),   40));
  v_budget := greatest(500, least(coalesce(nullif(v_cfg->>'budget_ms','')::int, 5000),         7000));

  select coalesce((value->'qa'->>'journey_reuse_min')::int, 60) into v_reuse_min
    from dev_runner_config where key = 'worker_pool';
  v_reuse_min := greatest(coalesce(v_reuse_min, 60), 0);

  -- The commit this command's branch actually stands on, and the files it owns.
  select nullif(btrim(coalesce(resume_commit,'')), '') into v_commit
    from dev_commands where id = p_command_id;
  v_files := coalesce(public.dev_cmd_footprint(p_command_id), '{}');

  v_t0 := clock_timestamp();

  for j in
    select dj.id, dj.name, dj.required, dj.files
      from dev_journeys dj
     where dj.enabled
       and (dj.area is null or dj.area = p_area)
       and dj.id > v_cursor
       -- FILE SCOPING: a global journey (no area) always runs. One that names
       -- files runs only when this command touched them. One that names none
       -- keeps its old behaviour, so nothing silently stops being tested.
       and (dj.area is null
            or dj.files is null
            or coalesce(array_length(dj.files,1),0) = 0
            or coalesce(array_length(public.dev_paths_conflict(dj.files, v_files),1),0) > 0)
     order by dj.id
     limit v_limit
  loop
    if extract(epoch from (clock_timestamp() - v_t0)) * 1000 >= v_budget then
      v_stop := 'budget';
      exit;
    end if;

    v_scanned := v_scanned + 1;
    v_last    := j.id;

    -- REUSE: green on this exact commit, inside the window. The probe is the
    -- same code against the same tree; running it again buys nothing.
    v_prev := null;
    if v_commit is not null and v_reuse_min > 0 then
      select r.at into v_prev
        from dev_journey_runs r
       where r.journey_id = j.id and r.status = 'passed'
         and r.commit_sha = v_commit
         and r.at > now() - make_interval(mins => v_reuse_min)
       order by r.at desc limit 1;
    end if;

    if v_prev is not null then
      reused := reused + 1;
      passed := passed + 1;
      -- Recorded as 'passed' because dev_journey_runs.status is CHECK-constrained
      -- and every completion gate reads that word. The evidence carries the
      -- truth, and the promotion query below refuses to count a reused row.
      insert into dev_journey_runs(command_id, journey_id, status, evidence, duration_ms, commit_sha)
      values (p_command_id, j.id, 'passed',
              jsonb_build_object('reused', true, 'reused_from', v_prev, 'commit', v_commit,
                                 'window_min', v_reuse_min), 0, v_commit);
      runs := runs || jsonb_build_object('journey', j.name, 'status','passed', 'reused', true,
                'evidence', jsonb_build_object('reused_from', v_prev), 'duration_ms', 0);
      continue;
    end if;

    perform set_config('request.jwt.claims', v_claims, true);
    v_p0 := clock_timestamp();
    v := dev_journey_probe(j.name);
    v_ms := (extract(epoch from (clock_timestamp() - v_p0)) * 1000)::int;

    insert into dev_journey_runs(command_id, journey_id, status, evidence, duration_ms, commit_sha)
    values (p_command_id, j.id, v->>'status', coalesce(v->'evidence','{}'), v_ms, v_commit)
    returning status, evidence into st, v_ev;

    if st = 'passed' then
      passed := passed + 1;
      if not j.required then v_passed_ids := v_passed_ids || j.id; end if;
    elsif st = 'failed' then failed := failed + 1;
    else skipped := skipped + 1;
    end if;

    runs := runs || jsonb_build_object('journey', j.name, 'status', st,
                                       'evidence', v_ev, 'duration_ms', v_ms);
  end loop;

  -- Promotion still needs REAL green runs: a reused verdict never promotes a
  -- journey to required, or one probe would make itself mandatory forever.
  if array_length(v_passed_ids, 1) > 0 then
    with promo as (
      update dev_journeys dj
         set required = true
       where dj.id = any(v_passed_ids)
         and not dj.required
         and (select count(*) from (
                select 1 from dev_journey_runs r
                 where r.journey_id = dj.id and r.status = 'passed'
                   and coalesce(r.evidence->>'reused','') <> 'true'
                 limit 2) z) >= 2
      returning dj.name)
    select coalesce(array_agg(name), '{}'::text[]) into promoted from promo;
  end if;

  if passed > 0 then
    update dev_commands set journey_pass_count = journey_pass_count + passed
     where id = p_command_id;
  end if;

  select exists (select 1 from dev_journeys
                  where enabled and (area is null or area = p_area) and id > v_last)
    into v_more;
  if v_more and v_stop = 'complete' then v_stop := 'ceiling'; end if;

  return jsonb_build_object(
    'ok', true, 'area', p_area,
    'passed', passed, 'failed', failed, 'skipped', skipped, 'reused', reused,
    'reuse_window_min', v_reuse_min, 'commit', coalesce(v_commit,''),
    'promoted_to_required', promoted, 'runs', runs,
    'scanned', v_scanned, 'row_ceiling', v_limit, 'budget_ms', v_budget,
    'elapsed_ms', (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int,
    'stopped', v_stop, 'has_more', coalesce(v_more, false), 'next_after_id', v_last);
end $fn$;

-- ───────────────────────────────────────────────────────────────────────────
-- 6. CLASH PREVENTION AT ADD TIME
-- ───────────────────────────────────────────────────────────────────────────
-- trg_dev_autochain already fires on INSERT, but require_lease=true meant a new
-- row could only be chained behind a command that was ALREADY BUILDING and
-- already holding the lease. Two rows added a minute apart against the same
-- file were both pending, so neither chained — and whichever pair of runners
-- claimed them next raced for the file. An older PENDING row is now a blocker
-- too, judged on its predicted footprint; a BUILDING one is still judged on the
-- leases it actually holds, so a long spec never blocks work it will not touch.
create or replace function public.dev_cmd_autochain(p_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  r record; v_all bigint[]; v_paths text[]; v_blockers bigint[];
  v_reason text; v_tpl text; v_tpl_f text; v_max int; v_fact boolean; v_pend boolean;
  n int := 0; v_capped int := 0; v_out jsonb := '[]'::jsonb;
begin
  select coalesce((value->'chain'->>'max_blockers')::int, 3),
         coalesce((value->'chain'->>'require_lease')::boolean, true),
         coalesce((value->'chain'->>'include_pending')::boolean, true)
    into v_max, v_fact, v_pend
    from dev_runner_config where key = 'worker_pool';
  v_max  := greatest(coalesce(v_max, 3), 1);
  v_fact := coalesce(v_fact, true);
  v_pend := coalesce(v_pend, true);

  select value#>>'{}' into v_tpl   from ui_copy where key = 'dev_queue.chain_chip';
  select value#>>'{}' into v_tpl_f from ui_copy where key = 'dev_queue.chain_chip_files';
  v_tpl   := coalesce(v_tpl,   'Queued after {ids} — same files');
  v_tpl_f := coalesce(v_tpl_f, 'Queued after {ids} — both write {files}');

  for r in
    select c.id, c.predicted_files, coalesce(c.chain_auto,'{}') as chain_auto
      from dev_commands c
     where c.status = 'pending'
       and (p_id is null or c.id = p_id)
     order by c.id
  loop
    -- FIRST-ORDER ONLY: `o` is judged on its own footprint and never on what
    -- o itself is queued behind, so a chain can never grow down the queue.
    select coalesce(array_agg(o.id order by o.id), '{}')
      into v_all
      from dev_commands o
     where o.id <> r.id
       and coalesce(array_length(r.predicted_files,1),0) > 0
       and (
             (o.status = 'building'
              and coalesce(array_length(
                    dev_paths_conflict(
                      case when v_fact then dev_cmd_leased_footprint(o.id)
                           else dev_cmd_footprint(o.id) end,
                      r.predicted_files), 1), 0) > 0)
          or (v_pend and o.status = 'pending' and o.id < r.id
              and coalesce(array_length(
                    dev_paths_conflict(dev_cmd_footprint(o.id), r.predicted_files), 1), 0) > 0)
           );

    v_blockers := v_all[1:v_max];
    if coalesce(array_length(v_all,1),0) > v_max then
      v_capped := v_capped + 1;
    end if;

    select coalesce(array_agg(distinct p), '{}')
      into v_paths
      from unnest(coalesce(v_blockers,'{}')) bid,
           unnest(dev_paths_conflict(
                    case when v_fact and (select status from dev_commands where id = bid) = 'building'
                         then dev_cmd_leased_footprint(bid)
                         else dev_cmd_footprint(bid) end,
                    r.predicted_files)) p;

    update dev_commands
       set depends_on = (select coalesce(array_agg(distinct d), '{}')
                           from unnest(coalesce(depends_on,'{}')) d
                          where not (d = any(r.chain_auto)) or d = any(v_blockers))
     where id = r.id;

    if coalesce(array_length(v_blockers,1),0) = 0 then
      update dev_commands set chain_auto = '{}', chain_reason = null
       where id = r.id
         and (chain_reason is not null or coalesce(chain_auto,'{}') <> '{}');
      continue;
    end if;

    v_reason := case
      when coalesce(array_length(v_paths,1),0) > 0 then
        replace(replace(v_tpl_f, '{ids}',
          (select string_agg('#'||b::text, ', ' order by b) from unnest(v_blockers) b)),
          '{files}',
          (select string_agg(regexp_replace(p, '^.*/', ''), ', ' order by p)
             from unnest(v_paths[1:3]) p))
      else
        replace(v_tpl, '{ids}',
          (select string_agg('#'||b::text, ', ' order by b) from unnest(v_blockers) b))
    end;

    update dev_commands
       set depends_on = (select coalesce(array_agg(distinct d), '{}')
                           from unnest(coalesce(depends_on,'{}') || v_blockers) d),
           chain_auto = v_blockers,
           chain_reason = v_reason
     where id = r.id;
    n := n + 1;
    v_out := v_out || jsonb_build_object('id', r.id, 'after', to_jsonb(v_blockers),
                                         'files', to_jsonb(v_paths), 'reason', v_reason);
  end loop;

  return jsonb_build_object('ok', true, 'chained', n, 'capped', v_capped,
                            'max_blockers', v_max, 'require_lease', v_fact,
                            'include_pending', v_pend,
                            'rows', v_out);
end $fn$;

-- dev_chain_watchdog has existed since #327 and was never registered with the
-- dispatcher, so "alert if chaining idles a runner" has never once fired.
-- One row in cron_task is the whole fix; no bare */N schedule (see the 18 Aug
-- connection-exhaustion outage) — the dispatcher paces it.
insert into cron_task(name, ord, mode, base_interval_s, max_interval_s, enabled, dml, note, work_sql)
values ('dev-chain-idle-watchdog', 145, 'poll', 120, 900, true, true,
        'CHANGE #1674 — alerts when same-file chaining leaves a runner idle with work queued.',
        'select public.dev_chain_watchdog()')
  on conflict (name) do update
    set enabled = true,
        work_sql = excluded.work_sql,
        note = excluded.note,
        base_interval_s = coalesce(cron_task.base_interval_s, excluded.base_interval_s);

-- ───────────────────────────────────────────────────────────────────────────
-- 7. THE CARD — the grade, and where the lane's time actually goes
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public._dev_cmd_rows(p_status text, p_search text, p_batch text, p_limit integer, p_slim boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows jsonb; v_tat numeric; v_stale numeric;
  v_models jsonb; v_efforts jsonb;
  t_steps text; t_live text; t_stall text; t_resume text; t_ssteps text; t_shint text;
  t_fready text; t_fauto text; t_wait text; t_whint text; t_spec text;
begin
  -- CHANGE #1092 — an empty string is NOT a search. It used to reach the
  -- filter as '' and match every row through the coalesce branch, which is
  -- both wrong and unindexable.
  p_status := nullif(p_status, '');
  p_search := nullif(p_search, '');
  p_batch  := nullif(p_batch,  '');

  v_tat := _dev_cmd_base_tat();
  -- one config read for the whole page, not four or five per row
  v_models  := _dev_label_map('models');
  v_efforts := _dev_label_map('efforts');
  select coalesce((value->>'eta_stale_s')::numeric, 180) into v_stale
    from dev_runner_config where key='worker_pool';
  v_stale := coalesce(v_stale, 180);
  select value#>>'{}' into t_steps  from ui_copy where key='dev_queue.steps_chip';
  select value#>>'{}' into t_live   from ui_copy where key='dev_queue.live_stale';
  select value#>>'{}' into t_stall  from ui_copy where key='dev_queue.stall_chip';
  select value#>>'{}' into t_resume from ui_copy where key='dev_queue.resume_chip';
  select value#>>'{}' into t_ssteps from ui_copy where key='dev_queue.steps_stale_chip';
  select value#>>'{}' into t_shint  from ui_copy where key='dev_queue.steps_stale_hint';
  t_fready := _c_or('dev_queue.finish_ready_chip', '✅ All conditions met — closing automatically');
  t_fauto  := _c_or('dev_queue.finish_auto_chip',  '🤖 Auto-completed by the harness · {drift} after the last step');
  t_wait   := _c_or('dev_queue.wait_chip',  '⏸ {reason} · waiting {age}');
  t_whint  := _c_or('dev_queue.wait_hint',  'Not a failure — the work is committed and resumes automatically when the blocker clears.');
  t_spec   := _c_or('dev_queue.spec_chip',  'Spec {done}/{total}');

  with pick as (
    -- THE CEILING. One index-ordered walk, p_limit rows, nothing else touched.
    -- CHANGE #1092: the result_summary branch lost its coalesce so all three
    -- OR branches are trigram-indexable and the planner can BitmapOr them.
    -- `NULL ilike '%x%'` is NULL, i.e. not true — the same rows the coalesce
    -- kept, now that an empty search can no longer reach here.
    select dc.id
      from dev_commands dc
     where (p_status is null or dc.status = p_status)
       and (p_batch  is null or dc.batch_label = p_batch)
       and (p_search is null
            or dc.title          ilike '%'||p_search||'%'
            or dc.spec           ilike '%'||p_search||'%'
            or dc.result_summary ilike '%'||p_search||'%')
     order by dc.created_at desc, dc.id desc
     limit greatest(coalesce(p_limit, 120), 1)
  ),
  spec_agg as (
    select si.command_id,
           count(*)::int                                     as total,
           count(*) filter (where si.status = 'open')::int    as open_n
      from dev_command_spec_item si
      join pick p on p.id = si.command_id
     group by si.command_id
  ),
  qa_agg as (
    select qf.command_id,
           count(*) filter (where qf.status = 'open')::int    as open_n
      from qa_findings qf
      join pick p on p.id = qf.command_id
     group by qf.command_id
  ),
  msg_agg as (
    select m.command_id, count(*)::int as n
      from dev_command_messages m
      join pick p on p.id = m.command_id
     group by m.command_id
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id desc), '[]')
    into v_rows
  from (
    select dc.id,
           -- #887: materialised on write. Was a regexp over the whole build_log.
           coalesce(dc.title_display, dc.title) as title,
           dc.status, dc.priority, dc.urgent, dc.depends_on, dc.batch_label,
           dc.route, dc.area,
           _route_label(dc.route) as route_label, _route_tone(dc.route) as route_tone,
           _area_label(dc.area) as area_label,
           (dc.enriched_spec is not null and length(coalesce(dc.enriched_spec,'')) > 0) as has_enriched,
           case when dc.route='fast' and dc.status='completed' then 'Instant · 0 tokens' else '' end as speed_display,
           coalesce(dc.kind,'dev') as kind, coalesce(dc.is_danger,false) as is_danger,
           case when p_slim then left(coalesce(dc.plain_summary,''), 200)
                else coalesce(dc.plain_summary,'') end as plain_summary,
           dc.targets_web, dc.targets_android, dc.targets_ios,
           dc.web_deploy_no, dc.web_deployed_at, dc.android_status, dc.android_artifact_url,
           dc.android_built_at, dc.ios_status,
           dc.android_build_type, dc.debug_requested, dc.debug_status,
           -- #887: the cards view drops every one of these in _dev_card_strip,
           -- so the slim build never reads them off disk in the first place.
           case when p_slim then null::text  else dc.result_summary end as result_summary,
           case when p_slim then null::jsonb else dc.decisions      end as decisions,
           case when p_slim then null::jsonb else dc.screenshots    end as screenshots,
           case when p_slim then null::text  else dc.error_log      end as error_log,
           dc.retry_count,
           dc.cost_input_tokens, dc.cost_output_tokens, dc.cost_inr, dc.claimed_by, dc.heartbeat_at,
           coalesce(dc.model,'') as model, coalesce(dc.effort,'') as effort,
           coalesce(dc.price_mode,'') as price_mode,
           _dev_model_chip_m(v_models, v_efforts, dc.model, dc.effort, dc.price_mode,
                             dc.actual_model, dc.actual_effort) as model_chip,
           coalesce(dc.actual_model,'') as actual_model,
           coalesce(dc.actual_effort,'') as actual_effort,
           _dev_model_label_m(v_models, dc.model)   as model_label,
           _dev_effort_label_m(v_efforts, dc.effort) as effort_label,
           case when (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0)
                then ('₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990')) || ' — API-equivalent (included in your Max plan · ₹0 extra)'
                else '' end as cost_note,
           (dc.cost_input_tokens + dc.cost_output_tokens) as tokens_total,
           _fmt_tokens(dc.cost_input_tokens + dc.cost_output_tokens) as tokens_display,
           '₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990') as cost_display,
           (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0) as has_tokens,
           _ist_age(coalesce(dc.finished_at, dc.started_at, dc.created_at)) as age_display,
           dc.needs_input_question, dc.rolled_back, dc.created_at, dc.started_at, dc.finished_at,
           case when p_slim then null::text else left(dc.build_log, 4000) end as build_log_tail,
           tm.tat_seconds, tm.tat_display, tm.eta_at, tm.elapsed_seconds, tm.elapsed_display,
           tm.remaining_seconds, tm.remaining_display, tm.is_overrun, tm.has_eta, tm.eta_note,
           dc.eta_total_s, dc.eta_left_s,
           case when dc.status in ('completed','failed') then tm.ttt_display else '' end as ttt_display,
           case when p_slim then null::jsonb else coalesce(dc.steps, '[]'::jsonb) end as steps,
           dc.steps_done, dc.steps_total, dc.resume_count,
           -- CHANGE #1674 — the GRADE, on the card. Om could not see whether a
           -- command bought a hostile QA pass it did not need.
           coalesce(dc.size_class,'') as size_class,
           coalesce(dc.qa_scope,'')   as qa_scope,
           coalesce(dc.diff_files, 0) as diff_files,
           coalesce(dc.diff_rows, 0)  as diff_rows,
           coalesce(dc.grade_reason,'') as grade_reason,
           public._dev_grade_chip(dc.size_class, dc.qa_scope,
             case coalesce(dc.qa_scope,'standard') when 'deep' then 3 else 1 end) as grade_chip,
           case coalesce(dc.size_class,'')
                when 'xlarge' then 'warning'
                when 'small'  then 'success'
                else 'info' end as grade_tone,
           coalesce(dc.resume_branch,'') as resume_branch,
           coalesce(dc.release_reason,'') as release_reason,
           case when coalesce(dc.steps_total,0) > 0
                then replace(replace(coalesce(t_steps,'Step {done} of {total}'),
                       '{done}', coalesce(dc.steps_done,0)::text), '{total}', dc.steps_total::text)
                else '' end as steps_chip,
           (dc.status='building' and dc.heartbeat_at is not null
              and dc.heartbeat_at > now() - (v_stale || ' seconds')::interval) as is_live,
           case when dc.status='building'
                 and (dc.heartbeat_at is null
                      or dc.heartbeat_at <= now() - (v_stale || ' seconds')::interval)
                then replace(coalesce(t_live,'Worker offline — no heartbeat for {age}'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.heartbeat_at), 0)))
                else '' end as live_chip,
           -- ── CHANGE #1023 — the AGENT's liveness, not the runner's ──────────
           -- live_chip above says the heartbeat stopped. This says the beat is
           -- fine and the Claude session behind it is not — the exact state
           -- #1016 sat in for 32 minutes with nothing on the card to show it.
           dev_cmd_agent_chip(dc.status, dc.agent_silent_flagged, dc.agent_silent_at, dc.agent_pane_alive) as agent_chip,
           case when dc.status='building' and coalesce(dc.agent_silent_flagged,false)
                then case when dc.agent_pane_alive is false then 'error' else 'warning' end
                else 'neutral' end as agent_tone,
           coalesce(dc.agent_rc_session,'') as agent_rc_session,
           coalesce(dc.session_lost_count,0) as session_lost_count,
           coalesce(dc.started_flags,'') as started_flags,
           case when dc.status='building' and coalesce(dc.token_stall_flagged,false)
                then replace(coalesce(t_stall,'Tokens frozen {age} — build may be stuck'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.token_stall_at), 0)))
                else '' end as stall_chip,
           case when dc.status='building' and coalesce(dc.steps_stale_flagged,false)
                then replace(coalesce(t_ssteps,'Steps not being reported — checklist may be stale ({age})'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.steps_stale_at), 0)))
                else '' end as steps_stale_chip,
           case when dc.status='building' and coalesce(dc.steps_stale_flagged,false)
                then coalesce(t_shint,'') else '' end as steps_stale_hint,
           coalesce(dc.steps_auto_count,0) as steps_auto_count,
           coalesce(dc.steps_nudge_count,0) as steps_nudge_count,
           case when coalesce(dc.resume_count,0) > 0
                then replace(coalesce(t_resume,'Resumed {n}×'), '{n}', dc.resume_count::text)
                else '' end as resume_chip,
           -- ── CHANGE #571: WAITING IS NOT FAILING, and the card says which ──
           coalesce(dc.wait_state,'')  as wait_state,
           coalesce(dc.wait_kind,'')   as wait_kind,
           coalesce(dc.wait_reason,'') as wait_reason,
           case when p_slim then null::jsonb
                else coalesce(dc.wait_blocker,'{}'::jsonb) end as wait_blocker,
           dc.wait_since, coalesce(dc.wait_count,0) as wait_count,
           (dc.wait_state = 'parked') as is_waiting,
           case when dc.wait_state = 'parked'
                then replace(replace(t_wait, '{reason}', coalesce(dc.wait_reason,'')),
                       '{age}', _fmt_dur(coalesce(extract(epoch from now()-dc.wait_since), 0)))
                else '' end as wait_chip,
           case when dc.wait_state = 'parked' then 'warning' else 'neutral' end as wait_tone,
           case when dc.wait_state = 'parked' then t_whint else '' end as wait_hint,
           -- ── CHANGE #571 spec checklist — #887: set-based, was 8 subqueries ──
           coalesce(sa.total, 0)  as spec_total,
           coalesce(sa.open_n, 0) as spec_open,
           case when coalesce(sa.total,0) = 0 then ''
                else replace(replace(t_spec,
                       '{done}', (coalesce(sa.total,0) - coalesce(sa.open_n,0))::text),
                       '{total}', coalesce(sa.total,0)::text) end as spec_chip,
           case when dc.status = 'building' and coalesce(sa.open_n,0) > 0 then 'warning'
                when coalesce(sa.total,0) > 0 and coalesce(sa.open_n,0) = 0 then 'success'
                else 'neutral' end as spec_tone,
           -- ── CHANGE #369: the finish gate, on the card ────────────────────
           case when dc.status='completed' and coalesce(dc.auto_finished,false)
                then replace(t_fauto, '{drift}',
                       _fmt_dur(greatest(coalesce(extract(epoch from dc.finished_at - dc.steps_snap_at), 0), 0)))
                when dc.status='building' and dc.finish_ready_at is not null then t_fready
                else '' end as finish_chip,
           case when dc.status='completed' and dc.steps_snap_at is not null
                then round(extract(epoch from dc.finished_at - dc.steps_snap_at))::int
                else null end as finish_drift_s,
           case when dc.status='completed' and dc.steps_snap_tokens is not null
                then greatest((dc.cost_input_tokens + dc.cost_output_tokens) - dc.steps_snap_tokens, 0)
                else null end as finish_tokens_after,
           case when dc.status='completed' and coalesce(dc.auto_finished,false) then 'success'
                when dc.status='building' and dc.finish_ready_at is not null then 'info'
                else 'neutral' end as finish_tone,
           coalesce(dc.auto_finished,false) as auto_finished,
           coalesce(dc.auto_finish_source,'') as auto_finish_source,
           case when p_slim then null::jsonb
                else coalesce(dc.finish_blockers,'[]'::jsonb) end as finish_blockers,
           dc.finish_ready_at,
           dc.qa_status, dc.qa_required, dc.preview_status, dc.journey_pass_count,
           coalesce(qa.open_n, 0) as qa_open_findings,
           case when not dc.qa_required or dc.qa_status='waived' then ''
                when dc.qa_status='pending' then ''
                when dc.qa_status='running' then '🔍 QA testing'
                when dc.qa_status='passed' then '✅ QA passed'
                when dc.qa_status='failed' then '❌ QA: '||coalesce(qa.open_n,0)||' finding(s)'
                else '' end as qa_chip,
           case when dc.qa_status='waived' then 'neutral'
                when dc.qa_status='running' then 'info'
                when dc.qa_status='passed' then 'success'
                when dc.qa_status='failed' then 'error' else 'neutral' end as qa_tone,
           case coalesce(dc.preview_status,'')
                when 'deployed' then '🔎 On preview'
                when 'promoted' then '🚀 Promoted' else '' end as preview_chip,
           case coalesce(dc.preview_status,'')
                when 'deployed' then 'info' when 'promoted' then 'success' else 'neutral' end as preview_tone,
           _dev_chain_chip(dc.status, dc.chain_reason) as chain_chip,
           'info'::text as chain_tone,
           case when p_slim then null::text[] else coalesce(dc.predicted_files,'{}') end as predicted_files,
           case when dc.journey_pass_count > 0
                then '🧭 '||dc.journey_pass_count||' journey'||case when dc.journey_pass_count=1 then '' else 's' end||' green'
                else '' end as journey_chip,
           coalesce(ma.n, 0) as msg_count
      from pick pk
      join dev_commands dc on dc.id = pk.id
      left join spec_agg sa on sa.command_id = dc.id
      left join qa_agg   qa on qa.command_id = dc.id
      left join msg_agg  ma on ma.command_id = dc.id,
      lateral _dev_cmd_timing(dc.started_at, dc.finished_at, dc.status, v_tat,
                              dc.eta_total_s, dc.eta_left_s, dc.heartbeat_at, dc.eta_note) tm
  ) t;

  return coalesce(v_rows, '[]'::jsonb);
end
$function$;

create or replace function public._dev_card_keys()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select array[
    'id','title','status','kind','area','area_label','batch_label','priority',
    'urgent','is_danger','effort','route','route_label','route_tone',
    'claimed_by','model','model_chip','model_label','effort_label','retry_count',
    'created_at','started_at','finished_at','heartbeat_at','eta_at',
    'age_display','elapsed_display','remaining_display','tat_display',
    'ttt_display','speed_display','tokens_display','cost_display','cost_note',
    'has_eta','has_tokens','is_live','is_waiting','is_overrun','msg_count',
    'steps_done','steps_total','steps_chip','steps_stale_chip','steps_stale_hint',
    'spec_chip','spec_tone','spec_open','spec_total',
    'qa_chip','qa_tone','qa_status','qa_required','qa_open_findings',
    'journey_chip','preview_chip','preview_tone','preview_status',
    'chain_chip','chain_tone','finish_chip','finish_tone',
    'wait_chip','wait_tone','wait_kind','wait_reason','wait_hint','wait_state',
    'live_chip','stall_chip','resume_chip','debug_status','debug_requested',
    'size_class','qa_scope','diff_files','diff_rows','grade_chip','grade_tone','grade_reason',
    'auto_finished','auto_finish_source','rolled_back',
    -- CHANGE #1023 — agent liveness, next to the worker liveness it is not
    'agent_chip','agent_tone','agent_rc_session','session_lost_count','started_flags',
    'web_deploy_no','android_status','ios_status',
    'targets_web','targets_android','targets_ios'
  ]::text[];
$function$;

create or replace function public.deploy_lane_status(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l deploy_lock%rowtype; cfg jsonb := _mq_cfg();
        v_wait int; v_target int; v_busy boolean;
        v_hold_avg numeric; v_wait_avg numeric; v_n int;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Deploy lane is visible to super-admins only.');
  end if;
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
      'held_label', case when v_busy then extract(epoch from now() - l.acquired_at)::int || 's' else '—' end,
      'over_target', case when v_busy then extract(epoch from now() - l.acquired_at)::int > v_target else false end,
      'tone', case when not v_busy then 'success'
                   when extract(epoch from now() - l.acquired_at)::int > v_target then 'error'
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
                 'detail', agent || ' · ' || branch,
                 'value_label', 'waiting ' || extract(epoch from now() - pushed_at)::int || 's',
                 'tone', 'info') order by pushed_at), '[]'::jsonb)
               from deploy_queue where status = 'waiting')),
      'window_label', (select case
          when coalesce((cfg->>'window_s')::int, 0) <= 0 then 'Batch window off — every branch deploys alone.'
          when v_wait = 0 then 'Batch window ' || (cfg->>'window_s') || 's · nothing waiting.'
          when v_wait >= greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1)
            then 'Batch window full — ' || v_wait || ' branch(es) ship together.'
          else 'Batch window open — ' || v_wait || ' of ' ||
               greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1) ||
               ' branch(es), up to ' || (cfg->>'window_s') || 's.' end),
    'batch', (select jsonb_build_object(
                 'id', b.id, 'status', b.status,
                 'label', 'Batch ' || b.id || ' · ' || b.entries || ' branch(es)',
                 'value_label', b.status,
                 'tone', case b.status when 'deployed' then 'success' when 'failed' then 'error' else 'info' end,
                 'change_no', b.change_no, 'evicted', b.evicted,
                 -- CHANGE #1674 — per-phase timings, so "held 891s" says WHICH half.
                 'phases', public.merge_batch_phases(b.id),
                 'slowest_label', coalesce((
                    select (e->>'phase') || ' · ' || (e->>'seconds') || 's'
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     order by (e->>'seconds')::int desc limit 1), '—'),
                 'locked_s', coalesce((
                    select sum((e->>'seconds')::int)
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     where (e->>'locked')::boolean), 0))
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

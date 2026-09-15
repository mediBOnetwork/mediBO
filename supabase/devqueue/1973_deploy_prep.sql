-- CMD #1973 — THE DEPLOY LOCK STOPS PAYING FOR THE BUILD (control plane only).
--
-- This file is NOT replayed by the deploy lane (migration_replay.sh only runs
-- supabase/migrations/ against production). It is applied by hand with:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/devqueue/1973_deploy_prep.sql
-- It is idempotent; re-running it is a no-op.
--
-- MEASURED on CHANGE #1328: under the lock — merge 2 s, protected suite 6 min,
-- migrate 8 s, flutter clean + build + upload 9 min, verify 3.5 min = 21 min of
-- exclusive hold per ship, while #1849 and #1947 sat in the register for 22 and
-- 20 minutes waiting for a lane that was compiling Dart. Nothing about a rebase,
-- a test run or a build needs the lane: the tree they run on is fixed the moment
-- the branch is merged onto the live base.
--
-- So direct_deploy.sh now does its whole PREP with the lock free — fetch, rebase,
-- protected suite, flutter build web — and only joins the register when that is
-- green. Under the lock it does the four things that genuinely serialise:
-- migrate, upload, verify, promote. The number has to be knowable before the
-- lock for the build to stamp it (CHANGE #657 bakes it into main.dart.js), which
-- is what deploy_direct_prenumber() below is for — the same trade
-- merge_batch_prenumber() made for the batch lane in #1674: burning a number on
-- a failed prep costs nothing, holding the lane across a nine-minute build cost
-- every other runner nine minutes.

begin;

-- 1 ── what a direct deploy now records about itself ─────────────────────────
alter table deploy_direct add column if not exists prep_started_at timestamptz;
alter table deploy_direct add column if not exists prep_s            int;
alter table deploy_direct add column if not exists lock_at           timestamptz;
alter table deploy_direct add column if not exists lock_hold_s       int;
alter table deploy_direct add column if not exists bundle_path       text;
alter table deploy_direct add column if not exists rebuilt_under_lock boolean not null default false;
alter table deploy_direct add column if not exists prep_attempts     int not null default 0;

comment on column deploy_direct.prep_s is
  'CMD #1973 — seconds of rebase+test+build done with the deploy lock FREE.';
comment on column deploy_direct.lock_hold_s is
  'CMD #1973 — seconds the deploy lock was actually held. The number this command exists to shrink.';
comment on column deploy_direct.rebuilt_under_lock is
  'CMD #1973 — true when the live base moved between prep and the lock, so tests and build had to be re-run inside the lock.';

-- 2 ── phase vocabulary, said once ───────────────────────────────────────────
create or replace function public._deploy_direct_phase(p_status text)
returns jsonb language sql immutable as $fn$
  select case p_status
    when 'starting'      then jsonb_build_object('where','prep','word','starting')
    when 'prepping'      then jsonb_build_object('where','prep','word','rebasing onto the live base')
    when 'prep_testing'  then jsonb_build_object('where','prep','word','running the protected suite')
    when 'prep_building' then jsonb_build_object('where','prep','word','building the web bundle')
    when 'prepped'       then jsonb_build_object('where','prep','word','prep green — joining the register')
    when 'waiting_lock'  then jsonb_build_object('where','queue','word','waiting for the deploy lock')
    when 'locked'        then jsonb_build_object('where','lock','word','lock taken — checking the live base')
    when 'merging'       then jsonb_build_object('where','lock','word','the live base moved — rebasing')
    when 'testing'       then jsonb_build_object('where','lock','word','re-running the protected suite')
    when 'building'      then jsonb_build_object('where','lock','word','re-building the web bundle')
    when 'migrating'     then jsonb_build_object('where','lock','word','replaying migrations on live')
    when 'uploading'     then jsonb_build_object('where','lock','word','uploading the bundle')
    when 'verifying'     then jsonb_build_object('where','lock','word','verifying live')
    when 'deployed'      then jsonb_build_object('where','done','word','live')
    when 'failed'        then jsonb_build_object('where','done','word','failed')
    else jsonb_build_object('where','lock','word', p_status)
  end
$fn$;

-- 2b ── seconds the lane has actually been held, said in ONE place ──────────
create or replace function public._deploy_direct_hold_s(d deploy_direct)
returns int language sql stable as $fn$
  select coalesce(d.lock_hold_s,
                  case when d.lock_at is not null
                       then extract(epoch from (coalesce(d.finished_at, now()) - d.lock_at))::int
                       else 0 end)
$fn$;

-- 3 ── the line the wait door prints and the card draws ──────────────────────
create or replace function public.deploy_direct_line(d deploy_direct)
returns text language sql stable as $fn$
  select case d.status
    when 'deployed' then format('CHANGE #%s is live (commit %s, %s) — complete with p_deploy_no %s.%s',
                                d.change_no, left(coalesce(d.commit_sha,'?'),8),
                                _fmt_dur(extract(epoch from (coalesce(d.finished_at, now()) - d.started_at))),
                                d.change_no,
                                case when d.lock_hold_s is not null
                                     then format(' Lock held %s of that; prep %s ran with the lane free.',
                                                 _fmt_dur(d.lock_hold_s), _fmt_dur(coalesce(d.prep_s,0)))
                                     else '' end)
    when 'failed'   then format('Direct deploy FAILED — %s. Fix it on your branch and run devcmd.sh deploy_direct again.',
                                coalesce(d.note, 'no reason recorded'))
    when 'waiting_lock' then format('Waiting for the deploy lock — %s (%s so far). Prep is already green (%s), so the lock only has to migrate, upload and verify.',
                                coalesce(d.note,'held by another deploy'),
                                _fmt_dur(extract(epoch from (now() - coalesce(d.phase_at, d.started_at)))),
                                _fmt_dur(coalesce(d.prep_s,0)))
    else format('%s — %s%s (%s).',
                case _deploy_direct_phase(d.status)->>'where'
                  when 'prep' then 'Preparing with the deploy lock FREE'
                  when 'lock' then 'Under the deploy lock'
                  else 'Direct deploy' end,
                _deploy_direct_phase(d.status)->>'word',
                case when d.change_no is not null then ' · CHANGE #' || d.change_no else '' end,
                case when _deploy_direct_phase(d.status)->>'where' = 'lock' and d.lock_at is not null
                     then 'lock held ' || _fmt_dur(extract(epoch from (now() - d.lock_at)))
                     else _fmt_dur(extract(epoch from (now() - d.started_at))) || ' so far' end)
  end
$fn$;

-- 4 ── the number, claimed while the lane is FREE ────────────────────────────
-- Same trade as merge_batch_prenumber() (#1674). The build has to stamp the
-- number into version.json AND bake it into main.dart.js (#657), so it must be
-- known before the build — and the build is exactly what we are taking off the
-- lock. p_renew re-claims when the live base moved under us between prep and
-- the lock: somebody else published a number in between, so ours would go out
-- backwards. A burned number is a gap in deploy_registry, never a reuse.
create or replace function public.deploy_direct_prenumber(
  p_command_id bigint, p_agent text, p_title text,
  p_branch text default null, p_commit text default null,
  p_renew boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare d deploy_direct%rowtype; v_no int; v_live int;
begin
  perform _dev_guard();
  select * into d from deploy_direct
   where command_id is not distinct from p_command_id and status not in ('deployed','failed')
   order by id desc limit 1;
  if d.id is null then
    return jsonb_build_object('ok', false, 'error','no_open_direct_deploy',
      'instruction','deploy_direct_report(..., ''starting'', ...) first — the number hangs off that row.');
  end if;

  select greatest(coalesce((select max(change_no) from deploy_registry), 0),
                  coalesce((select change_no from app_version_state where id = 1), 0))
    into v_live;

  if d.change_no is not null and not p_renew then
    return jsonb_build_object('ok', true, 'change_no', d.change_no, 'already', true,
      'instruction', format('CHANGE #%s was already claimed for this deploy — build with it.', d.change_no));
  end if;

  v_no := v_live + 1;
  insert into deploy_registry(change_no, title, agent, branch, commit_sha, status)
  values (v_no, coalesce(p_title, 'direct deploy #' || p_command_id), p_agent, p_branch, p_commit, 'claimed')
  on conflict (change_no) do nothing;

  if p_renew and d.change_no is not null and d.change_no <> v_no then
    update deploy_registry set status = 'superseded'
     where change_no = d.change_no and status = 'claimed';
  end if;

  update deploy_direct set change_no = v_no, commit_sha = coalesce(p_commit, commit_sha)
   where id = d.id;

  return jsonb_build_object('ok', true, 'change_no', v_no, 'already', false, 'renewed', p_renew,
    'instruction', format('Stamp version.json with %s and BUILD now — the deploy lock is free. Take it only for migrate + upload + verify.', v_no));
end $fn$;

-- 5 ── the report, which now knows where the time went ───────────────────────
create or replace function public.deploy_direct_report(
  p_command_id bigint, p_agent text, p_status text, p_note text default null,
  p_change_no integer default null, p_commit text default null, p_branch text default null,
  p_title text default null, p_base text default null, p_pid integer default null,
  p_prep_s integer default null, p_bundle_path text default null,
  p_rebuilt boolean default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare d deploy_direct%rowtype; v_id bigint; v_terminal boolean; v_where text;
begin
  perform _dev_guard();
  v_terminal := p_status in ('deployed','failed');
  v_where    := _deploy_direct_phase(p_status)->>'where';
  if p_status = 'starting' then
    update deploy_direct set status = 'failed', finished_at = now(),
           note = coalesce(note,'') || ' [superseded by a new attempt]'
     where command_id is not distinct from p_command_id and status not in ('deployed','failed');
    insert into deploy_direct(command_id, agent, title, branch, status, note, pid, base_sha, commit_sha)
    values (p_command_id, p_agent, p_title, p_branch, 'starting', p_note, p_pid, p_base, p_commit)
    returning id into v_id;
  else
    select id into v_id from deploy_direct
     where command_id is not distinct from p_command_id and status not in ('deployed','failed')
     order by id desc limit 1;
    if v_id is null then
      insert into deploy_direct(command_id, agent, title, branch, status, note, pid, base_sha, commit_sha, change_no)
      values (p_command_id, p_agent, p_title, p_branch, p_status, p_note, p_pid, p_base, p_commit, p_change_no)
      returning id into v_id;
    end if;
  end if;
  update deploy_direct
     set status      = p_status,
         note        = coalesce(p_note, note),
         change_no   = coalesce(p_change_no, change_no),
         commit_sha  = coalesce(p_commit, commit_sha),
         branch      = coalesce(p_branch, branch),
         title       = coalesce(p_title, title),
         base_sha    = coalesce(p_base, base_sha),
         pid         = coalesce(p_pid, pid),
         bundle_path = coalesce(p_bundle_path, bundle_path),
         rebuilt_under_lock = coalesce(p_rebuilt, rebuilt_under_lock),
         -- CMD #1973 — the two clocks. prep_started_at on the first prep phase,
         -- prep_s when prep hands over, lock_at the first time a phase is one
         -- that genuinely needs the lane, lock_hold_s when it lets go.
         prep_started_at = case when v_where = 'prep' then coalesce(prep_started_at, now()) else prep_started_at end,
         prep_attempts   = case when p_status = 'prepping' then prep_attempts + 1 else prep_attempts end,
         prep_s      = coalesce(p_prep_s, prep_s),
         -- the lane clock. It banks on release (a mid-run 'waiting_lock' means
         -- we let the lock go and rejoined the tail) and closes on the verdict.
         lock_hold_s = case
             when lock_at is null then lock_hold_s
             when p_status = 'waiting_lock' or v_terminal
               then coalesce(lock_hold_s,0) + extract(epoch from (now() - lock_at))::int
             else lock_hold_s end,
         -- a lock RELEASED mid-run (the base moved and the rebase conflicted,
         -- so we let go and rejoined the tail) banks what it held and starts
         -- the next hold from zero.
         lock_at     = case when p_status = 'waiting_lock' then null
                            when v_where = 'lock' then coalesce(lock_at, now()) else lock_at end,
         phase_at    = now(),
         finished_at = case when v_terminal then now() else finished_at end,
         log         = log || jsonb_build_object('at', now(), 'status', p_status, 'note', p_note, 'change_no', p_change_no)
   where id = v_id
   returning * into d;
  if p_status = 'deployed' and d.change_no is not null and p_command_id is not null then
    update dev_commands
       set web_deploy_no   = d.change_no,
           web_deployed_at = now()
     where id = p_command_id;
    update deploy_registry
       set deployed_at = now(), status = 'deployed', hold_s = coalesce(d.lock_hold_s, hold_s),
           commit_sha = coalesce(d.commit_sha, commit_sha)
     where change_no = d.change_no;
  end if;
  return jsonb_build_object('ok', true, 'id', d.id, 'status', d.status, 'change_no', d.change_no,
    'prep_s', d.prep_s, 'lock_hold_s', d.lock_hold_s,
    'line', deploy_direct_line(d));
end $fn$;

-- 6 ── one row of the card, with the split said in words ─────────────────────
create or replace function public.deploy_direct_recent(p_limit integer default 8)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'command_id', d.command_id, 'agent', d.agent,
           'label', case when d.change_no is not null then 'CHANGE #' || d.change_no else 'direct deploy ' || d.id end
                    || case when d.command_id is not null then ' · #' || d.command_id else '' end,
           'title', d.title, 'branch', d.branch, 'status', d.status,
           'phase_label', _deploy_direct_phase(d.status)->>'word',
           'phase_where', _deploy_direct_phase(d.status)->>'where',
           'tone', case d.status when 'deployed' then 'success' when 'failed' then 'danger'
                                 when 'waiting_lock' then 'warning'
                                 when 'prepping' then 'neutral' when 'prep_testing' then 'neutral'
                                 when 'prep_building' then 'neutral' when 'prepped' then 'neutral'
                                 else 'info' end,
           'line', deploy_direct_line(d),
           -- the two numbers this command exists for, as strings, already judged
           'prep_label', case when coalesce(d.prep_s,0) > 0
                              then 'prep ' || _fmt_dur(d.prep_s) || ' · lock free' else '' end,
           'hold_label', case when _deploy_direct_hold_s(d) > 0
                              then 'lock ' || _fmt_dur(_deploy_direct_hold_s(d)) else '' end,
           'hold_tone', case
                when _deploy_direct_hold_s(d) = 0   then 'neutral'
                when _deploy_direct_hold_s(d) <= 300 then 'success'
                when _deploy_direct_hold_s(d) <= 600 then 'warning'
                else 'danger' end,
           'rebuilt_label', case when d.rebuilt_under_lock
                                 then 'the live base moved — retested under the lock' else '' end,
           'duration_label', _fmt_dur(extract(epoch from (coalesce(d.finished_at, now()) - d.started_at))),
           'started_at', d.started_at, 'finished_at', d.finished_at) order by d.id desc), '[]'::jsonb)
    from (select * from deploy_direct order by id desc limit greatest(coalesce(p_limit,8),1)) d
$fn$;

-- 7 ── the panel the Deploy lane card draws (heading, sentence, rows, empty) ──
create or replace function public.deploy_direct_panel(p_limit integer default 6)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb; v_avg_hold numeric; v_avg_prep numeric; v_n int;
begin
  v_rows := deploy_direct_recent(greatest(coalesce(p_limit,6),1));
  select count(*), avg(lock_hold_s), avg(prep_s) into v_n, v_avg_hold, v_avg_prep
    from deploy_direct
   where status = 'deployed' and lock_hold_s is not null and finished_at > now() - interval '7 days';
  return jsonb_build_object(
    'has', jsonb_array_length(v_rows) > 0,
    'heading', 'Direct deploys',
    'subtitle', case when coalesce(v_n,0) = 0
      then 'Each command deploys its own branch. Rebase, protected suite and flutter build run with the lock FREE; the lock only migrates, uploads and verifies.'
      else format('%s deploy(s) in 7 days · lock held %s on average · %s of prep ran with the lane free.',
                  v_n, _fmt_dur(coalesce(v_avg_hold,0)), _fmt_dur(coalesce(v_avg_prep,0))) end,
    'target_label', 'target: lock under 5 min',
    'rows', v_rows,
    'empty', 'No direct deploy has run yet.',
    'footnote', 'CMD #1973 — prep off the lock. Before it, one ship held the lane 21 min: 6 min of tests and 9 min of build were inside it.');
end $fn$;


-- 8 ── the lane card now carries the direct-deploy panel ─────────────────────
-- deploy_lane_status() has returned 'direct' since #1859, but as a bare array
-- of deploy_direct_recent() rows with no heading, no sentence and no judgement,
-- so DeployLaneSection never rendered it and the 21-minute holds were invisible
-- in the app. It returns the panel now, and the widget draws it.
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
        v_lock jsonb;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Deploy lane is visible to super-admins only.');
  end if;
  select * into l from deploy_lock where id = 1;
  v_lock   := public.deploy_lock_banner();
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
    -- CMD #1961 — a batch renewal line is only true while the merge lane is
    -- ON. With the lane off the last batch is from 7 Sep, and printing its
    -- renewals is the same stale sentence this command removes.
    if public.merge_lane_enabled() and lb.id is not null and coalesce(lb.renewals, 0) > 0 then
      v_ren_label := format('last batch %s renewed %s, held %ss',
                       lb.id, case lb.renewals when 1 then 'once' else lb.renewals || ' times' end,
                       coalesce(lb.hold_s, 0));
      v_ren_chip := lb.renewals || '×';
      v_ren_tone := case lb.status when 'deployed' then 'success' else 'neutral' end;
    else
      v_ren_label := public._c_or('dev_queue.lane_no_renewals', 'no lane renewals recorded yet');
      v_ren_chip := ''; v_ren_tone := 'neutral';
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    -- CMD #1961 — Recently completed replaces the batches block. deploy_batch
    -- stopped moving on 7 Sep when #1859 turned the merge lane off, so the card
    -- reported a six-day-old failure as the state of the lane.
    'completed', public.deploy_recent_completed(5),
    'title', 'Deploy lane',
    'subtitle', public._deploy_lane_subtitle(),
    'mode_label', case when not merge_lane_enabled() then 'DIRECT (deploy_lock)' else 'MERGE QUEUE' end,
    -- CMD #1973 — the panel, not a bare array: the card drew nothing from
    -- this key because there were no strings on it to draw.
    'direct', public.deploy_direct_panel(6),
    'mode_tone',  case when not merge_lane_enabled() then 'info' else 'success' end,
    'lane', jsonb_build_object(
      'busy', v_busy,
      'label', case when v_busy then 'Lane held by ' || coalesce(l.holder,'?') else 'Lane free' end,
      'detail', case when v_busy
        then coalesce(l.title,'a deploy') || ' · held ' ||
             extract(epoch from now() - l.acquired_at)::int || 's'
        else 'Nothing deploying right now.' end,
      'held_label', case when v_busy then extract(epoch from now() - l.acquired_at)::int || 's' else '—' end,
      'over_target', case when v_busy then extract(epoch from now() - l.acquired_at)::int > v_target else false end,
      'tone', case when not v_busy then 'success'
                   when extract(epoch from now() - l.acquired_at)::int > v_target then 'error'
                   else 'info' end,
      'renewals', case when v_busy then coalesce(l.renewals, 0) else 0 end,
      'expires_in_s', case when v_busy then v_exp_in end,
      'renewal_label', v_ren_label,
      'renewal_chip', v_ren_chip,
      'renewal_tone', v_ren_tone,
      -- CMD #1866 — WHOSE deploy holds the lock, said once by the backend.
      -- CMD #1961 — and the same holder chip the Dev Queue card prints.
      'lock_label', v_lock->>'label',
      'lock_tone',  v_lock->>'tone',
      'holder_chip', v_lock->>'holder_chip',
      'holder_chip_tone', v_lock->>'holder_chip_tone'),
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
    -- CMD #1866 — the wait gate's own decisions: kind, holder, verdict.
    'gate', case when to_regproc('public.dev_wait_gate_recent') is not null
                  then public.dev_wait_gate_recent(8)
                  else jsonb_build_object('has', false) end,
    'config', cfg);
end $function$

;

commit;

-- 9 ── the overload trap. `create or replace` on a function with THREE new
-- defaulted parameters does not replace anything — Postgres keys a function on
-- its argument types, so the 10-arg deploy_direct_report stayed and every
-- PostgREST call by name became ambiguous between the two. Drop the old arity
-- explicitly (the new one is a strict superset: every existing 10-arg call
-- still resolves) and restate the grants, which a fresh signature does not
-- inherit.
drop function if exists public.deploy_direct_report(bigint,text,text,text,integer,text,text,text,text,integer);

grant execute on function public.deploy_direct_report(bigint,text,text,text,integer,text,text,text,text,integer,integer,text,boolean) to anon, authenticated, service_role;
grant execute on function public.deploy_direct_prenumber(bigint,text,text,text,text,boolean) to anon, authenticated, service_role;
grant execute on function public.deploy_direct_panel(integer) to anon, authenticated, service_role;
grant execute on function public._deploy_direct_phase(text) to anon, authenticated, service_role;
grant execute on function public._deploy_direct_hold_s(deploy_direct) to anon, authenticated, service_role;

-- 10 ── two sentences that were true only for a row that HAD a prep ──────────
-- Rows written before this command have prep_s = 0 and no lock_at, and the
-- first draft told them "prep is already green (0s)" and called a first build a
-- re-build. The word depends on the row, so it is chosen from the row.
create or replace function public.deploy_direct_line(d deploy_direct)
returns text language sql stable as $fn$
  select case d.status
    when 'deployed' then format('CHANGE #%s is live (commit %s, %s) — complete with p_deploy_no %s.%s',
                                d.change_no, left(coalesce(d.commit_sha,'?'),8),
                                _fmt_dur(extract(epoch from (coalesce(d.finished_at, now()) - d.started_at))),
                                d.change_no,
                                case when coalesce(d.prep_s,0) > 0
                                     then format(' Lock held %s of that; %s of prep ran with the lane free.',
                                                 _fmt_dur(_deploy_direct_hold_s(d)), _fmt_dur(d.prep_s))
                                     else '' end)
    when 'failed'   then format('Direct deploy FAILED — %s. Fix it on your branch and run devcmd.sh deploy_direct again.',
                                coalesce(d.note, 'no reason recorded'))
    when 'waiting_lock' then format('Waiting for the deploy lock — %s (%s so far).%s',
                                coalesce(d.note,'held by another deploy'),
                                _fmt_dur(extract(epoch from (now() - coalesce(d.phase_at, d.started_at)))),
                                case when coalesce(d.prep_s,0) > 0
                                     then format(' Prep is already green (%s), so the lock only has to migrate, upload and verify.',
                                                 _fmt_dur(d.prep_s))
                                     else '' end)
    else format('%s — %s%s (%s).',
                case _deploy_direct_phase(d.status)->>'where'
                  when 'prep' then 'Preparing with the deploy lock FREE'
                  when 'lock' then 'Under the deploy lock'
                  else 'Direct deploy' end,
                case when d.status in ('testing','building') and not d.rebuilt_under_lock
                     then replace(_deploy_direct_phase(d.status)->>'word', 're-', '')
                     else _deploy_direct_phase(d.status)->>'word' end,
                case when d.change_no is not null then ' · CHANGE #' || d.change_no else '' end,
                case when d.lock_at is not null
                     then 'lock held ' || _fmt_dur(extract(epoch from (now() - d.lock_at)))
                     else _fmt_dur(extract(epoch from (now() - d.started_at))) || ' so far' end)
  end
$fn$;

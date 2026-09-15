-- replay-target: control-plane
-- CMD #1991 — WHERE THE 25 MINUTES WENT, PER DEPLOY.
--
-- deploy_direct already knew how long a deploy took end to end and how long it
-- held the lock. It did not know how that time was SPENT, so "the build is the
-- problem" was an assertion read off a journal on the VM, and the only way to
-- tell a 4-minute incremental build from a 16-minute clean one was to ssh in.
--
-- Three seconds columns, written by direct_deploy.sh from deploy.sh's own
-- phase marks, plus the panel the Deploy lane card has been able to draw since
-- #1973 but has never been sent (deploy_lane_status ships deploy_direct_recent,
-- which returned a bare ARRAY — an unrecognised shape, so the app drew nothing).
--
-- Idempotent: every statement is add-if-missing or create-or-replace.

alter table public.deploy_direct
  add column if not exists test_s      integer,
  add column if not exists build_s     integer,
  add column if not exists upload_s    integer,
  add column if not exists clean_build boolean;

comment on column public.deploy_direct.test_s      is 'seconds in flutter test test/protected/ on the merged tree (CMD #1991)';
comment on column public.deploy_direct.build_s     is 'seconds in flutter build web --release (CMD #1991)';
comment on column public.deploy_direct.upload_s    is 'seconds in the wrangler Pages upload (CMD #1991)';
comment on column public.deploy_direct.clean_build is 'true = flutter clean ran; false = the Dart build cache was kept (CMD #1991)';

-- ── the phase sentence, built once and rendered verbatim ────────────────────
create or replace function public._deploy_direct_phases_label(d public.deploy_direct)
returns text language sql stable as $fn$
  select case
    when d.test_s is null and d.build_s is null and d.upload_s is null then ''
    else trim(both ' · ' from concat_ws(' · ',
      case when d.test_s   is not null then 'test '   || public._fmt_dur(d.test_s)   end,
      case when d.build_s  is not null then 'build '  || public._fmt_dur(d.build_s)  end,
      case when d.upload_s is not null then 'upload ' || public._fmt_dur(d.upload_s) end,
      case when d.clean_build is false then 'cache kept'
           when d.clean_build is true  then 'clean build' end))
  end
$fn$;

-- Green while the build stays inside the 10-minute goal this command was
-- filed for; warning the moment it does not. The THRESHOLD is data, not Dart.
create or replace function public._deploy_direct_phases_tone(d public.deploy_direct)
returns text language sql stable as $fn$
  select case
    when d.build_s is null then 'neutral'
    when coalesce(d.build_s,0) + coalesce(d.upload_s,0)
         <= coalesce((select (value->'deploy_target'->>'build_upload_s')::int
                        from public.dev_runner_config where key='worker_pool'), 600)
      then 'success'
    else 'warning'
  end
$fn$;

-- ── the rows ────────────────────────────────────────────────────────────────
-- deploy_direct_recent stays an ARRAY. It is not only the card's: devcmd.sh's
-- deploy_direct launcher reads `[.[]? | select(.command_id==$i)]` off it under
-- `set -e`, so handing it an object makes jq fail, makes the command
-- substitution fail, and kills the launcher before it starts the deploy —
-- silently, with no log and no row. The new keys are added, nothing is moved.
create or replace function public.deploy_direct_recent(p_limit integer default 8)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'command_id', d.command_id, 'agent', d.agent,
           'label', case when d.change_no is not null then 'CHANGE #' || d.change_no
                         else 'direct deploy ' || d.id end
                    || case when d.command_id is not null then ' · #' || d.command_id else '' end,
           'title', d.title, 'branch', d.branch, 'status', d.status,
           'tone', case d.status when 'deployed' then 'success' when 'failed' then 'danger'
                                 when 'waiting_lock' then 'warning' else 'info' end,
           'line', deploy_direct_line(d),
           'phases_label', _deploy_direct_phases_label(d),
           'phases_tone',  _deploy_direct_phases_tone(d),
           'hold_label', case when d.lock_hold_s is not null
                              then 'lock held ' || _fmt_dur(d.lock_hold_s) else '' end,
           'hold_tone', case when coalesce(d.lock_hold_s,0) > 900 then 'warning' else 'neutral' end,
           'prep_label', '',
           'rebuilt_label', case when d.rebuilt_under_lock then 'rebuilt clean' else '' end,
           'duration_label', _fmt_dur(extract(epoch from (coalesce(d.finished_at, now()) - d.started_at))),
           'started_at', d.started_at, 'finished_at', d.finished_at) order by d.id desc), '[]'::jsonb)
    from (select * from deploy_direct order by id desc limit greatest(coalesce(p_limit,8),1)) d
$fn$;

-- ── the panel the card already knows how to draw ────────────────────────────
-- The card has been able to render heading/subtitle/rows/footnote since #1973,
-- but deploy_lane_status shipped the bare array on `direct` — an unrecognised
-- shape, which the widget deliberately draws as nothing. So this is the object
-- it wants, and deploy_lane_status is pointed at it below.
create or replace function public.deploy_direct_panel(p_limit integer default 8)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'has', exists (select 1 from deploy_direct),
    'heading', 'Direct deploys',
    'target_label', 'target 10 min',
    'subtitle', 'Each command deploys its own branch under the deploy lock. '
                || 'The phase line says where that deploy''s time went.',
    'empty', 'No direct deploy has run yet.',
    'footnote', 'build = flutter build web --release · upload = wrangler Pages upload · '
                || '"cache kept" means the Dart build cache survived because the toolchain, '
                || 'pubspec.lock, android/ and web/ were all unchanged.',
    'rows', public.deploy_direct_recent(p_limit))
$fn$;

-- ── the report: the same function, plus the seconds it is now told ──────────
drop function if exists public.deploy_direct_report(bigint,text,text,text,integer,text,text,text,text,integer);

create or replace function public.deploy_direct_report(
  p_command_id bigint,
  p_agent text,
  p_status text,
  p_note text default null,
  p_change_no integer default null,
  p_commit text default null,
  p_branch text default null,
  p_title text default null,
  p_base text default null,
  p_pid integer default null,
  p_test_s integer default null,
  p_build_s integer default null,
  p_upload_s integer default null,
  p_clean_build boolean default null,
  p_rebuilt boolean default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare d deploy_direct%rowtype; v_id bigint; v_terminal boolean; v_where text; v_live deploy_direct%rowtype;
begin
  perform _dev_guard();
  v_terminal := p_status in ('deployed','failed');
  v_where    := _deploy_direct_phase(p_status)->>'where';

  -- CMD #1975 (kept) — a command that is already live never deploys again.
  if p_status = 'starting' and p_command_id is not null then
    v_live := _deploy_direct_live_row(p_command_id);
    if v_live.id is not null then
      return jsonb_build_object('ok', false, 'refused', 'already_live',
        'command_id', p_command_id, 'change_no', v_live.change_no,
        'id', v_live.id, 'status', 'deployed',
        'line', (deploy_direct_live(p_command_id))->>'line',
        'next_step', format('Complete #%s with p_deploy_no %s — no deploy, no lock.',
                            p_command_id, v_live.change_no));
    end if;
  end if;

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
         -- CMD #1991 — the phase seconds. Every report carries the ones known
         -- so far, so a deploy that dies mid-phase still leaves what it spent.
         test_s      = coalesce(p_test_s, test_s),
         build_s     = coalesce(p_build_s, build_s),
         upload_s    = coalesce(p_upload_s, upload_s),
         clean_build = coalesce(p_clean_build, clean_build),
         rebuilt_under_lock = coalesce(p_rebuilt, rebuilt_under_lock),
         -- one lock hold per deploy: it opens on the first phase that needs the
         -- lane and closes when the row is terminal. No prep clock any more.
         lock_at     = case when v_where = 'lock' then coalesce(lock_at, now()) else lock_at end,
         lock_hold_s = case
             when lock_at is null then lock_hold_s
             when v_terminal then extract(epoch from (now() - lock_at))::int
             else lock_hold_s end,
         phase_at    = now(),
         finished_at = case when v_terminal then now() else finished_at end,
         log         = log || jsonb_build_object('at', now(), 'status', p_status, 'note', p_note,
                                                 'change_no', p_change_no,
                                                 'test_s', p_test_s, 'build_s', p_build_s,
                                                 'upload_s', p_upload_s, 'clean_build', p_clean_build)
   where id = v_id
   returning * into d;
  -- the row's own record of its change number: dev_cmd_complete coalesces on
  -- it and dev_cmd_finish_state reads it FIRST.
  if p_status = 'deployed' and d.change_no is not null and p_command_id is not null then
    update dev_commands
       set web_deploy_no   = d.change_no,
           web_deployed_at = now()
     where id = p_command_id;
    update deploy_registry
       set deployed_at = now(), status = 'deployed',
           commit_sha = coalesce(d.commit_sha, commit_sha)
     where change_no = d.change_no;
  end if;
  return jsonb_build_object('ok', true, 'id', d.id, 'status', d.status, 'change_no', d.change_no,
    'lock_hold_s', d.lock_hold_s,
    'phases_label', _deploy_direct_phases_label(d),
    'completed', (select status = 'completed' from dev_commands where id = p_command_id),
    'line', deploy_direct_line(d));
end $fn$;

grant execute on function public.deploy_direct_report(bigint,text,text,text,integer,text,text,text,text,integer,integer,integer,integer,boolean,boolean) to service_role;
grant execute on function public.deploy_direct_recent(integer) to service_role;
grant execute on function public.deploy_direct_panel(integer) to service_role;
grant execute on function public._deploy_direct_phases_label(public.deploy_direct) to service_role;
grant execute on function public._deploy_direct_phases_tone(public.deploy_direct) to service_role;

-- ── deploy_lane_status ships the PANEL on `direct` ────────────────────────
-- Regenerated verbatim from the live definition with exactly one token
-- changed: deploy_direct_recent(8) -> deploy_direct_panel(8).
create or replace function public.deploy_lane_status(p_limit integer DEFAULT 12)
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
    'direct', public.deploy_direct_panel(8),
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
end $function$;

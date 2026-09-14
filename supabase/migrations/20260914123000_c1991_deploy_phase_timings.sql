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

-- ── the panel the card already knows how to draw ────────────────────────────
create or replace function public.deploy_direct_recent(p_limit integer default 8)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  with rows as (
    select * from deploy_direct order by id desc limit greatest(coalesce(p_limit,8),1)
  )
  select jsonb_build_object(
    'has', exists (select 1 from rows),
    'heading', 'Direct deploys',
    'target_label', 'target 10 min',
    'subtitle', 'Each command deploys its own branch under the deploy lock. '
                || 'The phase line says where that deploy''s time went.',
    'empty', 'No direct deploy has run yet.',
    'footnote', 'build = flutter build web --release · upload = wrangler Pages upload · '
                || '"cache kept" means the Dart build cache survived because the toolchain, '
                || 'pubspec.lock, android/ and web/ were all unchanged.',
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
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
         'started_at', d.started_at, 'finished_at', d.finished_at) order by d.id desc)
       from rows d), '[]'::jsonb))
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
grant execute on function public._deploy_direct_phases_label(public.deploy_direct) to service_role;
grant execute on function public._deploy_direct_phases_tone(public.deploy_direct) to service_role;

-- CMD #1852 (e) — A SESSION THAT EXPIRES PURGES ITSELF, AND A PURGE THAT
-- STOPPED HALF-WAY CARRIES ON.
--
-- #573's sweep only ENDED a forgotten session. Ending it stops the stamping;
-- it leaves every row the run created sitting in the real tables for ever,
-- which is precisely the residue this command exists to remove. And a purge
-- that died mid-way — the browser tab closed, the statement timed out, the
-- deploy restarted the pool — stayed at `purge_started_at set, purged_at
-- null` with nothing on earth scheduled to look at it again.
--
-- The sweep now does three things and reports each: end what expired,
-- purge what it just ended, and RESUME whatever is stuck in the middle of a
-- purge. The journal's own `undone_at` cursor makes resuming free.
--
-- Bounded on purpose: at most `sessions_per_tick` sessions and a small budget
-- each, on a 1 GB instance, on a cron that comes back every 15 minutes.

begin;

alter table public.test_mode_config
  add column if not exists autopurge_enabled boolean not null default true;
alter table public.test_mode_config
  add column if not exists autopurge_budget_ms int not null default 8000;
alter table public.test_mode_config
  add column if not exists autopurge_sessions_per_tick int not null default 3;
alter table public.test_mode_config
  add column if not exists purge_stuck_minutes int not null default 30;

comment on column public.test_mode_config.purge_stuck_minutes is
  'CMD #1852 — a purge still unfinished this many minutes after it started is '
  'rendered as STUCK rather than as quietly in progress.';

create or replace function public.test_session_expire_sweep()
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $fn$
declare n int; r record; c public.test_mode_config%rowtype;
        v_purged int := 0; v_resumed int := 0; v_left int := 0; v_stuck int := 0;
        v_res jsonb;
begin
  select * into c from public.test_mode_config where id = 1;

  update public.test_sessions
     set status='ended', ended_at=coalesce(ended_at, expires_at), auto_expired=true
   where status='live' and now() >= expires_at;
  get diagnostics n = row_count;

  if coalesce(c.autopurge_enabled, true) then
    -- Two populations, one loop, oldest first:
    --   * a session that auto-expired and was never purged — it purges itself;
    --   * a session already mid-purge — it RESUMES, from the journal cursor.
    for r in
      select s.id, (s.purge_started_at is not null) as resuming
        from public.test_sessions s
       where s.status <> 'purged'
         and s.ended_at is not null
         and s.purged_at is null
         and (s.auto_expired or s.purge_started_at is not null)
       order by s.ended_at asc
       limit greatest(1, coalesce(c.autopurge_sessions_per_tick, 3))
    loop
      begin
        v_res := public.test_session_purge(r.id, greatest(1000, coalesce(c.autopurge_budget_ms, 8000)));
        if coalesce((v_res->>'done')::boolean, false) then
          if r.resuming then v_resumed := v_resumed + 1; else v_purged := v_purged + 1; end if;
        else
          v_left := v_left + 1;      -- picked up again on the next tick
        end if;
      exception when others then
        -- One session that will not purge never stops the sweep looking at the
        -- next one; the row keeps purge_started_at and stays visible as stuck.
        v_left := v_left + 1;
      end;
    end loop;
  end if;

  select count(*) into v_stuck from public.test_sessions
   where purged_at is null and purge_started_at is not null
     and purge_started_at < now() - make_interval(mins => greatest(1, coalesce(c.purge_stuck_minutes, 30)));

  return jsonb_build_object('ok',true,'expired',n,
    'purged',v_purged,'resumed',v_resumed,'unfinished',v_left,'stuck',v_stuck);
end $fn$;

-- ---------------------------------------------------------------------------
-- STUCK IS VISIBLE, NOT SILENT
-- ---------------------------------------------------------------------------
create or replace function public.test_session_purge_health()
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $fn$
declare c public.test_mode_config%rowtype; v_stuck int; v_running int; v_names text;
begin
  select * into c from public.test_mode_config where id = 1;
  select count(*) filter (where purge_started_at < now() - make_interval(mins => greatest(1, coalesce(c.purge_stuck_minutes,30)))),
         count(*)
    into v_stuck, v_running
    from public.test_sessions
   where purged_at is null and purge_started_at is not null;
  if coalesce(v_running,0) = 0 then
    return jsonb_build_object('has', false);
  end if;
  select string_agg('#'||id::text, ', ' order by id) into v_names
    from public.test_sessions where purged_at is null and purge_started_at is not null;
  return jsonb_build_object(
    'has', true,
    'stuck', v_stuck,
    'running', v_running,
    'tone', case when v_stuck > 0 then 'danger' else 'warning' end,
    'label', case when v_stuck > 0
      then public.uic('test_session.purge_stuck','A purge has been running too long and is not finishing:')
      else public.uic('test_session.purge_running','A purge is still running:') end || ' ' || coalesce(v_names,''));
end $fn$;

revoke all on function public.test_session_purge_health() from public, anon;
grant execute on function public.test_session_purge_health() to authenticated, service_role;

-- The list says, per row, WHERE the purge got to and whether its proof holds —
-- both in the backend's own words, so the screen picks no sentence and no
-- colour of its own.
create or replace function public.test_session_list(p_limit int default 20)
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_rows jsonb; c public.test_mode_config%rowtype;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  select * into c from public.test_mode_config where id = 1;
  select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'id', s.id,
      'label', s.label,
      'status', case
        when s.status='live' and s.ended_at is null and now() < s.expires_at then 'live'
        when s.status='live' then 'expired'
        when s.status <> 'purged' and s.purge_started_at is not null then 'purging'
        else s.status end,
      'status_label', case
        when s.status='live' and s.ended_at is null and now() < s.expires_at
                               then public.uic('test_session.live','LIVE')
        when s.status='purged' then public.uic('test_session.purged_chip','Purged')
        when s.status='live'   then public.uic('test_session.expired_chip','Auto-expired')
        when s.purge_started_at is not null and s.purge_started_at <
             now() - make_interval(mins => greatest(1, coalesce(c.purge_stuck_minutes,30)))
                               then public.uic('test_session.purge_stuck_chip','Purge stuck')
        when s.purge_started_at is not null
                               then public.uic('test_session.purging_chip','Purging…')
        when s.auto_expired    then public.uic('test_session.expired_chip','Auto-expired')
        else public.uic('test_session.ended_chip','Ended') end,
      'status_tone', case
        when s.status='live' and s.ended_at is null and now() < s.expires_at then 'danger'
        when s.status='purged' then 'success'
        when s.status <> 'purged' and s.purge_started_at is not null and s.purge_started_at <
             now() - make_interval(mins => greatest(1, coalesce(c.purge_stuck_minutes,30))) then 'danger'
        when s.status <> 'purged' and s.purge_started_at is not null then 'warning'
        else 'neutral' end,
      'origin', s.origin,
      'origin_label', case when s.origin='automated'
        then public.uic('test_session.origin_automated','Automated')
        else public.uic('test_session.origin_human','Started by a person') end,
      'origin_tone', case when s.origin='automated' then 'info' else 'warning' end,
      'banner_label', case when s.origin='automated'
        then public.uic('test_session.no_banner','No banner — bot scope only')
        else public.uic('test_session.banner_shown','Banner shown platform-wide') end,
      'started_label', public.uic('test_session.started_label','Started') || ' ' ||
                       to_char(s.started_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
      'by', coalesce(s.started_by_label,''),
      'residue', case when s.status = 'purged'
                      then coalesce(s.proof->'residue', '{}'::jsonb)
                      else public.test_session_residue(s.id) end,
      'proof', coalesce(s.proof, '{}'::jsonb),
      -- CMD #1852 — the verdict and its colour are the BACKEND's, and the
      -- fingerprint sentence rides with them: the screen used to choose
      -- between proof_clean and proof_dirty, and between success and danger,
      -- in Dart.
      'proof_label', case
        when s.proof ? 'clean' and (s.proof->>'clean')::boolean
             then public.uic('test_session.proof_clean','Clean — zero residue, business data identical')
        when s.proof ? 'clean'
             then public.uic('test_session.proof_dirty','Residue left — purge again')
        else '' end,
      'proof_tone', case when s.proof ? 'clean' and (s.proof->>'clean')::boolean
                         then 'success' when s.proof ? 'clean' then 'danger' else 'neutral' end,
      'fingerprint_label', coalesce(s.proof #>> '{fingerprint,line}', ''),
      'fingerprint_tone',  coalesce(s.proof #>> '{fingerprint,tone}', 'neutral'),
      'reversed_label', case when s.proof ? 'undo'
        then public.uic('test_session.reversed_label','Writes reversed') || ' ' ||
             coalesce(s.proof #>> '{undo,reversed}', '0')
        else '' end,
      'can_purge', (s.status <> 'purged'),
      'can_end', (s.status = 'live' and s.ended_at is null and now() < s.expires_at)
    ) as x
    from public.test_sessions s
    order by s.id desc
    limit least(20, greatest(1, coalesce(p_limit,20)))
  ) q;
  return jsonb_build_object('ok', true,
    'title', public.uic('test_session.list_title','Sessions'),
    'empty', public.uic('test_session.empty',''),
    'health', public.test_session_purge_health(),
    'rows', v_rows);
end $fn$;

insert into public.ui_copy (key, value) values
  ('test_session.purging_chip',    to_jsonb('Purging…'::text)),
  ('test_session.purge_stuck_chip',to_jsonb('Purge stuck'::text)),
  ('test_session.purge_stuck',     to_jsonb('A purge has been running too long and is not finishing:'::text)),
  ('test_session.purge_running',   to_jsonb('A purge is still running:'::text)),
  ('test_session.reversed_label',  to_jsonb('Writes reversed'::text))
on conflict (key) do update set value = excluded.value;

-- The cron row already exists from #573; make sure its note matches what the
-- sweep now actually does.
update public.cron_task
   set note = 'CHANGE #573 / CMD #1852 - ends a forgotten test session at its expiry, then purges it and resumes any purge that stopped half-way.'
 where name = 'test_session_expire';

commit;

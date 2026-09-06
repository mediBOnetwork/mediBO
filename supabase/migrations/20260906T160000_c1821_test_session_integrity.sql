-- replay-target: production
--
-- CHANGE #1821 — TEST MODE TURNS ITSELF BACK ON. The whole loop, closed.
--
-- WHAT OM SAW (6 Sep, live): he starts test mode, stops it, the app confirms
-- OFF. Five minutes later the red TEST MODE strip is back, labelled
-- "autotest smoke", "Auto-ends 07 Sep 01:33" — and it is on his CUSTOMER
-- login too.
--
-- WHAT IT ACTUALLY WAS (traced, not guessed):
--   merge_worker.sh runs `autotest.sh --smoke --target prod` after EVERY
--   deploy batch (#635, the promote gate). That calls test_run_start(), which
--   calls test_session_start('autotest smoke', null). #573's start() has ONE
--   shape: scope='global', expiry = test_mode_config.session_hours = 12h. So a
--   three-minute bot run put the ENTIRE PLATFORM into incognito for twelve
--   hours, once per deploy. Production's own history proves the cadence —
--   sessions 91 (07:33), 92 (10:46), 93 (10:59), 95 (12:15), 96 (13:33 IST).
--   Session 96 was still live when this change was written, and its banner
--   payload read exactly what Om reported.
--
--   #634 was already aware of half of this: test_run_scope_to_bot() narrows
--   the bot's session to scope='actors' so a real customer's real order is
--   never STAMPED. Two holes it left, and they are the whole bug:
--     (a) test_session_banner() never looked at scope. A bot session raised
--         the platform-wide banner for every anon, customer, supplier and
--         rider on medibo.in.
--     (b) the narrowing happens AFTER the insert, and only when a matching
--         auth.users row exists for every qa_test_identities email. Between
--         the two statements — and for ever, if the identities are unmapped —
--         the session is GLOBAL against production.
--
-- THE RULE THIS CHANGE ADDS: a test session has an ORIGIN, and the origin is
-- observed, never declared. A caller with a real auth.uid() that is not
-- service_role is a HUMAN; everything else is AUTOMATED. Human sessions keep
-- #573 exactly as Om designed it (global, banner everywhere, 12h). Automated
-- sessions can no longer be global, can no longer raise a banner on anybody's
-- screen, live for an hour instead of twelve, cannot start while Om has a
-- session of his own open, and are ended and purged by the sweep instead of
-- lying around ended-but-dirty for ever.
--
-- Idempotent throughout: the merge worker replays this file on live once, and
-- a resumed worker may re-apply it whole.

-- ── 0. Nothing here applies to a database that has no test sessions ───────
do $guard$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                  where n.nspname='public' and c.relname='test_sessions') then
    raise notice '[c1821] no test_sessions here — nothing to do.';
    return;
  end if;
end $guard$;

-- ── 1. THE ORIGIN COLUMN ──────────────────────────────────────────────────
-- 'human'     — an admin tapped Start. Global, bannered, 12h. #573 unchanged.
-- 'automated' — anything else. Scoped, silent, short-lived, self-purging.
do $$
begin
  if to_regclass('public.test_sessions') is null then return; end if;

  alter table public.test_sessions add column if not exists origin text not null default 'human';
  alter table public.test_sessions add column if not exists started_by_kind text;
  alter table public.test_sessions add column if not exists ended_by uuid;
  alter table public.test_sessions add column if not exists ended_kind text;

  -- Backfill: a session with no started_by was opened by the runner or by cron.
  update public.test_sessions set origin = 'automated'
   where origin = 'human' and started_by is null;

  if not exists (select 1 from pg_constraint where conname = 'test_sessions_origin_chk') then
    alter table public.test_sessions
      add constraint test_sessions_origin_chk check (origin in ('human','automated')) not valid;
  end if;
end $$;

comment on column public.test_sessions.origin is
  'CHANGE #1821 — human = an admin tapped Start (global, bannered). automated '
  '= a bot/cron/runner opened it (scoped to the bot, never bannered, short '
  'TTL, swept and purged). Observed from auth.uid()+role at start(), never '
  'declared by the caller.';

create index if not exists test_sessions_origin_live_idx
  on public.test_sessions (origin, status) where status = 'live';

-- ── 2. ONE LIVE SESSION AT A TIME, ENFORCED IN THE DATABASE ───────────────
-- #573 shipped this index; it is re-asserted here because spec item 2 asks for
-- the guarantee to be enforced by the DB and not by the callers, and because a
-- clone created from a dump before #573 may not carry it.
do $$
begin
  if to_regclass('public.test_sessions') is null then return; end if;
  -- Any stragglers first, or the index build fails on legacy data.
  update public.test_sessions
     set status = 'ended', ended_at = coalesce(ended_at, expires_at, now()), auto_expired = true
   where status = 'live'
     and id <> (select max(id) from public.test_sessions where status = 'live');
  if not exists (select 1 from pg_class where relname = 'test_sessions_one_live') then
    create unique index test_sessions_one_live
      on public.test_sessions ((true)) where status = 'live';
  end if;
end $$;

-- ── 3. THE KNOBS ──────────────────────────────────────────────────────────
alter table public.test_mode_config
  add column if not exists automated_session_hours numeric not null default 1;
alter table public.test_mode_config
  add column if not exists automated_orphan_min int not null default 20;
alter table public.test_mode_config
  add column if not exists automated_purge_after_min int not null default 5;

comment on column public.test_mode_config.automated_session_hours is
  'CHANGE #1821 — hard ceiling on an AUTOMATED session. A 3-minute smoke used '
  'to hold a 12-hour global session; this is the backstop under the sweep.';

-- ── 4. WHO IS ASKING ──────────────────────────────────────────────────────
-- The one place that decides human vs machine, and the order of the tests is
-- the whole of its correctness.
--
-- It cannot be keyed on current_user: every function on this path is SECURITY
-- DEFINER, so inside them current_user is already the owner. It cannot be
-- keyed on session_user alone either: PostgREST connects as `authenticator`
-- for a customer, for Om and for the service role alike. So the JWT is asked
-- FIRST — it is the only thing that distinguishes those three — and
-- session_user is the fallback for the callers that carry no request at all
-- (pg_cron, the #305 dispatcher, psql, the runner's own migrations).
create or replace function public._test_caller_origin()
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_claims jsonb; v_role text; v_uid uuid;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null; end;
  v_role := coalesce(v_claims ->> 'role',
                     nullif(current_setting('request.jwt.claim.role', true), ''));
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;

  -- 1. The runner, the merge worker, an edge function: a machine, always.
  if coalesce(v_role,'') = 'service_role' then return 'automated'; end if;
  -- 2. A request carrying a user JWT is a person at a keyboard. This is the
  --    test that makes a human session possible at all through PostgREST.
  if v_uid is not null and coalesce(v_role,'') <> '' then return 'human'; end if;
  -- 3. No request context: cron, psql, a migration. Nobody tapped anything.
  if session_user in ('postgres','supabase_admin','service_role') then return 'automated'; end if;
  -- 4. A session that puts the whole platform into incognito must never be
  --    openable by nobody.
  if v_uid is null then return 'automated'; end if;
  return 'human';
exception when others then
  return 'automated';
end $fn$;

create or replace function public._test_caller_is_backend()
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select public._test_caller_origin() = 'automated';
$fn$;

revoke all on function public._test_caller_is_backend() from public, anon, authenticated;
revoke all on function public._test_caller_origin()     from public, anon, authenticated;

-- ── 5. THE STAMPING RULE FOR AN AUTOMATED SESSION ─────────────────────────
-- scope 'automated' stamps a row when EITHER the writer is a backend caller
-- (the heartbeat canary, the chaos probe, the safety net — rows nobody real
-- created) OR the writer is one of the run's registered test logins. It never
-- stamps a plain authenticated user. That is the difference between #634's
-- 'actors' and this: 'actors' stamped NOTHING when qa_test_identities had no
-- auth.users match, which silently turned bot rows into real production rows.
create or replace function public._test_session_stamps(p_session bigint, p_scope text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_uid uuid;
begin
  if p_session is null then return false; end if;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;

  -- The escape hatch wins over every scope.
  if v_uid is not null and exists (
       select 1 from public.test_session_exempt e where e.user_id = v_uid) then
    return false;
  end if;

  if p_scope = 'global' then return true; end if;

  if p_scope = 'automated' and public._test_caller_is_backend() then return true; end if;

  return v_uid is not null and exists (
    select 1 from public.test_session_actor a
     where a.session_id = p_session and a.user_id = v_uid);
end $fn$;

revoke all on function public._test_session_stamps(bigint, text) from public, anon, authenticated;

-- ── 6. THE AMBIENT LOOKUP LEARNS THE ORIGIN ───────────────────────────────
create or replace function public._test_session_ambient()
returns bigint language plpgsql volatile security definer set search_path to 'public' as $fn$
declare v_id bigint; v_scope text;
begin
  select id, scope into v_id, v_scope
    from public.test_sessions
   where status = 'live' and ended_at is null and now() < expires_at
   limit 1;
  if v_id is null then return null; end if;
  if not public._test_session_stamps(v_id, v_scope) then return null; end if;
  return v_id;
end $fn$;

-- The generic INSERT trigger. Kept inline and tg_op-guarded exactly as #573
-- left it — this sits on 57 tables, several of them hot — with the scope test
-- replaced by the shared rule above.
create or replace function public._synthetic_inherit()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_key text; v_hit boolean; v_sess bigint; v_j jsonb; v_parent bigint;
        v_scope text;
begin
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;

  if tg_op = 'INSERT' then
    select id, scope into v_sess, v_scope from public.test_sessions
     where status = 'live' and ended_at is null and now() < expires_at limit 1;
    if v_sess is not null and not public._test_session_stamps(v_sess, v_scope) then
      v_sess := null;
    end if;
  end if;
  if v_sess is not null then
    new.is_synthetic := true;
    v_j := to_jsonb(new);
    if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
      new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_sess));
    end if;
    return new;
  end if;

  if coalesce(new.is_synthetic,false) then return new; end if;

  -- A legacy explicit run context (part 1) still stamps.
  if coalesce(current_setting('medibo.synthetic', true),'') = 'on' then
    new.is_synthetic := true;
    return new;
  end if;

  for r in select * from public.synthetic_inherit_rule
            where child_table = tg_table_name loop
    v_key := to_jsonb(new) ->> r.child_col;
    continue when v_key is null;
    execute format(
      'select p.is_synthetic, p.test_session_id from public.%I p where p.%I = $1::%s limit 1',
      r.parent_table, r.parent_col, r.parent_type)
      into v_hit, v_parent using v_key;
    if coalesce(v_hit,false) then
      new.is_synthetic := true;
      if v_parent is not null then
        v_j := to_jsonb(new);
        if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
          new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_parent));
        end if;
      end if;
      return new;
    end if;
  end loop;
  return new;
end $fn$;

-- ── 7. START — THE ORIGIN IS OBSERVED, NOT DECLARED ───────────────────────
-- Signature unchanged on purpose: every existing caller (test_mode_action,
-- test_run_start, the heartbeat canary, the chaos probe, the safety net)
-- keeps working and gets the new behaviour without being edited.
create or replace function public.test_session_start(p_label text default null, p_hours numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint; v_hours numeric; v_uid uuid; v_label text;
        v_origin text; v_scope text; v_cap numeric;
        v_live_id bigint; v_live_origin text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not (select enabled from public.test_mode_config where id=1) then
    return jsonb_build_object('ok',false,'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_origin := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  if v_origin = 'automated' then v_uid := null; end if;

  -- A session left open past its expiry is closed BEFORE anything else, so
  -- neither the liveness read below nor the partial unique index can be
  -- confused by a row that is only nominally live (spec item 5).
  update public.test_sessions
     set status='ended', ended_at=coalesce(ended_at, expires_at), auto_expired=true
   where status='live' and (ended_at is not null or now() >= expires_at);

  select id, origin into v_live_id, v_live_origin
    from public.test_sessions
   where status='live' and ended_at is null and now() < expires_at
   limit 1;

  if v_live_id is not null then
    -- OFF MEANS OFF, and it also means MINE MEANS MINE. A bot must never join,
    -- extend or inherit the session Om is standing inside: test_run_finish()
    -- would then END and PURGE his run when the bot finished. It is refused,
    -- and run.js treats the refusal as "could not run", never as a pass.
    if v_origin = 'automated' and v_live_origin = 'human' then
      return jsonb_build_object('ok',false,'error','human_session_live',
        'session_id', v_live_id,
        'message', public.uic('test_session.human_live',
          'A person has test mode on. Automated runs do not join it.'));
    end if;
    -- A human tapping Start while a bot session is open takes the platform
    -- over: the bot's session is closed and his own is opened.
    if v_origin = 'human' and v_live_origin = 'automated' then
      update public.test_sessions
         set status='ended', ended_at=coalesce(ended_at, now()), ended_kind='superseded'
       where id = v_live_id;
      v_live_id := null;
    else
      return jsonb_build_object('ok',true,'already',true,'session_id',v_live_id,
        'origin', v_live_origin,
        'message', public.uic('test_session.already_on','Test mode is already on.'));
    end if;
  end if;

  if v_origin = 'automated' then
    v_scope := 'automated';
    v_cap := coalesce((select automated_session_hours from public.test_mode_config where id=1), 1);
    v_hours := least(coalesce(nullif(p_hours,0), v_cap), v_cap);
  else
    v_scope := 'global';
    v_hours := coalesce(nullif(p_hours,0),
                        (select session_hours from public.test_mode_config where id=1), 12);
  end if;

  v_label := coalesce(nullif(btrim(p_label),''),
                      to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' run');

  insert into public.test_sessions (label, scope, origin, started_by, started_by_label,
                                    started_by_kind, expires_at, before_fp)
  values (v_label, v_scope, v_origin, v_uid,
          case when v_origin = 'automated' then 'automated'
               else coalesce((select email from auth.users where id = v_uid), 'admin') end,
          v_origin,
          now() + make_interval(mins => greatest(1, (v_hours*60)::int)),
          public.test_fingerprint())
  returning id into v_id;

  return jsonb_build_object('ok',true,'session_id',v_id,'origin',v_origin,'scope',v_scope,
    'banner', (v_origin = 'human'),
    'message', case when v_origin = 'human'
      then public.uic('test_session.started','Test mode is ON. Everything you do now is a test.')
      else public.uic('test_session.started_automated','Automated test run open — no banner, bot scope only.') end);
end $fn$;

-- ── 8. END — and it records WHO ───────────────────────────────────────────
create or replace function public.test_session_end(p_session bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint; v_uid uuid; v_kind text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_id := coalesce(p_session, public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  v_kind := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         ended_by = coalesce(ended_by, v_uid),
         ended_kind = coalesce(ended_kind, v_kind)
   where id = v_id;
  return jsonb_build_object('ok',true,'session_id',v_id,
    'residue', public.test_session_residue(v_id),
    'message', public.uic('test_session.ended','Test mode is OFF.'));
end $fn$;

-- ── 9. THE BANNER — an automated run is INVISIBLE ─────────────────────────
-- This one predicate is the fix for "the banner appears on a CUSTOMER
-- account". #634 already kept the bot's WRITES away from real users; nothing
-- kept its BANNER away from them, because this function never looked at what
-- kind of session it had found.
create or replace function public.test_session_banner()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare s public.test_sessions%rowtype; c public.test_mode_config%rowtype;
begin
  select * into c from public.test_mode_config where id = 1;
  select * into s from public.test_sessions
   where status='live' and ended_at is null and now() < expires_at
     and origin = 'human'
   limit 1;
  if not found then
    return jsonb_build_object('on', false, 'poll_ms', coalesce(c.banner_poll_ms, 20000));
  end if;
  return jsonb_build_object(
    'on', true,
    'poll_ms', coalesce(c.banner_poll_ms, 20000),
    'session_id', s.id,
    'text',  public.uic('test_session.banner','TEST MODE — nothing here is real'),
    'label', s.label,
    'hint',  public.uic('test_session.banner_hint',''),
    'ends_label', public.uic('test_session.expiry_label','Auto-ends') || ' ' ||
                  to_char(s.expires_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
    'badge', public.uic('test_mode.badge','TEST'),
    'tone', 'danger');
end $fn$;

-- ── 10. THE BOT'S OWN SCOPE ───────────────────────────────────────────────
-- #634's narrowing is kept, but it can only ever NARROW now: an automated
-- session is already scope='automated' at insert time, so the window between
-- the insert and this call — and the case where no qa_test_identities email
-- maps to an auth.users row — are both closed.
create or replace function public.test_run_scope_to_bot(p_session bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_n int := 0; v_origin text;
begin
  if p_session is null then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;
  select origin into v_origin from public.test_sessions where id = p_session;

  insert into public.test_session_actor (session_id, user_id, label)
  select p_session, u.id, t.role
    from public.qa_test_identities t
    join auth.users u on lower(u.email) = lower(t.identity)
   where coalesce(t.identity,'') <> ''
  on conflict (session_id, user_id) do nothing;
  get diagnostics v_n = row_count;

  -- Never widen. A human session Om already had open is left exactly as he set
  -- it; an automated one stays 'automated' whether or not an identity mapped.
  if v_origin = 'automated' then
    update public.test_sessions set scope = 'automated'
     where id = p_session and scope <> 'automated';
  end if;

  return jsonb_build_object('ok', v_origin = 'automated' or v_n > 0, 'actors', v_n,
                            'origin', v_origin,
                            'scope', (select scope from public.test_sessions where id = p_session));
end $$;
revoke all on function public.test_run_scope_to_bot(bigint) from public, anon;
grant execute on function public.test_run_scope_to_bot(bigint) to service_role;

-- ── 11. A RUN THAT CANNOT OPEN A SESSION DOES NOT RUN ─────────────────────
-- Before this, a refused session left v_sid null and the run went ahead
-- UNSTAMPED against production — every row the bot created became a real row.
-- Now the run refuses itself, and run.js exits 3 ("could not run"), which the
-- merge worker already records as not_run rather than as a pass.
create or replace function public.test_run_start(
  p_kind        text default 'preview',
  p_target_url  text default '',
  p_commit      text default null,
  p_deploy_no   int  default null,
  p_command_id  bigint default null,
  p_triggered_by text default 'vm',
  p_note        text default null,
  p_open_session boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_key uuid; v_sess jsonb; v_sid bigint; v_scope jsonb := '{}'::jsonb;
begin
  perform public._dev_guard();
  if p_open_session then
    v_sess := public.test_session_start('autotest ' || coalesce(p_kind,'preview'), null);
    if coalesce((v_sess->>'ok')::boolean, false) = false then
      return jsonb_build_object('ok', false,
        'error', coalesce(v_sess->>'error','session_refused'),
        'session', v_sess,
        'message', coalesce(v_sess->>'message',''));
    end if;
    v_sid  := nullif(v_sess->>'session_id','')::bigint;
    -- A session this call did NOT open belongs to somebody else's run.
    if v_sid is not null and coalesce((v_sess->>'already')::boolean, false) then
      return jsonb_build_object('ok', false, 'error', 'session_busy',
        'session', v_sess,
        'message', public.uic('test_session.busy','Another test session is already open.'));
    end if;
    if v_sid is not null then
      v_scope := public.test_run_scope_to_bot(v_sid);
    end if;
  end if;

  insert into public.test_runs (kind, target_url, git_commit, deploy_no, command_id,
                                test_session_id, triggered_by, note)
  values (coalesce(nullif(p_kind,''),'preview'), coalesce(p_target_url,''), p_commit,
          p_deploy_no, p_command_id, v_sid, coalesce(nullif(p_triggered_by,''),'vm'), p_note)
  returning id, run_key into v_id, v_key;

  return jsonb_build_object('ok', true, 'run_id', v_id, 'run_key', v_key,
                            'test_session_id', v_sid,
                            'scope', v_scope,
                            'session', coalesce(v_sess, '{}'::jsonb));
end $$;
grant execute on function public.test_run_start(text,text,text,int,bigint,text,text,boolean)
  to authenticated, service_role;

-- ── 12. THE REAPER — the purge gap, closed ────────────────────────────────
-- #573's sweep only ended sessions at their expiry. Production carried five
-- ended-but-never-purged automated sessions from a single day, and an
-- automated session whose run was killed by `timeout 300` sat LIVE for the
-- rest of its twelve hours. Three passes now, each bounded, so the #305
-- dispatcher's dblink budget is never the thing that stops it:
--   (a) expire  — status live past expires_at.
--   (b) orphan  — an AUTOMATED live session whose run has ended, or which has
--                 been open longer than automated_orphan_min with no run at all.
--   (c) purge   — ONE ended automated session per pass. Automated rows are bot
--                 rows by construction; nobody inspects them first.
-- A HUMAN session is never purged here. Om looks at the residue and taps Purge.
create or replace function public.test_session_expire_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare n_exp int := 0; n_orph int := 0; v_purge jsonb := '{}'::jsonb;
        v_orphan_min int; v_purge_after int; v_id bigint; v_has_runs boolean;
begin
  select coalesce(automated_orphan_min, 20), coalesce(automated_purge_after_min, 5)
    into v_orphan_min, v_purge_after
    from public.test_mode_config where id = 1;
  v_orphan_min := coalesce(v_orphan_min, 20);
  v_purge_after := coalesce(v_purge_after, 5);

  update public.test_sessions
     set status='ended', ended_at=coalesce(ended_at, expires_at), auto_expired=true,
         ended_kind=coalesce(ended_kind,'expired')
   where status='live' and now() >= expires_at;
  get diagnostics n_exp = row_count;

  v_has_runs := to_regclass('public.test_runs') is not null;
  if v_has_runs then
    update public.test_sessions s
       set status='ended', ended_at=now(), auto_expired=true,
           ended_kind=coalesce(s.ended_kind,'orphan')
     where s.status='live' and s.origin='automated'
       and (
         exists (select 1 from public.test_runs r
                  where r.test_session_id = s.id and r.ended_at is not null)
         or (not exists (select 1 from public.test_runs r where r.test_session_id = s.id)
             and s.started_at < now() - make_interval(mins => v_orphan_min))
       );
    get diagnostics n_orph = row_count;
  else
    update public.test_sessions s
       set status='ended', ended_at=now(), auto_expired=true,
           ended_kind=coalesce(s.ended_kind,'orphan')
     where s.status='live' and s.origin='automated'
       and s.started_at < now() - make_interval(mins => v_orphan_min);
    get diagnostics n_orph = row_count;
  end if;

  select id into v_id from public.test_sessions
   where origin='automated' and status='ended'
     and coalesce(ended_at, started_at) < now() - make_interval(mins => v_purge_after)
   order by id limit 1;
  if v_id is not null then
    begin
      v_purge := public.test_session_purge(v_id, 4000);
    exception when others then
      v_purge := jsonb_build_object('ok', false, 'error', sqlerrm);
    end;
  end if;

  return jsonb_build_object('ok',true,'expired',n_exp,'orphans',n_orph,
                            'purged_session', v_id, 'purge', v_purge);
end $fn$;

-- Tighter cadence: a bot session that dies must not stay live for a quarter of
-- an hour. Still a cron_task poll on the #305 dispatcher, never a bare */N.
update public.cron_task
   set base_interval_s = 300, max_interval_s = 900, enabled = true,
       note = 'CHANGE #1821 - ends expired and ORPHANED test sessions and purges automated ones.'
 where name = 'test_session_expire';

-- ── 13. EXPIRED CAN NEVER READ AS LIVE, ANYWHERE ──────────────────────────
-- test_session_list() decided LIVE/danger/can_end from status alone, so a row
-- whose expiry had passed but which the sweep had not yet reached printed a
-- red LIVE chip on the admin screen (spec item 5). Liveness is one predicate
-- now, and it is the same one the banner and the trigger use.
create or replace function public.test_session_list(p_limit int default 20)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'id', s.id,
      'label', s.label,
      -- An expired-but-unswept row must not report 'live' to ANY caller — not
      -- the chip, not the tone, not the raw status a script might read.
      'status', case
        when s.status='live' and s.ended_at is null and now() < s.expires_at then 'live'
        when s.status='live' then 'expired'
        else s.status end,
      'status_label', case
        when s.status='live' and s.ended_at is null and now() < s.expires_at
                               then public.uic('test_session.live','LIVE')
        when s.status='purged' then public.uic('test_session.purged_chip','Purged')
        when s.status='live'   then public.uic('test_session.expired_chip','Auto-expired')
        when s.auto_expired    then public.uic('test_session.expired_chip','Auto-expired')
        else public.uic('test_session.ended_chip','Ended') end,
      'status_tone', case
        when s.status='live' and s.ended_at is null and now() < s.expires_at then 'danger'
        when s.status='purged' then 'success' else 'neutral' end,
      -- CHANGE #1821 — the row now says WHO opened it and whether it could
      -- ever have raised the platform banner. That is the whole difference Om
      -- could not see: five "autotest smoke" rows looked exactly like his own.
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
    'rows', v_rows);
end $fn$;

-- The #636 residue oracle asked `s.status = 'live'` and therefore counted an
-- expired-but-unswept session as live, hiding real residue from the safety net
-- (spec item 5 again, on a different surface). Rebuilt against the same
-- predicate — and moved off information_schema onto pg_catalog while it is
-- open, because the recorded lesson from #636 is that this exact join shape,
-- run per table inside an oracle, took a database down for ninety seconds.
do $$
begin
  if to_regprocedure('public._autotest_synthetic_residue()') is null then return; end if;
  execute $q$
    create or replace function public._autotest_synthetic_residue()
    returns table (n bigint, sample text)
    language plpgsql stable security definer set search_path to 'public' as $body$
    declare r record; c bigint; total bigint := 0; hits text[] := '{}';
    begin
      for r in
        select k.relname as table_name
          from pg_class k
          join pg_namespace ns on ns.oid = k.relnamespace
          join pg_attribute a1 on a1.attrelid = k.oid and a1.attname = 'is_synthetic' and a1.attnum > 0 and not a1.attisdropped
          join pg_attribute a2 on a2.attrelid = k.oid and a2.attname = 'test_session_id' and a2.attnum > 0 and not a2.attisdropped
         where ns.nspname = 'public' and k.relkind = 'r'
           and k.relname not like 'autotest%'
         order by k.relname
      loop
        begin
          execute format($q2$
            select count(*) from public.%I t
             where t.is_synthetic
               and (t.test_session_id is null
                    or not exists (select 1 from public.test_sessions s
                                    where s.id = t.test_session_id
                                      and s.status = 'live' and s.ended_at is null
                                      and now() < s.expires_at))
          $q2$, r.table_name) into c;
        exception when others then c := 0;
        end;
        if coalesce(c,0) > 0 then
          total := total + c;
          hits := hits || (r.table_name || '=' || c);
        end if;
      end loop;
      n := total;
      sample := coalesce(array_to_string(hits[1:12], ', '), '');
      return next;
      return;
    end $body$;
  $q$;
end $$;

-- ── 14. PERMISSION HOLES FOUND ON THIS PATH ───────────────────────────────
-- test_session_live_id() was granted to anon. Nothing in the app calls it (the
-- app reads test_session_banner()), and an id is one probe closer to a session
-- an anon has no business knowing exists. The SECURITY DEFINER callers inside
-- the database are unaffected.
revoke execute on function public.test_session_live_id() from anon, authenticated;
-- test_session_residue() enumerates fifty tables; it belongs to the admin
-- screen, which reaches it through test_session_list()/test_mode_screen().
revoke execute on function public.test_session_residue(bigint) from anon;
grant execute on function public.test_session_expire_sweep() to service_role;

-- ── 15. THE WORDS (backend, as always) ────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('test_session.origin_automated', to_jsonb('Automated'::text)),
  ('test_session.origin_human',     to_jsonb('Started by a person'::text)),
  ('test_session.no_banner',        to_jsonb('No banner — bot scope only'::text)),
  ('test_session.banner_shown',     to_jsonb('Banner shown platform-wide'::text)),
  ('test_session.human_live',       to_jsonb('A person has test mode on. Automated runs do not join it.'::text)),
  ('test_session.busy',             to_jsonb('Another test session is already open.'::text)),
  ('test_session.started_automated',to_jsonb('Automated test run open — no banner, bot scope only.'::text)),
  ('test_session.origin_title',     to_jsonb('Who started it'::text))
on conflict (key) do nothing;

-- replay-target: production
-- CMD #1850 — A TEST SESSION CAN SET ITS OWN CLOCK.
--
-- #1847 shipped the order cut-off, the unpaid auto-cancel and the restoration
-- window. Nobody can test any of it at 2pm: the only way to see the 30-minute
-- warning fire is to be sitting there at 11:30. Same for order hours, licence
-- expiry, a stock-update token going stale and every SLA countdown.
--
-- So a live test session may PIN AN EFFECTIVE TIME, and the decisions that
-- read the wall clock read the session's clock instead — for that session's
-- install and nobody else's.
--
--   1. ONE READER. public.now_eff(). It resolves the session exactly the way
--      #1848's stamp does — through test_session_mine(), i.e. the opaque
--      x-medibo-test-session header this install carries. No header, no live
--      session, no pin, or ANY failure at all → now(). That last clause is
--      the whole safety story: a bug in the clock can only ever hand back the
--      real time.
--   2. AN OFFSET, NOT A FREEZE. clock_offset is an interval; now_eff() is
--      now() + offset. "Jump to 11:29 PM" sets the offset that puts the
--      session there; "+15 min" adds to it; Release sets it null. Time still
--      PASSES inside a pinned session, so a countdown counts down and an SLA
--      timer still runs — a frozen clock would make half of what this exists
--      to test untestable.
--   3. NEVER A GLOBAL FACT. pg_cron carries no request headers, so every
--      scheduled job reads now() by construction. On top of that the write
--      side is guarded: test_clock_session() is non-null only while THIS
--      request is a pinned session, and each tick that writes either scopes
--      itself to that session's own rows (order_cutoff_tick) or refuses to
--      run at all (order_hours_tick, partner_licence_expiry_sweep).
--   4. NEVER A FAKE TRUTH. A row written under a pinned clock keeps its real
--      created_at (column defaults are untouched) and additionally records
--      test_clock_at — the effective instant the decision was made under. The
--      audit reads both. Every pin/step/release is itself a row in
--      test_clock_event with BOTH times.

begin;

-- ---------------------------------------------------------------------------
-- 1. THE PIN LIVES ON THE SESSION
-- ---------------------------------------------------------------------------
alter table public.test_sessions
  add column if not exists clock_offset    interval,
  add column if not exists clock_pinned_at timestamptz,
  add column if not exists clock_pinned_to timestamptz,
  add column if not exists clock_pinned_by uuid;

comment on column public.test_sessions.clock_offset is
  'CMD #1850 — the session''s clock: now_eff() = now() + this. NULL = the real clock.';

-- Every clock action, with BOTH times, forever.
create table if not exists public.test_clock_event (
  id            bigserial primary key,
  session_id    bigint not null references public.test_sessions(id) on delete cascade,
  action        text   not null,           -- pin | step | release
  arg           text,
  offset_before interval,
  offset_after  interval,
  effective_at  timestamptz not null,      -- what the session's clock read after it
  real_at       timestamptz not null default now(),
  actor         uuid
);
create index if not exists test_clock_event_session_idx
  on public.test_clock_event (session_id, id desc);

comment on table public.test_clock_event is
  'CMD #1850 — the audit trail of a session clock. real_at is the wall clock, '
  'effective_at is what the session believed. Neither is ever overwritten.';

-- ---------------------------------------------------------------------------
-- 2. THE READER — the only thing in the platform that decides what "now" is
-- ---------------------------------------------------------------------------

-- The session id ONLY while this request is a pinned human session. Every
-- write-side guard asks this, never now_eff(): "is a clock pinned right now,
-- and whose?" is a different question from "what time is it?".
create or replace function public.test_clock_session()
 returns bigint
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  v_id := public.test_session_mine();
  if v_id is null then return null; end if;
  return (select s.id from public.test_sessions s
           where s.id = v_id and s.origin = 'human' and s.clock_offset is not null);
exception when others then
  return null;
end $$;

create or replace function public.now_eff()
 returns timestamptz
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_off interval;
begin
  -- One lookup, and it is the SAME reader that decides whether a row is test
  -- data at all. A session that cannot stamp cannot bend time either.
  select s.clock_offset into v_off
    from public.test_sessions s
   where s.id = public.test_session_mine()
     and s.origin = 'human'
     and s.clock_offset is not null;
  if v_off is null then return now(); end if;
  return now() + v_off;
exception when others then
  -- A clock that throws is a clock that reads the real time. Never an error.
  return now();
end $$;

-- The IST calendar day under the effective clock — the form half the cut-off
-- engine actually uses.
create or replace function public.today_eff()
 returns date
 language sql stable security definer set search_path to 'public'
as $$ select (public.now_eff() at time zone 'Asia/Kolkata')::date $$;

-- The effective instant a row was written under, or NULL when the session is
-- on the real clock. This is what lands in test_clock_at.
create or replace function public.test_clock_of(p_session bigint)
 returns timestamptz
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_off interval;
begin
  if p_session is null then return null; end if;
  select s.clock_offset into v_off from public.test_sessions s
   where s.id = p_session and s.clock_offset is not null;
  if v_off is null then return null; end if;
  return now() + v_off;
exception when others then
  return null;
end $$;

revoke all on function public.now_eff() from public;
grant execute on function public.now_eff() to anon, authenticated, service_role;
revoke all on function public.today_eff() from public;
grant execute on function public.today_eff() to anon, authenticated, service_role;
revoke all on function public.test_clock_session() from public;
grant execute on function public.test_clock_session() to anon, authenticated, service_role;
revoke all on function public.test_clock_of(bigint) from public, anon;
grant execute on function public.test_clock_of(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. A WRITE UNDER A PINNED CLOCK RECORDS BOTH TIMES
-- ---------------------------------------------------------------------------
-- Every table #573 stamps with test_session_id gains test_clock_at. It is
-- metadata-only DDL (a nullable column), and it is written by the ONE stamping
-- trigger, beside the session id, so nothing else has to learn about it.
do $$
declare t text;
begin
  foreach t in array public._test_session_tables() loop
    if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'public' and c.relname = t and c.relkind = 'r') then
      execute format('alter table public.%I add column if not exists test_clock_at timestamptz', t);
    end if;
  end loop;
end $$;

comment on column public.orders.test_clock_at is
  'CMD #1850 — the EFFECTIVE instant this row was decided under, when a test '
  'session had its clock pinned. created_at stays the real wall clock. NULL '
  'on every real row and on every test row written on the real clock.';

commit;

-- ---------------------------------------------------------------------------
-- 4. THE ONE STAMPING TRIGGER ALSO RECORDS THE EFFECTIVE TIME
-- ---------------------------------------------------------------------------
begin;

CREATE OR REPLACE FUNCTION public._synthetic_inherit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_key text; v_hit boolean; v_sess bigint; v_j jsonb; v_parent bigint;
        v_clock timestamptz;
begin
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- CMD #1848 — the ONE reader. This install's session (by header), or
    -- the bot lane; anybody else's insert is never stamped.
    v_sess := public._test_session_ambient();
  end if;
  if v_sess is not null then
    new.is_synthetic := true;
    v_j := to_jsonb(new);
    -- CMD #1850 — a row written under a pinned clock records BOTH times: its
    -- own created_at stays the real wall clock (the column default is never
    -- touched), and test_clock_at carries the effective instant the decision
    -- was made under. NULL whenever the session is on the real clock.
    v_clock := public.test_clock_of(v_sess);
    if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
      v_j := v_j || jsonb_build_object('test_session_id', v_sess);
    end if;
    if v_clock is not null and v_j ? 'test_clock_at' and v_j->>'test_clock_at' is null then
      v_j := v_j || jsonb_build_object('test_clock_at', v_clock);
    end if;
    new := jsonb_populate_record(new, v_j);
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
        v_clock := public.test_clock_of(v_parent);
        if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
          v_j := v_j || jsonb_build_object('test_session_id', v_parent);
        end if;
        if v_clock is not null and v_j ? 'test_clock_at' and v_j->>'test_clock_at' is null then
          v_j := v_j || jsonb_build_object('test_clock_at', v_clock);
        end if;
        new := jsonb_populate_record(new, v_j);
      end if;
      return new;
    end if;
  end loop;
  return new;
end $function$

;

-- ---------------------------------------------------------------------------
-- 5. THE WORDS. Every label the time control draws lives here, never in Dart.
-- ---------------------------------------------------------------------------
insert into public.ui_copy(key, value) values
  ('test_clock.title',          '"Session clock"'::jsonb),
  ('test_clock.badge',          '"CLOCK"'::jsonb),
  ('test_clock.real_sub',       '"Real time — nothing is shifted"'::jsonb),
  ('test_clock.pinned_sub',     '"Pinned · real time is {real}"'::jsonb),
  ('test_clock.jump_label',     '"Jump to"'::jsonb),
  ('test_clock.jump_hint',      '"DD-MM HH:MM, 24-hour, IST"'::jsonb),
  ('test_clock.jump_action',    '"Pin"'::jsonb),
  ('test_clock.step_label',     '"Step"'::jsonb),
  ('test_clock.release_action', '"Real time"'::jsonb),
  ('test_clock.open_action',    '"Clock"'::jsonb),
  ('test_clock.close_action',   '"Done"'::jsonb),
  ('test_clock.pinned_msg',     '"Session clock pinned. Only this session sees it."'::jsonb),
  ('test_clock.released_msg',   '"Back on the real clock."'::jsonb),
  ('test_clock.no_session',     '"Start test mode before setting a clock."'::jsonb),
  ('test_clock.bad_time',       '"That is not a time this clock understands."'::jsonb),
  ('test_clock.presets_label',  '"Jump to a moment that matters"'::jsonb),
  ('test_clock.preset_cutoff_minus', '"1 min before cut-off"'::jsonb),
  ('test_clock.preset_cutoff_warn',  '"First cut-off warning"'::jsonb),
  ('test_clock.preset_cutoff_plus',  '"Just past cut-off"'::jsonb),
  ('test_clock.preset_hours_close',  '"1 min before close"'::jsonb),
  ('test_clock.preset_hours_closed', '"After close"'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 6. THE STATE THE BANNER PRINTS — every string, already rendered.
-- ---------------------------------------------------------------------------
create or replace function public._test_clock_steps()
 returns jsonb
 language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_array(
    jsonb_build_object('key','-60','label','−1 h',  'minutes',-60),
    jsonb_build_object('key','-15','label','−15 m', 'minutes',-15),
    jsonb_build_object('key','1',  'label','+1 m',  'minutes',1),
    jsonb_build_object('key','15', 'label','+15 m', 'minutes',15),
    jsonb_build_object('key','60', 'label','+1 h',  'minutes',60));
$$;

-- The moments worth jumping to, resolved from the LIVE configuration of the
-- caller's own zone — so "1 min before cut-off" means this zone's cut-off
-- today, not a number typed into an app.
create or replace function public._test_clock_presets()
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_zone smallint; v_cut timestamptz; cfg public.order_alert_config;
        h public.order_hours%rowtype; v_close timestamptz; v_today date;
        v jsonb := '[]'::jsonb;
begin
  v_today := (now() at time zone 'Asia/Kolkata')::date;
  begin v_zone := public.zone_effective(null); exception when others then v_zone := null; end;
  if v_zone is null then
    select id into v_zone from public.zones where coalesce(is_default,false) limit 1;
  end if;
  cfg := public._oa_cfg();
  v_cut := public._order_cutoff_at(v_zone, v_today);
  if v_cut is not null then
    v := v || jsonb_build_array(
      jsonb_build_object('key','cutoff_warn',
        'label', public.uic('test_clock.preset_cutoff_warn','First cut-off warning'),
        'at', to_char((v_cut - make_interval(mins => greatest(coalesce(cfg.cutoff_warn1_min,30),0)))
                      at time zone 'Asia/Kolkata','YYYY-MM-DD HH24:MI')),
      jsonb_build_object('key','cutoff_minus',
        'label', public.uic('test_clock.preset_cutoff_minus','1 min before cut-off'),
        'at', to_char((v_cut - interval '1 minute') at time zone 'Asia/Kolkata','YYYY-MM-DD HH24:MI')),
      jsonb_build_object('key','cutoff_plus',
        'label', public.uic('test_clock.preset_cutoff_plus','Just past cut-off'),
        'at', to_char((v_cut + make_interval(mins => greatest(coalesce(cfg.cutoff_cancel_after_min,0),0) + 1))
                      at time zone 'Asia/Kolkata','YYYY-MM-DD HH24:MI')));
  end if;
  select * into h from public.order_hours where zone_id = v_zone;
  if h.id is null then select * into h from public.order_hours order by id limit 1; end if;
  if h.id is not null and h.auto_close_time is not null then
    v_close := ((v_today::text || ' ' || to_char(h.auto_close_time,'HH24:MI:SS'))::timestamp)
               at time zone 'Asia/Kolkata';
    v := v || jsonb_build_array(
      jsonb_build_object('key','hours_close',
        'label', public.uic('test_clock.preset_hours_close','1 min before close'),
        'at', to_char((v_close - interval '1 minute') at time zone 'Asia/Kolkata','YYYY-MM-DD HH24:MI')),
      jsonb_build_object('key','hours_closed',
        'label', public.uic('test_clock.preset_hours_closed','After close'),
        'at', to_char((v_close + interval '5 minutes') at time zone 'Asia/Kolkata','YYYY-MM-DD HH24:MI')));
  end if;
  return v;
exception when others then
  return '[]'::jsonb;
end $$;

create or replace function public.test_clock_state()
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $$
declare s public.test_sessions%rowtype; v_id bigint; v_eff timestamptz; v_pin boolean;
begin
  v_id := public.test_session_mine();
  if v_id is not null then
    select * into s from public.test_sessions where id = v_id and origin = 'human';
  end if;
  if v_id is null or s.id is null then
    return jsonb_build_object('has', false);
  end if;
  v_pin  := s.clock_offset is not null;
  v_eff  := now() + coalesce(s.clock_offset, interval '0');
  return jsonb_build_object(
    'has', true,
    'session_id', s.id,
    'pinned', v_pin,
    'title', public.uic('test_clock.title','Session clock'),
    'badge', public.uic('test_clock.badge','CLOCK'),
    'tone', case when v_pin then 'warning' else 'neutral' end,
    'now_at', v_eff,
    'now_label', to_char(v_eff at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI AM'),
    'now_sub', case when v_pin
      then replace(public.uic('test_clock.pinned_sub','Pinned · real time is {real}'), '{real}',
                   to_char(now() at time zone 'Asia/Kolkata','FMHH12:MI AM'))
      else public.uic('test_clock.real_sub','Real time — nothing is shifted') end,
    'open_action',    public.uic('test_clock.open_action','Clock'),
    'close_action',   public.uic('test_clock.close_action','Done'),
    'step_label',     public.uic('test_clock.step_label','Step'),
    'steps',          public._test_clock_steps(),
    'jump_label',     public.uic('test_clock.jump_label','Jump to'),
    'jump_hint',      public.uic('test_clock.jump_hint','DD-MM HH:MM, 24-hour, IST'),
    'jump_action',    public.uic('test_clock.jump_action','Pin'),
    'presets_label',  public.uic('test_clock.presets_label','Jump to a moment that matters'),
    'presets',        public._test_clock_presets(),
    'can_release',    v_pin,
    'release_action', public.uic('test_clock.release_action','Real time'));
exception when others then
  return jsonb_build_object('has', false);
end $$;

-- ---------------------------------------------------------------------------
-- 7. SETTING IT. Three verbs, one ledger row each, one state payload back.
-- ---------------------------------------------------------------------------
create or replace function public._test_clock_write(p_session bigint, p_action text,
         p_arg text, p_before interval, p_after interval)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_uid uuid;
begin
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  update public.test_sessions
     set clock_offset    = p_after,
         clock_pinned_at = case when p_after is null then null else now() end,
         clock_pinned_to = case when p_after is null then null else now() + p_after end,
         clock_pinned_by = case when p_after is null then null else coalesce(clock_pinned_by, v_uid) end
   where id = p_session;
  insert into public.test_clock_event(session_id, action, arg, offset_before,
            offset_after, effective_at, real_at, actor)
  values (p_session, p_action, p_arg, p_before, p_after,
          now() + coalesce(p_after, interval '0'), now(), v_uid);
  return public.test_clock_state()
       || jsonb_build_object('ok', true,
            'message', case when p_after is null
              then public.uic('test_clock.released_msg','Back on the real clock.')
              else public.uic('test_clock.pinned_msg',
                     'Session clock pinned. Only this session sees it.') end);
end $$;

create or replace function public.test_clock_pin(p_at text)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_before interval; v_target timestamptz; v_txt text;
begin
  v_id := public.test_session_mine();
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_session',
      'message', public.uic('test_clock.no_session','Start test mode before setting a clock.'));
  end if;
  v_txt := btrim(coalesce(p_at, ''));
  if v_txt = '' then
    return jsonb_build_object('ok', false, 'error', 'bad_time',
      'message', public.uic('test_clock.bad_time','That is not a time this clock understands.'));
  end if;
  begin
    -- The client sends what the person typed; IST is the platform's clock, so
    -- the backend does the parsing and the timezone, never Dart.
    if v_txt ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?$' then
      v_target := (replace(v_txt,'T',' ')::timestamp) at time zone 'Asia/Kolkata';
    elsif v_txt ~ '^\d{2}:\d{2}$' then
      v_target := (((now() at time zone 'Asia/Kolkata')::date::text || ' ' || v_txt)::timestamp)
                  at time zone 'Asia/Kolkata';
    else
      v_target := v_txt::timestamptz;
    end if;
  exception when others then
    v_target := null;
  end;
  if v_target is null then
    return jsonb_build_object('ok', false, 'error', 'bad_time',
      'message', public.uic('test_clock.bad_time','That is not a time this clock understands.'));
  end if;
  select clock_offset into v_before from public.test_sessions where id = v_id;
  return public._test_clock_write(v_id, 'pin', v_txt, v_before, v_target - now());
end $$;

create or replace function public.test_clock_step(p_minutes integer)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_before interval;
begin
  v_id := public.test_session_mine();
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_session',
      'message', public.uic('test_clock.no_session','Start test mode before setting a clock.'));
  end if;
  if p_minutes is null or abs(p_minutes) > 525600 then
    return jsonb_build_object('ok', false, 'error', 'bad_time',
      'message', public.uic('test_clock.bad_time','That is not a time this clock understands.'));
  end if;
  select clock_offset into v_before from public.test_sessions where id = v_id;
  return public._test_clock_write(v_id, 'step', p_minutes::text, v_before,
           coalesce(v_before, interval '0') + make_interval(mins => p_minutes));
end $$;

create or replace function public.test_clock_release()
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_before interval;
begin
  v_id := public.test_session_mine();
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_session',
      'message', public.uic('test_clock.no_session','Start test mode before setting a clock.'));
  end if;
  select clock_offset into v_before from public.test_sessions where id = v_id;
  return public._test_clock_write(v_id, 'release', null, v_before, null);
end $$;

-- Grants — the state is a read anyone carrying the token may make; SETTING the
-- clock is never anonymous.
revoke all on function public._test_clock_steps() from public, anon;
revoke all on function public._test_clock_presets() from public, anon;
revoke all on function public._test_clock_write(bigint, text, text, interval, interval) from public, anon;
grant execute on function public._test_clock_steps() to authenticated, service_role;
grant execute on function public._test_clock_presets() to authenticated, service_role;
grant execute on function public._test_clock_write(bigint, text, text, interval, interval) to service_role;
revoke all on function public.test_clock_state() from public;
grant execute on function public.test_clock_state() to anon, authenticated, service_role;
revoke all on function public.test_clock_pin(text) from public, anon;
revoke all on function public.test_clock_step(integer) from public, anon;
revoke all on function public.test_clock_release() from public, anon;
grant execute on function public.test_clock_pin(text)     to authenticated, service_role;
grant execute on function public.test_clock_step(integer) to authenticated, service_role;
grant execute on function public.test_clock_release()     to authenticated, service_role;

-- The ledger is read through the console, never directly.
revoke all on table public.test_clock_event from public, anon, authenticated;
grant select, insert on table public.test_clock_event to service_role;
alter table public.test_clock_event enable row level security;

commit;

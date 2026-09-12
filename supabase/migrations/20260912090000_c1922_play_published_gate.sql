-- ============================================================================
-- CHANGE #1922 — the update prompt may only offer a version Play has PUBLISHED
--
-- 08 Sep: 1.3.25 was uploaded at 22:22 and sat "In review" in Play Console,
-- yet every phone already showed "A new version of mediBO is ready · Version
-- 1.3.25 · Update on Google Play". Tapping it opened a Play page still serving
-- 1.3.24 — a dead end, and one every user hit on every launch.
--
-- Cause: scripts/publish_play.sh calls app_release_publish() the moment the AAB
-- is UPLOADED, and app_update_check() simply read the newest app_releases row.
-- Upload is not publication. Play's review can take days, and a staged rollout
-- reaches 1 % of users before it reaches everyone.
--
-- After this migration app_releases carries TWO facts, never one:
--   • the SUBMITTED build   — written at upload time, as before;
--   • the PUBLISHED build   — play_status/rollout_pct, written ONLY by
--     app_release_play_sync() from what the Google Play API itself reports.
-- app_update_check() reads the published one. Nothing else can switch the
-- prompt on: publishing a release row no longer prompts anybody.
--
-- Idempotent: every statement is guarded, the one-shot backfill is marked in
-- app_settings, so the live replay can run this file more than once safely.
-- ============================================================================

-- ─── 1. the gate columns ────────────────────────────────────────────────────
alter table public.app_releases
  add column if not exists play_track        text,
  add column if not exists play_status       text not null default 'submitted',
  add column if not exists rollout_pct       numeric,
  add column if not exists submitted_at      timestamptz,
  add column if not exists play_published_at timestamptz,
  add column if not exists play_checked_at   timestamptz;

comment on column public.app_releases.play_status is
  'submitted | in_review | rollout | published | halted | unknown — written by app_release_play_sync() from the Play API only. The in-app prompt reads published.';

update public.app_releases set submitted_at = released_at where submitted_at is null;

create index if not exists idx_app_releases_published
  on public.app_releases(platform, version_code desc)
  where play_status = 'published';

-- ─── 2. the transition log ──────────────────────────────────────────────────
create table if not exists public.app_release_play_log (
  id           bigserial primary key,
  platform     text        not null default 'android',
  version_name text,
  version_code int         not null,
  track        text,
  from_status  text,
  to_status    text        not null,
  from_rollout numeric,
  rollout_pct  numeric,
  source       text        not null default 'poller',
  note         text,
  at           timestamptz not null default now()
);
create index if not exists idx_app_release_play_log_at
  on public.app_release_play_log(at desc);

alter table public.app_release_play_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='app_release_play_log'
                    and policyname='app_release_play_log_no_direct') then
    -- No direct client access: the log is read through app_update_state() only.
    create policy app_release_play_log_no_direct on public.app_release_play_log
      for select using (false);
  end if;
end $$;

-- ─── 3. one-shot backfill ───────────────────────────────────────────────────
-- Everything already in the table predates the gate. The newest row per
-- platform is the one that may still be in review (that is exactly the 1.3.25
-- case), so it stays 'submitted' until Play is read; every older row was
-- superseded, which can only happen after it went live, so it is 'published'.
-- Marked done in app_settings so a replay never re-demotes a synced row.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'c1922_gate_backfill') then
    update public.app_releases r
       set play_status       = 'published',
           rollout_pct       = 100,
           play_published_at = coalesce(r.play_published_at, r.released_at)
     where r.version_code < (select max(r2.version_code) from public.app_releases r2
                              where r2.platform = r.platform);
    insert into public.app_settings(key, value)
    values ('c1922_gate_backfill', jsonb_build_object('at', now(), 'change', 1922))
    on conflict (key) do nothing;
  end if;
end $$;

-- ─── 4. copy (every visible word lives here) ────────────────────────────────
insert into public.ui_copy(key, value) values
  ('app_update_admin.title',            '"In-app update prompt"'::jsonb),
  ('app_update_admin.subtitle',         '"The prompt can only offer a version Google Play has actually published. A submitted build stays silent until review clears and the rollout reaches everyone."'::jsonb),
  ('app_update_admin.published_heading','"Users are being offered"'::jsonb),
  ('app_update_admin.submitted_heading','"Latest submitted build"'::jsonb),
  ('app_update_admin.none_published',   '"No published version yet — the prompt is off."'::jsonb),
  ('app_update_admin.none_submitted',   '"No build has been submitted."'::jsonb),
  ('app_update_admin.prompt_on',        '"Prompt is ON"'::jsonb),
  ('app_update_admin.prompt_off',       '"Prompt is OFF"'::jsonb),
  ('app_update_admin.prompt_on_detail', '"Play has published {version}. Anyone on an older build sees the update sheet."'::jsonb),
  ('app_update_admin.prompt_off_detail','"Nothing is published on Play, so no one is prompted."'::jsonb),
  ('app_update_admin.checked_label',    '"Play read {age}"'::jsonb),
  ('app_update_admin.never_checked',    '"Play has not been read yet"'::jsonb),
  ('app_update_admin.log_heading',      '"Play status changes"'::jsonb),
  ('app_update_admin.log_empty',        '"No status change recorded yet."'::jsonb),
  ('app_update_admin.version_label',    '"Version {name} ({code})"'::jsonb),
  ('app_update_admin.rollout_label',    '"Rolling out to {pct}% of users"'::jsonb),
  ('app_update_admin.track_label',      '"{track} track"'::jsonb),
  ('app_update_admin.submitted_meta',   '"Submitted {age}"'::jsonb),
  ('app_update_admin.published_meta',   '"Published {age}"'::jsonb),
  ('app_update_admin.status_submitted', '"Submitted — waiting for Play"'::jsonb),
  ('app_update_admin.status_in_review', '"In review on Play"'::jsonb),
  ('app_update_admin.status_rollout',   '"Staged rollout — not everyone yet"'::jsonb),
  ('app_update_admin.status_published', '"Published on Play"'::jsonb),
  ('app_update_admin.status_halted',    '"Halted on Play"'::jsonb),
  ('app_update_admin.status_unknown',   '"Play has not reported this build"'::jsonb),
  ('app_update_admin.log_line',         '"{name} ({code}) · {from} → {to}"'::jsonb),
  ('app_update_admin.log_first',        '"{name} ({code}) · {to}"'::jsonb)
on conflict (key) do nothing;

-- ─── 5. the vocabulary, in one place ────────────────────────────────────────
create or replace function public._c1922_status_label(p_status text)
returns text language sql stable set search_path to 'public' as $$
  select public._c('app_update_admin.status_' || coalesce(nullif(p_status,''),'unknown'));
$$;

create or replace function public._c1922_status_tone(p_status text)
returns text language sql immutable as $$
  select case coalesce(p_status,'')
           when 'published' then 'success'
           when 'rollout'   then 'warning'
           when 'in_review' then 'warning'
           when 'halted'    then 'danger'
           else 'neutral' end;
$$;

-- The ONE definition of "published_version": a release Play reports as live to
-- everybody. A staged rollout below 100 % is deliberately NOT published.
create or replace function public.app_published_release(p_platform text default 'android')
returns public.app_releases
language sql stable security definer set search_path to 'public' as $$
  select * from public.app_releases
   where platform = coalesce(p_platform,'android')
     and play_status = 'published'
     and coalesce(rollout_pct, 100) >= 100
   order by version_code desc
   limit 1;
$$;

-- ─── 6. publishing a RELEASE ROW no longer prompts anybody ──────────────────
-- app_release_publish() is what publish_play.sh calls the moment the AAB is
-- uploaded. It now records a SUBMISSION: the row exists, the APK is served,
-- and play_status stays 'submitted' until the Play API says otherwise. A
-- re-run for a code Play already published keeps that published state (same
-- artifact), so a retry can never silently switch the prompt back off.
-- The 7th parameter is added with a default, so the OLD 6-arg function must go
-- first: two candidates that both match a 4-key named call is a PostgREST 300.
drop function if exists public.app_release_publish(text, integer, text, text, boolean, text);

create or replace function public.app_release_publish(
  p_version_name text, p_version_code integer, p_apk_url text,
  p_notes text default null, p_mandatory boolean default false,
  p_platform text default 'android', p_track text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_plat text := coalesce(p_platform,'android');
begin
  if not (
        coalesce(auth.jwt()->>'role','') = 'service_role'
     or get_my_role() in ('admin','super_admin')
     or (coalesce(current_setting('request.jwt.claims', true), '') = ''
         and session_user in ('postgres','supabase_admin'))
  ) then
    return jsonb_build_object('error','not_authorized','message','Only an admin can publish a release');
  end if;

  insert into app_releases(platform, version_name, version_code, apk_url, notes,
                           is_mandatory, released_by, play_track, play_status, submitted_at)
  values (v_plat, btrim(p_version_name), p_version_code,
          nullif(btrim(p_apk_url),''), nullif(btrim(p_notes),''),
          coalesce(p_mandatory,false), auth.uid(),
          nullif(btrim(coalesce(p_track,'')),''), 'submitted', now())
  on conflict (platform, version_code) do update
     set version_name = excluded.version_name, apk_url = excluded.apk_url,
         notes = excluded.notes, is_mandatory = excluded.is_mandatory,
         play_track = coalesce(excluded.play_track, app_releases.play_track),
         released_at = now();

  insert into app_release_play_log(platform, version_name, version_code, track,
                                   from_status, to_status, source, note)
  select v_plat, btrim(p_version_name), p_version_code,
         nullif(btrim(coalesce(p_track,'')),''), null,
         r.play_status, 'release_publish',
         'submitted to Play — the prompt stays on the published version'
    from app_releases r
   where r.platform = v_plat and r.version_code = p_version_code
     and r.play_status <> 'published';

  return jsonb_build_object('ok', true, 'submitted', true,
    'play_status', (select play_status from app_releases
                     where platform = v_plat and version_code = p_version_code),
    'message', 'Release ' || p_version_name || ' recorded as submitted');
end $function$;

-- ─── 7. the poller's write: what PLAY says, nothing else ────────────────────
-- Fed the payload of `python3 scripts/play_ops.py tracks` verbatim (the same
-- read the Play Store screen renders), every ~2 min by medibo-play.timer.
-- Rules:
--   • an empty/failed read changes NOTHING (a Play outage must not silence or
--     wrongly enable the prompt);
--   • only the gate track (default 'production') can publish a version;
--   • status completed + rollout 100 %  → published;
--     inProgress → rollout (prompt stays off until it reaches 100 %);
--     draft/inReview → in_review; halted → halted;
--   • a code ABOVE the live production code can never stay 'published' — that
--     is the 1.3.25 case, and it is demoted with a logged transition;
--   • every change is written to app_release_play_log.
create or replace function public.app_release_play_sync(
  p_tracks jsonb, p_platform text default 'android', p_source text default 'poller')
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_plat    text := coalesce(p_platform,'android');
  v_cfg     jsonb := coalesce((select value from app_settings where key='app_update_channel'),'{}'::jsonb);
  v_gate    text := coalesce(nullif(btrim(coalesce(v_cfg->>'gate_track','')),''), 'production');
  v_pick    jsonb;
  v_raw     text;
  v_status  text;
  v_frac    numeric;
  v_roll    numeric;
  v_name    text;
  v_codes   int[];
  v_max     int;
  v_seen    int[] := '{}';
  v_changes int := 0;
  r         record;
  v_new     text;
  v_newroll numeric;
begin
  if not (
        coalesce(auth.jwt()->>'role','') = 'service_role'
     or get_my_role() in ('admin','super_admin')
     or (coalesce(current_setting('request.jwt.claims', true), '') = ''
         and session_user in ('postgres','supabase_admin'))
  ) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  if p_tracks is null or jsonb_typeof(p_tracks) <> 'array' or jsonb_array_length(p_tracks) = 0 then
    -- Play could not be read. Say so and touch nothing.
    return jsonb_build_object('ok', false, 'error','no_track_data',
                              'message','Play returned no track state — nothing changed');
  end if;

  -- every code Play mentions anywhere: those are "on Play", not merely submitted
  select coalesce(array_agg(distinct c::int),'{}') into v_seen
    from jsonb_array_elements(p_tracks) t,
         jsonb_array_elements_text(coalesce(t->'version_codes','[]'::jsonb)) c
   where c ~ '^[0-9]+$';

  select t into v_pick from jsonb_array_elements(p_tracks) t
   where t->>'track' = v_gate limit 1;

  if v_pick is not null then
    v_raw    := v_pick->>'status';
    v_name   := v_pick->>'version_name';
    v_frac   := nullif(v_pick->>'user_fraction','')::numeric;
    v_status := case v_raw
                  when 'completed'  then 'published'
                  when 'inProgress' then 'rollout'
                  when 'halted'     then 'halted'
                  when 'draft'      then 'in_review'
                  when 'inReview'   then 'in_review'
                  else 'unknown' end;
    -- Play omits userFraction on a full rollout; absent means everyone.
    v_roll := case when v_frac is null then (case when v_status='published' then 100 else null end)
                   else round(v_frac * 100, 2) end;
    if v_status = 'rollout' and coalesce(v_roll,0) >= 100 then v_status := 'published'; end if;

    select coalesce(array_agg(c::int),'{}') into v_codes
      from jsonb_array_elements_text(coalesce(v_pick->'version_codes','[]'::jsonb)) c
     where c ~ '^[0-9]+$';
    select max(x) into v_max from unnest(v_codes) x;
  end if;

  for r in select * from app_releases where platform = v_plat loop
    v_new := r.play_status; v_newroll := r.rollout_pct;

    if v_codes is not null and r.version_code = any(v_codes) then
      v_new := v_status; v_newroll := v_roll;
    elsif v_max is not null and r.version_code > v_max then
      -- uploaded, but the live production release is an OLDER code: this build
      -- is not serving anybody yet, whatever we believed before.
      v_new := case when r.version_code = any(v_seen) then 'in_review' else r.play_status end;
      if r.play_status = 'published' then v_new := 'in_review'; end if;
      v_newroll := null;
    end if;

    if v_new is distinct from r.play_status or v_newroll is distinct from r.rollout_pct then
      update app_releases
         set play_status = v_new,
             rollout_pct = v_newroll,
             play_track  = coalesce(case when r.version_code = any(coalesce(v_codes,'{}')) then v_gate end, play_track),
             play_published_at = case when v_new = 'published'
                                      then coalesce(play_published_at, now()) else play_published_at end,
             play_checked_at = now()
       where id = r.id;
      insert into app_release_play_log(platform, version_name, version_code, track,
                                       from_status, to_status, from_rollout, rollout_pct, source)
      values (v_plat, coalesce(r.version_name, v_name), r.version_code,
              case when r.version_code = any(coalesce(v_codes,'{}')) then v_gate else r.play_track end,
              r.play_status, v_new, r.rollout_pct, v_newroll, coalesce(p_source,'poller'));
      v_changes := v_changes + 1;
    else
      update app_releases set play_checked_at = now() where id = r.id;
    end if;
  end loop;

  -- Play is serving a version we have no row for. That is not a reason to keep
  -- the prompt pointing at an older build (on 12 Sep production was on 1.3.26
  -- (41) while app_releases stopped at 1.3.25 (39) — an APK upload had failed,
  -- so the prompt named a version Play no longer served). Play's own answer is
  -- the record: adopt it, published, and log where it came from.
  if v_codes is not null and v_status is not null then
    insert into app_releases(platform, version_name, version_code, play_track,
                             play_status, rollout_pct, submitted_at, play_published_at,
                             play_checked_at)
    select v_plat, coalesce(nullif(v_name,''), c::text), c, v_gate, v_status, v_roll, now(),
           case when v_status = 'published' then now() end, now()
      from unnest(v_codes) c
     where not exists (select 1 from app_releases a
                        where a.platform = v_plat and a.version_code = c);
    if found then
      insert into app_release_play_log(platform, version_name, version_code, track,
                                       from_status, to_status, rollout_pct, source, note)
      select v_plat, coalesce(nullif(v_name,''), c::text), c, v_gate, null, v_status, v_roll,
             coalesce(p_source,'poller'), 'Play reported a release mediBO had no row for'
        from unnest(v_codes) c
       where not exists (select 1 from app_release_play_log l
                          where l.platform = v_plat and l.version_code = c);
      v_changes := v_changes + 1;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'gate_track', v_gate,
    'live_code', v_max,
    'live_status', v_status,
    'rollout_pct', v_roll,
    'transitions', v_changes,
    'published_code', (select version_code from app_published_release(v_plat)),
    'published_name', (select version_name from app_published_release(v_plat)),
    'checked_at', now());
end $function$;

-- ─── 8. the phone's check now reads the PUBLISHED release ───────────────────
-- Only this one SELECT changed: the newest row became the newest PUBLISHED
-- row. Everything below it (channel resolution, copy, dismiss key) is #282's
-- and is untouched.
create or replace function public.app_update_check(
  p_platform text default 'android', p_version_code integer default 0,
  p_install_source text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  r          app_releases%rowtype;
  v_cfg      jsonb;
  v_channel  text;
  v_url      text;
  v_action   text;
  v_title    text;
  v_message  text;
  v_src      text := nullif(btrim(coalesce(p_install_source, '')), '');
begin
  -- CHANGE #1922: a submitted-but-unreviewed build is invisible here.
  r := public.app_published_release(coalesce(p_platform,'android'));

  if r.id is null or coalesce(p_version_code, 0) >= r.version_code then
    return jsonb_build_object(
      'update_available', false,
      'current', coalesce(r.version_name, ''),
      'message', '',
      'dismiss_key', null);
  end if;

  v_cfg := coalesce((select value from app_settings where key = 'app_update_channel'), '{}'::jsonb);

  select s.channel into v_channel from app_install_source s where s.source = v_src;
  if v_channel is null then
    v_channel := case
      when coalesce((v_cfg->>'unknown_is_play')::boolean, true) then 'play'
      else 'direct' end;
  end if;

  v_url := case when v_channel = 'play' then nullif(btrim(coalesce(v_cfg->>'play_url','')), '') end;
  if v_url is null and v_channel = 'play' then
    v_url := nullif(btrim(coalesce(r.apk_url, '')), '');
    if v_url is not null then v_channel := 'direct'; end if;
  end if;
  if v_channel = 'direct' then
    v_url := nullif(btrim(coalesce(r.apk_url, '')), '');
    if v_url is null then
      v_url := nullif(btrim(coalesce(v_cfg->>'play_url','')), '');
      if v_url is not null then v_channel := 'play'; end if;
    end if;
  end if;

  if v_url is null then
    return jsonb_build_object('update_available', false, 'current', '',
                              'message', '', 'dismiss_key', null);
  end if;

  v_action  := case when v_channel = 'play' then _c('app_update.action_play')
                    else _c('app_update.action_apk') end;
  v_title   := case when r.is_mandatory then _c('app_update.title_mandatory')
                    else _c('app_update.title') end;
  v_message := coalesce(
    nullif(btrim(coalesce(r.public_notes, '')), ''),
    nullif(case when r.is_mandatory then _c('app_update.message_mandatory')
                else _c('app_update.message_default') end, ''),
    '');

  return jsonb_build_object(
    'update_available', true,
    'current',       coalesce(r.version_name, ''),
    'version_name',  r.version_name,
    'version_code',  r.version_code,
    'version_label', case when coalesce(_c('app_update.version_label'), '') = '' then ''
                          else format(_c('app_update.version_label'), r.version_name) end,
    'channel',       v_channel,
    'store_name',    coalesce(nullif(btrim(coalesce(v_cfg->>'store_name','')), ''), ''),
    'install_source', coalesce(v_src, ''),
    'action_url',    v_url,
    'apk_url',       case when v_channel = 'direct' then v_url end,
    'mandatory',     r.is_mandatory,
    'eyebrow',       _c('app_update.eyebrow'),
    'title',         v_title,
    'message',       v_message,
    'action_label',  v_action,
    'dismiss_label', case when r.is_mandatory then null else _c('app_update.dismiss') end,
    'dismiss_key',   case when r.is_mandatory then null
                          else 'app_update:' || coalesce(p_platform,'android') || ':' || r.version_code end
  );
end $function$;

-- ─── 9. the admin panel's ONE payload (rendered verbatim by Flutter) ────────
create or replace function public.app_update_state(p_platform text default 'android')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_plat text := coalesce(p_platform,'android');
  pub    app_releases%rowtype;
  sub    app_releases%rowtype;
  v_chk  timestamptz;
  v_log  jsonb;
begin
  if not (get_my_role() in ('admin','super_admin')
          or coalesce(auth.jwt()->>'role','') = 'service_role') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  pub := public.app_published_release(v_plat);
  select * into sub from app_releases where platform = v_plat
   order by version_code desc limit 1;
  select max(play_checked_at) into v_chk from app_releases where platform = v_plat;

  select coalesce(jsonb_agg(x order by x_at desc), '[]'::jsonb) into v_log from (
    select jsonb_build_object(
             'title', case when l.from_status is null
                           then _cf('app_update_admin.log_first', jsonb_build_object(
                                  'name', coalesce(l.version_name,''), 'code', l.version_code::text,
                                  'to',   _c1922_status_label(l.to_status)))
                           else _cf('app_update_admin.log_line', jsonb_build_object(
                                  'name', coalesce(l.version_name,''), 'code', l.version_code::text,
                                  'from', _c1922_status_label(l.from_status),
                                  'to',   _c1922_status_label(l.to_status))) end,
             'detail', case when l.rollout_pct is null then ''
                            else _cf('app_update_admin.rollout_label',
                                     jsonb_build_object('pct', trim(to_char(l.rollout_pct,'FM999990.##')))) end,
             'at_label', _ist_stamp(l.at),
             'tone', _c1922_status_tone(l.to_status)) as x,
           l.at as x_at
      from app_release_play_log l
     where l.platform = v_plat
     order by l.at desc limit 20) s;

  return jsonb_build_object(
    'ok', true,
    'title',    _c('app_update_admin.title'),
    'subtitle', _c('app_update_admin.subtitle'),
    'prompt', jsonb_build_object(
      'is_on',  pub.id is not null,
      'label',  case when pub.id is not null then _c('app_update_admin.prompt_on')
                     else _c('app_update_admin.prompt_off') end,
      'tone',   case when pub.id is not null then 'success' else 'neutral' end,
      'detail', case when pub.id is not null
                     then _cf('app_update_admin.prompt_on_detail', jsonb_build_object(
                            'version', _cf('app_update_admin.version_label', jsonb_build_object(
                              'name', coalesce(pub.version_name,''), 'code', pub.version_code::text))))
                     else _c('app_update_admin.prompt_off_detail') end),
    'published', jsonb_build_object(
      'has',          pub.id is not null,
      'heading',      _c('app_update_admin.published_heading'),
      'empty_label',  _c('app_update_admin.none_published'),
      'version_label', case when pub.id is null then ''
                            else _cf('app_update_admin.version_label', jsonb_build_object(
                                   'name', coalesce(pub.version_name,''), 'code', pub.version_code::text)) end,
      'status_label', _c1922_status_label(pub.play_status),
      'status_tone',  _c1922_status_tone(pub.play_status),
      'meta_label',   case when pub.play_published_at is null then ''
                           else _cf('app_update_admin.published_meta',
                                    jsonb_build_object('age', _ist_age(pub.play_published_at))) end),
    'submitted', jsonb_build_object(
      'has',          sub.id is not null,
      'heading',      _c('app_update_admin.submitted_heading'),
      'empty_label',  _c('app_update_admin.none_submitted'),
      'version_label', case when sub.id is null then ''
                            else _cf('app_update_admin.version_label', jsonb_build_object(
                                   'name', coalesce(sub.version_name,''), 'code', sub.version_code::text)) end,
      'status_label', _c1922_status_label(sub.play_status),
      'status_tone',  _c1922_status_tone(sub.play_status),
      'rollout_label', case when sub.rollout_pct is null or sub.rollout_pct >= 100 then ''
                            else _cf('app_update_admin.rollout_label', jsonb_build_object(
                                   'pct', trim(to_char(sub.rollout_pct,'FM999990.##')))) end,
      'track_label',  case when coalesce(sub.play_track,'') = '' then ''
                           else _cf('app_update_admin.track_label',
                                    jsonb_build_object('track', sub.play_track)) end,
      'meta_label',   case when sub.submitted_at is null then ''
                           else _cf('app_update_admin.submitted_meta',
                                    jsonb_build_object('age', _ist_age(sub.submitted_at))) end),
    'checked_label', case when v_chk is null then _c('app_update_admin.never_checked')
                          else _cf('app_update_admin.checked_label',
                                   jsonb_build_object('age', _ist_age(v_chk))) end,
    'log_heading', _c('app_update_admin.log_heading'),
    'log_empty',   _c('app_update_admin.log_empty'),
    'log',         v_log);
end $function$;

-- ─── 10. grants (a SECURITY DEFINER function is open until it is closed) ────
revoke all on function public.app_published_release(text) from public, anon;
revoke all on function public.app_release_play_sync(jsonb, text, text) from public, anon, authenticated;
revoke all on function public.app_update_state(text) from public, anon;
revoke all on function public._c1922_status_label(text) from public, anon;
revoke all on function public._c1922_status_tone(text) from public, anon;
grant execute on function public.app_update_check(text, integer, text) to anon, authenticated;
grant execute on function public.app_update_state(text) to authenticated;
grant execute on function public.app_release_play_sync(jsonb, text, text) to service_role;
grant execute on function public.app_release_publish(text, integer, text, text, boolean, text, text) to authenticated, service_role;

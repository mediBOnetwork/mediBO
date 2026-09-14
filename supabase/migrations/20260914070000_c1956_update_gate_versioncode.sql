-- ============================================================================
-- CMD #1956 — the update popup compares versionCode, and only Play's own
--             answer about the PRODUCTION track may switch it on.
--
-- What was wrong (all four are the same root):
--
--   1. play_release 102/103/104 (app_releases 39/40/41) carry version_name
--      1.3.25 against version codes 43, 44 and 45. The release script derived
--      the NAME from the working tree and the CODE from Play. The shared
--      checkout is reset between commands, so the tree kept answering 1.3.24
--      and the name kept being "bumped" to the same 1.3.25 while the code
--      climbed. A name is therefore not an identity and must never decide
--      anything.
--
--   2. #1922 gated the prompt on play_status/rollout, which is right, but the
--      user-visible line still read "Version 1.3.25 is ready" — the same
--      sentence for four different builds, and for one Play was already
--      serving. A phone that tapped it landed on a Play page saying Open.
--
--   3. app_published_release() accepted any track. A version completed on
--      internal/beta could satisfy the gate while production served an older
--      build.
--
--   4. Play's real review state was never stored. play_status was inferred
--      from a mapping of the track status and nothing recorded what Play
--      itself said, so "is it actually reviewed" had no answer in the row.
--
-- After this file:
--   • the gate is  version_code > installed  AND  play_status = published
--     AND rollout_pct >= 100  AND play_track = the gate track (production)
--     AND play_review_status = 'completed'  — Play's own word, stored verbatim;
--   • app_release_next_version() is the ONE place a release number is decided,
--     code +1 and name patch +1 together, both derived from the database and
--     from Play's highest code, never from a working tree;
--   • "Not now" hides the prompt for dismiss_seconds (24 h) for THAT
--     version_code — the backend names the key and the window;
--   • rg behavior test release_version_name_unique goes red the moment two
--     release rows created from here on share a version_name.
--
-- Idempotent: guarded DDL, one-shot backfills marked in app_settings.
-- ============================================================================

-- ─── 1. what Play actually said ─────────────────────────────────────────────
alter table public.app_releases
  add column if not exists play_review_status text,
  add column if not exists play_raw           jsonb;

comment on column public.app_releases.play_review_status is
  'The Play Developer API release status VERBATIM (completed | inProgress | halted | draft | inReview). Written only by app_release_play_sync() from the API answer. The in-app prompt requires ''completed''.';
comment on column public.app_releases.play_raw is
  'The raw track payload the status was read from, kept so a wrong verdict can be traced to what Play returned.';

-- Rows already proven published by #1922 predate the column; Play had
-- completed them (that is what published+100% meant), so say so once.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'c1956_review_backfill') then
    update public.app_releases
       set play_review_status = 'completed'
     where play_status = 'published'
       and coalesce(rollout_pct, 100) >= 100
       and play_review_status is null;
    insert into public.app_settings(key, value)
    values ('c1956_review_backfill', jsonb_build_object('at', now(), 'change', 1956))
    on conflict (key) do nothing;
  end if;
end $$;

-- The historical duplicates are real history — Play genuinely served four
-- codes under the name 1.3.25 and rewriting them would be a lie. The guard
-- therefore ratchets from HERE: every release recorded from this code onward
-- must carry its own name. The watermark is data, so it is visible and can be
-- moved by an UPDATE if a future clean-up ever does dedupe the old rows.
insert into public.app_settings(key, value)
select 'c1956_name_unique_from',
       jsonb_build_object(
         'version_code', coalesce((select max(version_code) from public.app_releases
                                    where platform = 'android'), 0),
         'at', now(), 'change', 1956,
         'why', 'codes 43-46 all shipped as 1.3.25; those rows are history, not a regression')
on conflict (key) do nothing;

-- ─── 2. the gate track lives in config, not in a function body ─────────────
insert into public.app_settings(key, value)
values ('app_update_channel', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings
   set value = value
             || jsonb_build_object('gate_track', coalesce(value->>'gate_track', 'production'))
             || jsonb_build_object('dismiss_seconds',
                  coalesce((value->>'dismiss_seconds')::int, 86400))
 where key = 'app_update_channel';

-- ─── 3. copy — every word the phone or the panel shows ─────────────────────
insert into public.ui_copy(key, value) values
  ('app_update.version_label_code',    '"Version {name} ({code})"'::jsonb),
  ('app_update_admin.gate_heading',    '"Why the prompt is on or off"'::jsonb),
  ('app_update_admin.gate_code',       '"Newer build code than the phone"'::jsonb),
  ('app_update_admin.gate_status',     '"Play reports it published"'::jsonb),
  ('app_update_admin.gate_rollout',    '"Rolled out to 100% of users"'::jsonb),
  ('app_update_admin.gate_track',      '"On the {track} track"'::jsonb),
  ('app_update_admin.gate_review',     '"Play review completed"'::jsonb),
  ('app_update_admin.gate_met',        '"Met"'::jsonb),
  ('app_update_admin.gate_unmet',      '"Not yet"'::jsonb),
  ('app_update_admin.review_label',    '"Play says {state}"'::jsonb),
  ('app_update_admin.dismiss_note',    '"Not now hides the prompt for {hours} h for that build code. A newer code asks again."'::jsonb)
on conflict (key) do nothing;

-- The prompt line must name the CODE as well as the name — four builds shared
-- 1.3.25 and the sentence was identical for all of them.
update public.ui_copy set value = '"Version {name} ({code})"'::jsonb
 where key = 'app_update.version_label_code';

-- ─── 4. the dismissal, per version CODE ─────────────────────────────────────
-- The phone stores the backend's key against the moment it was tapped; the
-- backend owns the window. Nothing here is per-user: an anonymous phone has no
-- uid, and a 24 h silence is a device preference, not an account fact.
create or replace function public._c1956_dismiss_seconds()
returns integer language sql stable set search_path to 'public' as $$
  select greatest(coalesce(
    ((select value from app_settings where key='app_update_channel')->>'dismiss_seconds')::int,
    86400), 0);
$$;

-- ─── 5. the ONE definition of "Play is serving this to everybody" ───────────
-- version_code is the only comparison anywhere. version_name is cosmetic and
-- appears solely inside a sentence.
create or replace function public.app_published_release(p_platform text default 'android')
returns public.app_releases
language sql stable security definer set search_path to 'public' as $$
  select r.* from public.app_releases r
   where r.platform = coalesce(p_platform,'android')
     and r.play_status = 'published'
     and coalesce(r.rollout_pct, 0) >= 100
     and coalesce(r.play_track, '') = coalesce(nullif(btrim(coalesce(
           (select value->>'gate_track' from app_settings where key='app_update_channel'),'')),''),
           'production')
     and coalesce(r.play_review_status, '') = 'completed'
   order by r.version_code desc
   limit 1;
$$;

-- Every unmet condition, named, for the admin panel. Same predicate as above,
-- written once per clause so the screen can say WHICH one is holding it.
create or replace function public.app_update_gate_rows(p_platform text default 'android')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_plat  text := coalesce(p_platform,'android');
  v_gate  text := coalesce(nullif(btrim(coalesce(
                    (select value->>'gate_track' from app_settings where key='app_update_channel'),'')),''),
                    'production');
  sub     app_releases%rowtype;
  v_rows  jsonb := '[]'::jsonb;
begin
  select * into sub from app_releases where platform = v_plat
   order by version_code desc limit 1;
  if sub.id is null then return v_rows; end if;

  v_rows := jsonb_build_array(
    jsonb_build_object('label', _c('app_update_admin.gate_status'),
                       'met',   sub.play_status = 'published'),
    jsonb_build_object('label', _c('app_update_admin.gate_rollout'),
                       'met',   coalesce(sub.rollout_pct, 0) >= 100),
    jsonb_build_object('label', _cf('app_update_admin.gate_track',
                                    jsonb_build_object('track', v_gate)),
                       'met',   coalesce(sub.play_track,'') = v_gate),
    jsonb_build_object('label', _c('app_update_admin.gate_review'),
                       'met',   coalesce(sub.play_review_status,'') = 'completed'));

  return (select coalesce(jsonb_agg(
            r || jsonb_build_object(
              'value', case when (r->>'met')::boolean then _c('app_update_admin.gate_met')
                            else _c('app_update_admin.gate_unmet') end,
              'tone',  case when (r->>'met')::boolean then 'success' else 'warning' end)), '[]'::jsonb)
          from jsonb_array_elements(v_rows) r);
end $function$;

-- ─── 6. the phone's check — versionCode only, plus the 24 h window ──────────
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
  v_plat     text := coalesce(p_platform,'android');
begin
  -- CMD #1956: the ONLY comparison is version_code, against a release Play has
  -- completed, published and rolled out to 100 % on the gate track.
  r := public.app_published_release(v_plat);

  if r.id is null or coalesce(p_version_code, 0) >= r.version_code then
    return jsonb_build_object(
      'update_available', false,
      'current', coalesce(r.version_name, ''),
      'installed_code', coalesce(p_version_code, 0),
      'message', '',
      'dismiss_key', null,
      'dismiss_seconds', 0);
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
                              'installed_code', coalesce(p_version_code, 0),
                              'message', '', 'dismiss_key', null,
                              'dismiss_seconds', 0);
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
    'installed_code', coalesce(p_version_code, 0),
    -- The name alone named four different builds. The code is the identity, so
    -- the code is in the sentence.
    'version_label', _cf('app_update.version_label_code', jsonb_build_object(
                       'name', coalesce(r.version_name,''), 'code', r.version_code::text)),
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
    -- The key is the version CODE, so a newer code is a different key and asks
    -- again by itself; the window is the backend's, never the phone's.
    'dismiss_key',   case when r.is_mandatory then null
                          else 'app_update:' || v_plat || ':' || r.version_code end,
    'dismiss_seconds', case when r.is_mandatory then 0
                            else public._c1956_dismiss_seconds() end
  );
end $function$;

-- ─── 7. ONE place decides the next release number ───────────────────────────
-- The release script used to read the working tree for the name and Play for
-- the code. Five workers share that checkout, it is reset between commands,
-- and so the name never moved while the code did. Both now come from here.
--   • code = max(Play's highest, our highest) + 1
--   • name = patch + 1 of the name on OUR highest code, then advanced until it
--     collides with nothing already recorded.
-- Never one without the other, and never a name that is already in use.
create or replace function public.app_release_next_version(
  p_platform text default 'android', p_play_max_code integer default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_plat  text := coalesce(p_platform,'android');
  v_ours  int;
  v_code  int;
  v_name  text;
  v_base  text;
  v_ma    int; v_mi int; v_pa int;
  v_parts text[];
begin
  if not (
        coalesce(auth.jwt()->>'role','') = 'service_role'
     or get_my_role() in ('admin','super_admin')
     or (coalesce(current_setting('request.jwt.claims', true), '') = ''
         and session_user in ('postgres','supabase_admin'))
  ) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  select max(version_code) into v_ours from app_releases where platform = v_plat;
  v_code := greatest(coalesce(p_play_max_code, 0), coalesce(v_ours, 0)) + 1;

  select version_name into v_base from app_releases
   where platform = v_plat and version_name is not null and btrim(version_name) <> ''
   order by version_code desc limit 1;
  v_base := coalesce(nullif(btrim(coalesce(v_base,'')),''), '1.0.0');

  v_parts := string_to_array(regexp_replace(v_base, '[^0-9.].*$', ''), '.');
  v_ma := coalesce(nullif(v_parts[1],'')::int, 1);
  v_mi := coalesce(nullif(v_parts[2],'')::int, 0);
  v_pa := coalesce(nullif(v_parts[3],'')::int, 0);

  -- Bump the patch, then keep bumping until the name is genuinely unused: a
  -- name that already exists is what produced four 1.3.25 rows.
  loop
    v_pa := v_pa + 1;
    v_name := v_ma || '.' || v_mi || '.' || v_pa;
    exit when not exists (select 1 from app_releases
                           where platform = v_plat and version_name = v_name);
  end loop;

  return jsonb_build_object(
    'ok', true, 'platform', v_plat,
    'version_code', v_code, 'version_name', v_name,
    'from_name', v_base, 'our_max_code', coalesce(v_ours, 0),
    'play_max_code', coalesce(p_play_max_code, 0));
end $function$;

-- ─── 8. the poller stores what Play SAID, including the review state ────────
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
  v_newrev  text;
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
    return jsonb_build_object('ok', false, 'error','no_track_data',
                              'message','Play returned no track state — nothing changed');
  end if;

  select coalesce(array_agg(distinct c::int),'{}') into v_seen
    from jsonb_array_elements(p_tracks) t,
         jsonb_array_elements_text(coalesce(t->'version_codes','[]'::jsonb)) c
   where c ~ '^[0-9]+$';

  select t into v_pick from jsonb_array_elements(p_tracks) t
   where t->>'track' = v_gate limit 1;

  if v_pick is not null then
    v_raw    := nullif(btrim(coalesce(v_pick->>'status','')),'');
    v_name   := v_pick->>'version_name';
    v_frac   := nullif(v_pick->>'user_fraction','')::numeric;
    v_status := case v_raw
                  when 'completed'  then 'published'
                  when 'inProgress' then 'rollout'
                  when 'halted'     then 'halted'
                  when 'draft'      then 'in_review'
                  when 'inReview'   then 'in_review'
                  else 'unknown' end;
    v_roll := case when v_frac is null then (case when v_status='published' then 100 else null end)
                   else round(v_frac * 100, 2) end;
    -- A 100 % inProgress rollout is finished in every way that matters to a
    -- phone, but Play has NOT said 'completed', so the review clause below
    -- still holds the prompt shut until it does.
    if v_status = 'rollout' and coalesce(v_roll,0) >= 100 then v_status := 'published'; end if;

    select coalesce(array_agg(c::int),'{}') into v_codes
      from jsonb_array_elements_text(coalesce(v_pick->'version_codes','[]'::jsonb)) c
     where c ~ '^[0-9]+$';
    select max(x) into v_max from unnest(v_codes) x;
  end if;

  for r in select * from app_releases where platform = v_plat loop
    v_new := r.play_status; v_newroll := r.rollout_pct; v_newrev := r.play_review_status;

    if v_codes is not null and r.version_code = any(v_codes) then
      v_new := v_status; v_newroll := v_roll; v_newrev := v_raw;
    elsif v_max is not null and r.version_code > v_max then
      v_new := case when r.version_code = any(v_seen) then 'in_review' else r.play_status end;
      if r.play_status = 'published' then v_new := 'in_review'; end if;
      v_newroll := null;
      -- It is not on the gate track, so whatever Play once said about its
      -- review no longer describes what users are being served.
      v_newrev := null;
    end if;

    if v_new is distinct from r.play_status
       or v_newroll is distinct from r.rollout_pct
       or v_newrev is distinct from r.play_review_status then
      update app_releases
         set play_status = v_new,
             rollout_pct = v_newroll,
             play_review_status = v_newrev,
             play_raw    = case when r.version_code = any(coalesce(v_codes,'{}'))
                                then v_pick else play_raw end,
             play_track  = coalesce(case when r.version_code = any(coalesce(v_codes,'{}')) then v_gate end, play_track),
             play_published_at = case when v_new = 'published'
                                      then coalesce(play_published_at, now()) else play_published_at end,
             play_checked_at = now()
       where id = r.id;
      insert into app_release_play_log(platform, version_name, version_code, track,
                                       from_status, to_status, from_rollout, rollout_pct, source, note)
      values (v_plat, coalesce(r.version_name, v_name), r.version_code,
              case when r.version_code = any(coalesce(v_codes,'{}')) then v_gate else r.play_track end,
              r.play_status, v_new, r.rollout_pct, v_newroll, coalesce(p_source,'poller'),
              case when v_newrev is null then null else 'Play review state: ' || v_newrev end);
      v_changes := v_changes + 1;
    else
      update app_releases
         set play_checked_at = now(),
             play_raw = case when r.version_code = any(coalesce(v_codes,'{}'))
                             then v_pick else play_raw end
       where id = r.id;
    end if;
  end loop;

  if v_codes is not null and v_status is not null then
    insert into app_releases(platform, version_name, version_code, play_track,
                             play_status, rollout_pct, play_review_status, play_raw,
                             submitted_at, play_published_at, play_checked_at)
    select v_plat, coalesce(nullif(v_name,''), c::text), c, v_gate, v_status, v_roll, v_raw, v_pick, now(),
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
    'review_status', v_raw,
    'rollout_pct', v_roll,
    'transitions', v_changes,
    'published_code', (select version_code from app_published_release(v_plat)),
    'published_name', (select version_name from app_published_release(v_plat)),
    'checked_at', now());
end $function$;

-- ─── 9. the admin panel gains the gate checklist and the review word ────────
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
      'review_label', case when coalesce(sub.play_review_status,'') = '' then ''
                           else _cf('app_update_admin.review_label',
                                    jsonb_build_object('state', sub.play_review_status)) end,
      'rollout_label', case when sub.rollout_pct is null or sub.rollout_pct >= 100 then ''
                            else _cf('app_update_admin.rollout_label', jsonb_build_object(
                                   'pct', trim(to_char(sub.rollout_pct,'FM999990.##')))) end,
      'track_label',  case when coalesce(sub.play_track,'') = '' then ''
                           else _cf('app_update_admin.track_label',
                                    jsonb_build_object('track', sub.play_track)) end,
      'meta_label',   case when sub.submitted_at is null then ''
                           else _cf('app_update_admin.submitted_meta',
                                    jsonb_build_object('age', _ist_age(sub.submitted_at))) end),
    'gate', jsonb_build_object(
      'heading', _c('app_update_admin.gate_heading'),
      'rows',    public.app_update_gate_rows(v_plat),
      'note',    _cf('app_update_admin.dismiss_note', jsonb_build_object(
                   'hours', trim(to_char(public._c1956_dismiss_seconds() / 3600.0, 'FM999990.##'))))),
    'checked_label', case when v_chk is null then _c('app_update_admin.never_checked')
                          else _cf('app_update_admin.checked_label',
                                   jsonb_build_object('age', _ist_age(v_chk))) end,
    'log_heading', _c('app_update_admin.log_heading'),
    'log_empty',   _c('app_update_admin.log_empty'),
    'log',         v_log);
end $function$;

-- ─── 10. the guard: two releases may never share a name from here on ────────
insert into public.rg_behavior_tests(name, body, enabled, note)
values ('release_version_name_unique', '', true,
        'CMD #1956 — a version_name that names two builds made the update prompt offer a build Play was already serving.')
on conflict (name) do nothing;

update public.rg_behavior_tests
   set enabled = true,
       note = 'CMD #1956 — a version_name that names two builds made the update prompt offer a build Play was already serving.',
       body = $rgb$
do $vnu$
declare
  v_from int;
  v_dupe text;
begin
  -- Codes 43-46 genuinely shipped to Play as 1.3.25. That is history and is
  -- not rewritten; the guard ratchets from the watermark this change recorded.
  select coalesce((value->>'version_code')::int, 0) into v_from
    from public.app_settings where key = 'c1956_name_unique_from';
  v_from := coalesce(v_from, 0);

  select string_agg(t.line, '; ') into v_dupe from (
    select r.platform || ' ' || r.version_name || ' → codes ' ||
           string_agg(r.version_code::text, ',' order by r.version_code) as line
      from public.app_releases r
     where r.version_code > v_from
       and coalesce(btrim(r.version_name), '') <> ''
     group by r.platform, r.version_name
    having count(*) > 1) t;

  if v_dupe is not null then
    raise exception 'release_version_name_unique: two releases share a version_name — %. One bump function must move versionCode AND versionName together (app_release_next_version).', v_dupe;
  end if;

  -- The bump function itself must never be able to hand back a name in use.
  if exists (select 1 from public.app_releases a
              where a.platform = 'android'
                and a.version_name = (public.app_release_next_version('android', null)->>'version_name')) then
    raise exception 'release_version_name_unique: app_release_next_version() proposed a version_name that is already recorded';
  end if;
end $vnu$;
$rgb$
 where name = 'release_version_name_unique';

-- ─── 11. grants ─────────────────────────────────────────────────────────────
revoke all on function public.app_published_release(text) from public, anon;
revoke all on function public.app_update_gate_rows(text) from public, anon;
revoke all on function public.app_release_next_version(text, integer) from public, anon;
revoke all on function public._c1956_dismiss_seconds() from public, anon;
revoke all on function public.app_release_play_sync(jsonb, text, text) from public, anon, authenticated;
revoke all on function public.app_update_state(text) from public, anon;
grant execute on function public.app_update_check(text, integer, text) to anon, authenticated;
grant execute on function public.app_update_state(text) to authenticated;
grant execute on function public.app_update_gate_rows(text) to authenticated, service_role;
grant execute on function public.app_release_next_version(text, integer) to authenticated, service_role;
grant execute on function public.app_release_play_sync(jsonb, text, text) to service_role;

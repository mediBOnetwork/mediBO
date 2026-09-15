-- CHANGE #281 — three release buttons, and the state behind them.
--
-- #280 gave Om ONE button that built and shipped straight to production. That
-- is the wrong shape for a release he wants to hold in his hand first. #281
-- splits it into the flow a real release has:
--
--   1. "Test now"       → build the bundle and put it on Play's INTERNAL
--                         TESTING track. No Google review, live for testers in
--                         minutes, installed FROM Play so it is Play-signed and
--                         behaves exactly like production.
--   2. "Publish update" → PROMOTE that SAME uploaded bundle from internal to
--                         production and submit for review, full rollout.
--                         Never a rebuild: what ships is the artifact Om
--                         actually tested, byte for byte.
--   3. "Auto-publish"   → a config flag. ON: every successful build goes to
--                         internal AND is submitted to production. OFF
--                         (default): builds stop at internal and wait for
--                         button 2. Flipping it is an UPDATE, never a deploy.
--
-- Everything the screen prints is in here: captions, hints, status labels,
-- tones, the disabled reasons, the rollout percentage string, the "as of"
-- timestamp. The Dart file added by this change contains no display string and
-- makes no enable/disable decision of its own.
--
-- Idempotent by construction (#233): every object is if-not-exists /
-- create-or-replace, so a resumed worker re-applies this as a silent no-op.

-- ── 1. the queue learns about promotion ─────────────────────────────────────
-- A promote job carries no build: it names a version code Play already has and
-- the track it is moving from. kind is what publish_play.sh branches on.
alter table play_release add column if not exists kind                text not null default 'publish';
alter table play_release add column if not exists source_version_code int;
alter table play_release add column if not exists from_track          text;
alter table play_release add column if not exists queued_by_auto      boolean not null default false;

-- ── 2. the auto-publish flag lives in config, not in code ───────────────────
create table if not exists play_config (
  id           int primary key default 1,
  auto_publish boolean not null default false,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint play_config_singleton check (id = 1)
);
insert into play_config(id) values (1) on conflict (id) do nothing;
alter table play_config enable row level security;
drop policy if exists play_config_no_direct on play_config;
create policy play_config_no_direct on play_config for select using (false);

-- ── 3. what Play itself says about each track ───────────────────────────────
-- Never inferred from our own queue: this table only ever holds what the Play
-- Developer API returned, with the moment it was read. An empty/stale row
-- renders as "not read yet" rather than as a confident wrong answer.
create table if not exists play_track_state (
  track         text primary key,
  version_name  text,
  version_codes int[],
  status        text,          -- Play's own release status, verbatim
  user_fraction numeric,       -- Play's staged-rollout fraction (null = full)
  release_notes text,
  raw           jsonb not null default '{}'::jsonb,
  error         text,          -- the Play API error body, verbatim
  fetched_at    timestamptz not null default now()
);
alter table play_track_state enable row level security;
drop policy if exists play_track_state_no_direct on play_track_state;
create policy play_track_state_no_direct on play_track_state for select using (false);

-- ── 4. copy — every visible word ────────────────────────────────────────────
insert into ui_copy(key, value) values
  ('play.test_button',        '"Test now"'::jsonb),
  ('play.test_hint',          '"Builds the current code and puts it on Play internal testing. No Google review — installable from Play in a few minutes."'::jsonb),
  ('play.test_running',       '"Building for testers…"'::jsonb),
  ('play.promote_button',     '"Publish update"'::jsonb),
  ('play.promote_hint',       '"Sends the exact build you just tested to production, full rollout, and submits it for Google review. Nothing is rebuilt."'::jsonb),
  ('play.promote_running',    '"Submitting…"'::jsonb),
  ('play.promote_none',       '"Nothing on internal testing yet. Tap Test now first."'::jsonb),
  ('play.promote_ready_fmt',  '"Ready to publish: %s from internal testing."'::jsonb),
  ('play.promote_live_fmt',   '"%s is already on production."'::jsonb),
  ('play.auto_title',         '"Auto-publish"'::jsonb),
  ('play.auto_hint_on',       '"ON — every successful build goes to internal testing and is submitted to production automatically."'::jsonb),
  ('play.auto_hint_off',      '"OFF — builds stop at internal testing and wait for Publish update."'::jsonb),
  ('play.auto_on_label',      '"On"'::jsonb),
  ('play.auto_off_label',     '"Off"'::jsonb),
  ('play.tracks_heading',     '"Live on Google Play"'::jsonb),
  ('play.tracks_hint',        '"Read from the Google Play Developer API."'::jsonb),
  ('play.tracks_never',       '"Not read from Play yet. The builder refreshes this every couple of minutes."'::jsonb),
  ('play.track_empty',        '"No release on this track."'::jsonb),
  ('play.asof_fmt',           '"As of %s"'::jsonb),
  ('play.rollout_fmt',        '"%s%% rollout"'::jsonb),
  ('play.rollout_full',       '"Full rollout"'::jsonb),
  ('play.refresh_button',     '"Refresh from Play"'::jsonb),
  ('play.refresh_queued',     '"Refreshing from Google Play — this takes up to two minutes."'::jsonb),
  ('play.notes_heading_281',  '"Release notes for testers and Play (en-US)"'::jsonb),
  ('play.busy_hint',          '"A release is already running. It has to finish before another can start."'::jsonb)
on conflict (key) do nothing;

-- ── 5. small helpers ────────────────────────────────────────────────────────
create or replace function _play_track_label(p_track text)
returns text language sql immutable as $$
  select case p_track
    when 'internal'   then 'Internal testing'
    when 'alpha'      then 'Closed testing'
    when 'beta'       then 'Open testing'
    when 'production' then 'Production'
    else initcap(coalesce(p_track,'—')) end;
$$;

-- Play's own release status words, given a label and a tone. Anything Play
-- invents that we have not seen yet still renders — as its own word, title-cased.
create or replace function _play_review_block(p_status text)
returns jsonb language sql immutable as $$
  select case p_status
    when 'completed'   then jsonb_build_object('label','Live',            'tone','success')
    when 'inProgress'  then jsonb_build_object('label','Rolling out',     'tone','info')
    when 'draft'       then jsonb_build_object('label','Draft',           'tone','warning')
    when 'halted'      then jsonb_build_object('label','Halted',          'tone','danger')
    when 'inReview'    then jsonb_build_object('label','In Google review','tone','info')
    else jsonb_build_object(
           'label', coalesce(nullif(initcap(regexp_replace(coalesce(p_status,''),'([a-z])([A-Z])','\1 \2','g')),''),'—'),
           'tone','info')
  end;
$$;

-- ── 6. the runner's window onto the flag ────────────────────────────────────
create or replace function play_autopublish_get()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE v boolean;
BEGIN
  PERFORM _dev_guard();
  SELECT auto_publish INTO v FROM play_config WHERE id = 1;
  RETURN jsonb_build_object('ok', true, 'auto_publish', coalesce(v, false));
END $$;

create or replace function play_autopublish_set(p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v boolean;
BEGIN
  PERFORM _dev_guard();
  INSERT INTO play_config(id, auto_publish, updated_at, updated_by)
  VALUES (1, coalesce(p_on,false), now(), auth.uid())
  ON CONFLICT (id) DO UPDATE
    SET auto_publish = excluded.auto_publish,
        updated_at   = now(),
        updated_by   = excluded.updated_by
  RETURNING auto_publish INTO v;

  PERFORM _audit(_actor(), 'play_autopublish_set', '1',
                 jsonb_build_object('auto_publish', v));
  RETURN jsonb_build_object(
    'ok', true, 'auto_publish', v,
    'message', CASE WHEN v THEN _play_c('play.auto_hint_on',  'ON')
                    ELSE      _play_c('play.auto_hint_off', 'OFF') END);
END $$;

-- ── 7. button 1 — Test now (build → internal testing) ───────────────────────
create or replace function play_test_request(p_notes text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
BEGIN
  PERFORM _dev_guard();
  RETURN play_publish_request('internal', p_notes);
END $$;

-- ── 8. button 2 — Publish update (promote the tested bundle) ────────────────
-- The promotable code is what Play says is on internal testing, NOT what our
-- own queue believes it uploaded: if a release was pulled or replaced in the
-- console, we must promote what is actually there. A code already live on
-- production is not offered again.
create or replace function play_promotable()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with i as (select version_codes[array_length(version_codes,1)] as code,
                    version_name, release_notes, fetched_at
               from play_track_state where track = 'internal'),
       p as (select version_codes from play_track_state where track = 'production')
  select jsonb_build_object(
    'has',           coalesce((select code is not null from i), false),
    'version_code',  (select code from i),
    'version_name',  (select version_name from i),
    'release_notes', (select release_notes from i),
    'fetched_at',    (select fetched_at from i),
    'already_live',  coalesce((select (select code from i) = any(p.version_codes) from p), false));
$$;

create or replace function play_promote_request(p_notes text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_id bigint; v_p jsonb; v_code int; v_notes text;
BEGIN
  PERFORM _dev_guard();

  IF EXISTS (SELECT 1 FROM play_release
              WHERE status IN ('queued','building','uploading') AND kind <> 'refresh') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'busy',
      'message', _play_c('play.busy','A publish is already running.'));
  END IF;

  v_p    := play_promotable();
  v_code := (v_p->>'version_code')::int;
  IF v_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nothing_to_promote',
      'message', _play_c('play.promote_none',
                         'Nothing on internal testing yet. Tap Test now first.'));
  END IF;

  -- The notes Om is looking at win; otherwise reuse the notes the tested build
  -- already carries, so production says exactly what the tester saw.
  v_notes := coalesce(nullif(btrim(coalesce(p_notes,'')),''),
                      nullif(btrim(coalesce(v_p->>'release_notes','')),''),
                      (play_notes_generate()->>'notes'));

  INSERT INTO play_release(kind, track, from_track, source_version_code,
                           version_code, version_name, release_notes, requested_by)
  VALUES ('promote', 'production', 'internal', v_code,
          v_code, v_p->>'version_name', left(v_notes,500), auth.uid())
  RETURNING id INTO v_id;

  PERFORM _audit(_actor(), 'play_promote_request', v_id::text,
                 jsonb_build_object('version_code', v_code));
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'version_code', v_code,
    'message', _play_c('play.queued_note',
                       'Queued. The builder picks this up within a minute.'));
END $$;

-- ── 9. live track state — written by the runner, read by the screen ─────────
create or replace function play_tracks_write(p_tracks jsonb, p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE t jsonb; v_n int := 0;
BEGIN
  PERFORM _dev_guard();

  IF p_error IS NOT NULL AND btrim(p_error) <> '' THEN
    -- A failed read never overwrites the last good answer; it is recorded
    -- against every known track so the screen can say so verbatim.
    UPDATE play_track_state SET error = p_error, fetched_at = now();
    RETURN jsonb_build_object('ok', false, 'error', p_error);
  END IF;

  FOR t IN SELECT * FROM jsonb_array_elements(coalesce(p_tracks,'[]'::jsonb)) LOOP
    INSERT INTO play_track_state(track, version_name, version_codes, status,
                                 user_fraction, release_notes, raw, error, fetched_at)
    VALUES (
      t->>'track',
      t->>'version_name',
      CASE WHEN jsonb_typeof(t->'version_codes') = 'array'
           THEN (SELECT array_agg(x::int) FROM jsonb_array_elements_text(t->'version_codes') x)
           END,
      t->>'status',
      nullif(t->>'user_fraction','')::numeric,
      t->>'release_notes',
      coalesce(t->'raw','{}'::jsonb),
      null,
      now())
    ON CONFLICT (track) DO UPDATE SET
      version_name  = excluded.version_name,
      version_codes = excluded.version_codes,
      status        = excluded.status,
      user_fraction = excluded.user_fraction,
      release_notes = excluded.release_notes,
      raw           = excluded.raw,
      error         = null,
      fetched_at    = now();
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'tracks', v_n);
END $$;

-- Asking for a refresh is a queue row like any other, so it is serialised
-- behind whatever the builder is already doing and shows up in history-free
-- state. The builder answers it within one timer tick (~2 min).
create or replace function play_refresh_request()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_id bigint;
BEGIN
  PERFORM _dev_guard();
  IF EXISTS (SELECT 1 FROM play_release WHERE kind='refresh' AND status='queued') THEN
    RETURN jsonb_build_object('ok', true, 'queued', true,
      'message', _play_c('play.refresh_queued','Refreshing from Google Play.'));
  END IF;
  INSERT INTO play_release(kind, track, status, requested_by)
  VALUES ('refresh', 'production', 'queued', auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id,
    'message', _play_c('play.refresh_queued','Refreshing from Google Play.'));
END $$;

-- ── 10. one render-ready payload ────────────────────────────────────────────
-- play_state_core is the #280 body, unchanged in meaning; play_state is core +
-- everything #281 adds. Splitting it this way keeps both migrations valid
-- whatever order they land in.
create or replace function play_state_core(p_limit int default 20)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE
  v_live   record;
  v_active record;
  v_hist   jsonb;
BEGIN
  PERFORM _dev_guard();

  SELECT * INTO v_live FROM app_releases
   WHERE platform='android' ORDER BY version_code DESC LIMIT 1;

  SELECT * INTO v_active FROM play_release
   WHERE status IN ('queued','building','uploading') AND kind <> 'refresh'
   ORDER BY requested_at DESC LIMIT 1;

  SELECT coalesce(jsonb_agg(x ORDER BY x->>'requested_at' DESC), '[]'::jsonb) INTO v_hist
  FROM (
    SELECT jsonb_build_object(
             'id', p.id,
             'requested_at', p.requested_at,
             'when_label', _play_ist(coalesce(p.finished_at, p.requested_at)),
             'version_label', coalesce(p.version_name,'—') ||
                              coalesce(' ('||p.version_code||')',''),
             'track_label', _play_track_label(p.track),
             'kind', p.kind,
             'kind_label', case p.kind when 'promote' then 'Promoted'
                                       when 'refresh' then 'Refresh'
                                       else 'Built' end,
             'auto', p.queued_by_auto,
             'status', p.status,
             'status_label', _play_status_block(p.status, p.play_error)->>'label',
             'status_tone',  _play_status_block(p.status, p.play_error)->>'tone',
             'review_status', p.review_status,
             'release_notes', p.release_notes,
             'play_error', p.play_error,
             'apk_url', p.apk_url
           ) AS x
      FROM play_release p
     WHERE p.kind <> 'refresh'          -- housekeeping is not release history
     ORDER BY p.requested_at DESC
     LIMIT greatest(coalesce(p_limit,20), 1)
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'title',            _play_c('play.title','Play Store'),
    'subtitle',         _play_c('play.subtitle','Build, upload and submit to Google Play — no manual steps.'),
    'live_heading',     _play_c('play.live_heading','Live on Google Play'),
    'next_heading',     _play_c('play.next_heading','Next release'),
    'history_heading',  _play_c('play.history_heading','Recent publishes'),
    'notes_heading',    _play_c('play.notes_heading_281','Release notes for testers and Play (en-US)'),
    'notes_hint',       _play_c('play.notes_hint','Written automatically from what changed since the last release. Edit if you want.'),
    'error_heading',    _play_c('play.error_heading','Google Play said'),
    'empty_history',    _play_c('play.empty_history','Nothing published from here yet.'),
    'publish_button',   _play_c('play.publish_button','Publish to Play'),
    'publishing_button',_play_c('play.publishing_button','Publishing…'),
    'can_publish',      v_active IS NULL,
    'live', CASE WHEN v_live IS NULL THEN jsonb_build_object('has', false)
                 ELSE jsonb_build_object(
                   'has', true,
                   'version_label', v_live.version_name || ' (' || v_live.version_code || ')',
                   'when_label', _play_ist(v_live.released_at),
                   'notes', v_live.notes) END,
    'active', CASE WHEN v_active IS NULL THEN jsonb_build_object('has', false)
                   ELSE jsonb_build_object(
                     'has', true,
                     'id', v_active.id,
                     'status', v_active.status,
                     'status_label', _play_status_block(v_active.status, null)->>'label',
                     'status_tone',  _play_status_block(v_active.status, null)->>'tone',
                     'track_label', _play_track_label(v_active.track),
                     'release_notes', v_active.release_notes,
                     'log_tail', v_active.log_tail) END,
    'draft_notes', (play_notes_generate()->>'notes'),
    'history', v_hist
  );
END $$;

create or replace function play_state(p_limit int default 20)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE
  v      jsonb;
  v_auto boolean;
  v_busy boolean;
  v_prom jsonb;
  v_tracks jsonb;
  v_asof text;
  v_terr text;
BEGIN
  v := play_state_core(p_limit);            -- guards inside

  SELECT coalesce(auto_publish,false) INTO v_auto FROM play_config WHERE id = 1;
  v_auto := coalesce(v_auto, false);
  v_busy := (v->'active'->>'has') = 'true';
  v_prom := play_promotable();

  SELECT max(fetched_at), max(error) INTO v_asof, v_terr FROM (
    SELECT to_char(fetched_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM') || ' IST' AS fetched_at,
           error
      FROM play_track_state) z;

  -- Every track Play knows about, in release order, each with the numbers the
  -- Play API returned and nothing we made up.
  SELECT coalesce(jsonb_agg(x ORDER BY ord), '[]'::jsonb) INTO v_tracks FROM (
    SELECT
      CASE t.track WHEN 'internal' THEN 1 WHEN 'alpha' THEN 2
                   WHEN 'beta' THEN 3 WHEN 'production' THEN 4 ELSE 5 END AS ord,
      jsonb_build_object(
        'track',          t.track,
        'track_label',    _play_track_label(t.track),
        'has',            t.version_codes IS NOT NULL AND array_length(t.version_codes,1) > 0,
        'version_label',  coalesce(t.version_name,'—') ||
                          coalesce(' (' || t.version_codes[array_length(t.version_codes,1)] || ')',''),
        'version_code',   t.version_codes[array_length(t.version_codes,1)],
        'status',         t.status,
        'status_label',   _play_review_block(t.status)->>'label',
        'status_tone',    _play_review_block(t.status)->>'tone',
        -- An empty track has no rollout at all; saying "Full rollout" there
        -- would be the screen asserting something Play never said.
        'rollout_label',  CASE
            WHEN t.version_codes IS NULL OR array_length(t.version_codes,1) IS NULL THEN null
            WHEN t.user_fraction IS NULL THEN _play_c('play.rollout_full','Full rollout')
            ELSE format(_play_c('play.rollout_fmt','%s%% rollout'),
                        trim(trailing '.' from trim(trailing '0' from
                          to_char(t.user_fraction * 100,'FM990.99')))) END,
        'release_notes',  t.release_notes,
        'empty_label',    _play_c('play.track_empty','No release on this track.'),
        'error',          t.error
      ) AS x
      FROM play_track_state t) s;

  RETURN v || jsonb_build_object(
    'retry',           _play_c('play.retry','Retry'),

    -- button 1
    'test_button',     _play_c('play.test_button','Test now'),
    'test_running',    _play_c('play.test_running','Building for testers…'),
    'test_hint',       _play_c('play.test_hint',''),
    'can_test',        NOT v_busy,

    -- button 2
    'promote_button',  _play_c('play.promote_button','Publish update'),
    'promote_running', _play_c('play.promote_running','Submitting…'),
    'promote_hint',    _play_c('play.promote_hint',''),
    'can_promote',     (NOT v_busy)
                       AND (v_prom->>'version_code') IS NOT NULL
                       AND (v_prom->>'already_live') <> 'true',
    'promote_note',    CASE
        WHEN v_busy THEN _play_c('play.busy_hint','A release is already running.')
        WHEN (v_prom->>'version_code') IS NULL
          THEN _play_c('play.promote_none','Nothing on internal testing yet. Tap Test now first.')
        WHEN (v_prom->>'already_live') = 'true'
          THEN format(_play_c('play.promote_live_fmt','%s is already on production.'),
                      coalesce(v_prom->>'version_name','') ||
                      ' (' || (v_prom->>'version_code') || ')')
        ELSE format(_play_c('play.promote_ready_fmt','Ready to publish: %s from internal testing.'),
                    coalesce(v_prom->>'version_name','') ||
                    ' (' || (v_prom->>'version_code') || ')') END,
    'promotable',      v_prom,

    -- button 3
    'auto_title',      _play_c('play.auto_title','Auto-publish'),
    'auto_publish',    v_auto,
    'auto_state_label',CASE WHEN v_auto THEN _play_c('play.auto_on_label','On')
                           ELSE _play_c('play.auto_off_label','Off') END,
    'auto_hint',       CASE WHEN v_auto THEN _play_c('play.auto_hint_on','ON')
                           ELSE _play_c('play.auto_hint_off','OFF') END,

    -- live per-track state
    'tracks_heading',  _play_c('play.tracks_heading','Live on Google Play'),
    'tracks_hint',     _play_c('play.tracks_hint','Read from the Google Play Developer API.'),
    'tracks_never',    _play_c('play.tracks_never','Not read from Play yet.'),
    'refresh_button',  _play_c('play.refresh_button','Refresh from Play'),
    'tracks',          v_tracks,
    'tracks_asof',     CASE WHEN v_asof IS NULL THEN null
                            ELSE format(_play_c('play.asof_fmt','As of %s'), v_asof) END,
    'tracks_error',    v_terr
  );
END $$;

-- ── 11. the runner claims promote/refresh rows too ──────────────────────────
-- Same SKIP LOCKED claim; it now hands the script everything a promote needs so
-- the script never queries the queue itself.
create or replace function play_publish_claim(p_worker text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record; v_auto boolean;
BEGIN
  PERFORM _dev_guard();
  SELECT * INTO r FROM play_release
   WHERE status = 'queued'
   ORDER BY requested_at
   FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('empty', true); END IF;

  UPDATE play_release
     SET status='building', worker=p_worker, started_at=now(),
         play_error=null, review_status=null
   WHERE id = r.id;

  SELECT coalesce(auto_publish,false) INTO v_auto FROM play_config WHERE id = 1;

  RETURN jsonb_build_object('ok', true, 'id', r.id, 'track', r.track,
                            'kind', coalesce(r.kind,'publish'),
                            'from_track', r.from_track,
                            'source_version_code', r.source_version_code,
                            'auto_publish', coalesce(v_auto,false),
                            'release_notes', r.release_notes);
END $$;

-- The auto-publish chain: a successful internal build queues its own promote
-- when the flag is on, so nobody has to tap anything. The row it creates is
-- marked queued_by_auto, which is how the history says who asked.
create or replace function play_autochain(p_release_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record; v_auto boolean; v_id bigint;
BEGIN
  PERFORM _dev_guard();
  SELECT coalesce(auto_publish,false) INTO v_auto FROM play_config WHERE id = 1;
  IF NOT coalesce(v_auto,false) THEN
    RETURN jsonb_build_object('ok', true, 'chained', false, 'reason', 'auto_publish_off');
  END IF;

  SELECT * INTO r FROM play_release WHERE id = p_release_id;
  IF NOT FOUND OR r.status <> 'submitted' OR r.track <> 'internal'
     OR r.version_code IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'chained', false, 'reason', 'not_an_internal_success');
  END IF;

  INSERT INTO play_release(kind, track, from_track, source_version_code,
                           version_code, version_name, release_notes,
                           queued_by_auto, requested_by)
  VALUES ('promote', 'production', 'internal', r.version_code,
          r.version_code, r.version_name, r.release_notes, true, r.requested_by)
  RETURNING id INTO v_id;

  PERFORM _audit('runner', 'play_autochain', v_id::text,
                 jsonb_build_object('from', p_release_id, 'version_code', r.version_code));
  RETURN jsonb_build_object('ok', true, 'chained', true, 'id', v_id);
END $$;

-- ── 12. the #280 request keeps working, minus the refresh false-positive ────
-- A queued 'refresh' row must never read as "a publish is already running",
-- otherwise tapping Refresh from Play greys out both buttons for two minutes.
create or replace function play_publish_request(p_track text default 'production',
                                                p_notes text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_id bigint; v_notes text; v_gen jsonb; v_src jsonb;
BEGIN
  PERFORM _dev_guard();
  IF p_track NOT IN ('production','beta','alpha','internal') THEN
    RAISE EXCEPTION 'play: unknown track %', p_track;
  END IF;
  IF EXISTS (SELECT 1 FROM play_release
              WHERE status IN ('queued','building','uploading') AND kind <> 'refresh') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'busy',
                              'message', _play_c('play.busy','A publish is already running.'));
  END IF;

  v_gen   := play_notes_generate();
  v_notes := coalesce(nullif(btrim(coalesce(p_notes,'')),''), v_gen->>'notes');
  v_src   := coalesce(v_gen->'source','[]'::jsonb);

  INSERT INTO play_release(kind, track, release_notes, notes_source, requested_by)
  VALUES ('publish', p_track, left(v_notes,500), v_src, auth.uid())
  RETURNING id INTO v_id;

  PERFORM _audit(_actor(),'play_publish_request', v_id::text,
                 jsonb_build_object('track', p_track));
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'track', p_track,
                            'message', _play_c('play.queued_note',
                              'Queued. The builder picks this up within a minute.'));
END $$;

revoke all on function play_autopublish_set(boolean)      from anon;
revoke all on function play_test_request(text)            from anon;
revoke all on function play_promote_request(text)         from anon;
revoke all on function play_refresh_request()             from anon;
revoke all on function play_tracks_write(jsonb,text)      from anon, authenticated;
revoke all on function play_autochain(bigint)             from anon, authenticated;

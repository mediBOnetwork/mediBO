-- CHANGE #280 — Publish to Play automatically.
--
-- Om never uploads an AAB or types release notes by hand again. This migration
-- is the BACKEND half: the publish queue the runner drains, the release-notes
-- generator, and the one render-ready payload the Play Store screen prints
-- verbatim. No display string in this feature lives in Dart.
--
-- Idempotent by construction (#233): every object is create-if-not-exists /
-- create-or-replace, so a resumed worker re-applies it as a silent no-op.

-- ── the queue ───────────────────────────────────────────────────────────────
-- One row per publish attempt. The runner claims a 'queued' row, walks it
-- through the stages, and finishes it. Nothing here is computed in Dart.
create table if not exists play_release (
  id            bigserial primary key,
  status        text not null default 'queued',   -- queued|building|uploading|submitted|failed
  track         text not null default 'production',
  version_name  text,
  version_code  int,
  release_notes text,
  notes_source  jsonb not null default '[]'::jsonb, -- the commands the notes came from
  aab_bytes     bigint,
  apk_url       text,
  edit_id       text,
  review_status text,                              -- Play's own words, verbatim
  play_error    text,                              -- Play's error body, verbatim
  log_tail      text,
  worker        text,
  requested_by  uuid,
  requested_at  timestamptz not null default now(),
  started_at    timestamptz,
  finished_at   timestamptz
);

create index if not exists play_release_status_idx on play_release(status, requested_at);

alter table play_release enable row level security;
-- Reads/writes go through the SECURITY DEFINER RPCs below; no direct table access.
drop policy if exists play_release_no_direct on play_release;
create policy play_release_no_direct on play_release for select using (false);

-- ── copy (every visible string) ─────────────────────────────────────────────
insert into ui_copy(key, value) values
  ('play.title',              '"Play Store"'::jsonb),
  ('play.subtitle',           '"Build, upload and submit to Google Play — no manual steps."'::jsonb),
  ('play.live_heading',       '"Live on Google Play"'::jsonb),
  ('play.next_heading',       '"Next release"'::jsonb),
  ('play.history_heading',    '"Recent publishes"'::jsonb),
  ('play.notes_heading',      '"Release notes (en-US)"'::jsonb),
  ('play.publish_button',     '"Publish to Play"'::jsonb),
  ('play.publishing_button',  '"Publishing…"'::jsonb),
  ('play.queued_note',        '"Queued. The builder picks this up within a minute."'::jsonb),
  ('play.empty_history',      '"Nothing published from here yet. Tap Publish to Play to ship the current build."'::jsonb),
  ('play.error_heading',      '"Google Play said"'::jsonb),
  ('play.retry',              '"Retry"'::jsonb),
  ('play.busy',               '"A publish is already running."'::jsonb),
  ('play.notes_hint',         '"Written automatically from what changed since the last release. Edit if you want."'::jsonb),
  ('play.no_credential',      '"Play publishing is not configured on this machine yet."'::jsonb)
on conflict (key) do nothing;

create or replace function _play_c(p_key text, p_default text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select value #>> '{}' from ui_copy where key = p_key), p_default);
$$;

-- ── status → label + tone (backend decides how it looks) ────────────────────
create or replace function _play_status_block(p_status text, p_err text)
returns jsonb language sql immutable as $$
  select case p_status
    when 'queued'    then jsonb_build_object('label','Queued',              'tone','info')
    when 'building'  then jsonb_build_object('label','Building the bundle', 'tone','info')
    when 'uploading' then jsonb_build_object('label','Uploading to Play',   'tone','info')
    when 'submitted' then jsonb_build_object('label','Submitted for review','tone','success')
    when 'failed'    then jsonb_build_object('label','Failed',              'tone','danger')
    else                  jsonb_build_object('label', initcap(p_status),    'tone','info')
  end;
$$;

create or replace function _play_ist(p_ts timestamptz)
returns text language sql immutable as $$
  select case when p_ts is null then null
    else to_char(p_ts at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') || ' IST' end;
$$;

-- ── release notes, generated from what actually changed ─────────────────────
-- Source of truth = the dev-queue rows completed since the last release Play
-- accepted. plain_summary is Om's own plain-language field; title is the
-- fallback. Everything is trimmed to Play's 500-character body limit here, in
-- the backend, so the client never edits a string to make it fit.
create or replace function play_notes_generate(p_since_code int default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE
  v_since  timestamptz;
  v_rows   jsonb := '[]'::jsonb;
  v_lines  text[] := '{}';
  v_text   text;
  r        record;
BEGIN
  PERFORM _dev_guard();

  -- Everything completed since the last release we actually published.
  SELECT max(finished_at) INTO v_since
    FROM play_release
   WHERE status = 'submitted'
     AND (p_since_code IS NULL OR version_code <= p_since_code);
  IF v_since IS NULL THEN
    SELECT max(released_at) INTO v_since FROM app_releases WHERE platform = 'android';
  END IF;
  v_since := coalesce(v_since, now() - interval '30 days');

  FOR r IN
    SELECT id, title, plain_summary
      FROM dev_commands
     WHERE status = 'completed'
       AND finished_at > v_since
       AND coalesce(kind,'dev') <> 'gcp'
     ORDER BY finished_at DESC
     LIMIT 12
  LOOP
    -- One customer-facing line per change: the plain summary's first sentence,
    -- else the title. Runner shorthand ("CHANGE #x:", bullet markup) is stripped.
    v_text := coalesce(nullif(btrim(split_part(regexp_replace(
                  coalesce(r.plain_summary, ''), '[*•]+', '', 'g'), E'\n', 1)), ''), r.title);
    v_text := btrim(regexp_replace(v_text, '^(CHANGE\s*#?\d+\s*[:\-–]\s*)', '', 'i'));
    v_text := regexp_replace(v_text, '\s+', ' ', 'g');
    IF length(v_text) > 90 THEN v_text := left(v_text, 87) || '…'; END IF;
    IF length(v_text) > 3 THEN
      v_lines := v_lines || ('• ' || upper(left(v_text,1)) || substr(v_text,2));
      v_rows  := v_rows || jsonb_build_object('id', r.id, 'line', v_text);
    END IF;
    EXIT WHEN array_length(v_lines,1) >= 6;
  END LOOP;

  IF array_length(v_lines,1) IS NULL THEN
    v_lines := ARRAY['• Speed and stability improvements across the app.'];
  END IF;

  v_text := array_to_string(v_lines, E'\n');
  WHILE length(v_text) > 500 AND array_length(v_lines,1) > 1 LOOP
    v_lines := v_lines[1:array_length(v_lines,1)-1];
    v_text  := array_to_string(v_lines, E'\n');
  END LOOP;
  v_text := left(v_text, 500);

  RETURN jsonb_build_object('ok', true, 'notes', v_text, 'since', v_since, 'source', v_rows);
END $$;

-- ── request a publish (the app's button) ────────────────────────────────────
create or replace function play_publish_request(p_track text default 'production',
                                                p_notes text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_id bigint; v_notes text; v_gen jsonb; v_src jsonb;
BEGIN
  PERFORM _dev_guard();
  IF p_track NOT IN ('production','beta','alpha','internal') THEN
    RAISE EXCEPTION 'play: unknown track %', p_track;
  END IF;
  IF EXISTS (SELECT 1 FROM play_release WHERE status IN ('queued','building','uploading')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'busy',
                              'message', _play_c('play.busy','A publish is already running.'));
  END IF;

  v_gen   := play_notes_generate();
  v_notes := coalesce(nullif(btrim(coalesce(p_notes,'')),''), v_gen->>'notes');
  v_src   := coalesce(v_gen->'source','[]'::jsonb);

  INSERT INTO play_release(track, release_notes, notes_source, requested_by)
  VALUES (p_track, left(v_notes,500), v_src, auth.uid())
  RETURNING id INTO v_id;

  PERFORM _audit(_actor(),'play_publish_request', v_id::text,
                 jsonb_build_object('track', p_track));
  RETURN jsonb_build_object('ok', true, 'id', v_id,
                            'message', _play_c('play.queued_note',
                              'Queued. The builder picks this up within a minute.'));
END $$;

-- ── runner side ─────────────────────────────────────────────────────────────
create or replace function play_publish_claim(p_worker text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record;
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

  RETURN jsonb_build_object('ok', true, 'id', r.id, 'track', r.track,
                            'release_notes', r.release_notes);
END $$;

create or replace function play_publish_progress(p_id bigint, p_status text,
                                                 p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
BEGIN
  PERFORM _dev_guard();
  UPDATE play_release SET
    status        = coalesce(nullif(p_status,''), status),
    version_name  = coalesce(p_patch->>'version_name', version_name),
    version_code  = coalesce((p_patch->>'version_code')::int, version_code),
    release_notes = coalesce(p_patch->>'release_notes', release_notes),
    aab_bytes     = coalesce((p_patch->>'aab_bytes')::bigint, aab_bytes),
    apk_url       = coalesce(p_patch->>'apk_url', apk_url),
    edit_id       = coalesce(p_patch->>'edit_id', edit_id),
    review_status = coalesce(p_patch->>'review_status', review_status),
    log_tail      = coalesce(p_patch->>'log_tail', log_tail)
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Terminal call. On success it also writes the app_releases row, so the in-app
-- Android update reminder serves exactly the version Play just took.
create or replace function play_publish_finish(p_id bigint, p_ok boolean,
                                               p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record;
BEGIN
  PERFORM _dev_guard();

  UPDATE play_release SET
    status        = CASE WHEN p_ok THEN 'submitted' ELSE 'failed' END,
    version_name  = coalesce(p_patch->>'version_name', version_name),
    version_code  = coalesce((p_patch->>'version_code')::int, version_code),
    release_notes = coalesce(p_patch->>'release_notes', release_notes),
    aab_bytes     = coalesce((p_patch->>'aab_bytes')::bigint, aab_bytes),
    apk_url       = coalesce(p_patch->>'apk_url', apk_url),
    edit_id       = coalesce(p_patch->>'edit_id', edit_id),
    review_status = coalesce(p_patch->>'review_status', review_status),
    play_error    = coalesce(p_patch->>'play_error', play_error),
    log_tail      = coalesce(p_patch->>'log_tail', log_tail),
    finished_at   = now()
  WHERE id = p_id
  RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'play: release % not found', p_id; END IF;

  IF p_ok AND r.version_code IS NOT NULL THEN
    INSERT INTO app_releases(platform, version_name, version_code, apk_url, notes, is_mandatory)
    VALUES ('android', coalesce(r.version_name, r.version_code::text),
            r.version_code, r.apk_url, r.release_notes, false)
    ON CONFLICT DO NOTHING;
  END IF;

  PERFORM _audit('runner', CASE WHEN p_ok THEN 'play_publish_ok' ELSE 'play_publish_fail' END,
                 p_id::text, jsonb_build_object('version_code', r.version_code));
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'status', r.status);
END $$;

-- ── the one screen payload ──────────────────────────────────────────────────
create or replace function play_state(p_limit int default 20)
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
   WHERE status IN ('queued','building','uploading')
   ORDER BY requested_at DESC LIMIT 1;

  SELECT coalesce(jsonb_agg(x ORDER BY x->>'requested_at' DESC), '[]'::jsonb) INTO v_hist
  FROM (
    SELECT jsonb_build_object(
             'id', p.id,
             'requested_at', p.requested_at,
             'when_label', _play_ist(coalesce(p.finished_at, p.requested_at)),
             'version_label', coalesce(p.version_name,'—') ||
                              coalesce(' ('||p.version_code||')',''),
             'track_label', initcap(p.track),
             'status', p.status,
             'status_label', _play_status_block(p.status, p.play_error)->>'label',
             'status_tone',  _play_status_block(p.status, p.play_error)->>'tone',
             'review_status', p.review_status,
             'release_notes', p.release_notes,
             'play_error', p.play_error,
             'apk_url', p.apk_url
           ) AS x
      FROM play_release p
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
    'notes_heading',    _play_c('play.notes_heading','Release notes (en-US)'),
    'notes_hint',       _play_c('play.notes_hint','Written automatically from what changed since the last release. Edit if you want.'),
    'error_heading',    _play_c('play.error_heading','Google Play said'),
    'empty_history',    _play_c('play.empty_history','Nothing published from here yet. Tap Publish to Play to ship the current build.'),
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
                     'track_label', initcap(v_active.track),
                     'release_notes', v_active.release_notes,
                     'log_tail', v_active.log_tail) END,
    'draft_notes', (play_notes_generate()->>'notes'),
    'history', v_hist
  );
END $$;

revoke all on function play_publish_request(text,text)         from anon;
revoke all on function play_publish_claim(text)                from anon, authenticated;
revoke all on function play_publish_progress(bigint,text,jsonb) from anon, authenticated;
revoke all on function play_publish_finish(bigint,boolean,jsonb) from anon, authenticated;

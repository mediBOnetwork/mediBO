-- CHANGE #280 (e) — the error state needs a way out, and its label is a backend
-- string like every other word on the screen.
--
-- play_state() returned error_heading but no retry caption, so the screen's
-- error card had nothing to print on its button — a dead end only a page reload
-- escaped (design QA check 6: an error shows backend copy AND a Retry). The
-- whole function is restated here rather than wrapped, so re-applying the
-- migrations in any order still lands on this definition.
delete from ui_copy where key = 'play.retry_x';

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
    'retry',            _play_c('play.retry','Retry'),
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

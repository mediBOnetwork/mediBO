-- CHANGE #280 (d) — the app_releases row must always end up describing the
-- release Play actually took.
--
-- app_releases carries a UNIQUE (platform, version_code) index, so the first
-- cut's `ON CONFLICT DO NOTHING` silently skipped the write when a row for that
-- code already existed (it did: #279 had inserted 1.3.11/24 by hand ~19 minutes
-- before the first automated publish). No duplicate — but also no guarantee the
-- in-app reminder points at the artifact that was actually published.
--
-- Upsert instead: the version that reached Play owns the row. A hand-written
-- note is only replaced when this publish has one of its own.

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
    ON CONFLICT (platform, version_code) DO UPDATE SET
      version_name = excluded.version_name,
      apk_url      = coalesce(excluded.apk_url, app_releases.apk_url),
      notes        = coalesce(excluded.notes,   app_releases.notes);
  END IF;

  PERFORM _audit('runner', CASE WHEN p_ok THEN 'play_publish_ok' ELSE 'play_publish_fail' END,
                 p_id::text, jsonb_build_object('version_code', r.version_code));
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'status', r.status);
END $$;

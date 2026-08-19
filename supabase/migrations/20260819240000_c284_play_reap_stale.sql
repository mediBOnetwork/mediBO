-- CHANGE #284 (debug pass on #280) — a publish that dies mid-flight must not
-- lock the Play Store screen forever.
--
-- WHAT BROKE. play_release #3 sat at status='building' from 19:54 with
-- finished_at NULL: publish_play.sh got as far as "uploading to Play" and then
-- vanished (the box was running four workers at load 3.5). Nothing in the
-- system ever writes a terminal status for a run that is killed rather than
-- failed, and both doors downstream read that status:
--   * play_state().active is the newest row IN ('queued','building','uploading')
--     → the screen shows "Building the bundle" with no error and no Retry, and
--       can_publish is false, so the Publish button stays disabled;
--   * play_publish_request() returns busy for the same set → every future
--     publish is refused with "A publish is already running."
-- So one killed run permanently disables the feature. Om restarts this VM daily
-- for the 5h limit (CHANGE #233), which makes that a matter of when, not if.
--
-- THE FIX is a reaper that is independent of play_state(): it writes a terminal
-- status onto the ROW, so it holds no matter which command last redefined the
-- read path (#280 and #281 have each replaced play_state already). Both doors
-- above then open by themselves, and the existing error card + Retry — already
-- built by #280 and rendering play_error verbatim — becomes the way out.
--
-- Staleness is measured from started_at (requested_at for a row never claimed),
-- NOT from a progress heartbeat: publish_play.sh belongs to another in-flight
-- command right now and this must not depend on editing it. A real publish
-- takes ~7 min end to end (19:15:46 → 19:22:05 for 1.3.11), so 30 min is a
-- wide margin over the slowest honest run.

insert into ui_copy (key, value) values
  ('play.stale_error',
   '"The publish stopped without reporting back — the builder was restarted or lost its connection. Nothing was sent to Google Play. Tap Retry to run it again."'::jsonb)
on conflict (key) do nothing;

-- ── the reaper ──────────────────────────────────────────────────────────────
-- No _dev_guard(): pg_cron carries no JWT, so the guard would raise on every
-- tick. Execute is revoked from anon/authenticated instead, which leaves
-- service_role (the runner) and the cron owner.
create or replace function play_reap_stale(p_minutes int default 30)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_ids bigint[];
BEGIN
  WITH upd AS (
    UPDATE play_release
       SET status      = 'failed',
           play_error  = coalesce(play_error, _play_c('play.stale_error',
                           'The publish stopped without reporting back.')),
           finished_at = now()
     WHERE status IN ('queued','building','uploading')
       AND coalesce(started_at, requested_at)
             < now() - make_interval(mins => greatest(coalesce(p_minutes,30), 1))
    RETURNING id
  )
  SELECT coalesce(array_agg(id), '{}'::bigint[]) INTO v_ids FROM upd;

  RETURN jsonb_build_object('ok', true,
                            'reaped', coalesce(array_length(v_ids,1), 0),
                            'ids', coalesce(to_jsonb(v_ids), '[]'::jsonb));
END $$;

revoke all on function play_reap_stale(int) from anon, authenticated;

-- ── schedule ────────────────────────────────────────────────────────────────
-- Minutes 24/39/54. NEVER a bare */N: the 2026-08-18 outage was 35 pg_cron jobs
-- all starting on minute 0 taking every one of the 60 connection slots. Those
-- three minutes currently carry only cron-dispatch and one */2 job.
select cron.unschedule('play-reap-stale')
 where exists (select 1 from cron.job where jobname = 'play-reap-stale');

select cron.schedule('play-reap-stale', '24-59/15 * * * *',
                     $cron$select play_reap_stale(30)$cron$);

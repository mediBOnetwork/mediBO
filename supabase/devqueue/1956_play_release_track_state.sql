-- CMD #1956 — what PLAY says about a release, on the release row itself
-- (control plane: dev-queue project only).
-- This file is NOT replayed by the deploy lane (migration_replay.sh only runs
-- supabase/migrations/ against production). It is applied by hand with:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/devqueue/1956_play_release_track_state.sql
-- It is idempotent; re-running it is a no-op.
--
-- play_release.review_status was filled from the UPLOAD's own reply — the
-- edit we had just committed, echoed back. That is not the track state: Play
-- reviews afterwards, and a staged rollout reaches 1 % before it reaches
-- everyone. publish_play.sh now POLLS the Play Developer API after publishing
-- (refresh_tracks) and writes the answer here, so the release row records what
-- Play reports rather than what we sent.

begin;

alter table public.play_release
  add column if not exists play_status      text,
  add column if not exists play_rollout_pct numeric,
  add column if not exists play_review      text,
  add column if not exists play_track_name  text,
  add column if not exists play_checked_at  timestamptz;

comment on column public.play_release.play_status is
  'CMD #1956 — mediBO''s reading of the Play track state (published | rollout | in_review | halted | unknown), polled after publish. Never inferred from the upload reply.';
comment on column public.play_release.play_rollout_pct is
  'CMD #1956 — Play''s userFraction for this track, as a percentage. NULL means Play did not report one.';
comment on column public.play_release.play_review is
  'CMD #1956 — the Play release status VERBATIM (completed | inProgress | halted | draft | inReview).';
comment on column public.play_release.play_checked_at is
  'CMD #1956 — when the Play Developer API was last read for this row.';

create index if not exists idx_play_release_version_name
  on public.play_release(version_name);

-- The same rule the production guard enforces, said where the release is
-- actually created: two release rows must never share a version name. History
-- (codes 43-46, all 1.3.25) is left alone; the watermark is the highest code
-- that existed when this ran.
create table if not exists public.play_release_name_watermark (
  id            int primary key default 1,
  version_code  int not null,
  set_at        timestamptz not null default now(),
  note          text,
  constraint play_release_name_watermark_one_row check (id = 1)
);

insert into public.play_release_name_watermark(id, version_code, note)
select 1, coalesce((select max(version_code) from public.play_release), 0),
       'CMD #1956 — codes 43-46 all shipped as 1.3.25; those rows are history, not a regression'
on conflict (id) do nothing;

-- The progress RPC must be able to WRITE the polled state, or the columns above
-- stay null forever. Unknown patch keys were silently dropped — that is how a
-- "stored" field can be added and never land. p_status='' keeps the row's own
-- workflow status: a track poll reports on Play, it does not advance the queue.
create or replace function public.play_publish_progress(
  p_id bigint, p_status text, p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  perform _dev_guard();
  update play_release set
    status           = coalesce(nullif(p_status,''), status),
    version_name     = coalesce(p_patch->>'version_name', version_name),
    version_code     = coalesce((p_patch->>'version_code')::int, version_code),
    release_notes    = coalesce(p_patch->>'release_notes', release_notes),
    aab_bytes        = coalesce((p_patch->>'aab_bytes')::bigint, aab_bytes),
    apk_url          = coalesce(p_patch->>'apk_url', apk_url),
    edit_id          = coalesce(p_patch->>'edit_id', edit_id),
    review_status    = coalesce(p_patch->>'review_status', review_status),
    log_tail         = coalesce(p_patch->>'log_tail', log_tail),
    -- CMD #1956 — polled from the Play Developer API, never from the upload.
    play_status      = coalesce(p_patch->>'play_status', play_status),
    play_rollout_pct = coalesce((p_patch->>'play_rollout_pct')::numeric, play_rollout_pct),
    play_review      = coalesce(p_patch->>'play_review', play_review),
    play_track_name  = coalesce(p_patch->>'play_track_name', play_track_name),
    play_checked_at  = coalesce((p_patch->>'play_checked_at')::timestamptz, play_checked_at)
  where id = p_id;
  return jsonb_build_object('ok', true);
end $function$;

commit;

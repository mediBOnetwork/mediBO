-- CHANGE #464 (lane unblock): 'unknown' is not a build identity.
--
-- lib/boot_env_stub.dart (the ANDROID boot surface) has no browser fetch, so
-- main.dart's /version.json read always throws there and falls back to
-- RenderLog.setBuildHash('unknown'). That non-empty literal was authoritative
-- here: every Android session overwrote the web build hash on the SHARED
-- singleton row AND reset the data blob. verify_live.sh polls render-log for
-- build == the deployed commit, so it could never confirm — batches 987, 988
-- and 989 each deployed successfully and were then expired by
-- deploy_lane_sweep while verify_live.sh looped, blocking the whole lane.
--
-- 'unknown' now means exactly what '' means: "this writer does not know the
-- build" — it merges its keys and leaves build_hash alone. A real hash still
-- wins and still resets the log, so a new build can never be judged on stale
-- keys. Idempotent: create or replace.
create or replace function public.render_log_note(p_build text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  -- '' and 'unknown' are both "no build identity".
  v_build text := nullif(nullif(btrim(coalesce(p_build, '')), ''), 'unknown');
begin
  insert into render_log (id, build_hash, data, updated_at)
  values ('singleton', coalesce(v_build, 'unknown'),
          coalesce(p_data, '{}'::jsonb), now())
  on conflict (id) do update
    set data = case
                 -- New build => start a clean log, so stale keys can never be
                 -- mistaken for evidence about the build under test.
                 when v_build is not null
                      and render_log.build_hash is distinct from v_build
                   then coalesce(p_data, '{}'::jsonb)
                 else render_log.data || coalesce(p_data, '{}'::jsonb)
               end,
        build_hash = coalesce(v_build, render_log.build_hash),
        updated_at = now();
end;
$function$;

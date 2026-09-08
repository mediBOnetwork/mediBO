-- CMD #1895d — the home rail served a pre-#1895 card, and would have forever.
--
-- CHANGE #1290 put the new card everywhere the payload is built on demand
-- (storefront_page, storefront_search_page, the PDP). The HOME rail is served
-- from storefront_home_cache, and its rows still carried the old card_price:
-- no price_display, no sale_label, no colours — so CardPriceLines had nothing
-- to draw and every home card ended at the MRP. Proven on live: the same
-- product returns the new block from storefront_page and the old one from
-- storefront_home_v2.
--
-- It is not a stale-by-minutes problem, it is a stale-forever one. Read the
-- cache gate in storefront_home_v2:
--
--     if v_cached is null or (v_zone is not null and v_built < now() - '10 min')
--
-- An ANONYMOUS caller — every visitor who has not signed in — deliberately
-- never rebuilds inline, because the anon role has a 3 s statement budget and
-- the build takes 2-4 s. That is correct: the comment says the warm tick keeps
-- those rows fresh. storefront_home_warm_tick() is written and does exactly
-- that (refresh anon rows older than 8 minutes, drop anything past an hour).
--
-- Nothing calls it. There is no cron_task row for it, so it has never run, and
-- an anon home payload has been frozen at whatever it was when some visitor
-- last cold-built it. Every future change to the card payload would have been
-- invisible on the home screen in the same way.
--
-- So: register the tick, and rebuild what is cached now so the home is right
-- immediately instead of at the next tick.
--
-- Idempotent: on-conflict on the task, and the rebuild recomputes from the
-- current builder rather than patching the stored json.

-- ── 1. the tick that was never scheduled ───────────────────────────────────
insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, enabled, dml,
   base_interval_s, max_interval_s, note)
values
  ('c1895-storefront-home-warm', 330, 'poll',
   -- Only when there is something to do: an anon row older than the tick's own
   -- 8-minute window, or no anon row at all.
   $g$select exists (select 1 from public.storefront_home_cache
                      where cache_key like 'anon:%'
                        and built_at < now() - interval '8 minutes')$g$,
   $w$select public.storefront_home_warm_tick()$w$,
   true, true, 240, 900,
   'CMD #1895d — storefront_home_warm_tick() existed since the home cache did but was never registered, so anon home payloads never refreshed and the home rail served a pre-#1895 card indefinitely.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      enabled = true, base_interval_s = excluded.base_interval_s,
      max_interval_s = excluded.max_interval_s, note = excluded.note;

-- ── 2. make the home right now, not at the next tick ───────────────────────
-- Rebuilt, not deleted: deleting would make the next anonymous visitor pay the
-- 2-4 s cold build against a 3 s budget, which is the Retry screen the cache
-- exists to prevent. Capped so a replay cannot run long.
do $$
declare r record; v_payload jsonb; v_ords jsonb; v_n int; v_done int := 0;
begin
  for r in select cache_key from public.storefront_home_cache
            where cache_key like 'anon:%' order by built_at desc limit 4
  loop
    begin
      v_n := nullif(split_part(r.cache_key, ':', 2), '')::int;
      if v_n is null then continue; end if;
      v_payload := public._storefront_home_build(v_n);
      v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
      v_payload := v_payload - '_ords';
      update public.storefront_home_cache
         set payload = v_payload, ords = v_ords, built_at = now()
       where cache_key = r.cache_key;
      v_done := v_done + 1;
    exception when others then
      -- A cache row that will not rebuild is not worth failing a deploy over:
      -- the tick registered above will get it within the minute.
      null;
    end;
  end loop;
  raise notice 'c1895d: rebuilt % anon home cache row(s)', v_done;
end $$;

-- Anything older than the rebuilt set is dropped rather than left serving the
-- old shape: with no row, storefront_home_v2 cold-builds, which is correct if
-- slower, and the tick refills it.
delete from public.storefront_home_cache
 where cache_key like 'anon:%' and built_at < now() - interval '10 minutes';

-- DB CHOKE — ROOT CAUSE FIX
--
-- Symptom: Cloudflare 520/522, "job startup timeout" from pg_cron, curl_exit 28
-- transport blackouts from the runner fleet (11:16, 13:45, 15:41 on 2026-09-02),
-- and db_health_sample rows showing 43/60 connections with 19 sessions blocked
-- on Lock and a longest_query_s of 593.
--
-- Cause, in order of size:
--
-- 1. refresh_storefront_feed() disabled its own statement timeout
--    (set_config('statement_timeout','0',true)) and then full-scanned the
--    563k-row / 1.4 GB "MEDICINE" table into a temp table, inside the
--    every-minute cron_dispatch() transaction. work_mem is 3.5 MB, so the temp
--    table spilled to disk. Observed transactions of 1172 s, 1631 s and 2529 s.
--    A transaction that long also blocks autovacuum on MEDICINE for its whole
--    duration, which is why the visibility map goes stale and every later scan
--    costs more. Now bounded at 240 s.
--
-- 2. refresh_sf_avail_counts() looped over ALL rows of zones, including the
--    synthetic row id=99 code='tst' (is_active=false, is_synthetic=true) that a
--    test run left behind on 2026-09-01. It built the column name z_tst_sup,
--    which does not exist, so the refresh raised AFTER paying the full scan
--    above, rolled back, left job_dirty_state.dirty=true, and retried forever.
--    Now filters to active non-synthetic zones and skips any zone whose column
--    is missing instead of raising.
--
-- Also: lead_pipeline_refresh() carried SET statement_timeout=300s in proconfig.
-- A nested function's SET re-arms the timer on entry, so it silently overrode the
-- dispatcher's own per-task step_timeout_ms - measured max run 94 s against a
-- 55 s cap. Bounded to 120 s (above the observed max, 2.5x below the old cap).
--
-- 3. It also ran count(*) over "MEDICINE" once per zone. RULES.md is explicit:
--    never count(*) the 563k-row table on a recurring path. The per-zone counts
--    stay (they are array-length filtered and cannot come from the cache) but
--    the zone_id=0 total now reads medicine_count_cache.

CREATE OR REPLACE FUNCTION public.refresh_sf_avail_counts()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare z record; c bigint; v_total bigint; v_col text;
begin
  -- Total comes from the count cache, never from a fresh count(*) over 563k rows.
  select total into v_total from public.medicine_count_cache limit 1;
  if v_total is null then
    select count(*) into v_total from "MEDICINE";
  end if;

  insert into public.sf_avail_counts(zone_id, cnt, updated_at)
    values (0, v_total, now())
    on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();

  -- Only real zones. A synthetic or retired zone has no z_<code>_sup column,
  -- and must never be able to abort the whole storefront refresh.
  for z in
    select id, code from public.zones
     where is_active and not coalesce(is_synthetic, false)
  loop
    v_col := 'z_' || z.code || '_sup';

    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'MEDICINE'
         and column_name = v_col
    ) then
      continue;
    end if;

    execute format('select count(*) from "MEDICINE" where coalesce(array_length(%I,1),0) > 0', v_col)
      into c;

    insert into public.sf_avail_counts(zone_id, cnt, updated_at)
      values (z.id, coalesce(c,0), now())
      on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();
  end loop;
end
$function$;

-- The unbounded timeout is the single worst thing on this instance: it is what
-- turns a slow refresh into a 42-minute transaction that starves every other
-- session. Bounded, it fails fast and the dispatcher records the error.
CREATE OR REPLACE FUNCTION public.refresh_storefront_feed()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  if not pg_try_advisory_lock(778899001) then return; end if;
  perform set_config('statement_timeout', '240s', true);

  create temp table _all on commit drop as
    select id,
           coalesce(nullif(btrim(therapeutic_class), ''), 'OTHERS') as cat,
           (buyable
             and image_url_1 is not null
             and btrim(image_url_1) <> ''
             and image_url_1 not ilike '%drive.google.com%'
             and coalesce(nullif(regexp_replace(mrp::text,'[^0-9.]','','g'),'')::numeric, 0) > 0
           ) as feed_ok,
           sales_count
    from "MEDICINE";

  create temp table _ranked on commit drop as
    select id, cat,
           row_number() over (
             partition by lower(cat)
             order by sales_count desc nulls last, md5(id::text)) as rn
    from _all
    where feed_ok;

  delete from public.storefront_feed;

  insert into public.storefront_feed (category, rank, product_id)
  select 'All',
         row_number() over (order by rn, lower(cat)),
         id
  from _ranked;

  insert into public.storefront_feed (category, rank, product_id)
  select cat, rn, id from _ranked;

  delete from public.storefront_feed_meta;
  insert into public.storefront_feed_meta (category, total)
  select 'All', count(*) from _ranked
  union all
  select cat, count(*) from _ranked group by cat;

  perform public.refresh_sf_avail_counts();
  perform pg_advisory_unlock(778899001);
end
$function$;

ALTER FUNCTION public.lead_pipeline_refresh() SET statement_timeout='120s';

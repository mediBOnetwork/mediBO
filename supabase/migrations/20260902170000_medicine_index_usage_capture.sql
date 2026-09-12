-- 7-DAY INDEX USAGE CAPTURE ON "MEDICINE"
--
-- "MEDICINE" carries 36 indexes over a 1.4 GB heap; the index set alone is
-- 1.43 GB, of which five GIN trigram indexes are ~829 MB. Every UPDATE rewrites
-- an entry in each applicable index, which is why a 40k-row zone backfill batch
-- could run for 107 s. There are obvious duplicate pairs, but idx_scan counters
-- were wiped by the 2026-09-02 restart, so nothing can be dropped on evidence
-- yet. This captures that evidence.
--
-- Snapshot semantics: pg_stat_user_indexes counters are CUMULATIVE and reset to
-- zero on a crash-restart. We store the raw cumulative value each hour and
-- compute usage as the sum of positive deltas, so a restart costs one interval
-- instead of corrupting the whole window. A restart is recorded, not hidden.

create table if not exists public.medicine_index_usage_sample (
  at            timestamptz not null default date_trunc('hour', now()),
  index_name    text        not null,
  idx_scan      bigint      not null,
  idx_tup_read  bigint      not null,
  idx_tup_fetch bigint      not null,
  size_bytes    bigint      not null,
  primary key (at, index_name)
);

comment on table public.medicine_index_usage_sample is
  'Hourly cumulative pg_stat_user_indexes snapshot for "MEDICINE". Feeds medicine_index_usage_report(); safe to drop once the index diet is decided.';

create or replace function public.medicine_index_usage_snapshot()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare v_rows int;
begin
  insert into public.medicine_index_usage_sample
        (at, index_name, idx_scan, idx_tup_read, idx_tup_fetch, size_bytes)
  select date_trunc('hour', now()), i.indexrelname,
         i.idx_scan, i.idx_tup_read, i.idx_tup_fetch,
         pg_relation_size(i.indexrelid)
    from pg_stat_user_indexes i
   where i.relname = 'MEDICINE'
  on conflict (at, index_name) do update
     set idx_scan      = excluded.idx_scan,
         idx_tup_read  = excluded.idx_tup_read,
         idx_tup_fetch = excluded.idx_tup_fetch,
         size_bytes    = excluded.size_bytes;

  get diagnostics v_rows = ROW_COUNT;

  -- 60 days of hourly rows for 36 indexes is ~52k rows. Keep it bounded anyway.
  delete from public.medicine_index_usage_sample where at < now() - interval '60 days';

  return jsonb_build_object('ok', true, 'indexes', v_rows, 'at', date_trunc('hour', now()));
end
$function$;

-- The verdict. An index is only DROP-eligible when the whole observed window is
-- long enough to have seen the weekly jobs (medicine_vacuum_weekly runs Sunday,
-- the nightly catalogue refreshes run 03:10-04:10 IST) AND it took zero scans
-- across every interval in that window. Anything else is "keep".
create or replace function public.medicine_index_usage_report()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare v_first timestamptz; v_last timestamptz; v_days numeric; v_resets int;
begin
  select min(at), max(at) into v_first, v_last from public.medicine_index_usage_sample;
  if v_first is null then
    return jsonb_build_object('ok', false, 'reason', 'no samples yet');
  end if;
  v_days := round(extract(epoch from (v_last - v_first)) / 86400.0, 2);

  return (
    with d as (
      select index_name, at, idx_scan, size_bytes,
             idx_scan - lag(idx_scan) over (partition by index_name order by at) as delta
        from public.medicine_index_usage_sample
    ),
    agg as (
      select index_name,
             -- a negative delta is a counter reset: count it, never subtract it
             sum(greatest(coalesce(delta,0), 0))            as scans_in_window,
             count(*) filter (where delta < 0)              as resets,
             max(size_bytes)                                as size_bytes,
             max(idx_scan)                                  as last_cumulative
        from d group by index_name
    )
    select jsonb_build_object(
      'ok', true,
      'window_days', v_days,
      'window_complete', v_days >= 7,
      'first_sample', v_first,
      'last_sample',  v_last,
      'total_index_bytes', (select sum(size_bytes) from agg),
      'drop_eligible', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'index', a.index_name,
                 'size',  pg_size_pretty(a.size_bytes),
                 'bytes', a.size_bytes,
                 'def',   pg_get_indexdef(('public.'||quote_ident(a.index_name))::regclass))
                 order by a.size_bytes desc)
          from agg a
         where v_days >= 7
           and a.scans_in_window = 0
           and a.last_cumulative = 0
           -- never propose the primary key or a unique constraint
           and not exists (select 1 from pg_index x
                            where x.indexrelid = ('public.'||quote_ident(a.index_name))::regclass
                              and (x.indisprimary or x.indisunique))
      ), '[]'::jsonb),
      'keep', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'index', a.index_name,
                 'size',  pg_size_pretty(a.size_bytes),
                 'scans', a.scans_in_window,
                 'resets', a.resets)
                 order by a.scans_in_window desc)
          from agg a
         where a.scans_in_window > 0 or a.last_cumulative > 0
      ), '[]'::jsonb)
    )
  );
end
$function$;

revoke all on function public.medicine_index_usage_snapshot() from public, anon, authenticated;
revoke all on function public.medicine_index_usage_report()   from public, anon, authenticated;
grant execute on function public.medicine_index_usage_report() to service_role;

-- Registered as a cron_task row, never as its own pg_cron job (RULES.md: one
-- dispatcher, no bare */N schedules). ord 950 puts it after the real work.
insert into public.cron_task (name, ord, enabled, base_interval_s, step_timeout_ms,
                              work_sql, business_hours_only, dml)
values ('medicine_index_usage', 950, true, 3600, 10000,
        'select public.medicine_index_usage_snapshot()', false, false)
on conflict (name) do update
  set enabled = true, base_interval_s = 3600, step_timeout_ms = 10000,
      work_sql = excluded.work_sql, ord = excluded.ord;

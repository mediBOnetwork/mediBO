-- CHANGE #419 — the anonymisation floor, proven on seeded data.
--
--   psql "$(cat ~/.medibo/dburl)" -X -A -t -f scripts/c419_proof.sql
--
-- c419_cohort_proof() seeds a whole synthetic network — 6 pharmacies in one
-- zone, 3 in another, each with a POS bill — runs BOTH aggregation jobs, then
-- asserts the floor in both directions:
--
--   • the 6-shop zone produces a benchmark cohort row (pharmacy_count = 6) and
--     demand class + SKU rows;
--   • the 3-shop zone produces NOTHING — not a cohort row, not a class row, not
--     a SKU row. A group under the floor is not hidden at read time; it is
--     never written.
--
-- The seed deletes itself before the function returns, including on failure,
-- so this is safe to run against production.
select jsonb_pretty(public.c419_cohort_proof()) as cohort_floor_proof;

-- The floor itself cannot be edited away: min_cohort >= 5 is a check
-- constraint, so this UPDATE must raise.
do $$
begin
  begin
    update public.pharmacy_insight_config set min_cohort = 2 where id;
    raise exception 'FAIL: min_cohort was lowered below the floor';
  exception when check_violation then
    raise notice 'PASS: the cohort floor refuses to go below 5';
  end;
end $$;

-- Both aggregation jobs ride the ONE #305 dispatcher, at their own offsets.
select name, ord, mode, enabled, run_at_ist
  from public.cron_task
 where name in ('pharmacy-bench-refresh', 'pharmacy-demand-refresh')
 order by ord;

-- What the refreshes report on the real network right now. `refused_below_floor`
-- is the count of groups that were computed and then deliberately NOT stored.
select public.pharmacy_bench_refresh()  as bench_refresh;
select public.pharmacy_demand_refresh() as demand_refresh;

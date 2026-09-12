-- CHANGE #788 — the catalogue budget guard measures the QUERY, not the queue.
--
-- c747_catalogue_budget timed ONE call per RPC and compared it against 300 ms.
-- On this 1 GB instance that number is dominated by whatever else the fleet is
-- doing: the same catalogue_list measured 1692 ms cold, 483 ms, 359 ms and
-- 131 ms within a few minutes on 3 Sep, with no code change in between. So the
-- guard filed `critical` reds — which BLOCK dev_cmd_complete for every runner —
-- on load, and went green again on the next tick. A guard that flaps teaches
-- people to ignore it.
--
-- The budget is NOT relaxed. What changes is what gets measured: each RPC runs
-- up to three times and the BEST time counts. The minimum is the closest thing
-- to the query's own cost — a genuine regression makes every attempt slow, a
-- busy neighbour mostly hits the first. The payload-size check is unchanged
-- (bytes do not care how busy the box is) and still runs once.
--
-- The failure message now carries the measured milliseconds, so a real breach
-- is diagnosable instead of a bare "budget blown".
update public.rg_behavior_tests set body = $body$
do $c747$
declare
  t0 timestamptz; ms int; best int; sz int; bad text := '';
  budget_ms int := 300; budget_kb int := 512; i int;
begin
  -- One RPC, up to three attempts, the best time wins.
  create temp table if not exists _c747(q text, ms int, kb int) on commit drop;
  delete from _c747;

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_home(true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_home', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_tree('{}'::text[], true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_tree', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_companies(null, null, 0, 40, true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_companies', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_salts(null, 0, 40, true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_salts', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_list('tree', null, array['ANTI INFECTIVES'],
                                       '{}'::jsonb, 'name', true, null, 24)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_list', best, sz/1024);

  select string_agg(format('%s %sms; ', t.q, t.ms), '') into bad
    from _c747 t where t.ms > budget_ms;
  select coalesce(bad,'') || coalesce(string_agg(format('%s %skb; ', t.q, t.kb), ''), '')
    into bad from _c747 t where t.kb > budget_kb;

  if coalesce(bad,'') <> '' then
    raise exception 'RG_FAIL: catalogue budget blown (limit %ms / %kb, best of 3 attempts) — %',
      budget_ms, budget_kb, bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $c747$;
$body$ where name = 'c747_catalogue_budget';

-- CHANGE #1888 (follow-up) — the geocoder's answers must be COLLECTED.
--
-- 20260907230000_c1888 built the whole async path: geo_enqueue() fires the
-- nominatim request through pg_net and geo_collect() applies whatever came
-- back. geo_geocode() drains opportunistically, so a shop that registers or is
-- imported gets its pin. But the BACKFILL enqueues and then nothing ever calls
-- geo_collect() again — the answers sit in geo_lookup_queue with status='sent'
-- forever. Measured on live right after the replay: 1/7 shops with a pin,
-- 1/7 with a maps link, and a queue full of 'sent' rows nobody read.
--
-- The comment in that migration said "and by the cron dispatcher". This is the
-- row that makes that sentence true. It goes in cron_task, never in a pg_cron
-- slot of its own (the 2026-08-18 outages), behind a cheap gate so a quiet
-- queue costs one boolean per tick.
--
-- Idempotent: safe to replay on live.

insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
   base_interval_s, max_interval_s, current_interval_s, business_hours_only,
   dml, next_run_at)
values (
  'geo_collect', 320, 'poll',
  -- The gate: is there anything in flight at all?
  'select exists (select 1 from public.geo_lookup_queue where status = ''sent'')',
  'select public.geo_collect()',
  15000, true,
  'Applies the geocoder answers that geo_enqueue() fired through pg_net. Gated on an in-flight request, so an empty queue costs one boolean. Backs off to 1 h while nothing is waiting.',
  120, 3600, 120, false,
  true, now()
)
on conflict (name) do update
   set gate_sql        = excluded.gate_sql,
       work_sql        = excluded.work_sql,
       step_timeout_ms = excluded.step_timeout_ms,
       enabled         = true,
       note            = excluded.note,
       base_interval_s = excluded.base_interval_s,
       max_interval_s  = excluded.max_interval_s,
       business_hours_only = excluded.business_hours_only,
       dml             = excluded.dml;

-- Drain once right now, so the rows the backfill already queued are applied in
-- this replay instead of waiting for the first tick, and re-run the backfill so
-- the freshly-learned pincodes become pins, maps links and districts.
do $$
declare v_c jsonb; v_b jsonb;
begin
  begin
    v_c := public.geo_collect();
    v_b := public.geo_backfill_customers(500);
    raise notice 'c1888 geo_collect: % / backfill: %', v_c, v_b;
  exception when others then
    -- A geocoder that is down must never fail a deploy.
    raise notice 'c1888 geo_collect skipped: %', sqlerrm;
  end;
end $$;

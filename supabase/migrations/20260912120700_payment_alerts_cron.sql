-- CMD #1929 (9/9) — the one scheduled job this feature needs.
--
-- The AI fallback is dispatched inline by net.http_post at ingest. That call
-- can fail (the dispatcher is down, the function cold-starts past its
-- timeout), and an alert nobody parsed is money nobody matched — so a sweep
-- re-enqueues it.
--
-- The gate matters more than the schedule here: pg_cron starving the 60
-- connection cap is a real outage this project has already had, so this task
-- does nothing at all unless an unparsed alert actually exists.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, base_interval_s, enabled, note)
values (
  'payment_alert_ai_sweep', 35, 'poll',
  $g$select exists (
       select 1 from public.payment_alerts
        where status = 'new' and parse_source = 'none'
          and created_at < now() - interval '2 minutes'
          and created_at > now() - interval '2 days')$g$,
  $w$select public.payment_alert_ai_sweep(20)$w$,
  300, true,
  'Re-enqueues the Gemini fallback for a forwarded payment notification whose inline dispatch did not land. Gated: no unparsed alert, no work.')
on conflict (name) do update set
  gate_sql = excluded.gate_sql,
  work_sql = excluded.work_sql,
  base_interval_s = excluded.base_interval_s,
  mode = excluded.mode,
  note = excluded.note,
  enabled = excluded.enabled;

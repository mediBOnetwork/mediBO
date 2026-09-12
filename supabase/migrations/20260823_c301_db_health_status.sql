-- CHANGE #301 — the Om-facing read model for the DB lane.
-- Every word, number and tone on the screen is built here. The Flutter section
-- renders this payload in the order it arrives and computes nothing.
create or replace function public.db_health_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $$
declare
  cfg  public.db_watchdog_config%rowtype;
  lcfg public.db_work_lock_config%rowtype;
  gcfg public.db_guard_config%rowtype;
  s    public.db_health_sample%rowtype;
  v_ex int; v_hr int; v_peak int; v_alerts int; v_tone text;
begin
  begin
    perform public._db_guard();
  exception when others then
    return jsonb_build_object('ok', false, 'title', 'Database lane',
      'error', coalesce((select value #>> '{}' from public.ui_copy
                          where key = 'dev_queue.db_lane_forbidden'), ''));
  end;

  select * into cfg  from public.db_watchdog_config where id;
  select * into lcfg from public.db_work_lock_config where id;
  select * into gcfg from public.db_guard_config where id;
  select * into s from public.db_health_sample order by at desc limit 1;
  perform public._db_lock_reap();
  select count(*) filter (where kind = 'exclusive'), count(*) filter (where kind = 'heavy_read')
    into v_ex, v_hr from public.db_work_lock;
  select coalesce(max(conns), 0) into v_peak
    from public.db_health_sample where at > now() - interval '24 hours';
  select count(*) into v_alerts
    from public.rg_alerts where kind like 'db\_%' and last_seen > now() - interval '7 days';

  v_tone := case
    when s.at is null then 'warning'
    when s.conns > cfg.conn_max - 5 or s.timeouts_5min > cfg.timeouts_5min_warn then 'error'
    when s.conns > cfg.conn_warn or s.longest_txn_s > cfg.long_txn_seconds then 'warning'
    else 'success' end;

  return jsonb_build_object(
    'ok', true,
    'title', 'Database lane',
    'tone', v_tone,
    'headline', case when s.at is null
      then 'The watchdog has not sampled yet — it runs on the next dispatcher tick.'
      else format('%s of %s connections · peak %s in 24 h · %s statement timeouts in the last 5 minutes',
                  s.conns, s.max_conns, v_peak, s.timeouts_5min) end,
    'sampled_label', case when s.at is null then 'never'
      else format('Sampled %s IST', to_char(s.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI:SS')) end,
    'stats', jsonb_build_array(
      jsonb_build_object('label', 'Connections', 'value', format('%s / %s', coalesce(s.conns, 0), coalesce(s.max_conns, cfg.conn_max))),
      jsonb_build_object('label', 'Longest transaction', 'value', format('%s s', coalesce(s.longest_txn_s, 0))),
      jsonb_build_object('label', 'Timeouts (5 min)', 'value', coalesce(s.timeouts_5min, 0)::text)),
    'lanes', jsonb_build_array(
      jsonb_build_object(
        'label', 'Exclusive — DDL, bulk writes over 20k rows, VACUUM, index builds',
        'value_label', case when v_ex + v_hr = 0
            then format('%s slot · free', lcfg.exclusive_slots)
            else format('%s slot · busy', lcfg.exclusive_slots) end,
        'tone', case when v_ex + v_hr = 0 then 'success' else 'info' end),
      jsonb_build_object(
        'label', 'Heavy read — scans and audits over a big table',
        'value_label', case when v_ex > 0
            then format('%s slots · blocked by an exclusive step', lcfg.heavy_read_slots)
            else format('%s slots · %s in use', lcfg.heavy_read_slots, v_hr) end,
        'tone', case when v_ex > 0 then 'info' when v_hr >= lcfg.heavy_read_slots then 'warning' else 'success' end)),
    'held', coalesce((select jsonb_agg(jsonb_build_object(
              'label', format('%s · %s', l.holder, case l.kind when 'exclusive' then 'exclusive' else 'heavy read' end),
              'detail', format('%s · held %s s · expires in %s s',
                               coalesce(l.title, 'untitled'),
                               round(extract(epoch from (now() - l.acquired_at)))::int,
                               greatest(round(extract(epoch from (l.expires_at - now())))::int, 0)),
              'tone', 'info') order by l.acquired_at) from public.db_work_lock l), '[]'::jsonb),
    'held_empty', 'No agent is holding a database lane. Coding, tests and web builds never take one — only the rare exclusive step does.',
    'guard', jsonb_build_object('label', 'Session guardrails',
      'value_label', format('statement %s s · lock %s s · idle-in-transaction %s s · bulk writes in batches of %s',
                            gcfg.statement_timeout_ms / 1000, gcfg.lock_timeout_ms / 1000,
                            gcfg.idle_in_txn_ms / 1000, gcfg.max_batch_rows)),
    'window', jsonb_build_object('label', 'Heavy scheduled audits',
      'value_label', format('%s jobs run in the 21:00–02:00 UTC window (02:30–07:30 IST)',
        (select count(*) from cron.job where active
          and schedule ~ '^[0-9]+ (2[1-3]|0[01]) '))),
    'alerts', jsonb_build_object('label', 'Watchdog',
      'value_label', format('%s database alerts in 7 days · thresholds: %s connections, %s s transaction, %s timeouts in 5 min',
                            v_alerts, cfg.conn_warn, cfg.long_txn_seconds, cfg.timeouts_5min_warn),
      'quiet', 'Quiet — no connection, transaction or timeout alert in the last 7 days.',
      'recent', coalesce((select jsonb_agg(jsonb_build_object(
            'at_label', to_char(a.last_seen at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
            'severity', a.severity, 'kind', a.kind, 'name', a.name,
            'detail', format('seen %s time(s) · first %s IST', a.seen_count,
                             to_char(a.first_seen at time zone 'Asia/Kolkata', 'DD Mon HH24:MI')))
          order by a.last_seen desc)
        from (select * from public.rg_alerts where kind like 'db\_%'
               order by last_seen desc limit 8) a), '[]'::jsonb)));
end $$;

revoke all on function public.db_health_status() from public;
grant execute on function public.db_health_status() to authenticated, service_role;

insert into public.ui_copy (key, value) values
  ('dev_queue.db_lane_forbidden', to_jsonb('Only a super-admin can read the database lane.'::text))
on conflict (key) do nothing;

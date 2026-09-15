-- CMD #1820 — the road the token-anomaly alert takes to Om's phone.
--
-- dev_token_anomaly_scan() (control plane) calls runner_ops_alert('ops_token_anomaly'),
-- which forwards to production's notify(). Without a wa_event_routes row that
-- lands on notify()'s `unknown_event` branch: logged, never delivered. This is
-- the row. It is production-side on purpose — the control plane forwards, it
-- does not send.
--
-- Guarded by to_regclass so the control-plane replay pass (which has no
-- wa_event_routes) skips it instead of failing the batch.
do $$
begin
  if to_regclass('public.wa_event_routes') is null then
    raise notice 'c1820: no wa_event_routes here — nothing to route';
    return;
  end if;

  insert into public.wa_event_routes (event_key, label, description, audience, enabled, wa_category)
  values ('ops_token_anomaly',
          'Runner — a build cost far more than its class',
          'Raised once per command by dev_token_anomaly_scan() when a build passes the configured multiple of its size-class median. Tokens: command_id, title, tokens, median, factor, size_class.',
          'admin', true, 'utility')
  on conflict (event_key) do update
     set label       = excluded.label,
         description = excluded.description,
         audience    = 'admin',
         enabled     = true;

  -- Push copy, when the column set carries it. Written separately so a schema
  -- that predates push notifications still takes the route itself.
  begin
    update public.wa_event_routes
       set push_enabled = true,
           push_title   = 'A build ran away with itself',
           push_body    = 'Command {{command_id}} spent {{tokens}} tokens — {{factor}} the {{size_class}} median of {{median}}.'
     where event_key = 'ops_token_anomaly';
  exception when undefined_column then
    raise notice 'c1820: wa_event_routes has no push columns here — route created without push copy';
  end;
end $$;

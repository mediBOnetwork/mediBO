-- CHANGE #1366 — Disk-full can never silently block the queue.
--
-- Sep 5: the EC2 root disk sat at 99% from Sep 4 10:50 UTC. The boot doctor's
-- hard 2 GB floor turned every runner red — 354 red boots, ZERO claims for 21
-- hours — and nobody was told: gcp_disk_check reads dev_runner_config.gcp_status
-- which the GCP→AWS move stopped refreshing (stale since Aug 19), so the disk
-- watchdog had nothing to read, and a red boot only ever wrote an rg_alerts row
-- that nothing surfaces.
--
-- Three holes, closed here:
--   1. The floor is CONFIG (worker_pool.disk_floor_gb), not a literal, and the
--      doctor now cleans before it judges (script side).
--   2. A red boot ALERTS: WhatsApp on a new route, an rg_alerts row, and a
--      banner on the Dev Queue control strip. Re-alert every 30 min while red,
--      one recovery message when it clears.
--   3. The watchdog reads the runner's OWN measurement (vm_disk_report, called
--      by the supervisor every 5 min) instead of a GCP status blob nothing
--      writes any more — alert at 85%, auto-enqueue a cleanup at 90%.
--
-- Every string below is backend copy; the app prints it.

-- ── 1. config: the floor and the two watchdog thresholds ────────────────────
update dev_runner_config
   set value = value
             || case when value ? 'disk_floor_gb'   then '{}'::jsonb else jsonb_build_object('disk_floor_gb', 2) end
             || case when value ? 'disk_alert_pct'  then '{}'::jsonb else jsonb_build_object('disk_alert_pct', 85) end
             || case when value ? 'disk_cleanup_pct' then '{}'::jsonb else jsonb_build_object('disk_cleanup_pct', 90) end
 where key = 'worker_pool';

insert into dev_runner_config(key, value)
values ('runner_blocked', jsonb_build_object('blocked', false))
on conflict (key) do nothing;

-- ── 2. copy ─────────────────────────────────────────────────────────────────
insert into ui_copy(key, value) values
  ('dev_queue.blocked_banner',  to_jsonb('Runners blocked: {reason}'::text)),
  ('dev_queue.blocked_detail',  to_jsonb('{agent} refused to claim at {at}. Nothing in the queue moves until the boot doctor is green again.'::text)),
  ('dev_queue.blocked_since',   to_jsonb('Blocked for {age}'::text)),
  ('dev_queue.disk_label',      to_jsonb('Disk'::text)),
  ('dev_queue.disk_value',      to_jsonb('{pct}% used · {free} GB free'::text)),
  ('dev_queue.disk_sub_ok',     to_jsonb('Floor is {floor} GB — headroom is fine'::text)),
  ('dev_queue.disk_sub_warn',   to_jsonb('Above the {alert}% alert line — cleanup runs at {cleanup}%'::text)),
  ('dev_queue.disk_sub_bad',    to_jsonb('Under the {floor} GB floor — runners refuse to claim'::text)),
  ('dev_queue.disk_stale',      to_jsonb('Disk not reported yet'::text)),
  ('dev_queue.disk_stale_sub',  to_jsonb('The supervisor reports free space every 5 minutes'::text)),
  ('dev_queue.health_m_disk',   to_jsonb('Disk'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 3. the disk block every surface prints ──────────────────────────────────
create or replace function public.runner_disk_state()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v public.vm_health%rowtype; wp jsonb;
  v_floor numeric; v_alert numeric; v_cleanup numeric;
  v_pct numeric; v_free_gb numeric; v_age numeric; v_stale boolean;
  v_tone text; v_sub text;
begin
  select value into wp from dev_runner_config where key = 'worker_pool';
  wp := coalesce(wp, '{}'::jsonb);
  v_floor   := coalesce((wp->>'disk_floor_gb')::numeric, 2);
  v_alert   := coalesce((wp->>'disk_alert_pct')::numeric, 85);
  v_cleanup := coalesce((wp->>'disk_cleanup_pct')::numeric, 90);

  select * into v from public.vm_health order by reported_at desc limit 1;

  if v.id is null or coalesce(v.total_mb, 0) <= 0 then
    return jsonb_build_object(
      'has', false, 'ok', true,
      'label',    c755_copy('dev_queue.disk_label', '{}'::jsonb),
      'value',    c755_copy('dev_queue.disk_stale', '{}'::jsonb),
      'sub_line', c755_copy('dev_queue.disk_stale_sub', '{}'::jsonb),
      'tone', 'neutral',
      'floor_gb', v_floor, 'alert_pct', v_alert, 'cleanup_pct', v_cleanup);
  end if;

  v_pct     := round((v.total_mb - v.free_mb)::numeric / v.total_mb * 100);
  v_free_gb := round(v.free_mb::numeric / 1024, 1);
  v_age     := extract(epoch from (now() - v.reported_at));
  v_stale   := v_age > 1800;

  v_tone := case when v_free_gb < v_floor or v_pct >= v_cleanup then 'danger'
                 when v_pct >= v_alert then 'warning'
                 else 'success' end;
  v_sub := case
    when v_free_gb < v_floor then
      c755_copy('dev_queue.disk_sub_bad', jsonb_build_object('floor', v_floor::text))
    when v_pct >= v_alert then
      c755_copy('dev_queue.disk_sub_warn',
        jsonb_build_object('alert', v_alert::text, 'cleanup', v_cleanup::text))
    else
      c755_copy('dev_queue.disk_sub_ok', jsonb_build_object('floor', v_floor::text))
  end;

  return jsonb_build_object(
    'has', true, 'ok', true,
    'label',    c755_copy('dev_queue.disk_label', '{}'::jsonb),
    'value',    c755_copy('dev_queue.disk_value',
                  jsonb_build_object('pct', v_pct::text, 'free', v_free_gb::text)),
    'sub_line', v_sub,
    'pct', v_pct, 'free_gb', v_free_gb, 'tone', v_tone,
    'stale', v_stale, 'host', v.host,
    'at_label', to_char(v.reported_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
    'floor_gb', v_floor, 'alert_pct', v_alert, 'cleanup_pct', v_cleanup);
end $fn$;

-- ── 4. the blocked badge the control strip prints ───────────────────────────
create or replace function public.runner_blocked_badge()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare s jsonb; v_age text; v_since timestamptz;
begin
  select value into s from dev_runner_config where key = 'runner_blocked';
  s := coalesce(s, '{}'::jsonb);
  if coalesce((s->>'blocked')::boolean, false) is not true then
    return jsonb_build_object('has', false);
  end if;

  begin v_since := (s->>'since')::timestamptz; exception when others then v_since := null; end;
  v_age := case when v_since is null then ''
                when now() - v_since < interval '1 hour'
                  then greatest(round(extract(epoch from (now() - v_since))/60), 1)::text || 'm'
                else round(extract(epoch from (now() - v_since))/3600, 1)::text || 'h' end;

  return jsonb_build_object(
    'has', true, 'tone', 'danger',
    'label', c755_copy('dev_queue.blocked_banner',
               jsonb_build_object('reason', coalesce(s->>'reason', ''))),
    'detail', c755_copy('dev_queue.blocked_detail',
               jsonb_build_object('agent', coalesce(s->>'agent', 'A runner'),
                                  'at',    coalesce(s->>'at_label', ''))),
    'since_label', case when v_age = '' then ''
                        else c755_copy('dev_queue.blocked_since',
                               jsonb_build_object('age', v_age)) end,
    'agent', s->>'agent', 'reason', s->>'reason');
end $fn$;

-- ── 5. red boots alert, and say so, and un-say it ───────────────────────────
-- Called from runner_boot_report. Keeps runner_blocked truthful, fires the WA
-- route on the first red, re-fires every 30 min while red, and sends exactly
-- one recovery message when the last red runner turns green.
create or replace function public._runner_blocked_sync(p_agent text, p_verdict text, p_checks jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  s jsonb; v_red int; v_blocked boolean; v_was boolean;
  v_reason text; v_agent text; v_last timestamptz; v_free text;
  v_disk jsonb; v_send boolean := false; v_kind text := '';
begin
  select value into s from dev_runner_config where key = 'runner_blocked';
  s := coalesce(s, '{}'::jsonb);
  v_was := coalesce((s->>'blocked')::boolean, false);

  -- A runner is only "blocked" while its LATEST boot inside the last hour is
  -- red. An hour-old red from a box that has since booted green is history.
  select count(*) filter (where verdict = 'red') into v_red
    from (select distinct on (agent) agent, verdict
            from runner_boot_event
           where at > now() - interval '60 minutes'
           order by agent, at desc) q;
  v_blocked := coalesce(v_red, 0) > 0;

  if v_blocked then
    -- The failing check of the newest red boot, in the doctor's own words.
    select e.agent,
           -- ck->>'label' || ' — ' || ck->>'detail' does not parse: '||' binds
           -- tighter than '->>', so Postgres reads it as ck ->> ('label' || …)
           -- and the whole helper throws inside a swallowing block. Parenthesise.
           coalesce((select (ck->>'label') || ' — ' || (ck->>'detail')
                       from jsonb_array_elements(coalesce(e.checks, '[]'::jsonb)) ck
                      where coalesce((ck->>'ok')::boolean, false) = false
                      limit 1), 'boot doctor red')
      into v_agent, v_reason
      from runner_boot_event e
     where e.verdict = 'red' and e.at > now() - interval '60 minutes'
     order by e.at desc limit 1;
  end if;

  begin v_last := (s->>'last_alert_at')::timestamptz; exception when others then v_last := null; end;

  if v_blocked and not v_was then
    v_send := true; v_kind := 'blocked';
    s := jsonb_build_object('blocked', true, 'since', now(),
                            'agent', v_agent, 'reason', v_reason,
                            'at_label', to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST',
                            'last_alert_at', now());
  elsif v_blocked and v_was then
    s := s || jsonb_build_object('agent', v_agent, 'reason', v_reason);
    if v_last is null or now() - v_last >= interval '30 minutes' then
      v_send := true; v_kind := 'blocked';
      s := s || jsonb_build_object('last_alert_at', now());
    end if;
  elsif not v_blocked and v_was then
    v_send := true; v_kind := 'recovered';
    s := jsonb_build_object('blocked', false, 'cleared_at', now());
  end if;

  insert into dev_runner_config(key, value) values ('runner_blocked', s)
  on conflict (key) do update set value = excluded.value;

  if v_send then
    v_disk := public.runner_disk_state();
    v_free := case when coalesce((v_disk->>'has')::boolean, false)
                   then (v_disk->>'free_gb') else '—' end;
    begin
      -- notify(), not wa_send_event(): the WA path alone returns
      -- 'route_disabled' until Meta has approved a template, and an alert that
      -- waits on template approval is exactly the silence this change exists to
      -- end. notify() takes the same route row and reaches push and email too.
      if v_kind = 'blocked' then
        perform notify('sec_runner_blocked', null,
          jsonb_build_object('agent', coalesce(v_agent, 'A runner'),
                             'reason', coalesce(v_reason, 'boot doctor red'),
                             'free_gb', v_free));
        -- rg_alerts is (fingerprint, severity, kind, name, detail) — the old
        -- runner_boot_report wrote (level, source, message, details), which does
        -- not exist, inside a swallowing exception block. Every red boot's alert
        -- has been silently discarded since that code landed. This is the shape
        -- the table actually has.
        insert into rg_alerts(fingerprint, severity, kind, name, detail)
        values ('c1366_runners_blocked', 'error', 'runner',
                'Runners blocked — nothing is being claimed',
                jsonb_build_object('agent', v_agent, 'reason', v_reason,
                                   'free_gb', v_free, 'red_runners', v_red))
        on conflict (fingerprint) do update
          set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
              severity = 'error', detail = excluded.detail;
      else
        perform notify('sec_runner_recovered', null,
          jsonb_build_object('agent', coalesce(p_agent, 'A runner'),
                             'at', to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST'));
        insert into rg_alerts(fingerprint, severity, kind, name, detail)
        values ('c1366_runners_blocked', 'info', 'runner',
                'Runners green again — claiming resumed',
                jsonb_build_object('agent', p_agent, 'cleared_at', now()))
        on conflict (fingerprint) do update
          set last_seen = now(), severity = 'info', name = excluded.name,
              detail = excluded.detail;
      end if;
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('blocked', v_blocked, 'alerted', v_send, 'kind', v_kind);
end $fn$;

create or replace function public.runner_boot_report(p_agent text, p_host text, p_verdict text,
  p_checks jsonb default '[]'::jsonb, p_repairs jsonb default '[]'::jsonb,
  p_released integer default 0, p_duration_ms integer default 0,
  p_reason text default 'start'::text, p_version text default ''::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_id bigint; v_verdict text; v_blocked jsonb;
begin
  perform _dev_guard();
  v_verdict := case when coalesce(p_verdict,'') = 'green' then 'green' else 'red' end;

  insert into runner_boot_event
    (host, agent, verdict, boot_reason, checks, repairs,
     released_rows, duration_ms, doctor_version)
  values
    (coalesce(p_host,''), coalesce(p_agent,''), v_verdict, coalesce(p_reason,'start'),
     coalesce(p_checks,'[]'::jsonb), coalesce(p_repairs,'[]'::jsonb),
     greatest(coalesce(p_released,0),0), greatest(coalesce(p_duration_ms,0),0),
     coalesce(p_version,''))
  returning id into v_id;

  if v_verdict = 'red' then
    begin
      insert into rg_alerts (fingerprint, severity, kind, name, detail)
      values ('c1366_boot_red_' || coalesce(p_agent,'runner'), 'warn', 'runner',
              coalesce(p_agent,'runner') || ' refused to claim — boot doctor red',
              jsonb_build_object('event_id', v_id, 'checks', coalesce(p_checks,'[]'::jsonb)))
      on conflict (fingerprint) do update
        set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
            detail = excluded.detail;
    exception when others then null;
    end;
  end if;

  -- #1366 — a red boot is never silent again.
  begin v_blocked := public._runner_blocked_sync(p_agent, v_verdict, p_checks);
  exception when others then v_blocked := jsonb_build_object('blocked', null);
  end;

  delete from runner_boot_event where at < now() - interval '30 days';

  return jsonb_build_object('ok', true, 'id', v_id, 'verdict', v_verdict,
                            'fleet', v_blocked);
end $fn$;

-- ── 6. the watchdog, reading the runner's own measurement ───────────────────
create or replace function public.vm_disk_report(p_free_mb integer, p_total_mb integer default null::integer,
  p_worktrees integer default null::integer, p_host text default 'medibo'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  wp jsonb; v_floor numeric; v_alert numeric; v_cleanup numeric;
  v_pct numeric; v_free_gb numeric; v_last date; v_today date;
  v_state jsonb; v_disk_str text; v_enqueued boolean := false; v_alerted boolean := false;
begin
  insert into vm_health(host, free_mb, total_mb, worktrees)
  values (coalesce(p_host,'medibo'), p_free_mb, p_total_mb, p_worktrees);
  delete from vm_health where reported_at < now() - interval '30 days';

  select value into wp from dev_runner_config where key = 'worker_pool';
  wp := coalesce(wp, '{}'::jsonb);
  v_floor   := coalesce((wp->>'disk_floor_gb')::numeric, 2);
  v_alert   := coalesce((wp->>'disk_alert_pct')::numeric, 85);
  v_cleanup := coalesce((wp->>'disk_cleanup_pct')::numeric, 90);

  v_free_gb := round(coalesce(p_free_mb,0)::numeric / 1024, 1);
  v_pct := case when coalesce(p_total_mb,0) > 0
                then round((p_total_mb - p_free_mb)::numeric / p_total_mb * 100)
                else null end;

  -- Keep the GCP panel's disk line fresh. It has read a blob nothing wrote
  -- since the AWS move; this is the measurement that replaces it.
  if v_pct is not null then
    v_disk_str := round((p_total_mb - p_free_mb)::numeric/1024, 1)::text || ' GB / '
               || round(p_total_mb::numeric/1024, 1)::text || ' GB (' || v_pct::text || '%)';
    update dev_runner_config
       set value = coalesce(value,'{}'::jsonb)
                 || jsonb_build_object('disk', v_disk_str, 'disk_pct', v_pct, 'updated', now())
     where key = 'gcp_status';
  end if;

  if v_pct is not null and v_pct >= v_alert then
    begin
      perform notify('gcp_disk_alert', null,
        jsonb_build_object('pct', v_pct::text, 'disk', coalesce(v_disk_str, '')));
      v_alerted := true;
    exception when others then null;
    end;

    -- At the cleanup line, put the work in the queue itself — once per IST day,
    -- exactly the behaviour the dead GCP watchdog used to have.
    if v_pct >= v_cleanup then
      v_today := (now() at time zone 'Asia/Kolkata')::date;
      select (value->>'last_disk_cmd')::date into v_last from dev_runner_config where key='uptime';
      if v_last is distinct from v_today then
        insert into dev_commands (title, spec, kind, urgent, priority)
        values ('Auto: free disk space (disk ' || v_pct::text || '%)',
                'Disk is at ' || v_pct::text || '% with ' || v_free_gb::text || ' GB free. Run '
                || 'mediBO-runner/disk_cleanup.sh, then report the before/after df -h numbers in plain '
                || 'language. It only removes regenerable caches and build output. NEVER touch the repo '
                || 'working tree, DB dumps, runner files, or anything under /mnt.',
                'gcp', true, 5);
        insert into dev_runner_config(key, value)
        values ('uptime', jsonb_build_object('last_disk_cmd', v_today::text))
        on conflict (key) do update
          set value = jsonb_set(coalesce(dev_runner_config.value,'{}'::jsonb),
                                '{last_disk_cmd}', to_jsonb(v_today::text));
        v_enqueued := true;
      end if;
    end if;
  end if;

  v_state := public.runner_disk_state();

  return jsonb_build_object('ok', true,
    'free_mb', p_free_mb, 'free_gb', v_free_gb, 'pct', v_pct,
    'healthy', v_free_gb >= v_floor,
    'floor_gb', v_floor, 'alert_pct', v_alert, 'cleanup_pct', v_cleanup,
    'alerted', v_alerted, 'cleanup_enqueued', v_enqueued,
    'disk', v_state,
    'message', case
      when v_free_gb < v_floor then 'Critical — under the ' || v_floor::text
           || ' GB floor. Runners will refuse to claim. Cleanup now.'
      when v_pct is not null and v_pct >= v_cleanup then 'Very low — cleanup enqueued.'
      when v_pct is not null and v_pct >= v_alert then 'Low — above the alert line.'
      else 'Disk is fine' end);
end $fn$;

-- ── 7. the disk row on the Runner health card ───────────────────────────────
create or replace function public.runner_health_disk_metric()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'label', c755_copy('dev_queue.health_m_disk','{}'::jsonb),
    'value', case when coalesce((d->>'has')::boolean,false)
                  then (d->>'pct') || '%' else '—' end,
    'tone',  coalesce(d->>'tone','neutral'))
  from (select public.runner_disk_state() as d) s;
$fn$;

-- ── 8. the two surfaces read it ─────────────────────────────────────────────
create or replace function public.dev_ctl_get()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb;
begin
  v := public.dev_ctl_get_core();
  begin v_ctx := public.dev_context_metrics_cached(60);
  exception when others then v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  begin v_blocked := public.runner_blocked_badge();
  exception when others then v_blocked := jsonb_build_object('has', false);
  end;
  begin v_disk := public.runner_disk_state();
  exception when others then v_disk := jsonb_build_object('has', false);
  end;
  -- The Runner health card is a metrics printer; disk joins the other five
  -- measured inputs rather than the card learning a sixth shape.
  if coalesce((v->'health'->>'ok')::boolean, false) then
    v := jsonb_set(v, '{health,metrics}',
           coalesce(v->'health'->'metrics','[]'::jsonb)
           || jsonb_build_array(public.runner_health_disk_metric()));
  end if;

  return v || jsonb_build_object('context', v_ctx, 'blocked', v_blocked, 'disk', v_disk);
end $fn$;

-- ── 9. the WhatsApp routes ──────────────────────────────────────────────────
insert into wa_event_routes
  (event_key, label, description, audience, enabled, template_name, auto_template_name,
   auto_manage, variable_map, dedupe_minutes, wa_category, bypass_send_window,
   push_enabled, email_enabled, push_title, push_body, email_subject, email_body)
values
  ('sec_runner_blocked', 'Runners blocked',
   'A runner''s boot doctor went red, so nothing in the dev queue is being claimed. Re-sent every 30 minutes while it stays red.',
   'admin', true, 'sec_runner_blocked', 'sec_runner_blocked', true,
   '["{{agent}}","{{reason}}","{{free_gb}}"]'::jsonb, 30, 'utility', true,
   true, true, 'Runners blocked', '{{agent}}: {{reason}}',
   'mediBO runners blocked — {{reason}}',
   'The dev queue is not claiming. {{agent}} failed its boot check: {{reason}}. Free disk: {{free_gb}} GB.'),
  ('sec_runner_recovered', 'Runners back',
   'The last red runner passed its boot doctor — the queue is claiming again.',
   'admin', true, 'sec_runner_recovered', 'sec_runner_recovered', true,
   '["{{agent}}","{{at}}"]'::jsonb, 5, 'utility', true,
   true, true, 'Runners back', 'Claiming resumed at {{at}}',
   'mediBO runners are back',
   '{{agent}} passed its boot check at {{at}}. The dev queue is claiming again.')
on conflict (event_key) do update set
  label = excluded.label, description = excluded.description,
  audience = excluded.audience, enabled = excluded.enabled,
  variable_map = excluded.variable_map, dedupe_minutes = excluded.dedupe_minutes,
  push_enabled = excluded.push_enabled, email_enabled = excluded.email_enabled,
  push_title = excluded.push_title, push_body = excluded.push_body,
  email_subject = excluded.email_subject, email_body = excluded.email_body,
  updated_at = now();

insert into wa_event_template_seeds(name, category, language, components)
values
  ('sec_runner_blocked', 'UTILITY', 'en',
   '[{"type":"BODY","text":"mediBO build runners are blocked. {{1}} failed its boot check: {{2}}. Free disk: {{3}} GB. No queued command will run until this clears.","example":{"body_text":[["runner-2","Disk headroom — 0.7 GB free (99% used)","0.7"]]}},{"type":"FOOTER","text":"mediBO operations alert"}]'::jsonb),
  ('sec_runner_recovered', 'UTILITY', 'en',
   '[{"type":"BODY","text":"mediBO build runners are back. {{1}} passed its boot check at {{2}} and the dev queue is claiming again.","example":{"body_text":[["runner-2","05 Sep 14:20 IST"]]}},{"type":"FOOTER","text":"mediBO operations alert"}]'::jsonb)
on conflict (name) do update set components = excluded.components, category = excluded.category;

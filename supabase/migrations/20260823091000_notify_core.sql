-- CHANGE — #297 part 1, step 2: notify() — the ONE send entry point.
--
--   notify(event_key, recipient, vars) -> jsonb
--
-- Order of preference, and the reason for it:
--   1. An ENABLED route whose template is APPROVED always wins. This is the
--      order_placed fix: the old path sent free-form first whenever the 24h
--      window looked open, which bypassed the approved template for no gain
--      and, outside the window, was refused by Meta with "Re-engagement
--      message".
--   2. Free-form (the caller's legacy edge-function URL) is the FALLBACK, and
--      only while the tracked service window is open.
--   3. Window closed and no template -> nothing is sent and the send is
--      QUEUED, never dropped. A queued send goes out the moment a template is
--      approved or the customer writes in.
--
-- An event with NO route row at all is a legacy passthrough: the caller's URL
-- is posted exactly as before and the attempt is logged. That keeps the
-- supplier waterfall and every other unrouted sender behaving identically
-- while still funnelling through one door.
--
-- vars[] reserved keys (everything else is a template token):
--   order_id, customer_id, legacy_url, legacy_body, channel,
--   force_template, _retry_id

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- The ledger writer. Returns the row id so a caller can attach a provider id.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_log(
  p_event_key text, p_recipient text, p_channel text, p_status text,
  p_path text default null, p_provider_message_id text default null,
  p_failure_reason text default null, p_cost numeric default null,
  p_order_id uuid default null, p_customer_id uuid default null,
  p_vars jsonb default '{}'::jsonb, p_detail jsonb default null)
returns bigint language sql security definer set search_path to 'public' as $$
  insert into public.notification_log(
    event_key, recipient, channel, status, path, provider_message_id,
    failure_reason, cost, order_id, customer_id, vars, detail)
  values (p_event_key, coalesce(p_recipient,'unknown'), coalesce(p_channel,'whatsapp'),
          p_status, p_path, p_provider_message_id, p_failure_reason, p_cost,
          p_order_id, p_customer_id,
          -- never store the transport plumbing as if it were a template token
          coalesce(p_vars,'{}'::jsonb) - 'legacy_url' - 'legacy_body' - '_retry_id',
          p_detail)
  returning id;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Retry queue: enqueue with exponential backoff. One OPEN row per
-- (event, recipient, order) — a second failure bumps the existing row rather
-- than fanning the same message out N times.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_enqueue_retry(
  p_event_key text, p_recipient text, p_vars jsonb, p_reason text,
  p_order_id uuid default null, p_customer_id uuid default null,
  p_channel text default 'whatsapp', p_force_template boolean default false)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_att int;
begin
  if length(coalesce(p_recipient,'')) < 10 then return null; end if;

  select id, attempts into v_id, v_att
    from public.notification_retry_queue
   where status = 'pending' and event_key = p_event_key and recipient = p_recipient
     and coalesce(order_id,'00000000-0000-0000-0000-000000000000'::uuid)
       = coalesce(p_order_id,'00000000-0000-0000-0000-000000000000'::uuid);

  if v_id is not null then
    update public.notification_retry_queue
       set attempts        = attempts + 1,
           last_reason     = p_reason,
           force_template  = force_template or coalesce(p_force_template,false),
           next_attempt_at = now() + public.notify_backoff(attempts + 1),
           status          = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
           updated_at      = now()
     where id = v_id;
    return v_id;
  end if;

  insert into public.notification_retry_queue(
      event_key, recipient, channel, vars, order_id, customer_id,
      attempts, next_attempt_at, force_template, last_reason)
  values (p_event_key, p_recipient, coalesce(p_channel,'whatsapp'),
          coalesce(p_vars,'{}'::jsonb) - '_retry_id',
          p_order_id, p_customer_id, 1, now() + public.notify_backoff(1),
          coalesce(p_force_template,false), p_reason)
  returning id into v_id;
  return v_id;
end $$;

-- 1 → 2 min, 2 → 4, 3 → 16, 4 → 64, 5 → 120 (capped at two hours).
create or replace function public.notify_backoff(p_attempt integer)
returns interval language sql immutable as $$
  select least(make_interval(mins => power(4, greatest(coalesce(p_attempt,1),1) - 1)::int * 2),
               interval '2 hours');
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- notify() — the only send entry point.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify(
  p_event_key text,
  p_recipient text default null,
  p_vars jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net' as $$
declare
  r            record;
  v            jsonb;
  v_vars       jsonb := coalesce(p_vars, '{}'::jsonb);
  v_channel    text  := coalesce(nullif(v_vars->>'channel',''), 'whatsapp');
  v_order      uuid  := nullif(v_vars->>'order_id','')::uuid;
  v_cust       uuid  := nullif(v_vars->>'customer_id','')::uuid;
  v_url        text  := nullif(v_vars->>'legacy_url','');
  v_body       jsonb := case when v_vars ? 'legacy_body' then v_vars->'legacy_body' end;
  v_force_tpl  boolean := coalesce((v_vars->>'force_template')::boolean, false);
  v_retry      bigint := nullif(v_vars->>'_retry_id','')::bigint;
  v_tokens     jsonb;
  v_ph         text;
  v_aud        text;
  v_win        jsonb;
  v_open       boolean;
  v_reason     text;
begin
  if coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_event_key');
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  v_aud := coalesce(r.audience, 'customer');

  -- Tokens = everything that is not transport plumbing.
  v_tokens := v_vars - 'order_id' - 'customer_id' - 'legacy_url' - 'legacy_body'
                     - 'channel' - 'force_template' - '_retry_id';

  ---------------------------------------------------------------------------
  -- Recipient. An explicit p_recipient wins; then the order's customer; then
  -- the profile; then, for an admin-audience route, the admin number.
  ---------------------------------------------------------------------------
  v_ph := nullif(right(regexp_replace(coalesce(p_recipient,''),'\D','','g'),10),'');
  if coalesce(length(v_ph),0) <> 10 and v_order is not null then
    v_ph := right(regexp_replace(coalesce(public._order_customer_phone(v_order),''),'\D','','g'),10);
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_cust is not null then
    select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
      into v_ph from public.pharmacy_profiles pp where pp.id = v_cust;
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_aud = 'admin' then
    v_ph := right(regexp_replace(
              coalesce((select value #>> '{}' from public.app_settings where key='admin_wa_phone'),''),
              '\D','','g'), 10);
  end if;

  ---------------------------------------------------------------------------
  -- No route at all → legacy passthrough. Behaviour identical to before this
  -- change; the only difference is that the attempt is now on the ledger.
  ---------------------------------------------------------------------------
  if r.event_key is null then
    if v_url is null then
      perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
        null, 'unknown_event', null, v_order, v_cust, v_vars);
      return jsonb_build_object('ok', false, 'reason','unknown_event');
    end if;
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'legacy',
      null, null, null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', true, 'path','legacy', 'reason','no_route');
  end if;

  if coalesce(length(v_ph),0) <> 10 then
    perform public._wa_log_attempt(p_event_key, v_order, null, 'skipped', false, 'no_phone');
    perform public.notify_log(p_event_key, null, v_channel, 'skipped', 'none',
      null, 'no_phone', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  ---------------------------------------------------------------------------
  -- The admin's own on/off switch for this event. Unchanged semantics.
  ---------------------------------------------------------------------------
  if not public.notif_should_send(v_aud, p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'notification_off');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'notification_off', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','notification_off');
  end if;

  v_win  := public.notify_window(v_ph);
  v_open := coalesce((v_win->>'open')::boolean, false);

  ---------------------------------------------------------------------------
  -- 1. TEMPLATE FIRST. Always. This is the fix.
  ---------------------------------------------------------------------------
  begin
    v := public.wa_send_event_or_fallback(p_event_key, v_cust, v_tokens, v_ph, v_order);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason','exception', 'message', sqlerrm);
  end;

  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'template',
      v->>'recipient_id', null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue
         set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','template', 'window_open', v_open, 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  ---------------------------------------------------------------------------
  -- 2. FREE-FORM, and only inside the tracked window. force_template (set by
  --    the "Re-engagement message" recovery) never takes this branch.
  ---------------------------------------------------------------------------
  if v_url is not null and v_open and not v_force_tpl then
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'freeform', true,
                                   'window_open_no_template: ' || v_reason, v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'freeform',
      null, null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','freeform', 'window_open', true,
                              'reason', v_reason);
  end if;

  ---------------------------------------------------------------------------
  -- 3. Nothing legal to send right now → QUEUE it. Never a silent drop.
  ---------------------------------------------------------------------------
  perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, v_reason, v);
  perform public.notify_log(p_event_key, v_ph, v_channel, 'queued', 'none',
    null, v_reason, null, v_order, v_cust, v_vars, v);

  if v_retry is not null then
    update public.notification_retry_queue
       set attempts = attempts + 1, last_reason = v_reason,
           next_attempt_at = now() + public.notify_backoff(attempts + 1),
           status = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
           updated_at = now()
     where id = v_retry;
  else
    perform public.notify_enqueue_retry(p_event_key, v_ph, v_vars, v_reason,
                                        v_order, v_cust, v_channel, v_force_tpl);
  end if;

  return jsonb_build_object('ok', false, 'path','queued', 'window_open', v_open,
                            'reason', v_reason);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The drain. Cron every 5 minutes on an OFFSET (never a bare */5 — see the
-- connection-exhaustion outage of 2026-08-18).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_retry_tick(p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare q record; v_tried int := 0; v_ok int := 0; v jsonb;
begin
  for q in
    select * from public.notification_retry_queue
     where status = 'pending' and next_attempt_at <= now()
     order by next_attempt_at
     limit greatest(coalesce(p_limit,25),1)
  loop
    v_tried := v_tried + 1;
    begin
      v := public.notify(q.event_key, q.recipient,
             q.vars
             || jsonb_build_object('_retry_id', q.id)
             || case when q.order_id    is not null then jsonb_build_object('order_id', q.order_id) else '{}'::jsonb end
             || case when q.customer_id is not null then jsonb_build_object('customer_id', q.customer_id) else '{}'::jsonb end
             || case when q.force_template then jsonb_build_object('force_template', true) else '{}'::jsonb end);
      if coalesce((v->>'ok')::boolean,false) then v_ok := v_ok + 1; end if;
    exception when others then
      update public.notification_retry_queue
         set attempts = attempts + 1, last_reason = 'tick_error: ' || sqlerrm,
             next_attempt_at = now() + public.notify_backoff(attempts + 1),
             status = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
             updated_at = now()
       where id = q.id;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'tried', v_tried, 'sent', v_ok);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Health alerts. If an event's failure rate crosses the threshold inside an
-- hour, raise ONE open alert for it (never one per failure).
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.notification_alerts (
  id           bigserial primary key,
  event_key    text not null,
  channel      text not null default 'whatsapp',
  attempts     integer not null,
  failures     integer not null,
  failure_pct  integer not null,
  status       text not null default 'open',        -- open | resolved
  raised_at    timestamptz not null default now(),
  resolved_at  timestamptz,
  note         text
);
create unique index if not exists notification_alerts_open_uidx
  on public.notification_alerts (event_key, channel) where status = 'open';

alter table public.notification_alerts enable row level security;
drop policy if exists notification_alerts_admin_read on public.notification_alerts;
create policy notification_alerts_admin_read on public.notification_alerts
  for select using (public.get_my_role() in ('admin','super_admin'));

create table if not exists public.notification_health_config (
  id                  boolean primary key default true check (id),
  window_hours        integer not null default 1,
  min_attempts        integer not null default 5,
  failure_pct_threshold integer not null default 40,
  updated_at          timestamptz not null default now()
);
insert into public.notification_health_config(id) values (true) on conflict (id) do nothing;

create or replace function public.notify_health_scan()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cfg record; e record; v_raised int := 0; v_cleared int := 0;
begin
  select * into cfg from public.notification_health_config where id;

  for e in
    select l.event_key, l.channel,
           count(*)                                   as attempts,
           count(*) filter (where l.status = 'failed'
                              or l.status = 'queued') as failures
      from public.notification_log l
     where l.created_at > now() - make_interval(hours => cfg.window_hours)
       and l.status in ('sent','failed','queued')
     group by 1,2
  loop
    if e.attempts >= cfg.min_attempts
       and (e.failures * 100 / e.attempts) >= cfg.failure_pct_threshold then
      insert into public.notification_alerts(event_key, channel, attempts, failures, failure_pct)
      values (e.event_key, e.channel, e.attempts, e.failures,
              (e.failures * 100 / e.attempts))
      on conflict (event_key, channel) where status = 'open'
        do update set attempts = excluded.attempts, failures = excluded.failures,
                      failure_pct = excluded.failure_pct;
      v_raised := v_raised + 1;
    else
      update public.notification_alerts
         set status='resolved', resolved_at = now()
       where event_key = e.event_key and channel = e.channel and status = 'open';
      if found then v_cleared := v_cleared + 1; end if;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'raised', v_raised, 'cleared', v_cleared,
                            'threshold_pct', cfg.failure_pct_threshold,
                            'window_hours', cfg.window_hours);
end $$;

commit;

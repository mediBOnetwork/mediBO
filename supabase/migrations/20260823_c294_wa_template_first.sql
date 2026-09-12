-- CHANGE #294 — WhatsApp: template-first customer sends, never free-form outside the 24h window.
--
-- Incident (order CPO230826CHAO1, 2026-08-23 08:47:57 UTC, Chandra Medicom):
--   • wa_notify_order_placed() only POSTed to the `order-notify` edge function,
--     which sends a FREE-FORM document. It never called wa_send_event('order_placed'),
--     so the approved `order_placed` template was never used — not on this order and
--     not on any order since the route was created. It landed only when the customer
--     happened to have messaged us inside the last 24h.
--   • The payment/QR send had the same shape (`payment_qr_to_customer`, free-form).
--   • trg_wa_retry_on_hard_fail deliberately EXCLUDES '%re-engagement%' failures, so
--     an out-of-window failure was logged and then died there.
--
-- This migration makes the window the gate for every customer-facing send:
--   window open  -> the rich free-form message (best UX)
--   window shut  -> the approved template through wa_event_routes
--   any "Re-engagement message" failure -> automatic template retry
--   every attempt (including a skip and its reason) -> wa_send_attempts
--   any failed customer-facing send -> an admin alert, not a silent log line
--
-- Idempotent throughout: safe to re-apply after a runner restart.

-- ───────────────────────────────────────────────────────────────── 1. window ──

create or replace function public.wa_window_open(p_phone text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1
      from whatsapp_messages m
     where m.direction = 'in'
       and length(right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)) = 10
       and right(regexp_replace(m.sender_phone,'\D','','g'),10)
         = right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)
       and coalesce(m.received_at, m.created_at) > now() - interval '24 hours');
$$;

comment on function public.wa_window_open(text) is
  'CHANGE #294 — is the Meta 24h customer-service window open for this number? '
  'The ONLY thing allowed to decide whether a free-form message may be sent.';

create or replace function public.wa_window_state(p_phone text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with last_in as (
    select max(coalesce(m.received_at, m.created_at)) as at
      from whatsapp_messages m
     where m.direction = 'in'
       and length(right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)) = 10
       and right(regexp_replace(m.sender_phone,'\D','','g'),10)
         = right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)
  )
  select jsonb_build_object(
    'open', coalesce(at > now() - interval '24 hours', false),
    'last_inbound_at', at,
    'closes_at', case when at is null then null else at + interval '24 hours' end,
    'label', case
       when at is null then 'Never messaged us — template only'
       when at > now() - interval '24 hours'
         then 'Open — free-form allowed until '
              || to_char((at + interval '24 hours') at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI am')
              || ' IST'
       else 'Closed since '
            || to_char((at + interval '24 hours') at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI am')
            || ' IST — template only'
     end)
  from last_in;
$$;

-- ──────────────────────────────────────────────────────── 2. attempt ledger ──

create table if not exists public.wa_send_attempts (
  id          bigserial primary key,
  event_key   text not null,
  order_id    uuid,
  phone       text,
  path        text not null,          -- template | freeform | template_retry | skipped
  ok          boolean not null default false,
  reason      text,
  detail      jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists wa_send_attempts_order_idx   on public.wa_send_attempts(order_id, event_key);
create index if not exists wa_send_attempts_created_idx on public.wa_send_attempts(created_at desc);
create index if not exists wa_send_attempts_open_idx    on public.wa_send_attempts(ok, created_at desc);
alter table public.wa_send_attempts enable row level security;

comment on table public.wa_send_attempts is
  'CHANGE #294 — every customer-facing notification attempt, including the ones we '
  'deliberately skipped and why. An order can no longer be created without a row here.';

create or replace function public._wa_log_attempt(
  p_event_key text, p_order_id uuid, p_phone text,
  p_path text, p_ok boolean, p_reason text, p_detail jsonb default null)
returns void
language sql security definer set search_path to 'public'
as $$
  insert into public.wa_send_attempts(event_key, order_id, phone, path, ok, reason, detail)
  values (p_event_key, p_order_id, p_phone, p_path, coalesce(p_ok,false), p_reason, p_detail);
$$;

-- ─────────────────────────────────────── 3. routed_to -> event_key, fallback ──

alter table public.wa_event_routes
  add column if not exists fallback_event_key text;

comment on column public.wa_event_routes.fallback_event_key is
  'CHANGE #294 — event to use when THIS route has no approved template yet. Lets a '
  'newly submitted template sit in review without the message going free-form.';

create or replace function public.wa_event_key_for_routed(p_routed text)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select r.event_key
    from wa_event_routes r
   where regexp_replace(coalesce(p_routed,''), '_error$', '') = any(r.legacy_routed_to)
   order by r.event_key
   limit 1;
$$;

-- Header media for a templated event (Meta needs the media on the HEADER
-- component, per message). Null => this event has no media header to fill.
create or replace function public.wa_event_header_media(p_event_key text, p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_url text;
begin
  if p_event_key = 'payment_qr' and p_order_id is not null then
    select q.image_url into v_url
      from razorpay_qr q
     where q.order_id = p_order_id
       and coalesce(q.image_url,'') <> ''
       and lower(coalesce(q.status,'')) not in ('closed','paid')
     order by q.created_at desc
     limit 1;
    if v_url is not null then
      return jsonb_build_object('type','image','link',v_url);
    end if;
  end if;
  return null;
end $$;

-- ────────────────────────────────── 4. template send with approved fallback ──

create or replace function public.wa_send_event_or_fallback(
  p_event_key text, p_customer_id uuid default null, p_tokens jsonb default '{}'::jsonb,
  p_phone text default null, p_order_id uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v jsonb; v_fb text; v2 jsonb;
begin
  begin
    v := public.wa_send_event_now(p_event_key, p_customer_id, p_tokens, p_phone, p_order_id);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason', 'exception', 'message', sqlerrm);
  end;

  if coalesce((v->>'ok')::boolean, false) then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  -- Only a MISSING/unapproved template justifies the fallback. A deliberate
  -- "notification_off" / "suppressed" / "legacy_already_delivered" must stay a no-send.
  if coalesce(v->>'reason','') not in
     ('route_disabled','template_not_approved','unknown_event','missing_values','exception')
  then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  select nullif(btrim(coalesce(fallback_event_key,'')),'') into v_fb
    from wa_event_routes where event_key = p_event_key;
  if v_fb is null then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  begin
    v2 := public.wa_send_event_now(v_fb, p_customer_id, p_tokens, p_phone, p_order_id);
  exception when others then
    v2 := jsonb_build_object('ok', false, 'reason', 'exception', 'message', sqlerrm);
  end;

  return v2 || jsonb_build_object('used_event', v_fb,
                                  'primary_event', p_event_key,
                                  'primary_reason', v->>'reason');
end $$;

-- ───────────────────────────────────────────── 5. the one customer dispatcher ──

create or replace function public.wa_notify_customer_event(
  p_event_key   text,
  p_order_id    uuid    default null,
  p_phone       text    default null,
  p_legacy_url  text    default null,
  p_legacy_body jsonb   default null)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $$
declare v_ph text; v_open boolean; v jsonb; v_reason text;
begin
  v_ph := coalesce(
            nullif(regexp_replace(coalesce(p_phone,''),'\D','','g'),''),
            case when p_order_id is not null then public._order_customer_phone(p_order_id) end);
  v_ph := right(coalesce(v_ph,''), 10);

  if length(v_ph) <> 10 then
    perform public._wa_log_attempt(p_event_key, p_order_id, null, 'skipped', false, 'no_phone');
    return jsonb_build_object('ok', false, 'reason', 'no_phone');
  end if;

  if not public.notif_should_send('customer', p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, 'notification_off');
    return jsonb_build_object('ok', false, 'reason', 'notification_off');
  end if;

  v_open := public.wa_window_open(v_ph);

  -- Window genuinely open: the rich free-form message is the better customer
  -- experience and Meta allows it. Anything else is a template.
  if v_open and p_legacy_url is not null then
    perform net.http_post(
      url     := p_legacy_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(p_legacy_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform', true, 'window_open');
    return jsonb_build_object('ok', true, 'path', 'freeform', 'reason', 'window_open');
  end if;

  v := public.wa_send_event_or_fallback(p_event_key, null, '{}'::jsonb, v_ph, p_order_id);
  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    return jsonb_build_object('ok', true, 'path', 'template', 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  -- No template available. Sending free-form into a shut window WILL fail, but a
  -- logged failure is what raises the alert and the retry — it is never silent.
  if p_legacy_url is not null then
    perform net.http_post(
      url     := p_legacy_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(p_legacy_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform', false,
                                   'window_closed_no_template: ' || v_reason, v);
    return jsonb_build_object('ok', false, 'path', 'freeform', 'reason', v_reason);
  end if;

  perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, v_reason, v);
  return jsonb_build_object('ok', false, 'reason', v_reason);
end $$;

comment on function public.wa_notify_customer_event(text,uuid,text,text,jsonb) is
  'CHANGE #294 — THE door for every customer-facing WhatsApp notification. '
  'Window open => free-form; window shut => approved template; always logged.';

-- ──────────────────────────────────────────────────── 6. rewire the triggers ──

create or replace function public.wa_notify_order_placed()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  begin
    perform public.wa_notify_customer_event(
      'order_placed', NEW.id, null,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
      jsonb_build_object('order_id', NEW.id, 'event', 'placed'));
  exception when others then
    -- An order must never fail to be created because a notification blew up,
    -- but the attempt (and the reason) is still on the record.
    perform public._wa_log_attempt('order_placed', NEW.id, null, 'skipped', false,
                                   'trigger_error: ' || sqlerrm);
  end;
  return NEW;
end $$;

create or replace function public.wa_notify_order_updated()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if lower(coalesce(NEW.status,'')) in ('cancelled','canceled','rejected') then return NEW; end if;
  begin
    perform public.wa_notify_customer_event(
      'order_updated', NEW.id, null,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
      jsonb_build_object('order_id', NEW.id, 'event', 'updated'));
  exception when others then
    perform public._wa_log_attempt('order_updated', NEW.id, null, 'skipped', false,
                                   'trigger_error: ' || sqlerrm);
  end;
  return NEW;
end $$;

create or replace function public.wa_notify_order_status()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare ns text := lower(coalesce(NEW.status,'')); os text := lower(coalesce(OLD.status,''));
        ev text; k text;
begin
  if ns = os then return NEW; end if;
  if ns in ('accepted','confirmed') then ev := 'accepted'; k := 'order_accepted';
  elsif ns in ('rejected','cancelled','canceled') then ev := 'rejected'; k := 'order_rejected';
  else return NEW; end if;
  begin
    perform public.wa_notify_customer_event(
      k, NEW.id, null,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
      jsonb_build_object('order_id', NEW.id, 'event', ev));
  exception when others then
    perform public._wa_log_attempt(k, NEW.id, null, 'skipped', false, 'trigger_error: ' || sqlerrm);
  end;
  return NEW;
end $$;

-- ──────────────────────────── 7. re-engagement => template retry + the alert ──

create or replace function public.wa_send_failed_alert(
  p_event_key text, p_phone text, p_order_id uuid, p_reason text, p_retried jsonb)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_code text; v_label text;
begin
  select o.order_code into v_code from orders o where o.id = p_order_id;
  select coalesce(r.label, p_event_key) into v_label from wa_event_routes r where r.event_key = p_event_key;

  begin
    perform public.wa_send_event_now(
      'wa_send_failed', null,
      jsonb_build_object(
        'failed_message', coalesce(v_label, p_event_key),
        'failed_to',      right(coalesce(p_phone,''),10),
        'failed_reason',  coalesce(p_reason,'unknown')
          || case when coalesce(v_code,'') <> '' then ' (' || v_code || ')' else '' end),
      null, p_order_id);
  exception when others then null;   -- the ledger row below is the durable alert
  end;

  perform public._wa_log_attempt(p_event_key, p_order_id, p_phone, 'alert', false,
                                 coalesce(p_reason,'send_failed'), p_retried);
end $$;

create or replace function public.trg_wa_out_failed()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare v_event text; v_order uuid; v_code text; v jsonb;
begin
  if NEW.direction <> 'out'
     or NEW.wa_status <> 'failed'
     or coalesce(OLD.wa_status,'') = 'failed'
     or coalesce(NEW.routed_to,'') in ('bot_reply','admin_reply','bot_send_error','send_error','campaign')
  then
    return null;
  end if;

  v_event := public.wa_event_key_for_routed(NEW.routed_to);

  v_code := nullif(btrim(split_part(replace(coalesce(NEW.file_name,''),'mediBO-',''), '.', 1)),'');
  if v_code is not null then
    select o.id into v_order from orders o where o.order_code = v_code limit 1;
  end if;
  if v_order is null then
    -- The most recent order of that number is the only sane anchor when the
    -- message carried no file name (a plain text send).
    select o.id into v_order
      from orders o
      join pharmacy_profiles pp on pp.user_id = o.user_id
     where right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
         = right(regexp_replace(NEW.sender_phone,'\D','','g'),10)
     order by o.created_at desc
     limit 1;
  end if;

  if coalesce(NEW.wa_fail_reason,'') ilike '%re-engagement%' then
    if v_event is not null then
      v := public.wa_send_event_or_fallback(v_event, null, '{}'::jsonb, NEW.sender_phone, v_order);
      perform public._wa_log_attempt(v_event, v_order, NEW.sender_phone, 'template_retry',
                                     coalesce((v->>'ok')::boolean,false),
                                     coalesce(v->>'reason','retried_as_template'), v);
      if coalesce((v->>'ok')::boolean,false) then
        return null;   -- recovered: the customer got the template. No alarm.
      end if;
    else
      perform public._wa_log_attempt(coalesce(NEW.routed_to,'unknown'), v_order, NEW.sender_phone,
                                     'skipped', false,
                                     'no_event_route_for_' || coalesce(NEW.routed_to,'null'));
    end if;
  end if;

  perform public.wa_send_failed_alert(coalesce(v_event, NEW.routed_to, 'unknown'),
                                      NEW.sender_phone, v_order,
                                      coalesce(NEW.wa_fail_reason,'send_failed'), v);
  return null;
end $$;

drop trigger if exists trg_wa_out_failed on public.whatsapp_messages;
create trigger trg_wa_out_failed
  after update of wa_status on public.whatsapp_messages
  for each row execute function public.trg_wa_out_failed();

-- ───────────────────────────────────────────────────────── 8. the guard sweep ──

create or replace function public.wa_notify_sweep()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_fixed int := 0; v_seen int := 0;
begin
  for r in
    select o.id, o.order_code
      from orders o
     where o.created_at between now() - interval '24 hours' and now() - interval '4 minutes'
       and not exists (select 1 from wa_send_attempts a
                        where a.order_id = o.id and a.event_key = 'order_placed' and a.ok)
       and (select count(*) from wa_send_attempts a
             where a.order_id = o.id and a.event_key = 'order_placed') < 3
     order by o.created_at
     limit 25
  loop
    v_seen := v_seen + 1;
    begin
      perform public.wa_notify_customer_event(
        'order_placed', r.id, null,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
        jsonb_build_object('order_id', r.id, 'event', 'placed'));
      v_fixed := v_fixed + 1;
    exception when others then
      perform public._wa_log_attempt('order_placed', r.id, null, 'skipped', false,
                                     'sweep_error: ' || sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'checked', v_seen, 'reattempted', v_fixed);
end $$;

comment on function public.wa_notify_sweep() is
  'CHANGE #294 — no order may exist without an attempted order_placed notification. '
  'Offset schedule (never a bare */N) per the connection-exhaustion lesson.';

-- ─────────────────────────────────────────────────────── 9. the payment path ──

create or replace function public._send_payment_qr_wa_auto(
  p_order_id uuid, p_phone text, p_amount numeric, p_kind text default 'remaining')
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $$
declare v_ph10 text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10);
begin
  if length(v_ph10) <> 10 then return jsonb_build_object('ok',false,'error','bad_phone'); end if;
  if coalesce(p_amount,0) <= 0 then return jsonb_build_object('ok',false,'error','nothing_due'); end if;

  return public.wa_notify_customer_event(
    'payment_qr', p_order_id, v_ph10,
    'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/send-payment-qr',
    jsonb_build_object('order_id', p_order_id, 'phone', v_ph10,
                       'amount', round(p_amount), 'kind', lower(coalesce(p_kind,'remaining'))));
end $$;

create or replace function public.send_payment_qr_wa(
  p_order_id uuid, p_phone text, p_amount numeric, p_kind text default 'advance')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_ph10 text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10);
  v_owner uuid; v jsonb;
begin
  select user_id into v_owner from orders where id = p_order_id;
  if v_owner is null then return jsonb_build_object('error','no_order'); end if;
  if v_owner <> ALL (public.my_owner_user_ids()) and get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  if length(v_ph10) <> 10 then return jsonb_build_object('error','bad_phone'); end if;
  if coalesce(p_amount,0) <= 0 then return jsonb_build_object('error','bad_amount'); end if;

  v := public._send_payment_qr_wa_auto(p_order_id, v_ph10, p_amount, p_kind);

  update pharmacy_profiles set last_payment_wa_no = v_ph10 where user_id = v_owner;

  return jsonb_build_object('status','queued','phone',v_ph10,'amount',round(p_amount),
                            'kind',lower(coalesce(p_kind,'advance')),'sent',v);
end $$;

-- ─────────────────────────────────────────────── 10. the admin-facing screen ──

create or replace function public.wa_send_health(p_hours integer default 48)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb; v_tot int; v_ok int; v_bad int; v_since timestamptz;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  v_since := now() - make_interval(hours => greatest(1, least(coalesce(p_hours,48), 720)));

  select count(*), count(*) filter (where a.ok), count(*) filter (where not a.ok)
    into v_tot, v_ok, v_bad
  from wa_send_attempts a
  where a.created_at >= v_since and a.path <> 'alert';

  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', a.id,
      'at', a.created_at,
      'when_label', to_char(a.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI am'),
      'title', coalesce(r.label, a.event_key),
      'order_code', o.order_code,
      'phone_label', case when a.phone is null then 'No number on file'
                          else '+91 ' || right(a.phone,10) end,
      'path_label', case a.path
                      when 'template'       then 'Approved template'
                      when 'template_retry' then 'Template retry'
                      when 'freeform'       then 'Free-form (window open)'
                      when 'alert'          then 'Admin alert'
                      else 'Not sent' end,
      'status_label', case when a.ok then 'Delivered to Meta' else 'Not delivered' end,
      'tone', case when a.ok then 'good' when a.path = 'skipped' then 'warn' else 'bad' end,
      'reason', a.reason,
      'can_retry', (not a.ok) and a.path <> 'alert' and a.order_id is not null,
      'event_key', a.event_key
    ) as x
    from wa_send_attempts a
    left join wa_event_routes r on r.event_key = a.event_key
    left join orders o on o.id = a.order_id
    where a.created_at >= v_since
    order by a.created_at desc
    limit 60
  ) s;

  return jsonb_build_object(
    'ok', true,
    'heading', 'Notification delivery',
    'window_note', 'Free-form messages are only allowed for 24h after the customer '
                   'writes to us. Outside that window mediBO sends the approved template.',
    'range_label', 'Last ' || greatest(1, least(coalesce(p_hours,48), 720)) || ' hours',
    'summary_label', v_tot || ' attempts · ' || v_ok || ' delivered · ' || v_bad || ' not delivered',
    'summary_tone', case when v_bad = 0 then 'good' when v_bad <= 2 then 'warn' else 'bad' end,
    'empty_label', 'No customer notifications in this window yet.',
    'retry_label', 'Resend',
    'rows', v_rows);
end $$;

grant execute on function public.wa_send_health(integer) to authenticated;

create or replace function public.wa_send_retry(p_attempt_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare a record; v jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select * into a from wa_send_attempts where id = p_attempt_id;
  if a.id is null then return jsonb_build_object('error','not_found'); end if;

  v := public.wa_notify_customer_event(a.event_key, a.order_id, a.phone,
        case when a.event_key in ('order_placed','order_updated','order_accepted','order_rejected')
             then 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify' end,
        case when a.event_key in ('order_placed','order_updated','order_accepted','order_rejected')
             then jsonb_build_object('order_id', a.order_id,
                                     'event', replace(a.event_key,'order_','')) end);

  return jsonb_build_object(
    'ok', coalesce((v->>'ok')::boolean,false),
    'message', case when coalesce((v->>'ok')::boolean,false)
                    then 'Sent again — check Notification delivery in a moment.'
                    else 'Could not send: ' || coalesce(v->>'reason','unknown') end,
    'detail', v);
end $$;

grant execute on function public.wa_send_retry(bigint) to authenticated;

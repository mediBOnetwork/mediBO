-- ============================================================================
-- CHANGE #306 — two fixes the ladder rehearsal caught before a single alert
-- ever rang (found by replaying every rung inside a rolled-back transaction).
--
-- 1. notification_log.recipient is NOT NULL, and an admin's device row has no
--    phone10 — so the very first real ring would have thrown inside
--    order_alert_push(), aborting the whole dispatcher tick with it. The
--    recipient is now the admin's phone when there is one and their user id
--    when there is not: the column's job is to identify who was reached, and a
--    user id does that for a device.
-- 2. order_alert_tick() counted a "ring" for alerts that cannot ring (the
--    backfilled pre-#306 orders carry ring=false). No push was ever sent for
--    them — order_alert_push refuses those — but the tick called it once per
--    alert per minute and reported a number that was not true. Skip them.
-- ============================================================================
create or replace function public.order_alert_push(p_alert_id bigint, p_kind text default 'new')
returns jsonb
language plpgsql security definer set search_path to 'public', 'net' as $$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; u record;
  v_vars jsonb; v_title text; v_body text; v_count int; v_tok text;
  v_log bigint; v_req bigint; v_sent int := 0; v_alert jsonb; v_ongoing text;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', false, 'reason','alerts_disabled');
  end if;
  select * into a from public.order_alert where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'reason','no_alert'); end if;
  if a.state <> 'ringing' or not a.ring then
    return jsonb_build_object('ok', false, 'reason','not_ringing');
  end if;

  v_count := public.order_alert_open_count();
  v_vars := jsonb_build_object(
    'customer',   coalesce(a.customer_name,''),
    'order_code', coalesce(a.order_code,''),
    'amount',     public.inr_money(a.amount),
    'age',        public._oa_age_label(a.created_at),
    'count',      v_count::text);

  v_title := public.oa_label(case when p_kind='critical' then 'push_title_critical'
                                  else 'push_title' end, v_vars);
  v_body  := public.oa_label(case when p_kind='critical' then 'push_body_critical'
                                  else 'push_body' end, v_vars);
  v_ongoing := case when v_count = 1 then public.oa_label('ongoing_title_one', v_vars)
                    else public.oa_label('ongoing_title', v_vars) end;

  for u in
    select t.user_id, min(t.phone10) as phone10, jsonb_agg(distinct t.token) tokens
      from public.push_tokens t
     where t.is_active and t.user_id is not null
       and t.role in ('admin','super_admin')
     group by t.user_id
  loop
    v_tok := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
    insert into public.order_alert_token (token, alert_id, user_id, expires_at)
    values (v_tok, a.id, u.user_id, coalesce(a.expires_at, now() + interval '6 hours'));

    insert into public.notification_log
      (event_key, recipient, channel, status, ok, audience, recipient_id, user_id,
       order_id, customer_id, title, body, deep_link, language, vars, payload, path)
    values
      ('order_alert_new',
       coalesce(nullif(btrim(u.phone10),''), u.user_id::text),
       'push', 'queued', null, 'admin', u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, '/admin/order-alerts', 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind), 'push')
    returning id into v_log;

    v_alert := jsonb_build_object(
      'kind',                'order_alert',
      'alert_id',            a.id,
      'push_title',          v_title,
      'push_body',           v_body,
      'order_id',            a.order_id,
      'order_code',          coalesce(a.order_code,''),
      'customer',            coalesce(a.customer_name,''),
      'amount',              public.inr_money(a.amount),
      'critical',            (p_kind = 'critical'),
      'credit_note',         coalesce(a.credit_note,''),
      'credit_blocked',      a.credit_blocked,
      'accept_label',        public.oa_label('accept_label'),
      'reject_label',        public.oa_label('reject_label'),
      'view_label',          public.oa_label('view_label'),
      'channel_id',          'medibo_order_alert',
      'channel_name',        public.oa_label('channel_name'),
      'channel_description', public.oa_label('channel_description'),
      'ring_seconds',        cfg.ring_seconds,
      'full_screen',         true,
      'pending_count',       v_count,
      'ongoing_title',       v_ongoing,
      'ongoing_body',        public.oa_label('ongoing_body'),
      'action_token',        v_tok,
      'action_url',          'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-alert-action');

    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('log_id', v_log, 'tokens', u.tokens,
                                    'title', v_title, 'body', v_body,
                                    'deep_link', '/admin/order-alerts',
                                    'event_key', 'order_alert_new',
                                    'order_id', a.order_id,
                                    'alert', v_alert),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  update public.order_alert
     set push_count    = push_count + 1,
         last_push_at  = now(),
         first_push_at = coalesce(first_push_at, now())
   where id = a.id;

  if v_sent = 0 then return jsonb_build_object('ok', false, 'reason','no_admin_device'); end if;
  return jsonb_build_object('ok', true, 'devices', v_sent, 'kind', p_kind);
end $$;

-- An alert that cannot ring is still watched (it is in the badge and the feed,
-- and it can still be paid or actioned) — it is only the RINGING rungs it is
-- excluded from.
create or replace function public.order_alert_tick()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype;
  v_age int; v_paid int := 0; v_rang int := 0; v_wa int := 0;
  v_crit int := 0; v_cancel int := 0; v_phone text; v_vars jsonb;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', true, 'skipped','disabled');
  end if;

  for a in select * from public.order_alert where state = 'ringing' order by created_at
  loop
    v_age := greatest(extract(epoch from (now() - a.created_at))::int, 0);

    -- 1. The money landed. This is the prepaid path: it auto-accepts, exactly
    --    as it does today, and was never heard.
    if public.order_is_paid(a.order_id) then
      update public.order_alert
         set state='accepted', risk='prepaid', ring=false, actioned_at=now(),
             actioned_by_label='payment', action_source='auto',
             action_reason='payment_verified'
       where id = a.id;
      v_paid := v_paid + 1;
      continue;
    end if;

    -- Everything below is the RINGING ladder. An alert that does not ring
    -- (the pre-#306 backfill) is watched for payment above and left alone.
    if not a.ring then continue; end if;

    -- 2. Out of time — cancel and release whatever it was holding.
    if a.expires_at is not null and now() >= a.expires_at then
      update public.order_alert
         set state='auto_cancelled', ring=false, actioned_at=now(),
             actioned_by_label='auto', action_source='auto',
             action_reason='autocancel_window'
       where id = a.id;
      perform public._oa_release_and_cancel(a.order_id,
        public.oa_label('auto_cancel_reason',
          jsonb_build_object('window', cfg.autocancel_after_min::text)),
        'order_alert_auto');
      v_cancel := v_cancel + 1;
      continue;
    end if;

    -- 3. First ring, once the payment grace window has passed.
    if a.push_count = 0 then
      if v_age >= cfg.ring_delay_s then
        perform public.order_alert_push(a.id, 'new');
        v_rang := v_rang + 1;
      end if;
      continue;
    end if;

    -- 4. Critical.
    if v_age >= cfg.critical_after_s and a.stage <> 'critical' then
      update public.order_alert set stage='critical', critical_at=now() where id = a.id;
      perform public.order_alert_push(a.id, 'critical');
      v_crit := v_crit + 1;
      continue;
    end if;

    -- 5. WhatsApp the admin.
    if v_age >= cfg.wa_after_s and a.wa_sent_at is null then
      v_vars := jsonb_build_object(
        'customer',   coalesce(a.customer_name,''),
        'order_code', coalesce(a.order_code,''),
        'amount',     public.inr_money(a.amount),
        'age',        public._oa_age_label(a.created_at),
        'order_id',   a.order_id::text,
        '_no_push',   true);
      foreach v_phone in array coalesce(public._oa_admin_phones(), '{}'::text[])
      loop
        begin
          perform public.notify('order_alert_escalation', v_phone, v_vars);
        exception when others then null;
        end;
      end loop;
      update public.order_alert set wa_sent_at=now(), stage='whatsapp' where id = a.id;
      v_wa := v_wa + 1;
      continue;
    end if;

    -- 6. Keep ringing.
    if a.last_push_at is not null
       and now() - a.last_push_at >= make_interval(secs => greatest(cfg.rering_after_s,15))
       and a.push_count < 30 then
      perform public.order_alert_push(a.id,
        case when a.stage = 'critical' then 'critical' else 'new' end);
      if a.stage = 'new' then
        update public.order_alert set stage='rering' where id = a.id;
      end if;
      v_rang := v_rang + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'auto_accepted', v_paid, 'rang', v_rang,
                            'whatsapp', v_wa, 'critical', v_crit,
                            'auto_cancelled', v_cancel);
end $$;

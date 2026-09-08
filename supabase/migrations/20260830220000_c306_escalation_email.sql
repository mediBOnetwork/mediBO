-- ============================================================================
-- CHANGE #306 — make the 3-minute rung actually arrive.
--
-- The WhatsApp escalation route is configured and enabled, but Meta has no
-- `order_alert_escalation` template yet, so notify() correctly refuses to send
-- and queues it (visible in WhatsApp Ops → Notification delivery). Queued is
-- not reached: an unpaid order sitting unactioned is exactly when a second
-- channel has to work. The email stack from #299 does work today and the
-- admins table already holds the addresses, so the rung sends BOTH — the
-- WhatsApp as before (it starts landing the moment the template is approved,
-- with no code change) and an email now.
-- ============================================================================
update public.wa_event_routes
   set email_enabled = true,
       email_mode    = 'always',
       email_subject = 'Unpaid order {{order_code}} is waiting',
       email_body    = 'Order {{order_code}} from {{customer}} for {{amount}} is UNPAID and has been waiting {{age}}.'
                       || E'\n\nAccepting it starts the supplier inquiry only — it does not authorise buying the stock.'
                       || E'\n\nOpen mediBO ▸ Admin ▸ New-order alerts to accept or reject it.'
 where event_key = 'order_alert_escalation';

-- Who the escalation email reaches: every admin on the platform, from the one
-- table that defines what an admin is.
create or replace function public._oa_admin_emails()
returns text[]
language sql stable security definer set search_path to 'public' as $$
  select array(select distinct lower(btrim(a.email)) from public.admins a
                where coalesce(btrim(a.email),'') <> '')
$$;

create or replace function public.order_alert_tick()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype;
  v_age int; v_paid int := 0; v_rang int := 0; v_wa int := 0;
  v_crit int := 0; v_cancel int := 0; v_phone text; v_mail text; v_vars jsonb;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', true, 'skipped','disabled');
  end if;

  for a in select * from public.order_alert where state = 'ringing' order by created_at
  loop
    v_age := greatest(extract(epoch from (now() - a.created_at))::int, 0);

    -- 1. The money landed: the prepaid path auto-accepts and was never heard.
    if public.order_is_paid(a.order_id) then
      update public.order_alert
         set state='accepted', risk='prepaid', ring=false, actioned_at=now(),
             actioned_by_label='payment', action_source='auto',
             action_reason='payment_verified'
       where id = a.id;
      v_paid := v_paid + 1;
      continue;
    end if;

    -- An alert that does not ring (the pre-#306 backfill) is watched for
    -- payment above and excluded from every ringing rung below.
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

    -- 5. Reach the admin off-device: WhatsApp and email, neither able to break
    --    the tick.
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
      foreach v_mail in array coalesce(public._oa_admin_emails(), '{}'::text[])
      loop
        begin
          perform public.notif_send_email('order_alert_escalation', v_mail,
                    v_vars - '_no_push', null, a.order_id);
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

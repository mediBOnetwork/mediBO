-- CMD #2015 — the endless order-alert ringtone, ended.
--
-- What was wrong, in the order it hurt:
--   1. A synthetic (test-mode) alert pushed to a real phone. The row it named
--      was invisible to that phone, so nothing on the device could ever stop
--      it — the only exit was uninstalling the app.
--   2. The Android channel used USAGE_ALARM + setBypassDnd(true), so silent
--      mode, vibrate mode, Do Not Disturb and the volume keys were all
--      bypassed by design.
--   3. MediaPlayer.isLooping = true for ring_seconds, re-armed by a re-ring
--      rung that allowed push_count < 30. Thirty two-minute alarm loops.
--   4. Nothing counted RINGS, so there was no cap to reach.
--   5. There was no kill switch that silenced devices already holding an alert.
--
-- The policy now lives here, in the backend, and the device only renders it:
--   * is_synthetic never leaves the building (no push at all).
--   * mute_all silences every device on the next push AND through
--     order_alert_reconcile(), which every app start and every foreground asks.
--   * ring_cap (3) counts RINGS, not pushes. Ring 4 does not exist.
--   * the channel id moved to medibo_order_alert_v2 — an Android channel's
--     sound and DND-bypass cannot be changed after creation, so the only way
--     to un-bypass an installed phone is a NEW channel (the app deletes the
--     old one).
--
-- Idempotent: every statement is add-if-missing or create-or-replace.

-- ── 1. Config: the kill switch and the cap ────────────────────────────────
alter table public.order_alert_config
  add column if not exists mute_all boolean not null default false;
alter table public.order_alert_config
  add column if not exists ring_cap integer not null default 3;

-- ── 2. The alert counts its own rings ─────────────────────────────────────
alter table public.order_alert
  add column if not exists ring_count integer not null default 0;
alter table public.order_alert
  add column if not exists stopped_at timestamptz;

-- ── 3. Copy. Every word the phone and the settings screen show is here. ────
update public.order_alert_config set labels = coalesce(labels,'{}'::jsonb) || jsonb_build_object(
  'section_silence',   'Silence',
  'field_mute_all',    'Silence all order alerts',
  'field_ring_cap',    'Maximum rings per order',
  'silence_note',      'Alerts still arrive and stay in the tray — they just never make a sound on any device.',
  'mute_banner',       'Order alerts are silenced on every device.',
  'stop_label',        'Stop',
  'stop_toast',        'Alert silenced',
  'channel_name',      'Orders',
  'channel_description', 'New orders waiting to be opened'
) where id = 'singleton';

-- ── 4. A ring is a decision, and this is the only place it is taken ───────
create or replace function public._oa_ring_allowed(a public.order_alert)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select not coalesce(a.is_synthetic,false)
     and a.stopped_at is null
     and coalesce(a.ring,false)
     and a.state = 'ringing'
     and not coalesce((select c.mute_all from public.order_alert_config c where c.id='singleton'), false)
     and coalesce(a.ring_count,0)
         < greatest(coalesce((select c.ring_cap from public.order_alert_config c where c.id='singleton'), 3), 0)
$$;

-- ── 5. Stop: the notification's own button, and the app's ─────────────────
create or replace function public._oa_apply_action(p_alert_id bigint, p_action text, p_reason text, p_by uuid, p_by_label text, p_source text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; v_credit jsonb;
begin
  cfg := public._oa_cfg();
  select * into a from public.order_alert where id = p_alert_id for update;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','no_alert',
                              'message', public.oa_label('toast_already'));
  end if;

  -- CMD #2015 — Stop kills the SOUND, not the order. It is allowed on an
  -- alert that has already been actioned (the button is on a notification
  -- that may still be in the tray), and it is permanent: stopped_at is what
  -- _oa_ring_allowed() reads, so nothing re-rings this alert ever again.
  if p_action = 'stop' then
    update public.order_alert
       set stopped_at = coalesce(stopped_at, now()), ring = false
     where id = a.id;
    return jsonb_build_object('ok', true, 'state', a.state, 'stopped', true,
      'message', public.oa_label('stop_toast'));
  end if;

  if a.state <> 'ringing' then
    return jsonb_build_object('ok', false, 'error','already_actioned',
                              'state', a.state,
                              'message', public.oa_label('toast_already'));
  end if;

  if p_action = 'accept' then
    v_credit := public.customer_credit_state(a.customer_id);
    if coalesce((v_credit->>'blocked')::boolean, false)
       and not public.order_is_paid(a.order_id) then
      update public.order_alert
         set credit_blocked = true, credit_note = v_credit->>'message'
       where id = a.id;
      return jsonb_build_object('ok', false, 'error','credit_blocked',
        'message', public.oa_label('toast_blocked',
                     jsonb_build_object('reason', coalesce(v_credit->>'message',''))),
        'credit', v_credit);
    end if;

    update public.order_alert
       set state='accepted', actioned_at=now(), actioned_by=p_by,
           actioned_by_label=p_by_label, action_reason=p_reason, action_source=p_source
     where id = a.id;
    return jsonb_build_object('ok', true, 'state','accepted',
      'message', public.oa_label('toast_accepted'));

  elsif p_action = 'reject' then
    update public.order_alert
       set state='rejected', actioned_at=now(), actioned_by=p_by,
           actioned_by_label=p_by_label, action_reason=p_reason, action_source=p_source
     where id = a.id;
    perform public._oa_release_and_cancel(a.order_id,
      coalesce(nullif(btrim(p_reason),''), public.oa_label('state_rejected')),
      coalesce(p_by_label,'admin'));
    return jsonb_build_object('ok', true, 'state','rejected',
      'message', public.oa_label('toast_rejected'));
  end if;

  return jsonb_build_object('ok', false, 'error','unknown_action');
end $function$;

-- The in-app Stop, for the signed-in admin.
create or replace function public.order_alert_stop(p_alert_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_label text;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  return public._oa_apply_action(p_alert_id, 'stop', null, auth.uid(),
                                 coalesce(v_label,'admin'), 'notification');
end $function$;
grant execute on function public.order_alert_stop(bigint) to authenticated;

-- ── 6. Reconcile: the device asks, the server answers, the device obeys ───
-- Called on app start and on every foreground. An alert exists on this phone
-- only because this list says so; anything else is cancelled and silenced.
create or replace function public.order_alert_reconcile()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; v_role text; v_uid uuid := auth.uid();
  v_live jsonb; v_ids jsonb; v_count int;
begin
  cfg := public._oa_cfg();
  v_role := public.get_my_role();
  if v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', true, 'cancel_all', true, 'live', '[]'::jsonb,
      'live_ids', '[]'::jsonb, 'mute_all', true, 'count', 0);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'alert_id', a.id,
           'order_id', a.order_id,
           'ring',     public._oa_ring_allowed(a)) order by a.created_at), '[]'::jsonb),
         coalesce(jsonb_agg(a.id order by a.created_at), '[]'::jsonb),
         count(*)::int
    into v_live, v_ids, v_count
    from public.order_alert a
   where a.state = 'ringing'
     and not coalesce(a.is_synthetic, false)
     and coalesce(cfg.enabled, false)
     and ( v_role in ('admin','super_admin')
           or a.partner_id = any (coalesce(public._oa_partner_zone_ids(v_uid), '{}'::bigint[])) );

  return jsonb_build_object(
    'ok',                  true,
    'enabled',             coalesce(cfg.enabled,false),
    'mute_all',            coalesce(cfg.mute_all,false),
    'ring_cap',            greatest(coalesce(cfg.ring_cap,3),0),
    'channel_id',          'medibo_order_alert_v2',
    'channel_name',        public.oa_label('channel_name'),
    'channel_description', public.oa_label('channel_description'),
    'stop_label',          public.oa_label('stop_label'),
    'live',                v_live,
    'live_ids',            v_ids,
    'count',               v_count,
    'cancel_all',          (v_count = 0),
    'ongoing_title',       case when v_count = 1 then public.oa_label('ongoing_title_one')
                                else public.oa_label('ongoing_title',
                                       jsonb_build_object('count', v_count::text)) end,
    'ongoing_body',        public.oa_label('ongoing_body'));
end $function$;
grant execute on function public.order_alert_reconcile() to authenticated;

-- A partner's alerts, by the partner rows they belong to. Small helper so the
-- reconcile above stays readable; admins never reach it.
create or replace function public._oa_partner_zone_ids(p_uid uuid)
returns bigint[]
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(array_agg(distinct pu.partner_id), '{}'::bigint[])
    from public.partner_users pu
    join public.region_partners rp on rp.id = pu.partner_id
   where pu.auth_user_id = p_uid
     and coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
$$;

-- ── 7. The push. One ring decision, taken here, rendered on the phone. ────
create or replace function public.order_alert_push_raw(p_alert_id bigint, p_kind text default 'new', p_audience text default null)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; u record;
  v_vars jsonb; v_title text; v_body text; v_count int;
  v_log bigint; v_req bigint; v_sent int := 0; v_alert jsonb; v_ongoing text;
  v_aud text; v_deep text; v_uids uuid[]; v_paid boolean; v_silent boolean;
  v_items text; v_icount int; v_silenced int := 0; v_rang int := 0;
  v_ring_allowed boolean; v_stop_token text; v_stop_url text;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', false, 'reason','alerts_disabled');
  end if;
  select * into a from public.order_alert where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'reason','no_alert'); end if;

  -- CMD #2015 item 2 — a synthetic alert never reaches a real device at all.
  -- It is visible inside test mode, where the row it names is also visible.
  -- This is the bug that made the ring unstoppable: a notification naming a
  -- row the phone could not see, so nothing on the phone could clear it.
  if coalesce(a.is_synthetic, false) then
    return jsonb_build_object('ok', false, 'reason','synthetic_never_pushed');
  end if;

  if public.test_outbound_silenced(a.test_session_id) or public.test_order_silenced(a.order_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if a.state <> 'ringing' or not a.ring then
    return jsonb_build_object('ok', false, 'reason','not_ringing');
  end if;
  if public._oa_open_quiet(a) then
    return jsonb_build_object('ok', true, 'reason','opened_elsewhere', 'devices', 0);
  end if;

  -- CMD #2015 items 3 + 6 — the kill switch and the cap. Neither withholds
  -- the alert: the notification still lands and still opens the order. They
  -- decide only whether the phone is allowed to make a sound.
  v_ring_allowed := public._oa_ring_allowed(a);

  v_aud := coalesce(nullif(btrim(p_audience),''), public._oa_audience(a));
  v_deep := case when v_aud = 'partner' then '/partner' else '/admin/order-alerts' end;
  if v_aud = 'partner' then
    v_uids := public._oa_partner_user_ids(a.partner_id);
    if coalesce(array_length(v_uids,1),0) = 0 then
      v_aud := 'admin';
      v_deep := '/admin/order-alerts';
    end if;
  end if;

  v_paid   := public.order_is_paid(a.order_id);
  v_icount := public._oa_item_count(a.order_id);
  v_items  := public._oa_items_label(a.order_id);
  v_stop_url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-alert-action';

  v_count := (select count(*)::int from public.order_alert al
               where al.state = 'ringing'
                 and not coalesce(al.is_synthetic,false)
                 and (v_aud <> 'partner' or al.partner_id = a.partner_id));
  v_vars := jsonb_build_object(
    'customer',   coalesce(a.customer_name,''),
    'order_code', coalesce(a.order_code,''),
    'amount',     public.inr_money(a.amount),
    'age',        public._oa_age_label(a.created_at),
    'items',      v_items,
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
       and ( (v_aud = 'partner' and t.user_id = any (v_uids))
          or (v_aud <> 'partner' and t.role in ('admin','super_admin')) )
     group by t.user_id
  loop
    v_silent := (not v_ring_allowed) or public._oa_silent_for(u.user_id, null);
    if v_silent then v_silenced := v_silenced + 1; else v_rang := v_rang + 1; end if;

    -- CMD #2015 item 5 — the Stop button's one-shot token. It opens exactly
    -- one door (order_alert_action_by_token with action 'stop') and dies with
    -- the alert.
    v_stop_token := md5(gen_random_uuid()::text || clock_timestamp()::text || a.id::text);
    insert into public.order_alert_token (token, alert_id, user_id, expires_at)
    values (v_stop_token, a.id, u.user_id,
            coalesce(a.expires_at, now() + interval '6 hours'));

    insert into public.notification_log
      (event_key, recipient, channel, status, ok, audience, recipient_id, user_id,
       order_id, customer_id, title, body, deep_link, language, vars, payload, path)
    values
      ('order_alert_new',
       coalesce(nullif(btrim(u.phone10),''), u.user_id::text),
       'push', 'queued', null, v_aud, u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, v_deep, 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind, 'audience', v_aud,
                                  'silent', v_silent, 'view_only', true,
                                  'ring_count', a.ring_count, 'ring_cap', cfg.ring_cap), 'push')
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
      'item_count',          v_icount,
      'items_label',         v_items,
      'age_label',           public._oa_age_label(a.created_at),
      'paid',                v_paid,
      'risk',                case when v_paid then 'prepaid' else 'unpaid' end,
      'risk_label',          public.oa_label(case when v_paid then 'strip_prepaid'
                                                  else 'strip_unpaid' end),
      'critical',            (p_kind = 'critical'),
      'credit_note',         coalesce(a.credit_note,''),
      'credit_blocked',      a.credit_blocked,
      'audience',            v_aud,
      'view_only',           true,
      'open_label',          public.oa_label('open_label'),
      'view_only_note',      public.oa_label('push_view_only_note'),
      'deep_link',           v_deep,
      -- CMD #2015 item 4 — the NEW channel. medibo_order_alert used
      -- USAGE_ALARM and setBypassDnd(true); a channel's sound and DND bypass
      -- are immutable once created, so the only way off it on a phone that
      -- already has the app is a different id. The app deletes the old one.
      'channel_id',          'medibo_order_alert_v2',
      'channel_name',        public.oa_label('channel_name'),
      'channel_description', public.oa_label('channel_description'),
      'silent',              v_silent,
      'is_synthetic',        false,
      'mute_all',            coalesce(cfg.mute_all,false),
      'ring_cap',            greatest(coalesce(cfg.ring_cap,3),0),
      'ring_index',          coalesce(a.ring_count,0),
      'ring_seconds',        case when v_silent then 0
                                  else least(greatest(coalesce(cfg.ring_seconds,20),5), 20) end,
      -- Never a full-screen takeover any more: a full-screen intent needs the
      -- alarm/call treatment this change is removing.
      'full_screen',         false,
      'stop_label',          public.oa_label('stop_label'),
      'stop_token',          v_stop_token,
      'stop_url',            v_stop_url,
      'pending_count',       v_count,
      'ongoing_title',       v_ongoing,
      'ongoing_body',        public.oa_label('ongoing_body'),
      'notif',               public.order_alert_notif(a.id, p_kind));

    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('log_id', v_log, 'tokens', u.tokens,
                                    'title', v_title, 'body', v_body,
                                    'deep_link', v_deep,
                                    'event_key', 'order_alert_new',
                                    'order_id', a.order_id,
                                    'alert', v_alert),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  update public.order_alert
     set push_count    = push_count + 1,
         -- A RING is counted once per push that actually made a sound
         -- somewhere. Ring 4 does not exist: _oa_ring_allowed() reads this.
         ring_count    = ring_count + case when v_rang > 0 then 1 else 0 end,
         last_push_at  = now(),
         first_push_at = coalesce(first_push_at, now()),
         audience      = v_aud,
         partner_push_count = partner_push_count + case when v_aud='partner' then 1 else 0 end,
         partner_first_push_at = case when v_aud='partner'
                                      then coalesce(partner_first_push_at, now())
                                      else partner_first_push_at end
   where id = a.id;

  if v_sent = 0 then
    return jsonb_build_object('ok', false, 'audience', v_aud,
      'reason', case when v_aud='partner' then 'no_partner_device' else 'no_admin_device' end);
  end if;
  return jsonb_build_object('ok', true, 'devices', v_sent, 'silenced', v_silenced,
                            'rang', v_rang, 'ring_allowed', v_ring_allowed,
                            'ring_count', coalesce(a.ring_count,0) + case when v_rang > 0 then 1 else 0 end,
                            'ring_cap', cfg.ring_cap,
                            'view_only', true, 'kind', p_kind, 'audience', v_aud);
end $function$;

-- ── 8. The tick: muted stops it, and the cap ends the re-ring ─────────
create or replace function public.order_alert_tick()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype;
  v_age int; v_paid int := 0; v_rang int := 0; v_wa int := 0;
  v_crit int := 0; v_cancel int := 0; v_esc int := 0; v_partner int := 0;
  v_quiet int := 0;
  v_phone text; v_mail text; v_vars jsonb; v_res jsonb;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', true, 'skipped','disabled');
  end if;

  -- CMD #2015 — the kill switch stops the whole tick's ringing work.
  if coalesce(cfg.mute_all,false) then
    return jsonb_build_object('ok', true, 'skipped','muted');
  end if;

  for a in select * from public.order_alert where state = 'ringing'
            and not coalesce(is_synthetic,false) order by created_at
  loop
    v_age := greatest(extract(epoch from (now() - a.created_at))::int, 0);

    -- CMD #1988 — a paid order is NO LONGER auto-accepted here. Payment is not
    -- a decision; somebody still has to look at the order. It rings like any
    -- other until a human opens it and accepts or rejects it on the order
    -- screen. What payment DOES buy it is safety from the auto-cancel below.

    -- An alert that does not ring (the pre-#306 backfill) is excluded from
    -- every ringing rung below.
    if not a.ring then continue; end if;

    -- CMD #1988 item 4 — STOP ON OPEN. Somebody has this order open on some
    -- device: no ring, no escalation, no WhatsApp, until the re-ring window
    -- has passed with the order still unactioned.
    if public._oa_open_quiet(a) then
      v_quiet := v_quiet + 1;
      continue;
    end if;

    -- Out of time — cancel and release whatever it was holding. Never for an
    -- order the customer has already paid for.
    if a.expires_at is not null and now() >= a.expires_at then
      if public.order_is_paid(a.order_id) then
        v_paid := v_paid + 1;
      else
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
    end if;

    -- First ring. ring_delay_s is 0 now and the trigger already fired on
    -- insert, so this rung only catches an alert whose insert-time push failed.
    if a.push_count = 0 then
      if v_age >= coalesce(cfg.ring_delay_s, 0) then
        v_res := public.order_alert_push(a.id, 'new');
        if coalesce(v_res->>'audience','') = 'partner' then v_partner := v_partner + 1; end if;
        v_rang := v_rang + 1;
      end if;
      continue;
    end if;

    -- ESCALATION. The partner was rung and nobody accepted inside the window,
    -- so the admin becomes the audience from here on.
    if a.audience = 'partner' and a.escalated_at is null
       and v_age >= greatest(coalesce(cfg.ring_delay_s,0),0) + greatest(cfg.partner_escalate_after_s,15) then
      update public.order_alert set escalated_at = now(), audience = 'admin' where id = a.id;
      perform public.order_alert_push(a.id,
        case when a.stage = 'critical' then 'critical' else 'new' end, 'admin');
      v_esc := v_esc + 1;
      continue;
    end if;

    -- Critical.
    if v_age >= cfg.critical_after_s and a.stage <> 'critical' then
      update public.order_alert set stage='critical', critical_at=now() where id = a.id;
      perform public.order_alert_push(a.id, 'critical');
      v_crit := v_crit + 1;
      continue;
    end if;

    -- Reach the admin off-device: WhatsApp and email, neither able to break
    -- the tick. An order that is already paid for is not chased off-device.
    if v_age >= cfg.wa_after_s and a.wa_sent_at is null
       and not public.order_is_paid(a.order_id) then
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

    -- Keep ringing — this is also the re-ring an opened-but-unactioned order
    -- gets once its quiet window above has expired.
    -- CMD #2015 item 3 — the HARD CAP. push_count < 30 allowed thirty
    -- re-rings; ring_count is the number of times a phone actually made a
    -- sound and it stops at ring_cap (3). The notification that is already in
    -- the tray stays there — it simply never rings again.
    if a.last_push_at is not null
       and now() - a.last_push_at >= make_interval(secs => greatest(cfg.rering_after_s,15))
       and coalesce(a.ring_count,0) < greatest(coalesce(cfg.ring_cap,3),0)
       and a.stopped_at is null
       and a.push_count < 30 then
      perform public.order_alert_push(a.id,
        case when a.stage = 'critical' then 'critical' else 'new' end);
      if a.stage = 'new' then
        update public.order_alert set stage='rering' where id = a.id;
      end if;
      v_rang := v_rang + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'paid_held', v_paid, 'rang', v_rang,
                            'partner_rings', v_partner, 'escalated', v_esc,
                            'open_quiet', v_quiet,
                            'whatsapp', v_wa, 'critical', v_crit,
                            'auto_cancelled', v_cancel);
end 
$function$;

-- ── 9. Settings: the kill switch is a field, so the screen just draws it ──
create or replace function public.order_alert_settings()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare cfg public.order_alert_config; v_phone text; v_open jsonb; v_log jsonb;
        v_zone smallint; v_cut time;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg := public._oa_cfg();
  v_phone := coalesce((select value #>> '{}' from public.app_settings
                        where key='admin_wa_phone'), '');
  -- CMD #1847 QA fix: zone_effective() is what set_order_hours() writes to.
  v_zone := public.zone_effective(public.admin_active_zone());
  select h.cutoff_time into v_cut from public.order_hours h where h.zone_id = v_zone;

  select coalesce(jsonb_agg(public._oa_item(a) order by a.created_at desc), '[]'::jsonb)
    into v_open
    from public.order_alert a where a.state = 'ringing';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id,
           'order_code', coalesce((select o.order_code from public.orders o where o.id = l.order_id),''),
           'supplier', coalesce(l.supplier_name,''),
           'allowed', l.allowed,
           'reason', coalesce(l.reason,''),
           'reason_label', public.oa_label(coalesce(l.detail->>'reason', l.reason)),
           'when_label', public._oa_age_label(l.created_at)) order by l.created_at desc), '[]'::jsonb)
    into v_log
    from (select * from public.purchase_gate_log order by created_at desc limit 30) l;

  return jsonb_build_object(
    'ok', true,
    'title',    public.oa_label('settings_title'),
    'subtitle', public.oa_label('settings_subtitle'),
    'sections', jsonb_build_object(
       'timings', public.oa_label('section_timings'),
       'credit',  public.oa_label('section_credit'),
       'open',    public.oa_label('section_open'),
       'log',     public.oa_label('section_log'),
       'cutoff',  public.oa_label('section_cutoff'),
       'device',  public.oa_label('fsi_section')),
    -- CMD #2015 item 6 — the kill switch. priority:true puts the group at the
    -- top of the screen; the screen never learns the words or the keys.
    'mute_all', coalesce(cfg.mute_all,false),
    'mute_banner', case when coalesce(cfg.mute_all,false)
                        then public.oa_label('mute_banner') else '' end,
    'groups', jsonb_build_array(
      jsonb_build_object('key','silence','label', public.oa_label('section_silence'),
        'priority', true, 'note', public.oa_label('silence_note'),
        'fields', jsonb_build_array('mute_all','ring_cap')),
      jsonb_build_object('key','cutoff','label', public.oa_label('section_cutoff'),
        'fields', jsonb_build_array('cutoff_enabled','cutoff_time','cutoff_default_time',
          'cutoff_warn1_min','cutoff_warn2_min','cutoff_cancel_after_min',
          'cutoff_restore_min','cutoff_extend_min','cutoff_pause_outside_hours',
          'cutoff_behaviour','cutoff_warn_text'))),
    'fields', jsonb_build_array(
      jsonb_build_object('key','mute_all','label',public.oa_label('field_mute_all'),
                         'type','bool','value',coalesce(cfg.mute_all,false),
                         'hint',public.oa_label('silence_note')),
      jsonb_build_object('key','ring_cap','label',public.oa_label('field_ring_cap'),
                         'type','int','value',greatest(coalesce(cfg.ring_cap,3),0)),
      jsonb_build_object('key','enabled','label',public.oa_label('field_enabled'),
                         'type','bool','value',cfg.enabled),
      jsonb_build_object('key','ring_delay_s','label',public.oa_label('field_ring_delay'),
                         'type','int','value',cfg.ring_delay_s),
      jsonb_build_object('key','rering_after_s','label',public.oa_label('field_rering'),
                         'type','int','value',cfg.rering_after_s),
      jsonb_build_object('key','wa_after_s','label',public.oa_label('field_wa'),
                         'type','int','value',cfg.wa_after_s),
      jsonb_build_object('key','critical_after_s','label',public.oa_label('field_critical'),
                         'type','int','value',cfg.critical_after_s),
      jsonb_build_object('key','ring_seconds','label',public.oa_label('field_ring_seconds'),
                         'type','int','value',cfg.ring_seconds),
      jsonb_build_object('key','autocancel_after_min','label',public.oa_label('field_autocancel'),
                         'type','int','value',cfg.autocancel_after_min),
      jsonb_build_object('key','admin_wa_phone','label',public.oa_label('escalation_phone_label'),
                         'type','text','value',v_phone,
                         'hint',public.oa_label('escalation_phone_hint')),
      jsonb_build_object('key','new_customer_prepaid_only','label',public.oa_label('field_prepaid_new'),
                         'type','bool','value',cfg.new_customer_prepaid_only),
      jsonb_build_object('key','established_credit_limit','label',public.oa_label('field_established_limit'),
                         'type','money','value',cfg.established_credit_limit,
                         'display',public.inr_money(cfg.established_credit_limit)),
      jsonb_build_object('key','established_min_paid_orders','label',public.oa_label('field_min_paid'),
                         'type','int','value',cfg.established_min_paid_orders),
      jsonb_build_object('key','enforce_credit_block','label',public.oa_label('field_enforce'),
                         'type','bool','value',cfg.enforce_credit_block),
      jsonb_build_object('key','purchase_gate_enabled','label',public.oa_label('field_gate'),
                         'type','bool','value',cfg.purchase_gate_enabled),
      jsonb_build_object('key','cutoff_enabled','label',public.oa_label('field_cutoff_enabled'),
                         'type','bool','value',cfg.cutoff_enabled),
      jsonb_build_object('key','cutoff_time','label',public.oa_label('field_cutoff_time'),
                         'type','text','value',to_char(coalesce(v_cut, cfg.cutoff_default_time),'HH24:MI'),
                         'hint', public.oa_label('cutoff_clock_title')),
      jsonb_build_object('key','cutoff_default_time','label',public.oa_label('field_cutoff_default'),
                         'type','text','value',to_char(cfg.cutoff_default_time,'HH24:MI')),
      jsonb_build_object('key','cutoff_warn1_min','label',public.oa_label('field_cutoff_warn1'),
                         'type','int','value',cfg.cutoff_warn1_min),
      jsonb_build_object('key','cutoff_warn2_min','label',public.oa_label('field_cutoff_warn2'),
                         'type','int','value',cfg.cutoff_warn2_min),
      jsonb_build_object('key','cutoff_cancel_after_min','label',public.oa_label('field_cutoff_cancel'),
                         'type','int','value',cfg.cutoff_cancel_after_min),
      jsonb_build_object('key','cutoff_restore_min','label',public.oa_label('field_cutoff_restore'),
                         'type','int','value',cfg.cutoff_restore_min),
      jsonb_build_object('key','cutoff_extend_min','label',public.oa_label('field_cutoff_extend'),
                         'type','int','value',cfg.cutoff_extend_min),
      jsonb_build_object('key','cutoff_pause_outside_hours','label',public.oa_label('field_cutoff_pause'),
                         'type','bool','value',cfg.cutoff_pause_outside_hours),
      jsonb_build_object('key','cutoff_behaviour','label',public.oa_label('field_cutoff_behaviour'),
                         'type','text','value',cfg.cutoff_behaviour,
                         'hint', public.oa_label('cutoff_behaviour_cancel') || ' / '
                                 || public.oa_label('cutoff_behaviour_hold')),
      jsonb_build_object('key','cutoff_warn_text','label',public.oa_label('field_cutoff_warntext'),
                         'type','text','value',cfg.cutoff_warn_text,
                         'multiline', true)),
    'phone_warning', case when v_phone = '' then public.oa_label('escalation_phone_missing') else '' end,
    'saved_label',   public.oa_label('saved'),
    'override_label',public.oa_label('override_label'),
    'override_hint', public.oa_label('override_hint'),
    'credit_limit_label',   public.oa_label('credit_limit_label'),
    'credit_prepaid_label', public.oa_label('credit_prepaid_label'),
    'credit_never_label',   public.oa_label('cutoff_never_label'),
    'empty_title',   public.oa_label('empty_title'),
    'empty_body',    public.oa_label('empty_body'),
    'fsi',           public.order_alert_fsi(),
    'open_count',    public.order_alert_open_count(),
    'open',          v_open,
    'cutoff',        public.order_cutoff_console(null, null),
    'log',           v_log);
end 
$function$;

create or replace function public.order_alert_settings_set(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_label text; k text; v_before jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  v_before := to_jsonb(public._oa_cfg());

  for k in select jsonb_object_keys(coalesce(p_patch,'{}'::jsonb)) loop
    if k = 'admin_wa_phone' then
      insert into public.app_settings(key, value)
      values ('admin_wa_phone', to_jsonb(right(regexp_replace(coalesce(p_patch->>k,''),'\D','','g'),10)))
      on conflict (key) do update set value = excluded.value;
    elsif k = 'cutoff_time' then
      -- Per zone, on order_hours, through the RPC that already owns that table.
      perform public.set_order_hours(null, null, null, null, false,
                public.admin_active_zone(), nullif(btrim(p_patch->>k),'')::time);
    elsif k in ('enabled','mute_all','new_customer_prepaid_only','enforce_credit_block',
                'block_at_placement','purchase_gate_enabled',
                'cutoff_enabled','cutoff_pause_outside_hours') then
      execute format('update public.order_alert_config set %I = $1, updated_at=now(), updated_by=$2 where id=''singleton''', k)
        using (p_patch->>k)::boolean, coalesce(v_label,'admin');
    elsif k in ('ring_cap','rering_after_s','wa_after_s','critical_after_s','autocancel_after_min',
                'ring_seconds','ring_delay_s','established_min_paid_orders',
                'cutoff_warn1_min','cutoff_warn2_min','cutoff_cancel_after_min',
                'cutoff_restore_min','cutoff_extend_min') then
      execute format('update public.order_alert_config set %I = greatest($1,0), updated_at=now(), updated_by=$2 where id=''singleton''', k)
        using (p_patch->>k)::int, coalesce(v_label,'admin');
    elsif k = 'cutoff_default_time' then
      update public.order_alert_config
         set cutoff_default_time = nullif(btrim(p_patch->>k),'')::time,
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton' and nullif(btrim(p_patch->>k),'') is not null;
    elsif k = 'cutoff_behaviour' then
      update public.order_alert_config
         set cutoff_behaviour = case when lower(btrim(p_patch->>k)) = 'hold' then 'hold' else 'cancel' end,
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'cutoff_warn_text' then
      update public.order_alert_config
         set cutoff_warn_text = coalesce(p_patch->>k,''),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'established_credit_limit' then
      update public.order_alert_config
         set established_credit_limit = greatest((p_patch->>k)::numeric, 0),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'labels' then
      update public.order_alert_config
         set labels = coalesce(labels,'{}'::jsonb) || (p_patch->'labels'),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    end if;
  end loop;

  -- Who changed a setting, and to what. The existing audit log, not a new one.
  perform public.audit_write('order_alert_settings_set','order_alert_config','singleton',
            v_before, p_patch || jsonb_build_object('by', coalesce(v_label,'admin')));

  return public.order_alert_settings() || jsonb_build_object('saved', true);
end 
$function$;

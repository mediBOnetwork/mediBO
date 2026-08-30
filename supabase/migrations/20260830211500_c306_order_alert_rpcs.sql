-- ============================================================================
-- CHANGE #306 — push, feed, actions and the escalation ladder.
-- Nothing here returns a raw row: every payload carries finished strings.
-- ============================================================================

update public.order_alert_config
   set labels = coalesce(labels,'{}'::jsonb) || $lbl${
  "age_seconds": "{{n}}s",
  "age_minutes": "{{n}} min",
  "age_hours": "{{n}} hr",
  "escalation_phone_label": "Escalation WhatsApp number",
  "escalation_phone_hint": "The 10-digit number the 3-minute WhatsApp goes to.",
  "escalation_phone_missing": "No escalation number set — WhatsApp escalation is off."
}$lbl$::jsonb
 where id = 'singleton';

-- ── "4 min", server-side. Dart never subtracts two clocks. ─────────────────
create or replace function public._oa_age_label(p_since timestamptz)
returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare v_s bigint;
begin
  if p_since is null then return ''; end if;
  v_s := greatest(extract(epoch from (now() - p_since))::bigint, 0);
  if v_s < 60 then
    return public.oa_label('age_seconds', jsonb_build_object('n', v_s::text));
  elsif v_s < 3600 then
    return public.oa_label('age_minutes', jsonb_build_object('n', (v_s/60)::text));
  end if;
  return public.oa_label('age_hours', jsonb_build_object('n', (v_s/3600)::text));
end $$;

-- ── Who the escalation reaches ──────────────────────────────────────────────
-- There was no admin number recorded anywhere on this platform (app_settings
-- .admin_wa_phone was present and empty, the allowlist was empty, and the
-- super-admin push tokens carry no phone10). Rather than leave the 3-minute
-- rung dead, this resolves a number from every place one could legitimately
-- live, and the alerts screen writes app_settings.admin_wa_phone so Om can set
-- it without a deploy.
create or replace function public._oa_admin_phones()
returns text[]
language sql stable security definer set search_path to 'public' as $$
  select array(
    select distinct p from (
      select right(regexp_replace(coalesce((select value #>> '{}' from public.app_settings
                                             where key='admin_wa_phone'),''),'\D','','g'),10) p
      union all
      select right(regexp_replace(coalesce(na.phone10,''),'\D','','g'),10)
        from public.notification_allowlist na where na.audience = 'admin'
      union all
      select right(regexp_replace(coalesce(t.phone10,''),'\D','','g'),10)
        from public.push_tokens t
       where t.is_active and t.role in ('admin','super_admin')
    ) s where length(p) = 10)
$$;

-- ── How many decisions are outstanding right now ────────────────────────────
create or replace function public.order_alert_open_count()
returns integer
language sql stable security definer set search_path to 'public' as $$
  select count(*)::int from public.order_alert where state = 'ringing'
$$;

-- ── The push ────────────────────────────────────────────────────────────────
-- Data-only and high priority, so Android wakes our own service and builds a
-- full-screen-intent notification with Accept / Reject on it. The action token
-- is what makes those buttons work from the lock screen without a session.
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
    select t.user_id, jsonb_agg(distinct t.token) tokens
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
      ('order_alert_new', null, 'push', 'queued', null, 'admin', u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, '/admin/order-alerts', 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind), 'push')
    returning id into v_log;

    v_alert := jsonb_build_object(
      'kind',                'order_alert',
      'alert_id',            a.id,
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

-- ── Cancelling: the order and anything it was holding ───────────────────────
create or replace function public._oa_release_and_cancel(p_order_id uuid, p_reason text, p_by text)
returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.offer_reservations
     set status = 'released', released_at = now(), order_id = null
   where order_id = p_order_id and status <> 'released';

  update public.orders
     set status        = 'cancelled',
         closed_at     = coalesce(closed_at, now()),
         closed_by     = coalesce(closed_by, p_by),
         closed_reason = coalesce(closed_reason, p_reason),
         close_mode    = coalesce(close_mode, 'order_alert')
   where id = p_order_id;
end $$;

-- ── The one place an alert changes state ────────────────────────────────────
create or replace function public._oa_apply_action(
  p_alert_id bigint, p_action text, p_reason text, p_by uuid, p_by_label text, p_source text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; v_credit jsonb;
begin
  cfg := public._oa_cfg();
  select * into a from public.order_alert where id = p_alert_id for update;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','no_alert',
                              'message', public.oa_label('toast_already'));
  end if;
  if a.state <> 'ringing' then
    return jsonb_build_object('ok', false, 'error','already_actioned',
                              'state', a.state,
                              'message', public.oa_label('toast_already'));
  end if;

  if p_action = 'accept' then
    -- The credit block is the whole point: an over-limit customer cannot have
    -- an unpaid order accepted, and the popup says exactly why.
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
end $$;

-- ── In-app action (admin session) ───────────────────────────────────────────
create or replace function public.order_alert_action(
  p_order_id uuid, p_action text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a public.order_alert%rowtype; v_label text; v_res jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into a from public.order_alert where order_id = p_order_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','no_alert',
                              'message', public.oa_label('toast_already'));
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  v_res := public._oa_apply_action(a.id, p_action, p_reason, auth.uid(),
                                   coalesce(v_label,'admin'), 'app');
  return v_res || jsonb_build_object('feed', public.order_alert_feed());
end $$;

-- ── Lock-screen action (one-shot token, no session) ─────────────────────────
create or replace function public.order_alert_action_by_token(
  p_token text, p_action text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare t public.order_alert_token%rowtype; v_label text;
begin
  select * into t from public.order_alert_token where token = p_token;
  if t.token is null then
    return jsonb_build_object('ok', false, 'error','bad_token');
  end if;
  if t.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','expired_token');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = t.user_id;
  update public.order_alert_token set used_at = now() where token = p_token;
  return public._oa_apply_action(t.alert_id, p_action, p_reason, t.user_id,
                                 coalesce(v_label,'admin'), 'notification');
end $$;

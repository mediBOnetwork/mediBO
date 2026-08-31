-- CHANGE #398 (2/4) — THE RING GOES TO THE PARTNER FIRST.
--
-- #306 built the full-screen new-order alert and pointed it at admin devices.
-- But the admin does not fulfil the order — the ZONE PARTNER does. An order
-- landing in Zone 1 woke a phone in the platform office and left the person who
-- actually has to source, collect, count and pack it asleep.
--
-- So the same ring is now addressed: it goes to the partner's own active staff
-- devices for orders in their zone, and only escalates to admin when no partner
-- device has accepted inside the escalation window. Every other #306 rule is
-- untouched — the prepaid order still auto-accepts and never rings, the
-- autocancel window still runs, WhatsApp and email still escalate.

-- ── State the alert now carries ─────────────────────────────────────────────
alter table public.order_alert
  add column if not exists zone_id     smallint,
  add column if not exists partner_id  bigint,
  add column if not exists audience    text not null default 'admin',
  add column if not exists partner_push_count int not null default 0,
  add column if not exists partner_first_push_at timestamptz,
  add column if not exists escalated_at timestamptz;

alter table public.order_alert_config
  add column if not exists partner_ring_first      boolean not null default true,
  add column if not exists partner_escalate_after_s int    not null default 120;

create index if not exists order_alert_zone_idx on public.order_alert(zone_id, state);

-- Backfill the zone/partner of the alerts already on the table, so an alert
-- raised before this change is still addressable rather than invisible.
update public.order_alert a
   set zone_id = coalesce(a.zone_id, o.zone_id, pp.zone_id)
  from public.orders o
  left join public.pharmacy_profiles pp on pp.id = o.customer_id
 where o.id = a.order_id and a.zone_id is null;

update public.order_alert a
   set partner_id = rp.id
  from public.region_partners rp
 where rp.zone_id = a.zone_id and coalesce(rp.is_active,true) and a.partner_id is null;

-- ── Who the alert is FOR ────────────────────────────────────────────────────
-- Partner staff are resolved by IDENTITY (partner_users.auth_user_id), never by
-- push_tokens.role: get_my_role() deliberately calls a partner 'admin' so the
-- fulfilment RPCs authorise, so the token's role word cannot tell the two
-- apart. The partner row is the truth.
create or replace function public._oa_partner_user_ids(p_partner bigint)
returns uuid[]
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(array_agg(distinct pu.auth_user_id), '{}'::uuid[])
    from partner_users pu
    join region_partners rp on rp.id = pu.partner_id
   where pu.partner_id = p_partner
     and pu.auth_user_id is not null
     and coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
$function$;

create or replace function public._oa_partner_devices(p_partner bigint)
returns int
language sql
stable security definer
set search_path to 'public'
as $function$
  select count(distinct t.user_id)::int
    from push_tokens t
   where t.is_active and t.user_id = any (public._oa_partner_user_ids(p_partner))
$function$;

-- The audience this alert should ring RIGHT NOW. One decision, in one place,
-- so the tick and the push can never disagree about who is being woken.
create or replace function public._oa_audience(a public.order_alert)
returns text
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare cfg public.order_alert_config;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.partner_ring_first, true) then return 'admin'; end if;
  if a.partner_id is null then return 'admin'; end if;
  if a.escalated_at is not null then return 'admin'; end if;
  if public._oa_partner_devices(a.partner_id) = 0 then return 'admin'; end if;
  return 'partner';
end $function$;

-- ── The zone fence on the alert surfaces ────────────────────────────────────
-- A partner sees the alerts of their OWN zone and nothing else. An admin (a
-- real one — my_partner_id() is null) sees everything, exactly as before.
create or replace function public._oa_visible(p_zone smallint)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select case when public.my_partner_id() is null then true
              else coalesce(p_zone, -1) = coalesce(public.partner_zone_id(), -2) end
$function$;

create or replace function public.order_alert_open_count()
returns integer
language sql
stable security definer
set search_path to 'public'
as $function$
  select count(*)::int from public.order_alert
   where state = 'ringing' and public._oa_visible(zone_id)
$function$;

-- ── Raise: stamp the zone and its partner ───────────────────────────────────
create or replace function public.order_alert_raise(p_order_id uuid)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; o public.orders%rowtype;
  v_credit jsonb; v_id bigint; v_name text; v_zone smallint; v_partner bigint;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled, false) then return null; end if;

  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''),
                  nullif(btrim(o.pharmacy_name),''), ''),
         coalesce(o.zone_id, pp.zone_id)
    into v_name, v_zone
    from public.pharmacy_profiles pp where pp.id = o.customer_id;
  v_name := coalesce(nullif(btrim(coalesce(v_name, o.pharmacy_name, '')),''), o.pharmacy_name, '');
  v_zone := coalesce(v_zone, o.zone_id);

  select rp.id into v_partner from public.region_partners rp
   where rp.zone_id = v_zone and coalesce(rp.is_active,true) order by rp.id limit 1;

  v_credit := public.customer_credit_state(o.customer_id);

  insert into public.order_alert
    (order_id, order_code, customer_id, customer_name, amount, risk, state, stage,
     credit_blocked, credit_note, expires_at, ring, zone_id, partner_id, audience)
  values
    (o.id, coalesce(o.order_code, o.payment_id, ''), o.customer_id, v_name,
     coalesce(o.total_amount, 0),
     case when public.order_is_paid(o.id) then 'prepaid' else 'unpaid' end,
     case when public.order_is_paid(o.id) then 'accepted' else 'ringing' end,
     'new',
     coalesce((v_credit->>'blocked')::boolean, false),
     nullif(v_credit->>'message',''),
     now() + make_interval(mins => greatest(cfg.autocancel_after_min, 1)),
     not public.order_is_paid(o.id),
     v_zone, v_partner,
     case when v_partner is not null and coalesce(cfg.partner_ring_first,true)
          then 'partner' else 'admin' end)
  on conflict (order_id) do nothing
  returning id into v_id;

  return v_id;
end $function$;

-- ── Push: the same card, addressed ──────────────────────────────────────────
create or replace function public.order_alert_push(p_alert_id bigint, p_kind text default 'new',
                                                   p_audience text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; u record;
  v_vars jsonb; v_title text; v_body text; v_count int; v_tok text;
  v_log bigint; v_req bigint; v_sent int := 0; v_alert jsonb; v_ongoing text;
  v_aud text; v_deep text; v_uids uuid[];
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

  v_aud := coalesce(nullif(btrim(p_audience),''), public._oa_audience(a));
  v_deep := case when v_aud = 'partner' then '/partner' else '/admin/order-alerts' end;
  if v_aud = 'partner' then
    v_uids := public._oa_partner_user_ids(a.partner_id);
    if coalesce(array_length(v_uids,1),0) = 0 then
      v_aud := 'admin';
      v_deep := '/admin/order-alerts';
    end if;
  end if;

  v_count := (select count(*)::int from public.order_alert al
               where al.state = 'ringing'
                 and (v_aud <> 'partner' or al.partner_id = a.partner_id));
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
       and ( (v_aud = 'partner' and t.user_id = any (v_uids))
          or (v_aud <> 'partner' and t.role in ('admin','super_admin')) )
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
       'push', 'queued', null, v_aud, u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, v_deep, 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind, 'audience', v_aud), 'push')
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
      'audience',            v_aud,
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
                                    'deep_link', v_deep,
                                    'event_key', 'order_alert_new',
                                    'order_id', a.order_id,
                                    'alert', v_alert),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  update public.order_alert
     set push_count    = push_count + 1,
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
  return jsonb_build_object('ok', true, 'devices', v_sent, 'kind', p_kind, 'audience', v_aud);
end $function$;

-- ── Tick: partner first, admin as the fallback rung ─────────────────────────
create or replace function public.order_alert_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype;
  v_age int; v_paid int := 0; v_rang int := 0; v_wa int := 0;
  v_crit int := 0; v_cancel int := 0; v_esc int := 0; v_partner int := 0;
  v_phone text; v_mail text; v_vars jsonb; v_res jsonb;
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

    -- 3. First ring, once the payment grace window has passed. The audience is
    --    the partner's own devices when this zone has a partner with a device.
    if a.push_count = 0 then
      if v_age >= cfg.ring_delay_s then
        v_res := public.order_alert_push(a.id, 'new');
        if coalesce(v_res->>'audience','') = 'partner' then v_partner := v_partner + 1; end if;
        v_rang := v_rang + 1;
      end if;
      continue;
    end if;

    -- 3b. ESCALATION. The partner was rung and nobody accepted inside the
    --     window, so the admin becomes the audience from here on. This is the
    --     rung that makes partner-first safe: an unattended partner phone
    --     costs the order the escalation window, never the order.
    if a.audience = 'partner' and a.escalated_at is null
       and v_age >= greatest(cfg.ring_delay_s,0) + greatest(cfg.partner_escalate_after_s,15) then
      update public.order_alert set escalated_at = now(), audience = 'admin' where id = a.id;
      perform public.order_alert_push(a.id,
        case when a.stage = 'critical' then 'critical' else 'new' end, 'admin');
      v_esc := v_esc + 1;
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
                            'partner_rings', v_partner, 'escalated', v_esc,
                            'whatsapp', v_wa, 'critical', v_crit,
                            'auto_cancelled', v_cancel);
end $function$;

-- ── The partner may see and answer the ring for their OWN zone ──────────────
create or replace function public.order_alert_feed(p_limit integer default 25)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; v_items jsonb := '[]'::jsonb; a public.order_alert%rowtype;
  v_count int;
begin
  cfg := public._oa_cfg();
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error','not_admin', 'count', 0,
                              'items', '[]'::jsonb);
  end if;

  for a in select * from public.order_alert
            where state = 'ringing' and public._oa_visible(zone_id)
            order by created_at desc
            limit greatest(coalesce(p_limit,25),1)
  loop
    v_items := v_items || jsonb_build_array(public._oa_item(a));
  end loop;

  v_count := public.order_alert_open_count();

  return jsonb_build_object(
    'ok',           true,
    'enabled',      cfg.enabled,
    'count',        v_count,
    'has_any',      v_count > 0,
    'badge_label',  case when v_count > 0
                         then public.oa_label('badge_label', jsonb_build_object('count', v_count::text))
                         else '' end,
    'badge_tooltip',public.oa_label('badge_tooltip', jsonb_build_object('count', v_count::text)),
    'ongoing_title',case when v_count = 1 then public.oa_label('ongoing_title_one')
                         else public.oa_label('ongoing_title', jsonb_build_object('count', v_count::text)) end,
    'ongoing_body', public.oa_label('ongoing_body'),
    'empty_title',  public.oa_label('empty_title'),
    'empty_body',   public.oa_label('empty_body'),
    'poll_s',       20,
    'items',        v_items);
end $function$;

create or replace function public.order_alert_card(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare a public.order_alert%rowtype; v_count int;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into a from public.order_alert where order_id = p_order_id;
  if a.id is null or not public._oa_visible(a.zone_id) then
    return jsonb_build_object('ok', false, 'error','no_alert', 'show', false);
  end if;
  v_count := public.order_alert_open_count();
  return jsonb_build_object(
    'ok',           true,
    'show',         a.state = 'ringing',
    'queue_count',  v_count,
    'queue_label',  case when v_count > 1
                         then public.oa_label('banner_unpaid_queued',
                                jsonb_build_object('count', v_count::text))
                         else '' end,
    'poll_s',       20,
    'item',         public._oa_item(a));
end $function$;

create or replace function public.order_alert_action(p_order_id uuid, p_action text,
                                                     p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare a public.order_alert%rowtype; v_label text; v_res jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into a from public.order_alert where order_id = p_order_id;
  if a.id is null or not public._oa_visible(a.zone_id) then
    return jsonb_build_object('ok', false, 'error','no_alert',
                              'message', public.oa_label('toast_already'));
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  -- A partner answering their own zone's ring is stamped as the partner, and
  -- the existing partner audit trail records it like every other partner act.
  if public.my_partner_id() is not null then
    perform public.partner_audit('partner.inquiry','order_alert_' || coalesce(p_action,''),
              jsonb_build_object('order_id', p_order_id, 'alert_id', a.id));
  end if;
  v_res := public._oa_apply_action(a.id, p_action, p_reason, auth.uid(),
                                   coalesce(v_label,'admin'), 'app');
  return v_res || jsonb_build_object('feed', public.order_alert_feed());
end $function$;

insert into public.partner_rpc_allow(proname, source, note) values
  ('order_alert_feed','c398','partner rings for their own zone'),
  ('order_alert_card','c398','partner rings for their own zone'),
  ('order_alert_action','c398','partner accepts/rejects their own zone ring'),
  ('order_alert_open_count','c398','partner ring badge')
on conflict (proname) do nothing;

-- ── Recorded verification ───────────────────────────────────────────────────
create or replace function public.c398_alert_proof()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'alerts_with_zone',    (select count(*) from order_alert where zone_id is not null),
    'alerts_with_partner', (select count(*) from order_alert where partner_id is not null),
    'partner_ring_first',  (select partner_ring_first from order_alert_config limit 1),
    'escalate_after_s',    (select partner_escalate_after_s from order_alert_config limit 1),
    'partner_devices',     (select public._oa_partner_devices(rp.id) from region_partners rp
                             where coalesce(rp.is_active,true) order by rp.id limit 1),
    'audience_of_open',    (select coalesce(jsonb_object_agg(audience, n),'{}'::jsonb)
                              from (select audience, count(*) n from order_alert
                                     where state='ringing' group by audience) s))
$function$;
grant execute on function public.c398_alert_proof() to service_role;

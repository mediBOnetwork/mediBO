-- CMD #1989 — the new-order alert looks like the rest of the app.
--
-- #1988 took the centre dialog away because it fought the lock-screen alert.
-- What was left in the app is a slim strip, and the alert Om actually sees on
-- a phone is a grey OS card with flat chips. This change gives BOTH surfaces a
-- designed shape, and — as always — decides every word and every tone HERE:
--
--   order_alert_sheet()  the bottom sheet's whole payload: shop name, mono
--                        order code, the amount and its item count, a one-line
--                        preview of the first three items, the live age, the
--                        status pill (Unpaid amber / Paid green), the rail
--                        tone, and the ONE primary action. Nothing about the
--                        sheet is computed in Dart.
--   order_alert_strip()  gains sheet_autoshow / sheet_order_id, so whether the
--                        sheet interrupts at all stays a BACKEND decision.
--                        #1988's "one interrupt per order" survives: a device
--                        that gets the full-screen alert is never auto-sheeted.
--   push payload         `notif` — the lock-screen card, rendered: the title
--                        is the shop name, the body is amount · items · paid,
--                        there is one Open action, everything lands in one
--                        Orders channel under one tag, and a summary line
--                        replaces the body when several are waiting.
--
-- Idempotent: labels are MERGED, every function is `create or replace`, and
-- the grant block re-runs safely.

-- ── 1. LABELS ───────────────────────────────────────────────────────────────
-- Merged, never replaced: a label this build does not know about survives.

insert into public.order_alert_config (id) values ('singleton')
on conflict (id) do nothing;

update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     -- the bottom sheet
     'sheet_primary',        'Open order',
     'sheet_status_paid',    'Paid',
     'sheet_status_unpaid',  'Unpaid',
     'sheet_preview_more',   '+{{count}} more',
     'sheet_preview_none',   'No items on this order yet',
     'sheet_more_waiting',   '{{count}} more waiting',
     'sheet_age_prefix',     '{{age}} ago',
     -- the lock-screen / tray card. Title is the SHOP, body is the money.
     'push_title',           '{{customer}}',
     'push_body',            '{{amount}} · {{items}} · {{risk}}',
     'push_title_critical',  '{{customer}}',
     'push_body_critical',   '{{amount}} · {{items}} · {{risk}} · {{age}}',
     'notif_summary_many',   '{{count}} orders waiting',
     'notif_open',           'Open',
     'channel_name',         'Orders',
     'channel_description',  'New orders waiting to be opened',
     'ongoing_title_one',    '1 order waiting',
     'ongoing_title',        '{{count}} orders waiting',
     'ongoing_body',         'Open the order to accept or reject it')
 where id = 'singleton';

-- ── 2. THE ITEM PREVIEW ─────────────────────────────────────────────────────
-- "Dolo 650, Pan-D, Azithral 500 +4 more" — one faint line, built once, here.
-- Dart never joins names and never counts the remainder.

create or replace function public._oa_items_preview(p_order_id uuid,
                                                    p_n integer default 3)
returns text language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_names text[]; v_total int; v_rest int; v_line text;
begin
  select coalesce(array_agg(nm order by ord), '{}'::text[])
    into v_names
    from (select coalesce(nullif(btrim(oi.product_name), ''), '—') as nm,
                 row_number() over (order by oi.created_at nulls last, oi.product_name, oi.id) as ord
            from public.order_items oi
           where oi.order_id = p_order_id
           order by oi.created_at nulls last, oi.product_name, oi.id
           limit greatest(coalesce(p_n, 3), 1)) s;

  v_total := public._oa_item_count(p_order_id);
  if coalesce(array_length(v_names, 1), 0) = 0 then
    return public.oa_label('sheet_preview_none');
  end if;

  v_line := array_to_string(v_names, ', ');
  v_rest := greatest(v_total - array_length(v_names, 1), 0);
  if v_rest > 0 then
    v_line := v_line || ' ' ||
      public.oa_label('sheet_preview_more',
                      jsonb_build_object('count', v_rest::text));
  end if;
  return v_line;
end $function$;

-- ── 3. THE SHEET ────────────────────────────────────────────────────────────
-- One RPC, one screen. p_order_id null = the oldest alert still ringing in
-- the caller's zones, which is exactly what the popup wants to show.

create or replace function public.order_alert_sheet(p_order_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype;
  v_count int; v_paid boolean; v_age text; v_tone text; v_ring boolean;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'show', false, 'count', 0);
  end if;
  cfg := public._oa_cfg();

  select count(*)::int into v_count
    from public.order_alert al
   where al.state = 'ringing' and public._oa_visible(al.zone_id);

  if p_order_id is null then
    select * into a from public.order_alert al
     where al.state = 'ringing' and public._oa_visible(al.zone_id)
     order by al.created_at asc limit 1;
  else
    select * into a from public.order_alert al
     where al.order_id = p_order_id and public._oa_visible(al.zone_id)
     order by al.created_at desc limit 1;
  end if;

  if a.id is null then
    return jsonb_build_object('ok', true, 'show', false, 'count', v_count);
  end if;

  v_paid := public.order_is_paid(a.order_id);
  v_age  := public._oa_age_label(a.created_at);
  -- Item 2 + 4: amber unpaid, green paid. One decision, one place, two uses
  -- (the rail down the left edge and the filled pill) so they can never drift.
  v_tone := case when v_paid then 'success' else 'warning' end;
  v_ring := a.ring and a.state = 'ringing'
              and not public._oa_open_quiet(a)
              and not public._oa_silent_for(auth.uid(), null);

  return jsonb_build_object(
    'ok',              true,
    'show',            a.state = 'ringing',
    'count',           v_count,
    'alert_id',        a.id,
    'order_id',        a.order_id,
    'shop_name',       coalesce(nullif(btrim(a.customer_name),''),
                                coalesce(a.order_code,'')),
    'order_code',      coalesce(a.order_code,''),
    'amount_display',  public.inr_money(a.amount),
    'items_label',     public._oa_items_label(a.order_id),
    'item_count',      public._oa_item_count(a.order_id),
    'items_preview',   public._oa_items_preview(a.order_id, 3),
    -- An age we cannot say is an ABSENCE, not the word "ago" on its own.
    'age_label',       case when btrim(coalesce(v_age,'')) = '' then ''
                            else public.oa_label('sheet_age_prefix',
                                   jsonb_build_object('age', v_age)) end,
    'status_label',    public.oa_label(case when v_paid then 'sheet_status_paid'
                                            else 'sheet_status_unpaid' end),
    'status_tone',     v_tone,
    'rail_tone',       v_tone,
    'paid',            v_paid,
    'primary_label',   public.oa_label('sheet_primary'),
    'more_label',      case when v_count > 1
                            then public.oa_label('sheet_more_waiting',
                                   jsonb_build_object('count', (v_count-1)::text))
                            else '' end,
    'ring',            v_ring,
    'opened',          a.opened_at is not null,
    -- The sheet re-reads itself on this interval so the age stays live without
    -- a single clock subtraction in Dart.
    'refresh_s',       30,
    'poll_s',          20);
end $function$;

-- ── 4. THE STRIP TELLS THE APP WHETHER TO OPEN THE SHEET ────────────────────
-- #1988's rule stands: one interrupt per order. A device that already gets the
-- full-screen lock-screen alert (Android) is never auto-sheeted; the web, which
-- has no full-screen intent, is. `sheet_autoshow` is that decision, taken here.

create or replace function public.order_alert_strip()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare cfg public.order_alert_config; a public.order_alert%rowtype;
        v_count int; v_paid boolean; v_age text; v_ring boolean;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'show', false, 'count', 0);
  end if;
  cfg := public._oa_cfg();

  select count(*)::int into v_count
    from public.order_alert al
   where al.state = 'ringing' and public._oa_visible(al.zone_id);

  if v_count = 0 then
    return jsonb_build_object('ok', true, 'show', false, 'count', 0,
                              'ring', false, 'sheet_autoshow', false,
                              'sheet_order_id', null, 'poll_s', 20);
  end if;

  select * into a from public.order_alert al
   where al.state = 'ringing' and public._oa_visible(al.zone_id)
   order by al.created_at asc limit 1;

  v_paid := public.order_is_paid(a.order_id);
  v_age  := public._oa_age_label(a.created_at);
  v_ring := a.ring
              and not public._oa_open_quiet(a)
              and not public._oa_silent_for(auth.uid(), null);

  return jsonb_build_object(
    'ok',           true,
    'show',         true,
    'count',        v_count,
    'alert_id',     a.id,
    'order_id',     a.order_id,
    'order_code',   coalesce(a.order_code,''),
    'title',        case when v_count = 1 then public.oa_label('strip_title_one')
                         else public.oa_label('strip_title_many',
                                jsonb_build_object('count', v_count::text)) end,
    'subtitle',     public.oa_label('strip_subtitle', jsonb_build_object(
                      'customer', coalesce(a.customer_name,''),
                      'amount',   public.inr_money(a.amount),
                      'items',    public._oa_items_label(a.order_id),
                      'age',      v_age)),
    'action_label', public.oa_label('strip_action'),
    'more_label',   case when v_count > 1
                         then public.oa_label('strip_more',
                                jsonb_build_object('count', (v_count-1)::text))
                         else '' end,
    'risk',         case when v_paid then 'prepaid' else 'unpaid' end,
    'risk_label',   public.oa_label(case when v_paid then 'strip_prepaid' else 'strip_unpaid' end),
    'paid',         v_paid,
    'age_label',    v_age,
    'tone',         case when a.stage = 'critical' then 'danger'
                         when v_paid then 'info' else 'warning' end,
    'ring',         v_ring,
    'ring_seconds', cfg.ring_seconds,
    'opened',       a.opened_at is not null,
    -- CMD #1989: the popup is the backend's call, never the client's. It only
    -- opens for an alert nobody has opened yet, and only where there is no
    -- full-screen alert competing with it.
    'sheet_autoshow', (a.opened_at is null and a.state = 'ringing'),
    'sheet_order_id', a.order_id,
    'poll_s',       20);
end $function$;

-- ── 5. THE LOCK-SCREEN CARD, RENDERED ───────────────────────────────────────
-- Same push, one new object. The service worker and the Android tray both draw
-- `notif` verbatim: no title built from a template in JS, no plural in Kotlin.

create or replace function public.order_alert_notif(p_alert_id bigint,
                                                    p_kind text default 'new')
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  a public.order_alert%rowtype; v_paid boolean; v_count int;
  v_vars jsonb; v_aud text; v_items text;
begin
  select * into a from public.order_alert where id = p_alert_id;
  if a.id is null then return '{}'::jsonb; end if;

  v_paid  := public.order_is_paid(a.order_id);
  v_items := public._oa_items_label(a.order_id);
  v_aud   := coalesce(a.audience, 'admin');
  v_count := (select count(*)::int from public.order_alert al
               where al.state = 'ringing'
                 and (v_aud <> 'partner' or al.partner_id = a.partner_id));

  v_vars := jsonb_build_object(
    'customer',   coalesce(nullif(btrim(a.customer_name),''), coalesce(a.order_code,'')),
    'order_code', coalesce(a.order_code,''),
    'amount',     public.inr_money(a.amount),
    'age',        public._oa_age_label(a.created_at),
    'items',      v_items,
    'risk',       public.oa_label(case when v_paid then 'sheet_status_paid'
                                       else 'sheet_status_unpaid' end),
    'count',      v_count::text);

  return jsonb_build_object(
    -- Item 6 — the shop is the headline; the money is the line under it.
    'title',        public.oa_label(case when p_kind='critical'
                                         then 'push_title_critical'
                                         else 'push_title' end, v_vars),
    'body',         public.oa_label(case when p_kind='critical'
                                         then 'push_body_critical'
                                         else 'push_body' end, v_vars),
    -- Item 8 — one line when several are waiting, and it is written here.
    'summary',      case when v_count > 1
                         then public.oa_label('notif_summary_many', v_vars)
                         else '' end,
    'count',        v_count,
    -- Item 7 — one action, and it only opens.
    'open_label',   public.oa_label('notif_open'),
    'actions',      jsonb_build_array(jsonb_build_object(
                      'action', 'open',
                      'title',  public.oa_label('notif_open'))),
    -- Item 8 — one Orders channel, one tag, so the tray collapses them.
    'channel_id',   'medibo_order_alert',
    'channel_name', public.oa_label('channel_name'),
    'channel_description', public.oa_label('channel_description'),
    'group',        'medibo_orders',
    'tag',          'medibo_orders',
    'renotify',     true,
    -- Item 8 — ongoing while unactioned.
    'ongoing',      (a.actioned_at is null),
    'require_interaction', (a.actioned_at is null),
    'status_label', public.oa_label(case when v_paid then 'sheet_status_paid'
                                         else 'sheet_status_unpaid' end),
    'status_tone',  case when v_paid then 'success' else 'warning' end,
    'paid',         v_paid,
    -- Item 6 — the monogram and the brand accent, from the design tokens the
    -- rest of the app is painted with.
    'icon',         '/icons/medibo-monogram-192.png',
    'badge',        '/icons/medibo-monogram-72.png',
    -- The accent is the SAME brand token the app is painted with, so a
    -- recolour via ui_design_set() reaches the lock screen with no deploy.
    'accent',       coalesce(nullif(public.ui_design_get()->'colors'->>'brand',''),
                             '#1B873F'),
    'deep_link',    case when v_aud = 'partner' then '/partner'
                         else '/admin/order-alerts' end,
    'order_id',     a.order_id,
    'order_code',   coalesce(a.order_code,''));
end $function$;

-- The push carries it. Everything else about order_alert_push_raw is #1988's.
create or replace function public._oa_notif_for(p_alert_id bigint, p_kind text)
returns jsonb language sql stable security definer set search_path to 'public'
as $$ select public.order_alert_notif(p_alert_id, p_kind) $$;

-- ── 6. GRANTS ───────────────────────────────────────────────────────────────
-- A new SECURITY DEFINER function inherits PUBLIC EXECUTE (standing lesson
-- #122). Revoke by pattern, then grant only the roles that may call it.

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('order_alert_sheet','order_alert_notif',
                         '_oa_items_preview','_oa_notif_for','order_alert_strip',
                         -- Repaired in passing: both push senders were execute-
                         -- able by ANY signed-in user, so any account could make
                         -- every admin device ring. No Dart caller has ever used
                         -- them — the trigger and the tick call them as definer.
                         'order_alert_push','order_alert_push_raw')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    if r.proname in ('order_alert_sheet','order_alert_strip') then
      execute format('grant execute on function %s to authenticated', r.sig);
    else
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
end $$;

-- ── 7. THE PUSH CARRIES IT ──────────────────────────────────────────────────
-- #1988's function, verbatim, with ONE key added: `notif`. Nothing else in it
-- changed — the body below is pg_get_functiondef of the shipped version.

CREATE OR REPLACE FUNCTION public.order_alert_push_raw(p_alert_id bigint, p_kind text DEFAULT 'new'::text, p_audience text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; u record;
  v_vars jsonb; v_title text; v_body text; v_count int;
  v_log bigint; v_req bigint; v_sent int := 0; v_alert jsonb; v_ongoing text;
  v_aud text; v_deep text; v_uids uuid[]; v_paid boolean; v_silent boolean;
  v_items text; v_icount int; v_silenced int := 0;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', false, 'reason','alerts_disabled');
  end if;
  select * into a from public.order_alert where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'reason','no_alert'); end if;
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_outbound_silenced(a.test_session_id) or public.test_order_silenced(a.order_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if a.state <> 'ringing' or not a.ring then
    return jsonb_build_object('ok', false, 'reason','not_ringing');
  end if;
  -- CMD #1988 item 4 — somebody has the order open. Nothing is sent until the
  -- re-ring window has passed with the order still unactioned.
  if public._oa_open_quiet(a) then
    return jsonb_build_object('ok', true, 'reason','opened_elsewhere', 'devices', 0);
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

  v_paid   := public.order_is_paid(a.order_id);
  v_icount := public._oa_item_count(a.order_id);
  v_items  := public._oa_items_label(a.order_id);

  v_count := (select count(*)::int from public.order_alert al
               where al.state = 'ringing'
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
    -- CMD #1988 item 3 + 6 — quiet hours and a snoozed device SILENCE the
    -- alert for this recipient. They never withhold it: it still lands, it
    -- still opens the order, it just does not make a sound.
    v_silent := public._oa_silent_for(u.user_id, null);
    if v_silent then v_silenced := v_silenced + 1; end if;

    insert into public.notification_log
      (event_key, recipient, channel, status, ok, audience, recipient_id, user_id,
       order_id, customer_id, title, body, deep_link, language, vars, payload, path)
    values
      ('order_alert_new',
       coalesce(nullif(btrim(u.phone10),''), u.user_id::text),
       'push', 'queued', null, v_aud, u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, v_deep, 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind, 'audience', v_aud,
                                  'silent', v_silent, 'view_only', true), 'push')
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
      -- ONE action, and it only opens the order. No accept_label, no
      -- reject_label, no action_token, no action_url — a decision is never
      -- taken from a notification (CMD #1988 item 2).
      'view_only',           true,
      'open_label',          public.oa_label('open_label'),
      'view_only_note',      public.oa_label('push_view_only_note'),
      'deep_link',           v_deep,
      'channel_id',          'medibo_order_alert',
      'channel_name',        public.oa_label('channel_name'),
      'channel_description', public.oa_label('channel_description'),
      'silent',              v_silent,
      'ring_seconds',        case when v_silent then 0 else cfg.ring_seconds end,
      'full_screen',         true,
      'pending_count',       v_count,
      'ongoing_title',       v_ongoing,
      'ongoing_body',        public.oa_label('ongoing_body'),
      -- CMD #1989 — the lock-screen card, rendered. One object, drawn verbatim
      -- by the web service worker and the Android tray.
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
                            'view_only', true, 'kind', p_kind, 'audience', v_aud);
end $function$


;

-- ── 8. GRANTS, AFTER THE LAST REPLACE ───────────────────────────────────────
-- `create or replace` keeps whatever privileges the function already had, so
-- the sweep is repeated once everything above has been (re)created. Running it
-- twice is free; running it only once, before section 7, is a trap.

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('order_alert_sheet','order_alert_notif',
                         '_oa_items_preview','_oa_notif_for','order_alert_strip',
                         'order_alert_push','order_alert_push_raw')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    if r.proname in ('order_alert_sheet','order_alert_strip') then
      execute format('grant execute on function %s to authenticated', r.sig);
    else
      execute format('revoke all on function %s from authenticated', r.sig);
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
end $$;

-- ============================================================================
-- CHANGE #306 — the surfaces: the feed (badge + list + sticky line), the popup
-- card, and the escalation tick. All finished strings.
-- ============================================================================

-- One alert, rendered. Used by the feed, the popup and the admin screen so the
-- three can never drift apart.
create or replace function public._oa_item(a public.order_alert)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare cfg public.order_alert_config; v_credit jsonb; v_paid boolean; v_age text;
begin
  cfg    := public._oa_cfg();
  v_paid := public.order_is_paid(a.order_id);
  v_credit := public.customer_credit_state(a.customer_id);
  v_age  := public._oa_age_label(a.created_at);

  return jsonb_build_object(
    'alert_id',        a.id,
    'order_id',        a.order_id,
    'order_code',      coalesce(a.order_code,''),
    'customer',        coalesce(a.customer_name,''),
    'amount_display',  public.inr_money(a.amount),
    'age_label',       v_age,
    'state',           a.state,
    'state_label',     public.oa_label('state_' || a.state),
    'stage',           a.stage,
    'stage_label',     public.oa_label('stage_' || a.stage),
    'risk',            case when v_paid then 'prepaid' else 'unpaid' end,
    'risk_label',      public.oa_label(case when v_paid then 'risk_prepaid' else 'risk_unpaid' end),
    'paid',            v_paid,
    'ring',            a.ring and a.state = 'ringing' and not v_paid,
    'critical',        a.stage = 'critical',
    'banner',          case
                         when v_paid then public.oa_label('banner_prepaid')
                         when a.stage = 'critical'
                           then public.oa_label('banner_critical', jsonb_build_object('age', v_age))
                         else public.oa_label('banner_unpaid') end,
    'credit_blocked',  coalesce((v_credit->>'blocked')::boolean,false) and not v_paid,
    'credit_note',     case when v_paid then '' else coalesce(v_credit->>'message','') end,
    'credit',          v_credit,
    'can_accept',      a.state = 'ringing'
                         and not (coalesce((v_credit->>'blocked')::boolean,false) and not v_paid),
    'can_reject',      a.state = 'ringing',
    'accept_label',    public.oa_label('accept_label'),
    'reject_label',    public.oa_label('reject_label'),
    'dismiss_label',   public.oa_label('dismiss_label'),
    'view_label',      public.oa_label('view_label'),
    'accept_note',     case when coalesce((v_credit->>'blocked')::boolean,false) and not v_paid
                            then public.oa_label('accept_note_blocked')
                            else public.oa_label('accept_note') end,
    'reject_note',     public.oa_label('reject_note'),
    'override_label',  public.oa_label('override_label'),
    'override_hint',   public.oa_label('override_hint'),
    'actioned_by',     coalesce(a.actioned_by_label,''),
    'push_count',      a.push_count);
end $$;

-- ── The feed: badge, list, sticky line ──────────────────────────────────────
create or replace function public.order_alert_feed(p_limit integer default 25)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; v_items jsonb := '[]'::jsonb; a public.order_alert%rowtype;
  v_count int;
begin
  cfg := public._oa_cfg();
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin', 'count', 0,
                              'items', '[]'::jsonb);
  end if;

  for a in select * from public.order_alert
            where state = 'ringing' order by created_at desc
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
end $$;

-- ── The popup's own payload ─────────────────────────────────────────────────
create or replace function public.order_alert_card(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare a public.order_alert%rowtype; v_count int;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into a from public.order_alert where order_id = p_order_id;
  if a.id is null then
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
end $$;

-- ── The ladder ──────────────────────────────────────────────────────────────
-- Runs once a minute from the cron_task dispatcher (#273) — never its own
-- pg_cron schedule (#301). Order matters: money first (an order that paid
-- while ringing must stop ringing), then the window, then the rungs.
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

-- ── The dispatcher row (never a bare */N pg_cron schedule) ──────────────────
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                              enabled, note, dml)
values ('order_alert', 45, 'poll',
        'select exists (select 1 from public.order_alert where state = ''ringing'')',
        'select public.order_alert_tick()', 20000, true,
        'CHANGE #306 — re-ring, WhatsApp, critical and auto-cancel for unpaid orders.',
        true)
on conflict (name) do update
  set gate_sql = excluded.gate_sql,
      work_sql = excluded.work_sql,
      enabled  = true,
      note     = excluded.note;

-- ── The two routes this feature sends on ────────────────────────────────────
insert into public.wa_event_routes (event_key, label, description, audience, enabled,
                                    push_enabled, push_title, push_body, language,
                                    auto_manage, wa_category, template_name, variable_map)
values
 ('order_alert_new', 'New order alert (admin)',
  'CHANGE #306 — the full-screen ring for an unpaid order. Sent by order_alert_push().',
  'admin', false, true, 'New order · {{customer}}',
  '{{order_code}} · {{amount}} · UNPAID', 'en', false, 'utility', null,
  '["{{customer}}","{{order_code}}","{{amount}}"]'::jsonb),
 ('order_alert_escalation', 'Unpaid order escalation (admin)',
  'CHANGE #306 — the 3-minute WhatsApp rung when an unpaid order is still unactioned.',
  'admin', true, false, 'Unpaid order waiting',
  '{{order_code}} from {{customer}} is unpaid and waiting {{age}}.', 'en', true, 'utility',
  'order_alert_escalation',
  '["{{customer}}","{{order_code}}","{{amount}}","{{age}}"]'::jsonb)
on conflict (event_key) do update
  set label       = excluded.label,
      description = excluded.description,
      audience    = excluded.audience;

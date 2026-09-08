-- CHANGE — #297 part 1, steps 5+6: preview, test-send, and the one RPC the
-- Notification Center screen renders.
--
-- SUPPLIER SAFETY IS ENFORCED IN THE BACKEND, not by asking the runner to be
-- careful: notify_test_send() refuses any number that belongs to a supplier
-- profile or has ever written to us as a supplier, and it refuses any number
-- that is not the caller's own or the configured admin number. There is no
-- parameter that lets an admin aim a test at a customer either.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- Preview: render an event with sample data, send nothing.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_preview(p_event_key text, p_vars jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r record; t record; v_body text; v_tokens jsonb := coalesce(p_vars,'{}'::jsonb);
        v_keys text[]; k text; v_sample jsonb := '{}'::jsonb; v_val text; v_comp jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._nc('notify.not_authorized','Only an admin can preview a message.'));
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('ok', false, 'error','unknown_event',
      'message', public._ncf('notify.unknown_event', jsonb_build_object('a', p_event_key),
                             'There is no route called {a}.'));
  end if;

  select * into t from public.wa_templates where id = r.template_id;

  -- Which tokens does this message actually take? The template's own token_map
  -- is authoritative; the route's variable_map is the fallback (#295).
  select coalesce(
           case when jsonb_typeof(t.token_map) = 'array'
                  then array(select jsonb_array_elements_text(t.token_map)) end,
           case when jsonb_typeof(r.variable_map) = 'array'
                  then array(select (regexp_matches(el, '^\{\{([a-z0-9_]+)\}\}$'))[1]
                               from jsonb_array_elements_text(r.variable_map) el) end,
           '{}'::text[])
    into v_keys;

  foreach k in array coalesce(v_keys,'{}'::text[]) loop
    v_val := coalesce(v_tokens->>k, public._nc('notify.sample.' || k, ''),
                      upper(replace(k,'_',' ')));
    v_sample := v_sample || jsonb_build_object(k, v_val);
  end loop;

  select c->>'text' into v_body
    from jsonb_array_elements(coalesce(t.components,'[]'::jsonb)) c
   where upper(coalesce(c->>'type','')) = 'BODY'
   limit 1;

  if v_body is not null then
    for k in select jsonb_object_keys(v_sample) loop
      v_body := replace(v_body, '{{' || k || '}}', coalesce(v_sample->>k,''));
    end loop;
    -- Meta numbers its placeholders; substitute positionally too.
    for i in 1 .. coalesce(array_length(v_keys,1),0) loop
      v_body := replace(v_body, '{{' || i || '}}', coalesce(v_sample->>v_keys[i],''));
    end loop;
  end if;

  select jsonb_agg(jsonb_build_object('type', upper(coalesce(c->>'type','')),
                                      'text', c->>'text'))
    into v_comp
    from jsonb_array_elements(coalesce(t.components,'[]'::jsonb)) c;

  return jsonb_build_object(
    'ok', true,
    'heading',        public._nc('notify.preview_heading','Preview'),
    'event_key',      r.event_key,
    'title',          coalesce(r.label, r.event_key),
    'audience',       coalesce(r.audience,'customer'),
    'channel_label',  public._nc('notify.channel_whatsapp','WhatsApp'),
    'template_name',  t.name,
    'template_status',upper(coalesce(t.status,'NONE')),
    'status_label',   case when upper(coalesce(t.status,'')) = 'APPROVED'
                           then public._nc('notify.tpl_approved','Approved by Meta')
                           when t.id is null
                           then public._nc('notify.tpl_none','No template linked yet')
                           else public._ncf('notify.tpl_pending', jsonb_build_object('a', coalesce(t.status,'?')),
                                            'Template is {a} — not sendable yet') end,
    'status_tone',    case when upper(coalesce(t.status,'')) = 'APPROVED' then 'good' else 'warn' end,
    'enabled',        coalesce(r.enabled,false),
    'tokens',         v_sample,
    'components',     coalesce(v_comp,'[]'::jsonb),
    'body_preview',   coalesce(v_body, public._nc('notify.no_body','This route has no template body yet.')),
    'empty_label',    public._nc('notify.preview_empty','Nothing to preview until a template is linked.'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Test send: to YOURSELF, and only to yourself.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._notify_is_supplier_phone(p_phone10 text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.supplier_profiles sp
     where right(regexp_replace(coalesce(sp.whatsapp_no, sp.phone, ''),'\D','','g'),10) = p_phone10)
      or exists (
    select 1 from public.whatsapp_messages m
     where m.sender_type = 'supplier'
       and right(regexp_replace(coalesce(m.sender_phone,''),'\D','','g'),10) = p_phone10);
$$;

create or replace function public.notify_test_send(p_event_key text, p_vars jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ph text; v_admin text; v_me text; v jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._nc('notify.not_authorized','Only an admin can send a test.'));
  end if;

  -- The caller's own number, then the configured admin number. Nothing else is
  -- reachable from here — there is no recipient parameter by design.
  select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
    into v_me from public.pharmacy_profiles pp where pp.user_id = auth.uid() limit 1;
  v_admin := right(regexp_replace(
               coalesce((select value #>> '{}' from public.app_settings where key='admin_wa_phone'),''),
               '\D','','g'), 10);
  v_ph := coalesce(nullif(v_me,''), nullif(v_admin,''));

  if coalesce(length(v_ph),0) <> 10 then
    return jsonb_build_object('ok', false, 'error','no_test_number',
      'message', public._nc('notify.no_test_number',
        'Add a WhatsApp number to your admin profile (or set admin_wa_phone) to test-send.'));
  end if;

  -- Belt and braces: a supplier number can never be the target of a test.
  if public._notify_is_supplier_phone(v_ph) then
    return jsonb_build_object('ok', false, 'error','supplier_number',
      'message', public._nc('notify.test_supplier_blocked',
        'That number belongs to a supplier. Test messages are never sent to suppliers.'));
  end if;

  v := public.notify(p_event_key, v_ph,
         coalesce(p_vars,'{}'::jsonb) || jsonb_build_object('force_template', true));

  return jsonb_build_object(
    'ok', coalesce((v->>'ok')::boolean, false),
    'sent_to_label', public._ncf('notify.test_sent_to', jsonb_build_object('a', '+91 ' || v_ph),
                                 'Test sent to {a}'),
    'message', case when coalesce((v->>'ok')::boolean,false)
                    then public._nc('notify.test_ok','Sent — check your WhatsApp in a moment.')
                    else public._ncf('notify.test_failed', jsonb_build_object('a', coalesce(v->>'reason','unknown')),
                                     'Could not send: {a}') end,
    'detail', v);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The screen. One read, every string written here.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_center(p_hours integer default 24)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_since timestamptz; v_pending int; v_dead int; v_rows jsonb; v_alerts jsonb;
        v_sent int; v_failed int; v_queued int; cfg record;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._nc('notify.not_authorized','Only an admin can open the Notification Centre.'));
  end if;
  v_since := now() - make_interval(hours => greatest(1, least(coalesce(p_hours,24), 720)));
  select * into cfg from public.notification_health_config where id;

  select count(*) filter (where status='pending'), count(*) filter (where status='dead')
    into v_pending, v_dead from public.notification_retry_queue;

  select count(*) filter (where status='sent'),
         count(*) filter (where status='failed'),
         count(*) filter (where status='queued')
    into v_sent, v_failed, v_queued
    from public.notification_log where created_at >= v_since;

  select coalesce(jsonb_agg(x order by (x->>'sort_key')::text desc), '[]'::jsonb) into v_alerts
  from (
    select jsonb_build_object(
      'id', a.id, 'sort_key', a.raised_at::text,
      'title', coalesce(r.label, a.event_key),
      'body',  public._ncf('notify.alert_body',
                 jsonb_build_object('a', a.failure_pct::text, 'b', a.failures::text, 'c', a.attempts::text),
                 '{a}% not delivered — {b} of {c} in the last hour'),
      'tone', 'bad') as x
    from public.notification_alerts a
    left join public.wa_event_routes r on r.event_key = a.event_key
    where a.status = 'open'
  ) s;

  select coalesce(jsonb_agg(x order by (x->>'sort_key')::text), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'event_key',   r.event_key,
      'sort_key',    coalesce(r.audience,'customer') || '|' || coalesce(r.label, r.event_key),
      'title',       coalesce(r.label, r.event_key),
      'audience',    coalesce(r.audience,'customer'),
      'subtitle',    coalesce(r.description, r.template_name,
                              public._nc('notify.no_template','No template linked yet')),
      'enabled',     coalesce(r.enabled,false),
      'state_label', case when not coalesce(r.enabled,false)
                          then public._nc('notify.state_off','Off')
                          when r.template_id is null
                          then public._nc('notify.state_no_template','On — no template')
                          else public._nc('notify.state_live','Live') end,
      'state_tone',  case when not coalesce(r.enabled,false) then 'muted'
                          when r.template_id is null then 'warn' else 'good' end,
      'sent',        coalesce(l.sent,0),
      'failed',      coalesce(l.failed,0),
      'queued',      coalesce(l.queued,0),
      'count_label', public._ncf('notify.count_label',
                       jsonb_build_object('a', coalesce(l.sent,0)::text,
                                          'b', (coalesce(l.failed,0) + coalesce(l.queued,0))::text),
                       '{a} sent · {b} not delivered'),
      'channels_label', public._nc('notify.channel_whatsapp','WhatsApp'),
      'preview_label',  public._nc('notify.preview_action','Preview'),
      'test_label',     public._nc('notify.test_action','Send me a test')
    ) as x
    from public.wa_event_routes r
    left join (
      select event_key,
             count(*) filter (where status='sent')   as sent,
             count(*) filter (where status='failed') as failed,
             count(*) filter (where status='queued') as queued
        from public.notification_log where created_at >= v_since group by 1) l
      on l.event_key = r.event_key
  ) s;

  return jsonb_build_object(
    'ok', true,
    'heading',        public._nc('notify.heading','Notification Centre'),
    'subheading',     public._nc('notify.subheading',
                        'Every message mediBO sends goes out through one dispatcher. WhatsApp is the only channel today.'),
    'range_label',    public._ncf('notify.range_label',
                        jsonb_build_object('a', greatest(1, least(coalesce(p_hours,24),720))::text),
                        'Last {a} hours'),
    'summary_label',  public._ncf('notify.summary_label',
                        jsonb_build_object('a', coalesce(v_sent,0)::text,
                                           'b', coalesce(v_failed,0)::text,
                                           'c', coalesce(v_queued,0)::text),
                        '{a} sent · {b} failed · {c} waiting'),
    'summary_tone',   case when coalesce(v_failed,0) = 0 and coalesce(v_queued,0) = 0 then 'good'
                           when coalesce(v_failed,0) + coalesce(v_queued,0) <= 2 then 'warn'
                           else 'bad' end,
    'pending_label',  public._ncf('notify.pending_label',
                        jsonb_build_object('a', coalesce(v_pending,0)::text),
                        '{a} waiting to be retried'),
    'pending_count',  coalesce(v_pending,0),
    'dead_label',     public._ncf('notify.dead_label', jsonb_build_object('a', coalesce(v_dead,0)::text),
                        '{a} gave up after every retry'),
    'dead_count',     coalesce(v_dead,0),
    'threshold_label',public._ncf('notify.threshold_label',
                        jsonb_build_object('a', cfg.failure_pct_threshold::text),
                        'An alert is raised when more than {a}% of an event fails within an hour'),
    'alerts_heading', public._nc('notify.alerts_heading','Needs attention'),
    'alerts',         coalesce(v_alerts,'[]'::jsonb),
    'alerts_empty',   public._nc('notify.alerts_empty','No event is failing right now.'),
    'events_heading', public._nc('notify.events_heading','Events'),
    'events',         coalesce(v_rows,'[]'::jsonb),
    'events_empty',   public._nc('notify.events_empty','No notification routes are configured yet.'),
    'retry_label',    public._nc('notify.retry_now','Retry waiting messages'));
end $$;

-- Admin button: drain the queue now instead of waiting for the cron.
create or replace function public.notify_retry_now()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._nc('notify.not_authorized','Only an admin can do that.'));
  end if;
  v := public.notify_retry_tick(50);
  return jsonb_build_object('ok', true,
    'message', public._ncf('notify.retry_done',
                 jsonb_build_object('a', coalesce(v->>'tried','0'), 'b', coalesce(v->>'sent','0')),
                 'Tried {a} · sent {b}'),
    'detail', v);
end $$;

commit;

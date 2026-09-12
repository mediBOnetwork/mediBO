-- CMD #1929 (5/9) — the customer's WhatsApp reply resolves the payment match.
--
-- wa_assistant_handle is re-created with ONE block added, at the top of the
-- inbound path, before the assistant classifies. Everything else in the
-- function is byte-for-byte what it was: a phone with no open payment
-- question takes exactly the old path.

CREATE OR REPLACE FUNCTION public.wa_assistant_handle(p_message_id uuid, p_classify jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m record; v_phone10 text; v_text text; v_tid uuid; v_order uuid; v_cust uuid;
  v_zone smallint; v_cfg record; v_intent record; v_facts jsonb;
  v_cls jsonb; v_intent_key text; v_conf numeric; v_sent text;
  v_reply text; v_reason text; v_outcome text := 'skipped';
  v_unanswered int; v_sla text;
  v_pa jsonb;   -- CMD #1929
begin
  select * into m from public.whatsapp_messages where id = p_message_id;
  if not found then return jsonb_build_object('ok', false, 'error','no_message'); end if;
  if coalesce(m.direction,'') <> 'in' then
    return jsonb_build_object('ok', true, 'outcome','skipped', 'reason','outbound');
  end if;

  v_phone10 := right(regexp_replace(coalesce(m.sender_phone,''), '\D','','g'), 10);
  v_text := coalesce(nullif(btrim(m.text_body),''), nullif(btrim(m.caption),''), '');
  if v_text = '' then
    return jsonb_build_object('ok', true, 'outcome','skipped', 'reason','no_text');
  end if;

  -- CMD #1929 — a payment question THIS feature asked is answered by this
  -- feature, before the assistant classifies anything. Same principle as
  -- wa_assistant_intent.defer_to: two replies to one question is worse than
  -- the slower one on its own. Nothing else in this function changes, and a
  -- phone with no open payment question takes the old path untouched.
  begin
    v_pa := public.payment_alert_answer_try(v_phone10, v_text);
  exception when others then v_pa := null;
  end;
  if coalesce((v_pa->>'handled')::boolean, false) then
    if coalesce(v_pa->>'reply','') <> '' then
      begin
        perform public.wa_notify_customer_event('wa_assistant_reply',
          nullif(v_pa->>'order_id','')::uuid, v_phone10,
          'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
          jsonb_build_object('to', v_phone10, 'tag','payment_alert',
                             'text', v_pa->>'reply'),
          jsonb_build_object('text', v_pa->>'reply'));
      exception when others then null;
      end;
    end if;
    insert into public.wa_assistant_reply (message_id, wa_message_id, phone,
      customer_id, order_id, inbound_text, intent, outcome, reason, reply_text)
    values (m.id, m.wa_message_id, v_phone10,
            nullif(v_pa->>'customer_id','')::uuid, nullif(v_pa->>'order_id','')::uuid,
            left(v_text, 500), 'payment_alert_which_order',
            case when coalesce((v_pa->>'ok')::boolean, false) then 'answered' else 'handoff' end,
            'payment_alert_' || coalesce(v_pa->>'reason','answered'),
            left(coalesce(v_pa->>'reply',''), 1000));
    return jsonb_build_object('ok', true, 'outcome','answered',
      'reason','payment_alert_which_order', 'reply', coalesce(v_pa->>'reply',''),
      'payment_alert', v_pa);
  end if;

  v_tid := public._c713_wa_thread_for(v_phone10, v_text, m.reply_to_wa_id);
  select t.customer_id, t.order_id into v_cust, v_order
    from public.order_thread t where t.id = v_tid;
  select o.zone_id into v_zone from public.orders o where o.id = v_order;

  select * into v_cfg from public.wa_assistant_config
   where zone_id = coalesce(v_zone, 0::smallint);
  if not found then
    select * into v_cfg from public.wa_assistant_config where zone_id = 0::smallint;
  end if;
  if not coalesce(v_cfg.enabled, false) then
    insert into public.wa_assistant_reply (message_id, wa_message_id, phone, zone_id,
      customer_id, order_id, thread_id, inbound_text, outcome, reason)
    values (m.id, m.wa_message_id, v_phone10, v_zone, v_cust, v_order, v_tid,
            left(v_text, 500), 'skipped', 'assistant_off');
    return jsonb_build_object('ok', true, 'outcome','skipped', 'reason','assistant_off');
  end if;

  v_cls := coalesce(p_classify, '{}'::jsonb);
  v_intent_key := coalesce(nullif(v_cls->>'intent',''), 'other');
  v_conf := coalesce((v_cls->>'confidence')::numeric, 0);
  v_sent := coalesce(nullif(v_cls->>'sentiment',''), 'neutral');
  if coalesce((v_cls->>'ok')::boolean, false) is not true then
    v_intent_key := 'other'; v_conf := 0;
    v_reason := 'classifier_' || coalesce(v_cls->>'reason', 'unavailable');
  end if;

  select * into v_intent from public.wa_assistant_intent where key = v_intent_key;

  -- Another feature owns this question. Log it and say nothing: two replies to
  -- one question is worse than the slower one on its own.
  if v_intent.defer_to is not null then
    insert into public.wa_assistant_reply (message_id, wa_message_id, phone, zone_id,
      customer_id, order_id, thread_id, inbound_text, intent, confidence, sentiment,
      outcome, reason, model)
    values (m.id, m.wa_message_id, v_phone10, v_zone, v_cust, v_order, v_tid,
            left(v_text,500), v_intent_key, v_conf, v_sent, 'skipped',
            'deferred_to_' || v_intent.defer_to, nullif(v_cls->>'model',''));
    return jsonb_build_object('ok', true, 'outcome','skipped',
      'reason','deferred_to_' || v_intent.defer_to, 'intent', v_intent_key);
  end if;

  -- The customer has come back this many times since the assistant last
  -- answered them and a person last stepped in.
  select count(*)::int into v_unanswered
    from public.wa_assistant_reply r
   where r.phone = v_phone10
     and r.created_at > now() - interval '6 hours'
     and r.outcome = 'answered';

  v_reason := coalesce(v_reason,
    case
      when v_intent is null                          then 'unknown_intent'
      when not coalesce(v_intent.enabled, false)     then 'intent_disabled'
      when coalesce(v_intent.always_handoff, false)  then 'intent_always_handoff'
      when v_sent = 'negative'                       then 'negative_sentiment'
      when v_conf < coalesce(v_cfg.min_confidence, 0.75) then 'low_confidence'
      when v_unanswered >= coalesce(v_cfg.max_unanswered, 2) then 'unanswered_followups'
      when coalesce(v_intent.needs_order, true) and v_order is null then 'no_order'
      else null
    end);

  if v_reason is not null then
    v_sla := coalesce(nullif(v_cfg.handoff_sla_label,''),
                      public.uic('wa_asst.sla_default','shortly'));
    v_reply := replace(public.uic('wa_asst.handoff',''), '{sla}', v_sla);
    v_outcome := 'handoff';
    if v_tid is not null then
      begin
        perform public._thread_append(v_tid,
          replace(public.uic('wa_asst.thread_note',''), '{reason}', v_reason),
          'system', null, null, '', 'assistant', '[]'::jsonb, null, null);
      exception when others then null; end;
    end if;
    begin
      perform public.notify('wa_assistant_handoff', v_phone10,
        jsonb_build_object('reason', v_reason, 'order_code',
                           coalesce((select order_code from public.orders where id = v_order), '')));
    exception when others then null; end;
  else
    v_facts := public._c714_order_facts(v_order);
    v_reply := public.uic(v_intent.copy_key, '');
    v_reply := replace(v_reply, '{code}',             coalesce(v_facts->>'code',''));
    v_reply := replace(v_reply, '{status}',           coalesce(v_facts->>'status',''));
    v_reply := replace(v_reply, '{eta}',              coalesce(v_facts->>'eta',''));
    v_reply := replace(v_reply, '{amount}',           coalesce(v_facts->>'amount',''));
    v_reply := replace(v_reply, '{bill_note}',        coalesce(v_facts->>'bill_note',''));
    v_reply := replace(v_reply, '{payment}',          coalesce(v_facts->>'payment',''));
    v_reply := replace(v_reply, '{payment_note}',     coalesce(v_facts->>'payment_note',''));
    v_reply := replace(v_reply, '{return_status}',    coalesce(v_facts->>'return_status',''));
    v_reply := replace(v_reply, '{unavailable}',      coalesce(v_facts->>'unavailable',''));
    v_reply := replace(v_reply, '{unavailable_note}', coalesce(v_facts->>'unavailable_note',''));
    -- An empty token must not leave doubled or dangling punctuation behind,
    -- but the sentence keeps its own full stop. (The first attempt at this
    -- swallowed the closing '.' of every reply.)
    v_reply := regexp_replace(v_reply, '\s+', ' ', 'g');
    v_reply := replace(v_reply, ' .', '.');
    v_reply := regexp_replace(v_reply, '\.{2,}', '.', 'g');
    v_reply := regexp_replace(v_reply, '[—:-]\s*$', '', 'g');
    v_reply := btrim(v_reply);
    v_outcome := case when v_reply = '' then 'handoff' else 'answered' end;
    if v_outcome = 'handoff' then v_reason := 'empty_template'; end if;
  end if;

  if coalesce(v_reply,'') <> '' then
    begin
      perform public.wa_notify_customer_event('wa_assistant_reply', v_order, v_phone10,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
        jsonb_build_object('to', v_phone10, 'tag', 'wa_assistant', 'text', v_reply),
        jsonb_build_object('text', v_reply));
    exception when others then
      v_outcome := 'handoff'; v_reason := coalesce(v_reason,'send_failed');
    end;
  end if;

  insert into public.wa_assistant_reply (message_id, wa_message_id, phone, zone_id,
    customer_id, order_id, thread_id, inbound_text, intent, confidence, sentiment,
    outcome, reason, reply_text, model)
  values (m.id, m.wa_message_id, v_phone10, v_zone, v_cust, v_order, v_tid,
          left(v_text, 500), v_intent_key, v_conf, v_sent, v_outcome, v_reason,
          left(coalesce(v_reply,''), 1000), nullif(v_cls->>'model',''));

  return jsonb_build_object('ok', true, 'outcome', v_outcome, 'intent', v_intent_key,
    'confidence', v_conf, 'sentiment', v_sent, 'reason', v_reason,
    'reply', coalesce(v_reply,''), 'order_id', v_order, 'thread_id', v_tid);
end $function$;

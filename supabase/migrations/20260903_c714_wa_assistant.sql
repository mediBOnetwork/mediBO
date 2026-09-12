-- CHANGE #714 — the WhatsApp order assistant.
--
-- Today an inbound customer message lands in whatsapp_messages, #713 files it
-- on the order thread, and a person answers. "Where is my order" is the same
-- question a hundred times a week and the answer is already in the database.
--
-- THE RULE THIS FEATURE IS BUILT ON: the assistant never states a fact it made
-- up. It classifies the QUESTION with the model, and then every sentence it
-- sends is a template from ui_copy filled with values read out of
-- order_timeline / customer_track_order / the bill and payment rows. The model
-- picks WHICH template; it never writes one. A question it cannot classify
-- confidently, an angry one, or a complaint goes to a human — and so does
-- anything at all when the model is unreachable, which is the safe direction
-- to fail in.
--
-- Idempotent throughout.

-- ── 1. the intents ─────────────────────────────────────────────────────────
create table if not exists public.wa_assistant_intent (
  key           text primary key,
  label         text not null,
  -- The ui_copy key whose template this intent answers with. NULL means the
  -- intent is understood but always handed to a person (complaint).
  copy_key      text,
  -- Some questions are meaningless without an order to answer about.
  needs_order   boolean not null default true,
  -- Off by default is the wrong default for a feature nobody can see working,
  -- but ON by default for an intent nobody has reviewed is worse. Each row
  -- carries its own switch and the console flips it.
  enabled       boolean not null default true,
  -- An intent that always goes to a person no matter how sure the model is.
  always_handoff boolean not null default false,
  sort_order    int not null default 100
);

insert into public.wa_assistant_intent (key, label, copy_key, needs_order, enabled, always_handoff, sort_order) values
  ('where_is_order',    'Where is my order',   'wa_asst.where_is_order',  true,  true,  false, 10),
  ('bill',              'Bill or invoice',     'wa_asst.bill',            true,  true,  false, 20),
  ('payment_status',    'Payment status',      'wa_asst.payment_status',  true,  true,  false, 30),
  ('return_status',     'Return status',       'wa_asst.return_status',   true,  true,  false, 40),
  ('reorder',           'Reorder',             'wa_asst.reorder',         false, true,  false, 50),
  ('unavailable_item',  'Item not available',  'wa_asst.unavailable',     true,  true,  false, 60),
  ('complaint',         'Complaint',           null,                      false, true,  true,  70),
  ('other',             'Something else',      null,                      false, true,  true,  80)
on conflict (key) do update
  set label = excluded.label, copy_key = excluded.copy_key,
      needs_order = excluded.needs_order, always_handoff = excluded.always_handoff,
      sort_order = excluded.sort_order;

-- ── 2. the switches ────────────────────────────────────────────────────────
-- Zone 0 is the global row: the assistant is OFF everywhere until somebody
-- turns it on, because a wrong auto-reply to a customer is worse than a slow
-- human one.
create table if not exists public.wa_assistant_config (
  zone_id            smallint primary key,
  enabled            boolean not null default false,
  -- Below this the model's answer is not trusted and a person takes it.
  min_confidence     numeric not null default 0.75,
  -- Two unanswered follow-ups in a row and the assistant stops guessing.
  max_unanswered     int not null default 2,
  handoff_sla_label  text not null default '',
  updated_at         timestamptz not null default now(),
  updated_by         uuid
);

insert into public.wa_assistant_config (zone_id, enabled) values (0::smallint, false)
on conflict (zone_id) do nothing;

-- ── 3. every reply is logged, answered or handed off ───────────────────────
create table if not exists public.wa_assistant_reply (
  id            bigserial primary key,
  message_id    uuid,
  wa_message_id text,
  phone         text not null,
  zone_id       smallint,
  customer_id   uuid,
  order_id      uuid,
  thread_id     uuid,
  inbound_text  text,
  intent        text,
  confidence    numeric,
  sentiment     text,
  -- 'answered' | 'handoff' | 'skipped'
  outcome       text not null,
  reason        text,
  reply_text    text,
  model         text,
  created_at    timestamptz not null default now()
);

create index if not exists idx_wa_asst_reply_at on public.wa_assistant_reply (created_at desc);
create index if not exists idx_wa_asst_reply_phone on public.wa_assistant_reply (phone, created_at desc);

alter table public.wa_assistant_reply enable row level security;
alter table public.wa_assistant_intent enable row level security;
alter table public.wa_assistant_config enable row level security;
drop policy if exists wa_asst_reply_admin on public.wa_assistant_reply;
create policy wa_asst_reply_admin on public.wa_assistant_reply
  for select to authenticated
  using (public.get_my_role() in ('admin','super_admin'));
drop policy if exists wa_asst_intent_read on public.wa_assistant_intent;
create policy wa_asst_intent_read on public.wa_assistant_intent
  for select to authenticated using (true);
drop policy if exists wa_asst_config_admin on public.wa_assistant_config;
create policy wa_asst_config_admin on public.wa_assistant_config
  for select to authenticated
  using (public.get_my_role() in ('admin','super_admin'));

-- ── 4. every sentence the assistant may send ───────────────────────────────
-- These are the ONLY words that ever leave it. The model chooses which key to
-- use; it never writes a sentence, so it can never invent a delivery date, an
-- amount or a status. {tokens} are filled from order_timeline /
-- customer_track_order / the bill and payment rows and from nowhere else.
insert into public.ui_copy (key, value) values
  ('wa_asst.where_is_order', to_jsonb('Order {code}: {status}. {eta}'::text)),
  ('wa_asst.bill',           to_jsonb('Order {code} — bill {amount}. {bill_note}'::text)),
  ('wa_asst.payment_status', to_jsonb('Order {code}: {payment}. {payment_note}'::text)),
  ('wa_asst.return_status',  to_jsonb('Order {code} — return: {return_status}.'::text)),
  ('wa_asst.reorder',        to_jsonb('You can reorder from your last order here: {link}'::text)),
  ('wa_asst.unavailable',    to_jsonb('Order {code}: {unavailable}. {unavailable_note}'::text)),
  ('wa_asst.handoff',        to_jsonb('Thank you — a person from our team will reply {sla}.'::text)),
  ('wa_asst.sla_default',    to_jsonb('shortly'::text)),
  ('wa_asst.no_order',       to_jsonb('I could not find a recent order for this number, so I am passing this to our team.'::text)),
  ('wa_asst.eta_none',       to_jsonb(''::text)),
  ('wa_asst.bill_none',      to_jsonb('The bill is not ready yet.'::text)),
  ('wa_asst.payment_none',   to_jsonb('No payment recorded yet.'::text)),
  ('wa_asst.return_none',    to_jsonb('no return raised'::text)),
  ('wa_asst.unavailable_none', to_jsonb('every item is being fulfilled'::text)),
  ('wa_asst.thread_note',    to_jsonb('Assistant handed this to a person: {reason}'::text))
on conflict (key) do nothing;

insert into public.ui_copy (key, value) values
  ('wa_asst.console_title',    to_jsonb('WhatsApp assistant'::text)),
  ('wa_asst.console_subtitle', to_jsonb('What the assistant answered, what it handed to a person, and the switches that govern it.'::text)),
  ('wa_asst.console_empty',    to_jsonb('The assistant has not replied to anything yet.'::text)),
  ('wa_asst.console_denied',   to_jsonb('Only mediBO staff can see the assistant console.'::text)),
  ('wa_asst.switch_label',     to_jsonb('Assistant is on'::text)),
  ('wa_asst.switch_off_note',  to_jsonb('Off — every message goes straight to a person.'::text)),
  ('wa_asst.intents_heading',  to_jsonb('Which questions it may answer'::text)),
  ('wa_asst.replies_heading',  to_jsonb('Last 50 replies'::text)),
  ('wa_asst.zone_heading',     to_jsonb('Per zone'::text)),
  ('wa_asst.saved',            to_jsonb('Saved.'::text)),
  ('wa_asst.outcome_answered', to_jsonb('Answered'::text)),
  ('wa_asst.outcome_handoff',  to_jsonb('Handed to a person'::text)),
  ('wa_asst.outcome_skipped',  to_jsonb('Skipped'::text))
on conflict (key) do nothing;

-- ── 5. the facts, read out of the order and nowhere else ───────────────────
-- Every value this returns comes from a column or an existing RPC. There is no
-- branch here that writes prose: the sentence is a ui_copy template and this
-- function only fills its {tokens}.
create or replace function public._c714_order_facts(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  o record; v_tl jsonb; v_bill numeric; v_paid numeric; v_unav int; v_ret int;
begin
  select id, order_code, status, zone_id, customer_id, created_at
    into o from public.orders where id = p_order_id;
  if not found then return jsonb_build_object('has', false); end if;

  -- order_timeline is the CUSTOMER-facing wording of where an order is. The
  -- assistant repeats that sentence rather than inventing a second vocabulary
  -- for the same thing.
  begin v_tl := public.order_timeline(p_order_id); exception when others then v_tl := null; end;

  select coalesce(sum((e->>'amount')::numeric), 0) into v_bill
    from jsonb_array_elements(coalesce(public._bill_lines_for_order(p_order_id), '[]'::jsonb)) e
   where (e->>'amount') is not null;

  -- What the customer has actually paid against this order: the verified
  -- payment claims, which is the same ledger the pending-bills screen reads.
  select coalesce(sum(pc.amount), 0) into v_paid
    from public.payment_claims pc
   where pc.order_id = p_order_id
     and coalesce(pc.status,'') in ('verified','matched','settled');

  select count(*)::int into v_unav
    from public.order_items where order_id = p_order_id
     and coalesce(unfulfillable, false);

  select count(*)::int into v_ret
    from public.order_items oi
    join public.supplier_return_item ri on ri.order_item_id = oi.id
   where oi.order_id = p_order_id;

  return jsonb_build_object(
    'has', true,
    'order_id', o.id,
    'code', coalesce(o.order_code, ''),
    'zone_id', o.zone_id,
    'customer_id', o.customer_id,
    -- The timeline's own current-step label, verbatim.
    'status', coalesce(
        (select s->>'label' from jsonb_array_elements(coalesce(v_tl->'steps','[]'::jsonb)) s
          where (s->>'current')::boolean order by 1 limit 1),
        coalesce(o.status, '')),
    'eta', case when coalesce((v_tl->>'has_eta')::boolean, false)
                then coalesce(v_tl->>'eta_label','') || ' ' || coalesce(v_tl->>'eta_display','')
                else public.uic('wa_asst.eta_none','') end,
    'amount', public.inr_money(coalesce(v_bill, 0)),
    'bill_note', case when coalesce(v_bill,0) > 0 then ''
                      else public.uic('wa_asst.bill_none','') end,
    'payment', case when coalesce(v_paid,0) <= 0
                    then public.uic('wa_asst.payment_none','')
                    else public.inr_money(v_paid) end,
    'payment_note', case when coalesce(v_bill,0) > coalesce(v_paid,0)
                         then public.inr_money(coalesce(v_bill,0) - coalesce(v_paid,0))
                         else '' end,
    'return_status', case when coalesce(v_ret,0) > 0 then v_ret::text
                          else public.uic('wa_asst.return_none','') end,
    'unavailable', case when coalesce(v_unav,0) > 0 then v_unav::text
                        else public.uic('wa_asst.unavailable_none','') end,
    'unavailable_note', '');
end $function$;

comment on function public._c714_order_facts(uuid) is
  'CHANGE #714 — the values the assistant may put into a template. Every one is '
  'read from the order; none is written here.';

-- ── 6. the assistant itself ────────────────────────────────────────────────
-- The message id is a UUID, not a bigint. A create-or-replace with a changed
-- signature does not replace — it FORKS, leaving both live and every existing
-- caller on the old one (#703). So the wrong arity is dropped explicitly, and
-- the drop stays in the file because a resumed worker re-runs it.
drop function if exists public.wa_assistant_handle(bigint, jsonb);

create or replace function public.wa_assistant_handle(
  p_message_id uuid, p_classify jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m record; v_phone10 text; v_text text; v_tid uuid; v_order uuid; v_cust uuid;
  v_zone smallint; v_cfg record; v_intent record; v_facts jsonb;
  v_cls jsonb; v_intent_key text; v_conf numeric; v_sent text;
  v_reply text; v_reason text; v_outcome text := 'skipped';
  v_unanswered int; v_sla text;
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

  -- The SAME resolver #713 uses, so the assistant and the human thread can
  -- never disagree about which order a message is about.
  v_tid := public._c713_wa_thread_for(v_phone10, v_text, m.reply_to_wa_id);
  select t.customer_id, t.order_id into v_cust, v_order
    from public.order_thread t where t.id = v_tid;
  select o.zone_id into v_zone from public.orders o where o.id = v_order;

  -- The switch: the zone's row if it has one, otherwise the global row.
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

  -- The classifier's verdict. Passed in by the caller that already spoke to
  -- the edge function (the trigger does), or absent — and absent means a
  -- person takes it, which is the safe direction.
  v_cls := coalesce(p_classify, '{}'::jsonb);
  v_intent_key := coalesce(nullif(v_cls->>'intent',''), 'other');
  v_conf := coalesce((v_cls->>'confidence')::numeric, 0);
  v_sent := coalesce(nullif(v_cls->>'sentiment',''), 'neutral');
  if coalesce((v_cls->>'ok')::boolean, false) is not true then
    v_intent_key := 'other'; v_conf := 0;
    v_reason := 'classifier_' || coalesce(v_cls->>'reason', 'unavailable');
  end if;

  select * into v_intent from public.wa_assistant_intent where key = v_intent_key;

  -- ── the hand-off rules, in the order they must be read ──────────────────
  -- Two unanswered follow-ups: the customer has asked again and again and the
  -- assistant is plainly not helping.
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

    -- The person who takes over sees WHY, on the order thread itself.
    if v_tid is not null then
      begin
        perform public._thread_append(v_tid,
          replace(public.uic('wa_asst.thread_note',''), '{reason}', v_reason),
          'system', null, null, '', 'assistant', '[]'::jsonb, null, null);
      exception when others then null; end;
    end if;
    -- and the zone's partner is told there is a person-shaped job waiting.
    begin
      perform public.notify('wa_assistant_handoff', v_phone10,
        jsonb_build_object('reason', v_reason, 'order_code',
                           coalesce((select order_code from public.orders where id = v_order), '')));
    exception when others then null; end;
  else
    v_facts := public._c714_order_facts(v_order);
    v_reply := public.uic(v_intent.copy_key, '');
    -- Fill the template. Only these tokens exist, and every one of them came
    -- out of _c714_order_facts — so a template can never print a fact that is
    -- not in the order.
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
    v_reply := replace(v_reply, '{link}',             '');
    v_reply := btrim(regexp_replace(v_reply, '\s+', ' ', 'g'));
    v_outcome := case when v_reply = '' then 'handoff' else 'answered' end;
    if v_outcome = 'handoff' then v_reason := 'empty_template'; end if;
  end if;

  -- THE SEND. Through wa_notify_customer_event and nothing else: it picks
  -- free-form inside the 24 h window and the approved template outside it. A
  -- net.http_post here would look fine and then fail asynchronously with
  -- 'Re-engagement message'.
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

comment on function public.wa_assistant_handle(uuid, jsonb) is
  'CHANGE #714 — answers one inbound customer message from backend truth, or '
  'hands it to a person. Every sentence is a ui_copy template; the model only '
  'chooses which one.';

revoke all on function public.wa_assistant_handle(uuid, jsonb) from public, anon;
revoke all on function public._c714_order_facts(uuid) from public, anon;

-- ── 7. three things the live probe found ───────────────────────────────────
-- (a) 'reorder' is ALREADY answered by trg_wa_reorder_reply /
--     reorder_wa_inbound. Classifying it and answering it again would send the
--     customer two replies to one question, and the worse of the two would be
--     mine. The intent stays in the vocabulary — it is logged, so the console
--     shows how often people ask — but the assistant stays silent and lets the
--     feature that owns it answer.
alter table public.wa_assistant_intent
  add column if not exists defer_to text;

update public.wa_assistant_intent
   set defer_to = 'reorder_wa_inbound', copy_key = null
 where key = 'reorder';

-- (b) The tokens carried sentence punctuation, so the templates printed
--     "No payment recorded yet.." and a dangling "here:" with no link.
--     A token is a VALUE; the template owns the punctuation.
update public.ui_copy set value = to_jsonb('no payment recorded yet'::text)
 where key = 'wa_asst.payment_none';
update public.ui_copy set value = to_jsonb('The bill is not ready yet'::text)
 where key = 'wa_asst.bill_none';
update public.ui_copy set value = to_jsonb('Order {code} — payment: {payment}. {payment_note}'::text)
 where key = 'wa_asst.payment_status';
update public.ui_copy set value = to_jsonb('Order {code} — bill {amount}. {bill_note}'::text)
 where key = 'wa_asst.bill';

create or replace function public.wa_assistant_handle(
  p_message_id uuid, p_classify jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m record; v_phone10 text; v_text text; v_tid uuid; v_order uuid; v_cust uuid;
  v_zone smallint; v_cfg record; v_intent record; v_facts jsonb;
  v_cls jsonb; v_intent_key text; v_conf numeric; v_sent text;
  v_reply text; v_reason text; v_outcome text := 'skipped';
  v_unanswered int; v_sla text;
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

revoke all on function public.wa_assistant_handle(uuid, jsonb) from public, anon;

-- ── 8. the door the assistant listens at ───────────────────────────────────
-- An AFTER INSERT trigger beside the ones #713, #425 and the reorder handler
-- already use. It NEVER raises: an assistant that breaks an inbound webhook
-- would cost the business every message, not just the ones it cannot answer.
--
-- The classification round trip is an HTTP call, which must not happen inside
-- the webhook's transaction — so the trigger records the message as pending
-- and the cron dispatcher classifies and answers it a moment later. A customer
-- waiting two seconds longer is nothing; a webhook held open on Vertex is an
-- outage.
create table if not exists public.wa_assistant_queue (
  message_id   uuid primary key,
  phone        text not null,
  text_body    text not null,
  queued_at    timestamptz not null default now(),
  started_at   timestamptz,
  done_at      timestamptz,
  attempts     int not null default 0,
  last_error   text
);

create index if not exists idx_wa_asst_queue_pending
  on public.wa_assistant_queue (queued_at) where done_at is null;

create or replace function public.trg_c714_wa_assistant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_body text; v_on boolean;
begin
  if coalesce(new.direction,'') <> 'in' then return new; end if;
  if coalesce(new.is_synthetic, false) then return new; end if;
  if coalesce(new.msg_type,'') not in ('text','button','interactive') then return new; end if;

  v_body := coalesce(nullif(btrim(new.text_body),''), nullif(btrim(new.caption),''), '');
  if v_body = '' then return new; end if;

  -- Nothing is queued while every switch is off, so a disabled assistant costs
  -- the inbound path one boolean read.
  select bool_or(enabled) into v_on from public.wa_assistant_config;
  if not coalesce(v_on, false) then return new; end if;

  insert into public.wa_assistant_queue (message_id, phone, text_body)
  values (new.id, coalesce(new.sender_phone,''), left(v_body, 1000))
  on conflict (message_id) do nothing;

  return new;
exception when others then
  return new;
end $function$;

drop trigger if exists c714_wa_assistant_trg on public.whatsapp_messages;
create trigger c714_wa_assistant_trg
  after insert on public.whatsapp_messages
  for each row execute function public.trg_c714_wa_assistant();

-- The worker the dispatcher runs: classify, then answer. It is deliberately
-- one message per tick — a burst of inbound must not become a burst of Vertex
-- calls on a 1 GB box.
create or replace function public.wa_assistant_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare q record; v_cls jsonb; v_res jsonb; v_resp jsonb;
begin
  select * into q from public.wa_assistant_queue
   where done_at is null and attempts < 3
   order by queued_at
   limit 1 for update skip locked;
  if not found then return jsonb_build_object('ok', true, 'idle', true); end if;

  update public.wa_assistant_queue
     set started_at = now(), attempts = attempts + 1 where message_id = q.message_id;

  begin
    select content::jsonb into v_resp from net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-assistant',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('text', q.text_body),
      timeout_milliseconds := 20000) as t(content text);
    v_cls := coalesce(v_resp, jsonb_build_object('ok', false, 'reason','no_response'));
  exception when others then
    v_cls := jsonb_build_object('ok', false, 'reason','http_error');
  end;

  v_res := public.wa_assistant_handle(q.message_id, v_cls);

  update public.wa_assistant_queue
     set done_at = now(), last_error = nullif(v_res->>'reason','')
   where message_id = q.message_id;

  return jsonb_build_object('ok', true, 'message_id', q.message_id, 'result', v_res);
end $function$;

comment on function public.wa_assistant_tick() is
  'CHANGE #714 — one queued inbound message per tick: classify, then answer or '
  'hand off. The HTTP call is here and never inside the inbound webhook.';

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, note,
                              base_interval_s, dml)
values ('wa_assistant_tick', 640, 'poll',
        'select exists (select 1 from public.wa_assistant_queue where done_at is null and attempts < 3)',
        'select public.wa_assistant_tick()', true,
        'CHANGE #714 — answers one queued inbound WhatsApp question.', 60, true)
on conflict (name) do update
  set work_sql = excluded.work_sql, gate_sql = excluded.gate_sql,
      note = excluded.note, enabled = true;

revoke all on function public.wa_assistant_tick() from public, anon;

-- ── 9. the console ─────────────────────────────────────────────────────────
create or replace function public.wa_assistant_console(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_intents jsonb; v_zones jsonb; v_global record;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', public.uic('wa_asst.console_title','WhatsApp assistant'),
      'message', public.uic('wa_asst.console_denied',''));
  end if;

  select * into v_global from public.wa_assistant_config where zone_id = 0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', r.id::text,
           'phone', r.phone,
           'inbound', coalesce(r.inbound_text,''),
           'intent', coalesce(i.label, coalesce(r.intent,'—')),
           'intent_key', coalesce(r.intent,''),
           'confidence', r.confidence,
           'confidence_label', case when r.confidence is null then '—'
                                    else to_char(round(r.confidence*100), 'FM990') || '%' end,
           'sentiment', coalesce(r.sentiment,''),
           'outcome', r.outcome,
           'outcome_label', case r.outcome
                              when 'answered' then public.uic('wa_asst.outcome_answered','')
                              when 'handoff'  then public.uic('wa_asst.outcome_handoff','')
                              else public.uic('wa_asst.outcome_skipped','') end,
           'outcome_tone', case r.outcome when 'answered' then 'success'
                                          when 'handoff' then 'warning' else 'neutral' end,
           'reason', coalesce(r.reason,''),
           'reply', coalesce(r.reply_text,''),
           'at', public._ist_stamp(r.created_at))
         order by r.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.wa_assistant_reply
           order by created_at desc
           limit greatest(coalesce(p_limit,50),1)) r
    left join public.wa_assistant_intent i on i.key = r.intent;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.key, 'label', t.label, 'enabled', t.enabled,
           'always_handoff', t.always_handoff,
           'defer_to', coalesce(t.defer_to,''),
           'needs_order', t.needs_order)
         order by t.sort_order), '[]'::jsonb)
    into v_intents from public.wa_assistant_intent t;

  select coalesce(jsonb_agg(jsonb_build_object(
           'zone_id', z.id, 'zone_name', z.name,
           'enabled', coalesce(c.enabled, false))
         order by z.id), '[]'::jsonb)
    into v_zones
    from public.zones z
    left join public.wa_assistant_config c on c.zone_id = z.id
   where z.is_active and not coalesce(z.is_synthetic, false);

  return jsonb_build_object('ok', true,
    'title', public.uic('wa_asst.console_title',''),
    'subtitle', public.uic('wa_asst.console_subtitle',''),
    'empty_note', public.uic('wa_asst.console_empty',''),
    'switch_label', public.uic('wa_asst.switch_label',''),
    'switch_off_note', public.uic('wa_asst.switch_off_note',''),
    'intents_heading', public.uic('wa_asst.intents_heading',''),
    'replies_heading', public.uic('wa_asst.replies_heading',''),
    'zone_heading', public.uic('wa_asst.zone_heading',''),
    'enabled', coalesce(v_global.enabled, false),
    'min_confidence', coalesce(v_global.min_confidence, 0.75),
    'intents', v_intents,
    'zones', v_zones,
    'rows', v_rows);
end $function$;

create or replace function public.wa_assistant_set(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('wa_asst.console_denied',''));
  end if;

  -- One verb for all three switches, so the screen never learns three shapes.
  if p_patch ? 'intent_key' then
    update public.wa_assistant_intent
       set enabled = coalesce((p_patch->>'enabled')::boolean, enabled)
     where key = p_patch->>'intent_key';
  elsif p_patch ? 'zone_id' then
    insert into public.wa_assistant_config (zone_id, enabled, updated_at, updated_by)
    values ((p_patch->>'zone_id')::smallint,
            coalesce((p_patch->>'enabled')::boolean, false), now(), auth.uid())
    on conflict (zone_id) do update
      set enabled = excluded.enabled, updated_at = now(), updated_by = auth.uid();
  else
    update public.wa_assistant_config
       set enabled = coalesce((p_patch->>'enabled')::boolean, enabled),
           min_confidence = coalesce((p_patch->>'min_confidence')::numeric, min_confidence),
           max_unanswered = coalesce((p_patch->>'max_unanswered')::int, max_unanswered),
           updated_at = now(), updated_by = auth.uid()
     where zone_id = 0;
  end if;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public.uic('wa_asst.saved',''),
    'state', public.wa_assistant_console(50));
end $function$;

revoke all on function public.wa_assistant_console(integer) from public, anon;
revoke all on function public.wa_assistant_set(jsonb) from public, anon;
grant execute on function public.wa_assistant_console(integer) to authenticated;
grant execute on function public.wa_assistant_set(jsonb) to authenticated;

-- ── 10. the door — all THREE rows ──────────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, description)
values ('admin.wa_assistant', 'WhatsApp assistant', 'WhatsApp', 'forum',
        'wa_assistant', 61, 'medibo', false, 'none', true, 'comms', 'dashboard',
        array['admin','super_admin'],
        'CHANGE #714 — what the assistant answered, what it handed to a person, and the switches that govern it.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      route_key = excluded.route_key, roles_allowed = excluded.roles_allowed,
      surface = excluded.surface, description = excluded.description, is_active = true;

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('wa_assistant', 'admin.wa_assistant', 'feature', 'home_shell',
        'CHANGE #714 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true;

-- The row every migration forgets: without it #653 refuses the route while the
-- tile still renders (the #713 trap).
insert into public.access_role_default (role, feature_key, can_view, can_write) values
  ('admin',       'admin.wa_assistant', true, false),
  ('super_admin', 'admin.wa_assistant', true, true)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write;

-- CHANGE #712 · the customer stops waiting in the dark.
--
-- WHAT WAS MEASURED. notification_settings audience='customer' held 51 outbound
-- events and not one of them covered: (a) anything between order_accepted and
-- order_dispatched — the whole sourcing waterfall, which is the longest wait in
-- the order and the one the pharmacy cannot see; (b) a return decision — a
-- pharmacy raises one and hears nothing back, ever; (c) a refund — no "we have
-- started it", no "it is done, here is the reference"; (d) a partial delivery —
-- the rider hands over less than the order and nothing tells the pharmacy what
-- was left out or when it follows. _order_timeline_events() confirmed the same
-- three holes from the other side: ten sections, none of them a return, a
-- refund or a partial handover, and its only message section is internal:true.
--
-- THE SHAPE. One ledger, one emitter, triggers on state. No business RPC is
-- rewritten, because a notification that can break a return is worse than no
-- notification.
--
--   order_customer_event  — one row per (order, event, dedupe key). The UNIQUE
--     is the idempotency, the timeline's source, and the evidence that an event
--     fired exactly once. Everything else reads it.
--   _c712_emit()          — insert first (a duplicate never reaches the wire),
--     then public.notify(), which already does push -> WhatsApp template ->
--     email with the global setting, the per-user setting and the recipient's
--     language. Wrapped: a notification failure can never roll back the return,
--     the refund or the handover that fired it.
--
-- Idempotent throughout: create table if not exists, create or replace, on
-- conflict do nothing/update, drop trigger if exists.

-- ═══════════════════════ 1 · the ledger ═══════════════════════

create table if not exists public.order_customer_event (
  id            bigint generated always as identity primary key,
  order_id      uuid not null references public.orders(id) on delete cascade,
  customer_id   uuid,
  event_key     text not null,
  -- What makes this occurrence distinct. 'order' for a once-per-order event,
  -- the return/refund id for a per-record one, a 4-hour bucket for the throttled
  -- sourcing update. It is the whole of the idempotency rule and it is DATA.
  dedupe_key    text not null default 'order',
  vars          jsonb not null default '{}'::jsonb,
  notify_result jsonb,
  sent_at       timestamptz not null default now()
);

create unique index if not exists order_customer_event_once_uk
  on public.order_customer_event (order_id, event_key, dedupe_key);
create index if not exists order_customer_event_order_idx
  on public.order_customer_event (order_id, sent_at);

alter table public.order_customer_event enable row level security;

-- Read-only to the pharmacy that owns the order; writes are SECURITY DEFINER
-- only. The timeline reads it through _order_timeline_events(), which is itself
-- definer, so this policy is the direct-read case.
drop policy if exists order_customer_event_owner_read on public.order_customer_event;
create policy order_customer_event_owner_read on public.order_customer_event
  for select using (
    exists (select 1 from public.orders o
             where o.id = order_customer_event.order_id
               and (o.customer_id = auth.uid() or o.user_id = auth.uid()))
    or public._is_admin());

-- ═══════════════════════ 2 · the emitter ═══════════════════════

create or replace function public._c712_emit(
  p_order_id uuid, p_event_key text, p_vars jsonb default '{}'::jsonb,
  p_dedupe_key text default 'order')
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  o public.orders%rowtype;
  v_phone text; v_name text; v_vars jsonb; v_res jsonb; v_id bigint;
begin
  if p_order_id is null or coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_target');
  end if;
  select * into o from public.orders where id = p_order_id;
  if not found then return jsonb_build_object('ok', false, 'reason','no_order'); end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(o.pharmacy_name),''), ''),
         coalesce(nullif(btrim(pp.whatsapp_no),''), nullif(btrim(pp.phone),''),
                  nullif(btrim(o.phone),''), '')
    into v_name, v_phone
    from public.orders o2 left join public.pharmacy_profiles pp on pp.id = o2.customer_id
   where o2.id = p_order_id;

  v_vars := coalesce(p_vars,'{}'::jsonb)
            || jsonb_build_object(
                 'pharmacy_name', coalesce(v_name,''),
                 'order_code', coalesce(o.order_code, ''),
                 'order_id', p_order_id::text,
                 'customer_id', coalesce(o.customer_id::text, ''));

  -- THE LEDGER IS THE LOCK. A second trigger firing on the same state change
  -- loses this insert and returns without touching the wire, so "exactly once"
  -- is a database constraint rather than a promise made in nine places.
  insert into public.order_customer_event (order_id, customer_id, event_key, dedupe_key, vars)
  values (p_order_id, o.customer_id, p_event_key, coalesce(nullif(btrim(p_dedupe_key),''),'order'), v_vars)
  on conflict (order_id, event_key, dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'deduped', true, 'event', p_event_key);
  end if;

  -- A notification must never be able to roll back the business fact that
  -- caused it. Every failure is recorded on the ledger row and swallowed.
  begin
    v_res := public.notify(p_event_key, v_phone, v_vars);
  exception when others then
    v_res := jsonb_build_object('ok', false, 'reason','exception','message', sqlerrm);
  end;

  update public.order_customer_event set notify_result = v_res where id = v_id;
  return jsonb_build_object('ok', true, 'event', p_event_key, 'id', v_id, 'notify', v_res);
end $fn$;

comment on function public._c712_emit(uuid, text, jsonb, text) is
  'CHANGE #712 — the one door every customer order event goes through: ledger first (idempotent), then notify().';

-- ═══════════════════════ 3 · the vocabulary ═══════════════════════
-- New tokens only. Everything an existing message already says (pharmacy_name,
-- order_code, product_name, amount, payment_mode, utr, reason) is reused.

insert into public.wa_tokens (key, label, group_label, source_kind, source_ref, example, sort_order)
values
  ('sourcing_window',  'Expected dispatch window', 'Order', 'computed', 'sourcing_window',  'today by 7 pm', 120),
  ('confirmed_count',  'Items confirmed so far',   'Order', 'computed', 'confirmed_count',  '6',             121),
  ('pending_count',    'Items still being sourced','Order', 'computed', 'pending_count',    '2',             122),
  ('unfulfilled_names','Items nobody could supply','Order', 'computed', 'unfulfilled_names','Olmigo 40mg, Pan-D', 123),
  ('return_qty',       'Quantity returned',        'Order', 'computed', 'return_qty',       '2',             124),
  ('credit_amount',    'Credit note amount',       'Money', 'computed', 'credit_amount',    'Rs 1,240.00',   125),
  ('refund_ref',       'Refund reference',         'Money', 'computed', 'refund_ref',       'rfnd_PXY12ab',  126),
  ('delivered_count',  'Items delivered',          'Order', 'computed', 'delivered_count',  '9',             127),
  ('follows_count',    'Items still to follow',    'Order', 'computed', 'follows_count',    '1',             128),
  ('substitute_link',  'Substitute offer link',    'Order', 'computed', 'substitute_link',  'https://medibo.in/substitute-ask/6f1c2b', 129)
on conflict (key) do nothing;

-- ═══════════════════════ 4 · the nine events ═══════════════════════
-- Inserting the route is all that is needed for the admin list: the existing
-- wa_route_to_notification_trg writes the notification_settings row from it.

insert into public.wa_event_routes
  (event_key, label, description, language, audience, enabled, auto_manage,
   auto_template_name, wa_category, variable_map, dedupe_minutes,
   push_enabled, push_title, push_body, push_title_hi, push_body_hi,
   email_enabled, email_subject, email_body)
values
  ('sourcing_started', 'Sourcing started',
   'CHANGE #712 — the inquiry waterfall began. First word the pharmacy gets after the order is accepted.',
   'en', 'customer', true, true, 'sourcing_started', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{count}}", "{{sourcing_window}}"]'::jsonb, 0,
   true, 'Sourcing order {{order_code}}',
   'We are checking {{count}} items with our suppliers. Expected dispatch {{sourcing_window}}.',
   'ऑर्डर {{order_code}} की सोर्सिंग शुरू',
   'हम {{count}} आइटम सप्लायर से कन्फर्म कर रहे हैं। डिस्पैच {{sourcing_window}} तक।',
   true, 'We have started sourcing order {{order_code}}',
   E'Dear {{pharmacy_name}},\n\nWe have started sourcing order {{order_code}} — {{count}} items are with our suppliers now. Expected dispatch: {{sourcing_window}}.'),

  ('sourcing_update', 'Sourcing progress',
   'CHANGE #712 — items confirmed so far while others are still being sourced. At most one every 4 hours.',
   'en', 'customer', true, true, 'sourcing_update', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{confirmed_count}}", "{{pending_count}}"]'::jsonb, 0,
   true, 'Order {{order_code}} — {{confirmed_count}} confirmed',
   '{{confirmed_count}} items confirmed, {{pending_count}} still being sourced.',
   'ऑर्डर {{order_code}} — {{confirmed_count}} कन्फर्म',
   '{{confirmed_count}} आइटम कन्फर्म, {{pending_count}} अभी सोर्स हो रहे हैं।',
   true, 'Order {{order_code}} — {{confirmed_count}} items confirmed',
   E'Dear {{pharmacy_name}},\n\n{{confirmed_count}} items on order {{order_code}} are confirmed. {{pending_count}} are still being sourced — we will tell you as soon as they are settled.'),

  ('sourcing_done', 'Sourcing finished',
   'CHANGE #712 — the waterfall is over. Final list, and anything nobody could supply is named.',
   'en', 'customer', true, true, 'sourcing_done', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{confirmed_count}}", "{{unfulfilled_names}}"]'::jsonb, 0,
   true, 'Order {{order_code}} sourced',
   '{{confirmed_count}} items confirmed. Could not supply: {{unfulfilled_names}}',
   'ऑर्डर {{order_code}} सोर्स हो गया',
   '{{confirmed_count}} आइटम कन्फर्म। नहीं मिल पाए: {{unfulfilled_names}}',
   true, 'Order {{order_code}} — sourcing complete',
   E'Dear {{pharmacy_name}},\n\nSourcing for order {{order_code}} is complete: {{confirmed_count}} items confirmed.\n\nWe could not supply: {{unfulfilled_names}}'),

  ('return_requested_ack', 'Return request received',
   'CHANGE #712 — acknowledges a return the pharmacy raised, so it is never silent.',
   'en', 'customer', true, true, 'return_requested_ack', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{product_name}}", "{{return_qty}}"]'::jsonb, 0,
   true, 'Return received — {{order_code}}',
   '{{return_qty}} x {{product_name}}. We will review and tell you the decision.',
   'रिटर्न मिल गया — {{order_code}}',
   '{{return_qty}} x {{product_name}}। हम जाँच कर के बताएंगे।',
   true, 'Return request received for order {{order_code}}',
   E'Dear {{pharmacy_name}},\n\nWe have your return request on order {{order_code}} — {{return_qty}} x {{product_name}}. We will review it and tell you the decision here.'),

  ('return_approved', 'Return approved',
   'CHANGE #712 — the decision, with the credit it carries.',
   'en', 'customer', true, true, 'return_approved', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{product_name}}", "{{credit_amount}}"]'::jsonb, 0,
   true, 'Return approved — {{order_code}}',
   '{{product_name}} approved. Credit {{credit_amount}}.',
   'रिटर्न मंज़ूर — {{order_code}}',
   '{{product_name}} मंज़ूर। क्रेडिट {{credit_amount}}।',
   true, 'Return approved on order {{order_code}}',
   E'Dear {{pharmacy_name}},\n\nYour return of {{product_name}} on order {{order_code}} is approved. Credit: {{credit_amount}}.'),

  ('return_rejected', 'Return rejected',
   'CHANGE #712 — the decision and the reason, in the pharmacy own words back to it.',
   'en', 'customer', true, true, 'return_rejected', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{product_name}}", "{{reason}}"]'::jsonb, 0,
   true, 'Return not approved — {{order_code}}',
   '{{product_name}}: {{reason}}',
   'रिटर्न मंज़ूर नहीं — {{order_code}}',
   '{{product_name}}: {{reason}}',
   true, 'Return decision on order {{order_code}}',
   E'Dear {{pharmacy_name}},\n\nWe could not approve the return of {{product_name}} on order {{order_code}}.\n\nReason: {{reason}}'),

  ('refund_initiated', 'Refund started',
   'CHANGE #712 — the money is moving; amount and mode named up front.',
   'en', 'customer', true, true, 'refund_initiated', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{amount}}", "{{payment_mode}}"]'::jsonb, 0,
   true, 'Refund started — {{order_code}}',
   '{{amount}} by {{payment_mode}}. We will confirm when it lands.',
   'रिफंड शुरू — {{order_code}}',
   '{{amount}}, {{payment_mode}} से। पूरा होने पर बताएंगे।',
   true, 'Refund started for order {{order_code}}',
   E'Dear {{pharmacy_name}},\n\nA refund of {{amount}} for order {{order_code}} has been started by {{payment_mode}}. We will confirm here when it is done.'),

  ('refund_done', 'Refund completed',
   'CHANGE #712 — amount, mode and the reference the pharmacy accountant needs.',
   'en', 'customer', true, true, 'refund_done', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{amount}}", "{{refund_ref}}"]'::jsonb, 0,
   true, 'Refund completed — {{order_code}}',
   '{{amount}} refunded. Reference {{refund_ref}}.',
   'रिफंड पूरा — {{order_code}}',
   '{{amount}} वापस। रेफरेंस {{refund_ref}}।',
   true, 'Refund completed for order {{order_code}}',
   E'Dear {{pharmacy_name}},\n\n{{amount}} has been refunded for order {{order_code}}.\n\nReference: {{refund_ref}}'),

  ('delivery_partial', 'Partial delivery',
   'CHANGE #712 — what was handed over, what is still to follow, and when.',
   'en', 'customer', true, true, 'delivery_partial', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{delivered_count}}", "{{follows_count}}"]'::jsonb, 0,
   true, 'Part of order {{order_code}} delivered',
   '{{delivered_count}} items delivered, {{follows_count}} to follow.',
   'ऑर्डर {{order_code}} का कुछ हिस्सा डिलीवर',
   '{{delivered_count}} आइटम डिलीवर, {{follows_count}} बाकी।',
   true, 'Part of order {{order_code}} was delivered',
   E'Dear {{pharmacy_name}},\n\n{{delivered_count}} items from order {{order_code}} were delivered. {{follows_count}} are still to follow — we will tell you when they are on the way.')
on conflict (event_key) do nothing;

-- ═══════════════════════ 5 · the templates ═══════════════════════
-- Written as DRAFT with a filled `example` block, exactly the shape
-- notification_generate_template() produces, so the existing Notifications
-- card can submit each one to Meta with its Submit action (#228). Until Meta
-- approves, notify() falls through to push and email, which need no approval —
-- the customer is never silent while a template is pending.

insert into public.wa_templates (name, language, category, status, components, token_map)
values
  ('sourcing_started','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, we have started sourcing order {{2}}. {{3}} items are with our suppliers now and we expect to dispatch {{4}}. We will tell you here as items are confirmed.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','CPO020826CHAO1','8','today by 7 pm')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","order_code","count","sourcing_window"]'::jsonb),

  ('sourcing_update','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, order {{2}} update: {{3}} items are confirmed and {{4}} are still being sourced. We will send the final list as soon as it is settled.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','CPO020826CHAO1','6','2')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","order_code","confirmed_count","pending_count"]'::jsonb),

  ('sourcing_done','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, sourcing for order {{2}} is complete. {{3}} items are confirmed. We could not supply: {{4}}. Packing starts now.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','CPO020826CHAO1','7','Olmigo 40mg Tablet, Pan-D Capsule')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","order_code","confirmed_count","unfulfilled_names"]'::jsonb),

  ('return_requested_ack','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, we have your return request on order {{2}} — {{3}} x {{4}}. Our team will review it and you will get the decision here.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','CPO020826CHAO1','2','Olmigo 40mg Tablet')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","order_code","return_qty","product_name"]'::jsonb),

  ('return_approved','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, your return of {{2}} on order {{3}} is approved. Credit note value: {{4}}. It will be adjusted against your account.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','Olmigo 40mg Tablet','CPO020826CHAO1','Rs 1,240.00')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","product_name","order_code","credit_amount"]'::jsonb),

  ('return_rejected','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, we could not approve the return of {{2}} on order {{3}}. Reason: {{4}}. Reply here if you want us to look again.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','Olmigo 40mg Tablet','CPO020826CHAO1','Returned after the 7-day window')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","product_name","order_code","reason"]'::jsonb),

  ('refund_initiated','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, a refund of {{2}} for order {{3}} has been started by {{4}}. We will confirm here the moment it is done.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','Rs 1,240.00','CPO020826CHAO1','UPI')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","amount","order_code","payment_mode"]'::jsonb),

  ('refund_done','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, {{2}} has been refunded for order {{3}} by {{4}}. Reference: {{5}}. Please allow your bank its usual settlement time.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','Rs 1,240.00','CPO020826CHAO1','UPI','rfnd_PXY12ab')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","amount","order_code","payment_mode","refund_ref"]'::jsonb),

  ('delivery_partial','en','UTILITY','DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY','text',
       'Namaste {{1}}, part of order {{2}} was delivered: {{3}} items handed over, {{4}} still to follow. We will tell you when the rest is on the way.',
       'example', jsonb_build_object('body_text', jsonb_build_array(
         jsonb_build_array('Chandra Medicom','CPO020826CHAO1','9','1')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   '["pharmacy_name","order_code","delivered_count","follows_count"]'::jsonb)
on conflict do nothing;

-- Link each route to the template that carries its name.
update public.wa_event_routes r
   set template_id = t.id, updated_at = now()
  from public.wa_templates t
 where t.name = r.auto_template_name and t.language = 'en'
   and r.template_id is null
   and r.event_key in ('sourcing_started','sourcing_update','sourcing_done',
                       'return_requested_ack','return_approved','return_rejected',
                       'refund_initiated','refund_done','delivery_partial');

-- ═══════════════════════ 6 · the copy ═══════════════════════
-- Every sentence these triggers can produce is an UPDATE on ui_copy, never a
-- deploy — including the timeline wording added below.

insert into public.ui_copy (key, value) values
  ('c712.window_unknown', to_jsonb('as soon as it is sourced'::text)),
  ('c712.reason_none', to_jsonb('no reason was recorded'::text)),
  ('c712.unfulfilled_none', to_jsonb('nothing — every item was found'::text)),
  ('c712.mode_upi', to_jsonb('UPI'::text)),
  ('c712.ref_pending', to_jsonb('reference to follow'::text)),
  ('order_timeline.ev_c712', to_jsonb('We told you'::text)),
  ('order_timeline.ev_c712_sourcing_started', to_jsonb('Sourcing started'::text)),
  ('order_timeline.ev_c712_sourcing_update', to_jsonb('Sourcing progress'::text)),
  ('order_timeline.ev_c712_sourcing_done', to_jsonb('Sourcing finished'::text)),
  ('order_timeline.ev_c712_return_requested_ack', to_jsonb('Return request received'::text)),
  ('order_timeline.ev_c712_return_approved', to_jsonb('Return approved'::text)),
  ('order_timeline.ev_c712_return_rejected', to_jsonb('Return not approved'::text)),
  ('order_timeline.ev_c712_refund_initiated', to_jsonb('Refund started'::text)),
  ('order_timeline.ev_c712_refund_done', to_jsonb('Refund completed'::text)),
  ('order_timeline.ev_c712_delivery_partial', to_jsonb('Part of the order delivered'::text)),
  ('order_timeline.ev_c712_sourcing_started_detail', to_jsonb('{count} items with our suppliers · dispatch {sourcing_window}'::text)),
  ('order_timeline.ev_c712_sourcing_update_detail', to_jsonb('{confirmed_count} confirmed · {pending_count} still sourcing'::text)),
  ('order_timeline.ev_c712_sourcing_done_detail', to_jsonb('{confirmed_count} confirmed · could not supply: {unfulfilled_names}'::text)),
  ('order_timeline.ev_c712_return_requested_ack_detail', to_jsonb('{return_qty} x {product_name} · under review'::text)),
  ('order_timeline.ev_c712_return_approved_detail', to_jsonb('{product_name} · credit {credit_amount}'::text)),
  ('order_timeline.ev_c712_return_rejected_detail', to_jsonb('{product_name} · {reason}'::text)),
  ('order_timeline.ev_c712_refund_initiated_detail', to_jsonb('{amount} by {payment_mode}'::text)),
  ('order_timeline.ev_c712_refund_done_detail', to_jsonb('{amount} · reference {refund_ref}'::text)),
  ('order_timeline.ev_c712_delivery_partial_detail', to_jsonb('{delivered_count} delivered · {follows_count} to follow'::text))
on conflict (key) do nothing;

-- The dispatch window the pharmacy is quoted (#688/#702). Absent is a sentence,
-- never a blank: a window we cannot promise still has to read as something.
create or replace function public._c712_window(p_order_id uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_pin text; v jsonb;
begin
  select coalesce(nullif(btrim(pp.pincode),''), '')
    into v_pin from public.orders o
    left join public.pharmacy_profiles pp on pp.id = o.customer_id
   where o.id = p_order_id;
  v := public.delivery_promise(nullif(v_pin,''));
  return coalesce(nullif(btrim(coalesce(v->>'label','')),''),
                  public.uic('c712.window_unknown','as soon as it is sourced'));
end $fn$;


-- (sections 7 and 9 are superseded below by 7b and 9b — see why there.)

-- ═══════════════════════ 8 · returns ═══════════════════════

create or replace function public._c712_return_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_name text;
begin
  v_name := coalesce(nullif(btrim(new.product_name),''),
                     (select oi.product_name from public.order_items oi where oi.id = new.order_item_id), '');

  if tg_op = 'INSERT' then
    perform public._c712_emit(new.order_id, 'return_requested_ack',
      jsonb_build_object('product_name', v_name,
                         'return_qty', trim_scale(new.qty)::text),
      new.id::text);
    return null;
  end if;

  if coalesce(new.status,'') is distinct from coalesce(old.status,'') then
    if new.status = 'approved' then
      perform public._c712_emit(new.order_id, 'return_approved',
        jsonb_build_object('product_name', v_name,
                           'return_qty', trim_scale(new.qty)::text,
                           'credit_amount', public.inr_money(coalesce(new.credit_total,0))),
        new.id::text);
    elsif new.status = 'rejected' then
      perform public._c712_emit(new.order_id, 'return_rejected',
        jsonb_build_object('product_name', v_name,
                           'reason', coalesce(nullif(btrim(new.note),''),
                                              public.uic('c712.reason_none','no reason was recorded'))),
        new.id::text);
    end if;
  end if;
  return null;
end $fn$;

drop trigger if exists _c712_return_trg on public.order_returns;
create trigger _c712_return_trg
  after insert or update of status on public.order_returns
  for each row execute function public._c712_return_trg();

-- ═══════════════════════ 10 · partial delivery ═══════════════════════
-- delivery_partial_lines() already writes the delivery_events row; this reads
-- the counts off the order rather than parsing that row's sentence.

create or replace function public._c712_delivery_partial_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_delivered numeric; v_returned numeric;
begin
  if coalesce(new.event,'') <> 'partial' or new.order_id is null then return null; end if;

  select coalesce(d.delivered_qty,0), coalesce(d.returned_qty,0)
    into v_delivered, v_returned
    from public.deliveries d where d.id = new.delivery_id;

  perform public._c712_emit(new.order_id, 'delivery_partial',
    jsonb_build_object('delivered_count', trim_scale(coalesce(v_delivered,0))::text,
                       'follows_count',   trim_scale(coalesce(v_returned,0))::text),
    new.delivery_id::text);
  return null;
end $fn$;

drop trigger if exists _c712_delivery_partial_trg on public.delivery_events;
create trigger _c712_delivery_partial_trg
  after insert on public.delivery_events
  for each row execute function public._c712_delivery_partial_trg();

-- ═══════════════════════ 7b · sourcing, corrected ═══════════════════════
-- Two facts about this schema drove the rewrite, and both were found by
-- running it rather than reading it:
--
--   1. order_items.inquiry_id is set by inquiry_broadcast_to_oi() only once a
--      line is CONFIRMED. At "we have started sourcing" the link does not
--      exist yet, so a state built from inquiry_id alone counts one confirmed
--      line as the whole order and declares sourcing finished on the first
--      answer. The order's OWN lines are the denominator; the inquiry is
--      matched to them the way the broadcast matches them (product + date),
--      with the explicit link winning when it exists.
--   2. zzz_c643_suppress_noop cancels an UPDATE that changes nothing, and
--      `AFTER UPDATE OF current_status` fires on the COLUMN LIST of the
--      statement, not on the value: the engine writes AS3 and a BEFORE trigger
--      recomputes current_status, so a column-scoped trigger never sees it.
--      Hence: fire on any INSERT/UPDATE, and return immediately when the
--      status did not actually move.

create index if not exists order_items_product_date_idx
  on public.order_items (product_id, order_date)
  where fulfillment_state is distinct from 'cancelled';

create or replace function public._c712_sourcing_state(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'total',     count(*),
    'confirmed', count(*) filter (where i.current_status = 'Available'),
    'pending',   count(*) filter (where coalesce(i.current_status,'')
                                        not in ('Available','No Supplier Available')),
    'unfound',   count(*) filter (where i.current_status = 'No Supplier Available'),
    'unfulfilled_names',
      coalesce(string_agg(distinct oi.product_name, ', ')
               filter (where i.current_status = 'No Supplier Available'), ''))
    from public.order_items oi
    left join lateral (
      select i2.current_status
        from public.inquiry i2
       where i2.id = oi.inquiry_id
          or (oi.inquiry_id is null and i2.product_id = oi.product_id
              and i2.batch_date = oi.order_date)
       order by (i2.id = oi.inquiry_id) desc nulls last, i2.id desc
       limit 1) i on true
   where oi.order_id = p_order_id
     and coalesce(oi.fulfillment_state,'') <> 'cancelled';
$fn$;

create or replace function public._c712_inquiry_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_order uuid; s jsonb; v_bucket text;
begin
  -- Nothing about the waterfall moved -> nothing to say. (An INSERT always
  -- counts: that IS the waterfall starting.)
  if tg_op = 'UPDATE'
     and new.current_status is not distinct from old.current_status then
    return null;
  end if;

  for v_order in
    select distinct oi.order_id
      from public.order_items oi
     where coalesce(oi.fulfillment_state,'') <> 'cancelled'
       and (oi.inquiry_id = new.id
            or (oi.product_id = new.product_id and oi.order_date = new.batch_date))
  loop
    s := public._c712_sourcing_state(v_order);
    if coalesce((s->>'total')::int,0) = 0 then continue; end if;

    -- 1 · the waterfall has begun. Once per order, whichever line asks first.
    perform public._c712_emit(v_order, 'sourcing_started',
      jsonb_build_object('count', (s->>'total'),
                         'sourcing_window', public._c712_window(v_order)),
      'order');

    -- 2 · everything is settled -> the final list, with the misses named.
    if (s->>'pending')::int = 0 then
      perform public._c712_emit(v_order, 'sourcing_done',
        jsonb_build_object('confirmed_count', (s->>'confirmed'),
                           'unfulfilled_names',
                           coalesce(nullif(s->>'unfulfilled_names',''),
                                    public.uic('c712.unfulfilled_none','nothing — every item was found'))),
        'order');
      continue;
    end if;

    -- 3 · progress, at most one message every four hours. The bucket IS the
    --     throttle: a second confirmation inside the same window loses the
    --     insert and never reaches the wire.
    if (s->>'confirmed')::int > 0 then
      v_bucket := to_char(date_trunc('hour', now() at time zone 'Asia/Kolkata')
                          - make_interval(hours => (extract(hour from now() at time zone 'Asia/Kolkata')::int % 4)),
                          'YYYYMMDD-HH24');
      perform public._c712_emit(v_order, 'sourcing_update',
        jsonb_build_object('confirmed_count', (s->>'confirmed'),
                           'pending_count',   (s->>'pending')),
        v_bucket);
    end if;
  end loop;
  return null;
end $fn$;

drop trigger if exists _c712_inquiry_trg on public.inquiry;
create trigger _c712_inquiry_trg
  after insert or update on public.inquiry
  for each row execute function public._c712_inquiry_trg();

-- ═══════════════════════ 9b · refunds, corrected ═══════════════════════
-- refunds.method is a CODE ('razorpay' | 'manual_upi') and refunds.status is a
-- five-value enum whose finished state is 'processed'. A customer must never be
-- shown the code, so the mode is a ui_copy lookup with the code as its own
-- fallback: a method added tomorrow reads as itself until someone words it,
-- which is an UPDATE and not a deploy.

insert into public.ui_copy (key, value) values
  ('c712.mode_razorpay',   to_jsonb('online refund'::text)),
  ('c712.mode_manual_upi', to_jsonb('UPI transfer'::text))
on conflict (key) do nothing;

create or replace function public._c712_refund_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_mode text; v_ref text;
begin
  v_mode := public.uic('c712.mode_'||coalesce(nullif(btrim(new.method),''),'unknown'),
                       coalesce(nullif(btrim(new.method),''), ''));

  if tg_op = 'INSERT' then
    perform public._c712_emit(new.order_id, 'refund_initiated',
      jsonb_build_object('amount', public.inr_money(coalesce(new.amount,0)),
                         'payment_mode', v_mode),
      new.id::text);
    return null;
  end if;

  if coalesce(new.status,'') is distinct from coalesce(old.status,'')
     and new.status = 'processed' then
    v_ref := coalesce(nullif(btrim(new.utr),''), nullif(btrim(new.provider_refund_id),''),
                      public.uic('c712.ref_pending','reference to follow'));
    perform public._c712_emit(new.order_id, 'refund_done',
      jsonb_build_object('amount', public.inr_money(coalesce(new.amount,0)),
                         'payment_mode', v_mode, 'refund_ref', v_ref),
      new.id::text);
  end if;
  return null;
end $fn$;

-- ═══════════════════════ 12 · the timeline (spec item 3) ═══════════════════
-- A stage of its own so it sorts after the flow and never becomes the step the
-- order is "waiting on": is_flow false, like closed / message / action.

insert into public.order_timeline_stage (stage_key, sort_order, is_active, is_flow)
values ('told', 97, true, false)
on conflict (stage_key) do nothing;

CREATE OR REPLACE FUNCTION public._order_timeline_events(p_order_id uuid, p_access text, p_can_act boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o        public.orders%rowtype;
  v_raw    jsonb := '[]'::jsonb;
  v_out    jsonb := '[]'::jsonb;
  r        record;
  v_cust   text; v_cust_phone text;
  v_n      int;  v_amt text; v_ts timestamptz;
  v_open   boolean;
  v_flow_stage text;
  v_due    numeric;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then return '[]'::jsonb; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(o.pharmacy_name),''), ''),
         coalesce(nullif(btrim(pp.whatsapp_no),''), nullif(btrim(pp.phone),''), nullif(btrim(o.phone),''), '')
    into v_cust, v_cust_phone
    from public.orders o2 left join public.pharmacy_profiles pp on pp.id = o2.customer_id
   where o2.id = p_order_id;
  v_cust := coalesce(v_cust,''); v_cust_phone := coalesce(v_cust_phone,'');

  -- ── 1. placed ─────────────────────────────────────────────────────────────
  select count(*)::int into v_n from public.order_items where order_id = p_order_id;
  v_amt := public.inr_money(coalesce(o.total_amount, 0));
  v_raw := v_raw || jsonb_build_array(jsonb_build_object(
    'ts', o.created_at, 'stage','placed','hint',0,'internal',false,
    'label',  public._otl_fill('order_timeline.ev_placed','Order placed'),
    'detail', public._otl_fill('order_timeline.ev_placed_detail','{n} items · {amount}',
                jsonb_build_object('n', v_n::text, 'amount', v_amt)),
    'tone','neutral',
    'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
    'action_kind','call_customer','action_args','{}'::jsonb));

  -- ── 2. inquiry: asked / answered / advanced / nobody had it ───────────────
  for r in
    select i.current_supplier as sup,
           min(coalesce(i.asked_at, i.created_at)) as ts, count(*)::int as n
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id
       and coalesce(btrim(i.current_supplier),'') <> ''
     group by i.current_supplier
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',1,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_inq_asked','Asked {supplier}',
                  jsonb_build_object('supplier', r.sup)),
      'detail', public._otl_fill('order_timeline.ev_inq_asked_detail','{n} items on the inquiry',
                  jsonb_build_object('n', r.n::text)),
      'tone','neutral',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','nudge_supplier','action_args', jsonb_build_object('supplier_name', r.sup)));
  end loop;

  for r in
    -- "Answered" is the backend's own word for it: inquiry.response is the
    -- reply text the waterfall recorded. The per-form booleans are the FORM's
    -- toggles and are false on a row answered over WhatsApp.
    select i.responsed_by as sup, max(coalesce(i.asked_at, i.created_at)) as ts,
           count(*)::int as n, max(i.response) as reply
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id
       and coalesce(btrim(i.responsed_by),'') <> ''
       and coalesce(btrim(i.response),'') <> ''
       -- responsed_by also carries the engine's own "nobody answered" sentence.
       -- An actor you cannot name is not an actor, so only a real supplier
       -- becomes an "answered" event.
       and exists (select 1 from public.supplier_profiles sp
                    where sp.supplier_name = i.responsed_by)
     group by i.responsed_by
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',2,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_inq_answered','{supplier} answered',
                  jsonb_build_object('supplier', r.sup)),
      'detail', public._otl_fill('order_timeline.ev_inq_answered_detail','{n} items answered',
                  jsonb_build_object('n', r.n::text)) || ' · ' || coalesce(r.reply,''),
      'tone','green',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  for r in
    select i.next_supplier as sup, max(coalesce(i.asked_at, i.created_at)) as ts
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id and coalesce(btrim(i.next_supplier),'') <> ''
     group by i.next_supplier
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',3,'internal',true,
      'label', public._otl_fill('order_timeline.ev_inq_advanced','Moved on to {supplier}',
                 jsonb_build_object('supplier', r.sup)),
      'detail','','tone','amber',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  select count(*)::int, max(unfulfillable_at) into v_n, v_ts
    from public.order_items where order_id = p_order_id and coalesce(unfulfillable,false);
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','inquiry','hint',4,'internal',false,
      'label', public._otl_fill('order_timeline.ev_unfulfillable','{n} items nobody could supply',
                 jsonb_build_object('n', v_n::text)),
      'detail','','tone','red',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 3. supplier orders ────────────────────────────────────────────────────
  for r in
    select so.supplier_name as sup, so.created_at, so.accepted_at, so.packed_at,
           so.settled_at, so.accept_state, coalesce(so.decline_reason,'') as decline_reason,
           coalesce(nullif(btrim(sp.whatsapp_no),''), nullif(btrim(sp.phone),''), '') as phone
      from public.supplier_orders so
      left join public.supplier_profiles sp on sp.id = so.supplier_id
     where so.order_id = p_order_id
  loop
    if r.created_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.created_at, 'stage','sourcing','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_so_sent','Supplier order sent to {supplier}',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','neutral',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','nudge_supplier','action_args', jsonb_build_object('supplier_name', r.sup)));
    end if;
    if r.accepted_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.accepted_at, 'stage','sourcing','hint',2,'internal',false,
        'label', public._otl_fill(
                   case when coalesce(r.accept_state,'') = 'declined'
                        then 'order_timeline.ev_so_declined' else 'order_timeline.ev_so_accepted' end,
                   '{supplier} accepted', jsonb_build_object('supplier', r.sup)),
        'detail', r.decline_reason,
        'tone', case when coalesce(r.accept_state,'') = 'declined' then 'red' else 'green' end,
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.packed_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.packed_at, 'stage','sourcing','hint',3,'internal',false,
        'label', public._otl_fill('order_timeline.ev_so_packed','{supplier} packed the order',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','green',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.settled_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.settled_at, 'stage','sourcing','hint',4,'internal',true,
        'label', public._otl_fill('order_timeline.ev_so_settled','Settled with {supplier}',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','green',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 4. receiving + bagging (warehouse: internal) ──────────────────────────
  select count(*)::int, min(created_at) into v_n, v_ts
    from public.receiving_log where order_id = p_order_id;
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','receiving','hint',1,'internal',true,
      'label', public._otl_fill('order_timeline.ev_received','Received at the warehouse'),
      'detail', public._otl_fill('order_timeline.ev_received_detail','{n} entries',
                  jsonb_build_object('n', v_n::text)),
      'tone','neutral',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  select count(distinct bag_no)::int, min(created_at) into v_n, v_ts
    from public.bag_allocations where order_id = p_order_id;
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','receiving','hint',2,'internal',true,
      'label', public._otl_fill('order_timeline.ev_bagged','Bags allocated'),
      'detail', public._otl_fill('order_timeline.ev_bagged_detail','{n} bags',
                  jsonb_build_object('n', v_n::text)),
      'tone','neutral',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 5. pack + dispatch-ready ──────────────────────────────────────────────
  select count(*)::int, max(packed_at) into v_n, v_ts
    from public.order_items where order_id = p_order_id and coalesce(packed,false);
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','pack','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_packed','Packed'),
      'detail', public._otl_fill('order_timeline.ev_packed_detail','{n} items packed',
                  jsonb_build_object('n', v_n::text)),
      'tone','green',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;
  if o.dispatch_ready_at is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', o.dispatch_ready_at, 'stage','pack','hint',2,'internal',false,
      'label', public._otl_fill('order_timeline.ev_dispatch_ready','Ready to dispatch'),
      'detail','','tone','green',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 6. delivery: the milestones on the row, then the event log ────────────
  for r in
    select d.id, d.assigned_at, d.accepted_at, d.started_at, d.arrived_at,
           d.delivered_at, coalesce(d.fail_reason,'') as fail_reason,
           coalesce(nullif(btrim(dp.full_name),''),'') as rider,
           coalesce(nullif(btrim(dp.phone),''),'')     as phone
      from public.deliveries d
      left join public.delivery_partner_registrations dp on dp.id = d.partner_id
     where d.order_id = p_order_id
     order by d.created_at
  loop
    if r.assigned_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.assigned_at, 'stage','dispatch','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_assigned','Assigned to {rider}',
                   jsonb_build_object('rider', r.rider)),
        'detail','','tone','neutral',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','reassign','action_args', jsonb_build_object('delivery_id', r.id::text)));
    end if;
    if r.accepted_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.accepted_at, 'stage','dispatch','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_accepted','{rider} accepted the run',
                   jsonb_build_object('rider', r.rider)),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.started_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.started_at, 'stage','delivery','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_started','Out for delivery'),
        'detail','','tone','neutral',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','call_rider','action_args','{}'::jsonb));
    end if;
    if r.arrived_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.arrived_at, 'stage','delivery','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_arrived','Rider arrived'),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','call_rider','action_args','{}'::jsonb));
    end if;
    if r.delivered_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.delivered_at, 'stage','delivery','hint',3,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_delivered','Delivered'),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    elsif r.fail_reason <> '' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.arrived_at, r.started_at, r.assigned_at), 'stage','delivery','hint',4,
        'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_failed','Delivery attempt failed'),
        'detail', r.fail_reason,'tone','red',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','reassign','action_args', jsonb_build_object('delivery_id', r.id::text)));
    end if;
  end loop;

  -- delivery_events: an event this build has no sentence for is SKIPPED, never
  -- rendered as its raw key. A new event type is one ui_copy INSERT.
  for r in
    select de.event, de.created_at, coalesce(de.note,'') as note,
           coalesce(nullif(btrim(dp.full_name),''),'') as rider,
           coalesce(nullif(btrim(dp.phone),''),'')     as phone
      from public.delivery_events de
      left join public.delivery_partner_registrations dp on dp.id = de.partner_id
     where de.order_id = p_order_id
       and public.uic('order_timeline.dlv_'||de.event, '') <> ''
     order by de.created_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','delivery','hint',5,'internal',false,
      'label', public.uic('order_timeline.dlv_'||r.event, ''),
      'detail', r.note,'tone','neutral',
      'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 7. payments ───────────────────────────────────────────────────────────
  for r in
    select pc.created_at, pc.received_at, pc.status, coalesce(pc.verify_reason,'') as reason,
           coalesce(pc.amount,0) as amount
      from public.payment_claims pc
     where pc.order_id = p_order_id
     order by pc.created_at
     limit 30
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', coalesce(r.created_at, r.received_at), 'stage','payment','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_pay_claim','Payment claim received'),
      'detail', public.inr_money(r.amount),'tone','neutral',
      'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
      'action_kind','','action_args','{}'::jsonb));
    if r.status = 'verified' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.received_at, r.created_at), 'stage','payment','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_pay_verified','Payment verified'),
        'detail', public.inr_money(r.amount),'tone','green',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','','action_args','{}'::jsonb));
    elsif r.status = 'rejected' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.received_at, r.created_at), 'stage','payment','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_pay_rejected','Payment claim rejected'),
        'detail', r.reason,'tone','red',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','chase_payment','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 8. WhatsApp attempts, GROUPED (ops chatter: internal only) ──────────
  -- One row per (event_key, outcome) at the LAST attempt, with the count. The
  -- raw log is a retry loop: listing it drew 25 identical red rows on
  -- CPO010926TESTCUST1O1 and buried the order underneath them.
  for r in
    select wa.event_key, coalesce(wa.ok,false) as ok, count(*)::int as n,
           max(wa.created_at) as ts,
           max(coalesce(wa.reason,'')) as reason
      from public.wa_send_attempts wa
     where wa.order_id = p_order_id
     group by wa.event_key, coalesce(wa.ok,false)
     order by max(wa.created_at) desc
     limit 12
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','message','hint',1,'internal',true,
      'label', public._otl_fill(case when r.ok then 'order_timeline.ev_wa_ok'
                                     else 'order_timeline.ev_wa_failed' end,
                                'WhatsApp sent'),
      'detail', public._otl_fill(case when r.ok then 'order_timeline.ev_wa_ok_detail'
                                      else 'order_timeline.ev_wa_failed_detail' end,
                                 '{key}',
                                 jsonb_build_object('key', r.event_key,
                                                    'n', r.n::text,
                                                    'reason', r.reason)),
      'tone', case when r.ok then 'neutral' else 'red' end,
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 9. closure ────────────────────────────────────────────────────────────
  if o.closed_at is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', o.closed_at, 'stage','closed','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_closed','Order closed'),
      'detail', coalesce(o.closed_reason,''),'tone','green',
      'actor_kind','medibo','actor_name',coalesce(o.closed_by,''),'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  elsif coalesce(o.status,'') = 'cancelled' or coalesce(o.fulfillment_status,'') = 'cancelled' then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', coalesce(o.shipped_at, o.created_at), 'stage','closed','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_cancelled','Order cancelled'),
      'detail','','tone','red',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 10. the actions that were taken FROM this timeline ────────────────────
  for r in
    select al.created_at, al.action_kind, al.actor_kind, al.actor_name,
           al.ok, coalesce(al.note,'') as note
      from public.order_timeline_action_log al
     where al.order_id = p_order_id
     order by al.created_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','action','hint',1,'internal',true,
      'label', public._otl_fill('order_timeline.ev_act_done','{who} used {action}',
                 jsonb_build_object(
                   'who',    coalesce(nullif(r.actor_name,''), public.uic('order_timeline.actor_medibo','mediBO')),
                   'action', public.uic('order_timeline.act_'||r.action_kind, r.action_kind))),
      'detail', r.note, 'tone', case when r.ok then 'neutral' else 'red' end,
      'actor_kind', r.actor_kind,'actor_name', r.actor_name,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 11. what we actually TOLD the customer (CHANGE #712) ──────────────────
  --    Section 8 above is the ops view of the same wire: every WhatsApp
  --    ATTEMPT, grouped, internal:true. This is the other half — the events the
  --    customer was sent on purpose, worded for the customer, internal:false.
  --    It reads order_customer_event, so an event added tomorrow appears here
  --    with no change to this function: the label and the detail are ui_copy
  --    keys derived from the event key, and the vars are the message's own.
  for r in
    select ce.sent_at, ce.event_key, ce.vars
      from public.order_customer_event ce
     where ce.order_id = p_order_id
     order by ce.sent_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.sent_at, 'stage','told','hint',1,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_c712_'||r.event_key,
                  public.uic('order_timeline.ev_c712','We told you')),
      'detail', public._otl_fill('order_timeline.ev_c712_'||r.event_key||'_detail', '', r.vars),
      'tone','neutral',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- The furthest FLOW stage this order has reached is the one it is waiting on.
  select b.stage into v_flow_stage
    from (select v->>'stage' as stage from jsonb_array_elements(v_raw) t(v)
           where nullif(v->>'ts','') is not null
             and (p_access = 'full' or coalesce((v->>'internal')::boolean,false) = false)) b
    join public.order_timeline_stage ots on ots.stage_key = b.stage and ots.is_active and ots.is_flow
   order by ots.sort_order desc limit 1;

  -- ── assemble: filter, order, word, tone, and hang the action on the step ──
  --
  -- "Late" is not "the newest event is old": a WhatsApp attempt at 14:02 must
  -- not make an inquiry that has been silent since 05:00 look attended to. So
  -- lateness belongs to the furthest FLOW stage the order has reached, and
  -- only while the order is still open.
  v_open := (o.closed_at is null
             and coalesce(o.status,'') <> 'cancelled'
             and coalesce(o.fulfillment_status,'') <> 'cancelled'
             and not exists (select 1 from public.deliveries d
                              where d.order_id = p_order_id and d.delivered_at is not null));

  select coalesce(jsonb_agg(x.ev order by x.ts, x.hint, x.ord), '[]'::jsonb)
    into v_out
  from (
    select e.ts, e.hint, e.ord,
           jsonb_build_object(
             'ts',        e.ts,
             'ts_label',  public.ist_fmt(e.ts, 'dmy2_time12'),
             'age_label', public.ops_age_label(e.ts),
             'stage',     e.stage,
             'label',     e.label,
             'detail',    e.detail,
             'has_detail',(coalesce(e.detail,'') <> ''),
             'tone',      case when e.is_late  then 'red'
                               when e.is_amber then 'amber'
                               else e.tone end,
             'late',      e.is_late,
             'late_label',case when e.is_late
                               then public.uic('order_timeline.late_label','Late') else '' end,
             'is_current',e.is_waiting_on,
             'actor',     public._otl_actor(e.actor_kind, e.actor_name, e.actor_phone, p_access),
             'action',    case when p_can_act and p_access = 'full' and e.is_action_last
                               then public._otl_action(e.action_kind, p_order_id, e.action_args,
                                      case when e.is_late then 'red' else 'neutral' end)
                               else jsonb_build_object('has', false) end) as ev
      from (
        select b.*,
               (b.is_stage_last and b.stage = v_flow_stage and v_open
                and b.late_after_min is not null and b.age_min >= b.late_after_min)  as is_late,
               (b.is_stage_last and b.stage = v_flow_stage and v_open
                and b.amber_after_min is not null and b.age_min >= b.amber_after_min) as is_amber,
               (b.is_stage_last and b.stage = v_flow_stage and v_open)                as is_waiting_on
          from (
            select (v->>'ts')::timestamptz as ts,
                   (v->>'hint')::int       as hint,
                   row_number() over ()    as ord,
                   v->>'stage'  as stage, v->>'label' as label, v->>'detail' as detail,
                   v->>'tone'   as tone,
                   v->>'actor_kind' as actor_kind, v->>'actor_name' as actor_name,
                   v->>'actor_phone' as actor_phone,
                   v->>'action_kind' as action_kind, v->'action_args' as action_args,
                   floor(extract(epoch from (now() - (v->>'ts')::timestamptz))/60)::int as age_min,
                   ots.late_after_min, ots.amber_after_min,
                   row_number() over (partition by v->>'stage'
                                      order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1
                     as is_stage_last,
                   (coalesce(v->>'action_kind','') <> ''
                    and row_number() over (partition by v->>'stage', v->>'action_kind'
                                           order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1)
                     as is_action_last
              from jsonb_array_elements(v_raw) t(v)
              left join public.order_timeline_stage ots
                     on ots.stage_key = v->>'stage' and ots.is_active
             where nullif(v->>'ts','') is not null
               and (p_access = 'full' or coalesce((v->>'internal')::boolean, false) = false)
          ) b
      ) e
  ) x;

  return v_out;
end $function$

;

-- ═══════════════════════ 11 · the proof ═══════════════════════
-- Spec item 5: every event fires EXACTLY once. The ledger's unique key is the
-- mechanism; this is the test that the mechanism is wired to all four sources.
-- It fires each state change TWICE and asserts one row each.

insert into public.rg_behavior_tests(name, body) values (
  'c712_customer_events_fire_once',
$body$
do $x$
declare
  v_super uuid; v_order uuid; v_item uuid; v_inq bigint; v_ret uuid; v_ref uuid;
  v_del uuid; n int; v_s jsonb; v_pid bigint;
begin
  select u.id into v_super from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  if v_super is null then raise exception 'RG_ROLLBACK'; end if;
  perform set_config('request.jwt.claims',
    (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
       from auth.users u where u.id = v_super), true);

  -- A fixture of its own, so the proof never depends on whichever real order
  -- happened to be newest — and so nothing this test does can touch one.
  -- The batch date is far future on purpose: inquiry is UNIQUE on
  -- (product_id, batch_date, zone_id), and the ask below has to be an INSERT.
  insert into public.orders (pharmacy_name, phone, status, order_code, order_date, is_synthetic, placed_by_admin)
  values ('c712 probe pharmacy', '9999900001', 'accepted', 'C712PROBE', date '2031-01-01', true, true)
  returning id into v_order;

  select m.id into v_pid from public."MEDICINE" m order by m.id limit 1;

  insert into public.order_items (order_id, product_id, product_name, quantity, order_date, is_synthetic)
  values (v_order, v_pid, 'c712 probe item', 3, date '2031-01-01', true)
  returning id into v_item;

  -- 1 · SOURCING. The waterfall starts: the ask is an inquiry row carrying the
  --     same product and date the order line carries — the exact join
  --     inquiry_broadcast_to_oi() uses before order_items.inquiry_id exists.
  insert into public.inquiry (product_name, product_id, quantity, batch_date, is_synthetic)
  values ('c712 probe item', v_pid, 3, date '2031-01-01', true) returning id into v_inq;
  -- ...and a second ask on the same order must not repeat the message.
  update public.inquiry set quantity = 4 where id = v_inq;

  select count(*) into n from public.order_customer_event
   where order_id = v_order and event_key = 'sourcing_started';
  if n <> 1 then raise exception 'sourcing_started fired % times, expected 1', n; end if;

  -- the message names the whole order, not the one line that was asked
  if (select vars->>'count' from public.order_customer_event
       where order_id = v_order and event_key = 'sourcing_started') <> '1' then
    raise exception 'sourcing_started counted the wrong number of lines: %',
      (select vars from public.order_customer_event
        where order_id = v_order and event_key = 'sourcing_started');
  end if;

  -- 2 · RETURNS. Raise, then approve twice.
  insert into public.order_returns (order_id, order_item_id, product_name, qty, status, credit_total)
  values (v_order, v_item, 'c712 probe', 2, 'pending', 1240) returning id into v_ret;
  update public.order_returns set status = 'approved' where id = v_ret;
  update public.order_returns set status = 'approved' where id = v_ret;
  select count(*) into n from public.order_customer_event
   where order_id = v_order and event_key in ('return_requested_ack','return_approved');
  if n <> 2 then raise exception 'return events fired % times, expected 2 (ack + approved)', n; end if;

  -- 3 · REFUNDS. Request, then process twice.
  insert into public.refunds (order_id, amount, method, status)
  values (v_order, 1240, 'manual_upi', 'pending') returning id into v_ref;
  update public.refunds set status = 'processed', utr = 'rfnd_c712probe' where id = v_ref;
  update public.refunds set status = 'processed', utr = 'rfnd_c712probe' where id = v_ref;
  select count(*) into n from public.order_customer_event
   where order_id = v_order and event_key in ('refund_initiated','refund_done');
  if n <> 2 then raise exception 'refund events fired % times, expected 2', n; end if;

  -- every message carries the pharmacy's own name and the order code: a
  -- template that renders "Namaste ," is worse than no template.
  select count(*) into n from public.order_customer_event
   where order_id = v_order and coalesce(vars->>'order_code','') = '';
  if n > 0 then raise exception '% event(s) carried no order_code', n; end if;

  -- 4 · PARTIAL DELIVERY. The event row the rider's handover writes, twice.
  insert into public.deliveries (order_id, status, delivered_qty, returned_qty, is_synthetic)
  values (v_order, 'delivered', 2, 1, true) returning id into v_del;
  if v_del is not null then
    insert into public.delivery_events (delivery_id, order_id, event, note)
    values (v_del, v_order, 'partial', 'c712 probe');
    insert into public.delivery_events (delivery_id, order_id, event, note)
    values (v_del, v_order, 'partial', 'c712 probe again');
    select count(*) into n from public.order_customer_event
     where order_id = v_order and event_key = 'delivery_partial';
    if n <> 1 then raise exception 'delivery_partial fired % times, expected 1', n; end if;
    if (select vars->>'delivered_count'||'/'||(vars->>'follows_count')
          from public.order_customer_event
         where order_id = v_order and event_key = 'delivery_partial') <> '2/1' then
      raise exception 'the partial-delivery message carried the wrong counts: %',
        (select vars from public.order_customer_event
          where order_id = v_order and event_key = 'delivery_partial');
    end if;
  end if;

  -- and the timeline shows them to the CUSTOMER (not internal:true chatter).
  v_s := public._order_timeline_events(v_order, 'customer', false);
  if not exists (select 1 from jsonb_array_elements(v_s) e
                  where e->>'stage' = 'told') then
    raise exception 'the customer timeline carries no c712 event: %',
      (select jsonb_agg(distinct e->>'stage') from jsonb_array_elements(v_s) e);
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$body$)
on conflict (name) do update set body = excluded.body;

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

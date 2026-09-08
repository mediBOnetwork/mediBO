-- CHANGE #294 (part B) — the routes, templates and schedule the template-first
-- dispatcher needs. Idempotent: every insert is guarded, every update is by key.

-- ── 1. Admin alert: a failed customer-facing send must raise something ───────
insert into wa_templates(name, language, category, status, components, token_map)
select 'wa_send_failed', 'en', 'UTILITY', 'DRAFT',
  jsonb_build_array(
    jsonb_build_object('type','BODY',
      'text','mediBO alert: the message "{{1}}" to {{2}} did not reach the customer. Reason: {{3}}. Open WhatsApp Ops to resend it.',
      'example', jsonb_build_object('body_text',
        jsonb_build_array(jsonb_build_array('Order placed','+91 8357881873','Re-engagement message')))),
    jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
  '["failed_message","failed_to","failed_reason"]'::jsonb
where not exists (select 1 from wa_templates where name='wa_send_failed' and language='en');

insert into wa_event_routes(event_key, label, description, template_id, template_name, language,
       variable_map, enabled, bypass_send_window, auto_template_name, auto_manage,
       legacy_routed_to, dedupe_minutes, marketing_guard, audience)
select 'wa_send_failed', 'Message did not reach a customer',
       'Raised when a customer-facing WhatsApp send fails — including an out-of-window free-form message.',
       t.id, t.name, t.language,
       '["{{failed_message}}","{{failed_to}}","{{failed_reason}}"]'::jsonb,
       true, true, 'wa_send_failed', false, '{}', 15, true, 'admin'
from wa_templates t where t.name='wa_send_failed' and t.language='en'
  and not exists (select 1 from wa_event_routes where event_key='wa_send_failed');

-- ── 2. Payment QR as a template, with the QR on the header ──────────────────
insert into wa_templates(name, language, category, status, components, token_map,
       header_format, header_media_path, header_media_mime)
select 'payment_qr', 'en', 'UTILITY', 'DRAFT',
  jsonb_build_array(
    jsonb_build_object('type','HEADER','format','IMAGE'),
    jsonb_build_object('type','BODY',
      'text','Hi {{1}}, the payment for order {{2}} is {{3}}. Scan the QR above in any UPI app to pay. Reply here if you need help.',
      'example', jsonb_build_object('body_text',
        jsonb_build_array(jsonb_build_array('Chandra Medicom','CPO230826CHAO1','Rs 1,263.70')))),
    jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
  '["customer_name","order_code","amount"]'::jsonb,
  'IMAGE', 'whatsapp/wa_out_payqr_918357881873_1787281142155.jpg', 'image/jpeg'
where not exists (select 1 from wa_templates where name='payment_qr' and language='en');

insert into wa_event_routes(event_key, label, description, template_id, template_name, language,
       variable_map, enabled, bypass_send_window, auto_template_name, auto_manage,
       legacy_routed_to, dedupe_minutes, marketing_guard, audience, fallback_event_key)
select 'payment_qr', 'Payment QR to customer',
       'The UPI/Razorpay QR we send when an advance or balance is due.',
       t.id, t.name, t.language,
       '["{{customer_name}}","{{order_code}}","{{amount}}"]'::jsonb,
       true, true, 'payment_qr', false,
       array['payment_qr_to_customer'], 30, true, 'customer', 'payment_due'
from wa_templates t where t.name='payment_qr' and t.language='en'
  and not exists (select 1 from wa_event_routes where event_key='payment_qr');

-- Existing route already owned this legacy key? Make sure exactly one does.
update wa_event_routes
   set legacy_routed_to = array_remove(legacy_routed_to, 'payment_qr_to_customer')
 where event_key <> 'payment_qr'
   and 'payment_qr_to_customer' = any(legacy_routed_to);

-- ── 3. Fallbacks so a template in Meta review never means a free-form send ──
update wa_event_routes set fallback_event_key = 'payment_due'
 where event_key = 'payment_qr' and fallback_event_key is null;
update wa_event_routes set fallback_event_key = 'order_placed'
 where event_key = 'order_updated' and fallback_event_key is null;

-- ── 4. The guard sweep — OFFSET schedule, never a bare */N (outage lesson) ──
do $$
begin
  perform cron.unschedule('wa_notify_sweep');
exception when others then null;
end $$;
select cron.schedule('wa_notify_sweep', '7-59/10 * * * *', $$select public.wa_notify_sweep();$$);

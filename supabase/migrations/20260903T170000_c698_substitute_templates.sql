-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #698 (part C) — THE THREE WHATSAPP TEMPLATES, AS DRAFTS
--
-- The routes in part A are the wiring; these are the words. They are written
-- as DRAFTs on purpose: submitting a template publishes it to Meta for review
-- under mediBO's own WABA, and that is an outward-facing action an admin makes
-- from Dev Queue -> WhatsApp Templates, not something a build fires by itself.
-- Until they are approved, notify() logs the attempt and the in-app card still
-- carries the whole offer — the ask is never lost because a template is not
-- through review yet.
--
-- Every body is UTILITY, transactional, and carries no price: the offer is
-- availability only.
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.wa_templates (name, language, category, status, components, token_map)
values
  ('order_substitute_ask', 'en', 'UTILITY', 'DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY',
       'text', 'Namaste {{1}}, {{2}} from order {{3}} is not available right now. '
            || 'Other companies carry the same salt and strength. Open the link and tick the ones '
            || 'you accept — we will try them in that order. It closes in 10 minutes: {{4}}',
       'example', jsonb_build_object('body_text', jsonb_build_array(jsonb_build_array(
         'Chandra Medicom', 'Olmigo 40mg Tablet', 'CPO020826CHAO1',
         'https://medibo.in/substitute-ask/6f1c2b')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   jsonb_build_array('pharmacy_name','product_name','order_code','substitute_link')),

  ('order_substitute_applied', 'en', 'UTILITY', 'DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY',
       'text', 'Namaste {{1}}, {{2}} ({{3}}) will be supplied instead of {{4}} in order {{5}}. '
            || 'It is already part of the same delivery — nothing else for you to do.',
       'example', jsonb_build_object('body_text', jsonb_build_array(jsonb_build_array(
         'Chandra Medicom', 'Olmy 40 Tablet', 'Zydus Cadila',
         'Olmigo 40mg Tablet', 'CPO020826CHAO1')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   jsonb_build_array('pharmacy_name','substitute_name','substitute_company',
                     'product_name','order_code')),

  ('order_substitute_none', 'en', 'UTILITY', 'DRAFT',
   jsonb_build_array(
     jsonb_build_object('type','BODY',
       'text', 'Namaste {{1}}, we could not source {{2}} or an equal substitute for order {{3}}. '
            || 'We are shipping the rest of your order and you will not be billed for this item.',
       'example', jsonb_build_object('body_text', jsonb_build_array(jsonb_build_array(
         'Chandra Medicom', 'Olmigo 40mg Tablet', 'CPO020826CHAO1')))),
     jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
   jsonb_build_array('pharmacy_name','product_name','order_code'))
on conflict (name, language) do nothing;

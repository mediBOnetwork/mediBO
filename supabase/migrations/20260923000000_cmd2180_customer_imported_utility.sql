-- CMD #2180 — customer_imported goes to Meta as UTILITY.
--
-- Meta rejected this template with INCORRECT_CATEGORY: it was sent as MARKETING
-- with a celebration header image, an emoji, a "Download the app" button and the
-- customer's e-mail address in the body — none of which reads as a utility
-- message. This rewrites it as the transactional notice it actually is: two
-- variables, no header, no e-mail, one URL button.
--
-- login_email leaves EVERY var list at the same time — the template's token_map,
-- the route's variable_map and the running event campaign's variable_map — so a
-- send can never ask for a third value the template no longer has.
--
-- Idempotent: the component rewrite is guarded on the old three-variable body,
-- so replaying it after Meta has normalised the approved version changes nothing.

update public.wa_templates
   set components = '[{"type": "BODY", "text": "Hello {{1}}, your mediBO account is ready.\n\nLogin number: {{2}}\n\nSign in at medibo.in with this number to complete your registration and place your first order.", "example": {"body_text": [["Chandra Medicom", "8357881873"]]}}, {"type": "FOOTER", "text": "mediBO — B2B pharmacy supply"}, {"type": "BUTTONS", "buttons": [{"type": "URL", "text": "Open mediBO", "url": "https://www.medibo.in/"}]}]'::jsonb,
       category   = 'UTILITY',
       header_format     = null,
       header_handle     = null,
       header_media_path = null,
       header_media_mime = null,
       header_media_bytes= null,
       header_media_error= null,
       updated_at = now()
 where name = 'customer_imported'
   and language = 'en'
   and components::text like '%Email: {{3}}%';

update public.wa_templates
   set token_map = '["customer_name","login_number"]'::jsonb,
       updated_at = now()
 where name = 'customer_imported'
   and language = 'en'
   and token_map is distinct from '["customer_name","login_number"]'::jsonb;

update public.wa_event_routes
   set variable_map = '["{{customer_name}}","{{login_number}}"]'::jsonb,
       updated_at = now()
 where event_key = 'customer_imported'
   and variable_map is distinct from '["{{customer_name}}","{{login_number}}"]'::jsonb;

update public.wa_campaigns
   set variable_map = '["{{customer_name}}","{{login_number}}"]'::jsonb
 where audience_kind = 'event_route'
   and audience_params->>'event_key' = 'customer_imported'
   and variable_map is distinct from '["{{customer_name}}","{{login_number}}"]'::jsonb;

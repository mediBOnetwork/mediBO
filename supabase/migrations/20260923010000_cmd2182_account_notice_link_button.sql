-- CMD #2182 — the approved customer-import notice gets a mediBO link.
--
-- customer_account_notice is the UTILITY template Meta finally approved (#2180)
-- and wa_event_routes.customer_imported is bound to it, but it carries no link:
-- a customer reads "sign in at medibo.in" and has to type it. Meta freezes an
-- APPROVED template's components in practice (the category refusal 3835031 and
-- three rejections are all on this template's record), so the button is added
-- the way #2180 learned to: a NEW template under a new name, same BODY wording
-- word for word, same UTILITY category, one static URL button and nothing else.
--
-- The route is rebound below, but ONLY once Meta has actually approved the new
-- name — a route may never point at a PENDING or REJECTED template, and it may
-- never point at a MARKETING one.
--
-- Idempotent: the insert is guarded on the name, the rebind on Meta's verdict.

insert into public.wa_templates (name, language, category, components, token_map)
select 'customer_account_notice_v2', 'en', 'UTILITY',
       '[{"type": "BODY", "text": "Hi {{1}}, your mediBO customer account has been activated by our team.\n\nRegistered mobile number: {{2}}\n\nWe will keep you updated here. If any detail is incorrect, reply to this message.", "example": {"body_text": [["Chandra Medicom", "8357881873"]]}}, {"type": "BUTTONS", "buttons": [{"type": "URL", "text": "Open mediBO", "url": "https://www.medibo.in/"}]}]'::jsonb,
       '["customer_name","login_number"]'::jsonb
 where not exists (select 1 from public.wa_templates
                    where name = 'customer_account_notice_v2' and language = 'en');

-- The rebind. enabled and variable_map are asserted, not assumed: the route
-- keeps {{customer_name}} then {{login_number}}, which is exactly the two-
-- variable order both templates carry.
update public.wa_event_routes er
   set template_id        = t.id,
       template_name      = t.name,
       auto_template_name = t.name,
       language           = t.language,
       wa_category        = lower(t.category),
       variable_map       = '["{{customer_name}}","{{login_number}}"]'::jsonb,
       enabled            = true,
       campaign_id        = null,
       updated_at         = now()
  from public.wa_templates t
 where er.event_key = 'customer_imported'
   and t.name = 'customer_account_notice_v2'
   and t.language = 'en'
   and upper(coalesce(t.status,'')) = 'APPROVED'
   and upper(coalesce(t.category,'')) = 'UTILITY'
   and er.template_id is distinct from t.id;

-- campaign_id is cleared with the rebind on purpose: wa_send_event looks an
-- event campaign up by (event_key, template_id) and creates the one for this
-- template on the first send, re-linking the route itself. The old campaign is
-- left alone so its recipient history stays attached to the template that
-- actually sent those messages.

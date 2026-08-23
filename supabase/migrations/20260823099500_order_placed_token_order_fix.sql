-- CHANGE — #297 part 1: the visible half of the order_placed bug.
--
-- The APPROVED template body is:
--   "Hi {{1}}, we have received your order {{2}}. ..."
-- and its token_map was ["order_code","today_date"], so every customer who
-- placed an order was greeted by their own order number:
--   "Hi CPO230826CHAO1, we have received your order 2026-08-23."
-- (Verified against wa_campaign_recipients rows sent on 2026-08-23.)
--
-- The template text is approved by Meta and must not change; the MAP is what
-- was wrong. {{1}} is a greeting name and {{2}} is the order code, so the map
-- becomes ["customer_name","order_code"] on both the template and the route
-- that reads it. wa_token_value resolves customer_name via the computed
-- customer_name_best source, which is why no new token had to be invented.
--
-- A scan of every non-hidden template found this to be the ONLY route whose
-- greeting placeholder was fed a non-name token, and the only arity mismatch
-- left is login_authentication_number, whose value is supplied by the
-- login-otp function rather than by the token map.
update public.wa_templates
   set token_map = '["customer_name","order_code"]'::jsonb,
       updated_at = now()
 where name = 'order_placed'
   and token_map = '["order_code","today_date"]'::jsonb;

update public.wa_event_routes
   set variable_map = '["{{customer_name}}","{{order_code}}"]'::jsonb,
       updated_at = now()
 where event_key = 'order_placed'
   and variable_map = '["{{order_code}}","{{today_date}}"]'::jsonb;

-- CMD #2180 — the route always names the template it is actually bound to.
--
-- customer_imported could not be re-categorised at Meta (subcode 3835031) and
-- this token may not delete it, so the UTILITY template had to be created under
-- a new name on the SAME wa_templates row. wa_event_routes keeps a copy of the
-- template's name in template_name and auto_template_name — the second is what
-- _wa_route_autoenable matches on when Meta approves — so a rename on the row
-- silently breaks the auto-enable that switches the route on.
--
-- Idempotent by construction: it copies the bound row's own name, so replaying
-- it after any later rename keeps the two in step instead of pinning one value.

update public.wa_event_routes er
   set template_name      = t.name,
       auto_template_name = t.name,
       language           = t.language,
       updated_at         = now()
  from public.wa_templates t
 where t.id = er.template_id
   and er.event_key = 'customer_imported'
   and (er.template_name is distinct from t.name
        or er.auto_template_name is distinct from t.name
        or er.language is distinct from t.language);

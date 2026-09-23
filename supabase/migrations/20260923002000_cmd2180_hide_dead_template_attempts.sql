-- CMD #2180 — the dead attempts leave the Templates screen.
--
-- Getting customer_imported approved as UTILITY took six submissions. Meta will
-- not let this token delete a template, so every rejected attempt is permanent
-- at Meta and permanent in wa_templates — which put nine red "Rejected by Meta"
-- rows at the top of the admin screen for a template that is now approved and
-- live. hidden_at is the row's own answer to that: wa_templates_screen reads
-- `where hidden_at is null`, so hiding a row takes it off the screen without
-- pretending at Meta that it never existed.
--
-- Only rows that are REJECTED and bound to no route are hidden. The approved
-- MARKETING variants stay visible — they exist at Meta and are usable copy —
-- and the live template is never touched.

update public.wa_templates t
   set hidden_at = now(),
       updated_at = now()
 where t.name in ('customer_imported','customer_imported_v2',
                  'customer_imported_v3','customer_imported_v4')
   and upper(coalesce(t.status,'')) = 'REJECTED'
   and t.hidden_at is null
   and not exists (select 1 from public.wa_event_routes r where r.template_id = t.id);

-- The category probe that proved the account could still get a UTILITY approval
-- at all (order-style wording, approved) has done its job and belongs to nobody.
update public.wa_templates t
   set hidden_at = now(),
       updated_at = now()
 where t.name = 'zz_cat_probe_2180'
   and t.hidden_at is null
   and not exists (select 1 from public.wa_event_routes r where r.template_id = t.id);

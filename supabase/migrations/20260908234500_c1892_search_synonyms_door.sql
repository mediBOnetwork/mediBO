-- CMD #1892 — the one door the new home screen could not give a home to.
--
-- nav_parity_report() walks every pre-#1016 door and asks which home tab it
-- lands on now. 129 of 130 resolve. The 130th, admin.search_synonyms, resolves
-- to nothing: the row is is_active=false with no merged_into, so it is neither
-- a tile nor a thing that became another tile — it is simply gone, while
-- lib/screens/admin/search_synonyms_screen.dart and the 'search_synonyms'
-- route in shell_extra_routes.dart are both still there, wired and reachable
-- by URL alone.
--
-- Nothing retired it on purpose. CHANGE #790 shipped the row with
-- is_active = true; CHANGE #1016 placed it in more_catalogue next to its five
-- siblings (Add medicine, Catalogue health, Product pricing, Trade price
-- coverage, Discount slabs) — every one of which is active. No migration ever
-- turns it off. It was switched off in data and left orphaned, and the c1016
-- staff-IA journey has been carrying that one failure ever since.
--
-- A home screen whose whole job is "every door has a section" is the right
-- place to close it. The screen exists, the route exists, the category exists,
-- the roles are unchanged (admin, super_admin) — so the door goes back on the
-- shelf #1016 built for it, and the parity report resolves 130/130.
--
-- Idempotent: it names the one key and asserts the one state.
update public.feature_registry
   set is_active = true
 where feature_key = 'admin.search_synonyms'
   and is_active is distinct from true;

-- The section it belongs to, restated so a future re-run of this file lands
-- the row in the same place #1016 chose even if the category was cleared.
update public.feature_registry
   set category    = coalesce(nullif(category, ''), 'more_catalogue'),
       group_label = coalesce(nullif(group_label, ''), 'Catalogue & pricing')
 where feature_key = 'admin.search_synonyms';

do $$
declare v_unresolved int;
begin
  select (public.nav_parity_report() ->> 'unresolved')::int into v_unresolved;
  if v_unresolved <> 0 then
    raise warning 'c1892: nav parity still reports % unresolved door(s)', v_unresolved;
  end if;
end $$;

-- CMD #1892 — Dashboard home UI: needs-you-now rows, section tile grids, search.
--
-- The screen work is Flutter; the ONE decision that belongs in Postgres is
-- whether "Needs you now" still prints when nothing needs you. #1891 shipped it
-- as show_when_empty = true ("Nothing needs you right now." is an answer);
-- #1892's spec asks for the section to be HIDDEN when empty, so the flag flips.
-- It stays a column, never a Dart rule: changing our mind again is an UPDATE.
update public.dashboard_section
   set show_when_empty = false
 where section_key = 'needs_now'
   and show_when_empty is distinct from false;

-- The inline search field on the Dashboard is nav_search(); its placeholder and
-- its "keep typing" line are copy, so they live in ui_copy like every other
-- string the screen prints.
insert into public.ui_copy (key, value) values
  ('dashboard_home.search_hint', to_jsonb('Search screens, orders, customers, suppliers, products'::text)),
  ('dashboard_home.search_clear', to_jsonb('Clear'::text))
on conflict (key) do nothing;

-- CMD #1893 — one screen, one "Quick actions".
--
-- The pinned row this command added carries the heading the spec named:
-- QUICK ACTIONS. The dashboard_v2 ops card already printed a heading with the
-- same two words over Add order / Start inquiry / Assign delivery, so the live
-- admin home showed the phrase twice, ~250 px apart, meaning two different
-- things: one is "the three things you start most often", the other is "the
-- screens YOU pinned". A reader cannot tell which is which from the heading.
--
-- The ops card's three items are all tasks you begin, so it takes the heading
-- that says that, and "Quick actions" belongs to the pins alone. Copy only —
-- `dash.actions_title` is read by dashboard_ops()/dashboard_v2 through _c(),
-- so nothing in Dart changes and nothing else moves.
update public.ui_copy
   set value = '"Common tasks"'::jsonb
 where key = 'dash.actions_title'
   and value = '"Quick actions"'::jsonb;

insert into public.ui_copy (key, value)
values ('dash.actions_title', '"Common tasks"'::jsonb)
on conflict (key) do nothing;

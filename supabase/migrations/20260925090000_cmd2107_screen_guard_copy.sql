-- CMD #2107 — the screen guard's own words.
--
-- A build-time exception inside a screen used to replace that screen with
-- Flutter's default error box: a bare grey rectangle in a release build, with
-- no title, no explanation and no way back. Read on a phone that is "the
-- screen closed". ErrorWidget.builder now renders a real error state, and
-- every word of it is a row here — changing the wording is an UPDATE, never a
-- deploy.
insert into public.ui_copy (key, value) values
  ('screen_guard.title',  '"This screen hit a problem"'::jsonb),
  ('screen_guard.body',   '"Nothing was lost. Go back and open it again — if it keeps happening, tell us and we will fix it."'::jsonb),
  ('screen_guard.retry',  '"Try again"'::jsonb),
  ('screen_guard.back',   '"Go back"'::jsonb),
  ('routes_tab.retry',    '"Try again"'::jsonb),
  ('routes_tab.today_failed', '"Could not load today''s visits."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

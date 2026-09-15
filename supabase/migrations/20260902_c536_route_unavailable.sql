-- CHANGE #536 QA round 3 — the words an unknown route says.
--
-- feature_registry is DATA: a row can name a route_key a deployed build has
-- never heard of (three cshop_buying rows appeared at 15:56 UTC while this
-- command was open). home_shell's router used to fall out of its switch in
-- silence, so such a tile was a tap that did nothing. It now prints THIS
-- sentence — the app owns the SnackBar, not one word inside it.
insert into public.ui_copy (key, value) values
  ('home_shell.route_unavailable',
   to_jsonb('This one is not in your app yet — update the app and try again.'::text))
on conflict (key) do update set value = excluded.value;

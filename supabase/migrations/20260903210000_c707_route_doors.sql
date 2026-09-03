-- CHANGE #707 (5/5) — the doors, DECLARED.
--
-- The two screens were written against partnerDestination() in
-- partner_home_screen.dart. Nothing calls that resolver: CHANGE #653 retired
-- the partner surface and removed its three entry points, and the resolver
-- outlived them. So both screens compiled, both RPCs answered, the tiles
-- rendered — and every tap fell through home_shell's switch into the
-- backend-worded "route unavailable" branch.
--
-- That is exactly the failure surface_route exists to make impossible (#570,
-- #821): a route with no declared handler is a tile with no door, and
-- rg_check's c821_shell_doors target is what turns the drift red. The door for
-- both is now shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart,
-- which home_shell reaches through its one lookup — so handled_by is
-- 'home_shell', and scripts/gen_registered_routes.sh will name both in the
-- protected mirror.
--
-- Idempotent: the primary key is (route_key, feature_key), so a re-applied
-- migration updates the note and changes nothing else.

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('fulfil_tasks', 'partner.fulfil_tasks', 'feature', 'home_shell',
   'CHANGE #707 — the fulfilment task board (who owns each stage). Opened by '
   'shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart. '
   'fulfil_task_board() answers a caller who is neither office nor partner '
   'with can_write:false and its own refusal, so the door is not the guard.',
   true),
  ('my_tasks', 'worker.my_tasks', 'feature', 'home_shell',
   'CHANGE #707 — the worker''s own list for today, in promised order. Opened '
   'by shellExtraRouteScreen(); fulfil_my_tasks() refuses anyone who is not a '
   'worker, so the door being open to a role decides nothing.',
   true)
on conflict (route_key, feature_key) do update
   set kind       = excluded.kind,
       handled_by = excluded.handled_by,
       note       = excluded.note,
       is_active  = excluded.is_active,
       updated_at = now();

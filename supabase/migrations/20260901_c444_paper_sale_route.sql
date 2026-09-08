-- CMD #444 — #429's last mile: the /admin/go/paper_sale deep link.
--
-- #429 shipped the paper-sale surface and its proven entry point (the counter
-- app-bar button, CHANGE #916), but `home_shell.dart` was leased by #427 for
-- the whole of that build, so the shell's route case could not land with it.
-- The registry row was therefore parked `is_active=false` ON PURPOSE: an admin
-- tile that renders and does nothing on tap is worse than no tile at all, and
-- on a canvas app no tool can click, it is also invisible to every automated
-- check. Switching it on is the LAST step here, after the case exists.
--
-- Idempotent: re-running this is an UPDATE to the value it already holds.
update public.feature_registry
   set is_active = true
 where feature_key = 'admin.paper_sale'
   and route_key = 'paper_sale';

-- The closing-time nudge points at this deep link, so it must resolve. If the
-- row ever goes missing the nudge would point at nothing — recreate it rather
-- than silently leaving a dead link in a WhatsApp message.
insert into public.feature_registry(feature_key, label, group_label, icon_key, route_key,
                                    sort_order, owner, default_access, is_active,
                                    category, surface, roles_allowed, description)
values ('admin.paper_sale', 'Paper sales', 'Pharmacy tools', 'receipt_long', 'paper_sale',
        4137, 'medibo', 'none', true, 'parties', 'dashboard',
        array['admin','super_admin'],
        'CMD #429 - handwritten sale sheets photographed at the counter become stock movements. Reached from the counter app bar, and from here.')
on conflict (feature_key) do update
  set route_key = excluded.route_key, is_active = true;

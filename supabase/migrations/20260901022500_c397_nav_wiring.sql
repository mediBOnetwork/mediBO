-- CHANGE #397 — part 6: the way in.
--
-- Rule 11: a feature Om cannot tap does not exist. feature_registry is the one
-- nav surface (#325), so registering the two new features here is what puts a
-- real tile on the admin dashboard and a row in the command palette. The
-- matching `case` lives in home_shell.dart's `_handleAdminNav`, and
-- test/protected/registered_routes.dart pins the pair together so a tile can
-- never render without a router case behind it.
update public.feature_registry
   set route_key = 'bulk_actions',
       deep_link = '/admin/go/bulk_actions',
       surface   = 'dashboard',
       category  = 'system',
       group_label = 'Admin & System',
       is_active = true
 where feature_key = 'admin.bulk_actions';

update public.feature_registry
   set route_key = 'exports',
       deep_link = '/admin/go/exports',
       surface   = 'dashboard',
       category  = 'system',
       group_label = 'Admin & System',
       is_active = true
 where feature_key = 'admin.exports';

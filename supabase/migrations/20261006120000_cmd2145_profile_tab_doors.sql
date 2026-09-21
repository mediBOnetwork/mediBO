-- CMD #2145 — RG red after #1473 (c570_surface_map: 13 × unrouted_feature).
-- CMD #2125 registered the Profile tab's rows as feature_registry rows
-- (cust.my_shop, cust.ledger, cust.cart, …) and profile_tab_screen.dart opens
-- every one of them (ProfileTabAction.doorOf → cart / share / myShop /
-- customerMenuScreen / shell). What was never written is the matching
-- surface_route row: the door is (route_key, feature_key) (lesson 162), so a
-- route_key that already has a door for ANOTHER feature does not count.
-- Intentional change, missing registration → declare the doors.
-- Idempotent: on conflict do nothing.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note)
select f.route_key, f.feature_key, 'feature', 'profile_tab_screen',
       'CMD #2145: Profile tab row (CMD #2125) — opened by ProfileTabAction.doorOf'
  from public.feature_registry f
 where f.feature_key in ('cust.my_shop','cust.ledger','cust.payments','cust.advance',
                         'cust.statements','cust.gst_licence','cust.cart',
                         'cust.appearance','cust.language','cust.share_app',
                         'cust.about','cust.privacy','cust.terms')
   and f.route_key <> ''
on conflict (route_key, feature_key) do nothing;

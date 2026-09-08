-- CHANGE #536, QA round 4 (finding 275).
--
-- The spec names six Grow tiles: "Refills & counter, WhatsApp storefront,
-- Demand, Benchmark, Exchange & borrow, /near listing". Only five tiles exist,
-- and QA read that as two missing features. They are not missing — they are
-- SECTIONS INSIDE two tiles that do not name them:
--   • the WhatsApp storefront is the second pane of the refill console
--     (lib/screens/pharmacy/pharmacy_refill_screen.dart, CMD #417 — the public
--     page it publishes is storefront_screen.dart, reached from the shared
--     link, not from a tile of its own), route_key 'refill';
--   • the cohort benchmark is section 2 of the owner dashboard
--     (lib/screens/pharmacy/pharmacy_owner_screen.dart OwnerBenchmarkView,
--     fed by pharmacy_benchmark()), route_key 'pharmacy_owner'.
-- Registering a second tile for each would be two doors onto one screen. The
-- honest fix is that the tile SAYS what is behind it, and the description is
-- already a backend string the card prints verbatim — so this is a registry
-- data fix, exactly the class the spec asks for, with no Dart and no deploy.
--
-- search_terms is filled for the same reason: whatever searches this surface
-- next should find "whatsapp storefront" and "benchmark" without a schema
-- change. Idempotent: re-applying only rewrites the same two strings.
update public.feature_registry
   set description  = 'Reminders, and your WhatsApp storefront',
       search_terms = 'refill reminders whatsapp storefront share link counter ai'
 where surface = 'customer_shop' and route_key = 'refill';

update public.feature_registry
   set description  = 'Your day, and how you benchmark against nearby shops',
       search_terms = 'owner dashboard benchmark cohort compare nearby shops day'
 where surface = 'customer_shop' and route_key = 'pharmacy_owner';

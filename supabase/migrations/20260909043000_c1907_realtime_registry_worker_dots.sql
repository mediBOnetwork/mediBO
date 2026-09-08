-- CMD #1907 — RG red after #1272: three c643/c646 behaviour failures, one cause.
--
-- CMD #1878 (worker live dot) created public.lead_worker_locations and added it
-- straight to the supabase_realtime publication:
--
--     alter publication supabase_realtime add table public.lead_worker_locations
--
-- without a row in realtime_table_registry. CHANGE #643 made that registry the
-- single authority over what may be published, so the raw ALTER broke all three
-- guards at once:
--   * c643_realtime_publication_small  — 9 published tables against a ceiling of 8.
--   * c646_registry_matches_publication — published, but not live in the registry.
--   * c643_noop_updates_suppressed      — published without zzz_c643_suppress_noop.
--
-- The registry's own precedent settles which side gives way: a moving person's
-- position is already POLLED, not published — delivery_partner_locations is
-- live=false at 15 s, "inside the useful resolution of a road move". The worker
-- dot is exactly that shape, it has its own poll RPC (route_worker_dots()), and
-- the widget already runs a Timer.periodic on the backend's interval as its
-- floor, so nothing on screen changes: LiveFeed reads mode='poll' from
-- realtime_plan() and polls instead of binding a channel. Meanwhile the eight
-- live tables are each a "a human is waiting and 30 s would be a bug" surface,
-- so none of them is the one to demote.
--
-- Idempotent: one upsert plus the sync that makes the publication match.

insert into public.realtime_table_registry
  (table_name, live, filter_required, poll_seconds, surface, reason) values
  ('lead_worker_locations', false, false, 15, 'routes/live worker dot',
     'Worker position on the road, same class as delivery_partner_locations: '
     'route_worker_dots() is the poll and 15 s is inside the useful resolution '
     'of a road move. Live would be a ninth published table against a ceiling of eight.')
on conflict (table_name) do update
  set live            = excluded.live,
      filter_required = excluded.filter_required,
      poll_seconds    = excluded.poll_seconds,
      surface         = excluded.surface,
      reason          = excluded.reason,
      updated_at      = now();

-- Makes supabase_realtime match the registry (drops the ninth table) and
-- re-installs the no-op suppression trigger on everything still published.
select public.realtime_publication_sync();

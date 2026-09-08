-- CHANGE #707 (7/7) — the last mile of reachability: the access matrix.
--
-- The door was declared, the shell opened it, the mirror named it — and the
-- route was STILL refused. `_handleAdminNav` checks Access.routeCanView()
-- before it opens anything (#653: a deep link must not walk in behind a hidden
-- entry), and access_boot() reads that flag from access_role_default. Both new
-- features shipped with the table's own default — view=false for `admin` and
-- for `partner` — so the live render-log answered the reachability probe with
-- `c653_nav_denied=fulfil_tasks` and never wrote c707_task_board.
--
-- A super admin was never blocked (access_effective returns true for that role
-- unconditionally), which is exactly why this kind of gap survives a proof
-- taken as a super admin. It was found by driving the route as an ordinary
-- office admin.
--
-- What this fixes, and why each grant is the right one:
--
--   partner.fulfil_tasks / partner — the registry row already carries
--     default_access='write' because the board only ever shows THIS partner's
--     zone and only ever offers THIS partner's on-shift workers. Leaving
--     can_view=false contradicted that: the feature the spec hands to the
--     partner could not be opened by a partner.
--   partner.fulfil_tasks / admin — the office already runs fulfilment (the ops
--     board and the exceptions console are office surfaces, and #707 put the
--     stage owner on both). _c707_can() has ALWAYS granted an office admin
--     write here; this only stops the UI from hiding what the RPC allows.
--   worker.my_tasks — a worker login authorises as 'admin' against these RPCs
--     (#307), so the office role is the one that has to carry the View flag for
--     the worker's own list to open at all. It grants nothing: fulfil_my_tasks()
--     resolves my_fulfil_worker_id() and refuses anyone who is not a worker,
--     with its own sentence. write stays FALSE — there is nothing on that
--     screen an office login should be starting or finishing on someone's
--     behalf; the override path is the partner's, on the board.
--
-- Idempotent: (feature_key, role) is the key, so re-applying only re-asserts.

insert into public.access_role_default (feature_key, role, can_view, can_write)
values
  ('partner.fulfil_tasks', 'admin',       true,  true),
  ('partner.fulfil_tasks', 'partner',     true,  true),
  ('partner.fulfil_tasks', 'super_admin', true,  true),
  ('worker.my_tasks',      'admin',       true,  false),
  ('worker.my_tasks',      'partner',     true,  false),
  ('worker.my_tasks',      'super_admin', true,  true)
on conflict (feature_key, role) do update
   set can_view  = excluded.can_view,
       can_write = excluded.can_write;

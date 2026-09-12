-- CHANGE #756 — the regression guard went red on `c570_surface_map`:
--
--   route_key "ops_board" is not declared in surface_route, so tapping the
--   tile lands in the shell's default branch.
--
-- #688 built the Live ops board and registered its two feature rows with
-- route_key 'ops_board'; #754 then paired every fulfill_tab route to its stage
-- through access_boot().routes[].stage, so the route DOES open — Fulfill on
-- the ops-board stage, via shellOpenFulfillStage(). What was never written is
-- the DECLARATION the surface map audits against, which is why the guard could
-- not tell a working door from a missing one.
--
-- This is the declaration, in the shape #690 used for the `exceptions` stage:
-- one row per feature key, because the same stage is reachable under the admin
-- key and under the partner key and the audit checks both.
--
-- Data only. No RPC changes, no schema change, nothing to rebuild.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('ops_board', 'fulfill.ops_board', 'feature', 'home_shell',
   'CHANGE #756 — home_shell takes /admin/go/ops_board and shellOpenFulfillStage() opens Fulfill on the ops_board stage (the #754 pairing)', true),
  ('ops_board', 'partner.ops_board', 'feature', 'admin_fulfillment_screen',
   'CHANGE #756 — the same stage under the partner feature key', true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind,
      handled_by = excluded.handled_by,
      note = excluded.note,
      is_active = true;

-- CMD #2064 — regression-guard repair after CHANGE #1409.
--
-- rg_check() went red with 0 diffs and 2 CRITICAL behaviour failures. Both are
-- the same three rows: the Routes doors CMD #2056 (CHANGE #1411) put on the
-- Dashboard under FIELD & GROWTH.
--
--   c570_surface_map                            — R1 unrouted_feature ×3: the
--     route_keys cust_routes_builder / cust_routes_assign / cust_routes_today
--     are not declared in surface_route.
--   c634_every_feature_declares_a_test_contract — the same three features
--     carry no happy path.
--
-- Neither is rebaselineable: a behaviour failure is always a fix. And the fix
-- is a DECLARATION, not a blessing — the doors genuinely open today. #2056
-- shipped the wiring in the same change: a tile carries tab_host 'customers'
-- plus tab_key '<tab>:<section>', admin_dashboard_screen hands that to
-- AdminCustomerScreen.openTab(), and customer_tab_target.dart splits the pair
-- and resolves the section through kRoutesSectionModes
-- ('all_plans'/'past_plans' -> builder, 'today' -> today). What was missing is
-- the ROW that records it, which is the only thing the audit can read.
--
-- handled_by matches the sibling rows for the same screen ('admin_customer_
-- screen'), so the map keeps naming files the way every other door does.
--
-- Idempotent: the deploy replays this file on live exactly once, but re-runs
-- must be harmless, and CMD #2061 carries the same repair in its own file.

-- ── 1. The three doors ──────────────────────────────────────────────────────
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('cust_routes_builder', 'admin.cust_tab.routes_builder', 'feature',
   'admin_customer_screen',
   'CMD #2056 Dashboard tile; opens the Routes sub-tab at tab_screen '
   || 'routes:all_plans (kRoutesSectionModes -> builder).', true),
  ('cust_routes_assign', 'admin.cust_tab.routes_assign', 'feature',
   'admin_customer_screen',
   'CMD #2056 Dashboard tile; opens the Routes sub-tab at tab_screen '
   || 'routes:past_plans (kRoutesSectionModes -> builder, assignment panel).', true),
  ('cust_routes_today', 'admin.cust_tab.routes_today', 'feature',
   'admin_customer_screen',
   'CMD #2056 Dashboard tile; opens the Routes sub-tab at tab_screen '
   || 'routes:today (kRoutesSectionModes -> today).', true)
on conflict (route_key, feature_key) do update
   set kind       = excluded.kind,
       handled_by = excluded.handled_by,
       note       = excluded.note,
       is_active  = true,
       updated_at = now();

-- ── 2. The three test contracts ─────────────────────────────────────────────
-- The entry is the Routes screen's own deep link — the shell's parking route
-- only knows the canonical key (cust_routes), which is precisely why the three
-- tiles carry no deep_link of their own and travel by tab_host/tab_key. The
-- expectation is the render-log key the section actually writes when it paints:
-- c452_routes for the builder's plan list, c1872_today_routes for Today.
update public.feature_registry
   set test_automatable = true,
       test_entry       = '/admin/go/cust_routes',
       test_roles       = array['admin','super_admin']::text[],
       test_steps       = '[{"kind":"auth","role":"{role}"},
                            {"kind":"goto","path":"/admin/go/cust_routes"},
                            {"kind":"settle","ms":6000}]'::jsonb,
       test_expect      = jsonb_build_object(
                            'kind','visible','source','render_log','key','c452_routes'),
       test_skip_reason = null
 where feature_key in ('admin.cust_tab.routes_builder',
                       'admin.cust_tab.routes_assign');

update public.feature_registry
   set test_automatable = true,
       test_entry       = '/admin/go/cust_routes',
       test_roles       = array['admin','super_admin']::text[],
       test_steps       = '[{"kind":"auth","role":"{role}"},
                            {"kind":"goto","path":"/admin/go/cust_routes"},
                            {"kind":"settle","ms":6000}]'::jsonb,
       test_expect      = jsonb_build_object(
                            'kind','visible','source','render_log','key','c1872_today_routes'),
       test_skip_reason = null
 where feature_key = 'admin.cust_tab.routes_today';

-- ── 3. Prove it here, so a red guard can never be shipped by this file ──────
-- Scoped to the THREE rows this file declares: a build branch is a partial
-- copy of live (its surface_route does not carry the older cust_routes door),
-- and a self-check that fails on what the branch never had is a false alarm.
do $c2064$
declare v_missing text; v_gap text;
begin
  select string_agg(f.feature_key, ', ' order by f.feature_key) into v_missing
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and coalesce(f.route_key,'') <> '' and r.route_key is null
     and f.feature_key in ('admin.cust_tab.routes_builder',
                           'admin.cust_tab.routes_assign',
                           'admin.cust_tab.routes_today');
  if v_missing is not null then
    raise exception 'CMD #2064: Routes doors still undeclared: %', v_missing;
  end if;

  select string_agg(feature_key, ', ' order by feature_key) into v_gap
    from public.rg_contract_gap()
   where feature_key in ('admin.cust_tab.routes_builder',
                         'admin.cust_tab.routes_assign',
                         'admin.cust_tab.routes_today');
  if v_gap is not null then
    raise exception 'CMD #2064: Routes doors still have no test contract: %', v_gap;
  end if;
end $c2064$;

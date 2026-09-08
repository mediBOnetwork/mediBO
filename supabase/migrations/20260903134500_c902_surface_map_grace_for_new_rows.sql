-- CHANGE #902 · the surface map stops filing a critical on a build in progress.
--
-- WHAT WENT WRONG. 13:12:49 UTC — command #707, still building, registers
-- feature_registry row worker.my_tasks on surface 'dashboard'. That surface
-- serves [admin, super_admin, partner]; the row admits [worker, admin,
-- super_admin], so surface_map_audit()'s R5 reports `wrong_surface`, tone
-- danger, immediately. rg behaviour c570_surface_map raises on any drift, a
-- failing behaviour is a CRITICAL, and rg_watch files a critical on FIRST
-- sight — the confirm-runs delay #751 added covers schema diffs only. 13:20
-- red, 13:22 command #902 filed, 13:23 the owning command corrects its own row
-- and every run since is green. One worker slot, on a red that cleared itself
-- in three minutes.
--
-- WHY IT IS THE AUDIT AND NOT THE ROW. R1 already had this exact window, and
-- its own comment says why: `devtool.heartbeat`, registered minutes earlier by
-- #468 while that command was still building its screen, made every registry
-- INSERT a red rg_check for whoever deployed next. R1 got surface_map_grace_min
-- that day; R5 and R6 key off the same brand-new row and never did.
--
-- WHAT CHANGES. Inside surface_map_grace_min a row's surface/role mismatch (R5)
-- and a surface with no declared audience (R6) are REPORTED under `pending`,
-- not counted as drift. Past the window they are drift again, unchanged. The
-- guard is delayed for the length of one build, never removed — and `pending`
-- is now drawn on the Surface map screen, so Om reads it while it is pending.
--
-- Idempotent: create or replace only. No table, column or grant is touched.
CREATE OR REPLACE FUNCTION public.surface_map_audit()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role   text := coalesce(public.get_my_role(),'none');
  v_rows   jsonb;
  v_drift  jsonb := '[]'::jsonb;
  v_part   jsonb;
  v_sections jsonb := '[]'::jsonb;
  v_pending jsonb := '[]'::jsonb;
  v_admins int;
  -- how long a newly registered feature may go without a declared door before
  -- it counts as drift. DATA, so the window moves without a deploy.
  v_grace int := coalesce(
    (select (value #>> '{}')::int from public.app_settings
      where key = 'surface_map_grace_min'), 90);
begin
  if v_role <> 'super_admin' then
    return jsonb_build_object('ok', false,
      'title', 'Surface map',
      'message', coalesce(nullif(public._c('surface_map.denied'),''),
                          'Only a super admin can read the surface map.'));
  end if;

  select count(*) into v_admins from public.admins a
   where not coalesce(a.is_super,false);

  -- ── ROW 1: the feature registry, one line per feature.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key,
           'label', f.label,
           'registry_label', 'feature_registry',
           'surface_label', coalesce(s.label, f.surface),
           'resolver_label', coalesce(s.resolver, '—'),
           'intended_label', array_to_string(f.roles_allowed, ', ')
                             || case when f.partner_eligible then ' + partner' else '' end,
           'actual_label',
             case
               when f.surface in ('profile','both') then array_to_string(f.roles_allowed, ', ')
               when f.surface = 'dashboard' and f.feature_key not like 'admin.%'
                    and not f.partner_eligible then 'nobody — no admin.% key, not partner-eligible'
               when f.surface = 'dashboard' then
                 array_to_string(array_remove(f.roles_allowed, 'partner'), ', ')
                 || case when f.partner_eligible then ' + partner (by grant)' else '' end
               else array_to_string(f.roles_allowed, ', ')
             end,
           'route_label', case when f.route_key = '' then 'no route — section header'
                               else coalesce(r.handled_by, 'NO DOOR') || ' · ' || f.route_key end,
           'tone', case when f.route_key <> '' and r.route_key is null then 'danger'
                        when f.surface not in (select surface from public.surface_audience) then 'warning'
                        when exists (select 1 from unnest(f.roles_allowed) x
                                      where not (x = any (s.audience))) then 'warning'
                        else 'success' end)
         order by f.surface, f.category, f.sort_order), '[]'::jsonb)
    into v_rows
    from public.feature_registry f
    left join public.surface_audience s on s.surface = f.surface
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active;

  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'heading', 'Feature registry — ' || (select count(*)::text from public.feature_registry where is_active) || ' active features',
    'empty_hint', 'The registry is empty.',
    'rows', v_rows));

  -- ── ROW 2: the supplier's own registry. A separate table on purpose: a
  --    supplier is not an admin subject and never appears in access_effective.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', sf.feature_key,
           'label', public._c(sf.copy_key),
           'registry_label', 'supplier_feature',
           'surface_label', 'Supplier portal',
           'resolver_label', 'supplier_session()',
           'intended_label', 'supplier, supplier staff (clamped)',
           'actual_label', 'supplier, supplier staff (clamped)',
           'route_label', 'supplier_shell · ' || sf.feature_key,
           'tone', case when sf.is_active then 'success' else 'neutral' end)
         order by sf.sort_order), '[]'::jsonb)
    into v_part from public.supplier_feature sf;

  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'heading', 'Supplier portal — ' || (select count(*)::text from public.supplier_feature where is_active) || ' features',
    'empty_hint', 'No supplier feature is registered.',
    'rows', v_part));

  -- ── ROW 3: the bottom bar every signed-in visitor shares.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', s.slot_key,
           'label', public._c(s.label_key),
           'registry_label', 'customer_nav_slot',
           'surface_label', 'Bottom bar',
           'resolver_label', 'customer_nav()',
           'intended_label', coalesce(array_to_string(s.roles_allowed, ', '), 'everyone, signed in or not'),
           'actual_label', coalesce(array_to_string(s.roles_allowed, ', '), 'everyone, signed in or not'),
           'route_label', 'home_shell · page ' || s.page_index::text,
           'tone', 'success')
         order by s.sort_order), '[]'::jsonb)
    into v_part from public.customer_nav_slot s where s.is_active;

  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'heading', 'Bottom bar — ' || (select count(*)::text from public.customer_nav_slot where is_active) || ' slots',
    'empty_hint', 'No slot is registered.',
    'rows', v_part));

  -- ── DRIFT. Six mechanical rules. Every one of them caught a real defect on
  --    the day it was written; they are here so the next one is caught by CI.

  -- R1 · a live tile whose route no dispatcher declares — a door that opens
  --      onto nothing. (admin.delivery_extras / delivery_waves /
  --      returns_refunds were exactly this.)
  --
  --      QA round 2: this fired on `devtool.heartbeat`, registered minutes
  --      earlier by command #468 while that command was still building its
  --      screen. Correct on the data, wrong on the situation — and on a
  --      five-worker pool it makes every registry INSERT a red rg_check for
  --      whoever deploys next. A doorless tile is drift once it is older than
  --      surface_map_grace_min; younger than that it is reported as a warning
  --      that does not count, so Om still sees it and nobody else's build
  --      breaks while the owning command is still working.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','unrouted_feature', 'tone','danger',
           'label', f.label || ' has no door',
           'feature_key', f.feature_key,
           'detail', 'route_key "' || f.route_key || '" is not declared in surface_route, '
                     || 'so tapping the tile lands in the shell''s default branch.')
         ), '[]'::jsonb) into v_part
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and f.route_key <> '' and r.route_key is null
     and f.created_at < now() - make_interval(mins => v_grace);
  v_drift := v_drift || v_part;

  -- R2 · a declared feature door naming a feature that is gone or switched off.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','orphan_route', 'tone','warning',
           'label', 'Route ' || r.route_key || ' points at nothing',
           'feature_key', coalesce(r.feature_key,''),
           'detail', 'surface_route says kind=feature, but no ACTIVE feature_registry row carries that key.')
         ), '[]'::jsonb) into v_part
    from public.surface_route r
   where r.is_active and r.kind = 'feature'
     and not exists (select 1 from public.feature_registry f
                      where f.is_active and f.feature_key = r.feature_key);
  v_drift := v_drift || v_part;

  -- R3 · a role that can sign in but is not on the profile menu — no View
  --      Profile and, worse, no Logout. (The partner was in this state.)
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','role_cannot_sign_out', 'tone','danger',
           'label', u.role_key || ' has no profile menu',
           'feature_key','identity.logout',
           'detail', u.role_key || ' accounts can sign in, but the role is missing from '
                     || 'identity.* roles_allowed, so nav_registry() returns them an empty '
                     || 'profile_menu — including no way to log out.')
         ), '[]'::jsonb) into v_part
    from (select unnest(array['admin','super_admin','partner','supplier','customer',
                              'delivery','worker','mr','company']) as role_key) u
   where not exists (
     select 1 from public.feature_registry f
      where f.feature_key = 'identity.logout' and f.is_active
        and u.role_key = any (f.roles_allowed));
  v_drift := v_drift || v_part;

  -- R4 · an entry point whose audience is not its destination's audience.
  --      The My Shop tab sat on the supplier's, the partner's and the rider's
  --      bottom bar while the surface behind it admits only a pharmacy.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','entry_audience_mismatch', 'tone','danger',
           'label', 'My Shop tab audience ≠ My Shop surface audience',
           'feature_key','my_shop',
           'detail', 'bottom-bar slot admits [' || coalesce(array_to_string(s.roles_allowed,', '),'everyone')
                     || '] while the customer_shop features admit ['
                     || (select string_agg(distinct x, ', ' order by x)
                           from public.feature_registry f, unnest(f.roles_allowed) x
                          where f.is_active and f.surface = 'customer_shop') || '].')
         ), '[]'::jsonb) into v_part
    from public.customer_nav_slot s
   where s.slot_key = 'my_shop' and s.is_active
     and coalesce(
           (select array_agg(distinct x order by x)
              from public.feature_registry f, unnest(f.roles_allowed) x
             where f.is_active and f.surface = 'customer_shop'),
           array[]::text[])
         is distinct from
         (select array_agg(distinct y order by y) from unnest(coalesce(s.roles_allowed, array[]::text[])) y);
  v_drift := v_drift || v_part;

  -- R5 · a feature registered onto a surface its own role list contradicts —
  --      a pharmacy tile wearing admin roles, an admin tool wearing customer.
  --
  --      CHANGE #902: the same grace window R1 has, for the same reason and on
  --      the same clock. #707 registered worker.my_tasks at 13:12 while it was
  --      still building the screen behind it; the surface it landed on served
  --      [admin, super_admin, partner], so R5 fired DANGER on sight. A failing
  --      behaviour is a critical, and rg_watch files a critical WITHOUT the
  --      confirm-runs delay (#751) — so a red that its own owner cleared three
  --      minutes later had already spent a whole worker slot on itself. Inside
  --      the window the mismatch is REPORTED under pending, never counted; the
  --      moment the row is older than surface_map_grace_min it is drift again,
  --      exactly as before. This delays the alarm, it removes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','wrong_surface', 'tone','danger',
           'label', f.label || ' is on the wrong surface',
           'feature_key', f.feature_key,
           'detail', 'surface ' || f.surface || ' serves [' || array_to_string(sc.audience, ', ')
                     || '] but the row admits [' || array_to_string(f.roles_allowed, ', ') || '].')
         ), '[]'::jsonb) into v_part
    from public.feature_registry f
    join public.surface_audience sc on sc.surface = f.surface
   where f.is_active
     and exists (select 1 from unnest(f.roles_allowed) x where not (x = any (sc.audience)))
     and f.created_at < now() - make_interval(mins => v_grace);
  v_drift := v_drift || v_part;

  -- R6 · a surface nothing in this audit knows about. Forward compatibility:
  --      a new surface must be declared here, or its audience is unchecked.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','undeclared_surface', 'tone','warning',
           'label', 'Surface "' || f.surface || '" has no declared audience',
           'feature_key', f.surface,
           'detail', 'Add it to the surface table inside surface_map_audit() so its rows are audited.')
         ), '[]'::jsonb) into v_part
    from (select distinct surface from public.feature_registry where is_active) f
   where not exists (select 1 from public.surface_audience s where s.surface = f.surface)
     -- #902: a surface every one of whose rows is younger than the window is a
     -- registration in progress, not an unaudited surface. Reported below.
     and exists (select 1 from public.feature_registry f2
                  where f2.is_active and f2.surface = f.surface
                    and f2.created_at < now() - make_interval(mins => v_grace));
  v_drift := v_drift || v_part;

  -- ...and the same tiles while they are still inside the grace window. These
  --    are REPORTED, never counted: a door that has not landed yet is a build
  --    in progress, and a build in progress is not a defect.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','door_pending', 'tone','warning',
           'label', f.label || ' — door not landed yet',
           'feature_key', f.feature_key,
           'detail', 'registered ' || age_label || ' ago with route_key "' || f.route_key
                     || '" and no surface_route row. Counts as drift after '
                     || v_grace::text || ' minutes.')
         order by f.feature_key), '[]'::jsonb) into v_pending
    from (select fr.*, (extract(epoch from (now() - fr.created_at)) / 60)::int::text || ' min' as age_label
            from public.feature_registry fr) f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and f.route_key <> '' and r.route_key is null
     and f.created_at >= now() - make_interval(mins => v_grace);

  -- ...and the R5 mismatches still inside the window. Same rule, same clock:
  --    a surface/role pair that has not settled yet is a build in progress.
  select v_pending || coalesce(jsonb_agg(jsonb_build_object(
           'code','surface_pending', 'tone','warning',
           'label', f.label || ' — surface not settled yet',
           'feature_key', f.feature_key,
           'detail', 'registered ' || f.age_label || ' ago on surface ' || f.surface
                     || ', which serves [' || array_to_string(sc.audience, ', ')
                     || '] while the row admits [' || array_to_string(f.roles_allowed, ', ')
                     || ']. Counts as drift after ' || v_grace::text || ' minutes.')
         order by f.feature_key), '[]'::jsonb) into v_pending
    from (select fr.*, (extract(epoch from (now() - fr.created_at)) / 60)::int::text || ' min' as age_label
            from public.feature_registry fr) f
    join public.surface_audience sc on sc.surface = f.surface
   where f.is_active
     and exists (select 1 from unnest(f.roles_allowed) x where not (x = any (sc.audience)))
     and f.created_at >= now() - make_interval(mins => v_grace);

  -- ...and a surface whose every row is still inside the window.
  select v_pending || coalesce(jsonb_agg(jsonb_build_object(
           'code','undeclared_surface_pending', 'tone','warning',
           'label', 'Surface "' || f.surface || '" has no declared audience yet',
           'feature_key', f.surface,
           'detail', 'first registered ' || f.age_label || ' ago. Add it to surface_audience '
                     || 'so its rows are audited. Counts as drift after '
                     || v_grace::text || ' minutes.')
         order by f.surface), '[]'::jsonb) into v_pending
    from (select fr.surface,
                 min(fr.created_at) as first_at,
                 (extract(epoch from (now() - min(fr.created_at))) / 60)::int::text || ' min' as age_label
            from public.feature_registry fr where fr.is_active group by fr.surface) f
   where not exists (select 1 from public.surface_audience s where s.surface = f.surface)
     and f.first_at >= now() - make_interval(mins => v_grace);

  return jsonb_build_object(
    'ok', true,
    'title', coalesce(nullif(public._c('surface_map.title'),''), 'Surface map'),
    'subtitle', coalesce(nullif(public._c('surface_map.subtitle'),''),
                'Every feature, the audience it was registered for, and the audience that can reach it.'),
    'drift', v_drift,
    'drift_count', jsonb_array_length(v_drift),
    'pending', v_pending,
    'pending_count', jsonb_array_length(v_pending),
    'pending_heading', case when jsonb_array_length(v_pending) = 1
                            then '1 registration still landing'
                            else jsonb_array_length(v_pending)::text || ' registrations still landing' end,
    'pending_hint', 'Registered less than ' || v_grace::text
                    || ' minutes ago. Reported, not counted — each one becomes drift on its own clock.',
    -- the four row captions the screen prints. Renaming one is an UPDATE.
    'labels', jsonb_build_object(
      'intended', coalesce(nullif(public._c('surface_map.built_for'),''), 'Built for'),
      'actual',   coalesce(nullif(public._c('surface_map.reaches'),''),   'Reaches'),
      'surface',  coalesce(nullif(public._c('surface_map.surface'),''),   'Surface'),
      'route',    coalesce(nullif(public._c('surface_map.door'),''),      'Door')),
    'clean_label', coalesce(nullif(public._c('surface_map.clean'),''),
                            'No mapping drift — every feature reaches exactly its own audience.'),
    'drift_heading', case when jsonb_array_length(v_drift) = 1
                          then '1 mapping problem'
                          else jsonb_array_length(v_drift)::text || ' mapping problems' end,
    'summary', jsonb_build_array(
      jsonb_build_object('label','Features', 'value_label',
        (select count(*)::text from public.feature_registry where is_active), 'tone','neutral'),
      jsonb_build_object('label','Doors declared', 'value_label',
        (select count(*)::text from public.surface_route where is_active), 'tone','neutral'),
      jsonb_build_object('label','Surfaces', 'value_label',
        (select count(*)::text from (select distinct surface from public.feature_registry where is_active) q), 'tone','neutral'),
      jsonb_build_object('label','Admins bound by grants', 'value_label', v_admins::text, 'tone','neutral'),
      jsonb_build_object('label','Drift', 'value_label', jsonb_array_length(v_drift)::text,
        'tone', case when jsonb_array_length(v_drift) = 0 then 'success' else 'danger' end)),
    'sections', v_sections);
end $function$

;

-- CHANGE #902 · the guard for the guard the grace window protects.
--
-- R5 now waits surface_map_grace_min before it calls a fresh registration
-- drift. This test holds down BOTH halves of that: inside the window the
-- mismatch is reported under `pending` and counted as nothing, and one minute
-- past the window it is `wrong_surface` drift exactly as it always was. A
-- future edit that widens the window into a hole fails here.
insert into public.rg_behavior_tests(name, body) values (
  'c902_surface_map_grace',
$body$
do $x$
declare
  v jsonb; v_super uuid; v_key text := '_c902_grace_probe';
begin
  select u.id into v_super from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  if v_super is null then raise exception 'RG_ROLLBACK'; end if;
  perform set_config('request.jwt.claims',
    (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
       from auth.users u where u.id = v_super), true);

  -- a registration exactly like #707's: seconds old, on a surface whose
  -- audience its own role list contradicts, door not declared yet.
  insert into public.feature_registry
    (feature_key, label, surface, route_key, roles_allowed, category, sort_order, created_at)
  values (v_key, 'c902 grace probe', 'dashboard', '', array['worker'], 'system', 9999, now());

  v := public.surface_map_audit();
  if exists (select 1 from jsonb_array_elements(v->'drift') d
              where d->>'feature_key' = v_key) then
    raise exception 'a registration inside the grace window was counted as drift: %', v->'drift';
  end if;
  if not exists (select 1 from jsonb_array_elements(v->'pending') p
                  where p->>'feature_key' = v_key and p->>'code' = 'surface_pending') then
    raise exception 'a registration inside the grace window is not reported as pending: %', v->'pending';
  end if;

  -- ...and the same row, aged past the window, is drift again. The window
  -- delays the alarm; it must never remove it.
  update public.feature_registry
     set created_at = now() - make_interval(mins => 10000)
   where feature_key = v_key;

  v := public.surface_map_audit();
  if not exists (select 1 from jsonb_array_elements(v->'drift') d
                  where d->>'feature_key' = v_key and d->>'code' = 'wrong_surface') then
    raise exception 'the grace window swallowed a real wrong_surface: %', v->'drift';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$body$)
on conflict (name) do update set body = excluded.body;

-- CHANGE #754 — Fulfill tab polish.
--
-- Three Om reports, one migration. All three are the same shape: a decision
-- that was being made in Dart (which tab exists, what a toggle is called, how
-- tall a map is, what an empty day says) moves into the backend, and Flutter
-- goes back to rendering a payload.
--
-- 1. ONE SCREEN, ONE TAB. `partner_screen_tab` still registered Customer
--    Orders under the Customers screen and Supplier Inquiry / Supplier Orders
--    under the Suppliers screen, although all three live in Fulfill. The rows
--    are not deleted — a deleted row is a tab the app SHOWS, because
--    AccessMatrix.tabCanView treats a tab the payload never mentioned as
--    visible (a new tab must survive one deploy). They are marked
--    is_active=false with the Fulfill stage they moved to, so the payload says
--    "this tab is gone, and here is where it went".
-- 2. A route that now lives in Fulfill carries its stage, so /admin/go/inquiry
--    (and every other old position) opens Fulfill on the right stage instead
--    of falling through to a default branch. Derived, not listed: any active
--    feature sharing a canonical key with a fulfill_tab feature inherits that
--    stage, so the next screen that moves needs no code.
-- 3. The AutoFlow / Bundle toggles and the Supplier Shop map both hand the
--    frontend finished strings.
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ── ui_copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_supplier.toggle_on',            '"ON"'::jsonb),
  ('admin_supplier.toggle_off',           '"OFF"'::jsonb),
  ('admin_supplier.auto_meta_toast_on',   '"Automatic by Meta: ON"'::jsonb),
  ('admin_supplier.auto_meta_toast_off',  '"Automatic by Meta: OFF"'::jsonb),
  ('supplier_map_groups.header',          '"View suppliers in map"'::jsonb),
  ('supplier_map_groups.legend',          '"Status filters"'::jsonb),
  ('supplier_map_groups.empty_day',       '"No supplier locations for {d}"'::jsonb),
  ('nav.moved_to_fulfill',                '"Moved to Fulfill"'::jsonb)
on conflict (key) do nothing;

-- ── 1. one screen, one tab ─────────────────────────────────────────────────
alter table public.partner_screen_tab
  add column if not exists is_active boolean not null default true;
alter table public.partner_screen_tab
  add column if not exists moved_to_route text;

comment on column public.partner_screen_tab.is_active is
  'CHANGE #754 — false means the tab moved elsewhere. The row is KEPT so the '
  'payload can say the tab is gone: a tab absent from access_boot() is treated '
  'as visible by the app, which is what let Customer Orders survive its move.';
comment on column public.partner_screen_tab.moved_to_route is
  'CHANGE #754 — the route_key (a Fulfill stage) that now owns this screen.';

update public.partner_screen_tab
   set is_active = false, moved_to_route = 'customer_order'
 where screen = 'customer' and tab_key = 'orders';
update public.partner_screen_tab
   set is_active = false, moved_to_route = 'supplier_inquiry'
 where screen = 'supplier' and tab_key = 'inquiry';
update public.partner_screen_tab
   set is_active = false, moved_to_route = 'supplier_order'
 where screen = 'supplier' and tab_key = 'orders';

-- ── access_boot(): tabs carry their own is_active, routes carry their stage ──
create or replace function public.access_boot()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare s jsonb; v_feat jsonb; v_routes jsonb; v_tabs jsonb; v_zone text;
begin
  s := public.access_subject();
  if not (s->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'role','none', 'features','{}'::jsonb,
      'routes','{}'::jsonb, 'tabs','{}'::jsonb,
      'denied_view_message', public._c('access.denied_view'),
      'denied_write_message', public._c('access.denied_write'),
      'readonly_badge', public._c('access.readonly_badge'));
  end if;

  select coalesce(jsonb_object_agg(e.feature_key,
           jsonb_build_object('v', e.can_view, 'w', e.can_write)), '{}'::jsonb)
    into v_feat from public.access_effective(s->>'kind', s->>'id') e;

  select v_feat || coalesce(jsonb_object_agg(fr.feature_key, v_feat -> fr.canonical_key), '{}'::jsonb)
    into v_feat
    from public.feature_registry fr
   where fr.is_active and fr.canonical_key is not null
     and fr.canonical_key <> fr.feature_key
     and v_feat ? fr.canonical_key;

  -- CHANGE #657 — a container route is viewable when its own feature grants
  -- View OR when any tab of the screen it opens does. The OR only ever OPENS a
  -- container; it never grants what is inside it.
  -- CHANGE #754 — a tab that has MOVED can no longer prop its old container
  -- open (`st.is_active`), and every route whose screen now lives in Fulfill
  -- carries `stage`, the fulfill_tab route_key that shares its canonical key.
  -- Derived, so the next screen that moves needs no Dart and no new column.
  select coalesce(jsonb_object_agg(fr.route_key, jsonb_build_object(
           'feature', coalesce(fr.canonical_key, fr.feature_key),
           'label',   fr.label,
           'stage',   coalesce(fs.route_key, ''),
           'v', coalesce((v_feat -> coalesce(fr.canonical_key, fr.feature_key) ->> 'v')::boolean, false)
                or coalesce(tv.any_tab_view, false),
           'w', coalesce((v_feat -> coalesce(fr.canonical_key, fr.feature_key) ->> 'w')::boolean, false))),
         '{}'::jsonb)
    into v_routes
    from public.feature_registry fr
    left join lateral (
      select bool_or(coalesce((v_feat -> public._feature_canon(st.feature_key) ->> 'v')::boolean, false))
               as any_tab_view
        from public.partner_screen_tab st
       where st.screen = fr.tab_screen and st.is_active
    ) tv on fr.tab_screen is not null
    left join lateral (
      select f2.route_key
        from public.feature_registry f2
       where f2.is_active and f2.surface = 'fulfill_tab'
         and coalesce(f2.canonical_key, f2.feature_key)
             = coalesce(fr.canonical_key, fr.feature_key)
       order by f2.sort_order
       limit 1
    ) fs on true
   where fr.is_active and coalesce(fr.route_key,'') <> '';

  -- CHANGE #657 — `index` is partner_screen_tab.tab_index, so a screen
  -- addressed by tab NUMBER gets the number from the same row that grants it.
  -- CHANGE #754 — a moved tab is sent with v/w false and its new home in
  -- `moved_to`. It stays IN the payload on purpose: absence means "visible".
  select coalesce(jsonb_object_agg(t.screen, t.items), '{}'::jsonb) into v_tabs from (
    select st.screen, jsonb_agg(jsonb_build_object(
             'tab_key', st.tab_key, 'label', st.label, 'feature', st.feature_key,
             'index', st.tab_index,
             'active', st.is_active,
             'moved_to', coalesce(st.moved_to_route, ''),
             'v', st.is_active and coalesce((v_feat -> public._feature_canon(st.feature_key) ->> 'v')::boolean, false),
             'w', st.is_active and coalesce((v_feat -> public._feature_canon(st.feature_key) ->> 'w')::boolean, false))
           order by st.sort_order, st.tab_index) items
      from public.partner_screen_tab st group by st.screen) t;

  select z.name into v_zone from public.zones z where z.id = (s->>'zone_id')::smallint;

  return jsonb_build_object(
    'ok', true,
    'role',            s->>'role',
    'is_super',        (s->>'is_super')::boolean,
    'zone_locked',     (s->>'zone_locked')::boolean,
    'zone_id',         s->'zone_id',
    'zone_label',      coalesce(v_zone,''),
    'features',        v_feat,
    'routes',          v_routes,
    'tabs',            v_tabs,
    'denied_view_message',  public._c('access.denied_view'),
    'denied_write_message', public._c('access.denied_write'),
    'readonly_badge',       public._c('access.readonly_badge'));
end
$function$;

-- A moved tab is not the partner console's furniture either.
create or replace function public.partner_screen_tabs(p_screen text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_rows      jsonb;
  v_is_partner boolean := public.is_partner();
  v_role      text := coalesce(public.get_my_role(),'none');
  v_admin     boolean := v_role in ('admin','super_admin') and not v_is_partner;
begin
  -- CHANGE #570 — these tabs are the ADMIN console's furniture. A caller who
  -- is neither an admin nor a partner has no console to draw them in, so the
  -- payload does not carry them. Refusal copy is the backend's own.
  if not (v_admin or v_is_partner) then
    return jsonb_build_object(
      'ok', false, 'screen', p_screen, 'bounded', true, 'tabs', '[]'::jsonb,
      'zone_id', null,
      'message', coalesce(nullif(public._c('partner_tabs.not_yours'), ''),
                          'This screen is not part of your account.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'index', t.tab_index, 'key', t.tab_key,
           'label', t.label, 'feature_key', t.feature_key,
           'access', coalesce(public.partner_access(t.feature_key),'none')
         ) order by t.sort_order), '[]'::jsonb)
    into v_rows
    from public.partner_screen_tab t
   where t.screen = p_screen
     and t.is_active                                   -- CHANGE #754
     and (not v_is_partner
          or coalesce(public.partner_access(t.feature_key),'none') <> 'none');

  return jsonb_build_object(
    'ok', true, 'screen', p_screen,
    'bounded', v_is_partner,
    'tabs', v_rows,
    'zone_id', case when v_is_partner then public.partner_zone_id() end);
end $function$;

create or replace function public.partner_open(p_feature text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_home_copy'),'{}'::jsonb);
  v_acc text; fr record; v_screen text; v_tabs jsonb;
begin
  if public.my_partner_id() is null then
    return jsonb_build_object('ok',false,'error','not_partner',
      'message', coalesce(v_copy->>'not_partner_message',''));
  end if;
  v_acc := public.partner_access(p_feature);
  if v_acc = 'none' then
    perform public.partner_audit(p_feature,'open_denied','{}'::jsonb);
    return jsonb_build_object('ok',false,'error','no_access','access','none',
      'message', coalesce(v_copy->>'denied_message',''));
  end if;
  select * into fr from feature_registry where feature_key = p_feature;
  -- CHANGE #754 — a moved tab never names its old screen again.
  select t.screen into v_screen from public.partner_screen_tab t
   where t.feature_key = p_feature and t.is_active order by t.sort_order limit 1;
  if v_screen is not null then v_tabs := public.partner_screen_tabs(v_screen); end if;
  perform public.partner_audit(p_feature,'open', jsonb_build_object('access',v_acc));
  return jsonb_build_object('ok',true,'access',v_acc,
    'can_write', (v_acc='write'),
    'route_key', coalesce(fr.route_key,''),
    'label', coalesce(fr.label,''),
    'zone_id', public.partner_zone_id(),
    'screen', coalesce(v_screen,''),
    'tabs', coalesce(v_tabs->'tabs','[]'::jsonb),
    'access_label', case v_acc when 'write' then coalesce(v_copy->>'access_write_label','')
                               else coalesce(v_copy->>'access_read_label','') end);
end $function$;

-- ── 2. the AutoFlow / Bundle chips ─────────────────────────────────────────
-- The ⋮ menu that held these toggles sat alone on an otherwise empty row, so
-- the toggles become inline chips. A chip is a label, an on/off word and a
-- tone — all three chosen HERE, from the same app_settings rows the switches
-- already wrote, so the chip renders and computes nothing.
create or replace function public.supplier_toggle_chips()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_auto  boolean;
  v_order boolean;
  v_alloc text;
  v_on    text := public._c('admin_supplier.toggle_on');
  v_off   text := public._c('admin_supplier.toggle_off');
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('access.denied_view'));
  end if;

  select coalesce((value #>> '{}')::boolean, false) into v_auto
    from public.app_settings where key = 'inquiry_auto_meta';
  select coalesce((value #>> '{}')::boolean, false) into v_order
    from public.app_settings where key = 'supplier_order_auto_meta';
  select coalesce(value #>> '{}', 'first_available') into v_alloc
    from public.app_settings where key = 'allocation_mode';

  v_auto  := coalesce(v_auto,  false);
  v_order := coalesce(v_order, false);
  v_alloc := coalesce(v_alloc, 'first_available');

  return jsonb_build_object(
    'ok', true,
    'inquiry', jsonb_build_array(
      jsonb_build_object(
        'key', 'auto_meta',
        'setting_key', 'inquiry_auto_meta',
        'label', public._c('admin_supplier.autoflow'),
        'on', v_auto,
        'state_label', case when v_auto then v_on else v_off end,
        'tone', case when v_auto then 'on' else 'off' end),
      jsonb_build_object(
        'key', 'bundle',
        'setting_key', 'allocation_mode',
        'label', public._c('admin_supplier.bundle'),
        'on', (v_alloc = 'fewest_baskets'),
        'state_label', case when v_alloc = 'fewest_baskets' then v_on else v_off end,
        'tone', case when v_alloc = 'fewest_baskets' then 'on' else 'off' end,
        'action_label', public._c('admin_supplier.re_optimize_bundles'))),
    'order', jsonb_build_array(
      jsonb_build_object(
        'key', 'order_auto_meta',
        'setting_key', 'supplier_order_auto_meta',
        'label', public._c('admin_supplier.autoflow'),
        'on', v_order,
        'state_label', case when v_order then v_on else v_off end,
        'tone', case when v_order then 'on' else 'off' end)),
    'toast_on',  public._c('admin_supplier.auto_meta_toast_on'),
    'toast_off', public._c('admin_supplier.auto_meta_toast_off'));
end $function$;

revoke all on function public.supplier_toggle_chips() from public;
grant execute on function public.supplier_toggle_chips() to authenticated, service_role;

-- ── 3. the Supplier Shop map payload ───────────────────────────────────────
create or replace function public.map_supplier_groups_core(p_date date DEFAULT admin_active_date(), p_badge text DEFAULT NULL::text, p_chip_key text DEFAULT NULL::text, p_chip_complex text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH scope AS (
    SELECT oi.*, (o.created_at AT TIME ZONE 'Asia/Kolkata')::date AS odate
    FROM order_items oi JOIN orders o ON o.id = oi.order_id
    WHERE oi.fulfillment_state NOT IN ('shipped','cancelled')
  ),
  sel AS (SELECT * FROM scope WHERE p_date IS NULL OR odate = p_date),
  agg AS (
    SELECT sel.assigned_supplier,
           COALESCE(m.mode,'shop')              AS mode,
           (m.assigned_supplier IS NOT NULL)    AS forwarded,
           bool_or(coalesce(sel.shop_qty,0) > 0 OR coalesce(sel.received_qty,0) > 0
                   OR coalesce(sel.collect_locked,false) OR coalesce(sel.received_locked,false)) AS any_submitted
    FROM sel
    LEFT JOIN supplier_count_mode m ON m.assigned_supplier = sel.assigned_supplier AND m.mode_date = p_date
    WHERE sel.assigned_supplier IS NOT NULL AND btrim(sel.assigned_supplier) <> ''
    GROUP BY sel.assigned_supplier, m.mode, m.assigned_supplier
  ),
  withso AS (
    SELECT a.* FROM agg a
    WHERE EXISTS (SELECT 1 FROM supplier_orders so
                  WHERE so.supplier_name = a.assigned_supplier
                    AND (p_date IS NULL OR so.order_date = p_date))
  ),
  enr AS (
    SELECT w.assigned_supplier AS supplier, w.any_submitted,
           COALESCE((SELECT bool_or(so.packed) FROM supplier_orders so
                     WHERE so.supplier_name = w.assigned_supplier
                       AND (p_date IS NULL OR so.order_date = p_date)),false) AS is_packed,
           CASE WHEN NOT w.any_submitted THEN 'none'
                WHEN w.mode = 'shop' AND w.forwarded THEN 'shop'
                WHEN w.mode <> 'shop' THEN 'warehouse'
                ELSE 'shop' END AS submit_method,
           sp.street_address, lower(coalesce(sp.street_address,'')) AS lsa,
           sp.lat, sp.lng
    FROM withso w
    LEFT JOIN supplier_profiles sp ON sp.supplier_name = w.assigned_supplier
  ),
  parsed AS (
    SELECT e.*,
      CASE
        WHEN e.lsa ~ 'old\s*medical\s*complex' THEN 'OMC'
        WHEN e.lsa ~ 'new\s*medical\s*complex' THEN 'NMC'
        WHEN e.lsa ~ 'farista'    THEN 'FARISTA'
        WHEN e.lsa ~ 'tarun'      THEN 'TARUN'
        WHEN e.lsa ~ 'sanved'     THEN 'SANVED'
        WHEN e.lsa ~ 'bjp'        THEN 'BJP'
        WHEN e.lsa ~ 'dumartarai' THEN 'DUMARTARAI'
        WHEN e.lsa ~ 'birgao|birgoa' THEN 'BIRGAO'
        ELSE 'OTHER'
      END AS ckey,
      NULLIF((regexp_match(coalesce(e.street_address,''), '([0-9]+)'))[1], '')::int AS shop_no
    FROM enr e
  ),
  labelled AS (
    SELECT p.*,
      CASE ckey
        WHEN 'OMC' THEN 1 WHEN 'NMC' THEN 2 WHEN 'FARISTA' THEN 3 WHEN 'TARUN' THEN 4
        WHEN 'SANVED' THEN 5 WHEN 'BJP' THEN 6 WHEN 'DUMARTARAI' THEN 7 WHEN 'BIRGAO' THEN 8
        ELSE 99 END AS corder,
      CASE ckey
        WHEN 'OMC' THEN 'Old Medical Complex' WHEN 'NMC' THEN 'New Medical Complex'
        WHEN 'FARISTA' THEN 'Farista Complex'  WHEN 'TARUN' THEN 'Tarun CG Complex'
        WHEN 'SANVED' THEN 'Sanved Sikhar Complex' WHEN 'BJP' THEN 'BJP Complex'
        WHEN 'DUMARTARAI' THEN 'Dumartarai' WHEN 'BIRGAO' THEN 'Birgao'
        ELSE 'Other' END AS cname
    FROM parsed p
  ),
  hasman AS ( SELECT DISTINCT complex_key FROM supplier_map_ranges ),
  banded AS (
    SELECT l.*,
      CASE
        WHEN l.shop_no IS NULL THEN jsonb_build_array('__NONE__')
        WHEN EXISTS (SELECT 1 FROM hasman h WHERE h.complex_key = l.ckey) THEN
          COALESCE(
            (SELECT jsonb_agg(coalesce(r.label, r.lo||'-'||r.hi) ORDER BY r.sort_order, r.lo)
               FROM supplier_map_ranges r
              WHERE r.complex_key = l.ckey AND l.shop_no BETWEEN r.lo AND r.hi),
            jsonb_build_array('__OTHER__'))
        ELSE jsonb_build_array((((l.shop_no-1)/10)*10+1)||'-'||(((l.shop_no-1)/10)*10+10))
      END AS chip_keys
    FROM labelled l
  ),
  filt AS (
    SELECT b.*
    FROM banded b
    WHERE
      (p_badge IS NULL OR p_badge = ''
        OR (p_badge='NP' AND NOT b.is_packed)
        OR (p_badge='P'  AND b.is_packed)
        OR (p_badge='NC' AND NOT b.any_submitted)
        OR (p_badge='C'  AND b.any_submitted))
      AND (
        p_chip_key IS NULL OR p_chip_key = ''
        OR b.ckey <> coalesce(p_chip_complex, b.ckey)
        OR b.chip_keys ? p_chip_key
      )
  ),
  suprows AS (
    SELECT f.ckey, f.corder, f.cname, f.shop_no, f.lat, f.lng, f.is_packed, f.supplier,
      jsonb_build_object(
        'supplier',   f.supplier,
        'shop_no',    f.shop_no,
        'shop_label', CASE WHEN f.shop_no IS NULL THEN '—' ELSE f.shop_no::text END,
        'address',    coalesce(f.street_address,''),
        'packed',     f.is_packed,
        'submitted',  f.any_submitted,
        'submit_method', f.submit_method,
        'lat',        f.lat,
        'lng',        f.lng,
        'has_coords', (f.lat IS NOT NULL AND f.lng IS NOT NULL),
        'dot_packed', jsonb_build_object(
          'state', CASE WHEN f.is_packed THEN 'green' ELSE 'yellow' END,
          'fill',  CASE WHEN f.is_packed THEN '#1B7A43' ELSE '#FCD34D' END,
          'border',CASE WHEN f.is_packed THEN '#1B7A43' ELSE '#F59E0B' END)
      ) AS j
    FROM filt f
  ),
  chips_final AS (
    SELECT s.ckey,
      (
        COALESCE(
          (SELECT jsonb_agg(jsonb_build_object('lo',r.lo,'hi',r.hi,'label',coalesce(r.label,r.lo||'-'||r.hi),'key',coalesce(r.label,r.lo||'-'||r.hi)) ORDER BY r.sort_order, r.lo)
             FROM supplier_map_ranges r WHERE r.complex_key = s.ckey),
          (SELECT jsonb_agg(DISTINCT jsonb_build_object('lo',b*10+1,'hi',b*10+10,'label',(b*10+1)||'-'||(b*10+10),'key',(b*10+1)||'-'||(b*10+10))
                    ORDER BY jsonb_build_object('lo',b*10+1,'hi',b*10+10,'label',(b*10+1)||'-'||(b*10+10),'key',(b*10+1)||'-'||(b*10+10)))
             FROM (SELECT ((l2.shop_no-1)/10) b FROM labelled l2 WHERE l2.ckey = s.ckey AND l2.shop_no IS NOT NULL) z),
          '[]'::jsonb
        )
        || CASE WHEN EXISTS (SELECT 1 FROM labelled l3 WHERE l3.ckey = s.ckey AND l3.shop_no IS NOT NULL
                             AND EXISTS (SELECT 1 FROM hasman h WHERE h.complex_key = s.ckey)
                             AND NOT EXISTS (SELECT 1 FROM supplier_map_ranges r2 WHERE r2.complex_key = s.ckey AND l3.shop_no BETWEEN r2.lo AND r2.hi))
                THEN jsonb_build_array(jsonb_build_object('lo',null,'hi',null,'label','Other shops','key','__OTHER__'))
                ELSE '[]'::jsonb END
        || CASE WHEN EXISTS (SELECT 1 FROM labelled l4 WHERE l4.ckey = s.ckey AND l4.shop_no IS NULL)
                THEN jsonb_build_array(jsonb_build_object('lo',null,'hi',null,'label','No shop #','key','__NONE__'))
                ELSE '[]'::jsonb END
      ) AS chip_arr
    FROM (SELECT DISTINCT ckey FROM labelled) s
  ),
  allcomplex AS ( SELECT DISTINCT ckey, corder, cname FROM labelled ),
  groups AS (
    SELECT ac.ckey, ac.corder, ac.cname,
      jsonb_build_object(
        'key',    ac.ckey,
        'name',   ac.cname,
        'order',  ac.corder,
        'count',  (SELECT count(*) FROM suprows s WHERE s.ckey = ac.ckey),
        'header', ac.cname||' ('||(SELECT count(*) FROM suprows s WHERE s.ckey = ac.ckey)||')',
        'chips',  coalesce((SELECT chip_arr FROM chips_final cf WHERE cf.ckey = ac.ckey), '[]'::jsonb),
        'suppliers', coalesce((SELECT jsonb_agg(s.j ORDER BY s.shop_no NULLS LAST, (s.j->>'supplier')) FROM suprows s WHERE s.ckey = ac.ckey), '[]'::jsonb)
      ) AS gj
    FROM allcomplex ac
  ),
  -- map pins: one entry per FILTERED supplier that has coords (packed colour so pin can be coloured)
  points AS (
    SELECT jsonb_agg(jsonb_build_object(
             'supplier', s.supplier,
             'lat', s.lat, 'lng', s.lng,
             'complex', s.ckey,
             'packed', s.is_packed,
             'pin_color', CASE WHEN s.is_packed THEN '#1B7A43' ELSE '#FCD34D' END
           ) ORDER BY s.supplier) AS arr,
           avg(s.lat) AS clat, avg(s.lng) AS clng, count(*) AS npts
    FROM suprows s WHERE s.lat IS NOT NULL AND s.lng IS NOT NULL
  ),
  badges AS (
    SELECT count(*) AS total_s,
      count(*) FILTER (WHERE NOT is_packed)     AS np,
      count(*) FILTER (WHERE is_packed)         AS p,
      count(*) FILTER (WHERE NOT any_submitted) AS nc,
      count(*) FILTER (WHERE any_submitted)     AS c
    FROM labelled
  )
  SELECT jsonb_build_object(
    'status','ok', 'date', p_date,
    'active_badge', p_badge, 'active_chip', p_chip_key, 'active_chip_complex', p_chip_complex,
    'total_suppliers', (SELECT total_s FROM badges),
    -- CHANGE #754 — the header keeps its supplier count, but the words are
    -- ui_copy now, and the tab's two map sizes, its legend heading and its
    -- empty-day sentence all travel in this payload so the Dart panel picks
    -- nothing: it renders a string and a number the backend chose.
    'header_label', public._c('supplier_map_groups.header')||' ('||(SELECT total_s FROM badges)||')',
    'legend_label', public._c('supplier_map_groups.legend'),
    'has_points', ((SELECT npts FROM points) > 0),
    'empty_label', case when (SELECT npts FROM points) > 0 then ''
                        else replace(public._c('supplier_map_groups.empty_day'), '{d}',
                                     to_char(coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date), 'DD/MM/YYYY')) end,
    'map_mini_height', 120,
    'map_full_height', 320,
    'map_points', coalesce((SELECT arr FROM points), '[]'::jsonb),
    'map_center', CASE WHEN (SELECT npts FROM points) > 0
                       THEN jsonb_build_object('lat',(SELECT clat FROM points),'lng',(SELECT clng FROM points))
                       ELSE jsonb_build_object('lat',21.2514,'lng',81.6296) END,  -- Raipur fallback
    'badges', jsonb_build_array(
      jsonb_build_object('key','NP','filter_key','NP','count',(SELECT np FROM badges),
        'text','NP·'||(SELECT np FROM badges)||'S','fill','#FCD34D','fg','#7C4A03','selected', p_badge='NP'),
      jsonb_build_object('key','P','filter_key','P','count',(SELECT p FROM badges),
        'text','P·'||(SELECT p FROM badges)||'S','fill','#1B7A43','fg','#FFFFFF','selected', p_badge='P'),
      jsonb_build_object('key','NC','filter_key','NC','count',(SELECT nc FROM badges),
        'text','NC·'||(SELECT nc FROM badges)||'S','fill','#FCD34D','fg','#7C4A03','selected', p_badge='NC'),
      jsonb_build_object('key','C','filter_key','C','count',(SELECT c FROM badges),
        'text','C·'||(SELECT c FROM badges)||'S','fill','#1B7A43','fg','#FFFFFF','selected', p_badge='C'),
      jsonb_build_object('key','ROUTE','filter_key',null,'count',null,
        'text','Optimize route','fill','#FCD34D','fg','#7C4A03','is_action',true)
    ),
    'groups', coalesce((SELECT jsonb_agg(gj ORDER BY corder, cname) FROM groups), '[]'::jsonb)
  );
$function$

;

-- The zone wrapper filters the points, so the header count, the "any points at
-- all" flag and the empty-day sentence have to be recomputed from what SURVIVED
-- the filter — before #754 the header kept the unzoned count.
create or replace function public.map_supplier_groups(
  p_date date default admin_active_date(),
  p_badge text default null,
  p_chip_key text default null,
  p_chip_complex text default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
DECLARE v jsonb; z smallint := public.admin_active_zone(); g jsonb; n int; pts jsonb; np int;
BEGIN
  v := public.map_supplier_groups_core(p_date, p_badge, p_chip_key, p_chip_complex);
  IF z IS NULL OR v IS NULL THEN RETURN v; END IF;

  SELECT coalesce(jsonb_agg(ng ORDER BY (ng->>'order')::int NULLS LAST), '[]'::jsonb)
    INTO g
  FROM (
    SELECT grp
           || jsonb_build_object(
                'suppliers', fs,
                'count',     jsonb_array_length(fs),
                'header',    coalesce(grp->>'name','') || ' (' || jsonb_array_length(fs) || ')')
           AS ng
    FROM (
      SELECT e AS grp, public.zone_filter_supplier_array(e->'suppliers', z) AS fs
      FROM jsonb_array_elements(coalesce(v->'groups','[]'::jsonb)) e
    ) s
    WHERE jsonb_array_length(s.fs) > 0
  ) t;

  SELECT coalesce(sum(jsonb_array_length(x->'suppliers')),0)::int INTO n
  FROM jsonb_array_elements(g) x;

  pts := public.zone_filter_supplier_array(v->'map_points', z);
  np  := coalesce(jsonb_array_length(pts), 0);

  RETURN v || jsonb_build_object(
    'groups',          g,
    'map_points',      pts,
    'total_suppliers', n,
    -- CHANGE #754 — the count in the header is the count the operator can see.
    'header_label',    public._c('supplier_map_groups.header')||' ('||n||')',
    'has_points',      (np > 0),
    'empty_label',     case when np > 0 then ''
                            else replace(public._c('supplier_map_groups.empty_day'), '{d}',
                                   to_char(coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date), 'DD/MM/YYYY')) end,
    'zone_id', z, 'zone_label', coalesce((SELECT name FROM zones WHERE id=z),''));
END $function$;

-- ── the guard: one screen key, one tab ─────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values (
  'c754_one_screen_one_tab',
$body$
do $c754$
declare v_dup text; v_missing int;
begin
  -- A screen that lives in Fulfill must not ALSO be an active tab of another
  -- screen. This is what let Customer Orders keep showing inside Customers
  -- after it moved: two rows, same feature, two different tab bars.
  select string_agg(d.feature_key || ' @ ' || d.screens, ', ')
    into v_dup
    from (
      select public._feature_canon(st.feature_key) as feature_key,
             string_agg(distinct st.screen, '+') as screens,
             count(distinct st.screen) as n
        from public.partner_screen_tab st
       where st.is_active
       group by 1
      having count(distinct st.screen) > 1
    ) d;
  if v_dup is not null then
    raise exception 'RG_FAIL: a screen is registered under more than one tab bar — %', v_dup;
  end if;

  -- A feature that is an active fulfill_tab stage must not be an active tab
  -- of any other screen either.
  select count(*) into v_missing
    from public.partner_screen_tab st
    join public.feature_registry fr
      on coalesce(fr.canonical_key, fr.feature_key) = public._feature_canon(st.feature_key)
   where st.is_active and fr.is_active and fr.surface = 'fulfill_tab'
     and st.screen <> 'fulfillment';
  if v_missing > 0 then
    raise exception 'RG_FAIL: % tab(s) duplicate a Fulfill stage on another screen', v_missing;
  end if;

  -- And a tab that was retired must say where it went, or the deep link to it
  -- has nowhere to redirect to.
  select count(*) into v_missing
    from public.partner_screen_tab st
   where not st.is_active and coalesce(st.moved_to_route,'') = '';
  if v_missing > 0 then
    raise exception 'RG_FAIL: % retired tab(s) carry no moved_to_route', v_missing;
  end if;

  raise exception 'RG_ROLLBACK';
end $c754$;
$body$,
  true,
  'CHANGE #754 — one screen is registered under one tab bar only.')
on conflict (name) do update
  set body = excluded.body, enabled = excluded.enabled, note = excluded.note;

-- Supabase's default privileges hand every new function an EXPLICIT grant to
-- `anon`, so revoking PUBLIC is not enough: the anon key ships inside the web
-- bundle and the APK. This RPC reads admin settings and already refuses a
-- non-admin, but a tokenless caller has no business reaching it at all.
revoke execute on function public.supplier_toggle_chips() from anon;

-- ORDER OF OPERATIONS (learned the hard way, 2026-09-03).
--
-- These three UPDATEs are the whole visible half of fix 3, and they take effect
-- the instant they land — access_boot() is live, the deployed app already reads
-- `v`, and the duplicate tabs vanished from Customers and Suppliers before a
-- single line of Dart shipped. That is max-backend working exactly as intended,
-- and it is also the trap: the SAME flag is read by the EMBEDDED instances of
-- those screens inside Fulfill, and the build in production had no
-- `widget.embedded` guard yet — so Fulfill -> Customer order would have
-- redirected itself to the Customers list.
--
-- So the rows were put back to is_active=true and re-flipped only after
-- verify_live.sh confirmed the bundle carrying the guard. Re-running this file
-- is safe and idempotent; if it is ever applied ahead of a build that lacks
-- lib/screens/admin/admin_*_screen_web.dart's embedded guard, flip them back:
--   update partner_screen_tab set is_active = true where moved_to_route is not null;

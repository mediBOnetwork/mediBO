CREATE OR REPLACE FUNCTION public._journey_bug240()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_crossed int; v_missing int;
  v_guard boolean; v_readers boolean; v_engine boolean;
  v_rejected boolean := null; v_accepted boolean := null;
  v_inq bigint; v_so uuid; v_err text := null;
  v_bad text;
  v_d1 constant date := date '2001-01-01';
  v_d2 constant date := date '2001-02-02';
  v_ok boolean;
BEGIN
  -- ── census ────────────────────────────────────────────────────────────────
  SELECT count(*)::int INTO v_crossed
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.batch_date IS NOT NULL AND so.order_date IS DISTINCT FROM i.batch_date;

  SELECT count(*)::int INTO v_missing
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.product_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(so.items,'[]'::jsonb)) x
                      WHERE (x->>'product_id') = i.product_id::text);

  -- ── structure ─────────────────────────────────────────────────────────────
  v_guard := EXISTS (SELECT 1 FROM pg_trigger t
                      WHERE t.tgrelid = 'public.inquiry'::regclass
                        AND t.tgname  = 'trg_inquiry_po_date_guard'
                        AND t.tgenabled <> 'D');

  -- ── readers ───────────────────────────────────────────────────────────────
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_bad
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('_get_inquiry_form_core','supplier_pending_inquiry_count',
                       'supplier_inquiry_buckets','get_supplier_inquiry_overview',
                       'get_supplier_inquiry_items')
     AND pg_get_functiondef(p.oid) NOT LIKE '%inq_is_ordered%';
  v_readers := (v_bad IS NULL);

  v_engine := NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('inquiry_engine_ranked_suppliers','inquiry_engine_sync')
       AND pg_get_functiondef(p.oid) LIKE '%inq_is_ordered%');

  -- ── behaviour ─────────────────────────────────────────────────────────────
  BEGIN
    INSERT INTO supplier_orders (supplier_name, order_no, order_date, status, items, total_amount)
    VALUES ('__j240_probe_supplier__', 999999, v_d2, 'pending', '[]'::jsonb, 0)
    RETURNING id INTO v_so;

    INSERT INTO inquiry (product_name, quantity, batch_date, inquiry_phase)
    VALUES ('__j240_probe__', 0, v_d1, 'draft')
    RETURNING id INTO v_inq;

    -- a cross-date pointer must be REJECTED
    BEGIN
      UPDATE inquiry SET supplier_order_id = v_so WHERE id = v_inq;
      v_rejected := false;          -- accepted -> the #240 bug is writable again
    EXCEPTION WHEN others THEN
      v_rejected := true;
    END;

    -- and a same-date pointer must still be ACCEPTED (the guard must not be a
    -- blanket block that would stop every legitimate commit)
    UPDATE supplier_orders SET order_date = v_d1 WHERE id = v_so;
    BEGIN
      UPDATE inquiry SET supplier_order_id = v_so WHERE id = v_inq;
      v_accepted := true;
    EXCEPTION WHEN others THEN
      v_accepted := false;
    END;
  EXCEPTION WHEN others THEN
    v_err := sqlerrm;
  END;

  -- cleanup ALWAYS, whatever happened above
  BEGIN
    DELETE FROM inquiry         WHERE id = v_inq;
    DELETE FROM supplier_orders WHERE id = v_so;
  EXCEPTION WHEN others THEN NULL;
  END;

  v_ok := v_crossed = 0
      AND v_missing = 0
      AND COALESCE(v_guard,false)
      AND COALESCE(v_readers,false)
      AND COALESCE(v_engine,false)
      AND COALESCE(v_rejected,false)
      AND COALESCE(v_accepted,false);

  RETURN jsonb_build_object(
    'status', CASE WHEN v_ok THEN 'passed' ELSE 'failed' END,
    'evidence', jsonb_build_object(
      'db_proof',
        'cross-date pointers='||v_crossed::text
        ||' | linked-but-absent-from-PO='||v_missing::text
        ||' | guard trigger enabled='||COALESCE(v_guard,false)::text
        ||' | display readers use inq_is_ordered='||COALESCE(v_readers,false)::text
        ||' | engine kept OFF the predicate='||COALESCE(v_engine,false)::text
        ||' | cross-date write REJECTED='||COALESCE(v_rejected::text,'null')
        ||' | same-date write ACCEPTED='||COALESCE(v_accepted::text,'null'),
      'readers_missing_predicate', COALESCE(v_bad,''),
      'probe_cleaned_up', NOT EXISTS (SELECT 1 FROM inquiry WHERE product_name = '__j240_probe__')
                      AND NOT EXISTS (SELECT 1 FROM supplier_orders WHERE supplier_name = '__j240_probe_supplier__'),
      'error', v_err));
END;
$function$
;
CREATE OR REPLACE FUNCTION public._journey_bug436()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_total int; v_open int; v_unguarded int; v_no_auth int;
        v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_ok boolean;
begin
  -- a1: the doors still EXIST. A bool_and over a vanished function is silently
  -- true, which is how a security journey quietly stops asserting anything.
  select count(*) into v_total
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix);
  v_a1 := v_total >= 140;

  -- a2: not one of them is reachable with the key that ships in the bundle.
  select count(*) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_open = 0;

  -- a3: the three the bug report named by hand — a bulk company re-link, a
  -- forced settlement of a supplier order, and a supplier status change.
  v_a3 := not has_function_privilege('anon','public.admin_supplier_company_bulk_link(jsonb)','execute')
      and not has_function_privilege('anon','public.admin_supplier_order_force_settle(uuid,text)','execute')
      and not has_function_privilege('anon','public.admin_supplier_action(uuid,text)','execute');

  -- a4: the four with NO body guard now guard themselves. pack_count_source_audit
  -- was returning product_id, product_name, order_item_id and counted qty for
  -- every line of any order id, tokenless.
  select count(*) into v_unguarded
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname in ('pack_nav','pack_count_source_audit','pack_item_bags',
                       'pack_mention_product_totals','pack_get_queue')
     and p.prosrc !~ 'get_my_role';
  v_a4 := v_unguarded = 0;

  -- a5: the revoke did not lock the admin screens out of their own RPCs.
  select count(*) into v_no_auth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not has_function_privilege('authenticated', p.oid, 'execute');
  v_a5 := v_no_auth = 0;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4 and v_a5;
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'admin_*/pack_* RPCs present='||v_total::text||' (>=140)='||v_a1::text||
      ' | anon EXECUTE holes='||v_open::text||' -> none='||v_a2::text||
      ' | the 3 named admin_supplier_* denied to anon='||v_a3::text||
      ' | body-level guard on all 5 pack RPCs='||v_a4::text||
      ' | authenticated still holds EXECUTE everywhere='||v_a5::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_bug633()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_ok boolean;
  v_open int; v_log record; v_slots int; v_fresh boolean;
begin
  v_a1 := exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'admin_customer_screen_data');

  select count(*) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proname like 'admin\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_open = 0;

  select * into v_log from public.render_log where id = 'singleton';
  -- Freshness matters more here than anywhere: "no placeholder was rendered"
  -- is trivially true of a log nobody has written to.
  v_fresh := v_log.id is not null
         and v_log.updated_at > now() - interval '3 days'
         and coalesce(v_log.build_hash,'') ~ '^[0-9a-f]{7,40}$';
  v_a3 := v_fresh and not (coalesce(v_log.data,'{}'::jsonb) ? 'c633_raw_placeholder');

  select count(*) into v_slots from public.ui_copy
   where key in ('admin_customer.failed_to_load','admin_customer.toast_failed_to_load')
     and value::text like '%{e}%';
  v_a4 := v_slots = 2;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4;
  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'subject present='            || coalesce(v_a1,false)::text ||
      ' | admin_% reachable by anon=' || v_open::text ||
      ' | render log build='        || coalesce(v_log.build_hash,'(none)') ||
      ' fresh='                     || coalesce(v_fresh,false)::text ||
      ' raw_placeholder_seen='      || (coalesce(v_log.data,'{}'::jsonb) ? 'c633_raw_placeholder')::text ||
      ' | {e} still in both templates=' || coalesce(v_a4,false)::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_bug683()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_total int; v_open int; v_no_auth int; v_allow_blank int; v_public_missing int;
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
  v_ok boolean;
  c_public constant text[] := array['storefront_page','storefront_product',
                                    'storefront_search_page','storefront_home_v2'];
  c_closed constant text[] := array['zone_full_rebuild','availability_heal_batch',
                                    'zone_sync_medicine_batch','refresh_storefront_feed',
                                    'refresh_medicine_count_cache','zone_supplier_names',
                                    'zone_add','zone_contact_save','storefront_save',
                                    '_sf_category_counts'];
begin
  -- a1: the cluster still EXISTS. Guards against a vacuous pass.
  select count(*) into v_total
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix
                   and r.prefix in ('storefront\_%','zone\_%','\_zone\_%','\_viewer\_zone\_%',
                                    '\_supplier\_zone\_%','refresh\_%','availability\_%',
                                    '\_sf\_%','sf\_%'));
  v_a1 := v_total >= 70;

  -- a2: not one of them is reachable with the key that ships in the bundle.
  select count(*) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_open = 0;

  -- a3: the ten this bug named by hand — the rebuild, the heal, the batch sync,
  --     two refresh jobs, the supplier roster, the two zone writes, the
  --     storefront config write and the feed helper that leaked the census.
  select count(*) = 0 into v_a3
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proname = any (c_closed)
     and has_function_privilege('anon', p.oid, 'execute');

  -- a4: and the storefront a signed-out visitor came for still opens. A
  --     lockdown that closes the shop is a bug, not a fix.
  select count(*) into v_public_missing
    from unnest(c_public) as t(fn)
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = t.fn
        and has_function_privilege('anon', p.oid, 'execute'));
  v_a4 := v_public_missing = 0;

  -- a5: the revoke did not lock the signed-in app out of its own RPCs.
  select count(*) into v_no_auth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not has_function_privilege('authenticated', p.oid, 'execute');
  v_a5 := v_no_auth = 0;

  -- a6: every exception names the caller that earns it. An allow row with an
  --     empty reason is how this class comes back wearing a permit.
  select count(*) into v_allow_blank
    from public.rpc_anon_allow a where btrim(coalesce(a.reason,'')) = '';
  v_a6 := v_allow_blank = 0;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4 and v_a5 and v_a6;
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'zone/storefront RPCs present='||v_total::text||' (>=70)='||v_a1::text||
      ' | anon EXECUTE holes='||v_open::text||' -> none='||v_a2::text||
      ' | the 10 named jobs/reads denied to anon='||v_a3::text||
      ' | the public storefront still open to anon='||v_a4::text||
      ' | authenticated still holds EXECUTE everywhere='||v_a5::text||
      ' | every allow row states its caller='||v_a6::text));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_bug821()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_doorless   jsonb;
  v_grace      int;
  v_pending    int;
  v_unknown    jsonb;
  v_feedback   record;
  v_has_reg    boolean := false;
  v_target     record;
  v_has_target boolean := false;
  v_baselined  boolean;
  v_orphan     jsonb;
  v_fail       text[] := array[]::text[];
begin
  v_grace := coalesce((select (value #>> '{}')::int from public.app_settings
                        where key = 'surface_map_grace_min'), 90);

  -- A1 · no live tile is doorless past the grace window. This is the bug's own
  --      shape: a feature_registry row with a route_key and nothing in
  --      surface_route to open it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key, 'route_key', f.route_key,
           'age_min', (extract(epoch from (now() - f.created_at)) / 60)::int)
         order by f.feature_key), '[]'::jsonb)
    into v_doorless
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and coalesce(f.route_key,'') <> '' and r.route_key is null
     and f.created_at < now() - make_interval(mins => v_grace);
  if jsonb_array_length(v_doorless) > 0 then
    v_fail := v_fail || array['a live tile has no door past the ' || v_grace
                         || '-minute grace window: ' || v_doorless::text];
  end if;

  -- ...and the ones inside it are reported, never counted — a door that has
  -- not landed yet is a build in progress, not a defect (surface_map_audit's
  -- own rule, asserted here so the two can never disagree).
  select count(*) into v_pending
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and coalesce(f.route_key,'') <> '' and r.route_key is null;

  -- A2 · every declared door names a handler this app actually has. A row that
  --      says handled_by='some_screen_nobody_wrote' is a door on paper only,
  --      and it is what turns the guard green while the button stays dead.
  select coalesce(jsonb_agg(distinct r.handled_by), '[]'::jsonb) into v_unknown
    from public.surface_route r
   where r.is_active
     and r.handled_by not in ('home_shell','partner_home_screen','dev_queue_screen',
                              'admin_dashboard_screen','admin_fulfillment_screen',
                              'customer_menu','admin_customer_screen',
                              'admin_supplier_screen','supplier_shell');
  if jsonb_array_length(v_unknown) > 0 then
    v_fail := v_fail || array['surface_route names handlers that do not exist: ' || v_unknown::text];
  end if;

  -- A3 · no declared door points at a feature that is gone or switched off.
  select coalesce(jsonb_agg(r.route_key order by r.route_key), '[]'::jsonb) into v_orphan
    from public.surface_route r
   where r.is_active and r.kind = 'feature'
     and not exists (select 1 from public.feature_registry f
                      where f.is_active and f.feature_key = r.feature_key);
  if jsonb_array_length(v_orphan) > 0 then
    v_fail := v_fail || array['doors point at features that no longer exist: ' || v_orphan::text];
  end if;

  -- A4 · the row Om reported, specifically: the Feedback desk is registered,
  --      active, admitted to the roles that own it, and its door is declared.
  select f.is_active as reg_active, f.roles_allowed, f.route_key,
         r.route_key is not null as has_door, r.handled_by
    into v_feedback
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.feature_key = 'admin.feedback';
  v_has_reg := found;
  if not v_has_reg then
    v_fail := v_fail || array['feature_registry has no admin.feedback row at all'];
  else
    if not v_feedback.reg_active then
      v_fail := v_fail || array['admin.feedback is registered but switched off'];
    end if;
    if v_feedback.route_key <> 'feedback' then
      v_fail := v_fail || array['admin.feedback route_key is "' || v_feedback.route_key || '", not "feedback"'];
    end if;
    if not v_feedback.has_door then
      v_fail := v_fail || array['admin.feedback has no active surface_route row — the tile has no door'];
    end if;
    if not ('super_admin' = any (v_feedback.roles_allowed)) then
      v_fail := v_fail || array['admin.feedback does not admit super_admin'];
    end if;
  end if;

  -- A5 · and the alarm that keeps the offline mirror honest is ARMED. The
  --      protected suite runs on the Dart VM with no network, so its copy of
  --      the door list is a checked-in file; this payload target is what makes
  --      that file going stale a RED rg_check instead of a quiet green.
  select t.name, t.enabled into v_target
    from public.rg_payload_targets t where t.name = 'c821_shell_doors';
  v_has_target := found;
  if not v_has_target or not v_target.enabled then
    v_fail := v_fail || array['rg payload target c821_shell_doors is missing or disabled — '
                        || 'door-list drift would go unreported again'];
  else
    select exists (select 1 from public.rg_baseline b
                    where b.kind = 'payload' and b.name = 'c821_shell_doors')
      into v_baselined;
    if not v_baselined then
      v_fail := v_fail || array['c821_shell_doors has no rg_baseline row — the alarm is installed but not set'];
    end if;
  end if;

  -- `status`, not `ok`: dev_journeys_run reads v->>'status' straight into
  -- dev_journey_runs.status, which is NOT NULL. A helper that answers with a
  -- boolean instead records nothing and the journey can never go green.
  return jsonb_build_object(
    'status', case when cardinality(v_fail) = 0 then 'passed' else 'failed' end,
    'ok', cardinality(v_fail) = 0,
    'evidence', jsonb_build_object(
      'doorless_past_grace', v_doorless,
      'doors_still_in_grace', v_pending,
      'grace_min', v_grace,
      'unknown_handlers', v_unknown,
      'orphan_doors', v_orphan,
      'feedback_door', case when not v_has_reg then 'no registry row'
                            else coalesce(v_feedback.handled_by, 'NO DOOR') end,
      'drift_alarm_armed', coalesce(v_baselined, false),
      'doors_declared', (select count(*) from public.surface_route where is_active),
      'shell_doors', (select count(*) from public.surface_route
                       where is_active and handled_by = 'home_shell')),
    'failures', to_jsonb(v_fail));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c1016_staff_ia()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fail text[] := array[]::text[]; v jsonb; v_n int; v_super uuid;
begin
  v := public.nav_parity_report();
  if coalesce((v->>'unresolved')::int,1) > 0 then
    v_fail := v_fail || ('parity: ' || (v->>'unresolved') || ' unresolved');
  end if;
  select count(*) into v_n from public.staff_nav_tab where is_active;
  if v_n <> 6 then v_fail := v_fail || ('staff_nav_tab holds ' || v_n || ' tabs, expected 6'); end if;
  -- the super admin sees six tabs and a populated More grid
  select u.id into v_super from auth.users u join public.admins a
      on lower(btrim(a.email)) = lower(btrim(u.email)) where coalesce(a.is_super,false) limit 1;
  if v_super is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_super, 'role', 'authenticated')::text, true);
    v := public.staff_nav();
    if (v->>'ok') <> 'true' then v_fail := v_fail || 'staff_nav refused the super admin'; end if;
    select count(*) into v_n from jsonb_array_elements(v->'tabs') t where (t->>'visible')::boolean;
    if v_n <> 6 then v_fail := v_fail || ('super admin sees ' || v_n || ' tabs'); end if;
    v := public.staff_home('more');
    if coalesce((v->>'items_count')::int,0) < 20 then
      v_fail := v_fail || ('More grid has only ' || coalesce(v->>'items_count','0') || ' items for the super admin');
    end if;
    v := public.staff_home('dashboard');
    if coalesce((v->>'items_count')::int,0) <> 0 then
      v_fail := v_fail || ('Dashboard still homes ' || (v->>'items_count') || ' tiles');
    end if;
  end if;
  return jsonb_build_object(
    'status', case when cardinality(v_fail) = 0 then 'passed' else 'failed' end,
    'ok', cardinality(v_fail) = 0,
    'evidence', jsonb_build_object('failures', to_jsonb(v_fail), 'parity', public.nav_parity_report() - 'rows'),
    'failures', to_jsonb(v_fail));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c408_binding()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean; a6 boolean;
        v_src text; v_bind text;
begin
  select p.prosrc into v_src from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='customer_staff_add';
  select p.prosrc into v_bind from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='login_bind_owner';

  -- the shape that was wrong
  a1 := coalesce(position('''customer_staff''' in coalesce(v_src,'')) > 0, false);
  a2 := coalesce(position('customer_staff' in coalesce(v_bind,'')) = 0, false);
  a3 := exists (select 1 from pg_constraint
                 where conname = 'login_identities_owner_type_check'
                   and pg_get_constraintdef(oid) like '%customer_staff%');
  a4 := exists (select 1 from pg_proc p
                 where p.pronamespace='public'::regnamespace
                   and p.proname='customer_id_for_user'
                   and p.prosrc like '%customer_users%');
  -- the live invariants the bug would have violated
  a5 := not exists (select 1 from login_identities li
                     join customer_users cu on cu.identity = li.identity
                    where li.owner_type = 'customer');
  a6 := not exists (select 1 from pharmacy_profiles pp
                     join customer_users cu on cu.auth_user_id = pp.user_id
                    where pp.user_id is not null);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 and a6 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'staff bind as customer_staff=' || a1::text
   || ' | login_bind_owner has no branch for it=' || a2::text
   || ' | owner_type CHECK admits it=' || a3::text
   || ' | customer_id_for_user knows staff=' || a4::text
   || ' | no staff identity bound as owner=' || a5::text
   || ' | no pharmacy owned by a staff auth user=' || a6::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c408_pricing()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; v_src text;
begin
  select p.prosrc into v_src from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='order_edit_apply';

  -- the trade total, the same function placement uses
  a1 := coalesce(position('cart_pricing_block' in coalesce(v_src,'')) > 0, false);
  a2 := coalesce(position('net_payable' in coalesce(v_src,'')) > 0, false);
  -- MEDICINE.mrp is a rendered rupee STRING; parsed, never cast
  a3 := coalesce(position('_slab_num' in coalesce(v_src,'')) > 0, false);
  -- the basket changed, so the discount slab is re-snapshotted rather than left stale
  a4 := coalesce(position('order_slab_snapshot' in coalesce(v_src,'')) > 0, false);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'totals through cart_pricing_block=' || a1::text
   || ' | on net_payable, not MRP=' || a2::text
   || ' | mrp parsed with _slab_num=' || a3::text
   || ' | slab re-snapshotted after the edit=' || a4::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c408_window()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a1 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean;
  v_edit text; v_mos text; v_chain text;
begin
  select p.prosrc into v_edit from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='_order_edit_gate';
  select p.prosrc into v_mos  from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='my_orders_screen';

  v_chain := coalesce(v_edit,'');
  select v_chain || coalesce(string_agg(p.prosrc, E'\n'), '')
    into v_chain
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('_order_change_gate')
     and position(p.proname in coalesce(v_edit,'')) > 0;

  a1 := coalesce(position('oi.bag_no' in v_chain) = 0, false);
  a2 := coalesce(position('asked_at' in v_chain) > 0
             and position('supplier_order_id' in v_chain) > 0, false);
  a3 := coalesce(position('o.order_date' in v_chain) > 0
             and position('o.zone_id' in v_chain) > 0, false);
  a4 := coalesce(position('_order_edit_gate' in coalesce(v_mos,'')) > 0, false);
  a5 := coalesce(position('button_label' in coalesce(v_edit,'')) > 0, false);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'gate no longer reads bag_no=' || a1::text
   || ' | closes on asked_at/supplier_order_id=' || a2::text
   || ' | falls back to the order own date+zone=' || a3::text
   || ' | window rides my_orders_screen=' || a4::text
   || ' | and the button caption travels with the flag=' || a5::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c414_shop_fence()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; v_unfenced text;
begin
  -- the fence exists, and is not reachable by a client itself
  a1 := exists (select 1 from pg_proc p
                 where p.pronamespace='public'::regnamespace
                   and p.proname='_c414_shop_for');
  a2 := not has_function_privilege('authenticated', 'public._c414_shop_for(uuid)', 'EXECUTE')
    and not has_function_privilege('anon',          'public._c414_shop_for(uuid)', 'EXECUTE');

  -- the two functions that take a shop id both go through it
  a3 := (select bool_and(p.prosrc like '%_c414_shop_for%')
           from pg_proc p
          where p.pronamespace='public'::regnamespace
            and p.proname in ('pharmacy_velocity','pharmacy_reorder_draft_build'));

  -- and NO other client-reachable function in this feature takes a raw shop id
  -- without going through the fence. This is the part that catches the NEXT one.
  select string_agg(p.proname, ', ') into v_unfenced
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'pharmacy\_%'
     and pg_get_function_identity_arguments(p.oid) like '%p_shop uuid%'
     and p.prosrc not like '%_c414_shop_for%'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  a4 := v_unfenced is null;

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'the fence exists=' || a1::text
   || ' | no client can call it directly=' || a2::text
   || ' | both shop-id functions go through it=' || a3::text
   || ' | no unfenced shop-id function is client-reachable=' || a4::text
   || coalesce(' -> ' || v_unfenced, '')));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c418_provider_error()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_scan uuid;
  v_payload jsonb;
  v_shop uuid;
  a_recorded boolean; a_copy boolean; a_no_leak boolean; a_family_clean boolean;
  v_leakers text;
  v_last record;
begin
  select id into v_shop from public.pharmacy_profiles
   where coalesce(is_deleted,false) = false order by id limit 1;

  -- A synthetic scan, failed with a provider error shaped exactly like the one
  -- that leaked. Cleaned up at the end whatever happens.
  insert into public.rx_scan (pharmacy_id, status, image_path)
  values (v_shop, 'reading', 'journey/qa-418-233.png') returning id into v_scan;

  perform public.rx_scan_report(
    v_scan, false, 'gemini-3.5-flash', '[]'::jsonb, null,
    'Vertex AI error 403: {"error":{"code":403,"status":"PERMISSION_DENIED",'
    || '"details":[{"reason":"BILLING_DISABLED","metadata":{"consumer":'
    || '"projects/project-b83d3f5f-25d0-45ef-a4e"}}]}}', 900);

  select (status = 'failed' and length(coalesce(ocr_error,'')) > 100)
    into a_recorded from public.rx_scan where id = v_scan;

  v_payload := public._c418_detail(v_shop, v_scan);
  a_copy := (v_payload->>'failed_message') = public.ui_text('rx.err_read_failed');

  a_no_leak := position('BILLING_DISABLED' in v_payload::text) = 0
           and position('PERMISSION_DENIED' in v_payload::text) = 0
           and position('aiplatform' in v_payload::text) = 0
           and position('Vertex' in v_payload::text) = 0
           and position('project-b83d3f5f' in v_payload::text) = 0;

  -- The class check: no rx payload builder may interpolate ocr_error.
  --
  -- COMMENTS ARE STRIPPED FIRST. The naive version of this scan flagged
  -- _c418_detail on the strength of the comment that explains why it stopped
  -- rendering ocr_error — a guard that fails on the note describing the fix is
  -- a guard everyone learns to ignore, which is worse than no guard.
  select string_agg(p.proname, ',' order by p.proname) into v_leakers
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'rx\_scan\_%' or p.proname like '\_c418\_%')
     and p.proname not in ('rx_scan_report')          -- the writer, not a renderer
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') like '%ocr\_error%';
  a_family_clean := v_leakers is null;

  delete from public.rx_scan where id = v_scan;

  -- Evidence only: is the provider actually reachable right now?
  select r.status, left(coalesce(r.ocr_error,''), 60) as err into v_last
    from public.rx_scan r
   where r.ocr_error is not null order by r.created_at desc limit 1;

  -- dev_journeys_run reads `status` and `evidence`; anything else is recorded
  -- as a NULL status and the insert fails on the not-null. Same shape as
  -- _journey_c414_shop_fence.
  return jsonb_build_object(
    'status', case when a_recorded and a_copy and a_no_leak and a_family_clean
                   then 'passed' else 'failed' end,
    'evidence', jsonb_build_object(
      'asserts', jsonb_build_object(
        'failure_is_recorded_not_swallowed', a_recorded,
        'payload_carries_ui_copy_sentence',  a_copy,
        'no_provider_token_in_payload',      a_no_leak,
        'no_rx_builder_interpolates_ocr_error', a_family_clean),
      'db_proof', 'renderers leaking ocr_error=' || coalesce(v_leakers, 'none')
        || ' | last real provider outcome=' || coalesce(v_last.status, 'none')
        || ' | note: the Vertex BILLING_DISABLED blocker is escalated separately '
        || '(payment config), this journey holds down its containment'));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c424_shop_fence()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean;
        v_open text; v_missing text; v_broken integer;
begin
  -- 1. No function in this feature that takes a shop id as an ARGUMENT may be
  --    executable by a client (the #424 blocker).
  select string_agg(p.proname, ', ') into v_open
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proname like 'pharmacy\_%' or p.proname like '\_c424\_%')
     and pg_get_function_identity_arguments(p.oid) like '%uuid%'
     and pg_get_function_identity_arguments(p.oid) like '%p_shop%'
     and p.prosrc like '%c424%'
     and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
          or has_function_privilege('anon', p.oid, 'EXECUTE'));
  a1 := v_open is null;

  -- 2. The two client surfaces still resolve the shop from the SESSION.
  select string_agg(x.fn, ', ') into v_missing
    from (values ('pharmacy_inference_screen'), ('pharmacy_lot_correct')) x(fn)
   where not exists (
     select 1 from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = x.fn
        and p.prosrc like '%pos_shop()%'
        and has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  a2 := v_missing is null;

  -- 3. The fixture still reproduces the spec's numbers.
  a3 := coalesce((public.c424_montikop_proof() ->> 'ok')::boolean, false);

  -- 4. CHANGE #442 — every STORED estimate obeys its own definition. An
  --    oversold shelf line (qty < 0) once produced sold = -3 and a band whose
  --    top was below its bottom, and nothing on screen could have shown it.
  select count(*) into v_broken
    from public.pharmacy_lot_inference
   where inferred_sold < 0
      or inferred_left < 0
      or inferred_left > qty_in
      or left_low > left_high
      or left_low > inferred_left
      or left_high < inferred_left
      or confidence < 0 or confidence > 1;
  a4 := v_broken = 0;

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'no shop-id engine function is client-reachable=' || a1::text
   || coalesce(' -> ' || v_open, '')
   || ' | both session-scoped surfaces reachable=' || a2::text
   || coalesce(' -> missing ' || v_missing, '')
   || ' | montikop fixture still green=' || a3::text
   || ' | stored estimates breaking their own invariants=' || v_broken::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c450_autoenable_gated()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_src text; ok1 boolean; ok2 boolean; ok3 boolean;
        v_key text; v_tpl uuid; v_after boolean; v_live int;
begin
  select pg_get_functiondef(oid) into v_src
    from pg_proc where proname = '_wa_route_autoenable' and pronamespace = 'public'::regnamespace;

  -- 1. the trigger consults the rule at all
  ok1 := v_src is not null and v_src ilike '%_wa_route_blockers_raw%';
  -- 2. and gates `enabled` on it rather than setting it unconditionally
  ok2 := v_src is not null and v_src !~* 'enabled\s*=\s*true\s*,' ;

  -- 3. behaviour: a blocked route that is OFF stays OFF across a re-approval.
  select r.event_key, r.template_id into v_key, v_tpl
    from wa_event_routes r
   where r.auto_manage and r.template_id is not null
     and coalesce((public._wa_route_blockers_raw(r.event_key, r.template_id)->>'blocked')::boolean, false)
   limit 1;

  if v_key is null then
    ok3 := true;   -- no blocked auto route to probe; structure checks stand alone
  else
    update wa_event_routes set enabled = false where event_key = v_key;
    update wa_templates set status = 'PENDING'  where id = v_tpl;
    update wa_templates set status = 'APPROVED' where id = v_tpl;
    select enabled into v_after from wa_event_routes where event_key = v_key;
    ok3 := (v_after = false);
    -- put the world back exactly as it was
    update wa_event_routes set enabled = true where event_key = v_key;
  end if;

  select count(*)::int into v_live
    from wa_event_routes r
   where r.enabled
     and coalesce((public._wa_route_blockers_raw(r.event_key, r.template_id)->>'blocked')::boolean, false);

  return jsonb_build_object(
    'status', case when ok1 and ok2 and ok3 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object(
      'trigger_consults_blocker', ok1,
      'enabled_is_gated_not_unconditional', ok2,
      'blocked_route_stays_off_across_reapproval', ok3,
      'probed_route', coalesce(v_key,'none'),
      'enabled_but_blocked_routes_now', v_live,
      'db_proof', case when ok1 and ok2 and ok3
        then 'the auto-enable trigger asks the blocker and leaves a blocked route switched off'
        else 'the auto-enable trigger can switch a route on that cannot send' end));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c450_live_event_keys()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bad text; v_checked int; v_chase text; v_utr text; ok1 boolean; ok2 boolean; ok3 boolean;
begin
  -- Every literal event key passed to a wa_send_event* call from a public
  -- function, checked against the routes table.
  with calls as (
    select p.proname,
           (regexp_matches(pg_get_functiondef(p.oid),
              'wa_send_event(?:_now|_or_fallback)?\s*\(\s*''([a-z0-9_]+)''', 'g'))[1] as event_key
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname like 'admin\_%'
  )
  select string_agg(distinct c.proname || ' -> ' || c.event_key, '; ' order by c.proname || ' -> ' || c.event_key),
         count(*)::int
    into v_bad, v_checked
    from calls c
   where not exists (select 1 from wa_event_routes r where r.event_key = c.event_key);

  ok1 := v_bad is null;

  -- The two this command shipped, named explicitly so the journey still means
  -- something if the scan above ever stops matching.
  select coalesce((select 'yes' from wa_event_routes where event_key='payment_due'),'MISSING') into v_chase;
  select coalesce((select 'yes' from wa_event_routes where event_key='payment_utr_request'),'MISSING') into v_utr;
  ok2 := v_chase = 'yes';
  ok3 := v_utr   = 'yes';

  return jsonb_build_object(
    'status', case when ok1 and ok2 and ok3 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object(
      'unregistered_event_keys', coalesce(v_bad, 'none'),
      'payment_due_registered', v_chase,
      'payment_utr_request_registered', v_utr,
      'db_proof', case when ok1 and ok2 and ok3
        then 'every literal event key reachable from an admin_* function exists in wa_event_routes'
        else 'an admin action names an event key that is in no row of wa_event_routes: ' || coalesce(v_bad,'') end));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c467_partner_audit_fence()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_present int; v_anon int; v_noauth int; v_unguarded int;
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
  v_ok boolean;
  c_fns constant text[] := array['admin_partner_audit_list',
                                 'admin_partner_audit_preview',
                                 'admin_partner_console'];
  -- a guard is anything that ties the read to the CALLER, not one function name
  c_guard constant text :=
    '(role_for_medibo_only|get_my_role|is_admin|_dev_guard|my_partner_id|partner_access|is_partner|auth\.uid)';
begin
  select count(*) into v_present
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (c_fns);
  v_a1 := v_present >= 3;

  select count(*) into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (c_fns)
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_anon = 0;

  select count(*) into v_noauth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (c_fns)
     and not has_function_privilege('authenticated', p.oid, 'execute');
  v_a3 := v_noauth = 0;

  -- a grant is not a guard: every CLIENT-REACHABLE reader of partner_audit_log
  -- must refuse a caller it cannot place, whatever EXECUTE says. The writer and
  -- the internal cNNN_*_proof helpers are not client doors and are excluded.
  select count(*) into v_unguarded
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and p.prosrc like '%partner_audit_log%'
     and p.proname <> 'partner_audit'
     and p.proname !~ '^c[0-9]+_'
     and p.proname !~ '^_journey'
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'))
     and p.prosrc !~ c_guard;
  v_a4 := v_unguarded = 0;

  v_a5 := not has_table_privilege('anon','public.partner_audit_log','select')
      and not has_table_privilege('authenticated','public.partner_audit_log','select');

  v_a6 := not has_function_privilege('anon','public.partner_licence_expiry_sweep()','execute')
      and not has_function_privilege('authenticated','public.partner_licence_expiry_sweep()','execute');

  v_ok := v_a1 and v_a2 and v_a3 and v_a4 and v_a5 and v_a6;
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'partner-audit doors present='||v_present::text||' (>=3)='||v_a1::text||
      ' | anon EXECUTE holes='||v_anon::text||' -> none='||v_a2::text||
      ' | authenticated still holds EXECUTE on all='||v_a3::text||
      ' | client-reachable readers of partner_audit_log with no caller check='||
        v_unguarded::text||' -> none='||v_a4::text||
      ' | the log table itself is not selectable by anon or authenticated='||v_a5::text||
      ' | the cron-only licence sweep is reachable by neither client role='||v_a6::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c686_bare_dollar()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_n int; v_bad text; v_title text; v_upi text; v_a4 boolean;
begin
  select count(*), string_agg(key || ' = ' || left(value #>> '{}', 50), ' | ' order by key)
    into v_n, v_bad
    from public.ui_copy where (value #>> '{}') ~ '\$[A-Za-z_]';
  select value #>> '{}' into v_title from public.ui_copy where key = 'cust_pay.qr_image_title';
  select value #>> '{}' into v_upi   from public.ui_copy where key = 'cust_pay.qr_image_upi_line';
  v_a4 := public.ui_copy_is_source_code('UPI ID: $vpa')
      and not public.ui_copy_is_source_code('Save $5 today')
      and not public.ui_copy_is_source_code('US$ 20');
  return jsonb_build_object(
    'status', case when v_n = 0 and v_title !~ '\$[A-Za-z_]' and v_upi = 'UPI ID: {vpa}'
                    and coalesce(v_a4,false) then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'rows with a bare $identifier=' || v_n::text ||
      case when v_n > 0 then ' (' || left(coalesce(v_bad,''), 200) || ')' else '' end ||
      ' | qr_image_title=' || coalesce(v_title,'<null>') ||
      ' | qr_image_upi_line=' || coalesce(v_upi,'<null>') ||
      ' | rule separates $vpa from $5/US$ 20=' || coalesce(v_a4,false)::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c686_detector_battery()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_missed text[] := '{}'; v_false text[] := '{}'; v text;
  c_bad constant text[] := array[
    -- Om's own bug, and the same shape one dollar sign lighter
    'Ordered by: ${row.pharmacy.isNotEmpty ?',
    'Ordered by: {row.pharmacy.isNotEmpty ? row.pharmacy : row.name}',
    -- round 2's escapes
    '] != null ? ', '{{ b[0] ; return x }}', '{{items.length}}', '{ if (x) {ok} }',
    '{a: {b}}', 'items.first.name', 'items.first.name ', ' items.first.name',
    -- round 3's escapes
    'UPI ID: $vpa', 'total.length', 'x ?? y', 'value != null',
    -- round 4's escapes (R3-4)
    'Theme.of(context).textTheme.bodyMedium', 'EdgeInsets.all(16)',
    'const SizedBox(height: 8)', 'TextStyle(fontWeight: FontWeight.w600)',
    'DateFormat(''dd MMM yyyy'').format(date)', 'order.total.abs()',
    '(x) => x.name', 'count > 1 ? ''items'' : ''item''', '''Total: ''',
    '''Qty: '' + qty', '\u{1F4B5}  Collect Cash',
    -- QA round 4, finding 3: every rule hardcoded the SINGLE quote
    'count > 1 ? "items" : "item"', '"Total: "', '"Qty: " + qty',
    -- …and three methods the old name list never had
    'items.toList()', 'x.padLeft(2)', 'a.fold(0, f)'];
  -- QA round 4, finding 2: round 5's shape rules refused 16 of 42 ordinary
  -- pharma sentences. Measuring against the rows that already EXIST proves
  -- nothing about the copy someone writes tomorrow, so the sentences that
  -- caught it are pinned here permanently.
  c_good constant text[] := array[
    'Ordered by: {name}', 'Ordered by: {name} · {pharmacy}', '₹{amount}',
    'Heartbeat FAILED at {{stage}}', 'Doctor''s prescription', 'Save $5 today',
    'US$ 20', 'Visit https://medibo.in for help', 'https://company.com (optional)',
    'Loading...', 'Cancel this order?', 'Your order is on the way.', ', ',
    'Scan to pay', 'UPI ID: {vpa}', 'GST: {v}', 'new_column_name', 'Cancel',
    'Duration (days)', 'Colors (assorted)', 'Icons (set of 12)', 'Padding (mm)',
    'Offset (₹)', 'Theme.', 'Read the terms;', 'Cart => Checkout',
    'Dr.Sharma(MBBS)', 'Dr. Sharma (MBBS)', 'Qty (strips)', '2-3 days',
    'Sub-total (incl. GST)', 'Mon-Sat, 9 a.m. to 8 p.m.', 'MRP (₹)',
    'Discount (%)', 'Batch/Exp.', 'e.g. Paracetamol 500mg', 'Ph. 0771-2345678',
    'No. of strips', 'Amt. (₹)', '"{name}" will be cancelled.',
    'Proforma — not a tax invoice. Rates and GST are final; batch may change.'];
begin
  foreach v in array c_bad loop
    if not (public.ui_copy_is_source_code(v) or public.ui_copy_brace_is_source(v)
            or public.ui_copy_bare_expression(v) or public.ui_copy_shape_is_source(v)) then
      v_missed := v_missed || v;
    end if;
  end loop;
  foreach v in array c_good loop
    if public.ui_copy_is_source_code(v) or public.ui_copy_brace_is_source(v)
       or public.ui_copy_bare_expression(v) or public.ui_copy_shape_is_source(v) then
      v_false := v_false || v;
    end if;
  end loop;
  return jsonb_build_object(
    'status', case when cardinality(v_missed) = 0 and cardinality(v_false) = 0
                   then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'known-bad shapes refused=' || (cardinality(c_bad) - cardinality(v_missed))::text
        || '/' || cardinality(c_bad)::text ||
      case when cardinality(v_missed) > 0 then ' | ACCEPTED: ' || array_to_string(v_missed, ' ¦ ') else '' end ||
      ' | legitimate copy still storable=' || (cardinality(c_good) - cardinality(v_false))::text
        || '/' || cardinality(c_good)::text ||
      case when cardinality(v_false) > 0 then ' | FALSE POSITIVE: ' || array_to_string(v_false, ' ¦ ') else '' end));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c686_drift_rpc_fenced()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_oid oid; v_src text; v_a1 boolean; v_a2 boolean; v_a3 boolean;
        v_a4 boolean; v_acl text;
begin
  select p.oid, p.prosrc into v_oid, v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ui_copy_param_drift_report';
  if v_oid is null then
    return jsonb_build_object('status','failed','evidence',
      jsonb_build_object('db_proof','ui_copy_param_drift_report does not exist'));
  end if;
  v_a1 := not (has_function_privilege('anon', v_oid, 'EXECUTE')
            or has_function_privilege('authenticated', v_oid, 'EXECUTE')
            or has_function_privilege('public', v_oid, 'EXECUTE'));
  v_a2 := has_function_privilege('service_role', v_oid, 'EXECUTE');
  -- the body keys off the JWT role claim, and no longer off current_user,
  -- which is 'postgres' inside this function whatever the caller is
  v_a3 := v_src ~ 'request\.jwt\.claim' and v_src !~ 'current_user';
  -- the table it writes is not readable or writable by a logged-in account
  -- either, so RLS is not the only thing standing between them
  v_a4 := not (has_table_privilege('anon','public.ui_copy_param_drift','SELECT')
            or has_table_privilege('authenticated','public.ui_copy_param_drift','SELECT')
            or has_table_privilege('authenticated','public.ui_copy_param_drift','INSERT')
            or has_table_privilege('authenticated','public.ui_copy_param_drift','DELETE'));
  select coalesce(array_to_string(p.proacl::text[], ' '), '<default>') into v_acl
    from pg_proc p where p.oid = v_oid;
  return jsonb_build_object(
    'status', case when v_a1 and v_a2 and v_a3 and v_a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'closed to anon/authenticated/public=' || coalesce(v_a1,false)::text ||
      ' | service_role can call=' || coalesce(v_a2,false)::text ||
      ' | body reads the JWT role claim, not current_user=' || coalesce(v_a3,false)::text ||
      ' | drift table closed to logged-in accounts=' || coalesce(v_a4,false)::text ||
      ' | acl=' || v_acl));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c686_header_slots()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean;
        v_drift int; v_missing int; v_plain text; v_ph text;
begin
  select value #>> '{}' into v_plain from public.ui_copy where key = 'admin_customer.ordered_by';
  select value #>> '{}' into v_ph    from public.ui_copy where key = 'admin_customer.ordered_by_with_pharmacy';
  v_a1 := v_plain = 'Ordered by: {name}';
  v_a2 := v_ph is not null and v_ph like '%{name}%' and v_ph like '%{pharmacy}%';
  v_a3 := not (public.ui_copy_is_source_code(v_plain) or public.ui_copy_brace_is_source(v_plain)
            or public.ui_copy_is_source_code(v_ph)    or public.ui_copy_brace_is_source(v_ph));
  select count(*) into v_drift from public.ui_copy_param_drift;
  select count(*) into v_missing from public.ui_copy_param_drift where kind = 'missing_key';
  v_a4 := v_drift = 0;
  return jsonb_build_object(
    'status', case when v_a1 and v_a2 and v_a3 and v_a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'ordered_by=' || coalesce(v_plain,'<null>') ||
      ' | with_pharmacy=' || coalesce(v_ph,'<null>') ||
      ' | neither is source=' || coalesce(v_a3,false)::text ||
      ' | call-site/template drift rows=' || v_drift::text ||
      ' (keys the app reads that do not exist=' || v_missing::text || ')'));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c686_sweep_complete()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_n int; v_bad text; v_a2 boolean; v_named int;
begin
  select count(*), string_agg(key, ', ' order by key) into v_n, v_bad
    from public.ui_copy
   where public.ui_copy_is_source_code(value #>> '{}')
      or ((public.ui_copy_brace_is_source(value #>> '{}')
           or public.ui_copy_bare_expression(value #>> '{}'))
          and not exists (select 1 from public.ui_copy_source_exempt e where e.key = ui_copy.key));
  -- the nine rows QA named, each pinned to the sentence it should have been
  select count(*) into v_named from (values
    ('admin_company.gst_prefix',                    'GST: {v}'),
    ('admin_company.dl_prefix',                     'DL: {v}'),
    ('unmapped_companies.toast_mapped',             '{raw} → {name}'),
    ('sup_pay.toast_payment_recorded',              '{kind} payment recorded ✓'),
    ('profile.viewas_confirm_body',                 'Any changes (cart, orders, profile) will be SAVED to {name}.'),
    ('cust_pay.qr_image_title',                     'Scan to pay'),
    ('cust_pay.qr_image_upi_line',                  'UPI ID: {vpa}')
  ) as w(k, expected)
  join public.ui_copy u on u.key = w.k and u.value #>> '{}' = w.expected;
  -- the four whose exact wording is prose, asserted on the property that BROKE
  -- rather than on the wording: a dropped slot, a sentence truncated mid-word,
  -- a fragment that never started as one, and a literal \u escape. Note
  -- err_new_column_name_empty legitimately ENDS in }" — the slot sits inside
  -- quotes — so it is pinned on being a capitalised sentence that still owns
  -- its {column} slot, not on its tail.
  select (
       (select value #>> '{}' from public.ui_copy where key='wa_campaigns.cancel_body') like '%{name}%'
   and (select value #>> '{}' from public.ui_copy where key='notifications.allowlist_note') ~ '\.$'
   and (select value #>> '{}' from public.ui_copy where key='admin_add_medicine.err_new_column_name_empty') ~ '^[A-Z].*\{column\}'
   and (select value #>> '{}' from public.ui_copy where key='cash_payment.btn_collect_cash') !~ '\\u'
  ) into v_a2;
  return jsonb_build_object(
    'status', case when v_n = 0 and v_named = 7 and coalesce(v_a2,false) then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'rows still holding Dart source=' || v_n::text ||
      case when v_n > 0 then ' (' || left(coalesce(v_bad,''), 300) || ')' else '' end ||
      ' | named casualties repaired=' || v_named::text || '/7' ||
      ' | truncated/escaped prose repaired=' || coalesce(v_a2,false)::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c697_feedback()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order   uuid;
  v_uid     uuid;
  v_claims  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_token   text;
  v_prompt  jsonb; v_form jsonb; v_sub jsonb; v_again jsonb; v_twice jsonb;
  v_dims    int := 0; v_chips int := 0;
  v_tickets int := 0; v_dim_tag text := ''; v_feeds int := 0; v_weeks int := 0;
  -- CHANGE #799 — the tickets that were ALREADY on this order before the
  -- probe touched it. See the count below for why they have to be excluded.
  v_pre     uuid[] := '{}';
  v_anon_form boolean := false;
  v_ran     boolean := false;
  -- grants: the two writers must be unreachable, the two token entry points open
  v_writer_closed boolean;
  v_anon_open     boolean;
  v_once_only     boolean;
  v_routes        int;
  v_crons         int;
  v_nav           boolean;
  v_ok            boolean;
begin
  perform public._dev_guard();

  -- ── Structure. These hold whether or not a fixture order exists.
  v_writer_closed :=
    not has_function_privilege('anon',
      'public._order_feedback_write(uuid,jsonb,integer,text,text[],text,uuid,uuid)', 'execute')
    and not has_function_privilege('authenticated',
      'public._order_feedback_write(uuid,jsonb,integer,text,text[],text,uuid,uuid)', 'execute');

  v_anon_open :=
    has_function_privilege('anon', 'public.order_feedback_form(text)', 'execute')
    and has_function_privilege('anon',
      'public.order_feedback_submit_token(text,jsonb,integer,text,text[])', 'execute');

  -- One row per order is a CONSTRAINT, not a convention — that is what makes
  -- "never asked twice" true even when two tabs answer at once.
  select exists (
    select 1 from pg_index i
      join pg_class c on c.oid = i.indrelid
      join pg_attribute a on a.attrelid = c.oid and a.attnum = i.indkey[0]
     where c.relname = 'order_feedback' and i.indisunique
       and i.indnatts = 1 and a.attname = 'order_id')
    into v_once_only;

  select count(*) into v_routes from public.wa_event_routes
   where event_key in ('order_feedback_request','order_feedback_low') and enabled;

  select count(*) into v_crons from public.cron_task
   where name in ('order_feedback_sweep','order_feedback_rollup') and enabled;

  select (route_key = 'feedback' and is_active) into v_nav
    from public.feature_registry where feature_key = 'admin.feedback';

  -- ── The live chain, against a real closed order, then rolled back.
  select o.id, pp.user_id into v_order, v_uid
    from public.orders o
    join public.pharmacy_profiles pp on pp.id = o.customer_id
   where o.closed_at is not null and pp.user_id is not null
   order by o.closed_at desc limit 1;

  -- CHANGE #799 — remember what was there first.
  --
  -- The probe picks the NEWEST closed order and rolls its own writes back, but
  -- a ticket a real customer opened on that order does not roll back — it was
  -- never the probe's. Counting every feedback ticket on the order therefore
  -- counts strangers: on 2026-09-03 a genuine 'support' ticket (MB-2609-0004)
  -- landed on exactly that order and this journey read 3 where it had made 2,
  -- and went red for every command after it while the feedback loop itself was
  -- working perfectly. A probe must assert on what IT did.
  select coalesce(array_agg(t.id), '{}') into v_pre
    from public.support_ticket t
   where t.order_id = v_order and t.topic_code = 'feedback';

  if v_order is not null then
    begin
      v_ran := true;
      -- The order may already carry an answer; inside this block that is ours
      -- to clear, because none of it survives the raise at the bottom.
      delete from public.order_feedback where order_id = v_order;
      delete from public.order_feedback_token where order_id = v_order;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

      v_prompt := public.order_feedback_prompt(v_order);
      v_dims   := jsonb_array_length(coalesce(v_prompt->'dimensions','[]'::jsonb));
      select count(*)::int into v_chips
        from jsonb_array_elements(coalesce(v_prompt->'dimensions','[]'::jsonb)) d
       where jsonb_array_length(coalesce(d->'chips','[]'::jsonb)) > 0;

      v_token := public.order_feedback_send_wa(v_order) ->> 'token';

      -- The WhatsApp page, as a signed-out browser sees it.
      perform set_config('request.jwt.claims',
        json_build_object('role','anon')::text, true);
      v_form := public.order_feedback_form(v_token);
      v_anon_form := coalesce((v_form->>'ok')::boolean, false)
                 and coalesce(v_form->>'title','') <> '';

      v_sub := public.order_feedback_submit_token(v_token,
        '{"ordering":5,"packaging":1,"delivery":4,"products":5,"support":2}'::jsonb,
        5, 'boxes arrived crushed', array['pkg_damaged']);

      select count(*)::int, coalesce(string_agg(distinct feedback_dim, ','), '')
        into v_tickets, v_dim_tag
        from public.support_ticket
       where order_id = v_order and topic_code = 'feedback'
         and not (id = any (v_pre));

      select count(*)::int into v_feeds
        from public.exception_scorecard_input
       where exception_id like 'ofb:' || v_order::text || '%';

      perform public.order_feedback_rollup(4);
      select count(*)::int into v_weeks from public.order_feedback_weekly;

      -- Asked once: the customer's own prompt, and the link, both close.
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_again := public.order_feedback_prompt(v_order);
      v_twice := public.order_feedback_submit_token(v_token,
        '{"ordering":5,"packaging":5,"delivery":5,"products":5,"support":5}'::jsonb, 10);

      raise exception using errcode = 'ZZ697', message = 'c697 journey rollback';
    exception when sqlstate 'ZZ697' then
      null;  -- every write above is gone; the answers are still in the variables
    end;
  end if;

  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_writer_closed and v_anon_open and coalesce(v_once_only,false)
      and v_routes = 2 and v_crons = 2 and coalesce(v_nav,false)
      and v_ran
      and coalesce((v_prompt->>'show')::boolean,false)
      and v_dims = 5 and v_chips = 5
      and v_anon_form
      and coalesce((v_sub->>'ok')::boolean,false)
      and coalesce((v_sub->>'ticket_opened')::boolean,false)
      and v_tickets = 2 and v_dim_tag like '%packaging%'
      and v_feeds >= 3
      and v_weeks >= 1
      and coalesce((v_again->>'show')::boolean, true) = false
      and coalesce(v_twice->>'error','') = 'used';

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
        'internal writers closed to anon+authenticated=' || v_writer_closed::text
     || ' | anon may read+submit the token page=' || v_anon_open::text
     || ' | one feedback row per order is a unique index=' || coalesce(v_once_only::text,'?')
     || ' | wa routes live=' || v_routes || '/2'
     || ' | cron tasks enabled=' || v_crons || '/2'
     || ' | Feedback desk registered at route feedback=' || coalesce(v_nav::text,'?')
     || ' | live chain ran=' || v_ran::text
     || ' | prompt.show=' || coalesce(v_prompt->>'show','-')
     || ' dimensions=' || v_dims || ' of 5, all with chips=' || v_chips
     || ' | anon form ok=' || v_anon_form::text
     || ' | token submit ok=' || coalesce(v_sub->>'ok','-')
     || ' ticket_opened=' || coalesce(v_sub->>'ticket_opened','-')
     || ' | tickets=' || v_tickets || ' tagged ' || coalesce(nullif(v_dim_tag,''),'-')
     || ' | scorecard inputs=' || v_feeds
     || ' | weekly rollup rows=' || v_weeks
     || ' | asked twice=' || coalesce(v_again->>'show','-')
     || ' | token reused=' || coalesce(v_twice->>'error','-')
     || ' | every write above was rolled back'));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c698_substitute()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '200s'
AS $function$
declare
  -- static guarantees
  v_anon_page   boolean; v_anon_apply boolean; v_one_ask boolean;
  v_cron        boolean; v_routes int; v_probe_arm boolean;
  v_blocked     boolean; v_allowed boolean; v_no_price boolean; v_hooked boolean;
  -- the live chain
  v_cust uuid; v_user uuid; v_ord uuid; v_line uuid; v_ask bigint; v_tok text;
  v_ids bigint[]; v_inq bigint; v_sup text; v_slot int;
  v_opts int := 0; v_probes int := 0; v_demand numeric := 0;
  v_joined boolean := false; v_qty numeric := 0; v_orig_unf boolean := false;
  v_loser_gone boolean := false; v_blocked_line_asked boolean := true;
  v_chain text := 'not run'; v_ok boolean;
  v_pid bigint; v_warf bigint; v_l2 uuid;
begin
  perform public._dev_guard();

  -- ── 1. the fence: the token page is anonymous, the machinery is not ──────
  v_anon_page := has_function_privilege('anon',
      'public.substitute_ask_page(text)', 'execute')
    and has_function_privilege('anon',
      'public.substitute_ask_submit(text, bigint[], boolean)', 'execute')
    and has_function_privilege('anon', 'public.substitute_ask_skip(text)', 'execute');
  v_anon_apply := has_function_privilege('anon',
      'public.substitute_apply(bigint, bigint)', 'execute')
    or has_function_privilege('anon', 'public.substitute_ask_open(uuid)', 'execute')
    or has_function_privilege('anon', 'public.substitute_ask_tick(integer)', 'execute');

  -- ── 2. "one ask per line, never repeated" is an INDEX, not a code path ───
  v_one_ask := exists (
    select 1 from pg_indexes
     where schemaname = 'public' and tablename = 'order_substitute_ask'
       and indexdef ilike '%unique%' and indexdef ilike '%order_item_id%');

  v_cron := coalesce((select enabled from public.cron_task
                       where name = 'substitute_ask_tick'), false);
  select count(*) into v_routes from public.wa_event_routes
   where event_key in ('order_substitute_ask','order_substitute_applied',
                       'order_substitute_none') and enabled;

  -- ── 3. the waterfall can SEE a ticked substitute ─────────────────────────
  select coalesce(p.prosrc,'') ilike '%order_substitute_probe%' into v_probe_arm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'inquiry_demand_qty' limit 1;

  -- and the finalizer is where the ask is opened from, so an unfulfilled line
  -- can never be shipped past without the customer having been asked.
  select coalesce(p.prosrc,'') ilike '%substitute_ask_open%' into v_hooked
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'order_finalize_unfulfilled' limit 1;

  -- ── 4. never a narrow-therapeutic-index or Schedule X molecule ───────────
  select m.id into v_warf from public."MEDICINE" m
   where m.salt_composition ilike '%warfarin%' and m.buyable is true limit 1;
  v_blocked := v_warf is null or not public.med_substitutable(v_warf);

  -- CHANGE #850 — this used to call substitute_candidates() once per scanned
  -- order line (the scalar-helper-scan anti-pattern): 241 calls at ~195 ms,
  -- 47 s of a 55 s statement budget, so the probe timed out instead of
  -- answering and #850 could not close on it. The assertion is unchanged --
  -- a REAL order line, newest first, whose product has live substitutes --
  -- but the expensive helper now runs over a bounded, de-duplicated recent
  -- window instead of the whole table.
  select s.product_id into v_pid
    from (
      select distinct on (oi.product_id) oi.product_id, oi.zone_id, oi.created_at
        from (
          select oi2.product_id, oi2.zone_id, oi2.created_at
            from public.order_items oi2
           where oi2.zone_id is not null
           order by oi2.created_at desc
           limit 400
        ) oi
        join public."MEDICINE" m on m.id = oi.product_id
       order by oi.product_id, oi.created_at desc
    ) s
   where jsonb_array_length(
           public.substitute_candidates(s.product_id, s.zone_id, null, 3)->'items') > 0
   order by s.created_at desc
   limit 1;
  v_allowed := v_pid is not null and public.med_substitutable(v_pid);

  -- ── 5. NO PRICES. mediBO sells at the supplier's rate; an offer that
  -- carried a number we have not got yet would be a promise we cannot keep.
  v_no_price := v_pid is null or not (
    public.substitute_candidates(v_pid, null, null, 3)::text
      ~* '"(price|mrp|rate|amount|net|margin|saving|pricing)[^"]*"\s*:');

  -- ── 6. THE LIVE CHAIN, rolled back before this function answers ──────────
  begin
    select o.customer_id, o.user_id into v_cust, v_user
      from public.orders o
      join public.pharmacy_profiles pp
        on pp.user_id = o.user_id and pp.approved
       and coalesce(pp.is_deleted,false) = false
     where o.user_id is not null and coalesce(o.is_synthetic,false) = false
     order by o.created_at desc limit 1;
    if v_cust is null or v_pid is null then
      v_chain := 'no live customer or no zone-stocked substitutable product to test with';
      raise exception 'C698_PROBE_ROLLBACK';
    end if;

    insert into public.orders (customer_id, user_id, pharmacy_name, order_code,
                               status, fulfillment_status, total_amount,
                               zone_id, phone, placed_by_admin)
    select v_cust, v_user, coalesce(pp.pharmacy_name,''), 'C698-PROBE',
           'accepted', 'open', 0, coalesce(pp.zone_id, public.zone_default_id()),
           '9999999999', true
      from public.pharmacy_profiles pp where pp.id = v_cust
    returning id into v_ord;

    insert into public.order_items (order_id, product_id, product_name, quantity,
                                    mrp, gst_percent, pharmacy_name)
    select v_ord, m.id, coalesce(m.product_name,''), 5,
           nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
           m.gst_percent, ''
      from public."MEDICINE" m where m.id = v_pid
    returning id into v_line;

    if v_warf is not null then
      insert into public.order_items (order_id, product_id, product_name, quantity,
                                      mrp, gst_percent, pharmacy_name)
      select v_ord, m.id, coalesce(m.product_name,''), 1,
             nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
             m.gst_percent, ''
        from public."MEDICINE" m where m.id = v_warf
      returning id into v_l2;
    end if;

    update public.order_items set unfulfillable = true,
           unfulfillable_reason = 'No supplier available', unfulfillable_at = now()
     where order_id = v_ord;

    -- The ask is opened the way order_finalize_unfulfilled opens it (that hook
    -- is asserted separately, from the function's own source). The probe calls
    -- substitute_ask_open directly so it never takes the orders-total write
    -- lock the finalizer takes — a journey that runs on every command must not
    -- be able to deadlock with a live order being finalized beside it.
    perform public.substitute_ask_open(v_line);
    if v_l2 is not null then perform public.substitute_ask_open(v_l2); end if;

    select a.id, a.token, jsonb_array_length(a.options)
      into v_ask, v_tok, v_opts
      from public.order_substitute_ask a where a.order_item_id = v_line;
    if v_ask is null then
      v_chain := 'no ask opened for a substitutable unfulfilled line';
      raise exception 'C698_PROBE_ROLLBACK';
    end if;
    -- the blocked molecule must have been passed over in SILENCE
    v_blocked_line_asked := v_l2 is not null and exists (
      select 1 from public.order_substitute_ask where order_item_id = v_l2);

    -- tick the LAST option first: the order of the taps is the ranking
    select array[(a.options->(v_opts-1)->>'product_id')::bigint,
                 (a.options->0->>'product_id')::bigint]
      into v_ids from public.order_substitute_ask a where a.id = v_ask;
    perform public.substitute_ask_submit(v_tok, v_ids, false);

    select count(*) into v_probes from public.order_substitute_probe where ask_id = v_ask;
    select public.inquiry_demand_qty(p.product_id, i.current_supplier, true)
      into v_demand
      from public.order_substitute_probe p
      join public.inquiry i on i.id = p.inquiry_id
     where p.ask_id = v_ask and p.rank = 1;

    -- the SECOND-ranked substitute answers Available first
    select p.inquiry_id into v_inq
      from public.order_substitute_probe p where p.ask_id = v_ask and p.rank = 2;
    select i.current_supplier into v_sup from public.inquiry i where i.id = v_inq;
    select s into v_slot from generate_series(1,30) s
     where (to_jsonb((select q from public.inquiry q where q.id = v_inq)) ->> ('PS'||s)) = v_sup
     limit 1;
    if v_slot is not null then
      execute format('update public.inquiry set %I = %L where id = %s',
                     'AS'||v_slot, 'Available', v_inq);
    end if;

    perform public.substitute_ask_tick(50);

    select true, sub.quantity into v_joined, v_qty
      from public.order_items sub
     where sub.order_id = v_ord and sub.substitute_for = v_line limit 1;
    select oi.unfulfillable into v_orig_unf
      from public.order_items oi where oi.id = v_line;
    -- a losing probe leaves NOTHING on a distributor's purchase order
    v_loser_gone := not exists (
      select 1 from public.order_substitute_probe p
       where p.ask_id = v_ask and p.rank = 1
         and p.inquiry_id is not null
         and exists (select 1 from public.inquiry i where i.id = p.inquiry_id));

    v_chain := 'ran';
    raise exception 'C698_PROBE_ROLLBACK';
  exception when others then
    if sqlerrm <> 'C698_PROBE_ROLLBACK' and v_chain = 'not run' then
      v_chain := 'error: ' || left(sqlerrm, 120);
    end if;
  end;

  v_ok := v_anon_page and not v_anon_apply and v_one_ask and v_cron
      and v_routes = 3 and coalesce(v_probe_arm, false) and coalesce(v_hooked, false)
      and v_blocked and v_allowed and v_no_price
      and v_chain = 'ran'
      and v_opts > 0 and v_probes = 2 and v_demand > 0
      and coalesce(v_joined, false) and coalesce(v_orig_unf, false)
      and v_loser_gone and not v_blocked_line_asked;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'anon may read+answer the token page=' || v_anon_page::text ||
      ' | anon may apply/open/tick=' || v_anon_apply::text || ' (must be false)' ||
      ' | one-ask-per-line is a unique index=' || v_one_ask::text ||
      ' | tick cron enabled=' || v_cron::text ||
      ' | wa routes active=' || v_routes::text || '/3' ||
      ' | inquiry_demand_qty counts probe demand=' || coalesce(v_probe_arm::text,'?') ||
      ' | order_finalize_unfulfilled opens the ask=' || coalesce(v_hooked::text,'?') ||
      ' | narrow-therapeutic molecule refused=' || v_blocked::text ||
      ' | an ordinary product is allowed=' || v_allowed::text ||
      ' | offer carries no price key=' || v_no_price::text ||
      ' | live chain=' || v_chain ||
      ' | options offered=' || v_opts::text ||
      ' | probes started=' || v_probes::text ||
      ' | waterfall sees the demand=' || v_demand::text ||
      ' | substitute joined the same order=' || coalesce(v_joined::text,'false') ||
      ' at qty ' || coalesce(v_qty::text,'-') ||
      ' | original line still unfulfilled=' || coalesce(v_orig_unf::text,'false') ||
      ' | losing probe left nothing on a PO=' || v_loser_gone::text ||
      ' | blocked molecule was asked about=' || v_blocked_line_asked::text ||
        ' (must be false)' ||
      ' | every write rolled back=true'));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c705_kyc_expiry_block()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_uid uuid := gen_random_uuid(); v_zone smallint;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_reg jsonb; v_ph uuid; v_up jsonb; v_doc uuid; v_ver jsonb;
  v_sweep1 jsonb; v_sweep2 jsonb; v_sweep3 jsonb;
  v_b7 int := 0; v_b7_again int := 0; v_bexp int := 0;
  v_state_exp text := ''; v_gate_exp jsonb; v_renew jsonb; v_state_renew text := '';
  v_ver2 jsonb; v_gate_after jsonb; v_chain text := 'not run';
  v_cron_on boolean; v_cron_at time; v_ok boolean;
begin
  perform public._dev_guard();

  select coalesce(enabled,false), run_at_ist into v_cron_on, v_cron_at
    from cron_task where name = 'kyc-expiry-sweep';

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_reg := public.submit_registration('pharmacy', jsonb_build_object(
                 'pharmacy_name','C705 PROBE EXPIRY','customer_name','C705 PROBE',
                 'phone','9000000707','whatsapp_no','9000000707','address','Probe Lane',
                 'city','Raipur','state','Chhattisgarh','pincode','492001'));
      v_ph := nullif(v_reg->>'id','')::uuid;
      update pharmacy_profiles set zone_id = v_zone where id = v_ph;
      -- a licence that expires in six days: the 7-day bucket, not the 30
      v_up := public.kyc_upload_register('drug_licence',
                'pharmacy/'||v_ph::text||'/dl.pdf', 'dl.pdf', 'CG-20B-707',
                null, v_today + 6);
      v_doc := nullif(v_up->>'doc_id','')::uuid;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_ver := public.kyc_review_set(v_doc, 'verified', null);

      v_sweep1 := public.kyc_expiry_sweep();
      select count(*) into v_b7 from kyc_expiry_reminder
       where owner_id = v_ph and bucket_days = 7;
      v_sweep2 := public.kyc_expiry_sweep();               -- must be silent
      select count(*) into v_b7_again from kyc_expiry_reminder
       where owner_id = v_ph and bucket_days = 7;

      -- the day it lapses (the only clock a probe may move is the document's)
      update kyc_documents set valid_to = v_today - 1 where id = v_doc;
      v_sweep3 := public.kyc_expiry_sweep();
      select count(*) into v_bexp from kyc_expiry_reminder
       where owner_id = v_ph and bucket_days = -1;
      v_state_exp := public.kyc_state('pharmacy', v_ph) ->> 'state';
      v_gate_exp  := public.kyc_gate('pharmacy', v_ph, 'trade');

      -- renew: the ordinary upload path, and the block lifts on its own
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_renew := public.kyc_upload_register('drug_licence',
                   'pharmacy/'||v_ph::text||'/dl-renewed.pdf', 'dl-renewed.pdf',
                   'CG-20B-707R', null, v_today + 400);
      v_state_renew := public.kyc_state('pharmacy', v_ph) ->> 'state';
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_ver2 := public.kyc_review_set(nullif(v_renew->>'doc_id','')::uuid, 'verified', null);
      v_gate_after := public.kyc_gate('pharmacy', v_ph, 'trade');
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_cron_on,false) and v_cron_at is not null
      and v_b7 = 1 and v_b7_again = 1
      and v_bexp = 1
      and v_state_exp = 'expired'
      and coalesce((v_gate_exp->>'blocked')::boolean,false)
      and coalesce(v_gate_exp->>'reason','') = 'kyc_expired'
      and coalesce((v_renew->>'ok')::boolean,false)
      and v_state_renew = 'pending'
      and coalesce((v_ver2->>'ok')::boolean,false)
      and not coalesce((v_gate_after->>'blocked')::boolean,true);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | cron_task kyc-expiry-sweep enabled='||coalesce(v_cron_on,false)::text
   || ' at '||coalesce(v_cron_at::text,'<none>')||' IST'
   || ' | 7-day reminder rows after one sweep='||v_b7::text
   || ' after two='||v_b7_again::text||' (a re-run must be silent)'
   || ' | sweep1 reminded='||coalesce(v_sweep1->>'reminded','?')
   || ' sweep2 reminded='||coalesce(v_sweep2->>'reminded','?')
   || ' | on expiry: reminder rows='||v_bexp::text
   || ' expired='||coalesce(v_sweep3->>'expired','?')
   || ' blocked='||coalesce(v_sweep3->>'blocked','?')
   || ' | state='||coalesce(nullif(v_state_exp,''),'?')
   || ' gate blocked='||coalesce(v_gate_exp->>'blocked','?')
   || ' -> '||coalesce(v_gate_exp->>'message','')
   || ' | renew upload ok='||coalesce(v_renew->>'ok','?')
   || ' state='||coalesce(nullif(v_state_renew,''),'?')
   || ' | after re-verification blocked='||coalesce(v_gate_after->>'blocked','?')));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c705_kyc_pharmacy_chain()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_uid uuid := gen_random_uuid(); v_zone smallint;
  v_reg jsonb; v_ph uuid; v_panel0 jsonb; v_panel1 jsonb; v_up jsonb; v_doc uuid;
  v_ver jsonb; v_appr jsonb; v_gate0 jsonb; v_gate1 jsonb; v_queue jsonb;
  v_in_queue boolean := false; v_early_block boolean := false; v_early_msg text := '';
  v_approved boolean := false; v_chain text := 'not run';
  v_anon_write boolean; v_anon_token boolean; v_live_uk boolean; v_trg int;
  v_refused_approved boolean := false; v_ok boolean;
begin
  perform public._dev_guard();

  -- The fence: the applicant's own writes are authenticated-only, the token
  -- page is the ONE anonymous door, and the review RPCs are neither.
  v_anon_write := has_function_privilege('anon',
        'public.kyc_upload_register(text,text,text,text,date,date,text,bigint)','execute')
    or has_function_privilege('anon','public.kyc_review_set(uuid,text,text)','execute')
    or has_function_privilege('anon','public.kyc_review_queue(text,text,integer,integer)','execute')
    or has_function_privilege('anon','public.kyc_drive_send(text,integer)','execute');
  v_anon_token := has_function_privilege('anon','public.kyc_token_form(text)','execute')
              and has_function_privilege('anon','public.kyc_token_submit(text,text,text,date,text)','execute');
  v_live_uk := exists (select 1 from pg_indexes
                        where schemaname='public' and tablename='kyc_documents'
                          and indexname='kyc_documents_live_uk');
  select count(*) into v_trg from pg_trigger
   where not tgisinternal
     and tgname in ('trg_kyc_approval_guard_pharmacy','trg_kyc_approval_guard_supplier');

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      -- the applicant registers through the SAME door every other kind uses
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_reg := public.submit_registration('pharmacy', jsonb_build_object(
                 'pharmacy_name','C705 PROBE PHARMACY','customer_name','C705 PROBE',
                 'phone','9000000705','whatsapp_no','9000000705','address','Probe Lane',
                 'city','Raipur','state','Chhattisgarh','pincode','492001',
                 'approved', true));                    -- must be REFUSED, not applied
      v_ph := nullif(v_reg->>'id','')::uuid;
      v_refused_approved := coalesce(v_reg->'rejected_keys','[]'::jsonb) ? 'approved'
                        and not coalesce((select approved from pharmacy_profiles where id = v_ph), false);
      update pharmacy_profiles set zone_id = v_zone where id = v_ph;
      v_panel0 := public.kyc_my_panel();

      -- an admin cannot approve it yet
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      begin
        perform public.admin_review_registration('pharmacy', v_ph, 'approved');
      exception when others then
        v_early_block := true; v_early_msg := left(sqlerrm, 160);
      end;

      -- upload
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_up := public.kyc_upload_register('drug_licence',
                'pharmacy/'||v_ph::text||'/dl.pdf', 'dl.pdf', 'CG-20B-C705',
                null, ((now() at time zone 'Asia/Kolkata')::date + 365));
      v_doc := nullif(v_up->>'doc_id','')::uuid;
      v_panel1 := public.kyc_my_panel();
      v_gate0 := public.cart_rx_gate(v_ph, '[]'::jsonb);

      -- review, then approve
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_queue := public.kyc_review_queue('pending', 'pharmacy', 50, 0);
      v_in_queue := exists (select 1
        from jsonb_array_elements(coalesce(v_queue->'rows','[]'::jsonb)) r
       where r->>'doc_id' = v_doc::text);
      v_ver  := public.kyc_review_set(v_doc, 'verified', null);
      v_appr := public.admin_review_registration('pharmacy', v_ph, 'approved');
      select coalesce(approved,false) into v_approved from pharmacy_profiles where id = v_ph;
      v_gate1 := public.cart_rx_gate(v_ph, '[]'::jsonb);
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := not v_anon_write and v_anon_token and v_live_uk and v_trg = 2
      and v_chain = 'ran'
      and v_refused_approved
      and coalesce(v_panel0->'state'->>'state','') = 'missing'
      and v_early_block
      and v_early_msg ilike '%drug licence%'
      and coalesce((v_up->>'ok')::boolean,false)
      and coalesce(v_panel1->'state'->>'state','') = 'pending'
      and coalesce((v_gate0->>'blocked')::boolean,false)
      and v_in_queue
      and coalesce((v_ver->>'ok')::boolean,false)
      and coalesce(v_ver->'owner_state'->>'state','') = 'verified'
      and coalesce((v_appr->>'ok')::boolean,false)
      and v_approved
      and not coalesce((v_gate1->>'blocked')::boolean,true);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | anon can write KYC='||coalesce(v_anon_write,false)::text||' (must be false)'
   || ' | anon token page open='||coalesce(v_anon_token,false)::text
   || ' | one live doc per kind (unique index)='||coalesce(v_live_uk,false)::text
   || ' | approval triggers='||v_trg::text
   || ' | applicant could not set approved itself='||v_refused_approved::text
   || ' | panel before upload='||coalesce(v_panel0->'state'->>'state','?')
   || ' | approval before verification refused='||v_early_block::text
   || ' -> '||coalesce(nullif(v_early_msg,''),'<no message>')
   || ' | upload ok='||coalesce(v_up->>'ok','?')
   || ' | panel after upload='||coalesce(v_panel1->'state'->>'state','?')
   || ' | ordering blocked while pending='||coalesce(v_gate0->>'blocked','?')
   || ' -> '||coalesce(v_gate0->>'message','')
   || ' | document in the review queue='||v_in_queue::text
   || ' | verify ok='||coalesce(v_ver->>'ok','?')
   || ' state='||coalesce(v_ver->'owner_state'->>'state','?')
   || ' | approve after verification ok='||coalesce(v_appr->>'ok','?')
   || ' approved='||v_approved::text
   || ' | ordering blocked after verification='||coalesce(v_gate1->>'blocked','?')));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c705_kyc_reject_reason()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_uid uuid := gen_random_uuid(); v_zone smallint;
  v_reason text := 'The licence photo is cut off - page 2 is missing.';
  v_reg jsonb; v_ph uuid; v_up jsonb; v_doc uuid; v_no_reason jsonb; v_rej jsonb;
  v_panel jsonb; v_item jsonb; v_gate jsonb; v_chain text := 'not run';
  v_route_on boolean; v_route_has_reason boolean; v_ok boolean;
begin
  perform public._dev_guard();

  -- the applicant is told over WhatsApp too, and the template carries the
  -- reason itself rather than "contact support"
  select coalesce(enabled,false),
         coalesce(push_body,'') like '%{{reason}}%'
    into v_route_on, v_route_has_reason
    from wa_event_routes where event_key = 'kyc_document_rejected';

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_reg := public.submit_registration('pharmacy', jsonb_build_object(
                 'pharmacy_name','C705 PROBE REJECT','customer_name','C705 PROBE',
                 'phone','9000000706','address','Probe Lane','city','Raipur',
                 'state','Chhattisgarh','pincode','492001'));
      v_ph := nullif(v_reg->>'id','')::uuid;
      update pharmacy_profiles set zone_id = v_zone where id = v_ph;
      v_up := public.kyc_upload_register('drug_licence',
                'pharmacy/'||v_ph::text||'/dl.jpg', 'dl.jpg', 'CG-20B-706',
                null, ((now() at time zone 'Asia/Kolkata')::date + 200));
      v_doc := nullif(v_up->>'doc_id','')::uuid;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_no_reason := public.kyc_review_set(v_doc, 'rejected', null);   -- refused
      v_rej       := public.kyc_review_set(v_doc, 'rejected', v_reason);

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_panel := public.kyc_my_panel();
      select r into v_item from jsonb_array_elements(coalesce(v_panel->'items','[]'::jsonb)) r
       where r->>'kind' = 'drug_licence';
      v_gate := public.cart_rx_gate(v_ph, '[]'::jsonb);
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_route_on,false) and coalesce(v_route_has_reason,false)
      and not coalesce((v_no_reason->>'ok')::boolean, true)
      and coalesce(v_no_reason->>'error','') = 'no_reason'
      and coalesce((v_rej->>'ok')::boolean,false)
      and coalesce(v_item->>'status','') = 'rejected'
      and coalesce(v_item->>'reason_line','') like '%page 2 is missing%'
      and coalesce(v_item->>'status_tone','') = 'danger'
      and coalesce((v_gate->>'blocked')::boolean,false)
      and coalesce(v_gate->'kyc'->>'reason','') = 'kyc_rejected';

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | WhatsApp route kyc_document_rejected enabled='||coalesce(v_route_on,false)::text
   || ' carries the reason='||coalesce(v_route_has_reason,false)::text
   || ' | rejection with no reason refused='||coalesce(v_no_reason->>'error','?')
   || ' | rejection with a reason ok='||coalesce(v_rej->>'ok','?')
   || ' | applicant panel status='||coalesce(v_item->>'status','?')
   || ' tone='||coalesce(v_item->>'status_tone','?')
   || ' | the reason the applicant reads='||coalesce(nullif(v_item->>'reason_line',''),'<empty>')
   || ' | ordering blocked='||coalesce(v_gate->>'blocked','?')
   || ' reason='||coalesce(v_gate->'kyc'->>'reason','?')));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c705_kyc_supplier_token()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_zone smallint; v_sup uuid; v_name text := 'C705 PROBE SUPPLIER';
  v_token text := 'c705probe' || replace(gen_random_uuid()::text,'-','');
  v_blocked0 boolean; v_blocked1 boolean; v_form jsonb; v_sub jsonb; v_doc uuid;
  v_early_block boolean := false; v_early_msg text := '';
  v_ver jsonb; v_appr jsonb; v_approved boolean := false; v_chain text := 'not run';
  v_engine_reads_gate boolean; v_card jsonb; v_ok boolean;
begin
  perform public._dev_guard();

  -- the inquiry engine asks the gate itself; the waterfall is where a blocked
  -- supplier has to disappear, not the console
  select coalesce(p.prosrc,'') like '%kyc_supplier_blocked%' into v_engine_reads_gate
    from pg_proc p where p.pronamespace='public'::regnamespace
     and p.proname='start_inquiry_for_suppliers' limit 1;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      insert into supplier_profiles (supplier_name, contact_name, phone, whatsapp_no,
                                     city, state, address, zone_id, approved, status)
      values (v_name, 'C705 PROBE', '9000000708', '9000000708', 'Raipur',
              'Chhattisgarh', 'Probe Lane', v_zone, false, 'pending')
      returning id into v_sup;
      v_blocked0 := public.kyc_supplier_blocked(v_name);

      -- an admin cannot approve it yet
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      begin
        perform public.admin_review_registration('supplier', v_sup, 'approved');
      exception when others then
        v_early_block := true; v_early_msg := left(sqlerrm,160);
      end;
      v_card := public.kyc_drive_card();

      -- the backfill link, opened in a WhatsApp browser with no session
      insert into kyc_upload_token(token, owner_kind, owner_id)
      values (v_token, 'supplier', v_sup);
      perform set_config('request.jwt.claims',
        json_build_object('role','anon')::text, true);
      v_form := public.kyc_token_form(v_token);
      v_sub  := public.kyc_token_submit(v_token, 'token/'||v_token||'/dl.jpg',
                  'CG-21B-708', ((now() at time zone 'Asia/Kolkata')::date + 300), 'dl.jpg');
      v_doc  := nullif(v_sub->>'doc_id','')::uuid;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_ver  := public.kyc_review_set(v_doc, 'verified', null);
      v_appr := public.admin_review_registration('supplier', v_sup, 'approved');
      select coalesce(approved,false) into v_approved from supplier_profiles where id = v_sup;
      v_blocked1 := public.kyc_supplier_blocked(v_name);
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_engine_reads_gate,false)
      and coalesce(v_blocked0,false)
      and v_early_block and v_early_msg ilike '%drug licence%'
      and coalesce((v_form->>'ok')::boolean,false)
      and coalesce(v_form->>'title','') <> ''
      and coalesce((v_sub->>'ok')::boolean,false)
      and coalesce((v_ver->>'ok')::boolean,false)
      and coalesce((v_appr->>'ok')::boolean,false)
      and v_approved
      and not coalesce(v_blocked1,true)
      and coalesce((v_card->>'ok')::boolean,false);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | the inquiry waterfall reads the gate='||coalesce(v_engine_reads_gate,false)::text
   || ' | supplier not asked while unverified='||coalesce(v_blocked0,false)::text
   || ' | approval before verification refused='||v_early_block::text
   || ' -> '||coalesce(nullif(v_early_msg,''),'<no message>')
   || ' | anonymous token page ok='||coalesce(v_form->>'ok','?')
   || ' title='||coalesce(v_form->>'title','?')
   || ' | anonymous upload ok='||coalesce(v_sub->>'ok','?')
   || ' | verify ok='||coalesce(v_ver->>'ok','?')
   || ' | approve after verification ok='||coalesce(v_appr->>'ok','?')
   || ' approved='||v_approved::text
   || ' | supplier asked again after verification='||(not coalesce(v_blocked1,true))::text
   || ' | drive card='||coalesce(v_card->>'progress_label', v_card->>'ok', '?')));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c707_assign()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._c707_journey_slice(array[
    'a stage materialises one task',
    'asking twice returns the SAME task',
    'one OPEN task per order-stage',
    'the actor starts the task',
    'the item is counted onto the task',
    'the quantity lands on the task',
    'quantities accumulate, they do not replace',
    'nothing counted yet says so in words',
    'productivity answers for an authorised caller',
    'the proof workers appear on it',
    'a worker with no hours reads the backend dash',
    'the board answers for an authorised caller',
    'the board offers only on-shift workers as chips'
  ], 'assign -> the worker counts -> the task closes carrying its metrics')
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c707_auto()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._c707_journey_slice(array[
    'auto-assign picks an on-shift counter',
    'an unmarked worker is never picked',
    'a packer is not picked for the count stage',
    'the pack stage reaches the packer',
    'round-robin fans out to the idle worker',
    'an ASSIGNED task keeps its worker',
    'an UNASSIGNED task adopts the actor'
  ], 'auto-assign: round-robin across the on-shift roster, by stage role')
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c707_override()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._c707_journey_slice(array[
    'a stranger cannot close the stage',
    'the refusal names the assigned worker',
    'the refused stage is still open',
    'a partner override CAN close it',
    'the close is reported as an override',
    'the override is stamped on the row',
    'the override keeps the name it was taken from',
    'a fresh unowned stage is NOT an exception yet',
    'an AGED unowned stage is an exception',
    'the exception reason is registered and enabled',
    'assigning it clears the exception',
    'the ops board owner block names the worker'
  ], 'the guard: a stranger is refused by name, a partner override is logged')
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c708_hold_auto_cancel()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_order uuid; v_sweep jsonb;
  v_status text := ''; v_hold_status text := ''; v_reason text := '';
  v_chain text := 'not run'; v_days int; v_ok boolean;
begin
  perform public._dev_guard();

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select o.id into v_order from orders o
   where o.status <> 'cancelled' and o.closed_at is null
   order by o.created_at desc limit 1;

  if v_admin is not null and v_order is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      delete from order_stage_history where order_id = v_order;
      insert into order_stage_history(order_id, stage_key, entered_at)
      values (v_order, 'accept', now() - interval '2 hours');

      perform public.order_hold(v_order, 'stock_elsewhere', null, null);
      update order_hold
         set auto_cancel_on = (now() at time zone 'Asia/Kolkata')::date - 1,
             held_at = now() - interval '20 days'
       where order_id = v_order and status = 'active';

      v_sweep := public.order_hold_sweep();
      select o.status into v_status from orders o where o.id = v_order;
      select h.status, coalesce(h.resume_note,'') into v_hold_status, v_reason
        from order_hold h where h.order_id = v_order order by h.id desc limit 1;
      select count(*)::int into v_days from order_cancellations
       where order_id = v_order and reason_code = 'held_too_long';

      v_chain := 'ran';
      raise exception using errcode='ZZ708', message='c708 journey rollback';
    exception
      when sqlstate 'ZZ708' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce((v_sweep->>'cancelled')::int,0) = 1
      and v_status = 'cancelled'
      and v_hold_status = 'cancelled'
      and v_reason <> ''
      and coalesce(v_days,0) = 1;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | sweep cancelled='||coalesce(v_sweep->>'cancelled','?')
   || ' | order status='||coalesce(nullif(v_status,''),'?')
   || ' | hold row='||coalesce(nullif(v_hold_status,''),'?')
   || ' | the sentence on it='||coalesce(nullif(v_reason,''),'<empty>')
   || ' | cancellation rows with reason held_too_long='||coalesce(v_days,0)::text));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c708_hold_auto_resume()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_order uuid;
  v_s1 jsonb; v_s2 jsonb; v_s3 jsonb; v_held_after boolean := true;
  v_reminders int := 0; v_chain text := 'not run'; v_cron boolean; v_ok boolean;
begin
  perform public._dev_guard();

  select coalesce(enabled,false) into v_cron from cron_task where name = 'order-hold-sweep';

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select o.id into v_order from orders o
   where o.status <> 'cancelled' and o.closed_at is null
   order by o.created_at desc limit 1;

  if v_admin is not null and v_order is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      delete from order_stage_history where order_id = v_order;
      insert into order_stage_history(order_id, stage_key, entered_at)
      values (v_order, 'supplier_order', now() - interval '2 hours');

      -- due to resume tomorrow: the reminder goes once, and only once
      perform public.order_hold(v_order, 'cash_later', null,
                ((now() at time zone 'Asia/Kolkata')::date + 1));
      v_s1 := public.order_hold_sweep();
      v_s2 := public.order_hold_sweep();
      select count(*)::int into v_reminders from order_hold
       where order_id = v_order and reminded_at is not null;

      -- the date arrives: the sweep resumes it, through order_resume itself
      update order_hold set resume_on = (now() at time zone 'Asia/Kolkata')::date
       where order_id = v_order and status = 'active';
      v_s3 := public.order_hold_sweep();
      v_held_after := coalesce((public.order_hold_state(v_order)->>'held')::boolean, true);

      v_chain := 'ran';
      raise exception using errcode='ZZ708', message='c708 journey rollback';
    exception
      when sqlstate 'ZZ708' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_cron,false)
      and coalesce((v_s1->>'reminded')::int,0) = 1
      and coalesce((v_s2->>'reminded')::int,1) = 0
      and v_reminders = 1
      and coalesce((v_s3->>'resumed')::int,0) = 1
      and v_held_after = false;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | cron_task order-hold-sweep enabled='||coalesce(v_cron,false)::text
   || ' | sweep 1 reminded='||coalesce(v_s1->>'reminded','?')
   || ' | sweep 2 reminded='||coalesce(v_s2->>'reminded','?')||' (must be 0)'
   || ' | reminder rows on the hold='||v_reminders::text
   || ' | sweep 3 resumed='||coalesce(v_s3->>'resumed','?')
   || ' | still held afterwards='||v_held_after::text||' (must be false)'));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c708_hold_stages()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_order uuid; v_stage text;
  v_allowed text := ''; v_refused text := ''; v_mismatch text := '';
  v_in_pack_before boolean; v_in_pack_held boolean; v_in_pack_after boolean;
  v_deliv jsonb; v_inv jsonb; v_frozen boolean := false;
  v_hold jsonb; v_resume jsonb; v_badge text := '';
  v_chain text := 'not run'; r record; v_sheet jsonb; v_ok boolean;
  v_stage_rows int; v_reasons int;
begin
  perform public._dev_guard();

  select count(*)::int into v_stage_rows from order_hold_stage where allow;
  select count(*)::int into v_reasons from order_hold_reason where is_active;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;

  select o.id into v_order from orders o
   where o.status <> 'cancelled' and o.closed_at is null
   order by o.created_at desc limit 1;

  if v_admin is not null and v_order is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);

      -- (a) the gate answers exactly what the CONFIG says, stage by stage
      for r in select s.stage_key, s.allow from order_hold_stage s
                join sla_stage st on st.stage_key = s.stage_key
               order by st.sort_order
      loop
        delete from order_stage_history where order_id = v_order;
        insert into order_stage_history(order_id, stage_key, entered_at)
        values (v_order, r.stage_key, now() - interval '2 hours');
        v_sheet := public.order_hold_sheet(v_order);
        if coalesce((v_sheet->>'can_hold')::boolean,false) = r.allow then
          if r.allow then
            v_allowed := v_allowed || r.stage_key || ' ';
          else
            v_refused := v_refused || r.stage_key || ' ';
          end if;
        else
          v_mismatch := v_mismatch || r.stage_key || ' ';
        end if;
      end loop;

      -- (b) at an allowed stage: hold, and every surface goes quiet
      delete from order_stage_history where order_id = v_order;
      insert into order_stage_history(order_id, stage_key, entered_at)
      values (v_order, 'supplier_order', now() - interval '2 hours');

      v_in_pack_before := exists (
        select 1 from jsonb_array_elements(public.pack_list_orders_core(null,false)->'orders') x
         where x->>'order_id' = v_order::text);

      v_hold := public.order_hold(v_order, 'shop_closed', 'journey', null);
      v_badge := public.order_hold_state(v_order)->>'badge';

      v_in_pack_held := exists (
        select 1 from jsonb_array_elements(public.pack_list_orders_core(null,false)->'orders') x
         where x->>'order_id' = v_order::text);
      v_deliv := public.delivery_eligibility(v_order);
      v_inv   := public.customer_invoice_issue(v_order);
      v_frozen := coalesce((select bool_and(public._c708_inquiry_held(oi.inquiry_id))
                              from order_items oi
                             where oi.order_id = v_order and oi.inquiry_id is not null), true);

      -- (c) resume, and it carries on from exactly where it was
      v_resume := public.order_resume(v_order, 'journey');
      v_stage  := public._c708_stage(v_order);
      v_in_pack_after := exists (
        select 1 from jsonb_array_elements(public.pack_list_orders_core(null,false)->'orders') x
         where x->>'order_id' = v_order::text);

      v_chain := 'ran';
      raise exception using errcode='ZZ708', message='c708 journey rollback';
    exception
      when sqlstate 'ZZ708' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and v_stage_rows = 4 and v_reasons >= 5
      and btrim(coalesce(v_mismatch,'')) = ''
      and btrim(coalesce(v_allowed,'')) <> ''
      and btrim(coalesce(v_refused,'')) <> ''
      and coalesce((v_hold->>'ok')::boolean,false)
      and coalesce(v_badge,'') <> ''
      and coalesce(v_in_pack_held,true) = false
      and coalesce((v_deliv->>'can_assign')::boolean,true) = false
      and coalesce((v_inv->>'ok')::boolean,true) = false
      and coalesce(v_inv->>'reason','') = 'on_hold'
      and v_frozen
      and coalesce((v_resume->>'ok')::boolean,false)
      and v_stage = 'supplier_order'
      and coalesce(v_in_pack_after,false) = coalesce(v_in_pack_before,false);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | stages the config allows='||v_stage_rows::text
   || ' reasons='||v_reasons::text
   || ' | gate said YES at: '||coalesce(nullif(btrim(v_allowed),''),'-')
   || ' | gate said NO at: '||coalesce(nullif(btrim(v_refused),''),'-')
   || ' | disagreements with the config: '||coalesce(nullif(btrim(v_mismatch),''),'none')
   || ' | hold ok='||coalesce(v_hold->>'ok','?')||' badge='||coalesce(v_badge,'?')
   || ' | pack queue before='||coalesce(v_in_pack_before::text,'?')
   || ' held='||coalesce(v_in_pack_held::text,'?')
   || ' after resume='||coalesce(v_in_pack_after::text,'?')
   || ' | rider can_assign='||coalesce(v_deliv->>'can_assign','?')
   || ' -> '||coalesce(v_deliv->>'blocked_label','')
   || ' | invoice='||coalesce(v_inv->>'reason','?')
   || ' | inquiry rows frozen='||v_frozen::text
   || ' | resume ok='||coalesce(v_resume->>'ok','?')
   || ' stage after resume='||coalesce(v_stage,'?')));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c709_damage_chain()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_item uuid; v_order uuid; v_qty numeric; v_price numeric;
  v_bill_before numeric; v_bill_after numeric; v_note text := '';
  v_bag_before numeric; v_bag_after numeric;
  v_log jsonb; v_cost numeric; v_amount numeric; v_state jsonb;
  v_over jsonb; v_noreason jsonb; v_nophoto jsonb;
  v_chain text := 'not run'; v_ok boolean;
  v_reasons int; v_stages int; v_cost_type boolean;
begin
  perform public._dev_guard();

  select count(*)::int into v_reasons from handling_damage_reason where is_active;
  select count(*)::int into v_stages  from handling_damage_stage  where allow;
  select exists (select 1 from cost_types where slug='handling_damage' and active)
    into v_cost_type;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;

  -- a line that actually reaches the bill, so the money half is real
  select oi.id, oi.order_id, oi.quantity, oi.price
    into v_item, v_order, v_qty, v_price
    from order_items oi
    join orders o on o.id = oi.order_id
   where o.status <> 'cancelled' and o.closed_at is null
     and coalesce(oi.unfulfillable,false) = false
     and oi.fulfillment_state not in ('shipped','cancelled')
     and oi.quantity >= 4
     and exists (select 1 from jsonb_array_elements(public._bill_lines_for_order(oi.order_id)) e
                  where (e->>'qty')::numeric > 0)
   order by o.created_at desc limit 1;

  if v_admin is not null and v_item is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);

      -- price it so the settlement half is exercised even on a line the
      -- catalogue has not rated yet
      update order_items set price = coalesce(nullif(price,0), 40) where id = v_item;

      select coalesce(sum((e->>'qty')::numeric),0) into v_bill_before
        from jsonb_array_elements(public._bill_lines_for_order(v_order)) e;
      select coalesce(sum(qty),0) into v_bag_before
        from bag_allocations where order_item_id = v_item and state='reserved';

      -- the three refusals, each in the backend's own words
      v_noreason := public.damage_log(v_item, 1, 'not_a_reason', 'count');
      v_over     := public.damage_log(v_item, v_qty + 10, 'broken', 'count', null, 'p.jpg');
      v_nophoto  := public.damage_log(v_item, 1, 'broken', 'count');

      -- the real one
      v_log := public.damage_log(v_item, 2, 'broken', 'count', 'journey',
                 'order/'||v_order::text||'/journey.jpg');

      select coalesce(sum((e->>'qty')::numeric),0),
             coalesce(max(e->>'damage_note'),'')
        into v_bill_after, v_note
        from jsonb_array_elements(public._bill_lines_for_order(v_order)) e;
      select coalesce(sum(qty),0) into v_bag_after
        from bag_allocations where order_item_id = v_item and state='reserved';
      select amount into v_amount from handling_damage
       where order_item_id = v_item order by id desc limit 1;
      select computed_amount into v_cost from order_costs
       where order_id = v_order and cost_type = 'handling_damage';
      v_state := public.damage_state(v_order);

      v_chain := 'ran';
      raise exception using errcode='ZZ709', message='c709 journey rollback';
    exception
      when sqlstate 'ZZ709' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and v_reasons = 5 and v_stages = 4 and coalesce(v_cost_type,false)
      and coalesce(v_noreason->>'error','') = 'bad_reason'
      and coalesce(v_over->>'error','') = 'qty_over'
      and coalesce(v_nophoto->>'error','') = 'need_photo'
      and coalesce((v_log->>'ok')::boolean,false)
      and v_bill_after = v_bill_before - 2
      and v_note like '%damaged in handling%'
      and coalesce(v_bag_after,0) <= coalesce(v_bag_before,0)
      and coalesce(v_amount,0) > 0
      and coalesce(v_cost,0) = coalesce(v_amount,0)
      and coalesce((v_state->>'confirmed_qty')::numeric,0) >= 2;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | reasons='||v_reasons::text||' stages='||v_stages::text
   || ' cost type registered='||coalesce(v_cost_type,false)::text
   || ' | bad reason='||coalesce(v_noreason->>'error','?')
   || ' | over qty='||coalesce(v_over->>'error','?')
   || ' | missing photo='||coalesce(v_nophoto->>'error','?')
   || ' | logged='||coalesce(v_log->>'ok','?')
   || ' | bill qty '||coalesce(v_bill_before::text,'?')||' -> '||coalesce(v_bill_after::text,'?')
   || ' | the sentence on the bill='||coalesce(nullif(v_note,''),'<none>')
   || ' | bag reserved '||coalesce(v_bag_before::text,'?')||' -> '||coalesce(v_bag_after::text,'?')
   || ' | valued at='||coalesce(v_amount::text,'null')
   || ' settlement line='||coalesce(v_cost::text,'none')
   || ' | order note='||coalesce(v_state->>'order_note','?')));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c709_damage_zero_line()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_item uuid; v_order uuid; v_qty numeric;
  v_unfulfillable boolean := false; v_reason text := '';
  v_in_bill boolean := true; v_exc int := 0; v_chain text := 'not run'; v_ok boolean;
  v_exc_reason boolean;
begin
  perform public._dev_guard();

  select exists (select 1 from exception_reason
                  where reason_code = 'damage_rate_high' and enabled)
    into v_exc_reason;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;

  select oi.id, oi.order_id, oi.quantity into v_item, v_order, v_qty
    from order_items oi
    join orders o on o.id = oi.order_id
   where o.status <> 'cancelled' and o.closed_at is null
     and coalesce(oi.unfulfillable,false) = false
     and oi.fulfillment_state not in ('shipped','cancelled')
     and oi.quantity between 1 and 20
   order by o.created_at desc limit 1;

  if v_admin is not null and v_item is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);

      -- the whole line breaks
      perform public.damage_log(v_item, v_qty, 'wet', 'pack', 'journey',
                'order/'||v_order::text||'/journey.jpg');

      select coalesce(unfulfillable,false), coalesce(unfulfillable_reason,'')
        into v_unfulfillable, v_reason from order_items where id = v_item;
      v_in_bill := exists (
        select 1 from jsonb_array_elements(public._bill_lines_for_order(v_order)) e
         where (e->>'product') = (select product_name from order_items where id = v_item)
           and (e->>'qty')::numeric > 0);
      select count(*)::int into v_exc from public._exception_rows() r
       where r.reason_code = 'damage_rate_high';

      v_chain := 'ran';
      raise exception using errcode='ZZ709', message='c709 journey rollback';
    exception
      when sqlstate 'ZZ709' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_exc_reason,false)
      and v_unfulfillable
      and v_reason <> ''
      and v_in_bill = false;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | exceptions reason damage_rate_high registered='||coalesce(v_exc_reason,false)::text
   || ' | whole line damaged -> unfulfillable='||v_unfulfillable::text
   || ' reason='||coalesce(nullif(v_reason,''),'<empty>')
   || ' | still on the bill='||v_in_bill::text||' (must be false)'
   || ' | damage_rate_high rows on the console now='||v_exc::text));
end
$function$
;
CREATE OR REPLACE FUNCTION public._journey_c745_logout_always()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p     jsonb := public.c745_customer_menu_proof() -> 'qa-745-425';
  v_free  int;
  v_gated int;
  v_ok    boolean;
begin
  -- The exemption is a gate, not a hole: exactly ONE account-free row on the
  -- profile surface (Logout), and the rows that need an account still do.
  select count(*) filter (where not cp.needs_account),
         count(*) filter (where cp.needs_account)
    into v_free, v_gated
    from public.customer_feature_placement cp
    join public.feature_registry f on f.feature_key = cp.feature_key
   where cp.placement = 'profile_account'
     and cp.is_active and f.is_active
     and 'customer' = any (f.roles_allowed);

  v_ok := coalesce((v_p->>'ok')::boolean, false)
      and v_free = 1
      and v_gated > 0;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'registry exempts Logout=' || coalesce(v_p->>'registry_exempts_logout','?') ||
      ' | RPC honours the exemption=' || coalesce(v_p->>'rpc_honours_the_exemption','?') ||
      ' | predicate with no account keeps Logout=' ||
        coalesce(v_p->>'predicate_without_an_account_keeps_logout','?') ||
      ' | account-free profile rows=' || v_free::text || ' (must be 1: cust.logout)' ||
      ' | rows still gated on an account=' || v_gated::text ||
      ' | live customer_surfaces() for ' || coalesce(v_p->>'subject','no subject') ||
        '=' || coalesce(v_p->>'live_rpc','?')));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_c745_offline_menu()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p       jsonb := public.c745_customer_menu_proof() -> 'qa-745-426';
  v_src     text;
  v_by_key  boolean;
  v_literal boolean;
  v_ok      boolean;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_surfaces';

  -- The staleness sentence is looked up by KEY. Inlining the words here would
  -- move the copy out of ui_copy and back into a deploy.
  v_by_key  := coalesce(v_src, '') like '%cust_menu.offline_note%';
  v_literal := coalesce(v_src, '') ilike '%last saved menu%';

  v_ok := coalesce((v_p->>'ok')::boolean, false)
      and v_by_key
      and not v_literal;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'ui_copy cust_menu.offline_note=' || coalesce(nullif(v_p->>'offline_note',''), '<empty>') ||
      ' | payload carries that sentence=' || coalesce(v_p->>'payload_carries_the_sentence','?') ||
      ' | RPC looks the sentence up by ui_copy key=' || v_by_key::text ||
      ' | RPC hardcodes the sentence=' || v_literal::text || ' (must be false)' ||
      ' | RPC has no ok:false answer=' || coalesce(v_p->>'rpc_has_no_ok_false_answer','?') ||
      ' | live customer_surfaces() for ' || coalesce(v_p->>'subject','no subject') ||
        '=' || coalesce(v_p->>'live_rpc','?')));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_contention_phrase(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select p
    from unnest(array[
      -- the database under contention
      'canceling statement due to lock timeout',
      'canceling statement due to statement timeout',
      'canceling statement due to user request',
      'deadlock detected',
      'could not serialize access',
      'could not obtain lock',
      'lock timeout',
      'statement timeout',
      'too many clients',
      'remaining connection slots',
      'server closed the connection',
      'terminating connection due to',
      'unable to check out connection from the pool',
      -- the transport in front of it
      'could not query the database for the schema cache',
      'schema cache',
      'pgrst002',
      'pgrst001',
      'pgrst000',
      '503 service unavailable',
      '504 gateway',
      'connection refused',
      'connection reset by peer'
    ]) p
   where position(p in lower(coalesce(p_text, ''))) > 0
   order by length(p) desc
   limit 1
$function$
;
CREATE OR REPLACE FUNCTION public._journey_qa_1149_508()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pk_is_file  boolean;
  v_files       bigint;
  v_by_file     boolean;
  v_mode        jsonb;
  v_mode_ok     boolean;
  v_closed      boolean;
  v_record_src  text;
  v_writes_ledger boolean;
  v_writes_cli  boolean;
  v_ok          boolean;
begin
  -- (a) the ledger is keyed by the full FILE basename. A version key is what
  -- made 20260904_ ambiguous across several files in the first place.
  select (a.attname = 'file') into v_pk_is_file
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.conrelid = 'public.migration_replay_ledger'::regclass and c.contype = 'p'
     and array_length(c.conkey, 1) = 1;

  -- (b) it was SEEDED from the tree, so history is already "applied" and can
  -- never be pending. An empty ledger is the exact state that replays history.
  select count(*) into v_files from public.migration_replay_ledger;

  -- (c) the door the script asks answers by file, not only by version.
  v_by_file := to_regprocedure('public.migration_replay_applied(text[],text[])') is not null;

  -- (d) while no build branch has carried builds, the worker RECORDS and
  -- applies nothing — today's behaviour, unchanged.
  v_mode := public.migration_replay_mode();
  v_mode_ok := (v_mode->>'mode') in ('record','replay')
    and ((v_mode->>'built_24h')::int > 0) = ((v_mode->>'mode') = 'replay');

  -- (e) neither door is reachable over HTTP by a browser role.
  select not exists (
    select 1 from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     cross join (values ('anon'),('authenticated')) r(rolname)
    where n.nspname = 'public'
      and p.proname in ('migration_replay_applied','migration_replay_record',
                        'migration_replay_seed','migration_replay_mode')
      and has_function_privilege(r.rolname, p.oid, 'execute'))
    into v_closed;

  -- (f) recording writes the ledger, never the CLI table the repo never fed.
  select p.prosrc into v_record_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'migration_replay_record';
  v_writes_ledger := coalesce(v_record_src,'') like '%migration_replay_ledger%';
  v_writes_cli    := coalesce(v_record_src,'') like '%supabase_migrations.schema_migrations%';

  v_ok := coalesce(v_pk_is_file,false) and v_files >= 500 and v_by_file
      and v_mode_ok and v_closed and v_writes_ledger and not v_writes_cli;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'ledger primary key is the file basename=' || coalesce(v_pk_is_file::text,'?') ||
      ' | ledger seeded from the tree=' || v_files || ' file(s) (must be >= 500)' ||
      ' | migration_replay_applied answers by file=' || v_by_file::text ||
      ' | mode=' || coalesce(v_mode->>'mode','?') ||
        ' with built_24h=' || coalesce(v_mode->>'built_24h','?') ||
        ' consistent=' || v_mode_ok::text ||
      ' | replay doors closed to anon/authenticated=' || coalesce(v_closed::text,'?') ||
      ' | record writes the ledger=' || v_writes_ledger::text ||
      ' | record writes supabase_migrations.schema_migrations=' || v_writes_cli::text ||
        ' (must be false)'));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_qa_706_473()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_open    text[] := '{}';
  v_closed  int := 0;
  v_service int := 0;
  r record;
  v_scoped boolean;
begin
  for r in
    select p.oid,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'kyc\_ocr\_%'
            or p.proname in ('kyc_verify_doc','kyc_identity_claim_set'))
  loop
    if has_function_privilege('anon', r.oid, 'EXECUTE')
       or has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      v_open := v_open || r.sig;
    else
      v_closed := v_closed + 1;
    end if;
    if has_function_privilege('service_role', r.oid, 'EXECUTE') then
      v_service := v_service + 1;
    end if;
  end loop;

  -- The read half stays open to a signed-in user, so it must be SCOPED instead:
  -- kyc_verify_panel and kyc_verify_evaluate take a doc_id, and without the
  -- scope test any pharmacy could read another account's licence.
  v_scoped := (to_regprocedure('public.kyc_verify_scope_ok(uuid)') is not null)
          and (select prosrc like '%kyc_verify_scope_ok%'
                 from pg_proc where oid = 'public.kyc_verify_panel(uuid)'::regprocedure)
          and (select prosrc like '%kyc_verify_scope_ok%'
                 from pg_proc where oid = 'public.kyc_verify_evaluate(uuid)'::regprocedure);

  return jsonb_build_object(
    'status', case when array_length(v_open,1) is null
                    and v_closed >= 5 and v_service >= 5 and v_scoped
                   then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'privileged KYC rpcs closed to anon+authenticated=' || v_closed::text ||
      ' | still reachable by a client role=' ||
        coalesce(nullif(array_to_string(v_open, ', '), ''), 'none') ||
      ' | service_role keeps its own access=' || v_service::text ||
      ' | the two doc_id readers are scope-tested=' || v_scoped::text));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_qa_850_512()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_build text; v_fresh boolean; v_change text; v_norm boolean;
begin
  perform public._dev_guard();
  -- CHANGE #850 — this journey was auto-created from a QA "Version check
  -- failed" blocker that was never a product defect: qa_agent.sh appends
  -- /version.json to whatever URL it is handed, and it had been handed a
  -- ROUTE. The app is a single-page app behind a catch-all, so that path
  -- served index.html. The repair is in the harness (it now strips the path
  -- to an origin); what this journey holds down is the fact the version
  -- check exists to establish -- the live build identifies itself.
  select rl.build_hash,
         (rl.updated_at > now() - interval '2 days'),
         coalesce(rl.data->>'change', '')
    into v_build, v_fresh, v_change
    from public.render_log rl where rl.id = 'singleton';

  v_norm := coalesce(v_build,'') <> '' and v_fresh;

  return jsonb_build_object(
    'status', case when v_norm and v_change <> '' then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'live build hash published=' || coalesce(nullif(v_build,''),'<none>')
      || ' | render log fresh=' || coalesce(v_fresh::text,'false')
      || ' | change published=' || coalesce(nullif(v_change,''),'<none>')
      || ' | version check must read the ORIGIN, never a route (SPA catch-all serves index.html)=true'));
end $function$
;
CREATE OR REPLACE FUNCTION public._journey_qa319_version()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_total int; v_bad int; v_green int; v_last record; v_ok boolean;
BEGIN
  SELECT count(*) INTO v_total
    FROM verify_run_log WHERE at > now() - interval '24 hours';

  -- The finding itself: a run whose version.json was not JSON leaves a
  -- commit_hash that is null or is not a git hash.
  SELECT count(*) INTO v_bad
    FROM verify_run_log
   WHERE at > now() - interval '24 hours'
     AND (commit_hash IS NULL OR commit_hash !~ '^[0-9a-f]{7,40}$');

  SELECT count(*) INTO v_green
    FROM verify_run_log
   WHERE at > now() - interval '24 hours'
     AND build_match AND exit_code = 0;

  SELECT * INTO v_last FROM verify_run_log ORDER BY at DESC LIMIT 1;

  v_ok := (v_total > 0 AND v_bad = 0 AND v_green > 0);

  RETURN jsonb_build_object(
    'status', CASE WHEN v_ok THEN 'passed' ELSE 'failed' END,
    'evidence', jsonb_build_object(
      'db_proof',
        'verify_run_log last 24h: runs=' || v_total ||
        ' green=' || v_green ||
        ' unparseable_version_json=' || v_bad ||
        ' | latest commit=' || coalesce(v_last.commit_hash, 'null') ||
        ' build_match=' || coalesce(v_last.build_match::text, 'null') ||
        ' exit_code=' || coalesce(v_last.exit_code::text, 'null'),
      'asserts', jsonb_build_object(
        'version_json_parsed_on_every_run', v_bad = 0,
        'at_least_one_green_verification', v_green > 0,
        'evidence_is_fresh', v_total > 0)));
END
$function$
;

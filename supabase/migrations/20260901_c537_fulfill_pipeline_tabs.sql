-- CHANGE #537 — Fulfill is the order pipeline, in 9 tabs, in physical order.
--
--   1 Customer order → 2 Supplier inquiry → 3 Supplier order → 4 Supplier shop
--   → 5 Warehouse → 6 Bag → 7 Pack → 8 Delivery → 9 Dispute
--
-- Nothing inside the stage screens changes. What changes is that the tab BAR
-- stops being nine hand-written Dart widgets and becomes a payload: the tabs,
-- their order, their labels, who may see them and the number on each badge all
-- come from here. A partner sees the same sequence with the tabs their
-- permission matrix does not grant simply absent — the order of the rest is
-- untouched, because the order is sort_order, not an index in Dart.
--
-- Idempotent end to end: a resumed worker may re-run this file.

-- ── 1. A medibo-owned feature can now name its partner twin ──────────────────
-- admin_access() reads owner='medibo' rows; partner_access() reads
-- owner='partner' rows. A stage needs BOTH gates, so the medibo row points at
-- the partner row instead of the two being matched by a naming convention in
-- application code.
alter table public.feature_registry
  add column if not exists partner_feature_key text;

comment on column public.feature_registry.partner_feature_key is
  'CHANGE #537 — for an owner=medibo row, the owner=partner feature_key that '
  'gates the same thing for a region partner. NULL means partners never see it.';

-- ── 1b. The registry gains a fourth surface ─────────────────────────────────
-- 'fulfill_tab' keeps the nine stages OUT of nav_registry (which reads
-- surface='dashboard'), so registering the pipeline does not spray nine new
-- tiles across the dashboard. Additive; the profile clause is preserved.
alter table public.feature_registry
  drop constraint if exists feature_registry_surface_ck;

alter table public.feature_registry
  add constraint feature_registry_surface_ck check (
    (surface = any (array['dashboard'::text, 'profile'::text, 'both'::text,
                          'dev_tools'::text, 'fulfill_tab'::text]))
    and ((surface <> 'profile'::text)
         or ((category = 'identity'::text)
             and (feature_key = any (array['identity.view_profile'::text,
                                           'identity.logout'::text]))))
  );

-- ── 2. Stage 1 had no partner permission at all ─────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   badge_noun, roles_allowed, description)
values
  ('partner.customer_orders', 'Customer orders', 'Orders', 'receipt',
   'customer_orders', 5, 'partner', true, 'none', true, 'orders', 'dashboard',
   'orders', array['admin','super_admin'],
   'Customer orders placed inside the partner zone')
on conflict (feature_key) do nothing;

-- ── 3. The nine stages ──────────────────────────────────────────────────────
-- surface='fulfill_tab' keeps them out of nav_registry (which reads
-- surface='dashboard'), so registering the pipeline does not spray nine new
-- tiles across the dashboard.
--
-- default_access='read' preserves today's behaviour exactly: every admin can
-- see every Fulfill tab unless an admin_permissions row says otherwise.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, partner_feature_key, deep_link, search_terms, description)
values
  ('fulfill.customer_order',   'Customer order',   'Fulfill', 'receipt',      'customer_order',   10, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.customer_orders', '/admin/fulfill/customer_order',   'customer order orders placed',        'Stage 1 — the order the customer placed'),
  ('fulfill.supplier_inquiry', 'Supplier inquiry', 'Fulfill', 'forum',             'supplier_inquiry', 20, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.inquiry',          '/admin/fulfill/supplier_inquiry', 'inquiry waterfall ask supplier',      'Stage 2 — the inquiry engine asking ranked suppliers'),
  ('fulfill.supplier_order',   'Supplier order',   'Fulfill', 'task',        'supplier_order',   30, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.supplier_orders',  '/admin/fulfill/supplier_order',   'supplier order po placed',            'Stage 3 — the order placed on the supplier'),
  ('fulfill.supplier_shop',    'Supplier shop',    'Fulfill', 'store',        'supplier_shop',    40, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.collect',          '/admin/fulfill/supplier_shop',    'collect counting shop pick to light', 'Stage 4 — counting and submitting at the supplier shop'),
  ('fulfill.warehouse',        'Warehouse',        'Fulfill', 'inventory',         'warehouse',        50, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.count',            '/admin/fulfill/warehouse',        'arrivals receiving warehouse count',  'Stage 5 — receiving and counting in the warehouse'),
  ('fulfill.bag',              'Bag',              'Fulfill', 'bag',      'bag',              60, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.bag_mapping',      '/admin/fulfill/bag',              'bag mapping allocation',              'Stage 6 — bag mapping and allocation'),
  ('fulfill.pack',             'Pack',             'Fulfill', 'package',       'pack',             70, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.pack',             '/admin/fulfill/pack',             'pack packing customer wise',          'Stage 7 — packing customer-wise'),
  ('fulfill.delivery',         'Delivery',         'Fulfill', 'truck',    'delivery',         80, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.assign_delivery',  '/admin/fulfill/delivery',         'delivery assign rider run',           'Stage 8 — assigning and running delivery'),
  ('fulfill.dispute',          'Dispute',          'Fulfill', 'alert',    'dispute',          90, 'medibo', false, 'read', true, 'orders', 'fulfill_tab', array['admin','super_admin'], 'partner.disputes',         '/admin/fulfill/dispute',          'dispute short damaged shortage',      'Stage 9 — disputes raised anywhere in the pipeline')
on conflict (feature_key) do update set
  label               = excluded.label,
  group_label         = excluded.group_label,
  icon_key            = excluded.icon_key,
  route_key           = excluded.route_key,
  sort_order          = excluded.sort_order,
  owner               = excluded.owner,
  partner_eligible    = excluded.partner_eligible,
  default_access      = excluded.default_access,
  is_active           = excluded.is_active,
  category            = excluded.category,
  surface             = excluded.surface,
  roles_allowed       = excluded.roles_allowed,
  partner_feature_key = excluded.partner_feature_key,
  deep_link           = excluded.deep_link,
  search_terms        = excluded.search_terms,
  description         = excluded.description;

-- ── 4. Copy ─────────────────────────────────────────────────────────────────
insert into public.app_settings (key, value)
values ('fulfill_tabs_copy', jsonb_build_object(
  'not_authorized',  'You do not have access to the fulfilment pipeline.',
  'empty_title',     'No pipeline stages',
  'empty_message',   'Your permissions do not include any fulfilment stage yet.',
  'badge_overflow',  '99+',
  'all_zones_label', 'All zones'))
on conflict (key) do update set value = public.app_settings.value || excluded.value;

-- ── 5. Badge counts — the EXISTING pipeline queries, nothing re-derived ──────
-- Every call below already honours the ONE admin date picker
-- (admin_active_date() is each function's default argument) and the ONE zone
-- (admin_active_zone(), which returns a partner's own zone first and always).
-- So a badge cannot drift from the list its tab shows: it IS that list.
--
-- Only the stages the caller can actually see are counted, and each stage is
-- wrapped on its own — one slow or refusing pipeline query costs its badge,
-- never the whole tab bar.
create or replace function public.fulfill_stage_counts(p_stages text[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v      jsonb := '{}'::jsonb;
  v_arr  jsonb;
  n      integer;
begin
  if p_stages is null or cardinality(p_stages) = 0 then
    return v;
  end if;

  -- Shop and Warehouse are two numbers out of ONE payload — never two calls.
  if ('supplier_shop' = any (p_stages)) or ('warehouse' = any (p_stages)) then
    begin v_arr := public.fw_list_arrivals(); exception when others then v_arr := null; end;
    if 'supplier_shop' = any (p_stages) then
      v := v || jsonb_build_object('supplier_shop',
             coalesce((v_arr->>'count')::int, 0));
    end if;
    if 'warehouse' = any (p_stages) then
      v := v || jsonb_build_object('warehouse',
             coalesce((v_arr->>'warehouse_count')::int, 0));
    end if;
  end if;

  if 'customer_order' = any (p_stages) then
    begin n := coalesce((public.admin_customer_orders()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('customer_order', n);
  end if;

  if 'supplier_inquiry' = any (p_stages) then
    begin select count(*) into n from public.get_supplier_inquiry_overview();
    exception when others then n := 0; end;
    v := v || jsonb_build_object('supplier_inquiry', coalesce(n, 0));
  end if;

  if 'supplier_order' = any (p_stages) then
    begin n := coalesce((public.admin_supplier_orders()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('supplier_order', n);
  end if;

  if 'bag' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.fw_list_bags()->'bags', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('bag', coalesce(n, 0));
  end if;

  if 'pack' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.pack_list_orders()->'orders', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('pack', coalesce(n, 0));
  end if;

  if 'delivery' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.admin_delivery_queue()->'orders', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('delivery', coalesce(n, 0));
  end if;

  -- The Disputes badge has always been "is_active, verbatim from the backend"
  -- (#132C / #174). Same predicate, same source, now on the server side of it.
  if 'dispute' = any (p_stages) then
    begin
      select count(*) into n
        from jsonb_array_elements(
               coalesce(public.fw_get_disputes()->'disputes', '[]'::jsonb)) d
       where (d->>'is_active')::boolean is true;
    exception when others then n := 0; end;
    v := v || jsonb_build_object('dispute', coalesce(n, 0));
  end if;

  return v;
end
$fn$;

-- ── 6. The tab bar itself ───────────────────────────────────────────────────
create or replace function public.fulfill_tabs()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role    text     := coalesce(public.get_my_role(), 'none');
  v_partner bigint   := public.my_partner_id();
  v_zone    smallint := public.admin_active_zone();
  v_copy    jsonb    := coalesce(
                          (select value from app_settings where key = 'fulfill_tabs_copy'),
                          '{}'::jsonb);
  v_over    text     := coalesce(v_copy->>'badge_overflow', '99+');
  v_stages  text[];
  v_counts  jsonb;
  v_tabs    jsonb;
begin
  if auth.uid() is null or v_role not in ('admin', 'super_admin') then
    return jsonb_build_object(
      'ok', false, 'error', 'not_authorized',
      'tabs', '[]'::jsonb, 'tab_count', 0, 'has_tabs', false,
      'message', coalesce(v_copy->>'not_authorized', ''));
  end if;

  -- Which stages this caller may see. A partner is gated on the partner twin
  -- of the stage; an admin on the stage itself.
  select array_agg(f.route_key order by f.sort_order)
    into v_stages
    from feature_registry f
   where f.is_active
     and f.surface = 'fulfill_tab'
     and v_role = any (f.roles_allowed)
     and case when v_partner is not null
              then f.partner_feature_key is not null
                   and coalesce(public.partner_access(f.partner_feature_key, v_partner), 'none') <> 'none'
              else coalesce(public.admin_access(f.feature_key), 'none') <> 'none'
         end;

  v_stages := coalesce(v_stages, array[]::text[]);
  v_counts := public.fulfill_stage_counts(v_stages);

  select coalesce(jsonb_agg(s.t order by s.sort_order), '[]'::jsonb)
    into v_tabs
    from (
      select f.sort_order,
             jsonb_build_object(
               'stage_key',   f.route_key,
               'feature_key', f.feature_key,
               'label',       f.label,
               'sort',        f.sort_order,
               'icon_key',    coalesce(f.icon_key, ''),
               'deep_link',   coalesce(f.deep_link, ''),
               'access',      acc.a,
               'can_write',   (acc.a = 'write'),
               'badge_count', coalesce((v_counts->>f.route_key)::int, 0),
               'has_badge',   coalesce((v_counts->>f.route_key)::int, 0) > 0,
               'badge_label',
                 case when coalesce((v_counts->>f.route_key)::int, 0) > 99 then v_over
                      when coalesce((v_counts->>f.route_key)::int, 0) > 0
                        then (coalesce((v_counts->>f.route_key)::int, 0))::text
                      else null end
             ) as t
        from feature_registry f
        cross join lateral (
          select case when v_partner is not null
                      then coalesce(public.partner_access(f.partner_feature_key, v_partner), 'none')
                      else coalesce(public.admin_access(f.feature_key), 'none')
                 end as a) acc
       where f.is_active
         and f.surface = 'fulfill_tab'
         and f.route_key = any (v_stages)
    ) s;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'is_partner', (v_partner is not null),
    'partner_id', v_partner,
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from zones z where z.id = v_zone),
                           coalesce(v_copy->>'all_zones_label', '')),
    'date', public.admin_active_date(),
    'tabs', coalesce(v_tabs, '[]'::jsonb),
    'tab_count', jsonb_array_length(coalesce(v_tabs, '[]'::jsonb)),
    'has_tabs', jsonb_array_length(coalesce(v_tabs, '[]'::jsonb)) > 0,
    'empty_title', coalesce(v_copy->>'empty_title', ''),
    'empty_message', coalesce(v_copy->>'empty_message', ''));
end
$fn$;

grant execute on function public.fulfill_stage_counts(text[]) to authenticated;
grant execute on function public.fulfill_tabs() to authenticated;

-- ── 7. The partner fence (CHANGE #352) ──────────────────────────────────────
-- Opt-IN, so a partner reaches this exactly like every other pipeline RPC.
-- clamp_ok: the function clamps itself — partner_access() decides the tabs and
-- admin_active_zone() returns the partner's own zone before anything else.
insert into public.partner_rpc_allow (proname, clamp_ok)
values ('fulfill_tabs', true), ('fulfill_stage_counts', true)
on conflict (proname) do update set clamp_ok = excluded.clamp_ok;

-- ── 8. Where is this order, right now? ──────────────────────────────────────
-- The bar is only half of "readable start-to-end". The other half is tapping
-- an order and landing on the tab where its work actually sits.
--
-- Resolution walks the pipeline BACKWARDS and stops at the furthest evidence
-- the order has left behind, because the furthest thing that happened is where
-- the order is. An ACTIVE dispute outranks all of it: a disputed line is
-- blocked, and the tab that can unblock it is Dispute.
--
-- Every predicate reads a mark the pipeline itself writes, and specifically
-- the mark the matching TAB reads. The first cut of this function used
-- order_items.bag_no for the Bag stage and put all 34 orders in Bag —
-- bag_no is stamped on every line at order time (293 of 293). The Bag tab
-- reads bag_item_counts (fw_list_bags_core), so this reads bag_item_counts,
-- and the two cannot disagree. Same reasoning for the Delivery hand-off:
-- orders.dispatch_ready is what pack_set_dispatch_ready writes, and an order
-- waiting to be assigned is already AT Delivery — that is the tab that
-- assigns it.
create or replace function public.fulfill_order_stage(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role  text := coalesce(public.get_my_role(), 'none');
  v_stage text;
  v_row   record;
begin
  if auth.uid() is null or v_role not in ('admin', 'super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'has', false);
  end if;

  if p_order_id is null or not exists (select 1 from orders o where o.id = p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'order_not_found', 'has', false);
  end if;

  -- 9 · an active dispute blocks everything downstream of it
  if exists (
       select 1 from supplier_disputes d
       join order_items oi on oi.id = d.order_item_id
      where oi.order_id = p_order_id
        and coalesce(d.status, 'open') not in ('resolved', 'cancelled'))
  then
    v_stage := 'dispute';

  -- 8 · handed to delivery, or ready to be
  elsif exists (select 1 from deliveries dl where dl.order_id = p_order_id)
     or exists (select 1 from orders o
                 where o.id = p_order_id and coalesce(o.dispatch_ready, false))
  then
    v_stage := 'delivery';

  -- 7 · packing has begun
  elsif exists (select 1 from order_items oi
                 where oi.order_id = p_order_id
                   and (coalesce(oi.packed, false) or coalesce(oi.packed_qty, 0) > 0))
  then
    v_stage := 'pack';

  -- 6 · counted into a bag — the mark the Bag tab itself reads
  elsif exists (
          select 1 from order_items oi
           where oi.order_id = p_order_id
             and exists (select 1 from bag_item_counts b
                          where b.assigned_supplier = oi.assigned_supplier
                            and b.product_id = oi.product_id
                            and b.qty > 0))
  then
    v_stage := 'bag';

  -- 5 · arrived in the warehouse
  elsif exists (select 1 from order_items oi
                 where oi.order_id = p_order_id and coalesce(oi.at_warehouse, false)) then
    v_stage := 'warehouse';

  -- 4 · counted at the supplier's shop
  elsif exists (select 1 from order_items oi
                 where oi.order_id = p_order_id
                   and (oi.shop_qty is not null or coalesce(oi.collect_locked, false))) then
    v_stage := 'supplier_shop';

  -- 3 · an order was placed on a supplier
  elsif exists (select 1 from supplier_orders so where so.order_id = p_order_id) then
    v_stage := 'supplier_order';

  -- 2 · the inquiry engine is still asking
  elsif exists (select 1 from order_items oi
                 where oi.order_id = p_order_id and oi.inquiry_id is not null) then
    v_stage := 'supplier_inquiry';

  -- 1 · placed, nothing has happened to it yet
  else
    v_stage := 'customer_order';
  end if;

  -- The label and the deep link are the registry's, not this function's, so a
  -- renamed stage renames here too with no deploy.
  select f.label, f.deep_link, f.feature_key
    into v_row
    from feature_registry f
   where f.surface = 'fulfill_tab' and f.route_key = v_stage and f.is_active;

  return jsonb_build_object(
    'ok', true,
    'has', true,
    'order_id', p_order_id,
    'stage_key', v_stage,
    'feature_key', coalesce(v_row.feature_key, ''),
    'label', coalesce(v_row.label, ''),
    'deep_link', coalesce(v_row.deep_link, ''));
end
$fn$;

grant execute on function public.fulfill_order_stage(uuid) to authenticated;

insert into public.partner_rpc_allow (proname, clamp_ok)
values ('fulfill_order_stage', true)
on conflict (proname) do update set clamp_ok = excluded.clamp_ok;

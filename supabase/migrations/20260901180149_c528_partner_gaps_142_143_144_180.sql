-- CHANGE #528 — feature_gaps rows 142/143/144/180 (partner surface, severity=high)
-- Applied 2026-09-01. Idempotent: create-if-not-exists / create-or-replace / on conflict.
create table if not exists public.partner_screen_tab (
  screen      text    not null,
  tab_index   int     not null,
  tab_key     text    not null,
  feature_key text    not null,
  label       text    not null default '',
  sort_order  int     not null default 0,
  primary key (screen, tab_index)
);
alter table public.partner_screen_tab enable row level security;
drop policy if exists partner_screen_tab_read on public.partner_screen_tab;
create policy partner_screen_tab_read on public.partner_screen_tab for select using (true);

insert into public.partner_screen_tab (screen, tab_index, tab_key, feature_key, label, sort_order) values
  ('fulfillment', 0, 'collect',         'partner.collect',         'Supplier Shop', 10),
  ('fulfillment', 1, 'count',           'partner.count',           'Warehouse',     20),
  ('fulfillment', 2, 'bag_mapping',     'partner.bag_mapping',     'Bag',           30),
  ('fulfillment', 3, 'pack',            'partner.pack',            'Pack',          40),
  ('fulfillment', 4, 'disputes',        'partner.disputes',        'Disputes',      50),
  ('fulfillment', 5, 'assign_delivery', 'partner.assign_delivery', 'Delivery',      60),
  ('supplier',    0, 'suppliers',       'medibo.supplier_registry','Suppliers',        10),
  ('supplier',    1, 'inquiry',         'partner.inquiry',         'Supplier Inquiry', 20),
  ('supplier',    2, 'orders',          'partner.supplier_orders', 'Supplier Orders',  30),
  ('supplier',    3, 'pending',         'medibo.supplier_registry','Pending Approval', 40),
  ('supplier',    4, 'leads',           'medibo.supplier_registry','Leads',            50),
  ('supplier',    5, 'staging',         'medibo.supplier_registry','Staging',          60)
on conflict (screen, tab_index) do update
  set tab_key = excluded.tab_key, feature_key = excluded.feature_key,
      label = excluded.label, sort_order = excluded.sort_order;

-- row 142: Disputes was tab index 4 with NO feature_registry key, so no grant
-- could ever govern it. default_access 'none' = invisible until granted.
insert into public.feature_registry
  (feature_key, label, route_key, owner, partner_eligible, default_access, is_active, sort_order, group_label, icon_key)
values
  ('partner.disputes', 'Disputes', 'disputes', 'partner', true, 'none', true, 75, 'Fulfilment', 'forum')
on conflict (feature_key) do update
  set partner_eligible = true, owner = 'partner', is_active = true;

create or replace function public.partner_screen_tabs(p_screen text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_rows jsonb; v_is_partner boolean := public.is_partner();
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'index', t.tab_index, 'key', t.tab_key,
           'label', t.label, 'feature_key', t.feature_key,
           'access', coalesce(public.partner_access(t.feature_key),'none')
         ) order by t.sort_order), '[]'::jsonb)
    into v_rows
    from public.partner_screen_tab t
   where t.screen = p_screen
     and (not v_is_partner
          or coalesce(public.partner_access(t.feature_key),'none') <> 'none');
  return jsonb_build_object(
    'ok', true, 'screen', p_screen,
    'bounded', v_is_partner,
    'tabs', v_rows,
    'zone_id', case when v_is_partner then public.partner_zone_id() end);
end $fn$;
grant execute on function public.partner_screen_tabs(text) to authenticated;

create or replace function public.partner_open(p_feature text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
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
  select t.screen into v_screen from public.partner_screen_tab t
   where t.feature_key = p_feature order by t.sort_order limit 1;
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
end $fn$;

-- rows 144 + 180: the zone clamp goes INSIDE the SECURITY DEFINER body, because
-- RLS is not evaluated there and the round-2 RLS clamp therefore never ran.
create or replace function public.partner_scope_order(
  p_order_id uuid, p_feature text, p_need text default 'read')
returns text
language sql stable security definer set search_path to 'public'
as $fn$
  select public.partner_scope_orders(array[p_order_id], p_feature, coalesce(p_need,'read'))
$fn$;
grant execute on function public.partner_scope_order(uuid, text, text) to authenticated;

-- row 144: pack_get_queue held a role gate but no zone predicate, and
-- get_my_role() answers 'admin' for an allow-listed partner rpc.
create or replace function public.pack_get_queue(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v jsonb; v_items jsonb; v_total int; v_packed int; v_done int; v_start int; v_groups jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  perform public.partner_scope_order(p_order_id, 'partner.pack', 'read');
  v := public._pack_get_queue_core(p_order_id);
  if v ? 'error' then return v; end if;
  v_items  := coalesce(v->'items','[]'::jsonb);
  v_total  := jsonb_array_length(v_items);
  select count(*) into v_packed from jsonb_array_elements(v_items) it
   where (it->>'is_packed')::boolean is true;
  select count(*) into v_done from jsonb_array_elements(v_items) it
   where (it->>'is_done')::boolean is true;
  select coalesce(min(ord), -1) into v_start
  from (select (row_number() over ())::int - 1 as ord, it from jsonb_array_elements(v_items) it) z
  where coalesce((z.it->>'is_done')::boolean, false) = false;
  select coalesce(jsonb_agg(g order by g_is_null, g_bag_no), '[]'::jsonb) into v_groups
  from (
    select (it->>'bag_no' is null) as g_is_null, (it->>'bag_no')::int as g_bag_no,
           jsonb_build_object(
             'bag_no', (it->>'bag_no')::int,
             'header_label', coalesce(it->>'bag_label', v->'labels'->>'no_bag'),
             'item_count', count(*),
             'order_item_ids', jsonb_agg(it->>'order_item_id')) as g
    from jsonb_array_elements(v_items) it
    group by (it->>'bag_no' is null), (it->>'bag_no')::int, it->>'bag_label'
  ) z;
  return v || jsonb_build_object(
    'nav', jsonb_build_object(
      'total', v_total, 'packed', v_packed, 'left', v_total - v_packed,
      'done', v_done, 'done_left', v_total - v_done,
      'bag_count', jsonb_array_length(coalesce(v->'bag_stats','[]'::jsonb)),
      'start_index', case when v_start < 0 then 0 else v_start end,
      'all_packed', (v_start < 0)),
    'bag_groups', v_groups);
end $fn$;

create table if not exists public.partner_rpc_guard_exempt (
  proname  text primary key,
  reason   text not null,
  added_at timestamptz not null default now()
);
insert into public.partner_rpc_guard_exempt (proname, reason) values
  ('partner_home',        'partner-owned rpc: resolves the zone from the caller''s own partner row'),
  ('partner_work_queue',  'partner-owned rpc: resolves the zone from the caller''s own partner row'),
  ('partner_open',        'permission read; returns no order, supplier or money data'),
  ('partner_screen_tabs', 'permission read; returns no order, supplier or money data')
on conflict (proname) do update set reason = excluded.reason;

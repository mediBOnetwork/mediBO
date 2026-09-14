-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2014 — Cart bill summary card + wishlist/suggested rail.
--
-- Two blocks live BELOW the cart item list, inside the page scroll:
--   A. a bill summary card whose every row (label, icon, order, visibility,
--      value or formula, waived flag) is a table row an admin edits;
--   C. fee rows that carry their own popup copy, so tapping one opens a
--      centred dialog the backend wrote;
--   B. a horizontal rail of EXISTING storefront cards whose contents, title
--      and order the backend decides.
--
-- Nothing here is computed in Dart. cart_bill_view() returns finished strings
-- (₹ formatted by inr_money, FREE from ui_copy) and the card prints them.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── A/C/D: the editable bill rows ─────────────────────────────────────────
create table if not exists public.cart_bill_row (
  id             bigserial primary key,
  zone_id        smallint    not null default 0,   -- 0 = every zone
  key            text        not null,
  label          text        not null default '',
  icon           text        not null default 'receipt_long',
  sort_order     int         not null default 100,
  visible        boolean     not null default true,
  value_source   text        not null default 'computed',  -- computed|fixed|formula
  computed_key   text,            -- mrp_total|trade_total|advance|delivery_fee|grand_total
  fixed_amount   numeric(12,2),
  formula        text,            -- e.g. '{trade_total} * 0.02'
  waived         boolean     not null default false,
  hide_when_zero boolean     not null default true,
  tone           text        not null default 'default',   -- default|brand|total
  bold           boolean     not null default false,
  divider_before boolean     not null default false,
  is_fee         boolean     not null default false,
  popup_title    text        not null default '',
  popup_body     text        not null default '',
  popup_dismiss  text        not null default '',
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

create unique index if not exists cart_bill_row_key_zone_uidx
  on public.cart_bill_row (key, zone_id);

alter table public.cart_bill_row enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='cart_bill_row'
                    and policyname='cart_bill_row_no_direct') then
    create policy cart_bill_row_no_direct on public.cart_bill_row
      for select to authenticated using (false);
  end if;
end $$;

-- ── B/D: the rail's own configuration ─────────────────────────────────────
create table if not exists public.cart_rail_config (
  zone_id     smallint    primary key,             -- 0 = every zone
  enabled     boolean     not null default true,
  title       text        not null default '',
  source      text        not null default 'auto', -- auto|wishlist|companions
  max_items   int         not null default 10,
  sort_mode   text        not null default 'backend', -- backend|recent|name
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

alter table public.cart_rail_config enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='cart_rail_config'
                    and policyname='cart_rail_config_no_direct') then
    create policy cart_rail_config_no_direct on public.cart_rail_config
      for select to authenticated using (false);
  end if;
end $$;

-- ── Seed copy (every user-visible word lives here, never in Dart) ─────────
insert into public.ui_copy(key, value) values
  ('cart.bill_title',        '"Bill summary"'::jsonb),
  ('cart.bill_free',         '"FREE"'::jsonb),
  ('cart.bill_empty',        '"Add items to see the bill"'::jsonb),
  ('cart.rail_empty',        '"Nothing to suggest yet"'::jsonb),
  ('admin.cart_bill_title',  '"Cart bill & rail"'::jsonb),
  ('admin_nav.tile_cart_bill','"Cart bill & rail"'::jsonb),
  ('common.ok',              '"OK"'::jsonb),
  ('common.not_authorized',  '"You do not have access to this."'::jsonb)
on conflict (key) do nothing;

-- ── Seed the seven rows the spec names, in order ──────────────────────────
insert into public.cart_bill_row
  (zone_id, key, label, icon, sort_order, value_source, computed_key,
   fixed_amount, waived, hide_when_zero, tone, bold, divider_before, is_fee,
   popup_title, popup_body, popup_dismiss)
values
  (0,'mrp_total','MRP total','local_offer_outlined',10,'computed','mrp_total',
     null,false,true,'default',false,false,false,'','',''),
  (0,'trade_total','Sale price (PTR)','sell_outlined',20,'computed','trade_total',
     null,false,true,'default',false,false,false,'','',''),
  (0,'advance','Advance amount','account_balance_wallet_outlined',30,'computed','advance',
     null,false,true,'brand',true,false,false,'','',''),
  (0,'handling_fee','Handling fee','inventory_2_outlined',40,'fixed',null,
     0,false,true,'default',false,false,true,
     'Handling fee','Covers picking, packing and cold-chain handling for this order.','Got it'),
  (0,'delivery_fee','Delivery fee','local_shipping_outlined',50,'computed','delivery_fee',
     null,false,true,'default',false,false,true,
     'Delivery fee','Charged per delivery to your pharmacy. Waived once the order crosses the free-delivery slab.','Got it'),
  (0,'grand_total','Grand total','receipt_long_outlined',90,'computed','grand_total',
     null,false,false,'total',true,true,false,'','','')
on conflict (key, zone_id) do nothing;

insert into public.cart_rail_config (zone_id, enabled, title, source, max_items, sort_mode)
values (0, true, 'You may also need', 'auto', 10, 'backend')
on conflict (zone_id) do nothing;

-- ── Formula evaluation, whitelisted ───────────────────────────────────────
-- An admin may type a formula over named basket variables. After substitution
-- only digits, the four operators, brackets, a dot and spaces may remain — a
-- formula that fails the whitelist is worth 0, never an error that breaks a
-- cart.
create or replace function public._cart_bill_eval(p_formula text, p_vars jsonb)
returns numeric
language plpgsql
immutable
set search_path to 'public'
as $$
declare v_expr text := coalesce(p_formula, ''); k text; v_out numeric;
begin
  if btrim(v_expr) = '' then return 0; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_expr := replace(v_expr, '{' || k || '}',
                      coalesce((p_vars->>k), '0'));
  end loop;
  if v_expr !~ '^[0-9+\-*/(). ]+$' then return 0; end if;
  begin
    execute 'select (' || v_expr || ')::numeric' into v_out;
  exception when others then
    return 0;
  end;
  return round(coalesce(v_out, 0), 2);
end $$;

-- ── The customer-facing read ──────────────────────────────────────────────
create or replace function public.cart_bill_view(p_guest_uid uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_cust      uuid;
  v_zone      smallint;
  v_totals    jsonb;
  v_mrp       numeric := 0;
  v_trade     numeric := 0;
  v_deliv     numeric := 0;
  v_items     int     := 0;
  v_units     int     := 0;
  v_adv       jsonb;
  v_adv_amt   numeric := 0;
  v_vars      jsonb;
  v_fees      numeric := 0;
  v_grand     numeric := 0;
  r           record;
  v_amt       numeric;
  v_waived    boolean;
  v_rows      jsonb := '[]'::jsonb;
  v_free      text  := public._c('cart.bill_free');
  v_ids       bigint[];
  v_rail      jsonb;
begin
  v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                     public.my_customer_id());

  if v_cust is null then
    return jsonb_build_object(
      'ok', true,
      'bill', jsonb_build_object('has', false, 'title', public._c('cart.bill_title'),
                                 'empty_note', public._c('cart.bill_empty'),
                                 'rows', '[]'::jsonb),
      'rail', jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb));
  end if;

  select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;

  v_totals := public.cart_totals_for(v_cust);
  v_mrp    := coalesce((v_totals->>'mrp_total')::numeric, 0);
  v_trade  := coalesce((v_totals->>'trade_total')::numeric, 0);
  v_deliv  := coalesce((v_totals->>'delivery_fee')::numeric, 0);
  v_items  := coalesce((v_totals->>'item_count')::int, 0);
  v_units  := coalesce((v_totals->>'unit_count')::int, 0);

  begin
    v_adv     := public.advance_pct_for(v_cust, v_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv_amt := 0;
  end;

  v_vars := jsonb_build_object(
    'mrp_total',    v_mrp,
    'trade_total',  v_trade,
    'delivery_fee', v_deliv,
    'advance',      v_adv_amt,
    'item_count',   v_items,
    'unit_count',   v_units);

  -- Pass 1: every fee row, so the grand total knows what it is adding.
  for r in
    select * from public.cart_bill_row b
     where b.visible
       and b.is_fee
       and b.zone_id in (0, coalesce(v_zone, 0))
       and not exists (select 1 from public.cart_bill_row z
                        where z.key = b.key and z.zone_id = coalesce(v_zone, 0)
                          and b.zone_id = 0 and coalesce(v_zone,0) <> 0)
  loop
    v_amt := case r.value_source
               when 'fixed'   then coalesce(r.fixed_amount, 0)
               when 'formula' then public._cart_bill_eval(r.formula, v_vars)
               else coalesce((v_vars->>coalesce(r.computed_key,''))::numeric, 0)
             end;
    v_waived := r.waived or (r.computed_key = 'delivery_fee' and v_deliv = 0 and v_items > 0);
    if not v_waived then v_fees := v_fees + v_amt; end if;
  end loop;

  v_grand := round(v_trade + v_fees, 2);
  v_vars  := v_vars || jsonb_build_object('grand_total', v_grand, 'fees_total', v_fees);

  -- Pass 2: render every row in the admin's order.
  for r in
    select * from public.cart_bill_row b
     where b.visible
       and b.zone_id in (0, coalesce(v_zone, 0))
       and not exists (select 1 from public.cart_bill_row z
                        where z.key = b.key and z.zone_id = coalesce(v_zone, 0)
                          and b.zone_id = 0 and coalesce(v_zone,0) <> 0)
     order by b.sort_order, b.key
  loop
    v_amt := case r.value_source
               when 'fixed'   then coalesce(r.fixed_amount, 0)
               when 'formula' then public._cart_bill_eval(r.formula, v_vars)
               else coalesce((v_vars->>coalesce(r.computed_key,''))::numeric, 0)
             end;
    v_waived := r.waived or (r.computed_key = 'delivery_fee' and v_deliv = 0 and v_items > 0);

    -- "Rows worth zero or not applicable hide themselves" — a waived fee is
    -- NOT worth zero, it is worth its struck amount plus the word FREE.
    continue when r.hide_when_zero and v_amt = 0 and not v_waived;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key',            r.key,
      'label',          r.label,
      'icon',           r.icon,
      'value',          case when v_waived then '' else public.inr_money(v_amt) end,
      'struck_value',   case when v_waived then public.inr_money(v_amt) else '' end,
      'free_label',     case when v_waived then v_free else '' end,
      'waived',         v_waived,
      'tone',           r.tone,
      'bold',           r.bold,
      'divider_before', r.divider_before,
      'tappable',       (btrim(r.popup_title) <> '' or btrim(r.popup_body) <> ''),
      'popup',          jsonb_build_object(
                          'title',   r.popup_title,
                          'body',    r.popup_body,
                          'dismiss', case when btrim(r.popup_dismiss) = ''
                                          then public._c('common.ok') else r.popup_dismiss end)));
  end loop;

  -- ── B. the rail ────────────────────────────────────────────────────────
  select coalesce(array_agg(distinct ci.product_id::bigint), '{}')
    into v_ids
    from public.cart_items ci
   where ci.customer_id = v_cust
     and coalesce(ci.removed_by_admin, false) = false
     and ci.product_id ~ '^[0-9]+$';

  v_rail := public.cart_rail_block(v_cust, v_zone, v_ids);

  return jsonb_build_object(
    'ok', true,
    'bill', jsonb_build_object(
      'has',        jsonb_array_length(v_rows) > 0,
      'title',      public._c('cart.bill_title'),
      'empty_note', public._c('cart.bill_empty'),
      'rows',       v_rows),
    'rail', v_rail);
end $$;

-- ── B. rail contents, title and order — all the backend's decision ────────
create or replace function public.cart_rail_block(
  p_customer_id uuid, p_zone_id smallint, p_cart_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_cfg   record;
  v_disc  numeric;
  v_items jsonb := '[]'::jsonb;
  v_uid   uuid;
  v_ids   bigint[] := coalesce(p_cart_ids, '{}'::bigint[]);
begin
  select * into v_cfg from public.cart_rail_config
   where zone_id = coalesce(p_zone_id, 0);
  if v_cfg is null then
    select * into v_cfg from public.cart_rail_config where zone_id = 0;
  end if;
  if v_cfg is null or not v_cfg.enabled then
    return jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb,
                              'empty_note', public._c('cart.rail_empty'));
  end if;

  v_disc := public._c791_safe_discount_pct();
  v_uid  := coalesce(public.viewer_cart_user(), auth.uid());

  -- The card block is the SAME storefront_pricing / storefront_cta pair the
  -- catalogue grid reads, so a rail card and a grid card cannot disagree.
  if v_cfg.source in ('auto', 'wishlist') then
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_items
    from (
      select row_number() over (order by w.created_at desc) as ord,
             jsonb_build_object(
               'id',           m.id,
               'name',         coalesce(m.product_name, ''),
               'company',      coalesce(m.marketer, ''),
               'pack_label',   coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                                        nullif(btrim(coalesce(m.pack_size,'')),''), ''),
               'form_chip',    coalesce(nullif(btrim(coalesce(m.pack_qty,'')),''),
                                        nullif(btrim(coalesce(m.pack_size,'')),''), ''),
               'image',        coalesce(m.image_url_1, ''),
               'pricing',      public.storefront_pricing(
                                 nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                                 v_disc, m.id),
               'availability', public.storefront_cta(
                                 public.storefront_effective_count(m.id, m.supplier_count), true)) as x
        from public.wishlist_items w
        join public."MEDICINE" m on m.id = w.product_id
       where w.account_id = v_uid
         and m.buyable is true
         and not (m.id = any (v_ids))
       order by w.created_at desc
       limit greatest(coalesce(v_cfg.max_items, 10), 1)
    ) s;
  end if;

  -- 'auto' tops a short wishlist up with the co-purchase companions the cart
  -- already computes, so the rail is never a lonely single card.
  if v_cfg.source in ('auto', 'companions')
     and jsonb_array_length(v_items) < greatest(coalesce(v_cfg.max_items, 10), 1) then
    declare
      v_comp jsonb := public.cart_companions(v_ids);
      v_have bigint[];
    begin
      select coalesce(array_agg((e->>'id')::bigint), '{}') into v_have
        from jsonb_array_elements(v_items) e;
      select v_items || coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_items
        from jsonb_array_elements(coalesce(v_comp->'items', '[]'::jsonb))
             with ordinality t(e, ord)
       where not ((e->>'id')::bigint = any (coalesce(v_have, '{}'::bigint[])));
    end;
  end if;

  -- Last resort for 'auto': a new pharmacy has no wishlist and a one-line cart
  -- has no co-purchase history, and an empty rail is worse than a relevant one.
  -- The widely-stocked buyable catalogue is the honest fallback — still the
  -- backend deciding, still the same card block.
  if v_cfg.source = 'auto'
     and jsonb_array_length(v_items) < greatest(coalesce(v_cfg.max_items, 10), 1) then
    declare
      v_have2 bigint[];
      v_more  jsonb;
    begin
      select coalesce(array_agg((e->>'id')::bigint), '{}') into v_have2
        from jsonb_array_elements(v_items) e;
      select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_more
      from (
        select row_number() over (order by coalesce(m.supplier_count, 0) desc, m.id) as ord,
               jsonb_build_object(
                 'id',           m.id,
                 'name',         coalesce(m.product_name, ''),
                 'company',      coalesce(m.marketer, ''),
                 'pack_label',   coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                                          nullif(btrim(coalesce(m.pack_size,'')),''), ''),
                 'form_chip',    coalesce(nullif(btrim(coalesce(m.pack_qty,'')),''),
                                          nullif(btrim(coalesce(m.pack_size,'')),''), ''),
                 'image',        coalesce(m.image_url_1, ''),
                 'pricing',      public.storefront_pricing(
                                   nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                                   v_disc, m.id),
                 'availability', public.storefront_cta(
                                   public.storefront_effective_count(m.id, m.supplier_count), true)) as x
          from public."MEDICINE" m
         where m.buyable is true
           and not (m.id = any (v_ids))
           and not (m.id = any (coalesce(v_have2, '{}'::bigint[])))
         order by coalesce(m.supplier_count, 0) desc, m.id
         limit greatest(coalesce(v_cfg.max_items, 10), 1)
      ) s;
      v_items := v_items || v_more;
    end;
  end if;

  if jsonb_array_length(v_items) > greatest(coalesce(v_cfg.max_items, 10), 1) then
    select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_items
      from (select e, ord from jsonb_array_elements(v_items) with ordinality t(e, ord)
             order by ord
             limit greatest(coalesce(v_cfg.max_items, 10), 1)) s;
  end if;

  return jsonb_build_object(
    'has',        jsonb_array_length(v_items) > 0,
    'title',      v_cfg.title,
    'empty_note', public._c('cart.rail_empty'),
    'items',      v_items);
end $$;

-- ── D. the admin surface ──────────────────────────────────────────────────
create or replace function public.admin_cart_bill_list()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role text := public.get_my_role();
  v_zone smallint;
  v_rows jsonb;
  v_cfg  jsonb;
begin
  if v_role not in ('admin', 'super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('common.not_authorized'));
  end if;

  v_zone := public.admin_active_zone();

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'zone_id', b.zone_id, 'key', b.key, 'label', b.label,
           'icon', b.icon, 'sort_order', b.sort_order, 'visible', b.visible,
           'value_source', b.value_source, 'computed_key', coalesce(b.computed_key,''),
           'fixed_amount', coalesce(b.fixed_amount, 0), 'formula', coalesce(b.formula,''),
           'waived', b.waived, 'hide_when_zero', b.hide_when_zero,
           'tone', b.tone, 'bold', b.bold, 'divider_before', b.divider_before,
           'is_fee', b.is_fee, 'popup_title', b.popup_title,
           'popup_body', b.popup_body, 'popup_dismiss', b.popup_dismiss)
           order by b.sort_order, b.key), '[]'::jsonb)
    into v_rows
    from public.cart_bill_row b
   where b.zone_id in (0, coalesce(v_zone, 0));

  select to_jsonb(c) into v_cfg from (
    select zone_id, enabled, title, source, max_items, sort_mode
      from public.cart_rail_config
     where zone_id in (0, coalesce(v_zone, 0))
     order by (zone_id = coalesce(v_zone, 0)) desc
     limit 1) c;

  return jsonb_build_object(
    'ok', true,
    'title',      public._c('admin.cart_bill_title'),
    'zone_id',    coalesce(v_zone, 0),
    'as_of',      to_char(public.admin_active_date(), 'DD Mon YYYY'),
    -- The one line the screen prints about scope: which zone these rows apply
    -- to and which day the admin is looking at. Worded here, never in Dart.
    'zone_line',  case when v_zone is null then 'All zones'
                       else 'Zone ' || v_zone::text end
                  || ' · ' || to_char(public.admin_active_date(), 'DD Mon YYYY'),
    'rows',       v_rows,
    'rail',       coalesce(v_cfg, '{}'::jsonb),
    'sources',    jsonb_build_array('computed','fixed','formula'),
    'tones',      jsonb_build_array('default','brand','total'),
    'rail_sources', jsonb_build_array('auto','wishlist','companions'),
    -- Every field caption this screen draws. A caption changes with an UPDATE
    -- here, never with a deploy.
    'labels', jsonb_build_object(
      'label',          'Row label',
      'icon',           'Icon name',
      'sort_order',     'Display order',
      'visible',        'Show this row',
      'value_source',   'Value from',
      'fixed_amount',   'Fixed amount (₹)',
      'formula',        'Formula',
      'tone',           'Tone',
      'waived',         'Waived (struck through + FREE)',
      'bold',           'Bold',
      'divider_before', 'Divider above',
      'popup_title',    'Popup title',
      'popup_body',     'Popup description',
      'popup_dismiss',  'Popup dismiss button',
      'rail_enabled',   'Show the suggested rail',
      'rail_title',     'Rail title',
      'rail_source',    'Rail contents',
      'rail_max',       'Maximum cards',
      'save',           'Save',
      'retry',          'Retry',
      'rows_heading',   'Bill rows',
      'rail_heading',   'Suggested rail'));
end $$;

create or replace function public.admin_cart_bill_save(p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_role text := public.get_my_role();
  v_id   bigint := nullif(p_row->>'id','')::bigint;
begin
  if v_role not in ('admin', 'super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('common.not_authorized'));
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'bad_request',
                              'message', 'row id missing');
  end if;

  update public.cart_bill_row set
    label          = coalesce(p_row->>'label', label),
    icon           = coalesce(nullif(p_row->>'icon',''), icon),
    sort_order     = coalesce(nullif(p_row->>'sort_order','')::int, sort_order),
    visible        = coalesce((p_row->>'visible')::boolean, visible),
    value_source   = coalesce(nullif(p_row->>'value_source',''), value_source),
    computed_key   = coalesce(p_row->>'computed_key', computed_key),
    fixed_amount   = coalesce(nullif(p_row->>'fixed_amount','')::numeric, fixed_amount),
    formula        = coalesce(p_row->>'formula', formula),
    waived         = coalesce((p_row->>'waived')::boolean, waived),
    hide_when_zero = coalesce((p_row->>'hide_when_zero')::boolean, hide_when_zero),
    tone           = coalesce(nullif(p_row->>'tone',''), tone),
    bold           = coalesce((p_row->>'bold')::boolean, bold),
    divider_before = coalesce((p_row->>'divider_before')::boolean, divider_before),
    popup_title    = coalesce(p_row->>'popup_title', popup_title),
    popup_body     = coalesce(p_row->>'popup_body', popup_body),
    popup_dismiss  = coalesce(p_row->>'popup_dismiss', popup_dismiss),
    updated_at     = now(),
    updated_by     = auth.uid()
  where id = v_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
                              'message', 'row not found');
  end if;
  return public.admin_cart_bill_list();
end $$;

create or replace function public.admin_cart_rail_save(p_cfg jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_role text := public.get_my_role();
  v_zone smallint := coalesce(nullif(p_cfg->>'zone_id','')::smallint, 0);
begin
  if v_role not in ('admin', 'super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('common.not_authorized'));
  end if;

  insert into public.cart_rail_config (zone_id, enabled, title, source, max_items, sort_mode, updated_at, updated_by)
  values (v_zone,
          coalesce((p_cfg->>'enabled')::boolean, true),
          coalesce(p_cfg->>'title', ''),
          coalesce(nullif(p_cfg->>'source',''), 'auto'),
          coalesce(nullif(p_cfg->>'max_items','')::int, 10),
          coalesce(nullif(p_cfg->>'sort_mode',''), 'backend'),
          now(), auth.uid())
  on conflict (zone_id) do update set
    enabled    = excluded.enabled,
    title      = excluded.title,
    source     = excluded.source,
    max_items  = excluded.max_items,
    sort_mode  = excluded.sort_mode,
    updated_at = now(),
    updated_by = auth.uid();

  return public.admin_cart_bill_list();
end $$;

-- ── Grants. The cart view is for signed-in customers only (it reads a cart);
--    the admin doors gate on get_my_role() and are never reachable by anon.
revoke all on function public.cart_bill_view(uuid)            from public, anon;
revoke all on function public.cart_rail_block(uuid, smallint, bigint[]) from public, anon;
revoke all on function public._cart_bill_eval(text, jsonb)    from public, anon;
revoke all on function public.admin_cart_bill_list()          from public, anon;
revoke all on function public.admin_cart_bill_save(jsonb)     from public, anon;
revoke all on function public.admin_cart_rail_save(jsonb)     from public, anon;

grant execute on function public.cart_bill_view(uuid)         to authenticated;
grant execute on function public.admin_cart_bill_list()       to authenticated;
grant execute on function public.admin_cart_bill_save(jsonb)  to authenticated;
grant execute on function public.admin_cart_rail_save(jsonb)  to authenticated;

-- ── The admin door, registered where every other admin door lives ─────────
-- CHANGE #325/#570: an admin screen is a feature_registry row plus a
-- surface_route row plus one case in shell_extra_routes.dart. There is no list
-- in Dart to append a tile to any more, and rg_check fails on a registered
-- tile with no declared route — so both rows are written here.
-- `receipt` is already a glyph navIcon() knows (Icons.receipt_long_outlined);
-- it was simply never registered, and feature_registry.icon_key is a FK.
insert into public.ui_icon (icon_key, label)
values ('receipt', 'Receipt')
on conflict (icon_key) do nothing;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, search_terms, description)
values
  ('admin.cart_bill', 'Cart bill & rail', 'Catalogue & pricing', 'receipt',
   'cart_bill', 70, 'medibo', false, 'none', true, 'more_catalogue', 'dashboard',
   array['admin','super_admin'],
   'cart bill summary handling delivery fee advance grand total popup wishlist rail suggested',
   'The cart bill summary rows and the suggested rail: labels, icons, order, fee amounts and popup copy, all editable without a deploy.')
on conflict (feature_key) do update set
  label        = excluded.label,
  group_label  = excluded.group_label,
  icon_key     = excluded.icon_key,
  route_key    = excluded.route_key,
  category     = excluded.category,
  surface      = excluded.surface,
  is_active    = true,
  description  = excluded.description;

insert into public.surface_route (route_key, feature_key, kind, handled_by, note)
values ('cart_bill', 'admin.cart_bill', 'feature', 'shell_extra_routes',
        'CMD #2014 — AdminCartBillScreen')
on conflict (route_key, feature_key) do update set

  handled_by  = excluded.handled_by,
  is_active   = true,
  updated_at  = now();

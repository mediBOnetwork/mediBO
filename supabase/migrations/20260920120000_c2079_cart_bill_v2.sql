-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2079 — the cart's bill becomes a Blinkit-style "Bill details" card, the
-- suggested rail becomes the customer's own Wishlist, and BOTH follow every
-- quantity tap instantly.
--
-- #2014 built the config table and #2047 put the blocks on cart_render()'s own
-- payload. What was still wrong:
--   * the rail was 'You may also need' (auto: wishlist → companions → widely
--     stocked), which is a suggestion engine, not the customer's wishlist;
--   * the card showed a Grand total the customer cannot be billed yet and did
--     not show the four fees a storefront is expected to waive out loud;
--   * a quantity tap re-priced the BAR (cart_update_item's summary) but not
--     the CARD — the bill only moved on a full cart_render();
--   * the floating pill's thumbnails were only ever built by cart_render(), so
--     an add/remove from a grid left the pill showing the previous basket.
--
-- Everything below is still config: the fee amounts, whether a fee is struck
-- through and shown FREE, the popup each fee opens, the rail's title and its
-- source are rows a super admin edits in Cart bill & rail. Nothing new is
-- worded, formatted or decided in Dart.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0. The table gains one idea: a row whose value may be a SENTENCE ───────
-- The sale-price line can only print ₹ when every line in the basket has a PTR
-- on record. When it does not, the honest answer is the backend's own sentence
-- ("Confirmed on bill"), not a number that would be wrong. Which condition and
-- which sentence are both stored, so the wording changes with an UPDATE.
alter table public.cart_bill_row
  add column if not exists fallback_when text not null default '',
  add column if not exists fallback_text text not null default '';

comment on column public.cart_bill_row.fallback_when is
  'empty = never; ''ptr_incomplete'' = print fallback_text instead of the amount when any cart line has no PTR in medicine_pricing';

-- ── 1. The rail IS the wishlist ───────────────────────────────────────────
insert into public.cart_rail_config (zone_id, enabled, title, source, max_items, sort_mode)
values (0, true, 'Wishlist', 'wishlist', 10, 'backend')
on conflict (zone_id) do update set
  enabled   = true,
  title     = 'Wishlist',
  source    = 'wishlist',
  updated_at= now();

-- ── 2. The card's own words ───────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('cart.bill_title', '"Bill details"'::jsonb),
  ('cart.bill_free',  '"FREE"'::jsonb)
on conflict (key) do update set value = excluded.value;

insert into public.ui_copy(key, value) values
  ('cart.rail_empty', '"Nothing on your wishlist yet"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ── 3. The rows the spec names, in the spec's order ───────────────────────
-- upsert, not "do nothing": #2014's seed is already on live and this command
-- is what changes it.
insert into public.cart_bill_row
  (zone_id, key, label, icon, sort_order, value_source, computed_key,
   fixed_amount, waived, hide_when_zero, tone, bold, divider_before, is_fee,
   popup_title, popup_body, popup_dismiss, fallback_when, fallback_text)
values
  (0,'mrp_total','MRP total','local_offer_outlined',10,'computed','mrp_total',
     null,false,false,'default',false,false,false,'','','','',''),

  (0,'trade_total','Sale price total','sell_outlined',20,'computed','trade_total',
     null,false,false,'default',false,false,false,'','','',
     'ptr_incomplete','Confirmed on bill'),

  (0,'handling_fee','Handling fee','inventory_2_outlined',30,'fixed',null,
     19,true,false,'default',false,true,true,
     'Handling fee',
     'What we spend picking your order off the shelf, checking batch and expiry, and keeping it in the right conditions until it is packed. It is waived on every order right now.',
     'Got it','',''),

  (0,'packaging_fee','Packaging fee','inventory_outlined',40,'fixed',null,
     9,true,false,'default',false,false,true,
     'Packaging fee',
     'Tamper-evident boxes, bubble wrap and the seal that tells you the box was not opened on the way. It is waived on every order right now.',
     'Got it','',''),

  (0,'delivery_fee','Delivery fee','local_shipping_outlined',50,'fixed',null,
     29,true,false,'default',false,false,true,
     'Delivery fee',
     'The cost of running the trip to your pharmacy — fuel, the rider and the route. It is waived on every order right now.',
     'Got it','',''),

  (0,'platform_fee','Platform fee','devices_outlined',60,'fixed',null,
     19,true,false,'default',false,false,true,
     'Platform fee',
     'What it costs to run mediBO — the app, the order desk and the payment rails. It is waived on every order right now.',
     'Got it','',''),

  (0,'advance','Advance to pay','account_balance_wallet_outlined',90,'computed','advance',
     null,false,false,'total',true,true,false,'','','','','')
on conflict (key, zone_id) do update set
  label          = excluded.label,
  icon           = excluded.icon,
  sort_order     = excluded.sort_order,
  value_source   = excluded.value_source,
  computed_key   = excluded.computed_key,
  fixed_amount   = excluded.fixed_amount,
  waived         = excluded.waived,
  hide_when_zero = excluded.hide_when_zero,
  tone           = excluded.tone,
  bold           = excluded.bold,
  divider_before = excluded.divider_before,
  is_fee         = excluded.is_fee,
  popup_title    = excluded.popup_title,
  popup_body     = excluded.popup_body,
  popup_dismiss  = excluded.popup_dismiss,
  fallback_when  = excluded.fallback_when,
  fallback_text  = excluded.fallback_text,
  visible        = true,
  updated_at     = now();

-- Grand total is gone from the card. The row is hidden, not deleted: a zone
-- that re-enables it keeps its own copy, and nothing an admin edited is lost.
update public.cart_bill_row set visible = false, updated_at = now()
 where key = 'grand_total';

-- ── 4. Is every line in this basket priced? ───────────────────────────────
-- True only when the basket has lines AND each one resolves to a
-- medicine_pricing row carrying a PTR. An unpriced line makes the sale-price
-- row print its sentence instead of a number.
create or replace function public._cart_ptr_complete(p_cart jsonb)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  with ids as (
    select distinct (e->>'product_id')::bigint as id
      from jsonb_array_elements(coalesce(p_cart->'items','[]'::jsonb)) e
     where (e->>'product_id') ~ '^[0-9]+$'
  )
  select count(*) > 0
     and count(*) filter (
           where exists (select 1 from public.medicine_pricing mp
                          where mp.product_id = ids.id
                            and mp.ptr is not null
                            and mp.ptr > 0)) = count(*)
    from ids;
$$;

revoke all on function public._cart_ptr_complete(jsonb) from public, anon;

-- ── 5. The card core, rebuilt around the two new ideas ────────────────────
create or replace function public._cart_bill_core(
  p_cart jsonb, p_cust uuid, p_zone smallint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_totals  jsonb;
  v_mrp     numeric := 0;
  v_trade   numeric := 0;
  v_deliv   numeric := 0;
  v_items   int     := 0;
  v_units   int     := 0;
  v_adv_amt numeric := 0;
  v_adv     jsonb;
  v_vars    jsonb;
  v_rows    jsonb   := '[]'::jsonb;
  v_free    text    := public._c('cart.bill_free');
  v_ids     bigint[] := '{}'::bigint[];
  v_rail    jsonb;
  r         record;
  v_amt     numeric;
  v_waived  boolean;
  v_ptr_ok  boolean := false;
  v_text    text;
begin
  p_cart := coalesce(p_cart, '{}'::jsonb);

  if p_cust is not null then
    begin
      v_totals := public.cart_totals_for(p_cust);
    exception when others then
      v_totals := null;
    end;
  end if;

  v_mrp := coalesce((v_totals->>'mrp_total')::numeric,
                    (p_cart->>'mrp_total')::numeric, 0);
  v_trade := coalesce((v_totals->>'trade_total')::numeric,
                      (p_cart#>>'{pricing,net_payable}')::numeric,
                      (p_cart#>>'{render,items_total}')::numeric, 0);
  v_deliv := coalesce((v_totals->>'delivery_fee')::numeric,
                      (p_cart#>>'{delivery,total}')::numeric, 0);
  v_items := coalesce((v_totals->>'item_count')::int,
                      (p_cart->>'item_count')::int, 0);
  v_units := coalesce((v_totals->>'unit_count')::int,
                      (p_cart->>'unit_count')::int, 0);

  if p_cust is not null then
    begin
      v_adv     := public.advance_pct_for(p_cust, p_zone);
      v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
    exception when others then
      v_adv_amt := 0;
    end;
  end if;

  begin
    v_ptr_ok := public._cart_ptr_complete(p_cart);
  exception when others then
    v_ptr_ok := false;
  end;

  v_vars := jsonb_build_object(
    'mrp_total',    v_mrp,
    'trade_total',  v_trade,
    'delivery_fee', v_deliv,
    'advance',      v_adv_amt,
    'item_count',   v_items,
    'unit_count',   v_units,
    'grand_total',  round(v_trade, 2),
    'fees_total',   0);

  for r in
    select * from public.cart_bill_row b
     where b.visible
       and b.zone_id in (0, coalesce(p_zone, 0))
       and not exists (select 1 from public.cart_bill_row z
                        where z.key = b.key and z.zone_id = coalesce(p_zone, 0)
                          and b.zone_id = 0 and coalesce(p_zone,0) <> 0)
     order by b.sort_order, b.key
  loop
    v_amt := case r.value_source
               when 'fixed'   then coalesce(r.fixed_amount, 0)
               when 'formula' then public._cart_bill_eval(r.formula, v_vars)
               else coalesce((v_vars->>coalesce(r.computed_key,''))::numeric, 0)
             end;
    v_waived := r.waived;

    -- A row may answer in words instead of rupees. When it does it is never
    -- struck through and never hidden: a sentence IS the value.
    v_text := case when r.fallback_when = 'ptr_incomplete' and not v_ptr_ok
                   then r.fallback_text else '' end;

    continue when v_text = '' and r.hide_when_zero and v_amt = 0 and not v_waived;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key',            r.key,
      'label',          r.label,
      'icon',           r.icon,
      'value',          case when v_text <> '' then v_text
                             when v_waived     then ''
                             else public.inr_money(v_amt) end,
      'is_text',        (v_text <> ''),
      'struck_value',   case when v_text = '' and v_waived
                             then public.inr_money(v_amt) else '' end,
      'free_label',     case when v_text = '' and v_waived then v_free else '' end,
      'waived',         (v_text = '' and v_waived),
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

  select coalesce(array_agg(distinct (e->>'product_id')::bigint), '{}')
    into v_ids
    from jsonb_array_elements(coalesce(p_cart->'items','[]'::jsonb)) e
   where (e->>'product_id') ~ '^[0-9]+$';

  if p_cust is not null then
    begin
      v_rail := public.cart_rail_block(p_cust, p_zone, v_ids);
    exception when others then
      v_rail := null;
    end;
  end if;

  return jsonb_build_object(
    'bill', jsonb_build_object(
      'has',        jsonb_array_length(v_rows) > 0 and v_items > 0,
      'title',      public._c('cart.bill_title'),
      'empty_note', public._c('cart.bill_empty'),
      'ptr_complete', v_ptr_ok,
      'rows',       v_rows),
    'rail', coalesce(v_rail, jsonb_build_object(
      'has', false, 'title', '', 'items', '[]'::jsonb,
      'empty_note', public._c('cart.rail_empty'))));
end $$;

revoke all on function public._cart_bill_core(jsonb, uuid, smallint) from public, anon;

-- ── 6. A quantity tap re-prices the CARD and the PILL, not just the bar ───
-- The fast write door keeps its shape (ok / item / summary) and its speed: the
-- bill and the pill are built from the rows this statement has already read,
-- inside the same call, and both are best-effort — a card that cannot be built
-- must never cost the customer the tap.
create or replace function public.cart_update_item(
  p_product_id text, p_quantity integer, p_guest_uid uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  w         jsonb;
  v_uid     uuid;
  v_cust    uuid;
  v_item    jsonb;
  v_lines   int := 0;
  v_units   int := 0;
  v_mrp     numeric := 0;
  v_zone    smallint;
  v_adv     jsonb;
  v_adv_amt numeric := 0;
  v_all     jsonb := '[]'::jsonb;
  v_bill    jsonb;
  v_pill    jsonb;
  v_retry   jsonb := jsonb_build_object('label', public._c('cart.row_retry'),
                                        'note',  public._c('cart.row_save_failed'));
begin
  w := public._cart_write_item(p_product_id, p_quantity, p_guest_uid);

  if not coalesce((w->>'ok')::boolean, false) then
    return w || jsonb_build_object('product_id', p_product_id, 'retry', v_retry);
  end if;

  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid  := p_guest_uid;
    v_cust := null;
  end if;

  select public._cart_line_json(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''),
           'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', ci.mrp,
           'image_url', coalesce(ci.image_url,''),
           'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           'pack_label', coalesce(nullif(btrim(coalesce(
                           public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),'')),''),
                                  coalesce(ci.pack_size,'')),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(m.buyable, false),
           'line_mrp', case when ci.mrp is null then null
                            else round(coalesce(ci.quantity,0) * ci.mrp, 2) end))
    into v_item
    from cart_items ci
    left join "MEDICINE" m
           on m.id = (case when ci.product_id ~ '^[0-9]+$' then ci.product_id::bigint end)
   where ci.product_id = p_product_id
     and (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
     and coalesce(ci.removed_by_admin, false) = false
   limit 1;

  -- The whole basket, in cart_state()'s own order and shape. It is what the
  -- pill stacks its thumbnails from and what the bill is priced against, so
  -- the bar, the card and the pill are three readings of ONE list.
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',   coalesce(ci.product_id,''),
           'product_name', coalesce(ci.product_name,''),
           'quantity',     coalesce(ci.quantity,0),
           'mrp',          ci.mrp,
           'image_url',    coalesce(ci.image_url,'')) order by ci.id), '[]'::jsonb),
         count(*),
         coalesce(sum(coalesce(ci.quantity,0)), 0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp)
                    filter (where ci.mrp is not null), 2), 0)
    into v_all, v_lines, v_units, v_mrp
    from cart_items ci
   where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
     and coalesce(ci.removed_by_admin, false) = false;

  begin
    if v_cust is not null then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
    v_adv     := public.advance_pct_for(v_cust, v_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv_amt := 0;
  end;

  begin
    v_bill := (public._cart_bill_core(
                 jsonb_build_object('items', v_all, 'mrp_total', v_mrp,
                                    'item_count', v_lines, 'unit_count', v_units),
                 v_cust, v_zone))->'bill';
  exception when others then
    v_bill := null;
  end;

  begin
    v_pill := public.cart_pill_block(v_all, v_lines);
  exception when others then
    v_pill := null;
  end;

  return jsonb_build_object(
    'ok',         true,
    'message',    w->>'message',
    'product_id', p_product_id,
    'removed',    (v_item is null),
    'item',       coalesce(v_item, 'null'::jsonb),
    'retry',      v_retry,
    'summary', jsonb_build_object(
      'item_count',  v_lines,
      'unit_count',  v_units,
      'items_label', case when v_lines = 1 then '1 item' else v_lines::text || ' items' end,
      'badge',       case when v_lines > 0 then v_lines::text else '' end,
      'mrp_total',   v_mrp,
      'bill',        coalesce(v_bill, 'null'::jsonb),
      'pill',        coalesce(v_pill, 'null'::jsonb),
      'bottom', jsonb_build_object(
        'has',             true,
        'items_label',     public._c('cart.bottom_items_label'),
        'items_value',     v_lines::text,
        'advance_label',   public._c('cart.bottom_advance_label'),
        'has_advance',     (v_adv_amt > 0),
        'advance_display', case when v_adv_amt > 0 then public.inr_money(v_adv_amt) else '' end)));
end $function$;

revoke all on function public.cart_update_item(text, integer, uuid) from public;
grant execute on function public.cart_update_item(text, integer, uuid) to authenticated, anon;

-- ── 7. cart_state() carries the pill (its thumbnails included) ────────────
-- The pill is chrome: it is on screen while the customer is in a grid, long
-- before the cart screen runs a cart_render(). Giving cart_state() the same
-- block cart_render() has means any read of the cart repaints it correctly.
create or replace function public.cart_state(p_guest_uid uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_uid uuid := coalesce(public.viewer_cart_user(), p_guest_uid);
        v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
        v_items jsonb; v_units int; v_mrp numeric; v_lines int; v_pricing jsonb;
        v_pill jsonb;
begin
  if auth.uid() is not null then v_uid := public.viewer_cart_user(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''), 'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', ci.mrp,
           'image_url', coalesce(ci.image_url,''), 'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           'pack_label', coalesce(nullif(btrim(coalesce(mb.pack_label,'')),''),
                                  coalesce(ci.pack_size,'')),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(mb.buyable, false),
           'line_mrp', case when ci.mrp is null then null
                            else round(coalesce(ci.quantity,0) * ci.mrp, 2) end)
           order by ci.id), '[]'::jsonb),
         coalesce(sum(ci.quantity),0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp) filter (where ci.mrp is not null), 2),0)
    into v_items, v_units, v_mrp
  from cart_items ci
  left join lateral (
    select m.buyable,
           public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type) as pack_label
      from "MEDICINE" m
     where m.id = (case when ci.product_id ~ '^[0-9]+$' then ci.product_id::bigint end)
     limit 1
  ) mb on true
  where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
    and coalesce(ci.removed_by_admin,false) = false;

  v_lines := jsonb_array_length(v_items);
  v_pricing := public.cart_pricing_block(v_items);

  begin
    v_pill := public.cart_pill_block(v_items, v_lines);
  exception when others then
    v_pill := null;
  end;

  return jsonb_build_object(
    'items', v_items,
    'admin_removed', '[]'::jsonb,
    'item_count', v_lines,
    'unit_count', v_units,
    'mrp_total', v_mrp,
    'pricing', v_pricing,
    'pill', coalesce(v_pill, 'null'::jsonb),
    'subtotal', (v_pricing->>'taxable')::numeric,
    'net_payable', (v_pricing->>'net_payable')::numeric,
    'customer_id', coalesce(v_cust::text, ''),
    'header', case when v_lines = 1 then '1 product in cart'
                   when v_lines = 0 then 'Your cart is empty'
                   else v_lines::text || ' products in cart' end,
    'badge', case when v_lines > 0 then v_lines::text else '' end,
    'cta_label', case when v_lines > 0
                      then v_lines::text || case when v_lines = 1 then ' item' else ' items' end
                      else '' end,
    'empty_title', 'Your cart is empty',
    'empty_note',  'Add products from the catalog to start an order.'
  );
end $function$;

revoke all on function public.cart_state(uuid) from public;
grant execute on function public.cart_state(uuid) to authenticated, anon;

-- ── 8. The admin surface learns the two new fields ────────────────────────
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
           'popup_body', b.popup_body, 'popup_dismiss', b.popup_dismiss,
           'fallback_when', coalesce(b.fallback_when,''),
           'fallback_text', coalesce(b.fallback_text,''))
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
    'zone_line',  case when v_zone is null then 'All zones'
                       else 'Zone ' || v_zone::text end
                  || ' · ' || to_char(public.admin_active_date(), 'DD Mon YYYY'),
    'rows',       v_rows,
    'rail',       coalesce(v_cfg, '{}'::jsonb),
    'sources',    jsonb_build_array('computed','fixed','formula'),
    'tones',      jsonb_build_array('default','brand','total'),
    'rail_sources', jsonb_build_array('auto','wishlist','companions'),
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
      'fallback_text',  'Text when the price is not confirmed yet',
      'popup_title',    'Popup title',
      'popup_body',     'Popup description',
      'popup_dismiss',  'Popup dismiss button',
      'rail_enabled',   'Show the wishlist rail',
      'rail_title',     'Rail title',
      'rail_source',    'Rail contents',
      'rail_max',       'Maximum cards',
      'save',           'Save',
      'retry',          'Retry',
      'rows_heading',   'Bill rows',
      'rail_heading',   'Wishlist rail'));
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
    fallback_text  = coalesce(p_row->>'fallback_text', fallback_text),
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

revoke all on function public.admin_cart_bill_list()      from public, anon;
revoke all on function public.admin_cart_bill_save(jsonb) from public, anon;
grant execute on function public.admin_cart_bill_list()      to authenticated;
grant execute on function public.admin_cart_bill_save(jsonb) to authenticated;

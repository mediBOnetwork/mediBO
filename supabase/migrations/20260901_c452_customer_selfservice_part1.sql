-- CMD #452 — HIGH customer defects batch B.
-- Part 1: the returns privilege hole found while reproducing feature_gaps #131,
-- and feature_gaps #182 (a product with no MRP could not be added to the cart).
--
-- _returns_guard() never fired: inside a SECURITY DEFINER function owned by
-- postgres, current_user IS 'postgres', so `current_user in
-- ('postgres','service_role')` was true for every caller and any signed-in
-- customer could call order_cancel / order_return_approve / refund_cancel.
--
-- cart_items.mrp was NOT NULL while 19.6% of buyable catalog rows carry no MRP,
-- so cart_set_item() raised 23502 for one buyable product in five. The column is
-- now nullable and the absence is rendered explicitly (has_mrp / empty
-- mrp_display / mrp_note) instead of being coalesced to the false ₹0.00 ceiling.

alter table public.cart_items alter column mrp drop not null;

insert into public.storefront_ui_label (key, value)
values ('cart_no_mrp_note', 'MRP not printed on this pack')
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public._cart_render_core(p_guest_uid uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cart jsonb := public.cart_state(p_guest_uid);
  v_mrp numeric := coalesce((v_cart->>'mrp_total')::numeric, 0);
  v_lines int := coalesce((v_cart->>'item_count')::int, 0);
  v_units int := coalesce((v_cart->>'unit_count')::int, 0);
  v_pricing jsonb := coalesce(v_cart->'pricing', '{}'::jsonb);
  v_net numeric := coalesce((v_pricing->>'net_payable')::numeric, 0);
  v_priced int := coalesce((v_pricing->>'priced_count')::int, 0);
  v_items jsonb;
  v_items_label text;
  v_margin jsonb;
  v_unpriced_line text := coalesce((select value from storefront_ui_label where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
  v_no_mrp text := coalesce((select value from storefront_ui_label where key='cart_no_mrp_note'),
                            'MRP not printed on this pack');
begin
  -- Per line: the TRADE rate when there is one, and the backend's own words
  -- when there is not. qty_label used to read "3 × <MRP>" — printing the legal
  -- ceiling as if it were the rate (feature_gaps #79).
  -- #182: a line with no MRP on record says so; it never prints ₹0.00, which
  -- would be a false ceiling.
  select coalesce(jsonb_agg(
           it || coalesce(tp, '{}'::jsonb) || jsonb_build_object(
             'has_mrp',           (nullif(it->>'mrp','') is not null),
             'mrp_display',       case when nullif(it->>'mrp','') is null then ''
                                       else public.inr_money((it->>'mrp')::numeric) end,
             'line_mrp_display',  case when nullif(it->>'mrp','') is null then ''
                                       else public.inr_money(coalesce((it->>'line_mrp')::numeric,0)) end,
             'mrp_note',          case when nullif(it->>'mrp','') is null then v_no_mrp else '' end,
             'has_trade_rate',    coalesce((tp->>'has_trade_rate')::boolean, false),
             'rate_note',         case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then '' else v_unpriced_line end,
             'qty_label',         case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then (it->>'quantity') || ' × ' || (tp->>'price_display')
                                       else (it->>'quantity') || ' × ' || v_unpriced_line end)
           order by ord), '[]'::jsonb)
    into v_items
  from (select it, ordinality as ord
        from jsonb_array_elements(coalesce(v_cart->'items','[]'::jsonb))
             with ordinality as t(it, ordinality)) z
  left join lateral (
    select l as tp
      from jsonb_array_elements(coalesce(v_pricing->'lines','[]'::jsonb)) l
     where (l->>'product_id') = (z.it->>'product_id')
     limit 1) p on true;

  v_items_label := case when v_lines = 1 then '1 item' else v_lines::text || ' items' end;

  v_margin := public.cart_margin_block(v_items);

  return v_cart || jsonb_build_object(
    'items', v_items,
    'margin', v_margin,
    'render', jsonb_build_object(
      'subtotal_display',     coalesce(v_pricing->>'taxable_display', public.inr_money(0)),
      'mrp_total_display',    public.inr_money(v_mrp),
      'net_payable_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'grand_total',          v_net,
      'grand_total_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'item_count',           v_lines,
      'unit_count',           v_units,
      'items_label',          v_items_label,
      'subtotal_line',        v_items_label || ' • '
                              || coalesce(v_pricing->>'net_payable_display','')
                              || case when coalesce((v_pricing->>'unpriced_count')::int,0) > 0
                                      then ' • ' || coalesce(v_pricing->>'unpriced_note','')
                                      else '' end,
      'pricing',              v_pricing,
      'tax_lines',            coalesce(v_pricing->'tax_lines', '[]'::jsonb),
      'has_tax',              coalesce((v_pricing->>'has_tax')::boolean, false),
      'margin',               v_margin,
      'pill', jsonb_build_object(
        'show',        (v_lines > 0),
        'items_label', v_items_label,
        'cta',         coalesce(public.storefront_labels()->>'cart_pill_cta', ''),
        'image',       coalesce(v_items->0->>'image_url', '')),
      'labels', jsonb_build_object(
        'subtotal',     coalesce(v_pricing->>'taxable_label', 'Taxable value'),
        'mrp_worth',    coalesce(v_pricing->>'mrp_worth_label', 'MRP worth'),
        'gst',          coalesce(v_pricing->>'gst_total_label', 'GST'),
        'total',        coalesce(v_pricing->>'net_payable_label', 'Net payable'))));
end $function$
;

CREATE OR REPLACE FUNCTION public._returns_guard()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(auth.jwt()->>'role','') = 'service_role'
     or coalesce(current_setting('request.jwt.claim.role', true),'') = 'service_role'
     or session_user in ('postgres','service_role','supabase_admin') then
    return;
  end if;
  if public.get_my_role() = 'super_admin' then
    return;
  end if;
  if public.get_my_role() = 'admin'
     and coalesce(public.admin_access('admin.returns_refunds'), 'none') <> 'none' then
    return;
  end if;
  raise exception 'returns: not authorized';
end $function$
;

CREATE OR REPLACE FUNCTION public.cart_state(p_guest_uid uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := coalesce(public.viewer_cart_user(), p_guest_uid);
        v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
        v_items jsonb; v_units int; v_mrp numeric; v_lines int; v_pricing jsonb;
begin
  if auth.uid() is not null then v_uid := public.viewer_cart_user(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''), 'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', ci.mrp,
           'image_url', coalesce(ci.image_url,''), 'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(mb.buyable, false),
           -- reference only: what this line is worth at the printed ceiling.
           -- No MRP on record => no reference value, not zero.
           'line_mrp', case when ci.mrp is null then null
                            else round(coalesce(ci.quantity,0) * ci.mrp, 2) end)
           order by ci.id), '[]'::jsonb),
         coalesce(sum(ci.quantity),0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp) filter (where ci.mrp is not null), 2),0)
    into v_items, v_units, v_mrp
  from cart_items ci
  left join lateral (
    select m.buyable
      from "MEDICINE" m
     where m.id = (case when ci.product_id ~ '^[0-9]+$' then ci.product_id::bigint end)
     limit 1
  ) mb on true
  where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
    and coalesce(ci.removed_by_admin,false) = false;

  v_lines := jsonb_array_length(v_items);
  v_pricing := public.cart_pricing_block(v_items);

  return jsonb_build_object(
    'items', v_items,
    'admin_removed', '[]'::jsonb,
    'item_count', v_lines,
    'unit_count', v_units,
    'mrp_total', v_mrp,
    'pricing', v_pricing,
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
end $function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- CMD #2090 — "You may also like" has to be able to ARRIVE.
--
-- #2087 built the block and wired the widget, and the rail has never once been
-- drawn on live: cart_also_like_block() read product_copurchase and nothing
-- else, and that table holds ZERO rows. `has` was therefore always false and
-- the screen correctly drew nothing — a rail that could only ever be empty.
--
-- The block gets the same LADDER the wishlist rail already has: the co-purchase
-- evidence first, because that is the honest answer when it exists, then the
-- widely-stocked buyable catalogue so a real pharmacy sees a real suggestion.
-- "Hide only when empty" now means what it says: the block is empty only when
-- the catalogue itself has nothing left to offer this basket.
--
-- It is also handed the ids the FIRST rail drew (p_exclude_ids), so the two
-- rails cannot be the same ten cards twice.
--
-- The 2-argument function is DROPPED before the 3-argument one is created: a
-- defaulted parameter added beside the old signature would leave two candidates
-- for every 2-arg call and every caller would fail on "is not unique".
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.cart_also_like_block(smallint, bigint[]);
drop function if exists public.cart_also_like_block(smallint, bigint[], bigint[]);

create function public.cart_also_like_block(
  p_zone_id     smallint,
  p_cart_ids    bigint[],
  p_exclude_ids bigint[] default '{}'::bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ids   bigint[] := coalesce(p_cart_ids, '{}'::bigint[]);
  v_skip  bigint[] := coalesce(p_exclude_ids, '{}'::bigint[]);
  v_zone  smallint;
  v_use   smallint;
  v_disc  numeric;
  v_max   int := 10;
  v_items jsonb := '[]'::jsonb;
  v_have  bigint[];
  v_more  jsonb;
begin
  if array_length(v_ids, 1) is null then
    return jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb,
                              'empty_note', public._c('cart.also_like_empty'));
  end if;

  v_zone := coalesce(p_zone_id, public._viewer_zone_or_null(), public.my_zone_id());
  v_disc := public._c791_safe_discount_pct();

  if v_zone is not null and exists (
       select 1 from public.product_copurchase
        where product_id = any (v_ids) and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  -- 1 — the evidence: what pharmacies actually bought with this basket.
  select coalesce(jsonb_agg(x order by x_support desc, x_id), '[]'::jsonb)
    into v_items
  from (
    select m.id as x_id, sum(c.support)::int as x_support,
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
                               nullif(regexp_replace(coalesce(m.mrp::text,''),
                                      '[^0-9.]','','g'),'')::numeric,
                               v_disc, m.id),
             'availability', public.storefront_cta(
                               public.storefront_effective_count(m.id, m.supplier_count),
                               true)) as x
      from public.product_copurchase c
      join public."MEDICINE" m on m.id = c.companion_id
     where c.product_id = any (v_ids)
       and c.zone_id = v_use
       and not (c.companion_id = any (v_ids))
       and not (c.companion_id = any (v_skip))
       and m.buyable is true
     group by m.id, m.product_name, m.marketer, m.pack_type, m.pack_size,
              m.pack_qty, m.image_url_1, m.mrp, m.supplier_count
     order by 2 desc, 1
     limit v_max
  ) s;

  -- 2 — the fallback: the widely-stocked buyable catalogue, minus this basket
  -- and minus everything the wishlist rail above already drew. Still the
  -- backend deciding, still the same card block the storefront grid reads.
  if jsonb_array_length(v_items) < v_max then
    select coalesce(array_agg((e->>'id')::bigint), '{}'::bigint[]) into v_have
      from jsonb_array_elements(v_items) e;

    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_more
    from (
      select row_number() over (order by m.sales_count desc nulls last, m.id) as ord,
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
                                 nullif(regexp_replace(coalesce(m.mrp::text,''),
                                        '[^0-9.]','','g'),'')::numeric,
                                 v_disc, m.id),
               'availability', public.storefront_cta(
                                 public.storefront_effective_count(m.id, m.supplier_count),
                                 true)) as x
        from public."MEDICINE" m
       where m.buyable is true
         and not (m.id = any (v_ids))
         and not (m.id = any (v_skip))
         and not (m.id = any (coalesce(v_have, '{}'::bigint[])))
       order by m.sales_count desc nulls last, m.id
       limit greatest(v_max - jsonb_array_length(v_items), 0)
    ) s;
    v_items := v_items || v_more;
  end if;

  return jsonb_build_object(
    'has',        jsonb_array_length(v_items) > 0,
    'title',      coalesce((select value from public.storefront_ui_label
                             where key = 'cart_also_like_title'), ''),
    'empty_note', public._c('cart.also_like_empty'),
    'zone_id',    v_use,
    'items',      v_items);
end
$function$;

revoke all on function public.cart_also_like_block(smallint, bigint[], bigint[]) from public;
revoke all on function public.cart_also_like_block(smallint, bigint[], bigint[]) from anon;
grant execute on function public.cart_also_like_block(smallint, bigint[], bigint[]) to authenticated;
grant execute on function public.cart_also_like_block(smallint, bigint[], bigint[]) to service_role;

-- The title the rail prints. Backend copy, never a Dart literal.
insert into public.storefront_ui_label (key, value)
values ('cart_also_like_title', 'You may also like')
on conflict (key) do nothing;

-- ── _cart_bill_core: hand the second rail what the first one drew ──
CREATE OR REPLACE FUNCTION public._cart_bill_core(p_cart jsonb, p_cust uuid, p_zone smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_rail_ids bigint[] := '{}'::bigint[];
  v_also    jsonb;
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

  -- The advance is the SAME reading the bottom bar takes. The row it used to
  -- print in the card is hidden now (CMD #2087), but the VARIABLE stays: a
  -- zone can switch the row back on and a formula row may still reference it.
  begin
    v_adv     := public.advance_pct_for(p_cust, p_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv_amt := 0;
  end;

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

  -- CMD #2090 — the second rail. It is handed the ids the FIRST rail already
  -- drew, so "You may also like" cannot repeat the wishlist rail card for
  -- card when both fall back to the catalogue. It never throws the cart away:
  -- an absent block is an absence, drawn as nothing.
  begin
    select coalesce(array_agg((e->>'id')::bigint), '{}'::bigint[])
      into v_rail_ids
      from jsonb_array_elements(coalesce(v_rail->'items', '[]'::jsonb)) e
     where (e->>'id') ~ '^[0-9]+$';
    v_also := public.cart_also_like_block(p_zone, v_ids, v_rail_ids);
  exception when others then
    v_also := null;
  end;

  return jsonb_build_object(
    'bill', jsonb_build_object(
      'has',        jsonb_array_length(v_rows) > 0 and v_items > 0,
      'title',      public._c('cart.bill_title'),
      'empty_note', public._c('cart.bill_empty'),
      'ptr_complete', v_ptr_ok,
      'rows',       v_rows),
    'rail', coalesce(v_rail, jsonb_build_object(
      'has', false, 'title', '', 'items', '[]'::jsonb,
      'empty_note', public._c('cart.rail_empty'))),
    'also_like', coalesce(v_also, jsonb_build_object(
      'has', false, 'title', '', 'items', '[]'::jsonb,
      'empty_note', public._c('cart.also_like_empty'))));
end
$function$
;

-- CHANGE #179 — Offers Marketplace: supplier self-list, anonymous buy, race-proof qty
-- Builds a full B2B offers marketplace on top of the existing scheme/pricing engine.
-- Supplier identity is NEVER exposed to customers — Om keeps the margin.

-- ── 1. supplier_offer_listings — the core table ───────────────────────────────
CREATE TABLE IF NOT EXISTS public.supplier_offer_listings (
  id              bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  supplier_id     uuid    NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id      bigint  NOT NULL,  -- MEDICINE.id
  listing_type    text    NOT NULL CHECK (listing_type IN ('scheme','near_expiry','discount')),
  -- qty management (race-proof)
  available_qty   numeric NOT NULL DEFAULT 0 CHECK (available_qty >= 0),
  sold_qty        numeric NOT NULL DEFAULT 0,
  -- pricing (B2B PTR basis)
  offer_ptr       numeric,           -- PTR for this listing (supplier's committed price)
  discount_pct    numeric,           -- % discount vs normal PTR
  net_price       numeric,           -- final net per unit (computed or manual)
  -- scheme fields (for listing_type='scheme')
  scheme_buy_qty  numeric,
  scheme_free_qty numeric,
  -- near-expiry fields
  batch_expiry_date date,
  -- optional constraints
  min_order_qty   numeric DEFAULT 1,
  end_date        date,              -- listing auto-expires on this date
  zone_ids        uuid[],            -- null = all zones
  -- admin fields
  margin_pct      numeric DEFAULT 0, -- mediBO's margin on marketplace sales
  moderated_at    timestamptz,
  moderated_by    uuid,
  moderation_note text,
  -- status lifecycle
  status          text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','paused','expired','delisted')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sol_supplier ON public.supplier_offer_listings(supplier_id);
CREATE INDEX IF NOT EXISTS idx_sol_product  ON public.supplier_offer_listings(product_id);
CREATE INDEX IF NOT EXISTS idx_sol_status   ON public.supplier_offer_listings(status) WHERE status='active';

-- ── 2. offer_near_expiry_disclosures — record customer opt-in ─────────────────
CREATE TABLE IF NOT EXISTS public.offer_near_expiry_disclosures (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id uuid NOT NULL,
  listing_id  bigint NOT NULL REFERENCES public.supplier_offer_listings(id),
  order_id    uuid,
  accepted_at timestamptz NOT NULL DEFAULT now()
);

-- ── 3. Add offer_listing_id to cart_items for tracking ────────────────────────
ALTER TABLE public.cart_items
  ADD COLUMN IF NOT EXISTS offer_listing_id bigint
    REFERENCES public.supplier_offer_listings(id) ON DELETE SET NULL;

-- ── 4. RLS policies ───────────────────────────────────────────────────────────
ALTER TABLE public.supplier_offer_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offer_near_expiry_disclosures ENABLE ROW LEVEL SECURITY;

-- Supplier: see/edit own listings
DROP POLICY IF EXISTS sol_supplier_select ON public.supplier_offer_listings;
CREATE POLICY sol_supplier_select ON public.supplier_offer_listings
  FOR SELECT USING (supplier_id = auth.uid() OR public.get_my_role() IN ('admin','super_admin','service'));

DROP POLICY IF EXISTS sol_supplier_insert ON public.supplier_offer_listings;
CREATE POLICY sol_supplier_insert ON public.supplier_offer_listings
  FOR INSERT WITH CHECK (
    supplier_id = auth.uid()
    AND public.get_my_role() IN ('supplier','admin','super_admin','service')
  );

DROP POLICY IF EXISTS sol_supplier_update ON public.supplier_offer_listings;
CREATE POLICY sol_supplier_update ON public.supplier_offer_listings
  FOR UPDATE USING (
    (supplier_id = auth.uid() AND public.get_my_role() IN ('supplier','admin','super_admin','service'))
    OR public.get_my_role() IN ('admin','super_admin','service')
  );

-- Near-expiry disclosures: customer can insert/see own
DROP POLICY IF EXISTS ned_customer_all ON public.offer_near_expiry_disclosures;
CREATE POLICY ned_customer_all ON public.offer_near_expiry_disclosures
  FOR ALL USING (
    customer_id = public.my_customer_id()
    OR public.get_my_role() IN ('admin','super_admin','service')
  );

-- ── 5. Helper: _offer_display_block (builds customer-safe card data) ──────────
-- NOTE: never includes supplier_id, supplier_company, or any supplier identity.
CREATE OR REPLACE FUNCTION public._offer_display_block(p_row public.supplier_offer_listings)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_med   record;
  v_mrp   numeric;
  v_months_left integer;
  v_type_label  text;
  v_type_badge  jsonb;
  v_scheme_text text;
  v_eff_price   numeric;
  v_days_left   integer;
  v_near_expiry_label text;
begin
  select m.id, m."NAME" as name, m."COMPANY" as company, m."PACK" as pack,
         nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
    into v_med
  from "MEDICINE" m where m.id = p_row.product_id;

  v_mrp := coalesce(v_med.mrp, 0);

  -- type badge
  v_type_label := case p_row.listing_type
    when 'scheme'      then coalesce((select value from storefront_ui_label where key='offer_type_scheme'),      'Scheme')
    when 'near_expiry' then coalesce((select value from storefront_ui_label where key='offer_type_near_expiry'), 'Near Expiry')
    when 'discount'    then coalesce((select value from storefront_ui_label where key='offer_type_discount'),    'Offer')
    else p_row.listing_type
  end;
  v_type_badge := jsonb_build_object(
    'label', v_type_label,
    'bg',    case p_row.listing_type
               when 'scheme'      then '#D1FAE5'
               when 'near_expiry' then '#FEF3C7'
               else                    '#EFF6FF'
             end,
    'fg',    case p_row.listing_type
               when 'scheme'      then '#065F46'
               when 'near_expiry' then '#92400E'
               else                    '#1E40AF'
             end
  );

  -- scheme text
  if p_row.listing_type = 'scheme' and coalesce(p_row.scheme_buy_qty,0)>0 then
    v_scheme_text := p_row.scheme_buy_qty::int::text||'+'||p_row.scheme_free_qty::int::text||' FREE';
    v_eff_price   := case when coalesce(p_row.offer_ptr,0)>0
      then round(p_row.offer_ptr/(p_row.scheme_buy_qty+p_row.scheme_free_qty),2)
      else round(v_mrp/(p_row.scheme_buy_qty+p_row.scheme_free_qty),2) end;
  elsif coalesce(p_row.net_price,0)>0 then
    v_eff_price := p_row.net_price;
  elsif coalesce(p_row.offer_ptr,0)>0 and coalesce(p_row.discount_pct,0)>0 then
    v_eff_price := round(p_row.offer_ptr*(1-p_row.discount_pct/100),2);
  else
    v_eff_price := coalesce(p_row.net_price, p_row.offer_ptr, v_mrp);
  end if;

  -- near-expiry chip
  if p_row.listing_type = 'near_expiry' and p_row.batch_expiry_date is not null then
    v_months_left := extract(month from age(p_row.batch_expiry_date, current_date))::integer
                   + extract(year from age(p_row.batch_expiry_date, current_date))::integer*12;
    v_near_expiry_label := v_months_left::text||' month'||case when v_months_left=1 then '' else 's' end||' left';
  end if;

  -- listing end date countdown
  v_days_left := case when p_row.end_date is not null
    then (p_row.end_date - current_date)::integer else null end;

  return jsonb_build_object(
    'id',              p_row.id,
    'product_id',      p_row.product_id,
    'product_name',    coalesce(v_med.name, ''),
    'company',         coalesce(v_med.company, ''),
    'pack',            coalesce(v_med.pack, ''),
    'mrp_display',     case when v_mrp>0 then public.inr_money(v_mrp) else '' end,
    'listing_type',    p_row.listing_type,
    'type_badge',      v_type_badge,
    'scheme_text',     coalesce(v_scheme_text,''),
    'discount_pct',    coalesce(p_row.discount_pct,0),
    'discount_label',  case when coalesce(p_row.discount_pct,0)>0
                            then public._num_label(p_row.discount_pct)||'% OFF' else '' end,
    'price_display',   case when coalesce(v_eff_price,0)>0 then public.inr_money(v_eff_price) else '' end,
    'eff_price',       coalesce(v_eff_price,0),
    'eff_per_unit_display', case when coalesce(v_eff_price,0)>0
                                 then public.inr_money(v_eff_price)||'/unit' else '' end,
    'available_qty',   p_row.available_qty,
    'qty_display',     p_row.available_qty::int::text||' units left',
    'qty_low',         p_row.available_qty <= 10,
    'sold_out',        p_row.available_qty <= 0,
    'min_order_qty',   coalesce(p_row.min_order_qty,1),
    'near_expiry_months_left', v_months_left,
    'near_expiry_label',       v_near_expiry_label,
    'expiry_date_display', case when p_row.batch_expiry_date is not null
                                then to_char(p_row.batch_expiry_date,'DD Mon YYYY') else null end,
    'end_date_display', case when v_days_left is not null
      then case when v_days_left<=0 then 'Ended'
                when v_days_left<=3 then 'Ends in '||v_days_left||' day'||case when v_days_left=1 then '' else 's' end
                else 'Ends '||to_char(p_row.end_date,'DD Mon') end
      else null end,
    'requires_disclosure', p_row.listing_type = 'near_expiry',
    -- seller display: ALWAYS mediBO, never the real supplier
    'seller',          'mediBO',
    'seller_display',  coalesce((select value from storefront_ui_label where key='offer_seller_label'),'Sold by mediBO')
  );
end;
$$;

-- ── 6. offers_feed — customer-facing feed, zero supplier identity ─────────────
CREATE OR REPLACE FUNCTION public.offers_feed(
  p_zone_id   uuid    DEFAULT NULL,
  p_offset    integer DEFAULT 0,
  p_limit     integer DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role  text := public.get_my_role();
  v_rows  jsonb;
  v_count bigint;
  v_title text := coalesce((select value from storefront_ui_label where key='offers_feed_title'),'Offers');
  v_empty text := coalesce((select value from storefront_ui_label where key='offers_feed_empty'),'No offers right now');
begin
  if v_role not in ('admin','super_admin','service') and not public.viewer_is_approved_customer() then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  select count(*), jsonb_agg(public._offer_display_block(sol))
    into v_count, v_rows
  from public.supplier_offer_listings sol
  where sol.status = 'active'
    and sol.available_qty > 0
    and (sol.end_date is null or sol.end_date >= current_date)
    and (sol.batch_expiry_date is null or sol.batch_expiry_date > current_date)
    and (sol.zone_ids is null or p_zone_id = any(sol.zone_ids))
  order by
    -- near-expiry first, then schemes, then discounts; within type sort by qty desc
    case sol.listing_type when 'scheme' then 1 when 'near_expiry' then 0 else 2 end,
    sol.available_qty desc,
    sol.created_at desc
  limit p_limit offset p_offset;

  return jsonb_build_object(
    'ok',       true,
    'title',    v_title,
    'count',    coalesce(v_count,0),
    'has_more', coalesce(v_count,0) > p_offset + p_limit,
    'empty',    case when coalesce(v_count,0)=0 then v_empty else null end,
    'rows',     coalesce(v_rows,'[]'::jsonb)
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.offers_feed TO authenticated;

-- ── 7. offer_add_to_cart — adds offer item, validates qty ────────────────────
CREATE OR REPLACE FUNCTION public.offer_add_to_cart(
  p_listing_id bigint,
  p_qty        numeric DEFAULT 1
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_cust  uuid := public.my_customer_id();
  v_uid   uuid := auth.uid();
  v_sol   public.supplier_offer_listings%rowtype;
  v_med   record;
  v_price numeric;
  v_existing_qty numeric := 0;
  v_label text;
begin
  if v_uid is null then
    return jsonb_build_object('ok',false,'error','not_authenticated');
  end if;
  if not public.viewer_is_approved_customer() then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  -- Lock the listing row to check availability
  select * into v_sol from public.supplier_offer_listings
  where id = p_listing_id FOR SHARE;

  if not found then
    return jsonb_build_object('ok',false,'error','listing_not_found');
  end if;
  if v_sol.status != 'active' then
    return jsonb_build_object('ok',false,'error','listing_unavailable');
  end if;
  if v_sol.available_qty <= 0 then
    return jsonb_build_object('ok',false,'error','sold_out',
      'message', coalesce((select value from storefront_ui_label where key='offer_sold_out'),'This offer is sold out'));
  end if;
  if p_qty < coalesce(v_sol.min_order_qty,1) then
    return jsonb_build_object('ok',false,'error','min_qty',
      'message','Minimum order is '||coalesce(v_sol.min_order_qty,1)::int::text||' units');
  end if;
  if p_qty > v_sol.available_qty then
    return jsonb_build_object('ok',false,'error','insufficient_qty',
      'message','Only '||v_sol.available_qty::int::text||' units available');
  end if;

  -- compute display price
  v_price := case
    when coalesce(v_sol.net_price,0) > 0 then v_sol.net_price
    when coalesce(v_sol.offer_ptr,0) > 0 and coalesce(v_sol.discount_pct,0) > 0
      then round(v_sol.offer_ptr*(1-v_sol.discount_pct/100),2)
    when coalesce(v_sol.offer_ptr,0) > 0 then v_sol.offer_ptr
    else 0
  end;

  select m.id, m."NAME" as name, m."COMPANY" as company, m."PACK" as pack,
         nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
    into v_med from "MEDICINE" m where m.id = v_sol.product_id;

  -- check if same listing already in cart
  select quantity into v_existing_qty
  from cart_items
  where (case when v_cust is not null then customer_id=v_cust else user_id=v_uid end)
    and offer_listing_id = p_listing_id
  limit 1;

  if found then
    -- update existing
    update cart_items set
      quantity = p_qty,
      price    = v_price,
      updated_at = now()
    where (case when v_cust is not null then customer_id=v_cust else user_id=v_uid end)
      and offer_listing_id = p_listing_id;
  else
    insert into cart_items(
      user_id, customer_id, product_id, product_name, price, mrp,
      quantity, manufacturer, pack_size, gst_percent, updated_at, offer_listing_id
    ) values (
      v_uid, v_cust,
      v_sol.product_id::text,
      coalesce(v_med.name,''),
      v_price,
      coalesce(v_med.mrp,0),
      p_qty::integer,
      coalesce(v_med.company,''),
      coalesce(v_med.pack,''),
      0,
      now(),
      p_listing_id
    );
  end if;

  v_label := coalesce((select value from storefront_ui_label where key='offer_added_to_cart'),'Added to cart');
  return jsonb_build_object(
    'ok',      true,
    'message', v_label,
    'listing_id', p_listing_id,
    'qty',     p_qty,
    'requires_disclosure', v_sol.listing_type = 'near_expiry'
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.offer_add_to_cart TO authenticated;

-- ── 8. _offer_confirm_qty — atomic qty deduction (called inside order placement) ──
CREATE OR REPLACE FUNCTION public._offer_confirm_qty(
  p_listing_id bigint,
  p_qty        numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_updated integer;
begin
  UPDATE public.supplier_offer_listings
  SET available_qty = available_qty - p_qty,
      sold_qty      = sold_qty + p_qty,
      updated_at    = now()
  WHERE id = p_listing_id
    AND available_qty >= p_qty
    AND status = 'active';

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  if v_updated = 0 then
    -- insufficient qty or listing gone — abort the order
    return jsonb_build_object('ok',false,'error','offer_qty_exhausted',
      'listing_id', p_listing_id);
  end if;

  -- auto-mark sold_out when qty hits 0
  UPDATE public.supplier_offer_listings
  SET status = 'expired'
  WHERE id = p_listing_id AND available_qty = 0;

  return jsonb_build_object('ok',true,'listing_id',p_listing_id,'deducted',p_qty);
end;
$$;

-- ── 9. Override _place_order_v2_core to confirm offer qtys atomically ─────────
CREATE OR REPLACE FUNCTION public._place_order_v2_core()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_sess jsonb := public.my_session();
  v_cart jsonb;
  v_cust uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_net numeric; v_id uuid; v_code text;
  v_addr text; v_copy jsonb;
  -- offer tracking
  v_offer_item record;
  v_confirm    jsonb;
  v_has_offers boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated'
      using hint = 'Session missing or expired; sign in again and retry.';
  end if;

  if (v_sess->>'can_place_order') is distinct from 'true' then
    raise exception 'order_gate_blocked'
      using hint = coalesce(v_sess->'order_gate'->>'message', 'Ordering is not available.');
  end if;

  v_cart := public.cart_state(null);
  v_items := coalesce(v_cart->'items', '[]'::jsonb);
  if jsonb_array_length(v_items) = 0 then
    raise exception 'empty_cart' using hint = 'No items to order.';
  end if;

  -- Atomically confirm offer qty for any offer items in the cart.
  -- This is a hard serialization point — if ANY offer item runs out, the whole
  -- order rolls back (the exception propagates and aborts the transaction).
  for v_offer_item in
    select ci.offer_listing_id, ci.quantity
    from cart_items ci
    where (case when v_cust is not null then ci.customer_id=v_cust else ci.user_id=v_uid end)
      and ci.offer_listing_id is not null
      and ci.quantity > 0
  loop
    v_has_offers := true;
    v_confirm := public._offer_confirm_qty(v_offer_item.offer_listing_id, v_offer_item.quantity);
    if not (v_confirm->>'ok')::boolean then
      raise exception 'offer_qty_exhausted'
        using hint = 'One or more offers sold out — remove them and retry.',
              detail = v_confirm::text;
    end if;
  end loop;

  v_net := coalesce((v_cart->>'subtotal')::numeric, (v_cart->>'mrp_total')::numeric, 0);

  select * into pp from pharmacy_profiles where id = v_cust;

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id)
  values
    (v_uid, v_cust, coalesce(pp.pharmacy_name,''), v_items, v_net,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending',
     case when v_has_offers then 'offer' else 'website' end,
     false,
     public.next_order_number())
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);

  return jsonb_build_object(
    'ok',              true,
    'id',              coalesce(v_id::text,''),
    'order_code',      coalesce(v_code,''),
    'amount',          v_net,
    'amount_display',  public.inr_money(v_net),
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0));
end
$$;

-- ── 10. supplier_offer_create — supplier lists a new offer ────────────────────
CREATE OR REPLACE FUNCTION public.supplier_offer_create(
  p_product_id      bigint,
  p_listing_type    text,
  p_available_qty   numeric,
  p_offer_ptr       numeric     DEFAULT NULL,
  p_discount_pct    numeric     DEFAULT NULL,
  p_net_price       numeric     DEFAULT NULL,
  p_scheme_buy_qty  numeric     DEFAULT NULL,
  p_scheme_free_qty numeric     DEFAULT NULL,
  p_batch_expiry_date date      DEFAULT NULL,
  p_min_order_qty   numeric     DEFAULT 1,
  p_end_date        date        DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
  v_id   bigint;
  v_margin numeric;
begin
  if v_role not in ('supplier','admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  if p_listing_type not in ('scheme','near_expiry','discount') then
    return jsonb_build_object('ok',false,'error','invalid_type');
  end if;
  if p_available_qty <= 0 then
    return jsonb_build_object('ok',false,'error','invalid_qty');
  end if;
  if p_listing_type='near_expiry' and p_batch_expiry_date is null then
    return jsonb_build_object('ok',false,'error','expiry_date_required');
  end if;
  if p_listing_type='scheme' and (coalesce(p_scheme_buy_qty,0)<=0 or coalesce(p_scheme_free_qty,0)<=0) then
    return jsonb_build_object('ok',false,'error','scheme_qty_required');
  end if;

  -- get configured margin
  select (value->>'marketplace_margin_pct')::numeric into v_margin
  from app_settings where key='offer_marketplace_config';

  insert into public.supplier_offer_listings(
    supplier_id, product_id, listing_type, available_qty,
    offer_ptr, discount_pct, net_price,
    scheme_buy_qty, scheme_free_qty,
    batch_expiry_date, min_order_qty, end_date,
    margin_pct, status
  ) values (
    auth.uid(), p_product_id, p_listing_type, p_available_qty,
    p_offer_ptr, p_discount_pct, p_net_price,
    p_scheme_buy_qty, p_scheme_free_qty,
    p_batch_expiry_date, coalesce(p_min_order_qty,1), p_end_date,
    coalesce(v_margin, 5), 'active'
  ) returning id into v_id;

  return jsonb_build_object('ok',true,'id',v_id);
end;
$$;
GRANT EXECUTE ON FUNCTION public.supplier_offer_create TO authenticated;

-- ── 11. supplier_offer_update — edit or pause/delist own listing ──────────────
CREATE OR REPLACE FUNCTION public.supplier_offer_update(
  p_id            bigint,
  p_available_qty numeric     DEFAULT NULL,
  p_offer_ptr     numeric     DEFAULT NULL,
  p_discount_pct  numeric     DEFAULT NULL,
  p_net_price     numeric     DEFAULT NULL,
  p_min_order_qty numeric     DEFAULT NULL,
  p_end_date      date        DEFAULT NULL,
  p_status        text        DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
  v_sol  public.supplier_offer_listings%rowtype;
begin
  select * into v_sol from public.supplier_offer_listings where id = p_id;
  if not found then
    return jsonb_build_object('ok',false,'error','not_found');
  end if;
  if v_sol.supplier_id != auth.uid() and v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  if p_status is not null and p_status not in ('active','paused','delisted') then
    return jsonb_build_object('ok',false,'error','invalid_status');
  end if;

  update public.supplier_offer_listings set
    available_qty = coalesce(p_available_qty, available_qty),
    offer_ptr     = coalesce(p_offer_ptr,     offer_ptr),
    discount_pct  = coalesce(p_discount_pct,  discount_pct),
    net_price     = coalesce(p_net_price,      net_price),
    min_order_qty = coalesce(p_min_order_qty,  min_order_qty),
    end_date      = coalesce(p_end_date,       end_date),
    status        = coalesce(p_status,         status),
    updated_at    = now()
  where id = p_id;

  return jsonb_build_object('ok',true,'id',p_id);
end;
$$;
GRANT EXECUTE ON FUNCTION public.supplier_offer_update TO authenticated;

-- ── 12. supplier_offers_mine — supplier's own listings with stats ─────────────
CREATE OR REPLACE FUNCTION public.supplier_offers_mine(
  p_status text    DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_limit  integer DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role  text := public.get_my_role();
  v_rows  jsonb;
  v_count bigint;
  v_title text := coalesce((select value from storefront_ui_label where key='supplier_offers_title'),'My Listings');
  v_empty text := coalesce((select value from storefront_ui_label where key='supplier_offers_empty'),'No listings yet — create your first offer');
begin
  if v_role not in ('supplier','admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  select count(*), jsonb_agg(row_to_json(r))
    into v_count, v_rows
  from (
    select
      sol.id,
      sol.product_id,
      m."NAME"             as product_name,
      m."COMPANY"          as company,
      sol.listing_type,
      case sol.listing_type
        when 'scheme'      then coalesce((select value from storefront_ui_label where key='offer_type_scheme'),'Scheme')
        when 'near_expiry' then coalesce((select value from storefront_ui_label where key='offer_type_near_expiry'),'Near Expiry')
        else               coalesce((select value from storefront_ui_label where key='offer_type_discount'),'Offer')
      end                  as type_label,
      sol.available_qty,
      sol.sold_qty,
      sol.available_qty + sol.sold_qty as total_listed_qty,
      sol.offer_ptr,
      sol.discount_pct,
      sol.net_price,
      sol.scheme_buy_qty,
      sol.scheme_free_qty,
      sol.batch_expiry_date,
      sol.min_order_qty,
      sol.end_date,
      sol.status,
      sol.created_at,
      sol.updated_at,
      case when coalesce(sol.offer_ptr,0)>0 then public.inr_money(sol.offer_ptr) else '' end as ptr_display,
      case when coalesce(sol.discount_pct,0)>0
           then public._num_label(sol.discount_pct)||'% OFF' else '' end as discount_label,
      case when coalesce(sol.net_price,0)>0 then public.inr_money(sol.net_price) else '' end as net_price_display,
      case sol.listing_type when 'scheme'
           then sol.scheme_buy_qty::int::text||'+'||sol.scheme_free_qty::int::text||' FREE'
           else '' end as scheme_text,
      case when sol.batch_expiry_date is not null then to_char(sol.batch_expiry_date,'DD Mon YYYY') else null end as expiry_display,
      case when sol.end_date is not null then to_char(sol.end_date,'DD Mon YYYY') else null end as end_date_display,
      -- status badge
      jsonb_build_object(
        'label', initcap(sol.status),
        'bg', case sol.status when 'active' then '#D1FAE5' when 'paused' then '#FEF3C7'
                              when 'expired' then '#FEE2E2' else '#F3F4F6' end,
        'fg', case sol.status when 'active' then '#065F46' when 'paused' then '#92400E'
                              when 'expired' then '#991B1B' else '#374151' end
      ) as status_badge
    from public.supplier_offer_listings sol
    join "MEDICINE" m on m.id = sol.product_id
    where sol.supplier_id = auth.uid()
      and (p_status is null or sol.status = p_status)
    order by sol.created_at desc
    limit p_limit offset p_offset
  ) r;

  return jsonb_build_object(
    'ok',       true,
    'title',    v_title,
    'empty',    case when coalesce(v_count,0)=0 then v_empty else null end,
    'count',    coalesce(v_count,0),
    'has_more', coalesce(v_count,0) > p_offset + p_limit,
    'rows',     coalesce(v_rows,'[]'::jsonb)
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.supplier_offers_mine TO authenticated;

-- ── 13. admin_offers_list — admin sees ALL listings WITH supplier identity ─────
CREATE OR REPLACE FUNCTION public.admin_offers_list(
  p_status text    DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_limit  integer DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role  text := public.get_my_role();
  v_rows  jsonb;
  v_count bigint;
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  select count(*), jsonb_agg(row_to_json(r))
    into v_count, v_rows
  from (
    select
      sol.id, sol.listing_type, sol.status,
      sol.available_qty, sol.sold_qty, sol.margin_pct,
      sol.offer_ptr, sol.discount_pct, sol.net_price,
      sol.scheme_buy_qty, sol.scheme_free_qty,
      sol.batch_expiry_date, sol.end_date, sol.created_at,
      m."NAME"    as product_name,
      m."COMPANY" as company,
      -- supplier identity ONLY for admin
      sol.supplier_id,
      coalesce(sc.supplier_company,'(no name)') as supplier_name,
      sol.moderation_note,
      case sol.status when 'active' then '#D1FAE5' else '#FEE2E2' end as status_bg,
      case sol.status when 'active' then '#065F46' else '#991B1B' end as status_fg
    from public.supplier_offer_listings sol
    join "MEDICINE" m on m.id = sol.product_id
    left join supplier_company sc on sc.supplier_id = sol.supplier_id
    where (p_status is null or sol.status = p_status)
    order by sol.created_at desc
    limit p_limit offset p_offset
  ) r;

  return jsonb_build_object(
    'ok',       true,
    'count',    coalesce(v_count,0),
    'has_more', coalesce(v_count,0) > p_offset + p_limit,
    'rows',     coalesce(v_rows,'[]'::jsonb)
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.admin_offers_list TO authenticated;

-- ── 14. admin_offer_moderate — remove/restore a listing ──────────────────────
CREATE OR REPLACE FUNCTION public.admin_offer_moderate(
  p_listing_id bigint,
  p_action     text,      -- 'remove' | 'restore' | 'set_margin'
  p_note       text       DEFAULT NULL,
  p_margin_pct numeric    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
  v_new_status text;
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  if p_action = 'remove' then
    update public.supplier_offer_listings set
      status = 'delisted', moderated_at = now(), moderated_by = auth.uid(),
      moderation_note = p_note, updated_at = now()
    where id = p_listing_id;
  elsif p_action = 'restore' then
    update public.supplier_offer_listings set
      status = 'active', moderated_at = now(), moderated_by = auth.uid(),
      moderation_note = p_note, updated_at = now()
    where id = p_listing_id;
  elsif p_action = 'set_margin' then
    if p_margin_pct is null then
      return jsonb_build_object('ok',false,'error','margin_required');
    end if;
    update public.supplier_offer_listings set
      margin_pct = p_margin_pct, updated_at = now()
    where id = p_listing_id;
  else
    return jsonb_build_object('ok',false,'error','invalid_action');
  end if;

  return jsonb_build_object('ok',true,'listing_id',p_listing_id,'action',p_action);
end;
$$;
GRANT EXECUTE ON FUNCTION public.admin_offer_moderate TO authenticated;

-- ── 15. admin_offer_margin_set — global marketplace margin config ─────────────
CREATE OR REPLACE FUNCTION public.admin_offer_margin_set(
  p_margin_pct numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  insert into app_settings(key, value) values (
    'offer_marketplace_config',
    jsonb_build_object('marketplace_margin_pct', p_margin_pct)
  )
  on conflict(key) do update set value = excluded.value;

  return jsonb_build_object('ok',true,'margin_pct',p_margin_pct);
end;
$$;
GRANT EXECUTE ON FUNCTION public.admin_offer_margin_set TO authenticated;

-- ── 16. _offer_expiry_cron — auto-expire listings by date/qty ────────────────
CREATE OR REPLACE FUNCTION public._offer_expiry_cron() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
begin
  update public.supplier_offer_listings set status = 'expired', updated_at = now()
  where status = 'active'
    and (
      (end_date is not null and end_date < current_date)
      or (batch_expiry_date is not null and batch_expiry_date <= current_date)
      or available_qty <= 0
    );
end;
$$;

-- ── 17. Schedule the cron (pg_cron) ──────────────────────────────────────────
-- Run every hour to auto-expire stale listings
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.schedule('offer-expiry-cron', '0 * * * *',
      'SELECT public._offer_expiry_cron()');
  END IF;
END;
$$;

-- ── 18. ui_copy — all strings from the backend ───────────────────────────────
INSERT INTO storefront_ui_label (key, value) VALUES
  ('offers_feed_title',       'Offers'),
  ('offers_feed_empty',       'No offers right now — check back soon'),
  ('offer_type_scheme',       'Scheme'),
  ('offer_type_near_expiry',  'Near Expiry'),
  ('offer_type_discount',     'Offer'),
  ('offer_seller_label',      'Sold by mediBO'),
  ('offer_sold_out',          'This offer is sold out'),
  ('offer_added_to_cart',     'Added to cart'),
  ('supplier_offers_title',   'My Listings'),
  ('supplier_offers_empty',   'No listings yet'),
  ('offer_near_expiry_title', 'Short-dated stock'),
  ('offer_near_expiry_disclosure', 'This product is near its expiry date. By adding it to your order, you confirm you have reviewed the expiry date and accept the terms of sale for short-dated stock.'),
  ('offer_near_expiry_accept', 'Yes, I understand'),
  ('offer_nav_label',         'Offers'),
  ('offer_list_btn',          'List an Offer'),
  ('offer_create_title',      'New Listing'),
  ('offer_edit_title',        'Edit Listing'),
  ('offer_qty_label',         'Available Qty'),
  ('offer_min_qty_label',     'Min. Order Qty'),
  ('offer_end_date_label',    'Offer Ends On'),
  ('offer_ptr_label',         'Your PTR (₹)'),
  ('offer_discount_label',    'Discount %'),
  ('offer_type_select',       'Offer Type'),
  ('offer_scheme_buy_label',  'Buy Qty (e.g. 5)'),
  ('offer_scheme_free_label', 'Free Qty (e.g. 1)'),
  ('offer_expiry_date_label', 'Batch Expiry Date'),
  ('offer_submit_btn',        'Publish Listing'),
  ('offer_save_btn',          'Save Changes'),
  ('offer_pause_btn',         'Pause'),
  ('offer_delist_btn',        'Remove Listing'),
  ('offer_restore_btn',       'Restore'),
  ('admin_offers_title',      'Offer Listings'),
  ('admin_offer_margin_label','mediBO Margin %'),
  ('admin_offer_remove_btn',  'Remove'),
  ('admin_offer_restore_btn', 'Restore')
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- Default marketplace config
INSERT INTO app_settings(key, value) VALUES
  ('offer_marketplace_config', '{"marketplace_margin_pct": 5}')
ON CONFLICT (key) DO NOTHING;

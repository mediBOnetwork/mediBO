-- CHANGE #223 — Offers marketplace: debug #179 + build the #178 deltas.
--
-- DEBUG (bugs found live in what #179 shipped):
--   B1  offers_feed raised 42803 ("sol.listing_type must appear in the GROUP BY
--       clause") on EVERY call — aggregate + ORDER BY without a subselect. The
--       customer Offers tab was dead for every role.
--   B2  supplier_offer_listings.zone_ids was uuid[] while every zone in the
--       platform is smallint — zone targeting could never match.
--   B3  offer lines were refused at checkout: _cart_unavailable_lines marks any
--       product with zone standby <= 0 unavailable, and an offer's supply is
--       committed by the listing, not by standby stock.
--   B4  the near-expiry disclosure was shown in Flutter but never recorded —
--       offer_near_expiry_disclosures stayed empty.
--   B5  direct-buy routing (#179 §6) did not exist: an offer line still went
--       into the SPN inquiry cascade even though supply + price are committed.
--
-- BUILD (#178 deltas the unified Offers surface never got):
--   N1  cart-hold reservations with auto-release (race-proof, idempotent)
--   N2  waitlist + back-in-stock notify
--   N3  auto-match to pharmacies that already buy the product + WA push
--   N4  every customer-facing string served from the backend

-- ── B2. zone_ids: uuid[] → smallint[] (table is empty, verified 0 rows) ───────
ALTER TABLE public.supplier_offer_listings DROP COLUMN IF EXISTS zone_ids;
ALTER TABLE public.supplier_offer_listings ADD COLUMN IF NOT EXISTS zone_ids smallint[];

-- ── N1. offer_reservations — the cart hold ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.offer_reservations (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listing_id  bigint NOT NULL REFERENCES public.supplier_offer_listings(id) ON DELETE CASCADE,
  customer_id uuid   NOT NULL,
  qty         numeric NOT NULL CHECK (qty > 0),
  status      text   NOT NULL DEFAULT 'held' CHECK (status IN ('held','consumed','released')),
  expires_at  timestamptz NOT NULL,
  order_id    uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  consumed_at timestamptz,
  released_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_offer_res_held
  ON public.offer_reservations(listing_id, customer_id) WHERE status = 'held';
CREATE INDEX IF NOT EXISTS ix_offer_res_expiry
  ON public.offer_reservations(expires_at) WHERE status = 'held';

ALTER TABLE public.offer_reservations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ores_own ON public.offer_reservations;
CREATE POLICY ores_own ON public.offer_reservations
  FOR ALL USING (
    customer_id = public.my_customer_id()
    OR public.get_my_role() IN ('admin','super_admin','service')
  );

-- ── N2. offer_waitlist — "tell me when it is back" ───────────────────────────
CREATE TABLE IF NOT EXISTS public.offer_waitlist (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listing_id  bigint NOT NULL REFERENCES public.supplier_offer_listings(id) ON DELETE CASCADE,
  customer_id uuid   NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  notified_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_offer_waitlist
  ON public.offer_waitlist(listing_id, customer_id);

ALTER TABLE public.offer_waitlist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owl_own ON public.offer_waitlist;
CREATE POLICY owl_own ON public.offer_waitlist
  FOR ALL USING (
    customer_id = public.my_customer_id()
    OR public.get_my_role() IN ('admin','super_admin','service')
  );

-- ── N3. offer_push_log — who we pushed which listing to ──────────────────────
CREATE TABLE IF NOT EXISTS public.offer_push_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listing_id  bigint NOT NULL REFERENCES public.supplier_offer_listings(id) ON DELETE CASCADE,
  customer_id uuid   NOT NULL,
  kind        text   NOT NULL,     -- 'match' | 'back_in_stock'
  result      jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_offer_push_listing ON public.offer_push_log(listing_id);
ALTER TABLE public.offer_push_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS opl_admin ON public.offer_push_log;
CREATE POLICY opl_admin ON public.offer_push_log
  FOR ALL USING (public.get_my_role() IN ('admin','super_admin','service'));

-- ── B5. carry the listing onto the order line ────────────────────────────────
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS offer_listing_id bigint;
CREATE INDEX IF NOT EXISTS ix_oi_offer_listing
  ON public.order_items(offer_listing_id) WHERE offer_listing_id IS NOT NULL;

-- ── helpers ──────────────────────────────────────────────────────────────────
-- Units held by OTHER customers right now (expired holds count as free).
CREATE OR REPLACE FUNCTION public._offer_held_qty(
  p_listing_id bigint,
  p_exclude_customer uuid DEFAULT NULL
) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT coalesce(sum(r.qty), 0)
  FROM public.offer_reservations r
  WHERE r.listing_id = p_listing_id
    AND r.status = 'held'
    AND r.expires_at > now()
    AND (p_exclude_customer IS NULL OR r.customer_id <> p_exclude_customer);
$$;

CREATE OR REPLACE FUNCTION public._offer_hold_minutes() RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT coalesce(
    (SELECT (value->>'cart_hold_minutes')::int FROM app_settings WHERE key='offer_marketplace_config'),
    30);
$$;

-- A backend string with {placeholders} filled in — the Dart side never builds
-- a sentence. (There is no SQL cf(); c()/cf() are the Flutter-side readers.)
CREATE OR REPLACE FUNCTION public._offer_copy(p_key text, p_vars jsonb DEFAULT '{}'::jsonb)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare v text; k text;
begin
  select value into v from storefront_ui_label where key = p_key;
  if v is null then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    v := replace(v, '{'||k||'}', coalesce(p_vars->>k,''));
  end loop;
  return v;
end;
$$;

-- ── B1 + N1 + N3. _offer_display_block — customer-safe card, zero identity ───
DROP FUNCTION IF EXISTS public._offer_display_block(public.supplier_offer_listings);
CREATE OR REPLACE FUNCTION public._offer_display_block(
  p_row      public.supplier_offer_listings,
  p_customer uuid    DEFAULT NULL,
  p_matched  boolean DEFAULT false
) RETURNS jsonb
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
  v_held  numeric;
  v_left  numeric;
  v_sold_out boolean;
  v_waitlisted boolean := false;
begin
  select m.id, m.product_name as name, m.marketer as company, m.pack_size as pack,
         nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
    into v_med
  from "MEDICINE" m where m.id = p_row.product_id;

  v_mrp := coalesce(v_med.mrp, 0);

  -- live availability = declared qty minus what OTHER carts are holding
  v_held := public._offer_held_qty(p_row.id, p_customer);
  v_left := greatest(coalesce(p_row.available_qty,0) - v_held, 0);
  v_sold_out := v_left <= 0;

  if p_customer is not null then
    select true into v_waitlisted from public.offer_waitlist w
     where w.listing_id = p_row.id and w.customer_id = p_customer limit 1;
    v_waitlisted := coalesce(v_waitlisted, false);
  end if;

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

  if p_row.listing_type = 'near_expiry' and p_row.batch_expiry_date is not null then
    v_months_left := extract(month from age(p_row.batch_expiry_date, current_date))::integer
                   + extract(year from age(p_row.batch_expiry_date, current_date))::integer*12;
    v_near_expiry_label := v_months_left::text||' month'||case when v_months_left=1 then '' else 's' end||' left';
  end if;

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
    -- live qty AFTER other customers' cart holds
    'available_qty',   v_left,
    'qty_display',     case when v_sold_out
                         then coalesce((select value from storefront_ui_label where key='offer_sold_out'),'Sold out')
                         else v_left::int::text||' units left' end,
    'qty_low',         (not v_sold_out) and v_left <= 10,
    'sold_out',        v_sold_out,
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
    -- auto-match (#178 §3): this pharmacy already buys this product
    'is_matched',      coalesce(p_matched,false),
    'match_label',     case when coalesce(p_matched,false)
                         then coalesce((select value from storefront_ui_label where key='offer_match_label'),'You order this') end,
    -- waitlist (#178 §2)
    'can_waitlist',    v_sold_out,
    'waitlisted',      v_waitlisted,
    'action_label',    case when v_sold_out then
                              case when v_waitlisted
                                then coalesce((select value from storefront_ui_label where key='offer_waitlisted_btn'),'On waitlist')
                                else coalesce((select value from storefront_ui_label where key='offer_waitlist_btn'),'Notify me') end
                            else coalesce((select value from storefront_ui_label where key='offer_add_btn'),'Add to Cart') end,
    'action_enabled',  (not v_sold_out) or (not v_waitlisted),
    -- seller display: ALWAYS mediBO, never the real supplier
    'seller',          'mediBO',
    'seller_display',  coalesce((select value from storefront_ui_label where key='offer_seller_label'),'Sold by mediBO')
  );
end;
$$;

-- ── B1 + N3. offers_feed — FIXED aggregate, zone-correct, match-ranked ───────
DROP FUNCTION IF EXISTS public.offers_feed(uuid, integer, integer);
CREATE OR REPLACE FUNCTION public.offers_feed(
  p_zone_id   smallint DEFAULT NULL,
  p_offset    integer  DEFAULT 0,
  p_limit     integer  DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role  text := public.get_my_role();
  v_cust  uuid := public.my_customer_id();
  v_zone  smallint;
  v_rows  jsonb;
  v_total bigint := 0;
  v_title text := coalesce((select value from storefront_ui_label where key='offers_feed_title'),'Offers');
  v_empty text := coalesce((select value from storefront_ui_label where key='offers_feed_empty'),'No offers right now');
begin
  if v_role not in ('admin','super_admin','service') and not public.viewer_is_approved_customer() then
    return jsonb_build_object('ok',false,'error','forbidden',
      'message', coalesce((select value from storefront_ui_label where key='offers_forbidden'),
                          'Offers are available to approved pharmacies.'));
  end if;

  v_zone := coalesce(p_zone_id, (select z.zone_id from public._storefront_viewer() z));

  with base as (
    select sol as rec, sol.id, sol.product_id, sol.listing_type,
           sol.available_qty, sol.created_at
    from public.supplier_offer_listings sol
    where sol.status = 'active'
      and sol.available_qty > 0
      and (sol.end_date is null or sol.end_date >= current_date)
      and (sol.batch_expiry_date is null or sol.batch_expiry_date > current_date)
      and (sol.zone_ids is null or v_zone is null or v_zone = any(sol.zone_ids))
  ),
  -- auto-match resolved SET-BASED (never a per-row helper scan over order_items)
  hist as (
    select oi.product_id
    from order_items oi
    join orders o on o.id = oi.order_id
    where v_cust is not null
      and o.customer_id = v_cust
      and oi.product_id in (select b.product_id from base b)
      and o.created_at > now() - interval '180 days'
    group by oi.product_id
  ),
  ranked as (
    select b.*, (h.product_id is not null) as is_matched, count(*) over () as total
    from base b left join hist h on h.product_id = b.product_id
  ),
  page as (
    select * from ranked
    order by is_matched desc,
             case listing_type when 'near_expiry' then 0 when 'scheme' then 1 else 2 end,
             available_qty desc, created_at desc
    limit p_limit offset p_offset
  )
  select coalesce(max(total),0),
         jsonb_agg(public._offer_display_block(rec, v_cust, is_matched)
                   order by is_matched desc,
                            case listing_type when 'near_expiry' then 0 when 'scheme' then 1 else 2 end,
                            available_qty desc, created_at desc)
    into v_total, v_rows
  from page;

  return jsonb_build_object(
    'ok',        true,
    'title',     v_title,
    'count',     coalesce(v_total,0),
    'has_more',  coalesce(v_total,0) > p_offset + p_limit,
    'empty',     case when coalesce(v_total,0)=0 then v_empty else null end,
    'load_more_label', coalesce((select value from storefront_ui_label where key='offer_load_more'),'Load more'),
    'retry_label',     coalesce((select value from storefront_ui_label where key='offer_retry'),'Retry'),
    'hold_note',       coalesce((select value from storefront_ui_label where key='offer_hold_note'),'')
                       , 'rows', coalesce(v_rows,'[]'::jsonb)
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.offers_feed TO authenticated;

-- ── B4 + N1. offer_add_to_cart — holds units, records the disclosure ─────────
DROP FUNCTION IF EXISTS public.offer_add_to_cart(bigint, numeric);
CREATE OR REPLACE FUNCTION public.offer_add_to_cart(
  p_listing_id bigint,
  p_qty        numeric DEFAULT 1,
  p_disclosure_seen boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_cust  uuid := public.my_customer_id();
  v_uid   uuid := auth.uid();
  v_sol   public.supplier_offer_listings%rowtype;
  v_med   record;
  v_price numeric;
  v_held  numeric;
  v_left  numeric;
  v_mins  integer := public._offer_hold_minutes();
  v_label text;
begin
  if v_uid is null then
    return jsonb_build_object('ok',false,'error','not_authenticated');
  end if;
  if not public.viewer_is_approved_customer() then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  if v_cust is null then
    return jsonb_build_object('ok',false,'error','no_customer');
  end if;

  -- serialize per listing: two carts racing for the last units queue here
  select * into v_sol from public.supplier_offer_listings
   where id = p_listing_id FOR UPDATE;

  if not found then
    return jsonb_build_object('ok',false,'error','listing_not_found');
  end if;
  if v_sol.status <> 'active' then
    return jsonb_build_object('ok',false,'error','listing_unavailable',
      'message', coalesce((select value from storefront_ui_label where key='offer_unavailable'),'This offer is no longer available'));
  end if;

  v_held := public._offer_held_qty(p_listing_id, v_cust);
  v_left := greatest(v_sol.available_qty - v_held, 0);

  if v_left <= 0 then
    return jsonb_build_object('ok',false,'error','sold_out','can_waitlist',true,
      'message', coalesce((select value from storefront_ui_label where key='offer_sold_out'),'Sold out'));
  end if;
  if p_qty < coalesce(v_sol.min_order_qty,1) then
    return jsonb_build_object('ok',false,'error','min_qty',
      'message', public._offer_copy('offer_min_qty_msg', jsonb_build_object('qty', coalesce(v_sol.min_order_qty,1)::int::text)));
  end if;
  if p_qty > v_left then
    return jsonb_build_object('ok',false,'error','insufficient_qty','qty_left',v_left,
      'message', public._offer_copy('offer_only_left_msg', jsonb_build_object('qty', v_left::int::text)));
  end if;
  -- B4: a near-expiry line may not enter a cart without a recorded opt-in
  if v_sol.listing_type = 'near_expiry' and not coalesce(p_disclosure_seen,false) then
    return jsonb_build_object('ok',false,'error','disclosure_required',
      'message', coalesce((select value from storefront_ui_label where key='offer_near_expiry_disclosure'),''));
  end if;

  v_price := case
    when coalesce(v_sol.net_price,0) > 0 then v_sol.net_price
    when coalesce(v_sol.offer_ptr,0) > 0 and coalesce(v_sol.discount_pct,0) > 0
      then round(v_sol.offer_ptr*(1-v_sol.discount_pct/100),2)
    when coalesce(v_sol.offer_ptr,0) > 0 then v_sol.offer_ptr
    else 0
  end;

  select m.id, m.product_name as name, m.marketer as company, m.pack_size as pack,
         nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
    into v_med from "MEDICINE" m where m.id = v_sol.product_id;

  if exists (select 1 from cart_items
              where customer_id = v_cust and offer_listing_id = p_listing_id) then
    update cart_items set
      quantity   = p_qty::integer,
      price      = v_price,
      updated_at = now()
    where customer_id = v_cust and offer_listing_id = p_listing_id;
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

  -- N1: hold the units for this cart (idempotent per listing+customer)
  update public.offer_reservations
     set qty = p_qty, expires_at = now() + make_interval(mins => v_mins)
   where listing_id = p_listing_id and customer_id = v_cust and status = 'held';
  if not found then
    insert into public.offer_reservations(listing_id, customer_id, qty, expires_at)
    values (p_listing_id, v_cust, p_qty, now() + make_interval(mins => v_mins));
  end if;

  -- B4: record the short-dated opt-in
  if v_sol.listing_type = 'near_expiry' then
    insert into public.offer_near_expiry_disclosures(customer_id, listing_id)
    values (v_cust, p_listing_id);
  end if;

  v_label := coalesce((select value from storefront_ui_label where key='offer_added_to_cart'),'Added to cart');
  return jsonb_build_object(
    'ok',      true,
    'message', v_label,
    'listing_id', p_listing_id,
    'qty',     p_qty,
    'qty_left', greatest(v_left - p_qty, 0),
    'hold_minutes', v_mins,
    'hold_note', public._offer_copy('offer_hold_msg', jsonb_build_object('mins', v_mins::text)),
    'requires_disclosure', v_sol.listing_type = 'near_expiry'
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.offer_add_to_cart TO authenticated;

-- ── N2. offer_waitlist_join — "notify me when it is back" ────────────────────
CREATE OR REPLACE FUNCTION public.offer_waitlist_join(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_cust uuid := public.my_customer_id();
begin
  if v_cust is null or not public.viewer_is_approved_customer() then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  if not exists (select 1 from public.supplier_offer_listings where id = p_listing_id) then
    return jsonb_build_object('ok',false,'error','listing_not_found');
  end if;

  insert into public.offer_waitlist(listing_id, customer_id)
  values (p_listing_id, v_cust)
  on conflict (listing_id, customer_id) do update set notified_at = null;

  return jsonb_build_object('ok',true,'listing_id',p_listing_id,'waitlisted',true,
    'message', coalesce((select value from storefront_ui_label where key='offer_waitlist_toast'),
                        'We will message you when this offer is back'),
    'action_label', coalesce((select value from storefront_ui_label where key='offer_waitlisted_btn'),'On waitlist'));
end;
$$;
GRANT EXECUTE ON FUNCTION public.offer_waitlist_join TO authenticated;

-- ── N1. _offer_reservation_sweep — auto-release abandoned holds ──────────────
CREATE OR REPLACE FUNCTION public._offer_reservation_sweep() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare v_released integer;
begin
  update public.offer_reservations
     set status = 'released', released_at = now()
   where status = 'held' and expires_at <= now();
  GET DIAGNOSTICS v_released = ROW_COUNT;
  return jsonb_build_object('ok',true,'released',v_released);
end;
$$;

-- ── N2. _offer_waitlist_notify_cron — back-in-stock messages ─────────────────
CREATE OR REPLACE FUNCTION public._offer_waitlist_notify_cron() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare r record; v_res jsonb; v_sent int := 0;
begin
  for r in
    select w.id, w.listing_id, w.customer_id, sol.product_id,
           coalesce(m.product_name,'') as product_name,
           coalesce(sol.discount_pct,0) as discount_pct,
           greatest(sol.available_qty - public._offer_held_qty(sol.id, null), 0) as qty_left
    from public.offer_waitlist w
    join public.supplier_offer_listings sol on sol.id = w.listing_id
    left join "MEDICINE" m on m.id = sol.product_id
    where w.notified_at is null
      and sol.status = 'active'
      and sol.available_qty > 0
    limit 200
  loop
    if r.qty_left <= 0 then continue; end if;
    v_res := public.wa_send_event('offer_back_in_stock', r.customer_id,
      jsonb_build_object(
        'product_name', r.product_name,
        'qty_left',     r.qty_left::int::text,
        'discount_pct', public._num_label(r.discount_pct)),
      null, null);
    insert into public.offer_push_log(listing_id, customer_id, kind, result)
    values (r.listing_id, r.customer_id, 'back_in_stock', v_res);
    update public.offer_waitlist set notified_at = now() where id = r.id;
    v_sent := v_sent + 1;
  end loop;
  return jsonb_build_object('ok',true,'notified',v_sent);
end;
$$;

-- ── N3. offer_match_customers — pharmacies that already buy this product ─────
CREATE OR REPLACE FUNCTION public.offer_match_customers(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
  v_sol  public.supplier_offer_listings%rowtype;
  v_rows jsonb;
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  select * into v_sol from public.supplier_offer_listings where id = p_listing_id;
  if not found then return jsonb_build_object('ok',false,'error','listing_not_found'); end if;

  select coalesce(jsonb_agg(row_to_json(r) order by r.times_ordered desc), '[]'::jsonb)
    into v_rows
  from (
    select o.customer_id,
           coalesce(pp.pharmacy_name,'') as pharmacy_name,
           count(*)::int                 as times_ordered,
           to_char(max(o.created_at) at time zone 'Asia/Kolkata','DD Mon YYYY') as last_ordered
    from order_items oi
    join orders o on o.id = oi.order_id
    join pharmacy_profiles pp on pp.id = o.customer_id
    where oi.product_id = v_sol.product_id
      and o.customer_id is not null
      and coalesce(pp.approved,false)
      and coalesce(pp.is_deleted,false) = false
      and (v_sol.zone_ids is null or pp.zone_id = any(v_sol.zone_ids))
      and o.created_at > now() - interval '180 days'
    group by o.customer_id, pp.pharmacy_name
  ) r;

  return jsonb_build_object('ok',true,'listing_id',p_listing_id,
    'count', jsonb_array_length(v_rows), 'rows', v_rows);
end;
$$;
GRANT EXECUTE ON FUNCTION public.offer_match_customers TO authenticated;

-- ── N3. offer_push_matched — WhatsApp the matched pharmacies ─────────────────
CREATE OR REPLACE FUNCTION public.offer_push_matched(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
  v_sol  public.supplier_offer_listings%rowtype;
  v_name text;
  r record; v_res jsonb; v_sent int := 0; v_skipped int := 0;
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  select * into v_sol from public.supplier_offer_listings where id = p_listing_id;
  if not found then return jsonb_build_object('ok',false,'error','listing_not_found'); end if;
  if v_sol.status <> 'active' then
    return jsonb_build_object('ok',false,'error','listing_unavailable');
  end if;
  select coalesce(m.product_name,'') into v_name from "MEDICINE" m where m.id = v_sol.product_id;

  for r in
    select (x->>'customer_id')::uuid as customer_id
    from jsonb_array_elements((public.offer_match_customers(p_listing_id))->'rows') x
  loop
    v_res := public.wa_send_event('offer_match', r.customer_id,
      jsonb_build_object(
        'product_name', v_name,
        'discount_pct', public._num_label(coalesce(v_sol.discount_pct,0)),
        'qty_left',     v_sol.available_qty::int::text),
      null, null);
    insert into public.offer_push_log(listing_id, customer_id, kind, result)
    values (p_listing_id, r.customer_id, 'match', v_res);
    if coalesce((v_res->>'ok')::boolean,false) then v_sent := v_sent + 1;
    else v_skipped := v_skipped + 1; end if;
  end loop;

  return jsonb_build_object('ok',true,'listing_id',p_listing_id,
    'sent',v_sent,'skipped',v_skipped,
    'message', public._offer_copy('offer_push_result_msg',
                 jsonb_build_object('sent', v_sent::text, 'skipped', v_skipped::text)));
end;
$$;
GRANT EXECUTE ON FUNCTION public.offer_push_matched TO authenticated;

-- ── N1. _offer_confirm_qty — atomic deduction + consume the hold ─────────────
CREATE OR REPLACE FUNCTION public._offer_confirm_qty(
  p_listing_id bigint,
  p_qty        numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_updated integer;
  v_cust    uuid := public.my_customer_id();
begin
  -- THE hard ceiling. One statement, one row lock: two concurrent confirms for
  -- the last units cannot both pass the available_qty >= p_qty predicate.
  UPDATE public.supplier_offer_listings
  SET available_qty = available_qty - p_qty,
      sold_qty      = sold_qty + p_qty,
      updated_at    = now()
  WHERE id = p_listing_id
    AND available_qty >= p_qty
    AND status = 'active';

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  if v_updated = 0 then
    return jsonb_build_object('ok',false,'error','offer_qty_exhausted',
      'listing_id', p_listing_id,
      'message', coalesce((select value from storefront_ui_label where key='offer_sold_out'),'Sold out'));
  end if;

  -- the buyer's own hold is now spent (idempotent: a retry finds nothing held)
  update public.offer_reservations
     set status = 'consumed', consumed_at = now()
   where listing_id = p_listing_id and customer_id = v_cust and status = 'held';

  UPDATE public.supplier_offer_listings
  SET status = 'expired'
  WHERE id = p_listing_id AND available_qty <= 0;

  return jsonb_build_object('ok',true,'listing_id',p_listing_id,'deducted',p_qty);
end;
$$;

-- ── B3. _cart_unavailable_lines — an offer line is committed supply ──────────
CREATE OR REPLACE FUNCTION public._cart_unavailable_lines()
RETURNS TABLE(product_id bigint, product_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare v_approved boolean; v_zone smallint; v_cid uuid;
begin
  if auth.uid() is null then return; end if;
  select approved, zone_id into v_approved, v_zone from public._storefront_viewer();
  if not coalesce(v_approved,false) or v_zone is null then return; end if;
  v_cid := public.my_customer_id();
  if v_cid is null then return; end if;
  return query
    select p.pid, m.product_name
    from cart_items ci
    cross join lateral (select nullif(regexp_replace(coalesce(ci.product_id::text,''),'[^0-9]','','g'),'')::bigint as pid) p
    join "MEDICINE" m on m.id = p.pid
    where ci.customer_id = v_cid
      and p.pid is not null
      and case
            when ci.offer_listing_id is null
              then public.medicine_zone_standby(p.pid, v_zone) <= 0
            -- an offer line does not need zone standby: the listing IS the
            -- supply. It is unavailable only if that listing died or ran short.
            else not exists (
              select 1 from public.supplier_offer_listings sol
               where sol.id = ci.offer_listing_id
                 and sol.status = 'active'
                 and sol.available_qty >= ci.quantity)
          end;
end;
$$;

-- ── B5. cart_state — carry the offer onto the line ──────────────────────────
CREATE OR REPLACE FUNCTION public.cart_state(p_guest_uid uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
declare v_uid uuid := coalesce(public.viewer_cart_user(), p_guest_uid);
        v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
        v_items jsonb; v_units int; v_mrp numeric; v_lines int;
begin
  if auth.uid() is not null then v_uid := public.viewer_cart_user(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''), 'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', coalesce(ci.mrp,0),
           'image_url', coalesce(ci.image_url,''), 'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(mb.buyable, false),
           -- offer lines (CHANGE #223): the listing rides along so the order,
           -- billing and direct-buy routing all know this line is committed.
           'offer_listing_id', ci.offer_listing_id,
           'is_offer', (ci.offer_listing_id is not null),
           'offer_price', case when ci.offer_listing_id is not null then coalesce(ci.price,0) end,
           'offer_price_display', case when ci.offer_listing_id is not null and coalesce(ci.price,0) > 0
                                       then public.inr_money(ci.price) end,
           'offer_badge', case when ci.offer_listing_id is not null
                          then coalesce((select value from storefront_ui_label where key='offer_cart_badge'),'Offer') end,
           -- line total = qty * MRP. No discount, no GST.
           'line_mrp', round(coalesce(ci.quantity,0) * coalesce(ci.mrp,0), 2))
           order by ci.id), '[]'::jsonb),
         coalesce(sum(ci.quantity),0),
         coalesce(round(sum(coalesce(ci.quantity,0) * coalesce(ci.mrp,0)), 2),0)
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

  return jsonb_build_object(
    'items', v_items,
    'admin_removed', '[]'::jsonb,
    'item_count', v_lines,
    'unit_count', v_units,
    'mrp_total', v_mrp,
    -- the single subtotal the customer pays
    'subtotal', v_mrp,
    'net_payable', v_mrp,
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
end
$$;

-- ── B5. explode_order_items — keep the listing on the order line ─────────────
CREATE OR REPLACE FUNCTION public.explode_order_items()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.items IS NOT DISTINCT FROM OLD.items) THEN
    RETURN NEW;  -- items unchanged: do NOT delete/recreate order_items
  END IF;

  DELETE FROM order_items WHERE order_id = NEW.id;
  IF NEW.items IS NOT NULL AND jsonb_typeof(NEW.items)='array' THEN
    INSERT INTO order_items (order_id, product_name, product_id, quantity, mrp, price,
                             gst_percent, line_total, pharmacy_name, payment_id, status,
                             offer_listing_id)
    SELECT NEW.id,
           COALESCE(it->>'product_name', it->>'name'),
           (SELECT id FROM "MEDICINE"
            WHERE product_name = COALESCE(it->>'product_name', it->>'name') LIMIT 1),
           COALESCE((it->>'quantity')::numeric, (it->>'qty')::numeric),
           NULLIF(it->>'mrp','')::numeric, NULLIF(it->>'price','')::numeric,
           NULLIF(it->>'gst_percent','')::numeric, NULLIF(it->>'line_total','')::numeric,
           NEW.pharmacy_name, NEW.payment_id, NEW.status,
           NULLIF(it->>'offer_listing_id','')::bigint
    FROM jsonb_array_elements(NEW.items) AS it;
  END IF;
  RETURN NEW;
END;
$$;

-- ── B5. oi_rollup_to_inquiry — an offer line never enters the cascade ───────
CREATE OR REPLACE FUNCTION public.oi_rollup_to_inquiry()
RETURNS trigger
LANGUAGE plpgsql
AS $$
declare
  pid bigint := coalesce(NEW.product_id, OLD.product_id);
  pname text; v_today date; v_batch int; r record; v_zones smallint[] := '{}';
begin
  if current_setting('medibo.in_broadcast', true) = '1' then return coalesce(NEW, OLD); end if;

  if TG_OP = 'UPDATE'
     and NEW.product_id is not distinct from OLD.product_id
     and NEW.quantity   is not distinct from OLD.quantity
     and NEW.status     is not distinct from OLD.status
     and NEW.zone_id    is not distinct from OLD.zone_id
     and coalesce(NEW.received_locked,false) is not distinct from coalesce(OLD.received_locked,false)
  then
    return NEW;
  end if;

  if pid is null then return coalesce(NEW, OLD); end if;

  v_today := (now() at time zone 'Asia/Kolkata')::date;

  select coalesce(max(i.inquiry_batch),1) into v_batch
    from inquiry i where i.batch_date = v_today;

  -- one bucket per zone that still has open, accepted demand today
  for r in
    select oi.zone_id,
           sum(oi.quantity) as qty,
           max(oi.product_name) as pname
    from order_items oi
    join orders o on o.id = oi.order_id
    where oi.product_id = pid
      and o.status = 'accepted'
      and not coalesce(oi.received_locked,false)
      and coalesce(oi.at_warehouse,false) = false
      and coalesce(oi.packed,false) = false
      and oi.fulfillment_state <> 'received'
      and oi.fulfillment_state <> 'cancelled'
      and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
      and oi.zone_id is not null
      -- CHANGE #223 (direct buy): an offer line is already committed to its
      -- hidden supplier at an agreed price — never ask the cascade for it.
      and oi.offer_listing_id is null
    group by oi.zone_id
    having sum(oi.quantity) > 0
  loop
    v_zones := v_zones || r.zone_id;

    insert into inquiry (product_id, product_name, quantity, batch_date, zone_id,
                         inquiry_batch, inquiry_phase, available, out_of_stock,
                         we_dont_stock_this_product)
    values (pid, r.pname, r.qty, v_today, r.zone_id,
            coalesce(v_batch,1), 'draft', false, false, false)
    on conflict (product_id, batch_date, zone_id) do update
      set quantity     = excluded.quantity,
          product_name = coalesce(inquiry.product_name, excluded.product_name);
  end loop;

  -- zones that no longer have demand today: drop only untouched drafts
  delete from inquiry
   where product_id = pid
     and batch_date = v_today
     and asked_at is null
     and coalesce(inquiry_phase,'draft') = 'draft'
     and not (zone_id = any(v_zones));

  return coalesce(NEW, OLD);
end;
$$;

-- ── B5 + N1. _place_order_v2_core — confirm, route, consume, disclose ───────
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
     -- B8: #179 wrote source='offer' here, but orders_source_chk only allows
     -- website|whatsapp, so EVERY order containing an offer line died on a
     -- constraint violation. Offer-ness is a per-LINE fact anyway and now
     -- rides on order_items.offer_listing_id.
     'website',
     false,
     public.next_order_number())
  returning id, order_code into v_id, v_code;

  if v_has_offers then
    -- DIRECT BUY: point the offer lines straight at the hidden supplier so the
    -- normal supplier-order / receiving / pack lane picks them up, and the
    -- inquiry cascade skips them entirely.
    -- the supplier NAME the fulfilment lane speaks (same vocabulary the
    -- inquiry cascade writes): supplier_profiles.supplier_name, with the
    -- company registry as a fallback.
    update order_items oi
       set assigned_supplier = coalesce(sp.supplier_name, sc.supplier_company,
                                        sc.supplier_name, oi.assigned_supplier)
      from public.supplier_offer_listings sol
      left join supplier_profiles sp
             on sp.user_id = sol.supplier_id
            and coalesce(sp.is_deleted,false) = false
      left join supplier_company sc on sc.supplier_id = sol.supplier_id
     where oi.order_id = v_id
       and oi.offer_listing_id = sol.id;

    -- _offer_confirm_qty already flipped the holds to 'consumed' above; give
    -- them (and the short-dated opt-ins) the order they were spent on.
    update public.offer_reservations r
       set order_id = v_id
     where r.customer_id = v_cust and r.order_id is null
       and r.status = 'consumed'
       and r.listing_id in (select oi.offer_listing_id from order_items oi
                             where oi.order_id = v_id and oi.offer_listing_id is not null);

    update public.offer_near_expiry_disclosures d
       set order_id = v_id
     where d.customer_id = v_cust and d.order_id is null
       and d.listing_id in (select oi.offer_listing_id from order_items oi
                             where oi.order_id = v_id and oi.offer_listing_id is not null);
  end if;

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

-- ── crons ────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.schedule('offer-reservation-sweep', '*/5 * * * *',
      'SELECT public._offer_reservation_sweep()');
    PERFORM cron.schedule('offer-waitlist-notify', '*/10 * * * *',
      'SELECT public._offer_waitlist_notify_cron()');
  END IF;
END;
$$;

-- ── WhatsApp routes (disabled until a template is attached in Notifications) ─
INSERT INTO wa_event_routes (event_key, label, description, enabled, audience)
VALUES
  ('offer_match', 'Offer matched to buyer',
   'Sent to pharmacies that already buy this product when a new offer is listed.',
   false, 'customer'),
  ('offer_back_in_stock', 'Offer back in stock',
   'Sent to pharmacies on an offer waitlist when units come back.',
   false, 'customer')
ON CONFLICT (event_key) DO NOTHING;

-- ── strings (every customer-facing word lives here, never in Dart) ───────────
INSERT INTO storefront_ui_label (key, value) VALUES
  ('offer_add_btn',          'Add to Cart'),
  ('offer_sold_out',         'Sold out'),
  ('offer_unavailable',      'This offer is no longer available'),
  ('offer_waitlist_btn',     'Notify me'),
  ('offer_waitlisted_btn',   'On waitlist'),
  ('offer_waitlist_toast',   'We will message you when this offer is back'),
  ('offer_load_more',        'Load more'),
  ('offer_retry',            'Retry'),
  ('offer_cancel_btn',       'Cancel'),
  ('offer_match_label',      'You order this'),
  ('offer_cart_badge',       'Offer'),
  ('offers_forbidden',       'Offers are available to approved pharmacies.'),
  ('offer_hold_note',        'Units are held for your cart for a short while'),
  ('offer_push_btn',         'Push to matched buyers'),
  ('offer_match_title',      'Matched buyers')
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- templates filled by _offer_copy()
INSERT INTO storefront_ui_label (key, value) VALUES
  ('offer_min_qty_msg',      'Minimum order is {qty} units'),
  ('offer_only_left_msg',    'Only {qty} units available'),
  ('offer_hold_msg',         'Held for your cart for {mins} minutes'),
  ('offer_push_result_msg',  'Sent to {sent} buyers, {skipped} skipped')
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- B6. Every offers label #179 wrote went into storefront_ui_label, but the
-- Flutter c() reader is fed by ui_copy (ui_boot → ui_copy_all). So EVERY
-- c('offer…') on the three offers screens rendered as an empty string. Mirror
-- the screen-chrome keys into ui_copy, which is the table c() actually reads.
INSERT INTO ui_copy (key, value)
SELECT s.key, to_jsonb(s.value)
FROM storefront_ui_label s
WHERE s.key LIKE 'offer%' OR s.key LIKE 'supplier_offer%' OR s.key LIKE 'admin_offer%'
ON CONFLICT (key) DO NOTHING;   -- never clobber copy another feature owns

GRANT EXECUTE ON FUNCTION public._offer_held_qty TO authenticated;
GRANT EXECUTE ON FUNCTION public.offer_waitlist_join TO authenticated;

-- ── B7. MEDICINE column names ────────────────────────────────────────────────
-- #179 addressed the catalog as m."NAME" / m."COMPANY" / m."PACK". Those
-- columns do not exist — the table has product_name / marketer / pack_size. So
-- _offer_display_block, offer_add_to_cart, supplier_offers_mine and
-- admin_offers_list all raised 42703 the moment a listing existed. The first
-- two are rewritten above; these two are the rest of the blast radius.
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
  v_empty text := coalesce((select value from storefront_ui_label where key='supplier_offers_empty'),'No listings yet');
begin
  if v_role not in ('supplier','admin','super_admin','service') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;

  select count(*) into v_count
  from public.supplier_offer_listings sol
  where sol.supplier_id = auth.uid()
    and (p_status is null or sol.status = p_status);

  select coalesce(jsonb_agg(row_to_json(r)), '[]'::jsonb)
    into v_rows
  from (
    select
      sol.id,
      sol.product_id,
      coalesce(m.product_name,'') as product_name,
      coalesce(m.marketer,'')     as company,
      sol.listing_type,
      case sol.listing_type
        when 'scheme'      then coalesce((select value from storefront_ui_label where key='offer_type_scheme'),'Scheme')
        when 'near_expiry' then coalesce((select value from storefront_ui_label where key='offer_type_near_expiry'),'Near Expiry')
        else               coalesce((select value from storefront_ui_label where key='offer_type_discount'),'Offer')
      end                  as type_label,
      sol.available_qty,
      sol.sold_qty,
      sol.available_qty + sol.sold_qty as total_listed_qty,
      -- units other carts are holding right now (#178 §2)
      public._offer_held_qty(sol.id, null) as held_qty,
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
      sol.available_qty::int::text||' left · '||sol.sold_qty::int::text||' sold' as stats_display,
      case when sol.batch_expiry_date is not null then to_char(sol.batch_expiry_date,'DD Mon YYYY') else null end as expiry_display,
      case when sol.end_date is not null then to_char(sol.end_date,'DD Mon YYYY') else null end as end_date_display,
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
    'rows',     v_rows
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.supplier_offers_mine TO authenticated;

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

  select count(*) into v_count
  from public.supplier_offer_listings sol
  where (p_status is null or sol.status = p_status);

  select coalesce(jsonb_agg(row_to_json(r)), '[]'::jsonb)
    into v_rows
  from (
    select
      sol.id, sol.listing_type, sol.status,
      sol.available_qty, sol.sold_qty, sol.margin_pct,
      public._offer_held_qty(sol.id, null) as held_qty,
      sol.offer_ptr, sol.discount_pct, sol.net_price,
      sol.scheme_buy_qty, sol.scheme_free_qty,
      sol.batch_expiry_date, sol.end_date, sol.created_at,
      coalesce(m.product_name,'') as product_name,
      coalesce(m.marketer,'')     as company,
      -- supplier identity ONLY for admin
      sol.supplier_id,
      coalesce(sc.supplier_company, sc.supplier_name, '(no name)') as supplier_name,
      sol.moderation_note,
      case sol.status when 'active' then '#D1FAE5' else '#FEE2E2' end as status_bg,
      case sol.status when 'active' then '#065F46' else '#991B1B' end as status_fg,
      (select count(*) from public.offer_waitlist w where w.listing_id = sol.id) as waitlist_count
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
    'push_label', coalesce((select value from storefront_ui_label where key='offer_push_btn'),'Push to matched buyers'),
    'rows',     v_rows
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.admin_offers_list TO authenticated;

-- ── B5 (cont). The other two cascade doors an offer line must not walk through
-- inquiry_start_batch_for_order() runs on accept and created an inquiry row for
-- EVERY product on the order, stamping inquiry_id on the line. That handed the
-- offer line to inquiry_broadcast_to_oi(), whose unconfirmed branch sets
-- assigned_supplier = null — so the direct-buy assignment was wiped the moment
-- the order was accepted. Both now skip lines that carry an offer_listing_id.
CREATE OR REPLACE FUNCTION public.inquiry_start_batch_for_order(p_order_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare
  v_date date := (now() at time zone 'Asia/Kolkata')::date;
  v_batch int; r record; v_inq bigint;
begin
  select coalesce(max(i.inquiry_batch),0)+1 into v_batch
    from inquiry i where i.batch_date = v_date;

  for r in
    select oi.product_id,
           max(oi.product_name) as product_name,
           max(oi.mrp)          as mrp,
           max(oi.gst_percent)  as gst_percent
    from order_items oi
    where oi.order_id = p_order_id
      and oi.product_id is not null
      and oi.fulfillment_state <> 'cancelled'
      and oi.offer_listing_id is null      -- CHANGE #223: direct-buy line
    group by oi.product_id
  loop
    select i.id into v_inq
      from inquiry i
     where i.product_id = r.product_id and i.batch_date = v_date
     order by i.id limit 1;

    if v_inq is null then
      insert into inquiry (product_id, product_name, quantity, mrp, gst_percent,
                           batch_date, inquiry_batch, inquiry_phase,
                           available, out_of_stock, we_dont_stock_this_product)
      values (r.product_id, r.product_name, 0, r.mrp, r.gst_percent,
              v_date, v_batch, 'draft', false, false, false)
      returning id into v_inq;
    end if;

    update order_items oi
       set inquiry_id = v_inq
     where oi.order_id = p_order_id
       and oi.product_id = r.product_id
       and oi.fulfillment_state <> 'cancelled'
       and oi.offer_listing_id is null;    -- CHANGE #223

    update inquiry i
       set quantity = coalesce((select sum(oi.quantity) from order_items oi
                                 where oi.inquiry_id = i.id
                                   and oi.fulfillment_state <> 'cancelled'
                                   and coalesce(oi.at_warehouse,false) = false
                                   and coalesce(oi.packed,false) = false
                                   and oi.fulfillment_state <> 'received'), 0)
     where i.id = v_inq;
  end loop;

  return v_batch;
end;
$$;

CREATE OR REPLACE FUNCTION public.inquiry_broadcast_to_oi()
RETURNS trigger
LANGUAGE plpgsql
AS $$
begin
  perform set_config('medibo.in_broadcast','1',true);

  if public._inq_confirmed(NEW) then
    update public.order_items oi
       set assigned_supplier = NEW.current_supplier,
           inquiry_id        = coalesce(oi.inquiry_id, NEW.id)
     where oi.product_id = NEW.product_id
       and oi.order_date = NEW.batch_date
       and oi.fulfillment_state <> 'cancelled'
       and not coalesce(oi.received_locked,false)
       and oi.offer_listing_id is null;    -- CHANGE #223: never re-route a
                                           -- committed offer line
  else
    update public.order_items oi
       set assigned_supplier = null
     where oi.inquiry_id = NEW.id
       and oi.order_date = NEW.batch_date
       and oi.fulfillment_state <> 'cancelled'
       and not coalesce(oi.received_locked,false)
       and coalesce(oi.at_warehouse,false) = false
       and coalesce(oi.packed,false) = false
       and oi.offer_listing_id is null;    -- CHANGE #223
  end if;

  perform set_config('medibo.in_broadcast','0',true);
  return NEW;
end;
$$;

-- ── B5 (cont). The supplier order is the last door ───────────────────────────
-- rebuild_all_supplier_orders() only admitted a line whose inquiry_id points at
-- a CONFIRMED inquiry. A direct-buy offer line has no inquiry by design, so it
-- was assigned to a supplier and then never appeared in that supplier's order —
-- invisible to shop counting, receiving and pack. A committed offer line is
-- admitted on exactly the same footing as a confirmed inquiry line.
CREATE OR REPLACE FUNCTION public.rebuild_all_supplier_orders(p_date date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r record; v_id uuid; v_n int := 0; v_units numeric := 0;
        v_day date := COALESCE(p_date, public.admin_active_date());
        v_stamp timestamptz;
BEGIN
  FOR r IN
    SELECT d.assigned_supplier AS supplier,
           jsonb_agg(jsonb_build_object(
             'product_id', d.product_id, 'product_name', d.product_name,
             'quantity', d.qty, 'mrp', d.mrp, 'pack_type', d.pack_type)
             ORDER BY d.product_name) AS items,
           sum(d.qty * COALESCE(d.mrp,0)) AS total,
           sum(d.qty) AS units
    FROM (
      SELECT oi.assigned_supplier, oi.product_id, oi.product_name,
             sum(oi.quantity) AS qty, max(oi.mrp) AS mrp, max(m.pack_type) AS pack_type
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      LEFT JOIN "MEDICINE" m ON m.id = oi.product_id
      WHERE oi.assigned_supplier IS NOT NULL
        AND ( oi.offer_listing_id IS NOT NULL          -- CHANGE #223 direct buy
              OR EXISTS (SELECT 1 FROM inquiry i
                     WHERE i.id = oi.inquiry_id
                       AND public._inq_confirmed(i)
                       AND i.batch_date = oi.order_date
                       AND i.current_supplier = oi.assigned_supplier) )
        AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day
        AND coalesce(o.fulfillment_status,'') NOT IN ('shipped','cancelled')
        AND coalesce(oi.fulfillment_state,'') <> 'cancelled'
      GROUP BY oi.assigned_supplier, oi.product_id, oi.product_name
    ) d
    GROUP BY d.assigned_supplier
  LOOP
    SELECT id INTO v_id FROM supplier_orders
     WHERE supplier_name = r.supplier
       AND order_date = v_day
       AND (status IS NULL OR status NOT IN ('shipped','closed','cancelled'))
     ORDER BY created_at LIMIT 1;

    IF v_id IS NULL THEN
      SELECT COALESCE(min(o.created_at), (v_day::text || ' 09:00')::timestamp AT TIME ZONE 'Asia/Kolkata')
        INTO v_stamp
        FROM order_items oi JOIN orders o ON o.id = oi.order_id
       WHERE oi.assigned_supplier = r.supplier
         AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day;

      INSERT INTO supplier_orders (supplier_name, supplier_id, spn, items, total_amount, status, order_id, order_date, created_at)
      VALUES (r.supplier,
              (SELECT id FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1),
              (SELECT "SPN" FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1),
              r.items, r.total, 'pending', NULL, v_day, v_stamp)
      RETURNING id INTO v_id;
    ELSE
      UPDATE supplier_orders
         SET items = r.items, total_amount = r.total,
             supplier_id = COALESCE(supplier_id,(SELECT id FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1)),
             spn = COALESCE(spn,(SELECT "SPN" FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1))
       WHERE id = v_id;
    END IF;

    v_n := v_n + 1; v_units := v_units + r.units;
  END LOOP;

  DELETE FROM supplier_orders so
   WHERE so.order_date = v_day
     AND (so.status IS NULL OR so.status NOT IN ('shipped','closed','cancelled'))
     AND NOT EXISTS (
       SELECT 1 FROM order_items oi
       JOIN orders o ON o.id = oi.order_id
       WHERE oi.assigned_supplier = so.supplier_name
         AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day
         AND coalesce(oi.fulfillment_state,'') <> 'cancelled'
         AND coalesce(o.fulfillment_status,'') <> 'cancelled');

  RETURN jsonb_build_object('ok', true, 'supplier_orders', v_n, 'units', v_units, 'date', v_day);
END;
$$;

-- the supplier shell's new Offers tab label (c() reads ui_copy)
INSERT INTO ui_copy (key, value) VALUES
  ('supplier_shell.tab_offers', to_jsonb('Offers'::text))
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

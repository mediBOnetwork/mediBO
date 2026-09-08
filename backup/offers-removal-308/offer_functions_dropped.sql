-- ============ _offer_confirm_qty(p_listing_id bigint, p_qty numeric) ============
CREATE OR REPLACE FUNCTION public._offer_confirm_qty(p_listing_id bigint, p_qty numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ _offer_copy(p_key text, p_vars jsonb) ============
CREATE OR REPLACE FUNCTION public._offer_copy(p_key text, p_vars jsonb DEFAULT '{}'::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text; k text;
begin
  select value into v from storefront_ui_label where key = p_key;
  if v is null then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    v := replace(v, '{'||k||'}', coalesce(p_vars->>k,''));
  end loop;
  return v;
end;
$function$
;

-- ============ _offer_display_block(p_row supplier_offer_listings, p_customer uuid, p_matched boolean) ============
CREATE OR REPLACE FUNCTION public._offer_display_block(p_row supplier_offer_listings, p_customer uuid DEFAULT NULL::uuid, p_matched boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ _offer_expiry_cron() ============
CREATE OR REPLACE FUNCTION public._offer_expiry_cron()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.supplier_offer_listings set status='expired',updated_at=now()
  where status='active'
    and ((end_date is not null and end_date<current_date)
      or (batch_expiry_date is not null and batch_expiry_date<=current_date)
      or available_qty<=0);
end;
$function$
;

-- ============ _offer_held_qty(p_listing_id bigint, p_exclude_customer uuid) ============
CREATE OR REPLACE FUNCTION public._offer_held_qty(p_listing_id bigint, p_exclude_customer uuid DEFAULT NULL::uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(sum(r.qty), 0)
  FROM public.offer_reservations r
  WHERE r.listing_id = p_listing_id
    AND r.status = 'held'
    AND r.expires_at > now()
    AND (p_exclude_customer IS NULL OR r.customer_id <> p_exclude_customer);
$function$
;

-- ============ _offer_hold_minutes() ============
CREATE OR REPLACE FUNCTION public._offer_hold_minutes()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(
    (SELECT (value->>'cart_hold_minutes')::int FROM app_settings WHERE key='offer_marketplace_config'),
    30);
$function$
;

-- ============ _offer_reservation_sweep() ============
CREATE OR REPLACE FUNCTION public._offer_reservation_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_released integer;
begin
  update public.offer_reservations
     set status = 'released', released_at = now()
   where status = 'held' and expires_at <= now();
  GET DIAGNOSTICS v_released = ROW_COUNT;
  return jsonb_build_object('ok',true,'released',v_released);
end;
$function$
;

-- ============ _offer_waitlist_notify_cron() ============
CREATE OR REPLACE FUNCTION public._offer_waitlist_notify_cron()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'product',      r.product_name,
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
$function$
;

-- ============ _sdo_set_updated_at() ============
CREATE OR REPLACE FUNCTION public._sdo_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin new.updated_at := now(); return new; end; $function$
;

-- ============ _vcm_short_dated_check() ============
CREATE OR REPLACE FUNCTION public._vcm_short_dated_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_months   numeric;
  v_pct      numeric;
  v_name     text;
begin
  if new.expiry_date is null then return new; end if;
  v_months := extract(year from age(new.expiry_date, current_date)) * 12
            + extract(month from age(new.expiry_date, current_date));
  select discount_pct into v_pct
    from public.short_dated_config
   where enabled and months_max > v_months
   order by months_max asc
   limit 1;
  if v_pct is null then return new; end if;

  select coalesce(m."PRODUCT_NAME", new.matched_name) into v_name
    from public."MEDICINE" m where m."ID" = new.product_id limit 1;
  v_name := coalesce(v_name, new.matched_name, 'Unknown');

  insert into public.short_dated_offers
    (product_id, product_name, supplier_name, batch_no, batch_expiry,
     available_qty, discount_pct, status, source_mention_id)
  values
    (new.product_id, v_name, new.supplier_name, new.batch_no, new.expiry_date,
     coalesce(new.qty, 1), v_pct, 'pending_confirm', new.id)
  on conflict do nothing;

  return new;
end; $function$
;

-- ============ admin_offer_margin_set(p_margin_pct numeric) ============
CREATE OR REPLACE FUNCTION public.admin_offer_margin_set(p_margin_pct numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := public.get_my_role();
begin
  if v_role not in ('admin','super_admin','service') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  insert into app_settings(key,value) values('offer_marketplace_config',jsonb_build_object('marketplace_margin_pct',p_margin_pct))
  on conflict(key) do update set value=excluded.value;
  return jsonb_build_object('ok',true,'margin_pct',p_margin_pct);
end;
$function$
;

-- ============ admin_offer_moderate(p_listing_id bigint, p_action text, p_note text, p_margin_pct numeric) ============
CREATE OR REPLACE FUNCTION public.admin_offer_moderate(p_listing_id bigint, p_action text, p_note text DEFAULT NULL::text, p_margin_pct numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := public.get_my_role();
begin
  if v_role not in ('admin','super_admin','service') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if p_action='remove' then
    update public.supplier_offer_listings set status='delisted',moderated_at=now(),moderated_by=auth.uid(),moderation_note=p_note,updated_at=now() where id=p_listing_id;
  elsif p_action='restore' then
    update public.supplier_offer_listings set status='active',moderated_at=now(),moderated_by=auth.uid(),moderation_note=p_note,updated_at=now() where id=p_listing_id;
  elsif p_action='set_margin' then
    if p_margin_pct is null then return jsonb_build_object('ok',false,'error','margin_required'); end if;
    update public.supplier_offer_listings set margin_pct=p_margin_pct,updated_at=now() where id=p_listing_id;
  else return jsonb_build_object('ok',false,'error','invalid_action'); end if;
  return jsonb_build_object('ok',true,'listing_id',p_listing_id,'action',p_action);
end;
$function$
;

-- ============ admin_offers_list(p_status text, p_offset integer, p_limit integer) ============
CREATE OR REPLACE FUNCTION public.admin_offers_list(p_status text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      sol.supplier_id,
      coalesce(sp.supplier_name, sc.supplier_company, sc.supplier_name, '(no name)') as supplier_name,
      sol.moderation_note,
      case sol.status when 'active' then '#D1FAE5' else '#FEE2E2' end as status_bg,
      case sol.status when 'active' then '#065F46' else '#991B1B' end as status_fg,
      (select count(*) from public.offer_waitlist w where w.listing_id = sol.id) as waitlist_count
    from public.supplier_offer_listings sol
    join "MEDICINE" m on m.id = sol.product_id
    left join supplier_company sc on sc.supplier_id = sol.supplier_id
    left join supplier_profiles sp on sp.user_id = sol.supplier_id
                                  and coalesce(sp.is_deleted,false) = false
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
$function$
;

-- ============ offer_add_to_cart(p_listing_id bigint, p_qty numeric, p_disclosure_seen boolean) ============
CREATE OR REPLACE FUNCTION public.offer_add_to_cart(p_listing_id bigint, p_qty numeric DEFAULT 1, p_disclosure_seen boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ offer_match_customers(p_listing_id bigint) ============
CREATE OR REPLACE FUNCTION public.offer_match_customers(p_listing_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ offer_push_matched(p_listing_id bigint) ============
CREATE OR REPLACE FUNCTION public.offer_push_matched(p_listing_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ offer_waitlist_join(p_listing_id bigint) ============
CREATE OR REPLACE FUNCTION public.offer_waitlist_join(p_listing_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ offers_feed(p_zone_id smallint, p_offset integer, p_limit integer) ============
CREATE OR REPLACE FUNCTION public.offers_feed(p_zone_id smallint DEFAULT NULL::smallint, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ short_dated_add_to_cart(p_offer_id uuid, p_qty numeric, p_disclosure_seen boolean) ============
CREATE OR REPLACE FUNCTION public.short_dated_add_to_cart(p_offer_id uuid, p_qty numeric, p_disclosure_seen boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o record; v_remaining numeric;
begin
  if get_my_role() not in ('customer','admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select * into o from public.short_dated_offers where id = p_offer_id and status = 'active';
  if not found then return jsonb_build_object('error','offer_not_found'); end if;
  v_remaining := o.available_qty - o.sourced_qty;
  if p_qty > v_remaining then
    return jsonb_build_object('error','qty_exceeds_available','available',v_remaining,
      'message','Only ' || v_remaining::text || ' units available from this batch');
  end if;
  if not coalesce(p_disclosure_seen, false) then
    return jsonb_build_object('error','disclosure_required',
      'message','Customer must acknowledge short-dated terms before adding to cart');
  end if;
  update public.short_dated_offers set sourced_qty = sourced_qty + p_qty where id = p_offer_id;
  return jsonb_build_object('ok', true, 'offer_id', p_offer_id,
    'product_id', o.product_id, 'qty', p_qty, 'discount_pct', o.discount_pct,
    'batch_expiry', to_char(o.batch_expiry,'DD Mon YYYY'), 'disclosure_recorded', true);
end; $function$
;

-- ============ short_dated_config_get() ============
CREATE OR REPLACE FUNCTION public.short_dated_config_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  return jsonb_build_object(
    'ok', true,
    'bands', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'months_max', months_max, 'discount_pct', discount_pct,
        'label', label, 'enabled', enabled, 'sort_order', sort_order
      ) order by months_max), '[]')
      from public.short_dated_config
    )
  );
end; $function$
;

-- ============ short_dated_config_save(p_bands jsonb) ============
CREATE OR REPLACE FUNCTION public.short_dated_config_save(p_bands jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  delete from public.short_dated_config;
  for b in select jsonb_array_elements(p_bands) loop
    insert into public.short_dated_config
      (months_max, discount_pct, label, enabled, sort_order)
    values (
      (b->>'months_max')::int,
      (b->>'discount_pct')::numeric,
      coalesce(b->>'label',''),
      coalesce((b->>'enabled')::boolean, true),
      coalesce((b->>'sort_order')::int, 0)
    );
  end loop;
  return jsonb_build_object('ok', true);
end; $function$
;

-- ============ short_dated_feed(p_zone_id integer) ============
CREATE OR REPLACE FUNCTION public.short_dated_feed(p_zone_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb;
begin
  if get_my_role() not in ('customer','admin','super_admin') then
    return jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'has_offers', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'offer_id',             o.id,
    'product_id',           o.product_id,
    'product_name',         o.product_name,
    'batch_no',             o.batch_no,
    'batch_expiry',         to_char(o.batch_expiry,'DD Mon YYYY'),
    'batch_expiry_raw',     o.batch_expiry,
    'months_to_expiry',     round(
      extract(year  from age(o.batch_expiry, current_date))*12 +
      extract(month from age(o.batch_expiry, current_date)), 1),
    'months_label',         case
      when (extract(year from age(o.batch_expiry,current_date))*12 +
            extract(month from age(o.batch_expiry,current_date))) < 1
        then 'Expires this month'
      when (extract(year from age(o.batch_expiry,current_date))*12 +
            extract(month from age(o.batch_expiry,current_date))) < 3
        then 'Expires in ' || floor(
          extract(year from age(o.batch_expiry,current_date))*12 +
          extract(month from age(o.batch_expiry,current_date)))::text || ' months'
      else 'Expires in ~' || floor(
          extract(year from age(o.batch_expiry,current_date))*12 +
          extract(month from age(o.batch_expiry,current_date)))::text || ' months'
      end,
    'remaining_qty',        o.available_qty - o.sourced_qty,
    'discount_pct',         o.discount_pct,
    'discount_label',       o.discount_pct::text || '% off',
    'bulk_clear_extra_pct', o.bulk_clear_extra_pct,
    'bulk_clear_min_qty',   o.bulk_clear_min_qty,
    'has_bulk_clear',       (o.bulk_clear_extra_pct > 0),
    'expiry_warning',       _expiry_warning(o.batch_expiry),
    'disclosure_title',     'Short-dated stock',
    'disclosure_body',      'This item expires ' || to_char(o.batch_expiry,'DD Mon YYYY') ||
                            '. It is discounted by ' || o.discount_pct::text ||
                            '% because of the limited time to expiry. Please confirm before adding to cart.'
  ) order by o.batch_expiry), '[]')
  into v_rows
  from public.short_dated_offers o
  where o.status = 'active'
    and (o.available_qty - o.sourced_qty) > 0
    and (o.zone_ids is null or p_zone_id = any(o.zone_ids));

  return jsonb_build_object(
    'ok', true,
    'has_offers', (v_rows != '[]'::jsonb),
    'items', v_rows,
    'section_title',    'Short-dated deals',
    'section_subtitle', 'Discounted stock — limited time',
    'disclosure_note',  'These items carry a short expiry and are discounted accordingly.'
  );
end; $function$
;

-- ============ short_dated_offer_confirm(p_id uuid, p_discount_pct numeric, p_bulk_clear_extra_pct numeric, p_bulk_clear_min_qty numeric, p_admin_notes text) ============
CREATE OR REPLACE FUNCTION public.short_dated_offer_confirm(p_id uuid, p_discount_pct numeric DEFAULT NULL::numeric, p_bulk_clear_extra_pct numeric DEFAULT NULL::numeric, p_bulk_clear_min_qty numeric DEFAULT NULL::numeric, p_admin_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor text;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  v_actor := coalesce(auth.jwt()->>'email','admin');
  update public.short_dated_offers set
    status               = 'active',
    discount_pct         = coalesce(p_discount_pct, discount_pct),
    override_discount    = (p_discount_pct is not null),
    bulk_clear_extra_pct = coalesce(p_bulk_clear_extra_pct, bulk_clear_extra_pct),
    bulk_clear_min_qty   = coalesce(p_bulk_clear_min_qty, bulk_clear_min_qty),
    admin_notes          = coalesce(p_admin_notes, admin_notes),
    confirmed_by         = v_actor,
    confirmed_at         = now()
  where id = p_id and status = 'pending_confirm';
  if not found then
    return jsonb_build_object('error','not_found_or_already_processed');
  end if;
  return jsonb_build_object('ok', true);
end; $function$
;

-- ============ short_dated_offer_disable(p_id uuid) ============
CREATE OR REPLACE FUNCTION public.short_dated_offer_disable(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  update public.short_dated_offers set status = 'disabled' where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('ok', true);
end; $function$
;

-- ============ short_dated_offer_edit(p_id uuid, p_available_qty numeric, p_discount_pct numeric, p_bulk_clear_extra_pct numeric, p_bulk_clear_min_qty numeric, p_admin_notes text, p_zone_ids integer[]) ============
CREATE OR REPLACE FUNCTION public.short_dated_offer_edit(p_id uuid, p_available_qty numeric DEFAULT NULL::numeric, p_discount_pct numeric DEFAULT NULL::numeric, p_bulk_clear_extra_pct numeric DEFAULT NULL::numeric, p_bulk_clear_min_qty numeric DEFAULT NULL::numeric, p_admin_notes text DEFAULT NULL::text, p_zone_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  update public.short_dated_offers set
    available_qty        = coalesce(p_available_qty, available_qty),
    discount_pct         = coalesce(p_discount_pct, discount_pct),
    override_discount    = case when p_discount_pct is not null then true else override_discount end,
    bulk_clear_extra_pct = coalesce(p_bulk_clear_extra_pct, bulk_clear_extra_pct),
    bulk_clear_min_qty   = coalesce(p_bulk_clear_min_qty, bulk_clear_min_qty),
    admin_notes          = coalesce(p_admin_notes, admin_notes),
    zone_ids             = coalesce(p_zone_ids, zone_ids)
  where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('ok', true);
end; $function$
;

-- ============ short_dated_offer_list(p_status text, p_limit integer, p_offset integer) ============
CREATE OR REPLACE FUNCTION public.short_dated_offer_list(p_status text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',                   o.id,
    'product_id',           o.product_id,
    'product_name',         o.product_name,
    'supplier_name',        o.supplier_name,
    'batch_no',             o.batch_no,
    'batch_expiry',         to_char(o.batch_expiry,'DD Mon YYYY'),
    'batch_expiry_raw',     o.batch_expiry,
    'months_to_expiry',     round(
      extract(year  from age(o.batch_expiry, current_date))*12 +
      extract(month from age(o.batch_expiry, current_date)), 1),
    'available_qty',        o.available_qty,
    'remaining_qty',        o.available_qty - o.sourced_qty,
    'sourced_qty',          o.sourced_qty,
    'discount_pct',         o.discount_pct,
    'discount_label',       o.discount_pct::text || '% off',
    'override_discount',    o.override_discount,
    'bulk_clear_extra_pct', o.bulk_clear_extra_pct,
    'bulk_clear_min_qty',   o.bulk_clear_min_qty,
    'status',               o.status,
    'wa_push_sent',         o.wa_push_sent,
    'confirmed_by',         o.confirmed_by,
    'confirmed_at',         o.confirmed_at,
    'admin_notes',          o.admin_notes,
    'expiry_warning',       _expiry_warning(o.batch_expiry),
    'created_at',           o.created_at
  ) order by
    case when o.status='pending_confirm' then 0
         when o.status='active' then 1
         else 2 end,
    o.batch_expiry), '[]')
  into v_rows
  from public.short_dated_offers o
  where (p_status is null or o.status = p_status)
  limit p_limit offset p_offset;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $function$
;

-- ============ short_dated_push_wa(p_id uuid) ============
CREATE OR REPLACE FUNCTION public.short_dated_push_wa(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o record; v_res jsonb; n int := 0;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select * into o from public.short_dated_offers where id = p_id and status = 'active';
  if not found then return jsonb_build_object('error','offer_not_active'); end if;

  v_res := public.wa_send_event(
    'short_dated_offer',
    p_tokens := jsonb_build_object(
      'product_name',  o.product_name,
      'discount_pct',  public._num_label(coalesce(o.discount_pct,0)),
      'batch_expiry',  to_char(o.batch_expiry,'DD Mon YYYY'),
      'remaining_qty', greatest(coalesce(o.available_qty,0) - coalesce(o.sourced_qty,0), 0)::text));

  update public.short_dated_offers set wa_push_sent = true where id = p_id;
  return jsonb_build_object('ok', coalesce((v_res->>'ok')::boolean,false), 'result', v_res);
end; $function$
;

-- ============ short_dated_sweep() ============
CREATE OR REPLACE FUNCTION public.short_dated_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expired int; v_exhausted int;
begin
  update public.short_dated_offers
     set status = 'expired'
   where status = 'active' and batch_expiry < (now() at time zone 'Asia/Kolkata')::date;
  get diagnostics v_expired = row_count;
  update public.short_dated_offers
     set status = 'exhausted'
   where status = 'active' and (available_qty - sourced_qty) <= 0;
  get diagnostics v_exhausted = row_count;
  return jsonb_build_object('ok', true, 'expired', v_expired, 'exhausted', v_exhausted);
end; $function$
;

-- ============ supplier_offer_create(p_product_id bigint, p_listing_type text, p_available_qty numeric, p_offer_ptr numeric, p_discount_pct numeric, p_net_price numeric, p_scheme_buy_qty numeric, p_scheme_free_qty numeric, p_batch_expiry_date date, p_min_order_qty numeric, p_end_date date) ============
CREATE OR REPLACE FUNCTION public.supplier_offer_create(p_product_id bigint, p_listing_type text, p_available_qty numeric, p_offer_ptr numeric DEFAULT NULL::numeric, p_discount_pct numeric DEFAULT NULL::numeric, p_net_price numeric DEFAULT NULL::numeric, p_scheme_buy_qty numeric DEFAULT NULL::numeric, p_scheme_free_qty numeric DEFAULT NULL::numeric, p_batch_expiry_date date DEFAULT NULL::date, p_min_order_qty numeric DEFAULT 1, p_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := public.get_my_role(); v_id bigint; v_margin numeric;
begin
  if v_role not in ('supplier','admin','super_admin','service') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if p_listing_type not in ('scheme','near_expiry','discount') then return jsonb_build_object('ok',false,'error','invalid_type'); end if;
  if p_available_qty<=0 then return jsonb_build_object('ok',false,'error','invalid_qty'); end if;
  if p_listing_type='near_expiry' and p_batch_expiry_date is null then return jsonb_build_object('ok',false,'error','expiry_date_required'); end if;
  if p_listing_type='scheme' and (coalesce(p_scheme_buy_qty,0)<=0 or coalesce(p_scheme_free_qty,0)<=0) then return jsonb_build_object('ok',false,'error','scheme_qty_required'); end if;
  select (value->>'marketplace_margin_pct')::numeric into v_margin from app_settings where key='offer_marketplace_config';
  insert into public.supplier_offer_listings(supplier_id,product_id,listing_type,available_qty,
    offer_ptr,discount_pct,net_price,scheme_buy_qty,scheme_free_qty,
    batch_expiry_date,min_order_qty,end_date,margin_pct,status)
  values(auth.uid(),p_product_id,p_listing_type,p_available_qty,
    p_offer_ptr,p_discount_pct,p_net_price,p_scheme_buy_qty,p_scheme_free_qty,
    p_batch_expiry_date,coalesce(p_min_order_qty,1),p_end_date,coalesce(v_margin,5),'active')
  returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end;
$function$
;

-- ============ supplier_offer_update(p_id bigint, p_available_qty numeric, p_offer_ptr numeric, p_discount_pct numeric, p_net_price numeric, p_min_order_qty numeric, p_end_date date, p_status text) ============
CREATE OR REPLACE FUNCTION public.supplier_offer_update(p_id bigint, p_available_qty numeric DEFAULT NULL::numeric, p_offer_ptr numeric DEFAULT NULL::numeric, p_discount_pct numeric DEFAULT NULL::numeric, p_net_price numeric DEFAULT NULL::numeric, p_min_order_qty numeric DEFAULT NULL::numeric, p_end_date date DEFAULT NULL::date, p_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := public.get_my_role(); v_sol public.supplier_offer_listings%rowtype;
begin
  select * into v_sol from public.supplier_offer_listings where id=p_id;
  if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if v_sol.supplier_id!=auth.uid() and v_role not in ('admin','super_admin','service') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if p_status is not null and p_status not in ('active','paused','delisted') then return jsonb_build_object('ok',false,'error','invalid_status'); end if;
  update public.supplier_offer_listings set
    available_qty=coalesce(p_available_qty,available_qty), offer_ptr=coalesce(p_offer_ptr,offer_ptr),
    discount_pct=coalesce(p_discount_pct,discount_pct), net_price=coalesce(p_net_price,net_price),
    min_order_qty=coalesce(p_min_order_qty,min_order_qty), end_date=coalesce(p_end_date,end_date),
    status=coalesce(p_status,status), updated_at=now()
  where id=p_id;
  return jsonb_build_object('ok',true,'id',p_id);
end;
$function$
;

-- ============ supplier_offers_mine(p_status text, p_offset integer, p_limit integer) ============
CREATE OR REPLACE FUNCTION public.supplier_offers_mine(p_status text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

-- ============ trg_cron_wake_offer_expiry() ============
CREATE OR REPLACE FUNCTION public.trg_cron_wake_offer_expiry()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.cron_wake('offer-expiry-cron');
  return null;
end $function$
;


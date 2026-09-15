-- CHANGE for dev-queue #308 — strip every Offers-marketplace branch out of the
-- core purchase flow. Idempotent: every statement is CREATE OR REPLACE.
-- Pre-edit definitions are archived at backup/offers-removal-308/core_functions_before.sql

CREATE OR REPLACE FUNCTION public._place_order_v2_core()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sess jsonb := public.my_session();
  v_cart jsonb;
  v_cust uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_act  uuid := public.my_acting_as();
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_net numeric; v_id uuid; v_code text;
  v_addr text; v_copy jsonb;
  v_checkout   jsonb;
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
     'website',
     -- #293: an admin acting as a customer IS an admin-placed order. It was
     -- hardcoded false, which is the flag the whole payment split keys on.
     (v_act is not null),
     public.next_order_number())
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);

  -- #293 — which of the three placement paths is this, and what happens next.
  v_checkout := public.checkout_action();

  -- Acting-as in gateway mode: the admin cannot pay, so the customer gets the
  -- QR on their own phone. A WhatsApp failure must never fail the order.
  if (v_checkout->>'acting_as')::boolean
     and (v_checkout->>'collection_mode') = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object(
    'ok',              true,
    'id',              coalesce(v_id::text,''),
    'order_code',      coalesce(v_code,''),
    'amount',          v_net,
    'amount_display',  public.inr_money(v_net),
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);
end
$function$;


CREATE OR REPLACE FUNCTION public._cart_unavailable_lines()
 RETURNS TABLE(product_id bigint, product_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      and public.medicine_zone_standby(p.pid, v_zone) <= 0;
end;
$function$;


CREATE OR REPLACE FUNCTION public._oa_release_and_cancel(p_order_id uuid, p_reason text, p_by text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.orders
     set status        = 'cancelled',
         closed_at     = coalesce(closed_at, now()),
         closed_by     = coalesce(closed_by, p_by),
         closed_reason = coalesce(closed_reason, p_reason),
         close_mode    = coalesce(close_mode, 'order_alert')
   where id = p_order_id;
end $function$;


CREATE OR REPLACE FUNCTION public.cart_state(p_guest_uid uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;


CREATE OR REPLACE FUNCTION public.explode_order_items()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.items IS NOT DISTINCT FROM OLD.items) THEN
    RETURN NEW;  -- items unchanged: do NOT delete/recreate order_items
  END IF;

  DELETE FROM order_items WHERE order_id = NEW.id;
  IF NEW.items IS NOT NULL AND jsonb_typeof(NEW.items)='array' THEN
    INSERT INTO order_items (order_id, product_name, product_id, quantity, mrp, price,
                             gst_percent, line_total, pharmacy_name, payment_id, status)
    SELECT NEW.id,
           COALESCE(it->>'product_name', it->>'name'),
           (SELECT id FROM "MEDICINE"
            WHERE product_name = COALESCE(it->>'product_name', it->>'name') LIMIT 1),
           COALESCE((it->>'quantity')::numeric, (it->>'qty')::numeric),
           NULLIF(it->>'mrp','')::numeric, NULLIF(it->>'price','')::numeric,
           NULLIF(it->>'gst_percent','')::numeric, NULLIF(it->>'line_total','')::numeric,
           NEW.pharmacy_name, NEW.payment_id, NEW.status
    FROM jsonb_array_elements(NEW.items) AS it;
  END IF;
  RETURN NEW;
END;
$function$;


CREATE OR REPLACE FUNCTION public.inquiry_broadcast_to_oi()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  perform set_config('medibo.in_broadcast','1',true);

  if public._inq_confirmed(NEW) then
    update public.order_items oi
       set assigned_supplier = NEW.current_supplier,
           inquiry_id        = coalesce(oi.inquiry_id, NEW.id)
     where oi.product_id = NEW.product_id
       and oi.order_date = NEW.batch_date
       and oi.fulfillment_state <> 'cancelled'
       and not coalesce(oi.received_locked,false);
  else
    update public.order_items oi
       set assigned_supplier = null
     where oi.inquiry_id = NEW.id
       and oi.order_date = NEW.batch_date
       and oi.fulfillment_state <> 'cancelled'
       and not coalesce(oi.received_locked,false)
       and coalesce(oi.at_warehouse,false) = false
       and coalesce(oi.packed,false) = false;
  end if;

  perform set_config('medibo.in_broadcast','0',true);
  return NEW;
end;
$function$;


CREATE OR REPLACE FUNCTION public.inquiry_start_batch_for_order(p_order_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
       and oi.fulfillment_state <> 'cancelled';

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
$function$;


CREATE OR REPLACE FUNCTION public.oi_rollup_to_inquiry()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$;


CREATE OR REPLACE FUNCTION public.rebuild_all_supplier_orders(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        AND EXISTS (SELECT 1 FROM inquiry i
                     WHERE i.id = oi.inquiry_id
                       AND public._inq_confirmed(i)
                       AND i.batch_date = oi.order_date
                       AND i.current_supplier = oi.assigned_supplier)
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
$function$;


CREATE OR REPLACE FUNCTION public.storefront_home_v2(p_items integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sections    jsonb := '[]'::jsonb;
  v_ids         bigint[];
  v_see_all     text;
  v_see_fmt     text;
  v_label       text;
  v_search_hint text;
  v_theme       jsonb;
  v_title       text;
  v_accentw     text;
  v_subtitle    text;
  v_n           int;
  v_total       int;
  v_cap         int;
  s             record;
begin
  select public.storefront_theme() into v_theme;
  v_see_all := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_label'), 'See all products');
  v_see_fmt := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_count_label'), '');
  v_search_hint := coalesce((select value from public.storefront_ui_label
                              where key = 'search_hint'), '');

  for s in
    select * from public.storefront_home_section where active order by ord
  loop
    v_n := least(s.item_count, greatest(coalesce(p_items, 100), 1));

    if s.kind = 'feed' then
      select array_agg(product_id order by rank) into v_ids
      from (select product_id, rank from public.storefront_feed
             where lower(category) = lower(s.category)
             order by rank limit v_n) t;
      continue when v_ids is null;

      v_title    := case when s.title <> '' then s.title
                         else initcap(lower(s.category)) end;
      v_accentw  := case when s.accent_word <> '' then s.accent_word
                         else split_part(initcap(lower(s.category)), ' ', 1) end;
      v_subtitle := case when s.subtitle <> '' then s.subtitle
                         else 'TOP PICKS IN ' || s.category end;

      v_total := public.get_storefront_count(s.category);
      v_cap   := case when s.max_items > 0 then least(v_total, s.max_items)
                      else v_total end;
      v_label := case when v_see_fmt <> ''
                      then replace(v_see_fmt, '{n}', to_char(v_total, 'FM999,999'))
                      else v_see_all end;

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title', v_title, 'accent_word', v_accentw, 'subtitle', v_subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', v_label,
        'see_all', jsonb_build_object('type','category','key', s.category),
        'infinite', s.infinite,
        'next_offset', coalesce(array_length(v_ids, 1), 0),
        'page_size', s.page_size,
        'total', v_cap,
        'items', public._sf_cards(v_ids));

    elsif s.kind = 'icon_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'icon_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', initcap(lower(fm.category)),
            'count_label', to_char(fm.total,'FM999,999') || ' products',
            'key', fm.category) order by fm.total desc), '[]'::jsonb)
          from (select category, total from public.storefront_feed_meta
                 where category <> 'All' and total > 0
                 order by total desc limit s.item_count) fm));

    elsif s.kind = 'brand_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'brand_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', mc.display,
            'count_label', to_char(mc.buyable_count,'FM999,999') || ' products',
            'key', mc.canon) order by mc.buyable_count desc), '[]'::jsonb)
          from (select display, canon, buyable_count from public.medicine_company
                 where buyable_count > 0 order by buyable_count desc
                 limit s.item_count) mc));

    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'generated_for', 'home',
    'theme', v_theme,
    'header', jsonb_build_object(
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'fg',        '#FFFFFF',
      'accent',    v_theme->>'accent',
      'search_hint', v_search_hint),
    'hero', jsonb_build_object(
      'show',    true,
      'eyebrow', coalesce((select value from public.storefront_ui_label where key = 'hero_eyebrow'), ''),
      'title',   coalesce((select value from public.storefront_ui_label where key = 'hero_title'), ''),
      'cta',     coalesce((select value from public.storefront_ui_label where key = 'hero_cta'), ''),
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'accent',    v_theme->>'accent',
      'props', jsonb_build_array(
        jsonb_build_object('icon','inventory','label',
          to_char(public.storefront_viewer_count(),'FM9,99,99,999') || '+ products'),
        jsonb_build_object('icon','truck','label',coalesce((select value from public.storefront_ui_label where key='delivery_time'),'Same-day delivery')),
        jsonb_build_object('icon','verified','label','Licensed distributors'))),
    'sections', v_sections);
end
$function$;

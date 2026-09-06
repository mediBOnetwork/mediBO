-- CMD #1848 (b) — the customer's OWN order readers honour the shadow tenant.
--
-- The live proof for spec item 8 found the gap: an order stamped with a test
-- session was still printed on test.cust1's ordinary Orders tab with NO
-- session header, because my_orders_screen_v2 / customer_order_detail /
-- my_orders_screen / customer_track_order are SECURITY DEFINER (postgres,
-- BYPASSRLS) and were not among the definer lists 5d of
-- 20260907020000_c1848_test_session_per_user.sql patched. Same rule, same
-- ONE helper (test_row_visible): an ordinary row is unchanged for everyone,
-- a session-stamped row exists only for the request carrying that session.
-- No session => test_row_visible() is true for every ordinary row, so the
-- real path returns exactly what it returned before. Idempotent (CREATE OR
-- REPLACE, bodies otherwise verbatim from live as of CHANGE #1224).

CREATE OR REPLACE FUNCTION public.my_orders_screen_v2(p_filter text DEFAULT NULL::text, p_query text DEFAULT NULL::text, p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust  uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_copy  jsonb := coalesce((select value from app_settings where key='orders_screen_copy'), '{}'::jsonb);
  v_f     text  := lower(coalesce(nullif(btrim(coalesce(p_filter,'')),''), 'active'));
  v_q     text  := nullif(btrim(coalesce(p_query,'')), '');
  v_rows  jsonb;
  v_counts jsonb;
  v_title text; v_note text;
begin
  if v_f not in ('active','delivered','cancelled') then v_f := 'active'; end if;

  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;

  with mine as (
    select o.id, o.created_at,
           public._order_customer_stage(o.id) as st
      from public.orders o
     where v_cust is not null and o.customer_id = v_cust
       and public.test_row_visible(o.is_synthetic, o.test_session_id)   -- CMD #1848 (b): the shadow tenant, in the definer reader too
  ),
  bucketed as (
    select id, created_at,
           case when (st->>'is_cancelled')::boolean then 'cancelled'
                when (st->>'is_delivered')::boolean then 'delivered'
                else 'active' end as bucket
      from mine
  ),
  matched as (
    select b.* from bucketed b
     where v_q is null
        or exists (select 1 from public.orders o
                    where o.id = b.id and o.order_code ilike '%'||v_q||'%')
        or exists (select 1 from public.order_items oi
                    where oi.order_id = b.id and oi.product_name ilike '%'||v_q||'%')
  )
  select
    coalesce((select jsonb_agg(public._order_customer_card(m.id) order by m.created_at desc)
                from matched m where m.bucket = v_f), '[]'::jsonb),
    jsonb_build_object(
      'active',    (select count(*) from matched where bucket='active'),
      'delivered', (select count(*) from matched where bucket='delivered'),
      'cancelled', (select count(*) from matched where bucket='cancelled'))
  into v_rows, v_counts;

  if v_cust is null and v_admin then
    v_title := coalesce(nullif(v_copy->>'admin_title',''), 'Admin account');
    v_note  := coalesce(nullif(v_copy->>'admin_note',''),
                 'This login is an admin, not a pharmacy. Customer orders live in the admin Orders tab.');
  elsif v_q is not null then
    v_title := public._c('orders.empty_search');
    v_note  := public._c('orders.empty_note');
  else
    v_title := public._c('orders.empty_' || v_f);
    v_note  := coalesce(nullif(public._c('orders.empty_note'),''),
                        coalesce(nullif(v_copy->>'empty_note',''), ''));
  end if;

  return jsonb_build_object(
    'ok', true,
    'filter', v_f,
    'filters', jsonb_build_array(
      jsonb_build_object('key','active',    'label', public._c('orders.filter_active'),
                         'count', (v_counts->>'active')::int,    'selected', v_f='active'),
      jsonb_build_object('key','delivered', 'label', public._c('orders.filter_delivered'),
                         'count', (v_counts->>'delivered')::int, 'selected', v_f='delivered'),
      jsonb_build_object('key','cancelled', 'label', public._c('orders.filter_cancelled'),
                         'count', (v_counts->>'cancelled')::int, 'selected', v_f='cancelled')),
    'search', jsonb_build_object('hint', public._c('orders.search_hint'), 'query', coalesce(v_q,'')),
    'orders', v_rows,
    'count',  jsonb_array_length(v_rows),
    'has_orders', (jsonb_array_length(v_rows) > 0),
    'is_admin_session', v_admin,
    'no_customer_account', (v_cust is null),
    'empty_title', v_title,
    'empty_note',  v_note,
    'customer_id', coalesce(v_cust::text,''));
end $function$;

CREATE OR REPLACE FUNCTION public.customer_order_detail(p_order_id uuid, p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype;
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_gate jsonb; v_actions jsonb := '[]'::jsonb; v_open_tickets int;
begin
  select * into o from public.orders
   where id = p_order_id
     and public.test_row_visible(is_synthetic, test_session_id);   -- CMD #1848 (b): the shadow tenant, in the definer reader too
  if o.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('order_change.reason_not_found'));
  end if;

  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;
  if not (o.customer_id is not distinct from v_cust or v_admin) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._c('order_change.reason_not_authorized'));
  end if;

  v_gate := public._order_change_gate(p_order_id);

  -- The two doors. Present ONLY while the window is open; there is no
  -- disabled state to tap and be refused by.
  if coalesce((v_gate->>'can_edit')::boolean,false) then
    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
      'key','edit', 'label', coalesce(v_gate->>'edit_label', public.ui_text('order_edit.button')),
      'tone','outline', 'enabled', true, 'badge', '', 'note', ''));
  end if;
  if coalesce((v_gate->>'can_cancel')::boolean,false) then
    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
      'key','cancel', 'label', coalesce(v_gate->>'cancel_label', public._c('cancel.cust_action_label')),
      'tone','danger', 'enabled', true, 'badge', '', 'note', ''));
  end if;

  -- Everything else the buyer may do on this order (returns #131, help #132)
  -- still comes from _order_customer_actions. Cancel is DROPPED from that list
  -- here: the gate above owns that door now, and two sources for one button is
  -- exactly the disagreement Part B collapses.
  v_actions := v_actions || coalesce((
    select jsonb_agg(a order by ord)
      from (select a, ordinality as ord
              from jsonb_array_elements(
                     coalesce(public._order_customer_actions(p_order_id), '[]'::jsonb))
                   with ordinality as t(a, ordinality)
             where coalesce(a->>'key','') <> 'cancel') q), '[]'::jsonb);

  select count(*) into v_open_tickets from public.support_ticket
   where order_id = p_order_id and status <> 'closed';

  return jsonb_build_object(
    'ok',    true,
    'title', public._c('orders.detail_title'),
    'order', public._order_customer_row(p_order_id),
    'card',  public._order_customer_card(p_order_id),
    'stage', public._order_customer_stage(p_order_id),
    'tabs',  jsonb_build_array(
       jsonb_build_object('key','items',   'label', public._c('orders.tab_items')),
       jsonb_build_object('key','payment', 'label', public._c('orders.tab_payment')),
       jsonb_build_object('key','bill',    'label', public._c('orders.tab_bill')),
       jsonb_build_object('key','help',    'label', public._c('orders.tab_help'))),
    'change_window', v_gate,
    'actions', v_actions,
    'window_note', case when coalesce((v_gate->>'open')::boolean,false)
                        then '' else coalesce(v_gate->>'reason','') end,
    -- CHANGE #691 (gap 126)
    'proof', public._delivery_proof_block(p_order_id),
    'eta',   public._delivery_eta_for_order(p_order_id),
    'help', jsonb_build_object(
       'title', public._c('orders.help_title'),
       'open_count', coalesce(v_open_tickets,0),
       'label', public._c('support.order_action_label')));
end $function$;

CREATE OR REPLACE FUNCTION public.my_orders_screen(p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_cfg  jsonb := coalesce((select value from app_settings where key='order_status_config'), '{}'::jsonb);
  v_copy jsonb := coalesce((select value from app_settings where key='orders_screen_copy'), '{}'::jsonb);
  v_unf  jsonb := coalesce((select value from app_settings where key='unfulfilled_copy'), '{}'::jsonb);
  v_tone jsonb := coalesce((select value from app_settings where key='item_status_tones'),
                    '{"green":{"bg":"#E1F5EE","fg":"#0F6E56"},
                      "yellow":{"bg":"#FEF3C7","fg":"#92400E"},
                      "red":{"bg":"#FBE9E7","fg":"#B42318"}}'::jsonb);
  v_rows jsonb; v_title text; v_note text;
begin
  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;

  select coalesce(jsonb_agg(o order by o->>'placed_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'id',                coalesce(ord.id::text,''),
      'order_code',        coalesce(ord.order_code,''),
      'placed_at',         coalesce(ord.created_at::text,''),
      'placed_at_label',   public._ist_stamp(ord.created_at),
      'status',            coalesce(ord.status,'pending'),
      -- CMD #1848 — a stamped order says so on the buyer's own list.
      'test_badge',        case when coalesce(ord.is_synthetic,false) then public.uic('test_mode.badge','TEST') else '' end,
      'status_label',      coalesce(nullif(v_cfg->lower(coalesce(ord.status,'pending'))->>'label',''),
                                    initcap(coalesce(ord.status,'pending'))),
      'status_color',      coalesce(v_cfg->lower(coalesce(ord.status,'pending'))->>'color',
                                    v_cfg->'_default'->>'color', '#F59E0B'),
      'total',             coalesce(ord.total_amount,0),
      'total_display',     public.inr_money(coalesce(ord.total_amount,0)),
      'placed_by_admin',   coalesce(ord.placed_by_admin,false),
      'unique_item_count', coalesce(g.n_ok,0),
      'unit_count',        coalesce(g.units_ok,0),
      'total_item_count',  coalesce(g.n_ok,0) + coalesce(g.n_bad,0),
      'lines',             coalesce(g.ok_lines, '[]'::jsonb),
      'has_unfulfilled',   (coalesce(g.n_bad,0) > 0),
      'unfulfilled_count', coalesce(g.n_bad,0),
      'unfulfilled_title', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items'),
      'unfulfilled_note',  coalesce(nullif(v_unf->>'note',''),''),
      'unfulfilled_label', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items')
                             || ' (' || coalesce(g.n_bad,0)::text || ')',
      'unfulfilled_collapsed', true,
      'unfulfilled_lines', coalesce(g.bad_lines, '[]'::jsonb),
      -- CHANGE #408 — the edit window travels WITH the order.
      'edit',              public._order_edit_gate(ord.id),
      -- CMD #452 — and so does every other door a buyer has on this order:
      -- track (#133), cancel (#130), returns (#131), help (#132). The card
      -- renders this list in payload order and decides nothing.
      'actions',           public._order_customer_actions(ord.id)
    ) as o
    from orders ord
    left join lateral (
      select
        count(*) filter (where d.unfulfillable = false)                       as n_ok,
        count(*) filter (where d.unfulfillable)                               as n_bad,
        coalesce(sum(d.qty) filter (where d.unfulfillable = false),0)::int     as units_ok,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'batch_block', public._order_product_batch_block(ord.id, d.product_id),
            'status_label', d.status_text,
            'status_tone',  d.status_tone,
            'status_ok',    (d.status_text = 'Available'),
            'status_text', d.status_text,
            'status_colors', coalesce(v_tone->d.status_tone, v_tone->'yellow'))
          order by d.product_name) filter (where d.unfulfillable = false)      as ok_lines,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'batch_block', public._order_product_batch_block(ord.id, d.product_id),
            'status_label', coalesce(d.reason, d.status_text),
            'status_tone',  'red',
            'status_ok',    false,
            'status_text', coalesce(d.reason, d.status_text),
            'status_colors', coalesce(v_unf->'chip_colors', v_tone->'red'))
          order by d.product_name) filter (where d.unfulfillable)              as bad_lines
      from (
        select oi.product_id,
               max(oi.product_name)                       as product_name,
               sum(coalesce(oi.quantity,0))               as qty,
               max(coalesce(oi.price, oi.mrp, 0))         as unit_price,
               sum(coalesce(oi.line_total,
                     coalesce(oi.quantity,0) * coalesce(oi.price, oi.mrp, 0))) as line_total,
               bool_or(oi.unfulfillable)                  as unfulfillable,
               max(oi.unfulfillable_reason)               as reason,
               coalesce(max(inq.current_status), 'Confirmation Pending') as status_text,
               case coalesce(max(inq.current_status), 'Confirmation Pending')
                 when 'Available'            then 'green'
                 when 'No Supplier Available' then 'red'
                 else 'yellow' end                        as status_tone,
               max(nullif(btrim(m.image_url_1),''))       as image_url,
               max(upper(nullif(btrim(m.marketer),'')))   as company,
               max(nullif(btrim(regexp_replace(coalesce(m.pack_qty,''),'(\d)\.0(\D)','\1\2','g')),'')) as pack_label,
               trim_scale(sum(coalesce(oi.quantity,0)))::text || ' ' ||
                 case when max(m.pack_type) is null
                        then case when sum(coalesce(oi.quantity,0)) > 1 then 'Units' else 'Unit' end
                      when sum(coalesce(oi.quantity,0)) > 1 and lower(max(m.pack_type)) ~ '(s|x|z|ch|sh)$'
                        then max(m.pack_type) || 'es'
                      when sum(coalesce(oi.quantity,0)) > 1 then max(m.pack_type) || 's'
                      else max(m.pack_type) end           as qty_label
        from order_items oi
        left join "MEDICINE" m on m.id = oi.product_id
        left join lateral (
          select q.current_status from inquiry q
           where q.product_id = oi.product_id
             and (q.zone_id is null or coalesce(oi.zone_id, ord.zone_id) is null
                  or q.zone_id = coalesce(oi.zone_id, ord.zone_id))
           order by (q.batch_date = (ord.created_at at time zone 'Asia/Kolkata')::date) desc nulls last,
                    q.batch_date desc nulls last, q.id desc limit 1) inq on true
        where oi.order_id = ord.id
        group by oi.product_id
      ) d
    ) g on true
    where v_cust is not null and ord.customer_id = v_cust
      and public.test_row_visible(ord.is_synthetic, ord.test_session_id)   -- CMD #1848 (b): the shadow tenant, in the definer reader too
    order by ord.created_at desc
  ) s;

  if v_cust is null and v_admin then
    v_title := 'Admin account';
    v_note  := 'This login is an admin, not a pharmacy. Customer orders live in the admin Orders tab.';
  else
    v_title := coalesce(nullif(v_copy->>'empty_title',''), 'No purchase orders yet');
    v_note  := coalesce(nullif(v_copy->>'empty_note',''),  'Placed orders will appear here.');
  end if;

  return jsonb_build_object(
    'orders',      v_rows,
    'count',       jsonb_array_length(v_rows),
    'has_orders',  (jsonb_array_length(v_rows) > 0),
    'is_admin_session', v_admin,
    'no_customer_account', (v_cust is null),
    'empty_title', v_title,
    'empty_note',  v_note,
    'customer_id', coalesce(v_cust::text,''));
end $function$;

CREATE OR REPLACE FUNCTION public.customer_track_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
        v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb; v_is_buyer boolean;
        -- CMD #1840 — the map contract, the trust line and the rider card.
        v_map jsonb; v_trust jsonb; v_rider_card jsonb;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid()
                    and public.test_row_visible(o.is_synthetic, o.test_session_id))
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
      -- CHANGE #704: the agency holding the stop can read its own tracking too.
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations ap on ap.id = dd.agency_id
                 where dd.order_id = p_order_id and ap.user_id = auth.uid())
    ) into v_allowed;
  if not coalesce(v_allowed,false) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_tl := public.order_timeline(p_order_id);

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null then
    return jsonb_build_object('ok',true,'tracking',false,'status','preparing',
      'status_label','Preparing your order', 'timeline', v_tl,
      'has_channel', false,
      'eta', public._delivery_eta_for_order(p_order_id),
      'proof', jsonb_build_object('has', false, 'heading', public._c('delivery.proof_heading')),
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
      -- CMD #1840 — nothing to track yet: the map contract still travels (the
      -- card renders no map because tracking is false), the trust line says
      -- 'done' so no subscription is opened, and there is no rider to card.
      'map', public._c1840_map_block('preparing'),
      'trust', public._c1840_trust_block(null, 'preparing', '{}'::jsonb),
      'rider_card', jsonb_build_object('has', false),
      'live', public._delivery_live_block(null));
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(live_animate_ms, 1200) into v_animate from delivery_config where id = 1;

  select snap_lat, snap_lng, snapped, speed_kmh into v_last
    from delivery_run_trail where run_id = d.run_id order by ts desc limit 1;
  v_snapped := coalesce(v_last.snapped,false)
               and v_last.snap_lat is not null and v_last.snap_lng is not null;

  -- CHANGE #691: the stop count and the arrival window now come from ONE block,
  -- so the tracker, the public page and the Orders card cannot disagree.
  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(p_order_id);
  -- CHANGE #703: the doorbell and the cold box. Both are whole payloads —
  -- the tracker prints them and decides nothing, not even whether the QR shows.
  -- CHANGE #703 / #354: this RPC admits the RIDER as well as the buyer, and
  -- the handover OTP is the one thing the rider must never be handed. Who is
  -- asking is decided here, once, and the block obeys it.
  select (public._is_admin()
          or exists (select 1 from orders o2 join pharmacy_profiles pp2 on pp2.id = o2.customer_id
                      where o2.id = p_order_id and pp2.user_id = auth.uid()
                        and public.test_row_visible(o2.is_synthetic, o2.test_session_id)))
    into v_is_buyer;
  v_arrival := public._c703_arrival_block(d.id, coalesce(v_is_buyer,false));
  v_cold    := public._c703_cold_block(d.id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CHANGE #462 (gap 104)
  -- CHANGE #703: the approach ring is what opens the handover, so the buyer has
  -- the three minutes the alert promised them rather than three seconds at the
  -- door. Arrival still opens it for a rider who appeared inside 50 m.
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or d.approach_notified_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  -- The staleness sentence is only meaningful while a rider is supposed to be
  -- moving. On a delivered or failed stop the map is history, not a live feed,
  -- so no "Rider offline" is ever shown for an order that already arrived.
  v_live := case when d.status in ('assigned','out_for_delivery')
                 then public._delivery_live_block(v_loc.updated_at)
                 else public._delivery_live_block(null) end;

  -- CMD #1840 — the three blocks the live map is made of. Every height, word,
  -- tone and threshold in them is decided here; the app renders them.
  v_map        := public._c1840_map_block(d.status);
  v_trust      := public._c1840_trust_block(v_loc.updated_at, d.status, v_arrival);
  v_rider_card := public._c1840_rider_card(d.id, v_eta);

  return jsonb_build_object(
    'ok', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', d.status,
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        -- CHANGE #704: before the agency names a rider there IS no rider to
        -- show, and the buyer is told exactly that rather than nothing.
        when 'agency_pending' then public._c('agency.track_pending')
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    'assigned_to', jsonb_build_object(
        'has',  (d.agency_id is not null or d.partner_id is not null),
        'kind', case when d.partner_id is not null then 'rider'
                     when d.agency_id is not null then 'agency' else 'none' end,
        'name', case when d.partner_id is not null then coalesce(v_name,'')
                     else coalesce((select ag.full_name
                                      from delivery_partner_registrations ag
                                     where ag.id = d.agency_id), '') end,
        'label', case when d.partner_id is not null then coalesce(v_name,'')
                      when d.agency_id is not null then public._c('agency.track_pending')
                      else '' end),
    -- CHANGE #463 (register row 117's deferred half, unblocked by row 121):
    -- the rider's verified face, for the buyer at whose door they are standing.
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    -- CHANGE #691 (gap 122 / 126)
    'eta',   v_eta,
    'proof', v_proof,
    -- CHANGE #703 (spec 1, 3 and 4)
    'arrival', v_arrival,
    'cold_chain', v_cold,
    'stops_ahead', v_ahead,
    'stops_ahead_label', nullif(v_eta->>'stops_ahead_label',''),
    'rider_lat', case when d.status in ('assigned','out_for_delivery') then v_loc.lat end,
    'rider_lng', case when d.status in ('assigned','out_for_delivery') then v_loc.lng end,
    -- CHANGE #700: the road-snapped twin, and the one pair a map should plot.
    'rider_snap_lat', case when d.status in ('assigned','out_for_delivery') and v_snapped
                           then v_last.snap_lat end,
    'rider_snap_lng', case when d.status in ('assigned','out_for_delivery') and v_snapped
                           then v_last.snap_lng end,
    'rider_snapped', (d.status in ('assigned','out_for_delivery')) and v_snapped,
    'map_lat', case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lat else v_loc.lat end end,
    'map_lng', case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lng else v_loc.lng end end,
    'speed_kmh', case when d.status in ('assigned','out_for_delivery') then v_last.speed_kmh end,
    'animate_ms', coalesce(v_animate, 1200),
    'note', case when d.status in ('assigned','out_for_delivery') and not v_snapped
                 then public._c('delivery.live_raw_note') else '' end,
    'live', v_live,
    -- CHANGE #700: the run-scoped broadcast this customer may listen to. The
    -- old view subscribed to postgres_changes on a table that is not in the
    -- publication, so it never received one event.
    'has_channel', (d.run_id is not null and d.status in ('assigned','out_for_delivery')),
    'channel', case when d.run_id is not null and d.status in ('assigned','out_for_delivery')
                    then 'run:' || d.run_id::text end,
    'location_updated_at', v_loc.updated_at,
    'destination_lat', d.lat, 'destination_lng', d.lng,
    'rider_arrived', (d.arrived_at is not null),
    'qr_token', case when v_show_qr then d.qr_token end,
    'delivered_at', d.delivered_at, 'proof_method', d.proof_method,
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    -- CHANGE #701 — the route to THIS door and nothing else: the segment from
    -- where the rider is to this stop, the road distance along it, and the
    -- stops in front named by postal area only. The rest of the run passes
    -- other pharmacies' doors and is cut in _c701_route_segment.
    'route', public._c701_route_block(d.id),
    -- CHANGE #701 — "share live link with staff". The BACKEND decides who is
    -- offered it (a live stop with a token), so the public /track page — which
    -- has no identity to authorise a send — simply never receives the block.
    'share', jsonb_build_object(
      'has',   (d.status in ('assigned','out_for_delivery')
                and coalesce(d.track_token,'') <> ''),
      'label', public._c('delivery.share_staff'),
      'rpc',   'delivery_share_track_link',
      'order_id', d.order_id::text),
    'track_token', case when d.status in ('assigned','out_for_delivery')
                        then d.track_token end,
    -- CMD #1840 — the persistent map's contract, the trustworthy pin and the
    -- rider + vehicle card, in the same payload the sheet already reads.
    'map', v_map,
    'trust', v_trust,
    'rider_card', v_rider_card,
    'timeline', v_tl);
end $function$;

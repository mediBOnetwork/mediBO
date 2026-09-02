-- CHANGE #630 — the Orders tab is ORDERS, and there is ONE change window.
--
-- PART A. The tab had become a drawer: a reorder banner, a Purchases tile, a
-- Saved-lists tile, a help box on every card and a five-chip row that ran off
-- the right edge of a 360 px phone. None of those are orders. They move to the
-- pharmacy's own surface (#536's My Shop, which is registry DATA), and what is
-- left is a list of orders with one truth per card and one thing to tap.
--
-- PART B. Om's rule: a customer may edit or cancel ONLY while the order has not
-- entered sourcing. Until now there were TWO gates that disagreed —
-- _order_edit_gate closed at the first inquiry (#408), while
-- _order_customer_cancel_gate never looked at the inquiry at all and happily
-- allowed a cancel through fulfillment_status='collecting', i.e. after the
-- waterfall had already asked suppliers. This collapses both onto ONE
-- implementation, _order_change_gate, and adds the second closer Om asked for:
-- order hours. When the window is shut the ACTION IS ABSENT, not disabled —
-- a greyed-out button that errors on tap is the thing being removed.
--
-- Idempotent throughout: re-applying is a no-op.

-- ── 1. Copy ────────────────────────────────────────────────────────────────
insert into ui_copy (key, value) values
  ('order_change.reason_not_found',       '"That order could not be found."'::jsonb),
  ('order_change.reason_not_authorized',  '"This order belongs to another account."'::jsonb),
  ('order_change.reason_closed',          '"This order is closed — contact support to change it."'::jsonb),
  ('order_change.reason_inquiry_started', '"Sourcing has started — contact support to change this order"'::jsonb),
  ('order_change.reason_dispatched',      '"This order is out for delivery — contact support to change it."'::jsonb),
  ('order_change.reason_hours_closed',    '"Order hours are closed — you can change this order when they reopen."'::jsonb),
  ('order_change.window_open',            '"You can still edit or cancel this order."'::jsonb),

  ('orders.filter_active',        '"Active"'::jsonb),
  ('orders.filter_delivered',     '"Delivered"'::jsonb),
  ('orders.filter_cancelled',     '"Cancelled"'::jsonb),
  ('orders.search_hint',          '"Search order code or medicine"'::jsonb),
  ('orders.not_billed',           '"Not billed"'::jsonb),
  ('orders.rate_on_confirmation', '"Rate on confirmation"'::jsonb),
  ('orders.item_count_one',       '"{n} item"'::jsonb),
  ('orders.item_count_many',      '"{n} items"'::jsonb),

  ('orders.stage_confirmed',        '"Confirmed · lining up suppliers"'::jsonb),
  ('orders.stage_sourcing',         '"Sourcing · asking suppliers now"'::jsonb),
  ('orders.stage_packed',           '"Packed · out for delivery today"'::jsonb),
  ('orders.stage_out_for_delivery', '"Out for delivery · on its way to you"'::jsonb),
  ('orders.stage_delivered',        '"Delivered"'::jsonb),
  ('orders.stage_cancelled',        '"Cancelled"'::jsonb),

  ('orders.step_confirmed',        '"Confirmed"'::jsonb),
  ('orders.step_sourcing',         '"Sourcing"'::jsonb),
  ('orders.step_packed',           '"Packed"'::jsonb),
  ('orders.step_out_for_delivery', '"Out for delivery"'::jsonb),

  ('orders.action_track',   '"Track"'::jsonb),
  ('orders.action_pay',     '"Pay"'::jsonb),
  ('orders.action_reorder', '"Reorder"'::jsonb),
  -- Om, live on #630: a Pending order that has not entered sourcing has
  -- nothing to track yet — the one useful thing to offer is the change
  -- window itself. Which action a status gets is DATA (see section 9), so
  -- swapping this back to Track is an UPDATE, never a deploy.
  ('orders.action_edit',    '"Edit order"'::jsonb),

  ('orders.empty_active',    '"No active orders"'::jsonb),
  ('orders.empty_delivered', '"No delivered orders yet"'::jsonb),
  ('orders.empty_cancelled', '"No cancelled orders"'::jsonb),
  ('orders.empty_search',    '"Nothing matched that search"'::jsonb),
  ('orders.empty_note',      '"Placed orders appear here."'::jsonb),

  ('orders.tab_help',        '"Help"'::jsonb),
  ('orders.detail_title',    '"Order"'::jsonb),
  ('orders.help_title',      '"Need help with this order?"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 2. THE ONE GATE ────────────────────────────────────────────────────────
-- Both doors, one decision, in Om's order: authorship, then closure, then
-- SOURCING (the moment the inquiry is asked), then physical movement, then
-- dispatch, then order hours. Everything a caller needs to render is in the
-- payload; nothing is left for Dart to work out.
create or replace function public._order_change_gate(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  o        public.orders%rowtype;
  v_cid    uuid    := public.my_customer_id();
  v_admin  boolean := coalesce(public.get_my_role() in ('admin','super_admin'), false);
  v_code   text;
  v_asked  boolean;
  v_moved  boolean;
  v_disp   boolean;
  v_open   boolean;
  v_reason text;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then
    v_code := 'not_found';
  elsif not (o.customer_id is not distinct from v_cid or v_admin) then
    v_code := 'not_authorized';
  elsif o.closed_at is not null
     or lower(coalesce(o.status,'')) in ('cancelled','canceled','rejected','delivered','completed')
     or exists (select 1 from public.order_cancellations where order_id = p_order_id) then
    v_code := 'closed';
  end if;

  -- Om's rule. The window closes the moment the waterfall asks its first
  -- supplier for this order — asked_at, or a supplier order already cut.
  -- fulfillment_status leaving 'open' means the same thing by another route.
  if v_code is null then
    select exists (
      select 1
        from public.order_items oi
        left join lateral (
          select q.* from public.inquiry q
           where q.id = oi.inquiry_id
              or (oi.inquiry_id is null
                  and q.product_id = oi.product_id
                  and q.batch_date = coalesce(oi.order_date, o.order_date)
                  and (q.zone_id is not distinct from coalesce(oi.zone_id, o.zone_id)
                       or q.zone_id is null))
           order by (q.id = oi.inquiry_id) desc, q.id desc
           limit 1) i on true
       where oi.order_id = p_order_id
         and (i.asked_at is not null or i.supplier_order_id is not null)
    ) into v_asked;
    if v_asked or coalesce(o.fulfillment_status,'open') <> 'open' then
      v_code := 'inquiry_started';
    end if;
  end if;

  -- Physical fulfilment having started. NOT bag_no: that is stamped at
  -- placement by assign_order_bag_no() and means nothing has happened yet.
  if v_code is null then
    select exists (
      select 1 from public.order_items oi
       where oi.order_id = p_order_id
         and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
              or coalesce(oi.received_qty,0) > 0
              or coalesce(oi.at_warehouse,false)
              or coalesce(oi.packed,false)
              or oi.shop_qty is not null
              or oi.assigned_supplier is not null)
    ) into v_moved;
    if v_moved then v_code := 'inquiry_started'; end if;
  end if;

  if v_code is null then
    select exists (select 1 from public.deliveries d
                    where d.order_id = p_order_id
                      and coalesce(d.status,'') in ('assigned','out_for_delivery','delivered'))
      into v_disp;
    if coalesce(o.dispatch_ready,false) or coalesce(v_disp,false) then
      v_code := 'dispatched';
    end if;
  end if;

  -- The second closer Om asked for: order hours. A shut counter is a shut
  -- counter for changes as well as for new orders.
  if v_code is null then
    v_open := coalesce((public.order_hours_state(o.zone_id)->>'is_open')::boolean, true);
    if not v_open then v_code := 'hours_closed'; end if;
  end if;

  if v_code is not null then
    v_reason := public._c('order_change.reason_' || v_code);
    return jsonb_build_object(
      'ok',          (v_code not in ('not_found','not_authorized')),
      'open',        false,
      'show',        false,
      'can_edit',    false,
      'can_cancel',  false,
      'reason_code', v_code,
      'reason',      v_reason,
      'message',     v_reason,
      'note',        v_reason);
  end if;

  return jsonb_build_object(
    'ok',           true,
    'open',         true,
    'show',         true,
    'can_edit',     true,
    'can_cancel',   true,
    'reason_code',  'open',
    'reason',       '',
    'message',      '',
    'note',         public._c('order_change.window_open'),
    'edit_label',   public.ui_text('order_edit.button'),
    'cancel_label', public._c('cancel.cust_action_label'),
    'window_label', public._c('order_change.window_open'));
end $fn$;

revoke all on function public._order_change_gate(uuid) from public;
grant execute on function public._order_change_gate(uuid) to authenticated, service_role;

-- ── 3. The two old gates become thin adapters over the one gate ────────────
-- Their payload SHAPES are unchanged (order_edit_state, my_order_cancel,
-- my_order_cancel_sheet and _order_customer_actions all keep reading exactly
-- the keys they read before); only the DECISION moved.
create or replace function public._order_edit_gate(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare g jsonb; v_code text;
begin
  g := public._order_change_gate(p_order_id);
  if coalesce((g->>'can_edit')::boolean,false) then
    return jsonb_build_object(
      'can_edit', true,
      'button_label', public.ui_text('order_edit.button'),
      'window_label', coalesce(nullif(g->>'window_label',''),
                               public.ui_text('order_edit.window_open')));
  end if;
  v_code := g->>'reason_code';
  return jsonb_build_object(
    'can_edit', false,
    -- 'not_pending' / 'closed' / 'inquiry_started' / 'not_found' /
    -- 'not_authorized' are the codes #408's callers already switch on;
    -- 'dispatched' and 'hours_closed' are new and carry their own reason.
    'error',   v_code,
    'reason',  coalesce(g->>'reason',''),
    'message', coalesce(g->>'message',''));
end $fn$;

create or replace function public._order_customer_cancel_gate(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare g jsonb;
begin
  g := public._order_change_gate(p_order_id);
  if not coalesce((g->>'can_cancel')::boolean,false) then
    -- CHANGE #630 — `show:false`. The action is ABSENT once the window shuts;
    -- it is no longer rendered disabled so it can refuse the tap. The sentence
    -- lives in the order detail instead.
    return jsonb_build_object(
      'show', false, 'can_cancel', false,
      'reason', coalesce(g->>'reason_code',''),
      'note',   coalesce(g->>'reason',''));
  end if;
  return jsonb_build_object(
    'show', true, 'can_cancel', true, 'reason', 'open',
    'label',        public._c('cancel.cust_action_label'),
    'note',         public._c('cancel.cust_window_open'),
    'title',        public._c('cancel.cust_sheet_title'),
    'body',         public._c('cancel.cust_sheet_body'),
    'reason_label', public._c('cancel.cust_reason_label'),
    'note_label',   public._c('cancel.cust_note_label'),
    'cta',          public._c('cancel.cust_cta'),
    'keep_cta',     public._c('cancel.cust_keep_cta'),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'label', r.label)
                                           order by r.sort, r.code)
                           from public.order_reason_option r
                          where r.scope='cancel' and r.active and r.customer_visible), '[]'::jsonb));
end $fn$;

-- ── 4. ONE row builder ─────────────────────────────────────────────────────
-- my_orders_screen() built its rows inline, so the order detail had no way to
-- ask for "that same order, fully" without a second query that disagreed
-- (exactly the fan-out #625 fixed once already). The row builder is now a
-- function; the list and the detail both read it, so they cannot drift.
create or replace function public._order_customer_row(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  ord   public.orders%rowtype;
  v_cfg jsonb := coalesce((select value from app_settings where key='order_status_config'), '{}'::jsonb);
  v_unf jsonb := coalesce((select value from app_settings where key='unfulfilled_copy'), '{}'::jsonb);
  v_tone jsonb := coalesce((select value from app_settings where key='item_status_tones'),
                    '{"green":{"bg":"#E1F5EE","fg":"#0F6E56"},
                      "yellow":{"bg":"#FEF3C7","fg":"#92400E"},
                      "red":{"bg":"#FBE9E7","fg":"#B42318"}}'::jsonb);
  g record;
begin
  select * into ord from public.orders where id = p_order_id;
  if ord.id is null then return null; end if;

  select
    count(*) filter (where d.unfulfillable = false)                    as n_ok,
    count(*) filter (where d.unfulfillable)                            as n_bad,
    coalesce(sum(d.qty) filter (where d.unfulfillable = false),0)::int as units_ok,
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
        'status_text',  d.status_text,
        'status_colors', coalesce(v_tone->d.status_tone, v_tone->'yellow'))
      order by d.product_name) filter (where d.unfulfillable = false)  as ok_lines,
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
        'status_text',  coalesce(d.reason, d.status_text),
        'status_colors', coalesce(v_unf->'chip_colors', v_tone->'red'))
      order by d.product_name) filter (where d.unfulfillable)          as bad_lines
  into g
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
             when 'Available'             then 'green'
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
    from public.order_items oi
    left join "MEDICINE" m on m.id = oi.product_id
    left join lateral (
      select q.current_status from public.inquiry q
       where q.product_id = oi.product_id
         and (q.zone_id is null or coalesce(oi.zone_id, ord.zone_id) is null
              or q.zone_id = coalesce(oi.zone_id, ord.zone_id))
       order by (q.batch_date = (ord.created_at at time zone 'Asia/Kolkata')::date) desc nulls last,
                q.batch_date desc nulls last, q.id desc limit 1) inq on true
    where oi.order_id = ord.id
    group by oi.product_id
  ) d;

  return jsonb_build_object(
    'id',                coalesce(ord.id::text,''),
    'order_code',        coalesce(ord.order_code,''),
    'placed_at',         coalesce(ord.created_at::text,''),
    'placed_at_label',   public._ist_stamp(ord.created_at),
    'status',            coalesce(ord.status,'pending'),
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
    'edit',              public._order_edit_gate(ord.id),
    'actions',           public._order_customer_actions(ord.id));
end $fn$;

revoke all on function public._order_customer_row(uuid) from public;
grant execute on function public._order_customer_row(uuid) to authenticated, service_role;

-- ── 5. Nine internal stages, compressed to the four a pharmacy uses ────────
-- The internal lifecycle (pending / accepted / collecting / counted /
-- at_warehouse / packed / dispatch_ready / assigned / out_for_delivery /
-- delivered) is warehouse vocabulary. A pharmacy asks one question — "where is
-- my order" — and there are four honest answers.
create or replace function public._order_customer_stage(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  o public.orders%rowtype;
  v_key text; v_idx int; v_cancelled boolean; v_delivered boolean;
  v_steps jsonb := '[]'::jsonb; k text; i int := 0;
  v_order text[] := array['confirmed','sourcing','packed','out_for_delivery'];
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;

  v_cancelled := lower(coalesce(o.status,'')) in ('cancelled','canceled','rejected')
                 or exists (select 1 from public.order_cancellations where order_id = p_order_id);
  v_delivered := (not v_cancelled)
                 and (lower(coalesce(o.status,'')) in ('delivered','completed')
                      or o.closed_at is not null
                      or exists (select 1 from public.deliveries d
                                  where d.order_id = p_order_id
                                    and coalesce(d.status,'') = 'delivered'));

  if v_cancelled then
    v_key := 'cancelled'; v_idx := -1;
  elsif v_delivered then
    v_key := 'delivered'; v_idx := 3;
  elsif coalesce(o.dispatch_ready,false)
     or exists (select 1 from public.deliveries d
                 where d.order_id = p_order_id
                   and coalesce(d.status,'') in ('assigned','out_for_delivery')) then
    v_key := 'out_for_delivery'; v_idx := 3;
  elsif exists (select 1 from public.order_items oi
                 where oi.order_id = p_order_id
                   and (coalesce(oi.packed,false) or coalesce(oi.at_warehouse,false))) then
    v_key := 'packed'; v_idx := 2;
  elsif coalesce(o.fulfillment_status,'open') <> 'open'
     or exists (select 1 from public.order_items oi
                 where oi.order_id = p_order_id
                   and (oi.assigned_supplier is not null
                        or coalesce(oi.fulfillment_state,'pending') <> 'pending')) then
    v_key := 'sourcing'; v_idx := 1;
  else
    v_key := 'confirmed'; v_idx := 0;
  end if;

  foreach k in array v_order loop
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'key',   k,
      'label', public._c('orders.step_' || k),
      'state', case when v_idx < 0 then 'todo'
                    when i <  v_idx then 'done'
                    when i =  v_idx then (case when v_key='delivered' then 'done' else 'current' end)
                    else 'todo' end));
    i := i + 1;
  end loop;

  return jsonb_build_object(
    'key',        v_key,
    'label',      public._c('orders.stage_' || v_key),
    'index',      v_idx,
    'is_active',  (not v_cancelled and not v_delivered),
    'is_delivered', v_delivered,
    'is_cancelled', v_cancelled,
    'show_progress', (not v_cancelled and not v_delivered),
    'steps',      v_steps);
end $fn$;

revoke all on function public._order_customer_stage(uuid) from public;
grant execute on function public._order_customer_stage(uuid) to authenticated, service_role;

-- ── 6. ONE CARD, ONE TRUTH ─────────────────────────────────────────────────
-- Code + date, item count, the money (or the honest sentence in place of it),
-- the stage in plain words, and exactly ONE thing to tap. Everything the card
-- used to carry — three chips, a track chip, a parcel chip, an edit button, an
-- actions row, a help box and a reorder button — is either inside the order now
-- or moved out of Orders altogether.
create or replace function public._order_customer_card(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  o public.orders%rowtype;
  st jsonb; v_n int; v_amount numeric; v_amount_label text; v_billed boolean;
  v_paid boolean; v_awaiting boolean; v_act text; v_sit text;
  v_map jsonb := coalesce((select value from app_settings where key='orders_card_action_map'),
                          '{}'::jsonb);
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;
  st := public._order_customer_stage(p_order_id);

  select count(distinct oi.product_id) into v_n
    from public.order_items oi where oi.order_id = p_order_id;

  v_amount := coalesce(o.total_amount, 0);
  v_billed := (nullif(btrim(coalesce(o.invoice_no,'')),'') is not null)
              or (nullif(btrim(coalesce(o.cust_bill_path,'')),'') is not null);

  -- ₹0.00 was rendering as a price and reading like a bug. Zero is never a
  -- price here: on a live order it means the rate is not fixed yet, and on a
  -- finished one it means no bill was raised. Two facts, two sentences.
  if v_amount > 0 then
    v_amount_label := public.inr_money(v_amount);
  elsif coalesce((st->>'is_active')::boolean,false) and not v_billed then
    v_amount_label := public._c('orders.rate_on_confirmation');
  else
    v_amount_label := public._c('orders.not_billed');
  end if;

  select exists (select 1 from public.payment_claims c
                  where c.order_id = p_order_id
                    and lower(coalesce(c.status,'')) in ('verified','received'))
    into v_paid;
  v_awaiting := (v_amount > 0) and (not v_paid)
                and (v_billed or coalesce(o.dispatch_ready,false)
                     or coalesce((st->>'is_delivered')::boolean,false));

  -- WHICH action a card offers is DATA. The card works out the SITUATION —
  -- five facts, not five labels — and app_settings.orders_card_action_map says
  -- what each situation is worth tapping. Om changed this once already (a
  -- pre-inquiry Pending order offers the change window, not a tracker), and
  -- that change must never again be a deploy.
  if coalesce((st->>'is_cancelled')::boolean,false) then
    v_sit := 'cancelled';
  elsif v_awaiting then
    v_sit := 'awaiting_payment';
  elsif coalesce((st->>'is_active')::boolean,false) then
    v_sit := case when coalesce((public._order_change_gate(p_order_id)->>'open')::boolean,false)
                  then 'change_window_open' else 'active' end;
  else
    v_sit := 'finished';
  end if;
  v_act := coalesce(nullif(v_map->>v_sit,''), 'track');

  return jsonb_build_object(
    'id',              coalesce(o.id::text,''),
    'order_code',      coalesce(o.order_code,''),
    'placed_at',       coalesce(o.created_at::text,''),
    'date_label',      public._ist_stamp(o.created_at),
    'header_label',    coalesce(nullif(o.order_code,''), '') ,
    'item_count',      coalesce(v_n,0),
    'item_count_label',
      replace(case when coalesce(v_n,0) = 1 then public._c('orders.item_count_one')
                   else public._c('orders.item_count_many') end,
              '{n}', coalesce(v_n,0)::text),
    'amount',          v_amount,
    'amount_label',    v_amount_label,
    'amount_is_money', (v_amount > 0),
    'stage_key',       st->>'key',
    'stage_label',     st->>'label',
    'progress',        jsonb_build_object(
                          'show',  (st->>'show_progress')::boolean,
                          'index', (st->>'index')::int,
                          'steps', st->'steps'),
    'placed_by_admin', coalesce(o.placed_by_admin,false),
    'placed_by_admin_label', case when coalesce(o.placed_by_admin,false)
                                  then public._c('orders.placed_by_admin') else '' end,
    'unfulfilled_count', coalesce(o.unfulfilled_count,0),
    'primary_action',  jsonb_build_object(
                          'key',   v_act,
                          'label', public._c('orders.action_' || v_act),
                          'tone',  coalesce(nullif(v_map->'_tones'->>v_act,''),
                                            case v_act when 'reorder' then 'outline'
                                                       else 'brand' end)),
    'situation',       v_sit);
end $fn$;

revoke all on function public._order_customer_card(uuid) from public;
grant execute on function public._order_customer_card(uuid) to authenticated, service_role;

-- ── 7. The list ────────────────────────────────────────────────────────────
-- Three filters with their own counts, a search that reaches the medicine
-- names, and lean cards. Active is the default because that is the only tab a
-- pharmacy opens Orders to look at.
create or replace function public.my_orders_screen_v2(
  p_filter text default null,
  p_query  text default null,
  p_view_as_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
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
end $fn$;

revoke all on function public.my_orders_screen_v2(text, text, uuid) from public;
grant execute on function public.my_orders_screen_v2(text, text, uuid) to authenticated, service_role;

-- ── 8. The order, opened ───────────────────────────────────────────────────
-- Items · Payment · Bill · Help are TABS in here now, not chips on the list.
-- The edit and cancel doors live here too, and they are ABSENT when the window
-- is shut — the sentence saying why takes their place.
create or replace function public.customer_order_detail(
  p_order_id uuid,
  p_view_as_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  o public.orders%rowtype;
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_gate jsonb; v_actions jsonb := '[]'::jsonb; v_open_tickets int;
begin
  select * into o from public.orders where id = p_order_id;
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
    'help', jsonb_build_object(
       'title', public._c('orders.help_title'),
       'open_count', coalesce(v_open_tickets,0),
       'label', public._c('support.order_action_label')));
end $fn$;

revoke all on function public.customer_order_detail(uuid, uuid) from public;
grant execute on function public.customer_order_detail(uuid, uuid) to authenticated, service_role;

-- ── 9. Which action each situation is worth ────────────────────────────────
-- The card computes a SITUATION; this row says what to offer for it. Om's
-- live correction on this command — a Pending order that has not entered
-- sourcing offers the change window, not a tracker — is this one row, so the
-- next correction is an UPDATE and not a deploy.
insert into app_settings (key, value) values
  ('orders_card_action_map', '{
     "cancelled":          "reorder",
     "awaiting_payment":   "pay",
     "change_window_open": "edit",
     "active":             "track",
     "finished":           "reorder",
     "_tones": {"pay":"brand","track":"brand","edit":"outline","reorder":"outline"}
   }'::jsonb)
on conflict (key) do nothing;

-- ── 10. The shop tools leave Orders ────────────────────────────────────────
-- PART A1. "Due for reorder" (#173), Purchases (#367 row 174), Saved lists
-- (#367 row 178) and Help requests are things a pharmacy does with its own
-- shop; none of them is an order. They were three header tiles and a help box
-- bolted to the top of a list of orders. They become registry rows on #536's
-- My Shop surface — DATA — so moving one again never touches Dart.
insert into nav_category (category_key, label, icon_key, sort_order, is_active) values
  ('cshop_buying', 'Buying', 'bag', 1005, true)
on conflict (category_key) do update set
  label      = excluded.label,
  icon_key   = excluded.icon_key,
  sort_order = excluded.sort_order,
  is_active  = excluded.is_active;

insert into feature_registry (
  feature_key, label, description, group_label, icon_key, route_key, sort_order,
  owner, partner_eligible, default_access, is_active, category, surface, roles_allowed
) values
  ('cust.reorder_due',   'Due for reorder', 'What you usually buy about now',      'Buying', 'autorenew',  'cust_reorder_due',   10, 'medibo', false, 'read', true, 'cshop_buying', 'customer_shop', array['customer','super_admin']),
  ('cust.purchases',     'Purchases',       'Your spend, month by month',          'Buying', 'timeline',   'cust_purchases',     20, 'medibo', false, 'read', true, 'cshop_buying', 'customer_shop', array['customer','super_admin']),
  ('cust.saved_lists',   'Saved lists',     'Named lists you reorder in one tap',  'Buying', 'task',       'cust_saved_lists',   30, 'medibo', false, 'read', true, 'cshop_buying', 'customer_shop', array['customer','super_admin']),
  ('cust.help_requests', 'Help requests',   'Questions you have raised on orders', 'Buying', 'support_agent', 'cust_help_requests', 40, 'medibo', false, 'read', true, 'cshop_buying', 'customer_shop', array['customer','super_admin'])
on conflict (feature_key) do update set
  label            = excluded.label,
  description      = excluded.description,
  group_label      = excluded.group_label,
  icon_key         = excluded.icon_key,
  route_key        = excluded.route_key,
  sort_order       = excluded.sort_order,
  is_active        = excluded.is_active,
  category         = excluded.category,
  surface          = excluded.surface,
  roles_allowed    = excluded.roles_allowed;

-- ── 11. The bottom bar is a registry, not five hand-written slots ───────────
-- Om, live on #630: the customer bar reads Home · Catalogue · Bulk · Orders ·
-- My Shop, and "registry sort_order owns it; do not hardcode the order in
-- Dart." Until now the five slots were a Dart list literal and the selected
-- index was a hand-written `index == 11 ? 2 : ...` ladder, so RE-ORDERING the
-- bar meant editing two expressions that had to agree. Both facts move here:
-- the row carries the shell page it opens, so the ladder is a lookup.
create table if not exists public.customer_nav_slot (
  slot_key    text primary key,
  label_key   text not null,
  icon_key    text not null,
  page_index  int  not null,
  sort_order  int  not null default 100,
  is_active   boolean not null default true,
  updated_at  timestamptz not null default now()
);

alter table public.customer_nav_slot enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='customer_nav_slot'
                    and policyname='customer_nav_slot_read') then
    create policy customer_nav_slot_read on public.customer_nav_slot
      for select using (true);
  end if;
end $$;

insert into public.customer_nav_slot (slot_key, label_key, icon_key, page_index, sort_order) values
  ('home',      'home_shell.home',      'home',        0,  10),
  ('catalogue', 'home_shell.catalogue', 'grid',        0,  20),
  ('bulk',      'home_shell.bulk',      'upload_file', 2,  30),
  ('orders',    'home_shell.orders',    'receipt',     1,  40),
  ('my_shop',   'home_shell.my_shop',   'storefront', 11,  50)
on conflict (slot_key) do update set
  label_key  = excluded.label_key,
  icon_key   = excluded.icon_key,
  page_index = excluded.page_index,
  sort_order = excluded.sort_order,
  is_active  = true,
  updated_at = now();

-- The bar, rendered. `badge` names the one slot that carries the order count;
-- the shell reads the number it already has rather than the row inventing one.
create or replace function public.customer_nav()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'ok', true,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key',        s.slot_key,
               'label',      public._c(s.label_key),
               'icon_key',   s.icon_key,
               'page_index', s.page_index,
               'badge',      (s.slot_key = 'orders'))
             order by s.sort_order, s.slot_key)
        from public.customer_nav_slot s
       where s.is_active), '[]'::jsonb));
$fn$;

revoke all on function public.customer_nav() from public;
grant execute on function public.customer_nav() to anon, authenticated, service_role;

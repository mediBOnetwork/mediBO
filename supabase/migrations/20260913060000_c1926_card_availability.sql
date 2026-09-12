-- CMD #1926 — one availability truth on every customer surface.
--
-- The card already asked `storefront_cta(storefront_effective_count(...))` on
-- sixteen RPCs; the REORDER family did not — it compared `MEDICINE.supplier_count`
-- raw, which is the national count, not the buyer's zone standby. A customer in
-- Raipur could therefore be offered a one-tap re-order of a pack no supplier in
-- Raipur can send, and the cart would then refuse it. This migration:
--
--  1. names the zone in words (`_zone_display_name`),
--  2. turns the count into the card's availability LINE (label + tone), which
--     `storefront_cta` now carries so every surface that already renders the
--     availability block gets the line for free,
--  3. publishes `storefront_availability(product_id, global_count)` as THE one
--     entry point — count and verdict in one call, so a new surface cannot
--     compose the pair wrongly,
--  4. routes the reorder family through it, and
--  5. leaves `storefront_availability_audit()` behind so a future surface that
--     reads supplier_count raw is FOUND rather than discovered by a customer.
--
-- Idempotent: every object is CREATE OR REPLACE / ON CONFLICT.

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('storefront.avail_plain',        to_jsonb('Available'::text)),
  ('storefront.avail_in_zone',      to_jsonb('Available · {zone}'::text)),
  ('storefront.not_avail_in_zone',  to_jsonb('Not available · {zone}'::text)),
  ('storefront.zone_suffix',        to_jsonb('Zone'::text))
on conflict (key) do nothing;

-- ── 2. The zone, in words ───────────────────────────────────────────────────
-- `zones.name` is inconsistent by hand: zone 1 is 'Raipur' and zone 2 is
-- 'Bilaspur Zone'. The word "Zone" is appended only when it is not already
-- there, so neither row reads "Bilaspur Zone Zone" nor "Raipur".
create or replace function public._zone_display_name(p_zone smallint)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select case
           when z.name is null or btrim(z.name) = '' then ''
           when lower(btrim(z.name)) like '%zone' then btrim(z.name)
           else btrim(z.name) || ' ' || public.uic('storefront.zone_suffix','Zone')
         end
    from public.zones z
   where z.id = p_zone;
$$;

-- ── 3. The availability LINE ────────────────────────────────────────────────
-- The rule, unchanged from #678/#1812 — only its wording is new:
--   * no viewer zone (anonymous, or signed in but not an approved customer)
--     => "Available", green. Such a viewer is never shown a zone verdict,
--     because they have no zone to be given one about.
--   * a viewer zone => the zone's own standby count decides, and the zone is
--     NAMED so the answer cannot be mistaken for a national one.
-- An unresolved line (a cart row whose product is no longer in the catalogue)
-- gets no line at all: "" is rendered as nothing, never as a guess.
create or replace function public.storefront_availability_line(
  p_count integer, p_resolved boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with v as (select public._viewer_zone_or_null() as z)
  select case
    when not coalesce(p_resolved, true)
      then jsonb_build_object('label','', 'tone','neutral')
    when (select z from v) is null
      then jsonb_build_object(
             'label', public.uic('storefront.avail_plain','Available'),
             'tone',  'success')
    when coalesce(p_count,0) >= 1
      then jsonb_build_object(
             'label', replace(public.uic('storefront.avail_in_zone','Available · {zone}'),
                              '{zone}', public._zone_display_name((select z from v))),
             'tone',  'success')
    else jsonb_build_object(
             'label', replace(public.uic('storefront.not_avail_in_zone','Not available · {zone}'),
                              '{zone}', public._zone_display_name((select z from v))),
             'tone',  'neutral')
  end;
$$;

-- ── 4. storefront_cta carries the line ──────────────────────────────────────
-- Same verdict, same colours, same copy keys as before — the only addition is
-- `availability_label` / `availability_tone`, so every one of the sixteen RPCs
-- that already builds an `availability` block renders the new line with no
-- change of its own.
create or replace function public.storefront_cta(
  p_supplier_count integer, p_resolved boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  -- CMD #1812 — there is exactly ONE availability rule and it is the zone's
  -- standby count. 1mg's scraped `status` used to open a third branch here
  -- ("Not for sale", red) on a product a supplier in the zone could send; that
  -- branch, its parameter and its copy keys are gone.
  select (case
    when not coalesce(p_resolved, true) then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'unresolved', true,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    when coalesce(p_supplier_count, 0) >= 1 then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    else
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label','Unavailable','gated', public.viewer_is_approved_customer(),
        'blocked_by', 'no_supplier',
        'note', case when auth.uid() is null
                     then public.uic('storefront.signed_out_note',
                                     'Sign in to see availability in your area.')
                     -- CMD #1909 — the buyer has a zone, so name it.
                     when public._viewer_zone_or_null() is not null
                     then public.uic('storefront.not_in_zone_note',
                                     'Not available in your zone')
                     else public.uic('storefront.no_supplier_note',
                                     'No supplier for this product right now') end,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='stock_out_label'), 'Out of stock'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  end)
  || jsonb_build_object(
       'availability_label',
         public.storefront_availability_line(p_supplier_count, p_resolved)->>'label',
       'availability_tone',
         public.storefront_availability_line(p_supplier_count, p_resolved)->>'tone');
$$;

-- ── 5. THE shared helper ────────────────────────────────────────────────────
-- Count and verdict in ONE call. Every customer surface that shows a product
-- asks this and nothing else; composing `storefront_cta(storefront_effective_count(…))`
-- by hand is what let sixteen call sites agree and six others drift.
create or replace function public.storefront_availability(
  p_product_id bigint, p_global_count integer default null)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select public.storefront_cta(
           public.storefront_effective_count(p_product_id, p_global_count), true);
$$;

-- The same truth as a scalar, for the paths that gate a WRITE rather than
-- render a card (re-order into the cart, the low-stock nudge).
create or replace function public.storefront_can_add(
  p_product_id bigint, p_global_count integer default null)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.storefront_effective_count(p_product_id, p_global_count) >= 1;
$$;

grant execute on function public._zone_display_name(smallint) to anon, authenticated;
grant execute on function public.storefront_availability_line(integer, boolean) to anon, authenticated;
grant execute on function public.storefront_availability(bigint, integer) to anon, authenticated;
grant execute on function public.storefront_can_add(bigint, integer) to anon, authenticated;

-- ── 6. The reorder family joins the contract ────────────────────────────────
-- Each of these compared `supplier_count >= 1` — the NATIONAL count. Replaced,
-- one for one, with the buyer's zone truth. Nothing else in them changes.
create or replace function public.reorder_suggestions()
returns jsonb
language plpgsql stable security definer
set search_path to 'public' set "TimeZone" to 'Asia/Kolkata'
as $function$
declare v_cust uuid; v_items jsonb; v_due int;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object(
      'ok', true, 'has_history', false, 'items', '[]'::jsonb,
      'due_count', 0, 'has_due', false,
      'title', public._reorder_uic('reorder.title','Reorder'),
      'empty_title', public._reorder_uic('reorder.empty_title','No reorder history yet'),
      'empty_note',  public._reorder_uic('reorder.empty_note','Your regular items will appear here once you have ordered a few times.'));
  end if;

  select coalesce(jsonb_agg(row order by row_order), '[]'::jsonb),
         coalesce(sum(case when (row->>'due')::boolean then 1 else 0 end),0)
    into v_items, v_due
  from (
    select jsonb_build_object(
             'product_id', c.product_id,
             'name', c.name,
             'marketer', c.marketer,
             'pack_size', c.pack_size,
             'image_url', c.image_url,
             'usual_qty', c.usual_qty,
             'qty_label', public._reorder_uic('reorder.usual_prefix','Usual: ') || c.usual_qty::text,
             'days_since_last', c.days_since_last,
             'since_label', c.days_since_last::text || ' ' || public._reorder_uic('reorder.days_ago','days ago'),
             'due', c.due,
             'due_label', case when c.due then public._reorder_uic('reorder.due_now','Due now') else '' end,
             'predicted_label', case
                    when c.predicted_next is null then ''
                    when c.predicted_next > current_date
                      then public._reorder_uic('reorder.next_prefix','Next ~ ') ||
                           to_char(c.predicted_next,'DD Mon')
                    when c.predicted_next = current_date
                      then public._reorder_uic('reorder.next_today','Expected today')
                    when (current_date - c.predicted_next) = 1
                      then public._reorder_uic('reorder.next_overdue_one','Overdue by 1 day')
                    else replace(
                           public._reorder_uic('reorder.next_overdue','Overdue by {n} days'),
                           '{n}', (current_date - c.predicted_next)::text)
                  end,
             'predicted_state', case
                    when c.predicted_next is null then 'none'
                    when c.predicted_next > current_date then 'future'
                    when c.predicted_next = current_date then 'today'
                    else 'overdue' end,
             'overdue_days', case
                    when c.predicted_next is null or c.predicted_next >= current_date then 0
                    else (current_date - c.predicted_next) end,
             'price_display', public._reorder_money(c.mrp),
             -- CMD #1926 — the buyer's ZONE decides, not the national count.
             'can_add', public.storefront_can_add(c.product_id::bigint, c.supplier_count),
             'availability', public.storefront_availability(c.product_id::bigint, c.supplier_count),
             'unavailable_label', case
                    when public.storefront_can_add(c.product_id::bigint, c.supplier_count) then ''
                    else public._reorder_uic('reorder.unavailable','Currently unavailable') end,
             'remind_on', coalesce(rp.notify, false),
             'remind_label', case when coalesce(rp.notify,false)
                    then public._reorder_uic('reorder.remind_on','Reminder on')
                    else public._reorder_uic('reorder.remind_off','Remind me') end,
             'shelf_level', rp.shelf_level,
             'shelf_label', case when rp.shelf_level is not null
                    then public._reorder_uic('reorder.shelf_prefix','Shelf level ') || rp.shelf_level::text
                    else '' end
           ) as row,
           (case when c.due then 0 else 1 end)::text ||
           lpad((100000 - least(c.days_since_last,99999))::text,6,'0') ||
           lpad((100000 - c.buy_count)::text,6,'0') as row_order
      from public._reorder_cadence(v_cust) c
      left join public.reorder_prefs rp
        on rp.customer_id = v_cust and rp.product_id = c.product_id
  ) s;

  return jsonb_build_object(
    'ok', true, 'has_history', (jsonb_array_length(v_items) > 0),
    'items', v_items,
    'due_count', v_due,
    'has_due', (v_due > 0),
    'title', public._reorder_uic('reorder.title','Reorder'),
    'due_title', public._reorder_uic('reorder.due_title','Due for reorder'),
    'all_title', public._reorder_uic('reorder.all_title','Your regular items'),
    'add_all_label', public._reorder_uic('reorder.add_all','Add all due to cart'),
    'add_label', public._reorder_uic('reorder.add','Add'),
    'manage_label', public._reorder_uic('reorder.manage','Manage auto-reorders'),
    'remind_title', public._reorder_uic('reorder.remind_title','Low-stock reminder'),
    'remind_note', public._reorder_uic('reorder.remind_note','We will message you on WhatsApp before you run out, so you can reorder in one reply.'),
    'shelf_hint', public._reorder_uic('reorder.shelf_hint','Shelf level (optional) — units you like to keep in stock'),
    'remind_save', public._reorder_uic('reorder.remind_save','Save reminder'),
    'remind_clear', public._reorder_uic('reorder.remind_clear','Turn reminder off'),
    'generic_error', public._reorder_uic('reorder.add_generic_error','Something went wrong'),
    'empty_title', public._reorder_uic('reorder.empty_title','No reorder history yet'),
    'empty_note',  public._reorder_uic('reorder.empty_note','Your regular items will appear here once you have ordered a few times.'));
end $function$;

create or replace function public.reorder_build_cart(p_product_ids text[] default null::text[])
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_cust uuid; r record; v_added int := 0;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  for r in
    select * from public._reorder_cadence(v_cust) c
     where public.storefront_can_add(c.product_id::bigint, c.supplier_count)  -- CMD #1926
       and ( (p_product_ids is not null and c.product_id = any(p_product_ids))
             or (p_product_ids is null and c.due) )
  loop
    perform public.cart_set_item(r.product_id, r.usual_qty, null);
    v_added := v_added + 1;
  end loop;
  return jsonb_build_object(
    'ok', true, 'added', v_added,
    'message', v_added::text || ' ' || public._reorder_uic('reorder.added_suffix','items added to cart'),
    'cart', public.cart_render(null));
end $function$;

create or replace function public.reorder_apply_diff(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_cust uuid; r record; v_added int := 0; v_pid text; v_qty int;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  for r in
    select oi.product_id, oi.quantity,
           -- CMD #1926 — the buyer's zone standby, not the national count.
           coalesce(public.storefront_can_add(m.id, m.supplier_count), false) as ok
      from public.order_items oi
      left join "MEDICINE" m on m.id = oi.product_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable,false) = false
  loop
    if r.ok then
      v_pid := r.product_id::text; v_qty := greatest(r.quantity::int,1);
      perform public.cart_set_item(v_pid, v_qty, null);
      v_added := v_added + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'ok', true, 'added', v_added,
    'message', v_added::text || ' ' || public._reorder_uic('reorder.added_suffix','items added to cart'),
    'cart', public.cart_render(null));
end $function$;

create or replace function public.reorder_lowstock_check()
returns integer
language plpgsql security definer set search_path to 'public'
as $function$
declare p record; v_items jsonb; v_pid uuid; n int := 0;
begin
  for p in
    select distinct customer_id from public.reorder_prefs where notify = true
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', cd.product_id, 'qty', cd.usual_qty, 'name', cd.name)), '[]'::jsonb)
      into v_items
      from public._reorder_cadence(p.customer_id) cd
      join public.reorder_prefs rp
        on rp.customer_id = p.customer_id and rp.product_id = cd.product_id and rp.notify = true
     -- CMD #1926 — never nudge a buyer about a pack their zone cannot send.
     where public.medicine_zone_standby(
             cd.product_id::bigint,
             (select pp.zone_id from public.pharmacy_profiles pp where pp.id = p.customer_id)) >= 1
       and ( cd.due
             or (rp.shelf_level is not null and cd.usual_qty <= rp.shelf_level) );
    if v_items <> '[]'::jsonb then
      v_pid := public._reorder_open_pending(p.customer_id, 'lowstock', v_items, null);
      if v_pid is not null then
        perform public.wa_send_event('reorder_due', p.customer_id, jsonb_build_object(), null, null);
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $function$;

create or replace function public.reorder_confirm_pending(p_cust uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare pend record; e jsonb; v_added int := 0; v_uid uuid; v_zone smallint;
begin
  select * into pend from public.reorder_pending
   where customer_id=p_cust and status='open' order by created_at limit 1;
  if pend.id is null then
    return jsonb_build_object('ok', false, 'reason','no_pending');
  end if;
  select user_id into v_uid from public.pharmacy_profiles where id=p_cust;
  -- CMD #1926 — this runs for the CUSTOMER, not the caller, so the zone is
  -- read from their profile rather than from _viewer_zone_or_null().
  select zone_id into v_zone from public.pharmacy_profiles where id=p_cust;
  for e in select * from jsonb_array_elements(pend.items) loop
    insert into public.cart_items(user_id, customer_id, product_id, product_name, price, mrp,
                                  quantity, gst_percent, added_by)
    select v_uid, p_cust, (e->>'product_id'), coalesce(m.product_name, e->>'name'),
           nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
           nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
           greatest((e->>'qty')::int,1),
           nullif(regexp_replace(coalesce(m.gst_percent::text,''),'\D','','g'),'')::int, 'reorder'
      from "MEDICINE" m
     where m.id::text = (e->>'product_id')
       and (case when v_zone is null then coalesce(m.supplier_count,0)
                 else public.medicine_zone_standby(m.id, v_zone) end) >= 1
    on conflict (user_id, product_id) do update
       set quantity=excluded.quantity, removed_by_admin=false, updated_at=now();
    v_added := v_added + 1;
  end loop;
  update public.reorder_pending set status='confirmed', resolved_at=now() where id=pend.id;
  return jsonb_build_object('ok', true, 'added', v_added, 'pending_id', pend.id);
end $function$;

create or replace function public.reorder_diff(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_cust uuid; v_ord record; v_lines jsonb; v_avail int; v_removed int;
        v_up int; v_down int; v_zone smallint;
begin
  v_cust := public.my_customer_id();
  select o.id, o.order_code, o.customer_id into v_ord
    from public.orders o where o.id = p_order_id;
  if v_ord.id is null or (v_cust is not null and v_ord.customer_id <> v_cust
        and public.get_my_role() not in ('admin','super_admin')) then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.order_not_found','Order not found'));
  end if;
  v_zone := public._viewer_zone_or_null();  -- CMD #1926

  select coalesce(jsonb_agg(line order by nm), '[]'::jsonb),
         coalesce(sum(case when avail then 1 else 0 end),0),
         coalesce(sum(case when not avail and swap_id is null then 1 else 0 end),0),
         coalesce(sum(case when delta > 0 then 1 else 0 end),0),
         coalesce(sum(case when delta < 0 then 1 else 0 end),0)
    into v_lines, v_avail, v_removed, v_up, v_down
  from (
    select oi.product_name as nm,
           coalesce(public.storefront_can_add(m.id, m.supplier_count), false) as avail,
           s.swap_id,
           round(coalesce(cur.mrp,0) - coalesce(oi.price,0),2) as delta,
           jsonb_build_object(
             'product_id', oi.product_id::text,
             'name', coalesce(m.product_name, oi.product_name),
             'last_qty', oi.quantity::int,
             'last_price_display', public._reorder_money(oi.price),
             'now_price_display', case when m.id is not null then public._reorder_money(cur.mrp) else '' end,
             'price_delta', round(coalesce(cur.mrp,0) - coalesce(oi.price,0),2),
             'price_delta_label', case
                 when m.id is null then ''
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) > 0
                      then '↑ ' || public._reorder_money(coalesce(cur.mrp,0)-coalesce(oi.price,0))
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) < 0
                      then '↓ ' || public._reorder_money(coalesce(oi.price,0)-coalesce(cur.mrp,0))
                 else public._reorder_uic('reorder.same_price','Same price') end,
             'price_tone', case
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) > 0 then 'warning'
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) < 0 then 'success'
                 else 'neutral' end,
             'status', case when m.id is null then 'discontinued'
                            when public.storefront_can_add(m.id, m.supplier_count) then 'available'
                            else 'out_of_stock' end,
             'status_label', case when m.id is null then public._reorder_uic('reorder.discontinued','No longer listed')
                            when public.storefront_can_add(m.id, m.supplier_count) then public._reorder_uic('reorder.in_stock','Available')
                            else public._reorder_uic('reorder.oos','Out of stock') end,
             'can_add', coalesce(public.storefront_can_add(m.id, m.supplier_count), false),
             'availability', case when m.id is null then null
                                  else public.storefront_availability(m.id, m.supplier_count) end,
             'swap', case when coalesce(public.storefront_can_add(m.id, m.supplier_count), false) = false
                            and sw.id is not null
                          then jsonb_build_object(
                                 'product_id', sw.id::text,
                                 'name', sw.product_name,
                                 'price_display', public._reorder_money(
                                     nullif(regexp_replace(coalesce(sw.mrp::text,''),'[^0-9.]','','g'),'')::numeric),
                                 'reason', public._reorder_uic('reorder.swap_reason','Same maker, in stock'))
                          else null end
           ) as line
      from public.order_items oi
      left join "MEDICINE" m on m.id = oi.product_id
      left join lateral (
        select nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
      ) cur on true
      left join lateral (
        -- CMD #1926 — a swap is only a swap if the BUYER's zone can send it.
        select sw2.id as swap_id from "MEDICINE" sw2
         where coalesce(public.storefront_can_add(m.id, m.supplier_count), false) = false
           and sw2.id <> coalesce(m.id,-1)
           and sw2.buyable is true
           and (case when v_zone is null then coalesce(sw2.supplier_count,0)
                     else public.medicine_zone_standby(sw2.id, v_zone) end) >= 1
           and ( (m.marketer is not null and sw2.marketer = m.marketer)
                 or (m.therapeutic_class is not null and sw2.therapeutic_class = m.therapeutic_class) )
         order by (case when sw2.marketer = m.marketer then 0 else 1 end), sw2.supplier_count desc
         limit 1
      ) s on true
      left join "MEDICINE" sw on sw.id = s.swap_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable,false) = false
  ) q;

  return jsonb_build_object(
    'ok', true,
    'order_code', coalesce(v_ord.order_code,''),
    'title', public._reorder_uic('reorder.diff_title','Reorder this order'),
    'lines', v_lines,
    'summary', jsonb_build_object(
       'total_lines', jsonb_array_length(v_lines),
       'available', v_avail,
       'removed', v_removed,
       'price_up', v_up,
       'price_down', v_down,
       'removed_label', case when v_removed > 0
            then v_removed::text || ' ' || public._reorder_uic('reorder.removed_suffix','item(s) unavailable — skipped')
            else '' end,
       'changes_label', case when (v_up+v_down) > 0
            then (v_up+v_down)::text || ' ' || public._reorder_uic('reorder.price_changed_suffix','price change(s) since last time')
            else '' end),
    'cta_label', public._reorder_uic('reorder.add_available','Add available items to cart'),
    'repeat_label', public._reorder_uic('reorder.repeat_toggle','Repeat this order automatically'),
    'repeat_note', public._reorder_uic('reorder.repeat_note','Every 30 days — we confirm on WhatsApp before dispatch'),
    'manage_label', public._reorder_uic('reorder.manage','Manage auto-reorders'),
    'generic_error', public._reorder_uic('reorder.add_generic_error','Something went wrong'),
    'add_count', v_avail);
end $function$;

-- ── 7. The drift audit ──────────────────────────────────────────────────────
-- Names every customer-facing function that still decides availability from a
-- raw `supplier_count` comparison instead of the zone truth. `ok:false` with
-- the offenders listed is the answer a future command needs; nothing here
-- changes behaviour, so it is safe to run on production at any time.
create or replace function public.storefront_availability_audit()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with candidates as (
    select p.proname, pg_get_functiondef(p.oid) as def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  ), offenders as (
    select proname from candidates
     where def ~* 'supplier_count[[:space:]]*,?[[:space:]]*0?\)?[[:space:]]*>=[[:space:]]*1'
       and def !~* 'storefront_effective_count|storefront_can_add|medicine_zone_standby'
       and proname <> 'storefront_cta'       -- the helper itself holds the rule
       and proname not like '\_%'            -- internals audited via their caller
       and proname not like 'admin\_%'
       and proname not like 'supplier\_%'
       and proname not like 'fw\_%'
       and proname not like 'test\_%'
  )
  select jsonb_build_object(
    'ok', not exists (select 1 from offenders),
    'offenders', coalesce((select jsonb_agg(proname order by proname) from offenders), '[]'::jsonb),
    'helper', 'storefront_availability(product_id, global_count)');
$$;

grant execute on function public.storefront_availability_audit() to authenticated;

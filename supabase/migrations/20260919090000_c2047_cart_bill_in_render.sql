-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2047 — the bill summary card and the suggested rail REACH THE SCREEN.
--
-- #2014 built both blocks and they worked; they were simply never visible.
-- The cart draws itself from ONE payload, cart_render(), and these two blocks
-- rode a SECOND, best-effort call (cart_bill_view()) whose every failure mode
-- is silent: a customer the second call resolves differently from the cart it
-- is describing, a rail that throws on real catalogue data, a request that
-- loses the race with a quantity tap. Any one of those leaves the blocks
-- absent with nothing said, which is exactly what Om saw.
--
-- So the blocks stop being a second opinion. _cart_bill_core() takes the cart
-- payload that is ALREADY being rendered and returns the bill and the rail for
-- exactly that basket; cart_render() appends them. One payload cannot disagree
-- with itself, and a bill that cannot be built degrades to has:false instead
-- of taking the cart down.
--
-- Nothing here is computed in Dart: ₹ strings come from inr_money, FREE from
-- ui_copy, every label/icon/order/visibility/formula/popup from cart_bill_row.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── The core: rows + rail for a basket that has already been resolved ──────
-- p_cart is a cart_state()/cart_render() payload. p_cust may be null (a cart
-- held against the user row rather than a pharmacy) — the bill still renders,
-- taking its basket numbers from the payload, and the rail simply stays empty
-- because a rail is a per-pharmacy decision.
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
  v_fees    numeric := 0;
  v_grand   numeric := 0;
  v_rows    jsonb   := '[]'::jsonb;
  v_free    text    := public._c('cart.bill_free');
  v_ids     bigint[] := '{}'::bigint[];
  v_rail    jsonb;
  r         record;
  v_amt     numeric;
  v_waived  boolean;
begin
  p_cart := coalesce(p_cart, '{}'::jsonb);

  -- The basket numbers. cart_totals_for() stays the authority whenever there
  -- is a pharmacy to ask about, so a bill row and the checkout bar cannot
  -- disagree; the payload is the fallback, never a second calculation.
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

  v_vars := jsonb_build_object(
    'mrp_total',    v_mrp,
    'trade_total',  v_trade,
    'delivery_fee', v_deliv,
    'advance',      v_adv_amt,
    'item_count',   v_items,
    'unit_count',   v_units);

  -- Pass 1: every fee row, so the grand total knows what it is adding.
  for r in
    select * from public.cart_bill_row b
     where b.visible
       and b.is_fee
       and b.zone_id in (0, coalesce(p_zone, 0))
       and not exists (select 1 from public.cart_bill_row z
                        where z.key = b.key and z.zone_id = coalesce(p_zone, 0)
                          and b.zone_id = 0 and coalesce(p_zone,0) <> 0)
  loop
    v_amt := case r.value_source
               when 'fixed'   then coalesce(r.fixed_amount, 0)
               when 'formula' then public._cart_bill_eval(r.formula, v_vars)
               else coalesce((v_vars->>coalesce(r.computed_key,''))::numeric, 0)
             end;
    v_waived := r.waived or (r.computed_key = 'delivery_fee' and v_deliv = 0 and v_items > 0);
    if not v_waived then v_fees := v_fees + v_amt; end if;
  end loop;

  v_grand := round(v_trade + v_fees, 2);
  v_vars  := v_vars || jsonb_build_object('grand_total', v_grand, 'fees_total', v_fees);

  -- Pass 2: render every row in the admin's order.
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
    v_waived := r.waived or (r.computed_key = 'delivery_fee' and v_deliv = 0 and v_items > 0);

    -- "Rows worth zero or not applicable hide themselves" — a waived fee is
    -- NOT worth zero, it is worth its struck amount plus the word FREE.
    continue when r.hide_when_zero and v_amt = 0 and not v_waived;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key',            r.key,
      'label',          r.label,
      'icon',           r.icon,
      'value',          case when v_waived then '' else public.inr_money(v_amt) end,
      'struck_value',   case when v_waived then public.inr_money(v_amt) else '' end,
      'free_label',     case when v_waived then v_free else '' end,
      'waived',         v_waived,
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

  -- ── B. the rail, off the SAME basket the bill just described ────────────
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
      'has',        jsonb_array_length(v_rows) > 0,
      'title',      public._c('cart.bill_title'),
      'empty_note', public._c('cart.bill_empty'),
      'rows',       v_rows),
    'rail', coalesce(v_rail, jsonb_build_object(
      'has', false, 'title', '', 'items', '[]'::jsonb,
      'empty_note', public._c('cart.rail_empty'))));
end $$;

-- ── The standalone read keeps its signature and its shape ─────────────────
-- Still granted to authenticated (the admin preview and any older client call
-- it), but it is no longer how the cart gets its blocks.
create or replace function public.cart_bill_view(p_guest_uid uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_cust uuid;
  v_zone smallint;
  v_cart jsonb;
begin
  v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                     public.my_customer_id());
  select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
  v_cart := public.cart_state(p_guest_uid);
  return jsonb_build_object('ok', true)
      || public._cart_bill_core(v_cart, v_cust, v_zone);
end $$;

-- ── The cart's ONE payload now carries both blocks ────────────────────────
-- Same body as before plus `bill` and `rail`. The whole append is guarded: a
-- bill that cannot be built must never be the reason a cart fails to load.
create or replace function public.cart_render(p_guest_uid uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v jsonb; k text; arr jsonb; el jsonb; i int; n int := 0; bad bigint[]; ids bigint[];
  v_cust uuid; v_zone smallint; v_blocks jsonb;
begin
  v := public._cart_render_core(p_guest_uid);
  select coalesce(array_agg(u.product_id),'{}') into bad from public._cart_unavailable_lines() u;

  select coalesce(array_agg(distinct (e->>'product_id')::bigint), '{}')
    into ids
    from jsonb_array_elements(coalesce(v->'items','[]'::jsonb)) e
   where (e->>'product_id') ~ '^[0-9]+$';

  -- CMD #2047 — the bill + rail, built from the payload above so they describe
  -- exactly the basket the screen is about to draw.
  begin
    v_cust := nullif(coalesce(v->>'customer_id', ''), '')::uuid;
    if v_cust is null then
      v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                         public.my_customer_id());
    end if;
    select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    v_blocks := public._cart_bill_core(coalesce(v,'{}'::jsonb), v_cust, v_zone);
  exception when others then
    v_blocks := jsonb_build_object(
      'bill', jsonb_build_object('has', false, 'title', '', 'empty_note', '',
                                 'rows', '[]'::jsonb),
      'rail', jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb,
                                 'empty_note', ''));
  end;

  if coalesce(array_length(bad,1),0) = 0 or v is null or jsonb_typeof(v) <> 'object' then
    return coalesce(v,'{}'::jsonb)
        || jsonb_build_object('unavailable_count', 0)
        || jsonb_build_object('companions', public.cart_companions(ids))
        || jsonb_build_object('header', public._c('cart.header_title'))
        || v_blocks;
  end if;
  for k in select jsonb_object_keys(v) loop
    if jsonb_typeof(v->k) = 'array' and jsonb_array_length(v->k) > 0
       and jsonb_typeof((v->k)->0) = 'object' and ((v->k)->0) ? 'product_id' then
      arr := '[]'::jsonb;
      for i in 0..jsonb_array_length(v->k)-1 loop
        el := (v->k)->i;
        if (nullif(el->>'product_id','')::bigint = any(bad)) then
          el := el || jsonb_build_object('unavailable', true, 'qty_locked', true);
          n := n + 1;
        end if;
        arr := arr || el;
      end loop;
      v := jsonb_set(v, array[k], arr);
    end if;
  end loop;
  return v || jsonb_build_object(
    'unavailable_count', coalesce(array_length(bad,1),0),
    'unavailable_badge', coalesce(array_length(bad,1),0)::text || ' item'
      || case when coalesce(array_length(bad,1),0) = 1 then '' else 's' end || ' not available',
    'companions', public.cart_companions(ids),
    'header', public._c('cart.header_title'))
    || v_blocks;
end $function$;

-- ── Grants. Unchanged surface: the core is internal, the two reads keep the
--    same audience they had, and neither is reachable by anon.
revoke all on function public._cart_bill_core(jsonb, uuid, smallint) from public, anon;
revoke all on function public.cart_bill_view(uuid)                   from public, anon;
grant execute on function public.cart_bill_view(uuid)                to authenticated;
grant execute on function public.cart_render(uuid)                   to authenticated;

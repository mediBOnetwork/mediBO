-- CMD #2139 — Cart v2: CD strip, swipe-remove rows, Clear, folded bill summary,
-- Delivery / Self pickup, one Place order bar with first-match popups.
--
-- Everything the screen prints is here. The app renders `cart_render().v2`
-- verbatim, asks `cart_place_block()` on the Place order tap, and writes the
-- receive mode through `cart_set_receive_mode()`. Idempotent: replayed on live
-- once by the direct deploy.

-- ── 1. Receive mode: the cart's choice, and the order's copy of it ─────────────
create table if not exists public.cart_receive_mode (
  customer_id uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  mode        text not null default 'delivery' check (mode in ('delivery','pickup')),
  updated_at  timestamptz not null default now()
);
alter table public.cart_receive_mode enable row level security;
revoke all on public.cart_receive_mode from anon, authenticated;

alter table public.orders add column if not exists receive_mode text not null default 'delivery';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_receive_mode_chk') then
    alter table public.orders add constraint orders_receive_mode_chk
      check (receive_mode in ('delivery','pickup'));
  end if;
end $$;

-- One-time hints a customer dismissed (the swipe tip).
create table if not exists public.cart_hint_seen (
  user_id uuid not null,
  hint    text not null,
  seen_at timestamptz not null default now(),
  primary key (user_id, hint)
);
alter table public.cart_hint_seen enable row level security;
revoke all on public.cart_hint_seen from anon, authenticated;

-- ── 2. Words ──────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('cart2.clear',                to_jsonb('Clear'::text)),
  ('cart2.clear_title',          to_jsonb('Clear all {n} items?'::text)),
  ('cart2.clear_body',           to_jsonb('Your cart will be empty. You can undo for {s} seconds.'::text)),
  ('cart2.clear_keep',           to_jsonb('Keep items'::text)),
  ('cart2.clear_confirm',        to_jsonb('Clear cart'::text)),
  ('cart2.cleared_snack',        to_jsonb('Cart cleared · {n} items'::text)),
  ('cart2.cd_lead',              to_jsonb('{pct}% CD'::text)),
  ('cart2.cd_rest',              to_jsonb('on orders above {amount}'::text)),
  ('cart2.swipe_tip_bold',       to_jsonb('Swipe left'::text)),
  ('cart2.swipe_tip_rest',       to_jsonb('on a product to remove it'::text)),
  ('cart2.swipe_tip_ok',         to_jsonb('Got it'::text)),
  ('cart2.remove',               to_jsonb('Remove'::text)),
  ('cart2.removed_snack',        to_jsonb('{name} removed'::text)),
  ('cart2.undo',                 to_jsonb('Undo'::text)),
  ('cart2.qty_remove',           to_jsonb('Remove from cart'::text)),
  ('cart2.bill_title',           to_jsonb('Bill summary'::text)),
  ('cart2.bill_mrp',             to_jsonb('MRP total · {n} items'::text)),
  ('cart2.bill_sale_value',      to_jsonb('On your final bill'::text)),
  ('cart2.bill_fees',            to_jsonb('Fees'::text)),
  ('cart2.bill_free',            to_jsonb('FREE'::text)),
  ('cart2.bill_savings',         to_jsonb('You save {amount} on fees with this order'::text)),
  ('cart2.bill_advance',         to_jsonb('Advance to pay'::text)),
  ('cart2.receive_title',        to_jsonb('How do you want to receive it?'::text)),
  ('cart2.receive_delivery',     to_jsonb('Delivery'::text)),
  ('cart2.receive_delivery_sub', to_jsonb('To your shop'::text)),
  ('cart2.receive_pickup',       to_jsonb('Self pickup'::text)),
  ('cart2.receive_pickup_sub',   to_jsonb('Collect from our partner'::text)),
  ('cart2.receive_pickup_none',  to_jsonb('Not available in your area yet'::text)),
  ('cart2.deliver_to',           to_jsonb('Deliver to'::text)),
  ('cart2.collect_from',         to_jsonb('Collect from'::text)),
  ('cart2.delivery_due',         to_jsonb('Pay remaining due before dispatch'::text)),
  ('cart2.pickup_due',           to_jsonb('Pay remaining due at the shop'::text)),
  ('cart2.mode_chip_delivery',   to_jsonb('Delivery · pay remaining due before dispatch'::text)),
  ('cart2.mode_chip_pickup',     to_jsonb('Self pickup · pay remaining due at the shop'::text)),
  ('cart2.bar_advance',          to_jsonb('Advance to pay'::text)),
  ('cart2.bar_place',            to_jsonb('Place order'::text)),
  ('cart2.pay_title',            to_jsonb('Pay {amount} advance'::text)),
  ('cart2.pay_body',             to_jsonb('Your order is placed as soon as the advance is paid.'::text)),
  ('cart2.place_title',          to_jsonb('Place this order?'::text)),
  ('cart2.place_body',           to_jsonb('We will confirm your order on WhatsApp.'::text)),
  ('cart2.cancel',               to_jsonb('Cancel'::text)),
  ('cart2.pay_place',            to_jsonb('Pay & place order'::text)),
  ('cart2.place_now',            to_jsonb('Place order'::text)),
  ('cart2.later',                to_jsonb('Later'::text)),
  ('cart2.ok',                   to_jsonb('OK'::text)),
  ('cart2.contact',              to_jsonb('Contact us'::text)),
  ('cart2.login',                to_jsonb('Login'::text)),
  ('cart2.continue',             to_jsonb('Continue'::text)),
  ('cart2.pop_login_title',      to_jsonb('Login to place your order'::text)),
  ('cart2.pop_login_body',       to_jsonb('Your cart stays saved.'::text)),
  ('cart2.pop_reg_title',        to_jsonb('Finish registering your pharmacy'::text)),
  ('cart2.pop_reg_body',         to_jsonb('Takes about a minute. Your cart stays saved.'::text)),
  ('cart2.pop_verify_title',     to_jsonb('Account under verification'::text)),
  ('cart2.pop_verify_body',      to_jsonb('We are verifying your details. You can order once approved.'::text)),
  ('cart2.pop_hold_title',       to_jsonb('Ordering is not available'::text)),
  ('cart2.pop_hold_body',        to_jsonb('Your account is on hold. Please contact us.'::text)),
  ('cart2.pop_area_title',       to_jsonb('We do not deliver here yet'::text)),
  ('cart2.pop_area_body',        to_jsonb('{pincode} is outside our delivery area. Please contact us before ordering.'::text)),
  ('cart2.pop_hours_title',      to_jsonb('Order hours are closed'::text)),
  ('cart2.pop_hours_body',       to_jsonb('Order hours are closed. Please place your order later.'::text)),
  ('cart2.pop_hours_chip',       to_jsonb('Opens again at {time} · your cart is saved'::text)),
  ('cart2.pop_payfail_title',    to_jsonb('Payment did not go through'::text)),
  ('cart2.pop_payfail_body',     to_jsonb('Your cart is saved — please try again.'::text)),
  ('cart2.try_again',            to_jsonb('Try again'::text)),
  ('cart2.placed_title',         to_jsonb('Order placed'::text)),
  ('cart2.placed_body_paid',     to_jsonb('Advance {amount} received. We will WhatsApp you updates.'::text)),
  ('cart2.placed_body',          to_jsonb('We will WhatsApp you updates.'::text)),
  ('cart2.placed_chip',          to_jsonb('Order {code} · {mode}'::text)),
  ('cart2.shop_more',            to_jsonb('Shop more'::text)),
  ('cart2.track',                to_jsonb('Track order'::text)),
  ('cart2.pickup_no_rider',      to_jsonb('This is a self-pickup order — the customer collects it from the partner, so no rider is assigned.'::text)),
  ('cart2.admin_mode_delivery',  to_jsonb('Delivery'::text)),
  ('cart2.admin_mode_pickup',    to_jsonb('Self pickup'::text))
on conflict (key) do nothing;

-- ── 3. Helpers ────────────────────────────────────────────────────────────────
create or replace function public._cart2_customer()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then return null; end if;
  begin
    v := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
  exception when others then v := null; end;
  return v;
end $$;
revoke all on function public._cart2_customer() from public, anon, authenticated;

create or replace function public._cart2_mode(p_cust uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select mode from public.cart_receive_mode where customer_id = p_cust), 'delivery');
$$;
revoke all on function public._cart2_mode(uuid) from public, anon, authenticated;

-- The zone partner a pickup order is collected from.
create or replace function public._cart2_partner(p_zone smallint)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when rp.id is null then null else jsonb_build_object(
           'name', rp.partner_name, 'address', coalesce(rp.address, '')) end
    from (select 1) one
    left join lateral (
      select * from public.region_partners r
       where r.is_active and r.zone_id = p_zone and r.suspended_at is null
       order by r.id limit 1) rp on true;
$$;
revoke all on function public._cart2_partner(smallint) from public, anon, authenticated;

-- The Delivery / Self pickup block. Fixed shape for both modes so the box
-- never changes height when the customer switches.
create or replace function public._cart2_receive(p_cust uuid, p_zone smallint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_mode text := public._cart2_mode(p_cust);
  v_pp   record;
  v_part jsonb := public._cart2_partner(p_zone);
  v_addr text;
begin
  if p_cust is null then
    return jsonb_build_object('has', false);
  end if;
  select pharmacy_name, address, pincode into v_pp from public.pharmacy_profiles where id = p_cust;
  v_addr := coalesce(v_pp.address, '');
  if coalesce(v_pp.pincode, '') <> '' and position(v_pp.pincode in v_addr) = 0 then
    v_addr := btrim(v_addr || ' ' || v_pp.pincode);
  end if;
  if v_part is null and v_mode = 'pickup' then v_mode := 'delivery'; end if;
  return jsonb_build_object(
    'has', true,
    'title', public._c('cart2.receive_title'),
    'selected', v_mode,
    'options', jsonb_build_array(
      jsonb_build_object('key', 'delivery', 'icon', 'local_shipping',
        'label', public._c('cart2.receive_delivery'),
        'sub', public._c('cart2.receive_delivery_sub'), 'enabled', true),
      jsonb_build_object('key', 'pickup', 'icon', 'storefront',
        'label', public._c('cart2.receive_pickup'),
        'sub', case when v_part is null then public._c('cart2.receive_pickup_none')
                    else public._c('cart2.receive_pickup_sub') end,
        'enabled', v_part is not null)),
    'boxes', jsonb_build_object(
      'delivery', jsonb_build_object(
        'lead', public._c('cart2.deliver_to'),
        'name', coalesce(v_pp.pharmacy_name, ''),
        'address', v_addr,
        'note', public._c('cart2.delivery_due')),
      'pickup', jsonb_build_object(
        'lead', public._c('cart2.collect_from'),
        'name', coalesce(v_part->>'name', ''),
        'address', coalesce(v_part->>'address', ''),
        'note', public._c('cart2.pickup_due'))));
end $$;
revoke all on function public._cart2_receive(uuid, smallint) from public, anon, authenticated;

-- ── 4. The v2 block ─────────────────────────────────────────────────────────
create or replace function public._cart_v2_block(p_cart jsonb, p_cust uuid, p_zone smallint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_totals jsonb; v_mrp numeric := 0; v_items int := 0; v_adv jsonb; v_adv_amt numeric := 0;
  v_slides jsonb; v_fees jsonb := '[]'::jsonb; v_fee_all numeric := 0; v_fee_due numeric := 0;
  v_saved numeric := 0; r record; v_sale_label text; v_undo int := 5; v_seen boolean := false;
begin
  p_cart := coalesce(p_cart, '{}'::jsonb);
  if p_cust is not null then
    begin v_totals := public.cart_totals_for(p_cust); exception when others then v_totals := null; end;
  end if;
  v_mrp := coalesce((v_totals->>'mrp_total')::numeric, (p_cart->>'mrp_total')::numeric, 0);
  v_items := coalesce((v_totals->>'item_count')::int, (p_cart->>'item_count')::int,
                      jsonb_array_length(coalesce(p_cart->'items','[]'::jsonb)));
  begin
    v_adv := public.advance_pct_for(p_cust, p_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then v_adv_amt := 0; end;
  begin v_undo := public.cart_undo_window_s(); exception when others then v_undo := 5; end;

  -- CD strip: every ACTIVE slab, lowest threshold first.
  select coalesce(jsonb_agg(jsonb_build_object(
           'lead', public._cf('cart2.cd_lead', jsonb_build_object('pct', trim(to_char(s.discount_pct, 'FM999990.##'), '.'))),
           'rest', public._cf('cart2.cd_rest', jsonb_build_object('amount', public.inr_money_compact(s.min_amount))))
           order by s.min_amount), '[]'::jsonb)
    into v_slides
    from public.discount_slabs s
   where s.active and s.effective_from <= (now() at time zone 'Asia/Kolkata')::date;

  -- Fees: the cart_bill_row fee rows (zone row overrides the global one).
  for r in
    select * from public.cart_bill_row b
     where b.visible and b.is_fee and b.zone_id in (0, coalesce(p_zone, 0))
       and not exists (select 1 from public.cart_bill_row z
                        where z.key = b.key and z.zone_id = coalesce(p_zone, 0)
                          and b.zone_id = 0 and coalesce(p_zone,0) <> 0)
     order by b.sort_order, b.key
  loop
    v_fee_all := v_fee_all + coalesce(r.fixed_amount, 0);
    if r.waived then v_saved := v_saved + coalesce(r.fixed_amount, 0);
    else v_fee_due := v_fee_due + coalesce(r.fixed_amount, 0); end if;
    v_fees := v_fees || jsonb_build_array(jsonb_build_object(
      'key', r.key, 'label', r.label,
      'struck', case when r.waived then public.inr_money(coalesce(r.fixed_amount,0)) else '' end,
      'value', case when r.waived then public._c('cart2.bill_free') else public.inr_money(coalesce(r.fixed_amount,0)) end,
      'free', r.waived,
      'info', jsonb_build_object('has', btrim(coalesce(r.popup_title,'')) <> '' or btrim(coalesce(r.popup_body,'')) <> '',
                                 'title', coalesce(r.popup_title,''), 'body', coalesce(r.popup_body,''),
                                 'dismiss', public._c('cart2.ok'))));
  end loop;

  select coalesce(max(label), 'Sale price total') into v_sale_label
    from public.cart_bill_row where key = 'trade_total' and zone_id = 0;

  if auth.uid() is not null then
    v_seen := exists (select 1 from public.cart_hint_seen where user_id = auth.uid() and hint = 'swipe_remove');
  end if;

  return jsonb_build_object(
    'has', v_items > 0,
    'cd_strip', jsonb_build_object('has', jsonb_array_length(v_slides) > 0,
                                   'interval_ms', 2000, 'slides', v_slides),
    'swipe_tip', jsonb_build_object('show', v_items > 0 and not v_seen,
                                    'bold', public._c('cart2.swipe_tip_bold'),
                                    'rest', public._c('cart2.swipe_tip_rest'),
                                    'ok', public._c('cart2.swipe_tip_ok')),
    'clear', jsonb_build_object(
      'label', public._c('cart2.clear'),
      'title', public._cf('cart2.clear_title', jsonb_build_object('n', v_items::text)),
      'body',  public._cf('cart2.clear_body', jsonb_build_object('s', v_undo::text)),
      'keep',  public._c('cart2.clear_keep'),
      'confirm', public._c('cart2.clear_confirm')),
    'row', jsonb_build_object(
      'remove', public._c('cart2.remove'),
      'removed', public._c('cart2.removed_snack'),
      'undo', public._c('cart2.undo'),
      'undo_s', v_undo,
      'picker_rpc', 'cart_qty_picker'),
    'bill', jsonb_build_object(
      'has', v_items > 0,
      'title', public._c('cart2.bill_title'),
      'mrp_label', public._cf('cart2.bill_mrp', jsonb_build_object('n', v_items::text)),
      'mrp_value', public.inr_money(v_mrp),
      'sale_label', v_sale_label,
      'sale_value', public._c('cart2.bill_sale_value'),
      'fees_has', jsonb_array_length(v_fees) > 0,
      'fees_label', public._c('cart2.bill_fees'),
      'fees_struck', case when v_saved > 0 then public.inr_money(v_fee_all) else '' end,
      'fees_value', case when v_fee_due = 0 then public._c('cart2.bill_free') else public.inr_money(v_fee_due) end,
      'fees_free', v_fee_due = 0,
      'fees', v_fees,
      'savings', jsonb_build_object('has', v_saved > 0,
        'text', public._cf('cart2.bill_savings', jsonb_build_object('amount', public.inr_money_compact(v_saved)))),
      'advance_label', public._c('cart2.bill_advance'),
      'advance_value', public.inr_money(v_adv_amt)),
    'receive', public._cart2_receive(p_cust, p_zone),
    'bar', jsonb_build_object(
      'advance_label', public._c('cart2.bar_advance'),
      'advance_value', public.inr_money(v_adv_amt),
      'place', public._c('cart2.bar_place')));
exception when others then
  return jsonb_build_object('has', false, 'error', sqlerrm);
end $$;
revoke all on function public._cart_v2_block(jsonb, uuid, smallint) from public, anon, authenticated;

-- ── 5. Hook it into cart_render (both returns) ──────────────────────────────
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cart_render(uuid)'::regprocedure);
  if position('_cart_v2_block' in d) = 0 then
    d := replace(d, '|| v_blocks;',
      '|| v_blocks || jsonb_build_object(''v2'', public._cart_v2_block(v, v_cust, v_zone));');
    execute d;
  end if;
end $$;

-- ── 6. Writes ───────────────────────────────────────────────────────────────
create or replace function public.cart_set_receive_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cust uuid := public._cart2_customer(); v_zone smallint;
begin
  if v_cust is null then return jsonb_build_object('ok', false, 'error', 'no_customer'); end if;
  if p_mode not in ('delivery','pickup') then return jsonb_build_object('ok', false, 'error', 'bad_mode'); end if;
  select zone_id into v_zone from public.pharmacy_profiles where id = v_cust;
  if p_mode = 'pickup' and public._cart2_partner(v_zone) is null then
    return jsonb_build_object('ok', false, 'error', 'no_partner', 'receive', public._cart2_receive(v_cust, v_zone));
  end if;
  insert into public.cart_receive_mode(customer_id, mode, updated_at) values (v_cust, p_mode, now())
  on conflict (customer_id) do update set mode = excluded.mode, updated_at = now();
  return jsonb_build_object('ok', true, 'receive', public._cart2_receive(v_cust, v_zone));
end $$;
revoke all on function public.cart_set_receive_mode(text) from public, anon;
grant execute on function public.cart_set_receive_mode(text) to authenticated;

create or replace function public.cart_swipe_tip_seen()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false); end if;
  insert into public.cart_hint_seen(user_id, hint) values (auth.uid(), 'swipe_remove')
  on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.cart_swipe_tip_seen() from public, anon;
grant execute on function public.cart_swipe_tip_seen() to authenticated;

-- The cart's quantity sheet: the same list as Bulk Upload, and "Remove from
-- cart" as the LAST row.
create or replace function public.cart_qty_picker(p_pack_type text default null, p_current integer default null)
returns jsonb language sql stable security definer set search_path = public as $$
  with b as (select public.bulk_qty_picker(p_pack_type, p_current) as j)
  select b.j || jsonb_build_object(
    'options', coalesce(b.j->'options', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
       'value', 0, 'label', public._c('cart2.qty_remove'), 'remove', true)))
  from b;
$$;
revoke all on function public.cart_qty_picker(text, integer) from public;
grant execute on function public.cart_qty_picker(text, integer) to anon, authenticated;

-- Clear now words its snackbar with the count ("Cart cleared · 3 items").
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cart_clear(uuid)'::regprocedure);
  if position('cart2.cleared_snack' in d) = 0 then
    d := replace(d, '''message'',      public._c(''cart.cleared_snack''),',
                    '''message'',      public._cf(''cart2.cleared_snack'', jsonb_build_object(''n'', v_n::text)),');
    execute d;
  end if;
end $$;

-- ── 7. The Place order tap: first matching popup, else the confirm sheet ────
create or replace function public._cart2_popup(p_key text, p_icon text, p_tone text,
  p_title text, p_body text, p_chip text,
  p_primary_label text, p_primary_action text, p_primary_route text,
  p_secondary_label text, p_secondary_action text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('has', true, 'key', p_key, 'icon', p_icon, 'tone', p_tone,
    'title', p_title, 'body', p_body, 'chip', coalesce(p_chip, ''),
    'primary', jsonb_build_object('label', p_primary_label, 'action', p_primary_action,
                                  'route', coalesce(p_primary_route, '')),
    'secondary', jsonb_build_object('has', coalesce(p_secondary_label, '') <> '',
                                    'label', coalesce(p_secondary_label, ''),
                                    'action', coalesce(p_secondary_action, 'dismiss')));
$$;
revoke all on function public._cart2_popup(text,text,text,text,text,text,text,text,text,text,text) from public, anon, authenticated;

create or replace function public.cart_place_block()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g jsonb; v_cust uuid; v_pp record; v_srv jsonb; v_oh jsonb; v_mode text; v_zone smallint;
  v_adv numeric := 0; v_advj jsonb; v_totals jsonb; v_pay boolean := false; v_route text;
begin
  g := public.cart_place_gate();
  if g->>'state' = 'logged_out' then
    return jsonb_build_object('blocked', true, 'popup', public._cart2_popup('login', 'person', 'info',
      public._c('cart2.pop_login_title'), public._c('cart2.pop_login_body'), '',
      public._c('cart2.login'), 'route', coalesce(g->>'route', '/login'),
      public._c('cart2.later'), 'dismiss'));
  end if;
  if g->>'state' in ('not_registered', 'incomplete') then
    return jsonb_build_object('blocked', true, 'popup', public._cart2_popup('register', 'assignment', 'warning',
      public._c('cart2.pop_reg_title'), public._c('cart2.pop_reg_body'), '',
      public._c('cart2.continue'), 'route', coalesce(g->>'route', ''),
      public._c('cart2.later'), 'dismiss') || jsonb_build_object('anchor', coalesce(g->>'anchor','')));
  end if;

  v_cust := public._cart2_customer();
  select * into v_pp from public.pharmacy_profiles where id = v_cust;

  if coalesce(v_pp.status, '') = 'suspended' then
    return jsonb_build_object('blocked', true, 'popup', public._cart2_popup('hold', 'block', 'danger',
      public._c('cart2.pop_hold_title'), public._c('cart2.pop_hold_body'), '',
      public._c('cart2.contact'), 'route', '/contact',
      public._c('cart2.ok'), 'dismiss'));
  end if;
  if g->>'state' = 'submitted' then
    return jsonb_build_object('blocked', true, 'popup', public._cart2_popup('verify', 'hourglass', 'info',
      public._c('cart2.pop_verify_title'), public._c('cart2.pop_verify_body'), '',
      public._c('cart2.ok'), 'dismiss', '', '', 'dismiss'));
  end if;

  v_zone := v_pp.zone_id;
  begin v_srv := public.delivery_serviceability_check(v_pp.pincode); exception when others then v_srv := null; end;
  if coalesce((v_srv->>'can_order')::boolean, true) = false then
    return jsonb_build_object('blocked', true, 'popup', public._cart2_popup('area', 'location', 'danger',
      public._c('cart2.pop_area_title'),
      public._cf('cart2.pop_area_body', jsonb_build_object('pincode', coalesce(v_pp.pincode, ''))), '',
      public._c('cart2.contact'), 'route', '/contact',
      public._c('cart2.ok'), 'dismiss'));
  end if;

  begin v_oh := public.order_hours_state(v_zone); exception when others then v_oh := null; end;
  if v_oh is not null and coalesce((v_oh->>'can_order')::boolean, true) = false then
    return jsonb_build_object('blocked', true, 'popup', public._cart2_popup('hours', 'schedule', 'warning',
      public._c('cart2.pop_hours_title'),
      coalesce(nullif(btrim(v_oh->>'closed_message'), ''), public._c('cart2.pop_hours_body')),
      case when coalesce(v_oh->>'auto_open_label', '') <> ''
           then public._cf('cart2.pop_hours_chip', jsonb_build_object('time', v_oh->>'auto_open_label'))
           else '' end,
      public._c('cart2.ok'), 'dismiss', '', '', 'dismiss'));
  end if;

  -- Clear: the confirm sheet.
  v_mode := public._cart2_mode(v_cust);
  begin
    v_totals := public.cart_totals_for(v_cust);
    v_advj := public.advance_pct_for(v_cust, v_zone);
    v_adv := round(coalesce((v_totals->>'mrp_total')::numeric, 0)
                   * coalesce((v_advj->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then v_adv := 0; end;
  begin
    v_pay := coalesce(public.payment_collection_mode(), 'manual') = 'gateway' and v_adv > 0;
  exception when others then v_pay := false; end;

  return jsonb_build_object('blocked', false,
    'mode', v_mode,
    'pay_now', v_pay,
    'confirm', public._cart2_popup('confirm', 'rupee', 'success',
      case when v_pay then public._cf('cart2.pay_title', jsonb_build_object('amount', public.inr_money(v_adv)))
           else public._c('cart2.place_title') end,
      case when v_pay then public._c('cart2.pay_body') else public._c('cart2.place_body') end,
      case when v_mode = 'pickup' then public._c('cart2.mode_chip_pickup') else public._c('cart2.mode_chip_delivery') end,
      case when v_pay then public._c('cart2.pay_place') else public._c('cart2.place_now') end, 'place', '',
      public._c('cart2.cancel'), 'dismiss'),
    'payment_failed', public._cart2_popup('payment_failed', 'warning', 'warning',
      public._c('cart2.pop_payfail_title'), public._c('cart2.pop_payfail_body'), '',
      public._c('cart2.try_again'), 'retry', '', public._c('cart2.cancel'), 'dismiss'));
end $$;
revoke all on function public.cart_place_block() from public;
grant execute on function public.cart_place_block() to anon, authenticated;

-- The "Order placed" popup for one of the caller's own orders.
create or replace function public.cart_v2_placed(p_order_id uuid, p_paid boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o record; v_cust uuid := public._cart2_customer(); v_adv numeric := 0;
begin
  select id, order_code, customer_id, receive_mode, total_amount, coalesce(placed_by_admin,false) pba
    into o from public.orders where id = p_order_id;
  if o.id is null or (o.customer_id is distinct from v_cust
                      and coalesce(public.get_my_role(), '') not in ('admin','super_admin')) then
    return jsonb_build_object('has', false);
  end if;
  begin
    v_adv := coalesce((public.admin_order_payment_view(p_order_id)->>'advance_expected')::numeric, 0);
  exception when others then v_adv := 0; end;
  return public._cart2_popup('placed', 'check', 'success',
    public._c('cart2.placed_title'),
    case when p_paid and v_adv > 0
         then public._cf('cart2.placed_body_paid', jsonb_build_object('amount', public.inr_money(v_adv)))
         else public._c('cart2.placed_body') end,
    public._cf('cart2.placed_chip', jsonb_build_object('code', coalesce(o.order_code, ''),
      'mode', case when o.receive_mode = 'pickup' then public._c('cart2.admin_mode_pickup')
                   else public._c('cart2.admin_mode_delivery') end)),
    public._c('cart2.track'), 'track', '', public._c('cart2.shop_more'), 'shop');
end $$;
revoke all on function public.cart_v2_placed(uuid, boolean) from public, anon;
grant execute on function public.cart_v2_placed(uuid, boolean) to authenticated;

-- ── 8. The order carries the mode; a pickup order never gets a rider ────────
create or replace function public._orders_receive_mode_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.customer_id is not null and coalesce(new.receive_mode, 'delivery') = 'delivery' then
    new.receive_mode := public._cart2_mode(new.customer_id);
  end if;
  return new;
end $$;
drop trigger if exists a1_orders_receive_mode on public.orders;
create trigger a1_orders_receive_mode before insert on public.orders
  for each row execute function public._orders_receive_mode_trg();

create or replace function public._deliveries_pickup_guard_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.orders o where o.id = new.order_id and o.receive_mode = 'pickup') then
    raise exception 'self_pickup_no_rider' using hint = public._c('cart2.pickup_no_rider');
  end if;
  return new;
end $$;
drop trigger if exists a1_deliveries_pickup_guard on public.deliveries;
create trigger a1_deliveries_pickup_guard before insert on public.deliveries
  for each row execute function public._deliveries_pickup_guard_trg();

-- Admin sees the mode on the ops order detail.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.ops_order_detail(uuid)'::regprocedure);
  if position('receive_label' in d) = 0 then
    d := replace(d, '''zone_label'', coalesce((select z.name from zones z where z.id = v_o.zone_id), ''''),',
      '''zone_label'', coalesce((select z.name from zones z where z.id = v_o.zone_id), ''''),
    ''receive_label'', (select case when o2.receive_mode = ''pickup'' then public._c(''cart2.admin_mode_pickup'')
                                    else public._c(''cart2.admin_mode_delivery'') end
                          from public.orders o2 where o2.id = p_order_id),');
    execute d;
  end if;
end $$;

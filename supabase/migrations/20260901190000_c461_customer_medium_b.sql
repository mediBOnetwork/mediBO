-- CHANGE #461 — MEDIUM customer defects, batch B (feature_gaps 166-170).
-- Every statement is idempotent: a resumed worker re-applies this file as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- #166 — Checkout serviceability leaked an internal change note to the buyer.
-- delivery_serviceability.note is an ADMIN field (it held "Seeded from an
-- approved customer at this pincode (CHANGE #309)."), and the payload used it
-- as the customer-facing `message`. Split the two: `note` stays internal and is
-- never rendered; a new `customer_note` carries buyer-facing wording when an
-- admin writes one; otherwise the ui_copy line is used.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.delivery_serviceability
  add column if not exists customer_note text;

comment on column public.delivery_serviceability.note is
  'INTERNAL. Provenance / ops note. Never rendered to a customer — see customer_note.';
comment on column public.delivery_serviceability.customer_note is
  'Customer-facing override for the serviceability message. NULL = use ui_copy.';

create or replace function public.delivery_serviceability_check(p_pincode text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  s public.delivery_serviceability%rowtype;
  v_pin text := nullif(btrim(coalesce(p_pincode,'')),'');
  v_mode text; v_cust_note text; v_zone smallint; v_has_note boolean := false;
begin
  if v_pin is null then
    return jsonb_build_object(
      'checked', false, 'mode','serviceable', 'can_order', true,
      'title','', 'message', public._c('checkout.serviceable_no_pincode'),
      'message_source', 'copy',
      'tone', jsonb_build_object('bg','#EFF6FF','fg','#1E40AF'));
  end if;

  select * into s from public.delivery_serviceability
   where pincode = v_pin and is_active;

  if s.pincode is null then
    v_mode := coalesce(public._dcfg(null)->>'unknown_pincode_mode', 'warn');
    v_zone := null;
  else
    v_mode := s.mode; v_zone := s.zone_id;
    -- #461: ONLY customer_note may reach the buyer. s.note is internal.
    v_cust_note := nullif(btrim(coalesce(s.customer_note,'')), '');
    if v_mode = 'serviceable'
       and not coalesce((public._dcfg(s.zone_id)->>'zone_serviceable')::boolean, true) then
      v_mode := 'blocked';
    end if;
  end if;

  v_has_note := (v_cust_note is not null);

  return jsonb_build_object(
    'checked',  true,
    'pincode',  v_pin,
    'zone_id',  v_zone,
    'mode',     v_mode,
    'can_order', (v_mode <> 'blocked'),
    'is_warning', (v_mode = 'warn'),
    'title', case v_mode
               when 'warn'    then public._c('checkout.serviceable_warn_title')
               when 'blocked' then public._c('checkout.serviceable_blocked_title')
               else '' end,
    'message', coalesce(v_cust_note, case v_mode
               when 'warn'    then public._cf('checkout.serviceable_warn_msg',
                                     jsonb_build_object('pincode', v_pin))
               when 'blocked' then public._cf('checkout.serviceable_blocked_msg',
                                     jsonb_build_object('pincode', v_pin))
               else public._c('checkout.serviceable_ok') end),
    -- provenance, not prose: says WHERE the message came from, never the note.
    'message_source', case when v_has_note then 'customer_note' else 'copy' end,
    'tone', case v_mode
              when 'warn'    then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
              when 'blocked' then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
              else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end $function$;

-- Admins keep both fields: the internal note AND the buyer-facing one.
-- The 5-arg signature is untouched on purpose (no rg_check churn); the
-- customer-facing line gets its own small RPC.
create or replace function public.admin_serviceability_note_set(
  p_pincode text, p_customer_note text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_pin text := nullif(btrim(coalesce(p_pincode,'')),'');
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if v_pin is null then
    return jsonb_build_object('ok',false,'error','pincode_required');
  end if;
  update public.delivery_serviceability
     set customer_note = nullif(btrim(coalesce(p_customer_note,'')),''),
         updated_at    = now(),
         updated_by    = coalesce(auth.jwt()->>'email','admin')
   where pincode = v_pin;
  if not found then
    return jsonb_build_object('ok',false,'error','pincode_not_listed');
  end if;
  return jsonb_build_object('ok',true,'pincode',v_pin,
           'check', public.delivery_serviceability_check(v_pin));
end $function$;

grant execute on function public.admin_serviceability_note_set(text,text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- #167 — Delivery charge was never computed or shown. orders.delivery_charge,
-- delivery_charge_gst, delivery_charge_waived and delivery_charge_label were
-- NULL on every order and cart_render returned no delivery line at all, so the
-- buyer saw a subtotal and paid it. The config existed the whole time
-- (delivery_config.charge_amount / free_above_amount / charge_gst_pct, plus a
-- per-pincode delivery_serviceability.charge_amount override) — nothing read it.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('cart.delivery_label',        to_jsonb('Delivery'::text)),
  ('cart.delivery_free_label',   to_jsonb('Delivery'::text)),
  ('cart.delivery_free_value',   to_jsonb('FREE'::text)),
  ('cart.delivery_gst_label',    to_jsonb('GST on delivery'::text)),
  ('cart.delivery_waived_note',  to_jsonb('Free delivery on this order'::text)),
  ('cart.delivery_threshold_note',to_jsonb('Add {amount} more for free delivery'::text)),
  ('cart.grand_total_label',      to_jsonb('Total payable'::text))
on conflict (key) do nothing;

-- One block, one source of truth. Used by the cart AND by order placement, so
-- the amount at checkout is the amount billed.
create or replace function public.delivery_charge_block(
  p_customer uuid, p_taxable numeric)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  cfg public.delivery_config%rowtype;
  v_pin        text;
  v_pin_charge numeric;
  v_base       numeric;
  v_free_above numeric;
  v_gst_pct    numeric;
  v_gst        numeric;
  v_total      numeric;
  v_waived     boolean;
  v_taxable    numeric := coalesce(p_taxable, 0);
  v_gap        numeric;
begin
  select * into cfg from public.delivery_config where id = 1;

  select nullif(btrim(coalesce(pp.pincode,'')),'') into v_pin
    from public.pharmacy_profiles pp where pp.id = p_customer;

  if v_pin is not null then
    select ds.charge_amount into v_pin_charge
      from public.delivery_serviceability ds
     where ds.pincode = v_pin and ds.is_active;
  end if;

  v_base       := coalesce(v_pin_charge, cfg.charge_amount, 0);
  v_free_above := coalesce(cfg.free_above_amount, 0);
  v_gst_pct    := coalesce(cfg.charge_gst_pct, 0);

  -- Waived when the platform charges nothing, or the basket clears the
  -- free-delivery threshold. A threshold of 0 is "no threshold", not "always
  -- free" — free_above 0 with a charge set must still charge.
  v_waived := (v_base <= 0)
              or (v_free_above > 0 and v_taxable >= v_free_above);

  if v_waived then
    v_base := 0;
  end if;

  v_gst   := round(v_base * v_gst_pct / 100.0, 2);
  v_total := round(v_base + v_gst, 2);
  v_gap   := case when v_free_above > 0 and not v_waived and v_taxable < v_free_above
                  then round(v_free_above - v_taxable, 2) end;

  return jsonb_build_object(
    'has',            true,
    'charged',        (v_total > 0),
    'waived',         v_waived,
    'label',          public._c('cart.delivery_label'),
    'amount',         round(v_base, 2),
    'amount_display', case when v_waived then public._c('cart.delivery_free_value')
                           else public.inr_money(round(v_base,2)) end,
    'gst_label',      public._c('cart.delivery_gst_label'),
    'gst_pct',        v_gst_pct,
    'gst',            v_gst,
    'gst_display',    public.inr_money(v_gst),
    'has_gst',        (v_gst > 0),
    'total',          v_total,
    'total_display',  public.inr_money(v_total),
    'free_above',     v_free_above,
    'note',           case
                        when v_waived and v_free_above > 0
                          then public._c('cart.delivery_waived_note')
                        when v_gap is not null
                          then public._cf('cart.delivery_threshold_note',
                                 jsonb_build_object('amount', public.inr_money(v_gap)))
                        else '' end);
end $function$;

grant execute on function public.delivery_charge_block(uuid, numeric) to authenticated, anon;

-- The cart now carries the delivery line and a grand total that INCLUDES it.
create or replace function public._cart_render_core(p_guest_uid uuid default null::uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_cart jsonb := public.cart_state(p_guest_uid);
  v_mrp numeric := coalesce((v_cart->>'mrp_total')::numeric, 0);
  v_lines int := coalesce((v_cart->>'item_count')::int, 0);
  v_units int := coalesce((v_cart->>'unit_count')::int, 0);
  v_pricing jsonb := coalesce(v_cart->'pricing', '{}'::jsonb);
  v_net numeric := coalesce((v_pricing->>'net_payable')::numeric, 0);
  v_items jsonb;
  v_items_label text;
  v_margin jsonb;
  v_delivery jsonb;
  v_rx jsonb;
  v_rewards jsonb;
  v_grand numeric;
  v_unpriced_line text := coalesce((select value from storefront_ui_label where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
  v_no_mrp text := coalesce((select value from storefront_ui_label where key='cart_no_mrp_note'),
                            'MRP not printed on this pack');
begin
  select coalesce(jsonb_agg(
           it || coalesce(tp, '{}'::jsonb) || jsonb_build_object(
             'has_mrp',           (nullif(it->>'mrp','') is not null),
             'mrp_display',       case when nullif(it->>'mrp','') is null then ''
                                       else public.inr_money((it->>'mrp')::numeric) end,
             'line_mrp_display',  case when nullif(it->>'mrp','') is null then ''
                                       else public.inr_money(coalesce((it->>'line_mrp')::numeric,0)) end,
             'mrp_note',          case when nullif(it->>'mrp','') is null then v_no_mrp else '' end,
             'has_trade_rate',    coalesce((tp->>'has_trade_rate')::boolean, false),
             'rate_note',         case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then '' else v_unpriced_line end,
             'qty_label',         case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then (it->>'quantity') || ' × ' || (tp->>'price_display')
                                       else (it->>'quantity') || ' × ' || v_unpriced_line end)
           order by ord), '[]'::jsonb)
    into v_items
  from (select it, ordinality as ord
        from jsonb_array_elements(coalesce(v_cart->'items','[]'::jsonb))
             with ordinality as t(it, ordinality)) z
  left join lateral (
    select l as tp
      from jsonb_array_elements(coalesce(v_pricing->'lines','[]'::jsonb)) l
     where (l->>'product_id') = (z.it->>'product_id')
     limit 1) p on true;

  v_items_label := case when v_lines = 1 then '1 item' else v_lines::text || ' items' end;

  v_margin := public.cart_margin_block(v_items);

  -- #461/#167: the delivery line. Computed once, here, from delivery_config
  -- and the customer's own pincode; the same block is stamped on the order.
  v_delivery := public.delivery_charge_block(public.my_customer_id(), v_net);
  v_grand    := round(v_net + coalesce((v_delivery->>'total')::numeric, 0), 2);

  -- #461/#170: the Rx / drug-licence gate. rx_required was populated on every
  -- row of "MEDICINE" and never read on the customer path.
  v_rx := public.cart_rx_gate(public.my_customer_id(), coalesce(v_cart->'items','[]'::jsonb));

  -- #461/#168: the tier benefit, and whether it can bite on THIS cart. The
  -- margin card is where the 3% promise is cashed, so the honest note lives here.
  v_rewards := public.cart_rewards_block(public.my_customer_id(), v_margin);

  return v_cart || jsonb_build_object(
    'items', v_items,
    'margin', v_margin,
    'delivery', v_delivery,
    'rx_gate', v_rx,
    'rewards', v_rewards,
    'render', jsonb_build_object(
      'subtotal_display',     coalesce(v_pricing->>'taxable_display', public.inr_money(0)),
      'mrp_total_display',    public.inr_money(v_mrp),
      'net_payable_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'delivery',             v_delivery,
      'rx_gate',              v_rx,
      'rewards',              v_rewards,
      'items_total',          v_net,
      'items_total_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'grand_total',          v_grand,
      -- Unchanged when nothing is charged for delivery: the old payload said
      -- net_payable_display and a zero-charge cart must keep saying exactly that.
      'grand_total_display',  case when coalesce((v_delivery->>'total')::numeric,0) > 0
                                   then public.inr_money(v_grand)
                                   else coalesce(v_pricing->>'net_payable_display', '') end,
      'item_count',           v_lines,
      'unit_count',           v_units,
      'items_label',          v_items_label,
      'subtotal_line',        v_items_label || ' • '
                              || coalesce(v_pricing->>'net_payable_display','')
                              || case when coalesce((v_pricing->>'unpriced_count')::int,0) > 0
                                      then ' • ' || coalesce(v_pricing->>'unpriced_note','')
                                      else '' end,
      'pricing',              v_pricing,
      'tax_lines',            coalesce(v_pricing->'tax_lines', '[]'::jsonb),
      'has_tax',              coalesce((v_pricing->>'has_tax')::boolean, false),
      'margin',               v_margin,
      'pill', jsonb_build_object(
        'show',        (v_lines > 0),
        'items_label', v_items_label,
        'cta',         coalesce(public.storefront_labels()->>'cart_pill_cta', ''),
        'image',       coalesce(v_items->0->>'image_url', '')),
      'labels', jsonb_build_object(
        'subtotal',     coalesce(v_pricing->>'taxable_label', 'Taxable value'),
        'mrp_worth',    coalesce(v_pricing->>'mrp_worth_label', 'MRP worth'),
        'gst',          coalesce(v_pricing->>'gst_total_label', 'GST'),
        'delivery',     coalesce(v_delivery->>'label', 'Delivery'),
        'grand',        public._c('cart.grand_total_label'),
        'total',        coalesce(v_pricing->>'net_payable_label', 'Net payable'))));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- #170 — Rx / drug-licence rules were carried but never enforced.
-- "MEDICINE".rx_required is populated on all 562,549 rows (Rx / OTC) and
-- pharmacy_profiles holds dl_20b / dl_21b, and NOTHING on the customer path
-- ever read either one. The class is now on the card and the PDP, and an Rx
-- line is gated on a valid licence — mode-driven, refusal copy from ui_copy.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.pharmacy_profiles
  add column if not exists dl_expiry date;

alter table public.orders
  add column if not exists rx_line_count int,
  add column if not exists licence_snapshot jsonb;

comment on column public.orders.licence_snapshot is
  'CHANGE #461: the buyer''s drug-licence state at the moment the order was placed.';

insert into public.ui_copy(key, value) values
  ('rx.badge_rx',        to_jsonb('Rx'::text)),
  ('rx.badge_otc',       to_jsonb('OTC'::text)),
  ('rx.pdp_rx_title',    to_jsonb('Prescription medicine'::text)),
  ('rx.pdp_rx_note',     to_jsonb('Schedule H / H1 stock. Your pharmacy drug licence must be on file to order this.'::text)),
  ('rx.pdp_otc_title',   to_jsonb('Over the counter'::text)),
  ('rx.pdp_otc_note',    to_jsonb('No prescription needed for this pack.'::text)),
  ('rx.licence_missing_title', to_jsonb('Drug licence needed'::text)),
  ('rx.licence_missing_msg',   to_jsonb('Add your 20B/21B drug licence to your profile to order prescription medicines. {count} in your cart need it.'::text)),
  ('rx.licence_expired_title', to_jsonb('Drug licence expired'::text)),
  ('rx.licence_expired_msg',   to_jsonb('Your drug licence expired on {date}. Renew it on your profile to keep ordering prescription medicines.'::text)),
  ('rx.licence_ok_note',       to_jsonb('Licence {licence} on file'::text)),
  ('rx.cart_rx_note',          to_jsonb('{count} prescription item(s) in this order'::text))
on conflict (key) do nothing;

insert into public.app_settings(key, value) values
  ('rx_licence_gate', '{"mode":"warn","min_licence_len":4}'::jsonb)
on conflict (key) do nothing;

-- Is this buyer's drug licence real and unexpired? A placeholder like "1" is
-- not a licence: min_licence_len (config, default 4) is the floor.
create or replace function public.rx_licence_state(p_customer uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  pp public.pharmacy_profiles%rowtype;
  v_cfg  jsonb := coalesce((select value from public.app_settings where key='rx_licence_gate'),
                           '{"mode":"warn","min_licence_len":4}'::jsonb);
  v_min  int   := coalesce((v_cfg->>'min_licence_len')::int, 4);
  v_mode text  := coalesce(v_cfg->>'mode', 'warn');
  v_lic  text;
  v_expired boolean := false;
begin
  select * into pp from public.pharmacy_profiles where id = p_customer;

  v_lic := coalesce(
    nullif(btrim(coalesce(pp.dl_20b,'')), ''),
    nullif(btrim(coalesce(pp.dl_21b,'')), ''),
    nullif(btrim(coalesce(pp.drug_license,'')), ''));

  if v_lic is not null and length(v_lic) < v_min then
    v_lic := null;                       -- "1" is a placeholder, not a licence
  end if;

  v_expired := (pp.dl_expiry is not null and pp.dl_expiry < (now() at time zone 'Asia/Kolkata')::date);

  return jsonb_build_object(
    'mode',       v_mode,
    'enforced',   (v_mode = 'block'),
    'has',        (v_lic is not null and not v_expired),
    'licence',    coalesce(v_lic, ''),
    'expiry',     pp.dl_expiry,
    'expired',    v_expired,
    'reason',     case when v_expired then 'expired'
                       when v_lic is null then 'missing'
                       else 'ok' end,
    'ok_note',    case when v_lic is not null and not v_expired
                       then public._cf('rx.licence_ok_note',
                              jsonb_build_object('licence', v_lic)) else '' end);
end $function$;

grant execute on function public.rx_licence_state(uuid) to authenticated;

-- The Rx class as a render-ready badge. One place, used by card, PDP and cart.
create or replace function public.rx_badge(p_rx text)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select case when upper(btrim(coalesce(p_rx,''))) = 'RX' then
    jsonb_build_object(
      'has', true, 'is_rx', true,
      'label', public._c('rx.badge_rx'),
      'title', public._c('rx.pdp_rx_title'),
      'note',  public._c('rx.pdp_rx_note'),
      'tone',  jsonb_build_object('bg','#FEE2E2','fg','#991B1B'))
  when upper(btrim(coalesce(p_rx,''))) = 'OTC' then
    jsonb_build_object(
      'has', true, 'is_rx', false,
      'label', public._c('rx.badge_otc'),
      'title', public._c('rx.pdp_otc_title'),
      'note',  public._c('rx.pdp_otc_note'),
      'tone',  jsonb_build_object('bg','#D1FAE5','fg','#065F46'))
  else jsonb_build_object('has', false, 'is_rx', false) end;
$function$;

grant execute on function public.rx_badge(text) to authenticated, anon;

-- The cart's Rx gate: how many Rx lines, and may this buyer order them?
create or replace function public.cart_rx_gate(p_customer uuid, p_items jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_rx   int := 0;
  v_lic  jsonb := public.rx_licence_state(p_customer);
  v_block boolean;
  v_title text := ''; v_msg text := '';
begin
  select count(*) into v_rx
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) it
    join "MEDICINE" m on m.id = nullif(it->>'product_id','')::bigint
   where upper(btrim(coalesce(m.rx_required,''))) = 'RX';

  if v_rx > 0 and not coalesce((v_lic->>'has')::boolean, false) then
    if (v_lic->>'reason') = 'expired' then
      v_title := public._c('rx.licence_expired_title');
      v_msg   := public._cf('rx.licence_expired_msg',
                   jsonb_build_object('date', to_char((v_lic->>'expiry')::date, 'DD Mon YYYY')));
    else
      v_title := public._c('rx.licence_missing_title');
      v_msg   := public._cf('rx.licence_missing_msg',
                   jsonb_build_object('count', v_rx::text));
    end if;
  end if;

  v_block := (v_rx > 0)
             and not coalesce((v_lic->>'has')::boolean, false)
             and coalesce((v_lic->>'enforced')::boolean, false);

  return jsonb_build_object(
    'has',        (v_rx > 0),
    'rx_count',   v_rx,
    'rx_note',    case when v_rx > 0
                       then public._cf('rx.cart_rx_note', jsonb_build_object('count', v_rx::text))
                       else '' end,
    'licence',    v_lic,
    'can_order',  not v_block,
    'blocked',    v_block,
    'is_warning', (v_msg <> '' and not v_block),
    'title',      v_title,
    'message',    v_msg,
    'tone',       case when v_block then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
                       when v_msg <> '' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end $function$;

grant execute on function public.cart_rx_gate(uuid, jsonb) to authenticated;

-- Order placement: the delivery charge is stamped on the order (so the amount
-- at checkout is the amount billed), the Rx gate is enforced in 'block' mode,
-- and the licence the buyer held at that moment is recorded.
create or replace function public._place_order_v2_core()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  v_delivery   jsonb;
  v_rx         jsonb;
  v_total      numeric;
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

  -- #461/#170: Schedule H/H1 stock needs a licence on file. In 'warn' mode the
  -- order still goes through and the licence state is recorded; in 'block' mode
  -- it is refused with the BACKEND's own copy.
  v_rx := public.cart_rx_gate(v_cust, v_items);
  if coalesce((v_rx->>'blocked')::boolean, false) then
    return jsonb_build_object('error','rx_licence_required',
      'message', coalesce(v_rx->>'message',''),
      'title',   coalesce(v_rx->>'title',''),
      'rx_gate', v_rx);
  end if;

  v_net := coalesce((v_cart->'pricing'->>'net_payable')::numeric, 0);

  -- #461/#167: the delivery line, computed by the SAME block the cart rendered.
  v_delivery := public.delivery_charge_block(v_cust, v_net);
  v_total    := round(v_net + coalesce((v_delivery->>'total')::numeric, 0), 2);

  select * into pp from pharmacy_profiles where id = v_cust;

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id,
     delivery_charge, delivery_charge_gst, delivery_charge_waived, delivery_charge_label,
     rx_line_count, licence_snapshot)
  values
    (v_uid, v_cust, coalesce(pp.pharmacy_name,''), v_items, v_total,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending',
     'website',
     (v_act is not null),
     public.next_order_number(),
     coalesce((v_delivery->>'amount')::numeric, 0),
     coalesce((v_delivery->>'gst')::numeric, 0),
     coalesce((v_delivery->>'waived')::boolean, false),
     coalesce(v_delivery->>'label',''),
     coalesce((v_rx->>'rx_count')::int, 0),
     coalesce(v_rx->'licence', '{}'::jsonb))
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);
  v_checkout := public.checkout_action();

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
    'amount',          v_total,
    'amount_display',  public.inr_money(v_total),
    'items_amount',    v_net,
    'delivery',        v_delivery,
    'rx_gate',         v_rx,
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);
end
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- #168 — Rewards promised a 3% margin benefit no order could deliver.
-- The tier block said benefit_kind margin_pct / benefit_value 3 and the points
-- block said "Worth ₹162.03 · can_redeem true", while every cart came back with
-- margin.has = false and margin.net_total ₹0.00: only 4 of 562,549 products
-- carry a trade price, so there is nothing for a margin percentage to apply to
-- and a redemption would have discounted an MRP-based total. The benefit is now
-- gated on a trade-priced basis and SAYS what it applies to.
-- ─────────────────────────────────────────────────────────────────────────────
update public.app_settings
   set value = coalesce(value,'{}'::jsonb) || jsonb_build_object(
     'benefit_margin_note',  'Applies to the trade-priced lines in your order.',
     'benefit_pending_note', 'This benefit applies once your order has trade-priced items. Nothing in the catalogue is trade-priced for you yet.',
     'points_redeem_blocked','Points apply to trade-priced orders. Add a trade-priced item to redeem.')
 where key = 'loyalty_copy';

insert into public.app_settings(key, value)
select 'loyalty_copy', jsonb_build_object(
     'benefit_margin_note',  'Applies to the trade-priced lines in your order.',
     'benefit_pending_note', 'This benefit applies once your order has trade-priced items. Nothing in the catalogue is trade-priced for you yet.',
     'points_redeem_blocked','Points apply to trade-priced orders. Add a trade-priced item to redeem.')
where not exists (select 1 from public.app_settings where key='loyalty_copy');

-- Is there ANY trade-priced stock a margin benefit could bite on?
create or replace function public._loy_trade_basis()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'ready_products', (select count(*) from public.medicine_pricing where pricing_ready),
    'has',            exists (select 1 from public.medicine_pricing where pricing_ready));
$function$;

create or replace function public.loyalty_tier_for(p_customer uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  r record; v_met numeric; v_cur jsonb := null; v_next jsonb := null; v_gap numeric;
  v_basis jsonb; v_applies boolean; v_kind text;
begin
  if not public._loy_active('tier') or p_customer is null then
    return jsonb_build_object('on', false);
  end if;
  for r in select * from loyalty_tier where enabled order by threshold_value asc, sort_order asc loop
    select case when r.threshold_kind = 'orders' then m.n_orders::numeric else m.amount end
      into v_met from public._loy_metric(p_customer, 'tier', r.window_days) m;
    if v_met >= r.threshold_value then
      v_cur := jsonb_build_object('id', r.id, 'name', r.name,
                 'benefit_kind', r.benefit_kind, 'benefit_value', r.benefit_value,
                 'met', v_met, 'threshold', r.threshold_value, 'kind', r.threshold_kind);
    elsif v_next is null then
      v_gap := r.threshold_value - v_met;
      v_next := jsonb_build_object('id', r.id, 'name', r.name,
                  'threshold', r.threshold_value, 'kind', r.threshold_kind,
                  'met', v_met, 'gap', v_gap,
                  'gap_label', case when r.threshold_kind = 'orders'
                                    then v_gap::int::text else public.inr_money(v_gap) end);
    end if;
  end loop;

  -- #461/#168: a margin benefit only exists where a trade price exists.
  v_basis := public._loy_trade_basis();
  v_kind  := v_cur->>'benefit_kind';
  v_applies := case
                 when v_cur is null then false
                 when v_kind = 'margin_pct' then coalesce((v_basis->>'has')::boolean, false)
                 else true
               end;

  if v_cur is not null then
    v_cur := v_cur || jsonb_build_object(
      'benefit_applies', v_applies,
      'benefit_basis',   case when v_kind = 'margin_pct' then 'trade_priced_lines' else 'order' end,
      'benefit_note',    case
                           when v_kind <> 'margin_pct' then ''
                           when v_applies then public._loy_copy()->>'benefit_margin_note'
                           else public._loy_copy()->>'benefit_pending_note' end);
  end if;

  return jsonb_build_object(
    'on', true,
    'title', public._loy_copy()->>'tier_title',
    'has', (v_cur is not null),
    'current', v_cur,
    'current_label', coalesce(v_cur->>'name', public._loy_copy()->>'tier_none'),
    'benefit_applies', v_applies,
    'benefit_note',    coalesce(v_cur->>'benefit_note', ''),
    'trade_basis',     v_basis,
    'next', v_next,
    'progress_label', case
      when v_next is not null then public._loy_fmt('tier_progress',
             jsonb_build_object('amount', v_next->>'gap_label', 'next', v_next->>'name'))
      when v_cur is not null then public._loy_copy()->>'tier_top'
      else '' end,
    'progress_pct', case
      when v_next is not null and (v_next->>'threshold')::numeric > 0
        then least(1.0, round(((v_next->>'met')::numeric / (v_next->>'threshold')::numeric)::numeric, 4))
      when v_cur is not null then 1.0 else 0 end);
end $function$;

create or replace function public.loyalty_my_rewards()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cust uuid := public.my_customer_id();
  v_copy jsonb := public._loy_copy();
  v_pts numeric; v_cfg jsonb; v_inr numeric; v_min numeric;
  v_tier jsonb; v_targets jsonb; v_streak jsonb; v_any boolean;
  v_basis jsonb; v_basis_ok boolean; v_can boolean;
begin
  if v_cust is null then
    return jsonb_build_object('ok', true, 'title', v_copy->>'screen_title',
      'has_account', false, 'any_on', false,
      'off_title', v_copy->>'off_title', 'off_note', v_copy->>'off_note');
  end if;

  v_tier    := public.loyalty_tier_for(v_cust);
  v_targets := public._loy_targets(v_cust);
  v_streak  := public._loy_streak(v_cust);

  v_pts := public.loyalty_points_balance(v_cust);
  select config into v_cfg from loyalty_program where key = 'points';
  v_inr := coalesce((v_cfg->>'inr_per_point')::numeric, 0);
  v_min := coalesce((v_cfg->>'min_redeem_points')::numeric, 0);

  -- #461/#168: a redemption must not discount an MRP-based total.
  v_basis    := public._loy_trade_basis();
  v_basis_ok := coalesce((v_basis->>'has')::boolean, false);
  v_can      := (v_pts >= v_min and v_min > 0 and v_inr > 0 and v_pts > 0 and v_basis_ok);

  v_any := coalesce((v_tier->>'on')::boolean,false)
        or public._loy_active('points')
        or jsonb_array_length(v_targets) > 0
        or coalesce((v_streak->>'on')::boolean,false)
        or public._loy_active('referral');

  return jsonb_build_object(
    'ok', true,
    'title', v_copy->>'screen_title',
    'has_account', true,
    'any_on', v_any,
    'off_title', v_copy->>'off_title',
    'off_note',  v_copy->>'off_note',
    'tier', v_tier,
    'trade_basis', v_basis,
    'points', case when public._loy_active('points') then jsonb_build_object(
        'on', true,
        'title', v_copy->>'points_title',
        'balance', v_pts,
        'balance_label', public._loy_fmt('points_balance', jsonb_build_object('points', v_pts::int::text)),
        'worth_label',   public._loy_fmt('points_worth',   jsonb_build_object('amount', public.inr_money(v_pts * v_inr))),
        'min_label',     case when v_min > 0 then public._loy_fmt('points_min',
                                jsonb_build_object('points', v_min::int::text)) else '' end,
        'redeem_label',  v_copy->>'points_redeem',
        'can_redeem',    v_can,
        'blocked_note',  case when not v_basis_ok and v_pts > 0
                              then coalesce(v_copy->>'points_redeem_blocked','') else '' end,
        'empty_note',    v_copy->>'points_none')
      else jsonb_build_object('on', false) end,
    'targets', jsonb_build_object(
        'on', (jsonb_array_length(v_targets) > 0),
        'title', v_copy->>'target_title',
        'items', v_targets),
    'streak', v_streak,
    'referral', case when public._loy_active('referral') then jsonb_build_object(
        'on', true,
        'title', v_copy->>'referral_title',
        'code_label', v_copy->>'referral_code',
        'code', public.loyalty_referral_code(),
        'note', v_copy->>'referral_note')
      else jsonb_build_object('on', false) end,
    'empty_note', v_copy->>'empty_note');
end $function$;

-- The cart's own view of the tier benefit: does it apply to THIS basket?
create or replace function public.cart_rewards_block(p_customer uuid, p_margin jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tier jsonb; v_cur jsonb; v_copy jsonb := public._loy_copy();
  v_cart_ready int := coalesce((p_margin->>'ready_count')::int, 0);
  v_applies boolean;
begin
  if p_customer is null then return jsonb_build_object('has', false); end if;
  v_tier := public.loyalty_tier_for(p_customer);
  if not coalesce((v_tier->>'on')::boolean, false)
     or not coalesce((v_tier->>'has')::boolean, false) then
    return jsonb_build_object('has', false);
  end if;

  v_cur := v_tier->'current';
  -- A margin benefit needs trade-priced lines IN THIS CART, not merely in the
  -- catalogue. Anything else (a flat benefit) applies to the order as a whole.
  v_applies := case when (v_cur->>'benefit_kind') = 'margin_pct'
                    then v_cart_ready > 0
                    else true end;

  return jsonb_build_object(
    'has',             true,
    'tier_label',      coalesce(v_tier->>'current_label',''),
    'benefit_kind',    coalesce(v_cur->>'benefit_kind',''),
    'benefit_value',   coalesce(v_cur->>'benefit_value',''),
    'benefit_applies', v_applies,
    'note',            case when v_applies
                            then coalesce(v_copy->>'benefit_margin_note','')
                            else coalesce(v_copy->>'benefit_pending_note','') end,
    'tone',            case when v_applies
                            then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
                            else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end);
end $function$;

grant execute on function public.cart_rewards_block(uuid, jsonb) to authenticated;
grant execute on function public._loy_trade_basis() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- #169 — Supplier schemes existed in code with no data and no way to file one.
-- supplier_schemes had 0 rows; cart_apply_schemes(), cart_scheme_nudge() and
-- the card fields has_scheme / scheme_badge / scheme_text / scheme_expiry /
-- scheme_effective were all live and all empty, so no card had ever shown a
-- scheme. Free goods (10+2, 5+1) are the primary commercial lever in pharma
-- distribution. Suppliers can now file one with validity dates, and a LIVE
-- scheme flows into medicine_pricing.scheme_* — the fields the card already reads.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.supplier_schemes
  add column if not exists valid_from date,
  add column if not exists valid_to   date,
  add column if not exists updated_at timestamptz default now();

create index if not exists supplier_schemes_live_idx
  on public.supplier_schemes (product_id, active);

-- A scheme is live when it is active and today sits inside its window.
create or replace function public.scheme_is_live(p_active boolean, p_from date, p_to date)
returns boolean
language sql
immutable
as $function$
  select coalesce(p_active, false)
     and (p_from is null or p_from <= (now() at time zone 'Asia/Kolkata')::date)
     and (p_to   is null or p_to   >= (now() at time zone 'Asia/Kolkata')::date);
$function$;

insert into public.ui_copy(key, value) values
  ('scheme.free_goods_text',  to_jsonb('{buy}+{free} FREE'::text)),
  ('scheme.discount_text',    to_jsonb('{pct}% off'::text)),
  ('scheme.special_text',     to_jsonb('Special rate {amount}'::text)),
  ('scheme.list_title',       to_jsonb('Schemes'::text)),
  ('scheme.list_empty',       to_jsonb('No schemes filed yet. File a 10+2 or a flat discount and it shows on the buyer''s card.'::text)),
  ('scheme.filed_toast',      to_jsonb('Scheme saved'::text)),
  ('scheme.removed_toast',    to_jsonb('Scheme removed'::text)),
  ('scheme.expired_chip',     to_jsonb('Expired'::text)),
  ('scheme.scheduled_chip',   to_jsonb('Scheduled'::text)),
  ('scheme.live_chip',        to_jsonb('Live'::text))
on conflict (key) do nothing;

-- Push every LIVE scheme onto medicine_pricing, the row _pricing_block reads.
create or replace function public.scheme_sync_product(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s public.supplier_schemes%rowtype; v_text text;
begin
  if p_product_id is null then return jsonb_build_object('ok', false); end if;

  select * into s
    from public.supplier_schemes
   where product_id = p_product_id
     and public.scheme_is_live(active, valid_from, valid_to)
   order by (scheme_type = 'free_goods') desc, updated_at desc nulls last
   limit 1;

  if s.id is null then
    update public.medicine_pricing
       set scheme_ready = false, scheme_text = null,
           scheme_buy_qty = null, scheme_free_qty = null,
           scheme_type = null, scheme_pct = null,
           scheme_starts_at = null, scheme_ends_at = null
     where product_id = p_product_id;
    update "MEDICINE" set has_scheme = false where id = p_product_id;
    return jsonb_build_object('ok', true, 'live', false, 'product_id', p_product_id);
  end if;

  v_text := case s.scheme_type
    when 'free_goods'   then public._cf('scheme.free_goods_text', jsonb_build_object(
                               'buy',  coalesce(s.order_qty,0)::int::text,
                               'free', coalesce(s.free_qty,0)::int::text))
    when 'discount_pct' then public._cf('scheme.discount_text', jsonb_build_object(
                               'pct', trim(to_char(coalesce(s.discount_pct,0),'FM999990.##'))))
    else                     public._cf('scheme.special_text', jsonb_build_object(
                               'amount', public.inr_money(coalesce(s.special_price,0)))) end;

  insert into public.medicine_pricing as mp (product_id, scheme_ready, scheme_text,
      scheme_buy_qty, scheme_free_qty, scheme_type, scheme_pct,
      scheme_starts_at, scheme_ends_at)
  values (p_product_id,
      (s.scheme_type = 'free_goods'
        and coalesce(s.order_qty,0) > 0 and coalesce(s.free_qty,0) > 0),
      v_text, s.order_qty, s.free_qty, s.scheme_type, s.discount_pct,
      s.valid_from::timestamptz, (s.valid_to + 1)::timestamptz)
  on conflict (product_id) do update set
      scheme_ready     = excluded.scheme_ready,
      scheme_text      = excluded.scheme_text,
      scheme_buy_qty   = excluded.scheme_buy_qty,
      scheme_free_qty  = excluded.scheme_free_qty,
      scheme_type      = excluded.scheme_type,
      scheme_pct       = excluded.scheme_pct,
      scheme_starts_at = excluded.scheme_starts_at,
      scheme_ends_at   = excluded.scheme_ends_at;

  update "MEDICINE" set has_scheme = true where id = p_product_id;

  return jsonb_build_object('ok', true, 'live', true,
    'product_id', p_product_id, 'scheme_text', v_text);
end $function$;

-- Filing surface for the supplier: save / list / remove, validity included.
create or replace function public.supplier_scheme_save(
  p_id bigint, p_product_id bigint, p_product_name text, p_scheme_type text,
  p_order_qty numeric, p_free_qty numeric, p_discount_pct numeric,
  p_special_price numeric, p_valid_from date, p_valid_to date, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_sp supplier_profiles%rowtype; v_id bigint;
begin
  select * into v_sp from current_supplier_profile();
  if v_sp.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier');
  end if;
  if coalesce(p_scheme_type,'') not in ('free_goods','discount_pct','special_price') then
    return jsonb_build_object('ok', false, 'error', 'invalid_scheme_type');
  end if;
  if p_product_id is null then
    return jsonb_build_object('ok', false, 'error', 'product_required');
  end if;
  if p_valid_from is not null and p_valid_to is not null and p_valid_to < p_valid_from then
    return jsonb_build_object('ok', false, 'error', 'invalid_window');
  end if;
  if p_scheme_type = 'free_goods'
     and (coalesce(p_order_qty,0) <= 0 or coalesce(p_free_qty,0) <= 0) then
    return jsonb_build_object('ok', false, 'error', 'qty_required');
  end if;

  if p_id is not null then
    update public.supplier_schemes
       set product_id = p_product_id, product_name = p_product_name,
           scheme_type = p_scheme_type, order_qty = p_order_qty, free_qty = p_free_qty,
           discount_pct = p_discount_pct, special_price = p_special_price,
           valid_from = p_valid_from, valid_to = p_valid_to,
           active = coalesce(p_active, true), updated_at = now()
     where id = p_id and supplier_id = v_sp.id
     returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
  else
    insert into public.supplier_schemes (supplier_id, product_id, product_name,
        scheme_type, order_qty, free_qty, discount_pct, special_price,
        valid_from, valid_to, active, updated_at)
    values (v_sp.id, p_product_id, p_product_name, p_scheme_type, p_order_qty,
        p_free_qty, p_discount_pct, p_special_price, p_valid_from, p_valid_to,
        coalesce(p_active, true), now())
    on conflict (supplier_id, product_id, scheme_type) do update set
        product_name = excluded.product_name, order_qty = excluded.order_qty,
        free_qty = excluded.free_qty, discount_pct = excluded.discount_pct,
        special_price = excluded.special_price, valid_from = excluded.valid_from,
        valid_to = excluded.valid_to, active = excluded.active, updated_at = now()
    returning id into v_id;
  end if;

  perform public.scheme_sync_product(p_product_id);
  return jsonb_build_object('ok', true, 'id', v_id,
           'toast', public._c('scheme.filed_toast'));
end $function$;

create or replace function public.supplier_scheme_delete(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_sp supplier_profiles%rowtype; v_pid bigint;
begin
  select * into v_sp from current_supplier_profile();
  if v_sp.id is null then return jsonb_build_object('ok', false, 'error', 'not_supplier'); end if;
  delete from public.supplier_schemes where id = p_id and supplier_id = v_sp.id
    returning product_id into v_pid;
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  perform public.scheme_sync_product(v_pid);
  return jsonb_build_object('ok', true, 'toast', public._c('scheme.removed_toast'));
end $function$;

create or replace function public.supplier_schemes_list()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_sp supplier_profiles%rowtype; v_rows jsonb;
begin
  select * into v_sp from current_supplier_profile();
  if v_sp.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier',
             'title', public._c('scheme.list_title'), 'rows', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'product_id', s.product_id,
    'product_name', coalesce(nullif(btrim(coalesce(s.product_name,'')),''), m.product_name, ''),
    'scheme_type', s.scheme_type,
    'order_qty', s.order_qty,
    'free_qty', s.free_qty,
    'discount_pct', s.discount_pct,
    'special_price', s.special_price,
    'valid_from', s.valid_from,
    'valid_to', s.valid_to,
    'active', s.active,
    'text', case s.scheme_type
      when 'free_goods'   then public._cf('scheme.free_goods_text', jsonb_build_object(
                                 'buy', coalesce(s.order_qty,0)::int::text,
                                 'free', coalesce(s.free_qty,0)::int::text))
      when 'discount_pct' then public._cf('scheme.discount_text', jsonb_build_object(
                                 'pct', trim(to_char(coalesce(s.discount_pct,0),'FM999990.##'))))
      else                     public._cf('scheme.special_text', jsonb_build_object(
                                 'amount', public.inr_money(coalesce(s.special_price,0)))) end,
    'window_label', case
      when s.valid_from is null and s.valid_to is null then ''
      when s.valid_to is null then to_char(s.valid_from,'DD Mon YYYY') || ' →'
      when s.valid_from is null then '→ ' || to_char(s.valid_to,'DD Mon YYYY')
      else to_char(s.valid_from,'DD Mon YYYY') || ' → ' || to_char(s.valid_to,'DD Mon YYYY') end,
    'state', case
      when not coalesce(s.active,false) then 'off'
      when s.valid_to is not null and s.valid_to < (now() at time zone 'Asia/Kolkata')::date then 'expired'
      when s.valid_from is not null and s.valid_from > (now() at time zone 'Asia/Kolkata')::date then 'scheduled'
      else 'live' end,
    'state_label', case
      when not coalesce(s.active,false) then public._c('scheme.expired_chip')
      when s.valid_to is not null and s.valid_to < (now() at time zone 'Asia/Kolkata')::date then public._c('scheme.expired_chip')
      when s.valid_from is not null and s.valid_from > (now() at time zone 'Asia/Kolkata')::date then public._c('scheme.scheduled_chip')
      else public._c('scheme.live_chip') end,
    'state_tone', case
      when public.scheme_is_live(s.active, s.valid_from, s.valid_to)
        then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
      when coalesce(s.active,false) and s.valid_from > (now() at time zone 'Asia/Kolkata')::date
        then jsonb_build_object('bg','#EFF6FF','fg','#1E40AF')
      else jsonb_build_object('bg','#FEE2E2','fg','#991B1B') end)
    order by s.updated_at desc nulls last, s.id desc), '[]'::jsonb)
    into v_rows
  from public.supplier_schemes s
  left join "MEDICINE" m on m.id = s.product_id
  where s.supplier_id = v_sp.id;

  return jsonb_build_object('ok', true,
    'title', public._c('scheme.list_title'),
    'empty_note', public._c('scheme.list_empty'),
    'count', jsonb_array_length(v_rows),
    'rows', v_rows);
end $function$;

grant execute on function public.supplier_scheme_save(bigint,bigint,text,text,numeric,numeric,numeric,numeric,date,date,boolean) to authenticated;
grant execute on function public.supplier_scheme_delete(bigint) to authenticated;
grant execute on function public.supplier_schemes_list() to authenticated;
grant execute on function public.scheme_sync_product(bigint) to authenticated;
grant execute on function public.scheme_is_live(boolean,date,date) to authenticated, anon;

-- A scheme that lapses overnight must stop showing. One row on the dispatcher,
-- never a bare */N schedule (the connection-exhaustion lesson).
create or replace function public.scheme_expiry_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int := 0; r record;
begin
  for r in
    select distinct mp.product_id
      from public.medicine_pricing mp
     where (mp.scheme_ready or mp.scheme_text is not null)
       and not exists (
         select 1 from public.supplier_schemes s
          where s.product_id = mp.product_id
            and public.scheme_is_live(s.active, s.valid_from, s.valid_to))
  loop
    perform public.scheme_sync_product(r.product_id);
    v_n := v_n + 1;
  end loop;

  for r in
    select distinct s.product_id
      from public.supplier_schemes s
     where public.scheme_is_live(s.active, s.valid_from, s.valid_to)
       and not exists (select 1 from public.medicine_pricing mp
                        where mp.product_id = s.product_id and mp.scheme_ready)
  loop
    perform public.scheme_sync_product(r.product_id);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'synced', v_n);
end $function$;

-- Once a day at 02:10 IST, off the one dispatcher. Never a bare */N schedule.
insert into public.cron_task (name, ord, mode, work_sql, note, run_at_ist, dml, enabled)
values ('scheme_expiry_sweep', 610, 'poll',
        'select public.scheme_expiry_sweep()',
        'CHANGE #461: a lapsed supplier scheme stops showing on the buyer''s card.',
        '02:10', true, true)
on conflict (name) do update set
  work_sql   = excluded.work_sql,
  note       = excluded.note,
  run_at_ist = excluded.run_at_ist,
  mode       = excluded.mode,
  dml        = excluded.dml,
  enabled    = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- #170 (cont.) — the Rx class reaches the CARD and the PDP.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._sf_cards(p_ids bigint[])
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'pack_qty_display', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_size_display', coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),'')),
    'pack_type', m.pack_type,
    'pack_qty', m.pack_qty,
    'pack_size', m.pack_size,
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false) then 'Scheme available' else '' end,
    -- CHANGE #461/#170: the prescription class, from "MEDICINE".rx_required.
    'rx', public.rx_badge(m.rx_required),
    'availability', public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0))),
    'pricing', public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id),
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  where lower(coalesce(m.buyable::text,'')) in ('true','t');
$function$;

-- The PDP is one RPC printed verbatim, so the Rx block is added by wrapping the
-- existing implementation rather than by re-typing 154 lines of it. The rename
-- runs once; re-applying this migration finds the core already renamed.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = '_product_detail_core')
  then
    alter function public.product_detail(bigint) rename to _product_detail_core;
  end if;
end $$;

create or replace function public.product_detail(p_product_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v jsonb; v_rx text;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;
  -- CHANGE #461/#170: the prescription class, and (for a signed-in pharmacy)
  -- whether their drug licence is on file for it.
  -- header.rx_required was FALSE on every product, including a product whose
  -- "MEDICINE".rx_required reads 'Rx' — which is why the PDP's existing
  -- _RxBanner had never once fired. It is now the column's own answer.
  return v
    || jsonb_build_object('header',
         coalesce(v->'header','{}'::jsonb)
         || jsonb_build_object('rx_required',
              (upper(btrim(coalesce(v_rx,''))) = 'RX')))
    || jsonb_build_object(
    'rx',         public.rx_badge(v_rx),
    'rx_licence', case when upper(btrim(coalesce(v_rx,''))) = 'RX'
                            and public.my_customer_id() is not null
                       then public.rx_licence_state(public.my_customer_id())
                       else jsonb_build_object('has', true, 'reason', 'n/a') end);
end $function$;

grant execute on function public.product_detail(bigint) to authenticated, anon;
grant execute on function public._product_detail_core(bigint) to authenticated, anon;
grant execute on function public.rx_badge(text) to authenticated, anon;

-- The redeem path must agree with can_redeem: no trade-priced basis, no
-- redemption. Otherwise the button is disabled and the RPC still says yes.
create or replace function public.loyalty_redeem(p_points numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cust uuid := public.my_customer_id(); v_cfg jsonb;
        v_bal numeric; v_min numeric; v_inr numeric; v_amt numeric;
begin
  if v_cust is null then return jsonb_build_object('ok', false, 'error', 'no_customer'); end if;
  if not public._loy_active('points') then
    return jsonb_build_object('ok', false, 'error', 'points_off');
  end if;

  -- CHANGE #461/#168
  if not coalesce((public._loy_trade_basis()->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'no_trade_basis',
      'message', coalesce(public._loy_copy()->>'points_redeem_blocked',''));
  end if;

  select config into v_cfg from loyalty_program where key = 'points';
  v_min := coalesce((v_cfg->>'min_redeem_points')::numeric, 0);
  v_inr := coalesce((v_cfg->>'inr_per_point')::numeric, 0);
  v_bal := public.loyalty_points_balance(v_cust);

  if coalesce(p_points,0) <= 0 or p_points > v_bal then
    return jsonb_build_object('ok', false, 'error', 'bad_amount',
      'message', public._loy_fmt('points_balance', jsonb_build_object('points', v_bal::int::text)));
  end if;
  if p_points < v_min then
    return jsonb_build_object('ok', false, 'error', 'below_min',
      'message', public._loy_fmt('points_min', jsonb_build_object('points', v_min::int::text)));
  end if;

  v_amt := round(p_points * v_inr, 2);
  insert into loyalty_ledger(customer_id, kind, points, amount_inr, note, idem_key)
  values (v_cust, 'points_redeemed', p_points, 0, 'redeem',
          'redeem:'||v_cust::text||':'||extract(epoch from clock_timestamp())::bigint::text);
  insert into loyalty_ledger(customer_id, kind, points, amount_inr, note, idem_key)
  values (v_cust, 'credit', 0, v_amt, 'redeem',
          'redeemcr:'||v_cust::text||':'||extract(epoch from clock_timestamp())::bigint::text);

  return jsonb_build_object('ok', true, 'redeemed_points', p_points,
    'credit_amount', v_amt, 'credit_label', public.inr_money(v_amt),
    'rewards', public.loyalty_my_rewards());
end $function$;

-- Plural forms are the BACKEND's job, never Dart's — and never "item(s)".
insert into public.ui_copy(key, value) values
  ('rx.licence_missing_msg_one',  to_jsonb('Add your 20B/21B drug licence to your profile to order prescription medicines. 1 item in your cart needs it.'::text)),
  ('rx.licence_missing_msg_many', to_jsonb('Add your 20B/21B drug licence to your profile to order prescription medicines. {count} items in your cart need it.'::text)),
  ('rx.cart_rx_note_one',         to_jsonb('1 prescription item in this order'::text)),
  ('rx.cart_rx_note_many',        to_jsonb('{count} prescription items in this order'::text))
on conflict (key) do nothing;

create or replace function public.cart_rx_gate(p_customer uuid, p_items jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_rx   int := 0;
  v_lic  jsonb := public.rx_licence_state(p_customer);
  v_block boolean;
  v_title text := ''; v_msg text := '';
begin
  select count(*) into v_rx
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) it
    join "MEDICINE" m on m.id = nullif(it->>'product_id','')::bigint
   where upper(btrim(coalesce(m.rx_required,''))) = 'RX';

  if v_rx > 0 and not coalesce((v_lic->>'has')::boolean, false) then
    if (v_lic->>'reason') = 'expired' then
      v_title := public._c('rx.licence_expired_title');
      v_msg   := public._cf('rx.licence_expired_msg',
                   jsonb_build_object('date', to_char((v_lic->>'expiry')::date, 'DD Mon YYYY')));
    else
      v_title := public._c('rx.licence_missing_title');
      v_msg   := case when v_rx = 1
                      then public._c('rx.licence_missing_msg_one')
                      else public._cf('rx.licence_missing_msg_many',
                             jsonb_build_object('count', v_rx::text)) end;
    end if;
  end if;

  v_block := (v_rx > 0)
             and not coalesce((v_lic->>'has')::boolean, false)
             and coalesce((v_lic->>'enforced')::boolean, false);

  return jsonb_build_object(
    'has',        (v_rx > 0),
    'rx_count',   v_rx,
    'rx_note',    case when v_rx = 0 then ''
                       when v_rx = 1 then public._c('rx.cart_rx_note_one')
                       else public._cf('rx.cart_rx_note_many',
                              jsonb_build_object('count', v_rx::text)) end,
    'licence',    v_lic,
    'can_order',  not v_block,
    'blocked',    v_block,
    'is_warning', (v_msg <> '' and not v_block),
    'title',      v_title,
    'message',    v_msg,
    'tone',       case when v_block then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
                       when v_msg <> '' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end $function$;

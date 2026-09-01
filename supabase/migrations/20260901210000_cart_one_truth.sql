-- CHANGE #572 — Cart cleanup: one price truth, one summary line, one notice,
-- honest CTA.
--
-- The customer cart printed "Awaiting supplier rates" FOUR times (the summary
-- line, the big amount, the Net payable row and the Total payable row), put a
-- bold ₹260.38 directly above "2 items not priced yet", stacked two amber
-- notices and offered "Pay & Place Order" when nothing was payable.
--
-- Every one of those is a BACKEND decision, so every one of them is fixed
-- here. cart_render() now returns three ready blocks the client only prints:
--   render.summary  — one line, one optional amount, and the totals ladder
--                     (Net payable / Delivery / Total payable) ONLY when an
--                     amount actually exists. Delivery stays, always.
--   render.notice   — THE one notice (the drug-licence gate), with its inline
--                     action. The Platinum note is no longer offered to the
--                     cart at all.
--   render.cta      — the button's own label and enabled state.
-- and every item carries price_line / price_note: one price truth per line,
-- never a number above "not priced yet".

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cart.line_rate_pending',        to_jsonb('MRP {mrp} · trade rate on confirmation'::text)),
  ('cart.line_rate_pending_no_mrp', to_jsonb('Trade rate on confirmation'::text)),
  ('cart.summary_pending',          to_jsonb('{items} · rate confirmed after supplier quote'::text)),
  ('cart.summary_partial',          to_jsonb('{items} · {pending} awaiting supplier quote'::text)),
  ('cart.summary_priced',           to_jsonb('{items}'::text)),
  ('cart.cta_place',                to_jsonb('Place order'::text)),
  ('cart.cta_pay_place',            to_jsonb('Pay & place order'::text)),
  ('cart.notice_add_licence',       to_jsonb('Add licence'::text)),
  ('cart.notice_renew_licence',     to_jsonb('Renew licence'::text))
on conflict (key) do update set value = excluded.value;

-- ── 2. The drug licence becomes addable ─────────────────────────────────────
-- The cart's notice now carries an "Add licence" action that opens the profile
-- field. That action would be a lie against a field the catalogue locks, so a
-- licence the customer has NOT got on file is editable; one already on file
-- still needs support to change. One rule, read by the form and by the save.
create or replace function public._cust_field_editable(p_key text, p_cust uuid)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select case
           when f.editable then true
           when f.key in ('dl_20b','dl_21b')
             then pp.id is not null and coalesce(btrim((to_jsonb(pp))->>f.key), '') = ''
           else false
         end
    from public.customer_profile_field f
    left join public.pharmacy_profiles pp on pp.id = p_cust
   where f.key = p_key;
$$;

create or replace function public.my_profile_edit()
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare v_cust uuid := public.my_customer_id(); pp pharmacy_profiles%rowtype; v jsonb;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer',
      'message', public._cust_uic('cust_profile.not_customer','This account does not have a customer profile yet.'));
  end if;
  select * into pp from pharmacy_profiles where id = v_cust;
  v := to_jsonb(pp);

  return jsonb_build_object(
    'ok', true,
    'title',       public._cust_uic('cust_profile.edit_title','Edit profile'),
    'note',        public._cust_uic('cust_profile.edit_note',''),
    'save_label',  public._cust_uic('cust_profile.save','Save changes'),
    'locked_chip', public._cust_uic('cust_profile.locked_chip','Verified'),
    'sections', (
      select coalesce(jsonb_agg(sec order by sec_ord), '[]'::jsonb) from (
        select f.section_key, min(f.ord) as sec_ord,
               jsonb_build_object(
                 'key', f.section_key,
                 'title', min(f.section_label),
                 'fields', jsonb_agg(jsonb_build_object(
                    'key', f.key, 'label', f.label, 'hint', f.hint,
                    'input_type', f.input_type,
                    'editable', public._cust_field_editable(f.key, v_cust),
                    'locked_note', case when public._cust_field_editable(f.key, v_cust)
                                        then '' else f.locked_note end,
                    'required', f.required,
                    'max_len', f.max_len,
                    'value', coalesce(v->>f.key, '')) order by f.ord)) as sec
          from public.customer_profile_field f
         group by f.section_key) q));
end $$;

create or replace function public.my_profile_save(p jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_cust uuid := public.my_customer_id();
  r record; v_new text; v_changed int := 0; v_hit int; v_err text;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer',
      'message', public._cust_uic('cust_profile.not_customer','This account does not have a customer profile yet.'));
  end if;

  -- Validate against the SAME table AND the SAME editability rule the form was
  -- drawn from, so a rule can never be true on one side and false on the other.
  for r in select * from public.customer_profile_field order by ord loop
    if not public._cust_field_editable(r.key, v_cust) then continue; end if;
    if not (p ? r.key) then continue; end if;
    v_new := btrim(coalesce(p->>r.key, ''));

    if r.required and v_new = '' then
      return jsonb_build_object('ok', false, 'error', 'required',
        'message', replace(public._cust_uic('cust_profile.required_error','{field} is required.'), '{field}', r.label));
    end if;
    if r.key = 'pincode' and v_new <> '' and v_new !~ '^[0-9]{6}$' then
      return jsonb_build_object('ok', false, 'error', 'bad_pincode',
        'message', public._cust_uic('cust_profile.pincode_error','PIN code must be 6 digits.'));
    end if;
    if r.input_type = 'phone' and v_new <> '' and length(regexp_replace(v_new,'[^0-9]','','g')) < 10 then
      return jsonb_build_object('ok', false, 'error', 'bad_phone',
        'message', public._cust_uic('cust_profile.phone_error','Enter a 10-digit mobile number.'));
    end if;
    if length(v_new) > r.max_len then
      v_new := left(v_new, r.max_len);
    end if;

    execute format('update public.pharmacy_profiles set %I = $1 where id = $2 and coalesce(%I,'''') is distinct from $1', r.key, r.key)
      using v_new, v_cust;
    get diagnostics v_hit = row_count;
    v_changed := v_changed + v_hit;

    if r.key = 'address_local' then
      update public.pharmacy_profiles set address = v_new where id = v_cust;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'changed', v_changed,
    'message', case when v_changed > 0
                 then public._cust_uic('cust_profile.saved','Profile updated.')
                 else public._cust_uic('cust_profile.no_change','Nothing changed.') end,
    'session', public.my_session());
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('ok', false, 'error', 'save_failed', 'message', v_err);
end $$;

-- ── 3. The one notice ───────────────────────────────────────────────────────
-- The cart shows AT MOST one notice, and the backend picks it. The tier
-- benefit note ("Nothing in the catalogue is trade-priced for you yet") reads
-- as a defect on a basket that is simply awaiting quotes, so it is not
-- offered here at all; it belongs where the benefit actually applies.
create or replace function public.cart_notice_block(p_rx jsonb)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_msg    text    := coalesce(p_rx->>'message','');
  v_reason text    := coalesce(p_rx->'licence'->>'reason','');
  v_block  boolean := coalesce((p_rx->>'blocked')::boolean, false);
  v_label  text;
begin
  if v_msg = '' then
    return jsonb_build_object('has', false, 'blocking', false,
      'title', '', 'message', '', 'action', jsonb_build_object('has', false));
  end if;

  v_label := case when v_reason = 'expired'
                  then public._c('cart.notice_renew_licence')
                  else public._c('cart.notice_add_licence') end;

  return jsonb_build_object(
    'has',      true,
    'blocking', v_block,
    'kind',     'drug_licence',
    'title',    coalesce(p_rx->>'title',''),
    'message',  v_msg,
    'tone',     coalesce(p_rx->'tone', jsonb_build_object('bg','#FEF3C7','fg','#92400E')),
    'action',   jsonb_build_object(
                  'has',   (v_label <> ''),
                  'label', v_label,
                  'kind',  'profile_edit',
                  'field', 'dl_20b',
                  'section', 'licence'));
end $$;

-- ── 4. The honest CTA ───────────────────────────────────────────────────────
-- "Pay & place order" is a promise about money. It may only be made when an
-- amount exists. Same branch checkout_action() uses for pay_now, AND a payable
-- basket.
create or replace function public.cart_cta_block(p_payable boolean, p_blocked boolean)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_mode  text := 'manual';
  v_act   uuid;
  v_role  text := 'none';
  v_staff boolean;
  v_pay   boolean;
begin
  -- The cart renders for guests too. A branch that cannot be resolved is not a
  -- reason to fail the whole payload: it falls back to the plain "Place order".
  begin
    v_mode := coalesce(public.payment_collection_mode(), 'manual');
    v_act  := public.my_acting_as();
    v_role := coalesce(public.get_my_role(), 'none');
  exception when others then
    v_mode := 'manual'; v_act := null; v_role := 'none';
  end;
  v_staff := v_role in ('admin','super_admin','worker');
  v_pay := coalesce(p_payable,false) and (v_mode = 'gateway') and v_act is null and not v_staff;
  return jsonb_build_object(
    'payable',  coalesce(p_payable,false),
    'pay_now',  v_pay,
    'enabled',  not coalesce(p_blocked,false),
    'label',    case when v_pay then public._c('cart.cta_pay_place')
                     else public._c('cart.cta_place') end);
end $$;

-- ── 5. The summary block ────────────────────────────────────────────────────
-- ONE line. The Net payable / Total payable ladder exists only while an amount
-- does; Delivery is always there because it is the only true number on an
-- unpriced basket.
create or replace function public.cart_summary_block(p_pricing jsonb, p_delivery jsonb,
                                                     p_items_label text, p_grand_display text)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_net      numeric := coalesce((p_pricing->>'net_payable')::numeric, 0);
  v_unpriced int     := coalesce((p_pricing->>'unpriced_count')::int, 0);
  v_priced   int     := coalesce((p_pricing->>'priced_count')::int, 0);
  v_has      boolean := (v_net > 0);
  v_rows     jsonb   := '[]'::jsonb;
  v_line     text;
begin
  if not v_has then
    v_line := public._cf('cart.summary_pending', jsonb_build_object('items', p_items_label));
  elsif v_unpriced > 0 then
    v_line := public._cf('cart.summary_partial',
                jsonb_build_object('items', p_items_label, 'pending', v_unpriced::text));
  else
    v_line := public._cf('cart.summary_priced', jsonb_build_object('items', p_items_label));
  end if;

  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','net','label', coalesce(p_pricing->>'net_payable_label','Net payable'),
      'amount', coalesce(p_pricing->>'net_payable_display',''), 'strong', false));
  end if;

  if coalesce((p_delivery->>'has')::boolean, false) then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','delivery','label', coalesce(p_delivery->>'label',''),
      'amount', coalesce(p_delivery->>'amount_display',''), 'strong', false));
    if coalesce((p_delivery->>'has_gst')::boolean, false) then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'key','delivery_gst','label', coalesce(p_delivery->>'gst_label',''),
        'amount', coalesce(p_delivery->>'gst_display',''), 'strong', false));
    end if;
  end if;

  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','grand','label', public._c('cart.grand_total_label'),
      'amount', p_grand_display, 'strong', true));
  end if;

  return jsonb_build_object(
    'line',           v_line,
    'has_amount',     v_has,
    'amount_display', case when v_has then coalesce(p_pricing->>'net_payable_display','') else '' end,
    'priced_count',   v_priced,
    'unpriced_count', v_unpriced,
    'rows',           v_rows);
end $$;

-- ── 6. cart_render's core, rebuilt around those three blocks ────────────────
create or replace function public._cart_render_core(p_guest_uid uuid DEFAULT NULL::uuid)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
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
  v_notice jsonb;
  v_summary jsonb;
  v_cta jsonb;
  v_grand numeric;
  v_grand_display text;
  v_unpriced_line text := coalesce((select value from storefront_ui_label where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
  v_no_mrp text := coalesce((select value from storefront_ui_label where key='cart_no_mrp_note'),
                            'MRP not printed on this pack');
begin
  -- ONE PRICE TRUTH PER LINE.
  -- price_line is the bold amount and price_note the caption under it. A line
  -- with no trade rate has NO bold amount at all: its MRP goes INSIDE the
  -- caption, so a rupee figure can never sit above the words that say the rate
  -- is not known yet.
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
                                       else (it->>'quantity') || ' × ' || v_unpriced_line end,
             'price_line',        case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then coalesce(nullif(tp->>'line_net_display',''),
                                                     public.inr_money(coalesce((tp->>'line_net')::numeric,0)))
                                       else '' end,
             'price_note',        case
                                    when coalesce((tp->>'has_trade_rate')::boolean, false)
                                      then (it->>'quantity') || ' × ' || (tp->>'price_display')
                                    when nullif(it->>'mrp','') is null
                                      then public._c('cart.line_rate_pending_no_mrp')
                                    else public._cf('cart.line_rate_pending',
                                           jsonb_build_object('mrp',
                                             public.inr_money(coalesce(nullif(it->>'line_mrp','')::numeric,
                                                                       nullif(it->>'mrp','')::numeric, 0))))
                                  end)
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
  v_delivery := public.delivery_charge_block(public.my_customer_id(), v_net);
  v_grand    := round(v_net + coalesce((v_delivery->>'total')::numeric, 0), 2);
  v_rx := public.cart_rx_gate(public.my_customer_id(), coalesce(v_cart->'items','[]'::jsonb));
  v_rewards := public.cart_rewards_block(public.my_customer_id(), v_margin);

  -- An amount exists or it does not. Everything below reads that one answer.
  v_grand_display := case when v_net > 0 then public.inr_money(v_grand) else '' end;

  v_notice  := public.cart_notice_block(v_rx);
  v_summary := public.cart_summary_block(v_pricing, v_delivery, v_items_label, v_grand_display);
  v_cta     := public.cart_cta_block((v_net > 0), not coalesce((v_rx->>'can_order')::boolean, true));

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
      -- #572 — the three blocks the cart screen actually renders.
      'summary',              v_summary,
      'notice',               v_notice,
      'cta',                  v_cta,
      'items_total',          v_net,
      'items_total_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'grand_total',          v_grand,
      'grand_total_display',  case when coalesce((v_delivery->>'total')::numeric,0) > 0
                                   then public.inr_money(v_grand)
                                   else coalesce(v_pricing->>'net_payable_display', '') end,
      'item_count',           v_lines,
      'unit_count',           v_units,
      'items_label',          v_items_label,
      -- The old subtotal_line said the same thing three times over. It is now
      -- the summary line and nothing else; cart_selected_total() (View As)
      -- keeps its own wording.
      'subtotal_line',        v_summary->>'line',
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
end $$;

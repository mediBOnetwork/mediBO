-- CMD #2162 — cart: CD strip rolls every 3 s, remove bar hides after 3 s,
-- Place order popup carries the selected mode as three lines, and the
-- receive box shows the advance note above the remaining-due note.
-- Idempotent: every statement is an upsert or CREATE OR REPLACE.

insert into public.ui_copy(key, value) values
  ('cart2.advance_note', to_jsonb('Pay advance now'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public.cart_undo_window_s()
 returns integer
 language sql
 immutable
 set search_path to 'public'
as $function$
  select 3
$function$;

CREATE OR REPLACE FUNCTION public._cart_v2_block(p_cart jsonb, p_cust uuid, p_zone smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                                   'interval_ms', 3000, 'slides', v_slides),
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
end $function$

;

CREATE OR REPLACE FUNCTION public._cart2_receive(p_cust uuid, p_zone smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'advance_note', public._c('cart2.advance_note'),
        'note', public._c('cart2.delivery_due')),
      'pickup', jsonb_build_object(
        'lead', public._c('cart2.collect_from'),
        'name', coalesce(v_part->>'name', ''),
        'address', coalesce(v_part->>'address', ''),
        'advance_note', public._c('cart2.advance_note'),
        'note', public._c('cart2.pickup_due'))));
end $function$

;

CREATE OR REPLACE FUNCTION public.cart_place_block()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      public._c('cart2.cancel'), 'dismiss')
      -- CMD #2162 — the SELECTED mode as three lines: title, green advance
      -- badge, orange remaining-due badge. The chip stays for older clients.
      || jsonb_build_object('mode', jsonb_build_object(
           'has', true,
           'key', v_mode,
           'icon', case when v_mode = 'pickup' then 'storefront' else 'local_shipping' end,
           'title', case when v_mode = 'pickup' then public._c('cart2.receive_pickup')
                         else public._c('cart2.receive_delivery') end,
           'advance_note', public._c('cart2.advance_note'),
           'note', case when v_mode = 'pickup' then public._c('cart2.pickup_due')
                        else public._c('cart2.delivery_due') end)),
    'payment_failed', public._cart2_popup('payment_failed', 'warning', 'warning',
      public._c('cart2.pop_payfail_title'), public._c('cart2.pop_payfail_body'), '',
      public._c('cart2.try_again'), 'retry', '', public._c('cart2.cancel'), 'dismiss'));
end $function$

;

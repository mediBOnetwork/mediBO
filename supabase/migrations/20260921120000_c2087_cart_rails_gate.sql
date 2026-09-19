-- CMD #2087 — Cart: full-width rails, "You may also like", a bill without the
-- advance row, no KYC chip above Place order, and ONE backend gate for the
-- Place order tap.
--
-- Everything the screen prints here is written in this file or in the tables it
-- seeds. The cart screen decides nothing: it asks cart_place_gate() on the tap
-- and renders whichever of the four answers comes back.

-- ── 1. The words ──────────────────────────────────────────────────────────
insert into public.storefront_ui_label(key, value, note) values
  ('cart_also_like_title', 'You may also like',
   'CMD #2087 — the second cart rail: order-history co-purchase for this basket.')
on conflict (key) do update set value = excluded.value,
                                note  = excluded.note,
                                updated_at = now();

insert into public.ui_copy(key, value) values
  ('cart.also_like_empty',   '"Nothing to suggest for this basket yet"'::jsonb),
  ('cart.gate_pending_title','"Account under verification"'::jsonb),
  ('cart.gate_pending_body',
   '"Your account is not approved yet — we are verifying your details"'::jsonb),
  ('cart.gate_pending_dismiss', '"OK"'::jsonb),
  ('cart.gate_login_cta',       '"Login"'::jsonb),
  ('cart.gate_register_cta',    '"Complete registration"'::jsonb),
  ('cart.gate_blocked_title',   '"Ordering is not available"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ── 2. The advance row leaves Bill details ────────────────────────────────
-- It is still printed above Place order, where the buyer is actually
-- committing to it (`summary.bottom`). Saying it twice, three centimetres
-- apart, is what this removes. Data, not code: an admin can put it back.
update public.cart_bill_row set visible = false where key = 'advance';

-- ── 3. "You may also like" — order-history co-purchase for this basket ────
-- product_copurchase is the same order-history evidence cart_companions()
-- reads; this block returns it as STOREFRONT CARDS so the rail is the same
-- CompactProductCard the wishlist rail and the catalogue grid draw.
-- Zone-scoped exactly as the companion rail is: the viewer's zone when that
-- zone has evidence, zone 0 otherwise.
create or replace function public.cart_also_like_block(
  p_zone_id smallint,
  p_cart_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ids   bigint[] := coalesce(p_cart_ids, '{}'::bigint[]);
  v_zone  smallint;
  v_use   smallint;
  v_disc  numeric;
  v_max   int := 10;
  v_items jsonb := '[]'::jsonb;
begin
  if array_length(v_ids, 1) is null then
    return jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb,
                              'empty_note', public._c('cart.also_like_empty'));
  end if;

  v_zone := coalesce(p_zone_id, public._viewer_zone_or_null(), public.my_zone_id());
  v_disc := public._c791_safe_discount_pct();

  if v_zone is not null and exists (
       select 1 from public.product_copurchase
        where product_id = any (v_ids) and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_support desc, x_id), '[]'::jsonb)
    into v_items
  from (
    select m.id as x_id, sum(c.support)::int as x_support,
           jsonb_build_object(
             'id',           m.id,
             'name',         coalesce(m.product_name, ''),
             'company',      coalesce(m.marketer, ''),
             'pack_label',   coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                                      nullif(btrim(coalesce(m.pack_size,'')),''), ''),
             'form_chip',    coalesce(nullif(btrim(coalesce(m.pack_qty,'')),''),
                                      nullif(btrim(coalesce(m.pack_size,'')),''), ''),
             'image',        coalesce(m.image_url_1, ''),
             'pricing',      public.storefront_pricing(
                               nullif(regexp_replace(coalesce(m.mrp::text,''),
                                      '[^0-9.]','','g'),'')::numeric,
                               v_disc, m.id),
             'availability', public.storefront_cta(
                               public.storefront_effective_count(m.id, m.supplier_count),
                               true)) as x
      from public.product_copurchase c
      join public."MEDICINE" m on m.id = c.companion_id
     where c.product_id = any (v_ids)
       and c.zone_id = v_use
       and not (c.companion_id = any (v_ids))
       and m.buyable is true
     group by m.id, m.product_name, m.marketer, m.pack_type, m.pack_size,
              m.pack_qty, m.image_url_1, m.mrp, m.supplier_count
     order by 2 desc, 1
     limit v_max
  ) s;

  return jsonb_build_object(
    'has',        jsonb_array_length(v_items) > 0,
    'title',      coalesce((select value from public.storefront_ui_label
                             where key = 'cart_also_like_title'), ''),
    'empty_note', public._c('cart.also_like_empty'),
    'zone_id',    v_use,
    'items',      v_items);
end
$function$;

revoke all on function public.cart_also_like_block(smallint, bigint[]) from public;
revoke all on function public.cart_also_like_block(smallint, bigint[]) from anon;
grant execute on function public.cart_also_like_block(smallint, bigint[]) to authenticated, service_role;

-- ── 4. The cart payload carries the second rail ───────────────────────────
create or replace function public._cart_bill_core(
  p_cart jsonb, p_cust uuid, p_zone smallint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
  v_rows    jsonb   := '[]'::jsonb;
  v_free    text    := public._c('cart.bill_free');
  v_ids     bigint[] := '{}'::bigint[];
  v_rail    jsonb;
  v_also    jsonb;
  r         record;
  v_amt     numeric;
  v_waived  boolean;
  v_ptr_ok  boolean := false;
  v_text    text;
begin
  p_cart := coalesce(p_cart, '{}'::jsonb);

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

  -- The advance is the SAME reading the bottom bar takes. The row it used to
  -- print in the card is hidden now (CMD #2087), but the VARIABLE stays: a
  -- zone can switch the row back on and a formula row may still reference it.
  begin
    v_adv     := public.advance_pct_for(p_cust, p_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv_amt := 0;
  end;

  begin
    v_ptr_ok := public._cart_ptr_complete(p_cart);
  exception when others then
    v_ptr_ok := false;
  end;

  v_vars := jsonb_build_object(
    'mrp_total',    v_mrp,
    'trade_total',  v_trade,
    'delivery_fee', v_deliv,
    'advance',      v_adv_amt,
    'item_count',   v_items,
    'unit_count',   v_units,
    'grand_total',  round(v_trade, 2),
    'fees_total',   0);

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
    v_waived := r.waived;

    v_text := case when r.fallback_when = 'ptr_incomplete' and not v_ptr_ok
                   then r.fallback_text else '' end;

    continue when v_text = '' and r.hide_when_zero and v_amt = 0 and not v_waived;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key',            r.key,
      'label',          r.label,
      'icon',           r.icon,
      'value',          case when v_text <> '' then v_text
                             when v_waived     then ''
                             else public.inr_money(v_amt) end,
      'is_text',        (v_text <> ''),
      'struck_value',   case when v_text = '' and v_waived
                             then public.inr_money(v_amt) else '' end,
      'free_label',     case when v_text = '' and v_waived then v_free else '' end,
      'waived',         (v_text = '' and v_waived),
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

  -- CMD #2087 — the second rail. It never throws the cart away: an absent
  -- co-purchase history is an absence, drawn as nothing.
  begin
    v_also := public.cart_also_like_block(p_zone, v_ids);
  exception when others then
    v_also := null;
  end;

  return jsonb_build_object(
    'bill', jsonb_build_object(
      'has',        jsonb_array_length(v_rows) > 0 and v_items > 0,
      'title',      public._c('cart.bill_title'),
      'empty_note', public._c('cart.bill_empty'),
      'ptr_complete', v_ptr_ok,
      'rows',       v_rows),
    'rail', coalesce(v_rail, jsonb_build_object(
      'has', false, 'title', '', 'items', '[]'::jsonb,
      'empty_note', public._c('cart.rail_empty'))),
    'also_like', coalesce(v_also, jsonb_build_object(
      'has', false, 'title', '', 'items', '[]'::jsonb,
      'empty_note', public._c('cart.also_like_empty'))));
end
$function$;

-- ── 5. No KYC chip above Place order ──────────────────────────────────────
-- CMD #1815 put a "licence not on file" chip and a View link directly above
-- Place order. It answers a question nobody is asking at the moment of
-- committing a basket, and the licence gate that DOES stop an order still
-- speaks for itself (the blocking notice below). The chip is dropped at the
-- source, so every surface reading render.notice loses it at once.
create or replace function public.cart_notice_block(p_rx jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_msg    text    := coalesce(p_rx->>'message','');
  v_reason text    := coalesce(p_rx->'licence'->>'reason','');
  v_block  boolean := coalesce((p_rx->>'blocked')::boolean, false);
  v_chip   jsonb   := jsonb_build_object('has', false);
  v_label  text;
begin
  if not v_block then
    return jsonb_build_object('has', false, 'blocking', false,
      'title', '', 'message', '',
      'note', '',
      'chip', v_chip,
      'action', jsonb_build_object('has', false));
  end if;

  v_label := case when v_reason = 'expired'
                  then public._c('cart.notice_renew_licence')
                  else public._c('cart.notice_add_licence') end;

  return jsonb_build_object(
    'has',      true,
    'blocking', true,
    'kind',     'drug_licence',
    'title',    coalesce(p_rx->>'title',''),
    'message',  v_msg,
    'note',     '',
    'chip',     v_chip,
    'tone',     coalesce(p_rx->'tone', jsonb_build_object('bg','#FEE2E2','fg','#991B1B')),
    'action',   jsonb_build_object(
                  'has',       (v_label <> ''),
                  'label',     v_label,
                  'kind',      'customer_route',
                  'route_key', 'cust_account',
                  'tab_key',   'profile',
                  'section',   'kyc'));
end
$function$;

-- ── 6. ONE gate for the Place order tap ───────────────────────────────────
-- Five answers, one round trip, every word and every route written here:
--   approved       → action 'order'  — the screen places the order
--   submitted      → action 'popup'  — "we are verifying your details"
--   incomplete     → action 'route'  — the form, resumed at the missing step
--   not_registered → action 'route'  — the form, from the top
--   logged_out     → action 'route'  — Login
-- The screen maps `route` to a named route and prints `popup` verbatim. It
-- never reads `state` to decide anything: `action` is the instruction.
create or replace function public.cart_place_gate()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_cid   uuid;
  v_row   record;
  v_reg   jsonb;
  v_route text;
  v_anchor text := '';
  v_pending jsonb := jsonb_build_object(
    'has',     true,
    'title',   public._c('cart.gate_pending_title'),
    'body',    public._c('cart.gate_pending_body'),
    'dismiss', public._c('cart.gate_pending_dismiss'));
begin
  v_route := coalesce(nullif(public.login_signup_cfg()->>'signup_form_route',''),
                      nullif(public.login_signup_cfg()->>'signup_route',''),
                      '/complete-registration');

  if v_uid is null then
    return jsonb_build_object(
      'ok', true, 'state', 'logged_out', 'action', 'route',
      'route', '/login', 'anchor', '',
      'cta',   public._c('cart.gate_login_cta'),
      'popup', jsonb_build_object('has', false));
  end if;

  begin
    v_cid := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                      public.my_customer_id());
  exception when others then
    v_cid := null;
  end;

  if v_cid is null then
    return jsonb_build_object(
      'ok', true, 'state', 'not_registered', 'action', 'route',
      'route', v_route, 'anchor', '',
      'cta',   public._c('cart.gate_register_cta'),
      'popup', jsonb_build_object('has', false));
  end if;

  select coalesce(approved, false) as approved,
         coalesce(status, '')      as status,
         coalesce(is_deleted, false) as deleted
    into v_row
    from public.pharmacy_profiles
   where id = v_cid;

  if v_row.approved and v_row.status <> 'suspended' and not v_row.deleted then
    return jsonb_build_object(
      'ok', true, 'state', 'approved', 'action', 'order',
      'route', '', 'anchor', '', 'cta', '',
      'popup', jsonb_build_object('has', false));
  end if;

  -- Not approved. Is anything still owed, or is it simply with us?
  begin
    v_reg := public.customer_registration_payload();
  exception when others then
    v_reg := jsonb_build_object('needs', false);
  end;

  if coalesce((v_reg->>'needs')::boolean, false) then
    if coalesce((v_reg#>>'{docs_pending,show}')::boolean, false) then
      v_anchor := coalesce(v_reg#>>'{docs_pending,anchor}', '');
    end if;
    return jsonb_build_object(
      'ok', true, 'state', 'incomplete', 'action', 'route',
      'route',  coalesce(nullif(v_reg->>'route',''), v_route),
      'anchor', v_anchor,
      'cta',    public._c('cart.gate_register_cta'),
      'popup',  jsonb_build_object('has', false));
  end if;

  return jsonb_build_object(
    'ok', true, 'state', 'submitted', 'action', 'popup',
    'route', '', 'anchor', '', 'cta', '',
    'popup', v_pending);
end
$function$;

-- The gate ANSWERS the logged-out case ("Login"), so it must be callable
-- before there is a session. It reads nothing an anonymous caller could not
-- already see: with auth.uid() null it returns the login route and stops.
revoke all on function public.cart_place_gate() from public;
grant execute on function public.cart_place_gate() to anon, authenticated, service_role;

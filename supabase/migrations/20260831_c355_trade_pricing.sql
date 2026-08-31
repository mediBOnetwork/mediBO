-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #355 — CUSTOMER register rows 79 / 80 / 81
--
-- feature_gaps #79  every order in history is billed at MRP, never a trade rate
-- feature_gaps #80  catalogue has no trade price: 2 of 562,549 medicines priced
-- feature_gaps #81  no GST on any catalogue row, so no tax breakup before checkout
--
-- legal_get_page('about'): "MRP printed on medicine packs is reference/regulatory
-- information only — it is the legal ceiling and a display field, never the
-- selling price ... Any build that prices, totals, or reports revenue on MRP is
-- wrong."
--
-- Root cause chain, all three rows, one line of code each:
--   cart_set_item / admin_cart_add   → cart_items.price := MRP
--   admin_writeas_place_order_v2     → orders.items[].price := cart_items.price
--   explode_order_items              → order_items.price := client-supplied price
--   _cart_render_core                → net_payable_display := inr_money(mrp_total)
--   _place_order_v2_core             → orders.total_amount := cart mrp_total
-- Nothing in that chain ever asks the pricing engine, which has existed and been
-- correct all along (_pricing_compute / _pricing_block / gst_rate_for).
--
-- This migration puts ONE resolver between the catalogue and every price the
-- platform stores or shows, and makes MRP structurally incapable of becoming a
-- price: the resolver returns NULL when a product has no trade rate, and every
-- writer takes what it returns.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Provenance on every stored price ────────────────────────────────────
-- Existing rows are annotated, never rewritten: they are real order history and
-- deleting/altering their numbers is not this command's call. 'legacy_mrp' is
-- what lets revenue reporting exclude them, and what stops the new trigger from
-- ever touching them.
alter table public.order_items add column if not exists price_source text;
alter table public.cart_items  add column if not exists price_source text;

update public.order_items
   set price_source = 'legacy_mrp'
 where price_source is null and price is not null;

comment on column public.order_items.price_source is
  'How this line got its price: trade_rate (resolved by trade_price_line), '
  'legacy_mrp (pre-#355 rows priced at MRP — never revenue), null (unpriced).';

-- ── 2. GST resolution — a rate for every catalogue row, none of it invented ──
-- The rule engine already exists and is admin-owned: gst_class_map (22 mapped
-- therapeutic classes) + app_settings.gst_rules.default. #81's evidence is that
-- "MEDICINE".gst_percent is NULL on all 562,549 rows — the COLUMN is empty, the
-- RULES are not. This resolves at read time from the rules rather than stamping
-- 562k rows: a rule change must not need a 562k-row rewrite (and that rewrite
-- would leave the "MEDICINE" visibility map stale on a 1 GB instance — see the
-- latency rules).
create or replace function public.gst_for_product(p_product_id bigint)
returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select case
    when m.id is null then
      jsonb_build_object('pct', null, 'source', 'unknown', 'confirmed', false)
    when mp.gst_pct is not null then
      jsonb_build_object('pct', mp.gst_pct, 'source', 'pricing_row', 'confirmed', true)
    when m.gst_percent is not null then
      jsonb_build_object('pct', m.gst_percent::numeric, 'source', 'catalog_column', 'confirmed', true)
    else
      jsonb_build_object(
        'pct', public.gst_rate_for(m.therapeutic_class)::numeric,
        'source', case when exists (
                         select 1 from public.gst_class_map g
                          where g.therapeutic_class = upper(btrim(coalesce(m.therapeutic_class,''))))
                       then 'class_map' else 'rule_default' end,
        'confirmed', false)
  end
  from (select 1) z
  left join "MEDICINE" m on m.id = p_product_id
  left join public.medicine_pricing mp on mp.product_id = p_product_id;
$fn$;

comment on function public.gst_for_product(bigint) is
  'CHANGE #355 — the GST rate for one product, with provenance. '
  'medicine_pricing.gst_pct > "MEDICINE".gst_percent > gst_class_map > rule default.';

-- ── 3. THE resolver. The only place a price may come from. ─────────────────
-- Returns has_trade_rate=false and price NULL when the product has no trade
-- rate. It never falls back to MRP — MRP is carried only as the reference
-- ceiling it is.
create or replace function public.trade_price_line(p_product_id bigint, p_qty numeric default 1)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_mrp   numeric;
  v_row   public.medicine_pricing;
  v_gst   jsonb;
  v_pct   numeric;
  v_calc  jsonb;
  v_qty   numeric := greatest(coalesce(p_qty, 0), 0);
  v_unit_taxable numeric; v_unit_net numeric;
  v_taxable numeric; v_gstamt numeric; v_cgst numeric; v_sgst numeric; v_net numeric;
  v_base  jsonb;
begin
  select nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric
    into v_mrp
  from "MEDICINE" m where m.id = p_product_id;

  select * into v_row from public.medicine_pricing where product_id = p_product_id;
  v_gst := public.gst_for_product(p_product_id);
  v_pct := coalesce((v_gst->>'pct')::numeric, 0);

  v_base := jsonb_build_object(
    'product_id',   p_product_id,
    'quantity',     v_qty,
    'mrp',          v_mrp,
    'mrp_display',  case when v_mrp is not null then public.inr_money(v_mrp) else '' end,
    'gst_pct',      (v_gst->'pct'),
    'gst_source',   (v_gst->>'source'),
    'gst_confirmed',(v_gst->>'confirmed')::boolean);

  -- No trade rate → no price. This is the whole fix for #79.
  if not coalesce(v_row.pricing_ready, false) or coalesce(v_row.ptr, 0) <= 0 then
    return v_base || jsonb_build_object(
      'has_trade_rate', false,
      'price',          null,
      'price_source',   null,
      'price_display',  '',
      'discount_pct',   0,
      'line_taxable',   0, 'line_gst', 0, 'line_cgst', 0, 'line_sgst', 0, 'line_net', 0,
      'line_total',     null,
      'line_net_display', '');
  end if;

  v_calc := public._pricing_compute(v_mrp, v_row.ptr, v_pct,
              coalesce(v_row.discount_pct, 0),
              v_row.scheme_buy_qty, v_row.scheme_free_qty, false);
  if v_calc is null then
    return v_base || jsonb_build_object(
      'has_trade_rate', false, 'price', null, 'price_source', null,
      'price_display', '', 'discount_pct', 0,
      'line_taxable', 0, 'line_gst', 0, 'line_cgst', 0, 'line_sgst', 0, 'line_net', 0,
      'line_total', null, 'line_net_display', '');
  end if;

  v_unit_taxable := (v_calc->>'taxable')::numeric;      -- PTR after discount + scheme, ex-GST
  v_unit_net     := (v_calc->>'net_payable')::numeric;  -- the same unit incl. GST

  -- Tax is computed on the LINE, not multiplied up from a rounded unit tax:
  -- 12 % of 8 x 12.35 is not 8 x round(12 % of 12.35).
  v_taxable := round(v_unit_taxable * v_qty, 2);
  v_gstamt  := round(v_taxable * v_pct / 100.0, 2);
  v_cgst    := round(v_gstamt / 2.0, 2);
  v_sgst    := round(v_gstamt - v_cgst, 2);
  v_net     := round(v_taxable + v_gstamt, 2);

  return v_base || jsonb_build_object(
    'has_trade_rate',   true,
    'price',            v_unit_taxable,
    'price_source',     'trade_rate',
    'price_display',    public.inr_money(v_unit_taxable),
    'unit_net',         v_unit_net,
    'unit_net_display', public.inr_money(v_unit_net),
    'discount_pct',     coalesce(v_row.discount_pct, 0),
    'scheme_factor',    (v_calc->>'scheme_factor')::numeric,
    'line_taxable',     v_taxable,
    'line_gst',         v_gstamt,
    'line_cgst',        v_cgst,
    'line_sgst',        v_sgst,
    'line_net',         v_net,
    'line_total',       v_taxable,
    'line_net_display', public.inr_money(v_net),
    'source',           coalesce(v_row.pricing_source, ''));
end;
$fn$;

comment on function public.trade_price_line(bigint, numeric) is
  'CHANGE #355 — the ONE price resolver. PTR -> discount -> scheme -> GST, all '
  'server-side. Returns has_trade_rate=false / price NULL when the product has '
  'no trade rate. It NEVER returns MRP as a price (feature_gaps #79).';

-- ── 4. Every new string is a row, not a Dart literal ───────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('cart_totals_title',      'Order summary',            'CHANGE #355 cart totals card title'),
  ('cart_taxable_total_label','Taxable value',           'CHANGE #355 cart taxable subtotal'),
  ('cart_gst_total_label',   'GST',                      'CHANGE #355 cart GST total row'),
  ('cart_net_payable_label', 'Net payable',              'CHANGE #355 cart payable row'),
  ('cart_mrp_worth_label',   'MRP worth (reference only)','CHANGE #355 MRP is never the payable'),
  ('cart_unpriced_line_note','Rate on supplier confirmation','CHANGE #355 per-line, no trade rate yet'),
  ('cart_unpriced_total_note','not priced yet — rate comes with the supplier quote','CHANGE #355 totals footnote, prefixed by the backend with the count'),
  ('cart_no_price_yet',      'Awaiting supplier rates',  'CHANGE #355 payable when no line has a trade rate'),
  ('cart_gst_estimated_note','GST shown at the catalogue rate for this class','CHANGE #355 shown when the rate is a rule, not a confirmed rate'),
  ('pricing_coverage_title', 'Trade price coverage',     'CHANGE #355 admin pricing screen title')
on conflict (key) do nothing;

-- ── 5. The cart's money, computed once, in one place ───────────────────────
-- Totals come from the trade rate ONLY. An unpriced line contributes zero to
-- the payable and says so; it is never silently valued at its MRP.
create or replace function public.cart_pricing_block(p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_lines jsonb := '[]'::jsonb;
  v_taxable numeric := 0; v_gst numeric := 0; v_cgst numeric := 0; v_sgst numeric := 0;
  v_net numeric := 0; v_mrp numeric := 0;
  v_priced int := 0; v_unpriced int := 0; v_est int := 0;
  v_rate numeric; v_rates numeric[] := '{}';
  it jsonb; v_tp jsonb; v_qty numeric; v_pid bigint;
  v_tax_lines jsonb := '[]'::jsonb;
  v_lbl_taxable text := coalesce((select value from storefront_ui_label where key='cart_taxable_total_label'), 'Taxable value');
  v_lbl_gst     text := coalesce((select value from storefront_ui_label where key='cart_gst_total_label'), 'GST');
  v_lbl_net     text := coalesce((select value from storefront_ui_label where key='cart_net_payable_label'), 'Net payable');
  v_lbl_mrp     text := coalesce((select value from storefront_ui_label where key='cart_mrp_worth_label'), 'MRP worth (reference only)');
  v_lbl_title   text := coalesce((select value from storefront_ui_label where key='cart_totals_title'), 'Order summary');
  v_lbl_unpriced text := coalesce((select value from storefront_ui_label where key='cart_unpriced_total_note'), 'not priced yet');
  v_lbl_none    text := coalesce((select value from storefront_ui_label where key='cart_no_price_yet'), 'Awaiting supplier rates');
  v_lbl_est     text := coalesce((select value from storefront_ui_label where key='cart_gst_estimated_note'), '');
begin
  for it in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_pid := nullif(it->>'product_id', '')::bigint;
    v_qty := coalesce((it->>'quantity')::numeric, 0);
    v_mrp := v_mrp + round(v_qty * coalesce((it->>'mrp')::numeric, 0), 2);

    if v_pid is null then
      v_unpriced := v_unpriced + 1;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'product_id', it->>'product_id', 'has_trade_rate', false));
      continue;
    end if;

    v_tp := public.trade_price_line(v_pid, v_qty);
    v_lines := v_lines || jsonb_build_array(v_tp);

    if (v_tp->>'has_trade_rate')::boolean then
      v_priced  := v_priced + 1;
      v_taxable := v_taxable + (v_tp->>'line_taxable')::numeric;
      v_gst     := v_gst     + (v_tp->>'line_gst')::numeric;
      v_cgst    := v_cgst    + (v_tp->>'line_cgst')::numeric;
      v_sgst    := v_sgst    + (v_tp->>'line_sgst')::numeric;
      v_net     := v_net     + (v_tp->>'line_net')::numeric;
      v_rate    := (v_tp->>'gst_pct')::numeric;
      if v_rate is not null and not (v_rate = any(v_rates)) then
        v_rates := v_rates || v_rate;
      end if;
      if not coalesce((v_tp->>'gst_confirmed')::boolean, false) then v_est := v_est + 1; end if;
    else
      v_unpriced := v_unpriced + 1;
    end if;
  end loop;

  v_taxable := round(v_taxable, 2); v_gst := round(v_gst, 2);
  v_cgst := round(v_cgst, 2); v_sgst := round(v_sgst, 2); v_net := round(v_net, 2);

  -- CGST/SGST — intra-state is the operating case (Chhattisgarh operator,
  -- Chhattisgarh pharmacies). IGST becomes a branch here the day the seller and
  -- the buyer GSTIN states differ; gst_split() already knows how to decide it.
  if v_priced > 0 then
    v_tax_lines := jsonb_build_array(
      jsonb_build_object('label', v_lbl_taxable, 'value', public.inr_money(v_taxable)),
      jsonb_build_object('label', 'CGST', 'value', public.inr_money(v_cgst)),
      jsonb_build_object('label', 'SGST', 'value', public.inr_money(v_sgst)),
      jsonb_build_object('label', v_lbl_gst, 'value', public.inr_money(v_gst)));
  end if;

  return jsonb_build_object(
    'title',            v_lbl_title,
    'lines',            v_lines,
    'priced_count',     v_priced,
    'unpriced_count',   v_unpriced,
    'has_priced',       (v_priced > 0),
    'has_unpriced',     (v_unpriced > 0),
    'has_tax',          (v_priced > 0),
    'taxable',          v_taxable,
    'taxable_display',  public.inr_money(v_taxable),
    'taxable_label',    v_lbl_taxable,
    'cgst',             v_cgst, 'cgst_display', public.inr_money(v_cgst),
    'sgst',             v_sgst, 'sgst_display', public.inr_money(v_sgst),
    'gst_total',        v_gst,  'gst_total_display', public.inr_money(v_gst),
    'gst_total_label',  v_lbl_gst,
    'gst_rates',        to_jsonb(v_rates),
    'gst_estimated_count', v_est,
    'gst_note',         case when v_est > 0 then v_lbl_est else '' end,
    'net_payable',      v_net,
    'net_payable_label',v_lbl_net,
    -- The payable NEVER falls back to MRP. With nothing priced it is ₹0.00 and
    -- the backend says why, in its own words.
    'net_payable_display', case when v_priced > 0 then public.inr_money(v_net) else v_lbl_none end,
    'mrp_worth',        round(v_mrp, 2),
    'mrp_worth_label',  v_lbl_mrp,
    'mrp_worth_display',public.inr_money(round(v_mrp, 2)),
    'tax_lines',        v_tax_lines,
    'unpriced_note',    case when v_unpriced > 0
                             then v_unpriced::text || ' item'
                                  || case when v_unpriced = 1 then '' else 's' end
                                  || ' ' || v_lbl_unpriced
                             else '' end);
end;
$fn$;

comment on function public.cart_pricing_block(jsonb) is
  'CHANGE #355 — cart money: taxable / CGST / SGST / GST / net payable over '
  'trade-rated lines only, plus the count and copy for lines with no rate yet. '
  'MRP is carried as reference (mrp_worth), never as the payable.';

-- ── 6. cart_state — the raw cart, now with the resolved money on it ────────
create or replace function public.cart_state(p_guest_uid uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_uid uuid := coalesce(public.viewer_cart_user(), p_guest_uid);
        v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
        v_items jsonb; v_units int; v_mrp numeric; v_lines int; v_pricing jsonb;
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
           -- reference only: what this line is worth at the printed ceiling.
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
  -- CHANGE #355 — the money is resolved here, once, from the trade rate.
  v_pricing := public.cart_pricing_block(v_items);

  return jsonb_build_object(
    'items', v_items,
    'admin_removed', '[]'::jsonb,
    'item_count', v_lines,
    'unit_count', v_units,
    'mrp_total', v_mrp,
    'pricing', v_pricing,
    -- #355: subtotal is the TAXABLE trade value and net_payable is the trade
    -- payable. Both were the MRP total, which is the bug feature_gaps #79 is.
    'subtotal', (v_pricing->>'taxable')::numeric,
    'net_payable', (v_pricing->>'net_payable')::numeric,
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
$fn$;

-- ── 7. _cart_render_core — the payable stops being the MRP total ───────────
create or replace function public._cart_render_core(p_guest_uid uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_cart jsonb := public.cart_state(p_guest_uid);
  v_mrp numeric := coalesce((v_cart->>'mrp_total')::numeric, 0);
  v_lines int := coalesce((v_cart->>'item_count')::int, 0);
  v_units int := coalesce((v_cart->>'unit_count')::int, 0);
  v_pricing jsonb := coalesce(v_cart->'pricing', '{}'::jsonb);
  v_net numeric := coalesce((v_pricing->>'net_payable')::numeric, 0);
  v_priced int := coalesce((v_pricing->>'priced_count')::int, 0);
  v_items jsonb;
  v_items_label text;
  v_margin jsonb;
  v_unpriced_line text := coalesce((select value from storefront_ui_label where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
begin
  -- Per line: the TRADE rate when there is one, and the backend's own words
  -- when there is not. qty_label used to read "3 × <MRP>" — printing the legal
  -- ceiling as if it were the rate (feature_gaps #79).
  select coalesce(jsonb_agg(
           it || coalesce(tp, '{}'::jsonb) || jsonb_build_object(
             'mrp_display',       public.inr_money(coalesce((it->>'mrp')::numeric,0)),
             'line_mrp_display',  public.inr_money(coalesce((it->>'line_mrp')::numeric,0)),
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

  return v_cart || jsonb_build_object(
    'items', v_items,
    'margin', v_margin,
    'render', jsonb_build_object(
      -- #355: subtotal is the taxable trade value; the grand total is the trade
      -- payable incl. GST. MRP keeps its own row, labelled as the reference it is.
      'subtotal_display',     coalesce(v_pricing->>'taxable_display', public.inr_money(0)),
      'mrp_total_display',    public.inr_money(v_mrp),
      'net_payable_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'grand_total',          v_net,
      'grand_total_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'item_count',           v_lines,
      'unit_count',           v_units,
      'items_label',          v_items_label,
      'subtotal_line',        v_items_label || ' • '
                              || case when v_priced > 0
                                      then coalesce(v_pricing->>'net_payable_display','')
                                      else coalesce(v_pricing->>'net_payable_display','') end
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
        'total',        coalesce(v_pricing->>'net_payable_label', 'Net payable'))));
end
$fn$;

-- ── 8. The cart stops storing MRP as a price ───────────────────────────────
-- NULL is the honest value for "this product has no trade rate yet". Writing
-- the MRP there is what every downstream total then multiplied up.
alter table public.cart_items alter column price drop not null;

create or replace function public.cart_set_item(p_product_id text, p_quantity integer, p_guest_uid uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_uid uuid; v_cust uuid; m record; v_mrp numeric; v_gst integer;
        v_tp jsonb; v_price numeric; v_src text; v_policy text;
begin
  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid  := p_guest_uid;
    v_cust := null;
  end if;

  if v_uid is null then
    return jsonb_build_object('ok',false,'message','Please log in');
  end if;
  if p_product_id is null or btrim(p_product_id) = '' then
    return jsonb_build_object('ok',false,'message','Product missing');
  end if;

  if coalesce(p_quantity,0) <= 0 then
    delete from cart_items
     where product_id = p_product_id
       and (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);
    return jsonb_build_object('ok',true,'message','Removed from cart',
                              'cart', public.cart_render(p_guest_uid));
  end if;

  select id, product_name, mrp, image_url_1, marketer, pack_size, therapeutic_class,
         gst_percent, supplier_count
    into m
  from "MEDICINE" where id::text = p_product_id;

  if not found then return jsonb_build_object('ok',false,'message','Product not found'); end if;
  if coalesce(m.supplier_count,0) < 1 and public.viewer_is_approved_customer() then
    return jsonb_build_object('ok',false,'message','No supplier for this product right now');
  end if;

  v_mrp := nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric;

  -- #355 — the price is RESOLVED, never copied from the MRP.
  v_tp    := public.trade_price_line(m.id, p_quantity);
  v_price := nullif(v_tp->>'price','')::numeric;
  v_src   := nullif(v_tp->>'price_source','');
  v_gst   := round(coalesce((v_tp->>'gst_pct')::numeric, 0))::int;

  -- feature_gaps #80 — the sellability policy. 'strict' refuses a product with
  -- no trade rate instead of letting it into a cart it cannot price; 'inquiry'
  -- (the default) keeps mediBO's own model, where the rate arrives with the
  -- supplier quote AFTER the order — see legal_get_page('about'), "How an order
  -- flows". Either way the MRP is never the price.
  v_policy := coalesce((select value->>'mode' from app_settings where key='pricing_policy'), 'inquiry');
  if v_policy = 'strict' and v_src is null then
    return jsonb_build_object('ok', false,
      'message', coalesce((select value from storefront_ui_label where key='cart_no_price_yet'),
                          'Awaiting supplier rates'));
  end if;

  insert into cart_items (user_id, customer_id, product_id, product_name, price, mrp, quantity,
                          image_url, manufacturer, pack_size, category, gst_percent, added_by,
                          price_source)
  values (v_uid, v_cust, p_product_id, m.product_name, v_price, v_mrp, p_quantity,
          m.image_url_1, m.marketer, m.pack_size, m.therapeutic_class, v_gst,
          case when auth.uid() is null then 'guest'
               when public.my_acting_as() is not null then 'admin' else 'customer' end,
          v_src)
  on conflict (user_id, product_id) do update
    set quantity = excluded.quantity,
        price = excluded.price,
        price_source = excluded.price_source,
        gst_percent = excluded.gst_percent,
        customer_id = coalesce(excluded.customer_id, cart_items.customer_id),
        removed_by_admin = false,
        updated_at = now();

  return jsonb_build_object('ok',true,'message','Cart updated','cart', public.cart_render(p_guest_uid));
end
$fn$;

create or replace function public.admin_cart_add(p_customer_id uuid, p_product_id text, p_qty integer default 1)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_role text := coalesce(public.get_my_role(), 'none');
  v_uid uuid;
  m record;
  v_existing cart_items%rowtype;
  v_qty int := greatest(coalesce(p_qty,1), 1);
  v_new_qty int;
  v_mrp numeric; v_tp jsonb;
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'forbidden' using hint = 'Only an admin may edit a customer cart.';
  end if;

  select user_id into v_uid from pharmacy_profiles where id = p_customer_id;
  if not found then
    v_uid := p_customer_id;
    p_customer_id := public.customer_id_for_user(v_uid);
    if p_customer_id is null then
      raise exception 'customer_not_found' using hint = 'No account for that id.';
    end if;
  end if;

  select id, product_name, mrp, marketer, therapeutic_class, image_url_1,
         pack_qty, pack_size, gst_percent
    into m
  from "MEDICINE" where id::text = p_product_id limit 1;
  if not found then
    raise exception 'product_not_found: %', p_product_id;
  end if;

  select * into v_existing from cart_items
   where customer_id = p_customer_id and product_id = p_product_id
   limit 1;

  v_mrp := nullif(regexp_replace(coalesce(m.mrp,''), '[^0-9.]', '', 'g'), '')::numeric;

  if found then
    v_new_qty := case when coalesce(v_existing.removed_by_admin,false)
                      then v_qty
                      else coalesce(v_existing.quantity,0) + v_qty end;
    v_tp := public.trade_price_line(m.id, v_new_qty);
    update cart_items set
      quantity = v_new_qty,
      price = nullif(v_tp->>'price','')::numeric,
      price_source = nullif(v_tp->>'price_source',''),
      removed_by_admin = false,
      removed_at = null,
      updated_at = now()
    where id = v_existing.id;
  else
    v_new_qty := v_qty;
    v_tp := public.trade_price_line(m.id, v_qty);
    insert into cart_items (
      user_id, customer_id, product_id, product_name, price, mrp, quantity,
      image_url, manufacturer, pack_size, category, gst_percent,
      added_by, removed_by_admin, updated_at, price_source)
    values (
      v_uid, p_customer_id, p_product_id, coalesce(m.product_name,''),
      -- #355: the resolved trade rate, or NULL. Never the MRP.
      nullif(v_tp->>'price','')::numeric,
      v_mrp,
      v_qty,
      coalesce(m.image_url_1,''), coalesce(m.marketer,''),
      coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),''), ''),
      coalesce(nullif(btrim(m.therapeutic_class),''), 'Other'),
      round(coalesce((v_tp->>'gst_pct')::numeric, 0))::int,
      coalesce(nullif(public.my_login_email(),''), 'admin'),
      false, now(), nullif(v_tp->>'price_source',''));
  end if;

  return jsonb_build_object(
    'ok',           true,
    'product_id',   p_product_id,
    'product_name', coalesce(m.product_name,''),
    'quantity',     v_new_qty,
    'cart',         public.cart_state(null));
end
$fn$;

-- ── 9. The order write path ────────────────────────────────────────────────
-- explode_order_items used to copy price / gst_percent / line_total straight
-- out of the CLIENT's items payload. That is how 213 of 213 priced lines came
-- to hold price = mrp exactly. It now carries only what the client legitimately
-- knows (what, how many, and the printed MRP); the price is resolved by the
-- trigger below, which every write path goes through.
create or replace function public.explode_order_items()
returns trigger language plpgsql as $fn$
begin
  if TG_OP = 'UPDATE' and (NEW.items is not distinct from OLD.items) then
    return NEW;
  end if;

  delete from order_items where order_id = NEW.id;
  if NEW.items is not null and jsonb_typeof(NEW.items) = 'array' then
    insert into order_items (order_id, product_name, product_id, quantity, mrp,
                             pharmacy_name, payment_id, status)
    select NEW.id,
           coalesce(it->>'product_name', it->>'name'),
           coalesce(nullif(it->>'product_id','')::bigint,
                    (select id from "MEDICINE"
                      where product_name = coalesce(it->>'product_name', it->>'name') limit 1)),
           coalesce((it->>'quantity')::numeric, (it->>'qty')::numeric),
           nullif(it->>'mrp','')::numeric,
           NEW.pharmacy_name, NEW.payment_id, NEW.status
    from jsonb_array_elements(NEW.items) as it;
  end if;
  return NEW;
end;
$fn$;

-- The single enforcement point: whatever writes an order line, the price on it
-- is the resolver's answer or nothing. A caller-supplied price is discarded.
-- Rows already stamped 'legacy_mrp' are history and are never touched.
create or replace function public._oi_resolve_price()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb;
begin
  if TG_OP = 'UPDATE' and coalesce(OLD.price_source,'') = 'legacy_mrp' then
    return NEW;
  end if;

  if NEW.product_id is null then
    NEW.price := null; NEW.price_source := null; NEW.line_total := null;
    return NEW;
  end if;

  v := public.trade_price_line(NEW.product_id, coalesce(NEW.quantity, 0));

  -- The rate is known even when the price is not: GST comes from the rule
  -- engine for every catalogue row (feature_gaps #81).
  NEW.gst_percent := (v->>'gst_pct')::numeric;

  if coalesce((v->>'has_trade_rate')::boolean, false) then
    NEW.price        := (v->>'price')::numeric;       -- per unit, ex-GST
    NEW.line_total   := (v->>'line_total')::numeric;  -- qty x price, ex-GST
    NEW.price_source := 'trade_rate';
  else
    NEW.price := null; NEW.line_total := null; NEW.price_source := null;
  end if;
  return NEW;
end;
$fn$;

drop trigger if exists trg_oi_resolve_price on public.order_items;
create trigger trg_oi_resolve_price
  before insert or update of price, quantity, product_id
  on public.order_items
  for each row execute function public._oi_resolve_price();

-- Both placement paths: the order's total is the trade payable, never the MRP
-- total. With nothing priced yet it is 0 — the amount owed is genuinely not
-- known until the suppliers quote, and 14,421.53 was never that amount.
create or replace function public._place_order_v2_core()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
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

  -- #355: the trade payable from cart_pricing_block. It was the MRP total.
  v_net := coalesce((v_cart->'pricing'->>'net_payable')::numeric, 0);

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
     (v_act is not null),
     public.next_order_number())
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
    'amount',          v_net,
    'amount_display',  coalesce(v_cart->'pricing'->>'net_payable_display', public.inr_money(v_net)),
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);
end
$fn$;

create or replace function public.admin_writeas_place_order_v2(p_customer_id uuid, p_product_ids text[] default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_total numeric; v_id uuid; v_code text; v_addr text;
  v_copy jsonb; v_checkout jsonb; v_pricing jsonb;
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'forbidden' using hint = 'Only an admin may place an order for a customer.';
  end if;

  select * into pp from pharmacy_profiles where id = p_customer_id;
  if not found then raise exception 'customer_not_found'; end if;

  -- #355: the payload carries WHAT was ordered and the printed MRP. It no
  -- longer carries a price — cart_items.price was the MRP, and this function
  -- copying it is what put price = mrp on every admin-placed line.
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  ci.product_id,
           'product_name',coalesce(ci.product_name,''),
           'quantity',    coalesce(ci.quantity,0),
           'mrp',         coalesce(ci.mrp,0))), '[]'::jsonb)
    into v_items
  from cart_items ci
  where ci.customer_id = p_customer_id
    and coalesce(ci.removed_by_admin,false) = false
    and (p_product_ids is null or ci.product_id = any(p_product_ids));

  if jsonb_array_length(v_items) = 0 then
    raise exception 'no_lines_selected';
  end if;

  v_pricing := public.cart_pricing_block(v_items);
  v_total   := coalesce((v_pricing->>'net_payable')::numeric, 0);

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id)
  values
    (pp.user_id, p_customer_id, coalesce(pp.pharmacy_name,''), v_items, v_total,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending', 'website', true,
     public.next_order_number())
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where customer_id = p_customer_id
     and (p_product_ids is null or product_id = any(p_product_ids));

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);

  v_checkout := jsonb_build_object(
    'ok', true,
    'collection_mode', public.payment_collection_mode(),
    'provider', case when public.payment_collection_mode() = 'gateway'
                     then 'razorpay_qr' else 'upi_manual' end,
    'acting_as', true, 'placed_by_admin', true, 'pay_now', false,
    'button_label',  public._rzp_copy('checkout_btn_place'),
    'actingas_note', case when public.payment_collection_mode() = 'gateway'
                          then public._rzp_copy('checkout_actingas_note') else '' end);

  if public.payment_collection_mode() = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', coalesce(v_id::text,''),
    'order_code', coalesce(v_code,''),
    'amount', v_total,
    'amount_display', coalesce(v_pricing->>'net_payable_display', public.inr_money(v_total)),
    'title', coalesce(v_copy->>'title',''),
    'note', coalesce(v_copy->>'note',''),
    'done_label', coalesce(v_copy->>'done_label',''),
    'item_count', jsonb_array_length(v_items),
    'checkout', v_checkout);
end
$fn$;

-- ── 10. cart_totals_for — the admin-side cart total, same rule ─────────────
create or replace function public.cart_totals_for(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_mrp numeric; v_pct numeric := 0; v_tiers jsonb; v_cur jsonb;
  v_fee numeric; v_free boolean := false; v_net numeric; v_items int; v_units int;
  v_lines jsonb; v_pricing jsonb; v_trade numeric;
begin
  select coalesce(sum(round(coalesce(ci.quantity,0) * coalesce(ci.mrp,0), 2)), 0),
         count(*), coalesce(sum(coalesce(ci.quantity,0)),0)
    into v_mrp, v_items, v_units
  from cart_items ci
  where ci.customer_id = p_customer_id
    and coalesce(ci.removed_by_admin,false) = false;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', ci.product_id,
           'quantity',   ci.quantity,
           'mrp',        ci.mrp)), '[]'::jsonb)
    into v_lines
  from cart_items ci
  where ci.customer_id = p_customer_id
    and coalesce(ci.removed_by_admin,false) = false;

  v_pricing := public.cart_pricing_block(v_lines);
  v_trade   := coalesce((v_pricing->>'net_payable')::numeric, 0);

  -- The order-value slab still ladders off the basket's MRP worth (that is what
  -- cart_tiers is keyed on), but it now discounts the TRADE payable, and the
  -- delivery fee is added to that. Discounting an MRP total produced a number
  -- that was never owed.
  select value into v_tiers from app_settings where key='cart_tiers';
  v_tiers := coalesce(v_tiers, '[]'::jsonb);
  select t into v_cur from jsonb_array_elements(v_tiers) t
   where (t->>'min_mrp')::numeric <= v_mrp
   order by (t->>'min_mrp')::numeric desc limit 1;
  if v_cur is not null then
    v_pct  := coalesce((v_cur->>'discount_pct')::numeric, 0);
    v_free := coalesce((v_cur->>'free_delivery')::boolean, false);
  end if;

  select (value)::text::numeric into v_fee from app_settings where key='delivery_fee';
  v_fee := case when v_free or v_items = 0 then 0 else coalesce(v_fee, 49) end;

  v_net := round(v_trade - (v_trade * v_pct / 100.0) + case when v_trade > 0 then v_fee else 0 end, 2);

  return jsonb_build_object(
    'mrp_total', v_mrp,
    'discount_pct', v_pct,
    'delivery_fee', v_fee,
    'pricing', v_pricing,
    'trade_total', v_trade,
    'net_payable', v_net,
    'net_payable_display', case when (v_pricing->>'has_priced')::boolean
                                then public.inr_money(v_net)
                                else coalesce(v_pricing->>'net_payable_display','') end,
    'item_count', v_items,
    'unit_count', v_units,
    'margin', public.cart_margin_block(v_lines));
end
$fn$;

-- ── 11. feature_gaps #80 — coverage is measured, not assumed ───────────────
-- "MEDICINE" is 562k rows on a 1 GB instance, so the counts are cached and
-- refreshed on a schedule (and on demand from the admin screen), never counted
-- on a user path — the same rule medicine_count_cache already follows.
create table if not exists public.pricing_coverage_cache (
  id              text primary key default 'singleton',
  catalogue_rows  bigint  not null default 0,
  priced_rows     bigint  not null default 0,
  gst_rule_rows   bigint  not null default 0,
  gst_column_rows bigint  not null default 0,
  buyable_rows    bigint  not null default 0,
  ordered_rows    bigint  not null default 0,
  computed_at     timestamptz not null default now()
);

create or replace function public.pricing_coverage_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_total bigint; v_priced bigint; v_gstcol bigint; v_buyable bigint;
        v_mapped bigint; v_ordered bigint;
begin
  select count(*), count(*) filter (where m.gst_percent is not null),
         count(*) filter (where coalesce(m.buyable,false)),
         count(*) filter (where exists (
           select 1 from public.gst_class_map g
            where g.therapeutic_class = upper(btrim(coalesce(m.therapeutic_class,'')))))
    into v_total, v_gstcol, v_buyable, v_mapped
  from "MEDICINE" m;

  select count(*) into v_priced from public.medicine_pricing where pricing_ready;
  select count(distinct product_id) into v_ordered
    from public.order_items where product_id is not null;

  insert into public.pricing_coverage_cache
    (id, catalogue_rows, priced_rows, gst_rule_rows, gst_column_rows,
     buyable_rows, ordered_rows, computed_at)
  values ('singleton', v_total, v_priced, v_mapped, v_gstcol, v_buyable, v_ordered, now())
  on conflict (id) do update set
    catalogue_rows = excluded.catalogue_rows,
    priced_rows    = excluded.priced_rows,
    gst_rule_rows  = excluded.gst_rule_rows,
    gst_column_rows= excluded.gst_column_rows,
    buyable_rows   = excluded.buyable_rows,
    ordered_rows   = excluded.ordered_rows,
    computed_at    = now();

  return public.pricing_coverage_report();
end;
$fn$;

create or replace function public.pricing_coverage_report()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  c public.pricing_coverage_cache;
  v_policy text; v_pol_row jsonb;
  v_mrp_lines bigint; v_trade_lines bigint; v_unpriced_lines bigint;
  v_title text := coalesce((select value from storefront_ui_label where key='pricing_coverage_title'),
                           'Trade price coverage');
begin
  select * into c from public.pricing_coverage_cache where id='singleton';
  v_policy := coalesce((select value->>'mode' from app_settings where key='pricing_policy'), 'inquiry');

  select count(*) filter (where price_source = 'legacy_mrp'),
         count(*) filter (where price_source = 'trade_rate'),
         count(*) filter (where price_source is null)
    into v_mrp_lines, v_trade_lines, v_unpriced_lines
  from public.order_items;

  return jsonb_build_object(
    'ok', true,
    'title', v_title,
    'computed_at', c.computed_at,
    'computed_label', case when c.computed_at is null then 'Never measured'
                           else 'Measured ' || to_char(c.computed_at at time zone 'Asia/Kolkata',
                                                       'DD Mon YYYY, HH12:MI AM') || ' IST' end,
    'policy', jsonb_build_object(
      'mode', v_policy,
      'label', case when v_policy = 'strict'
                    then 'Strict — a product with no trade rate cannot be added to a cart'
                    else 'Inquiry — a product with no trade rate can be ordered; the rate arrives with the supplier quote' end,
      'options', jsonb_build_array(
        jsonb_build_object('mode','inquiry','label','Inquiry (default)'),
        jsonb_build_object('mode','strict','label','Strict'))),
    'rows', jsonb_build_array(
      jsonb_build_object('label','Catalogue products',
        'value', coalesce(c.catalogue_rows,0)::text,
        'detail',''),
      jsonb_build_object('label','With a trade rate (PTR)',
        'value', coalesce(c.priced_rows,0)::text,
        'detail', case when coalesce(c.catalogue_rows,0) > 0
                       then round(coalesce(c.priced_rows,0)::numeric * 100 / c.catalogue_rows, 4)::text || '%'
                       else '' end),
      jsonb_build_object('label','GST rate resolvable',
        'value', coalesce(c.catalogue_rows,0)::text,
        'detail','every row resolves through gst_class_map or the rule default'),
      jsonb_build_object('label','GST rate from a mapped class',
        'value', coalesce(c.gst_rule_rows,0)::text,
        'detail', case when coalesce(c.catalogue_rows,0) > 0
                       then round(coalesce(c.gst_rule_rows,0)::numeric * 100 / c.catalogue_rows, 2)::text || '%'
                       else '' end),
      jsonb_build_object('label','Products ever ordered',
        'value', coalesce(c.ordered_rows,0)::text,
        'detail','the set that actually needs a rate first'),
      jsonb_build_object('label','Order lines priced at a trade rate',
        'value', coalesce(v_trade_lines,0)::text, 'detail',''),
      jsonb_build_object('label','Order lines awaiting a rate',
        'value', coalesce(v_unpriced_lines,0)::text, 'detail',''),
      jsonb_build_object('label','Legacy lines priced at MRP',
        'value', coalesce(v_mrp_lines,0)::text,
        'detail','pre-#355 history — never counted as revenue')),
    'legacy_mrp_lines', coalesce(v_mrp_lines,0),
    'trade_lines', coalesce(v_trade_lines,0),
    'unpriced_lines', coalesce(v_unpriced_lines,0),
    'catalogue_rows', coalesce(c.catalogue_rows,0),
    'priced_rows', coalesce(c.priced_rows,0));
end;
$fn$;

create or replace function public.pricing_policy_set(p_mode text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_role text := coalesce(public.get_my_role(), 'none');
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'forbidden' using hint = 'Only an admin may change the pricing policy.';
  end if;
  if p_mode not in ('inquiry','strict') then
    raise exception 'bad_mode' using hint = 'mode must be inquiry or strict';
  end if;
  insert into app_settings (key, value) values ('pricing_policy', jsonb_build_object('mode', p_mode))
    on conflict (key) do update set value = excluded.value;
  return public.pricing_coverage_report();
end;
$fn$;

insert into app_settings (key, value)
values ('pricing_policy', jsonb_build_object('mode','inquiry'))
on conflict (key) do nothing;

grant execute on function public.gst_for_product(bigint) to anon, authenticated;
grant execute on function public.trade_price_line(bigint, numeric) to anon, authenticated;
grant execute on function public.cart_pricing_block(jsonb) to anon, authenticated;
grant execute on function public.pricing_coverage_report() to authenticated;
grant execute on function public.pricing_coverage_refresh() to authenticated;
grant execute on function public.pricing_policy_set(text) to authenticated;

-- Coverage is recomputed off-peak by the ONE cron dispatcher (never a bare */N).
insert into public.cron_task (name, ord, mode, work_sql, enabled, dml, run_at_ist, note)
values ('pricing_coverage_refresh', 720, 'poll',
        'select public.pricing_coverage_refresh()', true, true, '03:47',
        'CHANGE #355 - nightly trade-price / GST coverage measurement, off-peak IST')
on conflict (name) do nothing;

-- The nav label for the new admin screen. A key with no row renders blank, so
-- the entry ships with its copy (CHANGE #645/#646's lesson, one step earlier).
insert into public.ui_copy (key, value)
values ('admin_nav.overflow_pricing', '"Trade Pricing"'::jsonb)
on conflict (key) do nothing;

-- CHANGE #1895 — the product card rebuilt to Om's 08-Sep sketch.
--
-- One field decides the sale line everywhere: pricing.price_display is either
-- the formatted PTR amount (approved viewer AND a trade price exists) or the
-- literal word "PTR". Flutter prints it as given — no approval check, no price
-- math and no formatting in the app.
--
-- Also here, because they are the same card:
--   * the MRP is ALWAYS sent and ALWAYS struck (it is the printed ceiling, and
--     it is now shown to anonymous viewers too),
--   * the "Register and get approved to see trade prices" sentence leaves the
--     card and becomes the locked PROMPT the PTR word opens,
--   * the Rx badge and the two pack strings ride on every card surface
--     (storefront, search, home, catalogue, PDP) so the card is identical
--     everywhere.
--
-- Idempotent: every statement is create-or-replace / on-conflict.

-- ── 1. Copy ────────────────────────────────────────────────────────────────
-- The prompt's words are data, so re-wording it is an UPDATE, never a deploy.
insert into public.storefront_ui_label (key, value, note) values
  ('ptr_locked_title', 'Trade price',
   'CHANGE #1895 — heading of the sheet the PTR word opens'),
  ('ptr_locked_cta',   'Register now',
   'CHANGE #1895 — button on the locked-price sheet'),
  ('ptr_locked_route', '/register',
   'CHANGE #1895 — where that button goes')
on conflict (key) do nothing;

-- ── 2. The price block ─────────────────────────────────────────────────────
create or replace function public._pricing_block(
  p_mrp numeric, p_row medicine_pricing, p_discount_pct numeric default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_has   boolean := (p_mrp is not null and p_mrp > 0);
  v_mrp   numeric := coalesce(p_mrp, 0);
  v_cap   text := coalesce((select value from storefront_ui_label where key = 'price_caption'), 'MRP');
  v_mrp_cap text := coalesce((select value from storefront_ui_label where key = 'mrp_caption'), 'MRP');
  v_net_cap text := coalesce((select value from storefront_ui_label where key = 'net_rate_caption'), 'NET');
  v_ptr_cap text := coalesce((select value from storefront_ui_label where key = 'ptr_caption'), 'PTR');
  v_locked text := coalesce((select value from storefront_ui_label where key = 'ptr_locked_note'), '');
  v_lock_title text := coalesce((select value from storefront_ui_label where key = 'ptr_locked_title'), '');
  v_lock_cta   text := coalesce((select value from storefront_ui_label where key = 'ptr_locked_cta'), '');
  v_lock_route text := coalesce((select value from storefront_ui_label where key = 'ptr_locked_route'), '');
  v_earn  text := coalesce((select value from storefront_ui_label where key = 'margin_earn_prefix'), 'You earn');
  v_suffix text := coalesce((select value from storefront_ui_label where key = 'margin_chip_suffix'), 'margin');
  v_loss text := coalesce((select value from storefront_ui_label where key = 'margin_loss_prefix'), 'Above MRP by');
  v_over text := coalesce((select value from storefront_ui_label where key = 'margin_chip_over_suffix'), 'above MRP');
  v_gst_title text := coalesce((select value from storefront_ui_label where key = 'gst_breakup_title'), 'GST breakup');
  v_tax_label text := coalesce((select value from storefront_ui_label where key = 'gst_taxable_label'), 'Taxable value');
  v_entitled boolean := public.viewer_sees_trade_price();
  v_base  jsonb;
  v_calc  jsonb;
  v_band  jsonb;
  v_pct   numeric;
  v_net   numeric;
  v_ptr   numeric;
  v_chip  text;
  v_lines jsonb;
  v_scheme_extra jsonb;
  v_eff   numeric;
  v_scheme_ready boolean;
  v_days_left integer;
begin
  -- The LOCKED base. CHANGE #1895: price_display is the literal word "PTR"
  -- here — the same field the entitled branch fills with the amount — so the
  -- card has exactly one string to print and never asks who is looking.
  -- has_ptr / ptr_display are still added ONLY on the entitled branch, so an
  -- unapproved viewer's payload carries no trade number to leak.
  v_base := jsonb_build_object(
    'has_price',        v_has,
    'mrp',              v_mrp,
    'sale_price',       v_mrp,
    'price_display',    v_ptr_cap,
    'price_caption',    case when v_has then v_cap else '' end,
    'price_locked',     true,
    'mrp_display',      case when v_has then public.inr_money(v_mrp) else '' end,
    'discount_pct',     0,
    'has_discount',     false,
    'discount_label',   '',
    'ribbon_top',       '',
    'ribbon_bottom',    '',
    'margin_label',     '',
    'display_mode',     'mrp_only',
    'pricing_ready',    false,
    'has_net',          false,
    'net_display',      '',
    'net_caption',      '',
    'has_margin',       false,
    'margin_pct',       null,
    'margin_chip',      null,
    'has_scheme',       false,
    'scheme_text',      '',
    'scheme_badge',     null,
    'scheme_effective', null,
    'scheme_expiry',    null,
    'has_struck_mrp',   v_has,
    'gst',              null,
    'locked_prompt', jsonb_build_object(
      'title', v_lock_title, 'note', v_locked,
      'cta',   v_lock_cta,   'route', v_lock_route),
    'card_price', jsonb_build_object(
      'has_mrp',       v_has,
      'mrp_label',     case when v_has then v_mrp_cap else '' end,
      'mrp_display',   case when v_has then public.inr_money(v_mrp) else '' end,
      -- The MRP is the printed ceiling and is struck whether or not the viewer
      -- may see the trade rate: what sits under it is the word PTR.
      'strike_mrp',    v_has,
      'price_display', v_ptr_cap,
      'price_locked',  true,
      'has_ptr',       false,
      -- CHANGE #1895 — the sentence left the card. It is the sheet's note now.
      'has_note',      false,
      'note',          '',
      'locked_title',  v_lock_title,
      'locked_note',   v_locked,
      'locked_cta',    v_lock_cta,
      'locked_route',  v_lock_route));

  v_scheme_ready := coalesce(p_row.scheme_ready, false)
                    AND coalesce(p_row.scheme_buy_qty, 0) > 0
                    AND coalesce(p_row.scheme_free_qty, 0) > 0;

  if v_scheme_ready then
    v_eff := round(coalesce(nullif(p_row.ptr, 0), nullif(v_mrp, 0), 0)
                   / (p_row.scheme_buy_qty + p_row.scheme_free_qty), 2);
    v_days_left := case when p_row.scheme_ends_at is not null
                        then extract(day from (p_row.scheme_ends_at - now()))::integer
                        else null end;
    v_scheme_extra := jsonb_build_object(
      'has_scheme',   true,
      'scheme_text',  coalesce(nullif(btrim(coalesce(p_row.scheme_text,'')), ''),
                               p_row.scheme_buy_qty::int::text || '+' ||
                               p_row.scheme_free_qty::int::text || ' FREE'),
      'scheme_badge', jsonb_build_object(
        'label', p_row.scheme_buy_qty::int::text || '+' ||
                 p_row.scheme_free_qty::int::text || ' FREE',
        'bg', '#D1FAE5', 'fg', '#065F46'),
      'scheme_effective', jsonb_build_object(
        'label', 'Effective ' || public.inr_money(v_eff) || '/unit',
        'per_unit', v_eff,
        'per_unit_display', public.inr_money(v_eff)),
      'scheme_expiry', case
        when v_days_left is null then null
        when v_days_left < 0 then jsonb_build_object('label','Scheme expired','urgent',true)
        when v_days_left = 0 then jsonb_build_object('label','Ends today','urgent',true)
        when v_days_left <= 3 then jsonb_build_object('label','Ends in ' || v_days_left || ' day' ||
                                   case when v_days_left=1 then '' else 's' end,'urgent',true)
        else jsonb_build_object('label','Ends in ' || v_days_left || ' days','urgent',false)
      end
    );
    v_base := v_base || v_scheme_extra;
  end if;

  if not v_has or not coalesce(p_row.pricing_ready, false) or not v_entitled then
    return v_base;
  end if;

  v_calc := public._pricing_compute(v_mrp, p_row.ptr, p_row.gst_pct,
              coalesce(p_row.discount_pct, 0),
              p_row.scheme_buy_qty, p_row.scheme_free_qty, false);
  if v_calc is null then return v_base; end if;

  v_net := (v_calc->>'net_payable')::numeric;
  v_ptr := (v_calc->>'ptr')::numeric;
  v_pct := (v_calc->>'margin_pct')::numeric;

  -- A row that computed no usable trade rate stays LOCKED: the card shows the
  -- word rather than a fabricated zero. QA's third case.
  if v_ptr is null or v_ptr <= 0 then return v_base; end if;

  select b into v_band
    from jsonb_array_elements(
           coalesce((select value from app_settings where key = 'pricing_margin_bands'), '[]'::jsonb)) b
   where (b->>'min_pct')::numeric <= v_pct
   order by (b->>'min_pct')::numeric desc limit 1;

  v_chip := case when v_pct < 0
                 then trim(public._num_label(abs(v_pct)) || '% ' || v_over)
                 else trim(public._num_label(v_pct) || '% ' || v_suffix) end;

  v_lines := jsonb_build_array(
    jsonb_build_object('label', v_tax_label,
                       'value', public.inr_money((v_calc->>'taxable')::numeric)))
    || case when (v_calc->>'is_igst')::boolean
         then jsonb_build_array(jsonb_build_object(
                'label', 'IGST ' || public._num_label((v_calc->>'gst_pct')::numeric) || '%',
                'value', public.inr_money((v_calc->>'igst')::numeric)))
         else jsonb_build_array(
                jsonb_build_object('label', 'CGST ' || public._num_label((v_calc->>'gst_pct')::numeric/2) || '%',
                                   'value', public.inr_money((v_calc->>'cgst')::numeric)),
                jsonb_build_object('label', 'SGST ' || public._num_label((v_calc->>'gst_pct')::numeric/2) || '%',
                                   'value', public.inr_money((v_calc->>'sgst')::numeric)))
       end;

  return v_base || jsonb_build_object(
    'display_mode',   'full',
    'pricing_ready',  true,
    -- CHANGE #1895 — the sale line is the PTR, not the GST-inclusive net. A
    -- pharmacy buys at PTR; the net payable is a BILL number and stays in
    -- net_display / the GST breakup below.
    'price_display',  public.inr_money(v_ptr),
    'price_caption',  v_ptr_cap,
    'price_locked',   false,
    'sale_price',     v_net,
    'has_net',        true,
    'net_display',    public.inr_money(v_net),
    'net_caption',    v_net_cap,
    'has_struck_mrp', true,
    'mrp_display',    public.inr_money(v_mrp),
    'has_discount',   true,
    'discount_label', v_chip,
    'has_margin',     true,
    'margin_pct',     v_pct,
    'margin_label',   case when (v_calc->>'margin_amount')::numeric < 0
                           then v_loss || ' ' || public.inr_money(abs((v_calc->>'margin_amount')::numeric))
                           else v_earn || ' ' || public.inr_money((v_calc->>'margin_amount')::numeric) end,
    'margin_chip',    jsonb_build_object(
      'label', v_chip,
      'bg',    coalesce(v_band->>'bg', '#EFF6FF'),
      'fg',    coalesce(v_band->>'fg', '#1E40AF'),
      'band',  coalesce(v_band->>'label', '')),
    'ribbon_top',     public._num_label(abs(v_pct)) || '%',
    'ribbon_bottom',  case when v_pct < 0 then v_over else v_suffix end,
    'has_ptr',        true,
    'ptr_display',    public.inr_money(v_ptr),
    'ptr_caption',    v_ptr_cap,
    'locked_prompt',  null,
    'card_price', jsonb_build_object(
      'has_mrp',       true,
      'mrp_label',     v_mrp_cap,
      'mrp_display',   public.inr_money(v_mrp),
      'strike_mrp',    true,
      'price_display', public.inr_money(v_ptr),
      'price_locked',  false,
      'has_ptr',       true,
      'ptr_label',     v_ptr_cap,
      'ptr_display',   public.inr_money(v_ptr),
      'ptr_bg',        '#1B7A43',
      'ptr_fg',        '#FFFFFF',
      'has_note',      false,
      'note',          '',
      'locked_title',  '',
      'locked_note',   '',
      'locked_cta',    '',
      'locked_route',  ''),
    'gst', jsonb_build_object(
      'title',           v_gst_title,
      'pct',             (v_calc->>'gst_pct')::numeric,
      'pct_display',     'GST ' || public._num_label((v_calc->>'gst_pct')::numeric) || '%',
      'is_igst',         (v_calc->>'is_igst')::boolean,
      'taxable_display', public.inr_money((v_calc->>'taxable')::numeric),
      'amount_display',  public.inr_money((v_calc->>'gst_amount')::numeric),
      'net_display',     public.inr_money(v_net),
      'lines',           v_lines),
    'source',         coalesce(p_row.pricing_source, ''),
    'raw', jsonb_build_object(
      'ptr',           v_ptr,
      'net_payable',   v_net,
      'taxable',       (v_calc->>'taxable')::numeric,
      'margin_amount', (v_calc->>'margin_amount')::numeric,
      'margin_pct',    v_pct));
end;
$function$;

-- ── 3. The Rx badge rides on every card surface ────────────────────────────
-- _cat_cards (home + catalogue) already sends `rx`; the storefront grid and
-- the search results did not, so the same product showed the badge on one
-- surface and not on another. One jsonb key each, nothing else moved.

CREATE OR REPLACE FUNCTION public.storefront_page(category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cfg AS (
    SELECT
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_initial_limit'), 250) AS initial_limit,
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_more_limit'), 100) AS more_limit
  ),
  lim AS (
    SELECT greatest(coalesce(nullif(page_limit, 0), (SELECT initial_limit FROM cfg)), 1) AS n
  ),
  disc AS (SELECT public.my_cart_discount_pct() AS pct),
  rows AS (
    SELECT f.*, row_number() over () AS _ord FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
  ),
  -- CMD #791 — one scan of order_items for the whole page.
  ov AS (
    SELECT public.purchase_overlay_map(array(SELECT r.id FROM rows r)) AS m
  ),
  n AS (SELECT count(*)::int AS returned FROM rows),
  t AS (SELECT public.get_storefront_count(category_filter)::bigint AS total)
  SELECT jsonb_build_object(
    'status','ok',
    'category', category_filter,
    'sort', 'default',
    'sort_options', public.storefront_sort_options('default'),
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'showing_label', (SELECT r.showing_label FROM rows r LIMIT 1),
    'total', (SELECT total FROM t),
    'count_label', to_char((SELECT total FROM t), 'FM9,99,99,999'),
    'banner_count_label', to_char((SELECT total FROM t), 'FM9,99,99,999') || '+ products',
    'show_all_label', 'Show all ' || to_char((SELECT total FROM t), 'FM9,99,99,999') || ' products',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (page_offset + (SELECT returned FROM n)) < (SELECT total FROM t),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_products'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'feed_end_label'), ''),
    'items', coalesce((
      SELECT jsonb_agg(
        (to_jsonb(r) - '_ord')
        || jsonb_build_object('availability',
             public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count),
                                   true))
        || jsonb_build_object('pack_badge', public.sf_pack_badge(src.pack_qty, src.pack_size, src.pack_type))
        || jsonb_build_object('type_chip', coalesce(nullif(btrim(src.pack_type),''), nullif(btrim(src.pack_size),''), ''))
        || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
        || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
        || jsonb_build_object('rx', public.rx_badge(src.rx_required))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id))
        || jsonb_build_object('purchase',
             coalesce((SELECT m -> r.id::text FROM ov), jsonb_build_object('has', false)))
        ORDER BY r._ord)
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id), '[]'::jsonb)
  );
$function$;

CREATE OR REPLACE FUNCTION public.storefront_search_page(search_term text, category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT NULL::integer, p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cfg AS (
    SELECT
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_initial_limit'), 250) AS initial_limit,
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_more_limit'), 100) AS more_limit
  ),
  lim AS (
    SELECT greatest(coalesce(nullif(page_limit, 0), (SELECT initial_limit FROM cfg)), 1) AS n
  ),
  disc AS (SELECT public.my_cart_discount_pct() AS pct),
  expanded AS (SELECT public.search_query_expand(search_term) AS x),
  probe AS (
    SELECT s.*, row_number() over () AS rn
    FROM public.search_medicines_priority(
           search_term, category_filter, page_offset, (SELECT n FROM lim) + 1, p_zone) s
  ),
  rows AS (SELECT * FROM probe WHERE rn <= (SELECT n FROM lim)),
  n AS (SELECT count(*)::int AS returned FROM rows),
  -- every row, once, with the family it belongs to and the full item payload
  item AS (
    SELECT r.rn, r.id,
           public.brand_family_key(r.product_name, src.marketer_canonical) AS fam,
           r.product_name,
           src.marketer_canonical AS mc,
           public._brand_root(r.product_name) AS root,
           (to_jsonb(r) - 'rn')
             || jsonb_build_object('availability',
                  public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count),
                                        true))
             || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
             || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
             || jsonb_build_object('rx', public.rx_badge(src.rx_required))
             || jsonb_build_object('pricing', public.storefront_pricing(
                  nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
                  (SELECT pct FROM disc), r.id))
             AS obj
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id
  ),
  fam AS (
    SELECT i.fam,
           min(i.rn) AS ord,
           count(*)::int AS n_variants,
           (array_agg(i.root       ORDER BY i.rn))[1] AS root,
           (array_agg(i.product_name ORDER BY i.rn))[1] AS lead_name,
           (array_agg(coalesce(i.mc, '') ORDER BY i.rn))[1] AS mc
      FROM item i
     GROUP BY i.fam
  ),
  blocks AS (
    SELECT f.ord,
      CASE WHEN f.n_variants >= 2 THEN
        jsonb_build_object(
          'kind', 'family',
          'family_key', f.fam,
          'title', (public._brand_split(f.lead_name, f.root))[1],
          'company_label', coalesce(mc.display, nullif(f.mc, ''), ''),
          'sub_label', CASE WHEN coalesce(mc.display, nullif(f.mc, ''), '') = '' THEN ''
                            ELSE replace(public.uic('search.family_by', 'by {company}'),
                                         '{company}', coalesce(mc.display, f.mc)) END,
          'variant_count', f.n_variants,
          'count_label', replace(public.uic('search.family_variants', '{n} variants'),
                                 '{n}', f.n_variants::text),
          'variants', (
            SELECT jsonb_agg(
                     i2.obj || jsonb_build_object(
                       'variant_label',
                       coalesce(nullif((public._brand_split(i2.product_name, i2.root))[2], ''),
                                i2.product_name))
                     ORDER BY i2.rn)
              FROM item i2 WHERE i2.fam = f.fam))
      ELSE
        jsonb_build_object(
          'kind', 'product',
          'item', (SELECT i3.obj FROM item i3 WHERE i3.fam = f.fam ORDER BY i3.rn LIMIT 1))
      END AS block
      FROM fam f
      LEFT JOIN public.medicine_company mc ON mc.canon = nullif(f.mc, '')
  )
  SELECT jsonb_build_object(
    'status','ok',
    'search_term', search_term,
    'category', category_filter,
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'result_count', (SELECT returned FROM n),
    'showing_label', (SELECT (page_offset + returned)::text FROM n)
                     || ' result(s) for "' || search_term || '"',
    'empty_label', 'No products match "' || search_term || '"',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (SELECT count(*) FROM probe) > (SELECT n FROM lim),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_results'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'search_end_label'), ''),
    -- CHANGE #790 — what a Hindi/Hinglish word was taken to mean, printed
    -- above the results so the shopper can see the search that actually ran.
    'expanded', (SELECT x FROM expanded),
    'expanded_prefix', public.uic('search.hinglish_prefix', 'Searching for'),
    -- CHANGE #790 / #747 — the switch itself, rendered verbatim.
    'zone_switch', public.catalogue_zone_switch(coalesce(p_zone, true)),
    -- CHANGE #790 — the grid renders THIS: one block per card, families
    -- already folded, in result order. `items` stays exactly as it was.
    'blocks', coalesce((SELECT jsonb_agg(b.block ORDER BY b.ord) FROM blocks b), '[]'::jsonb),
    'items', coalesce((
      SELECT jsonb_agg(i.obj ORDER BY i.rn) FROM item i), '[]'::jsonb)
  );
$function$;

-- ── 4. The product page reads the SAME field ───────────────────────────────
-- #1826 gave the PDP a two-line block; its sale row printed the GST-inclusive
-- net when entitled and the whole "Register and get approved…" SENTENCE when
-- not. #1895 makes that row the same one string every card prints — the PTR
-- amount or the word "PTR" — so a pharmacy sees one number in both places and
-- the sentence lives only in the prompt.
insert into public.storefront_ui_label (key, value, note) values
  ('pdp_sale_net_note', 'Net {net} · {gst}',
   'CHANGE #1895 — under the PTR on the product page')
on conflict (key) do nothing;

create or replace function public.pdp_price_lines(p_product_id bigint, p_mrp numeric)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_has_mrp boolean := (p_mrp is not null and p_mrp > 0);
  v_pb jsonb;
  v_mrp_cap text := public._pdp_label('mrp_caption', 'MRP');
  v_mrp_val text;
  v_mrp_note text := public._pdp_label('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price');
  v_sale_cap text := public._pdp_label('pdp_sale_price_caption', 'Sale price');
  v_sale_val text; v_sale_note text := ''; v_sale_amount boolean := false; v_sale_tone text := 'secondary';
  v_side text := '';
  v_sticky_main text;
begin
  v_mrp_val := case when v_has_mrp then public.inr_money(p_mrp)
                    else public._pdp_label('pdp_mrp_missing', 'Not printed on this pack') end;

  -- The SAME block every card reads. It has already decided entitlement, and
  -- it has already formatted the string.
  v_pb := public.storefront_pricing(p_mrp, null::numeric, p_product_id);

  v_sale_val    := coalesce(nullif(v_pb->>'price_display', ''),
                            public._pdp_label('ptr_caption', 'PTR'));
  v_sale_amount := not coalesce((v_pb->>'price_locked')::boolean, true);

  if v_sale_amount then
    v_sale_tone := 'primary';
    v_sale_note := replace(replace(
        public._pdp_label('pdp_sale_net_note', 'Net {net} · {gst}'),
        '{net}', coalesce(v_pb->>'net_display', '')),
        '{gst}', coalesce(v_pb#>>'{gst,pct_display}', ''));
    v_sale_note := btrim(regexp_replace(v_sale_note, '\s·\s*$', ''));
  else
    v_sticky_main := public._pdp_label('pdp_sticky_locked', 'Trade price on approval');
  end if;

  if v_has_mrp then
    v_side := btrim(public._pdp_label('pdp_sticky_mrp_prefix', 'MRP') || ' ' || public.inr_money(p_mrp));
  end if;

  return jsonb_build_object(
    'has', true,
    'mrp', jsonb_build_object(
      'caption',    v_mrp_cap,
      'value',      v_mrp_val,
      'has_amount', v_has_mrp,
      'has_note',   v_has_mrp,
      'note',       case when v_has_mrp then v_mrp_note else '' end,
      'tone',       'secondary'),
    'sale', jsonb_build_object(
      'caption',    v_sale_cap,
      'value',      v_sale_val,
      'has_amount', v_sale_amount,
      'has_note',   v_sale_note <> '',
      'note',       v_sale_note,
      'locked',     not v_sale_amount,
      'prompt',     v_pb -> 'locked_prompt',
      'tone',       v_sale_tone),
    'sticky', jsonb_build_object(
      'main',         coalesce(v_sticky_main, v_sale_val),
      'main_caption', public._pdp_label('pdp_sticky_sale_caption', 'Sale price'),
      'main_tone',    v_sale_tone,
      'has_side',     v_side <> '',
      'side',         v_side));
end $function$;

-- CHANGE #1895b — Om's 08-Sep sketch corrections, from his live reply on the card.
--
-- Five things were wrong against the sketch. Three of them are BACKEND facts and
-- live here; the other two (a green pack badge overlaying the photo, a solid
-- green ADD) are pure paint and live in the card widget.
--
--   * The sale line is a LABELLED row now: `sale_label` ("Sale price:") sits
--     before the value, and the value rides in a green badge whose colours the
--     backend sends (`sale_bg` / `sale_fg`), like every other chip on the card.
--
--   * The value is decided by the PTR ITSELF, not by who is looking. Om's note
--     on the sketch: "if PTR column in Medicine table have number then show
--     number, if no number then show 'PTR'". So `price_display` is the formatted
--     trade rate whenever medicine_pricing.ptr carries one, and the literal word
--     otherwise. `price_locked` follows the same fact — it is true only while the
--     card is showing the WORD, which is the only state whose tap has anywhere
--     to go.
--
--   * The MRP is no longer struck. It is a plain readable line ("MRP ₹260.38"),
--     not the emphasis of the card — the sale badge is.
--
-- The product page reads the card's own block now (`card_price.price_display`),
-- so "the same card everywhere" survives a future change to either one.
--
-- Idempotent: create-or-replace + on-conflict only.

-- ── 1. Copy ────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('sale_price_caption', 'Sale price:',
   'CHANGE #1895b — the label before the sale badge on every product card'),
  ('sale_badge_bg', '#1B7A43',
   'CHANGE #1895b — background of the green sale badge on the product card'),
  ('sale_badge_fg', '#FFFFFF',
   'CHANGE #1895b — text colour inside the green sale badge on the product card')
on conflict (key) do nothing;

update public.storefront_ui_label
   set value = 'PTR'
 where key = 'ptr_caption' and coalesce(value, '') = '';

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
  v_sale_cap text := coalesce((select value from storefront_ui_label where key = 'sale_price_caption'), 'Sale price:');
  v_sale_bg text := coalesce((select value from storefront_ui_label where key = 'sale_badge_bg'), '#1B7A43');
  v_sale_fg text := coalesce((select value from storefront_ui_label where key = 'sale_badge_fg'), '#FFFFFF');
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
      -- CHANGE #1895b — Om's sketch: the MRP is a PLAIN readable line. The
      -- emphasis of the card is the green sale badge under it, not a struck
      -- ceiling, so nothing here asks the card to draw a line through it.
      'strike_mrp',    false,
      'sale_label',    v_sale_cap,
      'sale_bg',       v_sale_bg,
      'sale_fg',       v_sale_fg,
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
      'strike_mrp',    false,
      'sale_label',    v_sale_cap,
      'sale_bg',       v_sale_bg,
      'sale_fg',       v_sale_fg,
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

-- ── 3. The product page reads the CARD'S block ─────────────────────────
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

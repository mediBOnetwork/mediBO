-- CMD #367 · feature_gaps row 177 — the PDP trust strip: FILL RATE ONLY.
--
-- Om's instruction, and the reason this row was cut down from the original
-- suggestion: mediBO does not know a product's expiry before it buys it, and
-- batch/expiry changes with every purchase. An "expiry promise" on the product
-- page would therefore be a promise we cannot keep, so NOTHING about expiry is
-- computed, stored or rendered here. What we do know, from our own inquiry
-- waterfall, is whether suppliers actually filled this product when a buyer
-- asked for it — that is the fill rate — plus the catalog's cold-chain flag.
--
-- Absence is explicit: a product nobody has asked for yet has has:false and
-- shows no chip at all, rather than an invented 100%.

-- Thresholds and copy are config, not code: retuning the strip is an UPDATE.
insert into app_settings (key, value) values
  ('pdp_trust_config', jsonb_build_object(
     'window_days',     180,
     'min_asks',        3,
     'good_pct',        85,
     'ok_pct',          60,
     'title',           'Supply record',
     'fill_suffix',     'fill rate',
     'fill_note_fmt',   'Filled {filled} of {asks} asks · last {days} days',
     'fill_low_asks',   'Not enough supply history yet',
     'cold_label',      'Cold chain',
     'cold_note',       'Moved in a cold box'))
on conflict (key) do nothing;

-- The inquiry waterfall is the only honest record of "did a supplier fill it".
create index if not exists idx_inquiry_product_batch
  on public.inquiry (product_id, batch_date desc);

create or replace function public.product_trust_strip(
  p_product_id bigint,
  p_cold_chain boolean default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_cfg    jsonb := coalesce((select value from app_settings where key='pdp_trust_config'), '{}'::jsonb);
  v_days   int  := coalesce((v_cfg->>'window_days')::int, 180);
  v_min    int  := coalesce((v_cfg->>'min_asks')::int, 3);
  v_good   int  := coalesce((v_cfg->>'good_pct')::int, 85);
  v_okp    int  := coalesce((v_cfg->>'ok_pct')::int, 60);
  v_asks   int  := 0;
  v_filled int  := 0;
  v_pct    int;
  v_tone   text;
  v_chips  jsonb := '[]'::jsonb;
  v_fill   jsonb;
  v_cold   jsonb;
  v_has_fill boolean := false;
  v_is_cold boolean := coalesce(p_cold_chain, false);
begin
  -- An "ask" is a resolved inquiry: the waterfall either found a supplier or
  -- ran out of them. A still-pending inquiry is not evidence either way and is
  -- excluded, so a busy day cannot drag the number down.
  select count(*),
         count(*) filter (where q.current_status = 'Available')
    into v_asks, v_filled
  from inquiry q
  where q.product_id = p_product_id
    and q.current_status in ('Available', 'No Supplier Available')
    and coalesce(q.batch_date, (q.created_at at time zone 'Asia/Kolkata')::date)
        >= (now() at time zone 'Asia/Kolkata')::date - v_days;

  v_has_fill := (v_asks >= v_min);

  if v_has_fill then
    v_pct  := round(v_filled * 100.0 / v_asks)::int;
    v_tone := case when v_pct >= v_good then 'success'
                   when v_pct >= v_okp  then 'warning'
                   else 'danger' end;
    v_fill := jsonb_build_object(
      'has',   true,
      'pct',   v_pct,
      'asks',  v_asks,
      'filled', v_filled,
      'label', v_pct::text || '% ' || coalesce(v_cfg->>'fill_suffix','fill rate'),
      'note',  replace(replace(replace(
                 coalesce(v_cfg->>'fill_note_fmt',''),
                 '{filled}', v_filled::text), '{asks}', v_asks::text), '{days}', v_days::text),
      'tone',  v_tone);
    v_chips := v_chips || jsonb_build_array(
      jsonb_build_object('key','fill_rate',
                         'label', v_fill->>'label',
                         'note',  v_fill->>'note',
                         'tone',  v_tone));
  else
    v_fill := jsonb_build_object(
      'has', false, 'pct', 0, 'asks', v_asks, 'filled', v_filled,
      'label', '', 'note', coalesce(v_cfg->>'fill_low_asks',''), 'tone', 'neutral');
  end if;

  if v_is_cold then
    v_cold := jsonb_build_object(
      'has',   true,
      'label', coalesce(v_cfg->>'cold_label','Cold chain'),
      'note',  coalesce(v_cfg->>'cold_note',''),
      'tone',  'info');
    v_chips := v_chips || jsonb_build_array(
      jsonb_build_object('key','cold_chain',
                         'label', v_cold->>'label',
                         'note',  v_cold->>'note',
                         'tone',  'info'));
  else
    v_cold := jsonb_build_object('has', false, 'label', '', 'note', '', 'tone', 'neutral');
  end if;

  return jsonb_build_object(
    'has',        (jsonb_array_length(v_chips) > 0),
    'title',      coalesce(v_cfg->>'title',''),
    'chips',      v_chips,
    'fill_rate',  v_fill,
    'cold_chain', v_cold);
end $$;

grant execute on function public.product_trust_strip(bigint, boolean) to authenticated, anon;
CREATE OR REPLACE FUNCTION public.product_detail(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  m               record;
  v_imgs          jsonb;
  v_overview      jsonb;
  v_sections      jsonb;
  v_similar       jsonb := '[]'::jsonb;
  v_hist_qty      numeric;
  v_idx_ready     boolean;
  v_mrp           numeric;
  v_gst           text;
  v_labels        jsonb;
  v_acct          uuid;
  v_is_wishlisted boolean := false;
  v_trust         jsonb;
BEGIN
  v_labels := public.storefront_labels();

  SELECT * INTO m FROM "MEDICINE" WHERE id = p_product_id;
  IF m.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'labels', v_labels);
  END IF;

  v_mrp := nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric;
  v_gst := nullif(replace(btrim(coalesce(m.gst_percent::text,'')), '%', ''), '');

  SELECT coalesce(jsonb_agg(u) FILTER (WHERE u IS NOT NULL AND u <> ''), '[]'::jsonb)
    INTO v_imgs
  FROM unnest(array[m.image_url_1, m.image_url_2, m.image_url_3, m.image_url_4, m.image_url_5]) u;

  SELECT coalesce(jsonb_agg(jsonb_build_object('label', l, 'value', val))
                  FILTER (WHERE nullif(btrim(val),'') IS NOT NULL), '[]'::jsonb)
    INTO v_overview
  FROM (VALUES
    ('Composition',       m.salt_composition),
    ('Manufacturer',      m.marketer),
    ('Therapeutic class', m.therapeutic_class),
    ('Chemical class',    m.chemical_class),
    ('Action class',      m.action_class),
    ('Storage',           m.storage),
    ('Habit forming',     m.habit_forming)
  ) t(l, val);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'title', ti,
           'body', btrim(regexp_replace(bo, 'show\s?more|show\s?less', '', 'gi'))))
         FILTER (WHERE nullif(btrim(bo),'') IS NOT NULL), '[]'::jsonb)
    INTO v_sections
  FROM (VALUES
    ('Introduction', m.product_introduction),
    ('Uses',         m.uses),
    ('Benefits',     m.benefits),
    ('Side effects', m.side_effects),
    ('How it works', m.how_it_works)
  ) t(ti, bo);

  -- Similar rail: same predicate as idx_medicine_salt_buyable partial index.
  v_idx_ready := to_regclass('public.idx_medicine_salt_buyable') IS NOT NULL;
  IF v_idx_ready AND nullif(btrim(m.salt_composition),'') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id',         s.id,
             'name',       coalesce(s.product_name,''),
             'company',    coalesce(s.marketer,''),
             'pack_label', coalesce(nullif(btrim(s.pack_type),''), nullif(btrim(s.pack_size),''), ''),
             'form_chip',  coalesce(nullif(btrim(s.pack_qty),''), nullif(btrim(s.pack_size),''), ''),
             'pack_type',  coalesce(s.pack_type,''),
             'pack_qty',   coalesce(s.pack_qty,''),
             'pack_size',  coalesce(s.pack_size,''),
             'image',      coalesce(s.image_url_1,''),
             'mrp_label',  coalesce(
               CASE WHEN nullif(regexp_replace(coalesce(s.mrp::text,''),'[^0-9.]','','g'),'') IS NOT NULL
                    THEN public.inr_money(nullif(regexp_replace(coalesce(s.mrp::text,''),'[^0-9.]','','g'),'')::numeric)
               END, ''))), '[]'::jsonb)
      INTO v_similar
    FROM (SELECT * FROM "MEDICINE" s
           WHERE s.salt_composition = m.salt_composition
             AND s.id <> m.id
             AND s.buyable IS TRUE
           ORDER BY s.sales_count DESC NULLS LAST LIMIT 10) s;
  END IF;

  -- History and wishlist are keyed to the ACCOUNT, never to auth.uid() directly.
  v_acct := public.my_customer_id();
  IF v_acct IS NOT NULL THEN
    SELECT sum(oi.quantity) INTO v_hist_qty
    FROM order_items oi
    WHERE oi.product_id = p_product_id
      AND oi.order_date >= current_date - 90
      AND oi.order_id IN (SELECT o.id FROM orders o WHERE o.customer_id = v_acct);

    -- Wishlist state for the current account.
    v_is_wishlisted := EXISTS (
      SELECT 1 FROM wishlist_items
      WHERE account_id = v_acct AND product_id = p_product_id
    );
  END IF;

  -- Row 177 — the trust strip. Fill rate and cold chain ONLY.
  -- No expiry promise anywhere: expiry and batch change with every purchase,
  -- so a minimum-expiry claim made before the stock is bought would be false.
  v_trust := public.product_trust_strip(p_product_id, m.cold_chain);

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     m.id,
    'labels', v_labels,
    'header', jsonb_build_object(
      'name',        coalesce(m.product_name,''),
      'company',     coalesce(m.marketer,''),
      'pack_label',  coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                              nullif(btrim(coalesce(m.pack_size,'')),''), ''),
      'form_chip',   coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),''), ''),
      'rx_required', (coalesce(m.rx_required::text,'') ILIKE '%yes%'
                      OR lower(coalesce(m.rx_required::text,'')) IN ('true','t','1')),
      'images',      v_imgs),
    'price', jsonb_build_object(
      'has_mrp',   (v_mrp IS NOT NULL),
      'mrp_label', coalesce(CASE WHEN v_mrp IS NOT NULL THEN public.inr_money(v_mrp) END, ''),
      'mrp_note',  'MRP',
      'has_gst',   (v_gst IS NOT NULL),
      'gst_label', coalesce(CASE WHEN v_gst IS NOT NULL THEN 'GST '||v_gst||'%' END, ''),
      'scheme',    (lower(coalesce(m.has_scheme::text,'')) IN ('true','t','yes','1'))),
    'availability', public.storefront_cta(public.storefront_effective_count(m.id, m.supplier_count)),
    'pricing',      public.storefront_pricing(v_mrp, null::numeric, p_product_id),
    'stock', jsonb_build_object(
      'buyable',            (m.buyable IS TRUE),
      'has_supplier_label', (nullif(btrim(coalesce(m.supplier_label,'')),'') IS NOT NULL),
      'supplier_label',     coalesce(m.supplier_label,'')),
    'trust',         v_trust,
    'overview',      v_overview,
    'has_highlight', (nullif(btrim(coalesce(m.product_highlight,'')),'') IS NOT NULL),
    'highlight',     coalesce(nullif(btrim(coalesce(m.product_highlight,'')),''), ''),
    'sections',      v_sections,
    'similar',       v_similar,
    'similar_ready', v_idx_ready,
    'show_wishlist', public.viewer_is_approved_customer(),
    'is_wishlisted', v_is_wishlisted,
    'my_history', jsonb_build_object(
      'has',   (v_hist_qty IS NOT NULL AND v_hist_qty > 0),
      'label', coalesce(CASE WHEN v_hist_qty IS NOT NULL AND v_hist_qty > 0
                             THEN 'You ordered '||v_hist_qty::bigint||' in the last 90 days'
                        END, '')));
END;
$function$

;

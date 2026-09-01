-- CMD #451 row 84 — product_detail's stock block: a status-blocked product is
-- not buyable, shows no operator supplier chip, and carries its own reason.
create or replace function public.product_detail(p_product_id bigint) returns jsonb language sql stable security definer set search_path to 'public' as $fn$
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
    -- CMD #451 row 84: the supplier chip ("AV - 12S") contradicted the block on
    -- a NOT FOR SALE / BANNED product, and it leaked an operator-facing string
    -- to anonymous visitors. A status-blocked product is not buyable, carries no
    -- supplier chip, and states WHY in the backend's own words instead.
    'stock', jsonb_build_object(
      'buyable',            (m.buyable IS TRUE) AND public.med_status_sellable(m.status),
      'has_supplier_label', public.med_status_sellable(m.status)
                            AND public.get_my_role() IN ('admin','super_admin')
                            AND (nullif(btrim(coalesce(m.supplier_label,'')),'') IS NOT NULL),
      'supplier_label',     CASE WHEN public.med_status_sellable(m.status)
                                  AND public.get_my_role() IN ('admin','super_admin')
                                 THEN coalesce(m.supplier_label,'') ELSE '' END,
      'status_block',       public.med_status_block(m.status),
      'blocked_by_status',  NOT public.med_status_sellable(m.status)),
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
$fn$;

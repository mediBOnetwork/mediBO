-- CHANGE #175 — Distributor scheme engine (5 features)
-- Extends medicine_pricing with scheme fields + 5 new RPCs

-- ── 1. Schema additions ───────────────────────────────────────────────
ALTER TABLE medicine_pricing
  ADD COLUMN IF NOT EXISTS scheme_type      text,          -- 'free_qty'|'pct'|'slab'
  ADD COLUMN IF NOT EXISTS scheme_pct       numeric,       -- for pct-type schemes
  ADD COLUMN IF NOT EXISTS scheme_starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS scheme_ends_at   timestamptz,
  ADD COLUMN IF NOT EXISTS scheme_ready     boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN medicine_pricing.scheme_ready IS
  'true only when a valid scheme exists: (free_qty type AND buy_qty>0 AND free_qty>0) OR (pct type AND pct>0)';

-- ── 2. Scheme compute helper ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._scheme_compute(
  p_buy_qty      numeric,
  p_free_qty     numeric,
  p_ptr          numeric,
  p_mrp          numeric,
  p_line_qty     numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN p_buy_qty IS NULL OR p_buy_qty <= 0 OR p_free_qty IS NULL OR p_free_qty <= 0 THEN
      jsonb_build_object('ok', false)
    ELSE
      jsonb_build_object(
        'ok',              true,
        'buy_qty',         p_buy_qty,
        'free_qty',        p_free_qty,
        -- effective per unit = ptr / (buy_qty + free_qty) when ptr available, else mrp
        'effective_per_unit',
          round(coalesce(nullif(p_ptr,0), nullif(p_mrp,0), 0)
                / (p_buy_qty + p_free_qty), 2),
        'effective_base',  CASE WHEN p_ptr IS NOT NULL AND p_ptr > 0 THEN 'ptr' ELSE 'mrp' END,
        -- for a given line qty, how many free units apply
        'free_for_qty',
          CASE WHEN p_line_qty IS NOT NULL AND p_line_qty > 0
               THEN floor(p_line_qty / p_buy_qty) * p_free_qty
               ELSE NULL END,
        -- units needed to unlock the next free tier
        'units_to_next',
          CASE WHEN p_line_qty IS NOT NULL AND p_line_qty > 0
               AND (p_line_qty % p_buy_qty) > 0
               THEN p_buy_qty - (p_line_qty % p_buy_qty)
               ELSE NULL END
      )
  END
$$;

-- ── 3. Extend _pricing_block to include scheme badge ──────────────────
-- The existing _pricing_block already outputs ribbon_top/bottom for margin.
-- We augment it by adding scheme output. Callers pick up the new keys verbatim.
CREATE OR REPLACE FUNCTION public._pricing_block(
  p_mrp          numeric,
  p_row          medicine_pricing,
  p_discount_pct numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_has   boolean := (p_mrp is not null and p_mrp > 0);
  v_mrp   numeric := coalesce(p_mrp, 0);
  v_cap   text := coalesce((select value from storefront_ui_label where key = 'price_caption'), 'MRP');
  v_net_cap text := coalesce((select value from storefront_ui_label where key = 'net_rate_caption'), 'NET');
  v_ptr_cap text := coalesce((select value from storefront_ui_label where key = 'ptr_caption'), 'PTR');
  v_earn  text := coalesce((select value from storefront_ui_label where key = 'margin_earn_prefix'), 'You earn');
  v_suffix text := coalesce((select value from storefront_ui_label where key = 'margin_chip_suffix'), 'margin');
  v_loss text := coalesce((select value from storefront_ui_label where key = 'margin_loss_prefix'), 'Above MRP by');
  v_over text := coalesce((select value from storefront_ui_label where key = 'margin_chip_over_suffix'), 'above MRP');
  v_gst_title text := coalesce((select value from storefront_ui_label where key = 'gst_breakup_title'), 'GST breakup');
  v_tax_label text := coalesce((select value from storefront_ui_label where key = 'gst_taxable_label'), 'Taxable value');
  v_base  jsonb;
  v_calc  jsonb;
  v_band  jsonb;
  v_pct   numeric;
  v_net   numeric;
  v_chip  text;
  v_lines jsonb;
  v_scheme jsonb;
  v_eff   numeric;
  v_scheme_ready boolean;
  v_days_left integer;
begin
  v_base := jsonb_build_object(
    'has_price',      v_has,
    'mrp',            v_mrp,
    'sale_price',     v_mrp,
    'price_display',  case when v_has then public.inr_money(v_mrp) else '' end,
    'price_caption',  case when v_has then v_cap else '' end,
    'mrp_display',    '',
    'discount_pct',   0,
    'has_discount',   false,
    'discount_label', '',
    'ribbon_top',     '',
    'ribbon_bottom',  '',
    'margin_label',   '',
    'display_mode',   'mrp_only',
    'pricing_ready',  false,
    'has_net',        false,
    'net_display',    '',
    'net_caption',    '',
    'has_margin',     false,
    'margin_pct',     null,
    'margin_chip',    null,
    'has_ptr',        false,
    'ptr_display',    '',
    'ptr_caption',    '',
    'has_scheme',     false,
    'scheme_text',    '',
    'scheme_badge',   null,
    'scheme_effective', null,
    'scheme_expiry',  null,
    'has_struck_mrp', false,
    'gst',            null);

  -- compute scheme output (no role gate — badge is visible to all approved buyers)
  v_scheme_ready := coalesce(p_row.scheme_ready, false)
                    AND coalesce(p_row.scheme_buy_qty, 0) > 0
                    AND coalesce(p_row.scheme_free_qty, 0) > 0;

  if v_scheme_ready then
    v_eff := round(coalesce(nullif(p_row.ptr,0), nullif(v_mrp,0), 0)
                   / (p_row.scheme_buy_qty + p_row.scheme_free_qty), 2);
    -- days left (null if no end date, -1 if expired)
    v_days_left := case when p_row.scheme_ends_at is not null
                        then extract(day from (p_row.scheme_ends_at - now()))::integer
                        else null end;
    -- Build effective display string e.g. "5+1 = ₹82/unit"
    v_scheme := jsonb_build_object(
      'has_scheme',   true,
      'scheme_text',  coalesce(nullif(btrim(coalesce(p_row.scheme_text,'')), ''),
                               p_row.scheme_buy_qty::text || '+' ||
                               p_row.scheme_free_qty::int::text || ' FREE'),
      'scheme_badge', jsonb_build_object(
        'label', p_row.scheme_buy_qty::text || '+' || p_row.scheme_free_qty::int::text || ' FREE',
        'bg', '#D1FAE5', 'fg', '#065F46'),
      'scheme_effective', jsonb_build_object(
        'label', 'Effective ' || public.inr_money(v_eff) || '/unit',
        'per_unit', v_eff,
        'per_unit_display', public.inr_money(v_eff)),
      'scheme_expiry', case
        when v_days_left is null then null
        when v_days_left < 0 then jsonb_build_object('label','Scheme expired','urgent',true)
        when v_days_left = 0 then jsonb_build_object('label','Ends today','urgent',true)
        when v_days_left <= 3 then jsonb_build_object('label','Ends in ' || v_days_left || ' day' || case when v_days_left=1 then '' else 's' end,'urgent',true)
        else jsonb_build_object('label','Ends in ' || v_days_left || ' days','urgent',false)
      end
    );
    v_base := v_base || v_scheme;
  end if;

  -- Role gate for pricing block (approved customer or admin)
  if not v_has or not coalesce(p_row.pricing_ready, false)
     or not (public.viewer_is_approved_customer()
             or public.get_my_role() = any (array['admin','super_admin'])) then
    return v_base;
  end if;

  v_calc := public._pricing_compute(v_mrp, p_row.ptr, p_row.gst_pct,
              coalesce(p_row.discount_pct, 0),
              p_row.scheme_buy_qty, p_row.scheme_free_qty, false);
  if v_calc is null then
    return v_base;
  end if;

  v_net := (v_calc->>'net_payable')::numeric;
  v_pct := (v_calc->>'margin_pct')::numeric;

  select b into v_band
    from jsonb_array_elements(
           coalesce((select value from app_settings where key = 'pricing_margin_bands'), '[]'::jsonb)) b
   where (b->>'min_pct')::numeric <= v_pct
   order by (b->>'min_pct')::numeric desc
   limit 1;

  v_chip := case when v_pct < 0
                 then trim(public._num_label(abs(v_pct)) || '% ' || v_over)
                 else trim(public._num_label(v_pct) || '% ' || v_suffix)
            end;

  v_lines := jsonb_build_array(
    jsonb_build_object('label', v_tax_label,
                       'value', public.inr_money((v_calc->>'taxable')::numeric)))
    || case when (v_calc->>'is_igst')::boolean
         then jsonb_build_array(jsonb_build_object(
                'label', 'IGST ' || public._num_label((v_calc->>'gst_pct')::numeric) || '%',
                'value', public.inr_money((v_calc->>'igst')::numeric)))
         else jsonb_build_array(
                jsonb_build_object(
                  'label', 'CGST ' || public._num_label((v_calc->>'gst_pct')::numeric / 2) || '%',
                  'value', public.inr_money((v_calc->>'cgst')::numeric)),
                jsonb_build_object(
                  'label', 'SGST ' || public._num_label((v_calc->>'gst_pct')::numeric / 2) || '%',
                  'value', public.inr_money((v_calc->>'sgst')::numeric)))
       end;

  return v_base || jsonb_build_object(
    'display_mode',   'full',
    'pricing_ready',  true,
    'price_display',  public.inr_money(v_net),
    'price_caption',  v_net_cap,
    'sale_price',     v_net,
    'has_net',        true,
    'net_display',    public.inr_money(v_net),
    'net_caption',    v_net_cap,
    'has_struck_mrp', true,
    'mrp_display',    public.inr_money(v_mrp),
    'has_discount',   true,
    'discount_label', v_chip,
    'has_margin',     ((v_calc->>'margin_amount')::numeric is not null),
    'margin_pct',     v_pct,
    'margin_label',   case when (v_calc->>'margin_amount')::numeric < 0
                           then v_loss || ' ' || public.inr_money(abs((v_calc->>'margin_amount')::numeric))
                           else v_earn || ' ' || public.inr_money((v_calc->>'margin_amount')::numeric)
                      end,
    'margin_chip', jsonb_build_object(
      'label', v_chip,
      'bg',    coalesce(v_band->>'bg', '#EFF6FF'),
      'fg',    coalesce(v_band->>'fg', '#1E40AF'),
      'band',  coalesce(v_band->>'label', '')),
    'ribbon_top',     public._num_label(abs(v_pct)) || '%',
    'ribbon_bottom',  case when v_pct < 0 then v_over else v_suffix end,
    'has_ptr',        true,
    'ptr_display',    public.inr_money((v_calc->>'ptr')::numeric),
    'ptr_caption',    v_ptr_cap,
    'has_scheme',     v_scheme_ready,
    'has_scheme',     v_scheme_ready,
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
      'ptr',           (v_calc->>'ptr')::numeric,
      'net_payable',   v_net,
      'taxable',       (v_calc->>'taxable')::numeric,
      'margin_amount', (v_calc->>'margin_amount')::numeric,
      'margin_pct',    v_pct));
end;
$$;

-- ── 4. product_pricing_upsert — add scheme_ready logic ────────────────
CREATE OR REPLACE FUNCTION public.product_pricing_upsert(
  p_product_id bigint,
  p_fields     jsonb,
  p_source     text DEFAULT 'manual'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_role text := public.get_my_role();
  v_ptr  numeric;
  v_gst  numeric;
  v_buy  numeric;
  v_free numeric;
  v_pct  numeric;
  v_tax  numeric;
  v_net  numeric;
  v_mrp  numeric;
  v_ready boolean;
  v_scheme_ready boolean;
  v_existing_updated_at timestamptz;
  v_existing_source text;
  -- source rank: manual > supplier_bill > other
  v_rank int;
  v_existing_rank int;
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  -- rank: manual=2, supplier_bill=1, else 0
  v_rank := case p_source when 'manual' then 2 when 'supplier_bill' then 1 else 0 end;

  -- check existing
  select pricing_updated_at, pricing_source
    into v_existing_updated_at, v_existing_source
  from medicine_pricing where product_id = p_product_id;

  if found then
    v_existing_rank := case v_existing_source when 'manual' then 2 when 'supplier_bill' then 1 else 0 end;
    -- never let a lower-rank source overwrite a higher-rank entry
    if v_rank < v_existing_rank then
      return jsonb_build_object('ok', true, 'skipped', 'lower_rank_source');
    end if;
  end if;

  -- get MRP for compute
  select nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]','','g'),'')::numeric
    into v_mrp from "MEDICINE" m where m.id = p_product_id;

  v_ptr  := (p_fields->>'ptr')::numeric;
  v_gst  := (p_fields->>'gst_pct')::numeric;
  v_buy  := (p_fields->>'scheme_buy_qty')::numeric;
  v_free := (p_fields->>'scheme_free_qty')::numeric;
  v_pct  := (p_fields->>'scheme_pct')::numeric;

  -- compute stored taxable/net_payable
  if v_ptr > 0 and v_gst is not null then
    declare v_c jsonb;
    begin
      v_c := public._pricing_compute(v_mrp, v_ptr, v_gst,
               coalesce((p_fields->>'discount_pct')::numeric, 0),
               v_buy, v_free, false);
      v_tax := (v_c->>'taxable')::numeric;
      v_net := (v_c->>'net_payable')::numeric;
    end;
  end if;

  v_ready := (v_ptr > 0 AND v_gst IS NOT NULL);
  v_scheme_ready := (
    (coalesce((p_fields->>'scheme_type'),'') = 'free_qty'
      AND v_buy > 0 AND v_free > 0)
    OR (coalesce((p_fields->>'scheme_type'),'') = 'pct'
      AND v_pct > 0)
    OR (v_buy > 0 AND v_free > 0)  -- implicit free_qty type
  );

  insert into medicine_pricing (
    product_id, ptr, gst_pct, scheme_text, scheme_buy_qty, scheme_free_qty,
    discount_pct, taxable_amount, net_payable, pricing_ready,
    pricing_source, pricing_updated_at, updated_by,
    scheme_type, scheme_pct, scheme_starts_at, scheme_ends_at, scheme_ready
  ) values (
    p_product_id,
    v_ptr,
    v_gst,
    p_fields->>'scheme_text',
    v_buy,
    v_free,
    (p_fields->>'discount_pct')::numeric,
    v_tax,
    v_net,
    coalesce(v_ready, false),
    p_source,
    now(),
    auth.uid(),
    p_fields->>'scheme_type',
    v_pct,
    (p_fields->>'scheme_starts_at')::timestamptz,
    (p_fields->>'scheme_ends_at')::timestamptz,
    coalesce(v_scheme_ready, false)
  )
  on conflict (product_id) do update set
    ptr                = coalesce(excluded.ptr, medicine_pricing.ptr),
    gst_pct            = coalesce(excluded.gst_pct, medicine_pricing.gst_pct),
    scheme_text        = coalesce(excluded.scheme_text, medicine_pricing.scheme_text),
    scheme_buy_qty     = coalesce(excluded.scheme_buy_qty, medicine_pricing.scheme_buy_qty),
    scheme_free_qty    = coalesce(excluded.scheme_free_qty, medicine_pricing.scheme_free_qty),
    discount_pct       = coalesce(excluded.discount_pct, medicine_pricing.discount_pct),
    taxable_amount     = coalesce(excluded.taxable_amount, medicine_pricing.taxable_amount),
    net_payable        = coalesce(excluded.net_payable, medicine_pricing.net_payable),
    pricing_ready      = excluded.pricing_ready,
    pricing_source     = excluded.pricing_source,
    pricing_updated_at = excluded.pricing_updated_at,
    updated_by         = excluded.updated_by,
    scheme_type        = coalesce(excluded.scheme_type, medicine_pricing.scheme_type),
    scheme_pct         = coalesce(excluded.scheme_pct, medicine_pricing.scheme_pct),
    scheme_starts_at   = coalesce(excluded.scheme_starts_at, medicine_pricing.scheme_starts_at),
    scheme_ends_at     = coalesce(excluded.scheme_ends_at, medicine_pricing.scheme_ends_at),
    scheme_ready       = excluded.scheme_ready;

  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'pricing_ready', v_ready, 'scheme_ready', coalesce(v_scheme_ready, false));
end;
$$;

-- ── 5. cart_apply_schemes — auto-free cart lines ──────────────────────
CREATE OR REPLACE FUNCTION public.cart_apply_schemes(
  p_customer_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_uid uuid := coalesce(p_customer_id, auth.uid());
  v_role text := public.get_my_role();
  v_lines jsonb;
  v_free_lines jsonb := '[]'::jsonb;
  v_total_savings numeric := 0;
  v_line record;
  v_sc public._scheme_compute%RETURN_TYPE;
  v_free_qty numeric;
  v_label_prefix text := coalesce(
    (select value from storefront_ui_label where key = 'scheme_free_line_prefix'), 'free');
  v_label_suffix text := coalesce(
    (select value from storefront_ui_label where key = 'scheme_free_line_suffix'), 'scheme');
begin
  if v_role not in ('admin','super_admin') and auth.uid() != v_uid then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  -- get active cart lines for customer
  select jsonb_agg(row_to_json(r))
    into v_lines
  from (
    select ci.product_id, ci.qty,
           coalesce(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),''),'0')::numeric as mrp,
           mp.ptr, mp.scheme_buy_qty, mp.scheme_free_qty, mp.scheme_ready,
           m."NAME" as name
    from   cart_items ci
    join   "MEDICINE" m on m.id = ci.product_id
    left join medicine_pricing mp on mp.product_id = ci.product_id
    where  ci.customer_id = v_uid
      and  ci.qty > 0
  ) r;

  if v_lines is null then
    return jsonb_build_object('ok', true, 'free_lines', '[]'::jsonb,
                              'total_savings', 0, 'total_savings_display', '₹0');
  end if;

  for v_line in select * from jsonb_to_recordset(v_lines) as x(
    product_id bigint, qty numeric, mrp numeric, ptr numeric,
    scheme_buy_qty numeric, scheme_free_qty numeric, scheme_ready boolean, name text
  ) loop
    continue when not coalesce(v_line.scheme_ready, false);
    continue when coalesce(v_line.scheme_buy_qty, 0) <= 0;

    v_free_qty := floor(v_line.qty / v_line.scheme_buy_qty) * v_line.scheme_free_qty;
    continue when v_free_qty <= 0;

    -- savings = free_qty × effective price (ptr if available, else mrp)
    declare v_unit_price numeric := coalesce(nullif(v_line.ptr, 0), v_line.mrp, 0);
    begin
      v_total_savings := v_total_savings + (v_free_qty * v_unit_price);
    end;

    v_free_lines := v_free_lines || jsonb_build_array(jsonb_build_object(
      'product_id',   v_line.product_id,
      'name',         v_line.name,
      'free_qty',     v_free_qty,
      'free_qty_display', v_free_qty::int::text || ' ' || v_label_prefix,
      'label',        v_free_qty::int::text || ' ' || v_label_prefix || ' — ' ||
                      v_line.scheme_buy_qty::int::text || '+' ||
                      v_line.scheme_free_qty::int::text || ' ' || v_label_suffix,
      'price_display','₹0',
      'scheme_text',  v_line.scheme_buy_qty::int::text || '+' ||
                      v_line.scheme_free_qty::int::text
    ));
  end loop;

  return jsonb_build_object(
    'ok',                   true,
    'free_lines',           v_free_lines,
    'total_savings',        round(v_total_savings, 2),
    'total_savings_display', public.inr_money(round(v_total_savings, 2))
  );
end;
$$;

-- ── 6. cart_scheme_nudge — "add N more to unlock" ────────────────────
CREATE OR REPLACE FUNCTION public.cart_scheme_nudge(
  p_customer_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_uid uuid := coalesce(p_customer_id, auth.uid());
  v_nudges jsonb := '[]'::jsonb;
  v_line record;
  v_gap numeric;
  v_add_label text := coalesce(
    (select value from storefront_ui_label where key = 'scheme_nudge_prefix'), 'Add');
  v_get_label text := coalesce(
    (select value from storefront_ui_label where key = 'scheme_nudge_suffix'), 'more → get');
  v_free_label text := coalesce(
    (select value from storefront_ui_label where key = 'scheme_nudge_free'), 'free');
begin
  for v_line in
    select ci.product_id, ci.qty, mp.scheme_buy_qty, mp.scheme_free_qty, m."NAME" as name
    from   cart_items ci
    join   "MEDICINE" m on m.id = ci.product_id
    join   medicine_pricing mp on mp.product_id = ci.product_id
    where  ci.customer_id = v_uid
      and  ci.qty > 0
      and  mp.scheme_ready = true
      and  mp.scheme_buy_qty > 0
      and  mp.scheme_free_qty > 0
  loop
    v_gap := v_line.scheme_buy_qty - (v_line.qty % v_line.scheme_buy_qty);
    -- only nudge when 1 or 2 units away from the next free tier
    continue when v_gap <= 0 or v_gap > 2;

    v_nudges := v_nudges || jsonb_build_array(jsonb_build_object(
      'product_id', v_line.product_id,
      'name',       v_line.name,
      'gap',        v_gap,
      'free_qty',   v_line.scheme_free_qty,
      'label',      v_add_label || ' ' || v_gap::int::text || ' more → get ' ||
                    v_line.scheme_free_qty::int::text || ' ' || v_free_label
    ));
  end loop;

  return jsonb_build_object('ok', true, 'nudges', v_nudges);
end;
$$;

-- ── 7. schemes_feed — storefront schemes listing ──────────────────────
CREATE OR REPLACE FUNCTION public.schemes_feed(
  p_zone_id     uuid DEFAULT NULL,
  p_customer_id uuid DEFAULT NULL,
  p_offset      int  DEFAULT 0,
  p_limit       int  DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_uid   uuid := coalesce(p_customer_id, auth.uid());
  v_role  text := public.get_my_role();
  v_rows  jsonb;
  v_count bigint;
  v_title text := coalesce(
    (select value from storefront_ui_label where key = 'schemes_feed_title'), 'Active Schemes');
  v_empty text := coalesce(
    (select value from storefront_ui_label where key = 'schemes_feed_empty'), 'No active schemes right now');
begin
  if v_role not in ('admin','super_admin') and not public.viewer_is_approved_customer() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select count(*), jsonb_agg(row_to_json(r))
    into v_count, v_rows
  from (
    select
      mp.product_id,
      m."NAME"    as name,
      m."COMPANY" as company,
      coalesce(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),''),'0')::numeric as mrp,
      mp.scheme_buy_qty,
      mp.scheme_free_qty,
      mp.scheme_text,
      mp.scheme_ends_at,
      mp.scheme_ready,
      -- badge label e.g. "5+1 FREE"
      mp.scheme_buy_qty::int::text || '+' || mp.scheme_free_qty::int::text || ' FREE'
        as badge_label,
      -- effective per unit (ptr-based when available, else mrp)
      round(coalesce(nullif(mp.ptr,0), nullif(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),''),'0')::numeric, 0)
            / (mp.scheme_buy_qty + mp.scheme_free_qty), 2) as effective_per_unit,
      -- days left
      case when mp.scheme_ends_at is not null
           then extract(day from (mp.scheme_ends_at - now()))::int
           else null end as days_left,
      mp.pricing_ready,
      mp.ptr
    from medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
    where mp.scheme_ready = true
      and m.deleted_at is null
      and (mp.scheme_ends_at is null or mp.scheme_ends_at > now())
    order by
      -- ending soon first, then by free_qty ratio desc (best schemes first)
      case when mp.scheme_ends_at is not null
           and mp.scheme_ends_at <= now() + interval '3 days' then 0 else 1 end,
      round(mp.scheme_free_qty / mp.scheme_buy_qty * 100) desc
    limit p_limit offset p_offset
  ) r;

  return jsonb_build_object(
    'ok',       true,
    'title',    v_title,
    'count',    coalesce(v_count, 0),
    'empty',    case when coalesce(v_count,0) = 0 then v_empty else null end,
    'has_more', (coalesce(v_count,0) > p_offset + p_limit),
    'rows',     coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

-- ── 8. admin_pricing_list — extend to include scheme fields ───────────
CREATE OR REPLACE FUNCTION public.admin_pricing_list(
  p_search text    DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_limit  integer DEFAULT 40
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_role   text := public.get_my_role();
  v_rows   jsonb;
  v_count  bigint;
  v_ready  bigint;
  v_scheme_ready bigint;
  v_total  bigint;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select count(*) into v_total
  from "MEDICINE" m
  where m.deleted_at is null and (m.mrp is not null and m.mrp != '');

  select count(*) into v_ready
  from medicine_pricing where pricing_ready = true;

  select count(*) into v_scheme_ready
  from medicine_pricing where scheme_ready = true;

  select count(*), jsonb_agg(row_to_json(r))
    into v_count, v_rows
  from (
    select
      m.id           as product_id,
      m."NAME"       as name,
      m."COMPANY"    as company,
      coalesce(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),''),'0')::numeric as mrp,
      mp.ptr,
      mp.gst_pct,
      mp.pricing_ready,
      mp.scheme_text,
      mp.scheme_buy_qty,
      mp.scheme_free_qty,
      mp.scheme_type,
      mp.scheme_pct,
      mp.scheme_starts_at,
      mp.scheme_ends_at,
      mp.scheme_ready,
      mp.pricing_source,
      mp.pricing_updated_at
    from "MEDICINE" m
    left join medicine_pricing mp on mp.product_id = m.id
    where m.deleted_at is null
      and (m.mrp is not null and m.mrp != '')
      and (p_search is null or lower(m."NAME") like '%' || lower(p_search) || '%'
           or lower(m."COMPANY") like '%' || lower(p_search) || '%')
    order by m.sales_count desc nulls last, m.id
    limit p_limit offset p_offset
  ) r;

  return jsonb_build_object(
    'ok',          true,
    'coverage', jsonb_build_object(
      'pricing_ready',     v_ready,
      'scheme_ready',      v_scheme_ready,
      'total',             v_total,
      'pricing_pct',       case when v_total > 0 then round(v_ready * 100.0 / v_total, 1) else 0 end,
      'scheme_pct',        case when v_total > 0 then round(v_scheme_ready * 100.0 / v_total, 1) else 0 end
    ),
    'count',  coalesce(v_count, 0),
    'rows',   coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

-- ── 9. Bill lines trigger — also capture scheme on billing ────────────
CREATE OR REPLACE FUNCTION public._bill_line_capture_pricing() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
begin
  -- Only capture when we have at least ptr + gst_pct
  if new.product_id is not null and coalesce(new.ptr, 0) > 0 and new.gst_pct is not null then
    perform public.product_pricing_upsert(
      new.product_id,
      jsonb_build_object(
        'ptr',             new.ptr,
        'gst_pct',         new.gst_pct,
        'discount_pct',    new.disc_pct,
        'scheme_buy_qty',  new.qty,              -- bill qty is the buy qty
        'scheme_free_qty', coalesce(new.free_qty, 0),
        'scheme_type',     case when coalesce(new.free_qty,0) > 0 then 'free_qty' else null end
      ),
      'supplier_bill'
    );
  end if;
  return new;
end;
$$;

-- Drop and recreate trigger so function update takes effect
DROP TRIGGER IF EXISTS trg_bill_line_capture_pricing ON bill_lines;
CREATE TRIGGER trg_bill_line_capture_pricing
  AFTER INSERT OR UPDATE ON bill_lines
  FOR EACH ROW EXECUTE FUNCTION public._bill_line_capture_pricing();

-- Grant execute on new functions to authenticated
GRANT EXECUTE ON FUNCTION public._scheme_compute TO authenticated;
GRANT EXECUTE ON FUNCTION public.cart_apply_schemes TO authenticated;
GRANT EXECUTE ON FUNCTION public.cart_scheme_nudge TO authenticated;
GRANT EXECUTE ON FUNCTION public.schemes_feed TO authenticated;

-- CHANGE #274 — the storefront card, rebuilt to the Plazza anatomy, with B2B
-- MRP/PTR trade pricing.
--
-- Everything the card prints is decided here. The three things this migration
-- adds, and why each is backend work rather than layout work:
--
--  1. `sf_pack_badge()` — the compact pack quantity that sits bottom-left ON
--     the image ("10 tablets", "30 ml"). The catalogue stores
--     "10.0 tablets in 1 strip"; shortening that is a wording decision, so it
--     is made once here instead of in every surface that draws a card.
--
--  2. `_sf_cards()` — pack_label and form_chip were SWAPPED: the chip under
--     the card was printing the long pack quantity as a full-width grey pill,
--     and the badge on the image was printing the container type. The card
--     wants the QUANTITY on the image and the TYPE in the chip.
--
--  3. `card_price` — the MRP/PTR block, entitlement-gated in the RPC. An
--     un-entitled viewer's payload carries no PTR value ANYWHERE: the
--     `has_ptr` / `ptr_display` / `ptr_caption` keys are no longer part of the
--     base block, so they are absent rather than empty. PTR is never hidden in
--     Flutter — it never leaves Postgres.
--
-- Idempotent: create-or-replace + on-conflict everywhere.

-- ── 1. labels ────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value) values
  ('mrp_caption',        'MRP'),
  ('ptr_locked_note',    'Register and get approved to see trade prices'),
  ('card_add_label',     'ADD')
on conflict (key) do update set value = excluded.value;

-- ── 2. the compact pack badge ────────────────────────────────────────────────
-- "10.0 tablets in 1 strip" → "10 tablets"
-- "1.0 Injection in 1 vial" → "1 injection"
-- "30.0 ml in 1 bottle"     → "30 ml"
-- No pack_qty → pack_size ("1 Vial") → pack_type ("Strip") → ''.
create or replace function public.sf_pack_badge(
  p_pack_qty text, p_pack_size text, p_pack_type text)
returns text
language sql
immutable
as $$
  select coalesce(
    nullif(btrim(
      -- take everything before " in 1 …", then drop a trailing ".0" on the
      -- leading number: the catalogue stores counts as floats and "10.0
      -- tablets" reads as a measurement rather than a count.
      lower(regexp_replace(
        split_part(btrim(coalesce(p_pack_qty, '')), ' in ', 1),
        '^([0-9]+)\.0+(\s|$)', '\1\2'))
    ), ''),
    nullif(btrim(coalesce(p_pack_size, '')), ''),
    nullif(btrim(coalesce(p_pack_type, '')), ''),
    '');
$$;

comment on function public.sf_pack_badge(text, text, text) is
  'CHANGE #274 — the compact pack quantity printed bottom-left on a product card.';

-- ── 3. who may see a trade price ─────────────────────────────────────────────
-- Approved + registered customers, admin, super_admin, employee (worker), and
-- anyone using view-as-customer (viewer_is_approved_customer() already returns
-- true for an acting-as session). Everyone else: MRP only.
create or replace function public.viewer_sees_trade_price()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.viewer_is_approved_customer()
      or public.get_my_role() = any (array['admin','super_admin','worker']);
$$;

comment on function public.viewer_sees_trade_price() is
  'CHANGE #274 — the ONE entitlement door for PTR. False => the payload carries no PTR value at all.';

-- ── 4. the pricing block, with the card''s MRP/PTR pair ──────────────────────
create or replace function public._pricing_block(
  p_mrp numeric, p_row medicine_pricing, p_discount_pct numeric default null)
returns jsonb
language plpgsql
stable
security definer
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
  v_chip  text;
  v_lines jsonb;
  v_scheme_extra jsonb;
  v_eff   numeric;
  v_scheme_ready boolean;
  v_days_left integer;
begin
  -- The MRP-only base. NOTE what is NOT here: has_ptr / ptr_display /
  -- ptr_caption. They are added ONLY on the entitled branch below, so an
  -- unapproved viewer's payload has no PTR key to leak, empty or otherwise.
  v_base := jsonb_build_object(
    'has_price',        v_has,
    'mrp',              v_mrp,
    'sale_price',       v_mrp,
    'price_display',    case when v_has then public.inr_money(v_mrp) else '' end,
    'price_caption',    case when v_has then v_cap else '' end,
    'mrp_display',      '',
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
    'has_struck_mrp',   false,
    'gst',              null,
    -- The card's own two-line price block. MRP always; PTR only when the
    -- backend both HAS one and the viewer is entitled to it.
    'card_price', jsonb_build_object(
      'has_mrp',      v_has,
      'mrp_label',    case when v_has then v_mrp_cap else '' end,
      'mrp_display',  case when v_has then public.inr_money(v_mrp) else '' end,
      'strike_mrp',   false,
      'has_ptr',      false,
      'has_note',     (not v_entitled) and v_locked <> '',
      'note',         case when (not v_entitled) then v_locked else '' end));

  -- Scheme badge: no role gate (visible to all approved buyers)
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

  -- Pricing block (role-gated). No MRP, no captured trade price, or a viewer
  -- who may not see trade prices => the MRP-only block above, unchanged.
  if not v_has or not coalesce(p_row.pricing_ready, false) or not v_entitled then
    return v_base;
  end if;

  v_calc := public._pricing_compute(v_mrp, p_row.ptr, p_row.gst_pct,
              coalesce(p_row.discount_pct, 0),
              p_row.scheme_buy_qty, p_row.scheme_free_qty, false);
  if v_calc is null then return v_base; end if;

  v_net := (v_calc->>'net_payable')::numeric;
  v_pct := (v_calc->>'margin_pct')::numeric;

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
    'ptr_display',    public.inr_money((v_calc->>'ptr')::numeric),
    'ptr_caption',    v_ptr_cap,
    -- The card's pair, now with the trade price. The PTR — not the net — is
    -- the number a pharmacy pays per pack, so that is what the filled box
    -- shows; GST and discounts land on the bill, not on the shelf label.
    'card_price', jsonb_build_object(
      'has_mrp',     true,
      'mrp_label',   v_mrp_cap,
      'mrp_display', public.inr_money(v_mrp),
      'strike_mrp',  true,
      'has_ptr',     true,
      'ptr_label',   v_ptr_cap,
      'ptr_display', public.inr_money((v_calc->>'ptr')::numeric),
      'ptr_bg',      '#1B7A43',
      'ptr_fg',      '#FFFFFF',
      'has_note',    false,
      'note',        ''),
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
$function$;

-- ── 5. the home/rail card, with pack badge and type chip the right way round ─
create or replace function public._sf_cards(p_ids bigint[])
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    -- ON the image, bottom-left: the compact QUANTITY ("10 tablets").
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    -- Under the image: the TYPE chip ("Strip", "Vial", "Bottle").
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_display', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_size_display', coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),'')),
    'pack_type', m.pack_type,
    'pack_qty', m.pack_qty,
    'pack_size', m.pack_size,
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false) then 'Scheme available' else '' end,
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

-- ── 6. the compact ADD word ──────────────────────────────────────────────────
-- The card's pill is 76px wide; "Add to cart" does not fit and was ellipsised
-- on every tile. `cta_short` is the word the CARD prints; `cta_label` stays
-- the long form the product page and the cart use. Both are backend strings.
create or replace function public.storefront_cta(
  p_supplier_count integer, p_resolved boolean default true)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  SELECT CASE
    -- unapproved / anonymous / incognito: the shop always looks full
    WHEN NOT public.viewer_is_approved_customer() THEN
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', false,
        'cta_short', coalesce((SELECT value FROM public.storefront_ui_label
                                 WHERE key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))
    -- product could not be resolved at all: never block on something we cannot check
    WHEN NOT coalesce(p_resolved, true) THEN
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', true, 'unresolved', true,
        'cta_short', coalesce((SELECT value FROM public.storefront_ui_label
                                 WHERE key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))
    -- resolved product: NULL and 0 both mean no supplier
    WHEN coalesce(p_supplier_count, 0) >= 1 THEN
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', true,
        'cta_short', coalesce((SELECT value FROM public.storefront_ui_label
                                 WHERE key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))
    ELSE
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label','Unavailable','gated', true,
        'note','No supplier for this product right now',
        'cta_short', coalesce((SELECT value FROM public.storefront_ui_label
                                 WHERE key='stock_out_label'), 'Out of stock'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  END;
$function$;

-- ── 7. the category grid gets the same two card fields ───────────────────────
create or replace function public.storefront_page(
  category_filter text default 'All', page_offset integer default 0,
  page_limit integer default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
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
    SELECT f.* FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
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
        to_jsonb(r)
        || jsonb_build_object('availability', public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count)))
        || jsonb_build_object('pack_badge', public.sf_pack_badge(r.pack_qty, r.pack_size, r.pack_type))
        || jsonb_build_object('type_chip', coalesce(nullif(btrim(r.pack_type),''), nullif(btrim(r.pack_size),''), ''))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id)))
      FROM rows r), '[]'::jsonb)
  );
$function$;

-- ── 8. the guard: an un-entitled viewer's storefront payload has NO PTR ──────
insert into public.rg_behavior_tests (name, body, enabled, note) values (
'storefront_ptr_entitlement',
$rgt$
do $rg$
declare
  v_ids   bigint[];
  v_cards jsonb;
  v_txt   text;
  v_ptr   numeric;
  v_mrp   numeric;
  v_pid   bigint;
begin
  -- A product that HAS a captured trade price, so this can never pass
  -- vacuously by testing a product with no PTR to leak in the first place.
  select mp.product_id, mp.ptr into v_pid, v_ptr
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where coalesce(mp.pricing_ready,false) and coalesce(mp.ptr,0) > 0
     and lower(coalesce(m.buyable::text,'')) in ('true','t')
   limit 1;
  if v_pid is null then
    raise exception 'RG_FAIL: no priced+buyable product exists, so PTR entitlement is untested';
  end if;
  v_ids := array[v_pid];

  -- ANONYMOUS: no session at all.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('medibo.viewer_approved', '', true);
  if public.viewer_sees_trade_price() then
    raise exception 'RG_FAIL: an anonymous viewer is entitled to trade prices';
  end if;
  v_cards := public._sf_cards(v_ids);
  v_txt   := v_cards::text;

  if v_cards #> '{0,pricing,card_price,has_ptr}' <> 'false'::jsonb then
    raise exception 'RG_FAIL: card_price.has_ptr is not false for an anonymous viewer -> %',
      v_cards #> '{0,pricing,card_price}';
  end if;
  if v_cards #> '{0,pricing,card_price}' ? 'ptr_display' then
    raise exception 'RG_FAIL: card_price carries a ptr_display key for an anonymous viewer';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cards -> 0 -> 'pricing') k
              where k in ('ptr_display','ptr_caption','has_ptr','raw')) then
    raise exception 'RG_FAIL: the pricing block still carries PTR keys for an anonymous viewer';
  end if;
  -- The number itself must not appear anywhere in the payload, under any key.
  -- (Skipped in the freak case where the PTR equals the MRP, which is legitimately printed.)
  select nullif(regexp_replace(coalesce(mrp::text,''), '[^0-9.]','','g'),'')::numeric
    into v_mrp from "MEDICINE" where id = v_pid;
  if v_ptr is distinct from v_mrp and position(public.inr_money(v_ptr) in v_txt) > 0 then
    raise exception 'RG_FAIL: the PTR value % appears in an anonymous storefront payload',
      public.inr_money(v_ptr);
  end if;
  if v_cards #> '{0,pricing,display_mode}' <> '"mrp_only"'::jsonb then
    raise exception 'RG_FAIL: an anonymous viewer got a full pricing block';
  end if;

  -- SUPER ADMIN: the same card must carry the PTR.
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
      where coalesce(a.is_super,false) limit 1), true);
  perform set_config('medibo.viewer_approved', '', true);
  if not public.viewer_sees_trade_price() then
    raise exception 'RG_FAIL: a super admin may not see trade prices';
  end if;
  v_cards := public._sf_cards(v_ids);
  if v_cards #> '{0,pricing,card_price,has_ptr}' <> 'true'::jsonb then
    raise exception 'RG_FAIL: a super admin gets no PTR on the card -> %',
      v_cards #> '{0,pricing,card_price}';
  end if;
  if coalesce(v_cards #>> '{0,pricing,card_price,ptr_display}', '') = '' then
    raise exception 'RG_FAIL: card_price.ptr_display is empty for a super admin';
  end if;

  -- The displayed PTR is the one the table holds RIGHT NOW — never a cache.
  if (v_cards #>> '{0,pricing,card_price,ptr_display}') <> public.inr_money(v_ptr) then
    raise exception 'RG_FAIL: the card shows % but medicine_pricing.ptr is %',
      v_cards #>> '{0,pricing,card_price,ptr_display}', public.inr_money(v_ptr);
  end if;
  update public.medicine_pricing set ptr = v_ptr + 7 where product_id = v_pid;
  v_cards := public._sf_cards(v_ids);
  if (v_cards #>> '{0,pricing,card_price,ptr_display}') <> public.inr_money(v_ptr + 7) then
    raise exception 'RG_FAIL: PTR did not follow medicine_pricing — expected %, got %',
      public.inr_money(v_ptr + 7), v_cards #>> '{0,pricing,card_price,ptr_display}';
  end if;

  -- The card also has to keep its Plazza anatomy fields.
  if coalesce(v_cards #>> '{0,pack_label}', '') = ''
     and coalesce((select btrim(coalesce(pack_qty, pack_size, pack_type, ''))
                     from "MEDICINE" where id = v_pid), '') <> '' then
    raise exception 'RG_FAIL: the card lost its pack badge';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$rgt$,
true,
'CHANGE #274 — PTR is entitlement-gated in the RPC, not hidden in Flutter: an anonymous viewer''s storefront payload carries no ptr key and no PTR number anywhere, while a super admin gets card_price.ptr_display, and that value follows medicine_pricing.ptr live (a supplier bill import changes the card with no deploy).')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

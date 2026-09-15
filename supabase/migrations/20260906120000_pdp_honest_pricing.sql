-- CMD #1826 — the product page never implies a price or a supply it does not
-- have. Two new render-ready blocks on product_detail():
--
--   price_lines  — BOTH prices, every time (Om amendment A): the MRP row as
--                  the printed pack ceiling and the SALE PRICE row as what the
--                  buyer pays. When medicine_pricing has no pricing_ready row
--                  the sale row prints the backend's "On quote" copy — never a
--                  dash, never a zero, never MRP repeated. The sticky bar's
--                  main number is the sale row's value, MRP small beside it.
--   supply       — a supply-CONFIDENCE band derived from supplier_item_memory:
--                  label + tone + optional sub-line + optional speed line, all
--                  worded here. No supplier name, no count, no depth leaves
--                  the database. has:false when nothing is known.
--
-- Every threshold is one UPDATE on app_settings.pdp_supply_confidence; every
-- word is one UPDATE on storefront_ui_label. Idempotent: replayed on live by
-- the merge worker.

-- ── Copy ────────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('pdp_sale_price_caption', 'Sale price (PTR)',
     'CMD #1826 — caption of the row that holds what the buyer pays'),
  ('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price',
     'CMD #1826 — sub-line under the MRP row'),
  ('pdp_mrp_missing', 'Not printed on this pack',
     'CMD #1826 — MRP row value when the catalogue holds no MRP'),
  ('pdp_sale_on_quote', 'On quote',
     'CMD #1826 — sale-price row value when no pricing_ready row exists'),
  ('pdp_sale_on_quote_note', 'Trade rate is confirmed when suppliers quote',
     'CMD #1826 — sub-line under an on-quote sale row'),
  ('pdp_sale_ptr_note', 'PTR {ptr} · {gst}',
     'CMD #1826 — sub-line under a priced sale row; {ptr} {gst} filled server-side'),
  ('pdp_sticky_sale_caption', 'Sale price',
     'CMD #1826 — caption under the sticky bar''s main number'),
  ('pdp_sticky_mrp_prefix', 'MRP',
     'CMD #1826 — prefix of the small MRP beside the sticky bar''s main number'),
  ('pdp_supply_green', 'Supply confirmed recently',
     'CMD #1826 — green band: several sources confirmed inside the window'),
  ('pdp_supply_amber_single', 'One source confirmed recently',
     'CMD #1826 — amber band: a single source inside the window'),
  ('pdp_supply_amber_ageing', 'Last confirmed a while ago',
     'CMD #1826 — amber band: confirmations exist but are older than the window'),
  ('pdp_supply_red', 'Checked recently, not confirmed',
     'CMD #1826 — red band: suppliers were asked inside the window, none said Available'),
  ('pdp_supply_sub_confirmed', 'Last confirmed {ago}',
     'CMD #1826 — sub-line; {ago} filled server-side'),
  ('pdp_supply_sub_checked', 'Last checked {ago}',
     'CMD #1826 — sub-line for the red band; {ago} filled server-side'),
  ('pdp_supply_speed', 'Usually confirmed {within}',
     'CMD #1826 — speed line; {within} filled server-side from real answer times')
on conflict (key) do nothing;

-- The sticky bar's main line is a NUMBER-sized slot beside Add to cart: for a
-- viewer who is not yet entitled to trade prices it carries a short phrase,
-- while the sale-price ROW above keeps the full ptr_locked_note sentence.
insert into public.storefront_ui_label (key, value, note) values
  ('pdp_sticky_locked', 'Trade price on approval',
     'CMD #1826 — sticky-bar main line when a trade rate exists but the viewer is not approved')
on conflict (key) do nothing;

-- ── Thresholds ──────────────────────────────────────────────────────────────
insert into public.app_settings (key, value) values
  ('pdp_supply_confidence', jsonb_build_object(
     'window_days',         30,   -- "recently"
     'ageing_days',         120,  -- older than this is silence, not a band
     'green_min_suppliers', 2,    -- distinct sources for the green band
     'speed_min_samples',   5,    -- answer-time samples before a speed line
     'speed_window_days',   90))
on conflict (key) do nothing;

-- ── Helpers ─────────────────────────────────────────────────────────────────
create or replace function public._pdp_ago_words(p_ts timestamptz)
returns text language sql stable set search_path = public as $$
  select case
    when p_ts is null then ''
    when now() - p_ts < interval '1 hour'   then 'within the hour'
    when now() - p_ts < interval '24 hours' then 'today'
    when now() - p_ts < interval '48 hours' then 'yesterday'
    when now() - p_ts < interval '14 days'
      then floor(extract(epoch from now() - p_ts)/86400)::int::text || ' days ago'
    when now() - p_ts < interval '60 days'
      then floor(extract(epoch from now() - p_ts)/604800)::int::text || ' weeks ago'
    else floor(extract(epoch from now() - p_ts)/2592000)::int::text || ' months ago'
  end;
$$;

create or replace function public._pdp_within_words(p_iv interval)
returns text language sql immutable as $$
  select case
    when p_iv is null then ''
    when p_iv <= interval '1 hour' then 'within an hour'
    when p_iv <= interval '24 hours'
      then 'within ' || ceil(extract(epoch from p_iv)/3600)::int::text || ' hours'
    when p_iv <= interval '48 hours' then 'within a day'
    else 'within ' || ceil(extract(epoch from p_iv)/86400)::int::text || ' days'
  end;
$$;

create or replace function public._pdp_label(p_key text, p_default text)
returns text language sql stable set search_path = public as $$
  select coalesce(nullif(btrim((select value from public.storefront_ui_label where key = p_key)), ''), p_default);
$$;

-- ── Count stripper ──────────────────────────────────────────────────────────
-- The trust strip's internal ask / fill tallies exist to compute a label; the
-- label leaves, the tallies do not — at the top level OR inside fill_rate.
create or replace function public._pdp_strip_counts(p jsonb)
returns jsonb language sql immutable as $$
  select case
    when p is null then '{}'::jsonb
    when p ? 'fill_rate' and jsonb_typeof(p->'fill_rate') = 'object'
      then (p - 'asks' - 'filled')
           || jsonb_build_object('fill_rate', (p->'fill_rate') - 'asks' - 'filled')
    else p - 'asks' - 'filled'
  end;
$$;

-- ── Supply confidence ───────────────────────────────────────────────────────
create or replace function public.pdp_supply_confidence(p_product_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg jsonb := coalesce((select value from public.app_settings where key = 'pdp_supply_confidence'), '{}'::jsonb);
  v_window  interval := make_interval(days => coalesce((cfg->>'window_days')::int, 30));
  v_ageing  interval := make_interval(days => coalesce((cfg->>'ageing_days')::int, 120));
  v_green   int      := greatest(1, coalesce((cfg->>'green_min_suppliers')::int, 2));
  v_min_n   int      := greatest(1, coalesce((cfg->>'speed_min_samples')::int, 5));
  v_speed_w interval := make_interval(days => coalesce((cfg->>'speed_window_days')::int, 90));
  n_recent_avail int; n_recent_any int; n_aged_avail int;
  last_avail timestamptz; last_any timestamptz;
  n_samples int; v_median interval;
  v_band text; v_label text; v_tone text; v_sub text := '';
  v_speed text := '';
begin
  if p_product_id is null then return jsonb_build_object('has', false); end if;

  select count(distinct m.supplier_name) filter (where m.last_answer = 'Available' and m.last_answered_at >= now() - v_window),
         count(distinct m.supplier_name) filter (where m.last_answered_at >= now() - v_window),
         count(distinct m.supplier_name) filter (where m.last_answer = 'Available'
                                                   and m.last_answered_at <  now() - v_window
                                                   and m.last_answered_at >= now() - v_ageing),
         max(m.last_answered_at) filter (where m.last_answer = 'Available'),
         max(m.last_answered_at)
    into n_recent_avail, n_recent_any, n_aged_avail, last_avail, last_any
    from public.supplier_item_memory m
   where m.product_id = p_product_id;

  if n_recent_avail >= v_green then
    v_band := 'green'; v_tone := 'success';
    v_label := public._pdp_label('pdp_supply_green', 'Supply confirmed recently');
    v_sub := replace(public._pdp_label('pdp_supply_sub_confirmed', 'Last confirmed {ago}'), '{ago}', public._pdp_ago_words(last_avail));
  elsif n_recent_avail >= 1 then
    v_band := 'amber'; v_tone := 'warning';
    v_label := public._pdp_label('pdp_supply_amber_single', 'One source confirmed recently');
    v_sub := replace(public._pdp_label('pdp_supply_sub_confirmed', 'Last confirmed {ago}'), '{ago}', public._pdp_ago_words(last_avail));
  elsif n_recent_any >= 1 then
    v_band := 'red'; v_tone := 'danger';
    v_label := public._pdp_label('pdp_supply_red', 'Checked recently, not confirmed');
    v_sub := replace(public._pdp_label('pdp_supply_sub_checked', 'Last checked {ago}'), '{ago}', public._pdp_ago_words(last_any));
  elsif n_aged_avail >= 1 then
    v_band := 'amber'; v_tone := 'warning';
    v_label := public._pdp_label('pdp_supply_amber_ageing', 'Last confirmed a while ago');
    v_sub := replace(public._pdp_label('pdp_supply_sub_confirmed', 'Last confirmed {ago}'), '{ago}', public._pdp_ago_words(last_avail));
  else
    -- Nothing recent enough to stand behind: silence, not a grey placeholder.
    return jsonb_build_object('has', false);
  end if;

  -- Speed, only when it is real: the median ask→answer time of actual
  -- Available answers for THIS product, and only past the sample floor.
  select count(*),
         percentile_cont(0.5) within group (order by (l.answered_at - l.asked_at))
    into n_samples, v_median
    from public.inquiry_day_log l
   where l.product_id = p_product_id
     and l.outcome = 'answered'
     and l.answer = 'Available'
     and l.asked_at is not null and l.answered_at is not null
     and l.answered_at > l.asked_at
     and l.answered_at >= now() - v_speed_w;
  if coalesce(n_samples, 0) >= v_min_n and v_median is not null then
    v_speed := replace(public._pdp_label('pdp_supply_speed', 'Usually confirmed {within}'),
                       '{within}', public._pdp_within_words(v_median));
  end if;

  return jsonb_build_object(
    'has',       true,
    'band',      v_band,
    'label',     v_label,
    'tone',      v_tone,
    'has_sub',   v_sub <> '',
    'sub',       v_sub,
    'has_speed', v_speed <> '',
    'speed',     v_speed);
end $$;

-- ── Price lines ─────────────────────────────────────────────────────────────
create or replace function public.pdp_price_lines(p_product_id bigint, p_mrp numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_has_mrp boolean := (p_mrp is not null and p_mrp > 0);
  v_entitled boolean := public.viewer_sees_trade_price();
  v_ready boolean := false;
  v_pb jsonb;
  v_mrp_cap text := public._pdp_label('mrp_caption', 'MRP');
  v_mrp_val text; v_mrp_note text := public._pdp_label('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price');
  v_sale_cap text := public._pdp_label('pdp_sale_price_caption', 'Sale price (PTR)');
  v_sale_val text; v_sale_note text := ''; v_sale_amount boolean := false; v_sale_tone text := 'secondary';
  v_side text := '';
  v_sticky_main text;
begin
  v_mrp_val := case when v_has_mrp then public.inr_money(p_mrp)
                    else public._pdp_label('pdp_mrp_missing', 'Not printed on this pack') end;

  select mp.pricing_ready and coalesce(mp.ptr, 0) > 0
    into v_ready
    from public.medicine_pricing mp where mp.product_id = p_product_id;
  v_ready := coalesce(v_ready, false);

  if v_ready and v_entitled then
    -- The SAME block every card reads, already gated on entitlement and
    -- formatted with inr_money. Net (PTR + GST − discount) is what is paid.
    v_pb := public.storefront_pricing(p_mrp, null::numeric, p_product_id);
    if coalesce((v_pb->>'has_net')::boolean, false) then
      v_sale_val := v_pb->>'net_display';
      v_sale_amount := true; v_sale_tone := 'primary';
      v_sale_note := replace(replace(public._pdp_label('pdp_sale_ptr_note', 'PTR {ptr} · {gst}'),
                         '{ptr}', coalesce(v_pb->>'ptr_display', '')),
                         '{gst}', coalesce(v_pb#>>'{gst,pct_display}', ''));
      v_sale_note := btrim(regexp_replace(v_sale_note, '\s·\s*$', ''));
    end if;
  end if;

  if not v_sale_amount then
    if v_ready and not v_entitled then
      v_sale_val := public._pdp_label('ptr_locked_note', 'Register and get approved to see trade prices');
      v_sticky_main := public._pdp_label('pdp_sticky_locked', 'Trade price on approval');
    else
      v_sale_val := public._pdp_label('pdp_sale_on_quote', 'On quote');
      v_sale_note := public._pdp_label('pdp_sale_on_quote_note', 'Trade rate is confirmed when suppliers quote');
    end if;
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
      'tone',       v_sale_tone),
    'sticky', jsonb_build_object(
      'main',         coalesce(v_sticky_main, v_sale_val),
      'main_caption', public._pdp_label('pdp_sticky_sale_caption', 'Sale price'),
      'main_tone',    v_sale_tone,
      'has_side',     v_side <> '',
      'side',         v_side));
end $$;

-- Leaf helpers: only product_detail() (security definer) calls them.
revoke all on function public.pdp_supply_confidence(bigint) from public, anon, authenticated;
revoke all on function public.pdp_price_lines(bigint, numeric) from public, anon, authenticated;
revoke all on function public._pdp_ago_words(timestamptz) from public, anon, authenticated;
revoke all on function public._pdp_within_words(interval) from public, anon, authenticated;
revoke all on function public._pdp_label(text, text) from public, anon, authenticated;
revoke all on function public._pdp_strip_counts(jsonb) from public, anon, authenticated;

-- ── product_detail(): attach the two blocks ─────────────────────────────────
create or replace function public.product_detail(p_product_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $function$
declare
  v jsonb; v_rx text;
  v_gallery jsonb; v_facts jsonb; v_purchase jsonb; v_companions jsonb;
  v_supply jsonb; v_lines jsonb; v_mrp numeric;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;

  begin v_gallery := public.product_gallery(p_product_id);
  exception when others then v_gallery := jsonb_build_object('has', false, 'count', 0, 'images', '[]'::jsonb); end;

  begin v_facts := public.product_facts(p_product_id);
  exception when others then v_facts := jsonb_build_object('has', false, 'title', '', 'rows', '[]'::jsonb); end;

  begin v_purchase := public.purchase_overlay(p_product_id);
  exception when others then v_purchase := jsonb_build_object('has', false); end;

  begin v_companions := public.product_companions(p_product_id, array[p_product_id]);
  exception when others then v_companions := jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb); end;

  -- CMD #1826 — supply confidence (a band, never a count) and the two price
  -- lines. Both worded here; the page prints them.
  v_mrp := nullif(v#>>'{pricing,mrp}', '')::numeric;
  begin v_supply := public.pdp_supply_confidence(p_product_id);
  exception when others then v_supply := jsonb_build_object('has', false); end;
  begin v_lines := public.pdp_price_lines(p_product_id, v_mrp);
  exception when others then v_lines := jsonb_build_object('has', false); end;

  -- CHANGE #461/#170: the prescription class, and (for a signed-in pharmacy)
  -- whether their drug licence is on file for it.
  return v
    || jsonb_build_object('header',
         coalesce(v->'header','{}'::jsonb)
         || jsonb_build_object('rx_required',
              (upper(btrim(coalesce(v_rx,''))) = 'RX')))
    || jsonb_build_object(
    'rx',         public.rx_badge(v_rx),
    'rx_licence', case when upper(btrim(coalesce(v_rx,''))) = 'RX'
                            and public.my_customer_id() is not null
                       then public.rx_licence_state(public.my_customer_id())
                       else jsonb_build_object('has', true, 'reason', 'n/a') end)
    -- CMD #791 — depth: the gallery, the fact table, this buyer's own history
    -- with the pack, and what it is bought with.
    || jsonb_build_object(
    'gallery',    v_gallery,
    'facts',      v_facts,
    'purchase',   v_purchase,
    'companions', v_companions)
    -- CMD #1826 — and NEVER a raw sourcing count in the payload: the trust
    -- strip's internal ask/fill tallies stay in the database.
    || jsonb_build_object(
    'trust',       public._pdp_strip_counts(v->'trust'),
    'supply',      v_supply,
    'price_lines', v_lines);
end $function$;

-- CMD #2190 — RG red: c747_catalogue_budget, catalogue_list 308ms (limit 300ms).
--
-- Not a schema regression and never a rebaseline: the list RPC sits right on
-- the budget and tips over whenever production is busy (373ms on the 19:41
-- run). Profiled with pg_stat_statements track=all over 10 real calls of the
-- behaviour's own query (tree / ANTI INFECTIVES / 24 rows, 265ms per call):
--
--   _product_card          6.4 ms per card  (24 cards per page)
--     _pricing_block       1.2 ms x2        double-evaluated lateral
--       viewer_sees_trade  0.58ms x2        get_my_role(), not memoised
--       18 label lookups   0.36ms           one scalar subquery per caption
--     rx_card_badge        0.35ms x2        recomputed for the outer row
--
-- Every one of those repeats is page-constant work. This change removes the
-- repeats; it does NOT change one byte of any payload (proved by comparing
-- catalogue_list / catalogue_home / search output before and after).
--
-- 1. viewer_sees_trade_price() memoises per TRANSACTION, keyed on the
--    credential, exactly as viewer_is_approved_customer() and
--    viewer_price_state() already do.
-- 2. _pricing_block() reads its 18 captions in ONE aggregate instead of 18
--    scalar subqueries; _product_card_foot() and _product_card_action() do the
--    same with theirs.
-- 3. The card builders' `cross join lateral (...)` gets `offset 0`, which stops
--    the planner inlining it and computing storefront_pricing()/storefront_cta()
--    once per REFERENCE (twice per card). Same fence CMD #2145 put on x.b.
-- 4. _cat_cards() stops recomputing rx / wish for the outer row: the card it
--    just built carries the identical values.
--
-- Idempotent: CREATE OR REPLACE only, no schema change, no grant change.

-- ── 1. the viewer's trade-price entitlement, once per transaction ───────────
create or replace function public.viewer_sees_trade_price()
returns boolean
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare v_key text; v_memo text; v_ans boolean;
begin
  -- Key on the credential, so a memo can never be read by a different one.
  v_key := coalesce(auth.uid()::text, 'anon');
  v_memo := nullif(current_setting('medibo.viewer_trade_price', true), '');
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return split_part(v_memo, '|', 2) = 't';
  end if;

  v_ans := public.viewer_is_approved_customer()
           or public.get_my_role() = any (array['admin','super_admin','worker']);

  perform set_config('medibo.viewer_trade_price',
                     v_key || '|' || case when v_ans then 't' else 'f' end, true);
  return coalesce(v_ans, false);
end $fn$;


-- ── 2. the pricing block's captions, in one read ──
create or replace function public._pricing_block(p_mrp numeric, p_row medicine_pricing, p_discount_pct numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_has   boolean := (p_mrp is not null and p_mrp > 0);
  v_mrp   numeric := coalesce(p_mrp, 0);
  v_lbl   jsonb;
  v_cap       text;
  v_mrp_cap   text;
  v_net_cap   text;
  v_ptr_cap   text;
  v_sale_cap  text;
  v_sale_bg   text;
  v_sale_fg   text;
  v_locked    text;
  v_lock_title text;
  v_lock_cta  text;
  v_lock_route text;
  v_earn      text;
  v_suffix    text;
  v_loss      text;
  v_over      text;
  v_gst_title text;
  v_tax_label text;
  v_entitled boolean;
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
  -- CMD #2190 — 17 captions, ONE index scan. Same values, same fallbacks:
  -- this block used to be 17 scalar subqueries in the DECLARE, evaluated on
  -- every card of every page.
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_lbl
    from storefront_ui_label where key in ('price_caption','mrp_caption','net_rate_caption','ptr_caption','sale_price_caption','sale_badge_bg','sale_badge_fg','ptr_locked_note','ptr_locked_title','ptr_locked_cta','ptr_locked_route','margin_earn_prefix','margin_chip_suffix','margin_loss_prefix','margin_chip_over_suffix','gst_breakup_title','gst_taxable_label');
  v_cap       := coalesce(v_lbl->>'price_caption', 'MRP');
  v_mrp_cap   := coalesce(v_lbl->>'mrp_caption', 'MRP');
  v_net_cap   := coalesce(v_lbl->>'net_rate_caption', 'NET');
  v_ptr_cap   := coalesce(v_lbl->>'ptr_caption', 'PTR');
  v_sale_cap  := coalesce(v_lbl->>'sale_price_caption', 'Sale price:');
  v_sale_bg   := coalesce(v_lbl->>'sale_badge_bg', '#1B7A43');
  v_sale_fg   := coalesce(v_lbl->>'sale_badge_fg', '#FFFFFF');
  v_locked    := coalesce(v_lbl->>'ptr_locked_note', '');
  v_lock_title := coalesce(v_lbl->>'ptr_locked_title', '');
  v_lock_cta  := coalesce(v_lbl->>'ptr_locked_cta', '');
  v_lock_route := coalesce(v_lbl->>'ptr_locked_route', '');
  v_earn      := coalesce(v_lbl->>'margin_earn_prefix', 'You earn');
  v_suffix    := coalesce(v_lbl->>'margin_chip_suffix', 'margin');
  v_loss      := coalesce(v_lbl->>'margin_loss_prefix', 'Above MRP by');
  v_over      := coalesce(v_lbl->>'margin_chip_over_suffix', 'above MRP');
  v_gst_title := coalesce(v_lbl->>'gst_breakup_title', 'GST breakup');
  v_tax_label := coalesce(v_lbl->>'gst_taxable_label', 'Taxable value');
  v_entitled := public.viewer_sees_trade_price();
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
$function$

;

-- ── 3. the foot line: its four labels in one read ──────────────────────────
create or replace function public._product_card_foot(p_card jsonb, p_scheme_line text default ''::text)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  -- CMD #2190 — one scan instead of two-to-four scalar subqueries per card.
  -- viewer_price_state() memoises itself, so naming all three locked variants
  -- here costs nothing and keeps the same precedence.
  with l as (
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) m
      from storefront_ui_label
     where key in ('card_foot_unavailable','card_foot_notified','card_foot_locked',
                   'card_foot_locked_register','card_foot_locked_pending')),
  f as (
    select case
      when p_card is null then null
      when not coalesce((p_card#>>'{availability,is_available}')::boolean, false)
           and coalesce((p_card->>'notified')::boolean, false) then
        jsonb_build_object('label', coalesce(l.m->>'card_foot_notified', ''),
          'tone', jsonb_build_object('name','muted','bg','#F3F4F6','fg','#6B7280'))
      when not coalesce((p_card#>>'{availability,is_available}')::boolean, false) then
        jsonb_build_object('label', coalesce(l.m->>'card_foot_unavailable',
                                             nullif(p_card#>>'{availability,label}', ''), ''),
          'tone', jsonb_build_object('name','danger','bg','#FEE2E2','fg','#991B1B'))
      when coalesce((p_card->>'locked')::boolean, false) then
        jsonb_build_object('label', coalesce(
            l.m->>(case (select public.viewer_price_state())
                     when 'register' then 'card_foot_locked_register'
                     when 'pending'  then 'card_foot_locked_pending'
                     else 'card_foot_locked' end),
            l.m->>'card_foot_locked',
            p_card#>>'{price,locked_note}', ''),
          'tone', jsonb_build_object('name','muted','bg','#F3F4F6','fg','#6B7280'))
      when coalesce(p_scheme_line, '') <> '' then
        jsonb_build_object('label', p_scheme_line,
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      when coalesce((p_card#>>'{price,has_margin}')::boolean, false)
           and coalesce(p_card#>>'{price,margin_label}', '') <> '' then
        jsonb_build_object('label', p_card#>>'{price,margin_label}',
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      else
        jsonb_build_object('label', coalesce(p_card#>>'{availability,label}', ''),
          'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46'))
    end as foot
    from l)
  select case when f.foot is null then null
              when not coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'card.show_foot'), true)
                then f.foot || jsonb_build_object('label', '', 'has', false)
              else f.foot || jsonb_build_object('has', coalesce(f.foot->>'label', '') <> '') end
    from f;
$fn$;

-- ── 4. the card's action strings: five labels in one read ──────────────────
create or replace function public._product_card_action(m "MEDICINE", p_qty integer, p_notified boolean)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  with u as (select public.bulk_qty_unit(m.pack_type) as unit,
                    greatest(coalesce(p_qty, 0), 0) as qty),
       -- CMD #2190 — one scan for every label this block prints.
       l as (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) m
               from storefront_ui_label
              where key in ('card_qty_foot','card_notify_short','card_notified_label',
                            'card_foot_unavailable','card_foot_notified'))
  select jsonb_build_object(
    'picker', jsonb_build_object('rpc', 'card_qty_picker', 'pack_type', coalesce(m.pack_type, '')),
    -- "{qty} strip" — singular template (kept for old builds); _one/_many pluralise ("4 strips").
    'qty_tpl', replace(public.uic('bulk.qty_line', '{qty} {unit}'), '{unit}', u.unit),
    'qty_tpl_one', replace(public.uic('bulk.qty_line', '{qty} {unit}'), '{unit}', u.unit),
    'qty_tpl_many', replace(public.uic('bulk.qty_line', '{qty} {unit}'), '{unit}', public._unit_plural(u.unit, 2)),
    'qty_label', case when u.qty > 0 then public.bulk_qty_line(u.qty, m.pack_type) else '' end,
    'qty_foot_tpl', replace(coalesce(l.m->>'card_qty_foot', ''), '{unit}', u.unit),
    'qty_foot', case when u.qty > 0 then
                  replace(replace(coalesce(l.m->>'card_qty_foot', ''),
                                  '{unit}', public._unit_plural(u.unit, u.qty)), '{qty}', u.qty::text)
                else '' end,
    'notify', jsonb_build_object(
      'rpc', 'stock_notify_request',
      'notified', coalesce(p_notified, false),
      'label', coalesce(l.m->>'card_notify_short', ''),
      'done_label', coalesce(l.m->>'card_notified_label', ''),
      'idle_line', coalesce(l.m->>'card_foot_unavailable', ''),
      'done_line', coalesce(l.m->>'card_foot_notified', ''),
      'tone', jsonb_build_object('name','danger','bg','#FEE2E2','fg','#991B1B')))
  from u cross join l;
$fn$;

-- ── 5. the catalogue page's cards: build each one ONCE ─────────────────────
create or replace function public._cat_cards(p_ids bigint[])
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c,
                                  coalesce((select new_days from public.catalogue_extras_config
                                             where id = 1), 30) as nd)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'salt', m.salt_composition,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false)
                       then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
    -- CHANGE #748 — the "New" chip, decided against the backend's own window.
    -- CMD #2190 — the window is read once per page, not twice per card.
    'is_new', (m.created_at is not null
               and m.created_at >= now() - make_interval(days => ch.nd)),
    'new_badge', case when (m.created_at is not null
               and m.created_at >= now() - make_interval(days => ch.nd))
                 then public.uic('catalogue.new_badge','New') else '' end,
    -- CMD #2190 — rx and wish are read off the card that was just built. They
    -- are the same two calls the card itself made (_product_card_base sets
    -- 'rx' = rx_card_badge(m.rx_required) and 'wish' = card_wish(m.id)), so
    -- the row is byte-identical and the page makes 24 fewer calls of each.
    'rx', k.card->'rx',
    'wish', k.card->'wish',
    'availability', l.av,
    'pricing', l.pr,
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
    'card', k.card
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt cross join ch
  -- CMD #2190 — `offset 0` fences the lateral. Without it the planner inlines
  -- it and evaluates storefront_pricing()/storefront_cta() once per REFERENCE
  -- — twice per card, and _pricing_block is the most expensive call on the
  -- page. Same fence CMD #2145 put on _product_card_base.
  cross join lateral (select
    public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
        true) as av,
    public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr
    offset 0) l
  cross join lateral (select public._product_card(m, l.pr, l.av,
        coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c) as card
    offset 0) k;
$fn$;

-- ── 6. the search page's cards: the same fence ─────────────────────────────
create or replace function public._search_cards(p_ids bigint[], p_pct numeric, p_zone smallint)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c,
                                  coalesce((select new_days from public.catalogue_extras_config
                                             where id = 1), 30) as nd)
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', m.id,
      'name', m.product_name,
      'company', m.marketer,
      'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
      'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
      'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
      'pack_type_label', public.sf_pack_type_label(m.pack_type),
      'image', m.image_url_1,
      'category', m.therapeutic_class,
      'salt', m.salt_composition,
      'has_offer', coalesce(m.has_scheme, false),
      'offer_chip', case when coalesce(m.has_scheme, false)
                         then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
      'is_new', (m.created_at is not null
                 and m.created_at >= now() - make_interval(days => ch.nd)),
      'new_badge', case when (m.created_at is not null
                 and m.created_at >= now() - make_interval(days => ch.nd))
                   then public.uic('catalogue.new_badge','New') else '' end,
      'rx', k.card->'rx',
      'wish', k.card->'wish',
      -- CMD #2023 — ONE truth. The card button is storefront_cta over
      -- storefront_effective_count, which is public.zone_available().
      'availability', l.av,
      'pricing', l.pr,
      'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                   then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
      'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
      'card', k.card
    ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt cross join ch
  cross join lateral (select
    public.storefront_cta(
          public.storefront_effective_count(m.id,
            coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
          true) as av,
    public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, p_pct, m.id) as pr
    offset 0) l
  cross join lateral (select public._product_card(m, l.pr, l.av,
        coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c) as card
    offset 0) k;
$fn$;

-- ── 7. the storefront's cards: the same fence ──────────────────────────────
create or replace function public._sf_cards(p_ids bigint[])
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'pack_qty_display', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_size_display', coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),'')),
    'pack_type', m.pack_type,
    'pack_qty', m.pack_qty,
    'pack_size', m.pack_size,
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false) then 'Scheme available' else '' end,
    -- CHANGE #461/#170: the prescription class, from "MEDICINE".rx_required.
    'rx', k.card->'rx',
    'wish', k.card->'wish',
    'availability', l.av,
    'pricing', l.pr,
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
    'card', k.card
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt cross join ch
  cross join lateral (select
    public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0))) as av,
    public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr
    offset 0) l
  cross join lateral (select public._product_card(m, l.pr, l.av,
        coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c) as card
    offset 0) k
  where lower(coalesce(m.buyable::text,'')) in ('true','t');
$fn$;

-- ── 8. the wishlist owner, once per transaction ────────────────────────────
-- my_customer_id() walks my_identity_keys() -> login_identities on every call,
-- and the card asks for it once per card. It is viewer state, so it memoises
-- like the other three viewer helpers.
create or replace function public._wish_owner()
returns uuid
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare v_key text; v_memo text; v_ans uuid;
begin
  v_key  := coalesce(auth.uid()::text, 'anon');
  v_memo := nullif(current_setting('medibo.wish_owner', true), '');
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(split_part(v_memo, '|', 2), '')::uuid;
  end if;

  v_ans := coalesce(public.my_customer_id(), auth.uid());

  perform set_config('medibo.wish_owner', v_key || '|' || coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

-- ── 9. the wish chip: three config reads become two ────────────────────────
create or replace function public.card_wish(p_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare v_lbl jsonb; v_has boolean;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_lbl
    from storefront_ui_label where key in ('card_wish_add','card_wish_remove');
  v_has := coalesce((select (value->>'wish')::boolean from public.app_settings where key = 'card.show'), true);

  if auth.uid() is null then
    return jsonb_build_object(
      'has', v_has, 'saved', false,
      'add_label',    coalesce(v_lbl->>'card_wish_add', ''),
      'remove_label', coalesce(v_lbl->>'card_wish_remove', ''));
  end if;
  return jsonb_build_object(
    'has',   v_has,
    'saved', exists (select 1 from public.wishlist_items w
                      where w.account_id = public._wish_owner()
                        and w.product_id = p_id),
    'add_label',    coalesce(v_lbl->>'card_wish_add', ''),
    'remove_label', coalesce(v_lbl->>'card_wish_remove', ''));
end $fn$;

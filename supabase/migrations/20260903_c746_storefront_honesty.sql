-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #746 — Storefront honesty: no margin, and Compare only on the product
-- page.
--
-- THE FACT THIS IS BUILT ON: medicine_pricing holds FOUR rows against 5.6 lakh
-- products. Every margin number the customer surface can draw comes from
-- _pricing_block, which only computes one where pricing_ready — so for
-- 99.999% of the catalogue the app was showing a "Highest margin" sort, four
-- "Above N%" filter chips and a "You earn" line for a rate mediBO does not have
-- yet. In this business the customer buys at a supplier rate DISCOVERED AFTER
-- the purchase, so a margin shown before it is not merely empty, it is wrong.
--
-- The rule, from Om: NEVER show a margin number, sort or filter anywhere in the
-- customer surface (cards, feed chips, product page, cart, compare) unless the
-- backend has real PTR for that product AND the flag is on.
--
-- So the switch is DATA, not deleted code:
--   app_settings.storefront_margin_enabled = false
--   storefront_margin_on()  — the one gate every surface asks
-- The storefront_margin_* RPCs stay, dormant: with the flag off they return the
-- plain feed and an empty option list rather than an error, so turning margin
-- back on the day real PTR lands is one UPDATE and no deploy.
--
-- Compare: it stays on the full product page (same-salt alternatives, which is
-- where comparing means something) and leaves the cards, grids, search results
-- and feed. The card checkbox was drawn from storefront_labels()'s cmp_add, so
-- the payload stops carrying the card-surface compare keys — the app cannot
-- render what it is not sent.
--
-- Idempotent end to end.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. The switch ───────────────────────────────────────────────────────────
insert into public.app_settings (key, value)
values ('storefront_margin_enabled', 'false'::jsonb)
on conflict (key) do nothing;

-- One gate, asked by every surface. Two conditions, both required: the flag is
-- on AND there is at least one buyable product with a real trade rate. Either
-- one alone has already been wrong once.
create or replace function public.storefront_margin_on()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select (value #>> '{}')::boolean
                     from public.app_settings
                    where key = 'storefront_margin_enabled'), false)
     and exists (select 1
                   from public.medicine_pricing mp
                   join public."MEDICINE" m on m.id = mp.product_id
                  where mp.pricing_ready
                    and lower(coalesce(m.buyable::text, '')) in ('true','t'));
$function$;

revoke execute on function public.storefront_margin_on() from public, anon;
grant execute on function public.storefront_margin_on() to authenticated, service_role;

-- ── 2. The catalogue's pricing block loses its margin while the flag is off ──
-- ONE place produces has_margin / margin_pct / margin_label / margin_chip for
-- the customer: _pricing_block, reached through storefront_pricing. Gating the
-- WRAPPER and not the block is deliberate — the supplier bill panel and the
-- supplier's own orders read _pricing_block for a rate that was actually
-- imported from a bill, and that margin is real. This is the customer's door.
create or replace function public.storefront_pricing(
  p_mrp numeric, p_discount_pct numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_none public.medicine_pricing; v_out jsonb;
begin
  v_out := public._pricing_block(p_mrp, v_none, p_discount_pct);
  if public.storefront_margin_on() then return v_out; end if;
  return public._margin_strip(v_out);
end;
$function$;

create or replace function public.storefront_pricing(
  p_mrp numeric, p_discount_pct numeric, p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_row public.medicine_pricing; v_out jsonb;
begin
  if p_product_id is not null then
    select * into v_row from public.medicine_pricing where product_id = p_product_id;
  end if;
  v_out := public._pricing_block(p_mrp, v_row, p_discount_pct);
  if public.storefront_margin_on() then return v_out; end if;
  return public._margin_strip(v_out);
end;
$function$;

-- The strip is its own function so there is exactly one definition of "what a
-- margin field is", and the rg guard below can check the same list.
-- Everything below is a margin EXPRESSION, not just the field called margin:
-- in the priced branch of _pricing_block the card ribbon reads "21.2%" over
-- "margin", and discount_label is the very same chip. Deleting has_margin and
-- leaving the ribbon would have left the number on the card — which is the bug
-- Om reported. What survives is the trade fact: PTR, net, GST, MRP.
create or replace function public._margin_strip(p_pricing jsonb)
returns jsonb
language sql
immutable
as $function$
  select case
    when p_pricing is null or jsonb_typeof(p_pricing) <> 'object' then p_pricing
    else (p_pricing - 'margin_pct' - 'margin_chip' - 'margin_amount')
         || jsonb_build_object(
              'has_margin',     false,
              'margin_label',   '',
              'discount_label', '',
              'has_discount',   false,
              'ribbon_top',     '',
              'ribbon_bottom',  '')
         || case when p_pricing ? 'raw'
                 then jsonb_build_object('raw',
                        (p_pricing->'raw') - 'margin_pct' - 'margin_amount')
                 else '{}'::jsonb end
  end;
$function$;

-- ── 3. The chips, the filter and the margin feed ────────────────────────────
-- The chips Om saw. With the flag off this is an empty list, which is what the
-- screen already renders as "no sort row at all".
create or replace function public.storefront_sort_options(p_active text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_default text := coalesce((select value from storefront_ui_label
                                where key = 'sort_default_label'), 'Popular');
  v_margin  text := coalesce((select value from storefront_ui_label
                                where key = 'sort_margin_label'), 'Highest margin');
  v_active  text := case when coalesce(p_active,'') like 'margin%' then p_active else 'default' end;
  v_chips   jsonb;
begin
  if not (public.viewer_is_approved_customer()
          or public.get_my_role() = any (array['admin','super_admin'])) then
    return '[]'::jsonb;
  end if;

  -- CHANGE #746 — the whole row is margin: one "Popular" chip alone is not a
  -- sort choice, it is decoration. Off means no chips at all.
  if not public.storefront_margin_on() then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', 'margin:' || f.min_pct::text,
           'label', f.label,
           'active', v_active = 'margin:' || f.min_pct::text)
         order by f.sort), '[]'::jsonb)
    into v_chips from public.storefront_margin_filter f where f.active;

  return jsonb_build_array(
    jsonb_build_object('key', 'default', 'label', v_default,
                       'active', v_active = 'default'),
    jsonb_build_object('key', 'margin',  'label', v_margin,
                       'active', v_active = 'margin'))
    || v_chips;
end;
$function$;

create or replace function public.storefront_margin_filters(p_active numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_ready int;
begin
  if not (public.viewer_is_approved_customer()
          or public.get_my_role() = any (array['admin','super_admin'])) then
    return jsonb_build_object('has', false, 'options', '[]'::jsonb);
  end if;

  -- CHANGE #746 — dormant, not deleted. has:false is the shape the screen
  -- already handles, so the day real PTR lands this is one UPDATE.
  if not public.storefront_margin_on() then
    return jsonb_build_object('has', false, 'options', '[]'::jsonb);
  end if;

  select count(*) into v_ready
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where mp.pricing_ready and lower(coalesce(m.buyable::text,'')) in ('true','t');

  select jsonb_agg(jsonb_build_object(
           'min_pct', f.min_pct, 'label', f.label,
           'active', p_active is not null and f.min_pct = p_active)
         order by f.sort)
    into v_rows from public.storefront_margin_filter f where f.active;

  return jsonb_build_object(
    'has', true,
    'title', coalesce((select value from storefront_ui_label where key='margin_filter_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key='margin_filter_note'), ''),
    'priced_count', v_ready,
    'options', jsonb_build_array(
        jsonb_build_object('min_pct', null,
          'label', coalesce((select value from storefront_ui_label where key='margin_filter_all'), ''),
          'active', p_active is null))
      || coalesce(v_rows, '[]'::jsonb));
end $function$;


-- The live ranking, preserved verbatim under a private name so the flag can
-- turn it back on without anyone having to rewrite it from memory.
CREATE OR REPLACE FUNCTION public._storefront_margin_page_on(p_offset integer DEFAULT 0, p_limit integer DEFAULT NULL::integer, p_min_margin numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_initial int := coalesce((select (value #>> '{}')::int from app_settings
                               where key = 'storefront_initial_limit'), 250);
  v_more    int := coalesce((select (value #>> '{}')::int from app_settings
                               where key = 'storefront_more_limit'), 100);
  v_lim     int := greatest(coalesce(nullif(p_limit, 0), v_initial), 1);
  v_off     int := greatest(coalesce(p_offset, 0), 0);
  v_disc    numeric := public.my_cart_discount_pct();
  v_is_admin boolean := public.role_for_medibo_only() = any (array['admin','super_admin']);
  v_total   bigint;
  v_items   jsonb;
  v_n       int;
begin
  if not (public.viewer_is_approved_customer() or v_is_admin) then
    return public.storefront_page('All', v_off, v_lim);
  end if;

  with ready as (
    select mp.product_id,
           ((public._pricing_compute(
               nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
               mp.ptr, mp.gst_pct, v_disc, mp.scheme_buy_qty, mp.scheme_free_qty)
            ) ->> 'margin_pct')::numeric as margin_pct
      from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't'))
  -- The filter keeps only rows whose REAL margin clears the threshold. An item
  -- with no rate was never in `ready` to begin with, so no null-tolerant
  -- comparison can sweep it in and give it a margin it has not got.
  select count(*) into v_total from ready r
   where p_min_margin is null
      or (r.margin_pct is not null and r.margin_pct >= p_min_margin);

  with ready as (
    select mp.product_id,
           ((public._pricing_compute(
               nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
               mp.ptr, mp.gst_pct, v_disc, mp.scheme_buy_qty, mp.scheme_free_qty)
            ) ->> 'margin_pct')::numeric as margin_pct
      from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't')),
  page as (
    select r.product_id, r.margin_pct
      from ready r
     where p_min_margin is null
        or (r.margin_pct is not null and r.margin_pct >= p_min_margin)
     order by r.margin_pct desc nulls last, r.product_id
     offset v_off limit v_lim)
  select coalesce(jsonb_agg(
           to_jsonb(m)
           || jsonb_build_object(
                'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
                'pack_type_label', public.sf_pack_type_label(m.pack_type))
           || jsonb_build_object('supplier_label',
                case when v_is_admin then coalesce(m.supplier_label, '') else '' end)
           || jsonb_build_object('availability',
                public.storefront_cta(public.storefront_effective_count(m.id,
                  coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text, ''), '[^0-9]', '', 'g'), '')::int, 0))))
           || jsonb_build_object('gst_percent_resolved',
                coalesce(m.gst_percent, public.gst_rate_for(m.therapeutic_class)))
           || jsonb_build_object('pricing', public.storefront_pricing(
                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                v_disc, m.id))
           order by p.margin_pct desc nulls last, p.product_id), '[]'::jsonb)
    into v_items
    from page p join "MEDICINE" m on m.id = p.product_id;

  v_n := jsonb_array_length(v_items);

  return jsonb_build_object(
    'status',        'ok',
    'category',      'All',
    'sort',          'margin',
    'sort_options',  public.storefront_sort_options('margin'),
    'margin_filter', public.storefront_margin_filters(p_min_margin),
    'min_margin',    p_min_margin,
    'page_offset',   v_off,
    'page_limit',    v_lim,
    'gated',         public.viewer_is_approved_customer(),
    'showing_label', coalesce((select value from storefront_ui_label
                                 where key = 'sort_margin_showing'), ''),
    'empty_label',   coalesce((select value from storefront_ui_label
                                 where key = 'sort_margin_empty'), ''),
    'total',         v_total,
    'count_label',   to_char(v_total, 'FM9,99,99,999'),
    'initial_limit', v_initial,
    'more_limit',    v_more,
    'next_offset',   v_off + v_n,
    'has_more',      (v_off + v_n) < v_total,
    'more_label',    coalesce((select value from storefront_ui_label
                                 where key = 'load_more_products'), ''),
    'end_label',     coalesce((select value from storefront_ui_label
                                 where key = 'feed_end_label'), ''),
    'items',         v_items);
end $function$;

revoke execute on function public._storefront_margin_page_on(integer, integer, numeric) from public, anon;
grant execute on function public._storefront_margin_page_on(integer, integer, numeric) to authenticated, service_role;

-- The margin feed itself. Dormant means it still ANSWERS — a bookmark, a back
-- button or a cached deep link must not 404 — it just answers with the plain
-- catalogue page instead of a ranking it cannot honestly compute.
create or replace function public.storefront_margin_page(
  p_offset integer default 0, p_limit integer default null, p_min_margin numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if not public.storefront_margin_on() then
    return public.storefront_page('All', p_offset, p_limit)
           || jsonb_build_object('sort', 'default',
                                 'sort_options', '[]'::jsonb,
                                 'margin_filter',
                                   jsonb_build_object('has', false,
                                                      'options', '[]'::jsonb),
                                 'min_margin', null);
  end if;
  return public._storefront_margin_page_on(p_offset, p_limit, p_min_margin);
end $function$;

-- ── 4. Compare leaves the cards ─────────────────────────────────────────────
-- The card checkbox and the tray above the grid were drawn from
-- storefront_labels()'s cmp_add / cmp_cta / cmp_clear / cmp_full. The product
-- PAGE does not read that bundle — product_detail_v2 carries its own `compare`
-- block — so dropping these four keys from the bundle removes compare from
-- every card, grid, search result and feed and leaves the product page intact.
-- The rows stay in storefront_ui_label: the compare SHEET still prints them.
create or replace function public.storefront_labels()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from public.storefront_ui_label
   where key not in ('cmp_add', 'cmp_cta', 'cmp_clear', 'cmp_full');
$function$;

-- ── 5. The compare table drops its Margin row ───────────────────────────────
insert into public.storefront_ui_label (key, value) values
  ('cmp_note_no_margin', 'Net rate shows only where a real trade rate exists.')
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public.product_compare(p_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_disc  numeric := public.my_cart_discount_pct();
  v_absent text  := coalesce((select value from storefront_ui_label where key='cmp_absent'), '');
  v_ids   bigint[];
  v_cols  jsonb;
  v_rows  jsonb;
begin
  -- At most three, de-duplicated, in the order the customer picked them. The
  -- cap is enforced here as well as in the tray: a hand-made call must not be
  -- able to build a twenty-column table on a 1 GB instance.
  select array_agg(id order by ord) into v_ids
    from (select distinct on (id) id, ord
            from unnest(coalesce(p_ids, '{}'::bigint[])) with ordinality as t(id, ord)
           order by id, ord) d
   where ord <= 3;

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object(
      'ok', true, 'has', false,
      'title', coalesce((select value from storefront_ui_label where key='cmp_title'), ''),
      'note',  coalesce((select value from storefront_ui_label where key='cmp_note'), ''),
      'empty', coalesce((select value from storefront_ui_label where key='cmp_empty'), ''),
      'products', '[]'::jsonb, 'rows', '[]'::jsonb);
  end if;

  -- One pass over the chosen products, as a CTE rather than a temp table:
  -- this function is STABLE (a read the storefront makes on every tray open)
  -- and a STABLE function may not CREATE TABLE. Everything a cell can need is
  -- resolved here, from the SAME helpers the product page and the cards use:
  -- storefront_pricing (rate/margin/GST), product_trust_strip (fill rate),
  -- product_rating_summary (the reviews aggregate), storefront_cta
  -- (availability). No second opinion is computed anywhere below.
  --
  -- Each row is built the same way: a label, then one {has,value} cell per
  -- column, ordered by the position the customer picked. `has:false` is the
  -- ONLY way a cell says "we do not know this" — there is no empty-string
  -- convention for the app to misread as a value.
  with src as (
    select m.id,
           ord.n                                as pos,
           coalesce(m.product_name, '')         as name,
           coalesce(m.marketer, '')             as company,
           coalesce(m.image_url_1, '')          as image,
           coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),''), '') as pack,
           public.storefront_pricing(
             nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
             v_disc, m.id)                      as pricing,
           public.product_trust_strip(m.id, m.cold_chain) as trust,
           public.product_rating_summary(m.id)  as rating,
           public.storefront_cta(public.storefront_effective_count(m.id, m.supplier_count)) as cta
      from unnest(v_ids) with ordinality as ord(pid, n)
      join "MEDICINE" m on m.id = ord.pid
  ), cols as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',      c.id::text,
             'name',    c.name,
             'company', c.company,
             'image',   c.image,
             'pricing', c.pricing) order by c.pos), '[]'::jsonb) as v
      from src c
  ), cells as (
    select 'rate' as key, 1 as ord,
           coalesce((select value from storefront_ui_label where key='cmp_row_rate'), '') as label,
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.pricing->>'has_net')::boolean, false),
             'value', case when coalesce((c.pricing->>'has_net')::boolean, false)
                           then c.pricing->>'net_display' else v_absent end,
             'tone',  'text') order by c.pos) as cells
      from src c
    union all
    select 'margin', 2,
           coalesce((select value from storefront_ui_label where key='cmp_row_margin'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.pricing->>'has_margin')::boolean, false),
             'value', case when coalesce((c.pricing->>'has_margin')::boolean, false)
                           then c.pricing->'margin_chip'->>'label' else v_absent end,
             'tone',  case when coalesce((c.pricing->>'has_margin')::boolean, false)
                           and coalesce((c.pricing->>'margin_pct')::numeric, 0) >= 0
                           then 'success' else 'text' end) order by c.pos)
      from src c
    union all
    select 'gst', 3,
           coalesce((select value from storefront_ui_label where key='cmp_row_gst'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.pricing->'gst' is not null and c.pricing->'gst' <> 'null'::jsonb),
             'value', coalesce(c.pricing->'gst'->>'pct_display', v_absent),
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'pack', 4,
           coalesce((select value from storefront_ui_label where key='cmp_row_pack'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.pack <> ''),
             'value', case when c.pack <> '' then c.pack else v_absent end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'fill', 5,
           coalesce((select value from storefront_ui_label where key='cmp_row_fill'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.trust->'fill_rate'->>'has')::boolean, false),
             'value', case when coalesce((c.trust->'fill_rate'->>'has')::boolean, false)
                           then c.trust->'fill_rate'->>'label' else v_absent end,
             'tone',  coalesce(c.trust->'fill_rate'->>'tone', 'text')) order by c.pos)
      from src c
    union all
    select 'rating', 6,
           coalesce((select value from storefront_ui_label where key='cmp_row_rating'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.rating->>'has')::boolean, false),
             'value', case when coalesce((c.rating->>'has')::boolean, false)
                           then (c.rating->>'stars_label') || ' · ' || (c.rating->>'count_label')
                           else coalesce(nullif(c.rating->>'empty',''), v_absent) end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'company', 7,
           coalesce((select value from storefront_ui_label where key='cmp_row_company'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.company <> ''),
             'value', case when c.company <> '' then c.company else v_absent end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'stock', 8,
           coalesce((select value from storefront_ui_label where key='cmp_row_stock'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   true,
             'value', coalesce(c.cta->>'cta_label', v_absent),
             'tone',  case when coalesce((c.cta->>'can_add')::boolean, false)
                           then 'success' else 'warning' end) order by c.pos)
      from src c
  )
  select (select v from cols),
         coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'cells', cells)
                                    order by ord) from cells), '[]'::jsonb)
    into v_cols, v_rows;

  -- CHANGE #746 — the Margin row leaves the table entirely while the flag is
  -- off. A row of dashes is not honesty, it is a promise the catalogue cannot
  -- keep; and the note above the table says "rate and margin", so that goes
  -- too.
  if not public.storefront_margin_on() then
    select coalesce(jsonb_agg(r order by ord), '[]'::jsonb) into v_rows
      from jsonb_array_elements(v_rows) with ordinality as t(r, ord)
     where r->>'key' <> 'margin';
  end if;

  return jsonb_build_object(
    'ok',       true,
    'has',      true,
    'title',    coalesce((select value from storefront_ui_label where key='cmp_title'), ''),
    'note',     coalesce((select value from storefront_ui_label
                             where key = case when public.storefront_margin_on()
                                              then 'cmp_note' else 'cmp_note_no_margin' end), ''),
    'empty',    coalesce((select value from storefront_ui_label where key='cmp_empty'), ''),
    'max',      3,
    'labels', jsonb_build_object(
      'add',    coalesce((select value from storefront_ui_label where key='cmp_add'), ''),
      'cta',    coalesce((select value from storefront_ui_label where key='cmp_cta'), ''),
      'clear',  coalesce((select value from storefront_ui_label where key='cmp_clear'), ''),
      'remove', coalesce((select value from storefront_ui_label where key='cmp_remove'), ''),
      'full',   coalesce((select value from storefront_ui_label where key='cmp_full'), ''),
      'min',    coalesce((select value from storefront_ui_label where key='cmp_min'), '')),
    'products', v_cols,
    'rows',     v_rows);
end $function$;

-- ── 6. The guard ────────────────────────────────────────────────────────────
-- Om's rule written as a test, because a rule nobody checks comes back. With
-- the flag off, no customer feed or card payload may carry a margin number or
-- a compare affordance. It asks the RPCs themselves rather than reading the
-- source, so a new caller that reintroduces the field is caught too.
insert into public.rg_behavior_tests (name, body, enabled, note) values (
'c746_no_margin_no_card_compare',
$rg$
do $body$
declare
  v_on   boolean := public.storefront_margin_on();
  v_p    jsonb;
  v_bad  text;
begin
  if v_on then
    -- The flag is ON: margin is allowed to appear, so there is nothing to
    -- police here. This test exists for the OFF state.
    raise exception 'RG_ROLLBACK';
  end if;

  -- 1. The card/PDP/compare pricing block carries no margin number — checked on
  --    a PRICED product, because the unpriced path never had one. This is the
  --    exact payload the card ribbon read "21.2% margin" from.
  select public.storefront_pricing(
           nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
           null::numeric, m.id)
    into v_p
    from public."MEDICINE" m
    join public.medicine_pricing mp on mp.product_id = m.id
   where mp.pricing_ready
   limit 1;
  if v_p is null then
    v_p := public.storefront_pricing(100::numeric, null::numeric, null::bigint);
  end if;
  if coalesce((v_p->>'has_margin')::boolean, false)
     or v_p ? 'margin_pct' or v_p ? 'margin_chip' or v_p ? 'margin_amount'
     or coalesce(v_p->>'margin_label','') <> ''
     or coalesce(v_p->>'discount_label','') <> ''
     or coalesce(v_p->>'ribbon_top','') <> ''
     or coalesce(v_p->>'ribbon_bottom','') <> ''
     or coalesce(v_p->'raw', '{}'::jsonb) ? 'margin_pct'
     or coalesce(v_p->'raw', '{}'::jsonb) ? 'margin_amount' then
    raise exception 'RG_FAIL: storefront_pricing still carries a margin while storefront_margin_enabled is off: %', v_p;
  end if;

  -- 2. The feed's sort row is the margin row. Off means no chips.
  if jsonb_array_length(coalesce(public.storefront_sort_options(null), '[]'::jsonb)) <> 0 then
    raise exception 'RG_FAIL: storefront_sort_options still returns margin chips while the flag is off';
  end if;

  -- 3. The margin filter is dormant, not merely empty-optioned.
  if coalesce((public.storefront_margin_filters(null)->>'has')::boolean, false) then
    raise exception 'RG_FAIL: storefront_margin_filters says has:true while the flag is off';
  end if;

  -- 4. Compare belongs to the product page. The storefront label bundle — the
  --    only thing a card reads — must not carry the card-surface compare keys.
  select string_agg(k, ', ') into v_bad
    from (select jsonb_object_keys(public.storefront_labels()) k) t
   where k in ('cmp_add','cmp_cta','cmp_clear','cmp_full');
  if v_bad is not null then
    raise exception 'RG_FAIL: storefront_labels() still sends the card compare keys: %', v_bad;
  end if;

  -- 5. ...and the product page still HAS its compare block, so this guard can
  --    never be satisfied by deleting compare altogether.
  if coalesce((select value from public.storefront_ui_label where key='cmp_add'), '') = '' then
    raise exception 'RG_FAIL: cmp_add is gone from storefront_ui_label — the product page compare needs it';
  end if;

  -- The harness runs every behaviour inside a transaction and expects it to
  -- end by rolling itself back, so a test can probe freely and leave nothing.
  raise exception 'RG_ROLLBACK';
end $body$;
$rg$,
true,
'CHANGE #746 — medicine_pricing has 4 rows against 5.6 lakh products, so a margin shown to a customer is a number mediBO does not have. Off means off: no margin field in the pricing block, no sort chips, no filter, and no compare on cards.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

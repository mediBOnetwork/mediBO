-- CMD #2040 — Product page polish.
--
-- Six spec items, all of them decided in SQL so the page stays a renderer:
--   1. the PDP price block is the CARD's price block (struck MRP, then
--      "Sale price:" + the green badge carrying pricing.price_display);
--   2. the corner Rx badge on a card becomes a wishlist heart, so every card
--      payload now carries a `wish` block;
--   3. the Rx chip moves beside the pack chip on the PDP (frontend only —
--      rx_badge() already words it);
--   4. "same composition" and "same salt" become ONE backend-titled rail whose
--      items are FULL storefront cards, so the page can draw the exact same
--      widget the storefront draws;
--   5. Compare is a button, not a tray: one tap opens the same-salt table;
--   6. Introduction / Uses / Benefits are accordions — and WHICH sections
--      those are is a label, not a Dart literal.
--
-- Idempotent throughout. The three card builders and product_detail itself are
-- patched by SPLICING one key into their LIVE definition rather than being
-- rewritten from a copy: this file is replayed on production long after it was
-- written here, and a wholesale CREATE OR REPLACE would silently revert
-- whatever landed in between.

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value) values
  ('card_wish_add',          'Save'),
  ('card_wish_remove',       'Saved'),
  ('cmp_open',               'Compare'),
  ('cmp_salt_note',          'Other brands with the same composition.'),
  ('cmp_row_mrp',            'MRP'),
  ('cmp_row_sale',           'Sale price'),
  ('pdp_accordion_sections', 'Introduction,Uses,Benefits')
on conflict (key) do nothing;

-- ── 2. The wishlist block every card carries ────────────────────────────────
-- `has` is the same rule product_detail() already uses for its own wishlist
-- control (viewer_is_approved_customer), so a card and the page it opens can
-- never disagree about whether the heart exists. `saved` is the account's row,
-- never auth.uid() directly.
create or replace function public.card_wish(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'has',   public.viewer_is_approved_customer(),
    'saved', exists (select 1 from public.wishlist_items w
                      where w.account_id = public.my_customer_id()
                        and w.product_id = p_id),
    'add_label',    coalesce((select value from public.storefront_ui_label
                               where key = 'card_wish_add'), ''),
    'remove_label', coalesce((select value from public.storefront_ui_label
                               where key = 'card_wish_remove'), ''));
$function$;

-- Internal only: it is reached through the SECURITY DEFINER card builders, so
-- nothing outside the database ever needs to call it (constraint #79).
revoke all on function public.card_wish(bigint) from public, anon, authenticated;

-- ── 3. Splice `wish` into the three card builders ───────────────────────────
do $mig$
declare
  v_fn   text;
  v_src  text;
  v_new  text;
  v_anch text := '''rx'', public.rx_badge(m.rx_required),';
begin
  foreach v_fn in array array['_sf_cards', '_cat_cards', '_search_cards'] loop
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
     limit 1;

    if v_src is null then
      raise notice 'c2040: %() not present, skipping', v_fn;
      continue;
    end if;
    if position('''wish'', public.card_wish(' in v_src) > 0 then
      continue;                                  -- already spliced
    end if;
    if position(v_anch in v_src) = 0 then
      raise exception 'c2040: anchor not found in %()', v_fn;
    end if;

    v_new := replace(v_src, v_anch,
                     v_anch || E'\n      ''wish'', public.card_wish(m.id),');
    execute v_new;
  end loop;
end $mig$;

-- ── 4. Which sections are accordions is DATA ────────────────────────────────
-- The page groups the flagged sections into one accordion; the list itself is
-- `pdp_accordion_sections`, so adding "How it works" to it is an UPDATE.
create or replace function public._pdp_accordion_sections(p_sections jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with names as (
    select lower(btrim(x)) as t
      from unnest(string_to_array(
             coalesce((select value from public.storefront_ui_label
                        where key = 'pdp_accordion_sections'), ''), ',')) x
     where btrim(x) <> ''
  )
  select coalesce(
    jsonb_agg(
      s || jsonb_build_object(
        'accordion',
        exists (select 1 from names n where n.t = lower(coalesce(s->>'title', '')))
      ) order by ord), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_sections, '[]'::jsonb)) with ordinality t(s, ord);
$function$;

revoke all on function public._pdp_accordion_sections(jsonb) from public, anon, authenticated;

-- ── 5. ONE rail, and its items are FULL storefront cards ────────────────────
-- The old page drew two rails off the same salt column: `similar` (bare tiles)
-- and `substitutes` (a second design, with its own compare tray). This is the
-- one that survives, and it hands back exactly what the storefront grid gets,
-- so the PDP can render CompactProductCard instead of a look-alike.
create or replace function public.pdp_salt_rail(p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_salt  text;
  v_title text;
  v_ids   bigint[];
begin
  v_title := coalesce((select value from public.storefront_ui_label
                        where key = 'pdp_similar_title'), '');
  select nullif(btrim(m.salt_composition), '') into v_salt
    from "MEDICINE" m where m.id = p_product_id;

  if v_salt is null then
    return jsonb_build_object('has', false, 'title', v_title, 'items', '[]'::jsonb);
  end if;

  select coalesce(array_agg(x.id order by x.rn), '{}'::bigint[]) into v_ids
    from (select s.id,
                 row_number() over (order by s.sales_count desc nulls last, s.id) as rn
            from "MEDICINE" s
           where s.salt_composition = v_salt
             and s.id <> p_product_id
             and s.buyable is true
           order by s.sales_count desc nulls last, s.id
           limit 10) x;

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('has', false, 'title', v_title, 'items', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'has',   true,
    'title', v_title,
    'items', public._sf_cards(v_ids));
end
$function$;

revoke all on function public.pdp_salt_rail(bigint) from public, anon, authenticated;

-- ── 6. Compare is one tap on the PDP ────────────────────────────────────────
-- Same payload SHAPE as product_compare() so the sheet that already exists
-- prints it unchanged; different rows, because the question here is not "which
-- of the three I ticked" but "what else is this salt". The viewed pack is
-- always column one. Prices come from storefront_pricing's card_price block —
-- the same block the cards read — so an unapproved viewer sees the literal
-- word and never a trade rate.
create or replace function public.pdp_salt_compare(p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_disc   numeric := public.my_cart_discount_pct();
  v_absent text := coalesce((select value from public.storefront_ui_label
                              where key = 'cmp_absent'), '');
  v_salt   text;
  v_ids    bigint[];
  v_cols   jsonb;
  v_rows   jsonb;
  v_title  text := coalesce((select value from public.storefront_ui_label
                              where key = 'cmp_title'), '');
  v_note   text := coalesce((select value from public.storefront_ui_label
                              where key = 'cmp_salt_note'), '');
  v_empty  text := coalesce((select value from public.storefront_ui_label
                              where key = 'cmp_empty'), '');
begin
  select nullif(btrim(m.salt_composition), '') into v_salt
    from "MEDICINE" m where m.id = p_product_id;

  select coalesce(array_agg(x.id order by x.rn), '{}'::bigint[]) into v_ids
    from (select s.id,
                 row_number() over (order by s.sales_count desc nulls last, s.id) as rn
            from "MEDICINE" s
           where v_salt is not null
             and s.salt_composition = v_salt
             and s.id <> p_product_id
             and s.buyable is true
           order by s.sales_count desc nulls last, s.id
           limit 5) x;

  v_ids := array_prepend(p_product_id, coalesce(v_ids, '{}'::bigint[]));

  if coalesce(array_length(v_ids, 1), 0) < 2 then
    return jsonb_build_object(
      'ok', true, 'has', false,
      'title', v_title, 'note', v_note, 'empty', v_empty,
      'products', '[]'::jsonb, 'rows', '[]'::jsonb);
  end if;

  with src as (
    select m.id,
           ord.n as pos,
           (m.id = p_product_id)                as is_current,
           coalesce(m.product_name, '')         as name,
           coalesce(m.marketer, '')             as company,
           coalesce(m.image_url_1, '')          as image,
           coalesce(nullif(btrim(m.pack_type), ''),
                    nullif(btrim(m.pack_size), ''), '') as pack,
           public.storefront_pricing(
             nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
             v_disc, m.id)                      as pricing,
           public.storefront_cta(
             public.storefront_effective_count(m.id,
               coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text, ''),
                                              '[^0-9]', '', 'g'), '')::int, 0)), true) as cta
      from unnest(v_ids) with ordinality as ord(pid, n)
      join "MEDICINE" m on m.id = ord.pid
  ), cols as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',         c.id::text,
             'name',       c.name,
             'company',    c.company,
             'image',      c.image,
             'pricing',    c.pricing,
             'is_current', c.is_current,
             'can_add',    coalesce((c.cta->>'can_add')::boolean, false),
             'cta_label',  coalesce(nullif(c.cta->>'cta_short', ''),
                                    c.cta->>'cta_label', '')) order by c.pos), '[]'::jsonb) as v
      from src c
  ), cells as (
    select 'company' as key, 1 as ord,
           coalesce((select value from public.storefront_ui_label
                      where key = 'cmp_row_company'), '') as label,
           jsonb_agg(jsonb_build_object(
             'has',   (c.company <> ''),
             'value', case when c.company <> '' then c.company else v_absent end,
             'tone',  'text') order by c.pos) as cells
      from src c
    union all
    select 'pack', 2,
           coalesce((select value from public.storefront_ui_label
                      where key = 'cmp_row_pack'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.pack <> ''),
             'value', case when c.pack <> '' then c.pack else v_absent end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'mrp', 3,
           coalesce((select value from public.storefront_ui_label
                      where key = 'cmp_row_mrp'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.pricing->'card_price'->>'has_mrp')::boolean, false),
             'value', case when coalesce((c.pricing->'card_price'->>'has_mrp')::boolean, false)
                           then c.pricing->'card_price'->>'mrp_display' else v_absent end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'sale', 4,
           coalesce((select value from public.storefront_ui_label
                      where key = 'cmp_row_sale'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (coalesce(c.pricing->'card_price'->>'price_display', '') <> ''),
             'value', coalesce(nullif(c.pricing->'card_price'->>'price_display', ''), v_absent),
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'stock', 5,
           coalesce((select value from public.storefront_ui_label
                      where key = 'cmp_row_stock'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   true,
             'value', coalesce(nullif(c.cta->>'cta_label', ''), v_absent),
             'tone',  case when coalesce((c.cta->>'can_add')::boolean, false)
                           then 'success' else 'warning' end) order by c.pos)
      from src c
  )
  select (select v from cols),
         coalesce((select jsonb_agg(jsonb_build_object(
                            'key', key, 'label', label, 'cells', cells) order by ord)
                     from cells), '[]'::jsonb)
    into v_cols, v_rows;

  return jsonb_build_object(
    'ok',       true,
    'has',      true,
    'title',    v_title,
    'note',     v_note,
    'empty',    v_empty,
    'max',      coalesce(array_length(v_ids, 1), 0),
    'products', v_cols,
    'rows',     v_rows);
end
$function$;

-- The PDP is a public page, so its compare table is reachable anonymously —
-- the trade rate inside it is already gated by storefront_pricing, which hands
-- an unapproved viewer the literal word instead of a number (constraint #79).
grant execute on function public.pdp_salt_compare(bigint) to anon, authenticated, service_role;

-- ── 7. Splice the two new blocks into product_detail() ──────────────────────
do $mig$
declare
  v_src  text;
  v_new  text;
  v_anch text := '''other_packs'', v_packs);';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'product_detail'
   limit 1;

  if v_src is null then
    raise exception 'c2040: product_detail() not present';
  end if;

  if position('''salt_rail''' in v_src) = 0 then
    if position(v_anch in v_src) = 0 then
      raise exception 'c2040: anchor not found in product_detail()';
    end if;
    v_new := replace(v_src, v_anch,
      '''other_packs'', v_packs,' || E'\n' ||
      '    ''salt_rail'',   public.pdp_salt_rail(p_product_id),' || E'\n' ||
      '    ''sections'',    public._pdp_accordion_sections(v->''sections''));');
    execute v_new;
  end if;
end $mig$;

-- ── 8. The compare button's word, and the rail that leaves ──────────────────
-- product_detail_v2 stops calling same_composition_options(): that block fed
-- the second rail, which this change removes. The function itself is
-- untouched — other flows (the substitute ask) still use it.
do $mig$
declare
  v_src text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'product_detail_v2'
   limit 1;

  if v_src is null then
    raise exception 'c2040: product_detail_v2() not present';
  end if;

  v_new := v_src;

  if position('''open_label''' in v_new) = 0 then
    if position('''max'',       3));' in v_new) = 0 then
      raise exception 'c2040: compare-block anchor not found in product_detail_v2()';
    end if;
    v_new := replace(v_new, '''max'',       3));',
      '''max'',       3,' || E'\n' ||
      '      ''open_label'', coalesce((select value from storefront_ui_label where key=''cmp_open''), '''')));');
  end if;

  if position('same_composition_options' in v_new) > 0 then
    v_new := replace(v_new,
      '''substitutes'',      public.same_composition_options(p_product_id, 10),',
      '-- CMD #2040 — the second salt rail left the page; ONE rail remains.' || E'\n' ||
      '    ''substitutes'',      jsonb_build_object(''has'', false),');
  end if;

  if v_new <> v_src then
    execute v_new;
  end if;
end $mig$;

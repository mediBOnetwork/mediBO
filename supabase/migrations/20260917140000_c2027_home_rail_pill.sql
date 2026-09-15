-- CMD #2027 — one calm "See all products" pill on every home rail.
--
-- The feed used to end every section with a full-width button painted in that
-- section's own accent (red, purple, blue, green) reading "Show all 1,934
-- products". Five loud colours down one scroll is not a system, and the count
-- in the label made every pill a different width and a different sentence.
--
-- Three things move to the backend here, because the app must decide none of
-- them:
--   1. The wording. `see_all_count_label` was the "Show all {n} products"
--      format; blanking it is what makes every rail read the neutral
--      `see_all_label` ("See all products") instead. Re-wording the pill stays
--      an UPDATE of these two rows, never a deploy.
--   2. The thumbnails. `see_all_thumbs` is the list of product photos the pill
--      shows, already filtered to the ones that HAVE a photo — the app must
--      never take three cards and hope, which is how a blank white circle got
--      on screen.
--   3. Shop by company now carries a pill of its own (`see_all` +
--      `see_all_label` + `see_all_thumbs`), pointing at the companies list.
--      Its thumbs are one real product photo from each of the top companies,
--      so the pill can never advertise art the section does not hold.
--
-- Whole-catalogue sections (category 'All' — Best Sellers, All products) are
-- unchanged: the hero's Browse-catalogue CTA is that door, and the app's
-- existing 'All' rule still suppresses their bar.

-- 1 ── the wording: no count in the label ────────────────────────────────────
update public.storefront_ui_label
   set value = ''
 where key = 'see_all_count_label'
   and value <> '';

insert into public.storefront_ui_label (key, value)
values ('see_all_label', 'See all products')
on conflict (key) do nothing;

-- 2 ── the payload: thumbs on every section, a pill on Shop by company ───────
create or replace function public._storefront_home_build(p_items integer default 100)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_sections    jsonb := '[]'::jsonb;
  v_ords        jsonb := '[]'::jsonb;
  v_ids         bigint[];
  v_see_all     text;
  v_see_fmt     text;
  v_label       text;
  v_search_hint text;
  v_theme       jsonb;
  v_title       text;
  v_accentw     text;
  v_subtitle    text;
  v_n           int;
  v_total       int;
  v_cap         int;
  v_items       jsonb;
  v_thumbs      jsonb;
  s             record;
begin
  select public.storefront_theme() into v_theme;
  v_see_all := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_label'), 'See all products');
  v_see_fmt := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_count_label'), '');
  v_search_hint := coalesce((select value from public.storefront_ui_label
                              where key = 'search_hint'), '');

  for s in
    select * from public.storefront_home_section where active order by ord
  loop
    v_n := least(s.item_count, greatest(coalesce(p_items, 100), 1));

    if s.kind = 'feed' then
      select array_agg(f.product_id order by f.rank) into v_ids
        from public._sf_feed_ids(s.category, 0, v_n) f;
      continue when v_ids is null;

      v_title    := case when s.title <> '' then s.title
                         else initcap(lower(s.category)) end;
      v_accentw  := case when s.accent_word <> '' then s.accent_word
                         else split_part(initcap(lower(s.category)), ' ', 1) end;
      v_subtitle := case when s.subtitle <> '' then s.subtitle
                         else 'TOP PICKS IN ' || s.category end;

      v_total := public.get_storefront_count(s.category);
      v_cap   := case when s.max_items > 0 then least(v_total, s.max_items)
                      else v_total end;
      v_label := case when v_see_fmt <> ''
                      then replace(v_see_fmt, '{n}', to_char(v_total, 'FM999,999'))
                      else v_see_all end;

      v_items := public._sf_cards(v_ids);

      -- The pill's thumbnails. FILTERED FIRST, then capped at three: taking
      -- the first three cards and dropping the ones without a photo is how a
      -- rail full of photographed products still showed one lonely disc.
      v_thumbs := (
        select coalesce(jsonb_agg(t.img), '[]'::jsonb)
          from (select e ->> 'image' as img
                  from jsonb_array_elements(v_items) e
                 where coalesce(e ->> 'image', '') <> ''
                 limit 3) t);

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title', v_title, 'accent_word', v_accentw, 'subtitle', v_subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', v_label,
        'see_all', jsonb_build_object('type','category','key', s.category),
        'see_all_thumbs', v_thumbs,
        'infinite', s.infinite,
        'next_offset', coalesce(array_length(v_ids, 1), 0),
        'page_size', s.page_size,
        'total', v_cap,
        'items', v_items);
      v_ords := v_ords || to_jsonb(s.ord);

    elsif s.kind = 'recently_viewed' then
      continue;   -- per user: spliced in by storefront_home_v2

    elsif s.kind = 'icon_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'icon_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', initcap(lower(fm.category)),
            'count_label', to_char(fm.total,'FM999,999') || ' products',
            'key', fm.category) order by fm.total desc), '[]'::jsonb)
          from (select c.category, c.total from public._sf_category_counts() c
                 where c.category <> 'All' and c.total > 0
                 order by c.total desc limit s.item_count) fm));
      v_ords := v_ords || to_jsonb(s.ord);

    elsif s.kind = 'brand_grid' then
      -- One photo per top company, so the three discs are three different
      -- makers rather than three packs of the same strip.
      v_thumbs := (
        select coalesce(jsonb_agg(t.img), '[]'::jsonb)
          from (select q.img
                  from (select (select m.image_url_1
                                  from "MEDICINE" m
                                 where m.marketer_canonical = mc.canon
                                   and coalesce(m.image_url_1, '') <> ''
                                   and lower(coalesce(m.buyable::text,'')) in ('true','t')
                                 limit 1) as img
                          from (select canon from public.medicine_company
                                 where buyable_count > 0
                                 order by buyable_count desc
                                 limit 6) mc) q
                 where q.img is not null
                 limit 3) t);

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'brand_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        -- The same pill as every product rail. 'companies' is a destination
        -- NAME the app maps onto navigation it already has; it is deliberately
        -- not 'All', which is the whole-catalogue key the app suppresses.
        'see_all_label', v_see_all,
        'see_all', jsonb_build_object('type','companies','key','all'),
        'see_all_thumbs', v_thumbs,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', mc.display,
            'count_label', to_char(mc.buyable_count,'FM999,999') || ' products',
            'key', mc.canon) order by mc.buyable_count desc), '[]'::jsonb)
          from (select display, canon, buyable_count from public.medicine_company
                 where buyable_count > 0 order by buyable_count desc
                 limit s.item_count) mc));
      v_ords := v_ords || to_jsonb(s.ord);
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'generated_for', 'home',
    'theme', v_theme,
    'header', jsonb_build_object(
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'fg',        '#FFFFFF',
      'accent',    v_theme->>'accent',
      'search_hint', v_search_hint),
    'hero', jsonb_build_object(
      'show',    true,
      'eyebrow', coalesce((select value from public.storefront_ui_label where key = 'hero_eyebrow'), ''),
      'title',   coalesce((select value from public.storefront_ui_label where key = 'hero_title'), ''),
      'cta',     coalesce((select value from public.storefront_ui_label where key = 'hero_cta'), ''),
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'accent',    v_theme->>'accent',
      'props', jsonb_build_array(
        jsonb_build_object('icon','inventory','label',
          to_char(public.storefront_viewer_count(),'FM9,99,99,999') || '+ products'),
        jsonb_build_object('icon','truck','label',coalesce((select value from public.storefront_ui_label where key='delivery_time'),'Same-day delivery')),
        jsonb_build_object('icon','verified','label','Licensed distributors'))),
    'sections', v_sections,
    '_ords', v_ords);
end
$function$;

-- 3 ── the cached payload predates the pill: rebuild it ───────────────────────
delete from public.storefront_home_cache;

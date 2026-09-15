-- CMD #2037 — Home polish pack, backend half.
--
-- 1. The category chip row (All / OTHERS / ANTI INFECTIVES / CARDIAC) under the
--    search bar is gone from every surface. `search_chip_row_surfaces` is the
--    backend's list of surfaces that draw it; emptying it is what turns the row
--    off for an app that still has the old code cached.
-- 2. The update bar sits DIRECTLY on the bottom nav — 0 gap — so its float
--    height is the nav's own height, not the nav plus a spacing step.
-- 3. "Shop by company" gets its own pill wording ("Show all companies"); it was
--    printing the product rails' "See all products".
--
-- Idempotent: every statement is an upsert or a CREATE OR REPLACE.

-- 1 ── the chip row, off everywhere -----------------------------------------
insert into public.app_settings (key, value)
values ('search_chip_row_surfaces', '[]'::jsonb)
on conflict (key) do update set value = excluded.value;

-- 2 ── the update bar floats exactly one bottom-nav height off the screen ----
insert into public.app_settings (key, value)
values ('app_update_bar', jsonb_build_object(
          'icon','settings','enabled',true,'bottom_gap',56,
          'web_enabled',true,'poll_seconds',300,
          'android_enabled',true,'min_version_code',0))
on conflict (key) do update
  set value = public.app_settings.value || jsonb_build_object('bottom_gap', 56);

-- 3 ── the company pill's own words -----------------------------------------
insert into public.storefront_ui_label (key, value)
values ('see_all_companies_label', 'Show all companies')
on conflict (key) do update set value = excluded.value;

CREATE OR REPLACE FUNCTION public._storefront_home_build(p_items integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sections    jsonb := '[]'::jsonb;
  v_ords        jsonb := '[]'::jsonb;
  v_ids         bigint[];
  v_see_all     text;
  v_see_fmt     text;
  v_see_comp    text;
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
  -- CMD #2037 — Shop by company gets its OWN pill wording. It used the
  -- product rails' label, so the one control that opens the COMPANY list read
  -- "See all products". A storefront_ui_label row, so re-wording it is an
  -- UPDATE.
  v_see_comp := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_companies_label'), 'Show all companies');
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
        'see_all_label', v_see_comp,
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

-- The feed is cached per zone; a wording change has to invalidate it or the
-- old pill keeps being served for up to ten minutes.
delete from public.storefront_home_cache;

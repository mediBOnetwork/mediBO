-- CMD #2020 — the Catalogue landing, made a place rather than a menu.
--
-- Everything this change adds is a PAYLOAD: the tile gradients, the preview
-- rows under each tile, the top-selling rail, the promo banner's words and
-- whether it exists at all. Flutter draws what arrives and decides none of it,
-- which is why the palette lives in app_settings and a re-colour is an UPDATE.
--
-- Idempotent: every statement is create-or-replace / insert-on-conflict, so
-- the live replay can run it once or twice with the same result.

-- ── 1. the words ──────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('catalogue.top_selling_title',  to_jsonb('Top selling'::text)),
  ('catalogue.top_selling_note',   to_jsonb('What pharmacies near you order most'::text)),
  ('catalogue.top_selling_fallback_note', to_jsonb('Available in your zone'::text)),
  ('catalogue.schemes_promo_title',    to_jsonb('Schemes & offers'::text)),
  ('catalogue.schemes_promo_subtitle', to_jsonb('Extra units on selected packs'::text)),
  ('catalogue.schemes_promo_action',   to_jsonb('View all'::text)),
  ('catalogue.preview_more',       to_jsonb('+{n} more'::text)),
  ('catalogue.rail_products_label', to_jsonb('Jump to a letter'::text))
on conflict (key) do nothing;

-- ── 2. the palette + the landing switches ─────────────────────────────────
-- Merged, never replaced: show_recent / show_tabs / show_tree keep whatever
-- they are set to. (The lesson pool_set taught — patching a sub-key must not
-- wipe its siblings.)
insert into public.app_settings (key, value)
values ('catalogue_landing', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings
   set value = jsonb_build_object(
         'show_recent', coalesce(value->'show_recent', 'true'::jsonb),
         'show_tabs',   coalesce(value->'show_tabs',   'true'::jsonb),
         'show_tree',   coalesce(value->'show_tree',   'false'::jsonb),
         -- how many products a scope may hold before the A–Z strip stops
         -- asking which letters are live and simply offers all of them.
         'rail_scan_max', coalesce(value->'rail_scan_max', '50000'::jsonb),
         'top_selling_days',  coalesce(value->'top_selling_days',  '30'::jsonb),
         'top_selling_limit', coalesce(value->'top_selling_limit', '12'::jsonb),
         'tiles', coalesce(value->'tiles', jsonb_build_object(
            'companies',  jsonb_build_object('from','#0E6B3A','to','#1B7A43','on','#FFFFFF'),
            'salts',      jsonb_build_object('from','#0B5FA5','to','#2E86DE','on','#FFFFFF'),
            'conditions', jsonb_build_object('from','#8A4B00','to','#C46A0B','on','#FFFFFF'),
            'browse',     jsonb_build_object('from','#5B2A86','to','#7C4DAB','on','#FFFFFF'))),
         'promo', coalesce(value->'promo', jsonb_build_object(
            'from','#7A1F3D','to','#B02E57','on','#FFFFFF')),
         'chip_tones', coalesce(value->'chip_tones',
            '["#E8F3EC","#EAF1FB","#FDF0E3","#F2ECFA","#FDECEF","#E9F6F6"]'::jsonb))
 where key = 'catalogue_landing';

-- ── 3. the landing config, read once per call ─────────────────────────────
create or replace function public._cat_landing_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((select value from public.app_settings where key = 'catalogue_landing'),
                  '{}'::jsonb)
      || '{}'::jsonb;
$fn$;

-- ── 4. one tile's preview ─────────────────────────────────────────────────
-- The tile previews are the FACET table's own top rows: nothing is ranked in
-- Dart and nothing is abbreviated there either. `kind` is what the tile draws
-- with them — a disc row, a coloured chip row or two plain names.
create or replace function public._cat_tile_preview(
  p_facet text, p_zone smallint, p_kind text, p_limit int)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  with tones as (
    select coalesce(public._cat_landing_cfg()->'chip_tones',
                    '["#E8F3EC","#EAF1FB","#FDF0E3"]'::jsonb) as t
  ),
  top as (
    select c.facet_key, c.label, c.n,
           row_number() over (order by c.n desc, c.label) - 1 as ord
      from public.catalogue_facet_count c
     where c.facet = p_facet
       and c.zone_id = coalesce(p_zone, 0::smallint)
       and coalesce(btrim(c.label),'') <> ''
       and (p_facet <> 'therapeutic' or coalesce(c.parent_key,'') = '')
     order by c.n desc, c.label
     limit greatest(coalesce(p_limit,0), 0)
  )
  select jsonb_build_object(
    'kind', p_kind,
    'has',  exists (select 1 from top),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'key',   t.facet_key,
        'label', t.label,
        'letter', public._cat_letter(t.label),
        'tone',  (select (tones.t ->> (t.ord % greatest(jsonb_array_length(tones.t),1))::int)
                    from tones),
        'count_label', public.cat_count_label(t.n))
      order by t.ord) from top t), '[]'::jsonb));
$fn$;

-- ── 5. the top-selling rail ───────────────────────────────────────────────
-- Ranked by what this zone actually ordered in the window, and when the zone
-- has no order history yet, by what is simply available in it. The NOTE says
-- which of the two the shopper is looking at, so the rail never silently
-- claims a popularity it does not have.
create or replace function public.catalogue_top_selling(p_zone boolean default true)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_az    smallint := public._cat_avail_zone();
  v_cfg   jsonb    := public._cat_landing_cfg();
  v_days  int      := greatest(coalesce((v_cfg->>'top_selling_days')::int, 30), 1);
  v_lim   int      := least(greatest(coalesce((v_cfg->>'top_selling_limit')::int, 12), 1), 24);
  v_ids   bigint[] := '{}'::bigint[];
  v_note  text;
  v_cards jsonb;
begin
  -- 1. the window: quantity ordered in this zone over the last v_days.
  select coalesce(array_agg(x.product_id order by x.q desc, x.product_id), '{}'::bigint[])
    into v_ids
    from (
      select oi.product_id, sum(coalesce(oi.quantity,0))::numeric as q
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
       where o.created_at >= now() - make_interval(days => v_days)
         and oi.product_id is not null
         and (v_az is null or o.zone_id = v_az)
       group by oi.product_id
       having sum(coalesce(oi.quantity,0)) > 0
       order by 2 desc, 1
       limit v_lim) x;
  v_note := public.uic('catalogue.top_selling_note',
                       'What pharmacies near you order most');

  -- 2. the fallback: what this zone can actually buy.
  if coalesce(array_length(v_ids,1),0) = 0 then
    select coalesce(array_agg(y.id order by y.id), '{}'::bigint[])
      into v_ids
      from (
        select m.id
          from public."MEDICINE" m
          join public.catalogue_zone_avail za
            on za.product_id = m.id
           and za.zone_id = coalesce(v_az, za.zone_id)
         where lower(coalesce(m.buyable::text,'')) in ('true','t')
         order by m.id
         limit v_lim) y;
    v_note := public.uic('catalogue.top_selling_fallback_note',
                         'Available in your zone');
  end if;

  -- 3. still nothing (an empty zone, an anonymous visitor before any zone is
  --    known): the block says has:false and the app draws no rail at all.
  if coalesce(array_length(v_ids,1),0) = 0 then
    select coalesce(array_agg(z.id order by z.id), '{}'::bigint[])
      into v_ids
      from (select m.id from public."MEDICINE" m
             where lower(coalesce(m.buyable::text,'')) in ('true','t')
             order by m.id limit v_lim) z;
    v_note := public.uic('catalogue.top_selling_fallback_note',
                         'Available in your zone');
  end if;

  v_cards := public._sf_cards(v_ids);
  return jsonb_build_object(
    'has',   jsonb_array_length(coalesce(v_cards,'[]'::jsonb)) > 0,
    'title', public.uic('catalogue.top_selling_title','Top selling'),
    'note',  v_note,
    'items', coalesce(v_cards, '[]'::jsonb));
end $fn$;

revoke all on function public.catalogue_top_selling(boolean) from public;
grant execute on function public.catalogue_top_selling(boolean)
  to anon, authenticated, service_role;

-- ── 6. the landing payload ────────────────────────────────────────────────
create or replace function public.catalogue_home(p_zone boolean default true)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  with z as (select public._cat_count_zone(p_zone) as cz),
       cfg as (select public._cat_landing_cfg() as c),
       schemes as (
         select coalesce((select n::bigint from public.catalogue_facet_count
                           where facet='tab' and zone_id=(select cz from z)
                             and facet_key='schemes'), 0::bigint) as n),
       cold as (
         select coalesce((select n::bigint from public.catalogue_facet_count
                           where facet='tab' and zone_id=(select cz from z)
                             and facet_key='cold_chain'), 0::bigint) as n)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.title','Catalogue'),
    'subtitle', public.uic('catalogue.subtitle','Browse the whole product list by class, company or salt.'),
    'zone', public.catalogue_zone_switch(p_zone),
    'total', public._cat_meta((select cz from z), 'total'),
    'refreshed_at', (select refreshed_at from public.catalogue_facet_count
                      where facet='meta' and zone_id=(select cz from z) and facet_key='total'),
    'stale_label', public.uic('catalogue.counts_note','Counts refresh automatically.'),
    'search_hint', public.uic('catalogue.search_hint','Search a salt or a company'),
    'search', jsonb_build_object(
      'placeholder', public.uic('catalogue.search_placeholder','Search a medicine, salt or company'),
      'hint',        public.uic('catalogue.search_hint','Search a salt or a company'),
      'clear_label', public.uic('catalogue.search_clear','Clear')),
    -- CMD #2020 — the landing has NO breadcrumb. A one-crumb trail reading
    -- "Catalogue" on the page called Catalogue is a row of chrome that says
    -- nothing; the trail appears the moment a tile is tapped and goes again on
    -- the way back. `items` empty is the backend's answer, not a Dart guard.
    'trail', jsonb_build_object(
      'label', public.uic('catalogue.trail_label','You are here'),
      'separator', public.uic('catalogue.trail_separator','›'),
      'items', '[]'::jsonb),
    'landing', (select c from cfg),
    'doors_title', public.uic('catalogue.doors_title','Browse by'),
    -- The four tiles. Each carries its own gradient and its own preview, so
    -- the tile is a rendered payload end to end.
    'doors', jsonb_build_array(
      jsonb_build_object(
        'key','companies', 'kind','companies', 'tab','companies',
        'label', public.uic('catalogue.door_company','Company'),
        'icon_key','store', 'icon_letter','C',
        'gradient', (select c->'tiles'->'companies' from cfg),
        'preview', public._cat_tile_preview('company', (select cz from z), 'logos', 4),
        'count_label', to_char(public._cat_meta((select cz from z), 'companies'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.companies_word','companies')),
      jsonb_build_object(
        'key','salts', 'kind','salts', 'tab','salts',
        'label', public.uic('catalogue.door_salt','Salt'),
        'icon_key','science', 'icon_letter','S',
        'gradient', (select c->'tiles'->'salts' from cfg),
        'preview', public._cat_tile_preview('salt', (select cz from z), 'names', 2),
        'count_label', to_char(public._cat_meta((select cz from z), 'salts'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.salts_word','salts')),
      jsonb_build_object(
        'key','conditions', 'kind','conditions', 'tab','conditions',
        'label', public.uic('catalogue.door_condition','Use'),
        'icon_key','medication', 'icon_letter','U',
        'gradient', (select c->'tiles'->'conditions' from cfg),
        'preview', public._cat_tile_preview('condition', (select cz from z), 'names', 2),
        'count_label', public.cat_count_label(
          public._cat_meta((select cz from z), 'condition_products'))),
      jsonb_build_object(
        'key','browse', 'kind','tree', 'tab','browse',
        'label', public.uic('catalogue.door_category','Category'),
        'icon_key','book', 'icon_letter','K',
        'gradient', (select c->'tiles'->'browse' from cfg),
        'preview', public._cat_tile_preview('therapeutic', (select cz from z), 'chips', 3),
        'count_label', public.cat_count_label(
          coalesce((select sum(n)::bigint from public.catalogue_facet_count
                     where facet='therapeutic' and zone_id=(select cz from z)), 0::bigint)))),
    -- CMD #2020 — the rail under the tiles. Same storefront card as everywhere
    -- else; only the ranking is new, and it is the backend's.
    'top_selling', public.catalogue_top_selling(p_zone),
    -- CMD #2020 — Schemes was a chip among chips. It is the one promotional
    -- thing this page has, so it is a full-width banner — and it is absent,
    -- not empty, when the zone is running no scheme at all.
    'promo', jsonb_build_object(
      'has', (select n from schemes) > 0,
      'key','schemes', 'list_kind','tab', 'list_key','schemes',
      'title',    public.uic('catalogue.schemes_promo_title','Schemes & offers'),
      'subtitle', public.uic('catalogue.schemes_promo_subtitle','Extra units on selected packs'),
      'count_label', public.cat_count_label((select n from schemes)),
      'action_label', public.uic('catalogue.schemes_promo_action','View all'),
      'gradient', (select c->'promo' from cfg)),
    -- The chip row under the banner. Cold chain stays a chip; Schemes does not
    -- appear twice.
    'chips', case when (select n from cold) > 0 then jsonb_build_array(
        jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
          'kind','list', 'list_kind','tab', 'list_key','cold_chain',
          'count_label', public.cat_count_label((select n from cold)),
          'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.')))
      else '[]'::jsonb end,
    'recent_viewed', (
      select jsonb_build_object(
        'has',   coalesce((r->>'has')::boolean, false),
        'title', case when coalesce(nullif(r->>'title',''), '') = ''
                      then public.uic('catalogue.recent_viewed_title','Recently viewed')
                      else r->>'title' end,
        'items', coalesce(r->'items','[]'::jsonb))
        from (select public.recently_viewed_rail(12) as r) t),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','browse','label', public.uic('catalogue.tab_browse','Browse'),
        'kind','tree',
        'count_label', public.cat_count_label(
          coalesce((select sum(n)::bigint from public.catalogue_facet_count
                     where facet='therapeutic' and zone_id=(select cz from z)), 0::bigint))),
      jsonb_build_object('key','companies','label', public.uic('catalogue.tab_companies','Companies'),
        'kind','companies',
        'count_label', to_char(public._cat_meta((select cz from z), 'companies'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.companies_word','companies')),
      jsonb_build_object('key','salts','label', public.uic('catalogue.tab_salts','Salts'),
        'kind','salts',
        'count_label', to_char(public._cat_meta((select cz from z), 'salts'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.salts_word','salts')),
      jsonb_build_object('key','conditions','label', public.uic('catalogue.tab_conditions','Uses'),
        'kind','conditions',
        'count_label', to_char(public._cat_meta((select cz from z), 'conditions'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.conditions_word','uses')),
      jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
        'kind','list', 'list_kind','tab', 'list_key','cold_chain',
        'count_label', public.cat_count_label((select n from cold)),
        'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.'))),
    'filters', public.catalogue_filter_defs('{}'::jsonb, (select cz from z)));
$fn$;

revoke all on function public.catalogue_home(boolean) from public;
grant execute on function public.catalogue_home(boolean)
  to anon, authenticated, service_role;

-- ── 7. the A–Z strip a PRODUCT list gets ──────────────────────────────────
-- Companies, salts and classes have had a strip since #1908; the list of
-- products behind one of them had none, so "Sun Pharma, 2,461 products" was a
-- wall with no way into it. The track is every letter, always — `enabled` says
-- whether anything sits behind it, and a scope too large to ask that of
-- offers them all rather than paying for a full scan on a phone's first read
-- (the cold-read budget lesson, #320).
create or replace function public._cat_products_rail(
  p_where text, p_zone smallint, p_total bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_max  bigint := coalesce((public._cat_landing_cfg()->>'rail_scan_max')::bigint, 50000);
  v_have text[] := '{}'::text[];
  v_scan boolean := (p_total is not null and p_total <= v_max);
  v_sql  text;
  v_join text := '';
begin
  if v_scan then
    if p_zone is not null then
      v_join := format('join public.catalogue_zone_avail za '
                       || 'on za.product_id = m.id and za.zone_id = %L::smallint', p_zone);
    end if;
    v_sql := format(
      'select coalesce(array_agg(distinct l), ''{}''::text[]) from ('
      || 'select case when left(public._norm_name(m.product_name),1) between ''a'' and ''z'' '
      || '            then upper(left(public._norm_name(m.product_name),1)) else ''#'' end as l '
      || 'from public."MEDICINE" m %s where %s) s', v_join, p_where);
    execute v_sql into v_have;
  end if;

  return jsonb_build_object(
    'label', public.uic('catalogue.rail_products_label','Jump to a letter'),
    'all_label', public.uic('catalogue.letter_all','All'),
    'letters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', t.key,
               'label', case when t.key = '#'
                             then public.uic('catalogue.rail_other','#') else t.key end,
               'enabled', (not v_scan) or t.key = any(v_have))
             order by (t.key = '#'), t.key)
        from (select chr(64 + generate_series(1,26)) as key
              union all select '#') t), '[]'::jsonb));
end $fn$;

-- ── 8. the product list ───────────────────────────────────────────────────
-- Dropped and recreated rather than replaced: the letter is a NEW argument,
-- and a defaulted argument added beside the old signature would leave two
-- overloads for PostgREST to choose between (the trap #1928's lesson names).
drop function if exists public.catalogue_list(text, text, text[], jsonb, text, boolean, text, integer);

create or replace function public.catalogue_list(
  p_kind text default 'tree',
  p_key text default null,
  p_path text[] default '{}'::text[],
  p_filters jsonb default '{}'::jsonb,
  p_sort text default 'name',
  p_zone boolean default true,
  p_cursor text default null,
  p_limit integer default 24,
  p_letter text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_azone smallint := public._cat_avail_zone();
  v_cz    smallint := public._cat_count_zone(p_zone);   -- 0 — all zones
  v_n     int      := least(greatest(coalesce(p_limit,24),1),50);
  v_sort  text     := case when coalesce(p_sort,'name') = 'newest' then 'newest' else 'name' end;
  v_scope text     := public._cat_where(p_kind, p_key, p_path, coalesce(p_filters,'{}'::jsonb));
  -- CMD #2020 — the letter, applied as a prefix RANGE on the normalised name
  -- so idx_medicine_name_norm_prefix still carries the read. '#' is
  -- everything that sorts before 'a' — a digit, a bracket, a symbol.
  v_letter text    := nullif(upper(btrim(coalesce(p_letter,''))),'');
  v_where text;
  v_cur   jsonb;
  v_cg    smallint;
  v_ids   bigint[] := '{}'::bigint[];
  v_grps  smallint[] := '{}'::smallint[];
  v_part  bigint[];
  v_got   int;
  v_last_id bigint; v_last_name text; v_last_g smallint;
  v_filtered boolean := coalesce(public._cat_filtered(coalesce(p_filters,'{}'::jsonb)), false);
  v_head text;
  v_empty text;
  v_typed boolean := (p_kind = 'search' and coalesce(btrim(coalesce(p_key,'')),'') <> '');
  v_request boolean := false;
  v_empty_hint text := '';
  v_zsw jsonb := public.catalogue_zone_switch(p_zone);
  v_narrow boolean := (p_kind = 'search');
  v_filters jsonb;
  v_total bigint; v_total_in bigint; v_total_out bigint;
  v_lbl_in text; v_lbl_out text;
  v_more boolean;
begin
  if v_letter is not null and v_letter <> '#' and v_letter !~ '^[A-Z]$' then
    v_letter := null;
  end if;
  v_where := v_scope || case
    when v_letter is null then ''
    when v_letter = '#' then
      ' and public._norm_name(m.product_name) operator(pg_catalog.~<~) ''a'''
    else format(
      ' and public._norm_name(m.product_name) operator(pg_catalog.~>=~) %L'
      || ' and public._norm_name(m.product_name) operator(pg_catalog.~<~) %L',
      lower(v_letter), chr(ascii(lower(v_letter)) + 1)) end;

  begin v_cur := nullif(btrim(coalesce(p_cursor,'')),'')::jsonb; exception when others then v_cur := null; end;
  v_cg := case when v_cur is null then null
               when v_cur ? 'g'  then (v_cur->>'g')::smallint
               else 0::smallint end;
  if v_azone is null then v_cg := null; end if;

  if v_azone is null then
    v_part := public._cat_page_ids(v_where, v_sort, v_cur, null::smallint, null::smallint, v_n);
    v_ids  := v_part;
    v_grps := array_fill(0::smallint, array[coalesce(array_length(v_ids,1),0)]);
  else
    if v_cg is null or v_cg = 0 then
      v_part := public._cat_page_ids(v_where, v_sort, case when v_cg = 0 then v_cur end,
                                     v_azone, 0::smallint, v_n);
      v_ids  := v_part;
      v_grps := array_fill(0::smallint, array[coalesce(array_length(v_part,1),0)]);
      v_got  := coalesce(array_length(v_part,1),0);
      if v_got < v_n then
        v_part := public._cat_page_ids(v_where, v_sort, null::jsonb, v_azone, 1::smallint, v_n - v_got);
        v_ids  := v_ids || v_part;
        v_grps := v_grps || array_fill(1::smallint, array[coalesce(array_length(v_part,1),0)]);
      end if;
    else
      v_part := public._cat_page_ids(v_where, v_sort, v_cur, v_azone, 1::smallint, v_n);
      v_ids  := v_part;
      v_grps := array_fill(1::smallint, array[coalesce(array_length(v_part,1),0)]);
    end if;
  end if;
  v_ids  := coalesce(v_ids, '{}'::bigint[]);
  v_grps := coalesce(v_grps, '{}'::smallint[]);
  v_got  := coalesce(array_length(v_ids,1),0);

  if v_got > 0 then
    select id, coalesce(product_name,'') into v_last_id, v_last_name
      from public."MEDICINE" where id = v_ids[v_got];
    v_last_g := v_grps[v_got];
  end if;

  -- A letter narrows the scope, so the precomputed scope totals stop being the
  -- truth about what is on screen: they go NULL together, exactly as they do
  -- under a filter, and the labels print without numbers rather than printing
  -- a number that is wrong.
  v_total     := case when v_filtered or v_letter is not null then null
                      else public._cat_scope_total(p_kind, p_key, p_path, 0::smallint) end;
  v_total_in  := case when v_filtered or v_letter is not null or v_azone is null then null
                      else public._cat_scope_total(p_kind, p_key, p_path, v_azone) end;
  v_total_out := case when v_total is null or v_total_in is null then null
                      else greatest(v_total - v_total_in, 0) end;
  v_lbl_in    := public.cat_group_label('in',  v_total_in);
  v_lbl_out   := public.cat_group_label('out', v_total_out);

  v_head := case
    when p_kind = 'company' then coalesce((select label from public.catalogue_facet_count
        where facet='company' and zone_id=v_cz and facet_key = coalesce(p_key,'')), coalesce(p_key,''))
    when p_kind = 'salt'    then coalesce(p_key,'')
    when p_kind = 'condition' then coalesce(
        (select label from public.catalogue_facet_count
          where facet='condition' and zone_id=v_cz and facet_key = coalesce(p_key,'')),
        (select label from public.use_bucket where condition_key = coalesce(p_key,'')),
        coalesce(p_key,''))
    when p_kind = 'search'  then coalesce(nullif(btrim(coalesce(p_key,'')),''),
                                          public.uic('catalogue.all_products','All products'))
    when p_kind = 'tab' and p_key = 'schemes'    then public.uic('catalogue.tab_schemes','Schemes')
    when p_kind = 'tab' and p_key = 'cold_chain' then public.uic('catalogue.tab_cold','Cold chain')
    when p_kind = 'tree' and coalesce(array_length(p_path,1),0) > 0
      then p_path[array_length(p_path,1)]
    else public.uic('catalogue.all_products','All products') end;

  v_empty := case
    when v_filtered then replace(public.uic('catalogue.list_empty_filtered_scope',
                         'Nothing in {scope} matches these filters.'), '{scope}', v_head)
    when v_typed    then replace(public.uic('catalogue.list_empty_search',
                         'No product matches “{q}”.'), '{q}', btrim(p_key))
    else replace(public.uic('catalogue.list_empty_scope',
                   'Nothing in {scope} right now.'), '{scope}', v_head) end;
  v_request := v_typed
    and coalesce((select request_open from public.catalogue_extras_config where id = 1), true);
  v_empty_hint := case when v_typed and not v_filtered
    then public.uic('catalogue.list_empty_search_hint',
                    'Check the spelling, or try a shorter word.') else '' end;

  v_filters := public.catalogue_filter_defs(coalesce(p_filters,'{}'::jsonb), v_cz);
  if not v_narrow then
    v_filters := jsonb_set(v_filters, '{groups}', '[]'::jsonb);
    -- CMD #2020 — "Name A–Z" and "Newest added" go with them. Two chips that
    -- reordered a list nobody had asked to be ordered differently, sitting
    -- where the A–Z strip belongs. The strip below is the one way of moving
    -- through a long list now, and it does not reorder anything.
    v_filters := jsonb_set(v_filters, '{sort}',
                   jsonb_build_object('label','', 'options','[]'::jsonb));
  end if;

  v_more := (v_got = v_n);

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind, 'key', p_key, 'path', to_jsonb(p_path),
    'title', v_head,
    'subtitle', case
      when p_kind = 'salt' then public.uic('catalogue.salt_subtitle','Every brand for this salt')
      when p_kind = 'condition' then public.uic('catalogue.condition_subtitle','Products used for this condition')
      when p_kind = 'company' then public.uic('catalogue.company_subtitle','Products from this company')
      when p_kind = 'search' then public.uic('catalogue.search_subtitle','Matches in the catalogue')
      else '' end,
    'trail', public.catalogue_trail(
               case when p_kind = 'company' then 'companies'
                    when p_kind = 'salt' then 'salts'
                    when p_kind = 'condition' then 'conditions'
                    else 'browse' end,
               p_path, p_kind, p_key, v_head),
    -- CMD #2020 — the A–Z strip, on the product list itself. A search has none:
    -- its narrowing is the word that was typed.
    'rail', case when v_narrow then '{}'::jsonb
                 else public._cat_products_rail(v_scope, v_azone,
                        public._cat_scope_total(p_kind, p_key, p_path,
                          coalesce(v_azone, 0::smallint))) end,
    'letter', coalesce(v_letter, ''),
    'zone', v_zsw,
    'grouped', v_azone is not null,
    'groups', case when v_azone is null then '[]'::jsonb else jsonb_build_array(
        jsonb_build_object('key','in',  'label', v_lbl_in,  'count', v_total_in),
        jsonb_build_object('key','out', 'label', v_lbl_out, 'count', v_total_out)) end,
    'sort', v_sort,
    'filters', v_filters,
    'filters_active', v_filtered,
    'filters_active_label', case when v_filtered
      then public.uic('catalogue.filters_on','Filters on') else '' end,
    'total', v_total,
    'count_label', case when v_total is null
      then to_char(v_got,'FM9,99,99,999') || ' ' || public.uic('catalogue.showing_word','shown')
      else public.cat_count_label(v_total) end,
    'empty_label', v_empty,
    'empty', jsonb_build_object(
      'label', v_empty,
      'hint', v_empty_hint,
      'action', jsonb_build_object(
        'has',  v_request,
        'kind', 'request',
        'label', public.uic('catalogue.empty_action','Request this product')),
      'clear', jsonb_build_object(
        'has', v_filtered,
        'kind','clear_filters',
        'label', public.uic('catalogue.filters_clear','Clear all')),
      'buttons', (
        case when v_filtered then jsonb_build_array(jsonb_build_object(
               'kind','clear_filters', 'tone','primary',
               'label', public.uic('catalogue.filters_clear','Clear all')))
             else '[]'::jsonb end
        ||
        case when v_request then jsonb_build_array(jsonb_build_object(
               'kind','request',
               'tone', case when v_filtered then 'secondary' else 'primary' end,
               'label', public.uic('catalogue.empty_action','Request this product')))
             else '[]'::jsonb end)),
    'limit', v_n,
    'has_more', v_more,
    'more_label', public.uic('catalogue.load_more','Load more'),
    'end_label', public.uic('catalogue.list_end','That is the whole list.'),
    'next_cursor', case when v_more and v_last_id is not null then
      (case when v_sort = 'newest'
            then jsonb_build_object('g', coalesce(v_last_g,0), 'i', v_last_id)
            else jsonb_build_object('g', coalesce(v_last_g,0), 'i', v_last_id, 'n', v_last_name) end)::text
      end,
    'items', public._cat_group_cards(v_ids, v_grps, v_azone, v_cg, v_lbl_in, v_lbl_out));
end $function$;

revoke all on function public.catalogue_list(text,text,text[],jsonb,text,boolean,text,integer,text) from public;
grant execute on function public.catalogue_list(text,text,text[],jsonb,text,boolean,text,integer,text)
  to anon, authenticated, service_role;

revoke all on function public._cat_tile_preview(text,smallint,text,int) from public;
grant execute on function public._cat_tile_preview(text,smallint,text,int)
  to anon, authenticated, service_role;
revoke all on function public._cat_products_rail(text,smallint,bigint) from public;
grant execute on function public._cat_products_rail(text,smallint,bigint)
  to anon, authenticated, service_role;
revoke all on function public._cat_landing_cfg() from public;
grant execute on function public._cat_landing_cfg()
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';

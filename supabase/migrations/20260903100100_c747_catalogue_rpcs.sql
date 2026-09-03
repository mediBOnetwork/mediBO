-- CHANGE #747 · step 2 — the Catalogue section, served entirely from the backend.
--
-- Five RPCs and one card builder. Every string the screen prints — tab names,
-- breadcrumbs, counts, filter chips, sort names, the zone switch's own wording,
-- every empty state — is composed here and rendered verbatim. The Flutter side
-- of this command asks and paints; it decides nothing.
--
-- The shape follows the storefront's, deliberately: `_cat_cards` returns the
-- SAME card `_sf_cards` returns, so `Product.fromHomeCard` reads a catalogue
-- row and a home rail row with one parser and the two surfaces can never
-- disagree about a product's price or availability.

-- A widened function with a defaulted parameter is an OVERLOAD, not a
-- replacement, and both arities then match every existing call ("function is
-- not unique" at CALL time, minutes after a green migration). So the old
-- signature goes first, every time.
drop function if exists public.catalogue_filter_defs(jsonb);

-- ── the catalogue's card ────────────────────────────────────────────────────
-- _sf_cards() drops anything not buyable, which is right for a home rail (a
-- rail of unavailable products is a rail of dead ends) and wrong for a
-- catalogue: browsing a therapeutic class must show the class, not the fraction
-- of it a supplier happens to stock today. So this is _sf_cards with the
-- buyable filter removed and nothing else changed — an out-of-stock row still
-- arrives with storefront_cta()'s own can_add:false verdict and prints it.
create or replace function public._cat_cards(p_ids bigint[])
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
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
    'rx', public.rx_badge(m.rx_required),
    'availability', public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
        true, m.status),
    'pricing', public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id),
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid;
$$;

-- ── the zone switch ─────────────────────────────────────────────────────────
-- #678's rule, stated once: an APPROVED customer with a zone sees zone truth;
-- everyone else sees the whole catalogue. `has:false` means the switch is not
-- drawn at all — an anonymous visitor is never shown a control that would not
-- change anything, and the app never decides that for itself.
create or replace function public.catalogue_zone_switch(p_on boolean default true)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  -- Resolved with the switch FORCED ON, so turning it off does not make the
  -- control disappear — `has` is "does this viewer get a switch", `on` is
  -- "is it flipped". Collapsing the two would erase the control the moment
  -- somebody used it.
  with z as (select public._cat_zone(true) as zid)
  select case when (select zid from z) is null then
    jsonb_build_object('has', false, 'on', false, 'zone_id', null,
      'label', public.uic('catalogue.zone_switch','Available in my zone'),
      'note',  public.uic('catalogue.zone_anon_note','Showing the whole catalogue.'))
  else
    jsonb_build_object('has', true, 'on', coalesce(p_on, true),
      'zone_id', (select zid from z),
      'label', public.uic('catalogue.zone_switch','Available in my zone'),
      'zone_label', (select name from public.zones where id = (select zid from z)),
      'note', case when coalesce(p_on, true)
                   then public.uic('catalogue.zone_on_note','Showing what suppliers in your zone can send.')
                   else public.uic('catalogue.zone_off_note','Showing the whole catalogue, including items no supplier near you stocks.') end)
  end;
$$;

-- The zone actually applied to a query: the viewer's zone when the switch is
-- on, and NULL — meaning no zone filter at all — otherwise. One place, so the
-- switch, the counts and the list can never disagree.
--
-- The extra condition is not defensive padding, it is a real case: the count
-- refresh only walks zones that are ACTIVE and not synthetic, so a customer
-- attached to any other zone (the synthetic test pharmacy is zone 99, and a
-- newly-created zone is in that state until its first refresh finishes) would
-- be filtered against a cache with nothing in it and shown an EMPTY catalogue.
-- Caught by the documented test.cust1 credential, which is exactly such a
-- customer. A zone the cache cannot speak for gets no zone filter and no
-- switch — the whole catalogue, honestly, rather than a confident nothing.
create or replace function public._cat_zone(p_on boolean default true)
returns smallint
language sql stable security definer
set search_path to 'public'
as $$
  select z.zid from (select public._viewer_zone_or_null() as zid) z
   where coalesce(p_on, true)
     and z.zid is not null
     and exists (select 1 from public.catalogue_facet_count c
                  where c.zone_id = z.zid and c.facet = 'meta');
$$;

-- Counts are read at the zone the switch resolved to; 0 is the whole catalogue.
create or replace function public._cat_count_zone(p_on boolean default true)
returns smallint
language sql stable security definer
set search_path to 'public'
as $$ select coalesce(public._cat_zone(p_on), 0::smallint) $$;

-- ── how a number is printed ─────────────────────────────────────────────────
-- Indian digit grouping, and the plural, decided here. Dart never pluralises.
create or replace function public.cat_count_label(p_n bigint)
returns text
language sql immutable parallel safe
as $$
  select to_char(coalesce(p_n,0), 'FM9,99,99,999')
      || case when coalesce(p_n,0) = 1 then ' product' else ' products' end;
$$;

-- One cached headline number: the tab bar's counts, read as a point lookup.
create or replace function public._cat_meta(p_zone smallint, p_key text)
returns bigint
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce((select n from public.catalogue_facet_count
                    where facet='meta' and zone_id = coalesce(p_zone,0::smallint)
                      and facet_key = p_key), 0::bigint);
$$;

-- ── the filter and sort vocabulary ──────────────────────────────────────────
-- The chips a list may offer, with their labels and their current state. The
-- app renders this array; it holds no list of its own.
-- p_zone_count is the COUNT zone (0 = the whole catalogue), so the pack types on
-- offer are the ones that actually exist in the view being filtered.
create or replace function public.catalogue_filter_defs(
  p_filters jsonb default '{}'::jsonb, p_zone_count smallint default 0)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'title', public.uic('catalogue.filters_title','Filters'),
    'clear_label', public.uic('catalogue.filters_clear','Clear all'),
    'apply_label', public.uic('catalogue.filters_apply','Show results'),
    'groups', jsonb_build_array(
      jsonb_build_object('key','pack_type','label', public.uic('catalogue.f_pack_type','Pack type'),
        'mode','multi',
        'options', coalesce((select jsonb_agg(jsonb_build_object(
                        'key', c.facet_key, 'label', c.label, 'n', c.n,
                        'selected', coalesce(p_filters->'pack_type','[]'::jsonb) ? c.facet_key)
                        order by c.n desc, c.label)
                     from public.catalogue_facet_count c
                      where c.facet = 'pack_type'
                        and c.zone_id = coalesce(p_zone_count, 0::smallint)), '[]'::jsonb)),
      jsonb_build_object('key','rx','label', public.uic('catalogue.f_rx','Prescription'),
        'mode','single',
        'options', jsonb_build_array(
          jsonb_build_object('key','Rx','label', public.uic('catalogue.f_rx_only','Rx only'),
            'selected', (p_filters->>'rx') = 'Rx'),
          jsonb_build_object('key','OTC','label', public.uic('catalogue.f_otc_only','OTC only'),
            'selected', (p_filters->>'rx') = 'OTC'))),
      jsonb_build_object('key','flags','label', public.uic('catalogue.f_flags','Product'),
        'mode','multi',
        'options', jsonb_build_array(
          jsonb_build_object('key','habit_forming','label', public.uic('catalogue.f_habit','Habit forming'),
            'selected', (p_filters->>'habit_forming') = 'true'),
          jsonb_build_object('key','cold_chain','label', public.uic('catalogue.f_cold','Cold chain'),
            'selected', (p_filters->>'cold_chain') = 'true'),
          jsonb_build_object('key','has_image','label', public.uic('catalogue.f_image','Has photo'),
            'selected', (p_filters->>'has_image') = 'true'),
          jsonb_build_object('key','has_scheme','label', public.uic('catalogue.f_scheme','Has scheme'),
            'selected', (p_filters->>'has_scheme') = 'true')))),
    'sort', jsonb_build_object('label', public.uic('catalogue.sort_title','Sort'),
      'options', jsonb_build_array(
        jsonb_build_object('key','name','label', public.uic('catalogue.sort_name','Name A–Z')),
        jsonb_build_object('key','newest','label', public.uic('catalogue.sort_newest','Newest added')))));
$$;

-- ── the WHERE clause a scope and a filter set make ──────────────────────────
-- Built once, used by the list and by nothing else. Every literal goes through
-- format(%L), so a company key or a salt string carrying a quote is data.
create or replace function public._cat_where(
  p_kind text, p_key text, p_path text[], p_filters jsonb)
returns text
language plpgsql immutable
as $$
declare w text := 'public.catalogue_universe_ok(m.status)'; v text;
begin
  if p_kind = 'tree' then
    if coalesce(array_length(p_path,1),0) >= 1 then
      w := w || format(' and m.therapeutic_class = %L', p_path[1]); end if;
    if coalesce(array_length(p_path,1),0) >= 2 then
      w := w || format(' and m.chemical_class = %L', p_path[2]); end if;
    if coalesce(array_length(p_path,1),0) >= 3 then
      w := w || format(' and m.action_class = %L', p_path[3]); end if;
  elsif p_kind = 'company' then
    w := w || format(' and m.marketer_canonical = %L', coalesce(p_key,''));
  elsif p_kind = 'salt' then
    w := w || format(' and m.salt_composition = %L', coalesce(p_key,''));
  elsif p_kind = 'tab' then
    -- Written as the bare boolean, not coalesce(...,false): the partial
    -- indexes below are declared `where has_scheme` / `where cold_chain`, and a
    -- coalesce wrapper stops the planner matching them (4.2 s vs 3 ms).
    if p_key = 'schemes'    then w := w || ' and m.has_scheme';
    elsif p_key = 'cold_chain' then w := w || ' and m.cold_chain';
    end if;
  end if;

  if coalesce(jsonb_array_length(p_filters->'pack_type'),0) > 0 then
    select string_agg(format('%L', x), ',') into v
      from jsonb_array_elements_text(p_filters->'pack_type') x;
    w := w || format(' and m.pack_type in (%s)', v);
  end if;
  if (p_filters->>'rx') in ('Rx','OTC') then
    w := w || format(' and upper(btrim(coalesce(m.rx_required,''''))) = %L', upper(p_filters->>'rx'));
  end if;
  if (p_filters->>'habit_forming') = 'true' then
    w := w || ' and upper(btrim(coalesce(m.habit_forming,''''))) = ''YES''';
  end if;
  if (p_filters->>'cold_chain') = 'true' then w := w || ' and m.cold_chain'; end if;
  -- has_image reads image_url_1, not the has_image boolean: the boolean is true
  -- on 4,095 rows while 252,760 actually carry a photo, and this filter has to
  -- agree with the picture the grid draws.
  if (p_filters->>'has_image') = 'true' then
    w := w || ' and m.image_url_1 is not null and btrim(m.image_url_1) <> ''''';
  end if;
  if (p_filters->>'has_scheme') = 'true' then w := w || ' and m.has_scheme'; end if;
  return w;
end $$;

-- True when the caller narrowed the list beyond its scope. A filtered list has
-- no cached total, so it prints a "showing N" line instead of a false count.
create or replace function public._cat_filtered(p_filters jsonb)
returns boolean
language sql immutable
as $$
  select coalesce(jsonb_array_length(p_filters->'pack_type'),0) > 0
      or (p_filters->>'rx') in ('Rx','OTC')
      or (p_filters->>'habit_forming') = 'true'
      or (p_filters->>'cold_chain') = 'true'
      or (p_filters->>'has_image') = 'true'
      or (p_filters->>'has_scheme') = 'true';
$$;

-- The cached total for a scope, or NULL when this scope has no cached node.
--
-- The whole point is that it is a PRIMARY KEY lookup. The first draft put the
-- scope CASE inside the WHERE clause, which is unindexable — it scanned all
-- 254,000 cache rows and made a cold-chain page take 2.4 s while the product
-- query underneath it took 27 ms. So the three key parts are resolved FIRST,
-- and only then is the table touched.
create or replace function public._cat_scope_total(
  p_kind text, p_key text, p_path text[], p_zone smallint)
returns bigint
language sql stable security definer
set search_path to 'public'
as $$
  with k as (
    select case p_kind
             when 'company' then 'company' when 'salt' then 'salt' when 'tab' then 'tab'
             when 'tree' then case coalesce(array_length(p_path,1),0)
                                when 1 then 'therapeutic' when 2 then 'chemical'
                                when 3 then 'action' end
           end as facet,
           case when p_kind = 'tree' then
                  case coalesce(array_length(p_path,1),0)
                    when 2 then p_path[1]
                    when 3 then public.catalogue_parent_key(p_path[1], p_path[2])
                    else '' end
                else '' end as parent,
           case p_kind
             when 'tree' then p_path[greatest(coalesce(array_length(p_path,1),0),1)]
             else coalesce(p_key,'') end as fkey
  )
  select c.n from public.catalogue_facet_count c, k
   where k.facet is not null
     and c.facet = k.facet and c.zone_id = p_zone
     and c.parent_key = k.parent and c.facet_key = k.fkey;
$$;

-- ── RPC 1 — the Catalogue tab itself ────────────────────────────────────────
-- One call answers everything the screen needs before a single row is drawn:
-- which tabs exist, what each is called, how big each is, whether this viewer
-- gets a zone switch and what the filter vocabulary is. Adding a tab is a row
-- here, not a deploy.
create or replace function public.catalogue_home(p_zone boolean default true)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz)
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
    'tabs', jsonb_build_array(
      -- The Browse tab counts what the TREE will show, not what the catalogue
      -- holds: 2.2 lakh rows carry no therapeutic class at all, so the whole-
      -- catalogue total on the tab and the tree's own header underneath it were
      -- two different numbers a foot apart on the same screen.
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
      jsonb_build_object('key','schemes','label', public.uic('catalogue.tab_schemes','Schemes'),
        'kind','list', 'list_kind','tab', 'list_key','schemes',
        'count_label', public.cat_count_label(coalesce((select n::bigint from public.catalogue_facet_count
                     where facet='tab' and zone_id=(select cz from z) and facet_key='schemes'),0)),
        'empty_label', public.uic('catalogue.schemes_empty','No product is running a scheme right now.')),
      jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
        'kind','list', 'list_kind','tab', 'list_key','cold_chain',
        'count_label', public.cat_count_label(coalesce((select n::bigint from public.catalogue_facet_count
                     where facet='tab' and zone_id=(select cz from z) and facet_key='cold_chain'),0)),
        'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.'))),
    'filters', public.catalogue_filter_defs('{}'::jsonb, (select cz from z)));
$$;

-- ── RPC 2 — the browse tree ─────────────────────────────────────────────────
-- One function for all three levels. p_path is the trail: {} lists therapeutic
-- classes, {tc} lists that class's chemical classes, {tc,cc} lists action
-- classes. The trail's LAST level also tells the app whether the next tap
-- should open products instead of another level.
create or replace function public.catalogue_tree(
  p_path text[] default '{}'::text[], p_zone boolean default true)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lvl as (select coalesce(array_length(p_path,1),0) as d),
  node as (
    select case (select d from lvl)
             when 0 then 'therapeutic' when 1 then 'chemical' else 'action' end as facet,
           case (select d from lvl)
             when 0 then '' when 1 then p_path[1]
             else public.catalogue_parent_key(p_path[1], p_path[2]) end as parent
  ),
  rows as (
    select c.facet_key, c.label, c.n
      from public.catalogue_facet_count c
     where c.zone_id = (select cz from z)
       and c.facet   = (select facet from node)
       and c.parent_key = (select parent from node)
     order by c.n desc, c.label
  )
  select jsonb_build_object(
    'ok', true,
    'title', case (select d from lvl)
               when 0 then public.uic('catalogue.tree_l0','Therapeutic class')
               when 1 then public.uic('catalogue.tree_l1','Chemical class')
               else        public.uic('catalogue.tree_l2','Action class') end,
    'level', (select d from lvl),
    'path', to_jsonb(p_path),
    'zone', public.catalogue_zone_switch(p_zone),
    -- The crumb trail, already worded. The app prints it; it never joins names.
    'crumbs', (select coalesce(jsonb_agg(jsonb_build_object(
                 'label', p, 'depth', o) order by o), '[]'::jsonb)
                 from unnest(p_path) with ordinality t(p, o)),
    'home_label', public.uic('catalogue.tree_home','All classes'),
    -- The next tap: another level, or the products themselves.
    'child_opens', case when (select d from lvl) >= 2 then 'products' else 'level' end,
    'products_label', public.uic('catalogue.tree_products','View products'),
    -- A leaf level with no children of its own still has products behind it.
    'has_products', (select d from lvl) >= 1,
    'empty_label', case when (select d from lvl) = 0
                        then public.uic('catalogue.tree_empty_root','The catalogue has no classes in this view.')
                        else public.uic('catalogue.tree_empty','Nothing below this class in this view — open the products instead.') end,
    'count_label', public.cat_count_label(coalesce((select sum(n)::bigint from rows),0::bigint)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', r.facet_key, 'label', r.label,
              'n', r.n, 'count_label', public.cat_count_label(r.n::bigint))
              order by r.n desc, r.label) from rows r), '[]'::jsonb));
$$;

-- ── RPC 3 — companies A–Z ───────────────────────────────────────────────────
-- 18,578 companies, so it is a letter index plus a paged list, never one blob.
-- The letters come from the same cache the rows do, which is why a letter can
-- never be offered with nothing behind it.
create or replace function public.catalogue_companies(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  hit as (
    select c.facet_key, c.label, c.letter, c.n
      from public.catalogue_facet_count c
     where c.facet = 'company' and c.zone_id = (select cz from z)
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
  ),
  page as (select * from hit order by label
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select * from page order by label limit (select n from lim))
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.companies_title','Companies'),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'search_hint', public.uic('catalogue.company_search_hint','Search a company'),
    'all_label', public.uic('catalogue.letter_all','All'),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('key', l.letter, 'label', l.letter, 'n', l.n)
                                order by l.letter)
                  from (select letter, count(*) as n from public.catalogue_facet_count
                         where facet='company' and zone_id=(select cz from z)
                         group by letter) l), '[]'::jsonb),
    'count_label', to_char(case when nullif(btrim(coalesce(p_q,'')),'') is null
                                 and nullif(btrim(coalesce(p_letter,'')),'') is null
                                then public._cat_meta((select cz from z), 'companies')
                                else (select count(*) from hit) end,'FM9,99,99,999') || ' '
                   || public.uic('catalogue.companies_word','companies'),
    'empty_label', public.uic('catalogue.companies_empty','No company matches this view.'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'letter', s.letter,
              'n', s.n, 'count_label', public.cat_count_label(s.n::bigint)) order by s.label)
              from shown s), '[]'::jsonb));
$$;

-- ── RPC 4 — the salt index ──────────────────────────────────────────────────
-- 107,619 salts: browsing all of them is meaningless, so this is search-first
-- with the biggest salts offered as the starting point. The count beside each
-- is the number of BRANDS behind that composition — which is the whole point
-- of the screen: one salt, every brand, side by side.
create or replace function public.catalogue_salts(
  p_q text default null, p_offset integer default 0,
  p_limit integer default 40, p_zone boolean default true)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  hit as (
    select c.facet_key, c.label, c.n
      from public.catalogue_facet_count c
     where c.facet = 'salt' and c.zone_id = (select cz from z)
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
  ),
  page as (select * from hit order by n desc, facet_key
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select * from page order by n desc, facet_key limit (select n from lim))
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.salts_title','Salts'),
    'zone', public.catalogue_zone_switch(p_zone),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'search_hint', public.uic('catalogue.salt_search_hint','Search a salt, e.g. Paracetamol'),
    'lead_label', public.uic('catalogue.salts_lead','Biggest salts first — search to narrow.'),
    'brands_word', public.uic('catalogue.brands_word','brands'),
    'empty_label', public.uic('catalogue.salts_empty','No salt matches this search in this view.'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'n', s.n,
              'count_label', to_char(s.n,'FM9,99,99,999') || ' '
                             || case when s.n = 1 then public.uic('catalogue.brand_word','brand')
                                     else public.uic('catalogue.brands_word','brands') end)
              order by s.n desc, s.facet_key) from shown s), '[]'::jsonb));
$$;

-- ── RPC 5 — the one product list ────────────────────────────────────────────
-- Every catalogue list is this function: a tree leaf, a company page, a salt's
-- brands, the Schemes tab and the Cold chain tab. One list means one filter
-- vocabulary, one sort, one zone rule and one pagination contract — five
-- surfaces that cannot drift apart.
--
-- KEYSET, not OFFSET. `offset 20000` re-reads twenty thousand rows to throw
-- them away; a company with 4,000 products would get slower the further a buyer
-- scrolled. The cursor carries the last row's sort key, so page 200 costs what
-- page 1 costs. The app treats the cursor as opaque and hands back whatever it
-- was given.
create or replace function public.catalogue_list(
  p_kind    text    default 'tree',
  p_key     text    default null,
  p_path    text[]  default '{}'::text[],
  p_filters jsonb   default '{}'::jsonb,
  p_sort    text    default 'name',
  p_zone    boolean default true,
  p_cursor  text    default null,
  p_limit   integer default 24)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_zone smallint := public._cat_zone(p_zone);
  v_cz   smallint := public._cat_count_zone(p_zone);
  v_n    int      := least(greatest(coalesce(p_limit,24),1),50);
  v_sort text     := case when coalesce(p_sort,'name') = 'newest' then 'newest' else 'name' end;
  v_where text    := public._cat_where(p_kind, p_key, p_path, coalesce(p_filters,'{}'::jsonb));
  v_join  text    := case when v_zone is null then ''
                     else format('join public.catalogue_zone_avail za on za.product_id = m.id and za.zone_id = %L::smallint', v_zone) end;
  v_cur  jsonb;
  v_keyset text := '';
  v_order  text;
  v_sql    text;
  v_ids  bigint[];
  v_last_id bigint; v_last_name text;
  v_total bigint;
  v_filtered boolean := public._cat_filtered(coalesce(p_filters,'{}'::jsonb));
  v_head text;
begin
  begin v_cur := nullif(btrim(coalesce(p_cursor,'')),'')::jsonb; exception when others then v_cur := null; end;

  if v_sort = 'newest' then
    v_order := 'order by m.id desc';
    if v_cur ? 'i' then v_keyset := format(' and m.id < %L::bigint', v_cur->>'i'); end if;
  else
    v_order := 'order by m.product_name, m.id';
    if v_cur ? 'i' then
      v_keyset := format(' and (m.product_name, m.id) > (%L, %L::bigint)',
                         coalesce(v_cur->>'n',''), v_cur->>'i');
    end if;
  end if;

  -- The LIMIT is inside, the numbering outside. Written the other way round
  -- (`row_number() over ()` beside the sort) the window ran BEFORE the sort, so
  -- it both materialised every matching row and numbered them in the wrong
  -- order — a cold-chain page walked 4,413 rows to return 24 of them, scrambled.
  v_sql := format(
    'select array_agg(t.id order by t.ord) from ('
    || 'select s.id, row_number() over () as ord from ('
    || 'select m.id, m.product_name from public."MEDICINE" m %s where %s%s %s limit %s'
    || ') s) t', v_join, v_where, v_keyset, v_order, v_n);
  execute v_sql into v_ids;
  v_ids := coalesce(v_ids, '{}'::bigint[]);

  -- The cursor for the next page is the LAST row this page returned, read from
  -- the row itself rather than recomputed — so a tie on product_name cannot
  -- drop or repeat a product.
  if array_length(v_ids,1) is not null then
    select id, coalesce(product_name,'') into v_last_id, v_last_name
      from "MEDICINE" where id = v_ids[array_length(v_ids,1)];
  end if;

  -- The total is the CACHED node count, and only when the caller has not
  -- narrowed it. A filtered list reports what it is showing instead of a number
  -- it would have to scan 5.6 lakh rows to know.
  v_total := case when v_filtered then null
                  else public._cat_scope_total(p_kind, p_key, p_path, v_cz) end;

  v_head := case
    when p_kind = 'company' then coalesce((select label from public.catalogue_facet_count
        where facet='company' and zone_id=v_cz and facet_key = coalesce(p_key,'')), coalesce(p_key,''))
    when p_kind = 'salt'    then coalesce(p_key,'')
    when p_kind = 'tab' and p_key = 'schemes'    then public.uic('catalogue.tab_schemes','Schemes')
    when p_kind = 'tab' and p_key = 'cold_chain' then public.uic('catalogue.tab_cold','Cold chain')
    when p_kind = 'tree' and coalesce(array_length(p_path,1),0) > 0
      then p_path[array_length(p_path,1)]
    else public.uic('catalogue.all_products','All products') end;

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind, 'key', p_key, 'path', to_jsonb(p_path),
    'title', v_head,
    'subtitle', case
      when p_kind = 'salt' then public.uic('catalogue.salt_subtitle','Every brand for this salt')
      when p_kind = 'company' then public.uic('catalogue.company_subtitle','Products from this company')
      else '' end,
    'zone', public.catalogue_zone_switch(p_zone),
    'sort', v_sort,
    'filters', public.catalogue_filter_defs(coalesce(p_filters,'{}'::jsonb), v_cz),
    'filters_active', v_filtered,
    'filters_active_label', case when v_filtered
      then public.uic('catalogue.filters_on','Filters on') else '' end,
    'total', v_total,
    'count_label', case when v_total is null
      then to_char(coalesce(array_length(v_ids,1),0),'FM9,99,99,999') || ' '
           || public.uic('catalogue.showing_word','shown')
      else public.cat_count_label(v_total) end,
    'empty_label', case when v_filtered
      then public.uic('catalogue.list_empty_filtered','Nothing matches these filters. Clear one and try again.')
      else public.uic('catalogue.list_empty','Nothing here in this view.') end,
    'limit', v_n,
    'has_more', coalesce(array_length(v_ids,1),0) = v_n,
    'more_label', public.uic('catalogue.load_more','Load more'),
    'end_label', public.uic('catalogue.list_end','That is the whole list.'),
    'next_cursor', case when coalesce(array_length(v_ids,1),0) = v_n and v_last_id is not null
      then (case when v_sort = 'newest'
                 then jsonb_build_object('i', v_last_id)
                 else jsonb_build_object('i', v_last_id, 'n', v_last_name) end)::text
      end,
    'items', public._cat_cards(v_ids));
end $$;

-- ── who may call ────────────────────────────────────────────────────────────
-- Anonymous browsing is the point: a pharmacy that has not signed in still sees
-- the whole catalogue, and the zone switch simply does not appear for them.
grant execute on function public.catalogue_home(boolean)                to anon, authenticated;
grant execute on function public.catalogue_tree(text[], boolean)        to anon, authenticated;
grant execute on function public.catalogue_companies(text, text, integer, integer, boolean) to anon, authenticated;
grant execute on function public.catalogue_salts(text, integer, integer, boolean)           to anon, authenticated;
grant execute on function public.catalogue_list(text, text, text[], jsonb, text, boolean, text, integer) to anon, authenticated;
grant execute on function public.catalogue_zone_switch(boolean)         to anon, authenticated;
grant execute on function public.catalogue_filter_defs(jsonb, smallint) to anon, authenticated;
grant execute on function public._cat_meta(smallint, text)              to anon, authenticated;
grant execute on function public.cat_count_label(bigint)                to anon, authenticated;

-- ── the indexes the lists need to stay under 300 ms ─────────────────────────
-- Everything else the catalogue asks for already has one (therapeutic+name,
-- marketer_canonical, id). These two are the gaps: a salt's brands and the
-- schemes tab both had to scan.
-- The salt index opens on "biggest salts first", which is a full ordered read
-- of 106,571 cached rows unless the sort key IS the index.
create index if not exists idx_cat_facet_size
  on public.catalogue_facet_count (facet, zone_id, n desc, facet_key);

-- Level 2 and 3 of the browse tree filter on chemical_class inside a
-- therapeutic class. Without this the planner walks the whole therapeutic
-- class (75,562 rows for ANTI INFECTIVES) to find a chemical class of 420.
create index if not exists idx_medicine_chemical_name
  on public."MEDICINE" (chemical_class, product_name, id);

create index if not exists idx_medicine_salt_plain
  on public."MEDICINE" (salt_composition, product_name, id);
create index if not exists idx_medicine_has_scheme_name
  on public."MEDICINE" (product_name, id) where has_scheme;
create index if not exists idx_medicine_cold_chain_name
  on public."MEDICINE" (product_name, id) where cold_chain;
create index if not exists idx_medicine_company_name
  on public."MEDICINE" (marketer_canonical, product_name, id);

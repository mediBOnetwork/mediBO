-- CMD #1905 — a search suggestion carries a TYPE and an ID.
--
-- The bug (08 Sep): typing "sun pharma" and tapping the company row
-- "SUN PHARMACEUTICAL IND… 2461 products" pasted that company NAME into the
-- product search box. `catalogue_list(p_kind => 'search')` filters on
-- `_norm_name(product_name)` by prefix, and no product is named
-- "SUN PHARMACEUTICAL INDUSTRIES LTD" — so a shopper who tapped the company
-- with 2,461 products got "Nothing here in this view." and an offer to
-- *request* the product they had just been shown 2,461 of. Salts broke the
-- same way. Brands only appeared to work because a brand's name is a prefix
-- of its own products' names, which is a coincidence and not a design.
--
-- The cause is that a suggestion was a STRING. `search_suggest()` already
-- knew each row's kind and key — it simply threw them away at the tap, which
-- is the one moment they mattered. So:
--
--   * every item now carries `kind` (product | company | salt | category),
--     `id` (the thing to open) and `nav` (WHICH surface opens it), and a
--     `chip_label` for the box that replaces the raw text;
--   * a brand row resolves to a real MEDICINE id, so a product suggestion
--     opens the product page instead of a search for its own name;
--   * groups come back in the order they are drawn — Products, Companies,
--     Salts, Categories — three each, with the backend's own "See all" row
--     and the nav that row opens;
--   * `catalogue_list()` stops offering "Request this product" on a scope
--     that was NAVIGATED to (a company, a salt, a class). It is offered only
--     after a TYPED query matched nothing, which is the only moment it is
--     true. The empty state names the scope it is empty of, and when filters
--     are on it offers Clear first.
--
-- Idempotent: copy rows are upserted, the per-group cap is a setting, and
-- every function is CREATE OR REPLACE.

-- ── 1. Copy ────────────────────────────────────────────────────────────────
-- Every string below is editable in ui_copy. Nothing here is ever built in
-- Dart: the group titles, the chip prefixes, the "See all" row and the empty
-- sentences are all rows an admin can rewrite without a deploy.
insert into public.ui_copy(key, value) values
  ('search.group_product',   to_jsonb('Products'::text)),
  ('search.group_company',   to_jsonb('Companies'::text)),
  ('search.group_salt',      to_jsonb('Salts'::text)),
  ('search.group_category',  to_jsonb('Categories'::text)),
  ('search.see_all',         to_jsonb('See all'::text)),
  ('search.chip_product',    to_jsonb('Product: {name}'::text)),
  ('search.chip_company',    to_jsonb('Company: {name}'::text)),
  ('search.chip_salt',       to_jsonb('Salt: {name}'::text)),
  ('search.chip_category',   to_jsonb('Category: {name}'::text)),
  ('search.chip_clear',      to_jsonb('Clear'::text)),
  ('catalogue.list_empty_search',
     to_jsonb('No product matches “{q}”.'::text)),
  ('catalogue.list_empty_search_hint',
     to_jsonb('Check the spelling, or try a shorter word.'::text)),
  ('catalogue.list_empty_scope',
     to_jsonb('Nothing in {scope} right now.'::text)),
  ('catalogue.list_empty_filtered_scope',
     to_jsonb('Nothing in {scope} matches these filters.'::text))
on conflict (key) do nothing;

-- Three per group is the spec's cap; it stays a setting so it can be tuned
-- without a deploy. One extra row is fetched to learn whether "See all" is
-- true, which is cheaper than counting every candidate.
insert into public.app_settings(key, value)
values ('search_suggest_per_group', to_jsonb(3))
on conflict (key) do update set value = to_jsonb(3);

-- ── 2. Where a suggestion goes ─────────────────────────────────────────────
-- The BACKEND names the destination; the app only knows which screen renders
-- which kind. The URL itself is deliberately not built here — the browser's
-- address bar belongs to the app (catalogue_screen.dart owns the deep link),
-- and a path assembled in SQL would be a second, drifting copy of it.
CREATE OR REPLACE FUNCTION public._suggest_nav(p_kind text, p_id text, p_label text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    -- A product opens the product page. An unresolved id (a family whose
    -- label no longer names a live row) falls back to the family LIST rather
    -- than to a dead route — the one place a text query is still honest,
    -- because a brand name really is a prefix of its own products' names.
    when p_kind = 'product' and coalesce(p_id, '') <> ''
      then jsonb_build_object('kind', 'product',  'id', p_id,   'title', p_label)
    when p_kind = 'product'
      then jsonb_build_object('kind', 'search',   'id', p_label, 'title', p_label)
    when p_kind = 'company'
      then jsonb_build_object('kind', 'company',  'id', p_id,   'title', p_label)
    when p_kind = 'salt'
      then jsonb_build_object('kind', 'salt',     'id', p_id,   'title', p_label)
    else   jsonb_build_object('kind', 'category', 'id', p_id,   'title', p_label)
  end;
$function$;

-- "See all" opens the full list for that KIND, still without re-running a
-- product-name search: companies and salts open their own catalogue tabs
-- filtered by what was typed, products open the product search that the
-- typed words were always meant to run.
CREATE OR REPLACE FUNCTION public._suggest_see_all_nav(p_kind text, p_q text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case p_kind
    when 'brand'    then jsonb_build_object('kind', 'search', 'id', p_q,  'title', p_q)
    when 'company'  then jsonb_build_object('kind', 'tab', 'tab', 'companies', 'query', p_q)
    when 'salt'     then jsonb_build_object('kind', 'tab', 'tab', 'salts',     'query', p_q)
    else                 jsonb_build_object('kind', 'tab', 'tab', 'browse',    'query', '')
  end;
$function$;

-- ── 3. search_suggest ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.search_suggest(p_q text, p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_min    int := coalesce((select (value #>> '{}')::int from public.app_settings
                             where key = 'search_suggest_min_chars'), 2);
  v_per    int := coalesce((select (value #>> '{}')::int from public.app_settings
                             where key = 'search_suggest_per_group'), 3);
  v_norm   text := public._norm_name(p_q);
  v_zid    smallint := public._cat_zone(coalesce(p_zone, true));
  v_exp    jsonb;
  v_terms  text[];
  v_groups jsonb;
  v_typo   boolean := false;
  v_lit    int := 0;
  v_near   text[] := '{}';
  v_knn    int := coalesce((select (value #>> '{}')::int from public.app_settings
                             where key = 'search_suggest_knn'), 60);
  v_qtrim  text := btrim(coalesce(p_q, ''));
  v_sep    text := chr(1);
begin
  if length(replace(v_norm, ' ', '')) < v_min then
    return jsonb_build_object(
      'ok', true, 'ready', false, 'q', coalesce(p_q, ''), 'min_chars', v_min,
      'groups', '[]'::jsonb,
      'expanded', jsonb_build_object('has', false),
      'zone', jsonb_build_object('on', v_zid is not null, 'zone_id', v_zid),
      'hint', public.uic('search.suggest_min_chars',
                         'Type at least 2 letters to see suggestions'),
      'clear_label', public.uic('search.chip_clear', 'Clear'),
      'empty_label', '');
  end if;

  -- The Hinglish mapping runs FIRST, so "bukhar" is matched against
  -- Paracetamol and not against a brand that happens to start with "buk".
  v_exp   := public.search_query_expand(v_norm);
  v_terms := array[v_norm];
  if coalesce((v_exp->>'has')::boolean, false) then
    v_terms := v_terms || public._norm_name(v_exp->>'target');
  end if;

  -- Does the literal search find anything at all? One cheap probe (~5 ms on
  -- the live cache) decides whether the typo lane is worth opening.
  -- EXISTS, not count(*): a broad prefix like "montic" matches hundreds of
  -- families and counting them all cost 430 ms on its own, which is the very
  -- budget this probe exists to protect. It stops at the first row.
  select case when exists (
    select 1
      from (select distinct term from unnest(v_terms) term where term <> '') t
      join public.search_suggest_cache s
        on ( s.norm like t.term || '%'
             or (length(t.term) >= 4 and s.norm like '%' || t.term || '%') )
     where (v_zid is null or s.zones @> array[v_zid])
  ) then 0 else 1 end into v_lit;
  v_typo := v_lit = 1 and exists (
    select 1 from unnest(v_terms) term where length(term) >= 4);

  -- The typo lane, resolved ONCE into a bounded key list before the main
  -- query. Selecting the keys out of the KNN scan and then joining them back
  -- with `key = any(...)` cost another 93 ms, because the cache's primary key
  -- is (kind, key) and a key-only predicate cannot use it — so the keys are
  -- qualified with their kind and matched on the full key below.
  if v_typo then
    select coalesce(array_agg(z.kind || v_sep || z.key), '{}') into v_near
      from (
        select s.kind, s.key
          from public.search_suggest_cache s
         where (v_zid is null or s.zones @> array[v_zid])
         order by s.norm <-> v_norm
         limit v_knn
      ) z;
  end if;

  with t as (
    select distinct term from unnest(v_terms) term where term <> ''
  ),
  cand as (
    select s.kind, s.key, s.label, s.sub_label, s.n, s.rank,
           min(case when s.norm = t.term then 0
                    when s.norm like t.term || '%' then 1
                    when s.norm like '%' || t.term || '%' then 2
                    else 3 end) as tier,
           max(similarity(s.norm, t.term)) as sim,
           max(s.query) as query
      from t
      join public.search_suggest_cache s
        on ( s.norm like t.term || '%'
             -- the contains lane only opens at four characters: below that a
             -- prefix is already the honest answer
             or (length(t.term) >= 4 and s.norm like '%' || t.term || '%')
             -- CHANGE #790E — the TYPO lane is a bounded FALLBACK, not a
             -- third arm of the same OR. Measured on the live cache: prefix
             -- alone 1 ms, prefix+contains 5 ms, and adding `%` to the same
             -- OR took the whole call to 570 ms — GIN returned 9,835 rows and
             -- the heap recheck threw 9,808 away, on every keystroke, against
             -- a spec budget of 100 ms. It now runs only when the literal
             -- lanes found NOTHING (which is when a shopper has actually
             -- mistyped), and then as a KNN scan of the nearest v_knn rows.
             or (v_typo and (s.kind || v_sep || s.key) = any(v_near)) )
     where (v_zid is null or s.zones @> array[v_zid])
     group by s.kind, s.key, s.label, s.sub_label, s.n, s.rank
  ),
  ranked as (
    -- CMD #1905 — `tier` first is what makes "Sun Pharmaceutical" beat
    -- "Ayursun" on "sun pharma": an exact hit is tier 0, a PREFIX is tier 1
    -- and a mere substring is tier 2, so a substring can never outrank a
    -- prefix however well it sells.
    select c.*, row_number() over (partition by c.kind
             order by c.tier asc, c.rank desc, c.n desc, length(c.label) asc) as rn
      from cand c
  ),
  picked as (
    -- v_per + 1: the extra row is never drawn, it only answers "is there a
    -- See all?" without paying for a count over every candidate.
    select * from ranked where rn <= v_per + 1
  ),
  -- A product suggestion must open a PRODUCT. The cache's brand key is
  -- `<brand root>|<marketer_canonical>` and its label is a real product_name
  -- from that family, so the id is one index hit on idx_medicine_company_name
  -- (0.06 ms measured on live) — run for at most v_per + 1 rows, and only for
  -- brands.
  withid as (
    select p.*, pid.id as product_id
      from picked p
      left join lateral (
        select m.id
          from public."MEDICINE" m
         where m.product_name = p.label
           and m.marketer_canonical is not distinct from
               nullif(case when position('|' in p.key) > 0
                           then substr(p.key, position('|' in p.key) + 1)
                           else '' end, '')
         order by m.id
         limit 1
      ) pid on p.kind = 'brand'
  ),
  shaped as (
    select w.*,
           -- The cache still speaks in 'brand'; the PAYLOAD speaks the
           -- shopper's language, and 'product' is what a brand row opens.
           case when w.kind = 'brand' then 'product' else w.kind end as okind,
           case when w.kind = 'brand' then coalesce(w.product_id::text, '')
                else w.key end as oid
      from withid w
  ),
  grouped as (
    select k.kind, k.ord, k.title,
           count(*) filter (where s.rn <= v_per) as shown,
           count(*) as found,
           jsonb_agg(jsonb_build_object(
             -- `kind` and `key` stay for anything still reading the old shape;
             -- `id` and `nav` are what a tap uses now.
             'kind', s.okind, 'key', s.key, 'id', s.oid,
             'label', s.label,
             'sub_label', case when s.kind = 'brand' and s.sub_label <> ''
                               then replace(public.uic('search.family_by', 'by {company}'),
                                            '{company}', s.sub_label)
                               else s.sub_label end,
             'count_label', public._suggest_count_label(s.kind, s.n),
             'n', s.n,
             'query', s.query,
             'chip_label', replace(
               case s.okind
                 when 'product'  then public.uic('search.chip_product',  'Product: {name}')
                 when 'company'  then public.uic('search.chip_company',  'Company: {name}')
                 when 'salt'     then public.uic('search.chip_salt',     'Salt: {name}')
                 else                 public.uic('search.chip_category', 'Category: {name}')
               end, '{name}', s.label),
             'nav', public._suggest_nav(s.okind, s.oid, s.label))
             order by s.rn)
             filter (where s.rn <= v_per) as items
      from (values ('brand',    1, public.uic('search.group_product',  'Products')),
                   ('company',  2, public.uic('search.group_company',  'Companies')),
                   ('salt',     3, public.uic('search.group_salt',     'Salts')),
                   ('category', 4, public.uic('search.group_category', 'Categories')))
             as k(kind, ord, title)
      join shaped s on s.kind = k.kind
     group by k.kind, k.ord, k.title
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', case when g.kind = 'brand' then 'product' else g.kind end,
           'title', g.title,
           'items', coalesce(g.items, '[]'::jsonb),
           'see_all', jsonb_build_object(
             'has', g.found > g.shown,
             'label', public.uic('search.see_all', 'See all'),
             'nav', public._suggest_see_all_nav(g.kind, v_qtrim)))
           order by g.ord),
         '[]'::jsonb)
    into v_groups
    from grouped g
   where coalesce(g.items, '[]'::jsonb) <> '[]'::jsonb;

  return jsonb_build_object(
    'ok', true, 'ready', true, 'q', coalesce(p_q, ''), 'min_chars', v_min,
    'groups', coalesce(v_groups, '[]'::jsonb),
    'expanded', v_exp,
    'zone', jsonb_build_object(
       'on', v_zid is not null, 'zone_id', v_zid,
       'note', case when v_zid is null then ''
                    else public.uic('search.zone_note',
                                    'Suggestions from what your zone can send') end),
    'hint', '',
    'clear_label', public.uic('search.chip_clear', 'Clear'),
    'empty_label', case when coalesce(jsonb_array_length(v_groups), 0) > 0 then ''
                        else public.uic('search.suggest_empty',
                               'No matches yet — press search to look through the full catalogue') end);
end $function$;

-- ── 4. catalogue_list — the empty state tells the truth ────────────────────
CREATE OR REPLACE FUNCTION public.catalogue_list(p_kind text DEFAULT 'tree'::text, p_key text DEFAULT NULL::text, p_path text[] DEFAULT '{}'::text[], p_filters jsonb DEFAULT '{}'::jsonb, p_sort text DEFAULT 'name'::text, p_zone boolean DEFAULT true, p_cursor text DEFAULT NULL::text, p_limit integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  -- p_zone survives in the signature only so a deep link, a cached page or an
  -- app build from before this change still resolves the function. Nothing
  -- reads it any more; _cat_zone() returns NULL whatever it is handed.
  v_azone smallint := public._cat_avail_zone();
  v_cz    smallint := public._cat_count_zone(p_zone);   -- 0 — all zones
  v_n     int      := least(greatest(coalesce(p_limit,24),1),50);
  v_sort  text     := case when coalesce(p_sort,'name') = 'newest' then 'newest' else 'name' end;
  v_where text     := public._cat_where(p_kind, p_key, p_path, coalesce(p_filters,'{}'::jsonb));
  v_cur   jsonb;
  v_cg    smallint;
  v_sql   text;
  v_ids   bigint[] := '{}'::bigint[];
  v_grps  smallint[] := '{}'::smallint[];
  v_part  bigint[];
  v_got   int;
  v_last_id bigint; v_last_name text; v_last_g smallint;
  v_filtered boolean := coalesce(public._cat_filtered(coalesce(p_filters,'{}'::jsonb)), false);
  v_head text;
  v_empty text;
  -- CMD #1905 — a TYPED query is the only scope that may offer
  -- "Request this product"; a navigated one (company / salt / class)
  -- never is, because the shopper did not type anything to miss with.
  v_typed boolean := (p_kind = 'search' and coalesce(btrim(coalesce(p_key,'')),'') <> '');
  v_request boolean := false;
  v_empty_hint text := '';
  v_zsw jsonb := public.catalogue_zone_switch(p_zone);
  v_narrow boolean := (p_kind = 'search');
  v_filters jsonb;
  v_sentence jsonb;
  v_total bigint; v_total_in bigint; v_total_out bigint;
  v_lbl_in text; v_lbl_out text;
  v_more boolean;
begin
  begin v_cur := nullif(btrim(coalesce(p_cursor,'')),'')::jsonb; exception when others then v_cur := null; end;
  -- A cursor minted before this change carries no 'g'. It was a position in
  -- the zone-filtered list, which is now group 0 — so read it as one.
  v_cg := case when v_cur is null then null
               when v_cur ? 'g'  then (v_cur->>'g')::smallint
               else 0::smallint end;
  if v_azone is null then v_cg := null; end if;

  -- ── the page ────────────────────────────────────────────────────────────
  -- Two keyset reads, never a sort over the whole scope: group 0 is the same
  -- indexed join #747 always ran, group 1 is the same walk with an anti-join
  -- on the (zone_id, product_id) primary key. Ordering by a computed group
  -- column instead would have made a 5.6-lakh scope sort on every page.
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

  -- ── the counts ──────────────────────────────────────────────────────────
  -- Both totals come from catalogue_facet_count, which already keeps a row per
  -- (facet, zone): zone 0 is the whole catalogue, the viewer's zone is what is
  -- reachable. Subtracting is the ONE piece of arithmetic here and it is done
  -- in SQL, never in Dart. A filtered scope has no precomputed total, so every
  -- count goes NULL together and the labels print without numbers.
  v_total     := case when v_filtered then null
                      else public._cat_scope_total(p_kind, p_key, p_path, 0::smallint) end;
  v_total_in  := case when v_filtered or v_azone is null then null
                      else public._cat_scope_total(p_kind, p_key, p_path, v_azone) end;
  v_total_out := case when v_total is null or v_total_in is null then null
                      else greatest(v_total - v_total_in, 0) end;
  v_lbl_in    := public.cat_group_label('in',  v_total_in);
  v_lbl_out   := public.cat_group_label('out', v_total_out);

  v_head := case
    when p_kind = 'company' then coalesce((select label from public.catalogue_facet_count
        where facet='company' and zone_id=v_cz and facet_key = coalesce(p_key,'')), coalesce(p_key,''))
    when p_kind = 'salt'    then coalesce(p_key,'')
    when p_kind = 'search'  then coalesce(nullif(btrim(coalesce(p_key,'')),''),
                                          public.uic('catalogue.all_products','All products'))
    when p_kind = 'tab' and p_key = 'schemes'    then public.uic('catalogue.tab_schemes','Schemes')
    when p_kind = 'tab' and p_key = 'cold_chain' then public.uic('catalogue.tab_cold','Cold chain')
    when p_kind = 'tree' and coalesce(array_length(p_path,1),0) > 0
      then p_path[array_length(p_path,1)]
    else public.uic('catalogue.all_products','All products') end;

  -- Nothing is hidden any more, so "nothing here" can no longer be the zone's
  -- fault and the copy stops blaming it.
  -- CMD #1905 — an empty scope NAMES itself. "Nothing here in this view."
  -- told a shopper who had just tapped a company with 2,461 products nothing
  -- at all; v_head is already the scope's own title, so the sentence uses it.
  v_empty := case
    when v_filtered then replace(public.uic('catalogue.list_empty_filtered_scope',
                         'Nothing in {scope} matches these filters.'), '{scope}', v_head)
    when v_typed    then replace(public.uic('catalogue.list_empty_search',
                         'No product matches “{q}”.'), '{q}', btrim(p_key))
    else replace(public.uic('catalogue.list_empty_scope',
                   'Nothing in {scope} right now.'), '{scope}', v_head) end;
  -- "Request this product" is true ONLY after a typed query found nothing.
  -- On a company, a salt or a class it was an offer to request the very
  -- catalogue the shopper had asked to see.
  -- TYPED is the whole gate, not "typed and unfiltered": a shopper who typed
  -- a word and narrowed it may still want the product requested. What the
  -- filters change is the ORDER — clearing them comes first below, because a
  -- filter the shopper set themselves is the likelier reason for the blank.
  v_request := v_typed
    and coalesce((select request_open from public.catalogue_extras_config where id = 1), true);
  v_empty_hint := case when v_typed and not v_filtered
    then public.uic('catalogue.list_empty_search_hint',
                    'Check the spelling, or try a shorter word.') else '' end;

  v_filters := public.catalogue_filter_defs(coalesce(p_filters,'{}'::jsonb), v_cz);
  if not v_narrow then
    v_filters := jsonb_set(v_filters, '{groups}', '[]'::jsonb);
    v_sentence := jsonb_build_object(
      'lead','', 'separator','', 'all_label','', 'clear_label','',
      'has_selection', false, 'parts', '[]'::jsonb);
  else
    v_sentence := public.catalogue_sentence(coalesce(p_filters,'{}'::jsonb), p_zone, v_cz);
  end if;

  -- A full page means there may be more. With two groups that still holds:
  -- group 0 short + group 1 topping the page up to v_n means group 1 has more.
  v_more := (v_got = v_n);

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind, 'key', p_key, 'path', to_jsonb(p_path),
    'title', v_head,
    'subtitle', case
      when p_kind = 'salt' then public.uic('catalogue.salt_subtitle','Every brand for this salt')
      when p_kind = 'company' then public.uic('catalogue.company_subtitle','Products from this company')
      when p_kind = 'search' then public.uic('catalogue.search_subtitle','Matches in the catalogue')
      else '' end,
    'trail', public.catalogue_trail(
               case when p_kind = 'company' then 'companies'
                    when p_kind = 'salt' then 'salts'
                    else 'browse' end,
               p_path, p_kind, p_key, v_head),
    'zone', v_zsw,
    'grouped', v_azone is not null,
    'groups', case when v_azone is null then '[]'::jsonb else jsonb_build_array(
        jsonb_build_object('key','in',  'label', v_lbl_in,  'count', v_total_in),
        jsonb_build_object('key','out', 'label', v_lbl_out, 'count', v_total_out)) end,
    'sort', v_sort,
    'filters', v_filters,
    'sentence', v_sentence,
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
      -- CMD #1905 — the buttons in the order they are drawn, tone included.
      -- Clear filters comes FIRST when filters are on: the shopper's own
      -- filter is the likeliest reason the scope is empty, so undoing it is
      -- the primary way out and requesting a product is the afterthought.
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
end $function$

;

-- ── 5. Grants ──────────────────────────────────────────────────────────────
-- The two helpers are internals of search_suggest(), which is SECURITY
-- DEFINER and therefore still calls them as the owner. Nothing outside needs
-- them, so the API roles do not get them: a function in the exposed schema is
-- reachable over PostgREST whatever it is named.
revoke all on function public._suggest_nav(text, text, text) from public, anon, authenticated;
revoke all on function public._suggest_see_all_nav(text, text) from public, anon, authenticated;

-- search_suggest and catalogue_list keep exactly the reach they already had:
-- the storefront typeahead and the catalogue are open to a signed-out shopper
-- by design, which is how a first-time visitor can browse before registering.
grant execute on function public.search_suggest(text, boolean) to anon, authenticated;
grant execute on function public.catalogue_list(text, text, text[], jsonb, text, boolean, text, integer)
  to anon, authenticated;

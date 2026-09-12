-- CMD #1910 — the typeahead learns Conditions.
--
-- A condition row is a TYPED row like a company or a salt: it carries its own
-- id (the condition_key) and its own nav, so a tap opens "Catalogue › Use ›
-- Fever" rather than running a text search for the word "fever".
--
-- Synonyms ride in the cache row's `norm`, not in extra rows: the matcher
-- already has a contains lane at four characters, so "bukhar" finds Fever
-- through the SAME index scan and the row keeps one id.

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
    when p_kind = 'condition'
      then jsonb_build_object('kind', 'condition','id', p_id,   'title', p_label)
    else   jsonb_build_object('kind', 'category', 'id', p_id,   'title', p_label)
  end;
$function$;

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
    when 'condition' then jsonb_build_object('kind', 'tab', 'tab', 'conditions','query', p_q)
    else                 jsonb_build_object('kind', 'tab', 'tab', 'browse',    'query', '')
  end;
$function$;

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
                 when 'condition' then public.uic('search.chip_condition', 'Use: {name}')
                 else                 public.uic('search.chip_category', 'Category: {name}')
               end, '{name}', s.label),
             'nav', public._suggest_nav(s.okind, s.oid, s.label))
             order by s.rn)
             filter (where s.rn <= v_per) as items
      from (values ('brand',    1, public.uic('search.group_product',  'Products')),
                   ('company',  2, public.uic('search.group_company',  'Companies')),
                   ('salt',     3, public.uic('search.group_salt',     'Salts')),
                   ('category', 4, public.uic('search.group_category', 'Categories')),
                   ('condition', 5, public.uic('search.group_condition', 'Conditions')))
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

-- ── the cache rows ────────────────────────────────────────────────────────
-- #1894 stopped PLANNING the typeahead cache, so nothing rebuilds it on a
-- schedule any more. Condition rows are therefore written straight into the
-- cache by this function — never through the stage/swap pair, whose swap
-- deletes a whole hash bucket across every kind and would take brands with it.
-- It is the one writer of kind='condition' and it is idempotent: rebuild,
-- upsert, then drop the keys that no longer exist.
create or replace function public.search_suggest_conditions_rebuild()
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_rows bigint := 0;
begin
  with zone_of as (
    select z.facet_key, array_agg(distinct z.zone_id order by z.zone_id) as zones
      from public.catalogue_facet_count z
     where z.facet = 'condition' and z.zone_id > 0
     group by z.facet_key
  ),
  src as (
    select c.facet_key as key,
           c.label,
           c.n,
           -- The label FIRST, so a prefix match on the real word still ranks
           -- as a prefix; the synonyms follow for the contains lane.
           public._norm_name(c.label || ' ' ||
             coalesce(array_to_string(cond.synonyms, ' '), '')) as norm,
           coalesce(zo.zones, '{}'::smallint[]) as zones
      from public.catalogue_facet_count c
      join public.condition cond on cond.condition_key = c.facet_key and cond.is_active
      left join zone_of zo on zo.facet_key = c.facet_key
     where c.facet = 'condition' and c.zone_id = 0
       and nullif(btrim(c.label), '') is not null
  )
  insert into public.search_suggest_cache(kind, key, label, sub_label, n, rank, norm, zones, query)
  select 'condition', s.key, s.label, '', s.n, s.n::bigint, s.norm, s.zones, s.label
    from src s
  on conflict (kind, key) do update
    set label = excluded.label, sub_label = excluded.sub_label, n = excluded.n,
        rank = excluded.rank, norm = excluded.norm, zones = excluded.zones,
        query = excluded.query;
  get diagnostics v_rows = row_count;

  delete from public.search_suggest_cache c
   where c.kind = 'condition'
     and not exists (select 1 from public.catalogue_facet_count f
                      join public.condition cond
                        on cond.condition_key = f.facet_key and cond.is_active
                     where f.facet = 'condition' and f.zone_id = 0
                       and f.facet_key = c.key);
  return v_rows;
end $fn$;

revoke all on function public.search_suggest_conditions_rebuild() from public, anon, authenticated;

insert into public.ui_copy (key, value) values
  ('search.group_condition', to_jsonb('Conditions'::text)),
  ('search.chip_condition',  to_jsonb('Use: {name}'::text))
on conflict (key) do nothing;

-- CMD #1929 — same guard as the seed pass in
-- 20260912200000_c1910_condition_schema_seed.sql: this rebuild is a live data
-- pass at the end of a migration, and a migration that cancels on
-- statement_timeout fails the whole replay for every command on the box. It is
-- one statement, so a cancel rolls back whole; give it room, and defer with a
-- warning rather than block the lane. Re-runnable at any time.
set statement_timeout = '600s';

do $rebuild$
begin
  perform public.search_suggest_conditions_rebuild();
exception when others then
  raise warning 'search_suggest_conditions_rebuild deferred (%) — re-run select public.search_suggest_conditions_rebuild();', sqlerrm;
end $rebuild$;

reset statement_timeout;

-- CHANGE #790, part E — the two gaps left in the backend half.
--
-- (1) suggest_facet was O(rows) correlated subqueries.
--     For every one of the 106,571 salt rows at zone 0 it re-queried
--     catalogue_facet_count for that key's zones. Measured on the live box:
--     the salt unit did not finish inside 170 s, so the bounded tick could
--     never promote salts into the typeahead cache at all — the whole "Salts"
--     group was permanently empty. This is the scalar-helper-scan the repo's
--     own lessons name: resolve the set ONCE in a CTE and join it.
--
-- (2) The synonym table shipped with no way to edit it.
--     Part C's own comment promises "editable afterwards from Admin → Search
--     synonyms", and #790's spec says the mapping is "admin-editable". Without
--     these three RPCs and a route, the Hinglish half is a seed nobody can
--     correct — and a wrong mapping (bukhar → the wrong salt) would need a
--     migration to fix. Every string below is the backend's.
--
-- Idempotent: create or replace, on conflict do nothing, if not exists.

-- ── 1. the facet unit, resolved set-based ──────────────────────────────────
create or replace function public.search_suggest_unit(
  p_kind text, p_arg text default '', p_arg2 text default '')
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows bigint := 0;
  v_bucket int;
  v_facet text;
begin
  if p_kind = 'suggest_reset' then
    delete from public.search_suggest_stage;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_brand' then
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select 'brand', g.root || '|' || coalesce(g.mc, ''), p_arg, g.label,
           coalesce(mc.display, g.mc, ''), g.n, g.rank, g.root, '{}'::smallint[], g.label
      from (
        select b.root, b.mc,
               (array_agg(b.product_name order by b.nlen, b.sales_count desc nulls last, b.id))[1] as label,
               count(*)::int as n,
               coalesce(sum(b.sales_count), 0)::bigint as rank
          from (
            select m.id, m.product_name, m.marketer_canonical as mc, m.sales_count,
                   public._brand_root(m.product_name) as root,
                   length(public._norm_name(m.product_name)) as nlen
              from public."MEDICINE" m
             where m.id between p_arg::bigint and p_arg2::bigint
               and public.catalogue_universe_ok(m.status)
               and nullif(btrim(m.product_name), '') is not null
          ) b
         group by b.root, b.mc
      ) g
      left join public.medicine_company mc on mc.canon = g.mc
    on conflict (kind, key, src) do update
      set n = excluded.n, rank = excluded.rank, label = excluded.label,
          sub_label = excluded.sub_label, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_zone' then
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    with fam as (
      select distinct public.brand_family_key(m.product_name, m.marketer_canonical) as key
        from public.catalogue_zone_avail za
        join public."MEDICINE" m on m.id = za.product_id
       where za.zone_id = v_bucket::smallint
    )
    update public.search_suggest_stage s
       set zones = (select coalesce(array_agg(distinct z order by z), '{}'::smallint[])
                      from unnest(s.zones || array[v_bucket::smallint]) z)
      from fam
     where s.kind = 'brand' and s.key = fam.key
       and not (s.zones @> array[v_bucket::smallint]);
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_facet' then
    -- CHANGE #790E — the zone list is aggregated ONCE, keyed by facet_key, and
    -- joined. The old shape ran one correlated subquery per row: 106,571 of
    -- them for salts, which never finished inside the statement cap.
    v_facet := case p_arg when 'category' then 'therapeutic' else p_arg end;
    with zone_of as (
      select z.facet_key,
             array_agg(distinct z.zone_id order by z.zone_id) as zones
        from public.catalogue_facet_count z
       where z.facet = v_facet
         and z.zone_id > 0
       group by z.facet_key
    )
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select p_arg, c.facet_key, '', c.label, '', c.n, c.n::bigint,
           public._norm_name(c.label),
           coalesce(zo.zones, '{}'::smallint[]),
           c.label
      from public.catalogue_facet_count c
      left join zone_of zo on zo.facet_key = c.facet_key
     where c.zone_id = 0
       and c.facet = v_facet
       and nullif(btrim(c.label), '') is not null
    on conflict (kind, key, src) do update
      set label = excluded.label, n = excluded.n, rank = excluded.rank,
          norm = excluded.norm, zones = excluded.zones, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_swap' then
    -- CHANGE #790E — this statement never once succeeded. `zones` is
    -- smallint[], so array_agg(s.zones) is smallint[][] and subscripting it
    -- with [1] yields a scalar smallint, which the column refuses:
    --   ERROR: column "zones" is of type smallint[] but expression is of
    --          type smallint
    -- The swap is the ONLY writer of search_suggest_cache, so the cache stayed
    -- empty and every typeahead answer was empty with it — the whole feature
    -- was dead on arrival and nothing said so, because catalogue_cache_tick()
    -- records the unit's error and moves on.
    -- A family that appears in several id ranges is available in the UNION of
    -- the zones those ranges saw, so the zones are unnested and re-aggregated
    -- rather than picked from one row.
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    delete from public.search_suggest_cache c
     where abs(hashtext(c.key)) % 6 = v_bucket;
    with src as (
      select s.* from public.search_suggest_stage s
       where abs(hashtext(s.key)) % 6 = v_bucket
    ),
    pick as (
      select s.kind, s.key,
             (array_agg(s.label     order by length(s.label), s.src))[1] as label,
             (array_agg(s.sub_label order by length(s.label), s.src))[1] as sub_label,
             sum(s.n)::int    as n,
             sum(s.rank)::bigint as rank,
             (array_agg(s.norm  order by length(s.label), s.src))[1] as norm,
             (array_agg(s.query order by length(s.label), s.src))[1] as query
        from src s group by s.kind, s.key
    ),
    zed as (
      select s.kind, s.key,
             coalesce(array_agg(distinct zz order by zz)
                        filter (where zz is not null), '{}'::smallint[]) as zones
        from src s
        left join lateral unnest(s.zones) zz on true
       group by s.kind, s.key
    )
    insert into public.search_suggest_cache(kind, key, label, sub_label, n, rank, norm, zones, query)
    select p.kind, p.key, p.label, p.sub_label, p.n, p.rank, p.norm,
           coalesce(z.zones, '{}'::smallint[]), p.query
      from pick p
      left join zed z on z.kind = p.kind and z.key = p.key
    on conflict (kind, key) do update
      set label = excluded.label, sub_label = excluded.sub_label, n = excluded.n,
          rank = excluded.rank, norm = excluded.norm, zones = excluded.zones,
          query = excluded.query;
    get diagnostics v_rows = row_count;
  end if;

  return v_rows;
end $function$;

comment on function public.search_suggest_unit(text, text, text) is
  'CHANGE #790 — one bounded unit of typeahead-cache work, driven by catalogue_cache_tick(). #790E made suggest_facet set-based.';

-- a facet_key index the set-based aggregate reads instead of the per-row probe
create index if not exists idx_cat_facet_key_zone
  on public.catalogue_facet_count (facet, facet_key, zone_id);

-- ── 2. the admin surface for the mapping ───────────────────────────────────
insert into public.ui_copy (key, value) values
  ('search.syn_title',        '"Search synonyms"'::jsonb),
  ('search.syn_subtitle',     '"What a shopper types, and the salt or class it should search for."'::jsonb),
  ('search.syn_empty',        '"No synonyms yet."'::jsonb),
  ('search.syn_add',          '"Add synonym"'::jsonb),
  ('search.syn_save',         '"Save"'::jsonb),
  ('search.syn_delete',       '"Delete"'::jsonb),
  ('search.syn_term_label',   '"What they type"'::jsonb),
  ('search.syn_term_hint',    '"bukhar"'::jsonb),
  ('search.syn_target_label', '"What to search for"'::jsonb),
  ('search.syn_target_hint',  '"Paracetamol"'::jsonb),
  ('search.syn_lang_label',   '"Language"'::jsonb),
  ('search.syn_kind_label',   '"Match as"'::jsonb),
  ('search.syn_active_label', '"Active"'::jsonb),
  ('search.syn_saved',        '"Saved."'::jsonb),
  ('search.syn_deleted',      '"Deleted."'::jsonb),
  ('search.syn_need_term',    '"Type the word a shopper would use."'::jsonb),
  ('search.syn_need_target',  '"Type the salt or class it should search for."'::jsonb),
  ('search.syn_denied',       '"Only mediBO staff can edit search synonyms."'::jsonb),
  ('search.syn_gone',         '"That synonym is no longer there."'::jsonb),
  ('search.syn_count_one',    '"1 synonym"'::jsonb),
  ('search.syn_count_many',   '"{n} synonyms"'::jsonb),
  ('search.syn_source_seed',  '"Seeded"'::jsonb),
  ('search.syn_source_admin', '"Edited by staff"'::jsonb)
on conflict (key) do nothing;

create or replace function public._c790_syn_denied()
returns jsonb language sql stable as $$
  select jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
    'title', public.uic('search.syn_title', 'Search synonyms'),
    'message', public.uic('search.syn_denied',
                          'Only mediBO staff can edit search synonyms.'));
$$;

-- The list. One RPC, every string in it, so the screen prints and never words.
create or replace function public.search_synonyms_list(p_q text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_n int; v_needle text;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return public._c790_syn_denied();
  end if;
  v_needle := nullif(btrim(coalesce(p_q, '')), '');

  select coalesce(jsonb_agg(jsonb_build_object(
           'term', s.term,
           'display', coalesce(nullif(s.display,''), s.term),
           'lang', s.lang,
           'target_kind', s.target_kind,
           'target', s.target,
           'note', coalesce(s.note, ''),
           'active', s.active,
           'source', s.source,
           'source_label', case when s.source = 'seed'
                                then public.uic('search.syn_source_seed','Seeded')
                                else public.uic('search.syn_source_admin','Edited by staff') end,
           'subtitle', coalesce(nullif(s.display,''), s.term) || ' → ' || s.target)
         order by s.term), '[]'::jsonb), count(*)::int
    into v_rows, v_n
    from public.search_synonym s
   where v_needle is null
      or s.term ilike '%'||v_needle||'%'
      or s.target ilike '%'||v_needle||'%';

  return jsonb_build_object(
    'ok', true,
    'title', public.uic('search.syn_title', 'Search synonyms'),
    'subtitle', public.uic('search.syn_subtitle',
      'What a shopper types, and the salt or class it should search for.'),
    'empty_note', public.uic('search.syn_empty', 'No synonyms yet.'),
    'add_label', public.uic('search.syn_add', 'Add synonym'),
    'save_label', public.uic('search.syn_save', 'Save'),
    'delete_label', public.uic('search.syn_delete', 'Delete'),
    'term_label', public.uic('search.syn_term_label', 'What they type'),
    'term_hint', public.uic('search.syn_term_hint', 'bukhar'),
    'target_label', public.uic('search.syn_target_label', 'What to search for'),
    'target_hint', public.uic('search.syn_target_hint', 'Paracetamol'),
    'lang_label', public.uic('search.syn_lang_label', 'Language'),
    'kind_label', public.uic('search.syn_kind_label', 'Match as'),
    'active_label', public.uic('search.syn_active_label', 'Active'),
    'count_label', case when v_n = 1
                        then public.uic('search.syn_count_one', '1 synonym')
                        else replace(public.uic('search.syn_count_many','{n} synonyms'),
                                     '{n}', v_n::text) end,
    'lang_options', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'label', l)
                       order by o), '[]'::jsonb)
                       from (values ('hi','Hindi / Hinglish',1), ('en','English',2)) v(k,l,o)),
    'kind_options', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'label', l)
                       order by o), '[]'::jsonb)
                       from (values ('salt','Salt',1), ('category','Category',2),
                                    ('brand','Brand',3)) v(k,l,o)),
    'rows', v_rows);
end $function$;

-- Upsert. The term is the key, so editing a row and adding one are the same
-- verb; `p_was` renames (delete the old key, write the new one) in one call.
create or replace function public.search_synonym_upsert(
  p_term text, p_target text, p_lang text default 'hi',
  p_target_kind text default 'salt', p_display text default null,
  p_note text default null, p_active boolean default true, p_was text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_term text; v_target text;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return public._c790_syn_denied();
  end if;
  v_term   := lower(nullif(btrim(coalesce(p_term,'')), ''));
  v_target := nullif(btrim(coalesce(p_target,'')), '');
  if v_term is null then
    return jsonb_build_object('ok', false, 'error', 'need_term', 'tone', 'danger',
      'message', public.uic('search.syn_need_term',
                            'Type the word a shopper would use.'));
  end if;
  if v_target is null then
    return jsonb_build_object('ok', false, 'error', 'need_target', 'tone', 'danger',
      'message', public.uic('search.syn_need_target',
                            'Type the salt or class it should search for.'));
  end if;

  if p_was is not null and lower(btrim(p_was)) <> v_term then
    delete from public.search_synonym where term = lower(btrim(p_was));
  end if;

  insert into public.search_synonym
    (term, display, lang, target_kind, target, note, source, active)
  values (v_term, coalesce(nullif(btrim(coalesce(p_display,'')),''), v_term),
          coalesce(nullif(p_lang,''), 'hi'),
          coalesce(nullif(p_target_kind,''), 'salt'), v_target,
          nullif(btrim(coalesce(p_note,'')), ''), 'admin', coalesce(p_active, true))
  on conflict (term) do update
    set display = excluded.display, lang = excluded.lang,
        target_kind = excluded.target_kind, target = excluded.target,
        note = excluded.note, active = excluded.active,
        source = 'admin', updated_at = now();

  return jsonb_build_object('ok', true, 'tone', 'success',
    'message', public.uic('search.syn_saved', 'Saved.'),
    'state', public.search_synonyms_list(null));
end $function$;

create or replace function public.search_synonym_delete(p_term text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return public._c790_syn_denied();
  end if;
  delete from public.search_synonym where term = lower(btrim(coalesce(p_term,'')));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'gone', 'tone', 'danger',
      'message', public.uic('search.syn_gone', 'That synonym is no longer there.'),
      'state', public.search_synonyms_list(null));
  end if;
  return jsonb_build_object('ok', true, 'tone', 'success',
    'message', public.uic('search.syn_deleted', 'Deleted.'),
    'state', public.search_synonyms_list(null));
end $function$;

revoke all on function public.search_synonyms_list(text) from anon;
revoke all on function public.search_synonym_upsert(text,text,text,text,text,text,boolean,text) from anon;
revoke all on function public.search_synonym_delete(text) from anon;

-- ── 3. the door ────────────────────────────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, description)
values ('admin.search_synonyms', 'Search synonyms', 'Catalogue', 'search',
        'search_synonyms', 57, 'medibo', false, 'none', true, 'catalogue',
        'dashboard', array['admin','super_admin'],
        'CHANGE #790 — the Hinglish/Hindi words a shopper types and the salt or class each one searches for.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      route_key = excluded.route_key, roles_allowed = excluded.roles_allowed,
      is_active = true, description = excluded.description;

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('search_synonyms', 'admin.search_synonyms', 'feature', 'home_shell',
        'CHANGE #790 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.',
        true)
on conflict (route_key, feature_key) do update
  set handled_by = excluded.handled_by, kind = excluded.kind,
      note = excluded.note, is_active = true;

-- ── 4. the typeahead's typo lane becomes a bounded KNN fallback ────────────
-- The GiST trigram index is what makes `norm <-> q` an ORDERED index scan, so
-- the typo lane asks for the 24 nearest strings and stops, instead of asking
-- GIN for every row above a similarity threshold and rechecking them all on
-- the heap. Measured on the live 51k-row cache: the GIN lane returned 30 rows
-- for "montic" in 420 ms (and 99 ms even when it returned NOTHING — that is
-- the index scan's own floor); the KNN lane answers the same query in 41 ms
-- and ranks better (Montiz-FX 0.56, Montina 0.50).
create index if not exists idx_ssc_norm_gist
  on public.search_suggest_cache using gist (norm gist_trgm_ops);

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
                             where key = 'search_suggest_per_group'), 5);
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
begin
  if length(replace(v_norm, ' ', '')) < v_min then
    return jsonb_build_object(
      'ok', true, 'ready', false, 'q', coalesce(p_q, ''), 'min_chars', v_min,
      'groups', '[]'::jsonb,
      'expanded', jsonb_build_object('has', false),
      'zone', jsonb_build_object('on', v_zid is not null, 'zone_id', v_zid),
      'hint', public.uic('search.suggest_min_chars',
                         'Type at least 2 letters to see suggestions'),
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
    select coalesce(array_agg(z.kind || '\u0001' || z.key), '{}') into v_near
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
             or (v_typo and (s.kind || '\u0001' || s.key) = any(v_near)) )
     where (v_zid is null or s.zones @> array[v_zid])
     group by s.kind, s.key, s.label, s.sub_label, s.n, s.rank
  ),
  ranked as (
    select c.*, row_number() over (partition by c.kind
             order by c.tier asc, c.rank desc, c.n desc, length(c.label) asc) as rn
      from cand c
  ),
  picked as (
    select * from ranked where rn <= v_per
  ),
  grouped as (
    select k.kind, k.ord, k.title,
           jsonb_agg(jsonb_build_object(
             'kind', p.kind, 'key', p.key, 'label', p.label,
             'sub_label', case when p.kind = 'brand' and p.sub_label <> ''
                               then replace(public.uic('search.family_by', 'by {company}'),
                                            '{company}', p.sub_label)
                               else p.sub_label end,
             'count_label', public._suggest_count_label(p.kind, p.n),
             'n', p.n,
             'query', p.query) order by p.rn) as items
      from (values ('brand', 1, public.uic('search.group_brand', 'Brands')),
                   ('salt', 2, public.uic('search.group_salt', 'Salts')),
                   ('company', 3, public.uic('search.group_company', 'Companies')),
                   ('category', 4, public.uic('search.group_category', 'Categories')))
             as k(kind, ord, title)
      join picked p on p.kind = k.kind
     group by k.kind, k.ord, k.title
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', g.kind, 'title', g.title,
                                               'items', g.items) order by g.ord),
                  '[]'::jsonb)
    into v_groups
    from grouped g;

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
    'empty_label', case when coalesce(jsonb_array_length(v_groups), 0) > 0 then ''
                        else public.uic('search.suggest_empty',
                               'No matches yet — press search to look through the full catalogue') end);
end $function$;

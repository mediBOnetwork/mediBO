-- CHANGE #790, part B2 — `search_suggest()`: the typeahead itself.
--
-- One RPC, one narrow table, no "MEDICINE" anywhere in the plan. A keystroke
-- is a prefix probe on `idx_ssc_norm_prefix`; a typo is a trigram probe on
-- `idx_ssc_norm_trgm`. Everything the app prints — the group titles, the
-- "12 variants" counter, the Hinglish note, the empty state — is a string
-- from this payload.

-- ── the copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('search.suggest_min_chars',  '"Type at least 2 letters to see suggestions"'::jsonb),
  ('search.group_brand',        '"Brands"'::jsonb),
  ('search.group_salt',         '"Salts"'::jsonb),
  ('search.group_company',      '"Companies"'::jsonb),
  ('search.group_category',     '"Categories"'::jsonb),
  ('search.count_brand_one',    '"1 variant"'::jsonb),
  ('search.count_brand_many',   '"{n} variants"'::jsonb),
  ('search.count_item_one',     '"1 product"'::jsonb),
  ('search.count_item_many',    '"{n} products"'::jsonb),
  ('search.suggest_empty',      '"No matches yet — press search to look through the full catalogue"'::jsonb),
  ('search.hinglish_note',      '"{term} → {target}"'::jsonb),
  ('search.hinglish_prefix',    '"Searching for"'::jsonb),
  ('search.zone_note',          '"Suggestions from what your zone can send"'::jsonb),
  ('search.family_variants',    '"{n} variants"'::jsonb),
  ('search.family_one',         '"1 variant"'::jsonb),
  ('search.family_by',          '"by {company}"'::jsonb)
on conflict (key) do nothing;

-- ── the counter, in one place ───────────────────────────────────────────────
create or replace function public._suggest_count_label(p_kind text, p_n integer)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when p_kind = 'brand' and coalesce(p_n, 0) = 1 then public.uic('search.count_brand_one', '1 variant')
    when p_kind = 'brand' then replace(public.uic('search.count_brand_many', '{n} variants'),
                                       '{n}', coalesce(p_n, 0)::text)
    when coalesce(p_n, 0) = 1 then public.uic('search.count_item_one', '1 product')
    else replace(public.uic('search.count_item_many', '{n} products'),
                 '{n}', coalesce(p_n, 0)::text)
  end;
$function$;

-- ── the typeahead ───────────────────────────────────────────────────────────
create or replace function public.search_suggest(p_q text, p_zone boolean default true)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
             -- the contains and trigram lanes only open at four characters:
             -- below that a prefix is already the honest answer and the
             -- trigram lane would scan half the cache for nothing
             or (length(t.term) >= 4 and s.norm like '%' || t.term || '%')
             or (length(t.term) >= 4 and s.norm % t.term) )
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

comment on function public.search_suggest(text, boolean) is
  'CHANGE #790 — typeahead. Reads search_suggest_cache only; never MEDICINE. Honours the #747 zone switch.';

grant execute on function public.search_suggest(text, boolean) to anon, authenticated;
grant execute on function public._suggest_count_label(text, integer) to anon, authenticated;

insert into public.app_settings (key, value) values
  ('search_suggest_min_chars', '2'::jsonb),
  ('search_suggest_per_group', '5'::jsonb)
on conflict (key) do nothing;

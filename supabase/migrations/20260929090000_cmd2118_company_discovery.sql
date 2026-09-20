-- CMD #2118 — Find a company in two taps.
--
-- Company discovery, MOBILE/PWA. Everything here is backend: the matcher, the
-- ranking, every label, every count string. Flutter renders the payload.
--
--  1. `storefront_company_search(q, limit)` — the Companies block that rides
--     ABOVE the medicine results in `storefront_search_page`, and the same
--     rows the "Shop by company" filter box draws. Short forms match because
--     every TOKEN of the query has to start a word of the company's name:
--     "sun pharma" -> SUN PHARMACEUTICAL…, "dr reddy" -> DR REDDYS…
--  2. `storefront_company_page(key, offset, limit, q)` — the 4-arg overload
--     adds "Search in this company". p_q has NO default on purpose: a
--     defaulted 4th argument would make every existing 3-named-arg call
--     ambiguous ("function is not unique") the moment this lands.
--
-- Idempotent: copy is upserted, functions are CREATE OR REPLACE.

-- ── Copy ──────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('storefront.companies_block_title', '"Companies"'::jsonb),
  ('storefront.company_filter_hint',   '"Filter companies"'::jsonb),
  ('storefront.company_filter_empty',  '"No company matches that."'::jsonb),
  ('storefront.company_in_hint',       '"Search in this company"'::jsonb),
  ('storefront.company_in_empty',      '"No product here matches that."'::jsonb)
on conflict (key) do nothing;

-- ── 1. The matcher ────────────────────────────────────────────────────────
-- One row per company whose name contains EVERY token of the query as the
-- start of a word. Tokens are stripped to [a-z0-9] before they are used in a
-- LIKE, so a query can never carry a wildcard into the pattern.
create or replace function public.company_match_rows(p_q text, p_limit integer)
returns table(key text, label text, n integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  with q as (select lower(btrim(coalesce(p_q, ''))) as s),
  toks as (
    select array_agg(t) as a
      from (select regexp_replace(x, '[^a-z0-9]', '', 'g') as t
              from regexp_split_to_table((select s from q), '\s+') as x) y
     where y.t <> ''
  )
  select mc.canon, mc.display, mc.buyable_count
    from public.medicine_company mc, toks
   where (select s from q) <> ''
     and coalesce(array_length(toks.a, 1), 0) > 0
     and mc.buyable_count > 0
     and (select bool_and((' ' || mc.name_norm) like ('% ' || t || '%'))
            from unnest(toks.a) as t)
   order by case when mc.name_norm like ((select s from q) || '%') then 0 else 1 end,
            mc.buyable_count desc,
            mc.display
   limit greatest(coalesce(p_limit, 8), 1);
$$;

-- ── 2. The block / the filter rows ────────────────────────────────────────
create or replace function public.storefront_company_search(p_q text, p_limit integer default 8)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'ok', true,
    'q', nullif(btrim(coalesce(p_q, '')), ''),
    'title',       public.uic('storefront.companies_block_title', 'Companies'),
    'hint',        public.uic('storefront.company_filter_hint', 'Filter companies'),
    'empty_label', public.uic('storefront.company_filter_empty', 'No company matches that.'),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', r.key,
               'label', r.label,
               'count_label', public.cat_count_label(r.n::bigint))
             order by r.rn)
        from (select m.*, row_number() over () as rn
                from public.company_match_rows(p_q, p_limit) m) r), '[]'::jsonb));
$$;

-- ── 3. The Companies block rides on the search envelope ───────────────────
create or replace function public.storefront_search_page(
  search_term text,
  category_filter text default 'All'::text,
  page_offset integer default 0,
  page_limit integer default null::integer,
  p_zone boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_size int := greatest(coalesce(nullif(page_limit,0),
                  coalesce((select (value #>> '{}')::int from public.app_settings
                              where key = 'search_initial_limit'), 30)), 1);
  v_page int := case when v_size > 0 then greatest(coalesce(page_offset,0),0) / v_size else 0 end;
  v_p    jsonb;
  v_co   jsonb;
begin
  v_p := public.search_page(search_term,
           jsonb_build_object('category', coalesce(nullif(btrim(category_filter),''),'All')),
           v_page, v_size, p_zone);

  -- CMD #2118 — the Companies block. Only on the FIRST page: it belongs above
  -- the first screen of results, not repeated every time Load more is tapped.
  if v_page = 0 then
    begin
      v_co := public.storefront_company_search(search_term, 6);
    exception when others then
      v_co := null;   -- a matcher failure must never take the results down
    end;
  end if;

  return jsonb_build_object(
    'status','ok',
    'search_term', search_term,
    'category', coalesce(nullif(btrim(category_filter),''),'All'),
    'page_offset', v_page * v_size,
    'page_limit', v_size,
    'gated', v_p->'gated',
    'result_count', v_p#>'{paging,returned}',
    'result_total', v_p->'total',
    'showing_label', v_p->>'header_label',
    'empty_label', v_p->>'empty_label',
    'initial_limit', v_size,
    'more_limit', v_size,
    'next_offset', (v_page * v_size) + coalesce((v_p#>>'{paging,returned}')::int, 0),
    'has_more', v_p#>'{paging,has_more}',
    'more_label', v_p#>>'{paging,more_label}',
    'end_label', v_p#>>'{paging,end_label}',
    'zone_switch', v_p->'zone',
    'companies', v_co,
    'items', v_p->'items');
end
$$;

-- ── 4. Search inside a company ────────────────────────────────────────────
create or replace function public.storefront_company_page(
  p_key text, p_offset integer, p_limit integer, p_q text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  c record;
  v_ids bigint[];
  v_total int;
  v_q text := nullif(btrim(coalesce(p_q, '')), '');
begin
  select display, canon, buyable_count into c
    from public.medicine_company where canon = p_key;
  if c.canon is null then
    return jsonb_build_object('ok', false, 'error', 'company_not_found');
  end if;

  select array_agg(id) into v_ids from (
    select id from "MEDICINE"
     where marketer_canonical = p_key
       and lower(coalesce(buyable::text,'')) in ('true','t')
       -- Plain substring, never a LIKE pattern: the box is a box, and a '%'
       -- typed into it is a percent sign.
       and (v_q is null or position(lower(v_q) in lower(coalesce(product_name,''))) > 0)
     order by sales_count desc nulls last, id
     offset greatest(p_offset,0) limit least(greatest(p_limit,1),50)) t;

  if v_q is null then
    v_total := coalesce(c.buyable_count, 0);
  else
    select count(*)::int into v_total from "MEDICINE"
     where marketer_canonical = p_key
       and lower(coalesce(buyable::text,'')) in ('true','t')
       and position(lower(v_q) in lower(coalesce(product_name,''))) > 0;
  end if;

  return jsonb_build_object(
    'ok', true,
    'company', jsonb_build_object('label', c.display, 'key', c.canon,
      'icon_letter', upper(left(btrim(coalesce(c.display,'?')), 1)),
      'sub_label', public.cat_count_label(v_total::bigint),
      'count_label', public.cat_count_label(v_total::bigint)),
    'back_label', public.uic('catalogue.company_back','Back'),
    'q', v_q,
    'search_hint', public.uic('storefront.company_in_hint','Search in this company'),
    'empty_label', public.uic('storefront.company_in_empty','No product here matches that.'),
    'items', public._sf_cards(coalesce(v_ids, '{}'::bigint[])),
    'offset', greatest(p_offset,0),
    'has_more', (greatest(p_offset,0) + coalesce(array_length(v_ids,1),0)) < v_total);
end
$$;

-- The 3-arg call the app used before this change keeps working, unchanged, by
-- delegating. p_q above has no default, so the two can never be ambiguous.
create or replace function public.storefront_company_page(
  p_key text, p_offset integer default 0, p_limit integer default 24)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.storefront_company_page(p_key, p_offset, p_limit, null::text);
$$;

-- ── Grants ────────────────────────────────────────────────────────────────
-- The storefront is browsable signed-out, so search and the company page are
-- anon-readable, exactly like the RPCs they extend. company_match_rows is the
-- internal row source and stays off the API.
revoke all on function public.company_match_rows(text, integer) from public, anon, authenticated;
grant execute on function public.storefront_company_search(text, integer) to anon, authenticated, service_role;
grant execute on function public.storefront_company_page(text, integer, integer, text) to anon, authenticated, service_role;
grant execute on function public.storefront_company_page(text, integer, integer) to anon, authenticated, service_role;
grant execute on function public.storefront_search_page(text, text, integer, integer, boolean) to anon, authenticated, service_role;

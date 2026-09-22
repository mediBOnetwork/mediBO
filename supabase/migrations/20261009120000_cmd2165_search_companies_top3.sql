-- CMD #2165 — Search: top 3 company matches above products.
--
-- CMD #2118 put a Companies object on `storefront_search_page` but nothing ever
-- rendered it, and its shape is a filter list (6 rows, no icon letter, no
-- explicit "is there a block?" flag). This change gives the search payload the
-- contract the Companies block actually renders from, so Dart decides nothing:
--
--   companies[]      up to 3 rows {key, label, count_label, icon_letter}
--   companies_has    boolean — false means "draw no Companies block at all"
--   companies_title  the block heading, already in the case it must print
--   companies_rpc    the RPC a tapped row opens
--   companies_style  every size / colour of the block, so a redesign is an
--                    UPDATE of one app_settings row, never a deploy
--
-- The block only exists on page 0 and only for a query of at least 3 letters
-- (both decided here, never in the client). The legacy `companies` object moves
-- to `companies_filter` so the older payload is still available unchanged.
--
-- Idempotent: CREATE OR REPLACE + an upsert of the two settings rows.

insert into public.app_settings(key, value)
values ('search_companies_min_chars', to_jsonb(3))
on conflict (key) do nothing;

insert into public.app_settings(key, value)
values ('search_companies_style', jsonb_build_object(
  'row_h', 60, 'tile', 40, 'tile_radius', 12,
  'title_size', 13, 'title_tracking', 0.8,
  'label_size', 14.5, 'count_size', 12.5,
  'gap', 12, 'pad_h', 16, 'divider', 1, 'chevron', 20,
  'tile_bg', '#E8F5EE', 'tile_fg', '#1B7A43'))
on conflict (key) do nothing;

insert into public.ui_copy(key, value)
values ('storefront.companies_block_title', to_jsonb('Companies'::text))
on conflict (key) do nothing;

create or replace function public.storefront_search_page(
  search_term text,
  category_filter text default 'All',
  page_offset integer default 0,
  page_limit integer default null,
  p_zone boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_size int := greatest(coalesce(nullif(page_limit,0),
                  coalesce((select (value #>> '{}')::int from public.app_settings
                              where key = 'search_initial_limit'), 30)), 1);
  v_page int := case when v_size > 0 then greatest(coalesce(page_offset,0),0) / v_size else 0 end;
  v_min  int := coalesce((select (value #>> '{}')::int from public.app_settings
                            where key = 'search_companies_min_chars'), 3);
  v_p    jsonb;
  v_co   jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_style jsonb;
begin
  v_p := public.search_page(search_term,
           jsonb_build_object('category', coalesce(nullif(btrim(category_filter),''),'All')),
           v_page, v_size, p_zone);

  -- CMD #2118 — the Companies block. Only on the FIRST page: it belongs above
  -- the first screen of results, not repeated every time Load more is tapped.
  -- CMD #2165 — and only once the query is long enough to mean a company.
  if v_page = 0 and length(btrim(coalesce(search_term,''))) >= v_min then
    begin
      v_co := public.storefront_company_search(search_term, 6);
    exception when others then
      v_co := null;   -- a matcher failure must never take the results down
    end;
  end if;

  -- Top 3, in the matcher's own order, each with the letter its tile shows.
  v_rows := coalesce((
    select jsonb_agg(jsonb_build_object(
             'key',         e->>'key',
             'label',       e->>'label',
             'count_label', e->>'count_label',
             'icon_letter', upper(substr(
               coalesce(nullif(regexp_replace(coalesce(e->>'label',''), '[^A-Za-z0-9]', '', 'g'), ''),
                        coalesce(e->>'label','?')), 1, 1)))
           order by t.ord)
      from jsonb_array_elements(coalesce(v_co->'rows','[]'::jsonb)) with ordinality t(e, ord)
     where t.ord <= 3), '[]'::jsonb);

  v_style := coalesce((select value from public.app_settings
                        where key = 'search_companies_style'), '{}'::jsonb);

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
    -- CMD #2165 — the Companies block, decided entirely here.
    'companies', v_rows,
    'companies_has', jsonb_array_length(v_rows) > 0,
    'companies_title', upper(public.uic('storefront.companies_block_title','Companies')),
    'companies_rpc', 'storefront_company_page',
    'companies_style', v_style,
    -- The pre-#2165 object, kept verbatim under its own key.
    'companies_filter', v_co,
    'items', v_p->'items');
end
$function$;

grant execute on function public.storefront_search_page(text, text, integer, integer, boolean)
  to anon, authenticated;

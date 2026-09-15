-- CMD #1909 — Catalogue lists: drop the zone toggle, show everything,
-- zone-available products first.
--
-- #747 shipped an "Available in my zone" switch that FILTERED. A customer in
-- Raipur asking for a therapeutic class was shown a short list and had no way
-- of knowing the catalogue held ten times as much; the empty state's own hint
-- ("Turn off 'Available in my zone'...") was the app admitting it was hiding
-- things. Om's call: never hide. Show the whole scope, ordered, with the two
-- groups named and counted by the backend.
--
-- The switch is not re-worded, it is REMOVED — `_cat_zone()` is the single
-- place every catalogue list asked "which zone am I filtering to?", so it now
-- answers "none", and tree/companies/salts/search/suggest stop filtering in
-- one edit instead of six. `catalogue_zone_switch()` reads the same helper, so
-- it reports has:false and the control (and its sentence chip) disappear from
-- every payload without a second rule.
--
-- Grouping needs the zone that filtering just gave up, so it gets its OWN
-- helper, `_cat_avail_zone()`, carrying the old gate verbatim: no facet counts
-- built for the zone means no counted divider, so the list degrades to one
-- flat page instead of printing "Available in your zone (0)".

begin;

-- ── 1. copy ────────────────────────────────────────────────────────────────
-- Wording lives here, never in Dart and never in a function body: the two
-- divider labels, their count-less twins (a filtered scope has no facet total)
-- and the reason an unavailable row's ADD is dead.
insert into public.ui_copy(key, value) values
  ('catalogue.group_in',        to_jsonb('Available in your zone ({n})'::text)),
  ('catalogue.group_out',       to_jsonb('Not available in your zone ({n})'::text)),
  ('catalogue.group_in_plain',  to_jsonb('Available in your zone'::text)),
  ('catalogue.group_out_plain', to_jsonb('Not available in your zone'::text)),
  ('catalogue.zone_block_note', to_jsonb('Not available in your zone'::text)),
  ('catalogue.zone_block_cta',  to_jsonb('Not in your zone'::text)),
  ('catalogue.list_empty_all',  to_jsonb('Nothing in the catalogue matches this yet.'::text))
on conflict (key) do nothing;

-- The hint that told people to turn off a switch that no longer exists.
update public.ui_copy set value = to_jsonb(''::text), updated_at = now()
 where key = 'catalogue.empty_zone_hint';

-- ── 2. the zone filter is gone ─────────────────────────────────────────────
-- Deliberately kept as a function returning NULL rather than deleted: it has
-- five callers (catalogue_list, catalogue_zone_switch, _cat_count_zone,
-- search_medicines_priority, search_suggest) and every one of them already
-- means "no zone filter" by NULL. Rewriting the 300-line search ranker to
-- delete one predicate would be the risk, not the fix.
create or replace function public._cat_zone(p_on boolean default true)
returns smallint
language sql
stable security definer
set search_path to 'public'
as $$
  -- CMD #1909: catalogue lists never filter by zone again. NULL here is
  -- "whole catalogue" to every caller, and it makes _cat_count_zone() answer
  -- 0, which is the all-zones row in catalogue_facet_count.
  select null::smallint;
$$;

-- ── 3. the zone we GROUP by ────────────────────────────────────────────────
create or replace function public._cat_avail_zone()
returns smallint
language sql
stable security definer
set search_path to 'public'
as $$
  -- The old _cat_zone(true) body, unchanged. The facet-count gate is what
  -- keeps a zone whose counts have never been built out of the grouped path:
  -- without it the divider would print a count of 0 beside a full list.
  select z.zid from (select public._viewer_zone_or_null() as zid) z
   where z.zid is not null
     and exists (select 1 from public.catalogue_facet_count c
                  where c.zone_id = z.zid and c.facet = 'meta');
$$;
revoke all on function public._cat_avail_zone() from public;

-- ── 4. the divider label ───────────────────────────────────────────────────
create or replace function public.cat_group_label(p_key text, p_n bigint)
returns text
language sql
stable security definer
set search_path to 'public'
as $$
  -- One label, two shapes: with a count when the facet totals know it, without
  -- when a filter is on and there is no honest number to print. The app never
  -- sees the difference — it prints whichever string arrived.
  select case
    when p_n is null and p_key = 'in'  then public.uic('catalogue.group_in_plain',  'Available in your zone')
    when p_n is null                   then public.uic('catalogue.group_out_plain', 'Not available in your zone')
    when p_key = 'in' then replace(public.uic('catalogue.group_in',
                             'Available in your zone ({n})'), '{n}', to_char(p_n,'FM9,99,99,999'))
    else                   replace(public.uic('catalogue.group_out',
                             'Not available in your zone ({n})'), '{n}', to_char(p_n,'FM9,99,99,999'))
  end;
$$;
revoke all on function public.cat_group_label(text, bigint) from public;

-- ── 5. the cards, with the group on them ───────────────────────────────────
-- _cat_cards() stays exactly what it was (other callers read it); the group,
-- the divider and the dead ADD are laid over it here, so there is one place
-- that knows what "out of zone" looks like on a card.
create or replace function public._cat_group_cards(
  p_ids   bigint[],
  p_grps  smallint[],
  p_zone  smallint,
  p_prev  smallint,      -- group the PREVIOUS page ended on; null on page one
  p_lbl_in  text,
  p_lbl_out text)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(
    case when p_zone is null or p_grps[c.ord] = 0 then c.val
         else c.val || jsonb_build_object('availability',
                coalesce(c.val->'availability','{}'::jsonb) || jsonb_build_object(
                  'is_available', false,
                  'can_add', false,
                  'blocked_by', 'not_in_zone',
                  'cta_label', public.uic('catalogue.zone_block_note','Not available in your zone'),
                  'note',      public.uic('catalogue.zone_block_note','Not available in your zone'),
                  'cta_short', public.uic('catalogue.zone_block_cta','Not in your zone'),
                  'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF')))
    end
    || jsonb_build_object(
         'group', case when p_zone is null then ''
                       when p_grps[c.ord] = 0 then 'in' else 'out' end,
         -- The divider is a property of the ROW that opens a group, so paging
         -- cannot lose it and cannot repeat it: page two of the same group
         -- opens with p_prev equal to its own group and prints nothing.
         'divider_label', case
            when p_zone is null then ''
            when c.ord = 1 and p_prev is distinct from p_grps[1]
              then case when p_grps[1] = 0 then p_lbl_in else p_lbl_out end
            when c.ord > 1 and p_grps[c.ord] is distinct from p_grps[c.ord - 1]
              then case when p_grps[c.ord] = 0 then p_lbl_in else p_lbl_out end
            else '' end)
    order by c.ord), '[]'::jsonb)
  from jsonb_array_elements(public._cat_cards(p_ids)) with ordinality c(val, ord);
$$;
revoke all on function public._cat_group_cards(bigint[], smallint[], smallint, smallint, text, text) from public;

-- ── 5a. one keyset page of ids ─────────────────────────────────────────────
-- The dynamic half of the list, pulled out so the two groups are provably the
-- SAME query with one predicate swapped. Internal: it takes a raw WHERE
-- fragment, so it is never granted to a client role — `_cat_where()` is the
-- only thing that builds one and catalogue_list() reaches it as definer.
create or replace function public._cat_page_ids(
  p_where  text,
  p_sort   text,
  p_cursor jsonb,
  p_zone   smallint,   -- null → no grouping, scan the scope as it stands
  p_grp    smallint,   -- 0 = available in p_zone, 1 = the rest
  p_limit  int)
returns bigint[]
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_join text := '';
  v_extra text := '';
  v_keyset text := '';
  v_order text;
  v_sql text;
  v_ids bigint[];
begin
  if coalesce(p_limit,0) < 1 then return '{}'::bigint[]; end if;

  if p_zone is not null and p_grp = 0 then
    v_join := format('join public.catalogue_zone_avail za '
                     || 'on za.product_id = m.id and za.zone_id = %L::smallint', p_zone);
  elsif p_zone is not null then
    -- The anti-join probes catalogue_zone_avail's (zone_id, product_id)
    -- primary key once per candidate row, so group 1 costs the same walk as
    -- group 0 plus an index lookup — not a sort of the scope.
    v_extra := format(' and not exists (select 1 from public.catalogue_zone_avail za '
                      || 'where za.product_id = m.id and za.zone_id = %L::smallint)', p_zone);
  end if;

  if p_sort = 'newest' then
    v_order := 'order by m.id desc';
    if p_cursor ? 'i' then v_keyset := format(' and m.id < %L::bigint', p_cursor->>'i'); end if;
  else
    v_order := 'order by m.product_name, m.id';
    if p_cursor ? 'i' then
      v_keyset := format(' and (m.product_name, m.id) > (%L, %L::bigint)',
                         coalesce(p_cursor->>'n',''), p_cursor->>'i');
    end if;
  end if;

  v_sql := format(
    'select array_agg(t.id order by t.ord) from ('
    || 'select s.id, row_number() over () as ord from ('
    || 'select m.id, m.product_name from public."MEDICINE" m %s where %s%s%s %s limit %s'
    || ') s) t', v_join, p_where, v_extra, v_keyset, v_order, p_limit);
  execute v_sql into v_ids;
  return coalesce(v_ids, '{}'::bigint[]);
end $$;
revoke all on function public._cat_page_ids(text, text, jsonb, smallint, smallint, int) from public;

-- ── 6. the list ────────────────────────────────────────────────────────────
create or replace function public.catalogue_list(
  p_kind    text    default 'tree',
  p_key     text    default null,
  p_path    text[]  default '{}'::text[],
  p_filters jsonb   default '{}'::jsonb,
  p_sort    text    default 'name',
  p_zone    boolean default true,   -- CMD #1909: accepted and IGNORED (see below)
  p_cursor  text    default null,
  p_limit   integer default 24)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
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
  v_empty := case
    when v_filtered then public.uic('catalogue.list_empty_filtered',
                       'Nothing matches these filters. Clear one and try again.')
    else public.uic('catalogue.list_empty','Nothing here in this view.') end;

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
      'hint', '',
      'action', jsonb_build_object(
        'has',  not v_filtered
                and coalesce((select request_open from public.catalogue_extras_config where id = 1), true),
        'kind', 'request',
        'label', public.uic('catalogue.empty_action','Request this product')),
      'clear', jsonb_build_object(
        'has', v_filtered,
        'kind','clear_filters',
        'label', public.uic('catalogue.filters_clear','Clear all'))),
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

-- ── 7. one reason, everywhere ──────────────────────────────────────────────
-- A card in the list now says "Not available in your zone". The PRODUCT PAGE
-- for the same pack said "No supplier for this product right now", because
-- storefront_cta() has one unavailable branch and it was worded before zones
-- were the rule. Two sentences for one fact is how a buyer decides the app is
-- guessing. The verdict itself is untouched — this is the copy, and only for a
-- viewer who actually HAS a zone; a signed-out visitor keeps their own line.
insert into public.ui_copy(key, value) values
  ('storefront.not_in_zone_note', to_jsonb('Not available in your zone'::text))
on conflict (key) do nothing;

create or replace function public.storefront_cta(p_supplier_count integer, p_resolved boolean default true)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $$
  -- CMD #1812 — there is exactly ONE availability rule and it is the zone's
  -- standby count. 1mg's scraped `status` used to open a third branch here
  -- ("Not for sale", red) on a product a supplier in the zone could send; that
  -- branch, its parameter and its copy keys are gone.
  select case
    when not coalesce(p_resolved, true) then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'unresolved', true,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    when coalesce(p_supplier_count, 0) >= 1 then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    else
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label','Unavailable','gated', public.viewer_is_approved_customer(),
        'blocked_by', 'no_supplier',
        'note', case when auth.uid() is null
                     then public.uic('storefront.signed_out_note',
                                     'Sign in to see availability in your area.')
                     -- CMD #1909 — the buyer has a zone, so name it.
                     when public._viewer_zone_or_null() is not null
                     then public.uic('storefront.not_in_zone_note',
                                     'Not available in your zone')
                     else public.uic('storefront.no_supplier_note',
                                     'No supplier for this product right now') end,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='stock_out_label'), 'Out of stock'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  end;
$$;

commit;

-- CMD #1953 — STEP 1: the hand-seeded bucket list becomes `use_bucket`.
--
-- #1910 called its 46-row vocabulary `condition` and its mapping
-- `condition_medicine`. #1953 takes the name `condition` for the thing that
-- actually holds a product's uses — a text[] column on MEDICINE — so the
-- hand-curated bucket list is renamed out of the way FIRST and every reader
-- is re-created against the new name in the same file.
--
-- Nothing is dropped, nothing is re-seeded: the rows, the grants, the RLS
-- policies and the indexes all travel with the table. The UI label for the
-- page is still whatever ui_copy says — this file changes no copy.
--
-- Idempotent: the rename runs only while the old name still exists, and every
-- function below is CREATE OR REPLACE.

do $$
begin
  if to_regclass('public.condition') is not null
     and to_regclass('public.use_bucket') is null then
    alter table public.condition rename to use_bucket;
  end if;
  if to_regclass('public.condition_medicine') is not null
     and to_regclass('public.use_bucket_medicine') is null then
    alter table public.condition_medicine rename to use_bucket_medicine;
  end if;
end $$;

-- The sequence/identity, indexes and policies keep their old names on purpose:
-- renaming them changes nothing a reader can see and every extra rename is one
-- more thing a replay can trip over.

CREATE OR REPLACE FUNCTION public.admin_condition_get(p_key text, p_q text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cz smallint := coalesce(public.admin_active_zone(), 0::smallint);
  v_c  public.use_bucket%rowtype;
  v_n  int := least(greatest(coalesce(p_limit,30),1),100);
  v_off int := greatest(coalesce(p_offset,0),0);
  v_q  text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb; v_total bigint;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  select * into v_c from public.use_bucket where condition_key = btrim(coalesce(p_key,''));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'danger',
      'message', public.uic('condition.not_found','That use no longer exists.'));
  end if;

  select count(*) into v_total
    from public.use_bucket_medicine cm
    join public."MEDICINE" m on m.id = cm.medicine_id
   where cm.condition_id = v_c.id
     and (v_q is null or lower(m.product_name) like '%'||lower(v_q)||'%');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id,
           'label', m.product_name,
           'sub_label', concat_ws(' · ', nullif(btrim(coalesce(m.marketer_canonical,'')),''),
                                          nullif(btrim(coalesce(m.salt_composition,'')),'')),
           'source', cm.source,
           'source_label', case when cm.source = 'admin'
                                then public.uic('condition.src_admin','Added by admin')
                                else public.uic('condition.src_seed','From the first seed') end,
           'remove_label', public.uic('condition.remove','Remove'))
           order by m.product_name), '[]'::jsonb) into v_rows
    from (
      select cm.*, m.product_name, m.marketer_canonical, m.salt_composition, m.id as mid
        from public.use_bucket_medicine cm
        join public."MEDICINE" m on m.id = cm.medicine_id
       where cm.condition_id = v_c.id
         and (v_q is null or lower(m.product_name) like '%'||lower(v_q)||'%')
       order by m.product_name
       offset v_off limit v_n
    ) x
    join public."MEDICINE" m on m.id = x.mid
    join public.use_bucket_medicine cm on cm.condition_id = v_c.id and cm.medicine_id = x.mid;

  return jsonb_build_object(
    'ok', true,
    'key', v_c.condition_key,
    'label', v_c.label,
    'synonyms', to_jsonb(v_c.synonyms),
    'sort_order', v_c.sort_order,
    'is_active', v_c.is_active,
    'scope', public._cond_scope(),
    'label_field', public.uic('condition.field_label','Name a shopper reads'),
    'synonyms_field', public.uic('condition.field_synonyms','Other words they search (comma separated)'),
    'sort_field', public.uic('condition.field_sort','Order in the list'),
    'active_field', public.uic('condition.field_active','Show in Browse by'),
    'products_title', public.uic('condition.products_title','Products under this use'),
    'products_hint', public.uic('condition.products_hint','Search the catalogue to add one.'),
    'search_hint', public.uic('condition.products_search_hint','Search products in this use'),
    'add_hint', public.uic('condition.add_product_hint','Search a product name to add'),
    'save_label', public.uic('condition.save','Save'),
    'saved_label', public.uic('condition.saved','Saved — live now.'),
    'empty_label', public.uic('condition.products_empty','No product under this use yet.'),
    'count_label', public.cat_count_label(coalesce((select f.n from public.catalogue_facet_count f
                      where f.facet='condition' and f.zone_id=v_cz and f.facet_key=v_c.condition_key),0)),
    'total', v_total,
    'offset', v_off,
    'next_offset', v_off + jsonb_array_length(v_rows),
    'has_more', v_off + jsonb_array_length(v_rows) < v_total,
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', v_rows);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_condition_map(p_key text, p_product_id bigint, p_on boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id bigint; v_key text := btrim(coalesce(p_key,''));
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  select id into v_id from public.use_bucket where condition_key = v_key;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'danger',
      'message', public.uic('condition.not_found','That use no longer exists.'));
  end if;
  if not exists (select 1 from public."MEDICINE" m where m.id = p_product_id) then
    return jsonb_build_object('ok', false, 'error', 'no_product', 'tone', 'danger',
      'message', public.uic('condition.no_product','That product is not in the catalogue.'));
  end if;

  if coalesce(p_on, true) then
    insert into public.use_bucket_medicine (condition_id, medicine_id, source, created_by)
    values (v_id, p_product_id, 'admin', lower(btrim(coalesce(auth.jwt() ->> 'email',''))))
    on conflict (condition_id, medicine_id) do nothing;
  else
    delete from public.use_bucket_medicine
     where condition_id = v_id and medicine_id = p_product_id;
  end if;

  perform public.condition_counts_refresh(v_key);

  return jsonb_build_object('ok', true, 'on', coalesce(p_on, true), 'tone', 'success',
    'message', case when coalesce(p_on, true)
                    then public.uic('condition.added','Added — live now.')
                    else public.uic('condition.removed','Removed — live now.') end);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_condition_product_search(p_key text, p_q text, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id bigint; v_n int := least(greatest(coalesce(p_limit,20),1),50);
  v_q text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  select id into v_id from public.use_bucket where condition_key = btrim(coalesce(p_key,''));
  if v_q is null or length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb,
      'hint', public.uic('condition.search_min','Type at least 2 letters.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id,
           'label', t.product_name,
           'sub_label', concat_ws(' · ', nullif(btrim(coalesce(t.marketer_canonical,'')),''),
                                         nullif(btrim(coalesce(t.salt_composition,'')),'')),
           'already', t.already,
           'action_label', case when t.already then public.uic('condition.already','Already added')
                                else public.uic('condition.add_product','Add') end)
           order by t.already, t.product_name), '[]'::jsonb) into v_rows
    from (
      select m.id, m.product_name, m.marketer_canonical, m.salt_composition,
             exists (select 1 from public.use_bucket_medicine cm
                      where cm.condition_id = v_id and cm.medicine_id = m.id) as already
        from public."MEDICINE" m
       where public._norm_name(m.product_name) like public._norm_name(v_q) || '%'
       order by m.sales_count desc nulls last, m.product_name
       limit v_n
    ) t;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'hint', '');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_condition_reseed(p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text := btrim(coalesce(p_key,'')); v_res jsonb;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  if not exists (select 1 from public.use_bucket where condition_key = v_key) then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'danger',
      'message', public.uic('condition.not_found','That use no longer exists.'));
  end if;
  v_res := public.condition_seed_run(array[v_key]);
  perform public.condition_counts_refresh(v_key);
  return jsonb_build_object('ok', true, 'tone', 'success', 'mapped', v_res->'mapped',
    'message', public.uic('condition.reseeded','Re-read from the catalogue — live now.'));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_condition_save(p_key text, p_label text, p_synonyms text[] DEFAULT NULL::text[], p_sort_order integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_key text := lower(regexp_replace(btrim(coalesce(p_key,'')), '[^a-zA-Z0-9]+', '-', 'g'));
  v_label text := nullif(btrim(coalesce(p_label,'')),'');
  v_syn text[] := coalesce((select array_agg(distinct lower(btrim(s)))
                              from unnest(coalesce(p_synonyms,'{}'::text[])) s
                             where nullif(btrim(s),'') is not null), '{}'::text[]);
  v_new boolean;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  v_key := trim(both '-' from v_key);
  if v_key = '' then
    return jsonb_build_object('ok', false, 'error', 'need_key', 'tone', 'danger',
      'message', public.uic('condition.need_key','A use needs a short key.'));
  end if;
  if v_label is null then
    return jsonb_build_object('ok', false, 'error', 'need_label', 'tone', 'danger',
      'message', public.uic('condition.need_label','A use needs the name a shopper reads.'));
  end if;

  v_new := not exists (select 1 from public.use_bucket where condition_key = v_key);
  insert into public.use_bucket (condition_key, label, synonyms, sort_order, is_active, updated_by)
  values (v_key, v_label, v_syn,
          coalesce(p_sort_order, 100), coalesce(p_is_active, true),
          lower(btrim(coalesce(auth.jwt() ->> 'email',''))))
  on conflict (condition_key) do update
    set label = excluded.label,
        synonyms = excluded.synonyms,
        sort_order = coalesce(p_sort_order, public.use_bucket.sort_order),
        is_active = coalesce(p_is_active, public.use_bucket.is_active),
        updated_at = now(),
        updated_by = excluded.updated_by;

  perform public.condition_counts_refresh(v_key);

  return jsonb_build_object('ok', true, 'key', v_key, 'created', v_new, 'tone', 'success',
    'message', public.uic('condition.saved','Saved — live now.'));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_conditions_list(p_q text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cz smallint := coalesce(public.admin_active_zone(), 0::smallint);
  v_n  int := least(greatest(coalesce(p_limit,50),1),200);
  v_off int := greatest(coalesce(p_offset,0),0);
  v_q  text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb; v_total bigint;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;

  select count(*) into v_total
    from public.use_bucket c
   where v_q is null or lower(c.label) like '%'||lower(v_q)||'%'
      or lower(c.condition_key) like '%'||lower(v_q)||'%'
      or exists (select 1 from unnest(c.synonyms) s where lower(s) like '%'||lower(v_q)||'%');

  select coalesce(jsonb_agg(r order by r_sort, r_label), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'key', c.condition_key,
               'label', c.label,
               'synonyms', to_jsonb(c.synonyms),
               'synonyms_label', case when coalesce(array_length(c.synonyms,1),0) = 0
                                      then public.uic('condition.no_synonyms','No other words yet')
                                      else array_to_string(c.synonyms, ', ') end,
               'sort_order', c.sort_order,
               'is_active', c.is_active,
               'status_label', case when c.is_active then public.uic('condition.active','Live')
                                    else public.uic('condition.hidden','Hidden') end,
               'status_tone', case when c.is_active then 'success' else 'muted' end,
               'count', coalesce(f.n, 0),
               'count_label', public.cat_count_label(coalesce(f.n, 0)),
               'seeded', c.seeded_at is not null) as r,
             c.sort_order as r_sort, c.label as r_label
        from public.use_bucket c
        left join public.catalogue_facet_count f
               on f.facet = 'condition' and f.zone_id = v_cz and f.facet_key = c.condition_key
       where v_q is null or lower(c.label) like '%'||lower(v_q)||'%'
          or lower(c.condition_key) like '%'||lower(v_q)||'%'
          or exists (select 1 from unnest(c.synonyms) s where lower(s) like '%'||lower(v_q)||'%')
       order by c.sort_order, c.label
       offset v_off limit v_n
    ) t;

  return jsonb_build_object(
    'ok', true,
    'title', public.uic('condition.admin_title','Uses & conditions'),
    'subtitle', public.uic('condition.admin_subtitle',
                  'The fourth door in Browse by. A shopper searches these words.'),
    'scope', public._cond_scope(),
    'search_hint', public.uic('condition.admin_search_hint','Search a use'),
    'add_label', public.uic('condition.add','New use'),
    'empty_label', public.uic('condition.admin_empty','No use matches this search.'),
    'count_label', to_char(v_total,'FM9,99,99,999') || ' '
                   || case when v_total = 1 then public.uic('catalogue.condition_word','use')
                           else public.uic('catalogue.conditions_word','uses') end,
    'total', v_total,
    'offset', v_off,
    'next_offset', v_off + jsonb_array_length(v_rows),
    'has_more', v_off + jsonb_array_length(v_rows) < v_total,
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', v_rows);
end $function$
;

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

CREATE OR REPLACE FUNCTION public.condition_counts_refresh(p_key text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows bigint := 0; v_step bigint; z record;
begin
  -- zone 0 is the whole catalogue; a real zone joins the materialised
  -- availability list, exactly as catalogue_cache_tick does for every other
  -- facet. Same shape, so the two can never disagree.
  delete from public.catalogue_facet_count
   where facet = 'condition'
     and (p_key is null or facet_key = p_key);

  insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
  select 'condition', 0::smallint, '', c.condition_key, c.label,
         case when upper(left(c.label,1)) between 'A' and 'Z'
              then upper(left(c.label,1)) else '#' end,
         count(distinct m.id)
    from public.use_bucket c
    join public.use_bucket_medicine cm on cm.condition_id = c.id
    join public."MEDICINE" m on m.id = cm.medicine_id
   where c.is_active and (p_key is null or c.condition_key = p_key)
   group by c.condition_key, c.label
  having count(distinct m.id) > 0;
  get diagnostics v_rows = row_count;

  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
    select 'condition', z.id, '', c.condition_key, c.label,
           case when upper(left(c.label,1)) between 'A' and 'Z'
                then upper(left(c.label,1)) else '#' end,
           count(distinct m.id)
      from public.use_bucket c
      join public.use_bucket_medicine cm on cm.condition_id = c.id
      join public."MEDICINE" m on m.id = cm.medicine_id
      join public.catalogue_zone_avail za on za.product_id = m.id and za.zone_id = z.id
     where c.is_active and (p_key is null or c.condition_key = p_key)
     group by c.condition_key, c.label
    having count(distinct m.id) > 0;
    get diagnostics v_step = row_count;
    v_rows := v_rows + v_step;
  end loop;

  -- The door's own number, per zone. It counts DISTINCT products, so a product
  -- under both Fever and Pain is one product on the tile.
  delete from public.catalogue_facet_count
   where facet = 'meta' and facet_key in ('conditions','condition_products');
  insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
  select 'meta', f.zone_id, '', 'conditions', 'conditions', '', count(*)
    from public.catalogue_facet_count f where f.facet = 'condition'
   group by f.zone_id;
  insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
  select 'meta', 0::smallint, '', 'condition_products', 'condition_products', '',
         count(distinct cm.medicine_id)
    from public.use_bucket_medicine cm
    join public.use_bucket c on c.id = cm.condition_id and c.is_active;
  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
    select 'meta', z.id, '', 'condition_products', 'condition_products', '',
           count(distinct cm.medicine_id)
      from public.use_bucket_medicine cm
      join public.use_bucket c on c.id = cm.condition_id and c.is_active
      join public.catalogue_zone_avail za on za.product_id = cm.medicine_id and za.zone_id = z.id;
  end loop;

  perform public.search_suggest_conditions_rebuild();
  return v_rows;
end $function$
;

CREATE OR REPLACE FUNCTION public.condition_seed_run(p_keys text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ins   bigint := 0;
  v_step  bigint;
  v_conds int    := 0;
  f       text;
begin
  -- A generous budget, set locally: the pass is one-time and it scans MEDICINE
  -- four times. The default role timeout is what turns a 90-second seed into a
  -- failed migration on a catalogue this size.
  set local statement_timeout = '900s';

  -- Dropped first, not just ON COMMIT DROP: a second call inside the SAME
  -- transaction (an admin re-seed, a test) would otherwise hit a temp table
  -- that already exists.
  drop table if exists _cs_target;
  drop table if exists _cs_val;

  create temp table _cs_target on commit drop as
    select c.id, c.condition_key
      from public.use_bucket c
     where case when p_keys is null then c.seeded_at is null
                else c.condition_key = any(p_keys) end;
  select count(*) into v_conds from _cs_target;
  if v_conds = 0 then
    return jsonb_build_object('ok', true, 'conditions', 0, 'mapped', 0);
  end if;

  create temp table _cs_val on commit drop as
  with vals as (
    select 'therapeutic_class'::text as field, m.therapeutic_class as value
      from public."MEDICINE" m where nullif(btrim(m.therapeutic_class),'') is not null
    union
    select 'chemical_class', m.chemical_class
      from public."MEDICINE" m where nullif(btrim(m.chemical_class),'') is not null
    union
    select 'action_class', m.action_class
      from public."MEDICINE" m where nullif(btrim(m.action_class),'') is not null
    union
    select 'salt_composition', m.salt_composition
      from public."MEDICINE" m where nullif(btrim(m.salt_composition),'') is not null
  )
  select distinct t.id as condition_id, v.field, v.value
    from vals v
    join public.condition_seed_rule r on r.field = v.field and v.value ilike r.pattern
    join _cs_target t on t.condition_key = r.condition_key;

  create index on _cs_val (field, value);

  foreach f in array array['therapeutic_class','chemical_class','action_class','salt_composition'] loop
    execute format($q$
      insert into public.use_bucket_medicine (condition_id, medicine_id, source)
      select distinct v.condition_id, m.id, 'seed'
        from public."MEDICINE" m
        join _cs_val v on v.field = %1$L and v.value = m.%2$I
       where m.id is not null
      on conflict do nothing
    $q$, f, f);
    get diagnostics v_step = row_count;
    v_ins := v_ins + v_step;
  end loop;

  update public.use_bucket c
     set seeded_at = now()
    from _cs_target t
   where t.id = c.id;

  return jsonb_build_object('ok', true, 'conditions', v_conds, 'mapped', v_ins);
end $function$
;


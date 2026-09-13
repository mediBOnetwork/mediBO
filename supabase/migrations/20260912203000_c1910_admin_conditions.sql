-- CMD #1910 — the admin screen behind the Use door.
--
-- The seed put a first mapping in place ONCE. From here the vocabulary is the
-- admin's: the label a shopper reads, the words they search with, and which
-- products actually sit under a use. Nothing in this file is ever recomputed
-- from MEDICINE behind the admin's back — `condition.seeded_at` closes the
-- seed for good, and a re-seed is an explicit button with its own reason.
--
-- Every write ends by refreshing exactly what the shopper sees: the facet
-- counts for that condition in every zone, and its typeahead row. That is what
-- "changes are live" means here — no cron, no wait.

-- ── the one refresher ─────────────────────────────────────────────────────
create or replace function public.condition_counts_refresh(p_key text default null)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $fn$
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
    from public.condition c
    join public.condition_medicine cm on cm.condition_id = c.id
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
      from public.condition c
      join public.condition_medicine cm on cm.condition_id = c.id
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
    from public.condition_medicine cm
    join public.condition c on c.id = cm.condition_id and c.is_active;
  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
    select 'meta', z.id, '', 'condition_products', 'condition_products', '',
           count(distinct cm.medicine_id)
      from public.condition_medicine cm
      join public.condition c on c.id = cm.condition_id and c.is_active
      join public.catalogue_zone_avail za on za.product_id = cm.medicine_id and za.zone_id = z.id;
  end loop;

  perform public.search_suggest_conditions_rebuild();
  return v_rows;
end $fn$;

revoke all on function public.condition_counts_refresh(text) from public, anon, authenticated;

-- ── the guard, once ───────────────────────────────────────────────────────
create or replace function public._cond_admin_ok()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$ select coalesce(public.get_my_role(),'none') in ('admin','super_admin') $fn$;

create or replace function public._cond_denied()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object('ok', false, 'error', 'denied', 'tone', 'danger',
    'message', public.uic('condition.denied','Only an admin can edit uses.'));
$fn$;

-- The scope line every admin condition payload carries: the zone and the date
-- the header picker is showing. Counts below are read for THAT zone.
create or replace function public._cond_scope()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'zone_id', public.admin_active_zone(),
    'count_zone', coalesce(public.admin_active_zone(), 0::smallint),
    'label', replace(replace(
        public.uic('condition.scope','{zone} · {date}'),
        '{zone}', coalesce((select z.name from public.zones z where z.id = public.admin_active_zone()),
                           public.uic('condition.scope_all_zones','All zones'))),
        '{date}', to_char(public.admin_active_date(), 'DD Mon YYYY')));
$fn$;

-- ── list ──────────────────────────────────────────────────────────────────
create or replace function public.admin_conditions_list(
  p_q text default null, p_offset integer default 0, p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_cz smallint := coalesce(public.admin_active_zone(), 0::smallint);
  v_n  int := least(greatest(coalesce(p_limit,50),1),200);
  v_off int := greatest(coalesce(p_offset,0),0);
  v_q  text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb; v_total bigint;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;

  select count(*) into v_total
    from public.condition c
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
        from public.condition c
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
end $fn$;

-- ── one condition, with its products ──────────────────────────────────────
create or replace function public.admin_condition_get(
  p_key text, p_q text default null, p_offset integer default 0, p_limit integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_cz smallint := coalesce(public.admin_active_zone(), 0::smallint);
  v_c  public.condition%rowtype;
  v_n  int := least(greatest(coalesce(p_limit,30),1),100);
  v_off int := greatest(coalesce(p_offset,0),0);
  v_q  text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb; v_total bigint;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  select * into v_c from public.condition where condition_key = btrim(coalesce(p_key,''));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'danger',
      'message', public.uic('condition.not_found','That use no longer exists.'));
  end if;

  select count(*) into v_total
    from public.condition_medicine cm
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
        from public.condition_medicine cm
        join public."MEDICINE" m on m.id = cm.medicine_id
       where cm.condition_id = v_c.id
         and (v_q is null or lower(m.product_name) like '%'||lower(v_q)||'%')
       order by m.product_name
       offset v_off limit v_n
    ) x
    join public."MEDICINE" m on m.id = x.mid
    join public.condition_medicine cm on cm.condition_id = v_c.id and cm.medicine_id = x.mid;

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
end $fn$;

-- ── save the words ────────────────────────────────────────────────────────
create or replace function public.admin_condition_save(
  p_key text, p_label text, p_synonyms text[] default null,
  p_sort_order integer default null, p_is_active boolean default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
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

  v_new := not exists (select 1 from public.condition where condition_key = v_key);
  insert into public.condition (condition_key, label, synonyms, sort_order, is_active, updated_by)
  values (v_key, v_label, v_syn,
          coalesce(p_sort_order, 100), coalesce(p_is_active, true),
          lower(btrim(coalesce(auth.jwt() ->> 'email',''))))
  on conflict (condition_key) do update
    set label = excluded.label,
        synonyms = excluded.synonyms,
        sort_order = coalesce(p_sort_order, public.condition.sort_order),
        is_active = coalesce(p_is_active, public.condition.is_active),
        updated_at = now(),
        updated_by = excluded.updated_by;

  perform public.condition_counts_refresh(v_key);

  return jsonb_build_object('ok', true, 'key', v_key, 'created', v_new, 'tone', 'success',
    'message', public.uic('condition.saved','Saved — live now.'));
end $fn$;

-- ── add or remove one product ─────────────────────────────────────────────
create or replace function public.admin_condition_map(
  p_key text, p_product_id bigint, p_on boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_id bigint; v_key text := btrim(coalesce(p_key,''));
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  select id into v_id from public.condition where condition_key = v_key;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'danger',
      'message', public.uic('condition.not_found','That use no longer exists.'));
  end if;
  if not exists (select 1 from public."MEDICINE" m where m.id = p_product_id) then
    return jsonb_build_object('ok', false, 'error', 'no_product', 'tone', 'danger',
      'message', public.uic('condition.no_product','That product is not in the catalogue.'));
  end if;

  if coalesce(p_on, true) then
    insert into public.condition_medicine (condition_id, medicine_id, source, created_by)
    values (v_id, p_product_id, 'admin', lower(btrim(coalesce(auth.jwt() ->> 'email',''))))
    on conflict (condition_id, medicine_id) do nothing;
  else
    delete from public.condition_medicine
     where condition_id = v_id and medicine_id = p_product_id;
  end if;

  perform public.condition_counts_refresh(v_key);

  return jsonb_build_object('ok', true, 'on', coalesce(p_on, true), 'tone', 'success',
    'message', case when coalesce(p_on, true)
                    then public.uic('condition.added','Added — live now.')
                    else public.uic('condition.removed','Removed — live now.') end);
end $fn$;

-- ── find a product to add ─────────────────────────────────────────────────
create or replace function public.admin_condition_product_search(
  p_key text, p_q text, p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_id bigint; v_n int := least(greatest(coalesce(p_limit,20),1),50);
  v_q text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  select id into v_id from public.condition where condition_key = btrim(coalesce(p_key,''));
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
             exists (select 1 from public.condition_medicine cm
                      where cm.condition_id = v_id and cm.medicine_id = m.id) as already
        from public."MEDICINE" m
       where public._norm_name(m.product_name) like public._norm_name(v_q) || '%'
       order by m.sales_count desc nulls last, m.product_name
       limit v_n
    ) t;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'hint', '');
end $fn$;

-- ── re-seed one condition, deliberately ───────────────────────────────────
-- The ONLY way the rule map ever touches a condition again, and it is a person
-- pressing it. It clears `seeded_at` first so condition_seed_run() treats the
-- condition as unseeded, and it never deletes an admin's own rows.
create or replace function public.admin_condition_reseed(p_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_key text := btrim(coalesce(p_key,'')); v_res jsonb;
begin
  if not public._cond_admin_ok() then return public._cond_denied(); end if;
  if not exists (select 1 from public.condition where condition_key = v_key) then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'danger',
      'message', public.uic('condition.not_found','That use no longer exists.'));
  end if;
  v_res := public.condition_seed_run(array[v_key]);
  perform public.condition_counts_refresh(v_key);
  return jsonb_build_object('ok', true, 'tone', 'success', 'mapped', v_res->'mapped',
    'message', public.uic('condition.reseeded','Re-read from the catalogue — live now.'));
end $fn$;

-- ── grants: admin surface, authenticated only ─────────────────────────────
revoke all on function public.admin_conditions_list(text, integer, integer) from public, anon;
revoke all on function public.admin_condition_get(text, text, integer, integer) from public, anon;
revoke all on function public.admin_condition_save(text, text, text[], integer, boolean) from public, anon;
revoke all on function public.admin_condition_map(text, bigint, boolean) from public, anon;
revoke all on function public.admin_condition_product_search(text, text, integer) from public, anon;
revoke all on function public.admin_condition_reseed(text) from public, anon;
grant execute on function public.admin_conditions_list(text, integer, integer) to authenticated, service_role;
grant execute on function public.admin_condition_get(text, text, integer, integer) to authenticated, service_role;
grant execute on function public.admin_condition_save(text, text, text[], integer, boolean) to authenticated, service_role;
grant execute on function public.admin_condition_map(text, bigint, boolean) to authenticated, service_role;
grant execute on function public.admin_condition_product_search(text, text, integer) to authenticated, service_role;
grant execute on function public.admin_condition_reseed(text) to authenticated, service_role;

insert into public.ui_copy (key, value) values
  ('condition.admin_title',        to_jsonb('Uses & conditions'::text)),
  ('condition.admin_subtitle',     to_jsonb('The fourth door in Browse by. A shopper searches these words.'::text)),
  ('condition.admin_search_hint',  to_jsonb('Search a use'::text)),
  ('condition.admin_empty',        to_jsonb('No use matches this search.'::text)),
  ('condition.denied',             to_jsonb('Only an admin can edit uses.'::text)),
  ('condition.not_found',          to_jsonb('That use no longer exists.'::text)),
  ('condition.no_product',         to_jsonb('That product is not in the catalogue.'::text)),
  ('condition.need_key',           to_jsonb('A use needs a short key.'::text)),
  ('condition.need_label',         to_jsonb('A use needs the name a shopper reads.'::text)),
  ('condition.no_synonyms',        to_jsonb('No other words yet'::text)),
  ('condition.active',             to_jsonb('Live'::text)),
  ('condition.hidden',             to_jsonb('Hidden'::text)),
  ('condition.add',                to_jsonb('New use'::text)),
  ('condition.save',               to_jsonb('Save'::text)),
  ('condition.saved',              to_jsonb('Saved — live now.'::text)),
  ('condition.added',              to_jsonb('Added — live now.'::text)),
  ('condition.removed',            to_jsonb('Removed — live now.'::text)),
  ('condition.reseeded',           to_jsonb('Re-read from the catalogue — live now.'::text)),
  ('condition.remove',             to_jsonb('Remove'::text)),
  ('condition.add_product',        to_jsonb('Add'::text)),
  ('condition.already',            to_jsonb('Already added'::text)),
  ('condition.field_label',        to_jsonb('Name a shopper reads'::text)),
  ('condition.field_synonyms',     to_jsonb('Other words they search (comma separated)'::text)),
  ('condition.field_sort',         to_jsonb('Order in the list'::text)),
  ('condition.field_active',       to_jsonb('Show in Browse by'::text)),
  ('condition.products_title',     to_jsonb('Products under this use'::text)),
  ('condition.products_hint',      to_jsonb('Search the catalogue to add one.'::text)),
  ('condition.products_search_hint', to_jsonb('Search products in this use'::text)),
  ('condition.add_product_hint',   to_jsonb('Search a product name to add'::text)),
  ('condition.products_empty',     to_jsonb('No product under this use yet.'::text)),
  ('condition.search_min',         to_jsonb('Type at least 2 letters.'::text)),
  ('condition.src_admin',          to_jsonb('Added by admin'::text)),
  ('condition.src_seed',           to_jsonb('From the first seed'::text)),
  ('condition.reseed',             to_jsonb('Re-read from catalogue'::text)),
  ('condition.scope',              to_jsonb('{zone} · {date}'::text)),
  ('condition.scope_all_zones',    to_jsonb('All zones'::text)),
  ('catalogue.condition_word',     to_jsonb('use'::text))
on conflict (key) do nothing;

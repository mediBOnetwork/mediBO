-- cmd #401 (3/3) — POSITIVE COMPANY COVERAGE.
--
-- Today the engine only knows what a supplier does NOT stock, and it learns it
-- the expensive way: `supplier_group_exclusion` fills up one rejection at a
-- time, after the customer has already waited through an inquiry that was
-- never going to be answered. Nobody has ever been able to tell us what they DO
-- stock.
--
-- So: a supplier declares his companies (and optionally a category inside one),
-- and the waterfall prefers a declared stockist over a supplier who has never
-- said. It is a PREFERENCE, never a filter — an undeclared supplier is still
-- asked, just after the ones who said they carry the brand. Making it a filter
-- would mean one supplier's tidy list silently starved everyone who has not
-- filled theirs in yet.
--
-- The exclusions keep their meaning exactly: they are HARD BLOCKS and they win.
-- A declaration cannot un-exclude a product — "I stock Cipla" and "not this
-- Cipla item" are both true, and the specific one is the one that matters.

create table if not exists supplier_coverage (
  id            bigserial primary key,
  supplier_name text not null,
  company       text,
  category      text,
  -- declared = he ticked it; seeded = we suggested it from his own history and
  -- he accepted. Kept apart so "what did he actually tell us" stays answerable.
  source        text not null default 'declared',
  declared_at   timestamptz not null default now()
);
create unique index if not exists supplier_coverage_uniq
  on supplier_coverage (lower(btrim(supplier_name)),
                        lower(btrim(coalesce(company,'*'))),
                        lower(btrim(coalesce(category,'*'))));
create index if not exists supplier_coverage_company_idx
  on supplier_coverage (lower(btrim(coalesce(company,''))));

-- Does this supplier claim this product's company/category?
create or replace function public.supplier_covers_product(p_supplier text, p_product_id bigint)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from supplier_coverage c
    join "MEDICINE" m on m.id = p_product_id
    where lower(btrim(c.supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
      and (c.company  is null
           or lower(btrim(c.company))  = lower(btrim(coalesce(m.marketer,''))))
      and (c.category is null
           or lower(btrim(c.category)) = lower(btrim(coalesce(m.therapeutic_class,''))))
  );
$$;

-- ── the waterfall's preference ─────────────────────────────────────────────
-- The ONLY change to the ranked list is one leading sort key. Declared
-- stockists first, then the SPN order that has always applied, so within each
-- group the best-performing supplier is still first. Nobody is removed.
create or replace function public.oi_zone_ps_payload(p_product_id bigint, p_zone_id smallint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_code text; v_sup text[]; v_oos text[]; v_nos text[];
  v_ranked text[]; j jsonb := '{}'::jsonb; i int;
begin
  select code into v_code from zones where id = p_zone_id and is_active;
  if v_code is null or p_product_id is null then
    return jsonb_build_object('zone_sup','{}'::text[],'zone_oos','{}'::text[],
                              'zone_nostock','{}'::text[],'ranked','{}'::text[],'ps','{}'::jsonb);
  end if;

  execute format('select %I, %I, %I from public."MEDICINE" where id = $1',
                 'z_'||v_code||'_sup','z_'||v_code||'_oos','z_'||v_code||'_nostock')
    into v_sup, v_oos, v_nos using p_product_id;

  select coalesce(array_agg(s.name order by
           -- cmd #401: declared coverage first. A boolean DESC puts true ahead
           -- of false, and every existing tie-break is untouched behind it.
           public.supplier_covers_product(s.name, p_product_id) desc,
           coalesce(sp."SPN",0) desc, s.name asc),'{}')
    into v_ranked
  from unnest(coalesce(v_sup,'{}')) as s(name)
  left join supplier_profiles sp
         on lower(btrim(sp.supplier_name)) = lower(btrim(s.name))
        and sp.zone_id = p_zone_id
        and not coalesce(sp.is_deleted,false)
  where not (coalesce(v_nos,'{}') @> array[s.name]);

  for i in 1..30 loop
    j := jsonb_set(j, array['PS'||i],
           case when v_ranked[i] is null then 'null'::jsonb else to_jsonb(v_ranked[i]) end);
  end loop;

  return jsonb_build_object(
    'zone_sup', coalesce(v_sup,'{}'), 'zone_oos', coalesce(v_oos,'{}'),
    'zone_nostock', coalesce(v_nos,'{}'), 'ranked', coalesce(v_ranked,'{}'), 'ps', j);
end $function$;

-- ── suggestions, from his OWN answered inquiries ───────────────────────────
-- Never a guess from someone else's data: only companies he personally
-- answered 'Available' for. An exclusion he already filed is never suggested
-- back to him.
create or replace function public.supplier_coverage_suggestions(p_supplier text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(x order by x.n desc, x.company), '[]'::jsonb)
  from (
    select btrim(m.marketer) as company, count(*) as n,
           public._cf('supplier.cov_suggest_sub',
             jsonb_build_object('n', count(*)::text)) as sub_label
    from supplier_item_memory sim
    join "MEDICINE" m on m.id = sim.product_id
    where lower(btrim(sim.supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
      and sim.last_answer = 'Available'
      and coalesce(btrim(m.marketer),'') <> ''
      and not exists (
        select 1 from supplier_coverage c
        where lower(btrim(c.supplier_name)) = lower(btrim(p_supplier))
          and lower(btrim(coalesce(c.company,''))) = lower(btrim(m.marketer)))
      and not exists (
        select 1 from supplier_group_exclusion g
        where lower(btrim(g.supplier_name)) = lower(btrim(p_supplier))
          and lower(btrim(coalesce(g.company,''))) = lower(btrim(m.marketer))
          and g.category is null)
    group by 1
    limit 40
  ) x;
$$;

-- ── the supplier's Companies screen, one rendered payload ───────────────────
create or replace function public.supplier_coverage_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_name text;
begin
  select supplier_name into v_name from supplier_profiles where id = public.my_supplier_id();
  if v_name is null then return jsonb_build_object('error','not_supplier'); end if;

  return jsonb_build_object(
    'ok', true,
    'supplier_name', v_name,
    'screen_title',    _c('supplier.cov_title'),
    'intro',           _c('supplier.cov_intro'),
    'declared_title',  _c('supplier.cov_declared_title'),
    'declared_empty',  _c('supplier.cov_declared_empty'),
    'suggest_title',   _c('supplier.cov_suggest_title'),
    'suggest_empty',   _c('supplier.cov_suggest_empty'),
    'excluded_title',  _c('supplier.cov_excluded_title'),
    'excluded_note',   _c('supplier.cov_excluded_note'),
    'add_label',       _c('supplier.cov_add'),
    'remove_label',    _c('supplier.cov_remove'),
    'declared', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'company', c.company, 'category', c.category,
               'label', coalesce(c.company, _c('supplier.cov_any_company'))
                        || case when c.category is null then ''
                                else ' · ' || c.category end,
               'source', c.source)
             order by lower(btrim(coalesce(c.company,''))))
      from supplier_coverage c
      where lower(btrim(c.supplier_name)) = lower(btrim(v_name))), '[]'::jsonb),
    'suggestions', public.supplier_coverage_suggestions(v_name),
    -- His hard blocks are shown on the same screen on purpose: declaring a
    -- company he has also excluded is the one confusing case, and seeing both
    -- lists together is what makes "the exclusion still wins" obvious.
    'excluded', coalesce((
      select jsonb_agg(jsonb_build_object(
               'company', g.company, 'category', g.category,
               'label', coalesce(g.company,'*')
                        || case when g.category is null then ''
                                else ' · ' || g.category end)
             order by lower(btrim(coalesce(g.company,''))))
      from supplier_group_exclusion g
      where lower(btrim(g.supplier_name)) = lower(btrim(v_name))), '[]'::jsonb));
end $$;

create or replace function public.supplier_coverage_set(p_company text, p_category text default null,
                                                        p_on boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_name text; v_company text; v_category text;
begin
  select supplier_name into v_name from supplier_profiles where id = public.my_supplier_id();
  if v_name is null then return jsonb_build_object('error','not_supplier'); end if;

  v_company  := nullif(btrim(coalesce(p_company,'')),'');
  v_category := nullif(btrim(coalesce(p_category,'')),'');
  -- "I stock everything" is not a declaration, it is the absence of one, and it
  -- would put him ahead of every real declaration on every product.
  if v_company is null and v_category is null then
    return jsonb_build_object('error','too_broad','message', _c('supplier.cov_too_broad'));
  end if;

  if p_on then
    insert into supplier_coverage (supplier_name, company, category, source)
    values (v_name, v_company, v_category, 'declared')
    on conflict (lower(btrim(supplier_name)),
                 lower(btrim(coalesce(company,'*'))),
                 lower(btrim(coalesce(category,'*'))))
    do update set declared_at = now(), source = 'declared';
  else
    delete from supplier_coverage
     where lower(btrim(supplier_name)) = lower(btrim(v_name))
       and lower(btrim(coalesce(company,'*')))  = lower(btrim(coalesce(v_company,'*')))
       and lower(btrim(coalesce(category,'*'))) = lower(btrim(coalesce(v_category,'*')));
  end if;

  return jsonb_build_object('ok', true,
    'message', case when p_on then _cf('supplier.cov_added',
                                    jsonb_build_object('company', coalesce(v_company, v_category)))
                    else _cf('supplier.cov_removed',
                           jsonb_build_object('company', coalesce(v_company, v_category))) end,
    'state', public.supplier_coverage_get());
end $$;

insert into ui_copy (key, value) values
  ('supplier.cov_title',           to_jsonb('Companies you stock'::text)),
  ('supplier.cov_intro',           to_jsonb('Tell us which companies you carry and we will ask you first for those products. Leaving this empty costs you nothing — you will still be asked, just after the shops that declared the brand.'::text)),
  ('supplier.cov_declared_title',  to_jsonb('You stock these'::text)),
  ('supplier.cov_declared_empty',  to_jsonb('Nothing declared yet. Add a company below and you will be asked first for it.'::text)),
  ('supplier.cov_suggest_title',   to_jsonb('Suggested from your past answers'::text)),
  ('supplier.cov_suggest_empty',   to_jsonb('No suggestions yet — they appear once you have answered a few inquiries.'::text)),
  ('supplier.cov_suggest_sub',     to_jsonb('you answered Available {n} time(s)'::text)),
  ('supplier.cov_excluded_title',  to_jsonb('You told us you do NOT stock these'::text)),
  ('supplier.cov_excluded_note',   to_jsonb('These stay blocked. Adding a company above does not undo them.'::text)),
  ('supplier.cov_any_company',     to_jsonb('Any company'::text)),
  ('supplier.cov_add',             to_jsonb('Add'::text)),
  ('supplier.cov_remove',          to_jsonb('Remove'::text)),
  ('supplier.cov_too_broad',       to_jsonb('Pick a company or a category — "everything" is not a declaration we can rank on.'::text)),
  ('supplier.cov_added',           to_jsonb('Added {company}. You will be asked first for it.'::text)),
  ('supplier.cov_removed',         to_jsonb('Removed {company}.'::text))
on conflict (key) do nothing;

revoke execute on function public.supplier_covers_product(text, bigint) from public, anon;
revoke execute on function public.supplier_coverage_suggestions(text) from public, anon;
revoke execute on function public.supplier_coverage_get() from public, anon;
revoke execute on function public.supplier_coverage_set(text, text, boolean) from public, anon;
grant execute on function public.supplier_covers_product(text, bigint) to authenticated, service_role;
grant execute on function public.supplier_coverage_suggestions(text) to authenticated, service_role;
grant execute on function public.supplier_coverage_get() to authenticated;
grant execute on function public.supplier_coverage_set(text, text, boolean) to authenticated;

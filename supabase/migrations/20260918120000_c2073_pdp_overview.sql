-- CMD #2073 — Product page: one overview card, dynamic dropdowns, no reviews.
--
-- Everything this change decides is DATA or SQL:
--   * the ONE "Product overview" card and the ORDER of its rows,
--   * the Rx/OTC badge's tone (the pack chip's light green, both ways),
--   * and the list of text sections, which is now built per PRODUCT from a
--     table — adding "How it works" or a new MEDICINE column is an INSERT,
--     never a deploy.
--
-- Idempotent: every statement is create-or-replace / if-not-exists / upsert.

begin;
set local lock_timeout = '60s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. COPY. The words the merged card needs. `do nothing` keeps an admin edit;
--    the two keys this change RE-WORDS are updated on purpose.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('pdp_ov_composition',   'Composition',       'CMD #2073 — Product overview row label.'),
  ('pdp_ov_manufacturer',  'Manufacturer',      'CMD #2073 — Product overview row label.'),
  ('pdp_ov_therapeutic',   'Therapeutic class', 'CMD #2073 — Product overview row label.')
on conflict (key) do nothing;

insert into public.storefront_ui_label (key, value, note) values
  ('pdp_overview_title',   'Product overview',  'CMD #2073 — heading over the ONE merged fact card.'),
  ('pdp_fact_rx',          'Medication type',   'CMD #2073 — renamed from "Prescription".')
on conflict (key) do update
  set value = excluded.value, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE ONE CARD. Overview and Product details were two cards printing facts
--    about the same pack. They are one list now, in the order the spec fixed,
--    and a column with nothing in it is an absent ROW — never a label with a
--    dash beside it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._pdp_overview_rows(p_product_id bigint)
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  with m as (select * from "MEDICINE" where id = p_product_id),
  lbl as (select key, value from storefront_ui_label),
  l as (select
      (select value from lbl where key = 'pdp_ov_composition')  as composition,
      (select value from lbl where key = 'pdp_fact_form')       as form,
      (select value from lbl where key = 'pdp_fact_pack')       as pack,
      (select value from lbl where key = 'pdp_ov_manufacturer') as manufacturer,
      (select value from lbl where key = 'pdp_ov_therapeutic')  as therapeutic,
      (select value from lbl where key = 'pdp_fact_rx')         as med_type,
      (select value from lbl where key = 'pdp_fact_rx_yes')     as rx_yes,
      (select value from lbl where key = 'pdp_fact_rx_no')      as rx_no,
      (select value from lbl where key = 'pdp_fact_storage')    as storage,
      (select value from lbl where key = 'pdp_fact_habit')      as habit),
  rows as (
    select * from (values
      ('composition',  (select composition  from l),
        (select nullif(btrim(coalesce(salt_composition,'')),'')   from m), 1),
      ('form',         (select form         from l),
        (select nullif(btrim(coalesce(pack_type,'')),'')          from m), 2),
      ('pack',         (select pack         from l),
        (select coalesce(nullif(btrim(coalesce(pack_qty,'')),''),
                         nullif(btrim(coalesce(pack_size,'')),'')) from m), 3),
      ('manufacturer', (select manufacturer from l),
        (select nullif(btrim(coalesce(marketer,'')),'')           from m), 4),
      ('therapeutic',  (select therapeutic  from l),
        (select nullif(btrim(coalesce(therapeutic_class,'')),'')  from m), 5),
      ('med_type',     (select med_type     from l),
        (select case when upper(btrim(coalesce(rx_required,''))) = 'RX'
                       then (select rx_yes from l)
                     when upper(btrim(coalesce(rx_required,''))) = 'OTC'
                       then (select rx_no  from l) end            from m), 6),
      ('storage',      (select storage      from l),
        (select nullif(btrim(coalesce(m.storage,'')),'')          from m m), 7),
      ('habit',        (select habit        from l),
        (select nullif(btrim(coalesce(habit_forming,'')),'')      from m), 8)
    ) t(k, lab, val, ord))
  select coalesce(
    (select jsonb_agg(jsonb_build_object('key', k, 'label', lab, 'value', val)
                      order by ord)
       from rows
      where val is not null
        and nullif(btrim(coalesce(lab,'')),'') is not null), '[]'::jsonb);
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE SECTIONS ARE A TABLE, NOT A LIST IN A FUNCTION.
--    Which MEDICINE text columns become dropdowns — and what each is called —
--    is DATA. A product only gets the sections whose column actually holds
--    something, so the list is per PRODUCT and there is no fixed set.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.pdp_section_source (
  col    text primary key,
  title  text    not null,
  sort   integer not null default 100,
  active boolean not null default true,
  note   text
);

insert into public.pdp_section_source (col, title, sort, note) values
  ('product_introduction', 'Introduction',  1, 'CMD #2073'),
  ('uses',                 'Uses',          2, 'CMD #2073'),
  ('benefits',             'Benefits',      3, 'CMD #2073'),
  ('side_effects',         'Side effects',  4, 'CMD #2073'),
  ('how_it_works',         'How it works',  5, 'CMD #2073'),
  ('product_highlight',    'Highlights',    6, 'CMD #2073 — the sixth filled MEDICINE text column.')
on conflict (col) do nothing;

alter table public.pdp_section_source enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='pdp_section_source'
                    and policyname='pdp_section_source_read') then
    create policy pdp_section_source_read on public.pdp_section_source
      for select using (true);
  end if;
end $$;

-- Every section is a collapsed dropdown now, so `accordion` is true for all of
-- them and the page has one rule instead of two.
create or replace function public._pdp_sections(p_product_id bigint)
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  with m as (select to_jsonb(x) as j from "MEDICINE" x where x.id = p_product_id),
  s as (
    select src.title,
           btrim(regexp_replace(coalesce(m.j->>src.col, ''),
                                'show\s?more|show\s?less', '', 'gi')) as body,
           src.sort
      from m cross join public.pdp_section_source src
     where src.active
  )
  select coalesce(
    jsonb_agg(jsonb_build_object('title', title, 'body', body, 'accordion', true)
              order by sort, title)
      filter (where nullif(body, '') is not null), '[]'::jsonb)
  from s;
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE BADGE. Rx and OTC now wear the pack chip's light green — one shape,
--    one fill, two words. `tone_name` is what the app resolves to a design
--    token, so the badge follows a token change with no deploy; the hex pair
--    stays for a build that predates this change.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.rx_badge(p_rx text)
returns jsonb
language sql stable set search_path to 'public'
as $fn$
  select case when upper(btrim(coalesce(p_rx,''))) = 'RX' then
    jsonb_build_object(
      'has', true, 'is_rx', true,
      'label', public._c('rx.badge_rx'),
      'title', public._c('rx.pdp_rx_title'),
      'note',  public._c('rx.pdp_rx_note'),
      'tone',  jsonb_build_object('bg','#D1FAE5','fg','#065F46','name','success'))
  when upper(btrim(coalesce(p_rx,''))) = 'OTC' then
    jsonb_build_object(
      'has', true, 'is_rx', false,
      'label', public._c('rx.badge_otc'),
      'title', public._c('rx.pdp_otc_title'),
      'note',  public._c('rx.pdp_otc_note'),
      'tone',  jsonb_build_object('bg','#D1FAE5','fg','#065F46','name','success'))
  else jsonb_build_object('has', false, 'is_rx', false) end;
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE PAGE PAYLOAD. `facts` is has:false from here on — its rows live in
--    `overview` now — and `sections` comes from the table above.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.product_detail(p_product_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v jsonb; v_rx text;
  v_gallery jsonb; v_facts jsonb; v_purchase jsonb; v_companions jsonb;
  v_supply jsonb; v_lines jsonb; v_mrp numeric;
  v_parts jsonb; v_title jsonb; v_chip text; v_packs jsonb;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;

  begin v_gallery := public.product_gallery(p_product_id);
  exception when others then v_gallery := jsonb_build_object('has', false, 'count', 0, 'images', '[]'::jsonb); end;

  -- CMD #2073 — Overview and Product details were one list printed as two
  -- cards. product_facts() is no longer read by this page; the same rows are
  -- in `overview`, in the order the spec fixed.
  v_facts := jsonb_build_object('has', false, 'title', '', 'rows', '[]'::jsonb);

  begin v_purchase := public.purchase_overlay(p_product_id);
  exception when others then v_purchase := jsonb_build_object('has', false); end;

  begin v_companions := public.product_companions(p_product_id, array[p_product_id]);
  exception when others then v_companions := jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb); end;

  -- CMD #1826 — supply confidence (a band, never a count) and the two price
  -- lines. Both worded here; the page prints them.
  v_mrp := nullif(v#>>'{pricing,mrp}', '')::numeric;
  begin v_supply := public.pdp_supply_confidence(p_product_id);
  exception when others then v_supply := jsonb_build_object('has', false); end;
  begin v_lines := public.pdp_price_lines(p_product_id, v_mrp);
  exception when others then v_lines := jsonb_build_object('has', false); end;

  -- CMD #1903 — the family, as a strip under the price.
  begin v_packs := public.pdp_other_packs(p_product_id);
  exception when others then v_packs := jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb); end;

  -- CMD #1896 — the title block.
  begin v_parts := public._pdp_pack_parts(p_product_id);
  exception when others then v_parts := jsonb_build_object('has', false); end;
  v_chip := coalesce(nullif(btrim(coalesce(v_parts->>'type', '')), ''),
                     nullif(btrim(coalesce(v_parts->>'container', '')), ''), '');
  v_title := jsonb_build_object(
    'has',     true,
    'name',    coalesce(v#>>'{header,name}', ''),
    'company', coalesce(v#>>'{header,company}', ''),
    'form_chip', jsonb_build_object(
      'has',   (v_chip <> ''),
      'label', initcap(v_chip),
      'tone',  'success'),
    'pack_line', jsonb_build_object(
      'has',   coalesce((v_parts->>'has')::boolean, false),
      'label', coalesce(v_parts->>'pack_line', '')));

  return v
    || jsonb_build_object('header',
         coalesce(v->'header','{}'::jsonb)
         || jsonb_build_object('rx_required',
              (upper(btrim(coalesce(v_rx,''))) = 'RX')))
    || jsonb_build_object(
    'rx',         public.rx_badge(v_rx),
    'rx_licence', case when upper(btrim(coalesce(v_rx,''))) = 'RX'
                            and public.my_customer_id() is not null
                       then public.rx_licence_state(public.my_customer_id())
                       else jsonb_build_object('has', true, 'reason', 'n/a') end)
    || jsonb_build_object(
    'gallery',    v_gallery,
    'facts',      v_facts,
    'purchase',   v_purchase,
    'companions', v_companions)
    || jsonb_build_object(
    'trust',       public._pdp_strip_counts(v->'trust'),
    'supply',      v_supply,
    'price_lines', v_lines,
    'title',       v_title,
    'other_packs', v_packs,
    'salt_rail',   public.pdp_salt_rail(p_product_id),
    -- CMD #2073 — ONE merged card, and every filled text column a dropdown.
    'overview',    public._pdp_overview_rows(p_product_id),
    'sections',    public._pdp_sections(p_product_id));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. GRANTS. Same reachability the page already had: the storefront is
--    readable signed out, so the two helpers follow product_detail exactly.
-- ─────────────────────────────────────────────────────────────────────────────
-- Both helpers are read ONLY through product_detail(), which is SECURITY
-- DEFINER and runs as the owner — so anon needs no grant of its own here, and
-- does not get one. Same for the section table.
revoke all on function public._pdp_overview_rows(bigint) from public;
revoke all on function public._pdp_sections(bigint)       from public;
revoke execute on function public._pdp_overview_rows(bigint) from anon;
revoke execute on function public._pdp_sections(bigint)       from anon;
grant execute on function public._pdp_overview_rows(bigint) to authenticated, service_role;
grant execute on function public._pdp_sections(bigint)       to authenticated, service_role;
revoke all on public.pdp_section_source from anon;
grant select on public.pdp_section_source to authenticated, service_role;

commit;

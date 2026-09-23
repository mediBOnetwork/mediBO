-- CMD #2184 — RG red: c747_catalogue_budget (catalogue_list 321ms vs a 300ms budget).
--
-- Root cause, measured on production (24-card page, "ANTI INFECTIVES"):
--   catalogue_list        ~300ms
--     _cat_group_cards    ~289ms
--       _product_card     ~180ms for 24 cards
--         _product_card_base ~75ms  (genuinely per-row)
--         the outer body     ~22ms  (when its page-invariant parts are hoisted)
--         ~80ms of nothing but re-running the SAME page-invariant lookups once
--         per card: card_style(), card_layout(), card_show(),
--         card_layout_screens() and three uncorrelated sub-selects
--         (app_settings 'card.text_lines', app_settings 'card.v6',
--         storefront_ui_label 'card_chip_unavailable').
--
-- Inlined in one query those sub-selects are InitPlans and run ONCE; inside a
-- SECURITY DEFINER function body they are a fresh plan per invocation, so a
-- 24-card page paid for them 24 times. Nothing about them depends on the row.
--
-- The fix is a hoist, not a rewrite: _product_card_chrome() returns every
-- page-invariant value in one jsonb, the list builders compute it ONCE and
-- pass it in, and _product_card falls back to computing it itself when no
-- chrome is supplied (so storefront_page / storefront_product keep working
-- unchanged). The rendered payload is byte-identical.

begin;

create or replace function public._product_card_chrome()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $chrome$
  select jsonb_build_object(
    'style', s.st,
    -- CMD #2167 — the card's whole geometry, live in the payload.
    'layout', s.ly || jsonb_build_object(
      'text_lines', coalesce((select (value #>> '{}')::int from public.app_settings
                               where key = 'card.text_lines'), 3),
      'name_max_lines', coalesce((s.ly->>'name_lines')::int, 2)),
    'show', s.sh,
    'layout_screens', s.sc,
    'sub_fg', s.st->>'sub_fg',
    'mrp_fg', s.st->>'mrp_fg',
    -- CMD #2160 — Product card v6.
    'image_pct', coalesce((s.ly->>'image_pct')::int, (s.v6->>'image_pct')::int, 92),
    'unavail_label', coalesce((select value from public.storefront_ui_label
                                where key = 'card_chip_unavailable'), ''),
    'unavail_bg', coalesce(s.v6->>'unavail_bg', '#FEE2E2'),
    'unavail_fg', coalesce(s.v6->>'unavail_fg', '#991B1B'),
    'notify_bg', coalesce(s.v6->>'notify_bg', '#DC2626'),
    'notify_fg', coalesce(s.v6->>'notify_fg', '#FFFFFF'))
  from (select public.card_style() st,
               public.card_layout() ly,
               public.card_show() sh,
               public.card_layout_screens() sc,
               coalesce((select value from public.app_settings where key = 'card.v6'),
                        '{}'::jsonb) v6
        offset 0) s;
$chrome$;

revoke all on function public._product_card_chrome() from public;
grant execute on function public._product_card_chrome() to authenticated, service_role;

-- The sixth argument is defaulted, so the old five-argument call sites resolve
-- to it — but only once the five-argument signature is gone, or every existing
-- call becomes ambiguous.
drop function if exists public._product_card("MEDICINE", jsonb, jsonb, integer, boolean);

create or replace function public._product_card(m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean, p_chrome jsonb default null)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $pcard$
  select x.b || jsonb_build_object(
    'style', x.ch->'style',
    'pack_chip', jsonb_build_object('label', x.pc, 'has', x.pc <> ''),
    'sub_line', public.card_sub_line(m) || jsonb_build_object('fg', x.ch->>'sub_fg'),
    'placeholder', jsonb_build_object('kind', public.card_placeholder_kind(m.pack_qty, m.pack_type)),
    -- CMD #2167 — the card's whole geometry, live in the payload.
    'layout', x.ch->'layout',
    'show', x.ch->'show',
    'layout_screens', x.ch->'layout_screens',
    'price', coalesce(x.b->'price', '{}'::jsonb) || jsonb_build_object('mrp_struck', true, 'mrp_fg', x.ch->>'mrp_fg'),
    -- CMD #2160 — Product card v6.
    'v6', jsonb_build_object(
      'image_pct', (x.ch->>'image_pct')::int,
      'scheme', public.card_scheme_short(m, p_pricing),
      'unavail_chip', jsonb_build_object(
        'has', not coalesce((x.b#>>'{availability,is_available}')::boolean, false),
        'label', x.ch->>'unavail_label',
        'bg', x.ch->>'unavail_bg',
        'fg', x.ch->>'unavail_fg'),
      'notify_pill', jsonb_build_object(
        'bg', x.ch->>'notify_bg',
        'fg', x.ch->>'notify_fg')))
  from (select public._product_card_base(m, p_pricing, p_avail, p_qty, p_notified) b,
               public.card_pack_chip(m.pack_qty, m.pack_type) pc,
               -- CMD #2184: the page's chrome, built ONCE by the list builder.
               coalesce(p_chrome, public._product_card_chrome()) ch
        offset 0) x   -- CMD #2145: evaluate _product_card_base once, not per use of x.b
$pcard$;

revoke all on function public._product_card("MEDICINE", jsonb, jsonb, integer, boolean, jsonb) from public;
grant execute on function public._product_card("MEDICINE", jsonb, jsonb, integer, boolean, jsonb) to authenticated, service_role;

-- CMD #2184: build the chrome once per page and hand it to every card.
CREATE OR REPLACE FUNCTION public._cat_cards(p_ids bigint[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'salt', m.salt_composition,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false)
                       then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
    -- CHANGE #748 — the "New" chip, decided against the backend's own window.
    'is_new', (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
    'new_badge', case when (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                 then public.uic('catalogue.new_badge','New') else '' end,
    'rx', public.rx_card_badge(m.rx_required),
      'wish', public.card_wish(m.id),
    'availability', l.av,
    'pricing', l.pr,
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
    'card', public._product_card(m, l.pr, l.av, coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c)
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt cross join ch
  cross join lateral (select
    public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
        true) as av,
    public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr) l;
$function$

;

-- CMD #2184: build the chrome once per page and hand it to every card.
CREATE OR REPLACE FUNCTION public._sf_cards(p_ids bigint[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'pack_qty_display', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_size_display', coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),'')),
    'pack_type', m.pack_type,
    'pack_qty', m.pack_qty,
    'pack_size', m.pack_size,
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false) then 'Scheme available' else '' end,
    -- CHANGE #461/#170: the prescription class, from "MEDICINE".rx_required.
    'rx', public.rx_card_badge(m.rx_required),
      'wish', public.card_wish(m.id),
    'availability', l.av,
    'pricing', l.pr,
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
    'card', public._product_card(m, l.pr, l.av, coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c)
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt cross join ch
  cross join lateral (select
    public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0))) as av,
    public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr) l
  where lower(coalesce(m.buyable::text,'')) in ('true','t');
$function$

;

-- CMD #2184: build the chrome once per page and hand it to every card.
CREATE OR REPLACE FUNCTION public._search_cards(p_ids bigint[], p_pct numeric, p_zone smallint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c)
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', m.id,
      'name', m.product_name,
      'company', m.marketer,
      'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
      'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
      'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
      'pack_type_label', public.sf_pack_type_label(m.pack_type),
      'image', m.image_url_1,
      'category', m.therapeutic_class,
      'salt', m.salt_composition,
      'has_offer', coalesce(m.has_scheme, false),
      'offer_chip', case when coalesce(m.has_scheme, false)
                         then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
      'is_new', (m.created_at is not null
                 and m.created_at >= now() - make_interval(days =>
                       coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
      'new_badge', case when (m.created_at is not null
                 and m.created_at >= now() - make_interval(days =>
                       coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                   then public.uic('catalogue.new_badge','New') else '' end,
      'rx', public.rx_card_badge(m.rx_required),
      'wish', public.card_wish(m.id),
      -- CMD #2023 — ONE truth. The card button is storefront_cta over
      -- storefront_effective_count, which is public.zone_available().
      'availability', l.av,
      'pricing', l.pr,
      'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                   then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
      'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
      'card', public._product_card(m, l.pr, l.av, coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c)
    ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt cross join ch
  cross join lateral (select
    public.storefront_cta(
          public.storefront_effective_count(m.id,
            coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
          true) as av,
    public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, p_pct, m.id) as pr) l;
$function$

;

-- CMD #2184: build the chrome once per page and hand it to every card.
CREATE OR REPLACE FUNCTION public.product_cards(p_ids bigint[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm),
       ch as materialized (select public._product_card_chrome() as c)
  select coalesce(jsonb_agg(public._product_card(m, l.pr, l.av,
           coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text, ch.c) order by o.ord), '[]'::jsonb)
    from unnest(p_ids) with ordinality o(pid, ord)
    join "MEDICINE" m on m.id = o.pid
    cross join cq cross join nt cross join ch
    cross join lateral (select
      public.storefront_cta(public.storefront_effective_count(m.id,
        coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)), true) as av,
      public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr) l;
$function$

;

commit;

-- CMD #2207 — the product card, precomputed.
--
-- CAUSE: _sf_cards() — the ONE builder behind the home rails, the search
-- results, the search idle rail, the company page and the cart rail — costs
-- 95 ms for 36 cards, i.e. ~2.6 ms per card, measured on live. It is not call
-- overhead (a SECURITY DEFINER + SET search_path plpgsql call was measured at
-- under 1 us); it is the jsonb the card is: _product_card() 1972 us,
-- _product_card_base() 1362 us of it, for a ~4.9 kB object per product. No
-- index and no rewrite makes building 4.9 kB of JSON 20 times cheaper.
--
-- FIX (the METHOD's step 3): the card is PRECOMPUTED per (viewer class,
-- product) by a cron_task and read back verbatim. Everything in a card that is
-- personal — the quantity in this viewer's cart, whether they asked to be
-- notified, whether they saved it — is still built live, but only for the
-- products that are actually in one of those three sets. A signed-out viewer
-- has none, so their whole page is cache reads.
--
-- The viewer CLASS is (zone, approved, admin, cart discount %): everything a
-- card depends on that is not the product itself and not one of the three
-- personal sets. The warm tick builds a class by seeding exactly the
-- per-request memos CMD #2207's first migration introduced, so a cached card
-- is bit-for-bit the card that class's viewer would have built.

create table if not exists public.sf_card_cache (
  ckey        text   not null,
  product_id  bigint not null,
  card        jsonb  not null,
  built_at    timestamptz not null default now(),
  primary key (ckey, product_id)
);

create index if not exists idx_sf_card_cache_built
  on public.sf_card_cache (built_at);

comment on table public.sf_card_cache is
  'CMD #2207 — the idle product card (no cart qty, no notify, no wish) per viewer class. Written only by sf_card_warm_tick(); read by _sf_cards().';

alter table public.sf_card_cache enable row level security;
revoke all on public.sf_card_cache from anon, authenticated;

insert into public.app_settings (key, value) values
  ('sf_card_cache_ttl_s',     to_jsonb(900)),
  ('sf_card_warm_ids',        to_jsonb(4000)),
  ('sf_card_warm_queries',    to_jsonb(40)),
  ('sf_card_warm_batch',      to_jsonb(500)),
  ('sf_card_cache_enabled',   to_jsonb(true)),
  ('sf_card_warm_zones',      to_jsonb(20))
on conflict (key) do nothing;

-- ── the class a card belongs to ───────────────────────────────────────────
create or replace function public._sf_card_class()
returns text
language sql stable security definer
set search_path to 'public'
as $fn$
  select coalesce(public._viewer_zone_or_null()::text, '-')
      || '/' || public.viewer_is_approved_customer()::text
      || '/' || (public.get_my_role() in ('admin','super_admin'))::text
      || '/' || coalesce(public.my_cart_discount_pct()::text, '0')
$fn$;

comment on function public._sf_card_class() is
  'CMD #2207 — everything an idle product card depends on besides the product: zone, approved, admin, cart discount %. Every helper in it is memoised per request.';

-- ── _sf_cards(): read the cache, build only what is personal or missing ───
create or replace function public._sf_cards(p_ids bigint[])
returns jsonb
language sql stable security definer
set search_path to 'public'
as $fn$
  with ctx as materialized (
    select public._sf_card_class()                as ck,
           public._viewer_cart_qty_map(p_ids)     as qm,
           public._viewer_notify_map(p_ids)       as nm,
           public._wish_owner()                   as wo,
           public._product_card_chrome()          as ch,
           greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                               where key = 'sf_card_cache_ttl_s'), 900), 30) as ttl,
           coalesce((select (value #>> '{}')::boolean from public.app_settings
                      where key = 'sf_card_cache_enabled'), true) as on_
  ),
  want as (
    select o.pid, o.ord from unnest(p_ids) with ordinality o(pid, ord)
  ),
  -- the three personal sets: a product in any of them is never served from
  -- the idle cache, it is built live exactly as it always was.
  personal as (
    select w.pid
      from want w cross join ctx x
     where (x.qm ? w.pid::text)
        or (x.nm ? w.pid::text)
        or (x.wo is not null
            and exists (select 1 from public.wishlist_items wi
                         where wi.account_id = x.wo and wi.product_id = w.pid))
  ),
  hit as (
    select w.ord, c.card
      from want w
      cross join ctx x
      join public.sf_card_cache c
        on c.ckey = x.ck and c.product_id = w.pid
      join "MEDICINE" m on m.id = w.pid
     where x.on_
       and c.built_at > now() - make_interval(secs => x.ttl)
       and lower(coalesce(m.buyable::text,'')) in ('true','t')
       and not exists (select 1 from personal p where p.pid = w.pid)
  ),
  miss as (
    select o.ord, jsonb_build_object(
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
      'rx', k.card->'rx',
      'wish', k.card->'wish',
      'availability', l.av,
      'pricing', l.pr,
      'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                   then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
      'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
      'card', k.card
    ) as card
    from unnest(p_ids) with ordinality o(pid, ord)
    join "MEDICINE" m on m.id = o.pid
    cross join ctx x
    cross join lateral (select
      public.storefront_cta(
          public.storefront_effective_count(m.id,
            coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0))) as av,
      public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr
      offset 0) l
    cross join lateral (select public._product_card(m, l.pr, l.av,
          coalesce((x.qm->>m.id::text)::int, 0), x.nm ? m.id::text, x.ch) as card
      offset 0) k
    where lower(coalesce(m.buyable::text,'')) in ('true','t')
      and not exists (select 1 from hit h where h.ord = o.ord)
  )
  select coalesce(jsonb_agg(z.card order by z.ord), '[]'::jsonb)
    from (select ord, card from hit union all select ord, card from miss) z;
$fn$;

-- ── the warm tick ─────────────────────────────────────────────────────────
-- Seeds a class's memos, builds its idle cards for the hot id set, stores
-- them. Classes: anonymous, plus every active zone as an approved customer.
create or replace function public._sf_card_seed_class(
  p_zone smallint, p_approved boolean, p_admin boolean, p_pct numeric)
returns text
language plpgsql volatile security definer
set search_path to 'public'
as $fn$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('medibo.m_vzone',    'anon|' || coalesce(p_zone::text,''), true);
  perform set_config('medibo.m_cazone',   'anon|' || coalesce(p_zone::text,''), true);
  perform set_config('medibo.viewer_approved', 'anon|' || case when p_approved then 't' else 'f' end, true);
  perform set_config('medibo.m_role',     'anon|' || case when p_admin then 'admin' else 'customer' end, true);
  perform set_config('medibo.m_cartpct',  'anon|' || coalesce(p_pct::text,'0'), true);
  perform set_config('medibo.m_cartuser', 'anon|', true);
  perform set_config('medibo.wish_owner', 'anon|', true);
  return public._sf_card_class();
end $fn$;

create or replace function public.sf_card_warm_tick()
returns jsonb
language plpgsql volatile security definer
set search_path to 'public'
as $fn$
declare
  v_ids     bigint[];
  v_class   text;
  v_zone    smallint;
  v_n       int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'sf_card_warm_ids'), 4000), 50);
  v_qn      int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'sf_card_warm_queries'), 40), 0);
  v_batch   int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'sf_card_warm_batch'), 1500), 50);
  v_ttl     int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'sf_card_cache_ttl_s'), 900), 30);
  v_zn      int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'sf_card_warm_zones'), 20), 1);
  v_out     jsonb := '[]'::jsonb;
  v_wrote   int;
  v_t0      timestamptz;
  v_q       text;
  v_qids    bigint[];
  v_zones   smallint[];
begin
  if not coalesce((select (value #>> '{}')::boolean from public.app_settings
                    where key = 'sf_card_cache_enabled'), true) then
    return jsonb_build_object('ok', true, 'skipped', 'disabled');
  end if;

  select coalesce(array_agg(z.id order by z.id), '{}'::smallint[])
    into v_zones
    from (select id from public.zones where coalesce(is_active, true)
           order by id limit v_zn) z;

  foreach v_zone in array (array[null::smallint] || v_zones) loop
    v_t0 := clock_timestamp();
    v_class := public._sf_card_seed_class(v_zone, v_zone is not null, false, 0);

    -- the hot id set for this class: the feed this class is served, plus the
    -- products the most-typed searches actually return.
    select coalesce(array_agg(f.product_id order by f.rank), '{}'::bigint[])
      into v_ids
      from public._sf_feed_ids('All', 0, v_n) f;

    if v_qn > 0 then
      for v_q in
        select r.q from public.search_recent r
         group by r.q order by count(*) desc, max(r.last_at) desc limit v_qn
      loop
        begin
          select coalesce(array_agg(s.id), '{}'::bigint[]) into v_qids
            from public.search_medicines_priority(v_q, 'All', 0, 60, false) s;
          v_ids := v_ids || v_qids;
        exception when others then null;
        end;
      end loop;
    end if;

    -- de-duplicate and bound the work this tick does.
    select coalesce(array_agg(distinct u), '{}'::bigint[]) into v_ids
      from (select unnest(v_ids) u limit v_batch * 8) t;

    v_wrote := 0;
    -- build in batches, so one tick is a predictable amount of work.
    for v_qids in
      select array_agg(t.u) from (
        select u, ntile(greatest(ceil(cardinality(v_ids)::numeric / v_batch)::int, 1))
                    over (order by u) as b
          from unnest(v_ids) u) t group by t.b
    loop
      insert into public.sf_card_cache (ckey, product_id, card, built_at)
      select v_class, (e->>'id')::bigint, e, now()
        from jsonb_array_elements(public._sf_cards(v_qids)) e
       where (e->>'id') ~ '^[0-9]+$'
      on conflict (ckey, product_id) do update
        set card = excluded.card, built_at = excluded.built_at;
      get diagnostics v_wrote = row_count;
      v_out := v_out;
    end loop;

    select count(*) into v_wrote from public.sf_card_cache where ckey = v_class;
    v_out := v_out || jsonb_build_object(
      'class', v_class, 'cards', v_wrote,
      'ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::int);
  end loop;

  -- Put the session back exactly as it was found: the memos this tick seeded
  -- are per-request state, and anything else running in the same transaction
  -- must not inherit the last class it built.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('medibo.m_vzone', '', true);
  perform set_config('medibo.m_cazone', '', true);
  perform set_config('medibo.viewer_approved', '', true);
  perform set_config('medibo.m_role', '', true);
  perform set_config('medibo.m_cartpct', '', true);
  perform set_config('medibo.m_cartuser', '', true);
  perform set_config('medibo.wish_owner', '', true);

  -- rows for a class nobody is in any more, or older than twice the TTL.
  delete from public.sf_card_cache
   where built_at < now() - make_interval(secs => v_ttl * 3);

  return jsonb_build_object('ok', true, 'classes', v_out);
end $fn$;

insert into public.cron_task (name, ord, mode, work_sql, step_timeout_ms, enabled,
                              base_interval_s, max_interval_s, dml, note)
values ('sf_card_warm', 121, 'poll', 'select public.sf_card_warm_tick()',
        300000, true, 300, 900, true,
        'CMD #2207 — precomputes the idle product card per viewer class, so the home rails, search results, search idle rail, company page and cart rail read a card instead of building 4.9 kB of JSON per product.')
on conflict (name) do update
   set work_sql = excluded.work_sql,
       step_timeout_ms = excluded.step_timeout_ms,
       enabled = true,
       base_interval_s = excluded.base_interval_s,
       max_interval_s = excluded.max_interval_s,
       dml = true,
       parked_reason = null,
       fail_count = 0,
       last_error = null,
       note = excluded.note;

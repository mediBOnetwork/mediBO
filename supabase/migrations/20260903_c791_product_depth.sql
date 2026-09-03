-- CMD #791 — Product page depth.
--
-- Four things the catalogue already knew and the product page never showed:
--   1. image_url_1..5 — five real pack shots, of which the page rendered a
--      swipe with no zoom, no counter and no thumbnails.
--   2. uses / side_effects / storage / salt / pack / Rx / habit-forming /
--      cold chain — columns with content on nearly every row.
--   3. order_items — the buyer's OWN history with this pack, which is the one
--      thing a pharmacy re-ordering trade stock actually wants on screen.
--   4. order_items pairs — what gets bought WITH it, per zone.
--
-- Everything below is a backend string. The Flutter side prints and taps; it
-- formats no date, pluralises no count and words no chip.
--
-- Idempotent throughout: create-or-replace, if-not-exists, on-conflict.

-- The migration runs as one transaction. The instance's default lock_timeout is
-- 5s, which is right for a user path and too tight for the CREATE POLICY below
-- while five runners are applying DDL; raised for this transaction only.
set local lock_timeout = '60s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. COPY. Every user-facing word this feature adds, in the table an admin
--    edits. `do nothing` on conflict so a re-run never clobbers an edit.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('pdp_gallery_zoom_hint',  'Tap to zoom',                'CMD #791 — hint under the PDP gallery when more than one shot exists.'),
  ('pdp_gallery_close',      'Close',                      'CMD #791 — the zoom viewer''s dismiss control.'),
  ('pdp_facts_title',        'Product details',            'CMD #791 — heading over the salt/pack/Rx fact table.'),
  ('pdp_fact_salt',          'Composition & strength',     'CMD #791 — fact row label.'),
  ('pdp_fact_form',          'Form',                       'CMD #791 — fact row label.'),
  ('pdp_fact_pack',          'Pack',                       'CMD #791 — fact row label.'),
  ('pdp_fact_rx',            'Prescription',               'CMD #791 — fact row label.'),
  ('pdp_fact_rx_yes',        'Prescription required (Rx)', 'CMD #791 — value when MEDICINE.rx_required reads Rx.'),
  ('pdp_fact_rx_no',         'Over the counter (OTC)',     'CMD #791 — value when it does not.'),
  ('pdp_fact_habit',         'Habit forming',              'CMD #791 — fact row label.'),
  ('pdp_fact_cold_chain',    'Cold chain',                 'CMD #791 — fact row label.'),
  ('pdp_fact_cold_chain_yes','Ships refrigerated (2-8°C)', 'CMD #791 — value when MEDICINE.cold_chain is true.'),
  ('pdp_fact_storage',       'Storage',                    'CMD #791 — fact row label.'),
  ('pdp_purchase_title',     'Your buying history',        'CMD #791 — heading over the repeat-purchase overlay.'),
  ('pdp_companions_title',   'Frequently bought together', 'CMD #791 — heading over the co-purchase rail.'),
  ('pdp_companions_note',    'Bought with this pack by pharmacies in your area.', 'CMD #791 — subtitle under the co-purchase rail.'),
  ('cart_companions_title',  'Frequently bought together', 'CMD #791 — heading over the cart''s co-purchase strip.'),
  ('cart_companions_note',   'Pharmacies who bought these also bought:',          'CMD #791 — subtitle in the cart.')
on conflict (key) do nothing;

-- Tunables. Support floor is the spec's 3; the rest keep the windows out of
-- the SQL body so a change is an UPDATE, not a migration.
insert into public.app_settings (key, value) values
  ('copurchase_min_support',       '3'::jsonb),
  ('copurchase_store_top_n',       '12'::jsonb),
  ('copurchase_show_top_n',        '6'::jsonb),
  ('copurchase_lookback_days',     '365'::jsonb),
  ('purchase_overlay_recent_days', '30'::jsonb),
  ('purchase_overlay_window_days', '365'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. GALLERY. Up to five URLs read verbatim from the columns the R2 cutover
--    rewrites in place (r2_cutover() swaps image_url_N and keeps the original
--    in image_src_N), so this is the R2 URL the moment that product is moved
--    and there is nothing here to change on cutover day.
--
--    `counter_label` is per image and pre-rendered ("2 / 5"): the page prints
--    the string at the index it is showing and never builds "x / y" itself.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.product_gallery(p_product_id bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with src as (
    select u, row_number() over () as i
      from "MEDICINE" m,
           lateral unnest(array[m.image_url_1, m.image_url_2, m.image_url_3,
                                m.image_url_4, m.image_url_5]) u
     where m.id = p_product_id
  ),
  live as (select u, row_number() over (order by i) as n
             from src where nullif(btrim(coalesce(u,'')), '') is not null),
  tot as (select count(*)::int c from live)
  select jsonb_build_object(
    'has',   (select c from tot) > 0,
    'count', (select c from tot),
    'zoom_hint', case when (select c from tot) > 0
                      then coalesce((select value from storefront_ui_label
                                      where key = 'pdp_gallery_zoom_hint'), '')
                      else '' end,
    'close_label', coalesce((select value from storefront_ui_label
                              where key = 'pdp_gallery_close'), ''),
    'images', coalesce((
      select jsonb_agg(jsonb_build_object(
               'url', l.u,
               'counter_label', l.n::text || ' / ' || (select c from tot))
             order by l.n)
        from live l), '[]'::jsonb));
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. FACTS. Salt + strength, form, pack, Rx/OTC, habit forming, cold chain,
--    storage — one table of {key,label,value}, every half of every row a
--    stored string. A blank column is an ABSENT row, never a dash.
--
--    There is no `strength` and no `form` column in "MEDICINE": strength is
--    printed inside salt_composition ("Levocetirizine (5mg) + Montelukast
--    (10mg)") and the form is pack_type ("Strip"). Both are carried verbatim
--    rather than parsed apart — splitting them would be the backend inventing
--    a field the catalogue does not have.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.product_facts(p_product_id bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with m as (select * from "MEDICINE" where id = p_product_id),
  lbl as (select key, value from storefront_ui_label),
  l as (select (select value from lbl where key = 'pdp_facts_title')      as title,
               (select value from lbl where key = 'pdp_fact_salt')        as salt,
               (select value from lbl where key = 'pdp_fact_form')        as form,
               (select value from lbl where key = 'pdp_fact_pack')        as pack,
               (select value from lbl where key = 'pdp_fact_rx')          as rx,
               (select value from lbl where key = 'pdp_fact_rx_yes')      as rx_yes,
               (select value from lbl where key = 'pdp_fact_rx_no')       as rx_no,
               (select value from lbl where key = 'pdp_fact_habit')       as habit,
               (select value from lbl where key = 'pdp_fact_cold_chain')  as cc,
               (select value from lbl where key = 'pdp_fact_cold_chain_yes') as cc_yes,
               (select value from lbl where key = 'pdp_fact_storage')     as storage),
  rows as (
    select * from (
      values
        ('salt',       (select salt    from l), (select nullif(btrim(coalesce(salt_composition,'')),'') from m), 1),
        ('form',       (select form    from l), (select nullif(btrim(coalesce(pack_type,'')),'')        from m), 2),
        ('pack',       (select pack    from l), (select coalesce(nullif(btrim(coalesce(pack_qty,'')),''),
                                                                 nullif(btrim(coalesce(pack_size,'')),'')) from m), 3),
        ('rx',         (select rx      from l), (select case when upper(btrim(coalesce(rx_required,''))) = 'RX'
                                                              then (select rx_yes from l) else (select rx_no from l) end
                                                   from m), 4),
        ('habit',      (select habit   from l), (select nullif(btrim(coalesce(habit_forming,'')),'')     from m), 5),
        ('cold_chain', (select cc      from l), (select case when cold_chain is true then (select cc_yes from l) end from m), 6),
        ('storage',    (select storage from l), (select nullif(btrim(coalesce(storage,'')),'')           from m), 7)
    ) t(k, lab, val, ord)
  )
  select jsonb_build_object(
    'has',   exists (select 1 from rows where val is not null and lab is not null),
    'title', coalesce((select title from l), ''),
    'rows',  coalesce((select jsonb_agg(jsonb_build_object('key', k, 'label', lab, 'value', val) order by ord)
                         from rows where val is not null and lab is not null), '[]'::jsonb));
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE PURCHASE OVERLAY.
--
--    "Last ordered 12 Aug · 3× last month · usual qty 9" — the buyer's own
--    order_items, keyed to the ACCOUNT (my_customer_id()), never to auth.uid().
--    Anonymous and signed-in-but-not-a-customer both fall out as has:false,
--    which is spec item 4: content for everyone, history for its owner.
--
--    Set-based on purpose: it takes an ARRAY of ids and scans order_items ONCE
--    for the whole page. A per-row scalar helper called inside a card SELECT is
--    the documented anti-pattern in this codebase (it re-scans per row), and
--    the catalogue grid asks for 250 ids at a time.
--
--    `usual_qty` is the MODE of the past quantities, not the mean: a pharmacy
--    that buys 3 strips four times and 40 strips once usually buys 3, and an
--    average would offer to add 10.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.purchase_overlay_map(p_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_acct   uuid;
  v_recent int;
  v_window int;
  v_out    jsonb;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return '{}'::jsonb;
  end if;

  v_acct := public.my_customer_id();
  if v_acct is null then
    return '{}'::jsonb;
  end if;

  v_recent := coalesce((select (value #>> '{}')::int from app_settings
                         where key = 'purchase_overlay_recent_days'), 30);
  v_window := coalesce((select (value #>> '{}')::int from app_settings
                         where key = 'purchase_overlay_window_days'), 365);

  with mine as (
    select oi.product_id, oi.order_id, oi.order_date, oi.quantity
      from order_items oi
      join orders o on o.id = oi.order_id
     where o.customer_id = v_acct
       and oi.product_id = any (p_ids)
       and oi.order_date is not null
       and oi.order_date >= (current_date - v_window)
       and coalesce(oi.quantity, 0) > 0
  ),
  agg as (
    select product_id,
           max(order_date)                                              as last_at,
           count(distinct order_id)                                     as orders_all,
           count(distinct order_id) filter (
             where order_date >= (current_date - v_recent))             as orders_recent,
           mode() within group (order by quantity)                      as usual_qty
      from mine
     group by product_id
  ),
  built as (
    select a.product_id,
           a.usual_qty,
           to_char(a.last_at, 'FMDD Mon')                               as last_label,
           a.orders_recent,
           -- The chips, in the order the spec writes them. A month with no
           -- order simply has no middle chip: "0x last month" is noise on a
           -- buying screen.
           (array['Last ordered ' || to_char(a.last_at, 'FMDD Mon')]
            || case when a.orders_recent > 0
                    then array[a.orders_recent::text || '× last month'] else '{}'::text[] end
            || case when a.usual_qty > 0
                    then array['usual qty ' || a.usual_qty::text] else '{}'::text[] end
           )                                                            as chips
      from agg a
     where a.last_at is not null
  )
  select coalesce(jsonb_object_agg(b.product_id::text, jsonb_build_object(
           'has',         true,
           'label',       array_to_string(b.chips, ' · '),
           'chips',       to_jsonb(b.chips),
           'short_label', 'Ordered ' || b.last_label,
           'last_label',  b.last_label,
           'usual_qty',   coalesce(b.usual_qty, 0),
           'can_add',     coalesce(b.usual_qty, 0) > 0,
           'add_label',   case when coalesce(b.usual_qty, 0) > 0
                               then 'Add usual qty (' || b.usual_qty::text || ')' else '' end,
           'title',       coalesce((select value from storefront_ui_label
                                     where key = 'pdp_purchase_title'), ''),
           'tone',        jsonb_build_object('bg', '#EFF6FF', 'fg', '#1E40AF'))),
         '{}'::jsonb)
    into v_out
    from built b;

  return coalesce(v_out, '{}'::jsonb);
end;
$$;

-- One product. Same map, same words — the page and the card cannot disagree
-- because there is one implementation.
create or replace function public.purchase_overlay(p_product_id bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(public.purchase_overlay_map(array[p_product_id]) -> p_product_id::text,
                  jsonb_build_object('has', false));
$$;

grant execute on function public.purchase_overlay_map(bigint[]) to anon, authenticated;
grant execute on function public.purchase_overlay(bigint) to anon, authenticated;
grant execute on function public.product_gallery(bigint) to anon, authenticated;
grant execute on function public.product_facts(bigint) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. FREQUENTLY BOUGHT TOGETHER.
--
--    A nightly job over order_items pairs, per zone, support >= 3. Never
--    computed on a user path: the read is a single indexed lookup.
--
--    zone_id = 0 is the platform-wide roll-up. It exists because a zone with
--    no pair history yet (and an anonymous visitor, who has no zone at all)
--    would otherwise see an empty rail forever — the fallback is still real
--    co-purchase evidence, just measured across every zone rather than one.
--
--    THE Rx RULE: a pair is only ever formed between two products of the SAME
--    prescription class. An OTC pack never suggests a Schedule-H companion,
--    and an Rx pack never launders one into an OTC-looking rail.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.product_copurchase (
  zone_id      smallint    not null,
  product_id   bigint      not null,
  companion_id bigint      not null,
  support      integer     not null,
  rank         integer     not null,
  is_rx        boolean     not null default false,
  built_at     timestamptz not null default now(),
  primary key (zone_id, product_id, companion_id)
);

create index if not exists idx_product_copurchase_read
  on public.product_copurchase (product_id, zone_id, rank);

alter table public.product_copurchase enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'product_copurchase'
                    and policyname = 'copurchase_read_all') then
    create policy copurchase_read_all on public.product_copurchase
      for select using (true);
  end if;
end $$;

comment on table public.product_copurchase is
  'CMD #791 — nightly co-purchase pairs from order_items. zone_id 0 is the platform-wide roll-up used when a zone has no evidence of its own.';

create or replace function public.copurchase_rebuild()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_min   int;
  v_top   int;
  v_days  int;
  v_rows  bigint;
begin
  v_min  := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_min_support'), 3);
  v_top  := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_store_top_n'), 12);
  v_days := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_lookback_days'), 365);

  drop table if exists _cop_new;
  create temporary table _cop_new on commit drop as
  with lines as (
    select distinct
           oi.order_id,
           oi.product_id,
           coalesce(oi.zone_id, o.zone_id)::smallint as zone_id
      from order_items oi
      join orders o on o.id = oi.order_id
     where oi.product_id is not null
       and coalesce(oi.order_date, o.order_date) >= (current_date - v_days)
       and coalesce(oi.unfulfillable, false) = false
  ),
  cls as (
    select l.*, (upper(btrim(coalesce(m.rx_required, ''))) = 'RX') as is_rx
      from lines l
      join "MEDICINE" m on m.id = l.product_id
     where m.buyable is true
       and public.med_status_sellable(m.status)
  ),
  -- Ordered pairs (both directions) so a lookup by either side is one index hit.
  -- The Rx class must MATCH: that is the "never across Rx restrictions" rule,
  -- enforced where the pair is formed rather than filtered at read time.
  pairs as (
    select a.zone_id, a.product_id, b.product_id as companion_id, a.is_rx, a.order_id
      from cls a
      join cls b
        on b.order_id = a.order_id
       and b.product_id <> a.product_id
       and b.is_rx = a.is_rx
  ),
  by_zone as (
    select zone_id, product_id, companion_id, bool_or(is_rx) as is_rx,
           count(distinct order_id)::int as support
      from pairs
     where zone_id is not null
     group by 1, 2, 3
  ),
  global as (
    select 0::smallint as zone_id, product_id, companion_id, bool_or(is_rx) as is_rx,
           count(distinct order_id)::int as support
      from pairs
     group by 2, 3
  ),
  unioned as (
    select * from by_zone
    union all
    select * from global
  )
  select zone_id, product_id, companion_id, support, is_rx,
         row_number() over (partition by zone_id, product_id
                            order by support desc, companion_id)::int as rank
    from unioned
   where support >= v_min;

  delete from _cop_new where _cop_new.rank > v_top;

  -- Whole-table swap. The set is small (top-N per product per zone) and a
  -- partial rebuild would leave yesterday's pairs for a product that dropped
  -- below the floor today.
  delete from public.product_copurchase;
  insert into public.product_copurchase (zone_id, product_id, companion_id, support, rank, is_rx, built_at)
  select zone_id, product_id, companion_id, support, rank, is_rx, now() from _cop_new;

  get diagnostics v_rows = row_count;

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'min_support', v_min,
    'top_n', v_top,
    'zones', (select count(distinct zone_id) from public.product_copurchase),
    'products', (select count(distinct product_id) from public.product_copurchase));
end;
$$;

-- The rail. Viewer's zone first, platform-wide roll-up when that zone has no
-- evidence. Every card field is the same block the storefront cards read, so a
-- companion's price can never disagree with the same product's card.
create or replace function public.product_companions(p_product_id bigint, p_exclude bigint[] default '{}')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_zone  smallint;
  v_show  int;
  v_use   smallint;
  v_items jsonb;
begin
  v_show := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_show_top_n'), 6);
  v_zone := coalesce(public._viewer_zone_or_null(), public.my_zone_id());

  -- Prefer the viewer's own zone; fall back to the platform roll-up (0).
  if v_zone is not null and exists (
       select 1 from product_copurchase
        where product_id = p_product_id and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_rank), '[]'::jsonb) into v_items
  from (
    select c.rank as x_rank,
           jsonb_build_object(
             'id',            m.id,
             'name',          coalesce(m.product_name, ''),
             'company',       coalesce(m.marketer, ''),
             'pack_label',    coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'form_chip',     coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'image',         coalesce(m.image_url_1, ''),
             'support_label', c.support::text || ' orders',
             'pricing',       public.storefront_pricing(
                                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                                public.my_cart_discount_pct(), m.id),
             'availability',  public.storefront_cta(
                                public.storefront_effective_count(m.id, m.supplier_count),
                                true, m.status)) as x
      from product_copurchase c
      join "MEDICINE" m on m.id = c.companion_id
     where c.product_id = p_product_id
       and c.zone_id = v_use
       and m.buyable is true
       and public.med_status_sellable(m.status)
       and not (m.id = any (coalesce(p_exclude, '{}'::bigint[])))
     order by c.rank
     limit greatest(v_show, 1)
  ) s;

  return jsonb_build_object(
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from storefront_ui_label where key = 'pdp_companions_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key = 'pdp_companions_note'), ''),
    'zone_id', v_use,
    'items', v_items);
end;
$$;

-- The cart's strip: companions of everything in the basket, minus what is
-- already in it, ranked by how strongly they co-occur.
create or replace function public.cart_companions(p_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_zone  smallint;
  v_show  int;
  v_use   smallint;
  v_items jsonb;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb);
  end if;

  v_show := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_show_top_n'), 6);
  v_zone := coalesce(public._viewer_zone_or_null(), public.my_zone_id());

  if v_zone is not null and exists (
       select 1 from product_copurchase
        where product_id = any (p_ids) and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_support desc, x_id), '[]'::jsonb) into v_items
  from (
    select m.id as x_id, sum(c.support)::int as x_support,
           jsonb_build_object(
             'id',            m.id,
             'name',          coalesce(m.product_name, ''),
             'company',       coalesce(m.marketer, ''),
             'pack_label',    coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'form_chip',     coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'image',         coalesce(m.image_url_1, ''),
             'support_label', sum(c.support)::text || ' orders',
             'pricing',       public.storefront_pricing(
                                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                                public.my_cart_discount_pct(), m.id),
             'availability',  public.storefront_cta(
                                public.storefront_effective_count(m.id, m.supplier_count),
                                true, m.status)) as x
      from product_copurchase c
      join "MEDICINE" m on m.id = c.companion_id
     where c.product_id = any (p_ids)
       and c.zone_id = v_use
       and not (c.companion_id = any (p_ids))
       and m.buyable is true
       and public.med_status_sellable(m.status)
     group by m.id, m.product_name, m.marketer, m.pack_type, m.pack_size,
              m.pack_qty, m.image_url_1, m.mrp, m.supplier_count, m.status
     order by 2 desc, 1
     limit greatest(v_show, 1)
  ) s;

  return jsonb_build_object(
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from storefront_ui_label where key = 'cart_companions_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key = 'cart_companions_note'), ''),
    'zone_id', v_use,
    'items', v_items);
end;
$$;

grant execute on function public.product_companions(bigint, bigint[]) to anon, authenticated;
grant execute on function public.cart_companions(bigint[]) to anon, authenticated;
grant execute on function public.copurchase_rebuild() to service_role;

-- The nightly job. Registered as a cron_task row for the ONE dispatcher —
-- never a bare pg_cron */N schedule (that is what starved the connection pool
-- on 2026-08-18).
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, run_at_ist, dml, note)
values ('copurchase_rebuild', 120, 'poll', null,
        'select public.copurchase_rebuild()', true, '02:40:00', false,
        'CMD #791 — rebuilds product_copurchase from order_items pairs (per zone + a platform roll-up), support >= copurchase_min_support, same-Rx-class pairs only.')
on conflict (name) do update
  set work_sql   = excluded.work_sql,
      run_at_ist = excluded.run_at_ist,
      mode       = excluded.mode,
      enabled    = excluded.enabled,
      dml        = excluded.dml,
      note       = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. WIRING. product_detail gains four blocks; the catalogue grid gains the
--    overlay; the cart gains the strip. All ADDITIVE — every key the existing
--    payloads carried is untouched, so nothing already rendering changes.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.product_detail(p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v jsonb; v_rx text;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;
  -- CHANGE #461/#170: the prescription class, and (for a signed-in pharmacy)
  -- whether their drug licence is on file for it.
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
    -- CMD #791 — depth. The gallery (up to five shots with their own counter
    -- strings), the fact table, this buyer's own history with the pack, and
    -- what it is bought with. `purchase` is has:false for anyone who is not a
    -- customer, which is how an anonymous visitor gets the content and none of
    -- the history.
    || jsonb_build_object(
    'gallery',    public.product_gallery(p_product_id),
    'facts',      public.product_facts(p_product_id),
    'purchase',   public.purchase_overlay(p_product_id),
    'companions', public.product_companions(p_product_id, array[p_product_id]));
end $function$;

-- The catalogue grid. The overlay map is resolved ONCE for the whole page in a
-- CTE and joined in — not called per row, which would re-scan order_items 250
-- times for one screen.
create or replace function public.storefront_page(category_filter text default 'All'::text,
                                                  page_offset integer default 0,
                                                  page_limit integer default null::integer)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  WITH cfg AS (
    SELECT
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_initial_limit'), 250) AS initial_limit,
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_more_limit'), 100) AS more_limit
  ),
  lim AS (
    SELECT greatest(coalesce(nullif(page_limit, 0), (SELECT initial_limit FROM cfg)), 1) AS n
  ),
  disc AS (SELECT public.my_cart_discount_pct() AS pct),
  rows AS (
    SELECT f.*, row_number() over () AS _ord FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
  ),
  -- CMD #791 — one scan of order_items for the whole page.
  ov AS (
    SELECT public.purchase_overlay_map(array(SELECT r.id FROM rows r)) AS m
  ),
  n AS (SELECT count(*)::int AS returned FROM rows),
  t AS (SELECT public.get_storefront_count(category_filter)::bigint AS total)
  SELECT jsonb_build_object(
    'status','ok',
    'category', category_filter,
    'sort', 'default',
    'sort_options', public.storefront_sort_options('default'),
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'showing_label', (SELECT r.showing_label FROM rows r LIMIT 1),
    'total', (SELECT total FROM t),
    'count_label', to_char((SELECT total FROM t), 'FM9,99,99,999'),
    'banner_count_label', to_char((SELECT total FROM t), 'FM9,99,99,999') || '+ products',
    'show_all_label', 'Show all ' || to_char((SELECT total FROM t), 'FM9,99,99,999') || ' products',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (page_offset + (SELECT returned FROM n)) < (SELECT total FROM t),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_products'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'feed_end_label'), ''),
    'items', coalesce((
      SELECT jsonb_agg(
        (to_jsonb(r) - '_ord')
        || jsonb_build_object('availability',
             public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count),
                                   true, src.status))
        || jsonb_build_object('status', public.med_status_block(src.status)->>'label')
        || jsonb_build_object('status_block', public.med_status_block(src.status))
        || jsonb_build_object('pack_badge', public.sf_pack_badge(src.pack_qty, src.pack_size, src.pack_type))
        || jsonb_build_object('type_chip', coalesce(nullif(btrim(src.pack_type),''), nullif(btrim(src.pack_size),''), ''))
        || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
        || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id))
        || jsonb_build_object('purchase',
             coalesce((SELECT m -> r.id::text FROM ov), jsonb_build_object('has', false)))
        ORDER BY r._ord)
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id), '[]'::jsonb)
  );
$function$;

create or replace function public.cart_render(p_guest_uid uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb; k text; arr jsonb; el jsonb; i int; n int := 0; bad bigint[]; ids bigint[];
begin
  v := public._cart_render_core(p_guest_uid);
  select coalesce(array_agg(u.product_id),'{}') into bad from public._cart_unavailable_lines() u;

  -- CMD #791 — the co-purchase strip, built from the ids actually in the
  -- basket. Empty basket => has:false and no strip.
  -- cart_items.product_id is TEXT and not every row holds a catalogue id, so
  -- the same numeric guard the pricing/margin/Rx blocks now carry applies here.
  select coalesce(array_agg(distinct (e->>'product_id')::bigint), '{}')
    into ids
    from jsonb_array_elements(coalesce(v->'items','[]'::jsonb)) e
   where (e->>'product_id') ~ '^[0-9]+$';

  if coalesce(array_length(bad,1),0) = 0 or v is null or jsonb_typeof(v) <> 'object' then
    return coalesce(v,'{}'::jsonb)
        || jsonb_build_object('unavailable_count', 0)
        || jsonb_build_object('companions', public.cart_companions(ids));
  end if;
  for k in select jsonb_object_keys(v) loop
    if jsonb_typeof(v->k) = 'array' and jsonb_array_length(v->k) > 0
       and jsonb_typeof((v->k)->0) = 'object' and ((v->k)->0) ? 'product_id' then
      arr := '[]'::jsonb;
      for i in 0..jsonb_array_length(v->k)-1 loop
        el := (v->k)->i;
        if (nullif(el->>'product_id','')::bigint = any(bad)) then
          el := el || jsonb_build_object('unavailable', true, 'qty_locked', true);
          n := n + 1;
        end if;
        arr := arr || el;
      end loop;
      v := jsonb_set(v, array[k], arr);
    end if;
  end loop;
  return v || jsonb_build_object(
    'unavailable_count', coalesce(array_length(bad,1),0),
    'unavailable_badge', coalesce(array_length(bad,1),0)::text || ' item'
      || case when coalesce(array_length(bad,1),0) = 1 then '' else 's' end || ' not available',
    'companions', public.cart_companions(ids));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. HARDENING — found by this command's own live reachability check.
--
-- The admin's product page came back as the not-found state on medibo.in while
-- every block was correct in SQL. Cause: `cart_items.product_id` is TEXT, that
-- account holds five preview rows ('prev1'..'prev5'), and
-- `cart_pricing_block()` cast the id to bigint unguarded — so
-- `my_cart_discount_pct()` RAISED, and every caller of it died with it.
--
-- That was already breaking `storefront_page()` for the same account (the whole
-- catalogue, not just this page) before CMD #791 existed; the co-purchase rail
-- simply made it visible on a second surface. Both halves are fixed here:
--
--   a) a cart row whose id is not a catalogue id is an UNPRICED line — the exact
--      branch the function already had for a null id — instead of an exception,
--   b) and no depth block may take the product page down with it. Each of the
--      four is wrapped, so a failure inside one renders that block absent and
--      the product still renders. Same rule as main.dart's boot guard: a
--      feature crash must never take the surface with it.
-- ─────────────────────────────────────────────────────────────────────────────
set local lock_timeout = '60s';

CREATE OR REPLACE FUNCTION public.cart_pricing_block(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lines jsonb := '[]'::jsonb;
  v_taxable numeric := 0; v_gst numeric := 0; v_cgst numeric := 0; v_sgst numeric := 0;
  v_net numeric := 0; v_mrp numeric := 0;
  v_priced int := 0; v_unpriced int := 0; v_est int := 0;
  v_rate numeric; v_rates numeric[] := '{}';
  it jsonb; v_tp jsonb; v_qty numeric; v_pid bigint;
  v_tax_lines jsonb := '[]'::jsonb;
  v_lbl_taxable text := coalesce((select value from storefront_ui_label where key='cart_taxable_total_label'), 'Taxable value');
  v_lbl_gst     text := coalesce((select value from storefront_ui_label where key='cart_gst_total_label'), 'GST');
  v_lbl_net     text := coalesce((select value from storefront_ui_label where key='cart_net_payable_label'), 'Net payable');
  v_lbl_mrp     text := coalesce((select value from storefront_ui_label where key='cart_mrp_worth_label'), 'MRP worth (reference only)');
  v_lbl_title   text := coalesce((select value from storefront_ui_label where key='cart_totals_title'), 'Order summary');
  v_lbl_unpriced text := coalesce((select value from storefront_ui_label where key='cart_unpriced_total_note'), 'not priced yet');
  v_lbl_none    text := coalesce((select value from storefront_ui_label where key='cart_no_price_yet'), 'Awaiting supplier rates');
  v_lbl_est     text := coalesce((select value from storefront_ui_label where key='cart_gst_estimated_note'), '');
begin
  for it in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    -- CMD #791 — cart_items.product_id is TEXT. A row that does not hold a
    -- catalogue id (the 'prev1'..'prev5' preview rows one account holds) is
    -- NOT priceable, and that is a normal outcome, not an error: it falls
    -- into the `v_pid is null` branch immediately below, which this
    -- function already had. The bare cast raised 22P02 and took
    -- my_cart_discount_pct() — and with it storefront_page(), the whole
    -- catalogue — down for that viewer.
    v_pid := case when (it->>'product_id') ~ '^[0-9]+$'
                  then (it->>'product_id')::bigint end;
    v_qty := coalesce((it->>'quantity')::numeric, 0);
    v_mrp := v_mrp + round(v_qty * coalesce((it->>'mrp')::numeric, 0), 2);

    if v_pid is null then
      v_unpriced := v_unpriced + 1;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'product_id', it->>'product_id', 'has_trade_rate', false));
      continue;
    end if;

    v_tp := public.trade_price_line(v_pid, v_qty);
    v_lines := v_lines || jsonb_build_array(v_tp);

    if (v_tp->>'has_trade_rate')::boolean then
      v_priced  := v_priced + 1;
      v_taxable := v_taxable + (v_tp->>'line_taxable')::numeric;
      v_gst     := v_gst     + (v_tp->>'line_gst')::numeric;
      v_cgst    := v_cgst    + (v_tp->>'line_cgst')::numeric;
      v_sgst    := v_sgst    + (v_tp->>'line_sgst')::numeric;
      v_net     := v_net     + (v_tp->>'line_net')::numeric;
      v_rate    := (v_tp->>'gst_pct')::numeric;
      if v_rate is not null and not (v_rate = any(v_rates)) then
        v_rates := v_rates || v_rate;
      end if;
      if not coalesce((v_tp->>'gst_confirmed')::boolean, false) then v_est := v_est + 1; end if;
    else
      v_unpriced := v_unpriced + 1;
    end if;
  end loop;

  v_taxable := round(v_taxable, 2); v_gst := round(v_gst, 2);
  v_cgst := round(v_cgst, 2); v_sgst := round(v_sgst, 2); v_net := round(v_net, 2);

  -- CGST/SGST — intra-state is the operating case (Chhattisgarh operator,
  -- Chhattisgarh pharmacies). IGST becomes a branch here the day the seller and
  -- the buyer GSTIN states differ; gst_split() already knows how to decide it.
  if v_priced > 0 then
    v_tax_lines := jsonb_build_array(
      jsonb_build_object('label', v_lbl_taxable, 'value', public.inr_money(v_taxable)),
      jsonb_build_object('label', 'CGST', 'value', public.inr_money(v_cgst)),
      jsonb_build_object('label', 'SGST', 'value', public.inr_money(v_sgst)),
      jsonb_build_object('label', v_lbl_gst, 'value', public.inr_money(v_gst)));
  end if;

  return jsonb_build_object(
    'title',            v_lbl_title,
    'lines',            v_lines,
    'priced_count',     v_priced,
    'unpriced_count',   v_unpriced,
    'has_priced',       (v_priced > 0),
    'has_unpriced',     (v_unpriced > 0),
    'has_tax',          (v_priced > 0),
    'taxable',          v_taxable,
    'taxable_display',  public.inr_money(v_taxable),
    'taxable_label',    v_lbl_taxable,
    'cgst',             v_cgst, 'cgst_display', public.inr_money(v_cgst),
    'sgst',             v_sgst, 'sgst_display', public.inr_money(v_sgst),
    'gst_total',        v_gst,  'gst_total_display', public.inr_money(v_gst),
    'gst_total_label',  v_lbl_gst,
    'gst_rates',        to_jsonb(v_rates),
    'gst_estimated_count', v_est,
    'gst_note',         case when v_est > 0 then v_lbl_est else '' end,
    'net_payable',      v_net,
    'net_payable_label',v_lbl_net,
    -- The payable NEVER falls back to MRP. With nothing priced it is ₹0.00 and
    -- the backend says why, in its own words.
    'net_payable_display', case when v_priced > 0 then public.inr_money(v_net) else v_lbl_none end,
    'mrp_worth',        round(v_mrp, 2),
    'mrp_worth_label',  v_lbl_mrp,
    'mrp_worth_display',public.inr_money(round(v_mrp, 2)),
    'tax_lines',        v_tax_lines,
    'unpriced_note',    case when v_unpriced > 0
                             then v_unpriced::text || ' item'
                                  || case when v_unpriced = 1 then '' else 's' end
                                  || ' ' || v_lbl_unpriced
                             else '' end);
end;
$function$;

-- The discount a companion tile is priced with. Never allowed to raise: the
-- co-purchase rail is an ADDITION to the product page, so a cart the viewer
-- happens to hold must not be able to blank the product they are looking at.
create or replace function public._c791_safe_discount_pct()
returns numeric
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  return public.my_cart_discount_pct();
exception when others then
  return null;
end;
$$;

grant execute on function public._c791_safe_discount_pct() to anon, authenticated;

-- The two companion readers now price through the safe wrapper, and resolve the
-- discount ONCE per call rather than once per tile.
create or replace function public.product_companions(p_product_id bigint, p_exclude bigint[] default '{}')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_zone  smallint;
  v_show  int;
  v_use   smallint;
  v_disc  numeric;
  v_items jsonb;
begin
  v_show := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_show_top_n'), 6);
  v_zone := coalesce(public._viewer_zone_or_null(), public.my_zone_id());
  v_disc := public._c791_safe_discount_pct();

  -- Prefer the viewer's own zone; fall back to the platform roll-up (0).
  if v_zone is not null and exists (
       select 1 from product_copurchase
        where product_id = p_product_id and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_rank), '[]'::jsonb) into v_items
  from (
    select c.rank as x_rank,
           jsonb_build_object(
             'id',            m.id,
             'name',          coalesce(m.product_name, ''),
             'company',       coalesce(m.marketer, ''),
             'pack_label',    coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'form_chip',     coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'image',         coalesce(m.image_url_1, ''),
             'support_label', c.support::text || ' orders',
             'pricing',       public.storefront_pricing(
                                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                                v_disc, m.id),
             'availability',  public.storefront_cta(
                                public.storefront_effective_count(m.id, m.supplier_count),
                                true, m.status)) as x
      from product_copurchase c
      join "MEDICINE" m on m.id = c.companion_id
     where c.product_id = p_product_id
       and c.zone_id = v_use
       and m.buyable is true
       and public.med_status_sellable(m.status)
       and not (m.id = any (coalesce(p_exclude, '{}'::bigint[])))
     order by c.rank
     limit greatest(v_show, 1)
  ) s;

  return jsonb_build_object(
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from storefront_ui_label where key = 'pdp_companions_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key = 'pdp_companions_note'), ''),
    'zone_id', v_use,
    'items', v_items);
end;
$$;

create or replace function public.cart_companions(p_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_zone  smallint;
  v_show  int;
  v_use   smallint;
  v_disc  numeric;
  v_items jsonb;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb);
  end if;

  v_show := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_show_top_n'), 6);
  v_zone := coalesce(public._viewer_zone_or_null(), public.my_zone_id());
  v_disc := public._c791_safe_discount_pct();

  if v_zone is not null and exists (
       select 1 from product_copurchase
        where product_id = any (p_ids) and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_support desc, x_id), '[]'::jsonb) into v_items
  from (
    select m.id as x_id, sum(c.support)::int as x_support,
           jsonb_build_object(
             'id',            m.id,
             'name',          coalesce(m.product_name, ''),
             'company',       coalesce(m.marketer, ''),
             'pack_label',    coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'form_chip',     coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'image',         coalesce(m.image_url_1, ''),
             'support_label', sum(c.support)::text || ' orders',
             'pricing',       public.storefront_pricing(
                                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                                v_disc, m.id),
             'availability',  public.storefront_cta(
                                public.storefront_effective_count(m.id, m.supplier_count),
                                true, m.status)) as x
      from product_copurchase c
      join "MEDICINE" m on m.id = c.companion_id
     where c.product_id = any (p_ids)
       and c.zone_id = v_use
       and not (c.companion_id = any (p_ids))
       and m.buyable is true
       and public.med_status_sellable(m.status)
     group by m.id, m.product_name, m.marketer, m.pack_type, m.pack_size,
              m.pack_qty, m.image_url_1, m.mrp, m.supplier_count, m.status
     order by 2 desc, 1
     limit greatest(v_show, 1)
  ) s;

  return jsonb_build_object(
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from storefront_ui_label where key = 'cart_companions_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key = 'cart_companions_note'), ''),
    'zone_id', v_use,
    'items', v_items);
end;
$$;

-- And the page itself: each depth block is wrapped, so a failure inside one
-- renders that block ABSENT and the product still renders. The four blocks are
-- additions to the product page; none of them is allowed to become the reason
-- there is no product page.
create or replace function public.product_detail(p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v jsonb; v_rx text;
  v_gallery jsonb; v_facts jsonb; v_purchase jsonb; v_companions jsonb;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;

  begin v_gallery := public.product_gallery(p_product_id);
  exception when others then v_gallery := jsonb_build_object('has', false, 'count', 0, 'images', '[]'::jsonb); end;

  begin v_facts := public.product_facts(p_product_id);
  exception when others then v_facts := jsonb_build_object('has', false, 'title', '', 'rows', '[]'::jsonb); end;

  begin v_purchase := public.purchase_overlay(p_product_id);
  exception when others then v_purchase := jsonb_build_object('has', false); end;

  begin v_companions := public.product_companions(p_product_id, array[p_product_id]);
  exception when others then v_companions := jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb); end;

  -- CHANGE #461/#170: the prescription class, and (for a signed-in pharmacy)
  -- whether their drug licence is on file for it.
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
    -- CMD #791 — depth: the gallery, the fact table, this buyer's own history
    -- with the pack, and what it is bought with.
    || jsonb_build_object(
    'gallery',    v_gallery,
    'facts',      v_facts,
    'purchase',   v_purchase,
    'companions', v_companions);
end $function$;

-- The cart's margin block carried the identical cast, so the CART was still
-- 500-ing for the same account after the pricing block was fixed.
CREATE OR REPLACE FUNCTION public.cart_margin_block(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_net numeric := 0; v_margin numeric := 0;
  v_ready int := 0; v_pending int := 0;
  v_label text := coalesce((select value from storefront_ui_label where key = 'cart_margin_label'), 'You earn on this order');
  v_net_label text := coalesce((select value from storefront_ui_label where key = 'cart_net_label'), 'Net payable (trade)');
begin
  select
    coalesce(sum(case when mp.pricing_ready then l.qty * (x.c->>'net_payable')::numeric end), 0),
    coalesce(sum(case when mp.pricing_ready and l.mrp > 0
                      then l.qty * (x.c->>'margin_amount')::numeric end), 0),
    count(*) filter (where coalesce(mp.pricing_ready, false)),
    count(*) filter (where not coalesce(mp.pricing_ready, false))
    into v_net, v_margin, v_ready, v_pending
  from (
    -- CMD #791 — the same unguarded cast cart_pricing_block carried. A cart
    -- row whose id is not a catalogue id ('prev3') is skipped by the WHERE
    -- below; the cast is guarded too, because nothing in SQL promises the
    -- select list is evaluated after the filter.
    select case when (it->>'product_id') ~ '^[0-9]+$'
                then (it->>'product_id')::bigint end as pid,
           coalesce((it->>'quantity')::numeric, 0) as qty,
           coalesce((it->>'mrp')::numeric, 0) as mrp
      from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) it
     where (it->>'product_id') ~ '^[0-9]+$') l
  left join public.medicine_pricing mp on mp.product_id = l.pid
  left join lateral (
    select public._pricing_compute(l.mrp, mp.ptr, mp.gst_pct,
             coalesce(mp.discount_pct, 0), mp.scheme_buy_qty, mp.scheme_free_qty, false) as c) x on true;

  return jsonb_build_object(
    'has',            (v_ready > 0),
    'label',          v_label,
    'total',          round(v_margin, 2),
    'total_display',  public.inr_money(round(v_margin, 2)),
    'net_label',      v_net_label,
    'net_total',      round(v_net, 2),
    'net_total_display', public.inr_money(round(v_net, 2)),
    'ready_count',    v_ready,
    'pending_count',  v_pending,
    'note', case when v_pending > 0 and v_ready > 0
                 then v_pending::text || ' item' || case when v_pending = 1 then '' else 's' end
                      || ' not priced yet - not counted above'
                 else '' end);
end;
$function$;

-- And the cart's Rx gate, the third copy of it — the cart still 500-ed after
-- the first two were fixed.
CREATE OR REPLACE FUNCTION public.cart_rx_gate(p_customer uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rx   int := 0;
  v_lic  jsonb := public.rx_licence_state(p_customer);
  v_block boolean;
  v_title text := ''; v_msg text := '';
  v_kyc  jsonb;                                   -- CHANGE #705
  v_kyc_block boolean := false;
begin
  select count(*) into v_rx
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) it
    -- CMD #791 — third instance of the same unguarded cast on a TEXT
    -- cart_items.product_id. A row that is not a catalogue id is not an Rx
    -- product either, so it simply does not join.
    join "MEDICINE" m on m.id = (case when (it->>'product_id') ~ '^[0-9]+$'
                                    then (it->>'product_id')::bigint end)
   where upper(btrim(coalesce(m.rx_required,''))) = 'RX';

  if v_rx > 0 and not coalesce((v_lic->>'has')::boolean, false) then
    if (v_lic->>'reason') = 'expired' then
      v_title := public._c('rx.licence_expired_title');
      v_msg   := public._cf('rx.licence_expired_msg',
                   jsonb_build_object('date', to_char((v_lic->>'expiry')::date, 'DD Mon YYYY')));
    else
      v_title := public._c('rx.licence_missing_title');
      v_msg   := case when v_rx = 1
                      then public._c('rx.licence_missing_msg_one')
                      else public._cf('rx.licence_missing_msg_many',
                             jsonb_build_object('count', v_rx::text)) end;
    end if;
  end if;

  v_block := (v_rx > 0)
             and not coalesce((v_lic->>'has')::boolean, false)
             and coalesce((v_lic->>'enforced')::boolean, false);

  -- CHANGE #705 — KYC parity. The Rx gate above asks "is there a licence
  -- NUMBER on file, and does this basket contain Schedule H stock?"; this asks
  -- "has a human VERIFIED the licence document?", and it applies to the whole
  -- basket, not only to Rx lines. Existing approved pharmacies keep ordering
  -- through their grace window; kyc_gate decides, this only renders it.
  v_kyc := public.kyc_gate('pharmacy', p_customer, 'trade');
  v_kyc_block := coalesce((v_kyc->>'blocked')::boolean, false);
  if v_kyc_block then
    v_title := coalesce(nullif(v_kyc->>'title',''), v_title);
    v_msg   := coalesce(nullif(v_kyc->>'message',''), v_msg);
  elsif v_msg = '' and coalesce(v_kyc->>'grace_note','') <> '' then
    v_msg := v_kyc->>'grace_note';                -- a warning, never a block
  end if;

  return jsonb_build_object(
    'has',        (v_rx > 0),
    'rx_count',   v_rx,
    'rx_note',    case when v_rx = 0 then ''
                       when v_rx = 1 then public._c('rx.cart_rx_note_one')
                       else public._cf('rx.cart_rx_note_many',
                              jsonb_build_object('count', v_rx::text)) end,
    'licence',    v_lic,
    'kyc',        v_kyc,
    'can_order',  not (v_block or v_kyc_block),
    'blocked',    (v_block or v_kyc_block),
    'is_warning', (v_msg <> '' and not (v_block or v_kyc_block)),
    'title',      v_title,
    'message',    v_msg,
    'tone',       case when (v_block or v_kyc_block) then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
                       when v_msg <> '' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end
$function$;

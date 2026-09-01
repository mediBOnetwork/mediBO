-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #427 — THE DEMAND ENGINE, THE OVERPAY CHANNEL AND SEASONALITY
--
-- #423 gave every pharmacy a vault of its own bills. #419 gave the zone an
-- anonymous demand radar built from POS sales and mediBO orders. This command
-- joins the two: the BILLS — including the ones from outside suppliers mediBO
-- never touched — become the network's own picture of what the market buys, at
-- what rate, from whom.
--
-- Three surfaces, one aggregate:
--   1. DEMAND ENGINE   — per-zone per-SKU purchase velocity across vaults, the
--                        rate spread by supplier, top movers and risers. Om's
--                        buying desk reads it; the #419 radar is fed by it.
--   2. OVERPAY CHANNEL — a monthly, capped, polite note to ONE pharmacy: your
--                        bill rate sits above what pharmacies near you pay.
--   3. SEASONALITY     — a per-SKU per-zone monthly factor learned from the
--                        same aggregate, which sharpens #424's velocity priors
--                        and the radar's own reading.
--
-- ANONYMISATION IS HARD LAW, and it is enforced in exactly one place so it
-- cannot drift:
--   * `_c427_floor()` is the ONLY cohort floor. It reads #419's
--     pharmacy_insight_config.min_cohort and can never return less than 5 —
--     lowering the #419 knob cannot lower this.
--   * every aggregate row is written only when its own distinct-pharmacy count
--     clears that floor; a group under it is stored NOWHERE, not written and
--     filtered later.
--   * the overpay comparison is computed against PEERS ONLY — the subject
--     pharmacy is removed from its own median, and at least `floor` OTHER
--     pharmacies must remain, so "5 data points" can never be four peers plus
--     yourself.
--   * `_c419_sharing()` (the opt-out) gates every read of every bill.
--   * no insight, payload or admin row ever names another pharmacy. The
--     supplier rate spread names SUPPLIERS to the platform operator only, and
--     even that row carries a cohort count, never a buyer.
--
-- Every string is a ui_copy row composed at READ time, so re-wording an
-- insight is an UPDATE and never a deploy. Every number is formatted here.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Config ──────────────────────────────────────────────────────────────
-- Deliberately NO min_cohort of its own. There is one floor in this codebase
-- and it belongs to #419.
create table if not exists public.pharmacy_network_config (
  id                    boolean primary key default true check (id),
  demand_months         integer  not null default 6,    -- history the engine reads
  top_n                 integer  not null default 15,   -- rows per admin list
  min_growth_pct        numeric  not null default 15,   -- "rising" starts here
  overpay_min_gap_pct   numeric  not null default 8,    -- below this we say nothing
  overpay_max_rows      integer  not null default 5,    -- capped, and polite
  overpay_lookback_days integer  not null default 120,
  overpay_min_units     numeric  not null default 5,    -- one stray box is not a pattern
  season_min_months     integer  not null default 6,    -- history before a factor exists
  season_min_units      numeric  not null default 20,
  season_floor          numeric  not null default 0.60,
  season_ceiling        numeric  not null default 1.80,
  updated_at            timestamptz not null default now()
);
insert into public.pharmacy_network_config (id) values (true)
  on conflict (id) do nothing;

create or replace function public._c427_cfg()
returns public.pharmacy_network_config
language sql stable security definer set search_path to 'public' as $$
  select * from public.pharmacy_network_config where id;
$$;

-- THE floor. Never below 5, whatever #419's knob says.
create or replace function public._c427_floor()
returns integer
language sql stable security definer set search_path to 'public' as $$
  select greatest(5, coalesce((select min_cohort from public.pharmacy_insight_config where id), 5));
$$;

create or replace function public._c427_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

create or replace function public._c427_month(p date default null)
returns date language sql stable as $$
  select date_trunc('month', coalesce(p, (now() at time zone 'Asia/Kolkata')::date))::date;
$$;

create or replace function public._c427_money(p numeric)
returns text language sql stable security definer set search_path to 'public' as $$
  select public.inr_money(coalesce(p, 0));
$$;

create or replace function public._c427_pct(p numeric)
returns text language sql immutable as $$
  select case when coalesce(p,0) > 0 then '+' else '' end
         || trim_scale(round(coalesce(p,0), 1))::text || '%';
$$;

-- ── 2. The aggregates ──────────────────────────────────────────────────────

-- What the zone actually bought, per SKU, per month. A row exists ONLY when
-- `pharmacy_count >= _c427_floor()`.
create table if not exists public.pharmacy_network_sku_month (
  month_key      date     not null,
  zone_id        smallint not null,
  medicine_id    bigint   not null,
  category_code  text     not null default 'other',
  product_name   text     not null default '—',
  pack_label     text,
  units          numeric  not null default 0,
  bills          integer  not null default 0,
  pharmacy_count integer  not null,
  median_rate    numeric,
  p25_rate       numeric,
  p75_rate       numeric,
  prev_units     numeric  not null default 0,
  delta_pct      numeric,
  computed_at    timestamptz not null default now(),
  primary key (month_key, zone_id, medicine_id)
);
create index if not exists pharmacy_network_sku_month_zone_idx
  on public.pharmacy_network_sku_month (zone_id, month_key desc, units desc);

-- The rate spread by supplier — the platform operator's buying desk. Carries a
-- cohort count and never a buyer.
create table if not exists public.pharmacy_network_supplier_rate (
  month_key      date     not null,
  zone_id        smallint not null,
  medicine_id    bigint   not null,
  supplier_key   text     not null,
  supplier_label text     not null,
  units          numeric  not null default 0,
  pharmacy_count integer  not null,
  median_rate    numeric,
  min_rate       numeric,
  max_rate       numeric,
  computed_at    timestamptz not null default now(),
  primary key (month_key, zone_id, medicine_id, supplier_key)
);
create index if not exists pharmacy_network_supplier_rate_zone_idx
  on public.pharmacy_network_supplier_rate (zone_id, month_key desc, medicine_id);

-- The seasonal factor: 1.0 is an average month for this SKU in this zone.
create table if not exists public.pharmacy_sku_season (
  zone_id        smallint not null,
  medicine_id    bigint   not null,
  month_no       smallint not null check (month_no between 1 and 12),
  factor         numeric  not null default 1,
  units          numeric  not null default 0,
  months_seen    integer  not null default 0,
  pharmacy_count integer  not null default 0,
  computed_at    timestamptz not null default now(),
  primary key (zone_id, medicine_id, month_no)
);

-- The same, one level up, so a SKU with thin history still gets a shape.
create table if not exists public.pharmacy_category_season (
  zone_id       smallint not null,
  category_code text     not null,
  month_no      smallint not null check (month_no between 1 and 12),
  factor        numeric  not null default 1,
  units         numeric  not null default 0,
  months_seen   integer  not null default 0,
  computed_at   timestamptz not null default now(),
  primary key (zone_id, category_code, month_no)
);

-- One pharmacy's monthly note. Numbers only — the sentence is composed at read
-- time from ui_copy, so re-wording is an UPDATE.
create table if not exists public.pharmacy_overpay_insight (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid     not null references public.pharmacy_profiles(id) on delete cascade,
  month_key     date     not null,
  medicine_id   bigint   not null,
  product_name  text     not null default '—',
  pack_label    text,
  your_rate     numeric  not null,
  peer_median   numeric  not null,
  delta_pct     numeric  not null,
  units         numeric  not null default 0,
  impact        numeric  not null default 0,   -- (your - peer) x units, INR
  peer_shops    integer  not null,             -- distinct OTHER pharmacies
  rank          integer  not null default 1,
  status        text     not null default 'new' check (status in ('new','seen','dismissed')),
  created_at    timestamptz not null default now(),
  seen_at       timestamptz,
  dismissed_at  timestamptz,
  unique (pharmacy_id, month_key, medicine_id)
);
create index if not exists pharmacy_overpay_insight_shop_idx
  on public.pharmacy_overpay_insight (pharmacy_id, month_key desc, rank);

-- #424's zone prior learns a season. `per_day` stays the flat rate it always
-- was; `per_day_season` is what a consumer should actually borrow.
alter table public.pharmacy_zone_sku_prior
  add column if not exists season_factor  numeric not null default 1;
alter table public.pharmacy_zone_sku_prior
  add column if not exists per_day_season numeric;

-- ── 3. RLS ─────────────────────────────────────────────────────────────────
-- Every aggregate is service-side only: nothing here is readable by a client
-- except through the SECURITY DEFINER RPCs below, which apply the floor, the
-- opt-out and the caller's own identity. A pharmacy's own insight rows are the
-- one exception and are still read through an RPC.
alter table public.pharmacy_network_config          enable row level security;
alter table public.pharmacy_network_sku_month       enable row level security;
alter table public.pharmacy_network_supplier_rate   enable row level security;
alter table public.pharmacy_sku_season              enable row level security;
alter table public.pharmacy_category_season         enable row level security;
alter table public.pharmacy_overpay_insight         enable row level security;

revoke all on public.pharmacy_network_config        from anon, authenticated;
revoke all on public.pharmacy_network_sku_month     from anon, authenticated;
revoke all on public.pharmacy_network_supplier_rate from anon, authenticated;
revoke all on public.pharmacy_sku_season            from anon, authenticated;
revoke all on public.pharmacy_category_season       from anon, authenticated;
revoke all on public.pharmacy_overpay_insight       from anon, authenticated;

-- ── 4. The one bill reader ─────────────────────────────────────────────────
-- Every cross-pharmacy number in this file comes through here, so the opt-out
-- and the zone requirement are stated once. INCLUDING outside purchases: the
-- vault does not care whether mediBO sold the box.
create or replace function public._c427_bill_units(p_from date, p_to date)
returns table (
  zone_id        smallint,
  medicine_id    bigint,
  product_name   text,
  pack_label     text,
  pharmacy_id    uuid,
  bill_id        uuid,
  invoice_date   date,
  units          numeric,
  rate           numeric,
  supplier_key   text,
  supplier_label text
)
language sql stable security definer set search_path to 'public' as $$
  select p.zone_id,
         l.medicine_id,
         coalesce(nullif(m.product_name, ''), nullif(l.product_name, ''), '—') as product_name,
         nullif(coalesce(l.pack_label, m.pack_size), '')                        as pack_label,
         b.pharmacy_id,
         b.id,
         b.invoice_date,
         coalesce(l.qty, 0) + coalesce(l.free_qty, 0)                           as units,
         -- The rate the pharmacy actually paid per unit, in that order of
         -- trust: the OCR's own unit cost, then the printed rate, then the
         -- taxable value spread over the billed quantity. MRP is never used —
         -- it is a ceiling, not a price (business context).
         coalesce(nullif(l.unit_cost, 0),
                  nullif(l.rate, 0),
                  case when coalesce(l.qty, 0) > 0
                       then round(l.taxable / l.qty, 4) end)                    as rate,
         lower(btrim(coalesce(nullif(b.supplier_gstin, ''), nullif(b.supplier_name, ''), 'unknown')))
                                                                                as supplier_key,
         coalesce(nullif(b.supplier_name, ''), nullif(b.supplier_gstin, ''), '—') as supplier_label
    from public.pharmacy_purchase_bill_line l
    join public.pharmacy_purchase_bill b on b.id = l.bill_id
    join public.pharmacy_profiles p      on p.id = b.pharmacy_id
    left join public."MEDICINE" m        on m.id = l.medicine_id
   where b.status in ('confirmed', 'applied')
     and b.invoice_date is not null
     and b.invoice_date >= p_from and b.invoice_date <= p_to
     and l.medicine_id is not null
     and coalesce(l.qty, 0) + coalesce(l.free_qty, 0) > 0
     and p.zone_id is not null
     and coalesce(p.is_deleted, false) = false
     and public._c419_sharing(b.pharmacy_id);
$$;

-- ── 5. DEMAND ENGINE — the monthly refresh ─────────────────────────────────
create or replace function public.network_demand_refresh(p_month date default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_month date := public._c427_month(p_month);
  v_prev  date := (public._c427_month(p_month) - interval '1 month')::date;
  v_floor integer := public._c427_floor();
  v_skus integer := 0; v_sup integer := 0; v_refused integer := 0; v_sup_refused integer := 0;
begin
  create temp table if not exists _c427_cur (
    zone_id smallint, medicine_id bigint, product_name text, pack_label text,
    pharmacy_id uuid, bill_id uuid, invoice_date date, units numeric, rate numeric,
    supplier_key text, supplier_label text) on commit drop;
  create temp table if not exists _c427_old (
    zone_id smallint, medicine_id bigint, pharmacy_id uuid, units numeric) on commit drop;
  delete from _c427_cur; delete from _c427_old;

  insert into _c427_cur
    select * from public._c427_bill_units(v_month, (v_month + interval '1 month - 1 day')::date);
  insert into _c427_old
    select zone_id, medicine_id, pharmacy_id, units
      from public._c427_bill_units(v_prev, (v_prev + interval '1 month - 1 day')::date);

  delete from public.pharmacy_network_sku_month     where month_key = v_month;
  delete from public.pharmacy_network_supplier_rate where month_key = v_month;

  -- Per SKU. A pharmacy's own rate is its MEDIAN across its own lines first,
  -- so a shop that bought ten times does not out-vote a shop that bought once
  -- when the network median is taken.
  with per_shop as (
    select c.zone_id, c.medicine_id, c.pharmacy_id,
           sum(c.units)                                                  as units,
           count(distinct c.bill_id)                                     as bills,
           max(c.product_name)                                           as product_name,
           max(c.pack_label)                                             as pack_label,
           percentile_cont(0.5) within group (order by c.rate)           as shop_rate
      from _c427_cur c
     where c.rate is not null and c.rate > 0
     group by c.zone_id, c.medicine_id, c.pharmacy_id
  ), cur as (
    select zone_id, medicine_id,
           max(product_name)                                             as product_name,
           max(pack_label)                                               as pack_label,
           sum(units)                                                    as units,
           sum(bills)::int                                               as bills,
           count(distinct pharmacy_id)::int                              as n,
           percentile_cont(0.50) within group (order by shop_rate)       as median_rate,
           percentile_cont(0.25) within group (order by shop_rate)       as p25_rate,
           percentile_cont(0.75) within group (order by shop_rate)       as p75_rate
      from per_shop group by zone_id, medicine_id
  ), prev as (
    select zone_id, medicine_id, sum(units) as units
      from _c427_old group by zone_id, medicine_id
  ), ins as (
    insert into public.pharmacy_network_sku_month
      (month_key, zone_id, medicine_id, category_code, product_name, pack_label,
       units, bills, pharmacy_count, median_rate, p25_rate, p75_rate,
       prev_units, delta_pct, computed_at)
    select v_month, c.zone_id, c.medicine_id,
           public._c419_category(m.therapeutic_class),
           c.product_name, c.pack_label,
           c.units, c.bills, c.n,
           round(c.median_rate, 2), round(c.p25_rate, 2), round(c.p75_rate, 2),
           coalesce(p.units, 0),
           case when coalesce(p.units, 0) > 0
                then round((c.units - p.units) / p.units * 100, 1) end,
           now()
      from cur c
      left join prev p on p.zone_id = c.zone_id and p.medicine_id = c.medicine_id
      left join public."MEDICINE" m on m.id = c.medicine_id
     where c.n >= v_floor
    returning 1
  )
  select (select count(*) from ins),
         (select count(*) from cur where n < v_floor)
    into v_skus, v_refused;

  -- Per supplier. Same floor: a supplier row that only two shops can see is
  -- two shops' private business, not a network rate.
  with per_shop as (
    select c.zone_id, c.medicine_id, c.supplier_key, c.pharmacy_id,
           max(c.supplier_label)                                         as supplier_label,
           sum(c.units)                                                  as units,
           percentile_cont(0.5) within group (order by c.rate)           as shop_rate
      from _c427_cur c
     where c.rate is not null and c.rate > 0
     group by c.zone_id, c.medicine_id, c.supplier_key, c.pharmacy_id
  ), sup as (
    select zone_id, medicine_id, supplier_key,
           max(supplier_label)                                           as supplier_label,
           sum(units)                                                    as units,
           count(distinct pharmacy_id)::int                              as n,
           percentile_cont(0.5) within group (order by shop_rate)        as median_rate,
           min(shop_rate)                                                as min_rate,
           max(shop_rate)                                                as max_rate
      from per_shop group by zone_id, medicine_id, supplier_key
  ), ins2 as (
    insert into public.pharmacy_network_supplier_rate
      (month_key, zone_id, medicine_id, supplier_key, supplier_label,
       units, pharmacy_count, median_rate, min_rate, max_rate, computed_at)
    select v_month, s.zone_id, s.medicine_id, s.supplier_key, s.supplier_label,
           s.units, s.n, round(s.median_rate, 2), round(s.min_rate, 2),
           round(s.max_rate, 2), now()
      from sup s where s.n >= v_floor
    returning 1
  )
  select (select count(*) from ins2),
         (select count(*) from sup where n < v_floor)
    into v_sup, v_sup_refused;

  return jsonb_build_object('ok', true, 'month', v_month, 'skus', v_skus,
    'supplier_rows', v_sup, 'refused_below_floor', v_refused + v_sup_refused,
    'min_cohort', v_floor);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

-- ── 6. SEASONALITY ─────────────────────────────────────────────────────────
-- Built from the STORED month rows, which already cleared the floor, so the
-- seasonal layer inherits the anonymity instead of re-deriving it.
create or replace function public.network_season_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_network_config := public._c427_cfg();
  v_sku integer := 0; v_cat integer := 0;
begin
  delete from public.pharmacy_sku_season;
  insert into public.pharmacy_sku_season
    (zone_id, medicine_id, month_no, factor, units, months_seen, pharmacy_count, computed_at)
  with base as (
    select zone_id, medicine_id,
           extract(month from month_key)::smallint as month_no,
           units, pharmacy_count
      from public.pharmacy_network_sku_month
  ), tot as (
    select zone_id, medicine_id,
           avg(units)                as mean_units,
           sum(units)                as all_units,
           count(*)                  as months_seen,
           max(pharmacy_count)       as shops
      from base group by zone_id, medicine_id
  ), mo as (
    select zone_id, medicine_id, month_no,
           avg(units) as month_units, count(*) as samples
      from base group by zone_id, medicine_id, month_no
  )
  select mo.zone_id, mo.medicine_id, mo.month_no,
         least(v_cfg.season_ceiling,
               greatest(v_cfg.season_floor,
                        round(mo.month_units / nullif(t.mean_units, 0), 3))),
         round(mo.month_units, 3), t.months_seen::int, t.shops, now()
    from mo join tot t on t.zone_id = mo.zone_id and t.medicine_id = mo.medicine_id
   where t.months_seen >= v_cfg.season_min_months
     and t.all_units   >= v_cfg.season_min_units
     and t.mean_units  > 0;
  get diagnostics v_sku = row_count;

  delete from public.pharmacy_category_season;
  insert into public.pharmacy_category_season
    (zone_id, category_code, month_no, factor, units, months_seen, computed_at)
  with base as (
    select zone_id, category_code,
           extract(month from month_key)::smallint as month_no,
           sum(units) as units
      from public.pharmacy_network_sku_month
     group by zone_id, category_code, month_key
  ), tot as (
    select zone_id, category_code, avg(units) as mean_units, count(*) as months_seen
      from base group by zone_id, category_code
  ), mo as (
    select zone_id, category_code, month_no, avg(units) as month_units
      from base group by zone_id, category_code, month_no
  )
  select mo.zone_id, mo.category_code, mo.month_no,
         least(v_cfg.season_ceiling,
               greatest(v_cfg.season_floor,
                        round(mo.month_units / nullif(t.mean_units, 0), 3))),
         round(mo.month_units, 3), t.months_seen::int, now()
    from mo join tot t on t.zone_id = mo.zone_id and t.category_code = mo.category_code
   where t.months_seen >= v_cfg.season_min_months and t.mean_units > 0;
  get diagnostics v_cat = row_count;

  -- Push the learned shape into #424's zone prior. `per_day` is untouched —
  -- it still means the flat rate; `per_day_season` is what a borrower reads.
  update public.pharmacy_zone_sku_prior z
     set season_factor  = f.factor,
         per_day_season = round(z.per_day * f.factor, 4)
    from (
      select z2.zone_id, z2.medicine_id,
             coalesce(s.factor, c.factor, 1) as factor
        from public.pharmacy_zone_sku_prior z2
        left join public.pharmacy_sku_season s
          on s.zone_id = z2.zone_id and s.medicine_id = z2.medicine_id
         and s.month_no = extract(month from public._c427_today())::smallint
        left join public."MEDICINE" m on m.id = z2.medicine_id
        left join public.pharmacy_category_season c
          on c.zone_id = z2.zone_id
         and c.category_code = public._c419_category(m.therapeutic_class)
         and c.month_no = extract(month from public._c427_today())::smallint
    ) f
   where f.zone_id = z.zone_id and f.medicine_id = z.medicine_id;

  return jsonb_build_object('ok', true, 'sku_factors', v_sku,
    'category_factors', v_cat, 'month_no', extract(month from public._c427_today())::int);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

-- ── 7. OVERPAY ─────────────────────────────────────────────────────────────
-- The strictest reading of the floor: the pharmacy being told is REMOVED from
-- its own comparison, and at least `floor` OTHER pharmacies must remain.
create or replace function public.network_overpay_refresh(p_month date default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg   public.pharmacy_network_config := public._c427_cfg();
  v_month date := public._c427_month(p_month);
  v_floor integer := public._c427_floor();
  v_from  date := (public._c427_month(p_month) + interval '1 month - 1 day')::date
                  - v_cfg.overpay_lookback_days;
  v_to    date := (public._c427_month(p_month) + interval '1 month - 1 day')::date;
  v_rows integer := 0; v_refused integer := 0;
begin
  delete from public.pharmacy_overpay_insight where month_key = v_month;

  with raw as (
    select * from public._c427_bill_units(v_from, v_to)
  ), per_shop as (
    -- one rate per (zone, sku, pharmacy) — never one per line
    select zone_id, medicine_id, pharmacy_id,
           max(product_name) as product_name,
           max(pack_label)   as pack_label,
           sum(units)        as units,
           percentile_cont(0.5) within group (order by rate) as shop_rate
      from raw where rate is not null and rate > 0
     group by zone_id, medicine_id, pharmacy_id
  ), peers as (
    -- for EACH subject shop: the median of the OTHER shops only
    select a.zone_id, a.medicine_id, a.pharmacy_id, a.product_name, a.pack_label,
           a.units, a.shop_rate,
           count(b.pharmacy_id)::int as peer_shops,
           percentile_cont(0.5) within group (order by b.shop_rate) as peer_median
      from per_shop a
      join per_shop b
        on b.zone_id = a.zone_id and b.medicine_id = a.medicine_id
       and b.pharmacy_id <> a.pharmacy_id
     group by a.zone_id, a.medicine_id, a.pharmacy_id, a.product_name,
              a.pack_label, a.units, a.shop_rate
  ), gap as (
    select p.*,
           round((p.shop_rate - p.peer_median) / nullif(p.peer_median, 0) * 100, 1) as delta_pct,
           round((p.shop_rate - p.peer_median) * p.units, 2)                        as impact
      from peers p
     where p.peer_median is not null and p.peer_median > 0
  ), eligible as (
    select g.*, row_number() over (partition by g.pharmacy_id
                                   order by g.impact desc, g.delta_pct desc) as rn
      from gap g
     where g.peer_shops >= v_floor
       and g.delta_pct  >= v_cfg.overpay_min_gap_pct
       and g.units      >= v_cfg.overpay_min_units
       and g.impact     > 0
  ), ins as (
    insert into public.pharmacy_overpay_insight
      (pharmacy_id, month_key, medicine_id, product_name, pack_label,
       your_rate, peer_median, delta_pct, units, impact, peer_shops, rank)
    select e.pharmacy_id, v_month, e.medicine_id, e.product_name, e.pack_label,
           round(e.shop_rate, 2), round(e.peer_median, 2), e.delta_pct,
           e.units, e.impact, e.peer_shops, e.rn::int
      from eligible e where e.rn <= v_cfg.overpay_max_rows
    on conflict (pharmacy_id, month_key, medicine_id) do nothing
    returning 1
  )
  select (select count(*) from ins),
         (select count(*) from gap
           where peer_shops < v_floor and delta_pct >= v_cfg.overpay_min_gap_pct)
    into v_rows, v_refused;

  return jsonb_build_object('ok', true, 'month', v_month, 'insights', v_rows,
    'refused_below_floor', v_refused, 'min_cohort', v_floor,
    'capped_at', v_cfg.overpay_max_rows);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

-- ── 8. #424's zone prior learns the season ─────────────────────────────────
-- Same body as CHANGE #424, plus the seasonal columns. `per_day` still means
-- exactly what it meant; `per_day_season` is what a borrower should read.
create or replace function public.pharmacy_zone_prior_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_cfg public.pharmacy_infer_config := public._c424_cfg(); v_n integer := 0;
        v_month smallint := extract(month from public._c427_today())::smallint;
begin
  insert into public.pharmacy_zone_sku_prior (zone_id, medicine_id, per_day, shops, computed_at)
  select p.zone_id, v.medicine_id, round(avg(v.per_day), 4), count(distinct v.pharmacy_id), now()
    from public.pharmacy_sku_velocity v
    join public.pharmacy_profiles p on p.id = v.pharmacy_id
   where v.source in ('own','pos','corrected') and p.zone_id is not null
   group by p.zone_id, v.medicine_id
  having count(distinct v.pharmacy_id) >= v_cfg.zone_min_shops
  on conflict (zone_id, medicine_id) do update
    set per_day = excluded.per_day, shops = excluded.shops, computed_at = now();
  get diagnostics v_n = row_count;

  -- CMD #427 — the seasonal shape the network learned from every vault.
  update public.pharmacy_zone_sku_prior z
     set season_factor  = f.factor,
         per_day_season = round(z.per_day * f.factor, 4)
    from (
      select z2.zone_id, z2.medicine_id,
             coalesce(s.factor, c.factor, 1) as factor
        from public.pharmacy_zone_sku_prior z2
        left join public.pharmacy_sku_season s
          on s.zone_id = z2.zone_id and s.medicine_id = z2.medicine_id
         and s.month_no = v_month
        left join public."MEDICINE" m on m.id = z2.medicine_id
        left join public.pharmacy_category_season c
          on c.zone_id = z2.zone_id
         and c.category_code = public._c419_category(m.therapeutic_class)
         and c.month_no = v_month
    ) f
   where f.zone_id = z.zone_id and f.medicine_id = z.medicine_id;

  return jsonb_build_object('ok', true, 'priors', v_n, 'min_shops', v_cfg.zone_min_shops,
                            'season_month', v_month);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

-- The borrower reads the seasonal rate when there is one. Same body as #424
-- otherwise — a SKU still on the bare prior borrows the zone's rate.
create or replace function public.pharmacy_velocity_learn(p_shop uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_infer_config := public._c424_cfg();
  v_from date := public._c424_today() - v_cfg.horizon_days;
  v_zone smallint;
  v_own integer := 0; v_zoned integer := 0;
begin
  if p_shop is null then return jsonb_build_object('ok', false, 'error', 'no_shop'); end if;
  select zone_id into v_zone from public.pharmacy_profiles where id = p_shop;

  with p as (
    select * from public._c424_purchases(p_shop, v_from)
  ), agg as (
    select medicine_id,
           count(*)                                   as buys,
           min(bought_on)                             as first_on,
           max(bought_on)                             as last_on,
           sum(qty)                                   as units_all,
           sum(qty) - (array_agg(qty order by bought_on desc))[1] as units_settled
      from p group by medicine_id
  ), gaps as (
    select medicine_id, buys, first_on, last_on, units_settled,
           greatest((last_on - first_on)::numeric, 0) as days_span,
           buys - 1                                   as gap_count
      from agg
  )
  insert into public.pharmacy_sku_velocity as v
    (pharmacy_id, medicine_id, alpha, beta, per_day, gaps, units_seen, days_seen,
     source, last_purchase_on, updated_at)
  select p_shop, g.medicine_id,
         v_cfg.prior_shape + coalesce(g.units_settled, 0),
         v_cfg.prior_rate  + g.days_span,
         (v_cfg.prior_shape + coalesce(g.units_settled, 0))
           / nullif(v_cfg.prior_rate + g.days_span, 0),
         g.gap_count, coalesce(g.units_settled, 0), g.days_span,
         case when g.gap_count >= v_cfg.own_min_gaps
                   and g.days_span between v_cfg.min_gap_days and v_cfg.max_gap_days * 4
              then 'own' else 'prior' end,
         g.last_on, now()
    from gaps g
  on conflict (pharmacy_id, medicine_id) do update
    set alpha = excluded.alpha, beta = excluded.beta, per_day = excluded.per_day,
        gaps = excluded.gaps, units_seen = excluded.units_seen,
        days_seen = excluded.days_seen,
        last_purchase_on = excluded.last_purchase_on,
        source = case when v.source in ('corrected','pos') then v.source
                      else excluded.source end,
        updated_at = now()
    where v.source not in ('corrected','pos');

  get diagnostics v_own = row_count;

  -- CMD #427: the borrowed rate is the SEASONAL one where the network learned
  -- a shape for this month, and the flat one everywhere else.
  update public.pharmacy_sku_velocity v
     set per_day = coalesce(z.per_day_season, z.per_day),
         alpha   = v_cfg.prior_shape + coalesce(z.per_day_season, z.per_day) * v_cfg.prior_rate,
         beta    = v_cfg.prior_rate,
         source  = 'zone',
         updated_at = now()
    from public.pharmacy_zone_sku_prior z
   where v.pharmacy_id = p_shop
     and v.medicine_id = z.medicine_id
     and z.zone_id = v_zone
     and z.shops >= v_cfg.zone_min_shops
     and v.source = 'prior';
  get diagnostics v_zoned = row_count;

  return jsonb_build_object('ok', true, 'skus', v_own, 'from_zone', v_zoned);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

-- ── 9. READ: the pharmacy's own overpay notes ──────────────────────────────
create or replace function public.pharmacy_overpay_entry()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); v_n integer := 0;
begin
  if v_shop is null then return jsonb_build_object('has', false); end if;
  select count(*) into v_n from public.pharmacy_overpay_insight
   where pharmacy_id = v_shop and status <> 'dismissed';
  return jsonb_build_object(
    'has', true,
    'label', public.ui_text('overpay427.entry'),
    'count', v_n,
    'badge', case when v_n > 0 then v_n::text else '' end);
exception when others then
  return jsonb_build_object('has', false);
end $$;

create or replace function public.pharmacy_overpay_insights()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_shop uuid := public.pos_shop();
  v_floor integer := public._c427_floor();
  v_rows jsonb; v_n integer := 0; v_total numeric := 0;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_pharmacy', 'tone', 'danger',
      'message', public.ui_text('overpay427.err_denied'));
  end if;

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), count(*), coalesce(sum(imp), 0)
    into v_rows, v_n, v_total
    from (
      select row_number() over (order by i.month_key desc, i.rank) as ord,
             i.impact as imp,
             jsonb_build_object(
               'id', i.id,
               'medicine_id', i.medicine_id,
               'name', i.product_name,
               'pack_label', coalesce(i.pack_label, ''),
               'headline', public.ui_text_f('overpay427.headline', jsonb_build_object(
                             'yours', public._c427_money(i.your_rate),
                             'peers', public._c427_money(i.peer_median),
                             'pct',   public._c427_pct(-i.delta_pct))),
               'detail', public.ui_text_f('overpay427.detail', jsonb_build_object(
                           'name', i.product_name,
                           'n',    i.peer_shops::text,
                           'impact', public._c427_money(i.impact))),
               'month_label', to_char(i.month_key, 'FMMonth YYYY'),
               'tone', case when i.delta_pct >= 20 then 'warning' else 'info' end,
               'action_label', public.ui_text('overpay427.action'),
               'route', '/product/' || i.medicine_id::text,
               'dismiss_label', public.ui_text('overpay427.dismiss'),
               'dismissed', (i.status = 'dismissed')) as x
        from public.pharmacy_overpay_insight i
       where i.pharmacy_id = v_shop and i.status <> 'dismissed'
       order by i.month_key desc, i.rank) q;

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('overpay427.title'),
    'subtitle', public.ui_text('overpay427.subtitle'),
    'privacy',  public.ui_text_f('overpay427.privacy', jsonb_build_object('n', v_floor::text)),
    'empty',    public.ui_text('overpay427.empty'),
    'total_label', case when v_n = 0 then ''
                        else public.ui_text_f('overpay427.total',
                               jsonb_build_object('amount', public._c427_money(v_total))) end,
    'count', v_n,
    'rows', v_rows);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

create or replace function public.pharmacy_overpay_dismiss(p_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); v_n integer := 0;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'message', public.ui_text('overpay427.err_denied'));
  end if;
  update public.pharmacy_overpay_insight
     set status = 'dismissed', dismissed_at = now()
   where id = p_id and pharmacy_id = v_shop;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0,
    'message', public.ui_text(case when v_n > 0 then 'overpay427.dismissed'
                                   else 'overpay427.err_gone' end));
exception when others then
  return jsonb_build_object('ok', false, 'message', SQLERRM);
end $$;

-- ── 10. READ: the admin demand engine ──────────────────────────────────────
create or replace function public.admin_demand_engine(
  p_zone integer default null, p_month date default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_network_config := public._c427_cfg();
  v_floor integer := public._c427_floor();
  v_month date := public._c427_month(p_month);
  v_zone smallint := p_zone::smallint;
  v_movers jsonb; v_rising jsonb; v_spread jsonb; v_season jsonb; v_zones jsonb;
  v_months jsonb; v_shops integer := 0; v_skus integer := 0; v_units numeric := 0;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_admin', 'tone', 'danger',
      'message', public.ui_text('demand427.err_denied'));
  end if;

  if v_zone is null then
    select zone_id into v_zone from public.pharmacy_network_sku_month
     where month_key = v_month group by zone_id order by sum(units) desc limit 1;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('key', z.id::text, 'label', z.name)
                            order by z.name), '[]'::jsonb)
    into v_zones from public.zones z
   where z.id in (select distinct zone_id from public.pharmacy_network_sku_month);

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', to_char(mk, 'YYYY-MM-DD'), 'label', to_char(mk, 'FMMon YYYY'))
           order by mk desc), '[]'::jsonb)
    into v_months
    from (select distinct month_key as mk from public.pharmacy_network_sku_month
           order by 1 desc limit 12) q;

  select coalesce(max(pharmacy_count), 0), count(*), coalesce(sum(units), 0)
    into v_shops, v_skus, v_units
    from public.pharmacy_network_sku_month
   where month_key = v_month and zone_id = v_zone;

  -- Top movers: what the zone buys most of.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_movers from (
    select row_number() over (order by s.units desc) as ord,
           jsonb_build_object(
             'medicine_id', s.medicine_id,
             'name', s.product_name,
             'pack_label', coalesce(s.pack_label, ''),
             'units_label', public.ui_text_f('demand427.units',
                              jsonb_build_object('n', trim_scale(round(s.units, 2))::text)),
             'rate_label', case when s.median_rate is null then ''
                                else public.ui_text_f('demand427.rate',
                                       jsonb_build_object('rate', public._c427_money(s.median_rate))) end,
             'spread_label', case when s.p25_rate is null or s.p75_rate is null then ''
                                  else public.ui_text_f('demand427.spread', jsonb_build_object(
                                         'low', public._c427_money(s.p25_rate),
                                         'high', public._c427_money(s.p75_rate))) end,
             'delta_label', case when s.delta_pct is null then ''
                                 else public._c427_pct(s.delta_pct) end,
             'cohort_label', public.ui_text_f('demand427.cohort',
                               jsonb_build_object('n', s.pharmacy_count::text)),
             'tone', case when coalesce(s.delta_pct, 0) >= v_cfg.min_growth_pct then 'success'
                          when coalesce(s.delta_pct, 0) <= -v_cfg.min_growth_pct then 'warning'
                          else 'info' end,
             'route', '/product/' || s.medicine_id::text) as x
      from public.pharmacy_network_sku_month s
     where s.month_key = v_month and s.zone_id = v_zone
       and s.pharmacy_count >= v_floor
     order by s.units desc limit v_cfg.top_n) q;

  -- Rising: what is growing fastest against last month.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_rising from (
    select row_number() over (order by s.delta_pct desc) as ord,
           jsonb_build_object(
             'medicine_id', s.medicine_id,
             'name', s.product_name,
             'units_label', public.ui_text_f('demand427.units',
                              jsonb_build_object('n', trim_scale(round(s.units, 2))::text)),
             'delta_label', public._c427_pct(s.delta_pct),
             'cohort_label', public.ui_text_f('demand427.cohort',
                               jsonb_build_object('n', s.pharmacy_count::text)),
             'tone', 'success',
             'route', '/product/' || s.medicine_id::text) as x
      from public.pharmacy_network_sku_month s
     where s.month_key = v_month and s.zone_id = v_zone
       and s.pharmacy_count >= v_floor
       and s.delta_pct is not null and s.delta_pct >= v_cfg.min_growth_pct
     order by s.delta_pct desc limit v_cfg.top_n) q;

  -- Rate spread by supplier: where the same box costs less.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_spread from (
    select row_number() over (order by r.units desc) as ord,
           jsonb_build_object(
             'medicine_id', r.medicine_id,
             'name', coalesce(s.product_name, '—'),
             'supplier', r.supplier_label,
             'rate_label', public._c427_money(r.median_rate),
             'range_label', public.ui_text_f('demand427.spread', jsonb_build_object(
                              'low', public._c427_money(r.min_rate),
                              'high', public._c427_money(r.max_rate))),
             'units_label', public.ui_text_f('demand427.units',
                              jsonb_build_object('n', trim_scale(round(r.units, 2))::text)),
             'cohort_label', public.ui_text_f('demand427.cohort',
                               jsonb_build_object('n', r.pharmacy_count::text)),
             'vs_label', case when s.median_rate is null or s.median_rate = 0 then ''
                              else public.ui_text_f('demand427.vs_network', jsonb_build_object(
                                     'pct', public._c427_pct(
                                       round((r.median_rate - s.median_rate) / s.median_rate * 100, 1)))) end,
             'tone', case when s.median_rate is not null and r.median_rate < s.median_rate
                          then 'success' else 'info' end) as x
      from public.pharmacy_network_supplier_rate r
      left join public.pharmacy_network_sku_month s
        on s.month_key = r.month_key and s.zone_id = r.zone_id and s.medicine_id = r.medicine_id
     where r.month_key = v_month and r.zone_id = v_zone
       and r.pharmacy_count >= v_floor
     order by r.units desc limit v_cfg.top_n) q;

  -- The seasonal shape for the month being read.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_season from (
    select row_number() over (order by abs(c.factor - 1) desc) as ord,
           jsonb_build_object(
             'key', c.category_code,
             'label', coalesce(cat.label, c.category_code),
             'factor_label', public.ui_text_f('demand427.factor',
                               jsonb_build_object('x', trim_scale(round(c.factor, 2))::text)),
             'tone', case when c.factor >= 1.15 then 'success'
                          when c.factor <= 0.85 then 'warning' else 'info' end) as x
      from public.pharmacy_category_season c
      left join public.pharmacy_insight_category cat on cat.code = c.category_code
     where c.zone_id = v_zone
       and c.month_no = extract(month from v_month)::smallint
     order by abs(c.factor - 1) desc limit v_cfg.top_n) q;

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('demand427.title'),
    'subtitle', public.ui_text('demand427.subtitle'),
    'privacy',  public.ui_text_f('demand427.privacy', jsonb_build_object('n', v_floor::text)),
    'zone_id',  v_zone,
    'zones',    v_zones,
    'month_key', to_char(v_month, 'YYYY-MM-DD'),
    'months',   v_months,
    'tiles', jsonb_build_array(
      jsonb_build_object('label', public.ui_text('demand427.t_skus'),
                         'value', v_skus::text, 'tone', 'info'),
      jsonb_build_object('label', public.ui_text('demand427.t_units'),
                         'value', trim_scale(round(v_units, 0))::text, 'tone', 'info'),
      jsonb_build_object('label', public.ui_text('demand427.t_shops'),
                         'value', v_shops::text, 'tone', 'success')),
    'tabs', jsonb_build_array(
      jsonb_build_object('key', 'movers', 'label', public.ui_text('demand427.tab_movers')),
      jsonb_build_object('key', 'rising', 'label', public.ui_text('demand427.tab_rising')),
      jsonb_build_object('key', 'spread', 'label', public.ui_text('demand427.tab_spread')),
      jsonb_build_object('key', 'season', 'label', public.ui_text('demand427.tab_season'))),
    'empty',  public.ui_text('demand427.empty'),
    'movers', v_movers, 'rising', v_rising, 'spread', v_spread, 'season', v_season);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

-- ── 11. Copy ───────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('overpay427.entry',     to_jsonb('Price check'::text)),
  ('overpay427.title',     to_jsonb('Price check'::text)),
  ('overpay427.subtitle',  to_jsonb('What your bills say you paid, next to what pharmacies near you paid for the same pack.'::text)),
  ('overpay427.headline',  to_jsonb('You paid {yours}; pharmacies near you pay {peers} ({pct})'::text)),
  ('overpay427.detail',    to_jsonb('Across {n} nearby pharmacies. At your volume that is about {impact} over the period.'::text)),
  ('overpay427.action',    to_jsonb('Get the mediBO price'::text)),
  ('overpay427.dismiss',   to_jsonb('Not useful'::text)),
  ('overpay427.dismissed', to_jsonb('Hidden. It will not come back this month.'::text)),
  ('overpay427.total',     to_jsonb('About {amount} across these lines'::text)),
  ('overpay427.privacy',   to_jsonb('Rates are a median across at least {n} pharmacies. No pharmacy or supplier is ever named, and yours is never shown to anyone.'::text)),
  ('overpay427.empty',     to_jsonb('Nothing to flag this month — your rates sit in line with pharmacies near you.'::text)),
  ('overpay427.err_denied',to_jsonb('This screen is for a pharmacy account.'::text)),
  ('overpay427.err_gone',  to_jsonb('That note is no longer here.'::text)),
  ('demand427.title',      to_jsonb('Demand engine'::text)),
  ('demand427.subtitle',   to_jsonb('What the zone actually buys, learned from every bill in the vault — including purchases mediBO never supplied.'::text)),
  ('demand427.privacy',    to_jsonb('Every row here is a group of at least {n} pharmacies. No pharmacy is named.'::text)),
  ('demand427.units',      to_jsonb('{n} units'::text)),
  ('demand427.rate',       to_jsonb('median {rate}'::text)),
  ('demand427.spread',     to_jsonb('{low} – {high}'::text)),
  ('demand427.cohort',     to_jsonb('{n} pharmacies'::text)),
  ('demand427.vs_network', to_jsonb('{pct} vs network'::text)),
  ('demand427.factor',     to_jsonb('x{x} this month'::text)),
  ('demand427.tab_movers', to_jsonb('Top movers'::text)),
  ('demand427.tab_rising', to_jsonb('Rising'::text)),
  ('demand427.tab_spread', to_jsonb('Rate spread'::text)),
  ('demand427.tab_season', to_jsonb('Seasonality'::text)),
  ('demand427.t_skus',     to_jsonb('SKUs'::text)),
  ('demand427.t_units',    to_jsonb('Units bought'::text)),
  ('demand427.t_shops',    to_jsonb('Pharmacies'::text)),
  ('demand427.empty',      to_jsonb('Nothing has cleared the anonymity floor for this zone and month yet.'::text)),
  ('demand427.err_denied', to_jsonb('The demand engine is for mediBO operators.'::text))
on conflict (key) do nothing;

-- ── 12. The dispatcher (#305) ──────────────────────────────────────────────
-- Off-peak IST, all three, in dependency order: demand feeds seasonality, and
-- both feed the overpay comparison. Never a bare */N schedule.
insert into public.cron_task (name, ord, mode, work_sql, base_interval_s,
                              run_at_ist, dml, note)
values
  ('c427-network-demand', 750, 'poll', 'select public.network_demand_refresh()',
   null, '02:40:00', true,
   'CMD #427 — monthly per-zone per-SKU purchase aggregate from every vault bill (including outside purchases). Writes only groups at or above the #419 cohort floor; a smaller group is stored nowhere.'),
  ('c427-network-season', 752, 'poll', 'select public.network_season_refresh()',
   null, '02:50:00', true,
   'CMD #427 — relearns the per-zone per-SKU monthly seasonal factors from the cohort-floored aggregate and pushes this month''s factor into #424''s zone priors.'),
  ('c427-network-overpay', 754, 'poll', 'select public.network_overpay_refresh()',
   null, '03:00:00', true,
   'CMD #427 — rebuilds each pharmacy''s capped monthly price-check notes. The subject pharmacy is removed from its own median and at least the floor in OTHER pharmacies must remain.')
on conflict (name) do update
  set work_sql = excluded.work_sql, run_at_ist = excluded.run_at_ist,
      ord = excluded.ord, dml = excluded.dml, note = excluded.note,
      enabled = true;

-- ── 13. Admin reachability ─────────────────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, category,
   surface, description, search_terms, roles_allowed)
values
  ('admin.demand_engine', 'Demand engine', 'Pharmacy tools', 'trending_up', 'demand_engine',
   445, 'parties', 'dashboard',
   'What the zone actually buys, and at what rate, learned from every bill in the vault.',
   'demand engine radar movers rising rate spread supplier seasonality network',
   array['admin','super_admin'])
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      icon_key = excluded.icon_key, group_label = excluded.group_label,
      description = excluded.description, search_terms = excluded.search_terms,
      is_active = true;

-- ── 14. Grants ─────────────────────────────────────────────────────────────
grant execute on function public.pharmacy_overpay_entry()            to authenticated;
grant execute on function public.pharmacy_overpay_insights()         to authenticated;
grant execute on function public.pharmacy_overpay_dismiss(uuid)      to authenticated;
grant execute on function public.admin_demand_engine(integer, date)  to authenticated;

revoke execute on function public.network_demand_refresh(date)  from anon, authenticated;
revoke execute on function public.network_season_refresh()      from anon, authenticated;
revoke execute on function public.network_overpay_refresh(date) from anon, authenticated;
revoke execute on function public._c427_bill_units(date, date)  from anon, authenticated;

-- CHANGE #419 — the screens the owner checks at night.
--
-- Three surfaces, one engine, and one rule that governs all of it: a pharmacy
-- is never identifiable in anything another pharmacy can read.
--
--   1. OWNER DASHBOARD — today's money, worked out from the shop's OWN data:
--      POS sales, landed cost off pharmacy_stock, dead and expiring value,
--      khata outstanding, the products and companies that actually earned.
--   2. BENCHMARK — the same shop against an ANONYMOUS cohort of similar shops
--      (same zone, same volume band). Framed as an opportunity, never a scold.
--   3. DEMAND RADAR — what the network is selling this week by therapeutic
--      class and by SKU, in this zone, with one tap to fill the mediBO cart.
--
-- ANONYMISATION IS STRUCTURAL, NOT POLITE. An aggregate row is only ever
-- WRITTEN when at least `min_cohort` (5) distinct pharmacies stand behind it,
-- and the refresh DELETES any stored row that has fallen under the floor. So a
-- small group is not "hidden by the reader" — it does not exist in the table
-- the reader can see. A pharmacy that has opted out contributes to NOTHING:
-- not a cohort, not a class, not a SKU, not a pharmacy count.
--
-- Every string on all three screens is here. Dart renders payloads verbatim.
-- Money is inr_money(); percentages, plurals and dates are composed in SQL.
--
-- Idempotent throughout: create-if-not-exists, create-or-replace, on-conflict.

-- ─────────────────────────── 1. CONFIG ──────────────────────────────────────

create table if not exists public.pharmacy_insight_config (
  id            boolean primary key default true check (id),
  min_cohort    integer not null default 5,   -- the floor. NEVER below 5.
  dead_days     integer not null default 90,  -- unsold this long = dead stock
  expiry_days   integer not null default 90,  -- expiring inside this = at risk
  top_n         integer not null default 5,   -- top products / companies
  radar_skus    integer not null default 12,  -- "stock these 12"
  min_growth_pct numeric not null default 15, -- below this a class is not news
  updated_at    timestamptz not null default now()
);
insert into public.pharmacy_insight_config (id) values (true)
  on conflict (id) do nothing;

-- The floor is a hard invariant, not a preference: a config edit can raise it
-- but never lower it below 5.
alter table public.pharmacy_insight_config
  drop constraint if exists pharmacy_insight_config_floor_ck;
alter table public.pharmacy_insight_config
  add constraint pharmacy_insight_config_floor_ck check (min_cohort >= 5);

comment on table public.pharmacy_insight_config is
  'CHANGE #419 — one row. min_cohort is the anonymisation floor: no network
   aggregate is ever stored or served over fewer distinct pharmacies, and the
   check constraint stops it being edited below 5.';

-- Volume bands. A shop is compared against shops of its own size, so a ₹4 lakh
-- counter is never told what a ₹40 lakh counter earns.
create table if not exists public.pharmacy_insight_band (
  code        text primary key,
  label       text not null,
  min_monthly numeric not null default 0,
  max_monthly numeric,                       -- null = open ended
  sort        integer not null default 100
);

insert into public.pharmacy_insight_band (code, label, min_monthly, max_monthly, sort) values
  ('band_a', 'Up to ₹1 lakh a month',      0,       100000,  10),
  ('band_b', '₹1–3 lakh a month',          100000,  300000,  20),
  ('band_c', '₹3–10 lakh a month',         300000,  1000000, 30),
  ('band_d', 'Over ₹10 lakh a month',      1000000, null,    40)
on conflict (code) do update
  set label = excluded.label, min_monthly = excluded.min_monthly,
      max_monthly = excluded.max_monthly, sort = excluded.sort;

-- Therapeutic classes as the owner talks about them. The map is DATA: a new
-- group is one INSERT, never a deploy. `match_rx` runs against
-- MEDICINE.therapeutic_class; the first active match by sort wins.
create table if not exists public.pharmacy_insight_category (
  code      text primary key,
  label     text not null,
  match_rx  text not null,
  sort      integer not null default 100,
  is_active boolean not null default true
);

insert into public.pharmacy_insight_category (code, label, match_rx, sort) values
  ('supplements',  'supplements',        'VITAMIN|MINERAL|NUTRA|NUTRIENT|SUPPLEMENT|TONIC|PROTEIN', 10),
  ('fever_pain',   'fever and pain',     'PAIN|ANALGESIC|ANTIPYRETIC|NSAID|ANTI ?INFLAMMATOR',      20),
  ('anti_infect',  'antibiotics',        'ANTI ?INFECTIVE|ANTIBIOTIC|ANTIBACTERIAL',                30),
  ('respiratory',  'cough and cold',     'RESPIRATOR|ASTHMA|COUGH|COLD|ANTIHISTAMIN',               40),
  ('gastro',       'stomach and acidity','GASTRO|ANTACID|ANTIEMETIC|LAXATIV',                       50),
  ('cardiac',      'heart and BP',       'CARDIAC|CARDIO|ANTIHYPERTENS|VASCULAR',                   60),
  ('diabetes',     'diabetes',           'DIABET|ANTIDIABETIC|INSULIN',                             70),
  ('derma',        'skin care',          'DERMA|TOPICAL|SKIN',                                      80),
  ('other',        'other medicines',    '.',                                                       999)
on conflict (code) do update
  set label = excluded.label, match_rx = excluded.match_rx, sort = excluded.sort;

-- Opt out. One flag, honoured by every aggregation in this file.
create table if not exists public.pharmacy_insight_optout (
  pharmacy_id uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  opted_out   boolean not null default false,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);

comment on table public.pharmacy_insight_optout is
  'CHANGE #419 — a pharmacy that sets opted_out contributes to NO network
   aggregate: not a benchmark cohort, not a demand class, not a SKU row, not a
   pharmacy count. Its own dashboard keeps working; only the sharing stops.';

-- ─────────────────────────── 2. HELPERS ─────────────────────────────────────

create or replace function public._c419_cfg()
returns public.pharmacy_insight_config
language sql stable security definer set search_path to 'public' as $$
  select * from public.pharmacy_insight_config where id;
$$;

create or replace function public._c419_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

create or replace function public._c419_money(p numeric)
returns text language sql stable security definer set search_path to 'public' as $$
  select public.inr_money(round(coalesce(p, 0)));
$$;

-- A signed percentage the way the screen prints it: '+40%' / '-18%' / '0%'.
create or replace function public._c419_pct(p numeric)
returns text language sql immutable as $$
  select case when coalesce(p,0) > 0 then '+' else '' end
         || trim_scale(round(coalesce(p,0), 1))::text || '%';
$$;

-- The therapeutic class of a medicine, in the owner's words.
create or replace function public._c419_category(p_class text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((
    select c.code from public.pharmacy_insight_category c
     where c.is_active and coalesce(p_class,'') ~* c.match_rx
     order by c.sort limit 1), 'other');
$$;

-- Every pharmacy whose data may enter a network aggregate.
create or replace function public._c419_sharing(p_shop uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select not coalesce((select o.opted_out from public.pharmacy_insight_optout o
                        where o.pharmacy_id = p_shop), false);
$$;

create or replace function public._c419_denied()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy', 'tone', 'danger',
                            'message', public.ui_text('owner419.err_denied'));
$$;

-- ─────────────────────────── 3. COPY ────────────────────────────────────────

insert into public.ui_copy (key, value) values
  ('owner419.err_denied',      to_jsonb('This screen belongs to a pharmacy account.'::text)),
  ('owner419.title',           to_jsonb('Your shop tonight'::text)),
  ('owner419.subtitle',        to_jsonb('Sales, profit and what is sitting still.'::text)),
  ('owner419.tile_label',      to_jsonb('Owner dashboard'::text)),
  ('owner419.range_today',     to_jsonb('Today'::text)),
  ('owner419.range_week',      to_jsonb('7 days'::text)),
  ('owner419.range_month',     to_jsonb('30 days'::text)),
  ('owner419.t_sales',         to_jsonb('Sales'::text)),
  ('owner419.t_profit',        to_jsonb('Gross profit'::text)),
  ('owner419.t_bills',         to_jsonb('Bills'::text)),
  ('owner419.t_avg',           to_jsonb('Average bill'::text)),
  ('owner419.t_dead',          to_jsonb('Dead stock'::text)),
  ('owner419.t_expiring',      to_jsonb('Expiring soon'::text)),
  ('owner419.t_khata',         to_jsonb('Khata outstanding'::text)),
  ('owner419.s_sales',         to_jsonb('{n} bills'::text)),
  ('owner419.s_profit',        to_jsonb('Cost known on {covered} of {total} lines'::text)),
  ('owner419.s_profit_none',   to_jsonb('No landed cost on the shelf yet'::text)),
  ('owner419.s_bills',         to_jsonb('Counter bills in this window'::text)),
  ('owner419.s_avg',           to_jsonb('Per bill, this window'::text)),
  ('owner419.s_dead',          to_jsonb('Nothing sold in {days} days'::text)),
  ('owner419.s_expiring',      to_jsonb('Expires within {days} days'::text)),
  ('owner419.s_khata',         to_jsonb('{n} accounts owe you'::text)),
  ('owner419.h_products',      to_jsonb('Top products'::text)),
  ('owner419.h_companies',     to_jsonb('Top companies'::text)),
  ('owner419.empty',           to_jsonb('No bills in this window yet.'::text)),
  ('owner419.empty_hint',      to_jsonb('Bill a patient on the counter and this fills up.'::text)),
  ('owner419.qty_units',       to_jsonb('{n} units'::text)),

  ('bench419.title',           to_jsonb('How you compare'::text)),
  ('bench419.subtitle',        to_jsonb('Against shops your size, nearby. Nobody is named.'::text)),
  ('bench419.cohort_label',    to_jsonb('{n} similar pharmacies · {band} · {zone}'::text)),
  ('bench419.card',            to_jsonb('Similar pharmacies earn {amount} a month more on {category} than you.'::text)),
  ('bench419.card_hint',       to_jsonb('Stocking a little deeper here is the easiest money on this list.'::text)),
  ('bench419.card_ahead',      to_jsonb('You earn {amount} a month more on {category} than shops your size.'::text)),
  ('bench419.card_ahead_hint', to_jsonb('Worth protecting — keep it in stock.'::text)),
  ('bench419.too_small',       to_jsonb('Not enough pharmacies near you yet.'::text)),
  ('bench419.too_small_hint',  to_jsonb('Comparisons need at least {n} similar shops so no single shop can be recognised. We will switch this on the moment there are.'::text)),
  ('bench419.no_gap',          to_jsonb('You are level with shops your size on every category we can compare.'::text)),
  ('bench419.optout_state',    to_jsonb('Your shop is out of the network comparison.'::text)),
  ('bench419.optout_hint',     to_jsonb('Nothing from your counter goes into any shared figure. Turn it back on to see how you compare.'::text)),
  ('bench419.optout_on',       to_jsonb('Share my totals anonymously'::text)),
  ('bench419.optout_off',      to_jsonb('Stop sharing my totals'::text)),
  ('bench419.optout_done_in',  to_jsonb('Your shop is back in the anonymous comparison.'::text)),
  ('bench419.optout_done_out', to_jsonb('Done — your shop is out of every shared figure.'::text)),
  ('bench419.privacy',         to_jsonb('Only group averages are ever shown, never a shop.'::text)),

  ('radar419.title',           to_jsonb('Demand radar'::text)),
  ('radar419.subtitle',        to_jsonb('What your zone is buying this week.'::text)),
  ('radar419.headline',        to_jsonb('{category} up {pct} in {zone} this week — stock these {n}.'::text)),
  ('radar419.headline_flat',   to_jsonb('Nothing is moving unusually in {zone} this week.'::text)),
  ('radar419.class_heading',   to_jsonb('By therapeutic class'::text)),
  ('radar419.sku_heading',     to_jsonb('SKUs to stock'::text)),
  ('radar419.units',           to_jsonb('{n} units'::text)),
  ('radar419.vs_prev',         to_jsonb('{pct} vs last week'::text)),
  ('radar419.add_all',         to_jsonb('Add all {n} to my cart'::text)),
  ('radar419.add_one',         to_jsonb('Add'::text)),
  ('radar419.added',           to_jsonb('{n} added to your mediBO cart. Nothing ordered yet — open the cart to confirm.'::text)),
  ('radar419.added_none',      to_jsonb('Nothing was added.'::text)),
  ('radar419.too_small',       to_jsonb('Your zone is still too quiet to read.'::text)),
  ('radar419.too_small_hint',  to_jsonb('The radar needs at least {n} pharmacies selling before a trend means anything.'::text)),
  ('radar419.in_stock',        to_jsonb('You have it'::text)),
  ('radar419.not_in_stock',    to_jsonb('Not on your shelf'::text))
on conflict (key) do nothing;

-- ─────────────────────────── 4. OWNER DASHBOARD ─────────────────────────────

-- The window the toggle picks. The KEYS are the backend's, so Dart sends back
-- exactly what it was given and never invents a range.
create or replace function public._c419_range(p_range text)
returns table (key text, label text, from_on date, days integer)
language sql stable security definer set search_path to 'public' as $$
  with t as (select public._c419_today() as d),
  r as (
    select case when coalesce(p_range,'today') in ('today','week','month')
                then coalesce(p_range,'today') else 'today' end as k
  )
  select r.k,
         public.ui_text('owner419.range_' || r.k),
         case r.k when 'today' then t.d
                  when 'week'  then t.d - 6
                  else              t.d - 29 end,
         case r.k when 'today' then 1 when 'week' then 7 else 30 end
    from r, t;
$$;

create or replace function public.pharmacy_owner_dashboard(p_range text default 'today')
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_shop uuid := public.pos_shop();
  v_cfg  public.pharmacy_insight_config;
  v_today date;
  v_key text; v_from date;
  v_sales numeric := 0; v_bills integer := 0; v_avg numeric := 0;
  v_profit numeric := 0; v_cov integer := 0; v_lines integer := 0;
  v_dead numeric := 0; v_exp numeric := 0; v_khata numeric := 0; v_khata_n integer := 0;
  v_products jsonb; v_companies jsonb; v_ranges jsonb;
begin
  if v_shop is null then return public._c419_denied(); end if;
  v_cfg := public._c419_cfg();
  v_today := public._c419_today();
  select key, from_on into v_key, v_from from public._c419_range(p_range);

  -- Money on the counter.
  select coalesce(sum(s.net_amount), 0), count(*)
    into v_sales, v_bills
    from public.pos_sales s
   where s.pharmacy_id = v_shop and s.status = 'completed'
     and s.sold_on between v_from and v_today;
  v_avg := case when v_bills > 0 then v_sales / v_bills else 0 end;

  -- Gross profit = what was billed ex-GST minus what the pack actually cost on
  -- the shelf. A line whose landed cost is unknown is EXCLUDED and counted, so
  -- the number is never quietly inflated by treating an unknown cost as zero.
  select coalesce(sum(l.taxable - (l.qty * c.cost)), 0),
         count(*) filter (where c.cost is not null),
         count(*)
    into v_profit, v_cov, v_lines
    from public.pos_sale_lines l
    join public.pos_sales s on s.id = l.sale_id
    left join lateral (
      select avg(nullif(st.unit_cost, 0)) as cost
        from public.pharmacy_stock st
       where st.pharmacy_id = v_shop and st.medicine_id = l.medicine_id
    ) c on true
   where s.pharmacy_id = v_shop and s.status = 'completed'
     and s.sold_on between v_from and v_today
     and c.cost is not null;

  select count(*) into v_lines
    from public.pos_sale_lines l join public.pos_sales s on s.id = l.sale_id
   where s.pharmacy_id = v_shop and s.status = 'completed'
     and s.sold_on between v_from and v_today;

  -- Dead stock: on the shelf, nothing sold in dead_days.
  select coalesce(sum(st.qty * coalesce(st.unit_cost, 0)), 0)
    into v_dead
    from public.pharmacy_stock st
   where st.pharmacy_id = v_shop and st.qty > 0
     and not exists (
       select 1 from public.pos_sale_lines l join public.pos_sales s on s.id = l.sale_id
        where s.pharmacy_id = v_shop and s.status = 'completed'
          and l.medicine_id = st.medicine_id
          and s.sold_on >= v_today - v_cfg.dead_days);

  select coalesce(sum(st.qty * coalesce(st.unit_cost, 0)), 0)
    into v_exp
    from public.pharmacy_stock st
   where st.pharmacy_id = v_shop and st.qty > 0
     and st.expiry_on is not null
     and st.expiry_on <= v_today + v_cfg.expiry_days;

  select coalesce(sum(k.balance), 0), count(*)
    into v_khata, v_khata_n
    from public.khata_account k
   where k.pharmacy_id = v_shop and k.is_active and k.balance > 0;

  -- Top products and companies, by what they actually billed.
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_products from (
    select jsonb_build_object(
             'rank', row_number() over (order by sum(l.amount) desc),
             'name', l.product_name,
             'value_label', public._c419_money(sum(l.amount)),
             'qty_label', public.ui_text_f('owner419.qty_units',
                            jsonb_build_object('n', trim_scale(round(sum(l.qty), 2))::text))) as x
      from public.pos_sale_lines l join public.pos_sales s on s.id = l.sale_id
     where s.pharmacy_id = v_shop and s.status = 'completed'
       and s.sold_on between v_from and v_today
     group by l.product_name
     order by sum(l.amount) desc
     limit v_cfg.top_n) q;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_companies from (
    select jsonb_build_object(
             'rank', row_number() over (order by sum(l.amount) desc),
             'name', coalesce(nullif(m.marketer, ''), m.marketer_canonical, '—'),
             'value_label', public._c419_money(sum(l.amount)),
             'qty_label', public.ui_text_f('owner419.qty_units',
                            jsonb_build_object('n', trim_scale(round(sum(l.qty), 2))::text))) as x
      from public.pos_sale_lines l
      join public.pos_sales s on s.id = l.sale_id
      left join public."MEDICINE" m on m.id = l.medicine_id
     where s.pharmacy_id = v_shop and s.status = 'completed'
       and s.sold_on between v_from and v_today
     group by coalesce(nullif(m.marketer, ''), m.marketer_canonical, '—')
     order by sum(l.amount) desc
     limit v_cfg.top_n) q;

  select jsonb_agg(jsonb_build_object('key', r.k, 'label', public.ui_text('owner419.range_' || r.k),
                                      'selected', r.k = v_key)
                   order by r.ord)
    into v_ranges
    from (values ('today', 1), ('week', 2), ('month', 3)) as r(k, ord);

  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('owner419.title'),
    'subtitle', public.ui_text('owner419.subtitle'),
    'range', v_key,
    'ranges', v_ranges,
    'has_sales', v_bills > 0,
    'empty', public.ui_text('owner419.empty'),
    'empty_hint', public.ui_text('owner419.empty_hint'),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','sales','label', public.ui_text('owner419.t_sales'),
        'value', public._c419_money(v_sales),
        'sub', public.ui_text_f('owner419.s_sales', jsonb_build_object('n', v_bills::text)),
        'tone','success'),
      jsonb_build_object('key','profit','label', public.ui_text('owner419.t_profit'),
        'value', public._c419_money(v_profit),
        'sub', case when v_cov = 0 then public.ui_text('owner419.s_profit_none')
                    else public.ui_text_f('owner419.s_profit',
                           jsonb_build_object('covered', v_cov::text, 'total', v_lines::text)) end,
        'tone', case when v_profit < 0 then 'danger' else 'success' end),
      jsonb_build_object('key','bills','label', public.ui_text('owner419.t_bills'),
        'value', v_bills::text,
        'sub', public.ui_text('owner419.s_bills'), 'tone','info'),
      jsonb_build_object('key','avg','label', public.ui_text('owner419.t_avg'),
        'value', public._c419_money(v_avg),
        'sub', public.ui_text('owner419.s_avg'), 'tone','info'),
      jsonb_build_object('key','dead','label', public.ui_text('owner419.t_dead'),
        'value', public._c419_money(v_dead),
        'sub', public.ui_text_f('owner419.s_dead',
                 jsonb_build_object('days', v_cfg.dead_days::text)),
        'tone', case when v_dead > 0 then 'warning' else 'info' end),
      jsonb_build_object('key','expiring','label', public.ui_text('owner419.t_expiring'),
        'value', public._c419_money(v_exp),
        'sub', public.ui_text_f('owner419.s_expiring',
                 jsonb_build_object('days', v_cfg.expiry_days::text)),
        'tone', case when v_exp > 0 then 'danger' else 'info' end),
      jsonb_build_object('key','khata','label', public.ui_text('owner419.t_khata'),
        'value', public._c419_money(v_khata),
        'sub', public.ui_text_f('owner419.s_khata', jsonb_build_object('n', v_khata_n::text)),
        'tone', case when v_khata > 0 then 'warning' else 'info' end)),
    'sections', jsonb_build_array(
      jsonb_build_object('key','products','heading', public.ui_text('owner419.h_products'),
                         'rows', v_products),
      jsonb_build_object('key','companies','heading', public.ui_text('owner419.h_companies'),
                         'rows', v_companies)));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

comment on function public.pharmacy_owner_dashboard(text) is
  'CHANGE #419 — the owner''s night screen in ONE call. Every rupee, caption and
   range label is composed here; Dart prints them. Gross profit excludes lines
   with no landed cost and SAYS how many it could price, rather than treating an
   unknown cost as zero.';

-- ─────────────────────────── 5. BENCHMARK ───────────────────────────────────

-- Per-pharmacy monthly totals, the input both the band and the cohort use.
-- Opted-out shops are absent from this view entirely.
create or replace function public._c419_month_sales(p_from date, p_to date)
returns table (pharmacy_id uuid, zone_id smallint, category_code text, amount numeric)
language sql stable security definer set search_path to 'public' as $$
  select s.pharmacy_id,
         p.zone_id,
         public._c419_category(m.therapeutic_class) as category_code,
         sum(l.amount) as amount
    from public.pos_sale_lines l
    join public.pos_sales s on s.id = l.sale_id
    join public.pharmacy_profiles p on p.id = s.pharmacy_id
    left join public."MEDICINE" m on m.id = l.medicine_id
   where s.status = 'completed'
     and s.sold_on between p_from and p_to
     and p.zone_id is not null
     and public._c419_sharing(s.pharmacy_id)
   group by s.pharmacy_id, p.zone_id, public._c419_category(m.therapeutic_class);
$$;

create or replace function public._c419_band(p_monthly numeric)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((
    select b.code from public.pharmacy_insight_band b
     where coalesce(p_monthly,0) >= b.min_monthly
       and (b.max_monthly is null or coalesce(p_monthly,0) < b.max_monthly)
     order by b.sort limit 1), 'band_a');
$$;

create table if not exists public.pharmacy_bench_cohort (
  period_start   date     not null,
  zone_id        smallint not null,
  band_code      text     not null,
  category_code  text     not null,
  pharmacy_count integer  not null,
  avg_monthly    numeric  not null default 0,
  median_monthly numeric  not null default 0,
  computed_at    timestamptz not null default now(),
  primary key (period_start, zone_id, band_code, category_code)
);

comment on table public.pharmacy_bench_cohort is
  'CHANGE #419 — anonymous cohort averages. A row EXISTS only while at least
   pharmacy_insight_config.min_cohort distinct opted-in pharmacies stand behind
   it; the refresh deletes any row that falls under the floor, so a small group
   is not merely hidden from the reader — it is not stored.';

create index if not exists pharmacy_bench_cohort_lookup_idx
  on public.pharmacy_bench_cohort (zone_id, band_code, period_start);

-- Nobody reads the cohort table directly; the RPCs are security definer.
alter table public.pharmacy_bench_cohort enable row level security;
alter table public.pharmacy_insight_optout enable row level security;
alter table public.pharmacy_insight_config enable row level security;

create or replace function public.pharmacy_bench_refresh(p_to date default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_insight_config := public._c419_cfg();
  v_to date := coalesce(p_to, public._c419_today());
  v_from date := coalesce(p_to, public._c419_today()) - 29;
  v_period date := date_trunc('month', coalesce(p_to, public._c419_today()))::date;
  v_kept integer := 0; v_refused integer := 0;
begin
  create temp table if not exists _c419_ms (
    pharmacy_id uuid, zone_id smallint, category_code text, amount numeric) on commit drop;
  delete from _c419_ms;
  insert into _c419_ms select * from public._c419_month_sales(v_from, v_to);

  -- The whole previous period goes first: a cohort that has fallen under the
  -- floor since the last run must STOP existing, not linger.
  delete from public.pharmacy_bench_cohort where period_start = v_period;

  with banded as (
    select m.pharmacy_id, m.zone_id, m.category_code, m.amount,
           public._c419_band(t.total) as band_code
      from _c419_ms m
      join (select pharmacy_id, sum(amount) as total from _c419_ms group by pharmacy_id) t
        on t.pharmacy_id = m.pharmacy_id
  ), grouped as (
    select zone_id, band_code, category_code,
           count(distinct pharmacy_id) as n,
           avg(amount) as avg_amt,
           percentile_cont(0.5) within group (order by amount)::numeric as med_amt
      from banded
     group by zone_id, band_code, category_code
  ), kept as (
    insert into public.pharmacy_bench_cohort
      (period_start, zone_id, band_code, category_code, pharmacy_count,
       avg_monthly, median_monthly, computed_at)
    select v_period, zone_id, band_code, category_code, n,
           round(avg_amt::numeric, 2), round(med_amt::numeric, 2), now()
      from grouped
     where n >= v_cfg.min_cohort
    returning 1
  )
  select (select count(*) from kept),
         (select count(*) from grouped where n < v_cfg.min_cohort)
    into v_kept, v_refused;

  return jsonb_build_object('ok', true, 'period', v_period, 'kept', v_kept,
                            'refused_below_floor', v_refused,
                            'min_cohort', v_cfg.min_cohort);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

comment on function public.pharmacy_bench_refresh(date) is
  'CHANGE #419 — nightly. Buckets every opted-in pharmacy by zone and volume
   band, and writes ONLY the groups with min_cohort or more distinct shops.
   Groups under the floor are counted in refused_below_floor and stored nowhere.';

create or replace function public.pharmacy_benchmark()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_shop uuid := public.pos_shop();
  v_cfg public.pharmacy_insight_config;
  v_today date; v_period date; v_zone smallint; v_zone_name text;
  v_total numeric := 0; v_band text; v_band_label text;
  v_cards jsonb; v_n integer := 0; v_max integer := 0;
begin
  if v_shop is null then return public._c419_denied(); end if;
  v_cfg := public._c419_cfg();
  v_today := public._c419_today();
  v_period := date_trunc('month', v_today)::date;

  if not public._c419_sharing(v_shop) then
    return jsonb_build_object(
      'ok', true, 'state', 'opted_out',
      'title', public.ui_text('bench419.title'),
      'subtitle', public.ui_text('bench419.subtitle'),
      'message', public.ui_text('bench419.optout_state'),
      'hint', public.ui_text('bench419.optout_hint'),
      'sharing', false,
      'toggle_label', public.ui_text('bench419.optout_on'),
      'privacy', public.ui_text('bench419.privacy'),
      'cards', '[]'::jsonb);
  end if;

  select p.zone_id, z.name into v_zone, v_zone_name
    from public.pharmacy_profiles p
    left join public.zones z on z.id = p.zone_id
   where p.id = v_shop;

  select coalesce(sum(amount), 0) into v_total
    from public._c419_month_sales(v_today - 29, v_today) where pharmacy_id = v_shop;
  v_band := public._c419_band(v_total);
  select label into v_band_label from public.pharmacy_insight_band where code = v_band;

  select coalesce(max(pharmacy_count), 0) into v_max
    from public.pharmacy_bench_cohort
   where period_start = v_period and zone_id = v_zone and band_code = v_band;

  if v_max < v_cfg.min_cohort then
    -- Either nothing is stored for this group, or what is stored is under the
    -- floor. Both answers are the same sentence, and neither leaks a count.
    return jsonb_build_object(
      'ok', true, 'state', 'too_small',
      'title', public.ui_text('bench419.title'),
      'subtitle', public.ui_text('bench419.subtitle'),
      'message', public.ui_text('bench419.too_small'),
      'hint', public.ui_text_f('bench419.too_small_hint',
                jsonb_build_object('n', v_cfg.min_cohort::text)),
      'sharing', true,
      'toggle_label', public.ui_text('bench419.optout_off'),
      'privacy', public.ui_text('bench419.privacy'),
      'cards', '[]'::jsonb);
  end if;

  with mine as (
    select category_code, sum(amount) as amount
      from public._c419_month_sales(v_today - 29, v_today)
     where pharmacy_id = v_shop group by category_code
  ), pairs as (
    select ch.category_code, cat.label as category_label,
           ch.avg_monthly, ch.pharmacy_count,
           coalesce(m.amount, 0) as my_amount,
           ch.avg_monthly - coalesce(m.amount, 0) as gap
      from public.pharmacy_bench_cohort ch
      join public.pharmacy_insight_category cat on cat.code = ch.category_code
      left join mine m on m.category_code = ch.category_code
     where ch.period_start = v_period and ch.zone_id = v_zone
       and ch.band_code = v_band and ch.pharmacy_count >= v_cfg.min_cohort
  )
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), count(*)
    into v_cards, v_n
    from (
      select case when gap > 0 then 0 else 1 end as ord,
             jsonb_build_object(
               'category', category_code,
               'tone', case when gap > 0 then 'warning' else 'success' end,
               'ahead', gap <= 0,
               'headline', case when gap > 0
                 then public.ui_text_f('bench419.card', jsonb_build_object(
                        'amount', public._c419_money(gap), 'category', category_label))
                 else public.ui_text_f('bench419.card_ahead', jsonb_build_object(
                        'amount', public._c419_money(abs(gap)), 'category', category_label)) end,
               'hint', case when gap > 0 then public.ui_text('bench419.card_hint')
                            else public.ui_text('bench419.card_ahead_hint') end,
               'mine_label', public._c419_money(my_amount),
               'cohort_label', public._c419_money(avg_monthly)) as x
        from pairs
       where abs(gap) >= 1
       order by case when gap > 0 then 0 else 1 end, abs(gap) desc
       limit 6) q;

  return jsonb_build_object(
    'ok', true, 'state', case when v_n = 0 then 'no_gap' else 'ready' end,
    'title', public.ui_text('bench419.title'),
    'subtitle', public.ui_text('bench419.subtitle'),
    'cohort_label', public.ui_text_f('bench419.cohort_label', jsonb_build_object(
       'n', v_max::text, 'band', coalesce(v_band_label, ''), 'zone', coalesce(v_zone_name, ''))),
    'message', case when v_n = 0 then public.ui_text('bench419.no_gap') else '' end,
    'hint', '',
    'sharing', true,
    'toggle_label', public.ui_text('bench419.optout_off'),
    'privacy', public.ui_text('bench419.privacy'),
    'cards', v_cards);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

create or replace function public.pharmacy_insight_optout_set(p_out boolean)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop();
begin
  if v_shop is null then return public._c419_denied(); end if;
  insert into public.pharmacy_insight_optout (pharmacy_id, opted_out, updated_by, updated_at)
  values (v_shop, coalesce(p_out, false), auth.uid(), now())
  on conflict (pharmacy_id) do update
    set opted_out = excluded.opted_out, updated_by = excluded.updated_by,
        updated_at = now();
  return jsonb_build_object('ok', true, 'tone', 'success',
    'sharing', not coalesce(p_out, false),
    'message', case when coalesce(p_out, false)
                    then public.ui_text('bench419.optout_done_out')
                    else public.ui_text('bench419.optout_done_in') end);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

-- ─────────────────────────── 6. DEMAND RADAR ────────────────────────────────

create table if not exists public.pharmacy_demand_class (
  week_start     date     not null,
  zone_id        smallint not null,
  category_code  text     not null,
  units          numeric  not null default 0,
  prev_units     numeric  not null default 0,
  delta_pct      numeric,
  pharmacy_count integer  not null,
  sku_count      integer  not null default 0,
  computed_at    timestamptz not null default now(),
  primary key (week_start, zone_id, category_code)
);

create table if not exists public.pharmacy_demand_sku (
  week_start     date     not null,
  zone_id        smallint not null,
  medicine_id    bigint   not null,
  category_code  text     not null,
  product_name   text     not null,
  units          numeric  not null default 0,
  prev_units     numeric  not null default 0,
  delta_pct      numeric,
  pharmacy_count integer  not null,
  computed_at    timestamptz not null default now(),
  primary key (week_start, zone_id, medicine_id)
);

comment on table public.pharmacy_demand_sku is
  'CHANGE #419 — zone SKU velocity, POS plus mediBO orders. Same floor as the
   benchmark: a SKU row is written only when min_cohort distinct pharmacies
   bought or sold it, so "this shop bought that" can never be read out of it.';

create index if not exists pharmacy_demand_sku_zone_idx
  on public.pharmacy_demand_sku (zone_id, week_start, delta_pct desc);

alter table public.pharmacy_demand_class enable row level security;
alter table public.pharmacy_demand_sku   enable row level security;

-- Units moved in one week, from BOTH sources, per (zone, medicine, pharmacy).
create or replace function public._c419_units(p_from date, p_to date)
returns table (zone_id smallint, medicine_id bigint, product_name text,
               pharmacy_id uuid, units numeric)
language sql stable security definer set search_path to 'public' as $$
  select p.zone_id, l.medicine_id, max(l.product_name), s.pharmacy_id, sum(l.qty)
    from public.pos_sale_lines l
    join public.pos_sales s on s.id = l.sale_id
    join public.pharmacy_profiles p on p.id = s.pharmacy_id
   where s.status = 'completed' and s.sold_on between p_from and p_to
     and p.zone_id is not null and l.medicine_id is not null
     and public._c419_sharing(s.pharmacy_id)
   group by p.zone_id, l.medicine_id, s.pharmacy_id
  union all
  select p.zone_id, oi.product_id::bigint, max(oi.product_name), o.customer_id, sum(oi.quantity)
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.pharmacy_profiles p on p.id = o.customer_id
   where o.order_date between p_from and p_to
     and p.zone_id is not null and oi.product_id is not null
     and coalesce(oi.unfulfillable, false) = false
     and public._c419_sharing(o.customer_id)
   group by p.zone_id, oi.product_id, o.customer_id;
$$;

create or replace function public.pharmacy_demand_refresh(p_week date default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_insight_config := public._c419_cfg();
  v_week date := coalesce(p_week, date_trunc('week', public._c419_today())::date);
  v_prev date; v_classes integer := 0; v_skus integer := 0; v_refused integer := 0;
begin
  v_prev := v_week - 7;

  create temp table if not exists _c419_now (
    zone_id smallint, medicine_id bigint, product_name text, pharmacy_id uuid, units numeric)
    on commit drop;
  create temp table if not exists _c419_old (
    zone_id smallint, medicine_id bigint, product_name text, pharmacy_id uuid, units numeric)
    on commit drop;
  delete from _c419_now; delete from _c419_old;
  insert into _c419_now select * from public._c419_units(v_week, v_week + 6);
  insert into _c419_old select * from public._c419_units(v_prev, v_prev + 6);

  delete from public.pharmacy_demand_sku   where week_start = v_week;
  delete from public.pharmacy_demand_class where week_start = v_week;

  with cur as (
    select zone_id, medicine_id, max(product_name) as product_name,
           sum(units) as units, count(distinct pharmacy_id) as n
      from _c419_now group by zone_id, medicine_id
  ), prev as (
    select zone_id, medicine_id, sum(units) as units from _c419_old group by zone_id, medicine_id
  ), joined as (
    select c.*, coalesce(p.units, 0) as prev_units,
           public._c419_category(m.therapeutic_class) as category_code
      from cur c
      left join prev p on p.zone_id = c.zone_id and p.medicine_id = c.medicine_id
      left join public."MEDICINE" m on m.id = c.medicine_id
  ), ins as (
    insert into public.pharmacy_demand_sku
      (week_start, zone_id, medicine_id, category_code, product_name, units,
       prev_units, delta_pct, pharmacy_count, computed_at)
    select v_week, zone_id, medicine_id, category_code, coalesce(product_name, '—'),
           units, prev_units,
           case when prev_units > 0 then round((units - prev_units) / prev_units * 100, 1)
                else null end,
           n, now()
      from joined where n >= v_cfg.min_cohort
    returning 1
  )
  select (select count(*) from ins),
         (select count(*) from joined where n < v_cfg.min_cohort)
    into v_skus, v_refused;

  -- Classes are aggregated from the SAME raw rows, not from the stored SKU
  -- rows: a class is legitimately above the floor even when no single SKU in
  -- it is, and it stays anonymous because its own pharmacy count is checked.
  with cur as (
    select n.zone_id, public._c419_category(m.therapeutic_class) as category_code,
           sum(n.units) as units, count(distinct n.pharmacy_id) as np,
           count(distinct n.medicine_id) as ns
      from _c419_now n left join public."MEDICINE" m on m.id = n.medicine_id
     group by n.zone_id, public._c419_category(m.therapeutic_class)
  ), prev as (
    select o.zone_id, public._c419_category(m.therapeutic_class) as category_code,
           sum(o.units) as units
      from _c419_old o left join public."MEDICINE" m on m.id = o.medicine_id
     group by o.zone_id, public._c419_category(m.therapeutic_class)
  ), ins2 as (
    insert into public.pharmacy_demand_class
      (week_start, zone_id, category_code, units, prev_units, delta_pct,
       pharmacy_count, sku_count, computed_at)
    select v_week, c.zone_id, c.category_code, c.units, coalesce(p.units, 0),
           case when coalesce(p.units, 0) > 0
                then round((c.units - p.units) / p.units * 100, 1) else null end,
           c.np, c.ns, now()
      from cur c left join prev p
        on p.zone_id = c.zone_id and p.category_code = c.category_code
     where c.np >= v_cfg.min_cohort
    returning 1
  )
  select count(*) into v_classes from ins2;

  return jsonb_build_object('ok', true, 'week', v_week, 'skus', v_skus,
                            'classes', v_classes, 'refused_below_floor', v_refused,
                            'min_cohort', v_cfg.min_cohort);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

create or replace function public.pharmacy_demand_radar()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_shop uuid := public.pos_shop();
  v_cfg public.pharmacy_insight_config;
  v_week date; v_zone smallint; v_zone_name text;
  v_classes jsonb; v_skus jsonb; v_top record; v_headline text; v_n integer := 0;
begin
  if v_shop is null then return public._c419_denied(); end if;
  v_cfg := public._c419_cfg();
  v_week := date_trunc('week', public._c419_today())::date;

  select p.zone_id, z.name into v_zone, v_zone_name
    from public.pharmacy_profiles p
    left join public.zones z on z.id = p.zone_id
   where p.id = v_shop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', d.category_code,
           'label', cat.label,
           'units_label', public.ui_text_f('radar419.units',
                            jsonb_build_object('n', trim_scale(round(d.units, 2))::text)),
           'delta_label', case when d.delta_pct is null then ''
                               else public.ui_text_f('radar419.vs_prev',
                                      jsonb_build_object('pct', public._c419_pct(d.delta_pct))) end,
           'tone', case when coalesce(d.delta_pct, 0) >= v_cfg.min_growth_pct then 'success'
                        when coalesce(d.delta_pct, 0) <= -v_cfg.min_growth_pct then 'warning'
                        else 'info' end)
         order by d.units desc), '[]'::jsonb)
    into v_classes
    from public.pharmacy_demand_class d
    join public.pharmacy_insight_category cat on cat.code = d.category_code
   where d.week_start = v_week and d.zone_id = v_zone
     and d.pharmacy_count >= v_cfg.min_cohort;

  if v_classes = '[]'::jsonb then
    return jsonb_build_object(
      'ok', true, 'state', 'too_small',
      'title', public.ui_text('radar419.title'),
      'subtitle', public.ui_text('radar419.subtitle'),
      'message', public.ui_text('radar419.too_small'),
      'hint', public.ui_text_f('radar419.too_small_hint',
                jsonb_build_object('n', v_cfg.min_cohort::text)),
      'classes', '[]'::jsonb, 'rows', '[]'::jsonb);
  end if;

  -- The SKUs to actually stock: the fastest movers in this zone, the ones the
  -- shelf is missing first.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), count(*)
    into v_skus, v_n
    from (
      select row_number() over (order by coalesce(s.delta_pct, 0) desc, s.units desc) as ord,
             jsonb_build_object(
               'medicine_id', s.medicine_id,
               'name', s.product_name,
               'category', s.category_code,
               'units_label', public.ui_text_f('radar419.units',
                                jsonb_build_object('n', trim_scale(round(s.units, 2))::text)),
               'delta_label', case when s.delta_pct is null then ''
                                   else public.ui_text_f('radar419.vs_prev',
                                          jsonb_build_object('pct', public._c419_pct(s.delta_pct))) end,
               'tone', case when coalesce(s.delta_pct, 0) >= v_cfg.min_growth_pct
                            then 'success' else 'info' end,
               'stock_label', case when exists (
                                select 1 from public.pharmacy_stock st
                                 where st.pharmacy_id = v_shop
                                   and st.medicine_id = s.medicine_id and st.qty > 0)
                              then public.ui_text('radar419.in_stock')
                              else public.ui_text('radar419.not_in_stock') end,
               'add_label', public.ui_text('radar419.add_one'),
               'qty', 1) as x
        from public.pharmacy_demand_sku s
       where s.week_start = v_week and s.zone_id = v_zone
         and s.pharmacy_count >= v_cfg.min_cohort
       order by coalesce(s.delta_pct, 0) desc, s.units desc
       limit v_cfg.radar_skus) q;

  select cat.label as label, d.delta_pct as pct
    into v_top
    from public.pharmacy_demand_class d
    join public.pharmacy_insight_category cat on cat.code = d.category_code
   where d.week_start = v_week and d.zone_id = v_zone
     and d.pharmacy_count >= v_cfg.min_cohort
     and coalesce(d.delta_pct, 0) >= v_cfg.min_growth_pct
   order by d.delta_pct desc limit 1;

  if v_top.label is null or v_n = 0 then
    v_headline := public.ui_text_f('radar419.headline_flat',
                    jsonb_build_object('zone', coalesce(v_zone_name, '')));
  else
    v_headline := public.ui_text_f('radar419.headline', jsonb_build_object(
      'category', upper(left(v_top.label, 1)) || substr(v_top.label, 2), 'pct', public._c419_pct(v_top.pct),
      'zone', coalesce(v_zone_name, ''), 'n', v_n::text));
  end if;

  return jsonb_build_object(
    'ok', true, 'state', 'ready',
    'title', public.ui_text('radar419.title'),
    'subtitle', public.ui_text('radar419.subtitle'),
    'headline', v_headline,
    'class_heading', public.ui_text('radar419.class_heading'),
    'sku_heading', public.ui_text('radar419.sku_heading'),
    'add_all_label', public.ui_text_f('radar419.add_all',
                       jsonb_build_object('n', v_n::text)),
    'classes', v_classes,
    'rows', v_skus);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

-- One tap fills the mediBO cart. Nothing is ordered here — same rule as #414.
create or replace function public.pharmacy_demand_add(p_items jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); it jsonb; v_n integer := 0; v_qty integer;
begin
  if v_shop is null then return public._c419_denied(); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'tone', 'info', 'added', 0,
      'message', public.ui_text('radar419.added_none'));
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    v_qty := greatest(1, coalesce((it->>'qty')::numeric, 1)::int);
    begin
      perform public.cart_set_item((it->>'medicine_id')::text, v_qty, null);
      v_n := v_n + 1;
    exception when others then null;   -- one bad line never sinks the rest
    end;
  end loop;

  if v_n = 0 then
    return jsonb_build_object('ok', false, 'tone', 'info', 'added', 0,
      'message', public.ui_text('radar419.added_none'));
  end if;
  return jsonb_build_object('ok', true, 'tone', 'success', 'added', v_n,
    'message', public.ui_text_f('radar419.added', jsonb_build_object('n', v_n::text)));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
                            'message', SQLERRM);
end $$;

-- ─────────────────────────── 7. THE ONE DISPATCHER (#305) ───────────────────

insert into public.cron_task (name, ord, mode, work_sql, enabled, note, run_at_ist) values
  ('pharmacy-bench-refresh', 730, 'poll',
   'select public.pharmacy_bench_refresh()', true,
   'CHANGE #419 — nightly cohort averages for the owner benchmark. Writes only '
   'groups with min_cohort or more distinct opted-in pharmacies and deletes the '
   'period first, so a group that fell under the floor stops existing.',
   time '03:10'),
  ('pharmacy-demand-refresh', 735, 'poll',
   'select public.pharmacy_demand_refresh()', true,
   'CHANGE #419 — weekly-window demand radar per zone (POS + mediBO orders), '
   'recomputed nightly for the current week. Same cohort floor.',
   time '03:25')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = excluded.enabled,
      run_at_ist = excluded.run_at_ist, note = excluded.note, ord = excluded.ord;

-- ─────────────────────────── 8. RECORDED PROOF ──────────────────────────────

-- Seeds a whole synthetic network, runs both refreshes and asserts the floor
-- both ways: a 6-shop zone is aggregated, a 3-shop zone is refused. Everything
-- it creates is deleted before it returns, whatever happens.
create or replace function public.c419_cohort_proof()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_insight_config := public._c419_cfg();
  v_big smallint; v_small smallint;
  v_med bigint; v_shop uuid; v_sale uuid; v_week date := date_trunc('week', public._c419_today())::date;
  v_ids uuid[] := '{}'; i integer;
  v_big_rows integer; v_small_rows integer; v_bench jsonb; v_radar jsonb;
  v_big_cohort integer; v_small_cohort integer;
begin
  select 900, 901 into v_big, v_small;
  select id into v_med from public."MEDICINE" where therapeutic_class ilike '%VITAMIN%' limit 1;
  if v_med is null then select id into v_med from public."MEDICINE" limit 1; end if;

  insert into public.zones (id, code, name, is_active) values
    (v_big, 'C419BIG', 'C419 Proof Big', false),
    (v_small, 'C419SML', 'C419 Proof Small', false)
  on conflict (id) do nothing;

  -- 6 shops in the big zone, 3 in the small one.
  for i in 1..9 loop
    insert into public.pharmacy_profiles (user_id, pharmacy_name, customer_name,
                                          address, city, pincode, zone_id, approved, status)
    values (gen_random_uuid(), 'C419 proof shop ' || i, 'C419 proof ' || i,
            'proof', 'proof', '000000',
            case when i <= 6 then v_big else v_small end, true, 'approved')
    returning id into v_shop;
    v_ids := v_ids || v_shop;

    insert into public.pos_sales (pharmacy_id, fy, invoice_seq, invoice_no, sold_on,
                                  status, net_amount, client_action_id)
    values (v_shop, '2026-27', i, 'C419/' || i, public._c419_today(), 'completed',
            5000 + i * 100, gen_random_uuid())
    returning id into v_sale;

    insert into public.pos_sale_lines (sale_id, line_no, medicine_id, product_name,
                                       qty, mrp, gross, amount, taxable)
    values (v_sale, 1, v_med, 'C419 proof item', 10, 100, 1000,
            5000 + i * 100, 4800 + i * 100);
  end loop;

  perform public.pharmacy_bench_refresh();
  perform public.pharmacy_demand_refresh(v_week);

  select count(*) into v_big_rows from public.pharmacy_bench_cohort
   where zone_id = v_big and period_start = date_trunc('month', public._c419_today())::date;
  select count(*) into v_small_rows from public.pharmacy_bench_cohort
   where zone_id = v_small;
  select coalesce(max(pharmacy_count), 0) into v_big_cohort
    from public.pharmacy_bench_cohort where zone_id = v_big;
  select coalesce(max(pharmacy_count), 0) into v_small_cohort
    from public.pharmacy_demand_sku where zone_id = v_small;

  select jsonb_build_object(
    'sku_rows_big',   (select count(*) from public.pharmacy_demand_sku   where zone_id = v_big),
    'sku_rows_small', (select count(*) from public.pharmacy_demand_sku   where zone_id = v_small),
    'class_rows_big', (select count(*) from public.pharmacy_demand_class where zone_id = v_big),
    'class_rows_small',(select count(*) from public.pharmacy_demand_class where zone_id = v_small))
    into v_radar;

  v_bench := jsonb_build_object(
    'min_cohort', v_cfg.min_cohort,
    'big_zone_cohort_rows', v_big_rows,
    'big_zone_pharmacy_count', v_big_cohort,
    'small_zone_cohort_rows', v_small_rows,
    'small_zone_sku_count', v_small_cohort);

  -- Clean up EVERYTHING, then assert.
  delete from public.pharmacy_bench_cohort where zone_id in (v_big, v_small);
  delete from public.pharmacy_demand_sku    where zone_id in (v_big, v_small);
  delete from public.pharmacy_demand_class  where zone_id in (v_big, v_small);
  delete from public.pos_sale_lines l using public.pos_sales s
   where l.sale_id = s.id and s.pharmacy_id = any(v_ids);
  delete from public.pos_sales where pharmacy_id = any(v_ids);
  delete from public.pharmacy_insight_optout where pharmacy_id = any(v_ids);
  delete from public.pharmacy_profiles where id = any(v_ids);
  delete from public.zones where id in (v_big, v_small);

  return jsonb_build_object(
    'ok', v_big_rows > 0
          and v_big_cohort >= v_cfg.min_cohort
          and v_small_rows = 0
          and (v_radar->>'sku_rows_big')::int > 0
          and (v_radar->>'sku_rows_small')::int = 0
          and (v_radar->>'class_rows_small')::int = 0,
    'bench', v_bench, 'radar', v_radar,
    'note', 'Seeded 6 shops in one zone and 3 in another. The 6-shop zone is '
            'aggregated; the 3-shop zone is stored nowhere.');
exception when others then
  -- The seed must never survive a failure.
  delete from public.pharmacy_bench_cohort where zone_id in (900, 901);
  delete from public.pharmacy_demand_sku    where zone_id in (900, 901);
  delete from public.pharmacy_demand_class  where zone_id in (900, 901);
  delete from public.pos_sale_lines l using public.pos_sales s
   where l.sale_id = s.id and s.pharmacy_id = any(v_ids);
  delete from public.pos_sales where pharmacy_id = any(v_ids);
  delete from public.pharmacy_profiles where id = any(v_ids);
  delete from public.zones where id in (900, 901);
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

comment on function public.c419_cohort_proof() is
  'CHANGE #419 — the anonymisation floor, proven on seeded data: a 6-pharmacy
   zone produces cohort and radar rows, a 3-pharmacy zone produces none. Self
   cleaning, including on failure.';

grant execute on function public.pharmacy_owner_dashboard(text)     to authenticated;
grant execute on function public.pharmacy_benchmark()               to authenticated;
grant execute on function public.pharmacy_insight_optout_set(boolean) to authenticated;
grant execute on function public.pharmacy_demand_radar()            to authenticated;
grant execute on function public.pharmacy_demand_add(jsonb)         to authenticated;

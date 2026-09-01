-- CHANGE #424 — the consumption inference engine.
--
-- The pharmacy changes NOTHING about how it works. It keeps buying, and its
-- bills keep landing in the Tier 0 vault (#423). From those purchases alone —
-- no POS, no counting, no daily entry — this engine infers what sold.
--
-- THE ARGUMENT, in Om's own example:
--   10 Montikop bought in January (exp 10/02/26), 12 more in February, 8 in
--   March. Nobody buys stock they still have. A repeat purchase is therefore
--   evidence that the OLDER lot is going out of the door, and the gaps between
--   purchases plus the quantities bought are a measurement of how fast.
--   So January's lot is presumed consumed at the observed velocity, and the
--   quantity that velocity CANNOT account for is presumed still on the shelf.
--
-- FOUR RULES THIS FILE IS BUILT ON:
--
--   1. FEFO. Stock leaves in expiry order, not purchase order. The oldest
--      still-live lot absorbs sales first; only what is left over spills onto
--      the next one.
--   2. PROBABILISTIC, NEVER FAKE-CERTAIN. Velocity is a Gamma posterior over
--      units/day (Poisson counts, conjugate prior), so every SKU carries a
--      spread, not a number. Each lot exposes inferred_sold, inferred_left, a
--      low/high band and a confidence — and every string the owner reads says
--      "around" or "likely", because the engine does not know, it estimates.
--   3. GROUND TRUTH OUTRANKS EVERYTHING. A one-tap correction ("how many are
--      actually left? 0 / 2 / 5 / other") pins that lot AND folds the observed
--      consumption back into the SKU's posterior, so the next estimate is
--      better. That is the whole learning loop.
--   4. POS SILENTLY WINS. Where #411's counter has real sales for a SKU, those
--      replace the inference for that SKU alone. The payload shape does not
--      change — only `method` and `confidence` do — so the swap is invisible
--      to the screen and inference stays underneath as the fallback for
--      movement no bill and no counter ever saw.
--
-- Idempotent throughout. Every string lives in ui_copy.

-- ─────────────────────────── 1. CONFIG ──────────────────────────────────────

create table if not exists public.pharmacy_infer_config (
  id             boolean primary key default true check (id),
  -- Gamma(prior_shape, prior_rate) over units/day: the belief held before any
  -- evidence. shape/rate = 0.5 units a day, weak enough that two real
  -- purchases outvote it.
  prior_shape    numeric not null default 1.0,
  prior_rate     numeric not null default 2.0,
  -- A zone prior is only worth borrowing when this many shops back it.
  zone_min_shops integer not null default 3,
  -- A SKU with fewer than this many purchase gaps is still "new" and leans on
  -- the zone prior.
  own_min_gaps   integer not null default 2,
  min_gap_days   integer not null default 3,    -- two bills a day apart are one restock
  max_gap_days   integer not null default 180,  -- a longer silence is not a gap, it is a stop
  horizon_days   integer not null default 365,  -- how far back the engine looks
  conf_high      numeric not null default 0.70, -- posterior CV below this = high confidence
  conf_low       numeric not null default 0.35,
  updated_at     timestamptz not null default now()
);
insert into public.pharmacy_infer_config (id) values (true) on conflict (id) do nothing;

comment on table public.pharmacy_infer_config is
  'CHANGE #424 — every knob of the inference engine. Retuning the prior or the
   confidence bands is an UPDATE, never a deploy.';

-- ─────────────────────────── 2. TABLES ──────────────────────────────────────

-- The learned posterior, one row per (pharmacy, SKU). alpha/beta ARE the
-- Gamma posterior: mean = alpha/beta units a day, and the spread shrinks as
-- evidence accumulates. Nothing here is a point estimate that forgot its own
-- uncertainty.
create table if not exists public.pharmacy_sku_velocity (
  pharmacy_id     uuid    not null references public.pharmacy_profiles(id) on delete cascade,
  medicine_id     bigint  not null,
  alpha           numeric not null default 1.0,   -- prior_shape + units observed
  beta            numeric not null default 2.0,   -- prior_rate  + days observed
  per_day         numeric not null default 0,     -- alpha / beta, materialised
  gaps            integer not null default 0,     -- restock intervals seen
  units_seen      numeric not null default 0,
  days_seen       numeric not null default 0,
  source          text    not null default 'prior'
                          check (source in ('prior','zone','own','pos','corrected')),
  corrections     integer not null default 0,
  last_purchase_on date,
  updated_at      timestamptz not null default now(),
  primary key (pharmacy_id, medicine_id)
);

comment on table public.pharmacy_sku_velocity is
  'CHANGE #424 — the Gamma posterior over units/day per pharmacy per SKU.
   alpha/beta are updated by every restock gap, every POS week and every
   correction; `source` records which evidence is currently in charge.';

-- The zone-level prior a brand-new SKU borrows until it has a history of its
-- own. Built from the pharmacies that already sell it, never from one shop.
create table if not exists public.pharmacy_zone_sku_prior (
  zone_id      smallint not null,
  medicine_id  bigint   not null,
  per_day      numeric  not null default 0,
  shops        integer  not null default 0,
  computed_at  timestamptz not null default now(),
  primary key (zone_id, medicine_id)
);

-- One row per lot (a pharmacy_stock row), holding what the engine believes
-- about it. Never the truth — an estimate that knows its own width.
create table if not exists public.pharmacy_lot_inference (
  lot_id        uuid primary key references public.pharmacy_stock(id) on delete cascade,
  pharmacy_id   uuid   not null references public.pharmacy_profiles(id) on delete cascade,
  medicine_id   bigint,
  received_on   date,
  expiry_on     date,
  qty_in        numeric not null default 0,
  inferred_sold numeric not null default 0,
  inferred_left numeric not null default 0,
  left_low      numeric not null default 0,   -- 10th percentile of remaining
  left_high     numeric not null default 0,   -- 90th percentile
  confidence    numeric not null default 0,   -- 0..1
  method        text    not null default 'inferred'
                        check (method in ('inferred','pos_actual','corrected')),
  per_day       numeric not null default 0,
  days_live     numeric not null default 0,
  computed_at   timestamptz not null default now()
);

create index if not exists pharmacy_lot_inference_shop_idx
  on public.pharmacy_lot_inference (pharmacy_id, medicine_id, expiry_on);

comment on table public.pharmacy_lot_inference is
  'CHANGE #424 — the per-lot estimate. `method` says where the number came
   from: inference, the POS counter, or the owner''s own correction. A
   correction is never overwritten by a later inference run.';

-- Ground truth. The one-tap answer to "how many are actually left?".
create table if not exists public.pharmacy_lot_correction (
  id           uuid primary key default gen_random_uuid(),
  lot_id       uuid not null references public.pharmacy_stock(id) on delete cascade,
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  medicine_id  bigint,
  actual_left  numeric not null check (actual_left >= 0),
  inferred_was numeric,
  source       text not null default 'alert',
  created_by   uuid,
  created_at   timestamptz not null default now()
);

create index if not exists pharmacy_lot_correction_lot_idx
  on public.pharmacy_lot_correction (lot_id, created_at desc);

alter table public.pharmacy_sku_velocity     enable row level security;
alter table public.pharmacy_zone_sku_prior   enable row level security;
alter table public.pharmacy_lot_inference    enable row level security;
alter table public.pharmacy_lot_correction   enable row level security;
alter table public.pharmacy_infer_config     enable row level security;

-- ─────────────────────────── 3. HELPERS ─────────────────────────────────────

create or replace function public._c424_cfg()
returns public.pharmacy_infer_config
language sql stable security definer set search_path to 'public' as $$
  select * from public.pharmacy_infer_config where id;
$$;

create or replace function public._c424_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

-- Quantities print without a fake '.00' but keep a real fraction.
create or replace function public._c424_qty(p numeric)
returns text language sql immutable as $$
  select trim_scale(round(coalesce(p, 0), 2))::text;
$$;

create or replace function public._c424_denied()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy', 'tone', 'danger',
                            'message', public.ui_text('infer424.err_denied'));
$$;

-- EVERY purchase signal this pharmacy has, from all three doors, as one
-- stream. The engine never asks where a purchase came from — a vault bill, a
-- shelf receipt and a mediBO order are all "this SKU arrived, this many, this
-- day", which is the only thing the inference needs.
create or replace function public._c424_purchases(p_shop uuid, p_from date)
returns table (medicine_id bigint, bought_on date, qty numeric)
language sql stable security definer set search_path to 'public' as $$
  -- 1. Tier 0 vault bill lines (#423) — the primary signal.
  select l.medicine_id, b.invoice_date, sum(coalesce(l.qty,0) + coalesce(l.free_qty,0))
    from public.pharmacy_purchase_bill_line l
    join public.pharmacy_purchase_bill b on b.id = l.bill_id
   where b.pharmacy_id = p_shop
     and b.status in ('confirmed','applied')
     and b.invoice_date is not null and b.invoice_date >= p_from
     and l.medicine_id is not null
   group by l.medicine_id, b.invoice_date
  union all
  -- 2. Shelf receipts that never came through a bill (#412 imports, manual).
  select s.medicine_id, s.received_on, sum(s.qty)
    from public.pharmacy_stock s
   where s.pharmacy_id = p_shop
     and s.received_on is not null and s.received_on >= p_from
     and s.medicine_id is not null
     and s.bill_line_id is null
   group by s.medicine_id, s.received_on
  union all
  -- 3. mediBO orders that were delivered but whose bill never got photographed.
  select oi.product_id, o.order_date, sum(oi.quantity)
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
   where o.customer_id = p_shop
     and o.order_date >= p_from
     and oi.product_id is not null
     and coalesce(oi.unfulfillable, false) = false
     and not exists (select 1 from public.pharmacy_purchase_bill b
                      where b.order_id = o.id and b.status in ('confirmed','applied'))
   group by oi.product_id, o.order_date;
$$;

comment on function public._c424_purchases(uuid, date) is
  'CHANGE #424 — one purchase stream from three doors (vault bills, shelf
   receipts, mediBO orders), de-duplicated at the source: a shelf row that came
   FROM a bill line is skipped, and a mediBO order that has a confirmed bill is
   skipped, so the same box is never counted twice.';

-- ─────────────────────────── 4. COPY ────────────────────────────────────────

insert into public.ui_copy (key, value) values
  ('infer424.err_denied',    to_jsonb('This screen belongs to a pharmacy account.'::text)),
  ('infer424.title',         to_jsonb('What is probably left'::text)),
  ('infer424.subtitle',      to_jsonb('Worked out from your purchase history. No counting needed.'::text)),
  ('infer424.tile_label',    to_jsonb('Likely stock on hand'::text)),
  ('infer424.empty',         to_jsonb('Not enough purchase history yet.'::text)),
  ('infer424.empty_hint',    to_jsonb('Add a few purchase bills and this fills in by itself.'::text)),
  ('infer424.left',          to_jsonb('Around {n} left'::text)),
  ('infer424.left_range',    to_jsonb('likely {low}–{high}'::text)),
  ('infer424.sold',          to_jsonb('About {n} of {inn} sold since {on}'::text)),
  ('infer424.pos_left',      to_jsonb('{n} left'::text)),
  ('infer424.rate',          to_jsonb('Selling about {n} a day'::text)),
  ('infer424.rate_zone',     to_jsonb('Using the rate other shops near you see'::text)),
  ('infer424.rate_new',      to_jsonb('Too new to judge the rate yet'::text)),
  ('infer424.conf_high',     to_jsonb('Confident'::text)),
  ('infer424.conf_medium',   to_jsonb('Rough estimate'::text)),
  ('infer424.conf_low',      to_jsonb('Just a guess'::text)),
  ('infer424.m_inferred',    to_jsonb('Estimated'::text)),
  ('infer424.m_pos_actual',  to_jsonb('From your counter'::text)),
  ('infer424.m_corrected',   to_jsonb('You counted this'::text)),
  ('infer424.expiring',      to_jsonb('Expires {on}'::text)),
  ('infer424.ask_title',     to_jsonb('How many are actually left?'::text)),
  ('infer424.ask_hint',      to_jsonb('One tap teaches the estimate — it gets better every time.'::text)),
  ('infer424.ask_other',     to_jsonb('Another number'::text)),
  ('infer424.ask_save',      to_jsonb('Save'::text)),
  ('infer424.corrected',     to_jsonb('Saved — {n} left. The estimate for this medicine just got better.'::text)),
  ('infer424.correct_failed',to_jsonb('That number could not be saved.'::text)),
  ('infer424.err_generic',   to_jsonb('That did not load. Try again in a moment.'::text)),
  ('infer424.heading_lots',  to_jsonb('Lot by lot'::text)),
  ('infer424.recompute_note',to_jsonb('Updated every night.'::text))
on conflict (key) do nothing;

-- ─────────────────────────── 5. THE VELOCITY ENGINE ─────────────────────────

-- Learn the Gamma posterior for every SKU this pharmacy buys.
--
-- The measurement is a restock GAP: between the first and the last purchase of
-- a SKU, everything bought except the final delivery has had time to sell, and
-- the elapsed days are the time it took. units / days is the observed rate, and
-- it enters the posterior as alpha += units, beta += days. Two purchases are
-- one gap and a weak opinion; ten purchases are nine gaps and a firm one, which
-- is exactly how a Gamma posterior tightens.
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
           -- everything except the most recent delivery has had time to sell
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
        -- a correction or a POS reading outranks a re-learn from purchases
        source = case when v.source in ('corrected','pos') then v.source
                      else excluded.source end,
        updated_at = now()
    where v.source not in ('corrected','pos');

  get diagnostics v_own = row_count;

  -- A SKU still on the bare prior borrows the zone's rate, when the zone has
  -- enough shops behind it to be more than one shop's habit.
  update public.pharmacy_sku_velocity v
     set per_day = z.per_day,
         alpha   = v_cfg.prior_shape + z.per_day * v_cfg.prior_rate,
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

-- The zone prior itself: the average learned rate across the shops that
-- already stock a SKU. Never fewer than zone_min_shops, so no shop's own
-- pattern can be read back out of it.
create or replace function public.pharmacy_zone_prior_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_cfg public.pharmacy_infer_config := public._c424_cfg(); v_n integer := 0;
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
  return jsonb_build_object('ok', true, 'priors', v_n, 'min_shops', v_cfg.zone_min_shops);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

-- ─────────────────────────── 6. FEFO PRESUMPTION ────────────────────────────

-- Walk each SKU's lots in FEFO order and pour the inferred consumption over
-- them. The oldest still-live lot absorbs sales first; what a lot cannot
-- absorb spills to the next. What no consumption can account for is PRESUMED
-- REMAINING — which is the whole point.
--
-- Where the POS has real sales for a SKU, those units replace the inferred
-- ones for that SKU alone. Where a lot carries a correction, the correction is
-- the answer and the pour resumes below it.
create or replace function public.pharmacy_infer_lots(p_shop uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_infer_config := public._c424_cfg();
  v_today date := public._c424_today();
  r record;
  v_sku bigint := null;
  v_rate numeric := 0;        -- units/day currently in charge for this SKU
  v_clock date;               -- the day the shelf became empty of older lots
  v_start date; v_days numeric; v_take numeric; v_demand numeric;
  v_sd numeric; v_cv numeric; v_conf numeric; v_method text;
  v_n integer := 0;
begin
  if p_shop is null then return jsonb_build_object('ok', false, 'error', 'no_shop'); end if;

  -- FEFO order, with a CLOCK. A lot cannot sell before it arrives and cannot
  -- start selling before the lot in front of it has run out, so the pour walks
  -- forward in time: each lot absorbs only the demand generated while it was
  -- actually the front of the queue. That is what makes Om's example come out
  -- right — January''s ten are gone, February''s twelve are nearly gone, and
  -- the box that arrived today has sold nothing at all.
  for r in
    select s.id as lot_id, s.medicine_id, s.qty as qty_in, s.received_on, s.expiry_on,
           coalesce(v.per_day, 0)               as per_day,
           coalesce(v.alpha, v_cfg.prior_shape) as alpha,
           coalesce(v.beta,  v_cfg.prior_rate)  as beta,
           coalesce(v.source, 'prior')          as vsource,
           c.actual_left,
           (select coalesce(sum(sl.qty), 0)
              from public.pos_sale_lines sl
              join public.pos_sales ps on ps.id = sl.sale_id
             where ps.pharmacy_id = p_shop and ps.status = 'completed'
               and sl.medicine_id = s.medicine_id
               and ps.sold_on >= coalesce(
                     (select min(s2.received_on) from public.pharmacy_stock s2
                       where s2.pharmacy_id = p_shop and s2.medicine_id = s.medicine_id),
                     v_today)) as pos_units,
           (select count(*) from public.pos_sale_lines sl
              join public.pos_sales ps on ps.id = sl.sale_id
             where ps.pharmacy_id = p_shop and ps.status = 'completed'
               and sl.medicine_id = s.medicine_id) as pos_lines,
           (select min(s2.received_on) from public.pharmacy_stock s2
             where s2.pharmacy_id = p_shop and s2.medicine_id = s.medicine_id) as sku_first_on
      from public.pharmacy_stock s
      left join public.pharmacy_sku_velocity v
        on v.pharmacy_id = s.pharmacy_id and v.medicine_id = s.medicine_id
      left join lateral (
        select actual_left from public.pharmacy_lot_correction
         where lot_id = s.id order by created_at desc limit 1) c on true
     where s.pharmacy_id = p_shop and s.medicine_id is not null
     order by s.medicine_id,
              s.expiry_on nulls last,      -- FEFO: earliest expiry leaves first
              s.received_on nulls last,
              s.id
  loop
    -- A new SKU resets the clock to the day its oldest lot arrived, and picks
    -- the rate that is in charge: the COUNTER''s own units where #411 has any,
    -- otherwise the learned posterior mean. The payload shape does not change
    -- between the two — only `method` and `confidence` do.
    if v_sku is distinct from r.medicine_id then
      v_sku  := r.medicine_id;
      v_clock := coalesce(r.sku_first_on, r.received_on, v_today);
      if r.pos_lines > 0 then
        v_rate := case when (v_today - v_clock) > 0
                       then r.pos_units / (v_today - v_clock)::numeric else 0 end;
      else
        v_rate := coalesce(r.per_day, 0);
      end if;
    end if;

    v_start := greatest(v_clock, coalesce(r.received_on, v_today));
    v_days  := greatest((v_today - v_start)::numeric, 0);
    v_demand := v_rate * v_days;
    v_method := case when r.pos_lines > 0 then 'pos_actual' else 'inferred' end;

    if r.actual_left is not null then
      -- Ground truth outranks the estimate. The clock advances by how long the
      -- corrected quantity actually took to sell, so the lots behind it move too.
      v_take := greatest(r.qty_in - r.actual_left, 0);
      v_clock := case when v_rate > 0
                      then v_start + (v_take / v_rate)::int else v_today end;
      insert into public.pharmacy_lot_inference as li
        (lot_id, pharmacy_id, medicine_id, received_on, expiry_on, qty_in,
         inferred_sold, inferred_left, left_low, left_high, confidence, method,
         per_day, days_live, computed_at)
      values (r.lot_id, p_shop, r.medicine_id, r.received_on, r.expiry_on, r.qty_in,
              v_take, r.actual_left, r.actual_left, r.actual_left, 1.0, 'corrected',
              v_rate, v_days, now())
      on conflict (lot_id) do update
        set inferred_sold = excluded.inferred_sold, inferred_left = excluded.inferred_left,
            left_low = excluded.left_low, left_high = excluded.left_high,
            confidence = 1.0, method = 'corrected', qty_in = excluded.qty_in,
            expiry_on = excluded.expiry_on, received_on = excluded.received_on,
            medicine_id = excluded.medicine_id,
            per_day = excluded.per_day, days_live = excluded.days_live,
            computed_at = now();
      v_n := v_n + 1;
      continue;
    end if;

    v_take := least(greatest(v_demand, 0), r.qty_in);
    -- The clock moves to the moment this lot ran out — or to today if it did not.
    v_clock := case when v_rate > 0 and v_take >= r.qty_in
                    then v_start + (r.qty_in / v_rate)::int
                    else v_today end;

    -- The spread is the posterior''s, not a made-up percentage:
    -- sd(units over d days) = d * sqrt(alpha) / beta.
    v_sd := v_days * sqrt(greatest(r.alpha, 0.0001)) / greatest(r.beta, 0.0001);
    v_cv := case when v_take > 0 then v_sd / v_take else 1.0 end;
    v_conf := case
                when r.pos_lines > 0 then 0.95
                when r.vsource = 'own'  then greatest(0.15, least(0.9, 1 - v_cv))
                when r.vsource = 'zone' then greatest(0.15, least(0.6, 1 - v_cv))
                else 0.2 end;

    insert into public.pharmacy_lot_inference as li
      (lot_id, pharmacy_id, medicine_id, received_on, expiry_on, qty_in,
       inferred_sold, inferred_left, left_low, left_high, confidence, method,
       per_day, days_live, computed_at)
    values (r.lot_id, p_shop, r.medicine_id, r.received_on, r.expiry_on, r.qty_in,
            round(v_take, 2), round(r.qty_in - v_take, 2),
            round(greatest(r.qty_in - v_take - 1.2816 * v_sd, 0), 2),
            round(least(r.qty_in, r.qty_in - v_take + 1.2816 * v_sd), 2),
            round(v_conf, 3), v_method, v_rate, v_days, now())
    on conflict (lot_id) do update
      set medicine_id = excluded.medicine_id, received_on = excluded.received_on,
          expiry_on = excluded.expiry_on, qty_in = excluded.qty_in,
          inferred_sold = excluded.inferred_sold, inferred_left = excluded.inferred_left,
          left_low = excluded.left_low, left_high = excluded.left_high,
          confidence = excluded.confidence, method = excluded.method,
          per_day = excluded.per_day, days_live = excluded.days_live,
          computed_at = now()
      -- a lot the owner has counted is never re-guessed
      where li.method <> 'corrected';
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'lots', v_n);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

comment on function public.pharmacy_infer_lots(uuid) is
  'CHANGE #424 — the FEFO presumption. Consumption is poured over a SKU''s lots
   in expiry order; what it cannot account for is presumed remaining. POS units
   replace the inferred pool per SKU, and a corrected lot is never re-guessed.';

-- ─────────────────────────── 7. THE READ SURFACE ────────────────────────────

create or replace function public._c424_conf_label(p numeric)
returns text language sql stable security definer set search_path to 'public' as $$
  select case when coalesce(p,0) >= (select conf_high from public.pharmacy_infer_config where id)
                then public.ui_text('infer424.conf_high')
              when coalesce(p,0) >= (select conf_low from public.pharmacy_infer_config where id)
                then public.ui_text('infer424.conf_medium')
              else public.ui_text('infer424.conf_low') end;
$$;

create or replace function public.pharmacy_inference_screen(p_limit integer default 50)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_shop uuid := public.pos_shop();
  v_rows jsonb; v_n integer := 0;
begin
  if v_shop is null then return public._c424_denied(); end if;

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), count(*)
    into v_rows, v_n
    from (
      select row_number() over (order by li.expiry_on nulls last, li.received_on) as ord,
             jsonb_build_object(
               'lot_id', li.lot_id,
               'medicine_id', li.medicine_id,
               'name', coalesce(s.product_name, '—'),
               'batch_label', coalesce(nullif(s.batch_no, ''), ''),
               'expiry_label', case when li.expiry_on is null then ''
                 else public.ui_text_f('infer424.expiring', jsonb_build_object(
                        'on', to_char(li.expiry_on, 'Mon YYYY'))) end,
               -- the number, and the fact that it IS an estimate, in one string
               'left_label', case when li.method = 'inferred'
                 then public.ui_text_f('infer424.left',
                        jsonb_build_object('n', public._c424_qty(li.inferred_left)))
                 else public.ui_text_f('infer424.pos_left',
                        jsonb_build_object('n', public._c424_qty(li.inferred_left))) end,
               'range_label', case when li.method = 'inferred'
                                    and li.left_high > li.left_low
                 then public.ui_text_f('infer424.left_range', jsonb_build_object(
                        'low', public._c424_qty(li.left_low),
                        'high', public._c424_qty(li.left_high)))
                 else '' end,
               'sold_label', public.ui_text_f('infer424.sold', jsonb_build_object(
                        'n', public._c424_qty(li.inferred_sold),
                        'inn', public._c424_qty(li.qty_in),
                        'on', coalesce(to_char(li.received_on, 'DD Mon'), '—'))),
               -- The rate the LOT was actually poured at, not the SKU's stored
               -- source: a lot the counter priced is described by the counter's
               -- own rate, however thin its purchase history happens to be.
               'rate_label', case
                 when li.method = 'pos_actual' or v.source in ('own','pos','corrected')
                   then public.ui_text_f('infer424.rate',
                          jsonb_build_object('n', public._c424_qty(round(li.per_day, 2))))
                 when v.source = 'zone' then public.ui_text('infer424.rate_zone')
                 else public.ui_text('infer424.rate_new') end,
               'method_label', case li.method
                 when 'pos_actual' then public.ui_text('infer424.m_pos_actual')
                 when 'corrected'  then public.ui_text('infer424.m_corrected')
                 else public.ui_text('infer424.m_inferred') end,
               'confidence_label', public._c424_conf_label(li.confidence),
               'confidence', li.confidence,
               'tone', case when li.confidence >= (select conf_high from public.pharmacy_infer_config where id)
                            then 'success'
                            when li.confidence >= (select conf_low from public.pharmacy_infer_config where id)
                            then 'info' else 'warning' end,
               'can_correct', li.method <> 'pos_actual',
               'ask_title', public.ui_text('infer424.ask_title'),
               'ask_hint', public.ui_text('infer424.ask_hint'),
               'ask_other', public.ui_text('infer424.ask_other'),
               'ask_save', public.ui_text('infer424.ask_save'),
               -- the one-tap choices, backend-owned: 0, 2, 5 and whatever the
               -- estimate itself says, so the likeliest answer is one tap too
               'ask_options', (
                 select jsonb_agg(jsonb_build_object('qty', q, 'label', public._c424_qty(q))
                                  order by q)
                   from (select distinct unnest(array[0, 2, 5, round(li.inferred_left)]) as q) o
                  where q <= li.qty_in)
             ) as x
        from public.pharmacy_lot_inference li
        join public.pharmacy_stock s on s.id = li.lot_id
        left join public.pharmacy_sku_velocity v
          on v.pharmacy_id = li.pharmacy_id and v.medicine_id = li.medicine_id
       where li.pharmacy_id = v_shop and li.inferred_left > 0
       order by li.expiry_on nulls last, li.received_on
       limit greatest(coalesce(p_limit, 50), 1)) q;

  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('infer424.title'),
    'subtitle', public.ui_text('infer424.subtitle'),
    'heading', public.ui_text('infer424.heading_lots'),
    'note', public.ui_text('infer424.recompute_note'),
    'empty', public.ui_text('infer424.empty'),
    'empty_hint', public.ui_text('infer424.empty_hint'),
    'count', v_n,
    'rows', v_rows);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM, 'tone', 'danger',
                            'message', public.ui_text('infer424.err_generic'));
end $$;

-- ─────────────────────────── 8. THE GROUND-TRUTH LOOP ───────────────────────

-- One tap. It pins the lot AND folds the observed consumption into the SKU's
-- posterior: units sold = qty_in - actual_left over the days the lot has been
-- live, which is exactly the evidence a Gamma posterior takes.
-- The correction itself, with the shop passed in. The RPC below resolves the
-- shop from the session; the fixture calls this directly, so the proof
-- exercises the SAME code the owner's tap runs and not a copy of it.
create or replace function public._c424_correct(p_shop uuid, p_lot_id uuid, p_left numeric)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := p_shop;
  v_lot record; v_sold numeric; v_days numeric; v_was numeric;
begin
  if v_shop is null then return public._c424_denied(); end if;
  if p_lot_id is null or p_left is null or p_left < 0 then
    return jsonb_build_object('ok', false, 'tone', 'danger',
      'message', public.ui_text('infer424.correct_failed'));
  end if;

  select s.id, s.medicine_id, s.qty, s.received_on
    into v_lot
    from public.pharmacy_stock s
   where s.id = p_lot_id and s.pharmacy_id = v_shop;
  -- A lot the catalogue could never match has no SKU to teach, so there is
  -- nothing to learn from a correction on it. Refuse in the backend's own
  -- words rather than letting a not-null constraint reach the owner.
  if found and v_lot.medicine_id is null then
    return jsonb_build_object('ok', false, 'tone', 'danger',
      'message', public.ui_text('infer424.correct_failed'));
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'tone', 'danger',
      'message', public.ui_text('infer424.correct_failed'));
  end if;

  select inferred_left into v_was from public.pharmacy_lot_inference where lot_id = p_lot_id;

  v_sold := greatest(coalesce(v_lot.qty, 0) - p_left, 0);
  v_days := greatest((public._c424_today() - coalesce(v_lot.received_on,
                       public._c424_today()))::numeric, 1);

  insert into public.pharmacy_lot_correction
    (lot_id, pharmacy_id, medicine_id, actual_left, inferred_was, source, created_by)
  values (p_lot_id, v_shop, v_lot.medicine_id, p_left, v_was, 'alert', auth.uid());

  -- Posterior update. This is the learning: a real observation of `v_sold`
  -- units over `v_days` days is added to alpha/beta, so the mean moves toward
  -- what actually happened and the spread tightens.
  insert into public.pharmacy_sku_velocity as v
    (pharmacy_id, medicine_id, alpha, beta, per_day, units_seen, days_seen,
     source, corrections, updated_at)
  values (v_shop, v_lot.medicine_id,
          (select prior_shape from public.pharmacy_infer_config where id) + v_sold,
          (select prior_rate  from public.pharmacy_infer_config where id) + v_days,
          v_sold / v_days, v_sold, v_days, 'corrected', 1, now())
  on conflict (pharmacy_id, medicine_id) do update
    set alpha = v.alpha + v_sold,
        beta  = v.beta  + v_days,
        per_day = (v.alpha + v_sold) / nullif(v.beta + v_days, 0),
        units_seen = v.units_seen + v_sold,
        days_seen  = v.days_seen  + v_days,
        source = 'corrected',
        corrections = v.corrections + 1,
        updated_at = now();

  -- Re-pour this pharmacy's lots so the shelf below this one moves too.
  perform public.pharmacy_infer_lots(v_shop);

  return jsonb_build_object('ok', true, 'tone', 'success',
    'left', p_left,
    'message', public.ui_text_f('infer424.corrected',
                 jsonb_build_object('n', public._c424_qty(p_left))));
exception when others then
  -- The owner reads copy, never a Postgres error. The detail stays in `error`
  -- for the log.
  return jsonb_build_object('ok', false, 'error', SQLERRM, 'tone', 'danger',
                            'message', public.ui_text('infer424.correct_failed'));
end $$;

create or replace function public.pharmacy_lot_correct(p_lot_id uuid, p_left numeric)
returns jsonb
language sql security definer set search_path to 'public' as $$
  select public._c424_correct(public.pos_shop(), p_lot_id, p_left);
$$;

-- ─────────────────────────── 9. NIGHTLY RECOMPUTE (#305) ────────────────────

create or replace function public.pharmacy_infer_recompute()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r record; v_shops integer := 0; v_lots integer := 0; v_res jsonb;
begin
  perform public.pharmacy_zone_prior_refresh();
  for r in
    select distinct s.pharmacy_id
      from public.pharmacy_stock s
     where s.medicine_id is not null
  loop
    perform public.pharmacy_velocity_learn(r.pharmacy_id);
    v_res := public.pharmacy_infer_lots(r.pharmacy_id);
    v_lots := v_lots + coalesce((v_res->>'lots')::int, 0);
    v_shops := v_shops + 1;
  end loop;
  -- The zone prior is rebuilt AFTER learning too, so tonight's shops feed
  -- tomorrow's newcomers.
  perform public.pharmacy_zone_prior_refresh();
  return jsonb_build_object('ok', true, 'shops', v_shops, 'lots', v_lots);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

insert into public.cron_task (name, ord, mode, work_sql, enabled, note, run_at_ist)
values ('pharmacy-consumption-infer', 740, 'poll',
        'select public.pharmacy_infer_recompute()', true,
        'CHANGE #424 — nightly consumption inference: relearn each SKU''s Gamma '
        'posterior from purchase gaps, refresh the zone priors, re-pour FEFO '
        'consumption over every lot. Corrected lots are left alone.',
        time '03:40')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = excluded.enabled,
      run_at_ist = excluded.run_at_ist, note = excluded.note, ord = excluded.ord;

-- ─────────────────────────── 10. OM'S MONTIKOP FIXTURE ──────────────────────

-- The spec IS this example, so it is the test: 10 bought in January (expiring
-- 10/02/26), 12 more in February, 8 in March. The engine must presume January's
-- lot is being consumed at the observed rate, must attribute consumption to the
-- EARLIEST-expiring lot first, and must leave the rest standing as presumed
-- remaining rather than inventing a sale for it.
create or replace function public.c424_montikop_proof()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid; v_med bigint; v_jan uuid; v_feb uuid; v_mar uuid;
  v_base date := public._c424_today();
  v_vel jsonb; v_inf jsonb; v_screen jsonb;
  v_jan_row public.pharmacy_lot_inference;
  v_feb_row public.pharmacy_lot_inference;
  v_mar_row public.pharmacy_lot_inference;
  v_corr jsonb; v_after numeric; v_per_day numeric; v_ok boolean;
begin
  select id into v_med from public."MEDICINE" limit 1;

  insert into public.pharmacy_profiles (user_id, pharmacy_name, customer_name,
                                        address, city, pincode, approved, status)
  values (gen_random_uuid(), 'C424 proof shop', 'C424 proof',
          'proof', 'proof', '000000', true, 'approved')
  returning id into v_shop;

  -- Three deliveries, 60 / 30 / 0 days ago — Om's Jan / Feb / Mar — with the
  -- January lot expiring first, which is what makes FEFO bite.
  insert into public.pharmacy_stock (pharmacy_id, medicine_id, product_name, item_key, qty,
                                     unit_cost, batch_no, expiry, expiry_on,
                                     received_on, source_kind)
  values (v_shop, v_med, 'Montikop 10 Tablet', 'c424:montikop', 10, 40, 'JAN', '02/26',
          v_base + 200, v_base - 60, 'outside')
  returning id into v_jan;
  insert into public.pharmacy_stock (pharmacy_id, medicine_id, product_name, item_key, qty,
                                     unit_cost, batch_no, expiry, expiry_on,
                                     received_on, source_kind)
  values (v_shop, v_med, 'Montikop 10 Tablet', 'c424:montikop', 12, 40, 'FEB', '08/26',
          v_base + 400, v_base - 30, 'outside')
  returning id into v_feb;
  insert into public.pharmacy_stock (pharmacy_id, medicine_id, product_name, item_key, qty,
                                     unit_cost, batch_no, expiry, expiry_on,
                                     received_on, source_kind)
  values (v_shop, v_med, 'Montikop 10 Tablet', 'c424:montikop', 8, 40, 'MAR', '12/26',
          v_base + 600, v_base, 'outside')
  returning id into v_mar;

  v_vel := public.pharmacy_velocity_learn(v_shop);
  v_inf := public.pharmacy_infer_lots(v_shop);

  select * into v_jan_row from public.pharmacy_lot_inference where lot_id = v_jan;
  select * into v_feb_row from public.pharmacy_lot_inference where lot_id = v_feb;
  select * into v_mar_row from public.pharmacy_lot_inference where lot_id = v_mar;
  select per_day into v_per_day from public.pharmacy_sku_velocity
   where pharmacy_id = v_shop and medicine_id = v_med;

  -- The correction loop: the owner says 2 are actually left in the January lot.
  v_corr := public._c424_correct(v_shop, v_jan, 2);
  select inferred_left into v_after from public.pharmacy_lot_inference where lot_id = v_jan;

  v_ok :=
    -- 22 units bought before the last delivery, over 60 days => ~0.37/day, and
    -- the January lot (earliest expiry) is fully absorbed first.
        v_jan_row.method = 'inferred'
    and v_jan_row.inferred_sold >= 9.9         -- all ten presumed consumed
    and v_jan_row.inferred_left <= 0.1
    -- February's lot takes the spill and keeps a real remainder.
    and v_feb_row.inferred_sold > 0
    and v_feb_row.inferred_left > 0
    -- March's delivery arrived today: nothing can have sold out of it yet.
    and v_mar_row.inferred_sold <= 0.01
    and v_mar_row.inferred_left >= 7.9
    -- the estimate is never presented as certain
    and v_jan_row.confidence < 1.0
    and v_feb_row.left_high >= v_feb_row.left_low
    -- and the correction pins the lot and is not re-guessed
    and (v_corr->>'ok')::boolean and v_after = 2;

  v_screen := jsonb_build_object(
    'velocity_per_day', round(coalesce(v_per_day, 0), 3),
    'jan', jsonb_build_object('in', v_jan_row.qty_in, 'sold', v_jan_row.inferred_sold,
                              'left', v_jan_row.inferred_left,
                              'conf', v_jan_row.confidence, 'method', v_jan_row.method),
    'feb', jsonb_build_object('in', v_feb_row.qty_in, 'sold', v_feb_row.inferred_sold,
                              'left', v_feb_row.inferred_left,
                              'low', v_feb_row.left_low, 'high', v_feb_row.left_high),
    'mar', jsonb_build_object('in', v_mar_row.qty_in, 'sold', v_mar_row.inferred_sold,
                              'left', v_mar_row.inferred_left),
    'after_correction_jan_left', v_after);

  -- Clean up everything this proof created.
  delete from public.pharmacy_lot_correction where pharmacy_id = v_shop;
  delete from public.pharmacy_lot_inference  where pharmacy_id = v_shop;
  delete from public.pharmacy_sku_velocity   where pharmacy_id = v_shop;
  delete from public.pharmacy_stock          where pharmacy_id = v_shop;
  delete from public.pharmacy_profiles       where id = v_shop;

  return jsonb_build_object('ok', v_ok, 'learn', v_vel, 'infer', v_inf,
                            'montikop', v_screen,
                            'note', 'Jan lot (earliest expiry) presumed consumed, Feb '
                                    'takes the spill, today''s Mar lot is untouched, '
                                    'and a correction pins Jan at 2.');
exception when others then
  delete from public.pharmacy_lot_correction where pharmacy_id = v_shop;
  delete from public.pharmacy_lot_inference  where pharmacy_id = v_shop;
  delete from public.pharmacy_sku_velocity   where pharmacy_id = v_shop;
  delete from public.pharmacy_stock          where pharmacy_id = v_shop;
  delete from public.pharmacy_profiles       where id = v_shop;
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

comment on function public.c424_montikop_proof() is
  'CHANGE #424 — the spec''s own example as an assertion: 10 in January (earliest
   expiry), 12 in February, 8 today. Self-cleaning, including on failure.';

grant execute on function public.pharmacy_inference_screen(integer) to authenticated;
grant execute on function public.pharmacy_lot_correct(uuid, numeric) to authenticated;

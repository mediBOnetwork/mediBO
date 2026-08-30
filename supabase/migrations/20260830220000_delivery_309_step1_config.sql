-- CHANGE #309 step 1 — the delivery module's missing configuration surface.
--
-- Ten features were confirmed absent by a live schema audit. Every one of them
-- needs a NUMBER that Om must be able to change without a deploy: a promise
-- window, a delivery charge, a free-above threshold, a geofence radius, a
-- document-expiry reminder lead time. Rule 12 and the max-backend rule both say
-- those live in the backend, so they all land here FIRST and every later step
-- reads them — nothing in steps 2-10 may hardcode one.
--
-- Two levels, deliberately:
--   delivery_config        — one row, the platform default for every zone.
--   zone_delivery_config   — an OPTIONAL per-zone override row. A missing row
--                            is not an error, it means "use the default", so a
--                            new zone works the moment it is created.
-- Every read goes through _dcfg(zone) which merges the two, so no caller ever
-- has to remember the fallback rule.

-- ── 1. Platform defaults ────────────────────────────────────────────────────
create table if not exists public.delivery_config (
  id                       smallint primary key default 1 check (id = 1),

  -- (2) SLA. The promise window, in minutes from the moment the stop is
  -- assigned to a rider. on_time_grace_min is the slack allowed before a
  -- delivery counts as breached, so a 2-minute overrun is not a red mark.
  promise_window_min       integer  not null default 240,
  on_time_grace_min        integer  not null default 15,

  -- (3) Delivery charge. free_above_amount is the ORDER value at or above
  -- which the charge is waived. cost_per_drop is what the drop actually costs
  -- the platform (rider payout + overhead), so margin per delivery is visible.
  charge_amount            numeric(10,2) not null default 0,
  free_above_amount        numeric(12,2) not null default 0,
  charge_gst_pct           numeric(5,2)  not null default 0,
  default_cost_per_drop    numeric(10,2) not null default 0,

  -- (6) Rider document expiry: how many days before expiry the reminder fires,
  -- and whether an expired document actually blocks assignment.
  doc_expiry_remind_days   integer  not null default 30,
  doc_expiry_blocks        boolean  not null default true,

  -- (9) Geofence arrival radius, in metres, around the stop's lat/lng.
  geofence_radius_m        integer  not null default 150,
  geofence_min_accuracy_m  integer  not null default 250,

  -- (10) Cold chain: how far a temperature-sensitive stop is pulled forward in
  -- the run sequence, and whether it forces a photo on completion.
  cold_chain_priority_boost integer not null default 1000,
  cold_chain_photo_required boolean not null default true,

  -- (1) Handover. handover_required gates out_for_delivery on a scan.
  -- handover_enforced_from exempts every delivery created BEFORE the feature
  -- shipped, so live in-flight parcels are never stranded by a new rule.
  handover_required        boolean  not null default true,
  handover_enforced_from   timestamptz not null default now(),

  -- (5) Payout run cadence, in days. 7 = weekly statements.
  payout_period_days       integer  not null default 7,

  -- (5) A rating below this counts as poor in the rider statement/dashboard.
  rating_poor_at_or_below  smallint not null default 2,

  updated_at               timestamptz not null default now(),
  updated_by               text
);

insert into public.delivery_config(id) values (1) on conflict (id) do nothing;

-- ── 2. Per-zone overrides ───────────────────────────────────────────────────
-- Every column is NULLABLE on purpose: null means "inherit the default".
create table if not exists public.zone_delivery_config (
  zone_id                  smallint primary key references public.zones(id) on delete cascade,
  promise_window_min       integer,
  on_time_grace_min        integer,
  charge_amount            numeric(10,2),
  free_above_amount        numeric(12,2),
  charge_gst_pct           numeric(5,2),
  cost_per_drop            numeric(10,2),
  geofence_radius_m        integer,
  is_serviceable           boolean not null default true,
  updated_at               timestamptz not null default now(),
  updated_by               text
);

-- ── 3. Pincode serviceability (5) ───────────────────────────────────────────
-- Checked at CHECKOUT, before an order exists. mode decides how hard the answer
-- is: 'serviceable' lets it through, 'warn' shows the note but allows the order,
-- 'blocked' refuses. A pincode with NO row falls back to the zone's own
-- is_serviceable plus delivery_config.unknown_pincode_mode below.
create table if not exists public.delivery_serviceability (
  pincode                  text     not null,
  zone_id                  smallint references public.zones(id) on delete set null,
  mode                     text     not null default 'serviceable'
                             check (mode in ('serviceable','warn','blocked')),
  note                     text,
  promise_window_min       integer,
  charge_amount            numeric(10,2),
  is_active                boolean  not null default true,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  updated_by               text,
  primary key (pincode)
);

create index if not exists idx_serviceability_zone
  on public.delivery_serviceability(zone_id) where is_active;

alter table public.delivery_config
  add column if not exists unknown_pincode_mode text not null default 'warn';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_config_unknown_mode_ck') then
    alter table public.delivery_config
      add constraint delivery_config_unknown_mode_ck
      check (unknown_pincode_mode in ('serviceable','warn','blocked'));
  end if;
end $$;

-- ── 4. The one reader every later step uses ─────────────────────────────────
-- Merges zone override over platform default. A null zone, an unknown zone and
-- a zone with no override row all resolve to the platform default rather than
-- to nulls, so no caller ever needs a coalesce of its own.
create or replace function public._dcfg(p_zone smallint default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'promise_window_min',        coalesce(z.promise_window_min,        d.promise_window_min),
    'on_time_grace_min',         coalesce(z.on_time_grace_min,         d.on_time_grace_min),
    'charge_amount',             coalesce(z.charge_amount,             d.charge_amount),
    'free_above_amount',         coalesce(z.free_above_amount,         d.free_above_amount),
    'charge_gst_pct',            coalesce(z.charge_gst_pct,            d.charge_gst_pct),
    'cost_per_drop',             coalesce(z.cost_per_drop,             d.default_cost_per_drop),
    'geofence_radius_m',         coalesce(z.geofence_radius_m,         d.geofence_radius_m),
    'geofence_min_accuracy_m',   d.geofence_min_accuracy_m,
    'doc_expiry_remind_days',    d.doc_expiry_remind_days,
    'doc_expiry_blocks',         d.doc_expiry_blocks,
    'cold_chain_priority_boost', d.cold_chain_priority_boost,
    'cold_chain_photo_required', d.cold_chain_photo_required,
    'handover_required',         d.handover_required,
    'handover_enforced_from',    d.handover_enforced_from,
    'payout_period_days',        d.payout_period_days,
    'rating_poor_at_or_below',   d.rating_poor_at_or_below,
    'unknown_pincode_mode',      d.unknown_pincode_mode,
    'zone_serviceable',          coalesce(z.is_serviceable, true),
    'zone_id',                   p_zone)
  from public.delivery_config d
  left join public.zone_delivery_config z on z.zone_id = p_zone
  where d.id = 1;
$$;

-- ── 5. RLS ──────────────────────────────────────────────────────────────────
-- Config is read by the storefront (a customer needs the charge and the promise
-- window before they order) and written only by admins through RPCs, which are
-- SECURITY DEFINER. So: readable to authenticated, no direct write policy.
alter table public.delivery_config          enable row level security;
alter table public.zone_delivery_config     enable row level security;
alter table public.delivery_serviceability  enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where tablename='delivery_config' and policyname='delivery_config_read') then
    create policy delivery_config_read on public.delivery_config
      for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies
                  where tablename='zone_delivery_config' and policyname='zone_delivery_config_read') then
    create policy zone_delivery_config_read on public.zone_delivery_config
      for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies
                  where tablename='delivery_serviceability' and policyname='delivery_serviceability_read') then
    create policy delivery_serviceability_read on public.delivery_serviceability
      for select to authenticated using (true);
  end if;
end $$;

grant select on public.delivery_config, public.zone_delivery_config,
                public.delivery_serviceability to authenticated;

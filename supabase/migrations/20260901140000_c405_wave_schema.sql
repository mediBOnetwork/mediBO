-- CHANGE #405 (A) — Auto-assignment engine and wave planning: the tables.
--
-- Verified before writing a line: delivery_assign() needs an admin-chosen
-- partner_id, nothing fires when packing completes, and no wave object exists.
-- Everything else the spec names is already here and is REUSED, never forked:
-- delivery_eligibility(), delivery_doc_state()'s expiry block, the zone-boundary
-- rule, the accept/reject flow (delivery_respond), delivery_optimize_run() and
-- delivery_suggest_partner().
--
-- A wave is (zone, IST date, time window). Zones behave as separate shops and a
-- delivery may never cross a zone boundary, so the zone IS the area unit here —
-- there is no second geography to invent.
--
-- Every migration in this command is idempotent: a resumed worker WILL re-apply
-- it and that must be a silent no-op.

-- ── 1. Per-zone mode and cut-off windows ────────────────────────────────────
-- Default mode is 'suggest' on purpose (spec 3): the engine prepares the wave
-- and an admin approves it, so Om sees the plan before trusting 'auto'.
create table if not exists public.delivery_wave_zone_config (
  zone_id      smallint primary key references public.zones(id) on delete cascade,
  mode         text not null default 'suggest',
  windows      jsonb not null default '[]'::jsonb,
  max_per_rider integer,
  enabled      boolean not null default true,
  updated_at   timestamptz not null default now(),
  updated_by   text
);

do $$ begin
  alter table public.delivery_wave_zone_config
    add constraint delivery_wave_zone_config_mode_chk
    check (mode in ('auto','suggest','manual'));
exception when duplicate_object then null; end $$;

-- ── 2. The wave ─────────────────────────────────────────────────────────────
create table if not exists public.delivery_wave (
  id            uuid primary key default gen_random_uuid(),
  zone_id       smallint not null references public.zones(id) on delete cascade,
  wave_date     date not null,
  window_key    text not null,
  window_label  text not null default '',
  cutoff_at     timestamptz,
  status        text not null default 'planned',
  mode          text not null default 'suggest',
  cut_reason    text not null default '',
  stop_count    integer not null default 0,
  rider_count   integer not null default 0,
  blocked_count integer not null default 0,
  created_by    text,
  created_at    timestamptz not null default now(),
  approved_at   timestamptz,
  approved_by   text,
  dispatched_at timestamptz,
  closed_at     timestamptz
);

do $$ begin
  alter table public.delivery_wave add constraint delivery_wave_status_chk
    check (status in ('planned','proposed','approved','dispatched','closed','cancelled'));
exception when duplicate_object then null; end $$;

-- One wave per zone / date / window. The dispatcher relies on this: it cuts a
-- wave by INSERT ... on conflict do nothing, so two dispatcher ticks landing in
-- the same second cannot produce two waves.
create unique index if not exists delivery_wave_slot_uk
  on public.delivery_wave (zone_id, wave_date, window_key);
create index if not exists delivery_wave_open_idx
  on public.delivery_wave (status, wave_date desc);

-- ── 3. The stops in a wave ──────────────────────────────────────────────────
create table if not exists public.delivery_wave_stop (
  id           uuid primary key default gen_random_uuid(),
  wave_id      uuid not null references public.delivery_wave(id) on delete cascade,
  order_id     uuid not null references public.orders(id) on delete cascade,
  delivery_id  uuid,
  partner_id   uuid references public.delivery_partner_registrations(id) on delete set null,
  status       text not null default 'planned',
  reason       text not null default '',
  attempt_no   integer not null default 1,
  seq          integer,
  created_at   timestamptz not null default now(),
  assigned_at  timestamptz,
  released_at  timestamptz,
  -- Riders who have already rejected THIS stop. Reallocation must never hand
  -- the same stop back to the rider who just refused it, so the exclusion has
  -- to survive on the row rather than be re-derived from the event log.
  rejected_by  uuid[] not null default '{}'::uuid[]
);

do $$ begin
  alter table public.delivery_wave_stop add constraint delivery_wave_stop_status_chk
    check (status in ('planned','assigned','rejected','blocked','removed','held'));
exception when duplicate_object then null; end $$;

create unique index if not exists delivery_wave_stop_uk
  on public.delivery_wave_stop (wave_id, order_id);
create index if not exists delivery_wave_stop_wave_idx
  on public.delivery_wave_stop (wave_id, status);
create index if not exists delivery_wave_stop_delivery_idx
  on public.delivery_wave_stop (delivery_id) where delivery_id is not null;

-- ── 4. The decision log (spec 4) ────────────────────────────────────────────
-- EVERY automatic decision writes a row here with the sentence that explains
-- it. The sentence is written HERE, in the backend, so the run map and the
-- admin screen print it verbatim rather than composing a reason in Dart.
create table if not exists public.delivery_wave_decision (
  id          bigserial primary key,
  wave_id     uuid references public.delivery_wave(id) on delete cascade,
  stop_id     uuid,
  order_id    uuid,
  partner_id  uuid,
  delivery_id uuid,
  decision    text not null,
  reason      text not null default '',
  meta        jsonb not null default '{}'::jsonb,
  actor       text not null default 'engine',
  created_at  timestamptz not null default now()
);
create index if not exists delivery_wave_decision_wave_idx
  on public.delivery_wave_decision (wave_id, created_at desc);
create index if not exists delivery_wave_decision_delivery_idx
  on public.delivery_wave_decision (delivery_id, created_at desc)
  where delivery_id is not null;

-- ── 5. The stop that a delivery came from ───────────────────────────────────
-- deliveries already exists and is the one ledger; a wave stop points AT a
-- delivery rather than replacing it, so nothing downstream (run map, proof,
-- payout, RTO) changes shape.
alter table public.deliveries add column if not exists wave_id uuid;
create index if not exists deliveries_wave_idx on public.deliveries (wave_id)
  where wave_id is not null;

-- ── 6. RLS — these are admin/engine tables ──────────────────────────────────
alter table public.delivery_wave              enable row level security;
alter table public.delivery_wave_stop         enable row level security;
alter table public.delivery_wave_decision     enable row level security;
alter table public.delivery_wave_zone_config  enable row level security;

-- No permissive policy is added: every read and write goes through the
-- SECURITY DEFINER RPCs in part B, which do their own role check. RLS on with
-- no policy means the anon and authenticated roles see nothing directly.

-- ── 7. Seed a config row per zone, with the default windows ─────────────────
-- Cut-offs are IST wall-clock times. They are DATA, so retiming a wave is an
-- UPDATE, never a deploy — and there is no new pg_cron job: part C registers
-- one cron_task row on the #305 dispatcher.
insert into public.delivery_wave_zone_config (zone_id, mode, windows, updated_by)
select z.id, 'suggest',
       jsonb_build_array(
         jsonb_build_object('key','morning',  'label','Morning wave',  'cutoff_ist','10:30'),
         jsonb_build_object('key','afternoon','label','Afternoon wave','cutoff_ist','14:30'),
         jsonb_build_object('key','evening',  'label','Evening wave',  'cutoff_ist','18:00')
       ),
       'change_405'
from public.zones z
on conflict (zone_id) do nothing;

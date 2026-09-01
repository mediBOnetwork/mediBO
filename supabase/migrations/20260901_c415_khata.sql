-- CMD #415 — the patient khata (udhaar) ledger, and the collector that works it.
--
-- Every pharmacy in Chhattisgarh already runs this book; it is a paper diary by
-- the till with a patient's name, a doctor's name, and a running figure nobody
-- reconciles. This is that diary, with two things paper cannot do: it knows how
-- OLD each balance is, and it can ask for the money by itself.
--
-- Shape follows POS (#411) exactly, because khata IS a POS payment mode:
--   * pos_shop() = my_customer_id() is the pharmacy. Every RPC gates on it.
--   * RLS ON with ZERO policies. Nothing reaches these tables except the
--     SECURITY DEFINER RPCs below, and each one filters to the caller's own
--     pharmacy. That is the PII fence the spec asks for: a patient's name and
--     phone belong to the pharmacy that wrote them down, not to mediBO. There
--     is deliberately NO admin RPC that returns a ledger row — khata_admin_
--     overview() counts and sums, and cannot name a patient.
--   * Every rupee, every label, every reminder sentence is composed here and
--     rendered verbatim. Dart computes nothing.
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ── 1. the account: one per patient or doctor, per pharmacy ────────────────
create table if not exists public.khata_account (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  kind           text not null default 'patient',   -- patient | doctor
  name           text not null,
  phone          text,                              -- 10 digits, or null
  limit_amount   numeric,                           -- optional credit ceiling
  balance        numeric not null default 0,        -- running, maintained below
  note           text,
  is_active      boolean not null default true,
  -- the collector's own state, reset by any payment
  reminder_stage    integer not null default 0,
  last_reminder_on  date,
  reminders_paused  boolean not null default false,
  oldest_due_on     date,        -- when the CURRENT unpaid run started ageing
  last_entry_at     timestamptz,
  last_payment_at   timestamptz,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint khata_account_kind_ck check (kind in ('patient','doctor'))
);

create unique index if not exists khata_account_phone_uq
  on public.khata_account (pharmacy_id, phone) where phone is not null;
create index if not exists khata_account_shop_ix
  on public.khata_account (pharmacy_id, is_active, balance desc);
create index if not exists khata_account_name_ix
  on public.khata_account (pharmacy_id, lower(name));

-- ── 2. the entries: the diary lines themselves ─────────────────────────────
-- amount is SIGNED the way the book reads: a credit sale ADDS to what is owed,
-- a payment SUBTRACTS. balance_after is stamped at write time under a row lock,
-- so a statement never has to re-add the column to print a running figure.
create table if not exists public.khata_entry (
  id               uuid primary key default gen_random_uuid(),
  pharmacy_id      uuid not null references public.pharmacy_profiles(id) on delete cascade,
  account_id       uuid not null references public.khata_account(id) on delete cascade,
  entry_type       text not null,                 -- sale | payment | adjust
  amount           numeric not null,              -- +owed / -paid
  balance_after    numeric not null,
  entry_on         date not null default (now() at time zone 'Asia/Kolkata')::date,
  sale_id          uuid references public.pos_sales(id) on delete set null,
  method           text,                          -- payments: cash | upi | other
  note             text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  client_action_id uuid,
  constraint khata_entry_type_ck check (entry_type in ('sale','payment','adjust'))
);

create unique index if not exists khata_entry_action_uq
  on public.khata_entry (client_action_id) where client_action_id is not null;
create unique index if not exists khata_entry_sale_uq
  on public.khata_entry (sale_id) where sale_id is not null;
create index if not exists khata_entry_acct_ix
  on public.khata_entry (account_id, created_at desc);
create index if not exists khata_entry_shop_ix
  on public.khata_entry (pharmacy_id, entry_on desc);

-- ── 3. the collector's settings, per pharmacy ──────────────────────────────
create table if not exists public.khata_settings (
  pharmacy_id     uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  enabled         boolean not null default false,  -- opt-in: never message a
                                                   -- patient before the shop says so
  gentle_days     integer not null default 7,      -- N — the soft nudge
  firm_days       integer not null default 15,     -- M — the firmer one
  final_days      integer not null default 30,     -- the last, still polite
  min_balance     numeric not null default 100,    -- never chase small change
  cycle_days      integer not null default 7,      -- at most ONE per cycle
  quiet_dow       integer[] not null default '{0}',-- 0=Sunday, quiet by default
  daily_cap       integer not null default 25,     -- per pharmacy, per day
  updated_at      timestamptz not null default now()
);

-- ── 4. reminder wording — platform default + the pharmacy's own edit ───────
-- pharmacy_id null = the approved platform wording. A pharmacy may edit within
-- it; khata_template_save() rejects anything that drops the required tokens or
-- adds a threat, so "editable within approved wording" is enforced, not hoped.
create table if not exists public.khata_template (
  id           bigint generated always as identity primary key,
  pharmacy_id  uuid references public.pharmacy_profiles(id) on delete cascade,
  stage        integer not null,                  -- 1 gentle | 2 firm | 3 final
  body         text not null,
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);
create unique index if not exists khata_template_uq
  on public.khata_template (coalesce(pharmacy_id, '00000000-0000-0000-0000-000000000000'::uuid), stage);

-- ── 5. what was actually sent — the frequency cap's evidence ───────────────
create table if not exists public.khata_reminder_log (
  id            bigint generated always as identity primary key,
  pharmacy_id   uuid not null,
  account_id    uuid not null references public.khata_account(id) on delete cascade,
  stage         integer not null,
  balance_at    numeric not null,
  age_days      integer,
  sent_on       date not null default (now() at time zone 'Asia/Kolkata')::date,
  dedupe_key    text not null,
  channel       text,
  detail        jsonb,
  created_at    timestamptz not null default now()
);
create unique index if not exists khata_reminder_dedupe_uq
  on public.khata_reminder_log (dedupe_key);
create index if not exists khata_reminder_acct_ix
  on public.khata_reminder_log (account_id, sent_on desc);

-- ── 6. the statement PDF, one per account per render ───────────────────────
create table if not exists public.khata_statement (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null,
  account_id    uuid not null references public.khata_account(id) on delete cascade,
  status        text not null default 'queued',   -- queued | ready | failed
  bucket        text, path text, file_name text, bytes integer, error text,
  requested_at  timestamptz not null default now(),
  ready_at      timestamptz
);
create index if not exists khata_statement_acct_ix
  on public.khata_statement (account_id, requested_at desc);

-- ── 7. the fence ───────────────────────────────────────────────────────────
-- RLS on, no policies: the tables are unreachable except through the RPCs.
alter table public.khata_account       enable row level security;
alter table public.khata_entry         enable row level security;
alter table public.khata_settings      enable row level security;
alter table public.khata_template      enable row level security;
alter table public.khata_reminder_log  enable row level security;
alter table public.khata_statement     enable row level security;

revoke all on public.khata_account, public.khata_entry, public.khata_settings,
              public.khata_template, public.khata_reminder_log, public.khata_statement
  from anon, authenticated;

-- ── 8. the pharmacy's OWN UPI address ──────────────────────────────────────
-- Money in a khata reminder must land in the PHARMACY's account, never in a
-- mediBO account — this is the shop's own book and mediBO is not a party to it.
-- `verified` here means the owner typed it, saw the name it resolves to, and
-- confirmed it; there is no PSP name-lookup on this plan, so an unconfirmed VPA
-- simply never ships in a reminder rather than shipping unverified.
alter table public.pharmacy_profiles
  add column if not exists upi_vpa           text,
  add column if not exists upi_vpa_name      text,
  add column if not exists upi_verified_at   timestamptz,
  add column if not exists upi_verified_by   uuid;

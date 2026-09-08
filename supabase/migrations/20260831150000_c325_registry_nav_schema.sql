-- CHANGE #325 — the feature registry becomes the SINGLE source of nav truth.
--
-- Extends the EXISTING feature_registry (never a parallel table) with the
-- columns the dashboard nav needs, plus the category table that names and
-- orders the dashboard's collapsible sections.
--
-- Every statement here is idempotent: a resumed worker will re-apply this file
-- and that must be a silent no-op.

-- ── Categories: labels + order live here, never in Dart ─────────────────────
create table if not exists nav_category (
  category_key text primary key,
  label        text not null,
  icon_key     text not null default 'tile',
  sort_order   int  not null default 100,
  is_active    boolean not null default true
);

insert into nav_category (category_key, label, icon_key, sort_order) values
  ('orders',    'Orders & Fulfilment',  'truck',    10),
  ('parties',   'Customers & Suppliers','people',   20),
  ('catalogue', 'Catalogue & Pricing',  'book',     30),
  ('delivery',  'Delivery',             'moped',    40),
  ('comms',     'Communication',        'forum',    50),
  ('money',     'Money',                'rupee',    60),
  ('system',    'Admin & System',       'settings', 70),
  ('identity',  'Account',              'person',   90)
on conflict (category_key) do update
  set label = excluded.label, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true;

-- ── The new registry columns ────────────────────────────────────────────────
alter table feature_registry
  add column if not exists category      text not null default 'system',
  add column if not exists surface       text not null default 'dashboard',
  add column if not exists badge_source  text,
  add column if not exists roles_allowed text[] not null default array['admin','super_admin'],
  add column if not exists deep_link     text,
  add column if not exists search_terms  text not null default '',
  add column if not exists badge_noun    text;

-- ── THE HARD GATE ───────────────────────────────────────────────────────────
-- surface='profile' (or 'both') is admissible ONLY for identity rows. This is
-- what permanently stops a feature leaking back into the profile dropdown: the
-- dropdown renders `surface in ('profile','both')` and nothing else can ever
-- carry that value. Proven by attempting the leak — the UPDATE raises 23514.
alter table feature_registry drop constraint if exists feature_registry_surface_ck;
alter table feature_registry add constraint feature_registry_surface_ck check (
  surface in ('dashboard','profile','both')
  and (surface = 'dashboard'
       or (category = 'identity'
           and feature_key in ('identity.view_profile','identity.logout')))
);

alter table feature_registry drop constraint if exists feature_registry_category_fk;
alter table feature_registry
  add constraint feature_registry_category_fk
  foreign key (category) references nav_category(category_key) on update cascade;

create index if not exists feature_registry_nav_idx
  on feature_registry (category, sort_order) where is_active;

-- ── Usage log + pins: what ranks the tiles, and what floats one to the top ──
create table if not exists nav_usage (
  id           bigserial primary key,
  user_id      uuid not null,
  feature_key  text not null,
  opened_at    timestamptz not null default now()
);
create index if not exists nav_usage_user_idx on nav_usage (user_id, feature_key, opened_at desc);
create index if not exists nav_usage_at_idx   on nav_usage (opened_at desc);

create table if not exists nav_pin (
  user_id     uuid not null,
  feature_key text not null,
  pinned_at   timestamptz not null default now(),
  primary key (user_id, feature_key)
);

alter table nav_category enable row level security;
alter table nav_usage    enable row level security;
alter table nav_pin      enable row level security;

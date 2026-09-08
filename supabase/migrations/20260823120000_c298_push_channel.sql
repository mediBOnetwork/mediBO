-- CHANGE #298 — PART 2 of the notification rebuild: push (FCM) as a channel,
-- the in-app inbox, deep links, and the per-event / per-user push switches.
--
-- Every statement is idempotent (checkpoint rule 3) because PART 1 (#297) is
-- landing notification_log and the wa_event_routes push columns in parallel
-- with the identical contract — whoever lands first wins, the other is a no-op.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. push_config — the Firebase client config, backend-driven.
--    These are the google-services.json values. They are NOT secrets (they
--    ship inside every published app binary); the FCM *server* credential is
--    GCP_SA_KEY and stays in edge secrets. Holding them here means Om can
--    point the app at a Firebase project with zero rebuild and zero deploy.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.push_config (
  id            text primary key default 'singleton',
  enabled       boolean not null default false,
  project_id    text,
  api_key       text,           -- Android: current_key / Web: apiKey
  app_id        text,           -- Android mobilesdk_app_id
  sender_id     text,           -- project_number
  web_api_key   text,
  web_app_id    text,
  vapid_key     text,
  android_package text not null default 'in.medibo.app',
  setup_note    text,
  updated_at    timestamptz not null default now()
);
insert into public.push_config (id) values ('singleton') on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. push_tokens — one row per device per user (spec item 1).
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.push_tokens (
  id           bigserial primary key,
  user_id      uuid not null,
  role         text,
  token        text not null,
  platform     text not null default 'android',
  device_label text,
  last_seen    timestamptz not null default now(),
  is_active    boolean not null default true,
  deactivated_reason text,
  created_at   timestamptz not null default now()
);
create unique index if not exists push_tokens_token_uidx  on public.push_tokens (token);
create index        if not exists push_tokens_user_idx    on public.push_tokens (user_id) where is_active;
create index        if not exists push_tokens_active_idx  on public.push_tokens (is_active, last_seen desc);

-- ─────────────────────────────────────────────────────────────────────────
-- 3. notification_log — shared with #297. Created here only if #297 has not
--    landed it yet; the extra columns the inbox needs are added either way.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.notification_log (
  id          bigserial primary key,
  event_key   text,
  recipient   text,
  channel     text not null default 'whatsapp',
  status      text not null default 'queued',
  provider_message_id text,
  failure_reason text,
  cost        numeric(10,4) not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.notification_log add column if not exists user_id    uuid;
alter table public.notification_log add column if not exists order_id   uuid;
alter table public.notification_log add column if not exists title      text;
alter table public.notification_log add column if not exists body       text;
alter table public.notification_log add column if not exists deep_link  text;
alter table public.notification_log add column if not exists read_at    timestamptz;
alter table public.notification_log add column if not exists payload    jsonb not null default '{}'::jsonb;
alter table public.notification_log add column if not exists updated_at timestamptz not null default now();
create index if not exists notification_log_user_idx  on public.notification_log (user_id, created_at desc);
create index if not exists notification_log_event_idx on public.notification_log (event_key, created_at desc);
create index if not exists notification_log_unread_idx on public.notification_log (user_id) where read_at is null;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. wa_event_routes push columns — shared with #297, same contract.
-- ─────────────────────────────────────────────────────────────────────────
alter table public.wa_event_routes add column if not exists push_enabled  boolean not null default false;
alter table public.wa_event_routes add column if not exists email_enabled boolean not null default false;
alter table public.wa_event_routes add column if not exists push_title    text;
alter table public.wa_event_routes add column if not exists push_body     text;
alter table public.wa_event_routes add column if not exists email_subject text;
alter table public.wa_event_routes add column if not exists email_body    text;
alter table public.wa_event_routes add column if not exists deep_link_kind text;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. notification_settings per-user opt-outs (spec item 7).
--    A NULL user_id row stays the GLOBAL default (the existing rows, and the
--    existing (audience, action_key) primary key still covers them). A row
--    with a user_id is that one user's override.
-- ─────────────────────────────────────────────────────────────────────────
alter table public.notification_settings add column if not exists user_id uuid;
alter table public.notification_settings add column if not exists channel text not null default 'all';
create unique index if not exists notification_settings_user_uidx
  on public.notification_settings (user_id, audience, action_key, channel)
  where user_id is not null;

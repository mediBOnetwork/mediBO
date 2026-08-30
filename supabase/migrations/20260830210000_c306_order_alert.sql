-- ============================================================================
-- CHANGE #306 — Zomato-style new-order alert for admin/ops.
--
-- The risk this table exists for: an UNPAID order is accepted, the inquiry
-- engine buys the stock from a supplier, and the customer then refuses to pay.
-- So the alert is not decoration — it is the gate. Everything the popup, the
-- notification, the badge and the escalation ladder SAY lives in
-- order_alert_config.labels; Flutter and Kotlin render what they are handed.
--
-- Idempotent by construction (#233): a resumed worker re-applies this and it
-- is a silent no-op.
-- ============================================================================

-- ── Config: every threshold, timing, limit and word ─────────────────────────
create table if not exists public.order_alert_config (
  id                        text primary key default 'singleton'
                              check (id = 'singleton'),
  enabled                   boolean not null default true,
  -- Escalation ladder, in seconds from the order landing.
  rering_after_s            integer not null default 60,
  wa_after_s                integer not null default 180,
  critical_after_s          integer not null default 300,
  -- How long an unactioned unpaid order lives before it is auto-cancelled.
  autocancel_after_min      integer not null default 45,
  -- How long ONE push keeps the phone ringing before the loop gives up.
  ring_seconds              integer not null default 120,
  -- Credit policy.
  new_customer_prepaid_only boolean not null default true,
  established_credit_limit  numeric not null default 25000,
  established_min_paid_orders integer not null default 1,
  enforce_credit_block      boolean not null default true,
  block_at_placement        boolean not null default false,
  -- The purchase gate: may an inquiry become a real supplier order?
  purchase_gate_enabled     boolean not null default true,
  labels                    jsonb  not null default '{}'::jsonb,
  updated_at                timestamptz not null default now(),
  updated_by                text
);

insert into public.order_alert_config (id) values ('singleton')
on conflict (id) do nothing;

-- ── One row per order that needs an admin decision ──────────────────────────
create table if not exists public.order_alert (
  id                bigserial primary key,
  order_id          uuid not null unique references public.orders(id) on delete cascade,
  order_code        text,
  customer_id       uuid,
  customer_name     text,
  amount            numeric not null default 0,
  -- 'unpaid' rings. 'prepaid' never rings — it is recorded so the feed can
  -- show it as a normal notification and nothing more.
  risk              text not null default 'unpaid',
  -- ringing | accepted | rejected | expired | auto_cancelled
  state             text not null default 'ringing',
  -- new | rering | whatsapp | critical
  stage             text not null default 'new',
  credit_blocked    boolean not null default false,
  credit_note       text,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz,
  first_push_at     timestamptz,
  last_push_at      timestamptz,
  push_count        integer not null default 0,
  wa_sent_at        timestamptz,
  critical_at       timestamptz,
  actioned_at       timestamptz,
  actioned_by       uuid,
  actioned_by_label text,
  action_reason     text,
  -- app | notification | auto
  action_source     text
);

create index if not exists order_alert_state_idx
  on public.order_alert (state, created_at desc);
create index if not exists order_alert_open_idx
  on public.order_alert (created_at desc) where state = 'ringing';

-- ── The one-shot credential a lock-screen button carries ────────────────────
-- An Accept tapped on the lock screen has no Supabase session to speak of, so
-- the push carries a token that authorises exactly this alert, for exactly the
-- admin whose device it was sent to, until the alert is over. No user JWT
-- ever leaves the app, and nothing long-lived is stored on the device.
create table if not exists public.order_alert_token (
  token       text primary key,
  alert_id    bigint not null references public.order_alert(id) on delete cascade,
  user_id     uuid,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists order_alert_token_alert_idx
  on public.order_alert_token (alert_id);

-- ── Per-customer credit ─────────────────────────────────────────────────────
-- Absent row = the policy in order_alert_config decides. A row is an explicit
-- decision by a named admin, and it wins.
create table if not exists public.customer_credit (
  customer_id  uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  credit_limit numeric not null default 0,
  prepaid_only boolean not null default false,
  note         text,
  updated_at   timestamptz not null default now(),
  updated_by   text
);

-- ── The purchase gate's audit trail ─────────────────────────────────────────
-- "Explicit admin override, logged with who and why" — this table IS the who
-- and the why. A supplier order for an unpaid customer cannot be sent without
-- a row here.
create table if not exists public.purchase_override (
  id                bigserial primary key,
  order_id          uuid references public.orders(id) on delete cascade,
  supplier_order_id uuid,
  granted_by        uuid,
  granted_by_label  text,
  reason            text not null,
  created_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  revoked_by        text
);
create index if not exists purchase_override_order_idx
  on public.purchase_override (order_id) where revoked_at is null;

-- ── Purchase decisions, allowed and blocked, for the admin screen ───────────
create table if not exists public.purchase_gate_log (
  id                bigserial primary key,
  order_id          uuid,
  supplier_order_id uuid,
  supplier_name     text,
  allowed           boolean not null,
  reason            text,
  detail            jsonb,
  created_at        timestamptz not null default now()
);
create index if not exists purchase_gate_log_at_idx
  on public.purchase_gate_log (created_at desc);

-- ── RLS: admin-only surfaces. Every RPC below is SECURITY DEFINER, so the
--    policies here only govern direct PostgREST reads (the realtime feed).
alter table public.order_alert_config enable row level security;
alter table public.order_alert        enable row level security;
alter table public.order_alert_token  enable row level security;
alter table public.customer_credit    enable row level security;
alter table public.purchase_override  enable row level security;
alter table public.purchase_gate_log  enable row level security;

do $$
declare t text;
begin
  foreach t in array array['order_alert_config','order_alert','customer_credit',
                           'purchase_override','purchase_gate_log']
  loop
    execute format('drop policy if exists %I on public.%I', t||'_admin_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (public.get_my_role() in (''admin'',''super_admin''))',
      t||'_admin_read', t);
  end loop;
  -- order_alert_token is never readable by a client: it is a credential.
  execute 'drop policy if exists order_alert_token_no_read on public.order_alert_token';
end $$;

comment on table public.order_alert is
  'CHANGE #306 — one admin decision per order. Unpaid orders ring; prepaid ones are recorded and silent.';

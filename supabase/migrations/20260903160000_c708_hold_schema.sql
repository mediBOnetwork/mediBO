-- CHANGE #708 (1/6) — order hold / park: the shape of it.
--
-- Verified absent before this change: an order moved forward or was cancelled,
-- and nothing else. A pharmacy that shut for a wedding, or wanted to pay next
-- week, or found the stock elsewhere, had one option — cancel — and the whole
-- fulfilment chain behind it (supplier orders, collected stock, bags) was torn
-- down with it.
--
-- A hold is NOT a fulfillment_status. Twelve RPCs scope open work with
-- `fulfillment_status not in ('shipped','cancelled')` (the #229 lesson), so a
-- new value there would have silently left held orders inside every one of
-- them. A hold is its own row, and every surface asks for it by name.
-- Idempotent throughout.

create table if not exists public.order_hold (
  id           bigint primary key generated always as identity,
  order_id     uuid not null references public.orders(id) on delete cascade,
  status       text not null default 'active'
                 check (status in ('active','resumed','cancelled')),
  stage_key    text,                          -- the stage it was held AT
  reason_code  text not null,
  reason_label text not null,                 -- frozen at hold time
  note         text,
  resume_on    date,
  auto_cancel_on date,
  held_by_kind text not null default 'customer'
                 check (held_by_kind in ('customer','staff','system')),
  held_by      uuid,
  held_by_label text,
  held_at      timestamptz not null default now(),
  resumed_at   timestamptz,
  resumed_by   uuid,
  resumed_kind text,
  resume_note  text,
  reminded_at  timestamptz,
  held_seconds bigint,                        -- filled on resume; the SLA credit
  created_at   timestamptz not null default now()
);

comment on table public.order_hold is
  'CHANGE #708 — one row per hold placed on an order. status=active is the '
  'live hold (at most one per order, by index); resumed/cancelled rows are the '
  'history the timeline reads. held_seconds is written on resume and is what '
  'pauses the #688 SLA clocks — the board subtracts it rather than storing a '
  'second copy of the elapsed time.';

create unique index if not exists order_hold_one_active
  on public.order_hold (order_id) where status = 'active';
create index if not exists order_hold_order_idx on public.order_hold (order_id, held_at desc);
create index if not exists order_hold_resume_idx
  on public.order_hold (resume_on) where status = 'active';
create index if not exists order_hold_cancel_idx
  on public.order_hold (auto_cancel_on) where status = 'active';

alter table public.order_hold enable row level security;

-- Nobody writes through the table: every write goes through a SECURITY DEFINER
-- RPC that decides who may do it. The customer reads their own holds so the
-- badge survives an offline render from cache.
drop policy if exists order_hold_read on public.order_hold;
create policy order_hold_read on public.order_hold
  for select to authenticated
  using (
    public.get_my_role() in ('admin','super_admin')
    or exists (select 1 from public.orders o
                join public.pharmacy_profiles p on p.id = o.customer_id
               where o.id = order_hold.order_id and p.user_id = auth.uid())
  );

-- ── which stages may be held, as DATA ──────────────────────────────────────
create table if not exists public.order_hold_stage (
  stage_key text primary key references public.sla_stage(stage_key) on delete cascade,
  allow     boolean not null default false,
  note      text
);

comment on table public.order_hold_stage is
  'CHANGE #708 — the stage gate. The spec allows a hold at pending/accepted, '
  'inquiry, inquiry-done (supplier_order) and packed; every other stage is one '
  'UPDATE away from allowed, with no deploy.';

insert into public.order_hold_stage (stage_key, allow, note)
select s.stage_key,
       s.stage_key in ('accept','inquiry','supplier_order','pack'),
       case when s.stage_key in ('accept','inquiry','supplier_order','pack')
            then 'CHANGE #708 — allowed by the spec.'
            else 'CHANGE #708 — not allowed: the order is already moving '
                 'physically at this stage.' end
  from public.sla_stage s
on conflict (stage_key) do nothing;

-- ── the reason chips, as DATA ──────────────────────────────────────────────
create table if not exists public.order_hold_reason (
  code       text primary key,
  label      text not null,
  audience   text not null default 'both' check (audience in ('customer','staff','both')),
  sort_order int not null default 100,
  is_active  boolean not null default true,
  needs_note boolean not null default false
);

comment on table public.order_hold_reason is
  'CHANGE #708 — the chips the hold sheet draws, in payload order. A new reason '
  'is an INSERT; Dart never holds a reason string.';

insert into public.order_hold_reason (code, label, audience, sort_order, needs_note) values
  ('shop_closed',    'Shop closed',                 'both',     10, false),
  ('cash_later',     'Will pay later',              'both',     20, false),
  ('stock_elsewhere','Stock came from elsewhere',    'both',     30, false),
  ('customer_asked', 'Customer asked us to hold it', 'staff',    40, false),
  ('other',          'Something else',               'both',     90, true)
on conflict (code) do nothing;

-- ── config ─────────────────────────────────────────────────────────────────
insert into public.app_settings (key, value) values
  ('order_hold', jsonb_build_object(
     'enabled',          true,
     'auto_cancel_days', 14,
     'remind_days',      1,
     'max_resume_days',  60,
     'note_max',         240))
on conflict (key) do nothing;

-- ── every word the surfaces print ──────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('order_hold.title',            to_jsonb('Hold my order'::text)),
  ('order_hold.subtitle',         to_jsonb('We will keep everything as it is and pick up exactly where we left off.'::text)),
  ('order_hold.reason_label',     to_jsonb('Why are we holding it?'::text)),
  ('order_hold.note_label',       to_jsonb('Anything we should know?'::text)),
  ('order_hold.note_hint',        to_jsonb('Optional'::text)),
  ('order_hold.resume_label',     to_jsonb('Start again on'::text)),
  ('order_hold.resume_hint',      to_jsonb('We will resume it for you on this date'::text)),
  ('order_hold.submit',           to_jsonb('Hold this order'::text)),
  ('order_hold.resume_submit',    to_jsonb('Resume now'::text)),
  ('order_hold.btn_hold',         to_jsonb('Hold'::text)),
  ('order_hold.btn_resume',       to_jsonb('Resume'::text)),
  ('order_hold.badge',            to_jsonb('On hold'::text)),
  ('order_hold.badge_reason',     to_jsonb('On hold — {reason}'::text)),
  ('order_hold.badge_until',      to_jsonb('On hold until {d}'::text)),
  ('order_hold.held_toast',       to_jsonb('Your order is on hold. Nothing moves until you resume it.'::text)),
  ('order_hold.resumed_toast',    to_jsonb('Your order is moving again.'::text)),
  ('order_hold.auto_cancel_note', to_jsonb('If it is still on hold on {d} we will cancel it and tell you.'::text)),
  ('order_hold.err_not_found',    to_jsonb('We could not find that order.'::text)),
  ('order_hold.err_not_yours',    to_jsonb('That order is not yours to hold.'::text)),
  ('order_hold.err_stage',        to_jsonb('This order is already at {stage} — it is too far along to hold. Call us and we will sort it out.'::text)),
  ('order_hold.err_already',      to_jsonb('This order is already on hold.'::text)),
  ('order_hold.err_not_held',     to_jsonb('This order is not on hold.'::text)),
  ('order_hold.err_reason',       to_jsonb('Please pick a reason.'::text)),
  ('order_hold.err_note',         to_jsonb('Please tell us a little more.'::text)),
  ('order_hold.err_resume_past',  to_jsonb('That date has already passed.'::text)),
  ('order_hold.err_resume_far',   to_jsonb('Please pick a date within {n} days.'::text)),
  ('order_hold.err_disabled',     to_jsonb('Holding an order is switched off right now.'::text)),
  ('order_hold.err_closed',       to_jsonb('This order is finished.'::text)),
  ('order_hold.no_date_label',    to_jsonb('No date yet'::text)),
  ('order_hold.held_by_customer', to_jsonb('Held by the pharmacy'::text)),
  ('order_hold.held_by_staff',    to_jsonb('Held by mediBO'::text)),
  ('order_hold.held_by_system',   to_jsonb('Held automatically'::text)),
  ('order_hold.count_label',      to_jsonb('{n} on hold'::text)),
  ('order_hold.dash_title',       to_jsonb('On hold'::text)),
  ('order_hold.stock_reserved',   to_jsonb('Stock reserved for this order'::text)),
  ('order_hold.stock_release',    to_jsonb('Release the stock'::text)),
  ('order_hold.stock_released',   to_jsonb('{n} bag line(s) released back to the shelf.'::text)),
  ('order_hold.release_reason',   to_jsonb('Why are you releasing it?'::text)),
  ('order_hold.timeline_held',    to_jsonb('Order held — {reason}'::text)),
  ('order_hold.timeline_resumed', to_jsonb('Order resumed'::text)),
  ('order_hold.timeline_cancelled', to_jsonb('Cancelled after {n} days on hold'::text)),
  ('order_hold.no_billing_note',  to_jsonb('Nothing is billed while an order is on hold.'::text))
on conflict (key) do nothing;

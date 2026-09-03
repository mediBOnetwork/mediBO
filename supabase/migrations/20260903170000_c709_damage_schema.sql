-- CHANGE #709 (1/6) — breakage inside the warehouse gets a record.
--
-- Verified absent before this change: there is no damage function anywhere.
-- Claims exist only on the rider's side (delivery_raise_claim); a strip crushed
-- at the counting table, a bottle that leaked in the bag or a wet carton found
-- at dispatch had NO record at all. The quantity simply went out short, or went
-- out damaged, and the customer's bill still carried it.
--
-- The ledger is additive: order_items.quantity is what the pharmacy ORDERED and
-- never changes. handling_damage rows are what was destroyed in our hands, and
-- every surface subtracts them — the bag ledger, the pack list, the bill, and
-- the unfulfilled split when a line reaches zero.
-- Idempotent throughout.

create table if not exists public.handling_damage (
  id             bigint primary key generated always as identity,
  order_id       uuid not null references public.orders(id) on delete cascade,
  order_item_id  uuid references public.order_items(id) on delete cascade,
  product_id     bigint,
  product_name   text,
  supplier_name  text,
  stage_key      text not null,
  qty            numeric not null check (qty > 0),
  reason_code    text not null,
  reason_label   text not null,
  note           text,
  bucket         text not null default 'partner'
                   check (bucket in ('partner','medibo','supplier')),
  bucket_label   text,
  amount         numeric,                     -- what it cost, at the line's own rate
  photo_bucket   text,
  photo_path     text,
  status         text not null default 'pending'
                   check (status in ('pending','confirmed','rejected','void')),
  worker_id      uuid,
  worker_label   text,
  task_id        bigint,
  zone_id        smallint,
  logged_by      uuid,
  logged_at      timestamptz not null default now(),
  confirmed_by   uuid,
  confirmed_at   timestamptz,
  reject_reason  text,
  applied_at     timestamptz,                 -- when the ledger was actually moved
  is_synthetic   boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table public.handling_damage is
  'CHANGE #709 — one row per quantity destroyed while mediBO was handling it. '
  'status=confirmed is the only state that moves a ledger: pending is a worker '
  'saying what happened, and a partner confirms it. The ordered quantity on '
  'order_items is never rewritten — every surface subtracts this table instead, '
  'so "what was ordered" and "what we broke" stay two separate facts.';

create index if not exists handling_damage_order_idx
  on public.handling_damage (order_id, status);
create index if not exists handling_damage_item_idx
  on public.handling_damage (order_item_id, status);
create index if not exists handling_damage_queue_idx
  on public.handling_damage (status, logged_at desc) where status = 'pending';
create index if not exists handling_damage_worker_idx
  on public.handling_damage (worker_id, logged_at desc);
create index if not exists handling_damage_supplier_idx
  on public.handling_damage (supplier_name, logged_at desc);
create index if not exists handling_damage_zone_idx
  on public.handling_damage (zone_id, logged_at desc);

alter table public.handling_damage enable row level security;

-- Nobody writes through the table; the customer may READ what was broken on
-- their own order, because the bill tells them anyway.
drop policy if exists handling_damage_read on public.handling_damage;
create policy handling_damage_read on public.handling_damage
  for select to authenticated
  using (
    public.get_my_role() in ('admin','super_admin')
    or exists (select 1 from public.orders o
                join public.pharmacy_profiles p on p.id = o.customer_id
               where o.id = handling_damage.order_id and p.user_id = auth.uid())
  );

-- ── the reason codes, as DATA ─────────────────────────────────────────────
create table if not exists public.handling_damage_reason (
  code        text primary key,
  label       text not null,
  sort_order  int not null default 100,
  is_active   boolean not null default true,
  needs_photo boolean not null default false,
  -- who carries the cost by default; the zone config may override it
  default_bucket text not null default 'partner'
    check (default_bucket in ('partner','medibo','supplier'))
);

insert into public.handling_damage_reason
  (code, label, sort_order, needs_photo, default_bucket) values
  ('broken',      'Broken',              10, true,  'partner'),
  ('leaked',      'Leaked',              20, true,  'partner'),
  ('wet',         'Wet',                 30, true,  'partner'),
  ('wrong_pack',  'Wrong pack',          40, false, 'supplier'),
  ('expired',     'Expired stock found', 50, true,  'supplier')
on conflict (code) do nothing;

-- ── the stages damage may be logged at, as DATA ──────────────────────────
create table if not exists public.handling_damage_stage (
  stage_key text primary key,
  allow     boolean not null default true,
  label     text,
  sort_order int not null default 100
);

insert into public.handling_damage_stage (stage_key, allow, label, sort_order) values
  ('count',    true, 'At counting',  10),
  ('bag',      true, 'At bagging',   20),
  ('pack',     true, 'At packing',   30),
  ('dispatch', true, 'At dispatch',  40)
on conflict (stage_key) do nothing;

-- ── config: who bears it, and when it becomes an exception ───────────────
insert into public.app_settings (key, value) values
  ('handling_damage', jsonb_build_object(
     'enabled',        true,
     'confirm_required', true,
     'rate_threshold_pct', 2.0,     -- damage rate above this raises an exception
     'min_events',     3,           -- ...but never off a single unlucky order
     'window_days',    30,
     'auto_reinquiry', true,
     'zone_bucket',    jsonb_build_object()))   -- zone_id -> partner|medibo|supplier
on conflict (key) do nothing;

-- ── every word the surfaces print ────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('damage.title',              to_jsonb('Report damage'::text)),
  ('damage.subtitle',           to_jsonb('Tell us what broke and how much of it, and we will keep it off the bill.'::text)),
  ('damage.qty_label',          to_jsonb('How many'::text)),
  ('damage.reason_label',       to_jsonb('What happened?'::text)),
  ('damage.note_label',         to_jsonb('Anything else?'::text)),
  ('damage.note_hint',          to_jsonb('Optional'::text)),
  ('damage.photo_label',        to_jsonb('Photo of the damage'::text)),
  ('damage.photo_hint',         to_jsonb('Required for this reason'::text)),
  ('damage.submit',             to_jsonb('Log the damage'::text)),
  ('damage.confirm',            to_jsonb('Confirm'::text)),
  ('damage.reject',             to_jsonb('Not damage'::text)),
  ('damage.stage_label',        to_jsonb('Found at {stage}'::text)),
  ('damage.logged_toast',       to_jsonb('Recorded. A partner will confirm it.'::text)),
  ('damage.confirmed_toast',    to_jsonb('Confirmed — {qty} taken off the order and the bill.'::text)),
  ('damage.rejected_toast',     to_jsonb('Marked as not damage. Nothing was changed.'::text)),
  ('damage.line_note',          to_jsonb('{qty} {unit} damaged in handling — not billed'::text)),
  ('damage.unit_default',       to_jsonb('units'::text)),
  ('damage.zero_line_reason',   to_jsonb('Damaged in handling'::text)),
  ('damage.pending_label',      to_jsonb('Waiting for a partner to confirm'::text)),
  ('damage.confirmed_label',    to_jsonb('Confirmed'::text)),
  ('damage.rejected_label',     to_jsonb('Not damage'::text)),
  ('damage.err_not_authorized', to_jsonb('You cannot report damage on this order.'::text)),
  ('damage.err_confirm_auth',   to_jsonb('Only a partner or mediBO can confirm damage.'::text)),
  ('damage.err_no_item',        to_jsonb('We could not find that line.'::text)),
  ('damage.err_qty',            to_jsonb('Enter how many were damaged.'::text)),
  ('damage.err_qty_over',       to_jsonb('That is more than the {n} on this line.'::text)),
  ('damage.err_reason',         to_jsonb('Pick what happened.'::text)),
  ('damage.err_photo',          to_jsonb('This reason needs a photo.'::text)),
  ('damage.err_stage',          to_jsonb('Damage cannot be logged at this stage.'::text)),
  ('damage.err_done',           to_jsonb('That damage report has already been dealt with.'::text)),
  ('damage.err_disabled',       to_jsonb('Damage reporting is switched off right now.'::text)),
  ('damage.bucket.partner',     to_jsonb('Partner bears it'::text)),
  ('damage.bucket.medibo',      to_jsonb('mediBO bears it'::text)),
  ('damage.bucket.supplier',    to_jsonb('Supplier bears it'::text)),
  ('damage.report_title',       to_jsonb('Damage report'::text)),
  ('damage.report_empty',       to_jsonb('No damage recorded in this window.'::text)),
  ('damage.rate_label',         to_jsonb('{pct}% of what was handled'::text)),
  ('damage.tab_worker',         to_jsonb('By worker'::text)),
  ('damage.tab_supplier',       to_jsonb('By supplier'::text)),
  ('damage.tab_product',        to_jsonb('By product'::text)),
  ('damage.tab_queue',          to_jsonb('To confirm'::text)),
  ('damage.count_label',        to_jsonb('{n} report(s)'::text)),
  ('damage.qty_summary',        to_jsonb('{qty} unit(s) over {n} report(s)'::text)),
  ('damage.exception_title',    to_jsonb('Damage rate above threshold'::text)),
  ('damage.cost_type_label',    to_jsonb('Handling damage'::text)),
  ('damage.none_label',         to_jsonb('—'::text))
on conflict (key) do nothing;

-- The settlement's own cost type, so a damage line lands where every other
-- cost on an order already lands (order_costs -> partner settlement).
insert into public.cost_types (slug, label, basis, default_value, rate_value, active)
select 'handling_damage', public._c('damage.cost_type_label'), 'flat', 0, 0, true
where not exists (select 1 from public.cost_types where slug = 'handling_damage');

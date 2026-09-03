-- CHANGE #707 — a fulfil stage gets an OWNER.
--
-- Today the pipeline knows the stage an order sits in (sla_stage, ops_board)
-- and it knows, per item, who touched it afterwards (order_items.packed_by,
-- pack_counted_by, received_by, collect_locked_by). What it has never known is
-- who is SUPPOSED to do the next stage. So a partner cannot hand work out, a
-- worker cannot be told what is theirs, and nobody can be measured: 24 RPCs
-- write an actor column and not one of them answers "whose job was this".
--
-- This migration is the record that answers it. One open task per order-stage
-- (per supplier, where the stage is per-supplier), assigned to a named worker
-- from the partner's own roster, with the clock and the quantity it handled.
--
-- Nothing here computes for the client: every label lands in ui_copy and every
-- decision (auto-assign on/off, how many minutes an unassigned task may age)
-- is a config row, so changing either is an UPDATE, not a deploy.
--
-- Idempotent throughout: create ... if not exists, on conflict do update.

-- ── the task ────────────────────────────────────────────────────────────────
create table if not exists public.fulfil_task (
  id              bigserial primary key,
  partner_id      bigint,
  zone_id         smallint,
  order_id        uuid        not null,
  stage_key       text        not null,
  -- Collect is per SUPPLIER within one order, so the identity of a task is
  -- (order, stage, supplier) and supplier_key is null for the stages that are
  -- whole-order. A nullable column in a unique index is why the index below
  -- coalesces rather than trusting NULL <> NULL.
  supplier_key    text,
  worker_id       bigint      references public.partner_worker(id) on delete set null,
  assigned_at     timestamptz,
  assigned_by     text,
  source          text        not null default 'manual',
  started_at      timestamptz,
  done_at         timestamptz,
  qty_handled     numeric     not null default 0,
  items_touched   integer     not null default 0,
  -- The override is a fact on the row, not a deletion of the assignment: the
  -- board must be able to say "X closed a stage assigned to Y, and here is who
  -- allowed it".
  override_by     text,
  override_at     timestamptz,
  override_reason text,
  is_synthetic    boolean     not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

do $$ begin
  alter table public.fulfil_task
    add constraint fulfil_task_source_ck check (source in ('manual','auto'));
exception when duplicate_object then null; end $$;

-- ONE OPEN TASK PER ORDER-STAGE. The spec's own line, enforced by the database
-- rather than by every writer remembering it.
create unique index if not exists uq_fulfil_task_open
  on public.fulfil_task (order_id, stage_key, coalesce(supplier_key,''))
  where done_at is null;

create index if not exists ix_fulfil_task_worker_day
  on public.fulfil_task (worker_id, done_at);
create index if not exists ix_fulfil_task_open_zone
  on public.fulfil_task (zone_id, stage_key) where done_at is null;
create index if not exists ix_fulfil_task_order
  on public.fulfil_task (order_id);

alter table public.fulfil_task enable row level security;
revoke all on public.fulfil_task from anon, authenticated;

-- ── the config, per zone ────────────────────────────────────────────────────
-- zone_id null is the platform default; a zone row beats it. Same shape as
-- sla_config, which the ops board already resolves this way.
create table if not exists public.fulfil_task_config (
  zone_id              smallint,
  auto_assign          boolean not null default false,
  unassigned_alert_min integer not null default 20,
  stages               text[]  not null default array['collect','count','bag','pack','dispatch'],
  is_active            boolean not null default true,
  updated_at           timestamptz not null default now()
);
create unique index if not exists uq_fulfil_task_config_zone
  on public.fulfil_task_config ((coalesce(zone_id, (-1)::smallint)));

alter table public.fulfil_task_config enable row level security;
revoke all on public.fulfil_task_config from anon, authenticated;

insert into public.fulfil_task_config (zone_id, auto_assign, unassigned_alert_min, stages)
select null::smallint, false, 20, array['collect','count','bag','pack','dispatch']
where not exists (select 1 from public.fulfil_task_config where zone_id is null);

-- ── the resolved config, one place ──────────────────────────────────────────
create or replace function public._c707_cfg(p_zone smallint)
returns public.fulfil_task_config
language sql stable security definer set search_path to 'public' as $fn$
  select c.* from public.fulfil_task_config c
   where c.is_active and (c.zone_id = p_zone or c.zone_id is null)
   order by (c.zone_id is null)   -- a zone row beats the platform default
   limit 1
$fn$;

-- ── who am I, as a worker ───────────────────────────────────────────────────
-- my_worker_id() already exists and means something else entirely (lead_workers,
-- the marketing roster). This is the fulfilment roster, resolved the same way
-- my_partner_id() resolves a partner: through the identity keys of the login.
create or replace function public.my_fulfil_worker_id()
returns bigint
language sql stable security definer set search_path to 'public' as $fn$
  select w.id from public.partner_worker w
   where w.is_active and w.identity = any (public.my_identity_keys())
   order by w.id limit 1
$fn$;

-- ── copy ────────────────────────────────────────────────────────────────────
-- Every string the three surfaces print. Placeholders are SINGLE brace: the
-- renderers here are replace()/_cf(), and #703 already paid for the double
-- brace form once.
insert into public.ui_copy (key, value) values
  ('ft.title',            '"Task board"'::jsonb),
  ('ft.subtitle',         '"Who is doing each stage, right now"'::jsonb),
  ('ft.my_title',         '"My tasks"'::jsonb),
  ('ft.my_subtitle',      '"Today, in the order they are promised"'::jsonb),
  ('ft.not_authorized',   '"You do not have access to the task board."'::jsonb),
  ('ft.empty',            '"No stages are waiting for a worker right now."'::jsonb),
  ('ft.my_empty',         '"Nothing is assigned to you today."'::jsonb),
  ('ft.unassigned',       '"Unassigned"'::jsonb),
  ('ft.assign',           '"Assign"'::jsonb),
  ('ft.reassign',         '"Reassign"'::jsonb),
  ('ft.auto_assign',      '"Auto-assign"'::jsonb),
  ('ft.auto_on',          '"Auto-assign is on for this zone"'::jsonb),
  ('ft.auto_off',         '"Auto-assign is off for this zone"'::jsonb),
  ('ft.assigned_to',      '"{worker}"'::jsonb),
  ('ft.assigned_auto',    '"{worker} · auto"'::jsonb),
  ('ft.start',            '"Start"'::jsonb),
  ('ft.finish',           '"Finish"'::jsonb),
  ('ft.started_label',    '"Started {ago}"'::jsonb),
  ('ft.done_label',       '"Done {ago}"'::jsonb),
  ('ft.waiting_label',    '"Waiting {ago}"'::jsonb),
  ('ft.promised_label',   '"Promised {time}"'::jsonb),
  ('ft.no_promise',       '"No promised time"'::jsonb),
  ('ft.qty_label',        '"{n} items"'::jsonb),
  ('ft.qty_one',          '"1 item"'::jsonb),
  ('ft.qty_none',         '"Nothing counted yet"'::jsonb),
  ('ft.assigned_ok',      '"Assigned to {worker}"'::jsonb),
  ('ft.unassigned_ok',    '"Assignment cleared"'::jsonb),
  ('ft.started_ok',       '"Started"'::jsonb),
  ('ft.finished_ok',      '"Task closed"'::jsonb),
  ('ft.err_not_yours',    '"This stage is assigned to {worker}. A partner can override."'::jsonb),
  ('ft.err_no_worker',    '"That worker is not on this partner''s roster."'::jsonb),
  ('ft.err_off_shift',    '"{worker} is not marked present today."'::jsonb),
  ('ft.err_no_task',      '"That stage has no open task."'::jsonb),
  ('ft.err_no_one_free',  '"No worker is on shift for this zone today."'::jsonb),
  ('ft.err_failed',       '"Could not save: {detail}"'::jsonb),
  ('ft.override_label',   '"Override"'::jsonb),
  ('ft.override_ok',      '"Closed as an override — {worker} was assigned"'::jsonb),
  ('ft.override_chip',    '"Override"'::jsonb),
  ('ft.source_manual',    '"Assigned by hand"'::jsonb),
  ('ft.source_auto',      '"Auto-assigned"'::jsonb),
  ('ft.workers_title',    '"Workers today"'::jsonb),
  ('ft.prod_tasks',       '"Tasks"'::jsonb),
  ('ft.prod_items',       '"Items/hour"'::jsonb),
  ('ft.prod_variance',    '"Count variance"'::jsonb),
  ('ft.prod_packerr',     '"Pack errors"'::jsonb),
  ('ft.prod_none',        '"—"'::jsonb),
  ('ft.prod_open',        '"{n} open"'::jsonb),
  ('ops_board.assignee_label',   '"Owner"'::jsonb),
  ('ops_board.unassigned',       '"Unassigned"'::jsonb),
  ('exc.reason.fulfil_task_unassigned', '"Stage with no worker"'::jsonb),
  ('exc.action.fulfil_task_unassigned', '"Assign a worker"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ── the exception reason ────────────────────────────────────────────────────
-- Owned by the zone, routed to the task board. sla_hours 0 means "the moment
-- it appears it is already late" — the ageing threshold is the config's own
-- unassigned_alert_min, applied where the row is produced.
insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind,
   action_route, sort_rank, enabled)
values
  ('fulfil_task_unassigned', 'fulfil_task', 3, 0, 'zone', 'route',
   'fulfil_tasks', 68, true)
on conflict (reason_code) do update
  set source_key   = excluded.source_key,
      severity     = excluded.severity,
      owner_kind   = excluded.owner_kind,
      action_kind  = excluded.action_kind,
      action_route = excluded.action_route,
      enabled      = true;

-- ── the two nav doors ───────────────────────────────────────────────────────
-- The partner's board, and the worker's own list. Two features because they
-- are two audiences with two answers to "what is mine", not one screen with a
-- role branch drawn in Dart.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, deep_link, search_terms, description,
   partner_feature_key, canonical_key)
values
  ('partner.fulfil_tasks', 'Task board', 'Fulfilment', 'people', 'fulfil_tasks',
   7, 'partner', true, 'write', true, 'orders', 'dashboard',
   '{admin,super_admin}', '/admin/go/fulfil_tasks',
   'task assign worker stage count pack bag collect productivity',
   'Who owns each fulfilment stage, and how each worker is doing today.',
   'partner.fulfil_tasks', 'partner.fulfil_tasks'),
  ('worker.my_tasks', 'My tasks', 'Fulfilment', 'people', 'my_tasks',
   -- owner is the OWNING SIDE of the feature (feature_registry_owner_check
   -- admits 'medibo' or 'partner' only), not the audience. The worker list is
   -- a platform surface handed to a worker login; the audience lives in
   -- roles_allowed, which is what nav_registry actually gates on.
   8, 'medibo', false, 'none', true, 'orders', 'dashboard',
   '{worker,admin,super_admin}', '/admin/go/my_tasks',
   'my tasks worker today start finish',
   'The stages assigned to you today, in promised order.',
   null, 'worker.my_tasks')
on conflict (feature_key) do update
  set label          = excluded.label,
      group_label    = excluded.group_label,
      route_key      = excluded.route_key,
      icon_key       = excluded.icon_key,
      sort_order     = excluded.sort_order,
      owner          = excluded.owner,
      partner_eligible = excluded.partner_eligible,
      default_access = excluded.default_access,
      is_active      = true,
      category       = excluded.category,
      surface        = excluded.surface,
      roles_allowed  = excluded.roles_allowed,
      deep_link      = excluded.deep_link,
      search_terms   = excluded.search_terms,
      description    = excluded.description;

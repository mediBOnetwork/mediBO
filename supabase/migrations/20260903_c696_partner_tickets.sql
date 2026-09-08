-- CHANGE #696 (1/3) — the mediBO <-> partner escalation channel: the store.
--
-- Verified absent before this change: no escalation table, no partner_chat,
-- no ticket of any kind between the office and a zone partner. A partner with
-- a stuck settlement, a supplier who will not answer, or a bug in the app sent
-- a WhatsApp message to whoever they had a number for; the office chasing a
-- count dispute did the same in the other direction. Nothing had an owner, a
-- clock, or an outcome anybody could count afterwards.
--
-- This is the same shape #713 gave the CUSTOMER conversation, for the other
-- counterparty: one row per issue, one message store, an SLA that belongs to
-- the CATEGORY (config, not code), an owner assigned at raise time by the
-- direction the issue travels, and a closure that cannot happen without an
-- outcome code — which is what makes the channel feed the partner scorecard
-- (#693) instead of evaporating into a chat log.
--
-- Max-backend: every label, chip, tone, sentence and button caption is a
-- ui_copy key resolved here. The Flutter screen renders the payload.
--
-- Idempotent throughout: create ... if not exists / on conflict do update. A
-- resumed worker re-applies this file as a silent no-op.

-- ── categories: the enum, as DATA ───────────────────────────────────────────
-- A new category is an INSERT plus its two ui_copy keys — never a deploy.
-- `direction` says who may RAISE it, `sla_hours` is the promise for that kind
-- of issue, and `link_kind` is the object the ticket points at.
create table if not exists public.partner_ticket_category (
  code             text primary key,
  direction        text    not null default 'partner',
  label_key        text    not null,
  hint_key         text    not null default '',
  link_kind        text    not null default 'none',
  sla_hours        numeric not null default 24,
  default_priority text    not null default 'normal',
  sort_order       integer not null default 100,
  active           boolean not null default true,
  constraint partner_ticket_category_dir_ck
    check (direction in ('partner','medibo')),
  constraint partner_ticket_category_link_ck
    check (link_kind in ('none','order','supplier','settlement'))
);
alter table public.partner_ticket_category enable row level security;
drop policy if exists partner_ticket_category_read on public.partner_ticket_category;
create policy partner_ticket_category_read on public.partner_ticket_category
  for select using (auth.uid() is not null);

insert into public.partner_ticket_category
  (code, direction, label_key, hint_key, link_kind, sla_hours, default_priority, sort_order)
values
  -- raised BY the partner, owned by the mediBO office
  ('order',            'partner', 'pt.cat.order',            'pt.cat.order.hint',            'order',      8,  'normal', 10),
  ('supplier',         'partner', 'pt.cat.supplier',         'pt.cat.supplier.hint',         'supplier',   12, 'normal', 20),
  ('payment',          'partner', 'pt.cat.payment',          'pt.cat.payment.hint',          'settlement', 24, 'normal', 30),
  ('app_bug',          'partner', 'pt.cat.app_bug',          'pt.cat.app_bug.hint',          'none',       48, 'low',    40),
  ('delivery',         'partner', 'pt.cat.delivery',         'pt.cat.delivery.hint',         'order',      6,  'high',   50),
  -- raised BY mediBO, owned by the partner
  ('sla_breach',       'medibo',  'pt.cat.sla_breach',       'pt.cat.sla_breach.hint',       'order',      12, 'high',   60),
  ('count_dispute',    'medibo',  'pt.cat.count_dispute',    'pt.cat.count_dispute.hint',    'order',      24, 'normal', 70),
  ('settlement_query', 'medibo',  'pt.cat.settlement_query', 'pt.cat.settlement_query.hint', 'settlement', 48, 'normal', 80)
on conflict (code) do update set
  direction        = excluded.direction,
  label_key        = excluded.label_key,
  hint_key         = excluded.hint_key,
  link_kind        = excluded.link_kind,
  sla_hours        = excluded.sla_hours,
  default_priority = excluded.default_priority,
  sort_order       = excluded.sort_order,
  active           = true;

-- ── priority: the multiplier on the category's promise ──────────────────────
-- Urgent does not get its own SLA table; it SHORTENS the category's, so the
-- two knobs can never disagree about what "due" means.
create table if not exists public.partner_ticket_priority (
  code       text primary key,
  label_key  text    not null,
  sla_factor numeric not null default 1,
  tone       text    not null default 'info',
  sort_order integer not null default 100,
  active     boolean not null default true
);
alter table public.partner_ticket_priority enable row level security;
drop policy if exists partner_ticket_priority_read on public.partner_ticket_priority;
create policy partner_ticket_priority_read on public.partner_ticket_priority
  for select using (auth.uid() is not null);

insert into public.partner_ticket_priority (code, label_key, sla_factor, tone, sort_order)
values ('urgent', 'pt.pri.urgent', 0.25, 'danger',  10),
       ('high',   'pt.pri.high',   0.5,  'warning', 20),
       ('normal', 'pt.pri.normal', 1,    'info',    30),
       ('low',    'pt.pri.low',    2,    'neutral', 40)
on conflict (code) do update set
  label_key = excluded.label_key, sla_factor = excluded.sla_factor,
  tone = excluded.tone, sort_order = excluded.sort_order, active = true;

-- ── outcomes: closure is not a status, it is an ANSWER ──────────────────────
-- fault_side + weight are what #693's scorecard reads. A closure with no
-- outcome is refused by partner_ticket_close(), which is the whole point of
-- the table: "resolved" that nobody classified teaches the platform nothing.
create table if not exists public.partner_ticket_outcome (
  code        text primary key,
  label_key   text    not null,
  applies_to  text    not null default 'all',
  fault_side  text    not null default 'none',
  weight      numeric not null default 0,
  is_success  boolean not null default true,
  sort_order  integer not null default 50,
  active      boolean not null default true,
  constraint partner_ticket_outcome_applies_ck
    check (applies_to in ('all','partner','medibo')),
  constraint partner_ticket_outcome_fault_ck
    check (fault_side in ('none','partner','medibo','supplier'))
);
alter table public.partner_ticket_outcome enable row level security;
drop policy if exists partner_ticket_outcome_read on public.partner_ticket_outcome;
create policy partner_ticket_outcome_read on public.partner_ticket_outcome
  for select using (auth.uid() is not null);

insert into public.partner_ticket_outcome
  (code, label_key, applies_to, fault_side, weight, is_success, sort_order)
values
  ('fixed',            'pt.out.fixed',            'all',    'none',     0, true,  10),
  ('partner_corrected','pt.out.partner_corrected','medibo', 'partner',  1, true,  20),
  ('medibo_corrected', 'pt.out.medibo_corrected', 'partner','medibo',   0, true,  30),
  ('supplier_at_fault','pt.out.supplier_at_fault','all',    'supplier', 0, true,  40),
  ('no_fault',         'pt.out.no_fault',         'all',    'none',     0, true,  50),
  ('duplicate',        'pt.out.duplicate',        'all',    'none',     0, true,  60),
  ('not_actioned',     'pt.out.not_actioned',     'medibo', 'partner',  2, false, 70),
  ('withdrawn',        'pt.out.withdrawn',        'all',    'none',     0, true,  80)
on conflict (code) do update set
  label_key = excluded.label_key, applies_to = excluded.applies_to,
  fault_side = excluded.fault_side, weight = excluded.weight,
  is_success = excluded.is_success, sort_order = excluded.sort_order, active = true;

-- ── the working-hours window and the escalation switches ────────────────────
-- "8 hours" is a promise about a working day, not about 03:00 — the same rule
-- #713 applies to a customer message, reusing its business-hours function so
-- the platform has ONE opinion about when the clock runs.
create table if not exists public.partner_ticket_config (
  id                 smallint primary key default 1,
  business_start_ist time    not null default '09:00',
  business_end_ist   time    not null default '21:00',
  nudge_at_fraction  numeric not null default 0.5,
  nudge_enabled      boolean not null default true,
  breach_ops_inbox   boolean not null default true,
  scorecard_feed     boolean not null default true,
  updated_at         timestamptz not null default now(),
  constraint partner_ticket_config_single check (id = 1)
);
insert into public.partner_ticket_config(id) values (1) on conflict (id) do nothing;
alter table public.partner_ticket_config enable row level security;
drop policy if exists partner_ticket_config_read on public.partner_ticket_config;
create policy partner_ticket_config_read on public.partner_ticket_config
  for select using (auth.uid() is not null);

-- ── the ticket ──────────────────────────────────────────────────────────────
create sequence if not exists public.partner_ticket_ref_seq;

create table if not exists public.partner_ticket (
  id                uuid primary key default gen_random_uuid(),
  ref               text unique,
  partner_id        bigint not null references public.region_partners(id),
  zone_id           bigint,
  -- WHO raised it decides WHO owns it: a partner's issue is the office's to
  -- answer, and the office's issue is the partner's. Nothing client-side ever
  -- picks an owner.
  raised_side       text not null,
  raised_by         uuid,
  raised_by_label   text not null default '',
  owner_side        text not null,
  category_code     text not null references public.partner_ticket_category(code),
  priority          text not null default 'normal'
                      references public.partner_ticket_priority(code),
  subject           text not null default '',
  status            text not null default 'open',
  link_kind         text not null default 'none',
  link_ref          text not null default '',
  -- the clock
  sla_hours         numeric,
  sla_due_at        timestamptz,
  nudge_due_at      timestamptz,
  nudged_at         timestamptz,
  breached_at       timestamptz,
  first_reply_at    timestamptz,
  -- the close
  resolved_at       timestamptz,
  closed_at         timestamptz,
  closed_by         uuid,
  closed_side       text,
  outcome_code      text references public.partner_ticket_outcome(code),
  outcome_note      text not null default '',
  last_message_at   timestamptz,
  last_actor_side   text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint partner_ticket_raised_ck check (raised_side in ('partner','medibo')),
  constraint partner_ticket_owner_ck  check (owner_side  in ('partner','medibo')),
  constraint partner_ticket_status_ck
    check (status in ('open','waiting','resolved','closed'))
);

create index if not exists partner_ticket_partner_ix
  on public.partner_ticket (partner_id, status, created_at desc);
create index if not exists partner_ticket_open_ix
  on public.partner_ticket (sla_due_at) where status <> 'closed';
create index if not exists partner_ticket_zone_ix
  on public.partner_ticket (zone_id, status, sla_due_at);
-- the tick's own index: the clocks still running
create index if not exists partner_ticket_due_ix
  on public.partner_ticket (nudge_due_at)
  where status in ('open','waiting') and nudged_at is null;

alter table public.partner_ticket enable row level security;
-- Reads go through the RPCs (security definer, zone-scoped). The direct-table
-- policy is deliberately the same clamp, so a client that ever queries the
-- table with the anon key sees exactly what the RPC would have shown it.
drop policy if exists partner_ticket_read on public.partner_ticket;
create policy partner_ticket_read on public.partner_ticket
  for select using (
    public._is_admin()
    or partner_id = public.my_partner_id()
  );

-- ── the timeline ────────────────────────────────────────────────────────────
create table if not exists public.partner_ticket_message (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.partner_ticket(id) on delete cascade,
  body         text not null default '',
  actor_side   text not null,
  actor_id     uuid,
  actor_label  text not null default '',
  kind         text not null default 'message',
  attachments  jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  constraint partner_ticket_message_side_ck
    check (actor_side in ('partner','medibo','system')),
  constraint partner_ticket_message_kind_ck
    check (kind in ('message','status','system','close'))
);
create index if not exists partner_ticket_message_ix
  on public.partner_ticket_message (ticket_id, created_at);

alter table public.partner_ticket_message enable row level security;
drop policy if exists partner_ticket_message_read on public.partner_ticket_message;
create policy partner_ticket_message_read on public.partner_ticket_message
  for select using (
    exists (select 1 from public.partner_ticket t
             where t.id = ticket_id
               and (public._is_admin() or t.partner_id = public.my_partner_id()))
  );

-- ── the ops-inbox reason, in the console's own vocabulary ───────────────────
insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind,
   action_route, sort_rank, enabled)
values ('partner_ticket_breach', 'partner_ticket', 2, 0, 'admin', 'route',
        'partner_issues', 73, true)
on conflict (reason_code) do update set
  source_key = excluded.source_key, severity = excluded.severity,
  owner_kind = excluded.owner_kind, action_kind = excluded.action_kind,
  action_route = excluded.action_route, sort_rank = excluded.sort_rank,
  enabled = true;

-- ── the attachment bucket: private, partner-writable in its OWN folder ──────
-- Same folder convention as partner-receipts (#399): 'p<partner_id>/...'. The
-- client never composes that path — partner_ticket_new()/_get() hand it back
-- in an `upload` block, so the rule lives in one place and a partner can only
-- ever write under their own prefix.
insert into storage.buckets (id, name, public)
values ('partner-issue-files','partner-issue-files', false)
on conflict (id) do nothing;

drop policy if exists partner_issue_files_select on storage.objects;
create policy partner_issue_files_select on storage.objects for select
  using (bucket_id = 'partner-issue-files'
         and (public.role_for_medibo_only() in ('admin','super_admin')
              or (public.my_partner_id() is not null
                  and (storage.foldername(name))[1] = 'p' || public.my_partner_id()::text)));

drop policy if exists partner_issue_files_insert on storage.objects;
create policy partner_issue_files_insert on storage.objects for insert
  with check (bucket_id = 'partner-issue-files'
              and (public.role_for_medibo_only() in ('admin','super_admin')
                   or (public.my_partner_id() is not null
                       and (storage.foldername(name))[1] = 'p' || public.my_partner_id()::text)));

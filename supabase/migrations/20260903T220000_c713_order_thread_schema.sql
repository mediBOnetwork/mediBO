-- CHANGE #713 (1/8) — ONE CONVERSATION PER ORDER: the store.
--
-- What was there: support_ticket / support_ticket_message / support_topic, an
-- admin-only support_inbox with no zone routing and no SLA, and every other
-- customer word scattered across WhatsApp threads that nobody owned. Three
-- places to look for "what did this customer say", and no answer to "who is
-- supposed to reply".
--
-- What this is: ONE message store per order. Every actor writes into it —
-- customer (from the app OR a WhatsApp reply), the zone partner, and mediBO
-- admin — and every message carries the actor's role, so the customer's own
-- view can render partner and admin alike as "mediBO" without the client
-- deciding that. A ticket stops being a separate conversation: it keeps its
-- reference, status and topic and points at the thread.
--
-- Idempotent throughout: create ... if not exists, add column if not exists,
-- on conflict do nothing. A resumed worker re-applies this as a no-op.

-- ── the thread ──────────────────────────────────────────────────────────────
create table if not exists public.order_thread (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid references public.orders(id) on delete cascade,
  customer_id       uuid references public.pharmacy_profiles(id),
  zone_id           smallint,
  partner_id        bigint references public.region_partners(id),
  -- Ownership. 'none' until a customer speaks; then the zone partner, and
  -- 'admin' once an unanswered message has escalated.
  owner_kind        text not null default 'none',
  owner_partner_id  bigint references public.region_partners(id),
  owner_label       text not null default '',
  topic_code        text references public.support_topic(code),
  status            text not null default 'open',
  last_message_at   timestamptz,
  last_actor_role   text,
  -- The clock. awaiting_since is the moment the customer last spoke with
  -- nobody having answered since; sla_due_at is when that becomes a breach.
  awaiting_since    timestamptz,
  sla_due_at        timestamptz,
  escalated_at      timestamptz,
  breach_logged_at  timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint order_thread_owner_kind_ck check (owner_kind in ('none','partner','admin')),
  constraint order_thread_status_ck     check (status in ('open','answered','closed'))
);

-- One thread per order. A thread with no order is a ticket that names none
-- (the customer's own general conversation), and there may be several.
create unique index if not exists order_thread_order_uq
  on public.order_thread (order_id) where order_id is not null;
create index if not exists order_thread_zone_ix
  on public.order_thread (zone_id, status, last_message_at desc);
create index if not exists order_thread_customer_ix
  on public.order_thread (customer_id, last_message_at desc);
-- The escalation tick's own index: the threads with a clock still running.
create index if not exists order_thread_due_ix
  on public.order_thread (sla_due_at) where escalated_at is null and awaiting_since is not null;

-- ── the messages ────────────────────────────────────────────────────────────
create table if not exists public.order_thread_message (
  id               uuid primary key default gen_random_uuid(),
  thread_id        uuid not null references public.order_thread(id) on delete cascade,
  ticket_id        uuid references public.support_ticket(id) on delete set null,
  body             text not null default '',
  -- The role is stamped at write time from the writer's own identity. The
  -- customer's view collapses partner+admin into one name; that mapping is
  -- made in SQL, not in Dart.
  actor_role       text not null,
  actor_id         uuid,
  actor_partner_id bigint,
  actor_label      text not null default '',
  source           text not null default 'app',
  attachments      jsonb not null default '[]'::jsonb,
  -- A critical outbound. Unread past the config window, this becomes a call
  -- task for the thread's owner.
  critical_key     text,
  wa_message_id    text,
  wa_phone10       text,
  created_at       timestamptz not null default now(),
  constraint order_thread_message_actor_ck
    check (actor_role in ('customer','partner','admin','system')),
  constraint order_thread_message_source_ck
    check (source in ('app','whatsapp','ticket','system','engine'))
);
create index if not exists order_thread_message_thread_ix
  on public.order_thread_message (thread_id, created_at);
create index if not exists order_thread_message_ticket_ix
  on public.order_thread_message (ticket_id, created_at) where ticket_id is not null;
create index if not exists order_thread_message_critical_ix
  on public.order_thread_message (critical_key, created_at desc) where critical_key is not null;
create unique index if not exists order_thread_message_wa_uq
  on public.order_thread_message (wa_message_id) where wa_message_id is not null;

-- ── read tracking, per recipient ────────────────────────────────────────────
-- viewer_kind is the SIDE that read it, viewer_id the login that did. A
-- critical outbound is "unread" while no row of the customer's side exists.
create table if not exists public.order_thread_read (
  message_id  uuid not null references public.order_thread_message(id) on delete cascade,
  viewer_kind text not null,
  viewer_id   uuid not null default '00000000-0000-0000-0000-000000000000'::uuid,
  read_at     timestamptz not null default now(),
  primary key (message_id, viewer_kind, viewer_id),
  constraint order_thread_read_kind_ck check (viewer_kind in ('customer','partner','admin'))
);
create index if not exists order_thread_read_msg_ix
  on public.order_thread_read (message_id, viewer_kind);

-- ── the SLA, as config ──────────────────────────────────────────────────────
-- Per topic, with '' as the default row. Business hours are IST, because the
-- promise "30 minutes" is a promise about a working day, not about 03:00.
create table if not exists public.thread_sla_config (
  tag                   text primary key,
  sla_minutes           integer not null default 30,
  business_start_ist    time    not null default '09:00',
  business_end_ist      time    not null default '21:00',
  unread_critical_hours numeric not null default 4,
  callback_sla_minutes  integer not null default 15,
  escalate_wa_nudge     boolean not null default true,
  enabled               boolean not null default true,
  updated_at            timestamptz not null default now()
);

insert into public.thread_sla_config (tag, sla_minutes) values ('', 30)
  on conflict (tag) do nothing;
-- One row per tag. A tag with no row of its own falls back to '' — so a NEW
-- tag is never unpoliced.
insert into public.thread_sla_config (tag, sla_minutes) values
  ('delivery', 20), ('billing', 45), ('quality', 30), ('other', 30)
on conflict (tag) do nothing;

-- ── call tasks ──────────────────────────────────────────────────────────────
create table if not exists public.thread_call_task (
  id           bigserial primary key,
  thread_id    uuid not null references public.order_thread(id) on delete cascade,
  order_id     uuid,
  customer_id  uuid,
  zone_id      smallint,
  partner_id   bigint,
  kind         text not null,
  reason_key   text not null default '',
  message_id   uuid references public.order_thread_message(id) on delete set null,
  due_at       timestamptz not null,
  status       text not null default 'open',
  outcome_code text,
  note         text,
  logged_by    uuid,
  logged_at    timestamptz,
  created_at   timestamptz not null default now(),
  closed_at    timestamptz,
  constraint thread_call_task_kind_ck check (kind in ('unread_critical','missed_callback')),
  constraint thread_call_task_status_ck check (status in ('open','done','cancelled'))
);
-- One open task per (kind, thread, reason) — a tick that runs every minute
-- must never stack up twenty identical calls.
create unique index if not exists thread_call_task_open_uq
  on public.thread_call_task (kind, thread_id, reason_key) where status = 'open';
create index if not exists thread_call_task_zone_ix
  on public.thread_call_task (zone_id, status, due_at);

create table if not exists public.thread_call_outcome (
  code   text primary key,
  label  text not null,
  tone   text not null default 'normal',
  sort   integer not null default 100,
  active boolean not null default true
);
insert into public.thread_call_outcome (code, label, tone, sort) values
  ('spoke',        'Spoke to customer',    'success', 10),
  ('no_answer',    'No answer',            'warning', 20),
  ('call_back',    'Asked to call later',  'warning', 30),
  ('wrong_number', 'Wrong number',         'danger',  40),
  ('resolved',     'Sorted on the call',   'success', 50)
on conflict (code) do nothing;

-- ── the ticket points at the thread ─────────────────────────────────────────
alter table public.support_ticket
  add column if not exists thread_id uuid references public.order_thread(id) on delete set null;
create index if not exists support_ticket_thread_ix on public.support_ticket (thread_id);
-- Zone, so a partner's inbox can be scoped without joining orders for a
-- ticket that names no order.
alter table public.support_ticket
  add column if not exists zone_id smallint;
alter table public.support_ticket
  add column if not exists owner_partner_id bigint references public.region_partners(id);

-- ── the four topic TAGS ─────────────────────────────────────────────────────
-- The eight existing support_topic rows are better customer-facing copy than
-- the spec's four words ("Where is my order?" beats "Delivery"), so the tags
-- are a LAYER over them rather than a replacement: every topic carries one
-- tag, the SLA is per tag, and the inbox filters on the tag. A topic added
-- tomorrow with no tag reads as 'other' and is still policed.
create table if not exists public.thread_topic_tag (
  tag    text primary key,
  label  text not null,
  tone   text not null default 'info',
  sort   integer not null default 100,
  active boolean not null default true
);
insert into public.thread_topic_tag (tag, label, tone, sort) values
  ('billing',  'Billing',  'warning', 10),
  ('delivery', 'Delivery', 'info',    20),
  ('quality',  'Quality',  'danger',  30),
  ('other',    'Other',    'info',    40)
on conflict (tag) do update set label = excluded.label,
                                tone  = excluded.tone,
                                sort  = excluded.sort,
                                active = true;

alter table public.support_topic
  add column if not exists tag text references public.thread_topic_tag(tag);

update public.support_topic set tag = v.tag
  from (values
    ('order_status','delivery'),
    ('wrong_item','quality'),
    ('damaged','quality'),
    ('billing','billing'),
    ('cancel_help','delivery'),
    ('account','other'),
    ('feedback','quality'),
    ('other','other')
  ) as v(code, tag)
 where public.support_topic.code = v.code
   and public.support_topic.tag is distinct from v.tag;

-- The thread's own tag, so the inbox and the SLA never have to walk back
-- through a ticket that may since have closed.
alter table public.order_thread
  add column if not exists tag text references public.thread_topic_tag(tag);

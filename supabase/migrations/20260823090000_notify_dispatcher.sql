-- CHANGE — PART 1 of 3 of the notification rebuild (dev command #297).
--
-- ONE entry point for every outbound message: public.notify(event_key,
-- recipient, vars). WhatsApp stays the only channel; push and email are
-- carried as COLUMNS ONLY so parts 2 and 3 have somewhere to land, and both
-- default to false so nothing reads them yet.
--
-- What this migration fixes, concretely: order_placed (and every sibling)
-- used to send FREE-FORM text first whenever the 24h service window looked
-- open, and only fell back to the approved template when it did not. That is
-- backwards — a free-form send outside the window is refused by Meta with
-- "Re-engagement message", and a free-form send inside it bypasses the
-- approved template for no gain. notify() reverses the order: an enabled
-- route with an APPROVED template always wins, and free-form survives only as
-- the fallback for a route that has no template yet AND an open window.
--
-- Every string an admin reads is in the backend (ui_copy / this file's own
-- payloads). Nothing here is formatted in Dart.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. wa_event_routes — the columns parts 2 and 3 will use. UNUSED for now.
--    They share the route's existing variable_map, so a token added for
--    WhatsApp is automatically available to push and email later.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.wa_event_routes
  add column if not exists push_enabled  boolean not null default false,
  add column if not exists email_enabled boolean not null default false,
  add column if not exists push_title    text,
  add column if not exists push_body     text,
  add column if not exists email_subject text,
  add column if not exists email_body    text;

comment on column public.wa_event_routes.push_enabled is
  'PART 2 placeholder. Nothing reads this yet — notify() ignores it.';
comment on column public.wa_event_routes.email_enabled is
  'PART 3 placeholder. Nothing reads this yet — notify() ignores it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. notification_log — one row per event PER CHANNEL. This is the ledger the
--    later parts share; wa_send_attempts stays as the WhatsApp-only ledger the
--    existing admin screens read, so nothing that works today stops working.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.notification_log (
  id                  bigserial primary key,
  event_key           text        not null,
  recipient           text        not null,
  channel             text        not null default 'whatsapp',
  status              text        not null,          -- sent | failed | skipped | queued
  provider_message_id text,
  failure_reason      text,
  cost                numeric(12,4),
  order_id            uuid,
  customer_id         uuid,
  path                text,                          -- template | freeform | legacy | none
  vars                jsonb       not null default '{}'::jsonb,
  detail              jsonb,
  created_at          timestamptz not null default now()
);

create index if not exists notification_log_event_idx
  on public.notification_log (event_key, created_at desc);
create index if not exists notification_log_status_idx
  on public.notification_log (status, created_at desc);
create index if not exists notification_log_recipient_idx
  on public.notification_log (recipient, created_at desc);

alter table public.notification_log enable row level security;
drop policy if exists notification_log_admin_read on public.notification_log;
create policy notification_log_admin_read on public.notification_log
  for select using (public.get_my_role() in ('admin','super_admin'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Retry queue. A failed send is NEVER silently lost: it lands here with an
--    exponential next_attempt_at and is drained by notify_retry_tick().
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.notification_retry_queue (
  id              bigserial primary key,
  event_key       text        not null,
  recipient       text        not null,
  channel         text        not null default 'whatsapp',
  vars            jsonb       not null default '{}'::jsonb,
  order_id        uuid,
  customer_id     uuid,
  attempts        integer     not null default 0,
  max_attempts    integer     not null default 5,
  next_attempt_at timestamptz not null default now(),
  force_template  boolean     not null default false,
  last_reason     text,
  status          text        not null default 'pending',   -- pending | done | dead
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists notification_retry_due_idx
  on public.notification_retry_queue (status, next_attempt_at);
create unique index if not exists notification_retry_open_uidx
  on public.notification_retry_queue (event_key, recipient, coalesce(order_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'pending';

alter table public.notification_retry_queue enable row level security;
drop policy if exists notification_retry_admin_read on public.notification_retry_queue;
create policy notification_retry_admin_read on public.notification_retry_queue
  for select using (public.get_my_role() in ('admin','super_admin'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The 24h WhatsApp service window, TRACKED rather than re-derived. Every
--    inbound message stamps window_until; notify() reads one indexed row
--    instead of scanning whatsapp_messages, so it knows IN ADVANCE whether
--    free-form is legal.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.wa_service_window (
  phone10         text primary key,
  last_inbound_at timestamptz not null,
  window_until    timestamptz not null,
  closed_reason   text,
  updated_at      timestamptz not null default now()
);

alter table public.wa_service_window enable row level security;
drop policy if exists wa_service_window_admin_read on public.wa_service_window;
create policy wa_service_window_admin_read on public.wa_service_window
  for select using (public.get_my_role() in ('admin','super_admin'));

create or replace function public._wa_window_touch(p_phone text, p_at timestamptz)
returns void language sql security definer set search_path to 'public' as $$
  insert into public.wa_service_window(phone10, last_inbound_at, window_until, closed_reason, updated_at)
  select right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10),
         coalesce(p_at, now()), coalesce(p_at, now()) + interval '24 hours', null, now()
  where length(right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)) = 10
  on conflict (phone10) do update
     set last_inbound_at = greatest(public.wa_service_window.last_inbound_at, excluded.last_inbound_at),
         window_until    = greatest(public.wa_service_window.window_until,    excluded.window_until),
         closed_reason   = null,
         updated_at      = now();
$$;

create or replace function public._trg_wa_window_inbound()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if NEW.direction = 'in' then
    perform public._wa_window_touch(NEW.sender_phone,
                                    coalesce(NEW.received_at, NEW.created_at, now()));
  end if;
  return null;
end $$;

drop trigger if exists wa_window_inbound_trg on public.whatsapp_messages;
create trigger wa_window_inbound_trg
  after insert on public.whatsapp_messages
  for each row execute function public._trg_wa_window_inbound();

-- Backfill from the messages already on record, so the table is authoritative
-- from the first second. Idempotent: the upsert keeps the later timestamp.
insert into public.wa_service_window(phone10, last_inbound_at, window_until)
select right(regexp_replace(m.sender_phone,'\D','','g'),10) as ph,
       max(coalesce(m.received_at, m.created_at))            as last_in,
       max(coalesce(m.received_at, m.created_at)) + interval '24 hours'
  from public.whatsapp_messages m
 where m.direction = 'in'
   and length(right(regexp_replace(coalesce(m.sender_phone,''),'\D','','g'),10)) = 10
   and coalesce(m.received_at, m.created_at) > now() - interval '60 days'
 group by 1
on conflict (phone10) do update
   set last_inbound_at = greatest(public.wa_service_window.last_inbound_at, excluded.last_inbound_at),
       window_until    = greatest(public.wa_service_window.window_until,    excluded.window_until),
       updated_at      = now();

-- wa_window_open() now reads the tracked row and keeps the old scan ONLY as
-- the fallback for a number that has never been seen. Same answer, one index
-- hit instead of a table scan, and callers are unchanged.
create or replace function public.wa_window_open(p_phone text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select w.window_until > now()
       from public.wa_service_window w
      where w.phone10 = right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)),
    exists (
      select 1
        from public.whatsapp_messages m
       where m.direction = 'in'
         and length(right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)) = 10
         and right(regexp_replace(m.sender_phone,'\D','','g'),10)
           = right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10)
         and coalesce(m.received_at, m.created_at) > now() - interval '24 hours'));
$$;

-- The window as a payload: open/closed, until when, and the backend's own
-- sentence for it. notify() and the admin screen both read this one answer.
-- Backend copy helpers. Every admin-facing sentence in the notify layer lives
-- in ui_copy, so rewording is an UPDATE, not a deploy. A missing key returns
-- the seeded default that the very next statement inserts, never a Dart string.
create or replace function public._nc(p_key text, p_default text default '')
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(nullif(btrim(coalesce((select u.value #>> '{}' from public.ui_copy u
                                          where u.key = p_key), '')), ''), p_default);
$$;

create or replace function public._ncf(p_key text, p_vars jsonb, p_default text default '')
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare s text; k text;
begin
  s := public._nc(p_key, p_default);
  if s = '' then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    s := replace(s, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return s;
end $$;

create or replace function public._notify_hhmm(p_iv interval)
returns text language sql immutable as $$
  select case
           when p_iv < interval '1 minute' then '1 min'
           when p_iv < interval '1 hour'
             then (extract(epoch from p_iv)/60)::int::text || ' min'
           else (extract(epoch from p_iv)/3600)::int::text || ' h' end;
$$;

create or replace function public.notify_window(p_phone text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare w record; v_ph text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10);
begin
  if length(v_ph) <> 10 then
    return jsonb_build_object('ok', false, 'open', false, 'reason','no_phone',
      'label', public._nc('notify.window_no_phone','No WhatsApp number on file'));
  end if;
  select * into w from public.wa_service_window where phone10 = v_ph;
  if w.phone10 is null then
    return jsonb_build_object('ok', true, 'open', false, 'reason','never_wrote_in',
      'label', public._nc('notify.window_never','Never written to us — approved template only'));
  end if;
  if w.window_until > now() then
    return jsonb_build_object('ok', true, 'open', true, 'until', w.window_until,
      'label', public._ncf('notify.window_open_for',
                 jsonb_build_object('a', public._notify_hhmm(w.window_until - now())),
                 'Free-form allowed for another {a}'));
  end if;
  return jsonb_build_object('ok', true, 'open', false, 'reason','window_closed',
    'label', public._nc('notify.window_closed','Window closed — approved template only'));
end $$;

commit;

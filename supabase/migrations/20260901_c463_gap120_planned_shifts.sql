-- CHANGE #463 · register row 120 — "Shifts record only what happened, never
-- what was planned".
--
-- REPRODUCED: delivery_partner_shifts stores started_at/ended_at, both stamped
-- by the rider after the fact. There was no roster anywhere, so
-- delivery_suggest_partner could only rank by open load — it had no way to
-- prefer a rider who was actually rostered on, and no way to avoid one who
-- was not working at all.
--
-- THE FIX: a roster table, and one extra ordering key in the suggester.
-- Deliberately ADDITIVE: with no roster rows the EXISTS is false for everyone,
-- the ordering collapses to the old `c.n, p.full_name`, and behaviour is
-- byte-for-byte what it was. A zone that never adopts rostering loses nothing.
--
-- The reason string says which rule won, and it is composed in the BACKEND —
-- admin_delivery_tab.dart prints reason verbatim.

create table if not exists public.delivery_planned_shift (
  id          bigserial primary key,
  partner_id  uuid not null references delivery_partner_registrations(id) on delete cascade,
  shift_date  date not null,
  start_time  time not null,
  end_time    time not null,
  zone_id     smallint,
  note        text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  constraint delivery_planned_shift_window_ck check (end_time > start_time),
  constraint delivery_planned_shift_uq unique (partner_id, shift_date, start_time)
);

create index if not exists delivery_planned_shift_lookup_idx
  on public.delivery_planned_shift (shift_date, partner_id);

alter table public.delivery_planned_shift enable row level security;

drop policy if exists delivery_planned_shift_admin_all on public.delivery_planned_shift;
create policy delivery_planned_shift_admin_all on public.delivery_planned_shift
  for all using (public.get_my_role() in ('admin','super_admin'))
  with check (public.get_my_role() in ('admin','super_admin'));

-- A rider may READ their own roster and nobody else's.
drop policy if exists delivery_planned_shift_own_read on public.delivery_planned_shift;
create policy delivery_planned_shift_own_read on public.delivery_planned_shift
  for select using (exists (
    select 1 from delivery_partner_registrations p
     where p.id = delivery_planned_shift.partner_id and p.user_id = auth.uid()));

comment on table public.delivery_planned_shift is
  'CHANGE #463 gap 120 - the roster: what a rider was PLANNED to work. delivery_partner_shifts stays the record of what actually happened.';

-- delivery_suggest_partner gains `on_shift` (computed in IST, the operating
-- timezone) as the FIRST ordering key; open load and name remain the
-- tie-breaks. See the command's build log for the full replaced body.
--   cross join lateral (select exists (
--     select 1 from delivery_planned_shift ps
--      where ps.partner_id = p.id
--        and ps.shift_date = (now() at time zone 'Asia/Kolkata')::date
--        and (now() at time zone 'Asia/Kolkata')::time between ps.start_time and ps.end_time
--   ) as on_shift) s
--   ...
--   order by s.on_shift desc, c.n, p.full_name
--
-- OUTSTANDING (filed, not hidden): the admin screen for ENTERING a roster.
-- The table and the preference are live and already change assignment on the
-- existing Delivery tab; the roster editor is a follow-up row.

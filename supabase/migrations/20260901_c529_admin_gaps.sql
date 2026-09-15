-- CHANGE #529 — the first 8 APPROVED severity=medium surface=admin
-- feature_gaps rows, by id: 13, 16, 21, 22, 36, 37, 38, 39.
--
-- This file is the historical record of what was applied; every statement is
-- idempotent, so a resumed worker re-applying it is a silent no-op. The live
-- migrations are, in order:
--   c529_gap13_inquiry_zone_and_hidden_scope
--   c529_gap38_39_supplier_locations_and_stale_date_scope
--   c529_gap39_date_scope_base
--   c529_gap16_bag_status_projection
--   c529_gap21_bill_supplier_id_resolution
--   c529_gap22_bill_chaser_precheck_quiet_hours
--   c529_gap22_chase_step_on_bill_pipeline
--   c529_gap36_37_dispute_ageing_reminder_sla
--   c529_gap38_supplier_set_location_v2
--
-- ── GAP 13 — inquiry.zone_id was NULL on 20 of 156 rows while orders,
-- order_items, supplier_orders and payment_claims were 100% zoned, so a
-- zone-scoped admin silently saw a shorter list with no hidden-count note.
-- None of the 20 had a supplier_order_id, so the zone is resolved from the
-- supplier the inquiry is actually with. PROOF: 20 NULL -> 0.
create or replace function public._c529_inquiry_zone(p_supplier text, p_supplier_order uuid)
returns smallint language sql stable set search_path to 'public' as $$
  select coalesce(
    (select so.zone_id from supplier_orders so where so.id = p_supplier_order),
    (select sp.zone_id from supplier_profiles sp
      where btrim(lower(sp.supplier_name)) = btrim(lower(coalesce(p_supplier,'')))
        and sp.zone_id is not null
      order by coalesce(sp.is_deleted,false), sp.created_at limit 1));
$$;

update public.inquiry i
   set zone_id = public._c529_inquiry_zone(i.current_supplier, i.supplier_order_id)
 where i.zone_id is null
   and public._c529_inquiry_zone(i.current_supplier, i.supplier_order_id) is not null;

create or replace function public._c529_inquiry_zone_trg() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if new.zone_id is null then
    new.zone_id := public._c529_inquiry_zone(new.current_supplier, new.supplier_order_id);
  end if;
  return new;
end $$;

drop trigger if exists trg_c529_inquiry_zone on public.inquiry;
create trigger trg_c529_inquiry_zone
  before insert or update of current_supplier, supplier_order_id, zone_id
  on public.inquiry for each row execute function public._c529_inquiry_zone_trg();

-- A zone-scoped list must SAY what it hid, in the backend's own words.
insert into public.ui_copy(key, value) values
  ('scope_hidden_note', to_jsonb('{n} hidden by your zone scope ({zone}).'::text))
on conflict (key) do nothing;

create or replace function public._c529_hidden_note(p_hidden int, p_zone smallint)
returns jsonb language sql stable set search_path to 'public' as $$
  select case when coalesce(p_hidden,0) <= 0
              then jsonb_build_object('hidden_by_scope', 0, 'hidden_note', null)
              else jsonb_build_object(
                'hidden_by_scope', p_hidden,
                'hidden_note', public._cf('scope_hidden_note', jsonb_build_object(
                   'n', p_hidden::text,
                   'zone', coalesce((select name from zones where id = p_zone), ''))))
         end;
$$;
-- inquiry_day() and fw_get_disputes() both now append _c529_hidden_note().

-- ── GAP 16 — bags.status was a column nobody advanced: all 500 rows read
-- 'empty' while 293 order_items carried a bag_no and bag_allocations held 3
-- rows. Status is now a PROJECTION of what is in the bag, and the row carries
-- its own label, tone and count copy. PROOF: 500 empty -> 465 empty /
-- 35 filling holding 293 items.
create or replace function public._c529_bag_state(p_bag_no integer)
returns jsonb language sql stable set search_path to 'public' as $$
  with it as (
    select count(*)::int as n,
           count(*) filter (where oi.fulfillment_state in ('shipped','delivered'))::int as shipped,
           count(*) filter (where oi.fulfillment_state = 'packed')::int as packed
      from order_items oi
     where oi.bag_no = p_bag_no and coalesce(oi.fulfillment_state,'') <> 'cancelled'
  ), al as (
    select count(*)::int as n,
           count(*) filter (where a.packed_at is not null)::int as packed
      from bag_allocations a where a.bag_no = p_bag_no
  )
  select jsonb_build_object('item_count', it.n, 'alloc_count', al.n,
    'status', case
        when it.n = 0 and al.n = 0          then 'empty'
        when it.n > 0 and it.shipped = it.n then 'dispatched'
        when it.packed > 0 or al.packed > 0 then 'full'
        else 'filling' end)
  from it, al;
$$;
-- bags_list() was re-created returning status/status_label/status_bg/status_fg/
-- item_count/alloc_count/count_label alongside bag_no/bag_code/note/updated_at.

-- ── GAP 21 — a bill was tied to its supplier by a lowercased NAME string even
-- though pending_bills.supplier_id exists: supplier_id was NULL on 6 of 18
-- bills and one 89-day-old bill has supplier_name NULL, so it could never be
-- scoped to a zone and a zone-scoped admin never counted it. The supplier is
-- resolved ONCE onto supplier_id (backfill + trigger), zone scoping reads the
-- id with the name join only as a fallback, and the bills that can never be
-- zoned are their own backend-labelled bucket. PROOF: 6 NULL -> 1, and that 1
-- is now counted in admin_unresolved_bills().
create or replace function public._c529_bill_supplier_id(p_supplier_name text)
returns text language sql stable set search_path to 'public' as $$
  select sp.id::text from supplier_profiles sp
   where btrim(lower(sp.supplier_name)) = btrim(lower(coalesce(p_supplier_name,'')))
     and coalesce(p_supplier_name,'') <> ''
   order by coalesce(sp.is_deleted,false), sp.created_at limit 1;
$$;

create or replace function public._c529_bill_zone(p_supplier_id text, p_supplier_name text)
returns smallint language sql stable set search_path to 'public' as $$
  select coalesce(
    (select sp.zone_id from supplier_profiles sp
      where p_supplier_id is not null and sp.id::text = p_supplier_id),
    (select sp.zone_id from supplier_profiles sp
      where btrim(lower(sp.supplier_name)) = btrim(lower(coalesce(p_supplier_name,'')))
        and coalesce(p_supplier_name,'') <> '' limit 1));
$$;

update public.pending_bills pb
   set supplier_id = public._c529_bill_supplier_id(pb.supplier_name)
 where pb.supplier_id is null
   and public._c529_bill_supplier_id(pb.supplier_name) is not null;

create or replace function public._c529_bill_supplier_trg() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if new.supplier_id is null then
    new.supplier_id := public._c529_bill_supplier_id(new.supplier_name);
  end if;
  return new;
end $$;

drop trigger if exists trg_c529_bill_supplier on public.pending_bills;
create trigger trg_c529_bill_supplier
  before insert or update of supplier_name, supplier_id on public.pending_bills
  for each row execute function public._c529_bill_supplier_trg();
-- admin_dashboard_counts(), admin_pending_bills_count() and the new
-- admin_unresolved_bills() all scope through _c529_bill_zone().

-- ── GAP 22 — the chaser logged a row every cycle for a switched-off
-- notification: bill_chase_log had grown 2,380 -> 2,800 rows, the newest all
-- {ok:false, reason:notification_off} sent at 04:12 IST, with no backoff and no
-- admin view of the suppression. The route is now checked BEFORE anything is
-- enqueued, IST quiet hours are honoured, and a muted chaser writes ZERO log
-- rows and ONE suppression row the admin can read.
alter table public.bill_auto_config
  add column if not exists chase_quiet_from_ist smallint not null default 9,
  add column if not exists chase_quiet_to_ist   smallint not null default 21;

create table if not exists public.bill_chase_suppression (
  id            smallint primary key default 1,
  suppressed    boolean not null default false,
  reason        text,
  message       text,
  waiting_count int not null default 0,
  checked_at    timestamptz not null default now()
);
insert into public.bill_chase_suppression(id) values (1) on conflict (id) do nothing;
-- bill_chase_gate() answers "may a chase go out right now, and if not why";
-- bill_chase_tick() consults it first; bill_chase_status() and a 'chase' step
-- appended to admin_bill_pipeline().steps render the answer verbatim.

-- ── GAP 36 — fw_send_supplier_short_reminder() existed in the DB with ZERO
-- callers in lib/, test/ or web/. It now stamps supplier_disputes.reminder_count
-- and every ACTIVE dispute carries a backend-labelled `short_reminder` action.
-- ── GAP 37 — the only dispute ever raised went 15 days with no reminder
-- (last_reminder_at NULL), no ageing and no escalation. Every dispute is now
-- aged in the backend and the flat list is sorted by supplier silence.
-- PROOF: that dispute now reads "waiting 38d · overdue" with escalate=true and
-- "Not reminded yet". Escalation is a FLAG, not an auto-fired rebuy inquiry —
-- dispute_sla_config.auto_rebuy defaults FALSE, because a cron that fires
-- supplier inquiries by itself is exactly the failure GAP 22 documents.
alter table public.supplier_disputes
  add column if not exists reminder_count int not null default 0;

create table if not exists public.dispute_sla_config (
  id             smallint primary key default 1,
  sla_hours      int not null default 24,
  escalate_hours int not null default 72,
  enabled        boolean not null default true,
  auto_rebuy     boolean not null default false,
  updated_at     timestamptz not null default now()
);
insert into public.dispute_sla_config(id) values (1) on conflict (id) do nothing;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note,
                             base_interval_s, max_interval_s)
values ('dispute-sla-nudge', 900, 'poll', 'select public.dispute_sla_tick()', true,
        'CHANGE #529 gap 37 — flags a dispute the supplier has been silent on past the SLA.',
        1800, 3600)
on conflict (name) do nothing;

-- ── GAP 38 — 8 of 35 active/approved suppliers had lat or lng NULL (geocode
-- never completed), so a collect run could only reach those shops from memory,
-- and admin_missing_locations() covered customers only. It now carries the
-- supplier bucket with its OWN title/note, and admin_supplier_set_location()
-- drops a pin recording its SOURCE, so an OSM fallback is never mistaken for a
-- Google hit. PROOF: supplier_missing_count = 8 of 35.

-- ── GAP 39 — admin_date_scope pinned test.admin@medibo.in to 2026-08-18 and
-- never moved: every scoped screen was filtered to a day two weeks gone with
-- nothing saying so. A pin set on an EARLIER IST day is no longer a choice the
-- admin is still making, so admin_active_date() rolls it forward; a pin set
-- TODAY is honoured and the state RPC carries a stale_banner with its own copy
-- and a Back-to-today action. PROOF: old rule 2026-08-18, new rule 2026-09-01.
insert into public.ui_copy(key, value) values
  ('date_scope_stale_title',  to_jsonb('You are looking at {label}, not today.'::text)),
  ('date_scope_stale_note',   to_jsonb('Every screen below is filtered to that day.'::text)),
  ('date_scope_stale_action', to_jsonb('Back to today'::text))
on conflict (key) do nothing;

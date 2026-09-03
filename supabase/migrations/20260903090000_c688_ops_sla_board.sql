-- CHANGE #688 — Live ops board: configurable SLA per stage, one screen sorted
-- by breach, amber/red clocks, live refresh.  (feature_gaps #72)
--
-- The evidence on the gap row: nothing in mediBO carried a promise clock.
-- inquiry.asked_at was NULL on every row, no order carried a promised time, and
-- the oldest open order was 41 days old with nothing flagging it. This change
-- gives every OPEN order exactly one clock — the clock of the stage it is
-- sitting in right now — and one screen that puts the worst breach on top.
--
-- Everything here is backend: the stage an order is in, the SLA it is measured
-- against, the elapsed/remaining wording, the tone, the owner and the one next
-- action are all computed and PHRASED in SQL. Flutter prints the payload.
--
-- Idempotent throughout (#233): a resumed worker re-applies this file silently.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE STAGE CATALOGUE
--
-- partner_queue_stage already names eight stages for the partner work queue.
-- This catalogue is deliberately its own table rather than more rows there:
-- the ops board measures TEN stages (it splits collect→arrival→count and adds
-- dispatch + delivered), and adding those to partner_queue_stage would put
-- permanently-empty stage cards on the partner queue, whose staging CTE never
-- assigns them. Labels and next actions are kept in step by hand where they
-- overlap.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.sla_stage (
  stage_key   text primary key,
  label       text    not null,
  sort_order  int     not null default 100,
  owner_role  text    not null default 'partner',   -- partner | supplier | rider
  owner_label text    not null default '',
  next_action text    not null default '',
  is_active   boolean not null default true
);

insert into public.sla_stage (stage_key, label, sort_order, owner_role, owner_label, next_action) values
  ('accept',         'Accept',         10, 'partner',  'Partner',  'Accept and start inquiry'),
  ('inquiry',        'Inquiry answer', 20, 'supplier', 'Supplier', 'Ask the next supplier'),
  ('supplier_order', 'Supplier order', 30, 'partner',  'Partner',  'Raise the supplier order'),
  ('collect',        'Collect',        40, 'partner',  'Partner',  'Collect from the shop'),
  ('arrival',        'Arrival',        50, 'partner',  'Partner',  'Receive at the warehouse'),
  ('count',          'Count',          60, 'partner',  'Partner',  'Count in at the warehouse'),
  ('bag',            'Bag',            70, 'partner',  'Partner',  'Allocate to a bag'),
  ('pack',           'Pack',           80, 'partner',  'Partner',  'Pack the order'),
  ('dispatch',       'Dispatch',       90, 'partner',  'Partner',  'Assign a rider and dispatch'),
  ('delivered',      'Delivered',     100, 'rider',    'Rider',    'Close the delivery with proof')
on conflict (stage_key) do update
   set label       = excluded.label,
       sort_order  = excluded.sort_order,
       owner_role  = excluded.owner_role,
       owner_label = excluded.owner_label,
       next_action = excluded.next_action;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE SLA ITSELF — per zone, per stage, in minutes
--
-- zone_id NULL is the platform default; a row with a zone_id overrides it for
-- that zone only. Zones behave as separate shops, so a slow-road zone can carry
-- a longer collect SLA without touching anybody else.
-- amber_pct is where the clock turns amber (70 = at 70% of the SLA).
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.sla_config (
  id          bigserial primary key,
  zone_id     smallint,
  stage_key   text        not null references public.sla_stage(stage_key) on delete cascade,
  sla_minutes int         not null default 60,
  amber_pct   int         not null default 70,
  is_active   boolean     not null default true,
  updated_at  timestamptz not null default now(),
  updated_by  text
);

do $$ begin
  alter table public.sla_config add constraint sla_config_minutes_ck check (sla_minutes between 1 and 100000);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.sla_config add constraint sla_config_amber_ck check (amber_pct between 1 and 100);
exception when duplicate_object then null; end $$;

create unique index if not exists sla_config_uk
  on public.sla_config (coalesce(zone_id, (-1)::smallint), stage_key);

-- Platform defaults. Real numbers for an IST B2B trade day, not placeholders:
-- an unaccepted order is the most expensive minute on the board, a supplier
-- answer may legitimately take two hours, and a delivery leg is half a day.
insert into public.sla_config (zone_id, stage_key, sla_minutes, amber_pct)
select null, s.stage_key, v.mins, 70
  from public.sla_stage s
  join (values
        ('accept', 30), ('inquiry', 120), ('supplier_order', 60), ('collect', 180),
        ('arrival', 120), ('count', 60), ('bag', 45), ('pack', 45),
        ('dispatch', 60), ('delivered', 240)
       ) as v(k, mins) on v.k = s.stage_key
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. STAGE HISTORY — when this order ENTERED the stage it is in
--
-- One row per (order, stage) holding the CURRENT visit. A re-entry (an order
-- bounced back to Count after a dispute) resets entered_at and bumps
-- visit_count, because the clock that matters is the one running now.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.order_stage_history (
  order_id    uuid        not null references public.orders(id) on delete cascade,
  stage_key   text        not null,
  entered_at  timestamptz not null,
  left_at     timestamptz,
  zone_id     smallint,
  visit_count int         not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (order_id, stage_key)
);
create index if not exists order_stage_history_open_idx
  on public.order_stage_history (stage_key, entered_at) where left_at is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE BREACH LOG — also the throttle
--
-- The unique key is (order, stage, entered_at): one alert per STAGE VISIT, so a
-- red order that stays red for two days is notified once, not every five
-- minutes. A genuine re-entry has a new entered_at and therefore alerts again.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.ops_sla_alert (
  id            bigserial primary key,
  order_id      uuid        not null references public.orders(id) on delete cascade,
  order_code    text        not null default '',
  stage_key     text        not null,
  zone_id       smallint,
  tone          text        not null default 'red',
  entered_at    timestamptz not null,
  over_minutes  int         not null default 0,
  fired_at      timestamptz not null default now(),
  notify_result jsonb       not null default '{}'::jsonb
);
create unique index if not exists ops_sla_alert_uk
  on public.ops_sla_alert (order_id, stage_key, entered_at);
create index if not exists ops_sla_alert_recent_idx
  on public.ops_sla_alert (fired_at desc);

alter table public.sla_stage           enable row level security;
alter table public.sla_config          enable row level security;
alter table public.order_stage_history enable row level security;
alter table public.ops_sla_alert       enable row level security;

do $$ begin
  create policy sla_stage_read on public.sla_stage for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy sla_config_read on public.sla_config for select to authenticated using (true);
exception when duplicate_object then null; end $$;
-- order_stage_history and ops_sla_alert carry no read policy on purpose: they
-- are reached only through the SECURITY DEFINER RPCs below.

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. DURATION WORDING — one place, so "2h 15m over" is never spelled in Dart
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_dur_label(p_seconds numeric)
returns text
language sql
immutable
as $$
  with s as (select greatest(coalesce(p_seconds, 0), 0)::bigint as sec)
  select case
           when sec < 60    then sec || 's'
           when sec < 3600  then (sec / 60) || 'm'
           when sec < 86400 then (sec / 3600) || 'h'
                                 || case when (sec % 3600) / 60 > 0
                                         then ' ' || ((sec % 3600) / 60) || 'm' else '' end
           else (sec / 86400) || 'd'
                || case when (sec % 86400) / 3600 > 0
                        then ' ' || ((sec % 86400) / 3600) || 'h' else '' end
         end
    from s;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE STAGE AN ORDER IS IN, AND SINCE WHEN
--
-- Set-based on purpose (see the latency rules): one aggregate pass over the
-- live order items, one over supplier_orders / bag_allocations / deliveries,
-- and the stage decided by a CASE — never a per-row scalar helper that would
-- re-scan a big table once per order.
--
-- The ladder is partner_work_queue()'s, extended: collect is split into
-- collect → arrival → count (the Supplier Shop / Warehouse split the fulfilment
-- console already has), and dispatch + delivered are added after pack.
--
-- `since` is the best REAL timestamp for entering that stage — a collect clock
-- starts when the item was locked at the shop, not when this function first
-- looked. That is what lets the board be honest about an order that has been
-- sitting for 41 days instead of showing every order green on day one.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._ops_order_stage(p_zone smallint default null)
returns table (
  order_id   uuid,
  order_code text,
  customer   text,
  amount     numeric,
  zone_id    smallint,
  created_at timestamptz,
  stage_key  text,
  since      timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with live as (
    select o.id, o.order_code, o.status, o.created_at, o.total_amount,
           coalesce(o.zone_id, pp.zone_id)::smallint as zid,
           coalesce(nullif(btrim(pp.pharmacy_name), ''), nullif(btrim(pp.customer_name), ''),
                    nullif(btrim(o.pharmacy_name), ''), '') as customer
      from orders o
      left join pharmacy_profiles pp on pp.id = o.customer_id
     where o.status <> 'cancelled'
       and o.closed_at is null
       and (p_zone is null or coalesce(o.zone_id, pp.zone_id) = p_zone)
  ), item as (
    select oi.order_id,
           count(*) as n_live,
           count(*) filter (where oi.assigned_supplier is null) as n_unassigned,
           count(*) filter (where oi.assigned_supplier is not null
                              and not exists (select 1 from supplier_orders so
                                               where so.order_id = oi.order_id
                                                 and btrim(lower(so.supplier_name))
                                                   = btrim(lower(oi.assigned_supplier)))) as n_no_po,
           count(*) filter (where oi.assigned_supplier is not null
                              and coalesce(oi.collect_locked, false) = false) as n_uncollected,
           count(*) filter (where coalesce(oi.collect_locked, false)
                              and oi.arrived_at is null) as n_unarrived,
           count(*) filter (where coalesce(oi.collect_locked, false)
                              and oi.wh_recount_qty is null) as n_uncounted,
           count(*) filter (where oi.wh_recount_qty is not null
                              and not exists (select 1 from bag_allocations ba
                                               where ba.order_item_id = oi.id)) as n_unbagged,
           count(*) filter (where coalesce(oi.packed, false) = false) as n_unpacked,
           max(oi.ps_filled_at)      as t_assigned,
           max(oi.collect_locked_at) as t_collected,
           max(oi.arrived_at)        as t_arrived,
           max(oi.packed_at)         as t_packed,
           max(i.asked_at)           as t_asked
      from order_items oi
      join live l on l.id = oi.order_id
      left join inquiry i on i.id = oi.inquiry_id
     where coalesce(oi.status, '') <> 'cancelled'
       and coalesce(oi.unfulfillable, false) = false
     group by oi.order_id
  ), po as (
    select so.order_id, max(so.created_at) as t_po
      from supplier_orders so join live l on l.id = so.order_id
     group by so.order_id
  ), bag as (
    select ba.order_id, max(ba.created_at) as t_bag
      from bag_allocations ba join live l on l.id = ba.order_id
     group by ba.order_id
  ), dlv as (
    select d.order_id,
           max(coalesce(d.assigned_at, d.created_at)) as t_assigned_rider,
           count(*) filter (where coalesce(lower(d.status), '') in ('delivered', 'completed')) as n_done
      from deliveries d join live l on l.id = d.order_id
     group by d.order_id
  )
  select l.id, coalesce(l.order_code, ''), l.customer,
         coalesce(l.total_amount, 0), l.zid, l.created_at,
         st.k,
         case st.k
           when 'accept'         then l.created_at
           when 'inquiry'        then coalesce(i.t_asked, l.created_at)
           when 'supplier_order' then coalesce(i.t_assigned, i.t_asked, l.created_at)
           when 'collect'        then coalesce(p.t_po, i.t_assigned, l.created_at)
           when 'arrival'        then coalesce(i.t_collected, p.t_po, l.created_at)
           when 'count'          then coalesce(i.t_arrived, i.t_collected, l.created_at)
           when 'bag'            then coalesce(i.t_arrived, i.t_collected, l.created_at)
           when 'pack'           then coalesce(b.t_bag, i.t_arrived, l.created_at)
           when 'dispatch'       then coalesce(i.t_packed, b.t_bag, l.created_at)
           when 'delivered'      then coalesce(d.t_assigned_rider, i.t_packed, l.created_at)
         end
    from live l
    left join item i on i.order_id = l.id
    left join po   p on p.order_id = l.id
    left join bag  b on b.order_id = l.id
    left join dlv  d on d.order_id = l.id
    cross join lateral (
      select case
               when l.status = 'pending'                       then 'accept'
               when coalesce(i.n_live, 0) = 0                  then null
               when i.n_unassigned  > 0                        then 'inquiry'
               when i.n_no_po       > 0                        then 'supplier_order'
               when i.n_uncollected > 0                        then 'collect'
               when i.n_unarrived   > 0                        then 'arrival'
               when i.n_uncounted   > 0                        then 'count'
               when i.n_unbagged    > 0                        then 'bag'
               when i.n_unpacked    > 0                        then 'pack'
               when d.order_id is null                         then 'dispatch'
               when coalesce(d.n_done, 0) = 0                  then 'delivered'
               else null
             end as k) st
   where st.k is not null;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. STAMPING — write the stage entry timestamps onto the order
--
-- Called by the tick (and by ops_board itself, so opening the screen is never
-- looking at a history that has not been written yet). Idempotent: an order
-- already recorded in its current stage is a no-op; a MOVED order closes the
-- stage it left and opens the one it entered; a genuine re-entry resets the
-- clock and bumps visit_count.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_stage_stamp(p_zone smallint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_opened int := 0; v_closed int := 0; v_seen int := 0;
begin
  with cur as (
    select s.order_id, s.stage_key, s.since, s.zone_id
      from public._ops_order_stage(p_zone) s
  ), closed as (
    -- every stage this order is NOT in any more
    update order_stage_history h
       set left_at = now(), updated_at = now()
      from cur n
     where h.order_id = n.order_id
       and h.left_at is null
       and h.stage_key <> n.stage_key
    returning 1
  ), opened as (
    -- the stage it IS in (disjoint from `closed`: different stage_key)
    insert into order_stage_history (order_id, stage_key, entered_at, zone_id)
    select n.order_id, n.stage_key, coalesce(n.since, now()), n.zone_id from cur n
    on conflict (order_id, stage_key) do update
       set left_at     = null,
           zone_id     = excluded.zone_id,
           updated_at  = now(),
           visit_count = case when order_stage_history.left_at is not null
                              then order_stage_history.visit_count + 1
                              else order_stage_history.visit_count end,
           entered_at  = case when order_stage_history.left_at is not null
                              then greatest(excluded.entered_at, order_stage_history.left_at)
                              else order_stage_history.entered_at end
    returning 1
  )
  select (select count(*) from cur), (select count(*) from opened), (select count(*) from closed)
    into v_seen, v_opened, v_closed;

  return jsonb_build_object('ok', true, 'orders', v_seen,
                            'opened', v_opened, 'closed', v_closed);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE BOARD
--
-- One row per OPEN order: the stage it is in, when it entered, how much of its
-- SLA is left (or how far past), the tone, who owns it and the one next action.
-- Sorted by breach — red first, worst overdue on top — because the whole point
-- of the screen is that the top row is the thing to do next.
--
-- A pure READ: it never writes history. Where an order has no history row yet
-- (a brand-new stage the tick has not stamped) it falls back to the derived
-- timestamp, so the board is never blank waiting for a cron.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_board(p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role    text     := coalesce(public.get_my_role(), 'none');
  v_partner bigint   := public.my_partner_id();
  v_access  text     := 'none';
  v_zone    smallint;
  v_rows    jsonb    := '[]'::jsonb;
  v_red int := 0; v_amber int := 0; v_green int := 0; v_total int := 0;
begin
  if v_partner is not null then
    v_access := coalesce(public.partner_access('partner.ops_board', v_partner), 'none');
  elsif v_role in ('admin', 'super_admin') then
    v_access := coalesce(public.admin_access('fulfill.ops_board'), 'none');
  end if;

  if v_access = 'none' then
    return jsonb_build_object(
      'ok', false, 'error', 'not_authorized',
      'title',   public.uic('ops_board.title', 'Ops board'),
      'message', public.uic('ops_board.not_authorized', ''),
      'rows', '[]'::jsonb, 'has_any', false);
  end if;

  -- A partner sees ITS zone and only its zone; zones are separate shops.
  v_zone := case when v_partner is not null then public.partner_zone_id()
                 else coalesce(p_zone, public.admin_active_zone()) end;

  with cur as (
    select s.* from public._ops_order_stage(v_zone) s
  ), joined as (
    select c.order_id, c.order_code, c.customer, c.amount, c.zone_id, c.created_at,
           c.stage_key,
           st.label       as stage_label,
           st.sort_order  as stage_sort,
           st.owner_role, st.owner_label, st.next_action,
           coalesce(h.entered_at, c.since, c.created_at) as entered_at,
           cfg.sla_minutes, cfg.amber_pct
      from cur c
      join sla_stage st on st.stage_key = c.stage_key and st.is_active
      left join order_stage_history h
             on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
      left join lateral (
        select f.sla_minutes, f.amber_pct
          from sla_config f
         where f.stage_key = c.stage_key and f.is_active
           and (f.zone_id = c.zone_id or f.zone_id is null)
         order by (f.zone_id is null)      -- a zone row beats the platform default
         limit 1) cfg on true
  ), clocked as (
    select j.*,
           (j.sla_minutes * 60)::numeric                                  as sla_sec,
           extract(epoch from (now() - j.entered_at))::numeric            as elapsed_sec,
           (j.sla_minutes * 60)::numeric
             - extract(epoch from (now() - j.entered_at))::numeric        as left_sec
      from joined j
     where j.sla_minutes is not null
  ), toned as (
    select k.*,
           case when k.left_sec <= 0 then 'red'
                when k.elapsed_sec >= k.sla_sec * k.amber_pct / 100.0 then 'amber'
                else 'green' end as tone
      from clocked k
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'order_id',       t.order_id::text,
      'order_code',     t.order_code,
      'customer',       t.customer,
      'amount_display', public.inr_money(t.amount),
      'stage_key',      t.stage_key,
      'stage_label',    t.stage_label,
      'owner_role',     t.owner_role,
      'owner_label',    t.owner_label,
      'next_action',    t.next_action,
      'entered_label',  public.ist_fmt(t.entered_at, 'relative'),
      'entered_at',     t.entered_at,
      'age_label',      public.ops_age_label(t.entered_at),
      'sla_label',      replace(public.uic('ops_board.sla_label', 'SLA {d}'),
                                '{d}', public.ops_dur_label(t.sla_sec)),
      'clock_label',    case when t.left_sec <= 0
                             then replace(public.uic('ops_board.over_label', '{d} over'),
                                          '{d}', public.ops_dur_label(-t.left_sec))
                             else replace(public.uic('ops_board.left_label', '{d} left'),
                                          '{d}', public.ops_dur_label(t.left_sec)) end,
      'overdue',        (t.left_sec <= 0),
      'seconds_left',   round(t.left_sec)::bigint,
      'tone',           t.tone,
      'tone_label',     case t.tone
                          when 'red'   then public.uic('ops_board.tone_red',   'Breached')
                          when 'amber' then public.uic('ops_board.tone_amber', 'Due soon')
                          else              public.uic('ops_board.tone_green', 'On time') end
      )
      -- SORTED BY BREACH: red, then amber, then green; inside a tone the most
      -- overdue (smallest seconds left) is on top.
      order by case t.tone when 'red' then 0 when 'amber' then 1 else 2 end,
               t.left_sec asc, t.entered_at asc), '[]'::jsonb),
    count(*) filter (where t.tone = 'red')::int,
    count(*) filter (where t.tone = 'amber')::int,
    count(*) filter (where t.tone = 'green')::int,
    count(*)::int
    into v_rows, v_red, v_amber, v_green, v_total
    from toned t;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'is_partner', (v_partner is not null),
    'access', v_access,
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from zones z where z.id = v_zone),
                           public.uic('ops_board.all_zones', 'All zones')),
    'title',    public.uic('ops_board.title', 'Ops board'),
    'subtitle', public.uic('ops_board.subtitle', ''),
    'rows', v_rows,
    'has_any', v_total > 0,
    'total', v_total,
    'counts', jsonb_build_object('red', v_red, 'amber', v_amber, 'green', v_green),
    'chips', jsonb_build_array(
      jsonb_build_object('tone', 'red',   'count', v_red,
        'label', replace(public.uic('ops_board.chip_red',   'Breached {n}'), '{n}', v_red::text)),
      jsonb_build_object('tone', 'amber', 'count', v_amber,
        'label', replace(public.uic('ops_board.chip_amber', 'Due soon {n}'), '{n}', v_amber::text)),
      jsonb_build_object('tone', 'green', 'count', v_green,
        'label', replace(public.uic('ops_board.chip_green', 'On time {n}'), '{n}', v_green::text))),
    'refresh_ms', greatest(coalesce(nullif(public.uic('ops_board.refresh_ms', ''), '')::int, 30000), 5000),
    'updated_label', replace(public.uic('ops_board.updated_label', 'Updated {t}'),
                             '{t}', public.ist_fmt(now(), 'time12')),
    'can_edit_sla', (v_role = 'super_admin'),
    'sla_button', public.uic('ops_board.sla_button', 'SLA settings'),
    'empty_title',   public.uic('ops_board.empty_title', 'Nothing open'),
    'empty_message', public.uic('ops_board.empty_message', ''));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. ONE ORDER'S CLOCKS — the row tap target
--
-- The stage timeline for a single order: every stage it has been through with
-- the time it spent there, and the live clock on the stage it is in now. This
-- is the ops "order detail": what happened, how long each step took, and the
-- one thing to do next.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_order_detail(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role    text   := coalesce(public.get_my_role(), 'none');
  v_partner bigint := public.my_partner_id();
  v_access  text   := 'none';
  v_o       record;
  v_cur     record;
  v_steps   jsonb  := '[]'::jsonb;
begin
  if v_partner is not null then
    v_access := coalesce(public.partner_access('partner.ops_board', v_partner), 'none');
  elsif v_role in ('admin', 'super_admin') then
    v_access := coalesce(public.admin_access('fulfill.ops_board'), 'none');
  end if;
  if v_access = 'none' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''));
  end if;

  select o.id, coalesce(o.order_code, '') as order_code, o.total_amount, o.created_at,
         coalesce(o.zone_id, pp.zone_id)::smallint as zone_id,
         coalesce(nullif(btrim(pp.pharmacy_name), ''), nullif(btrim(o.pharmacy_name), ''), '') as customer,
         o.status
    into v_o
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
   where o.id = p_order_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found',
      'title', public.uic('ops_board.detail_not_found_title', 'Order not found'),
      'message', public.uic('ops_board.detail_not_found_message', ''));
  end if;

  if v_partner is not null and v_o.zone_id is distinct from public.partner_zone_id() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''));
  end if;

  select * into v_cur from public._ops_order_stage(null) s where s.order_id = p_order_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key',   st.stage_key,
           'label',       st.label,
           'owner_label', st.owner_label,
           'next_action', st.next_action,
           'is_current',  (h.left_at is null and h.entered_at is not null),
           'reached',     (h.entered_at is not null),
           'entered_label', case when h.entered_at is null then ''
                                 else public.ist_fmt(h.entered_at, 'datetime') end,
           'spent_label', case
              when h.entered_at is null then ''
              when h.left_at is not null then public.ops_dur_label(extract(epoch from (h.left_at - h.entered_at)))
              else public.ops_dur_label(extract(epoch from (now() - h.entered_at))) end,
           'sla_label',   case when cfg.sla_minutes is null then ''
                              else replace(public.uic('ops_board.sla_label', 'SLA {d}'), '{d}',
                                           public.ops_dur_label(cfg.sla_minutes * 60)) end,
           'tone', case
              when h.entered_at is null then 'neutral'
              when cfg.sla_minutes is null then 'neutral'
              when coalesce(h.left_at, now()) - h.entered_at
                   >= make_interval(mins => cfg.sla_minutes) then 'red'
              when coalesce(h.left_at, now()) - h.entered_at
                   >= make_interval(secs => cfg.sla_minutes * 60 * cfg.amber_pct / 100.0) then 'amber'
              else 'green' end)
           order by st.sort_order), '[]'::jsonb)
    into v_steps
    from sla_stage st
    left join order_stage_history h on h.order_id = p_order_id and h.stage_key = st.stage_key
    left join lateral (
      select f.sla_minutes, f.amber_pct from sla_config f
       where f.stage_key = st.stage_key and f.is_active
         and (f.zone_id = v_o.zone_id or f.zone_id is null)
       order by (f.zone_id is null) limit 1) cfg on true
   where st.is_active;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_o.id::text,
    'order_code', v_o.order_code,
    'customer', v_o.customer,
    'amount_display', public.inr_money(coalesce(v_o.total_amount, 0)),
    'zone_label', coalesce((select z.name from zones z where z.id = v_o.zone_id), ''),
    'placed_label', replace(public.uic('ops_board.placed_label', 'Placed {t}'), '{t}',
                            public.ist_fmt(v_o.created_at, 'datetime')),
    'status_label', coalesce((select l.label from order_status_label l where l.status = v_o.status), v_o.status),
    'current_stage', coalesce(v_cur.stage_key, ''),
    'next_action', coalesce((select st.next_action from sla_stage st where st.stage_key = v_cur.stage_key), ''),
    'timeline_title', public.uic('ops_board.timeline_title', 'Stage timeline'),
    'steps', v_steps);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. SLA SETTINGS — super admin only, and it takes effect WITHOUT a deploy
--
-- ops_board reads sla_config on every call, so saving here changes the clocks,
-- the tones and the sort on the very next refresh. Nothing about an SLA lives
-- in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_sla_config_get(p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role text := coalesce(public.get_my_role(), 'none');
  v_rows jsonb;
begin
  if v_role not in ('admin', 'super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''), 'rows', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key',   st.stage_key,
           'label',       st.label,
           'owner_label', st.owner_label,
           'sla_minutes', coalesce(cfg.sla_minutes, 0),
           'amber_pct',   coalesce(cfg.amber_pct, 70),
           'sla_label',   case when cfg.sla_minutes is null then ''
                               else public.ops_dur_label(cfg.sla_minutes * 60) end,
           'is_override', (cfg.zone_id is not null),
           'source_label', case when cfg.zone_id is not null
                                then public.uic('ops_board.sla_source_zone', 'Zone override')
                                else public.uic('ops_board.sla_source_default', 'Platform default') end)
           order by st.sort_order), '[]'::jsonb)
    into v_rows
    from sla_stage st
    left join lateral (
      select f.zone_id, f.sla_minutes, f.amber_pct from sla_config f
       where f.stage_key = st.stage_key and f.is_active
         and (f.zone_id = p_zone or f.zone_id is null)
       order by (f.zone_id is null) limit 1) cfg on true
   where st.is_active;

  return jsonb_build_object(
    'ok', true,
    'can_edit', (v_role = 'super_admin'),
    'zone_id', p_zone,
    'zone_label', coalesce((select z.name from zones z where z.id = p_zone),
                           public.uic('ops_board.all_zones', 'All zones')),
    'title',    public.uic('ops_board.sla_title', 'SLA per stage'),
    'subtitle', public.uic('ops_board.sla_subtitle', ''),
    'minutes_label', public.uic('ops_board.sla_minutes_label', 'Minutes'),
    'save_label',    public.uic('ops_board.sla_save', 'Save'),
    'saved_message', public.uic('ops_board.sla_saved', 'SLA saved'),
    'readonly_message', public.uic('ops_board.sla_readonly', ''),
    'rows', v_rows);
end $$;

create or replace function public.ops_sla_config_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_zone smallint := nullif(p->>'zone_id', '')::smallint;
  v_who  text     := coalesce((select lower(btrim(u.email)) from auth.users u where u.id = auth.uid()), public._actor());
  v_n    int      := 0;
  r      jsonb;
begin
  if coalesce(public.get_my_role(), 'none') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.sla_readonly', ''));
  end if;

  for r in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
    if coalesce(r->>'stage_key', '') = '' then continue; end if;
    if not exists (select 1 from sla_stage s where s.stage_key = r->>'stage_key') then continue; end if;

    insert into sla_config (zone_id, stage_key, sla_minutes, amber_pct, updated_at, updated_by)
    values (v_zone, r->>'stage_key',
            greatest(least(coalesce((r->>'sla_minutes')::int, 60), 100000), 1),
            greatest(least(coalesce((r->>'amber_pct')::int, 70), 100), 1),
            now(), v_who)
    on conflict (coalesce(zone_id, (-1)::smallint), stage_key) do update
       set sla_minutes = excluded.sla_minutes,
           amber_pct   = excluded.amber_pct,
           is_active   = true,
           updated_at  = now(),
           updated_by  = excluded.updated_by;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'saved', v_n,
    'message', public.uic('ops_board.sla_saved', 'SLA saved'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. BREACH ALERTS — the amber→red flip
--
-- The tick stamps history first (so a clock exists), then finds every order
-- whose stage clock has just crossed its SLA and has not been alerted for THIS
-- stage visit. Each one posts to the ops inbox and WhatsApps the zone partner
-- through notify_partner() — the #398 partner audience, reused rather than
-- rebuilt. Throttled three ways: once per stage visit (the unique index), a
-- per-tick cap, and notify()'s own dedupe window on the route.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_sla_tick(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_stamp jsonb;
  v_lim   int := greatest(least(coalesce(p_limit, 20), 100), 1);
  -- An alert is the FLIP, not the standing state. Only a crossing inside this
  -- window notifies, so installing the clock on a 41-day backlog does not
  -- WhatsApp a partner thirty-two times in one tick; those orders still show
  -- red on the board, which is what the board is for.
  v_win   int := greatest(coalesce(nullif(public.uic('ops_board.alert_window_min', ''), '')::int, 180), 5);
  r       record;
  v_fired int := 0; v_sent int := 0;
  v_res   jsonb;
begin
  v_stamp := public.ops_stage_stamp(null);

  for r in
    select c.order_id, c.order_code, c.customer, c.zone_id, c.stage_key,
           st.label as stage_label, st.next_action,
           coalesce(h.entered_at, c.since, c.created_at) as entered_at,
           cfg.sla_minutes,
           extract(epoch from (now() - coalesce(h.entered_at, c.since, c.created_at)))
             / 60.0 - cfg.sla_minutes as over_min
      from public._ops_order_stage(null) c
      join sla_stage st on st.stage_key = c.stage_key and st.is_active
      left join order_stage_history h
             on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
      join lateral (
        select f.sla_minutes from sla_config f
         where f.stage_key = c.stage_key and f.is_active
           and (f.zone_id = c.zone_id or f.zone_id is null)
         order by (f.zone_id is null) limit 1) cfg on true
     where now() - coalesce(h.entered_at, c.since, c.created_at)
             >= make_interval(mins => cfg.sla_minutes)
       and now() - coalesce(h.entered_at, c.since, c.created_at)
             <= make_interval(mins => cfg.sla_minutes + v_win)
       and not exists (
             select 1 from ops_sla_alert a
              where a.order_id = c.order_id
                and a.stage_key = c.stage_key
                and a.entered_at = coalesce(h.entered_at, c.since, c.created_at))
     order by (extract(epoch from (now() - coalesce(h.entered_at, c.since, c.created_at)))
                 / 60.0 - cfg.sla_minutes) desc
     limit v_lim
  loop
    begin
      v_res := public.notify_partner('partner_sla_breach', jsonb_build_object(
                 'order_id',    r.order_id::text,
                 'order_code',  r.order_code,
                 'customer',    r.customer,
                 'zone_id',     coalesce(r.zone_id, 0)::text,
                 'stage',       r.stage_label,
                 'next_action', r.next_action,
                 'overdue',     public.ops_dur_label(greatest(r.over_min, 0) * 60)));
    exception when others then
      v_res := jsonb_build_object('ok', false, 'reason', 'notify_failed');
    end;

    insert into ops_sla_alert (order_id, order_code, stage_key, zone_id, tone,
                               entered_at, over_minutes, notify_result)
    values (r.order_id, r.order_code, r.stage_key, r.zone_id, 'red',
            r.entered_at, greatest(round(r.over_min)::int, 0), coalesce(v_res, '{}'::jsonb))
    on conflict (order_id, stage_key, entered_at) do nothing;

    v_fired := v_fired + 1;
    if coalesce((v_res->>'ok')::boolean, false) then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'stamped', v_stamp,
                            'breaches', v_fired, 'notified', v_sent);
end $$;

-- The WhatsApp / push route for the breach. audience='partner' puts it on the
-- SAME resolver the other five partner events use (#398).
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, push_enabled,
   push_title, push_body, deep_link_kind, wa_category, auto_manage, dedupe_minutes)
values
  ('partner_sla_breach', 'Partner · SLA breached',
   'An open order has passed its stage SLA and needs action now.',
   'partner', true, true,
   'SLA breached',
   '{{order_code}} is stuck at {{stage}} · {{overdue}} over · {{next_action}}',
   '/partner', 'utility', false, 45)
on conflict (event_key) do update
   set label        = excluded.label,
       description  = excluded.description,
       audience     = excluded.audience,
       push_enabled = true,
       push_title   = excluded.push_title,
       push_body    = excluded.push_body;

-- The tick rides the ONE cron dispatcher (never a bare */N schedule).
insert into public.cron_task (name, ord, mode, work_sql, base_interval_s,
                              max_interval_s, step_timeout_ms, dml, enabled, note)
values ('ops-sla-tick', 120, 'poll', 'select public.ops_sla_tick(20)', 300, 900,
        20000, true, true,
        'CHANGE #688 — stamps order stage history and fires amber-to-red SLA breach alerts.')
on conflict (name) do update
   set work_sql        = excluded.work_sql,
       base_interval_s = excluded.base_interval_s,
       dml             = true,
       enabled         = true,
       note            = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. WIRING — the tab, the access matrix, the partner fence, the copy
-- ─────────────────────────────────────────────────────────────────────────────

-- The Fulfill tab, matrix-gated exactly like its nine siblings. Two rows, the
-- shape every fulfilment feature already has: the admin-side feature that the
-- tab is registered under, and its partner twin (which partner_permissions
-- points at by foreign key).
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   deep_link, search_terms, description, partner_feature_key, canonical_key)
values
  ('fulfill.ops_board', 'Ops board', 'Fulfill', 'alert', 'ops_board', 5, 'medibo',
   false, 'read', true, 'orders', 'fulfill_tab', array['admin', 'super_admin'],
   '/admin/go/ops_board',
   'ops board sla clock breach overdue stage promise amber red',
   'Every open order with the clock on the stage it is in, worst breach first',
   'partner.ops_board', 'partner.ops_board'),
  ('partner.ops_board', 'Ops board', 'Fulfilment', 'alert', 'ops_board', 5, 'partner',
   true, 'none', true, 'system', 'dashboard', array['admin', 'super_admin'],
   '', 'ops board sla clock breach overdue stage', 'Ops board for this zone',
   null, null)
on conflict (feature_key) do update
   set label               = excluded.label,
       route_key           = excluded.route_key,
       surface             = excluded.surface,
       sort_order          = excluded.sort_order,
       roles_allowed       = excluded.roles_allowed,
       icon_key            = excluded.icon_key,
       partner_feature_key = excluded.partner_feature_key,
       is_active           = true;

-- Every active partner gets READ on the board. It is a read-only view of work
-- they already own; without the grant the matrix hides the tab from them and
-- the spec's "admin AND partner" half never ships.
insert into public.partner_permissions (partner_id, feature_key, access, updated_by)
select rp.id, 'partner.ops_board', 'read', 'CHANGE #688'
  from public.region_partners rp
 where coalesce(rp.is_active, true)
on conflict (partner_id, feature_key) do nothing;

-- The partner fence is opt-IN (#352): a partner user authorises as an admin
-- only for an RPC named here. The board and its detail are read-only, so they
-- are listed; ops_sla_config_set is NOT — editing an SLA stays super-admin.
insert into public.partner_rpc_allow (proname, source, note)
values ('ops_board',           'c688', 'Ops board — read-only, zone-clamped inside the RPC'),
       ('ops_order_detail',    'c688', 'Ops board row tap — zone-clamped inside the RPC'),
       ('ops_sla_config_get',  'c688', 'Ops board SLA panel, read-only for a partner')
on conflict (proname) do nothing;

-- Copy. Every string the board prints lives here, so wording is an UPDATE.
insert into public.ui_copy (key, value) values
  ('ops_board.title',                to_jsonb('Ops board'::text)),
  ('ops_board.subtitle',             to_jsonb('Every open order, worst breach first'::text)),
  ('ops_board.not_authorized',       to_jsonb('You do not have access to the ops board.'::text)),
  ('ops_board.all_zones',            to_jsonb('All zones'::text)),
  ('ops_board.sla_label',            to_jsonb('SLA {d}'::text)),
  ('ops_board.left_label',           to_jsonb('{d} left'::text)),
  ('ops_board.over_label',           to_jsonb('{d} over'::text)),
  ('ops_board.tone_red',             to_jsonb('Breached'::text)),
  ('ops_board.tone_amber',           to_jsonb('Due soon'::text)),
  ('ops_board.tone_green',           to_jsonb('On time'::text)),
  ('ops_board.chip_red',             to_jsonb('Breached {n}'::text)),
  ('ops_board.chip_amber',           to_jsonb('Due soon {n}'::text)),
  ('ops_board.chip_green',           to_jsonb('On time {n}'::text)),
  ('ops_board.refresh_ms',           to_jsonb('30000'::text)),
  ('ops_board.alert_window_min',     to_jsonb('180'::text)),
  ('ops_board.updated_label',        to_jsonb('Updated {t}'::text)),
  ('ops_board.empty_title',          to_jsonb('Nothing open'::text)),
  ('ops_board.empty_message',        to_jsonb('Every order in this zone is closed or cancelled.'::text)),
  ('ops_board.sla_button',           to_jsonb('SLA settings'::text)),
  ('ops_board.sla_title',            to_jsonb('SLA per stage'::text)),
  ('ops_board.sla_subtitle',         to_jsonb('Minutes allowed in each stage before the clock turns red.'::text)),
  ('ops_board.sla_minutes_label',    to_jsonb('Minutes'::text)),
  ('ops_board.sla_save',             to_jsonb('Save'::text)),
  ('ops_board.sla_saved',            to_jsonb('SLA saved — the board uses it on the next refresh.'::text)),
  ('ops_board.sla_readonly',         to_jsonb('Only a super admin can change an SLA.'::text)),
  ('ops_board.sla_source_zone',      to_jsonb('Zone override'::text)),
  ('ops_board.sla_source_default',   to_jsonb('Platform default'::text)),
  ('ops_board.timeline_title',       to_jsonb('Stage timeline'::text)),
  ('ops_board.placed_label',         to_jsonb('Placed {t}'::text)),
  ('ops_board.detail_not_found_title',   to_jsonb('Order not found'::text)),
  ('ops_board.detail_not_found_message', to_jsonb('This order is no longer on the board.'::text))
on conflict (key) do nothing;

-- The tab caption the fulfilment console prints (FulfillLookups.ui).
insert into public.fw_ui_label (key, value) values
  ('ops_board_tab',        'Ops board'),
  ('ops_board_owner',      'Owner'),
  ('ops_board_next',       'Next'),
  ('ops_board_retry',      'Retry'),
  ('ops_board_error',      'Could not load the ops board.')
on conflict (key) do nothing;

grant execute on function public.ops_board(smallint)             to authenticated;
grant execute on function public.ops_order_detail(uuid)          to authenticated;
grant execute on function public.ops_sla_config_get(smallint)    to authenticated;
grant execute on function public.ops_sla_config_set(jsonb)       to authenticated;
grant execute on function public.ops_dur_label(numeric)          to authenticated;

-- Proof helper: one call that shows the whole change is wired.
create or replace function public.c688_ops_board_proof()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'stages',          (select count(*) from sla_stage where is_active),
    'sla_defaults',    (select count(*) from sla_config where zone_id is null),
    'zone_overrides',  (select count(*) from sla_config where zone_id is not null),
    'staged_orders',   (select count(*) from public._ops_order_stage(null)),
    'history_rows',    (select count(*) from order_stage_history where left_at is null),
    'alerts',          (select count(*) from ops_sla_alert),
    'tab_registered',  (select count(*) from feature_registry
                         where surface = 'fulfill_tab' and route_key = 'ops_board' and is_active),
    'partner_grants',  (select count(*) from partner_permissions where feature_key = 'partner.ops_board'),
    'rpc_allowed',     (select count(*) from partner_rpc_allow
                         where proname in ('ops_board', 'ops_order_detail', 'ops_sla_config_get')),
    'wa_route',        (select count(*) from wa_event_routes
                         where event_key = 'partner_sla_breach' and audience = 'partner' and enabled),
    'cron_task',       (select count(*) from cron_task where name = 'ops-sla-tick' and enabled),
    'copy_keys',       (select count(*) from ui_copy where key like 'ops_board.%'));
$$;
grant execute on function public.c688_ops_board_proof() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. THE TAB BADGE — the breached count, so a breach is visible unopened.
-- (fulfill_stage_counts is replaced whole; only the ops_board block is new.)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fulfill_stage_counts(p_stages text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v      jsonb := '{}'::jsonb;
  v_arr  jsonb;
  n      integer;
begin
  if p_stages is null or cardinality(p_stages) = 0 then
    return v;
  end if;

  if ('supplier_shop' = any (p_stages)) or ('warehouse' = any (p_stages)) then
    begin v_arr := public.fw_list_arrivals(); exception when others then v_arr := null; end;
    if 'supplier_shop' = any (p_stages) then
      v := v || jsonb_build_object('supplier_shop', coalesce((v_arr->>'count')::int, 0));
    end if;
    if 'warehouse' = any (p_stages) then
      v := v || jsonb_build_object('warehouse', coalesce((v_arr->>'warehouse_count')::int, 0));
    end if;
  end if;

  if 'customer_order' = any (p_stages) then
    begin n := coalesce((public.admin_customer_orders()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('customer_order', coalesce(n, 0));
  end if;

  if 'supplier_inquiry' = any (p_stages) then
    begin select count(*) into n from public.get_supplier_inquiry_overview();
    exception when others then n := 0; end;
    v := v || jsonb_build_object('supplier_inquiry', coalesce(n, 0));
  end if;

  if 'supplier_order' = any (p_stages) then
    begin n := coalesce((public.admin_supplier_orders()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('supplier_order', coalesce(n, 0));
  end if;

  if 'bag' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.fw_list_bags()->'bags', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('bag', coalesce(n, 0));
  end if;

  if 'pack' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.pack_list_orders()->'orders', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('pack', coalesce(n, 0));
  end if;

  if 'delivery' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.admin_delivery_queue()->'orders', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('delivery', coalesce(n, 0));
  end if;

  if 'dispute' = any (p_stages) then
    begin
      select count(*) into n
        from jsonb_array_elements(
               coalesce(public.fw_get_disputes()->'disputes', '[]'::jsonb)) d
       where (d->>'is_active')::boolean is true;
    exception when others then n := 0; end;
    v := v || jsonb_build_object('dispute', coalesce(n, 0));
  end if;

  -- CHANGE #690 — the exceptions badge is the console's own count, so the tab
  -- and the screen can never disagree about how much is stuck.
  if 'exceptions' = any (p_stages) then
    begin n := coalesce((public.exceptions_queue()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('exceptions', coalesce(n, 0));
  end if;

  -- CHANGE #688 — the ops board badge is the BREACHED count, the same red the
  -- board itself sorts to the top. A number on the tab is how a breach is seen
  -- without opening the tab.
  if 'ops_board' = any (p_stages) then
    begin n := coalesce((public.ops_board()->'counts'->>'red')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('ops_board', coalesce(n, 0));
  end if;

  return v;
end
$function$

;

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. ADMIN VISIBILITY
--
-- feature_registry's trigger seeds role defaults from `default_access`, which
-- left a plain admin at none/none — so only the super admin would ever see the
-- board. Its sibling (partner.exceptions) gives an admin view+write; this is a
-- READ-ONLY board, so an admin gets view and the SLA panel stays super-admin.
-- access_effective resolves through the CANONICAL key, which is the partner
-- twin, so this is the row that decides it.
-- ─────────────────────────────────────────────────────────────────────────────
update public.access_role_default
   set can_view = true, can_write = false, updated_at = now()
 where feature_key = 'partner.ops_board' and role = 'admin';

-- CHANGE #470 — Stuck-order exceptions queue: no silent stalls anywhere.
--
-- #690 built the queue over seven sources. This change closes the five holes
-- the spec names — an ORDER that stops moving past its own per-stage SLA, a
-- bill that never rendered, a delivery waiting on a reattempt nobody booked, a
-- settlement period nobody acknowledged, and an impossible state the machine
-- itself found — and gives every row the STAGE it is stuck at.
--
-- Every statement is idempotent: a resumed worker re-applies this as a no-op.

-- 1. The stage a reason belongs to. Null = the reason is not stage-bound
--    (a bill, a settlement); the row still carries a stage when it can derive
--    one from the entity.
alter table public.exception_reason
  add column if not exists stage_key text;

update public.exception_reason set stage_key = v.stage
  from (values
    ('item_unfulfillable','inquiry'),
    ('count_variance','count'),
    ('fulfil_task_unassigned','count'),
    ('stock_followup_overdue','collect'),
    ('missed_handover','delivered'),
    ('cold_chain_breach','delivered'),
    ('agency_timeout','dispatch'),
    ('eta_promise_breach','delivered'),
    ('rider_anomaly','delivered')
  ) as v(code, stage)
 where exception_reason.reason_code = v.code
   and exception_reason.stage_key is distinct from v.stage;

-- 2. The five new reasons.
insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind,
   action_route, sort_rank, enabled, stage_key)
values
  -- The spec's headline: an order that stopped moving. Its deadline is the
  -- per-stage sla_config in MINUTES, so sla_hours is 0 — the row only exists
  -- once the stage clock has already run out.
  ('order_stage_stalled','orders',        5, 0,  'zone',  'route', '',              95, true, null),
  ('bill_unrendered',    'bill_jobs',     4, 2,  'admin', 'route', 'bill_pipeline', 60, true, null),
  ('delivery_reattempt_due','deliveries', 4, 0,  'zone',  'route', 'delivery',      70, true, 'delivered'),
  ('settlement_unacked', 'partner_settlement_periods', 3, 72, 'zone', 'route', 'settlement', 40, true, null),
  ('impossible_state',   'ops_state_finding', 5, 0, 'admin','route', '',            99, true, null)
on conflict (reason_code) do update
  set source_key   = excluded.source_key,
      severity     = excluded.severity,
      sla_hours    = excluded.sla_hours,
      owner_kind   = excluded.owner_kind,
      action_kind  = excluded.action_kind,
      action_route = excluded.action_route,
      sort_rank    = excluded.sort_rank,
      enabled      = excluded.enabled,
      stage_key    = excluded.stage_key;

-- 3. A stalled order routes to the surface that unsticks THAT stage, and an
--    impossible state to the surface that owns the entity. Both are data.
insert into public.exception_route_map (class_key, route, note) values
  ('stage:accept',        'customer_order',   'Order accepted late — open the customer order'),
  ('stage:inquiry',       'supplier_inquiry', 'Waterfall stalled — ask the next supplier'),
  ('stage:supplier_order','supplier_order',   'Supplier order not raised'),
  ('stage:collect',       'supplier_shop',    'Not collected from the shop'),
  ('stage:arrival',       'warehouse',        'Not received at the warehouse'),
  ('stage:count',         'warehouse',        'Not counted in'),
  ('stage:bag',           'bag',              'Not allocated to a bag'),
  ('stage:pack',          'pack',             'Not packed'),
  ('stage:dispatch',      'delivery',         'No rider assigned'),
  ('stage:delivered',     'delivery',         'Stop not closed with proof'),
  ('rule:item_packed_uncollected', 'pack',       'Packed without a collection'),
  ('rule:item_counted_uncollected','warehouse',  'Counted without a collection'),
  ('rule:bagged_uncounted',        'warehouse',  'Bagged without a count'),
  ('rule:unfulfillable_packed',    'pack',       'Unfulfillable item still packed'),
  ('rule:delivered_no_proof',      'delivery',   'Delivered without proof'),
  ('rule:closed_with_live_items',  'customer_order', 'Order closed with live items')
on conflict (class_key) do update
  set route = excluded.route, note = excluded.note;

-- 4. Every string the console prints. Nothing below is written in Dart.
insert into public.ui_copy (key, value) values
  ('exc.reason.order_stage_stalled',    '"Order stalled"'::jsonb),
  ('exc.action.order_stage_stalled',    '"Move it on"'::jsonb),
  ('exc.reason.bill_unrendered',        '"Bill not rendered"'::jsonb),
  ('exc.action.bill_unrendered',        '"Open the bill pipeline"'::jsonb),
  ('exc.reason.delivery_reattempt_due', '"Reattempt due"'::jsonb),
  ('exc.action.delivery_reattempt_due', '"Book the reattempt"'::jsonb),
  ('exc.reason.settlement_unacked',     '"Settlement unacknowledged"'::jsonb),
  ('exc.action.settlement_unacked',     '"Open the settlement"'::jsonb),
  ('exc.reason.impossible_state',       '"Impossible state"'::jsonb),
  ('exc.action.impossible_state',       '"Open and correct it"'::jsonb),
  -- #713 shipped two reasons without their copy; the console printed a blank
  -- chip for both. Fixed here rather than left for someone to notice.
  ('exc.reason.thread_sla_breach',      '"Customer waiting"'::jsonb),
  ('exc.action.thread_sla_breach',      '"Answer the thread"'::jsonb),
  ('exc.reason.thread_call_task_open',  '"Call not made"'::jsonb),
  ('exc.action.thread_call_task_open',  '"Make the call"'::jsonb),
  ('exc.stage_prefix',                  '"Stage: {stage}"'::jsonb),
  ('exc.stage_none',                    '"No stage"'::jsonb),
  ('exc.link_label',                    '"Open"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- 5. The state machine's own rule book — labels and routes are data, so a new
--    invariant is an INSERT here plus one branch in the sweep.
create table if not exists public.ops_state_rule (
  rule_key    text primary key,
  label       text not null,
  detail      text not null default '',
  next_action text not null default '',
  severity    smallint not null default 5,
  entity_kind text not null default 'order_item',
  sort_rank   integer not null default 0,
  enabled     boolean not null default true,
  created_at  timestamptz not null default now()
);

insert into public.ops_state_rule
  (rule_key, label, detail, next_action, severity, entity_kind, sort_rank) values
  ('item_packed_uncollected','Packed but never collected',
   'The line is marked packed while the shop collection was never locked.',
   'Re-open the line and lock the collection', 5, 'order_item', 90),
  ('item_counted_uncollected','Counted but never collected',
   'The warehouse recounted a line the shop never handed over.',
   'Lock the collection or clear the recount', 5, 'order_item', 80),
  ('bagged_uncounted','Bagged but never counted',
   'The line sits in a bag with no warehouse recount.',
   'Count the line in', 4, 'order_item', 70),
  ('unfulfillable_packed','Unfulfillable but packed',
   'A line no supplier could fill was packed into the order.',
   'Remove it from the pack', 5, 'order_item', 85),
  ('delivered_no_proof','Delivered without proof',
   'The stop is closed and carries no OTP, photo or signature.',
   'Attach the delivery proof', 4, 'delivery', 60),
  ('closed_with_live_items','Closed with live items',
   'The order is closed while lines are still neither packed nor written off.',
   'Re-open the order or settle the lines', 5, 'order', 95)
on conflict (rule_key) do update
  set label = excluded.label, detail = excluded.detail,
      next_action = excluded.next_action, severity = excluded.severity,
      entity_kind = excluded.entity_kind, sort_rank = excluded.sort_rank;

-- 6. What the sweep found. A finding is OPEN until the state it describes is
--    gone; the sweep itself closes it, so nothing is resolved by hand.
create table if not exists public.ops_state_finding (
  id          bigint generated by default as identity primary key,
  rule_key    text not null references public.ops_state_rule(rule_key),
  entity_kind text not null,
  entity_id   text not null,
  order_id    uuid,
  zone_id     smallint,
  label       text not null default '',
  detail      text not null default '',
  found_at    timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  cleared_at  timestamptz,
  runs        integer not null default 1
);

create unique index if not exists ops_state_finding_open_uq
  on public.ops_state_finding (rule_key, entity_id)
  where cleared_at is null;
create index if not exists ops_state_finding_zone_idx
  on public.ops_state_finding (zone_id) where cleared_at is null;

alter table public.ops_state_finding enable row level security;
alter table public.ops_state_rule    enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='ops_state_finding'
                    and policyname='ops_state_finding_admin_read') then
    create policy ops_state_finding_admin_read on public.ops_state_finding
      for select using (public.get_my_role() in ('admin','super_admin'));
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='ops_state_rule'
                    and policyname='ops_state_rule_admin_read') then
    create policy ops_state_rule_admin_read on public.ops_state_rule
      for select using (public.get_my_role() in ('admin','super_admin'));
  end if;
end $$;

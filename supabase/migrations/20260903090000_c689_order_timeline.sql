-- ============================================================================
-- CHANGE #689 — feature_gaps #75: ONE order timeline.
--
-- Answering "where is CPO260726NIT123O1" meant reading orders, order_items,
-- inquiry, supplier_orders, bag_allocations, receiving_log and
-- wa_send_attempts separately. This change assembles all of them into ONE
-- ordered event list on the RPC the app already calls for an order's progress
-- (order_timeline), with the responsible ACTOR on every event and a one-tap
-- ACTION on the step that is late.
--
-- PART 1 — the data the timeline is worded and ruled by. Every label is a
-- ui_copy row (wording changes are an UPDATE, never a deploy); every "late"
-- threshold is an order_timeline_stage row.
-- ============================================================================

-- ── copy ────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('order_timeline.events_heading',   to_jsonb('Order timeline'::text)),
  ('order_timeline.events_empty',     to_jsonb('Nothing has happened on this order yet.'::text)),
  ('order_timeline.privacy_note',     to_jsonb('Supplier details are kept private.'::text)),
  ('order_timeline.actor_customer',   to_jsonb('Customer'::text)),
  ('order_timeline.actor_supplier',   to_jsonb('Supplier'::text)),
  ('order_timeline.actor_rider',      to_jsonb('Rider'::text)),
  ('order_timeline.actor_warehouse',  to_jsonb('Warehouse'::text)),
  ('order_timeline.actor_medibo',     to_jsonb('mediBO'::text)),
  ('order_timeline.actor_partner',    to_jsonb('Partner'::text)),
  ('order_timeline.supplier_masked',  to_jsonb('a supplier'::text)),
  ('order_timeline.ev_placed',        to_jsonb('Order placed'::text)),
  ('order_timeline.ev_placed_detail', to_jsonb('{n} items · {amount}'::text)),
  ('order_timeline.ev_inq_asked',     to_jsonb('Asked {supplier}'::text)),
  ('order_timeline.ev_inq_asked_detail', to_jsonb('{n} items on the inquiry'::text)),
  ('order_timeline.ev_inq_answered',  to_jsonb('{supplier} answered'::text)),
  ('order_timeline.ev_inq_answered_detail', to_jsonb('{n} items answered'::text)),
  ('order_timeline.ev_inq_advanced',  to_jsonb('Moved on to {supplier}'::text)),
  ('order_timeline.ev_unfulfillable', to_jsonb('{n} items nobody could supply'::text)),
  ('order_timeline.ev_so_sent',       to_jsonb('Supplier order sent to {supplier}'::text)),
  ('order_timeline.ev_so_accepted',   to_jsonb('{supplier} accepted'::text)),
  ('order_timeline.ev_so_declined',   to_jsonb('{supplier} declined'::text)),
  ('order_timeline.ev_so_packed',     to_jsonb('{supplier} packed the order'::text)),
  ('order_timeline.ev_so_settled',    to_jsonb('Settled with {supplier}'::text)),
  ('order_timeline.ev_received',      to_jsonb('Received at the warehouse'::text)),
  ('order_timeline.ev_received_detail', to_jsonb('{n} entries'::text)),
  ('order_timeline.ev_bagged',        to_jsonb('Bags allocated'::text)),
  ('order_timeline.ev_bagged_detail', to_jsonb('{n} bags'::text)),
  ('order_timeline.ev_packed',        to_jsonb('Packed'::text)),
  ('order_timeline.ev_packed_detail', to_jsonb('{n} items packed'::text)),
  ('order_timeline.ev_dispatch_ready', to_jsonb('Ready to dispatch'::text)),
  ('order_timeline.ev_dlv_assigned',  to_jsonb('Assigned to {rider}'::text)),
  ('order_timeline.ev_dlv_accepted',  to_jsonb('{rider} accepted the run'::text)),
  ('order_timeline.ev_dlv_started',   to_jsonb('Out for delivery'::text)),
  ('order_timeline.ev_dlv_arrived',   to_jsonb('Rider arrived'::text)),
  ('order_timeline.ev_dlv_delivered', to_jsonb('Delivered'::text)),
  ('order_timeline.ev_dlv_failed',    to_jsonb('Delivery attempt failed'::text)),
  ('order_timeline.ev_pay_claim',     to_jsonb('Payment claim received'::text)),
  ('order_timeline.ev_pay_verified',  to_jsonb('Payment verified'::text)),
  ('order_timeline.ev_pay_rejected',  to_jsonb('Payment claim rejected'::text)),
  ('order_timeline.ev_wa_ok',         to_jsonb('WhatsApp sent'::text)),
  ('order_timeline.ev_wa_failed',     to_jsonb('WhatsApp failed'::text)),
  ('order_timeline.ev_closed',        to_jsonb('Order closed'::text)),
  ('order_timeline.ev_cancelled',     to_jsonb('Order cancelled'::text)),
  ('order_timeline.ev_act_done',      to_jsonb('{who} used {action}'::text)),
  ('order_timeline.dlv_picked_up',    to_jsonb('Parcel picked up'::text)),
  ('order_timeline.dlv_handover',     to_jsonb('Parcel handed over'::text)),
  ('order_timeline.dlv_reassigned',   to_jsonb('Reassigned to another rider'::text)),
  ('order_timeline.dlv_rescheduled',  to_jsonb('Delivery rescheduled'::text)),
  ('order_timeline.act_nudge_supplier', to_jsonb('Nudge supplier'::text)),
  ('order_timeline.act_chase_payment',  to_jsonb('Chase payment'::text)),
  ('order_timeline.act_call_customer',  to_jsonb('Call customer'::text)),
  ('order_timeline.act_call_rider',     to_jsonb('Call rider'::text)),
  ('order_timeline.act_reassign',       to_jsonb('Reassign rider'::text)),
  ('order_timeline.act_pick_rider',     to_jsonb('Pick a rider'::text)),
  ('order_timeline.act_no_riders',      to_jsonb('No rider is available in this zone right now.'::text)),
  ('order_timeline.act_not_allowed',    to_jsonb('You do not have permission to do that.'::text)),
  ('order_timeline.act_unknown',        to_jsonb('That action is not available on this order.'::text)),
  ('order_timeline.act_no_delivery',    to_jsonb('This order has no delivery to reassign.'::text)),
  ('order_timeline.act_no_supplier',    to_jsonb('No supplier is waiting on this order.'::text)),
  ('order_timeline.act_done',           to_jsonb('Done.'::text)),
  ('order_timeline.late_label',         to_jsonb('Late'::text)),
  ('order_timeline.not_authorized',     to_jsonb('You do not have access to this order.'::text))
on conflict (key) do nothing;

-- ── the matrix keys the timeline is gated on ────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, category, surface, partner_feature_key,
   description, search_terms)
values
  ('fulfill.order_timeline', 'Order timeline', 'Fulfill', 'timeline', '', 6,
   'medibo', false, 'read', 'orders', 'fulfill_tab', 'partner.order_timeline',
   'One ordered event list per order with the responsible person and a one-tap action.',
   'timeline order history where is my order actor nudge'),
  ('partner.order_timeline', 'Order timeline', 'Fulfilment', 'timeline', '', 6,
   'partner', true, 'none', 'system', 'dashboard', null,
   'One ordered event list per order, clamped to the partner zone.',
   'timeline order history')
on conflict (feature_key) do nothing;

-- feature_registry seeds access_role_default by trigger (super_admin write,
-- everyone else none) exactly as fulfill.ops_board is seeded. An admin is
-- granted the timeline the same way they are granted the board: by grant.

-- ── the partner fence: both RPCs are zone-clamped inside ────────────────────
insert into public.partner_rpc_allow(proname, source, note) values
  ('order_timeline',     'c689', 'Order timeline — zone-clamped inside the RPC'),
  ('order_timeline_act', 'c689', 'Order timeline one-tap action — zone-clamped inside the RPC')
on conflict (proname) do nothing;

-- ── when a stage counts as late, and what to offer when it is ───────────────
create table if not exists public.order_timeline_stage (
  stage_key       text primary key,
  sort_order      int  not null default 100,
  amber_after_min int,
  late_after_min  int,
  action_kind     text,
  is_active       boolean not null default true
);

insert into public.order_timeline_stage
  (stage_key, sort_order, amber_after_min, late_after_min, action_kind) values
  ('placed',    10,   30,   120, 'call_customer'),
  ('inquiry',   20,   45,   180, 'nudge_supplier'),
  ('sourcing',  30,   60,   240, 'nudge_supplier'),
  ('receiving', 40,   60,   240, null),
  ('pack',      50,   45,   120, null),
  ('dispatch',  60,   30,    90, 'reassign'),
  ('delivery',  70,   60,   180, 'call_rider'),
  ('payment',   80, 1440,  4320, 'chase_payment'),
  ('closed',    90, null,  null, null),
  ('message',   95, null,  null, null),
  ('action',    96, null,  null, null)
on conflict (stage_key) do nothing;

-- ── every action appends its own event ──────────────────────────────────────
create table if not exists public.order_timeline_action_log (
  id           bigserial primary key,
  order_id     uuid not null,
  action_kind  text not null,
  actor_kind   text not null default 'medibo',
  actor_name   text not null default '',
  ok           boolean not null default true,
  note         text not null default '',
  detail       jsonb  not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists order_timeline_action_log_order_idx
  on public.order_timeline_action_log(order_id, created_at);

alter table public.order_timeline_stage      enable row level security;
alter table public.order_timeline_action_log enable row level security;

-- A stage that is part of the ORDER'S FLOW can be "the one we are waiting on";
-- ops chatter (a WhatsApp attempt, an action someone took) never is, so a
-- message at 14:02 must not make the inquiry that has been silent for 9 hours
-- look attended to.
alter table public.order_timeline_stage add column if not exists is_flow boolean not null default true;
update public.order_timeline_stage set is_flow = false where stage_key in ('message','action','closed');

-- ============================================================================
-- CHANGE #689 — PART 2: the event builder.
--
-- One function assembles every source into one ordered list. It is the ONLY
-- place that knows which table an event came from; the app never learns.
-- ============================================================================

-- Fill {tokens} in a ui_copy sentence. The sentence stays in the table, so the
-- wording is an UPDATE and never a deploy.
create or replace function public._otl_fill(p_key text, p_fallback text, p_tokens jsonb default '{}'::jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v text := public.uic(p_key, p_fallback); k text;
begin
  if p_tokens is null then return v; end if;
  for k in select jsonb_object_keys(p_tokens) loop
    v := replace(v, '{'||k||'}', coalesce(p_tokens->>k, ''));
  end loop;
  return v;
end $$;

-- One actor block. `p_access` decides whether a name and a number are allowed
-- out at all: a customer never learns which supplier is holding their order.
create or replace function public._otl_actor(p_kind text, p_name text, p_phone text, p_access text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_role text; v_name text; v_phone text;
begin
  if coalesce(p_kind,'') = '' then return jsonb_build_object('has', false); end if;
  v_role := public.uic('order_timeline.actor_'||p_kind, '');
  if v_role = '' then return jsonb_build_object('has', false); end if;

  v_name  := coalesce(nullif(btrim(p_name),''), '');
  v_phone := coalesce(nullif(btrim(p_phone),''), '');

  if p_access <> 'full' then
    -- Filtered: no numbers at all, and a supplier is never named.
    v_phone := '';
    if p_kind = 'supplier' then v_name := public.uic('order_timeline.supplier_masked','a supplier'); end if;
  end if;

  return jsonb_build_object(
    'has',       true,
    'kind',      p_kind,
    'name',      v_name,
    'phone',     v_phone,
    'has_phone', (v_phone <> ''),
    'label',     case when v_name = '' then v_role else v_role || ' · ' || v_name end);
end $$;

-- One action descriptor. Every action is the SAME rpc with a different key —
-- the dispatcher is the whitelist, so the app can call `rpc` with `args`
-- verbatim without ever being handed a function name it could abuse.
create or replace function public._otl_action(p_kind text, p_order_id uuid, p_args jsonb, p_tone text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_label text;
begin
  if coalesce(p_kind,'') = '' then return jsonb_build_object('has', false); end if;
  v_label := public.uic('order_timeline.act_'||p_kind, '');
  if v_label = '' then return jsonb_build_object('has', false); end if;
  return jsonb_build_object(
    'has',   true,
    'kind',  p_kind,
    'label', v_label,
    'tone',  coalesce(nullif(p_tone,''), 'neutral'),
    'rpc',   'order_timeline_act',
    'args',  jsonb_build_object(
               'p_order_id', p_order_id::text,
               'p_action',   p_kind,
               'p_args',     coalesce(p_args, '{}'::jsonb)));
end $$;

-- ============================================================================
-- CHANGE #689 — PART 3: every source, assembled once, in one ordered list.
--
-- This is the ONLY place that knows an event came from supplier_orders rather
-- than receiving_log. The app is handed ts / label / actor / tone / action and
-- prints them; it never joins, never sorts, never decides.
--
-- p_access 'full'     → admin / partner: real supplier names, real numbers.
-- p_access 'customer' → the buyer: no supplier name, no phone, no ops chatter.
-- p_can_act           → whether a one-tap action may be offered at all.
-- ============================================================================
create or replace function public._order_timeline_events(
  p_order_id uuid, p_access text, p_can_act boolean default false)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  o        public.orders%rowtype;
  v_raw    jsonb := '[]'::jsonb;
  v_out    jsonb := '[]'::jsonb;
  r        record;
  v_cust   text; v_cust_phone text;
  v_n      int;  v_amt text; v_ts timestamptz;
  v_open   boolean;
  v_flow_stage text;
  v_due    numeric;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then return '[]'::jsonb; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(o.pharmacy_name),''), ''),
         coalesce(nullif(btrim(pp.whatsapp_no),''), nullif(btrim(pp.phone),''), nullif(btrim(o.phone),''), '')
    into v_cust, v_cust_phone
    from public.orders o2 left join public.pharmacy_profiles pp on pp.id = o2.customer_id
   where o2.id = p_order_id;
  v_cust := coalesce(v_cust,''); v_cust_phone := coalesce(v_cust_phone,'');

  -- ── 1. placed ─────────────────────────────────────────────────────────────
  select count(*)::int into v_n from public.order_items where order_id = p_order_id;
  v_amt := public.inr_money(coalesce(o.total_amount, 0));
  v_raw := v_raw || jsonb_build_array(jsonb_build_object(
    'ts', o.created_at, 'stage','placed','hint',0,'internal',false,
    'label',  public._otl_fill('order_timeline.ev_placed','Order placed'),
    'detail', public._otl_fill('order_timeline.ev_placed_detail','{n} items · {amount}',
                jsonb_build_object('n', v_n::text, 'amount', v_amt)),
    'tone','neutral',
    'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
    'action_kind','call_customer','action_args','{}'::jsonb));

  -- ── 2. inquiry: asked / answered / advanced / nobody had it ───────────────
  for r in
    select i.current_supplier as sup,
           min(coalesce(i.asked_at, i.created_at)) as ts, count(*)::int as n
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id
       and coalesce(btrim(i.current_supplier),'') <> ''
     group by i.current_supplier
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',1,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_inq_asked','Asked {supplier}',
                  jsonb_build_object('supplier', r.sup)),
      'detail', public._otl_fill('order_timeline.ev_inq_asked_detail','{n} items on the inquiry',
                  jsonb_build_object('n', r.n::text)),
      'tone','neutral',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','nudge_supplier','action_args', jsonb_build_object('supplier_name', r.sup)));
  end loop;

  for r in
    -- "Answered" is the backend's own word for it: inquiry.response is the
    -- reply text the waterfall recorded. The per-form booleans are the FORM's
    -- toggles and are false on a row answered over WhatsApp.
    select i.responsed_by as sup, max(coalesce(i.asked_at, i.created_at)) as ts,
           count(*)::int as n, max(i.response) as reply
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id
       and coalesce(btrim(i.responsed_by),'') <> ''
       and coalesce(btrim(i.response),'') <> ''
       -- responsed_by also carries the engine's own "nobody answered" sentence.
       -- An actor you cannot name is not an actor, so only a real supplier
       -- becomes an "answered" event.
       and exists (select 1 from public.supplier_profiles sp
                    where sp.supplier_name = i.responsed_by)
     group by i.responsed_by
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',2,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_inq_answered','{supplier} answered',
                  jsonb_build_object('supplier', r.sup)),
      'detail', public._otl_fill('order_timeline.ev_inq_answered_detail','{n} items answered',
                  jsonb_build_object('n', r.n::text)) || ' · ' || coalesce(r.reply,''),
      'tone','green',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  for r in
    select i.next_supplier as sup, max(coalesce(i.asked_at, i.created_at)) as ts
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id and coalesce(btrim(i.next_supplier),'') <> ''
     group by i.next_supplier
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',3,'internal',true,
      'label', public._otl_fill('order_timeline.ev_inq_advanced','Moved on to {supplier}',
                 jsonb_build_object('supplier', r.sup)),
      'detail','','tone','amber',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  select count(*)::int, max(unfulfillable_at) into v_n, v_ts
    from public.order_items where order_id = p_order_id and coalesce(unfulfillable,false);
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','inquiry','hint',4,'internal',false,
      'label', public._otl_fill('order_timeline.ev_unfulfillable','{n} items nobody could supply',
                 jsonb_build_object('n', v_n::text)),
      'detail','','tone','red',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 3. supplier orders ────────────────────────────────────────────────────
  for r in
    select so.supplier_name as sup, so.created_at, so.accepted_at, so.packed_at,
           so.settled_at, so.accept_state, coalesce(so.decline_reason,'') as decline_reason,
           coalesce(nullif(btrim(sp.whatsapp_no),''), nullif(btrim(sp.phone),''), '') as phone
      from public.supplier_orders so
      left join public.supplier_profiles sp on sp.id = so.supplier_id
     where so.order_id = p_order_id
  loop
    if r.created_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.created_at, 'stage','sourcing','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_so_sent','Supplier order sent to {supplier}',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','neutral',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','nudge_supplier','action_args', jsonb_build_object('supplier_name', r.sup)));
    end if;
    if r.accepted_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.accepted_at, 'stage','sourcing','hint',2,'internal',false,
        'label', public._otl_fill(
                   case when coalesce(r.accept_state,'') = 'declined'
                        then 'order_timeline.ev_so_declined' else 'order_timeline.ev_so_accepted' end,
                   '{supplier} accepted', jsonb_build_object('supplier', r.sup)),
        'detail', r.decline_reason,
        'tone', case when coalesce(r.accept_state,'') = 'declined' then 'red' else 'green' end,
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.packed_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.packed_at, 'stage','sourcing','hint',3,'internal',false,
        'label', public._otl_fill('order_timeline.ev_so_packed','{supplier} packed the order',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','green',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.settled_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.settled_at, 'stage','sourcing','hint',4,'internal',true,
        'label', public._otl_fill('order_timeline.ev_so_settled','Settled with {supplier}',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','green',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 4. receiving + bagging (warehouse: internal) ──────────────────────────
  select count(*)::int, min(created_at) into v_n, v_ts
    from public.receiving_log where order_id = p_order_id;
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','receiving','hint',1,'internal',true,
      'label', public._otl_fill('order_timeline.ev_received','Received at the warehouse'),
      'detail', public._otl_fill('order_timeline.ev_received_detail','{n} entries',
                  jsonb_build_object('n', v_n::text)),
      'tone','neutral',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  select count(distinct bag_no)::int, min(created_at) into v_n, v_ts
    from public.bag_allocations where order_id = p_order_id;
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','receiving','hint',2,'internal',true,
      'label', public._otl_fill('order_timeline.ev_bagged','Bags allocated'),
      'detail', public._otl_fill('order_timeline.ev_bagged_detail','{n} bags',
                  jsonb_build_object('n', v_n::text)),
      'tone','neutral',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 5. pack + dispatch-ready ──────────────────────────────────────────────
  select count(*)::int, max(packed_at) into v_n, v_ts
    from public.order_items where order_id = p_order_id and coalesce(packed,false);
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','pack','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_packed','Packed'),
      'detail', public._otl_fill('order_timeline.ev_packed_detail','{n} items packed',
                  jsonb_build_object('n', v_n::text)),
      'tone','green',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;
  if o.dispatch_ready_at is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', o.dispatch_ready_at, 'stage','pack','hint',2,'internal',false,
      'label', public._otl_fill('order_timeline.ev_dispatch_ready','Ready to dispatch'),
      'detail','','tone','green',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 6. delivery: the milestones on the row, then the event log ────────────
  for r in
    select d.id, d.assigned_at, d.accepted_at, d.started_at, d.arrived_at,
           d.delivered_at, coalesce(d.fail_reason,'') as fail_reason,
           coalesce(nullif(btrim(dp.full_name),''),'') as rider,
           coalesce(nullif(btrim(dp.phone),''),'')     as phone
      from public.deliveries d
      left join public.delivery_partner_registrations dp on dp.id = d.partner_id
     where d.order_id = p_order_id
     order by d.created_at
  loop
    if r.assigned_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.assigned_at, 'stage','dispatch','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_assigned','Assigned to {rider}',
                   jsonb_build_object('rider', r.rider)),
        'detail','','tone','neutral',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','reassign','action_args', jsonb_build_object('delivery_id', r.id::text)));
    end if;
    if r.accepted_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.accepted_at, 'stage','dispatch','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_accepted','{rider} accepted the run',
                   jsonb_build_object('rider', r.rider)),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.started_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.started_at, 'stage','delivery','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_started','Out for delivery'),
        'detail','','tone','neutral',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','call_rider','action_args','{}'::jsonb));
    end if;
    if r.arrived_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.arrived_at, 'stage','delivery','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_arrived','Rider arrived'),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','call_rider','action_args','{}'::jsonb));
    end if;
    if r.delivered_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.delivered_at, 'stage','delivery','hint',3,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_delivered','Delivered'),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    elsif r.fail_reason <> '' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.arrived_at, r.started_at, r.assigned_at), 'stage','delivery','hint',4,
        'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_failed','Delivery attempt failed'),
        'detail', r.fail_reason,'tone','red',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','reassign','action_args', jsonb_build_object('delivery_id', r.id::text)));
    end if;
  end loop;

  -- delivery_events: an event this build has no sentence for is SKIPPED, never
  -- rendered as its raw key. A new event type is one ui_copy INSERT.
  for r in
    select de.event, de.created_at, coalesce(de.note,'') as note,
           coalesce(nullif(btrim(dp.full_name),''),'') as rider,
           coalesce(nullif(btrim(dp.phone),''),'')     as phone
      from public.delivery_events de
      left join public.delivery_partner_registrations dp on dp.id = de.partner_id
     where de.order_id = p_order_id
       and public.uic('order_timeline.dlv_'||de.event, '') <> ''
     order by de.created_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','delivery','hint',5,'internal',false,
      'label', public.uic('order_timeline.dlv_'||r.event, ''),
      'detail', r.note,'tone','neutral',
      'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 7. payments ───────────────────────────────────────────────────────────
  for r in
    select pc.created_at, pc.received_at, pc.status, coalesce(pc.verify_reason,'') as reason,
           coalesce(pc.amount,0) as amount
      from public.payment_claims pc
     where pc.order_id = p_order_id
     order by pc.created_at
     limit 30
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', coalesce(r.created_at, r.received_at), 'stage','payment','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_pay_claim','Payment claim received'),
      'detail', public.inr_money(r.amount),'tone','neutral',
      'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
      'action_kind','','action_args','{}'::jsonb));
    if r.status = 'verified' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.received_at, r.created_at), 'stage','payment','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_pay_verified','Payment verified'),
        'detail', public.inr_money(r.amount),'tone','green',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','','action_args','{}'::jsonb));
    elsif r.status = 'rejected' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.received_at, r.created_at), 'stage','payment','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_pay_rejected','Payment claim rejected'),
        'detail', r.reason,'tone','red',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','chase_payment','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 8. WhatsApp attempts (ops chatter: internal only) ─────────────────────
  for r in
    select wa.created_at, wa.event_key, coalesce(wa.ok,false) as ok, coalesce(wa.reason,'') as reason
      from public.wa_send_attempts wa
     where wa.order_id = p_order_id
     order by wa.created_at desc
     limit 25
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','message','hint',1,'internal',true,
      'label', public._otl_fill(case when r.ok then 'order_timeline.ev_wa_ok'
                                     else 'order_timeline.ev_wa_failed' end,
                                'WhatsApp sent'),
      'detail', case when r.ok then r.event_key else r.event_key||' · '||r.reason end,
      'tone', case when r.ok then 'neutral' else 'red' end,
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 9. closure ────────────────────────────────────────────────────────────
  if o.closed_at is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', o.closed_at, 'stage','closed','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_closed','Order closed'),
      'detail', coalesce(o.closed_reason,''),'tone','green',
      'actor_kind','medibo','actor_name',coalesce(o.closed_by,''),'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  elsif coalesce(o.status,'') = 'cancelled' or coalesce(o.fulfillment_status,'') = 'cancelled' then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', coalesce(o.shipped_at, o.created_at), 'stage','closed','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_cancelled','Order cancelled'),
      'detail','','tone','red',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 10. the actions that were taken FROM this timeline ────────────────────
  for r in
    select al.created_at, al.action_kind, al.actor_kind, al.actor_name,
           al.ok, coalesce(al.note,'') as note
      from public.order_timeline_action_log al
     where al.order_id = p_order_id
     order by al.created_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','action','hint',1,'internal',true,
      'label', public._otl_fill('order_timeline.ev_act_done','{who} used {action}',
                 jsonb_build_object(
                   'who',    coalesce(nullif(r.actor_name,''), public.uic('order_timeline.actor_medibo','mediBO')),
                   'action', public.uic('order_timeline.act_'||r.action_kind, r.action_kind))),
      'detail', r.note, 'tone', case when r.ok then 'neutral' else 'red' end,
      'actor_kind', r.actor_kind,'actor_name', r.actor_name,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- The furthest FLOW stage this order has reached is the one it is waiting on.
  select b.stage into v_flow_stage
    from (select v->>'stage' as stage from jsonb_array_elements(v_raw) t(v)
           where nullif(v->>'ts','') is not null
             and (p_access = 'full' or coalesce((v->>'internal')::boolean,false) = false)) b
    join public.order_timeline_stage ots on ots.stage_key = b.stage and ots.is_active and ots.is_flow
   order by ots.sort_order desc limit 1;

  -- ── assemble: filter, order, word, tone, and hang the action on the step ──
  --
  -- "Late" is not "the newest event is old": a WhatsApp attempt at 14:02 must
  -- not make an inquiry that has been silent since 05:00 look attended to. So
  -- lateness belongs to the furthest FLOW stage the order has reached, and
  -- only while the order is still open.
  v_open := (o.closed_at is null
             and coalesce(o.status,'') <> 'cancelled'
             and coalesce(o.fulfillment_status,'') <> 'cancelled'
             and not exists (select 1 from public.deliveries d
                              where d.order_id = p_order_id and d.delivered_at is not null));

  select coalesce(jsonb_agg(x.ev order by x.ts, x.hint, x.ord), '[]'::jsonb)
    into v_out
  from (
    select e.ts, e.hint, e.ord,
           jsonb_build_object(
             'ts',        e.ts,
             'ts_label',  public.ist_fmt(e.ts, 'dmy2_time12'),
             'age_label', public.ops_age_label(e.ts),
             'stage',     e.stage,
             'label',     e.label,
             'detail',    e.detail,
             'has_detail',(coalesce(e.detail,'') <> ''),
             'tone',      case when e.is_late  then 'red'
                               when e.is_amber then 'amber'
                               else e.tone end,
             'late',      e.is_late,
             'late_label',case when e.is_late
                               then public.uic('order_timeline.late_label','Late') else '' end,
             'is_current',e.is_waiting_on,
             'actor',     public._otl_actor(e.actor_kind, e.actor_name, e.actor_phone, p_access),
             'action',    case when p_can_act and p_access = 'full' and e.is_action_last
                               then public._otl_action(e.action_kind, p_order_id, e.action_args,
                                      case when e.is_late then 'red' else 'neutral' end)
                               else jsonb_build_object('has', false) end) as ev
      from (
        select b.*,
               (b.is_stage_last and b.stage = v_flow_stage and v_open
                and b.late_after_min is not null and b.age_min >= b.late_after_min)  as is_late,
               (b.is_stage_last and b.stage = v_flow_stage and v_open
                and b.amber_after_min is not null and b.age_min >= b.amber_after_min) as is_amber,
               (b.is_stage_last and b.stage = v_flow_stage and v_open)                as is_waiting_on
          from (
            select (v->>'ts')::timestamptz as ts,
                   (v->>'hint')::int       as hint,
                   row_number() over ()    as ord,
                   v->>'stage'  as stage, v->>'label' as label, v->>'detail' as detail,
                   v->>'tone'   as tone,
                   v->>'actor_kind' as actor_kind, v->>'actor_name' as actor_name,
                   v->>'actor_phone' as actor_phone,
                   v->>'action_kind' as action_kind, v->'action_args' as action_args,
                   floor(extract(epoch from (now() - (v->>'ts')::timestamptz))/60)::int as age_min,
                   ots.late_after_min, ots.amber_after_min,
                   row_number() over (partition by v->>'stage'
                                      order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1
                     as is_stage_last,
                   (coalesce(v->>'action_kind','') <> ''
                    and row_number() over (partition by v->>'stage', v->>'action_kind'
                                           order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1)
                     as is_action_last
              from jsonb_array_elements(v_raw) t(v)
              left join public.order_timeline_stage ots
                     on ots.stage_key = v->>'stage' and ots.is_active
             where nullif(v->>'ts','') is not null
               and (p_access = 'full' or coalesce((v->>'internal')::boolean, false) = false)
          ) b
      ) e
  ) x;

  return v_out;
end $$;

-- ============================================================================
-- CHANGE #689 — PART 4: who may read the timeline, and how much of it.
-- ============================================================================
create or replace function public._otl_access(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role text := coalesce(public.get_my_role(), 'none');
  v_partner bigint := public.my_partner_id();
  v_a text := 'none'; v_b text := 'none'; v_best text := 'none';
  v_zone smallint; v_owner uuid; v_cust uuid;
begin
  select coalesce(o.zone_id, pp.zone_id)::smallint, o.user_id, o.customer_id
    into v_zone, v_owner, v_cust
    from public.orders o left join public.pharmacy_profiles pp on pp.id = o.customer_id
   where o.id = p_order_id;

  if v_partner is not null then
    v_a := coalesce(public.partner_access('partner.order_timeline', v_partner), 'none');
    v_b := coalesce(public.partner_access('partner.ops_board',      v_partner), 'none');
  elsif v_role in ('admin','super_admin') then
    v_a := coalesce(public.admin_access('fulfill.order_timeline'), 'none');
    v_b := coalesce(public.admin_access('fulfill.ops_board'),      'none');
  end if;
  -- The timeline is its own matrix key, but an operator who already holds the
  -- ops board holds the row's detail too — the board's row tap IS this screen.
  v_best := case when 'write' in (v_a, v_b) then 'write'
                 when 'read'  in (v_a, v_b) then 'read' else 'none' end;

  if v_best <> 'none' then
    if v_partner is not null and v_zone is distinct from public.partner_zone_id() then
      return jsonb_build_object('access','none','can_act',false);
    end if;
    return jsonb_build_object('access','full', 'can_act', (v_best = 'write'));
  end if;

  -- The buyer always sees their OWN order, filtered.
  if auth.uid() is not null and v_owner = auth.uid() then
    return jsonb_build_object('access','customer','can_act',false);
  end if;
  if v_cust is not null and exists (select 1 from public.pharmacy_profiles pp
                                     where pp.id = v_cust and pp.user_id = auth.uid()) then
    return jsonb_build_object('access','customer','can_act',false);
  end if;

  return jsonb_build_object('access','none','can_act',false);
end $$;

-- CHANGE #689 - PART 5: order_timeline keeps every key it had (#691's proof
-- and eta blocks included) and gains the assembled event list.
CREATE OR REPLACE FUNCTION public.order_timeline(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype; d public.deliveries%rowtype;
  cfg jsonb := coalesce((select value from public.app_settings where key='order_timeline_config'), '{}'::jsonb);
  ts jsonb; steps jsonb := '[]'::jsonb; st jsonb; k text;
  v_current text; v_eta text; v_eta_ts timestamptz; v_state text;
  v_hit boolean := false;
  v_acc jsonb; v_access text; v_can_act boolean; v_events jsonb;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found');
  end if;
  select * into d from public.deliveries where order_id = p_order_id
   order by created_at desc limit 1;

  -- When each step actually happened. NULL = it has not happened.
  ts := jsonb_build_object(
    'placed',     o.created_at,
    'sourcing',   case when coalesce(o.status,'') in ('accepted','packed','shipped','delivered','completed')
                         or coalesce(o.fulfillment_status,'') <> 'open'
                       then coalesce(o.order_date::timestamptz, o.created_at) end,
    'packed',     case when coalesce(o.dispatch_ready,false) then coalesce(o.dispatch_ready_at, o.shipped_at) end,
    'dispatched', case when d.id is not null and coalesce(d.status,'') in ('out_for_delivery','delivered','rto')
                       then coalesce(d.started_at, d.assigned_at, o.shipped_at) end,
    'delivered',  d.delivered_at);

  -- The furthest step that has happened is 'current'; everything after is
  -- pending. Walking the list backwards keeps that a single pass.
  for i in reverse jsonb_array_length(coalesce(cfg->'steps','[]'::jsonb))-1 .. 0 loop
    k := (cfg->'steps'->i)->>'key';
    if not v_hit and nullif(ts->>k,'') is not null then
      v_hit := true; v_current := k;
    end if;
  end loop;
  if v_current is null then v_current := 'placed'; end if;

  v_hit := false;
  for i in 0 .. jsonb_array_length(coalesce(cfg->'steps','[]'::jsonb))-1 loop
    st := cfg->'steps'->i;
    k  := st->>'key';
    if v_hit then
      v_state := 'pending';
    elsif k = v_current then
      v_state := case when k = 'delivered' then 'done' else 'current' end;
      v_hit := true;
    else
      v_state := 'done';
    end if;
    steps := steps || jsonb_build_array(jsonb_build_object(
      'key',       k,
      'label',     st->>'label',
      'state',     v_state,
      'done',      (v_state = 'done'),
      'current',   (v_state = 'current'),
      'ts_label',  public._ist_stamp(nullif(ts->>k,'')::timestamptz),
      'has_ts',    (nullif(ts->>k,'') is not null),
      'note',      case when v_state = 'pending' then coalesce(st->>'pending_note','') else '' end));
  end loop;

  -- Expected delivery: the rider's promise when there is one, otherwise the
  -- configured window from the day the order was placed, otherwise say so.
  v_eta_ts := coalesce(d.promised_at, d.next_attempt_on::timestamptz);
  if d.delivered_at is not null then
    v_eta := public._ist_stamp(d.delivered_at);
  elsif v_eta_ts is not null then
    v_eta := public._ist_stamp(v_eta_ts);
  elsif coalesce(o.status,'') = 'cancelled' then
    v_eta := '';
  else
    v_eta := '';
  end if;

  -- CHANGE #689 (gap 75) — the SAME payload now carries the full ordered
  -- event list: orders, order_items, inquiry, supplier_orders, receiving_log,
  -- bag_allocations, pack, deliveries/delivery_events, payments and
  -- wa_send_attempts, assembled once with the actor and the one-tap action.
  -- An operator gets names, numbers and actions; the buyer gets the same
  --list filtered - no supplier name, no phone, no ops chatter.
  v_acc     := public._otl_access(p_order_id);
  v_access  := coalesce(v_acc->>'access', 'none');
  v_can_act := coalesce((v_acc->>'can_act')::boolean, false);
  v_events  := case when v_access = 'none' then '[]'::jsonb
                    else public._order_timeline_events(p_order_id, v_access, v_can_act) end;

  return jsonb_build_object(
    'ok', true,
    'heading',      coalesce(cfg->>'heading','Order progress'),
    'current',      v_current,
    'steps',        steps,
    'eta_label',    coalesce(cfg->>'eta_label','Expected delivery'),
    'eta_display',  coalesce(nullif(v_eta,''), coalesce(cfg->>'eta_unknown','')),
    'has_eta',      (nullif(v_eta,'') is not null),
    -- CHANGE #691 (gap 126)
    'proof', public._delivery_proof_block(p_order_id),
    'eta',   public._delivery_eta_for_order(p_order_id),
    'placed_label', coalesce(cfg->>'placed_label','Placed'),
    'placed_at_label', public._ist_stamp(o.created_at),
    -- CHANGE #689 (gap 75)
    'access',          v_access,
    'can_act',         v_can_act,
    'events',          v_events,
    'event_count',     jsonb_array_length(v_events),
    'events_heading',  public.uic('order_timeline.events_heading','Order timeline'),
    'events_empty',    public.uic('order_timeline.events_empty',''),
    'privacy_note',    case when v_access = 'customer'
                            then public.uic('order_timeline.privacy_note','') else '' end);
end $function$



-- ============================================================================
-- CHANGE #689 — PART 6: the one-tap action.
--
-- The timeline hands the app `rpc: 'order_timeline_act'` and `args`. This
-- function IS the whitelist: it re-checks the matrix (never trusts the args),
-- calls the EXISTING RPC that already does the work, and appends its own event
-- so the timeline records what the operator did from it.
-- ============================================================================
create or replace function public.order_timeline_act(
  p_order_id uuid, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql volatile security definer set search_path to 'public' as $$
declare
  v_acc jsonb := public._otl_access(p_order_id);
  v_who text;
  v_res jsonb := '{}'::jsonb;
  v_ok  boolean := false;
  v_msg text := '';
  v_sup text; v_dlv uuid; v_partner uuid; v_user uuid;
  v_choices jsonb := '[]'::jsonb;
begin
  if coalesce(v_acc->>'access','none') <> 'full'
     or coalesce((v_acc->>'can_act')::boolean,false) is not true then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('order_timeline.act_not_allowed',''));
  end if;
  p_args := coalesce(p_args, '{}'::jsonb);

  select coalesce(nullif(btrim(a.email),''), '') into v_who
    from public.admins a where a.id = public.my_admin_id();
  v_who := coalesce(nullif(v_who,''), public.uic('order_timeline.actor_medibo','mediBO'));

  if p_action = 'nudge_supplier' then
    v_sup := nullif(btrim(coalesce(p_args->>'supplier_name','')), '');
    if v_sup is null then
      select so.supplier_name into v_sup from public.supplier_orders so
       where so.order_id = p_order_id order by so.created_at desc limit 1;
    end if;
    if v_sup is null then
      return jsonb_build_object('ok', false, 'error','no_supplier',
        'message', public.uic('order_timeline.act_no_supplier',''));
    end if;
    v_res := public.fw_send_supplier_short_reminder(v_sup);
    v_ok  := coalesce(v_res->>'status','') = 'ok' or coalesce((v_res->>'ok')::boolean,false);
    v_msg := coalesce(v_res->>'message', public.uic('order_timeline.act_done','Done.'));

  elsif p_action = 'chase_payment' then
    select o.user_id into v_user from public.orders o where o.id = p_order_id;
    if v_user is null then
      return jsonb_build_object('ok', false, 'error','no_customer',
        'message', public.uic('order_timeline.act_unknown',''));
    end if;
    v_res := public.admin_receivables_chase(v_user);
    v_ok  := coalesce((v_res->>'ok')::boolean, false);
    v_msg := coalesce(v_res->>'message', public.uic('order_timeline.act_done','Done.'));

  elsif p_action in ('call_customer','call_rider') then
    v_res := public.call_mask_prepare(auth.uid(), p_order_id,
               case when p_action = 'call_customer' then 'customer' else 'delivery' end);
    v_ok  := coalesce((v_res->>'ok')::boolean, false);
    v_msg := coalesce(v_res->>'message', '');

  elsif p_action = 'reassign' then
    v_dlv := nullif(btrim(coalesce(p_args->>'delivery_id','')), '')::uuid;
    if v_dlv is null then
      select d.id into v_dlv from public.deliveries d
       where d.order_id = p_order_id and coalesce(d.status,'') <> 'cancelled'
       order by d.created_at desc limit 1;
    end if;
    if v_dlv is null then
      return jsonb_build_object('ok', false, 'error','no_delivery',
        'message', public.uic('order_timeline.act_no_delivery',''));
    end if;
    v_partner := nullif(btrim(coalesce(p_args->>'partner_id','')), '')::uuid;
    if v_partner is null then
      -- A rider is a CHOICE, not a guess. The backend returns the eligible
      -- riders and their labels; the app draws the list and calls back.
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', dp.id::text,
               'label', coalesce(nullif(btrim(dp.full_name),''), dp.id::text))
               order by dp.full_name), '[]'::jsonb)
        into v_choices
        from public.delivery_partner_registrations dp
        join public.deliveries d on d.id = v_dlv
       where coalesce(dp.is_active,false)
         and coalesce(dp.is_deleted,false) = false
         and coalesce(dp.status,'') = 'approved'
         and dp.id is distinct from d.partner_id
         and (dp.zone_id is null or d.zone_id is null or dp.zone_id = d.zone_id);
      return jsonb_build_object(
        'ok', false, 'needs_choice', true, 'error','needs_choice',
        'choice_key','partner_id',
        'title',   public.uic('order_timeline.act_pick_rider','Pick a rider'),
        'choices', v_choices,
        'message', case when jsonb_array_length(v_choices) = 0
                        then public.uic('order_timeline.act_no_riders','') else '' end);
    end if;
    v_res := public.delivery_reassign(v_dlv, v_partner);
    v_ok  := coalesce((v_res->>'ok')::boolean, false);
    v_msg := coalesce(v_res->>'message', public.uic('order_timeline.act_done','Done.'));

  else
    return jsonb_build_object('ok', false, 'error','unknown_action',
      'message', public.uic('order_timeline.act_unknown',''));
  end if;

  -- The action appends its own event, so the timeline is the record of what
  -- was done to the order AND from it.
  insert into public.order_timeline_action_log
    (order_id, action_kind, actor_kind, actor_name, ok, note, detail)
  values (p_order_id, p_action, 'medibo', v_who, v_ok, coalesce(v_msg,''), coalesce(v_res,'{}'::jsonb));

  return jsonb_build_object(
    'ok', v_ok,
    'action', p_action,
    'message', coalesce(nullif(v_msg,''), public.uic('order_timeline.act_done','Done.')),
    'result', v_res,
    'timeline', public.order_timeline(p_order_id));
end $$;

revoke all on function public.order_timeline_act(uuid, text, jsonb) from public;
grant execute on function public.order_timeline_act(uuid, text, jsonb) to authenticated, service_role;
grant execute on function public._otl_access(uuid) to authenticated, anon, service_role;

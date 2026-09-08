-- CMD #1839 — Customer order tracking: 15 live stages, cumulative dots,
-- partial progress counts, dropped items, disputes, no supplier names.
--
-- ONE engine feeds BOTH customer views:
--   • the condensed dot strip on the Orders card  (_order_customer_stage →
--     _order_customer_card → my_orders_screen_v2)
--   • the Track popup's full list with timestamps (order_timeline →
--     customer_track_order)
-- so the two can never disagree. Flutter renders; it decides nothing.
--
-- Idempotent: safe to replay on live by the merge worker.

-- ── 1. The stage list is DATA ───────────────────────────────────────────────
-- Om can rename a stage, reorder the list or retire one with an UPDATE. No
-- deploy, no Dart change. `scope` says whether the stage is a whole-order fact
-- or an every-item fact (the ones that carry "14 of 15"). `origin_only` is how
-- a website/app order starts at "Order placed" while a WhatsApp enquiry starts
-- one stage earlier at "Lead".
create table if not exists public.order_customer_stage_def (
  stage_key   text primary key,
  sort_order  int     not null,
  label       text    not null,
  scope       text    not null default 'order',
  origin_only text,
  is_active   boolean not null default true
);
alter table public.order_customer_stage_def enable row level security;
revoke all on table public.order_customer_stage_def from anon, authenticated;

insert into public.order_customer_stage_def (stage_key, sort_order, label, scope, origin_only) values
  ('lead',             10, 'Lead',                 'order', 'whatsapp'),
  ('placed',           20, 'Order placed',         'order', null),
  ('advance_paid',     30, 'Advance paid',         'order', null),
  ('confirmed',        40, 'Order confirmed',      'order', null),
  ('processing',       50, 'Processing order',     'order', null),
  ('bill_sent',        60, 'Bill sent',            'order', null),
  ('balance_paid',     70, 'Balance paid',         'order', null),
  ('sourcing',         80, 'Sourcing',             'item',  null),
  ('collected',        90, 'Collected',            'item',  null),
  ('packing',         100, 'Packing',              'item',  null),
  ('packed',          110, 'Packed',               'item',  null),
  ('ready_dispatch',  120, 'Ready to dispatch',    'order', null),
  ('assigned',        130, 'Assigned to delivery', 'order', null),
  ('out_for_delivery',140, 'Out for delivery',     'order', null),
  ('delivered',       150, 'Delivered',            'order', null)
on conflict (stage_key) do update
  set sort_order  = excluded.sort_order,
      scope       = excluded.scope,
      origin_only = excluded.origin_only;

-- Every sentence the two views print. Copy, so it is an UPDATE not a deploy.
insert into public.ui_copy (key, value) values
  ('orders.stage_count_fmt',     to_jsonb('{label} {n} of {total}'::text)),
  ('orders.stage_dispute_one',   to_jsonb('1 item being re-sourced'::text)),
  ('orders.stage_dispute_many',  to_jsonb('{n} items being re-sourced'::text)),
  ('orders.stage_heading',       to_jsonb('Order progress'::text)),
  ('orders.stage_cancelled_note',to_jsonb('This order was cancelled.'::text))
on conflict (key) do nothing;

-- ── 2. The engine ───────────────────────────────────────────────────────────
create or replace function public._order_stage_engine(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  o public.orders%rowtype;
  d public.deliveries%rowtype;
  v_origin text;
  v_cancelled boolean; v_delivered boolean;
  v_total int := 0; v_dropped int := 0; v_disputed int := 0;
  n_src int := 0; n_col int := 0; n_pkg int := 0; n_pkd int := 0;
  t_lead timestamptz; t_placed timestamptz; t_adv timestamptz; t_conf timestamptz;
  t_proc timestamptz; t_bill timestamptz; t_bal timestamptz;
  t_src  timestamptz; t_col timestamptz; t_pkg timestamptz; t_pkd timestamptz;
  t_ready timestamptz; t_asg timestamptz; t_ofd timestamptz; t_dlv timestamptz;
  v_paid numeric := 0; v_first_paid timestamptz; v_last_paid timestamptz;
  r record;
  v_raw jsonb := '[]'::jsonb; v_stages jsonb := '[]'::jsonb;
  v_len int; i int; v_e jsonb;
  v_last_done int := -1; v_cur int := 0;
  v_state text; v_cnt text; v_full boolean;
  v_n int; v_tot int; v_ts timestamptz;
  v_fmt text; v_note text; v_caption text;
  v_cur_key text := ''; v_cur_label text := '';
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found');
  end if;
  select * into d from public.deliveries where order_id = p_order_id
   order by created_at desc limit 1;

  -- Where the order came from. A WhatsApp enquiry has a Lead stage; a website
  -- or app order does not have one to show, so it is never sent.
  v_origin := case when lower(coalesce(o.source,'')) in ('whatsapp','wa','wa_assistant','chat')
                   then 'whatsapp' else 'app' end;

  v_cancelled := lower(coalesce(o.status,'')) in ('cancelled','canceled','rejected')
                 or exists (select 1 from public.order_cancellations where order_id = p_order_id);
  v_delivered := (not v_cancelled)
                 and (lower(coalesce(o.status,'')) in ('delivered','completed')
                      or o.closed_at is not null
                      or coalesce(d.status,'') = 'delivered');

  -- ── every-item facts, in ONE pass ────────────────────────────────────────
  -- An item marked unfulfillable LEAVES the count: 15 becomes 14 and the stage
  -- completes on the 14. An item holding an OPEN dispute stays in the total but
  -- never counts as collected/packing/packed — that is what "holds its stage"
  -- means, and it is why the strip stops instead of lying.
  with it as (
    select oi.*,
           exists (select 1 from public.supplier_disputes sd
                    where sd.order_item_id = oi.id
                      and coalesce(sd.status,'') not in ('resolved','cancelled')) as disputed,
           exists (select 1 from public.inquiry q
                    where q.id = oi.inquiry_id
                      and (nullif(btrim(coalesce(q.submit_response,'')),'') is not null
                           or nullif(btrim(coalesce(q.response,'')),'') is not null
                           or q.available is not null)) as answered
      from public.order_items oi
     where oi.order_id = p_order_id
  ), live as (
    select * from it where not coalesce(unfulfillable, false)
  )
  select
    (select count(*) from live),
    (select count(*) from it where coalesce(unfulfillable,false)),
    (select count(*) from live where disputed),
    (select count(*) from live where answered or assigned_supplier is not null
        or coalesce(fulfillment_state,'pending') <> 'pending'
        or coalesce(collect_locked,false) or coalesce(at_warehouse,false) or coalesce(packed,false)),
    (select count(*) from live where not disputed and
        (coalesce(collect_locked,false) or shop_qty is not null
         or coalesce(at_warehouse,false) or coalesce(packed,false))),
    (select count(*) from live where not disputed and
        (coalesce(at_warehouse,false) or wh_recount_qty is not null or coalesce(packed,false))),
    (select count(*) from live where not disputed and coalesce(packed,false)),
    (select max(coalesce(ps_filled_at, created_at)) from live),
    (select max(collect_locked_at) from live),
    (select max(arrived_at) from live),
    (select max(packed_at) from live)
   into v_total, v_dropped, v_disputed, n_src, n_col, n_pkg, n_pkd,
        t_src, t_col, t_pkg, t_pkd;

  -- ── whole-order facts ────────────────────────────────────────────────────
  if v_origin = 'whatsapp' then
    select coalesce(min(t.created_at), o.created_at) into t_lead
      from public.order_thread t where t.order_id = p_order_id;
    t_lead := coalesce(t_lead, o.created_at);
  end if;
  t_placed := o.created_at;

  select coalesce(sum(c.amount), 0),
         min(coalesce(c.received_at, c.created_at)),
         max(coalesce(c.received_at, c.created_at))
    into v_paid, v_first_paid, v_last_paid
    from public.payment_claims c
   where c.order_id = p_order_id
     and lower(coalesce(c.status,'')) in ('verified','received');
  t_adv := v_first_paid;
  if coalesce(o.total_amount,0) > 0 and v_paid >= o.total_amount then
    t_bal := v_last_paid;
  end if;

  select min(e.at) into t_conf from public.order_state_event e
   where e.order_id = p_order_id and e.entity_kind = 'order' and e.to_state = 'accepted';
  if t_conf is null and lower(coalesce(o.status,'')) in
       ('accepted','packed','shipped','delivered','completed') then
    t_conf := coalesce(o.order_date::timestamptz, o.created_at);
  end if;

  select min(q.asked_at) into t_proc
    from public.order_items oi join public.inquiry q on q.id = oi.inquiry_id
   where oi.order_id = p_order_id and q.asked_at is not null;
  if t_proc is null and coalesce(o.fulfillment_status,'open') <> 'open' then
    t_proc := coalesce(o.order_date::timestamptz, o.created_at);
  end if;

  t_bill := coalesce(o.invoice_issued_at, o.cust_bill_uploaded_at);

  if coalesce(o.dispatch_ready,false) then
    t_ready := coalesce(o.dispatch_ready_at, o.shipped_at, o.created_at);
  end if;

  if d.id is not null and (d.partner_id is not null or d.agency_id is not null) then
    t_asg := coalesce(d.assigned_at, d.agency_assigned_at);
  end if;
  if d.id is not null and coalesce(d.status,'') in ('out_for_delivery','delivered','rto') then
    t_ofd := coalesce(d.started_at,
                      (select r2.started_at from public.delivery_runs r2 where r2.id = d.run_id),
                      d.assigned_at);
  end if;
  -- Proof captured. An order closed without a delivery row (counter pickup,
  -- an admin closure) is still delivered, and its closure IS the stamp.
  t_dlv := coalesce(d.delivered_at,
                    case when v_delivered then coalesce(o.closed_at, o.shipped_at, o.created_at) end);

  -- ── raw per-stage facts, in the table's own order ────────────────────────
  for r in
    select stage_key, sort_order, label, scope
      from public.order_customer_stage_def
     where is_active and (origin_only is null or origin_only = v_origin)
     order by sort_order, stage_key
  loop
    v_n := null; v_tot := null; v_ts := null;
    if r.scope = 'item' then
      v_tot := v_total;
      v_n := case r.stage_key when 'sourcing'  then n_src
                              when 'collected' then n_col
                              when 'packing'   then n_pkg
                              when 'packed'    then n_pkd else 0 end;
      v_ts := case r.stage_key when 'sourcing'  then t_src
                               when 'collected' then t_col
                               when 'packing'   then t_pkg
                               when 'packed'    then t_pkd end;
      -- Complete when every REMAINING line has reached it. An order whose
      -- every line was dropped is vacuously complete (there is nothing left to
      -- move); an order that has no lines at all is NOT — it has not started.
      v_full := case when v_tot > 0 then (v_n >= v_tot) else (v_dropped > 0) end;
      if not v_full then v_ts := null; end if;
    else
      v_ts := case r.stage_key when 'lead'             then t_lead
                               when 'placed'           then t_placed
                               when 'advance_paid'     then t_adv
                               when 'confirmed'        then t_conf
                               when 'processing'       then t_proc
                               when 'bill_sent'        then t_bill
                               when 'balance_paid'     then t_bal
                               when 'ready_dispatch'   then t_ready
                               when 'assigned'         then t_asg
                               when 'out_for_delivery' then t_ofd
                               when 'delivered'        then t_dlv end;
      v_full := (v_ts is not null);
    end if;
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'key', r.stage_key, 'label', r.label, 'scope', r.scope,
      'reached', coalesce(v_n, 0), 'total', coalesce(v_tot, 0),
      'ts', v_ts, 'full', v_full));
  end loop;

  v_len := jsonb_array_length(v_raw);

  -- Cumulative: the FURTHEST stage reached fills every dot behind it. A stage
  -- that never fired (no advance was asked for) can therefore not freeze the
  -- strip — the customer sees where the order actually is.
  for i in 0 .. v_len - 1 loop
    if (v_raw->i->>'full')::boolean then v_last_done := i; end if;
  end loop;
  v_cur := least(v_last_done + 1, v_len - 1);

  v_fmt := coalesce(nullif(public._c('orders.stage_count_fmt'),''), '{label} {n} of {total}');

  for i in 0 .. v_len - 1 loop
    v_e := v_raw->i;
    if v_cancelled then
      v_state := 'todo';
    elsif i <= v_last_done then
      v_state := 'done';
    elsif i = v_cur then
      v_state := 'current';
    else
      v_state := 'todo';
    end if;

    -- Partial progress. An every-item stage carries its count from the moment
    -- the order reaches it: "Packing 14 of 15" while it is mixed, and
    -- "Packing 14 of 14" once a dropped line has left the count and the stage
    -- completes on the fourteen. The sentence is written HERE, from a format
    -- string — never assembled in Dart, never pluralised in Dart.
    v_cnt := '';
    if v_state in ('current','done') and v_e->>'scope' = 'item'
       and (v_e->>'total')::int > 0 then
      v_cnt := replace(replace(replace(v_fmt,
                 '{label}', v_e->>'label'),
                 '{n}',     v_e->>'reached'),
                 '{total}', v_e->>'total');
    end if;

    v_stages := v_stages || jsonb_build_array(jsonb_build_object(
      'key',         v_e->>'key',
      'label',       v_e->>'label',
      'scope',       v_e->>'scope',
      'state',       v_state,
      'done',        (v_state = 'done'),
      'current',     (v_state = 'current'),
      'reached',     (v_e->>'reached')::int,
      'total',       (v_e->>'total')::int,
      'has_count',   (v_cnt <> ''),
      'count_label', v_cnt,
      'ts_label',    case when v_state = 'todo' then ''
                          else coalesce(public._ist_stamp(nullif(v_e->>'ts','')::timestamptz), '') end,
      'has_ts',      (v_state <> 'todo' and nullif(v_e->>'ts','') is not null)));

    if v_state = 'current' then
      v_cur_key := v_e->>'key';
      v_cur_label := v_e->>'label';
      v_caption := case when v_cnt <> '' then v_cnt else v_e->>'label' end;
    end if;
  end loop;

  -- The order is finished: the last stage is the one to name, and it is done.
  if v_cur_key = '' and v_len > 0 then
    v_cur_key   := v_raw->(v_len-1)->>'key';
    v_cur_label := v_raw->(v_len-1)->>'label';
    v_caption   := v_cur_label;
  end if;
  if v_cancelled then
    v_cur_key := 'cancelled'; v_cur_label := ''; v_caption := '';
  end if;

  -- A held line says so in words, and never names the supplier holding it.
  v_note := '';
  if v_disputed = 1 then
    v_note := coalesce(nullif(public._c('orders.stage_dispute_one'),''), '');
  elsif v_disputed > 1 then
    v_note := replace(coalesce(nullif(public._c('orders.stage_dispute_many'),''), ''),
                      '{n}', v_disputed::text);
  end if;

  return jsonb_build_object(
    'ok',             true,
    'origin',         v_origin,
    'heading',        coalesce(nullif(public._c('orders.stage_heading'),''), 'Order progress'),
    'stages',         v_stages,
    'stage_count',    v_len,
    'current_key',    v_cur_key,
    'current_index',  case when v_cancelled then -1 else v_cur end,
    'current_label',  v_cur_label,
    'caption',        coalesce(v_caption, ''),
    'remaining_total', v_total,
    'dropped_count',  v_dropped,
    'disputed_count', v_disputed,
    'has_dispute',    (v_disputed > 0),
    'dispute_note',   v_note,
    'is_cancelled',   v_cancelled,
    'is_delivered',   v_delivered,
    'is_active',      (not v_cancelled and not v_delivered));
end $fn$;

revoke all on function public._order_stage_engine(uuid) from public, anon, authenticated;

-- ── 3. Both customer views now read the ONE engine ──────────────────────────
-- The card's condensed strip. Its contract to my_orders_screen_v2
-- (is_active / is_delivered / is_cancelled, used for the three buckets) is
-- byte-for-byte what it was; `steps` is now the full stage list and the new
-- keys carry the partial-progress sentence.
create or replace function public._order_customer_stage(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare e jsonb; v_key text; v_label text;
begin
  e := public._order_stage_engine(p_order_id);
  if coalesce((e->>'ok')::boolean, false) is not true then return null; end if;

  if coalesce((e->>'is_cancelled')::boolean, false) then
    v_key := 'cancelled';
  elsif coalesce((e->>'is_delivered')::boolean, false) then
    v_key := 'delivered';
  else
    v_key := e->>'current_key';
  end if;
  -- A richer customer sentence for this stage when the copy table has one
  -- ("Sourcing · asking suppliers now"); otherwise the stage's own label.
  v_label := coalesce(nullif(public._c('orders.stage_' || v_key), ''),
                      nullif(e->>'current_label', ''), '');

  return jsonb_build_object(
    'key',           v_key,
    'label',         v_label,
    'index',         (e->>'current_index')::int,
    'is_active',     (e->>'is_active')::boolean,
    'is_delivered',  (e->>'is_delivered')::boolean,
    'is_cancelled',  (e->>'is_cancelled')::boolean,
    -- The strip stays on a delivered order: every dot green IS the answer.
    'show_progress', (not (e->>'is_cancelled')::boolean),
    'steps',         e->'stages',
    'heading',       e->>'heading',
    'caption',       e->>'caption',
    'current_label', e->>'current_label',
    'origin',        e->>'origin',
    'remaining_total', (e->>'remaining_total')::int,
    'dropped_count', (e->>'dropped_count')::int,
    'has_dispute',   (e->>'has_dispute')::boolean,
    'dispute_note',  e->>'dispute_note');
end $fn$;

-- The Track popup. Same engine, all stages, with the IST stamps.
-- CMD #1839 also RETIRES the customer event log: a buyer asking "where is my
-- order" is answered by the fifteen stages, not by an ops feed that had to be
-- filtered for supplier names in the first place. Operators keep theirs.
create or replace function public.order_timeline(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  o public.orders%rowtype; d public.deliveries%rowtype;
  cfg jsonb := coalesce((select value from public.app_settings where key='order_timeline_config'), '{}'::jsonb);
  e jsonb; v_eta text; v_eta_ts timestamptz;
  v_acc jsonb; v_access text; v_can_act boolean; v_events jsonb;
  v_is_customer boolean;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found');
  end if;
  select * into d from public.deliveries where order_id = p_order_id
   order by created_at desc limit 1;

  e := public._order_stage_engine(p_order_id);

  v_eta_ts := coalesce(d.promised_at, d.next_attempt_on::timestamptz);
  if d.delivered_at is not null then
    v_eta := public._ist_stamp(d.delivered_at);
  elsif v_eta_ts is not null then
    v_eta := public._ist_stamp(v_eta_ts);
  else
    v_eta := '';
  end if;

  v_acc     := public._otl_access(p_order_id);
  v_access  := coalesce(v_acc->>'access', 'none');
  v_can_act := coalesce((v_acc->>'can_act')::boolean, false);
  v_is_customer := (v_access = 'customer');
  v_events  := case when v_access in ('none','customer') then '[]'::jsonb
                    else public._order_timeline_events(p_order_id, v_access, v_can_act) end;

  return jsonb_build_object(
    'ok', true,
    'heading',      coalesce(nullif(e->>'heading',''), coalesce(cfg->>'heading','Order progress')),
    'current',      e->>'current_key',
    'current_index',(e->>'current_index')::int,
    'current_label',e->>'current_label',
    'caption',      e->>'caption',
    'steps',        e->'stages',
    'stage_count',  (e->>'stage_count')::int,
    'origin',       e->>'origin',
    'remaining_total', (e->>'remaining_total')::int,
    'dropped_count', (e->>'dropped_count')::int,
    'disputed_count',(e->>'disputed_count')::int,
    'has_dispute',  (e->>'has_dispute')::boolean,
    'dispute_note', e->>'dispute_note',
    'is_cancelled', (e->>'is_cancelled')::boolean,
    'is_delivered', (e->>'is_delivered')::boolean,
    'is_active',    (e->>'is_active')::boolean,
    'eta_label',    coalesce(cfg->>'eta_label','Expected delivery'),
    'eta_display',  coalesce(nullif(v_eta,''), coalesce(cfg->>'eta_unknown','')),
    'has_eta',      (nullif(v_eta,'') is not null),
    'proof', public._delivery_proof_block(p_order_id),
    'eta',   public._delivery_eta_for_order(p_order_id),
    'placed_label', coalesce(cfg->>'placed_label','Placed'),
    'placed_at_label', public._ist_stamp(o.created_at),
    'access',          v_access,
    'can_act',         v_can_act,
    'events',          v_events,
    'event_count',     jsonb_array_length(v_events),
    -- CMD #1839: the buyer is sent no event log and no privacy apology.
    'events_heading',  case when v_is_customer then ''
                            else public.uic('order_timeline.events_heading','Order timeline') end,
    'events_empty',    case when v_is_customer then ''
                            else public.uic('order_timeline.events_empty','') end,
    'privacy_note',    '');
end $fn$;

-- ── 4. The card carries the condensed strip's sentence ─────────────────────
-- `progress` grows the fields the strip prints under its dots: the caption
-- ("Packing 14 of 15" while mixed, the stage's own name otherwise) and the
-- re-sourcing note. Both are finished strings; the card adds no words.
CREATE OR REPLACE FUNCTION public._order_customer_card(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype;
  st jsonb; v_n int; v_amount numeric; v_amount_label text; v_billed boolean;
  v_paid boolean; v_awaiting boolean; v_act text; v_sit text;
  v_map jsonb := coalesce((select value from app_settings where key='orders_card_action_map'),
                          '{}'::jsonb);
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;
  st := public._order_customer_stage(p_order_id);

  select count(distinct oi.product_id) into v_n
    from public.order_items oi where oi.order_id = p_order_id;

  v_amount := coalesce(o.total_amount, 0);
  v_billed := (nullif(btrim(coalesce(o.invoice_no,'')),'') is not null)
              or (nullif(btrim(coalesce(o.cust_bill_path,'')),'') is not null);

  -- ₹0.00 was rendering as a price and reading like a bug. Zero is never a
  -- price here: on a live order it means the rate is not fixed yet, and on a
  -- finished one it means no bill was raised. Two facts, two sentences.
  if v_amount > 0 then
    v_amount_label := public.inr_money(v_amount);
  elsif coalesce((st->>'is_active')::boolean,false) and not v_billed then
    v_amount_label := public._c('orders.rate_on_confirmation');
  else
    v_amount_label := public._c('orders.not_billed');
  end if;

  select exists (select 1 from public.payment_claims c
                  where c.order_id = p_order_id
                    and lower(coalesce(c.status,'')) in ('verified','received'))
    into v_paid;
  v_awaiting := (v_amount > 0) and (not v_paid)
                and (v_billed or coalesce(o.dispatch_ready,false)
                     or coalesce((st->>'is_delivered')::boolean,false));

  -- WHICH action a card offers is DATA. The card works out the SITUATION —
  -- five facts, not five labels — and app_settings.orders_card_action_map says
  -- what each situation is worth tapping. Om changed this once already (a
  -- pre-inquiry Pending order offers the change window, not a tracker), and
  -- that change must never again be a deploy.
  if coalesce((st->>'is_cancelled')::boolean,false) then
    v_sit := 'cancelled';
  elsif v_awaiting then
    v_sit := 'awaiting_payment';
  elsif coalesce((st->>'is_active')::boolean,false) then
    v_sit := case when coalesce((public._order_change_gate(p_order_id)->>'open')::boolean,false)
                  then 'change_window_open' else 'active' end;
  else
    v_sit := 'finished';
  end if;
  v_act := coalesce(nullif(v_map->>v_sit,''), 'track');

  return jsonb_build_object(
    'id',              coalesce(o.id::text,''),
    'order_code',      coalesce(o.order_code,''),
    'placed_at',       coalesce(o.created_at::text,''),
    'date_label',      public._ist_stamp(o.created_at),
    'header_label',    coalesce(nullif(o.order_code,''), '') ,
    'item_count',      coalesce(v_n,0),
    'item_count_label',
      replace(case when coalesce(v_n,0) = 1 then public._c('orders.item_count_one')
                   else public._c('orders.item_count_many') end,
              '{n}', coalesce(v_n,0)::text),
    'amount',          v_amount,
    'amount_label',    v_amount_label,
    'amount_is_money', (v_amount > 0),
    'stage_key',       st->>'key',
    'stage_label',     st->>'label',
    'progress',        jsonb_build_object(
                          'show',  (st->>'show_progress')::boolean,
                          'index', (st->>'index')::int,
                          'steps', st->'steps',
                          'heading',       st->>'heading',
                          'caption',       st->>'caption',
                          'current_label', st->>'current_label',
                          'remaining_total', (st->>'remaining_total')::int,
                          'dropped_count', (st->>'dropped_count')::int,
                          'has_dispute',   (st->>'has_dispute')::boolean,
                          'dispute_note',  st->>'dispute_note'),
    'placed_by_admin', coalesce(o.placed_by_admin,false),
    'placed_by_admin_label', case when coalesce(o.placed_by_admin,false)
                                  then public._c('orders.placed_by_admin') else '' end,
    'unfulfilled_count', coalesce(o.unfulfilled_count,0),
    'primary_action',  jsonb_build_object(
                          'key',   v_act,
                          'label', public._c('orders.action_' || v_act),
                          'tone',  coalesce(nullif(v_map->'_tones'->>v_act,''),
                                            case v_act when 'reorder' then 'outline'
                                                       else 'brand' end)),
    -- CHANGE #691 (gap 122/126): the countdown on the card, and the proof
    -- once the order is closed. Both are finished strings.
    'eta',             public._delivery_eta_for_order(p_order_id),
    'proof',           public._delivery_proof_block(p_order_id),
    -- CHANGE #698 — the substitute ask lives ON the order card, because
    -- that is where the customer already is when an item falls out. The
    -- card carries the ask, its countdown sentence and, once it is over,
    -- the pair: what was ordered and what was supplied instead.
    'substitute',      public.substitute_ask_for_order(p_order_id),
    -- CHANGE #708 — the hold, from the one function every surface reads.
    'hold',            public.order_hold_state(p_order_id),
    'hold_sheet',      public.order_hold_sheet(p_order_id),
    'situation',       v_sit);
end $function$;


-- ── 5. LIVE — the stages move on screen without a refresh ───────────────────
-- CHANGE #643 put the live-vs-poll call in the backend, and it stays there.
-- These three tables are what a stage is made of, so they are marked live —
-- but `filter_required`, because an UNFILTERED binding on orders/order_items
-- is the fan-out that burned 95.9% of a 5M-message allowance. The Track popup
-- watches ONE order (id / order_id), so it binds live; the Orders list can only
-- narrow `orders` by customer, so its order_items and deliveries are polled.
-- Moving any of them back to poll is one UPDATE here — no deploy.
do $do$
declare t text;
begin
  foreach t in array array['orders','order_items','deliveries'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public'
                      and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $do$;

insert into public.realtime_table_registry
       (table_name, live, filter_required, poll_seconds, surface, reason) values
  ('orders',      true, true, 30, 'customer_orders',
   'CMD #1839 — the customer stage strip. Narrowed to one order (or one customer) or it polls.'),
  ('order_items', true, true, 30, 'customer_orders',
   'CMD #1839 — Collected / Packing / Packed tick off these rows. Live only when narrowed to one order.'),
  ('deliveries',  true, true, 20, 'customer_orders',
   'CMD #1839 — Assigned / Out for delivery / Delivered. Live only when narrowed to one order.')
on conflict (table_name) do nothing;

-- ── 6. Grant review ─────────────────────────────────────────────────────────
-- order_timeline() is a SIGNED-IN surface: the two admin screens call it
-- directly and customer_track_order() calls it as owner, so no anonymous
-- caller ever needed it. It was reachable as `anon` (returning a stage list for
-- any order id that was guessed) purely because nothing had revoked the default
-- PUBLIC grant. The public /track page uses its own token RPC and is untouched.
-- PUBLIC, not just anon: the default grant is what made it anonymous.
revoke execute on function public.order_timeline(uuid) from public, anon;
grant execute on function public.order_timeline(uuid) to authenticated, service_role;

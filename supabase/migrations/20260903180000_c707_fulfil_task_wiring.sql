-- CHANGE #707 (3/3) — the task stops being a form somebody fills in.
--
-- Four wirings, each of which removes a way the record could drift from what
-- actually happened on the floor:
--
--  1. THE ACTOR BINDS ITSELF. 24 RPCs already write an actor column on
--     order_items (collect_locked_by, received_by, pack_counted_by, packed_by).
--     Editing all 24 to also touch a task would have been 24 chances to forget,
--     and the 25th writer would forget for certain. A trigger on the columns
--     themselves cannot be forgotten: the moment a stage's actor column is
--     stamped, the matching open task starts, counts the item, and — if nobody
--     had assigned it — records the person who actually did the work.
--  2. AN UNOWNED STAGE AGES INTO AN EXCEPTION, on the console #690 already
--     draws, using the zone's own unassigned_alert_min.
--  3. THE OPS BOARD SAYS WHO. Every row already carries the stage and its
--     clock; it now carries the owner, because "late" and "nobody has it" are
--     the same problem read twice.
--  4. PRODUCTIVITY IS MEASURED, not typed: tasks closed, items an hour, count
--     variance and pack errors, all derived from rows that already exist.
--
-- Idempotent: create or replace, drop trigger if exists, on conflict do update.

-- ── 1. the actor binds itself ───────────────────────────────────────────────
-- WHICH STAGE a column feeds is data. The set of columns watched is the
-- trigger's WHEN clause, which is the one thing that cannot be a lookup.
create table if not exists public.fulfil_task_actor_map (
  column_name text primary key,
  stage_key   text not null,
  qty_column  text,
  is_active   boolean not null default true
);
alter table public.fulfil_task_actor_map enable row level security;
revoke all on public.fulfil_task_actor_map from anon, authenticated;

insert into public.fulfil_task_actor_map (column_name, stage_key, qty_column) values
  ('collect_locked_by', 'collect', 'shop_qty'),
  ('received_by',       'count',   'received_qty'),
  ('arrived_by',        'arrival', 'received_qty'),
  ('pack_counted_by',   'pack',    'pack_counted_qty'),
  ('packed_by',         'pack',    'packed_qty')
on conflict (column_name) do update
  set stage_key = excluded.stage_key, qty_column = excluded.qty_column, is_active = true;

-- One item's contribution to one stage's task.
create or replace function public._c707_touch(
  p_order uuid, p_stage text, p_zone smallint, p_actor text, p_qty numeric)
returns void
language plpgsql security definer set search_path to 'public' as $fn$
declare v_task bigint; v_worker bigint;
begin
  if p_order is null or p_stage is null then return; end if;

  select id into v_task from public.fulfil_task
   where order_id = p_order and stage_key = p_stage
     and supplier_key is null and done_at is null;
  if v_task is null then
    v_task := public._c707_ensure_task(p_order, p_stage, null, p_zone, null);
  end if;
  if v_task is null then return; end if;

  -- The person who did the work, if the roster knows them.
  select w.id into v_worker from public.partner_worker w
   where w.is_active and w.identity = public.identity_norm(p_actor) limit 1;

  update public.fulfil_task t
     set started_at    = coalesce(t.started_at, now()),
         -- An UNASSIGNED task adopts whoever actually did it. An ASSIGNED one
         -- is left alone: silently rewriting the assignment would erase the
         -- very fact the override path exists to record.
         worker_id     = coalesce(t.worker_id, v_worker),
         assigned_at   = case when t.worker_id is null and v_worker is not null
                              then coalesce(t.assigned_at, now()) else t.assigned_at end,
         assigned_by   = case when t.worker_id is null and v_worker is not null
                              then coalesce(t.assigned_by, 'actor') else t.assigned_by end,
         qty_handled   = coalesce(t.qty_handled,0) + coalesce(p_qty,0),
         items_touched = coalesce(t.items_touched,0) + 1,
         updated_at    = now()
   where t.id = v_task;
end $fn$;

create or replace function public._c707_bind_actor()
returns trigger
language plpgsql security definer set search_path to 'public' as $fn$
declare m record;
begin
  for m in select * from public.fulfil_task_actor_map where is_active loop
    if m.column_name = 'collect_locked_by'
       and NEW.collect_locked_by is not null
       and NEW.collect_locked_by is distinct from OLD.collect_locked_by then
      perform public._c707_touch(NEW.order_id, m.stage_key, NEW.zone_id,
                                 NEW.collect_locked_by, NEW.shop_qty);
    elsif m.column_name = 'received_by'
       and NEW.received_by is not null
       and NEW.received_by is distinct from OLD.received_by then
      perform public._c707_touch(NEW.order_id, m.stage_key, NEW.zone_id,
                                 NEW.received_by, NEW.received_qty);
    elsif m.column_name = 'arrived_by'
       and NEW.arrived_by is not null
       and NEW.arrived_by is distinct from OLD.arrived_by then
      perform public._c707_touch(NEW.order_id, m.stage_key, NEW.zone_id,
                                 NEW.arrived_by, NEW.received_qty);
    elsif m.column_name = 'pack_counted_by'
       and NEW.pack_counted_by is not null
       and NEW.pack_counted_by is distinct from OLD.pack_counted_by then
      perform public._c707_touch(NEW.order_id, m.stage_key, NEW.zone_id,
                                 NEW.pack_counted_by, NEW.pack_counted_qty);
    elsif m.column_name = 'packed_by'
       and NEW.packed_by is not null
       and NEW.packed_by is distinct from OLD.packed_by then
      perform public._c707_touch(NEW.order_id, m.stage_key, NEW.zone_id,
                                 NEW.packed_by, NEW.packed_qty);
    end if;
  end loop;
  return NEW;
exception when others then
  -- Counting a task must NEVER cost a warehouse worker their count. This is
  -- bookkeeping riding on someone else's write.
  return NEW;
end $fn$;

drop trigger if exists trg_c707_bind_actor on public.order_items;
create trigger trg_c707_bind_actor
after update of collect_locked_by, received_by, arrived_by, pack_counted_by, packed_by
on public.order_items
for each row
when (NEW.collect_locked_by is distinct from OLD.collect_locked_by
   or NEW.received_by       is distinct from OLD.received_by
   or NEW.arrived_by        is distinct from OLD.arrived_by
   or NEW.pack_counted_by   is distinct from OLD.pack_counted_by
   or NEW.packed_by         is distinct from OLD.packed_by)
execute function public._c707_bind_actor();

-- ── 2. an unowned stage ages into an exception ──────────────────────────────
create or replace function public._c707_unassigned_rows()
returns table(reason_code text, ref_id text, zone_id smallint, title text,
              subtitle text, since timestamp with time zone,
              supplier_key text, action_ref text)
language sql stable security definer set search_path to 'public' as $fn$
  select 'fulfil_task_unassigned'::text,
         t.id::text,
         t.zone_id,
         coalesce(nullif(o.order_code,''), t.order_id::text),
         coalesce(st.label, t.stage_key),
         t.created_at,
         null::text,
         t.order_id::text
    from public.fulfil_task t
    left join public.orders o    on o.id = t.order_id
    left join public.sla_stage st on st.stage_key = t.stage_key
    cross join lateral public._c707_cfg(t.zone_id) c
   where t.done_at is null
     and t.worker_id is null
     and t.created_at < now() - make_interval(mins => c.unassigned_alert_min)
$fn$;

-- ── 3. the ops board says who ───────────────────────────────────────────────
create or replace function public._c707_owner_block(p_order uuid, p_stage text)
returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'label', public.uic('ops_board.assignee_label','Owner'),
    'has',   (t.id is not null),
    'assigned', (t.worker_id is not null),
    'name',  case when t.worker_id is null then public.uic('ops_board.unassigned','Unassigned')
                  else coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity) end,
    'tone',  case when t.worker_id is null then 'warning' else 'success' end)
  from (select 1) z
  left join public.fulfil_task t
         on t.order_id = p_order and t.stage_key = p_stage
        and t.supplier_key is null and t.done_at is null
  left join public.partner_worker w on w.id = t.worker_id
  limit 1
$fn$;

-- ── 4. productivity, measured ───────────────────────────────────────────────
-- Every number here is derived from rows that already exist. items/hour is
-- items_touched over the time the worker actually held the task, not over the
-- length of the shift — a worker who was handed one task at 9am and closed it
-- at 9.10 did not work at 1/8th speed for the day.
create or replace function public.fulfil_worker_productivity(p_days integer default 1)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_partner bigint := public.my_partner_id(); v_from date; v_rows jsonb;
begin
  if not public._c707_can('read') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public._c('ft.not_authorized'), 'rows','[]'::jsonb);
  end if;
  v_from := ((now() at time zone 'Asia/Kolkata')::date) - (greatest(coalesce(p_days,1),1) - 1);

  select coalesce(jsonb_agg(jsonb_build_object(
           'worker_id',      x.worker_id,
           'name',           x.name,
           'tasks_done',     x.tasks_done,
           'tasks_open',     x.tasks_open,
           'open_label',     public._cf('ft.prod_open', jsonb_build_object('n', x.tasks_open::text)),
           'items',          x.items,
           'items_per_hour', case when x.held_hours > 0
                                  then to_char(x.items / x.held_hours, 'FM999990.0')
                                  else public._c('ft.prod_none') end,
           'variance_rate',  case when x.counted_lines > 0
                                  then to_char(100.0 * x.variance_lines / x.counted_lines, 'FM990.0') || '%'
                                  else public._c('ft.prod_none') end,
           'pack_errors',    x.pack_errors,
           'pack_errors_label', case when x.pack_errors = 0 then public._c('ft.prod_none')
                                     else x.pack_errors::text end)
         order by x.tasks_done desc, lower(x.name)), '[]'::jsonb)
    into v_rows
  from (
    select w.id as worker_id,
           coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity) as name,
           count(*) filter (where t.done_at is not null)::int                  as tasks_done,
           count(*) filter (where t.done_at is null)::int                      as tasks_open,
           coalesce(sum(t.items_touched), 0)::numeric                          as items,
           coalesce(sum(extract(epoch from (coalesce(t.done_at, now())
                       - coalesce(t.started_at, t.assigned_at, t.created_at)))) / 3600.0, 0)::numeric
                                                                                as held_hours,
           -- Count variance and pack errors are read off the ITEMS the worker
           -- actually stamped, not off the task: the dispute is raised against
           -- the line, so the line is where the truth is.
           (select count(*) from public.order_items oi
             where oi.received_by = w.identity
               and oi.received_at >= v_from)::numeric                          as counted_lines,
           (select count(*) from public.order_items oi
             where oi.received_by = w.identity
               and oi.received_at >= v_from
               and coalesce(oi.count_diff, 0) <> 0)::numeric                   as variance_lines,
           (select count(*) from public.order_items oi
             where oi.packed_by = w.identity
               and coalesce(oi.count_mismatch, false))::int                    as pack_errors
      from public.partner_worker w
      left join public.fulfil_task t
             on t.worker_id = w.id
            and (t.done_at is null
                 or (t.done_at at time zone 'Asia/Kolkata')::date >= v_from)
     where w.is_active and (v_partner is null or w.partner_id = v_partner)
     group by w.id, w.display_name, w.identity
  ) x;

  return jsonb_build_object(
    'ok', true,
    'title',          public._c('ft.workers_title'),
    'tasks_label',    public._c('ft.prod_tasks'),
    'items_label',    public._c('ft.prod_items'),
    'variance_label', public._c('ft.prod_variance'),
    'packerr_label',  public._c('ft.prod_packerr'),
    'days',           greatest(coalesce(p_days,1),1),
    'rows',           coalesce(v_rows,'[]'::jsonb));
end $fn$;

-- ── the two replacements ────────────────────────────────────────────────────
-- _exception_rows() gains one union arm; ops_board() gains one field. Both are
-- reproduced whole because that is what CREATE OR REPLACE means, and both are
-- byte-identical to the live definition apart from the block marked #707.

CREATE OR REPLACE FUNCTION public._exception_rows()
 RETURNS TABLE(reason_code text, ref_id text, zone_id smallint, title text, subtitle text, since timestamp with time zone, supplier_key text, action_ref text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- 1. Disputes nobody resolved.
  select 'dispute_open'::text, d.id::text, oi.zone_id,
         coalesce(nullif(d.product_name,''), '—'),
         coalesce(nullif(d.assigned_supplier,''), '—'),
         d.created_at,
         nullif(d.assigned_supplier,''),
         d.id::text
    from public.supplier_disputes d
    left join public.order_items oi on oi.id = d.order_item_id
   where d.resolved_at is null

  union all
  -- 2. Items no supplier could fill.
  select 'item_unfulfillable', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.unfulfillable_reason,''), '—'),
         coalesce(oi.unfulfillable_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.order_id::text
    from public.order_items oi
   where oi.unfulfillable is true

  union all
  -- 3. Shop count and warehouse recount disagree.
  select 'count_variance', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.assigned_supplier,''), '—'),
         coalesce(oi.received_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.id::text
    from public.order_items oi
   where oi.count_diff is not null
     and oi.count_diff <> 0
     and coalesce(oi.unfulfillable, false) = false

  union all
  -- CHANGE #702. The predicted promise breach, on the surface the partner
  -- already reads. It is a PREDICTION, so it appears the moment the model
  -- says the stop will be late — not after the promise has already passed.
  select 'eta_promise_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         coalesce(d.eta_breach_at, d.promised_at),
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.status in ('assigned','out_for_delivery')
     and d.promised_at is not null
     and d.eta_at is not null
     and d.eta_at > d.promised_at

  union all
  -- 4. WhatsApp sends the provider is refusing — the same blocking-fault
  --    filter the ops board already uses, so the two surfaces cannot disagree.
  select 'wa_send_failed', a.id::text,
         (select o.zone_id from public.orders o where o.id = a.order_id),
         coalesce(nullif(a.reason,''), '—'),
         coalesce(nullif(a.event_key,''), '—'),
         a.created_at,
         null,
         a.id::text
    from public.wa_send_attempts a
   where a.ok = false
     and a.created_at >= now() - interval '7 days'
     and coalesce(a.phone,'') not like '9000000%'
     and exists (select 1 from public.wa_send_fault_rule f
                  where f.enabled and f.is_blocking
                    and ((f.match_kind = 'exact' and a.reason = f.match_text)
                      or (f.match_kind = 'ilike' and a.reason ilike f.match_text)))

  union all
  -- 5. Stock follow-ups past their due date and still unanswered.
  select 'stock_followup_overdue', q.id::text, q.zone_id,
         coalesce(nullif(m.product_name,''), 'Product ' || q.product_id::text),
         coalesce(nullif(q.supplier_name,''), '—'),
         q.due_at,
         nullif(q.supplier_name,''),
         q.id::text
    from public.stock_update_queue q
    left join public."MEDICINE" m on m.id = q.product_id
   where q.resolved_at is null
     and q.due_at < now()

  union all
  -- 6. Payment claims nobody verified, once they are past the reason's SLA.
  select 'payment_claim_stuck', pc.id::text, pc.zone_id,
         coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text, 8)),
         coalesce(nullif(pc.payee_name,''), nullif(pc.sender_phone,''), '—'),
         coalesce(pc.paid_ts, pc.received_at, pc.created_at),
         null,
         pc.id::text
    from public.payment_claims pc
   where coalesce(pc.status,'') not in ('verified','rejected')
     and coalesce(pc.paid_ts, pc.received_at, pc.created_at)
         < now() - make_interval(hours =>
             (select r.sla_hours::int from public.exception_reason r
               where r.reason_code = 'payment_claim_stuck'))

  union all
  -- CHANGE #703. A rider anomaly is an ops item, so it belongs on the surface
  -- ops already reads. The row is the OPEN anomaly itself — it disappears from
  -- the console the moment the rule clears, without anyone closing it by hand.
  select 'rider_anomaly', a.id::text, a.zone_id,
         coalesce(nullif(r.full_name,''), 'Rider ' || left(coalesce(a.partner_id::text,'-'),8)),
         coalesce(nullif(k.label,''), a.kind),
         a.opened_at,
         null,
         coalesce(a.delivery_id::text, a.run_id::text)
    from public.delivery_anomaly a
    left join public.delivery_anomaly_kind k on k.kind = a.kind
    left join public.delivery_partner_registrations r on r.id = a.partner_id
   where a.cleared_at is null

  union all
  -- CHANGE #703. The rider reached the door and left again without completing.
  select 'missed_handover', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         d.missed_handover_at,
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.missed_handover_at is not null
     and d.status = 'out_for_delivery'

  union all
  -- CHANGE #703. A cold-chain stop past its allowed window, until it completes.
  select 'cold_chain_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         d.cold_breach_at,
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.cold_breach_at is not null
     and d.status in ('assigned','out_for_delivery')

  union all
  -- 7. Everything else on the ops board that is past its OWN class deadline.
  select 'sla_breach', b.class_key || '/' || b.item_id, b.zone_id,
         b.item_label,
         c.title || ' · ' || b.item_sub,
         b.since,
         null,
         b.class_key
    from (
      select 'orders_open'::text class_key, o.id::text item_id, o.zone_id,
             coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)) item_label,
             coalesce(nullif(o.pharmacy_name,''), '—') item_sub, o.created_at since
        from public.orders o where o.closed_at is null
      union all
      select 'supplier_unsettled', so.id::text, so.zone_id,
             coalesce(nullif(so.order_code,''), 'SO ' || left(so.id::text,8)),
             coalesce(nullif(so.supplier_name,''), '—'), so.created_at
        from public.supplier_orders so where so.settled_at is null
      union all
      select 'inquiry_pending', i.id::text, i.zone_id,
             coalesce(nullif(i.product_name,''), 'Inquiry ' || i.id::text),
             coalesce(nullif(i.current_status,''), '—'),
             coalesce(i.asked_at, i.created_at)
        from public.inquiry i where i.current_status = 'Confirmation Pending'
      union all
      select 'bills_pending', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Bill ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.status = 'pending'
      union all
      select 'bill_scan_error', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Scan ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.scan_status = 'error'
      union all
      select 'catalog_barcode_gap', bm.barcode_norm, null::smallint,
             coalesce(nullif(bm.sample_raw,''), bm.barcode_norm),
             bm.miss_count || case when bm.miss_count = 1 then ' scan' else ' scans' end
               || ', no product',
             bm.first_seen
        from public.catalog_barcode_miss bm
       where not exists (
               select 1 from public."MEDICINE" m
                where m.barcode is not null and btrim(m.barcode) <> ''
                  and public._norm_barcode(m.barcode) = bm.barcode_norm)
         and not exists (
               select 1 from public.product_barcode pb2
                where public._norm_barcode(pb2.barcode) = bm.barcode_norm)
    ) b
    join public.ops_board_class c
      on c.key = b.class_key and c.enabled
   where b.since < now() - make_interval(hours => c.sla_hours::int)

  union all
  -- CHANGE #704. The agency was given the stop and did not name a rider inside
  -- its response deadline, so mediBO took it back. The row stands while the
  -- stop is still open and disappears by itself when it completes — nobody
  -- closes it by hand.
  select 'agency_timeout', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(ag.full_name,''), '-'),
         d.agency_timeout_at,
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations ag on ag.id = d.agency_id
   where d.agency_timeout_at is not null
     and d.status not in ('delivered','rto','cancelled')

  union all
  -- CHANGE #707. A fulfil stage nobody owns, once it has aged past the zone's
  -- own unassigned_alert_min. The threshold is config rather than the reason's
  -- sla_hours because it is measured in MINUTES: a stage with no worker is a
  -- twenty-minute problem, not a four-hour one.
  select * from public._c707_unassigned_rows()
$function$;

CREATE OR REPLACE FUNCTION public.ops_board(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- CHANGE #707: the board already says WHAT is late and for how long.
      -- It now says WHO has it, because "overdue" and "nobody picked it up"
      -- are the same problem read twice.
      'owner',          public._c707_owner_block(t.order_id, t.stage_key),
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
end $function$;

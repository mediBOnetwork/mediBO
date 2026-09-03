-- CHANGE #696 (3/3) — the clock that runs by itself, the doors, and the feed.
--
-- Three things a ticket table does not give you on its own:
--   1. a nudge at HALF the promised time, on WhatsApp, to the side that owes
--      the answer — the point where a reminder still changes the outcome;
--   2. a breach that lands in the ops inbox every zone already reads, rather
--      than in a report nobody opens;
--   3. a closure that feeds the partner scorecard (#693) — which is the whole
--      reason closure requires an outcome code.
--
-- Plus the doors: a feature_registry row, a declared surface_route, the access
-- defaults (a NEW feature is seeded can_view=false for admin and partner, the
-- trap #713 fell into), and the nav badge.
--
-- Idempotent throughout.

-- ── the ops-inbox branch, as its own function ───────────────────────────────
-- Its own function, the way #707 and #713 added theirs, so the next command
-- that touches _exception_rows() adds a line rather than a paragraph.
-- A resumed worker (or a later change to _exception_rows()'s own column list)
-- must be able to re-shape this helper, and Postgres refuses to change a
-- function's OUT columns in place — so it is dropped first, deliberately.
drop function if exists public._c696_partner_ticket_rows();
create or replace function public._c696_partner_ticket_rows()
returns table(reason_code text, ref_id text, zone_id smallint, title text,
              subtitle text, since timestamptz, supplier_key text, action_ref text,
              stage_key text)
language sql stable security definer set search_path to 'public' as $$
  select 'partner_ticket_breach'::text,
         t.id::text,
         t.zone_id::smallint,
         coalesce(nullif(t.ref,''), 'Issue ' || left(t.id::text, 8)),
         coalesce(nullif(t.subject,''), '-'),
         t.sla_due_at,
         null::text,
         t.id::text,
         -- no fulfil stage owns an escalation: it is an office/partner item.
         null::text
    from public.partner_ticket t
   where t.status <> 'closed'
     and t.sla_due_at is not null
     and t.sla_due_at < now()
     and (select breach_ops_inbox from public.partner_ticket_config where id = 1);
$$;

-- === regenerated from the LIVE definitions, with one branch added ===

CREATE OR REPLACE FUNCTION public._exception_rows()
 RETURNS TABLE(reason_code text, ref_id text, zone_id smallint, title text, subtitle text, since timestamp with time zone, supplier_key text, action_ref text, stage_key text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- 0. CHANGE #709 — a worker breaking more than the threshold.
  select 'damage_rate_high'::text, 'worker:'||coalesce(d.worker_id::text,'-'),
         d.zone_id,
         coalesce(nullif(d.worker_label,''), '—'),
         public._cf('damage.rate_label',
           jsonb_build_object('pct', to_char(d.pct, 'FM990.9'))),
         d.last_at, null::text, coalesce(d.worker_id::text, '-'), null::text
    from (
      select h.worker_id,
             max(h.worker_label) as worker_label,
             max(h.zone_id) as zone_id,
             max(h.logged_at) as last_at,
             count(*)::int as n,
             round(100.0 * sum(h.qty)
                   / nullif(coalesce((select sum(t.qty_handled) from public.fulfil_task t
                                       where t.worker_id = h.worker_id
                                         and t.assigned_at >= now() - make_interval(days =>
                                             coalesce((select (value->>'window_days')::int
                                                         from public.app_settings
                                                        where key='handling_damage'), 30))), 0), 0), 1) as pct
        from public.handling_damage h
       where h.status = 'confirmed'
         and h.worker_id is not null
         and h.logged_at >= now() - make_interval(days =>
               coalesce((select (value->>'window_days')::int from public.app_settings
                          where key='handling_damage'), 30))
       group by h.worker_id) d
   where d.pct is not null
     and d.n >= coalesce((select (value->>'min_events')::int from public.app_settings
                           where key='handling_damage'), 3)
     and d.pct >= coalesce((select (value->>'rate_threshold_pct')::numeric
                              from public.app_settings where key='handling_damage'), 2.0)

  union all
  -- 1. Disputes nobody resolved.
  select 'dispute_open'::text, d.id::text, oi.zone_id,
         coalesce(nullif(d.product_name,''), '—'),
         coalesce(nullif(d.assigned_supplier,''), '—'),
         d.created_at, nullif(d.assigned_supplier,''), d.id::text, null::text
    from public.supplier_disputes d
    left join public.order_items oi on oi.id = d.order_item_id
   where d.resolved_at is null

  union all
  -- 2. Items no supplier could fill.
  select 'item_unfulfillable', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.unfulfillable_reason,''), '—'),
         coalesce(oi.unfulfillable_at, oi.created_at),
         nullif(oi.assigned_supplier,''), oi.order_id::text, 'inquiry'::text
    from public.order_items oi
   where oi.unfulfillable is true

  union all
  -- 3. Shop count and warehouse recount disagree.
  select 'count_variance', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.assigned_supplier,''), '—'),
         coalesce(oi.received_at, oi.created_at),
         nullif(oi.assigned_supplier,''), oi.id::text, 'count'::text
    from public.order_items oi
   where oi.count_diff is not null
     and oi.count_diff <> 0
     and coalesce(oi.unfulfillable, false) = false

  union all
  -- CHANGE #702. The predicted promise breach.
  select 'eta_promise_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         coalesce(d.eta_breach_at, d.promised_at),
         null, d.order_id::text, 'delivered'::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.status in ('assigned','out_for_delivery')
     and d.promised_at is not null
     and d.eta_at is not null
     and d.eta_at > d.promised_at

  union all
  -- 4. WhatsApp sends the provider is refusing.
  select 'wa_send_failed', a.id::text,
         (select o.zone_id from public.orders o where o.id = a.order_id),
         coalesce(nullif(a.reason,''), '—'),
         coalesce(nullif(a.event_key,''), '—'),
         a.created_at, null, a.id::text, null::text
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
         q.due_at, nullif(q.supplier_name,''), q.id::text, 'collect'::text
    from public.stock_update_queue q
    left join public."MEDICINE" m on m.id = q.product_id
   where q.resolved_at is null
     and q.due_at < now()

  union all
  -- 6. Payment claims nobody verified.
  select 'payment_claim_stuck', pc.id::text, pc.zone_id,
         coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text, 8)),
         coalesce(nullif(pc.payee_name,''), nullif(pc.sender_phone,''), '—'),
         coalesce(pc.paid_ts, pc.received_at, pc.created_at),
         null, pc.id::text, null::text
    from public.payment_claims pc
   where coalesce(pc.status,'') not in ('verified','rejected')
     and coalesce(pc.paid_ts, pc.received_at, pc.created_at)
         < now() - make_interval(hours =>
             (select r.sla_hours::int from public.exception_reason r
               where r.reason_code = 'payment_claim_stuck'))

  union all
  -- CHANGE #703. Rider anomalies.
  select 'rider_anomaly', a.id::text, a.zone_id,
         coalesce(nullif(r.full_name,''), 'Rider ' || left(coalesce(a.partner_id::text,'-'),8)),
         coalesce(nullif(k.label,''), a.kind),
         a.opened_at, null, coalesce(a.delivery_id::text, a.run_id::text), 'delivered'::text
    from public.delivery_anomaly a
    left join public.delivery_anomaly_kind k on k.kind = a.kind
    left join public.delivery_partner_registrations r on r.id = a.partner_id
   where a.cleared_at is null

  union all
  select 'missed_handover', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         d.missed_handover_at, null, d.order_id::text, 'delivered'::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.missed_handover_at is not null
     and d.status = 'out_for_delivery'

  union all
  select 'cold_chain_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         d.cold_breach_at, null, d.order_id::text, 'delivered'::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.cold_breach_at is not null
     and d.status in ('assigned','out_for_delivery')

  union all
  -- 7. Everything else on the ops board past its OWN class deadline.
  select 'sla_breach', b.class_key || '/' || b.item_id, b.zone_id,
         b.item_label, c.title || ' · ' || b.item_sub,
         b.since, null, b.class_key, null::text
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
  -- CHANGE #704. The agency never named a rider.
  select 'agency_timeout', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(ag.full_name,''), '-'),
         d.agency_timeout_at, null, d.order_id::text, 'dispatch'::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations ag on ag.id = d.agency_id
   where d.agency_timeout_at is not null
     and d.status not in ('delivered','rto','cancelled')

  union all
  -- CHANGE #707. A fulfil stage nobody owns.
  select *, 'count'::text from public._c707_unassigned_rows()

  union all
  -- CHANGE #713. A customer message past its SLA, and a call nobody made.
  select *, null::text from public._c713_thread_sla_rows()

  union all
  -- CHANGE #470 · A. THE HEADLINE: an order that stopped moving. The deadline
  -- is sla_config in MINUTES for that stage (zone row first, else the ALL row),
  -- so the queue and the ops board can never disagree about what "late" means.
  select 'order_stage_stalled', c.order_id::text || ':' || c.stage_key, c.zone_id,
         coalesce(nullif(c.order_code,''), 'Order ' || left(c.order_id::text,8)),
         st.label || ' · ' || coalesce(nullif(c.customer,''), '—'),
         coalesce(h.entered_at, c.since, c.created_at),
         null,
         'stage:' || c.stage_key,
         c.stage_key
    from public._ops_order_stage(null) c
    join public.sla_stage st on st.stage_key = c.stage_key and st.is_active
    left join public.order_stage_history h
           on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
    join lateral (
      select f.sla_minutes from public.sla_config f
       where f.stage_key = c.stage_key and f.is_active
         and (f.zone_id = c.zone_id or f.zone_id is null)
       order by (f.zone_id is null) limit 1) cfg on true
   where now() - coalesce(h.entered_at, c.since, c.created_at)
         > make_interval(mins => cfg.sla_minutes)

  union all
  -- CHANGE #470 · B. A bill the renderer never produced. Either the job is
  -- still not done past its SLA, or it says done and there is no artifact —
  -- both are a customer with no bill, which is the only thing that matters.
  select 'bill_unrendered', j.id::text,
         (select o.zone_id from public.orders o where o.id = j.order_id),
         coalesce(nullif(j.bill_name,''),
                  (select nullif(o.order_code,'') from public.orders o where o.id = j.order_id),
                  'Bill ' || left(j.id::text,8)),
         coalesce(nullif(j.last_error,''), j.status),
         coalesce(j.started_at, j.created_at),
         null, j.id::text, null::text
    from public.bill_jobs j
   where j.rendered_at is null
     and coalesce(j.status,'') <> 'cancelled'

  union all
  -- CHANGE #470 · C. A failed stop waiting on a reattempt. It stands while the
  -- delivery has not moved on, and disappears the moment it does.
  select 'delivery_reattempt_due', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(d.fail_reason,''), nullif(d.reattempt_window_label,''), '—'),
         coalesce(d.next_attempt_on::timestamptz, d.created_at),
         null, d.order_id::text, 'delivered'::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
   where lower(coalesce(d.status,'')) in ('failed','undelivered','reattempt')
     and d.next_attempt_on is not null
     and d.next_attempt_on <= (now() at time zone 'Asia/Kolkata')::date

  union all
  -- CHANGE #470 · D. A settlement period the partner never acknowledged. The
  -- clock starts when the period closed, not when it was computed.
  select 'settlement_unacked', p.id::text, p.zone_id,
         coalesce(nullif(rp.partner_name,''), 'Partner ' || p.partner_id::text),
         to_char(p.period_start,'DD Mon') || ' – ' || to_char(p.period_end,'DD Mon YYYY'),
         coalesce(p.closed_at, p.computed_at),
         null, p.id::text, null::text
    from public.partner_settlement_periods p
    left join public.region_partners rp on rp.id = p.partner_id
    left join public.partner_settlement_ack a
           on a.period_id = p.id and a.resolved_at is null
   where coalesce(p.closed_at, p.computed_at) is not null
     and coalesce(p.status,'') not in ('draft','cancelled')
     and (a.period_id is null or coalesce(a.state,'') not in ('accepted','acknowledged'))

  union all
  -- CHANGE #470 · E. What the state machine itself found. An impossible state
  -- is never a judgement call, so it is never closed by hand — the sweep that
  -- raised it is the sweep that clears it.
  select 'impossible_state', f.id::text, f.zone_id,
         coalesce(nullif(f.label,''), r.label),
         coalesce(nullif(f.detail,''), r.detail),
         f.found_at, null, 'rule:' || f.rule_key, null::text
    from public.ops_state_finding f
    join public.ops_state_rule r on r.rule_key = f.rule_key and r.enabled
   where f.cleared_at is null
  union all
  -- CHANGE #696. A partner issue whose promised answer has not arrived. It is
  -- derived from live state, so it leaves the console the moment somebody
  -- answers or closes it -- there is nothing here to tidy up by hand.
  select * from public._c696_partner_ticket_rows()
$function$;

CREATE OR REPLACE FUNCTION public._partner_metric_values(p_partner bigint, p_month date)
 RETURNS TABLE(metric text, value numeric, sample_n integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from date := date_trunc('month', p_month)::date;
  v_to   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  cfg    public.partner_scorecard_config%rowtype;
  v_zone smallint;
  v_lines int;
begin
  select * into cfg from public.partner_scorecard_config where id = 1;
  select r.zone_id::smallint into v_zone from public.region_partners r where r.id = p_partner;

  select count(*)::int into v_lines
    from public.order_items i
    join public.orders o on o.id = i.order_id
   where o.fulfillment_partner_id = p_partner
     and o.order_date between v_from and v_to
     and coalesce(o.is_synthetic,false) = false;

  -- 1. inquiry -> pack, in hours.
  return query
    select 'inquiry_to_pack_h'::text,
           round(avg(extract(epoch from (o.dispatch_ready_at - o.created_at)) / 3600.0)::numeric, 2),
           count(*)::int
      from public.orders o
     where o.fulfillment_partner_id = p_partner
       and o.order_date between v_from and v_to
       and coalesce(o.is_synthetic,false) = false
       and o.dispatch_ready_at is not null and o.created_at is not null
       and o.dispatch_ready_at >= o.created_at
    having count(*) > 0;

  -- 2. on-time dispatch %, against the dispatch SLA in partner_scorecard_config.
  return query
    select 'on_time_dispatch_pct'::text,
           round(100.0 * count(*) filter (
             where o.dispatch_ready_at <= o.created_at + make_interval(hours => cfg.dispatch_sla_hours::int))
                 / nullif(count(*),0)::numeric, 2),
           count(*)::int
      from public.orders o
     where o.fulfillment_partner_id = p_partner
       and o.order_date between v_from and v_to
       and coalesce(o.is_synthetic,false) = false
       and o.dispatch_ready_at is not null and o.created_at is not null
    having count(*) > 0;

  -- 3. count-dispute rate: ordered lines that raised a short / wrong-product
  --    dispute, over every ordered line in the month.
  if v_lines > 0 then
    return query
      select 'count_dispute_rate_pct'::text,
             round(100.0 * (
               select count(distinct d.order_item_id)
                 from public.supplier_disputes d
                 join public.order_items i2 on i2.id = d.order_item_id
                 join public.orders o2 on o2.id = i2.order_id
                where o2.fulfillment_partner_id = p_partner
                  and o2.order_date between v_from and v_to
                  and coalesce(o2.is_synthetic,false) = false
             )::numeric / v_lines::numeric, 2),
             v_lines;
  end if;

  -- 4. unfulfilled rate: lines no supplier in the zone could fulfil.
  if v_lines > 0 then
    return query
      select 'unfulfilled_rate_pct'::text,
             round(100.0 * (
               select coalesce(sum(coalesce(o3.unfulfilled_count,0)),0)
                 from public.orders o3
                where o3.fulfillment_partner_id = p_partner
                  and o3.order_date between v_from and v_to
                  and coalesce(o3.is_synthetic,false) = false
             )::numeric / v_lines::numeric, 2),
             v_lines;
  end if;

  -- 5. delivery SLA: handed over inside the promised window.
  return query
    select 'delivery_sla_pct'::text,
           round(100.0 * count(*) filter (where d.delivered_at <= d.promised_at)
                 / nullif(count(*),0)::numeric, 2),
           count(*)::int
      from public.deliveries d
      join public.orders o4 on o4.id = d.order_id
     where o4.fulfillment_partner_id = p_partner
       and o4.order_date between v_from and v_to
       and coalesce(o4.is_synthetic,false) = false
       and coalesce(d.is_synthetic,false) = false
       and d.delivered_at is not null and d.promised_at is not null
    having count(*) > 0;

  -- 6. settlement acknowledgement time, in hours, for statements that CLOSED
  --    inside the month.
  return query
    select 'settlement_ack_h'::text,
           round(avg(extract(epoch from (a.acked_at - p.closed_at)) / 3600.0)::numeric, 2),
           count(*)::int
      from public.partner_settlement_periods p
      join public.partner_settlement_ack a on a.period_id = p.id
     where p.partner_id = p_partner
       and p.closed_at is not null
       and (p.closed_at at time zone 'Asia/Kolkata')::date between v_from and v_to
       and a.acked_at >= p.closed_at
    having count(*) > 0;

  -- 7. exceptions closed inside the exception SLA, for the partner's zone.
  if v_zone is not null then
    return query
      select 'exception_sla_pct'::text,
             round(100.0 * count(*) filter (
               where e.closed_at <= coalesce(e.started_at, e.created_at)
                                    + make_interval(hours => cfg.exception_sla_hours::int))
                   / nullif(count(*),0)::numeric, 2),
             count(*)::int
        from public.exception_state e
       where e.zone_id = v_zone
         and e.closed_at is not null
         and (e.closed_at at time zone 'Asia/Kolkata')::date between v_from and v_to
      having count(*) > 0;
  end if;

  -- 8. CHANGE #696 -- issues closed inside the promised time. Every partner
  --    ticket, both directions, CLOSED inside the month: the share whose
  --    closure landed before the SLA its category promised. An outcome the
  --    office recorded as the partner's fault counts against it even when it
  --    closed in time, which is why the fault side is read here and not only
  --    the clock.
  return query
    select 'issue_sla_pct'::text,
           round(100.0 * count(*) filter (
             where t.closed_at <= t.sla_due_at
               and coalesce(o.fault_side,'none') <> 'partner')
                 / nullif(count(*),0)::numeric, 2),
           count(*)::int
      from public.partner_ticket t
      left join public.partner_ticket_outcome o on o.code = t.outcome_code
     where t.partner_id = p_partner
       and t.closed_at is not null
       and t.sla_due_at is not null
       and (t.closed_at at time zone 'Asia/Kolkata')::date between v_from and v_to
    having count(*) > 0;
end $function$;

CREATE OR REPLACE FUNCTION public.nav_badge_counts()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'pending_orders',     (select count(*) from orders where status = 'pending'),
    'flagged_bills',      (select count(*) from pending_bills where verdict in ('needs_approval','fake')),
    'pending_customers',  (select count(*) from pharmacy_profiles where coalesce(approved,false) = false),
    'deletion_requests',  (select count(*) from account_deletion_requests where status = 'pending'),
    'order_alerts',       (select count(*) from order_alert where actioned_at is null),
    'disputes',           (select count(*) from supplier_disputes where coalesce(status,'open') = 'open'),
    'contact_inquiries',  (select count(*) from contact_inquiries),
    -- CHANGE #713 — customer messages waiting on an answer, in the caller's
    -- own zone (all zones for the office). The count is the same clamp the
    -- inbox uses, so the badge can never promise work the screen then hides.
    'customer_threads',   public._thread_badge_count(),
    -- CHANGE #696 -- partner issues waiting on the caller's OWN side: a
    -- partner sees the ones the office handed back to them, the office
    -- sees every partner's. Same clamp as partner_ticket_list(), so the
    -- badge can never promise work the screen then hides.
    'partner_issues',     public._pt_badge_count()
  );
$function$;

-- ── the tick ────────────────────────────────────────────────────────────────
-- Two moments, one pass: the nudge at half the promised time, and the breach
-- when it runs out. Both are recorded IN the timeline, so neither side has to
-- take our word for when we said something.
create or replace function public.partner_ticket_sla_tick(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r record; v_cfg public.partner_ticket_config;
  v_nudged int := 0; v_breached int := 0; v_admin uuid;
  v_lim int := greatest(least(coalesce(p_limit,20),100),1);
begin
  select * into v_cfg from public.partner_ticket_config where id = 1;

  -- 1. Half the promised time has gone and the owner has not answered.
  if v_cfg.nudge_enabled then
    for r in
      select t.*, rp.partner_name
        from public.partner_ticket t
        left join public.region_partners rp on rp.id = t.partner_id
       where t.status in ('open','waiting')
         and t.nudged_at is null
         and t.nudge_due_at is not null
         and t.nudge_due_at < now()
       order by t.nudge_due_at
       limit v_lim
    loop
      update public.partner_ticket set nudged_at = now(), updated_at = now() where id = r.id;

      insert into public.partner_ticket_message (ticket_id, body, actor_side, actor_label, kind)
      values (r.id, public._c('pt.system_nudge'), 'system', public._c('pt.side.system'), 'system');

      begin
        if r.owner_side = 'partner' then
          perform public.notify_partner('partner_issue_nudge', jsonb_build_object(
            'partner_id', r.partner_id::text, 'zone_id', coalesce(r.zone_id,0)::text,
            'ref', coalesce(r.ref,''), 'subject', coalesce(r.subject,''),
            'due', public._ist_stamp(r.sla_due_at)));
        else
          perform public.notify('partner_issue_nudge', null, jsonb_build_object(
            'partner_id', r.partner_id::text, 'zone_id', coalesce(r.zone_id,0)::text,
            'ref', coalesce(r.ref,''), 'subject', coalesce(r.subject,''),
            'partner', coalesce(r.partner_name,''),
            'due', public._ist_stamp(r.sla_due_at)));
        end if;
      exception when others then null;
      end;
      v_nudged := v_nudged + 1;
    end loop;
  end if;

  -- 2. The promised time has passed. The ops inbox row is DERIVED (see
  --    _c696_partner_ticket_rows), so this branch records the moment, tells
  --    both sides, and never has to be undone.
  for r in
    select t.*, rp.partner_name
      from public.partner_ticket t
      left join public.region_partners rp on rp.id = t.partner_id
     where t.status <> 'closed'
       and t.breached_at is null
       and t.sla_due_at is not null
       and t.sla_due_at < now()
     order by t.sla_due_at
     limit v_lim
  loop
    update public.partner_ticket set breached_at = now(), updated_at = now() where id = r.id;

    insert into public.partner_ticket_message (ticket_id, body, actor_side, actor_label, kind)
    values (r.id, public._c('pt.system_breach'), 'system', public._c('pt.side.system'), 'system');

    -- The office, on the channel that lands today. Same shape as #713: push
    -- needs no Meta template, WhatsApp follows when the template lands.
    for v_admin in
      select distinct u.id
        from public.admins a
        join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
       where exists (select 1 from public.push_tokens k
                      where k.is_active and k.user_id = u.id)
    loop
      begin
        perform public.notif_push_send('partner_issue_breach', null, v_admin, null,
          jsonb_build_object('ref', coalesce(r.ref,''), 'subject', coalesce(r.subject,''),
            'partner', coalesce(r.partner_name,''),
            'zone_id', coalesce(r.zone_id,0)::text,
            'age', public._ist_age(r.sla_due_at)), 'admin');
      exception when others then null;
      end;
    end loop;

    begin
      perform public.notify('partner_issue_breach', null, jsonb_build_object(
        'ref', coalesce(r.ref,''), 'subject', coalesce(r.subject,''),
        'partner', coalesce(r.partner_name,''),
        'zone_id', coalesce(r.zone_id,0)::text,
        'age', public._ist_age(r.sla_due_at)));
    exception when others then null;
    end;

    if r.owner_side = 'partner' then
      begin
        perform public.notify_partner('partner_issue_breach', jsonb_build_object(
          'partner_id', r.partner_id::text, 'zone_id', coalesce(r.zone_id,0)::text,
          'ref', coalesce(r.ref,''), 'subject', coalesce(r.subject,''),
          'age', public._ist_age(r.sla_due_at)));
      exception when others then null;
      end;
    end if;

    v_breached := v_breached + 1;
  end loop;

  return jsonb_build_object('ok', true, 'nudged', v_nudged, 'breached', v_breached);
end $$;

revoke all on function public.partner_ticket_sla_tick(integer) from public;
grant execute on function public.partner_ticket_sla_tick(integer) to service_role;

-- ── the dispatcher row — gated, and never on a bare */N (#273) ──────────────
insert into public.cron_task (name, ord, mode, gate_sql, work_sql,
                              base_interval_s, max_interval_s, note, enabled)
values ('c696-partner-ticket-sla', 76, 'poll',
        'select exists (select 1 from public.partner_ticket where status <> ''closed'' '
          'and ((nudged_at is null and nudge_due_at < now()) '
          'or (breached_at is null and sla_due_at < now())))',
        'select public.partner_ticket_sla_tick(20)',
        120, 900,
        'CHANGE #696 - a partner issue nudges the owning side on WhatsApp at '
        'half the promised time and lands in the ops inbox when it passes.',
        true)
on conflict (name) do update
  set mode = excluded.mode, gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      note = excluded.note, enabled = true;

-- ── the channels ────────────────────────────────────────────────────────────
insert into public.notification_settings (audience, action_key, label, enabled, sort, channel)
values ('partner', 'partner_issue_raised', 'Partner - issue raised by mediBO', true, 60, 'all'),
       ('partner', 'partner_issue_nudge',  'Partner - issue reply due soon',   true, 61, 'all'),
       ('partner', 'partner_issue_breach', 'Partner - issue overdue',          true, 62, 'all'),
       ('admin',   'partner_issue_raised', 'Partner raised an issue',          true, 60, 'all'),
       ('admin',   'partner_issue_nudge',  'Partner issue reply due soon',     true, 61, 'all'),
       ('admin',   'partner_issue_breach', 'Partner issue overdue',            true, 62, 'all')
on conflict (audience, action_key, channel) where user_id is null
do update set label = excluded.label, enabled = true;

-- ── the scorecard metric (#693) ─────────────────────────────────────────────
-- A metric is DATA plus a branch in _partner_metric_values(); both are here.
insert into public.partner_scorecard_metric
  (slug, label, hint, value_suffix, direction, default_target, decimals, sort_order)
values
  ('issue_sla_pct', 'Issues answered in time',
   'Share of escalation issues closed inside the promised time, and not closed against the partner.',
   '%', 'higher_better', 90, 1, 80)
on conflict (slug) do update set
  label = excluded.label, hint = excluded.hint,
  value_suffix = excluded.value_suffix, direction = excluded.direction,
  default_target = excluded.default_target, decimals = excluded.decimals,
  sort_order = excluded.sort_order, active = true;

-- ── the door, DECLARED (#570 / #821) ───────────────────────────────────────
--
-- Found before deploy by asking nav_registry() as each role instead of assuming:
-- the registry row was copied from #713's partner.order_threads, and that row
-- appears on NOBODY's dashboard. nav_registry() has two branches and the copied
-- row satisfies neither:
--   * the office branch takes only `feature_key like 'admin.%'` — a key in the
--     `partner.` namespace is filtered out however the grants read;
--   * the partner branch takes only a row whose roles_allowed CONTAINS
--     'partner' — and the copied row allowed {admin,super_admin}.
-- So the feature had a working backend, a declared route and no way in. That is
-- the exact "no orphans either way" failure §11 exists for.
--
-- The shape that works is admin.feedback's (#697/#821): ONE row, in the admin
-- namespace, with 'partner' in roles_allowed and partner_eligible — the office
-- branch takes it on the namespace, the partner branch on the role, and the
-- per-partner grant still decides what a partner may do.

-- The wrong key, retired. It never shipped: it was created minutes ago in this
-- same command and no grant, pin or usage row can predate it.
delete from public.surface_route where feature_key = 'partner.issues';
delete from public.access_role_default where feature_key = 'partner.issues';
delete from public.feature_registry where feature_key = 'partner.issues';

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('partner_issues', 'admin.partner_issues', 'feature', 'home_shell',
   'CHANGE #696 - the mediBO <-> partner escalation channel. Opened by '
   'shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart. '
   'partner_ticket_list() answers a partner with their OWN issues and the '
   'office with every zone, and refuses anyone who is neither, so the door is '
   'not the guard.',
   true)
on conflict (route_key, feature_key) do update
   set kind = excluded.kind, handled_by = excluded.handled_by,
       note = excluded.note, is_active = excluded.is_active, updated_at = now();

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, deep_link, search_terms, description,
   partner_feature_key, canonical_key, badge_source, badge_noun)
values
  ('admin.partner_issues', 'Partner issues', 'Support', 'support_agent',
   'partner_issues', 8, 'partner', true, 'write', true, 'orders', 'dashboard',
   '{admin,super_admin,partner}', '/admin/go/partner_issues',
   'issue ticket escalation partner complaint sla breach settlement query count dispute app bug raise',
   'Issues between mediBO and a zone partner - raised either way, with an SLA clock, a timeline and a closing outcome.',
   'admin.partner_issues', 'admin.partner_issues',
   'partner_issues', 'issues waiting')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      route_key = excluded.route_key, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, owner = excluded.owner,
      partner_eligible = excluded.partner_eligible,
      default_access = excluded.default_access, is_active = true,
      category = excluded.category, surface = excluded.surface,
      roles_allowed = excluded.roles_allowed, deep_link = excluded.deep_link,
      search_terms = excluded.search_terms, description = excluded.description,
      badge_source = excluded.badge_source, badge_noun = excluded.badge_noun;

-- A NEW feature_registry row is seeded can_view=false for admin and partner
-- (#713 shipped a declared door nobody but the office could open). Write for
-- all three: raising, replying and closing are the whole feature, and what a
-- partner may see is still clamped by partner_ticket_list() to their own zone.
insert into public.access_role_default (role, feature_key, can_view, can_write)
values
  ('admin',       'admin.partner_issues', true, true),
  ('partner',     'admin.partner_issues', true, true),
  ('super_admin', 'admin.partner_issues', true, true)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write,
      updated_at = now();

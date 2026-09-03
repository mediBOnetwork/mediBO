-- CHANGE #470 — _exception_rows() v2.
--
-- Adds a trailing `stage_key` output and the five sources #690 did not cover.
-- The column is appended, never re-ordered, so every existing caller
-- (_dashboard_ops_build, exception_digest_line, _exception_writable, the
-- journey proofs) keeps compiling against the names it already reads.

drop function if exists public._exception_rows();

create or replace function public._exception_rows()
returns table(reason_code text, ref_id text, zone_id smallint, title text,
              subtitle text, since timestamptz, supplier_key text,
              action_ref text, stage_key text)
language sql stable security definer set search_path to 'public' as $function$
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
     -- 'due' is the only status that means "closed and waiting on the partner":
     -- 'open' is still accruing and 'settled' is already paid.
     and coalesce(p.status,'') = 'due'
     and p.settled_at is null
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
$function$;

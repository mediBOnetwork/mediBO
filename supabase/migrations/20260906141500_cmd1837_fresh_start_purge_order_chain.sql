-- CMD #1837 — FRESH START: delete transaction ROWS ONLY.
--
-- Om tested mediBO with real orders before test mode existed. This file wipes
-- the order chain so the app starts from zero, and changes NOTHING structural:
-- no table, column, index, constraint, function, RPC, trigger or policy is
-- touched, and no master data is deleted (MEDICINE and prices, company maps,
-- pharmacy_profiles, supplier_profiles, admins, partner/region rows, rider
-- registrations, zones, khata ACCOUNTS, templates, ui_copy, settings, feature
-- registry, cron tasks all stay exactly as they are).
--
-- The 121 tables below are the FULL foreign-key closure of the order chain,
-- computed from pg_constraint, not from a hand-written guess. Two facts were
-- proven before this file was written:
--   * nothing OUTSIDE the set references anything INSIDE it, so the set can be
--     emptied without orphaning any surviving row;
--   * the order below is a valid topological order — for every FK edge in the
--     schema the child is deleted before its parent (asserted table by table).
-- The one exception is the refunds <-> order_cancellations cycle (and
-- settlement_invoice's self-reference): those are broken by NULLing the
-- nullable side first. No constraint is dropped, disabled or deferred.
--
-- Everything runs in ONE transaction: it all lands or none of it does.
-- Idempotent by construction — a second run deletes 0 rows.
--
-- Backup taken before this ran:
--   db-backups/cmd-1837/pre-purge-20260906-135344.sql.gz
--   (data-only pg_dump of every relation named here, 720,038 bytes,
--    round-trip downloaded and gunzip -t verified)

BEGIN;

DO $cmd1837$
DECLARE
  v_t      text;
  v_n      bigint;
  v_total  bigint := 0;
  v_tables text[] := ARRAY[
    'refunds',
    'order_returns',
    'order_substitute_event',
    'order_substitute_probe',
    'order_thread_read',
    'thread_call_task',
    'bill_line_allocations',
    'handling_damage',
    'order_substitute_ask',
    'order_substitute_offer',
    'order_thread_message',
    'px_delivery_job',
    'px_disclosure',
    'supplier_disputes',
    'support_ticket_message',
    'delivery_claims',
    'delivery_events',
    'delivery_otp',
    'delivery_payout_lines',
    'delivery_ratings',
    'delivery_reschedule',
    'masked_calls',
    'order_alert_token',
    'order_hold_release',
    'order_items',
    'pharmacy_count_attribution',
    'pharmacy_count_evidence',
    'pharmacy_count_round',
    'pharmacy_parcel_count_line',
    'px_deal',
    'rx_scan_line',
    'storefront_request',
    'support_ticket',
    'bag_item_counts',
    'bag_sessions',
    'bag_supplier_usage',
    'bill_chase_log',
    'bill_jobs',
    'bill_lines',
    'call_sessions',
    'deliveries',
    'delivery_wave_decision',
    'delivery_wave_stop',
    'inquiry',
    'khata_entry',
    'ops_sla_alert',
    'order_alert',
    'order_cancellations',
    'order_costs',
    'order_customer_event',
    'order_feedback',
    'order_feedback_token',
    'order_fulfilment_snapshot',
    'order_hold',
    'order_pnl_slab',
    'order_stage_history',
    'order_thread',
    'partner_incentive_earning',
    'partner_settlement_ack',
    'partner_settlement_payments',
    'partner_settlements',
    'pharmacy_bill_shot',
    'pharmacy_count_line',
    'pharmacy_lot_correction',
    'pharmacy_lot_inference',
    'pharmacy_parcel_count',
    'pharmacy_purchase_bill_line',
    'pharmacy_stock_move',
    'pos_reservation',
    'pos_sale_event',
    'pos_sale_lines',
    'purchase_override',
    'px_listing',
    'razorpay_qr',
    'rx_scan',
    'rzp_payment_attempt',
    'settlement_invoice',
    'supplier_payments',
    'agency_dispatch_log',
    'agency_invoices',
    'bag_allocations',
    'bags',
    'customer_action_log',
    'dashboard_cache',
    'dashboard_daily',
    'delivery_partner_shifts',
    'delivery_wave',
    'fulfil_task',
    'inquiry_day_log',
    'loyalty_ledger',
    'notification_alerts',
    'notification_log',
    'notification_retry_queue',
    'ops_state_finding',
    'order_closure_log',
    'order_state_event',
    'orders',
    'pack_clip_mentions',
    'partner_settlement_periods',
    'payment_claims',
    'pending_bills',
    'pending_orders',
    'pharmacy_audit_log',
    'pharmacy_count_session',
    'pharmacy_gst_ledger',
    'pharmacy_purchase_bill',
    'pharmacy_radar_send_log',
    'pharmacy_sku_velocity',
    'pharmacy_stock',
    'pos_sales',
    'razorpay_webhook_log',
    'receiving_log',
    'stock_movement',
    'stock_update_forms',
    'stock_update_queue',
    'supplier_count_sessions',
    'supplier_item_memory',
    'supplier_orders',
    'supplier_perf_monthly',
    'voice_clip_log',
    'voice_clip_mentions'
  ];
BEGIN
  -- Break the two FK cycles without disabling anything. Both columns are
  -- nullable and both tables are emptied below anyway.
  IF to_regclass('public.order_cancellations') IS NOT NULL THEN
    EXECUTE 'update public.order_cancellations set refund_id = null where refund_id is not null';
  END IF;
  IF to_regclass('public.settlement_invoice') IS NOT NULL THEN
    EXECUTE 'update public.settlement_invoice set parent_invoice_id = null where parent_invoice_id is not null';
  END IF;

  FOREACH v_t IN ARRAY v_tables LOOP
    -- to_regclass keeps this safe on any database that does not carry the
    -- whole app schema (the control plane replays the same file).
    IF to_regclass('public.' || quote_ident(v_t)) IS NOT NULL THEN
      EXECUTE format('delete from public.%I', v_t);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_total := v_total + v_n;
      IF v_n > 0 THEN
        RAISE NOTICE 'cmd1837 purge: % -> % rows', v_t, v_n;
      END IF;
    END IF;
  END LOOP;

  -- Order-related WhatsApp sends and campaign rows: only the ones that carry an
  -- order_id. The WhatsApp inbox itself, the templates and the campaigns are
  -- master/history data and are NOT touched.
  IF to_regclass('public.wa_send_attempts') IS NOT NULL THEN
    EXECUTE 'delete from public.wa_send_attempts where order_id is not null';
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RAISE NOTICE 'cmd1837 purge: wa_send_attempts(order_id not null) -> % rows', v_n;
  END IF;
  IF to_regclass('public.wa_campaign_recipients') IS NOT NULL THEN
    EXECUTE 'delete from public.wa_campaign_recipients where order_id is not null';
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RAISE NOTICE 'cmd1837 purge: wa_campaign_recipients(order_id not null) -> % rows', v_n;
  END IF;

  RAISE NOTICE 'cmd1837 purge: % rows deleted in total', v_total;
END
$cmd1837$;

-- ── Counters, so the next order/bill/invoice starts fresh ──────────────────
-- Order codes (CPO…) need nothing: orders_set_order_code() derives the serial
-- from a COUNT of that customer's orders on that IST date, so an empty orders
-- table already restarts them. Deploy change numbers are NOT touched.
DO $cmd1837_seq$
DECLARE
  v_t text;
  v_seq text;
BEGIN
  -- Per-financial-year document counters: keep the row, restart the number.
  IF to_regclass('public.customer_invoice_series')  IS NOT NULL THEN
    EXECUTE 'update public.customer_invoice_series set next_no = 1 where next_no <> 1';
  END IF;
  IF to_regclass('public.pos_invoice_counter')      IS NOT NULL THEN
    EXECUTE 'update public.pos_invoice_counter set next_no = 1 where next_no <> 1';
  END IF;
  IF to_regclass('public.px_invoice_counter')       IS NOT NULL THEN
    EXECUTE 'update public.px_invoice_counter set next_no = 1 where next_no <> 1';
  END IF;
  IF to_regclass('public.settlement_invoice_series') IS NOT NULL THEN
    EXECUTE 'update public.settlement_invoice_series set next_no = 1 where next_no <> 1';
  END IF;
  IF to_regclass('public.supplier_return_series')   IS NOT NULL THEN
    EXECUTE 'update public.supplier_return_series set next_no = 1 where next_no <> 1';
  END IF;

  -- Khata account balances are a rollup of khata_entry, which is now empty.
  IF to_regclass('public.khata_account') IS NOT NULL THEN
    EXECUTE 'update public.khata_account set balance = 0, oldest_due_on = null, last_entry_at = null, last_payment_at = null, reminder_stage = 0';
  END IF;

  -- Restart the identity sequence of every table this file emptied, so the
  -- first new row is id 1 again. Sequences owned by tables NOT in the purge
  -- set are left alone, and no sequence is created or dropped.
  FOR v_t, v_seq IN
    SELECT c.relname, pg_get_serial_sequence('public.'||quote_ident(c.relname), a.attname)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY (ARRAY[
        'refunds',
        'order_returns',
        'order_substitute_event',
        'order_substitute_probe',
        'order_thread_read',
        'thread_call_task',
        'bill_line_allocations',
        'handling_damage',
        'order_substitute_ask',
        'order_substitute_offer',
        'order_thread_message',
        'px_delivery_job',
        'px_disclosure',
        'supplier_disputes',
        'support_ticket_message',
        'delivery_claims',
        'delivery_events',
        'delivery_otp',
        'delivery_payout_lines',
        'delivery_ratings',
        'delivery_reschedule',
        'masked_calls',
        'order_alert_token',
        'order_hold_release',
        'order_items',
        'pharmacy_count_attribution',
        'pharmacy_count_evidence',
        'pharmacy_count_round',
        'pharmacy_parcel_count_line',
        'px_deal',
        'rx_scan_line',
        'storefront_request',
        'support_ticket',
        'bag_item_counts',
        'bag_sessions',
        'bag_supplier_usage',
        'bill_chase_log',
        'bill_jobs',
        'bill_lines',
        'call_sessions',
        'deliveries',
        'delivery_wave_decision',
        'delivery_wave_stop',
        'inquiry',
        'khata_entry',
        'ops_sla_alert',
        'order_alert',
        'order_cancellations',
        'order_costs',
        'order_customer_event',
        'order_feedback',
        'order_feedback_token',
        'order_fulfilment_snapshot',
        'order_hold',
        'order_pnl_slab',
        'order_stage_history',
        'order_thread',
        'partner_incentive_earning',
        'partner_settlement_ack',
        'partner_settlement_payments',
        'partner_settlements',
        'pharmacy_bill_shot',
        'pharmacy_count_line',
        'pharmacy_lot_correction',
        'pharmacy_lot_inference',
        'pharmacy_parcel_count',
        'pharmacy_purchase_bill_line',
        'pharmacy_stock_move',
        'pos_reservation',
        'pos_sale_event',
        'pos_sale_lines',
        'purchase_override',
        'px_listing',
        'razorpay_qr',
        'rx_scan',
        'rzp_payment_attempt',
        'settlement_invoice',
        'supplier_payments',
        'agency_dispatch_log',
        'agency_invoices',
        'bag_allocations',
        'bags',
        'customer_action_log',
        'dashboard_cache',
        'dashboard_daily',
        'delivery_partner_shifts',
        'delivery_wave',
        'fulfil_task',
        'inquiry_day_log',
        'loyalty_ledger',
        'notification_alerts',
        'notification_log',
        'notification_retry_queue',
        'ops_state_finding',
        'order_closure_log',
        'order_state_event',
        'orders',
        'pack_clip_mentions',
        'partner_settlement_periods',
        'payment_claims',
        'pending_bills',
        'pending_orders',
        'pharmacy_audit_log',
        'pharmacy_count_session',
        'pharmacy_gst_ledger',
        'pharmacy_purchase_bill',
        'pharmacy_radar_send_log',
        'pharmacy_sku_velocity',
        'pharmacy_stock',
        'pos_sales',
        'razorpay_webhook_log',
        'receiving_log',
        'stock_movement',
        'stock_update_forms',
        'stock_update_queue',
        'supplier_count_sessions',
        'supplier_item_memory',
        'supplier_orders',
        'supplier_perf_monthly',
        'voice_clip_log',
        'voice_clip_mentions'
      ])
      AND pg_get_serial_sequence('public.'||quote_ident(c.relname), a.attname) IS NOT NULL
  LOOP
    EXECUTE format('alter sequence %s restart with 1', v_seq);
    RAISE NOTICE 'cmd1837 purge: sequence % restarted', v_seq;
  END LOOP;
END
$cmd1837_seq$;

COMMIT;

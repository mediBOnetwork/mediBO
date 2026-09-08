-- CHANGE #305 step 4 — 57 pg_cron entries become 2.
--
-- Every recurring job moves into cron_task and is dispatched by the one minute
-- tick that already runs. The work_sql is SELECTed out of cron.job rather than
-- retyped here, so what runs after the cutover is byte-identical to what ran
-- before it — the schedule changes, the work does not.
--
-- Two jobs stay on pg_cron because the dispatcher genuinely cannot host them:
--   • medicine_vacuum_weekly — VACUUM cannot run inside a function.
--   • cron-dispatch itself — it is the tick.
--
-- Ordering is the safety mechanism. The order path (inquiry, bills, orders,
-- notifications) sits at low `ord` and is served first; the heavy refreshes sit
-- at ord >= 900 and run last, so a 35-second storefront rebuild can only ever
-- delay the NEXT tick, never the inquiry engine inside this one.

-- did_work for a DML task is "did it touch a row", which GET DIAGNOSTICS already
-- answers honestly. For `select fn()` ROW_COUNT is always 1 and means nothing,
-- so only tasks flagged dml use it.
alter table public.cron_task
  add column if not exists dml boolean not null default false;

with map(jobname, ord, base_interval_s, max_interval_s, run_at_ist, run_dow,
         gate_sql, business_hours_only, step_timeout_ms, dml, note) as (values

  -- ── order / money / notification path — every 2-5 minutes, low ord ───────
  ('order_unfulfilled_sweep',           210, 120,  1800, null::time, null::int, null,
    false, 20000, false,
    'Splits out the items no supplier could fulfil. Also woken by cron_signal the moment an order item is refused, so the interval is only the safety net.'),
  ('bill-jobs-tick',                    220, 120,  1800,  null, null,
    'select coalesce((select auto_bill_enabled from public.bill_auto_config where id = 1), true)',
    false, 20000, false,
    'Bill rendering queue. The gate is the function''s own first line: auto-billing off means it returns 0 without touching a table.'),
  ('autosend_pending_supplier_orders',  230, 300,  1800,  null, null,
    'select coalesce((select (value #>> ''{}'')::boolean from public.app_settings where key = ''supplier_order_auto_meta''), false)
        and coalesce((select (value #>> ''{}'')::boolean from public.app_settings where key = ''inquiry_engine_mode''), false)',
    false, 20000, false,
    'Auto-sends queued supplier orders. Mirrors the two app_settings flags the function checks before it does anything.'),
  ('inquiry_lock_auto_release_5min',    240, 300,  1800,  null, null,
    'select exists (select 1 from public.inquiry_lock_zone where locked)',
    false, 20000, false,
    'Releases a zone lock the next day. Nothing locked, nothing to release.'),
  ('c298_push_timeout_sweep',           250, 300,  1800,  null, null,
    'select exists (select 1 from public.notification_log
        where channel = ''push'' and status = ''queued'' and created_at < now() - interval ''3 minutes'')',
    false, 20000, false,
    'Fails a push that never reported back. The gate is the loop''s own WHERE.'),
  ('notify_retry_tick',                 260, 600,  1800,  null, null,
    'select exists (select 1 from public.notification_retry_queue
        where status = ''pending'' and next_attempt_at <= now())',
    false, 20000, false,
    'Retries a failed notification. Gate is the queue itself being due.'),
  ('order-lifecycle-tick',              270, 600,  1800,  null, null, null,
    false, 20000, false,
    'Advances order/supplier lifecycle after a delivery. Left ungated on purpose - its loop condition spans four tables and a wrong gate here would silently strand an order.'),
  ('wa_notify_sweep',                   280, 600,  1800,  null, null,
    'select exists (select 1 from public.orders o
        where o.created_at between now() - interval ''3 hours'' and now() - interval ''4 minutes'')',
    false, 20000, false,
    'Repairs an order-placed WhatsApp that never went out. No order in the last three hours means there is nothing it could repair.'),
  ('version_watch_5min',                290, 300,  1800,  null, null, null,
    false, 20000, false,
    'Watches the deployed version.json through pg_net. Ungated: its state machine owns the polling.'),

  -- ── WhatsApp / offers / stock ────────────────────────────────────────────
  ('wa_templates_sync_5min',            310, 300,  1800,  null, null, null,
    false, 20000, false,
    'Pulls template status from Meta through the wa-templates edge function.'),
  ('wa_drip_tick_5min',                 320, 300,  1800,  null, null,
    'select exists (select 1 from public.wa_drips where status = ''running'')',
    false, 20000, false,
    'Drip pacing. No running drip, no work - the function''s own outer loop.'),
  ('wa_media_refresh_10min',            330, 600,  1800,  null, null,
    'select exists (select 1 from public.wa_templates tp
        where coalesce(tp.header_format, ''TEXT'') <> ''TEXT'' and tp.hidden_at is null
          and coalesce(tp.status, ''DRAFT'') in (''DRAFT'',''REJECTED'')
          and coalesce(tp.header_media_path, '''') <> '''')',
    false, 20000, false,
    'Re-uploads a media header handle. Gate is a superset of the loop''s WHERE, so it can run needlessly but can never skip a template that needs it.'),
  ('wa_event_autopilot_10min',          340, 600,  1800,  null, null, null,
    false, 20000, false,
    'Event-route autopilot. Ungated - the run function does its own batching.'),
  ('wa_alwaysopen_resume_10min',        350, 600,  1800,  null, null,
    'select exists (select 1 from public.wa_campaigns c
        where c.audience_kind in (''event_route'',''drip_step'') and c.status = ''paused'')',
    false, 20000, false,
    'Resumes a campaign auto-paused on delivery failures. Nothing paused, nothing to resume.'),
  ('offer-reservation-sweep',           360, 300,  1800,  null, null,
    'select exists (select 1 from public.offer_reservations where status = ''held'' and expires_at <= now())',
    false, 20000, false,
    'Releases an expired offer hold. Gate is the update''s own WHERE.'),
  ('offer-waitlist-notify',             370, 600,  1800,  null, null,
    'select exists (select 1 from public.offer_waitlist)',
    false, 20000, false,
    'Tells a waitlisted buyer stock is back. An empty waitlist is the common case.'),
  ('offer-expiry-cron',                 380, 3600, 3600,  null, null,
    'select exists (select 1 from public.supplier_offer_listings
        where status = ''active''
          and ((end_date is not null and end_date < current_date)
            or (batch_expiry_date is not null and batch_expiry_date <= current_date)
            or available_qty <= 0))',
    false, 20000, false,
    'Expires a listing. Also woken by cron_signal when a listing''s qty or dates change.'),
  ('stock_notify_sweep_15min',          390, 900,  3600,  null, null,
    'select exists (select 1 from public.stock_notify_requests r
        join public."MEDICINE" m on m.id = r.product_id
        where r.available_at is null and lower(coalesce(m.buyable::text, '''')) in (''true'',''t''))',
    false, 20000, false,
    'Flags a back-in-stock request. Gate is the update''s own join, and a product turning buyable now signals it directly.'),

  -- ── platform / dev tooling — no longer its own pg_cron entry ─────────────
  ('dev-runner-liveness',               410, 120,  1800,  null, null, null,
    false, 20000, false,
    'Releases a stale build row and flags a token-stalled worker. Stays in the database on purpose: a watchdog for the runner VM cannot live on the runner VM.'),
  ('dev-cmd-watchdog',                  415, 300,  1800,  null, null, null,
    false, 20000, false,
    'Fails a command whose worker stopped heartbeating. Same reason as liveness - it must outlive the box it watches.'),
  ('lease-sweep',                       420, 300,  1800,  null, null,
    'select exists (select 1 from public.file_leases fl
        where not exists (select 1 from public.dev_commands c
                          where c.id = fl.command_id and c.status = ''building''))',
    false, 20000, false,
    'Frees a file lease whose command is no longer building. Gate is the delete''s own WHERE.'),
  ('prune_orphan_count_modes',          425, 300,  1800,  null, null,
    'select exists (select 1 from public.supplier_count_mode scm
        where not exists (select 1 from public.order_items oi
                          where oi.assigned_supplier = scm.assigned_supplier
                            and oi.fulfillment_state not in (''shipped'',''cancelled'')))',
    false, 20000, false,
    'Drops a count mode with no live order behind it. Gate is the delete''s own WHERE.'),
  ('play-reap-stale',                   430, 900,  3600,  null, null,
    'select exists (select 1 from public.play_release where status in (''queued'',''building'',''uploading''))',
    false, 20000, false,
    'Fails a Play publish that stopped reporting. Nothing in flight is the normal state.'),
  ('gcp-uptime-check',                  435, 300,  1800,  null, null, null,
    false, 20000, false, 'GCP VM uptime probe.'),
  ('gcp-disk-check',                    440, 3600, 3600,  null, null, null,
    false, 20000, false, 'GCP disk headroom probe.'),
  ('gcp-schedule-scan',                 445, 900,  3600,  null, null, null,
    false, 20000, false, 'GCP scheduled start/stop reconciliation.'),
  ('notify_health_scan',                450, 3600, 3600,  null, null, null,
    false, 20000, false, 'Raises and clears notification-channel health alerts.'),
  ('dispute-nudge-24h',                 455, 3600, 3600,  null, null, null,
    false, 20000, true,
    'Marks an unanswered supplier dispute for a nudge. DML, so a run that marks nothing counts as idle and the interval backs off.'),
  ('bill-chase-tick',                   460, 7200, 7200,  null, null, null,
    false, 20000, false, 'Chases an unpaid supplier bill.'),
  ('sc-map-companies',                  465, 1800, 3600,  null, null,
    'select exists (select 1 from public.supplier_company
        where company_1 is null and coalesce(match_attempts, 0) < 5)',
    true, 20000, false,
    'Maps supplier company aliases. Gate is the function''s own n_todo check, and it is business-hours only: nothing user-facing waits on it overnight.'),
  ('wa_waba_info_6h',                   470, 21600, 21600, null, null, null,
    false, 20000, false, 'Refreshes WABA account info from Meta.'),
  ('mcc_refresh',                       475, 14400, 14400, null, null, null,
    false, 30000, false, 'Rebuilds the medicine category count cache.'),
  ('refresh_supplier_points',           480, 600,  3600,  null, null,
    'select coalesce((select dirty from public.job_dirty_state where job = ''ordered_medicine_points''), true)',
    false, 30000, false,
    'SPN points. Gate is the function''s own dirty check, so an idle day costs one boolean read a run.'),
  ('omp_safety_net',                    485, 21600, 21600, null, null, null,
    false, 20000, true, 'Re-arms the SPN points dirty flag every 6 h.'),
  ('lead_safety_net',                   490, 21600, 21600, null, null, null,
    false, 20000, true, 'Re-arms the lead pipeline dirty flag every 6 h.'),

  -- ── daily / weekly, pinned to the IST wall clock ────────────────────────
  ('bag-daily-reset-ist',               510, null, null, time '00:00', null, null,
    false, 30000, false, 'Bag numbering resets at midnight IST.'),
  ('cleanup-expired-removed-cart-items',515, null, null, time '00:05', null, null,
    false, 30000, true,  'Drops admin-removed cart items from previous days.'),
  ('vm_snapshot_weekly',                520, null, null, time '03:07', 0, null,
    false, 30000, false, 'Weekly VM snapshot kick, Sunday 03:07 IST.'),
  ('voice_tail_purge_daily',            525, null, null, time '03:15', null, null,
    false, 30000, false, 'Purges voice tails.'),
  ('mutation-audit-weekly',             530, null, null, time '03:40', 0, null,
    false, 30000, true,  'Queues the weekly mutation audit command, Sunday 03:40 IST.'),
  ('medicine_count_daily',              535, null, null, time '04:20', null, null,
    false, 55000, false, 'Rebuilds the medicine count cache. 10 s of work, once a day.'),
  ('sec-daily-checks',                  540, null, null, time '05:05', null, null,
    false, 30000, false, 'Daily security checks.'),
  ('cron_history_purge',                545, null, null, time '05:25', null, null,
    false, 30000, true,  'Trims cron.job_run_details to two days.'),
  ('purge_voice_clips',                 550, null, null, time '05:35', null, null,
    false, 30000, false, 'Purges stored voice clips.'),
  ('reorder_subscription_run_daily',    555, null, null, time '06:10', null, null,
    false, 30000, false, 'Runs due reorder subscriptions.'),
  ('reorder_lowstock_check_daily',      560, null, null, time '06:20', null, null,
    false, 30000, false, 'Low-stock reorder check.'),
  ('medicine_refresh_safety_net',       565, null, null, time '07:10', null, null,
    false, 30000, true,  'Re-arms the three medicine dirty flags daily.'),
  ('stock_update_sweep_5pm_ist',        570, null, null, time '17:00', null, null,
    false, 30000, false, 'Sends the daily supplier stock-update form at 17:00 IST.'),
  ('dev-cmd-weekly-changelog',          575, null, null, time '20:00', 0, null,
    false, 30000, false, 'Weekly changelog, Sunday 20:00 IST.'),
  ('dev-cmd-daily-digest',              580, null, null, time '21:00', null, null,
    false, 30000, false, 'Daily dev-queue digest at 21:00 IST.'),

  -- ── the heavy lane: last in the tick, so nothing above waits on it ───────
  ('lead-pipeline',                     900, 900,  3600,  null, null,
    'select coalesce((select dirty from public.lead_pipeline_state where id = 1), false)',
    true, 55000, false,
    'Lead scoring, distance and clustering. Was 95 runs a day at 13 s each because its own output re-dirtied it; the trigger fix means it now skips on a boolean until a lead genuinely changes. Business-hours only - no customer waits on a lead score.'),
  ('rg_watch_2h',                       910, null, null, time '03:51', null, null,
    false, 55000, false, 'Regression-guard watch. 19 s of work, once a day, last in the tick.'),
  ('refresh-therapeutic-categories',    920, 21600, 21600, null, null,
    'select coalesce((select dirty from public.job_dirty_state where job = ''therapeutic_categories''), true)',
    false, 55000, false,
    'Rebuilds therapeutic categories only when the medicine table says it is dirty.'),
  ('refresh-medicine-companies',        930, 21600, 21600, null, null,
    'select coalesce((select dirty from public.job_dirty_state where job = ''medicine_companies''), true)',
    false, 55000, false,
    'Rebuilds the company list only when dirty.'),
  ('refresh_storefront_feed_job',       940, 21600, 21600, null, null,
    'select coalesce((select dirty from public.job_dirty_state where job = ''storefront_feed''), true)',
    false, 55000, false,
    'Rebuilds the storefront feed only when dirty. 35 s worst case, which is why it is last.')
)
insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
   base_interval_s, max_interval_s, current_interval_s, run_at_ist, run_dow,
   business_hours_only, dml, next_run_at)
select m.jobname, m.ord, 'poll', m.gate_sql, j.command, m.step_timeout_ms, true, m.note,
       m.base_interval_s, coalesce(m.max_interval_s, 3600), m.base_interval_s,
       m.run_at_ist, m.run_dow::smallint, m.business_hours_only, m.dml,
       case when m.run_at_ist is not null
            then public._cron_next_pinned(m.run_at_ist, m.run_dow::smallint)
            else now() + make_interval(secs => m.base_interval_s) end
  from map m
  join cron.job j on j.jobname = m.jobname
 where j.active
on conflict (name) do nothing;

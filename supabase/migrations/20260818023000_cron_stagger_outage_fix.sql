-- 2026-08-18 production outage fix — pg_cron thundering herd.
--
-- At 02:00:00 UTC, 35 of the 60 active cron jobs started in the same second
-- (15 on '* * * * *', 10 on '*/5', 4 on '*/10', 3 on '*/15', plus '*/2', '*/30'
-- and the hourly jobs, all of which share minute 0). max_connections is 60 with
-- 3 superuser-reserved, so the burst plus PostgREST/GoTrue/realtime/storage
-- exhausted every slot. Postgres logged "remaining connection slots are reserved
-- for roles with the SUPERUSER attribute", every service upstream of Kong became
-- unreachable, and the edge served 520/522 for 29 minutes. pg_cron recorded the
-- 15 per-minute jobs as "job startup timeout" for 19m30s — they never got a
-- connection. Nothing crashed; the instance was simply starved.
--
-- Fix is phase-shift ONLY: every job keeps its exact frequency, it just no
-- longer starts on the same minute as every other job. Worst-case simultaneous
-- starts drop from 35 to ~20 (floor of 15 is the '* * * * *' set).
--
-- If a new recurring job is added, give it an offset schedule ('7-59/10'),
-- never a bare '*/10' — bare step expressions all collide on minute 0.

-- every 5 minutes (10 jobs) -> 5 phases, 2 jobs each
select cron.alter_job(52, schedule := '1-59/5 * * * *');  -- autosend_pending_supplier_orders
select cron.alter_job(54, schedule := '1-59/5 * * * *');  -- prune_orphan_count_modes
select cron.alter_job(64, schedule := '2-59/5 * * * *');  -- inquiry_lock_auto_release
select cron.alter_job(71, schedule := '2-59/5 * * * *');  -- wa_templates_sync
select cron.alter_job(73, schedule := '3-59/5 * * * *');  -- version_watch
select cron.alter_job(74, schedule := '3-59/5 * * * *');  -- wa_drip_tick
select cron.alter_job(79, schedule := '4-59/5 * * * *');  -- dev_cmd_watchdog
select cron.alter_job(85, schedule := '4-59/5 * * * *');  -- gcp_uptime_check
select cron.alter_job(86, schedule := '0-59/5 * * * *');  -- lease_sweep
select cron.alter_job(93, schedule := '0-59/5 * * * *');  -- _offer_reservation_sweep

-- every 10 minutes (4 jobs) -> offsets 6..9, clear of the */5 phases
select cron.alter_job(12, schedule := '6-59/10 * * * *'); -- refresh_ordered_medicine_points
select cron.alter_job(76, schedule := '7-59/10 * * * *'); -- wa_event_autopilot
select cron.alter_job(77, schedule := '8-59/10 * * * *'); -- wa_alwaysopen_resume
select cron.alter_job(94, schedule := '9-59/10 * * * *'); -- _offer_waitlist_notify_cron

-- every 15 minutes (3 jobs) -> offsets 11..13, off the :00/:15/:30/:45 boundary
select cron.alter_job(42, schedule := '11-59/15 * * * *'); -- lead_pipeline_tick (ran 26.7s at 02:00)
select cron.alter_job(68, schedule := '12-59/15 * * * *'); -- stock_notify_sweep
select cron.alter_job(82, schedule := '13-59/15 * * * *'); -- gcp_schedule_scan

-- every 30 / every 2 minutes
select cron.alter_job(39, schedule := '14-59/30 * * * *'); -- sc_map_companies
select cron.alter_job(62, schedule := '1-59/2 * * * *');   -- order_unfulfilled_sweep (odd minutes)

-- hourly and multi-hourly jobs pulled off minute 0 and minute 15
select cron.alter_job(92, schedule := '19 * * * *');    -- _offer_expiry_cron
select cron.alter_job(84, schedule := '23 * * * *');    -- gcp_disk_check
select cron.alter_job(63, schedule := '21 */2 * * *');
select cron.alter_job(50, schedule := '26 */4 * * *');
select cron.alter_job(17, schedule := '31 */6 * * *');

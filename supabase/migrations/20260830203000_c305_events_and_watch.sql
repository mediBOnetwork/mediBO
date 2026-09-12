-- CHANGE #305 steps 5-6 — turn polling into events, and watch the baseline.
--
-- Three of the migrated tasks were polling for something a row change already
-- announces. They keep their interval as a safety net, but the interval is no
-- longer how they find out: cron_wake() drops a signal and the very next tick
-- serves it, which is both faster than the old 2-15 minute poll and free.

create or replace function public.trg_cron_wake_unfulfilled()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  perform public.cron_wake('order_unfulfilled_sweep');
  return null;
end $fn$;

create or replace function public.trg_cron_wake_offer_expiry()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  perform public.cron_wake('offer-expiry-cron');
  return null;
end $fn$;

create or replace function public.trg_cron_wake_stock_notify()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  perform public.cron_wake('stock_notify_sweep_15min');
  return null;
end $fn$;

-- An item's fulfilment state changing is exactly the event the sweep polled for.
drop trigger if exists trg_c305_unfulfilled_wake on public.order_items;
create trigger trg_c305_unfulfilled_wake
after insert or update of fulfillment_state, assigned_supplier on public.order_items
for each statement execute function public.trg_cron_wake_unfulfilled();

-- A listing running out of stock or passing its date is the expiry event.
drop trigger if exists trg_c305_offer_expiry_wake on public.supplier_offer_listings;
create trigger trg_c305_offer_expiry_wake
after insert or update of available_qty, end_date, batch_expiry_date, status
on public.supplier_offer_listings
for each statement execute function public.trg_cron_wake_offer_expiry();

-- A product turning buyable is the back-in-stock event. Statement-level, because
-- MEDICINE is a 563k-row table and a bulk import must fire this once, not once
-- per row.
drop trigger if exists trg_c305_stock_notify_wake on public."MEDICINE";
create trigger trg_c305_stock_notify_wake
after update of buyable on public."MEDICINE"
for each statement execute function public.trg_cron_wake_stock_notify();

-- Someone asking to be told is also the event: the sweep should look now.
drop trigger if exists trg_c305_stock_request_wake on public.stock_notify_requests;
create trigger trg_c305_stock_request_wake
after insert on public.stock_notify_requests
for each statement execute function public.trg_cron_wake_stock_notify();


-- ── the creep alarm ───────────────────────────────────────────────────────
-- The whole point of this change is a number, so the number gets a watchdog.
-- If the daily execution baseline climbs back over target — someone adds a
-- pg_cron entry, or a task's backoff stops working — it says so in rg_alerts,
-- which is the same place the DB lane already reports.
create or replace function public.cron_baseline_watch()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_target int; v_jobs int; v_per_hour numeric; v_dispatch_per_hour numeric;
begin
  select target_per_hour into v_target from public.cron_baseline where id;
  v_target := coalesce(v_target, 60);

  select count(*) into v_jobs from cron.job where active;
  -- A trailing 3 hours, not 24: the number has to describe what the scheduler
  -- is doing NOW, or the day of a cutover reads as a permanent breach.
  select round(count(*) / greatest(extract(epoch from (now() - min(start_time))) / 3600.0, 1), 1)
    into v_per_hour
    from cron.job_run_details where start_time > now() - interval '3 hours';
  v_per_hour := coalesce(v_per_hour, 0);

  -- What the dispatcher itself actually did, so a creeping tick is visible too.
  select round(count(*) filter (where did_work) / 3.0, 1) into v_dispatch_per_hour
    from public.cron_job_stats where started_at > now() - interval '3 hours';

  if v_per_hour > v_target then
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values ('cron_baseline_creep', 'warning', 'cron', 'cron baseline above target',
            jsonb_build_object('per_hour', v_per_hour, 'target_per_hour', v_target,
                               'active_jobs', v_jobs,
                               'dispatcher_work_per_hour', coalesce(v_dispatch_per_hour, 0)))
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          detail = excluded.detail, severity = excluded.severity;
  else
    delete from public.rg_alerts where fingerprint = 'cron_baseline_creep';
  end if;

  -- Retention: the instrumentation must never become the next quota problem.
  delete from public.cron_job_stats where started_at < now() - interval '14 days';

  return jsonb_build_object('ok', true, 'per_hour', v_per_hour,
                            'target_per_hour', v_target, 'active_jobs', v_jobs);
end $fn$;

revoke all on function public.cron_baseline_watch() from anon, authenticated;
revoke all on public.cron_job_stats, public.cron_baseline from anon, authenticated;

insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
   base_interval_s, max_interval_s, current_interval_s, business_hours_only, dml, next_run_at)
values
  ('cron_baseline_watch', 495, 'poll', null,
   'select public.cron_baseline_watch()', 20000, true,
   'Watches its own change. Raises cron_baseline_creep in rg_alerts if executions per hour climb back over target, and trims cron_job_stats to 14 days.',
   3600, 3600, 3600, false, false, now() + interval '5 minutes')
on conflict (name) do nothing;

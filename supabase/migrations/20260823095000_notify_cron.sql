-- CHANGE — #297 part 1, step 4: the two schedules that keep the queue moving.
--
-- OFFSET schedules, never a bare */N. On 2026-08-18 thirty-five cron jobs all
-- fired on minute 0, took every one of the 60 connection slots and served
-- Cloudflare 520s for 29 minutes. `8-59/10` and minute 37 were chosen because
-- they were the least-crowded slots at the time this shipped.
do $$
begin
  perform cron.unschedule('notify_retry_tick');
exception when others then null;
end $$;
do $$
begin
  perform cron.unschedule('notify_health_scan');
exception when others then null;
end $$;

select cron.schedule('notify_retry_tick',  '8-59/10 * * * *', $$select public.notify_retry_tick(25);$$);
select cron.schedule('notify_health_scan', '37 * * * *',      $$select public.notify_health_scan();$$);

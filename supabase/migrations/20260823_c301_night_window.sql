-- CHANGE #301 — heavy scheduled audits move to the 21:00–02:00 UTC night window
-- (02:30–07:30 IST), so they never land on top of 4–7 agents building.
--
-- Chosen from measured evidence, not guesswork: cron.job_run_details over the
-- retained window shows rg_watch (the full schema+payload audit) averaging 17 s
-- and once hitting the 2-minute statement timeout during the 23 Aug choke,
-- while cron-dispatch failed 9 times with "job startup timeout" — the signature
-- of an instance with no spare connections.
--
-- Every minute is a distinct offset. A bare `*/N` or minute-0 schedule is what
-- caused the 18 Aug outage; nothing here reintroduces one.
do $$
declare r record;
begin
  for r in
    select * from (values
      -- name,                        new schedule,   why
      ('rg_watch_2h',                 '21 22 * * *',  'the heavy schema+payload audit: nightly instead of 12x a day'),
      ('sec-daily-checks',            '35 23 * * *',  'daily security scan'),
      ('cron_history_purge',          '55 23 * * *',  'bulk delete over cron.job_run_details'),
      ('medicine_count_daily',        '50 22 * * *',  'counts over the 563k-row MEDICINE table'),
      ('voice_tail_purge_daily',      '45 21 * * *',  'bulk delete of voice tails'),
      ('medicine_refresh_safety_net', '40 1 * * *',   'kicks the heavy MEDICINE refreshes — pull them into the window'),
      ('medicine_vacuum_weekly',      '40 22 * * 0',  'VACUUM (analyze) MEDICINE'),
      ('mutation-audit-weekly',       '10 22 * * 6',  'already nightly, but minute 0 is the collision minute')
    ) as t(name, sched, why)
  loop
    if exists (select 1 from cron.job where jobname = r.name) then
      perform cron.alter_job((select jobid from cron.job where jobname = r.name), schedule => r.sched);
    end if;
  end loop;
end $$;

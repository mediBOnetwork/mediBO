-- CHANGE #305 step 1 — INSTRUMENT BEFORE YOU CUT.
--
-- 57 pg_cron jobs were burning 8,335 executions a day against an idle app.
-- Nothing is removed on guesswork: every dispatcher-hosted job now writes one
-- row here per run, so "this job never does anything" is a measurement and not
-- an opinion. cron.job_run_details only keeps 2 days, so the pre-cut baseline
-- is frozen in its own row rather than recomputed from a window that will have
-- aged out by the time anyone reads the report.

create table if not exists public.cron_job_stats (
  id           bigserial primary key,
  job_name     text        not null,
  source       text        not null default 'dispatcher',
  started_at   timestamptz not null default now(),
  duration_ms  integer,
  rows_touched integer,
  did_work     boolean     not null default false,
  error        text
);

create index if not exists cron_job_stats_name_at_idx on public.cron_job_stats (job_name, started_at desc);
create index if not exists cron_job_stats_at_idx      on public.cron_job_stats (started_at desc);

alter table public.cron_job_stats enable row level security;
-- No policy on purpose: the dispatcher writes as SECURITY DEFINER and the admin
-- reads through cron_health(). Nothing client-side touches the raw table.

-- The frozen "before" measurement. One row, id = true.
create table if not exists public.cron_baseline (
  id             boolean     primary key default true check (id),
  measured_at    timestamptz not null default now(),
  jobs           integer     not null,
  runs_24h       integer     not null,
  runs_per_hour  numeric     not null,
  target_per_hour integer    not null default 60,
  note           text
);

alter table public.cron_baseline enable row level security;

insert into public.cron_baseline (id, jobs, runs_24h, runs_per_hour, target_per_hour, note)
select true,
       (select count(*)::int from cron.job where active),
       (select count(*)::int from cron.job_run_details where start_time > now() - interval '24 hours'),
       (select round(count(*)/24.0, 1) from cron.job_run_details where start_time > now() - interval '24 hours'),
       60,
       'Measured immediately before CHANGE #305 collapsed the recurring pg_cron entries into cron_dispatch.'
on conflict (id) do nothing;

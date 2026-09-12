-- CHANGE #635 — a transport TIMEOUT is the environment, not a product failure,
-- and the bot must say so in the backend's words.
--
-- Found the expensive way. The smoke gate this change built is now binding for
-- the whole fleet, and batch 575 logged:
--
--   FAILED  order pipeline — 0/9 stages — POST /rest/v1/rpc/test_pipeline_run
--           timed out after 25000ms
--   batch 575: NOT promoting #637 — the critical-path smoke failed
--   batch 575: NOT promoting #1806 — the critical-path smoke failed
--
-- Two commands that had nothing to do with the order pipeline were held back
-- because a 1 GB database, mid-deploy, did not answer one POST inside 25 s
-- (twice — api.js already retries a timeout once, so that verdict is ~50 s of
-- silence). run.js ALREADY draws this distinction everywhere else: a role with
-- no login is BLOCKED, never failed, because the environment could not meet the
-- precondition. A database that could not answer is the same class of fact, and
-- it was the one place the rule was not applied.
--
-- The verdict and the sentence live here so changing either is an UPDATE, not a
-- deploy — and so that a future decision to make timeouts fail again is one row,
-- reviewable, rather than a constant buried in a JS file.
create table if not exists public.test_config (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  note       text  not null default '',
  updated_at timestamptz not null default now()
);
alter table public.test_config enable row level security;

insert into public.test_config (key, value, note) values
 ('pipeline',
  jsonb_build_object(
    'timeout_verdict', 'blocked',
    'timeout_note',    'the pipeline RPC did not answer inside its budget — the database was busy, not the feature',
    'timeout_match',   'timed out after'),
  'How the flagship pipeline journey reports a transport timeout. verdict must be blocked|failed.')
on conflict (key) do update
  set value = public.test_config.value || excluded.value,
      note  = excluded.note,
      updated_at = now();

create or replace function public.test_config_get(p_key text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select coalesce(
    case when p_key is null
         then (select jsonb_object_agg(key, value) from public.test_config)
         else (select value from public.test_config where key = p_key) end,
    '{}'::jsonb)
$function$;

revoke all on function public.test_config_get(text) from public, anon;
grant execute on function public.test_config_get(text) to authenticated, service_role;

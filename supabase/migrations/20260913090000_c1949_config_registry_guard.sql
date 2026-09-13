-- CMD #1949 — rg guard: config_no_duplicate_keys.
-- The runner config (dev_runner_config) and its registry (dev_config_registry)
-- live on the control plane (medibo-dev); rg_check runs here on production.
-- The control plane computes the verdict (dev_config_registry_check) and pushes
-- it through _prod_rpc into rg_config_registry_verdict; the behaviour test below
-- reads that row inside every rg_check like the other rg tests. Idempotent.

create table if not exists public.rg_config_registry_verdict (
  id        text primary key default 'singleton' check (id = 'singleton'),
  ok        boolean not null,
  verdict   jsonb not null,
  pushed_at timestamptz not null default now()
);
alter table public.rg_config_registry_verdict enable row level security;
comment on table public.rg_config_registry_verdict is 'CMD #1949 — last config-registry verdict pushed from medibo-dev (dev_config_registry_push).';

create or replace function public.rg_config_verdict_write(p_verdict jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'rg_config_verdict_write: control plane only';
  end if;
  insert into rg_config_registry_verdict (id, ok, verdict, pushed_at)
  values ('singleton', coalesce((p_verdict->>'ok')::boolean, false), coalesce(p_verdict, '{}'::jsonb), now())
  on conflict (id) do update set ok = excluded.ok, verdict = excluded.verdict, pushed_at = now();
  return jsonb_build_object('ok', true, 'verdict_ok', (p_verdict->>'ok')::boolean, 'at', now());
end $$;
revoke execute on function public.rg_config_verdict_write(jsonb) from public, anon, authenticated;
grant  execute on function public.rg_config_verdict_write(jsonb) to service_role;

insert into public.rg_behavior_tests (name, body, enabled, note) values (
  'config_no_duplicate_keys',
  $body$
do $x$
declare r record;
begin
  select * into r from public.rg_config_registry_verdict where id = 'singleton';
  if not found then
    raise exception 'config_no_duplicate_keys: no verdict from medibo-dev yet — run devcmd.sh config_push';
  end if;
  if r.pushed_at < now() - interval '24 hours' then
    raise exception 'config_no_duplicate_keys: verdict is stale (% old) — dev_config_registry_push on medibo-dev is not running (trigger + cron_task config-registry-push)', age(now(), r.pushed_at);
  end if;
  if not r.ok then
    raise exception 'config_no_duplicate_keys: unregistered keys % · duplicate descriptions % — register the key in dev_config_registry (medibo-dev) or drop the duplicate',
      r.verdict->'unregistered', r.verdict->'duplicate_descriptions';
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$body$,
  true,
  'CMD #1949 — every key in dev_runner_config (medibo-dev) must be on dev_config_registry and no two rows may share a description. Verdict pushed by dev_config_registry_push() on config change and every 15 min.')
on conflict (name) do update set body = excluded.body, enabled = true, note = excluded.note;

insert into public.ui_copy (key, value) values
  ('dev_queue.pool_fields_empty', '"No editable settings were sent by the backend — dev_config_registry has no editable rows under worker_pool."'::jsonb)
on conflict (key) do nothing;

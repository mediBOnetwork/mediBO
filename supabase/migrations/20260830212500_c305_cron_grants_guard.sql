-- CHANGE #305 — turn the hole into a permanent guard.
--
-- Journey qa-273-47 pins a hard-coded list of six cron RPCs, so cron_baseline_watch()
-- was added in this very command and sailed straight past it while EXECUTE-able
-- by anon through the default PUBLIC grant. A fixed list retires one bug; this
-- retires the class. Any cron function added from here on is covered the moment
-- it exists, and rg_check goes red — which blocks every dev_cmd_complete — if
-- one is ever left open to the key that ships inside the web bundle and the APK.

insert into public.rg_behavior_tests (name, body, enabled, note)
values (
  'cron_surface_closed_to_clients',
  $rgbody$
do $rg$
declare v_open text;
begin
  -- Every cron_* / _cron_* function, not a list someone has to remember to
  -- extend. A function that guards itself with _dev_guard() may be reachable by
  -- a signed-in role (cron_health does exactly that, and the super-admin Cron
  -- health screen is built on it); nothing may be reachable by anon.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'cron\_%' or p.proname like '\_cron\_%')
     and has_function_privilege('anon', p.oid, 'execute');
  if v_open is not null then
    raise exception 'RG_FAIL: these cron functions are EXECUTE-able by anon - the anon key ships inside the web bundle and the APK, so this hands an anonymous caller the scheduler: %. Revoke from PUBLIC, not just from anon/authenticated - anon inherits the default PUBLIC grant and revoking a direct grant it never had is a no-op (CHANGE #305)', v_open;
  end if;

  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'cron\_%' or p.proname like '\_cron\_%')
     and has_function_privilege('authenticated', p.oid, 'execute')
     and p.prosrc not like '%_dev_guard()%';
  if v_open is not null then
    raise exception 'RG_FAIL: these cron functions are EXECUTE-able by a signed-in role without guarding themselves: % (CHANGE #305)', v_open;
  end if;

  -- The scheduler's own state is not client-readable either.
  select string_agg(c.relname, ', ') into v_open
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('cron_task','cron_signal','cron_guard_config','cron_dispatch_state',
                       'cron_job_stats','cron_baseline','scheduled_tasks')
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert'));
  if v_open is not null then
    raise exception 'RG_FAIL: cron state readable or writable by anon: % (CHANGE #305)', v_open;
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$rgbody$,
  true,
  'CHANGE #305 - no cron function or cron state table may be reachable with the anon key. Covers every cron_*/_cron_* name, so a function added later is guarded the day it is written.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

-- The guard's first run found eight MORE cron functions carrying the same
-- default PUBLIC grant, all predating this command: six _cron_sig_* trigger
-- functions and two read helpers, one of which (cron_window_stats) reads
-- cron.job_run_details and would have handed an anonymous caller the
-- scheduler's history. Revoking EXECUTE from a TRIGGER function does not stop
-- the trigger: PostgreSQL checks that privilege when the trigger is CREATED,
-- not each time it fires.
do $do$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'cron\_%' or p.proname like '\_cron\_%')
       and has_function_privilege('anon', p.oid, 'execute')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $do$;

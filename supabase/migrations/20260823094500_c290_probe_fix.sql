-- CHANGE #290 — correct the two probes added minutes earlier in this command.
--
-- Both were caught by re-running the baseline immediately after strengthening,
-- which is the point of doing that step: a new probe that reports `failed` on a
-- healthy system is not a stronger journey, it is a required journey that now
-- blocks every command in its area.
--
-- qa-274-57 — `count(*) filter (...)` was read into a BOOLEAN variable, so the
--   count was cast (0 -> false, n -> true) and then compared as `v_a1::text =
--   '0'`, i.e. 'false' = '0', which is never true. The probe reported a leak on
--   a clean payload. Compare the booleans as booleans.
--
-- qa-273-47 — the probe asserted no cron RPC is EXECUTE-able by anon OR by
--   authenticated. The journey's own assertions are anon-scoped, and
--   `authenticated` legitimately holds EXECUTE on cron_health: that function
--   calls _dev_guard() itself and answers a non-super-admin with backend copy,
--   which is exactly what the super-admin Cron Health screen renders. Revoking
--   it would have broken that screen to satisfy an assertion the journey never
--   made. Narrowed to anon, plus the invariant that actually matters: anything
--   `authenticated` can execute must guard itself.
--
-- Spliced and marker-guarded like every other edit to this function.

do $c290f$
declare v_def text; v_new text; v_before text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';
  if v_def is null then raise exception 'c290: dev_journey_probe not found'; end if;
  if position('c290-probe-fix' in v_def) > 0 then return; end if;
  v_new := v_def;

  -- ── qa-273-47: anon-scoped, plus "authenticated implies self-guarding" ────
  v_before := v_new;
  v_new := replace(v_new,
$a$    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute'));$a$,
$a$    -- c290-probe-fix: anon is the key that ships in the bundle, and it is the
    -- key this journey is about. A signed-in role may hold EXECUTE only where
    -- the function guards itself — cron_health does, and the super-admin Cron
    -- Health screen is built on exactly that.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('anon', p.oid, 'execute');
    select count(*) = 0 into v_a5
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and p.prosrc not like '%_dev_guard()%';$a$);
  if v_new = v_before then raise exception 'c290: qa-273-47 privilege anchor moved'; end if;

  v_before := v_new;
  v_new := replace(v_new,
$b$    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon/authenticated='||coalesce(v_a2,false)::text||$b$,
$b$    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | every signed-in-reachable cron RPC guards itself='||coalesce(v_a5,false)::text||$b$);
  if v_new = v_before then raise exception 'c290: qa-273-47 verdict anchor moved'; end if;

  -- ── qa-274-57: compare booleans as booleans ──────────────────────────────
  v_before := v_new;
  v_new := replace(v_new,
$c$    v_ok := coalesce(v_pass_count,0) > 0
        and v_a1::text = '0' and v_a2::text = '0'
        and v_a3::text = '0' and v_a4::text = '0';$c$,
$c$    -- c290-probe-fix: v_a1..v_a4 are booleans, so each count arrived already
    -- cast (0 -> false, n -> true). Comparing 'false' to '0' failed a clean
    -- payload every time.
    v_ok := coalesce(v_pass_count,0) > 0
        and not coalesce(v_a1,true) and not coalesce(v_a2,true)
        and not coalesce(v_a3,true) and not coalesce(v_a4,true);$c$);
  if v_new = v_before then raise exception 'c290: qa-274-57 verdict anchor moved'; end if;

  v_before := v_new;
  v_new := replace(v_new,
$d$        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | cards leaking a ptr key='||v_a1::text||
        ' | cards with card_price.has_ptr not false='||v_a2::text||
        ' | cards missing the locked note='||v_a3::text||
        ' | cards not in display_mode=mrp_only='||v_a4::text));$d$,
$d$        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | any card leaking a ptr key='||coalesce(v_a1,true)::text||
        ' | any card with card_price.has_ptr not false='||coalesce(v_a2,true)::text||
        ' | any card missing the locked note='||coalesce(v_a3,true)::text||
        ' | any card not in display_mode=mrp_only='||coalesce(v_a4,true)::text));$d$);
  if v_new = v_before then raise exception 'c290: qa-274-57 evidence anchor moved'; end if;

  execute v_new;
end $c290f$;

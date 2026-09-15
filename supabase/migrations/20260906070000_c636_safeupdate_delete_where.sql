-- replay-target: production
--
-- CHANGE #636 — the two whole-table DELETEs get a WHERE clause.
--
-- Found by running the drain for real: the lane claimed its request, called
-- autotest_safety_net_run() through PostgREST and got
--   400 {"code":"21000","message":"DELETE requires a WHERE clause"}
-- while the identical call over psql had passed on the build branch every time.
-- The difference is the CALLER, not the code: PostgREST connects as
-- `authenticator`, which preloads supautils' `safeupdate`, and that hook
-- rejects an unqualified DELETE or UPDATE. A migration replay runs as
-- `postgres` and never sees it — so a bug of exactly this shape is invisible to
-- every psql check and only appears the first time a real client calls the RPC.
--
-- `where true` is the whole fix: same semantics, same plan (the planner drops a
-- constant-true qual), and it satisfies the hook. The two functions are
-- re-emitted verbatim from the live catalogue with that one line changed, so
-- nothing else about them moves.


CREATE OR REPLACE FUNCTION public.autotest_auth_matrix_build()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rpcs int := 0; v_unclassified int := 0;
begin
  perform public._dev_guard();

  delete from public.autotest_rpc_audience where true;   -- safeupdate: an unqualified DELETE is refused for every PostgREST caller

  -- One row per NAME, not per overload: PostgREST addresses an RPC by name, so
  -- an overload set is only as guarded as its weakest member (bool_and) and as
  -- reachable as its most exposed one (bool_or).
  insert into public.autotest_rpc_audience
    (proname, audience, source, authoritative, args, is_secdef,
     guard_tokens, has_guard, anon_exec, auth_exec)
  select f.proname,
         coalesce(a.audience, array['admin','super_admin']::text[]),
         coalesce(a.source, 'unclassified'),
         coalesce(a.authoritative, false),
         f.args, f.is_secdef, f.guard_tokens, f.has_guard, f.anon_exec, f.auth_exec
    from (
      select c.proname,
             left(string_agg(c.args, ' | ' order by c.args), 400) as args,
             bool_or(c.is_secdef)   as is_secdef,
             bool_or(c.anon_exec)   as anon_exec,
             bool_or(c.auth_exec)   as auth_exec,
             bool_and(cardinality(public._autotest_guard_tokens(c.src)) > 0) as has_guard,
             (select coalesce(array_agg(distinct g), '{}'::text[])
                from unnest(array_agg(c.src)) s,
                     unnest(public._autotest_guard_tokens(s)) g) as guard_tokens
        from public.autotest_rpc_catalog() c
       group by c.proname
    ) f
    left join lateral public.autotest_audience_for(f.proname) a on true;

  get diagnostics v_rpcs = row_count;
  select count(*) into v_unclassified
    from public.autotest_rpc_audience where source = 'unclassified';

  return jsonb_build_object('ok', true, 'rpcs', v_rpcs,
                            'unclassified', v_unclassified,
                            'roles', (select count(*) from public.autotest_role where enabled),
                            'checks', v_rpcs * (select count(*) from public.autotest_role where enabled));
end $function$;


CREATE OR REPLACE FUNCTION public.autotest_auth_matrix_run(p_run_id bigint DEFAULT NULL::bigint, p_rebuild boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_total bigint; v_fail int := 0; v_unclassified int; v_gaps int := 0;
  v_probed int := 0; v_confirmed int := 0; v_cleared int := 0; v_susp bigint := 0;
  v_max int; v_r record; v_res jsonb; v_missing text;
begin
  perform public._dev_guard();
  select auth_probe_max into v_max from public.autotest_config where id = 1;

  if coalesce(p_rebuild, true) then perform public.autotest_auth_matrix_build(); end if;

  delete from public.autotest_auth_check where true;   -- safeupdate: an unqualified DELETE is refused for every PostgREST caller

  -- The matrix: every RPC x every enabled role, judged from the schema.
  with cell as (
    select a.proname, r.role_key, a.audience, a.authoritative, a.source,
           a.args, a.is_secdef, a.has_guard, a.guard_tokens,
           (r.role_key = any (a.audience)) as expected_allow,
           case
             when r.is_anon and not a.anon_exec then 'deny'
             when (not r.is_anon) and not a.auth_exec then 'deny'
             when a.is_secdef and not a.has_guard then 'open'
             when a.has_guard then 'guarded'
             else 'scoped'
           end as observed
      from public.autotest_rpc_audience a
      cross join public.autotest_role r
     where r.enabled
  ), judged as (
    select c.*,
           case
             when not c.expected_allow and c.observed = 'open' then 'fail'
             when c.expected_allow and c.observed = 'deny'      then 'fail'
             when c.source = 'unclassified'                     then 'unclassified'
             else 'pass'
           end as verdict
      from cell c
  )
  insert into public.autotest_auth_check
    (run_id, proname, role_key, expected, observed, verdict, severity, evidence)
  select p_run_id, j.proname, j.role_key,
         case when j.expected_allow then 'allow' else 'deny' end,
         j.observed, j.verdict,
         case
           when j.verdict <> 'fail' then null
           when j.expected_allow    then 'high'
           when j.authoritative     then 'critical'
           else 'medium'
         end,
         format('%s(%s) · secdef=%s · guards=%s · audience=%s · rule=%s',
                j.proname, j.args, j.is_secdef,
                coalesce(array_to_string(j.guard_tokens, '+'), 'none'),
                array_to_string(j.audience, ','), j.source)
    from judged j
   where j.verdict = 'fail';

  get diagnostics v_fail = row_count;
  select count(*) into v_total
    from public.autotest_rpc_audience a
    cross join public.autotest_role r where r.enabled;
  select count(*) into v_unclassified
    from public.autotest_rpc_audience where source = 'unclassified';

  -- Roles with no impersonable login can only ever be judged statically. Say so
  -- once, set-based, instead of burning the probe budget discovering it.
  update public.autotest_auth_check k
     set verdict = 'not_covered', severity = 'medium',
         evidence = evidence || ' · no test identity for this role'
   where k.verdict = 'fail'
     and k.role_key in (
       select r.role_key from public.autotest_role r
        where r.enabled and not r.is_anon
          and public._autotest_identity(r.role_key) is null);

  select count(*) into v_fail
    from public.autotest_auth_check where verdict in ('fail','proven');

  -- FINDINGS.
  --   proven reach          -> one row each, critical when the audience is
  --                            authoritative (this is the #570 shape)
  --   unreachable audience  -> one row each, there are never many
  --   everything else       -> aggregates, because a safety net nobody reads
  --                            is not a safety net
  for v_r in
    select proname, role_key, evidence from public.autotest_auth_check
     where verdict = 'fail' and expected = 'allow' order by proname limit 40
  loop
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s is closed to %s, its own audience', v_r.proname, v_r.role_key),
      'broken', 'high', 'auth_matrix', v_r.evidence,
      'Grant EXECUTE to that role, or correct the audience rule.',
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end loop;

  select count(*) into v_susp from public.autotest_auth_check
   where verdict = 'fail' and expected = 'deny';
  if v_susp > 0 then
    select string_agg(distinct proname, ', ') into v_missing
      from (select proname from public.autotest_auth_check
             where verdict = 'fail' and expected = 'deny'
               and severity = 'critical' order by proname limit 25) s;
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s auth-matrix suspicions still unproven', v_susp),
      'partial', 'medium', 'auth_matrix',
      format('SECURITY DEFINER RPCs with no recognisable guard, reachable by a role outside their declared audience. Not yet probed (budget %s per run). First 25 critical: %s',
             coalesce(v_max,0), coalesce(v_missing,'')),
      'Raise autotest_config.auth_probe_max, or add the guard token to _autotest_guard_tokens if these are already guarded.',
      'M', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end if;

  if v_unclassified > 0 then
    select string_agg(proname, ', ' order by proname) into v_missing
      from (select proname from public.autotest_rpc_audience
             where source = 'unclassified' order by proname limit 25) u;
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s RPCs have no declared audience', v_unclassified),
      'missing', 'medium', 'auth_matrix',
      format('No rule in autotest_audience_rule claims these, so the matrix defaults them closed and can prove nothing. First 25: %s', coalesce(v_missing,'')),
      'Add a rule (or an exact override) in autotest_audience_rule.',
      'M', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end if;

  for v_r in
    select r.role_key from public.autotest_role r
     where r.enabled and not r.is_anon
       and public._autotest_identity(r.role_key) is null
     order by r.sort
  loop
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('No test identity for role %s', v_r.role_key),
      'missing', 'high', 'auth_matrix',
      format('The QA identity ledger has no ready, resolvable login for %s, so every allow/deny for that role is static only — never proven.', v_r.role_key),
      'Create the login and mark it ready in the QA identity ledger.',
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end loop;

  if p_run_id is not null then
    update public.autotest_run
       set auth_total = v_total, auth_failed = v_fail,
           gaps_written = gaps_written + v_gaps,
           summary = summary || jsonb_build_object('auth', jsonb_build_object(
             'checks', v_total, 'failed', v_fail, 'unclassified', v_unclassified,
             'probed', v_probed, 'proven', v_confirmed, 'cleared', v_cleared))
     where id = p_run_id;
  end if;

  return jsonb_build_object('ok', true, 'checks', v_total, 'failed', v_fail,
    'unclassified', v_unclassified, 'probed', v_probed,
    'proven', v_confirmed, 'cleared_by_probe', v_cleared, 'gaps', v_gaps);
end $function$;

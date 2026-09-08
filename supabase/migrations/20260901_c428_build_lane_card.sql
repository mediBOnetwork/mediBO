-- CHANGE #428 (3/3) — the Build lane card tells the truth about the queue.
--
-- Two things #428 makes true had nowhere to show: WHY a command is not chained
-- (the exempt list) and whether the queue is starving a runner right now. Both
-- are new SECTIONS in the payload. BuildLaneSection renders sections in payload
-- order and has never needed to know their names (pinned by
-- test/protected/build_contention_test.dart), so this is zero Dart.
--
-- The headline also stops leading with a lease-refusal count and leads with the
-- number that actually matters: how many pending commands a runner can claim
-- right now. On the morning this landed that number was 1 of 28 and nobody
-- could see it.
--
-- Idempotent: create or replace.
create or replace function public.build_contention_status(p_days integer default 7)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_conf int; v_polls int; v_def int; v_grant int; v_chained int;
  v_debt int; v_debt_lines bigint; v_waiters int;
  v_since timestamptz; v_hot jsonb; v_chains jsonb; v_debt_rows jsonb; v_live jsonb;
  v_exempt jsonb; v_exempt_n int; v_pending int; v_free int; v_max int;
  v_wd jsonb; v_wd_rows jsonb;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Build lane is visible to super-admins only.');
  end if;
  v_since := now() - make_interval(days => greatest(coalesce(p_days,7),1));

  select count(distinct (command_id::text || '|' || coalesce(path,'')))
           filter (where kind='conflict'),
         count(*) filter (where kind='conflict'),
         count(*) filter (where kind='deferred'),
         count(*) filter (where kind='granted'),
         count(distinct command_id) filter (where kind='conflict')
    into v_conf, v_polls, v_def, v_grant, v_waiters
  from lease_event where at >= v_since;

  select count(*) filter (where coalesce(chain_reason,'') <> ''), count(*)
    into v_chained, v_pending
    from dev_commands where status='pending';
  v_free := greatest(v_pending - v_chained, 0);

  select coalesce((value->'chain'->>'max_blockers')::int, 3) into v_max
    from dev_runner_config where key='worker_pool';

  select count(*) into v_exempt_n from file_shared_surface where active;
  select count(*), coalesce(sum(lines),0) into v_debt, v_debt_lines from god_file_debt;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', path,
           'detail', 'last hit ' || _ist_age(mx) ||
                     case when attempts > cmds
                          then ' · ' || attempts || ' retries while waiting'
                          else '' end,
           'value_label', cmds || ' command' || case when cmds=1 then '' else 's' end || ' blocked',
           'tone', case when cmds >= 3 then 'error' when cmds >= 1 then 'warning' else 'neutral' end)
         order by cmds desc, attempts desc), '[]')
    into v_hot
  from (select path, count(distinct command_id) cmds, count(*) attempts, max(at) mx
          from lease_event
         where kind in ('conflict','deferred') and at >= v_since
         group by path order by count(distinct command_id) desc, count(*) desc limit 8) h;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', '#' || id || ' · ' || left(_dev_title(title, build_log), 48),
           'detail', chain_reason,
           'value_label', 'waiting, not building',
           'tone', 'info') order by id), '[]')
    into v_chains
  from dev_commands where status='pending' and coalesce(chain_reason,'') <> '';

  -- CHANGE #428 — the exempt list, rendered so the rule is auditable rather
  -- than folklore. Each row says what it is and why it never chains.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', label || ' · ' || path,
           'detail', reason,
           'value_label', 'never chains',
           'tone', 'success') order by id), '[]')
    into v_exempt
  from file_shared_surface where active;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', name,
           'detail', 'first seen ' || _ist_age(first_seen) || ' · seen ' || seen_count || '×',
           'value_label', 'starving',
           'tone', 'error') order by last_seen desc), '[]')
    into v_wd_rows
  from rg_alerts
   where kind = 'chain_starvation' and last_seen >= now() - interval '30 minutes';

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', path,
           'detail', reason,
           'value_label', to_char(lines, 'FM9,99,990') || ' lines',
           'tone', case when lines >= 5000 then 'error' when lines >= 2000 then 'warning' else 'neutral' end)
         order by lines desc), '[]')
    into v_debt_rows
  from (select * from god_file_debt order by lines desc limit 8) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', fl.path,
           'detail', 'held by #' || fl.command_id || ' · ' || coalesce(fl.worker,'—'),
           'value_label', _ist_age(fl.leased_at),
           'tone', 'neutral') order by fl.leased_at), '[]')
    into v_live
  from file_leases fl;

  return jsonb_build_object(
    'ok', true,
    'title', 'Build lane',
    'subtitle', 'Collisions are decided in SQL before a worker boots. Only two EXACT, non-shared paths chain — an append-only registry and a directory glob never do, because the merge queue merges the first and file leases guard the rest.',
    'mode_label', case when v_conf = 0 then 'NO COLLISIONS' else 'COLLISIONS: ' || v_conf end,
    'mode_tone',  case when v_conf = 0 then 'success' when v_conf <= 2 then 'warning' else 'error' end,
    'headline', jsonb_build_object(
      'label', v_free || ' of ' || v_pending || ' pending command'
               || case when v_pending=1 then '' else 's' end || ' claimable right now',
      'detail', v_chained || ' auto-chained (cap ' || coalesce(v_max,3) || ' blocker'
                || case when coalesce(v_max,3)=1 then '' else 's' end || ' each) · '
                || v_exempt_n || ' shared surfaces exempt · '
                || v_grant || ' files leased · ' || v_def || ' deferred and picked up later'
                || case when v_polls > v_conf
                     then ' · ' || v_polls || ' retries spent waiting (a build that polls is a build not building)'
                     else '' end,
      'tone', case when v_free = 0 and v_pending > 0 then 'error'
                   when v_chained = 0 then 'success' else 'warning' end),
    'sections', jsonb_build_array(
      jsonb_build_object('heading', 'Queue starvation watchdog',
        'empty_hint', 'No runner has idled beside a chained queue in the last 30 minutes.',
        'rows', v_wd_rows),
      jsonb_build_object('heading', 'Auto-chained — queued, not parked',
        'empty_hint', 'Nothing is queued behind another command right now.',
        'rows', v_chains),
      jsonb_build_object('heading', 'Conflict-exempt shared surfaces — ' || v_exempt_n || ' registered',
        'empty_hint', 'No surface is exempt — every predicted path can chain.',
        'rows', v_exempt),
      jsonb_build_object('heading', 'Files held right now',
        'empty_hint', 'No worker is holding a file.',
        'rows', v_live),
      jsonb_build_object('heading', 'Most contended files',
        'empty_hint', 'No file has been fought over in this window.',
        'rows', v_hot),
      jsonb_build_object('heading', 'God-file debt — ' || v_debt || ' files, ' || to_char(v_debt_lines,'FM9,99,99,990') || ' lines',
        'empty_hint', 'No Dart file is over the threshold. Run scripts/god_files.sh to refresh.',
        'rows', v_debt_rows)),
    'window_label', 'Last ' || p_days || ' days');
end $function$;

-- replay-target: control-plane
-- CHANGE #1823 — the critical-path smoke verdict lives on the batch, and the
-- Deploy lane card prints it. Until now the only record of a red smoke was a
-- line in merge_worker.journal, and the line every batch printed was
-- "could not run (exit 2) — not treated as a failure".
--
--   deploy_batch.smoke          one jsonb: verdict, exit, totals, failed[], blocked[], target, note, at
--   merge_batch_smoke()         the merge worker records the verdict right after the run
--   merge_batch_smoke_status()  the sentence + tone the card prints (has:false when none yet)
--   deploy_lane_status()        gains a 'smoke' block
-- Idempotent.

alter table public.deploy_batch add column if not exists smoke jsonb;

create or replace function public._smoke_sentence(p_batch bigint, p_smoke jsonb)
returns jsonb
language plpgsql stable
set search_path to 'public'
as $$
declare v text := coalesce(p_smoke->>'verdict','');
        t jsonb := coalesce(p_smoke->'totals','{}'::jsonb);
        n_pass int := coalesce((t->>'passed')::int,0);
        n_fail int := coalesce((t->>'failed')::int,0);
        n_block int := coalesce((t->>'blocked')::int,0);
        v_red text; v_label text; v_tone text; v_detail text;
begin
  if v = '' then return jsonb_build_object('has', false); end if;
  v_red := (select string_agg(x, ', ') from (select jsonb_array_elements_text(coalesce(p_smoke->'failed','[]'::jsonb)) x limit 4) q);
  v_label := case v
    when 'passed'  then 'Critical-path smoke passed — ' || n_pass || ' journey' || case when n_pass = 1 then '' else 's' end || ' green'
                        || case when n_block > 0 then ', ' || n_block || ' blocked' else '' end
    when 'failed'  then 'Critical-path smoke FAILED — ' || n_fail || ' red: ' || coalesce(v_red,'?')
                        || ' · batch ' || p_batch || ' not deployed'
    when 'crashed' then 'Critical-path smoke crashed mid-run (exit 3) — ' || coalesce(nullif(p_smoke->>'note',''),'no detail')
                        || ' · batch ' || p_batch || ' not deployed'
    when 'blocked' then 'Critical-path smoke could not run — ' || n_block || ' journey' || case when n_block = 1 then '' else 's' end
                        || ' blocked, nothing green (exit 2) · batch ' || p_batch || ' shipped unverified'
    else                'Critical-path smoke could not run — ' || coalesce(nullif(p_smoke->>'note',''),'no detail')
                        || ' (exit ' || coalesce(p_smoke->>'exit','2') || ') · batch ' || p_batch || ' shipped unverified' end;
  v_tone := case v when 'passed' then 'success' when 'failed' then 'error' when 'crashed' then 'error' else 'warning' end;
  v_detail := 'batch ' || p_batch
    || case when coalesce(p_smoke->>'target','') <> '' then ' · ' || (p_smoke->>'target') else '' end
    || case when (p_smoke->>'at') is not null
            then ' · ' || to_char((p_smoke->>'at')::timestamptz at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST'
            else '' end;
  return jsonb_build_object('has', true, 'verdict', v, 'label', v_label, 'tone', v_tone,
                            'detail', v_detail, 'batch_id', p_batch,
                            'passed', n_pass, 'failed', n_fail, 'blocked', n_block);
end $$;

create or replace function public.merge_batch_smoke(
  p_batch bigint, p_verdict text, p_exit integer default null,
  p_totals jsonb default '{}'::jsonb, p_failed jsonb default '[]'::jsonb,
  p_blocked jsonb default '[]'::jsonb, p_target text default null, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare b deploy_batch%rowtype; v jsonb;
begin
  perform _dev_guard();
  if p_verdict not in ('passed','failed','crashed','blocked','not_run') then
    return jsonb_build_object('ok', false, 'error', 'bad_verdict', 'allowed', 'passed|failed|crashed|blocked|not_run');
  end if;
  v := jsonb_build_object('verdict', p_verdict, 'exit', p_exit,
         'totals', coalesce(p_totals,'{}'::jsonb), 'failed', coalesce(p_failed,'[]'::jsonb),
         'blocked', coalesce(p_blocked,'[]'::jsonb), 'target', p_target, 'note', p_note, 'at', now());
  update deploy_batch set smoke = v,
         log = coalesce(log,'[]'::jsonb) || jsonb_build_object('at', now(), 'phase', 'smoke_verdict', 'verdict', p_verdict, 'exit', p_exit)
   where id = p_batch
  returning * into b;
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'no_such_batch'); end if;
  return jsonb_build_object('ok', true, 'batch_id', b.id) || public._smoke_sentence(b.id, v);
end $$;
revoke all on function public.merge_batch_smoke(bigint,text,integer,jsonb,jsonb,jsonb,text,text) from public, anon;
grant execute on function public.merge_batch_smoke(bigint,text,integer,jsonb,jsonb,jsonb,text,text) to service_role;

create or replace function public.merge_batch_smoke_status()
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce((select public._smoke_sentence(b.id, b.smoke)
                     from deploy_batch b where b.smoke is not null
                    order by b.id desc limit 1),
                  jsonb_build_object('has', false));
$$;
revoke all on function public.merge_batch_smoke_status() from public, anon;
grant execute on function public.merge_batch_smoke_status() to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.deploy_lane_status(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l deploy_lock%rowtype; cfg jsonb := _mq_cfg();
        v_wait int; v_target int; v_busy boolean;
        v_hold_avg numeric; v_wait_avg numeric; v_n int;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Deploy lane is visible to super-admins only.');
  end if;
  select * into l from deploy_lock where id = 1;
  v_busy   := l.token is not null and l.expires_at > now();
  v_target := coalesce((cfg->>'target_hold_s')::int, 60);
  select count(*) into v_wait from deploy_queue where status = 'waiting';

  select count(*), avg(hold_s), avg(wait_s) into v_n, v_hold_avg, v_wait_avg
    from deploy_registry
   where deployed_at is not null and deployed_at > now() - interval '7 days';

  return jsonb_build_object(
    'ok', true,
    'title', 'Deploy lane',
    'subtitle', case when coalesce((cfg->>'enabled')::boolean, true)
                     then 'Merge queue — runners push a branch and leave; one worker batches, tests once, deploys once.'
                     else 'Merge queue is OFF — runners fall back to holding the lane one at a time.' end,
    'mode_label', case when coalesce((cfg->>'enabled')::boolean, true) then 'MERGE QUEUE' else 'MUTEX (legacy)' end,
    'mode_tone',  case when coalesce((cfg->>'enabled')::boolean, true) then 'success' else 'warning' end,
    'lane', jsonb_build_object(
      'busy', v_busy,
      'label', case when v_busy then 'Lane held by ' || coalesce(l.holder,'?') else 'Lane free' end,
      'detail', case when v_busy
        then coalesce(l.title,'merge batch') || ' · held ' ||
             extract(epoch from now() - l.acquired_at)::int || 's'
        else 'Nothing merging right now.' end,
      'held_label', case when v_busy then extract(epoch from now() - l.acquired_at)::int || 's' else '—' end,
      'over_target', case when v_busy then extract(epoch from now() - l.acquired_at)::int > v_target else false end,
      'tone', case when not v_busy then 'success'
                   when extract(epoch from now() - l.acquired_at)::int > v_target then 'error'
                   else 'info' end),
    'queue', jsonb_build_object(
      'count', v_wait,
      'label', case when v_wait = 0 then 'Queue empty'
                    when v_wait = 1 then '1 branch waiting'
                    else v_wait || ' branches waiting' end,
      'empty_hint', 'Runners push a branch here and go straight back to building. Nothing waits on a lock.',
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'entry_id', id, 'command_id', command_id,
                 'label', case when command_id is null then title else '#'||command_id||' · '||title end,
                 'detail', agent || ' · ' || branch,
                 'value_label', 'waiting ' || extract(epoch from now() - pushed_at)::int || 's',
                 'tone', 'info') order by pushed_at), '[]'::jsonb)
               from deploy_queue where status = 'waiting'),
      -- CHANGE #1674, corrected by its own QA round: window_label belongs
      -- INSIDE queue. deploy_lane_section.dart reads queue['window_label']
      -- and build_speed_test.dart's fixture nests it there — only the SQL put
      -- it at the top level, so the batch-window sentence the backend was
      -- already writing ("Batch window 90s · nothing waiting.") could never
      -- reach the card. The screen and its test agreed; the server was alone.
      'window_label', (select case
          when coalesce((cfg->>'window_s')::int, 0) <= 0 then 'Batch window off — every branch deploys alone.'
          when v_wait = 0 then 'Batch window ' || (cfg->>'window_s') || 's · nothing waiting.'
          when v_wait >= greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1)
            then 'Batch window full — ' || v_wait || ' branch(es) ship together.'
          else 'Batch window open — ' || v_wait || ' of ' ||
               greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1) ||
               ' branch(es), up to ' || (cfg->>'window_s') || 's.' end)),
    'batch', (select jsonb_build_object(
                 'id', b.id, 'status', b.status,
                 'label', 'Batch ' || b.id || ' · ' || b.entries || ' branch(es)',
                 'value_label', b.status,
                 'tone', case b.status when 'deployed' then 'success' when 'failed' then 'error' else 'info' end,
                 'change_no', b.change_no, 'evicted', b.evicted,
                 -- CHANGE #1674 — per-phase timings, so "held 891s" says WHICH half.
                 'phases', public.merge_batch_phases(b.id),
                 'slowest_label', coalesce((
                    select (e->>'phase') || ' · ' || (e->>'seconds') || 's'
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     order by (e->>'seconds')::int desc limit 1), '—'),
                 'locked_s', coalesce((
                    select sum((e->>'seconds')::int)
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     where (e->>'locked')::boolean), 0))
               from deploy_batch b
              where b.status in ('merging','testing','deploying')
              order by b.id desc limit 1),
    'metrics', jsonb_build_object(
      'heading', 'Wait vs hold, last 7 days',
      'samples', v_n,
      'avg_hold_label', case when v_hold_avg is null then 'no hold time recorded yet'
                             else 'avg lane hold ' || round(v_hold_avg)::int || 's' end,
      'avg_wait_label', case when v_wait_avg is null then 'no queue wait recorded yet'
                             else 'avg queue wait ' || round(v_wait_avg)::int || 's' end,
      'target_label', 'target hold under ' || v_target || 's',
      'tone', case when v_hold_avg is null then 'info'
                   when v_hold_avg > v_target then 'warning' else 'success' end),
    'recent_heading', 'Recent deploys',
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', r.change_no,
                 'label', '#' || r.change_no || ' · ' || r.title,
                 'detail', coalesce(r.agent,'?'),
                 'value_label', case
                    when r.deployed_at is null and r.status = 'claimed'
                      then 'claimed ' || extract(epoch from now() - r.claimed_at)::int || 's ago · never released'
                    when r.deployed_at is null then r.status
                    else 'held ' || coalesce(r.hold_s, extract(epoch from r.deployed_at - r.claimed_at)::int) || 's'
                         || case when r.wait_s is not null then ' · waited ' || r.wait_s || 's' else '' end end,
                 'tone', case r.status when 'success' then 'success'
                                     when 'expired' then 'warning'
                                     when 'failed'  then 'error' else 'info' end
                 ) order by r.change_no desc), '[]'::jsonb)
               from (select * from deploy_registry order by change_no desc limit greatest(coalesce(p_limit,12),1)) r),
    'stale_heading', 'Stale claims',
    'stale_empty', 'No claim is holding a queue slot past its TTL.',
    'stale', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', change_no,
                 'label', '#' || change_no || ' · ' || title,
                 'detail', coalesce(agent,'?'),
                 'value_label', 'held since ' || to_char(claimed_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
                 'tone', 'warning')
                 order by change_no), '[]'::jsonb)
               from deploy_registry
              where status = 'claimed'
                and claimed_at < now() - make_interval(mins => greatest(coalesce((cfg->>'claim_ttl_minutes')::int,20),5))),
    -- CHANGE #1823 — the critical-path smoke verdict, printed verbatim by the
    -- Deploy lane card. It used to live only in merge_worker.journal.
    'smoke', public.merge_batch_smoke_status(),
    'config', cfg);
end $function$;

-- CHANGE #530 (b) — the Runner boot card must REFUSE, not vanish.
--
-- The first cut called `_dev_guard()`, which RAISES for a non-super-admin. The
-- Dart section catches that, so `_boot` stayed empty and the card drew nothing
-- at all: the render log read `c530_runner_boot=absent` where the three lanes
-- beside it read `refused`. An absent card cannot be proven to have rendered.
--
-- The three lanes answer a non-super-admin with `ok:false` and their OWN
-- sentence, and the section renders that sentence. Same contract here.
create or replace function runner_boot_status(p_limit int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rows jsonb; v_recent jsonb; v_green int; v_red int; v_total int;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Runner boot is visible to super-admins only.');
  end if;

  with latest as (
    select distinct on (agent) * from runner_boot_event
     where at > now() - interval '7 days' order by agent, at desc
  )
  select coalesce(jsonb_agg(x order by x->>'agent'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'agent', l.agent, 'host', l.host, 'verdict', l.verdict,
      'verdict_label', case when l.verdict='green' then 'Green — claiming'
                           else 'Red — refusing to claim' end,
      'tone', case when l.verdict='green' then 'success' else 'error' end,
      'at_label', to_char(l.at at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST',
      'reason_label', 'Boot: ' || l.boot_reason,
      'timing_label', case when l.duration_ms > 0
                          then 'Doctor ran in ' || round(l.duration_ms/1000.0,1)::text || 's'
                          else 'Doctor timing not recorded' end,
      'released_label', case when l.released_rows = 0 then 'No stale claims to release'
                            when l.released_rows = 1 then '1 stale claim released'
                            else l.released_rows::text || ' stale claims released' end,
      'repairs_label', case when jsonb_array_length(coalesce(l.repairs,'[]'::jsonb)) = 0
                             then 'Workspace was already clean'
                           when jsonb_array_length(l.repairs) = 1 then '1 repair applied'
                           else jsonb_array_length(l.repairs)::text || ' repairs applied' end,
      'repairs', coalesce(l.repairs,'[]'::jsonb),
      'checks',  coalesce(l.checks,'[]'::jsonb),
      'failed_label', (select case when count(*) = 0 then ''
                                   else count(*)::text || ' check(s) failed' end
                         from jsonb_array_elements(coalesce(l.checks,'[]'::jsonb)) e
                        where coalesce((e->>'ok')::boolean,false) = false)
    ) as x from latest l
  ) s;

  select count(*) filter (where verdict='green'), count(*) filter (where verdict='red'), count(*)
    into v_green, v_red, v_total
    from (select distinct on (agent) agent, verdict from runner_boot_event
           where at > now() - interval '7 days' order by agent, at desc) q;

  select coalesce(jsonb_agg(jsonb_build_object(
           'at_label', to_char(at at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST',
           'agent', agent, 'verdict', verdict,
           'tone', case when verdict='green' then 'success' else 'error' end,
           'detail', case when verdict='green' then 'Workspace green — claims allowed'
                          else 'Refused to claim until the doctor passes' end
         ) order by at desc), '[]'::jsonb) into v_recent
  from (select * from runner_boot_event order by at desc limit greatest(coalesce(p_limit,12),1)) r;

  return jsonb_build_object(
    'ok', true, 'title', 'Runner boot',
    'subtitle', 'Every runner runs the workspace doctor before it claims: git debris cleared, '
             || 'workspace reset to origin/main, toolchain proven, stale claims released. '
             || 'A red verdict means that runner refuses to claim until it is green.',
    'mode_label', case when v_total = 0 then 'No boots recorded'
                       when v_red = 0 then 'All runners green'
                       when v_red = 1 then '1 runner red'
                       else v_red::text || ' runners red' end,
    'mode_tone', case when v_total = 0 then 'neutral'
                      when v_red = 0 then 'success' else 'error' end,
    'counts_label', v_green::text || ' green · ' || v_red::text || ' red (last 7 days)',
    'runners', v_rows, 'runners_head', 'Latest boot per runner',
    'empty_label', 'No runner has booted since this was switched on. '
                || 'The next runner start writes the first verdict here.',
    'recent_head', 'Recent boots', 'recent', v_recent);
end $$;

revoke execute on function runner_boot_status(int) from anon, public;
grant  execute on function runner_boot_status(int) to service_role, authenticated;

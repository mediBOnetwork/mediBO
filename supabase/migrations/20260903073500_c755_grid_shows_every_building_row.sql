-- CHANGE #755 (follow-up) — the worker grid stops hiding live work.
--
-- Found while verifying #755: the devops journey worker-grid-loads asserts
-- "every command that has been building for over two minutes has a chip", and
-- it was red with #753 AND #754 both building, both heartbeating, both claimed
-- by runner-3. dev_supervisor_tick returns ONE row per agent (`limit 1`), so
-- the supervisor could only ever draw one chip for that agent and the second
-- command was invisible in the app — the exact opposite of what the grid is
-- for. A row can end up double-claimed (a release + re-claim while the agent
-- still holds one, or a claim_batch), and when it does Om must SEE it.
--
-- `slots` keeps its shape — one row per agent, the newest heartbeat — so every
-- existing reader is untouched. `extra_slots` carries whatever else that agent
-- is holding, and the supervisor appends a chip per entry.
--
-- Idempotent: create or replace only.

create or replace function public.dev_supervisor_tick(
  p_agents text[] default '{}'::text[],
  p_routes text[] default array['fast'::text, 'opus'::text])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ctl jsonb; v_slots jsonb; v_routes jsonb; v_extra jsonb;
begin
  perform _dev_guard();

  v_ctl := public.dev_ctl_get();

  select coalesce(jsonb_object_agg(a.agent, coalesce(b.row_json, 'null'::jsonb)), '{}'::jsonb)
    into v_slots
  from unnest(coalesce(p_agents,'{}')) a(agent)
  left join lateral (
    select jsonb_build_object(
             'id', c.id, 'title', c.title, 'model', c.model, 'effort', c.effort,
             'model_label', _dev_model_label(c.model), 'effort_label', _dev_effort_label(c.effort),
             'eta_left_s', c.eta_left_s, 'started_at', c.started_at,
             'heartbeat_at', c.heartbeat_at) as row_json
      from dev_commands c
     where c.status = 'building' and c.claimed_by = a.agent and c.id > 0
     order by c.heartbeat_at desc nulls last
     limit 1
  ) b on true;

  -- Everything the fleet is building that `slots` could not carry: a second
  -- row on an agent, or a row claimed by an agent outside p_agents. Ordered so
  -- the grid is stable between ticks.
  select coalesce(jsonb_agg(x.row_json order by x.id), '[]'::jsonb)
    into v_extra
  from (
    select c.id,
           jsonb_build_object(
             'id', c.id, 'agent', c.claimed_by, 'title', c.title,
             'model', c.model, 'effort', c.effort,
             'model_label', _dev_model_label(c.model),
             'effort_label', _dev_effort_label(c.effort),
             'eta_left_s', c.eta_left_s, 'started_at', c.started_at,
             'heartbeat_at', c.heartbeat_at) as row_json
      from dev_commands c
     where c.status = 'building' and c.id > 0
       and c.id is distinct from (v_slots #>> array[coalesce(c.claimed_by,''), 'id'])::bigint
  ) x;

  select coalesce(jsonb_object_agg(r.route, coalesce(k.n, 0)), '{}'::jsonb)
    into v_routes
  from unnest(coalesce(p_routes,'{}')) r(route)
  left join lateral (
    select count(*)::int n from dev_commands c
     where c.status = 'pending' and c.route = r.route and c.id > 0
  ) k on true;

  return jsonb_build_object(
    'ok', true,
    'server_time', now(),
    'ctl', v_ctl,
    'workflow', coalesce(v_ctl #>> '{desired_state,workflow}', 'on'),
    'active_host', coalesce(nullif(v_ctl #>> '{pool,config,active_host}',''),
                            (select value #>> '{active_host}' from dev_runner_config
                              where key = 'worker_pool'), ''),
    'pending_count',  (select count(*)::int from dev_commands
                        where status = 'pending'  and id > 0),
    'building_count', (select count(*)::int from dev_commands
                        where status = 'building' and id > 0),
    'android_requested',
      (select count(*)::int from dev_commands
        where android_status = 'requested' and id > 0),
    'pending_by_route', v_routes,
    'slots', v_slots,
    'extra_slots', v_extra);
end $$;

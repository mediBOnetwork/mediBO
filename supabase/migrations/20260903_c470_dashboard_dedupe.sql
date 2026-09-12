-- CHANGE #470 — the action strip lists a stalled order once, not twice.

CREATE OR REPLACE FUNCTION public._dashboard_ops_build(p_zone smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_funnel jsonb := '[]'::jsonb;
  v_needs  jsonb := '[]'::jsonb;
  v_total  int   := 0;
  v_ring   jsonb;
  v_done   int   := 0;
  v_prom   int   := 0;
  v_today  date  := (now() at time zone 'Asia/Kolkata')::date;
begin
  with cur as (select s.* from public._ops_order_stage(nullif(p_zone, 0)) s),
  per as (
    select f.stage_key, f.label, f.sort_order, f.route_key, f.deep_link,
           coalesce((select count(*) from cur c where c.stage_key = any (f.source_stages)), 0)::int as n
      from public.dashboard_funnel_stage f
     where f.is_active
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',        p.stage_key,
           'label',      p.label,
           'count',      p.n,
           'count_label', p.n::text,
           'route_key',  p.route_key,
           'deep_link',  p.deep_link) order by p.sort_order), '[]'::jsonb),
         coalesce(sum(p.n), 0)::int
    into v_funnel, v_total
    from per p;

  with cur as (select s.* from public._ops_order_stage(nullif(p_zone, 0)) s),
  ops as (
    select 'ops:' || c.order_id::text || ':' || c.stage_key            as id,
           coalesce(nullif(c.order_code, ''), 'Order ' || left(c.order_id::text, 8)) as label,
           coalesce(nullif(c.customer, ''), st.label)                  as sub_label,
           coalesce(h.entered_at, c.since, c.created_at)               as since,
           st.owner_label, st.label as stage_label, st.next_action,
           cfg.sla_minutes
      from cur c
      join public.sla_stage st on st.stage_key = c.stage_key and st.is_active
      left join public.order_stage_history h
             on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
      left join lateral (
        select f.sla_minutes from public.sla_config f
         where f.stage_key = c.stage_key and f.is_active
           and (f.zone_id = c.zone_id or f.zone_id is null)
         order by (f.zone_id is null) limit 1) cfg on true
     where cfg.sla_minutes is not null
  ),
  ops_all as (
    select o.id, o.label, o.sub_label, o.since, o.owner_label, o.stage_label,
           o.next_action,
           (extract(epoch from (now() - o.since)) / 60.0 - o.sla_minutes)::numeric  as over_min,
           o.since + make_interval(mins => o.sla_minutes::int)           as due_at,
           null::text as action_id, 'ops'::text as source
      from ops o
  ),
  exc_all as (
    select 'exc:' || r.reason_code || ':' || r.ref_id                  as id,
           r.title                                                     as label,
           coalesce(nullif(r.subtitle, ''), '')                        as sub_label,
           r.since,
           case when x.owner_kind = 'admin' or r.zone_id is null
                then public._c('exc.owner.admin')
                else coalesce((select rp.partner_name from public.region_partners rp
                                where rp.zone_id = r.zone_id and coalesce(rp.is_active, true)
                                order by rp.id limit 1), public._c('exc.owner.admin')) end as owner_label,
           public._c('exc.reason.' || r.reason_code)                   as stage_label,
           public._c('exc.action.' || r.reason_code)                   as next_action,
           (extract(epoch from (now() - r.since)) / 60.0 - (x.sla_hours * 60.0))::numeric as over_min,
           r.since + make_interval(hours => x.sla_hours::int)          as due_at,
           r.reason_code || ':' || r.ref_id                            as action_id,
           'exception'::text                                           as source
      from public._exception_rows() r
      join public.exception_reason x
        on x.reason_code = r.reason_code and x.enabled
      left join public.exception_state s
        on s.reason_code = r.reason_code and s.ref_id = r.ref_id
     where coalesce(s.status, 'open') <> 'closed'
       -- CHANGE #470 — a stalled order is now a first-class exception, and the
       -- ops_all block above already draws it from the same sla_config. Taking
       -- it from one side only keeps the strip from listing it twice.
       and r.reason_code <> 'order_stage_stalled'
       and (p_zone = 0 or r.zone_id = p_zone or r.zone_id is null)
  ),
  -- Cleared today: the green row. Bounded to five and to one IST day, so the
  -- snapshot stays the cache read the rg rule requires.
  done_rows as (
    select 'done:' || s.reason_code || ':' || s.ref_id                 as id,
           public._c('exc.reason.' || s.reason_code)                   as label,
           coalesce(nullif(s.note, ''), nullif(s.outcome_code, ''), '') as sub_label,
           s.closed_at                                                 as since,
           coalesce(nullif(s.owner_label, ''), '')                     as owner_label,
           public._c('exc.reason.' || s.reason_code)                   as stage_label,
           ''::text                                                    as next_action,
           null::numeric                                               as over_min,
           s.closed_at                                                 as due_at,
           null::text                                                  as action_id,
           'done'::text                                                as source
      from public.exception_state s
     where s.status = 'closed'
       and s.closed_at is not null
       and (s.closed_at at time zone 'Asia/Kolkata')::date = v_today
       and (p_zone = 0 or s.zone_id = p_zone or s.zone_id is null)
     order by s.closed_at desc
     limit 5
  ),
  merged as (
    select u.*,
           case when u.source = 'done'                                  then 'done'
                when u.over_min > 0                                     then 'overdue'
                when (u.due_at at time zone 'Asia/Kolkata')::date <= v_today then 'due_today'
                else 'open' end as state
      from (select * from ops_all
            union all select * from exc_all
            union all select * from done_rows) u
  ),
  ranked as (
    select m.*,
           case m.state when 'overdue' then 1 when 'due_today' then 2
                        when 'open' then 3 else 4 end as bucket,
           case when m.state = 'done' then extract(epoch from m.due_at)::numeric
                else coalesce(m.over_min, 0)::numeric end as rank_val
      from merged m
  ),
  picked as (
    select * from ranked order by bucket asc, rank_val desc, due_at asc limit 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          m.id,
           'label',       m.label,
           'sub_label',   m.sub_label,
           'stage_label', m.stage_label,
           'state',       m.state,
           'age_label',   public.ops_age_label(m.since),
           'over_label',  case m.state
             when 'overdue' then replace(public._c('dash.needs_over'), '{d}',
                                         public.ops_dur_label((m.over_min * 60.0)::numeric))
             when 'due_today' then replace(public._c('dash.needs_due'), '{d}',
                                         public.ops_dur_label((abs(m.over_min) * 60.0)::numeric))
             when 'open' then replace(public._c('dash.needs_open'), '{d}',
                                         public.ops_dur_label((abs(m.over_min) * 60.0)::numeric))
             else replace(public._c('dash.needs_done'), '{d}',
                                         public.ops_age_label(m.since)) end,
           'owner_label', case when coalesce(nullif(m.owner_label, ''), '') = '' then ''
                               else replace(public._c('dash.needs_owner'), '{owner}', m.owner_label) end,
           'tone',        case m.state when 'overdue' then 'bad'
                                       when 'due_today' then 'warn'
                                       when 'done' then 'good'
                                       else 'neutral' end,
           'source',      m.source,
           'action',      case
             when m.state = 'done'
               then jsonb_build_object('has', false, 'kind', '', 'label', '',
                                       'rpc', '', 'args', '{}'::jsonb, 'route', '')
             when m.source = 'exception'
               then jsonb_build_object('has', true, 'kind', 'rpc',
                      'label', coalesce(nullif(m.next_action, ''), public._c('dash.needs_action')),
                      'rpc', 'exceptions_action',
                      'args', jsonb_build_object('p_id', m.action_id),
                      'route', 'exceptions')
             when m.state = 'overdue'
               then jsonb_build_object('has', true, 'kind', 'route',
                      'label', coalesce(nullif(m.next_action, ''), public._c('dash.needs_action')),
                      'rpc', '', 'args', '{}'::jsonb, 'route', 'ops_board')
             else jsonb_build_object('has', true, 'kind', 'route',
                      'label', public._c('dash.needs_view'),
                      'rpc', '', 'args', '{}'::jsonb, 'route', 'ops_board') end)
           order by m.bucket asc, m.rank_val desc, m.due_at asc), '[]'::jsonb)
    into v_needs
    from picked m;

  select count(*) filter (where d.delivered_at is not null)::int, count(*)::int
    into v_done, v_prom
    from public.deliveries d
    join public.orders o on o.id = d.order_id
   where not coalesce(o.is_synthetic, false)
     and d.promised_at is not null
     and (d.promised_at at time zone 'Asia/Kolkata')::date = v_today
     and (p_zone = 0 or coalesce(d.zone_id, o.zone_id) = p_zone);

  v_ring := jsonb_build_object(
    'has',   v_prom > 0,
    'done',  v_done,
    'total', v_prom,
    'pct',   case when v_prom > 0 then round((v_done::numeric / v_prom) * 100)::int else 0 end,
    'label', replace(replace(public._c('dash.ring_label'), '{done}', v_done::text), '{total}', v_prom::text),
    'sub_label', case when v_prom = 0 then public._c('dash.ring_none')
                      when v_done >= v_prom then public._c('dash.ring_clear')
                      else replace(public._c('dash.ring_left'), '{n}', (v_prom - v_done)::text) end);

  return jsonb_build_object(
    'funnel',      v_funnel,
    'funnel_total', v_total,
    'needs_you',   v_needs,
    'promised',    v_ring,
    'open_total',  v_total,
    'accept_open', coalesce((select (e->>'count')::int from jsonb_array_elements(v_funnel) e
                              where e->>'key' = 'received'), 0));
end $function$

;

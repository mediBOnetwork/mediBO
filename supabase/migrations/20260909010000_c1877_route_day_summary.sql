-- CMD #1877 — Routes: day summary per worker (visited / converted / km / ₹).
--
-- One RPC, route_day_summary(), answers "what did the field team actually do
-- today?" for admin_active_date() in admin_active_zone(). It feeds TWO
-- surfaces verbatim: the card at the top of the Routes tab and the compact
-- "Field" strip on the Leads tab. Every number, every label, every ₹ string
-- and the conversion percentage are formatted HERE — Flutter prints them.
--
-- Scoping is the same pair every route RPC uses since #1872: the date comes
-- from admin_active_date(), the zone from admin_active_zone() through
-- _c1872_zone_match(), and a lead worker only ever sees his own row.
--
-- Idempotent: create-or-replace functions + an ON CONFLICT DO NOTHING copy
-- seed (an admin's later wording edit must survive a replay).

-- ── copy helper: one ui_copy read with a literal fallback ─────────────────
create or replace function public._c1877_copy(p_key text, p_fallback text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(nullif((select value #>> '{}' from public.ui_copy where key = p_key), ''),
                  p_fallback);
$$;

-- ── "{label} {n}" chip, tone included ────────────────────────────────────
create or replace function public._c1877_chip(p_key text, p_label text, p_n integer, p_tone text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'key',   p_key,
    'n',     coalesce(p_n, 0),
    'tone',  p_tone,
    'label', replace(replace(public._c1877_copy('routes_day.chip', '{label} {n}'),
                             '{label}', coalesce(p_label, '')),
                     '{n}', coalesce(p_n, 0)::text));
$$;

-- ── km, always one decimal, with its unit word from copy ─────────────────
create or replace function public._c1877_km(p_km numeric)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select replace(public._c1877_copy('routes_day.km', '{km} km'),
                 '{km}', to_char(coalesce(p_km, 0), 'FM990.0'));
$$;

-- ── conversion %: converted out of the stops actually closed today ───────
create or replace function public._c1877_conv(p_converted integer, p_done integer)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when coalesce(p_done, 0) > 0 then
    jsonb_build_object(
      'pct',   round(coalesce(p_converted, 0)::numeric * 100 / p_done, 0),
      'label', replace(public._c1877_copy('routes_day.conv', '{pct}% converted'),
                       '{pct}', to_char(round(coalesce(p_converted, 0)::numeric * 100 / p_done, 0), 'FM990')),
      'has',   true)
  else
    jsonb_build_object(
      'pct',   null,
      'label', public._c1877_copy('routes_day.conv_none', 'No stops closed yet'),
      'has',   false)
  end;
$$;

-- ── the chip row shared by every worker row, the totals and the strip ────
create or replace function public._c1877_chips(
  p_planned integer, p_visited integer, p_closed integer,
  p_ni integer, p_converted integer, p_km numeric, p_cost numeric)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_array(
    public._c1877_chip('planned',
      public._c1877_copy('routes_day.planned', 'Planned'), p_planned, 'info'),
    public._c1877_chip('visited',
      coalesce(public._c1873_status_meta('visited')       ->> 'label', 'Visited'),        p_visited,   'success'),
    public._c1877_chip('closed',
      coalesce(public._c1873_status_meta('closed')        ->> 'label', 'Closed'),         p_closed,    'warning'),
    public._c1877_chip('not_interested',
      coalesce(public._c1873_status_meta('not_interested')->> 'label', 'Not interested'), p_ni,        'danger'),
    public._c1877_chip('converted',
      coalesce(public._c1873_status_meta('converted')     ->> 'label', 'Converted'),      p_converted, 'brand'),
    jsonb_build_object('key', 'km', 'n', round(coalesce(p_km, 0), 1), 'tone', 'neutral',
                       'label', public._c1877_km(p_km)),
    jsonb_build_object('key', 'cost', 'n', coalesce(p_cost, 0), 'tone', 'neutral',
                       'label', replace(public._c1877_copy('routes_day.cost', '{cost} cost'),
                                        '{cost}', public._c1875_money(p_cost))));
$$;

-- ── the RPC ──────────────────────────────────────────────────────────────
create or replace function public.route_day_summary()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_role    text     := coalesce(get_my_role(), '');
  v_admin   boolean;
  v_worker  uuid     := public.my_worker_id();
  v_allowed boolean;
  v_date    date     := public.admin_active_date();
  v_zone    smallint := public.admin_active_zone();
  v_zonelbl text;
  v_rows    jsonb    := '[]'::jsonb;
  r         record;
  n_workers integer  := 0;
  t_routes  integer  := 0;
  t_planned integer  := 0;
  t_done    integer  := 0;
  t_visited integer  := 0;
  t_closed  integer  := 0;
  t_ni      integer  := 0;
  t_conv    integer  := 0;
  t_km      numeric  := 0;
  t_min     integer  := 0;
  t_cost    numeric;
  v_cost    numeric;
  v_conv    jsonb;
  v_tconv   jsonb;
  v_chips   jsonb;
  v_header  text;
  v_empty   text;
begin
  v_admin   := v_role in ('admin', 'super_admin');
  -- Partner staff reach the Routes tab but are neither an admin nor a lead
  -- worker. #1872 learned the hard way that raising here takes the WHOLE tab
  -- down, so an unauthorised caller gets an honest ok:false payload and the
  -- card simply does not draw.
  v_allowed := v_admin or v_worker is not null;

  v_zonelbl := coalesce((select z.name from zones z where z.id = v_zone),
                        public._c1877_copy('routes_day.zone_all', 'All zones'));
  v_header  := replace(replace(
                 public._c1877_copy('routes_day.header', '{date} · {zone}'),
                 '{date}', to_char(v_date, 'FMDy DD Mon')),
                 '{zone}', v_zonelbl);

  if v_allowed then
    for r in
      with rte as (
        select rr.id       as route_id,
               rr.worker_id,
               ww.name     as worker_name,
               pp.start_min
          from route_plan_routes rr
          join route_plans       pp on pp.id = rr.plan_id
          join lead_assignments  aa on aa.id = rr.assignment_id
          left join lead_workers ww on ww.id = rr.worker_id
         where rr.included
           and aa.for_date = v_date
           and (v_admin or rr.worker_id = v_worker)
           and public._c1872_zone_match(v_zone, pp.city, aa.zone_id)
      ),
      per_route as (
        -- km driven and minutes in the field are both measured over the stops
        -- that were actually CLOSED today (any outcome — a shut shop still
        -- cost the drive). eta_min is an absolute minute-of-day since #1876,
        -- so the last closed stop's ETA minus the route's start is the time
        -- the plan says this worker spent out.
        select t.route_id, t.worker_id, t.worker_name,
               count(s.id)                                                        ::int     as planned,
               count(s.id) filter (where s.visit_status is not null)               ::int     as done,
               count(s.id) filter (where s.visit_status = 'visited')               ::int     as visited,
               count(s.id) filter (where s.visit_status = 'closed')                ::int     as closed,
               count(s.id) filter (where s.visit_status = 'not_interested')        ::int     as ni,
               count(s.id) filter (where s.visit_status = 'converted')             ::int     as converted,
               coalesce(sum(s.leg_km) filter (where s.visit_status is not null), 0)::numeric as km,
               greatest(0, coalesce(max(s.eta_min) filter (where s.visit_status is not null), 0)
                           - coalesce(t.start_min, 0))                             ::int     as mins
          from rte t
          left join route_plan_stops s on s.route_id = t.route_id and s.included
         group by t.route_id, t.worker_id, t.worker_name, t.start_min
      )
      select worker_id,
             worker_name,
             count(*)          ::int as routes,
             sum(planned)      ::int as planned,
             sum(done)         ::int as done,
             sum(visited)      ::int as visited,
             sum(closed)       ::int as closed,
             sum(ni)           ::int as ni,
             sum(converted)    ::int as converted,
             sum(km)       ::numeric as km,
             sum(mins)         ::int as mins
        from per_route
       group by worker_id, worker_name
       order by sum(converted) desc, sum(done) desc, worker_name nulls last
    loop
      v_cost  := public._c1875_cost(r.km, r.mins);
      v_conv  := public._c1877_conv(r.converted, r.done);
      v_chips := public._c1877_chips(r.planned, r.visited, r.closed, r.ni,
                                     r.converted, r.km, v_cost);

      v_rows := v_rows || jsonb_build_object(
        'worker_id',    r.worker_id,
        'worker_label', coalesce(nullif(btrim(coalesce(r.worker_name, '')), ''),
                                 public._c1877_copy('routes_day.worker_none', 'Unassigned')),
        'routes',       r.routes,
        'planned',      r.planned,
        'done',         r.done,
        'visited',      r.visited,
        'closed',       r.closed,
        'not_interested', r.ni,
        'converted',    r.converted,
        'km',           round(r.km, 1),
        'minutes',      r.mins,
        'cost_inr',     v_cost,
        'progress_label', replace(replace(
                            public._c1877_copy('routes_day.progress', '{done} of {planned} stops closed'),
                            '{done}',    r.done::text),
                            '{planned}', r.planned::text),
        'km_label',     public._c1877_km(r.km),
        'cost_label',   replace(public._c1877_copy('routes_day.cost', '{cost} cost'),
                                '{cost}', public._c1875_money(v_cost)),
        'conversion_label', v_conv ->> 'label',
        'conversion_pct',   v_conv -> 'pct',
        'chips',        v_chips);

      n_workers := n_workers + 1;
      t_routes  := t_routes  + r.routes;
      t_planned := t_planned + r.planned;
      t_done    := t_done    + r.done;
      t_visited := t_visited + r.visited;
      t_closed  := t_closed  + r.closed;
      t_ni      := t_ni      + r.ni;
      t_conv    := t_conv    + r.converted;
      t_km      := t_km      + r.km;
      t_min     := t_min     + r.mins;
    end loop;
  end if;

  t_cost  := public._c1875_cost(t_km, t_min);
  v_tconv := public._c1877_conv(t_conv, t_done);

  v_empty := case when n_workers = 0 then
    case when not v_allowed
           then public._c1877_copy('routes_day.empty_denied',
                  'Only an admin or a field worker sees the day summary.')
         when v_admin
           then public._c1877_copy('routes_day.empty_admin',
                  'No route is assigned to a worker for this date in this zone.')
         else public._c1877_copy('routes_day.empty_worker',
                  'No route assigned to you for this date.') end
  end;

  return jsonb_build_object(
    'ok',           v_allowed,
    'is_admin',     v_admin,
    'date',         v_date,
    'zone_id',      v_zone,
    'has',          n_workers > 0,
    'title',        public._c1877_copy('routes_day.title', 'Day summary'),
    'header_label', v_header,
    'count_label',  case when n_workers = 1
                      then public._c1877_copy('routes_day.count_one', '1 worker in the field')
                      else replace(public._c1877_copy('routes_day.count_many',
                                                      '{n} workers in the field'),
                                   '{n}', n_workers::text) end,
    'workers',      v_rows,
    'worker_count', n_workers,
    'empty_label',  v_empty,
    'totals',       jsonb_build_object(
      'routes',    t_routes,
      'planned',   t_planned,
      'done',      t_done,
      'visited',   t_visited,
      'closed',    t_closed,
      'not_interested', t_ni,
      'converted', t_conv,
      'km',        round(t_km, 1),
      'minutes',   t_min,
      'cost_inr',  t_cost,
      'progress_label', replace(replace(
                          public._c1877_copy('routes_day.progress', '{done} of {planned} stops closed'),
                          '{done}',    t_done::text),
                          '{planned}', t_planned::text),
      'km_label',   public._c1877_km(t_km),
      'cost_label', replace(public._c1877_copy('routes_day.cost', '{cost} cost'),
                            '{cost}', public._c1875_money(t_cost)),
      'conversion_label', v_tconv ->> 'label',
      'conversion_pct',   v_tconv -> 'pct',
      'chips',      public._c1877_chips(t_planned, t_visited, t_closed, t_ni,
                                        t_conv, t_km, t_cost)),
    -- The Leads tab prints THIS block and nothing else: same numbers, one
    -- line, its own title. Two surfaces, one RPC, no second source of truth.
    'strip',        jsonb_build_object(
      'has',        v_allowed and n_workers > 0,
      'title',      public._c1877_copy('routes_day.strip_title', 'Field today'),
      'header_label', v_header,
      'summary_label', replace(replace(replace(replace(
                        public._c1877_copy('routes_day.strip',
                          '{done} of {planned} stops · {converted} converted · {km} · {cost}'),
                        '{done}',      t_done::text),
                        '{planned}',   t_planned::text),
                        '{converted}', t_conv::text),
                        '{km}',        public._c1877_km(t_km)),
      'cost_label', replace(public._c1877_copy('routes_day.cost', '{cost} cost'),
                            '{cost}', public._c1875_money(t_cost)),
      'conversion_label', v_tconv ->> 'label',
      'chips',      public._c1877_chips(t_planned, t_visited, t_closed, t_ni,
                                        t_conv, t_km, t_cost),
      'empty_label', v_empty,
      'link_label', public._c1877_copy('routes_day.strip_link', 'Routes')));
end;
$$;

revoke all on function public.route_day_summary()    from public;
grant execute on function public.route_day_summary() to authenticated;
grant execute on function public.route_day_summary() to service_role;

-- Seed copy only — ON CONFLICT DO NOTHING so an admin's later wording edit
-- survives a replay of this file on live.
insert into ui_copy(key, value) values
  ('routes_day.title',        '"Day summary"'::jsonb),
  ('routes_day.header',       '"{date} · {zone}"'::jsonb),
  ('routes_day.count_one',    '"1 worker in the field"'::jsonb),
  ('routes_day.count_many',   '"{n} workers in the field"'::jsonb),
  ('routes_day.worker_none',  '"Unassigned"'::jsonb),
  ('routes_day.zone_all',     '"All zones"'::jsonb),
  ('routes_day.planned',      '"Planned"'::jsonb),
  ('routes_day.chip',         '"{label} {n}"'::jsonb),
  ('routes_day.km',           '"{km} km"'::jsonb),
  ('routes_day.cost',         '"{cost} cost"'::jsonb),
  ('routes_day.conv',         '"{pct}% converted"'::jsonb),
  ('routes_day.conv_none',    '"No stops closed yet"'::jsonb),
  ('routes_day.progress',     '"{done} of {planned} stops closed"'::jsonb),
  ('routes_day.empty_admin',  '"No route is assigned to a worker for this date in this zone."'::jsonb),
  ('routes_day.empty_worker', '"No route assigned to you for this date."'::jsonb),
  ('routes_day.empty_denied', '"Only an admin or a field worker sees the day summary."'::jsonb),
  ('routes_day.strip_title',  '"Field today"'::jsonb),
  ('routes_day.strip',        '"{done} of {planned} stops · {converted} converted · {km}"'::jsonb),
  ('routes_day.strip_link',   '"Routes"'::jsonb)
on conflict (key) do nothing;

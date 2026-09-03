-- CHANGE #702 — the ETA learns.
--
-- #691 made the ETA REBASE (it was written once and never again). It still
-- predicted with two constants: the optimiser's leg time, and one dwell number
-- from app_settings that was the same for every rider, every zone and every
-- hour of the day. A 6 pm run through Raipur city and a 6 am run down the
-- highway got the same answer, and the customer got the same 20-minute window
-- whether the platform had one delivery of history or a thousand.
--
-- This change closes that loop. Every completed stop now records what ACTUALLY
-- happened — travel seconds, dwell seconds, distance, hour, weekday, zone,
-- rider — and a nightly fit turns that history into three numbers the estimate
-- uses: a per-zone hour-of-day multiplier, a per-rider dwell median, and the
-- 80th-percentile error, which IS the width of the window the customer reads.
-- More history, narrower window. No external service: the whole model is a
-- median and a percentile, and Postgres already has both.
--
-- Idempotent throughout.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. WHAT ACTUALLY HAPPENED
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.delivery_leg_history (
  id           bigserial primary key,
  delivery_id  uuid,
  run_id       uuid,
  partner_id   uuid,
  zone_id      smallint,
  seq          integer,
  leg_km       numeric,      -- planned distance for the leg that ended here
  planned_min  numeric,      -- what the optimiser said the leg would take
  actual_sec   integer,      -- what it took (leg start -> arrived_at)
  dwell_sec    integer,      -- time AT this stop (arrived_at -> delivered_at)
  hour_ist     smallint,     -- 0..23, the hour the leg ENDED, in IST
  dow          smallint,     -- 0=Sunday .. 6=Saturday, IST
  started_at   timestamptz,
  ended_at     timestamptz,
  outcome      text,         -- delivered / failed / rto
  is_synthetic boolean default false,
  created_at   timestamptz default now(),
  unique (delivery_id)
);

create index if not exists delivery_leg_history_zone_hour_idx
  on public.delivery_leg_history (zone_id, hour_ist);
create index if not exists delivery_leg_history_partner_idx
  on public.delivery_leg_history (partner_id);
create index if not exists delivery_leg_history_ended_idx
  on public.delivery_leg_history (ended_at desc);

comment on table public.delivery_leg_history is
  'CHANGE #702 — one row per completed stop: the planned leg vs what it actually took. The only input the ETA model has.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE MODEL. Three scopes, one table, every number a median or a percentile.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.eta_model (
  scope      text not null,      -- 'zone_hour' | 'zone' | 'rider_dwell' | 'band' | 'global'
  key        text not null,      -- '<zone>:<hour>' | '<zone>' | '<partner_id>' | 'all'
  multiplier numeric,            -- actual / planned, for the travel scopes
  dwell_min  numeric,            -- learned dwell, for rider_dwell
  mae_min    numeric,            -- mean absolute error of the fitted estimate
  p80_min    numeric,            -- 80th-percentile abs error = the band half-width
  samples    integer not null default 0,
  fitted_at  timestamptz default now(),
  primary key (scope, key)
);

comment on table public.eta_model is
  'CHANGE #702 — the fitted ETA model. Rewritten in full by eta_model_fit(); nothing else writes it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. SETTINGS — every threshold is data
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.app_settings(key, value) values
  ('eta_fit_min_samples_zone_hour', to_jsonb(5)),
  ('eta_fit_min_samples_rider',     to_jsonb(3)),
  ('eta_fit_lookback_days',         to_jsonb(60)),
  ('eta_multiplier_min',            to_jsonb(0.5)),
  ('eta_multiplier_max',            to_jsonb(3.0)),
  ('eta_dwell_min_minutes',         to_jsonb(1)),
  ('eta_dwell_max_minutes',         to_jsonb(20)),
  ('eta_band_min_minutes',          to_jsonb(10)),
  ('eta_band_max_minutes',          to_jsonb(45)),
  ('eta_offline_minutes',           to_jsonb(3)),
  ('eta_renotify_minutes',          to_jsonb(20)),
  ('eta_breach_grace_minutes',      to_jsonb(10))
on conflict (key) do nothing;

insert into public.ui_copy(key, value) values
  ('delivery.eta_confidence_high',   to_jsonb('Based on {n} past deliveries here'::text)),
  ('delivery.eta_confidence_low',    to_jsonb('Estimate will sharpen as we learn this route'::text)),
  ('delivery.eta_breach_title',      to_jsonb('Running late'::text)),
  ('delivery.eta_breach_body',       to_jsonb('We now expect {window}. Sorry — traffic is heavier than planned.'::text)),
  ('delivery.eta_promised_label',    to_jsonb('Originally promised'::text)),
  ('exc.reason.eta_promise_breach',  to_jsonb('Delivery will miss its promise'::text))
on conflict (key) do nothing;

-- The customer's re-ETA message. Free text, so no Meta review.
insert into public.app_settings(key, value)
values ('delivery_eta_update_message', to_jsonb(
  (chr(128337) || ' *Updated arrival*' || chr(10) || chr(10) ||
   '{pharmacy}, order {code} is running a little late.' || chr(10) ||
   'New expected: {eta}' || chr(10) || chr(10) ||
   'Live track: {link}')::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. NEW COLUMNS — the band, and the throttle's memory
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.deliveries add column if not exists eta_lo timestamptz;
alter table public.deliveries add column if not exists eta_hi timestamptz;
alter table public.deliveries add column if not exists eta_notified_at timestamptz;
alter table public.deliveries add column if not exists eta_breach_at timestamptz;

comment on column public.deliveries.eta_lo is
  'CHANGE #702 — the low edge of the arrival window; eta_at minus the learned band.';
comment on column public.deliveries.eta_hi is
  'CHANGE #702 — the high edge; eta_at plus the learned band. The window NARROWS as history grows.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. CAPTURE — every closed stop writes its own history row.
--    arrived_at is what makes this honest: travel is (leg start -> arrival) and
--    dwell is (arrival -> completion). Without an arrival we record the whole
--    span as travel and leave dwell NULL, and the fit ignores a NULL.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_capture_leg(p_delivery_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_start timestamptz; v_end timestamptz; v_ist timestamp;
  v_travel int; v_dwell int;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null or d.run_id is null then return; end if;
  if d.delivered_at is null and d.status not in ('failed','rto') then return; end if;

  -- the leg started when the rider left the previous stop, or when the run did
  select max(x.delivered_at) into v_start
    from public.deliveries x
   where x.run_id = d.run_id
     and x.id <> d.id
     and x.delivered_at is not null
     and x.delivered_at <= coalesce(d.arrived_at, d.delivered_at);
  if v_start is null then
    select started_at into v_start from public.delivery_runs where id = d.run_id;
  end if;
  if v_start is null then return; end if;

  v_end := coalesce(d.arrived_at, d.delivered_at);
  if v_end is null or v_end <= v_start then return; end if;

  v_travel := ceil(extract(epoch from (v_end - v_start)))::int;
  v_dwell  := case when d.arrived_at is not null and d.delivered_at is not null
                        and d.delivered_at >= d.arrived_at
                   then ceil(extract(epoch from (d.delivered_at - d.arrived_at)))::int end;

  v_ist := (coalesce(d.delivered_at, v_end) at time zone 'Asia/Kolkata');

  insert into public.delivery_leg_history(
    delivery_id, run_id, partner_id, zone_id, seq, leg_km, planned_min,
    actual_sec, dwell_sec, hour_ist, dow, started_at, ended_at, outcome,
    is_synthetic)
  values (d.id, d.run_id, d.partner_id, d.zone_id, d.seq, d.leg_km, d.leg_min,
          v_travel, v_dwell,
          extract(hour from v_ist)::smallint,
          extract(dow  from v_ist)::smallint,
          v_start, v_end, d.status, coalesce(d.is_synthetic,false))
  on conflict (delivery_id) do update
    set actual_sec = excluded.actual_sec,
        dwell_sec  = excluded.dwell_sec,
        ended_at   = excluded.ended_at,
        outcome    = excluded.outcome;
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE FIT. A median and a percentile — nothing here needs a GPU.
--
--    multiplier = median(actual / planned) per (zone, hour), falling back to the
--    zone, then to everything, then to 1.0. dwell = median per rider, falling
--    back the same way. p80 of the RESIDUAL error is the band half-width, which
--    is why the window narrows on its own: more samples, tighter percentile.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 6a. READING THE MODEL. Three lookups, each with the same fallback ladder:
--     the most specific answer the history can support, then the next one out,
--     then the constant the platform shipped with. A cold start behaves EXACTLY
--     like #691 did — which is the point: learning may not make it worse.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._eta_multiplier(p_zone smallint, p_hour smallint)
returns numeric language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select m.multiplier from public.eta_model m
      where m.scope='zone_hour'
        and m.key = coalesce(p_zone::text,'-') || ':' || coalesce(p_hour,0)::text),
    (select m.multiplier from public.eta_model m
      where m.scope='zone' and m.key = coalesce(p_zone::text,'-')),
    (select m.multiplier from public.eta_model m where m.scope='global' and m.key='all'),
    1.0);
$function$;

create or replace function public._eta_dwell_min(p_partner uuid)
returns numeric language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select m.dwell_min from public.eta_model m
      where m.scope='rider_dwell' and m.key = p_partner::text),
    (select m.dwell_min from public.eta_model m where m.scope='global' and m.key='all'),
    (select (value #>> '{}')::numeric from public.app_settings where key='delivery_dwell_minutes'),
    4);
$function$;

-- The half-width of the window the customer reads. It is the model's own 80th
-- percentile error, floored and capped by config — so an untrained platform
-- says a wide window honestly instead of a narrow one confidently.
create or replace function public._eta_band_min(p_zone smallint)
returns numeric language sql stable security definer set search_path to 'public'
as $function$
  select least(
    greatest(
      coalesce(
        (select m.p80_min from public.eta_model m
          where m.scope='band' and m.key = coalesce(p_zone::text,'-') and m.samples > 0),
        (select m.p80_min from public.eta_model m
          where m.scope='band' and m.key='all' and m.samples > 0),
        -- COLD START: with no history at all the band is HALF the window #691
        -- shipped, so an untrained platform says exactly what it said
        -- yesterday. Learning is never allowed to make day one worse.
        (select (value #>> '{}')::numeric / 2 from public.app_settings
          where key='delivery_eta_window_minutes'),
        10),
      coalesce((select (value #>> '{}')::numeric from public.app_settings where key='eta_band_min_minutes'), 10)),
    coalesce((select (value #>> '{}')::numeric from public.app_settings where key='eta_band_max_minutes'), 45));
$function$;

-- How much history stands behind THIS stop's estimate — the number the
-- confidence sentence prints.
create or replace function public._eta_samples(p_zone smallint, p_hour smallint)
returns integer language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select m.samples from public.eta_model m
      where m.scope='zone_hour'
        and m.key = coalesce(p_zone::text,'-') || ':' || coalesce(p_hour,0)::text),
    (select m.samples from public.eta_model m
      where m.scope='zone' and m.key = coalesce(p_zone::text,'-')),
    0);
$function$;

create or replace function public.eta_model_fit()
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_days int; v_min_zh int; v_min_rider int;
  v_lo numeric; v_hi numeric; v_dlo numeric; v_dhi numeric;
  v_zh int := 0; v_z int := 0; v_r int := 0; v_rows int;
  v_global numeric; v_gdwell numeric; v_mae numeric; v_p80 numeric;
begin
  v_days      := coalesce((select (value #>> '{}')::int     from app_settings where key='eta_fit_lookback_days'), 60);
  v_min_zh    := coalesce((select (value #>> '{}')::int     from app_settings where key='eta_fit_min_samples_zone_hour'), 5);
  v_min_rider := coalesce((select (value #>> '{}')::int     from app_settings where key='eta_fit_min_samples_rider'), 3);
  v_lo        := coalesce((select (value #>> '{}')::numeric from app_settings where key='eta_multiplier_min'), 0.5);
  v_hi        := coalesce((select (value #>> '{}')::numeric from app_settings where key='eta_multiplier_max'), 3.0);
  v_dlo       := coalesce((select (value #>> '{}')::numeric from app_settings where key='eta_dwell_min_minutes'), 1);
  v_dhi       := coalesce((select (value #>> '{}')::numeric from app_settings where key='eta_dwell_max_minutes'), 20);

  create temp table _fit_src on commit drop as
    select h.zone_id, h.hour_ist, h.partner_id,
           h.actual_sec / 60.0                     as actual_min,
           nullif(h.planned_min, 0)                as planned_min,
           h.dwell_sec / 60.0                      as dwell_min
      from public.delivery_leg_history h
     where h.ended_at >= now() - make_interval(days => v_days)
       and h.actual_sec is not null and h.actual_sec > 0
       and coalesce(h.outcome,'') <> 'rto';

  select count(*) into v_rows from _fit_src;

  -- the one number every fallback ends at
  select percentile_cont(0.5) within group (order by actual_min / planned_min)
    into v_global from _fit_src where planned_min is not null and planned_min > 0;
  v_global := least(greatest(coalesce(v_global, 1.0), v_lo), v_hi);

  select percentile_cont(0.5) within group (order by dwell_min)
    into v_gdwell from _fit_src where dwell_min is not null;
  v_gdwell := least(greatest(coalesce(v_gdwell,
                 coalesce((select (value #>> '{}')::numeric from app_settings
                            where key='delivery_dwell_minutes'), 4)), v_dlo), v_dhi);

  -- The model is REPLACED, never merged: a stale (zone,hour) that stopped
  -- happening must stop being predicted from.
  delete from public.eta_model;

  insert into public.eta_model(scope, key, multiplier, dwell_min, samples, fitted_at)
  values ('global', 'all', v_global, v_gdwell, coalesce(v_rows,0), now());

  insert into public.eta_model(scope, key, multiplier, samples, fitted_at)
  select 'zone_hour',
         coalesce(zone_id::text,'-') || ':' || hour_ist::text,
         least(greatest(percentile_cont(0.5) within group (order by actual_min / planned_min), v_lo), v_hi),
         count(*)::int, now()
    from _fit_src
   where planned_min is not null and planned_min > 0
   group by zone_id, hour_ist
  having count(*) >= v_min_zh;
  get diagnostics v_zh = row_count;

  insert into public.eta_model(scope, key, multiplier, samples, fitted_at)
  select 'zone', coalesce(zone_id::text,'-'),
         least(greatest(percentile_cont(0.5) within group (order by actual_min / planned_min), v_lo), v_hi),
         count(*)::int, now()
    from _fit_src
   where planned_min is not null and planned_min > 0
   group by zone_id
  having count(*) >= v_min_zh;
  get diagnostics v_z = row_count;

  insert into public.eta_model(scope, key, dwell_min, samples, fitted_at)
  select 'rider_dwell', partner_id::text,
         least(greatest(percentile_cont(0.5) within group (order by dwell_min), v_dlo), v_dhi),
         count(*)::int, now()
    from _fit_src
   where dwell_min is not null and partner_id is not null
   group by partner_id
  having count(*) >= v_min_rider;
  get diagnostics v_r = row_count;

  -- THE BAND. Residual of the FITTED estimate, not of the raw plan — so the
  -- window is an honest statement about how wrong this model still is.
  insert into public.eta_model(scope, key, mae_min, p80_min, samples, fitted_at)
  select 'band', coalesce(s.zone_id::text,'-'),
         round(avg(abs(s.actual_min - s.planned_min * public._eta_multiplier(s.zone_id, s.hour_ist)))::numeric, 2),
         round(coalesce(percentile_cont(0.8) within group (
                 order by abs(s.actual_min - s.planned_min * public._eta_multiplier(s.zone_id, s.hour_ist))), 0)::numeric, 2),
         count(*)::int, now()
    from _fit_src s
   where s.planned_min is not null and s.planned_min > 0
   group by s.zone_id;

  select round(avg(abs(s.actual_min - s.planned_min * public._eta_multiplier(s.zone_id, s.hour_ist)))::numeric, 2),
         round(coalesce(percentile_cont(0.8) within group (
                 order by abs(s.actual_min - s.planned_min * public._eta_multiplier(s.zone_id, s.hour_ist))), 0)::numeric, 2)
    into v_mae, v_p80
    from _fit_src s where s.planned_min is not null and s.planned_min > 0;

  insert into public.eta_model(scope, key, mae_min, p80_min, samples, fitted_at)
  values ('band', 'all', v_mae, v_p80, coalesce(v_rows,0), now())
  on conflict (scope, key) do update
    set mae_min = excluded.mae_min, p80_min = excluded.p80_min,
        samples = excluded.samples, fitted_at = excluded.fitted_at;

  return jsonb_build_object('ok', true, 'rows', coalesce(v_rows,0),
    'zone_hour', v_zh, 'zone', v_z, 'riders', v_r,
    'global_multiplier', v_global, 'global_dwell_min', v_gdwell,
    'mae_min', v_mae, 'p80_min', v_p80, 'fitted_at', now());
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE ESTIMATE, NOW LEARNED.
--    Same shape as #691 — read leg_min, never write it, walk the open stops in
--    sequence — with three substitutions: the leg is multiplied by what this
--    zone actually does at this hour, the dwell is what THIS rider actually
--    takes, and the window edges are stored rather than derived from a constant.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_recompute_eta(p_run_id uuid, p_force boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  r record;
  v_acc numeric := 0; v_n int := 0; v_first boolean := true;
  v_speed numeric; v_fallback numeric; v_gap numeric;
  v_anchor timestamptz := now();
  v_rlat numeric; v_rlng numeric; v_leg numeric; v_last timestamptz;
  v_zone smallint; v_partner uuid; v_dwell numeric; v_mult numeric;
  v_hour smallint; v_eta timestamptz; v_band numeric; v_samples int := 0;
begin
  if p_run_id is null then
    return jsonb_build_object('ok',false,'error','no_run');
  end if;

  select eta_rebased_at, partner_id, zone_id into v_last, v_partner, v_zone
    from delivery_runs where id = p_run_id;
  if not found then
    return jsonb_build_object('ok',false,'error','run_not_found');
  end if;

  v_speed    := greatest(coalesce((select (value #>> '{}')::numeric from app_settings
                          where key='delivery_eta_rider_speed_kmh'), 22), 1);
  v_fallback := coalesce((select (value #>> '{}')::numeric from app_settings
                          where key='delivery_eta_fallback_min_per_km'), 3);
  v_gap      := coalesce((select (value #>> '{}')::numeric from app_settings
                          where key='delivery_eta_rebase_min_seconds'), 60);

  if not coalesce(p_force,true)
     and v_last is not null
     and extract(epoch from (v_anchor - v_last)) < v_gap then
    return jsonb_build_object('ok',true,'run_id',p_run_id,'stops_rebased',0,
                              'throttled',true,'next_in_s',
                              ceil(v_gap - extract(epoch from (v_anchor - v_last))));
  end if;

  select l.lat, l.lng into v_rlat, v_rlng
    from delivery_partner_locations l
   where l.partner_id = v_partner;

  -- CHANGE #702: the dwell is this rider's own median, not one number for the
  -- whole fleet.
  v_dwell := public._eta_dwell_min(v_partner);

  for r in
    select d.id, d.leg_km, d.leg_min, d.seq, d.lat, d.lng, d.zone_id
      from deliveries d
     where d.run_id = p_run_id
       and d.status in ('assigned','out_for_delivery')
     order by d.seq nulls last, d.created_at
  loop
    if v_first and v_rlat is not null and v_rlng is not null
       and r.lat is not null and r.lng is not null then
      v_leg := ceil(public._km(v_rlat::double precision, v_rlng::double precision,
                               r.lat::double precision,  r.lng::double precision)
                    * 60.0 / v_speed);
    else
      v_leg := coalesce(nullif(r.leg_min,0), ceil(coalesce(r.leg_km,1) * v_fallback));
    end if;

    -- the hour the leg is EXPECTED to end in — a 5:50 pm departure that lands
    -- at 6:10 pm is priced at the 6 pm multiplier, which is the one that hurts.
    v_hour := extract(hour from
                ((v_anchor + make_interval(mins => ceil(v_acc + coalesce(v_leg,0))::int))
                 at time zone 'Asia/Kolkata'))::smallint;
    v_mult := public._eta_multiplier(coalesce(r.zone_id, v_zone), v_hour);

    v_acc := v_acc + greatest(coalesce(v_leg,0), 0) * v_mult;
    v_eta := v_anchor + make_interval(mins => ceil(v_acc)::int);
    v_band := public._eta_band_min(coalesce(r.zone_id, v_zone));
    v_samples := greatest(v_samples, public._eta_samples(coalesce(r.zone_id, v_zone), v_hour));

    update deliveries
       set eta_min = ceil(v_acc)::int,
           eta_at  = v_eta,
           eta_lo  = v_eta - make_interval(mins => ceil(v_band)::int),
           eta_hi  = v_eta + make_interval(mins => ceil(v_band)::int)
     where id = r.id;

    v_acc := v_acc + v_dwell;
    v_first := false;
    v_n := v_n + 1;
  end loop;

  update delivery_runs set eta_rebased_at = v_anchor where id = p_run_id;

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops_rebased',v_n,
    'dwell_minutes',v_dwell,'anchor',v_anchor,'throttled',false,
    'learned', true, 'samples', v_samples,
    'from_rider_gps',(v_rlat is not null and v_rlng is not null));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. MORE EVENTS THAT CHANGE THE ANSWER.
--    #691 rebased on three; the spec names five. Arrival at a stop and a
--    reschedule both move every stop after them, and neither used to.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_rebase_eta_trg()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_run uuid;
begin
  if tg_table_name = 'deliveries' then
    v_run := coalesce(new.run_id, old.run_id);
    -- CHANGE #702: a closed stop also teaches the model what it actually cost.
    if new.status is distinct from old.status
       and new.status in ('delivered','failed','rto') then
      begin
        perform public._delivery_capture_leg(new.id);
      exception when others then null;
      end;
    end if;
    perform public.delivery_recompute_eta(v_run, true);

  elsif tg_table_name = 'delivery_runs' then
    perform public.delivery_recompute_eta(new.id, true);

  elsif tg_table_name = 'delivery_partner_locations' then
    for v_run in
      select id from delivery_runs
       where partner_id = new.partner_id and status = 'started'
    loop
      perform public.delivery_recompute_eta(v_run, false);
    end loop;
  end if;
  return null;
exception when others then
  return null;
end $function$;

-- geofence enter: the rider is AT the door, so every stop behind them moves.
drop trigger if exists trg_delivery_arrive_rebase_eta on public.deliveries;
create trigger trg_delivery_arrive_rebase_eta
  after update of arrived_at on public.deliveries
  for each row
  when (old.arrived_at is distinct from new.arrived_at and new.run_id is not null)
  execute function public._delivery_rebase_eta_trg();

-- a reschedule removes a stop from today's run
drop trigger if exists trg_delivery_reschedule_rebase_eta on public.deliveries;
create trigger trg_delivery_reschedule_rebase_eta
  after update of rescheduled_at, next_attempt_on on public.deliveries
  for each row
  when ((old.rescheduled_at is distinct from new.rescheduled_at
         or old.next_attempt_on is distinct from new.next_attempt_on)
        and new.run_id is not null)
  execute function public._delivery_rebase_eta_trg();

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE RIDER WENT QUIET. A stale GPS is not a reason to keep promising the
--    old time — rebase from the last known point and let the band speak.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.eta_offline_rebase_tick()
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare r record; v_min int; v_n int := 0;
begin
  v_min := coalesce((select (value #>> '{}')::int from app_settings
                      where key='eta_offline_minutes'), 3);
  for r in
    select run.id
      from delivery_runs run
      left join delivery_partner_locations l on l.partner_id = run.partner_id
     where run.status = 'started'
       and (l.updated_at is null or l.updated_at < now() - make_interval(mins => v_min))
       and (run.eta_rebased_at is null
            or run.eta_rebased_at < now() - make_interval(mins => v_min))
  loop
    perform public.delivery_recompute_eta(r.id, true);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'runs_rebased', v_n, 'offline_minutes', v_min);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE WINDOW, NOW THE MODEL'S OWN.
--     #691 built the window from ONE config number, so every customer got the
--     same 20 minutes. It is now eta_lo..eta_hi — the learned band — with the
--     config value surviving only as the floor inside _eta_band_min().
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_eta_block(p_delivery_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_win int; v_ahead int; v_mins int; v_samples int; v_min_zh int;
  v_lo timestamptz; v_hi timestamptz;
  v_lo_t text; v_hi_t text; v_lo_m text; v_hi_m text; v_window text;
  v_ahead_label text; v_breach jsonb; v_hour smallint;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then
    return jsonb_build_object('has', false, 'state', 'none', 'label', '',
      'window_label','','countdown_label','','stops_ahead',0,'stops_ahead_label','',
      'breach', jsonb_build_object('has', false));
  end if;

  select count(*) into v_ahead from public.deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  v_ahead_label := case
      when d.status not in ('assigned','out_for_delivery') then ''
      when coalesce(v_ahead,0) = 0 then 'You are next'
      when v_ahead = 1 then '1 stop before you'
      else v_ahead::text || ' stops before you' end;

  if d.status = 'delivered' then
    return jsonb_build_object(
      'has', false, 'state', 'delivered',
      'heading', public._c('delivery.eta_heading'),
      'label',   public._c('delivery.eta_delivered'),
      'window_label','', 'countdown_label','', 'eta_at', null, 'eta_min', null,
      'stops_ahead', 0, 'stops_ahead_label', '', 'note','',
      'breach', jsonb_build_object('has', false));
  end if;

  if d.status not in ('assigned','out_for_delivery') or d.eta_at is null then
    return jsonb_build_object(
      'has', false,
      'state', case when d.status in ('assigned','out_for_delivery') then 'unknown' else 'none' end,
      'heading', public._c('delivery.eta_heading'),
      'label', case when d.status in ('assigned','out_for_delivery')
                    then public._c('delivery.eta_unknown') else '' end,
      'window_label','', 'countdown_label','', 'eta_at', null, 'eta_min', null,
      'stops_ahead', coalesce(v_ahead,0), 'stops_ahead_label', v_ahead_label, 'note','',
      'breach', jsonb_build_object('has', false));
  end if;

  -- CHANGE #702: the edges are the LEARNED band. A row written before this
  -- change (or by a rebase that has not run yet) falls back to the old constant
  -- window, so an in-flight run never loses its ETA mid-upgrade.
  v_win := coalesce((select (value #>> '{}')::int from public.app_settings
                      where key='delivery_eta_window_minutes'), 20);
  v_lo := coalesce(d.eta_lo, d.eta_at);
  v_hi := coalesce(d.eta_hi, d.eta_at + make_interval(mins => v_win));

  v_lo_t := to_char(v_lo at time zone 'Asia/Kolkata','FMHH12:MI');
  v_hi_t := to_char(v_hi at time zone 'Asia/Kolkata','FMHH12:MI');
  v_lo_m := lower(to_char(v_lo at time zone 'Asia/Kolkata','AM'));
  v_hi_m := lower(to_char(v_hi at time zone 'Asia/Kolkata','AM'));

  v_window := case when v_lo_m = v_hi_m
                   then v_lo_t || '–' || v_hi_t || ' ' || v_hi_m
                   else v_lo_t || ' ' || v_lo_m || '–' || v_hi_t || ' ' || v_hi_m end;

  v_mins := ceil(extract(epoch from (d.eta_at - now())) / 60.0)::int;

  v_hour := extract(hour from (d.eta_at at time zone 'Asia/Kolkata'))::smallint;
  v_samples := public._eta_samples(d.zone_id, v_hour);
  v_min_zh := coalesce((select (value #>> '{}')::int from public.app_settings
                         where key='eta_fit_min_samples_zone_hour'), 5);

  -- The promise the platform made vs the arrival it now expects. `has:false`
  -- when there is no promise, or when the estimate is still inside it — the
  -- app never works this out from two timestamps.
  v_breach := case
    when d.promised_at is not null and d.eta_at > d.promised_at
      then jsonb_build_object(
             'has', true,
             'title', public._c('delivery.eta_breach_title'),
             'body',  public._cf('delivery.eta_breach_body',
                                 jsonb_build_object('window', v_window)),
             'promised_caption', public._c('delivery.eta_promised_label'),
             'promised_label', public._ist_stamp(d.promised_at),
             'late_minutes', ceil(extract(epoch from (d.eta_at - d.promised_at))/60.0)::int)
    else jsonb_build_object('has', false) end;

  return jsonb_build_object(
    'has',   true,
    'state', 'eta',
    'heading', public._c('delivery.eta_heading'),
    'label',  btrim(public._c('delivery.eta_prefix') || ' ' || v_window),
    'window_label', v_window,
    'countdown_label', case
        when v_mins <= 0 then public._c('delivery.eta_now')
        when v_mins = 1  then public._c('delivery.eta_countdown_one')
        else public._cf('delivery.eta_countdown_many', jsonb_build_object('n', v_mins)) end,
    'eta_at',  d.eta_at,
    'eta_lo',  v_lo,
    'eta_hi',  v_hi,
    'eta_min', greatest(v_mins, 0),
    'window_minutes', greatest(ceil(extract(epoch from (v_hi - v_lo))/60.0)::int, 0),
    -- CHANGE #702: how much history stands behind this number, in words.
    'samples', coalesce(v_samples,0),
    'confidence', case when coalesce(v_samples,0) >= v_min_zh then 'high' else 'low' end,
    'confidence_label', case when coalesce(v_samples,0) >= v_min_zh
        then public._cf('delivery.eta_confidence_high', jsonb_build_object('n', v_samples))
        else public._c('delivery.eta_confidence_low') end,
    'breach', v_breach,
    'stops_ahead', coalesce(v_ahead,0),
    'stops_ahead_label', v_ahead_label,
    'note', public._c('delivery.eta_rebased_note'));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. PROMISE BREACH — predicted, told, and put in front of the partner.
--     Throttled: at most one re-ETA message per delivery per
--     eta_renotify_minutes, so a rider crawling through traffic cannot spam a
--     pharmacy every time the estimate twitches.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.eta_breach_tick()
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  r record; v_grace int; v_gap int; v_n int := 0; v_sent int := 0;
begin
  v_grace := coalesce((select (value #>> '{}')::int from app_settings
                        where key='eta_breach_grace_minutes'), 10);
  v_gap   := coalesce((select (value #>> '{}')::int from app_settings
                        where key='eta_renotify_minutes'), 20);

  for r in
    select d.id, d.order_id, d.eta_at, d.promised_at
      from deliveries d
     where d.status in ('assigned','out_for_delivery')
       and d.eta_at is not null
       and d.promised_at is not null
       and d.eta_at > d.promised_at + make_interval(mins => v_grace)
       and (d.eta_notified_at is null
            or d.eta_notified_at < now() - make_interval(mins => v_gap))
     order by d.eta_at
     limit 100
  loop
    v_n := v_n + 1;

    update deliveries
       set eta_notified_at = now(),
           eta_breach_at   = coalesce(eta_breach_at, now())
     where id = r.id;

    insert into delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    select r.id, r.order_id, d.partner_id, 'eta_breach',
           'expected ' || public._ist_stamp(r.eta_at)
           || ' vs promised ' || public._ist_stamp(r.promised_at),
           'system'
      from deliveries d where d.id = r.id;

    begin
      perform public.wa_notify_event(
        'delivery_eta_update', null, '{}'::jsonb, null, r.order_id,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
        jsonb_build_object('event','eta_update','delivery_id', r.id));
      v_sent := v_sent + 1;
    exception when others then
      perform public._wa_log_attempt('delivery_eta_update', r.order_id, null,
                                     'skipped', false, 'caller_error: ' || sqlerrm);
    end;
  end loop;

  return jsonb_build_object('ok', true, 'breaching', v_n, 'notified', v_sent,
                            'grace_minutes', v_grace, 'throttle_minutes', v_gap);
end $function$;

-- The partner's own copy of the same fact, on the surface they already read.
insert into public.exception_reason(reason_code, source_key, severity, sla_hours,
                                    owner_kind, action_kind, action_route, sort_rank, enabled)
values ('eta_promise_breach', 'deliveries', 3, 0, 'zone', 'route', 'delivery_run', 55, true)
on conflict (reason_code) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. THE OPS INBOX ARM. One more union in the queue every role already reads.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._exception_rows()
 RETURNS TABLE(reason_code text, ref_id text, zone_id smallint, title text, subtitle text, since timestamp with time zone, supplier_key text, action_ref text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- 1. Disputes nobody resolved.
  select 'dispute_open'::text, d.id::text, oi.zone_id,
         coalesce(nullif(d.product_name,''), '—'),
         coalesce(nullif(d.assigned_supplier,''), '—'),
         d.created_at,
         nullif(d.assigned_supplier,''),
         d.id::text
    from public.supplier_disputes d
    left join public.order_items oi on oi.id = d.order_item_id
   where d.resolved_at is null

  union all
  -- 2. Items no supplier could fill.
  select 'item_unfulfillable', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.unfulfillable_reason,''), '—'),
         coalesce(oi.unfulfillable_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.order_id::text
    from public.order_items oi
   where oi.unfulfillable is true

  union all
  -- 3. Shop count and warehouse recount disagree.
  select 'count_variance', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.assigned_supplier,''), '—'),
         coalesce(oi.received_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.id::text
    from public.order_items oi
   where oi.count_diff is not null
     and oi.count_diff <> 0
     and coalesce(oi.unfulfillable, false) = false

  union all
  -- CHANGE #702. The predicted promise breach, on the surface the partner
  -- already reads. It is a PREDICTION, so it appears the moment the model
  -- says the stop will be late — not after the promise has already passed.
  select 'eta_promise_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         coalesce(d.eta_breach_at, d.promised_at),
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.status in ('assigned','out_for_delivery')
     and d.promised_at is not null
     and d.eta_at is not null
     and d.eta_at > d.promised_at

  union all
  -- 4. WhatsApp sends the provider is refusing — the same blocking-fault
  --    filter the ops board already uses, so the two surfaces cannot disagree.
  select 'wa_send_failed', a.id::text,
         (select o.zone_id from public.orders o where o.id = a.order_id),
         coalesce(nullif(a.reason,''), '—'),
         coalesce(nullif(a.event_key,''), '—'),
         a.created_at,
         null,
         a.id::text
    from public.wa_send_attempts a
   where a.ok = false
     and a.created_at >= now() - interval '7 days'
     and coalesce(a.phone,'') not like '9000000%'
     and exists (select 1 from public.wa_send_fault_rule f
                  where f.enabled and f.is_blocking
                    and ((f.match_kind = 'exact' and a.reason = f.match_text)
                      or (f.match_kind = 'ilike' and a.reason ilike f.match_text)))

  union all
  -- 5. Stock follow-ups past their due date and still unanswered.
  select 'stock_followup_overdue', q.id::text, q.zone_id,
         coalesce(nullif(m.product_name,''), 'Product ' || q.product_id::text),
         coalesce(nullif(q.supplier_name,''), '—'),
         q.due_at,
         nullif(q.supplier_name,''),
         q.id::text
    from public.stock_update_queue q
    left join public."MEDICINE" m on m.id = q.product_id
   where q.resolved_at is null
     and q.due_at < now()

  union all
  -- 6. Payment claims nobody verified, once they are past the reason's SLA.
  select 'payment_claim_stuck', pc.id::text, pc.zone_id,
         coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text, 8)),
         coalesce(nullif(pc.payee_name,''), nullif(pc.sender_phone,''), '—'),
         coalesce(pc.paid_ts, pc.received_at, pc.created_at),
         null,
         pc.id::text
    from public.payment_claims pc
   where coalesce(pc.status,'') not in ('verified','rejected')
     and coalesce(pc.paid_ts, pc.received_at, pc.created_at)
         < now() - make_interval(hours =>
             (select r.sla_hours::int from public.exception_reason r
               where r.reason_code = 'payment_claim_stuck'))

  union all
  -- 7. Everything else on the ops board that is past its OWN class deadline.
  select 'sla_breach', b.class_key || '/' || b.item_id, b.zone_id,
         b.item_label,
         c.title || ' · ' || b.item_sub,
         b.since,
         null,
         b.class_key
    from (
      select 'orders_open'::text class_key, o.id::text item_id, o.zone_id,
             coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)) item_label,
             coalesce(nullif(o.pharmacy_name,''), '—') item_sub, o.created_at since
        from public.orders o where o.closed_at is null
      union all
      select 'supplier_unsettled', so.id::text, so.zone_id,
             coalesce(nullif(so.order_code,''), 'SO ' || left(so.id::text,8)),
             coalesce(nullif(so.supplier_name,''), '—'), so.created_at
        from public.supplier_orders so where so.settled_at is null
      union all
      select 'inquiry_pending', i.id::text, i.zone_id,
             coalesce(nullif(i.product_name,''), 'Inquiry ' || i.id::text),
             coalesce(nullif(i.current_status,''), '—'),
             coalesce(i.asked_at, i.created_at)
        from public.inquiry i where i.current_status = 'Confirmation Pending'
      union all
      select 'bills_pending', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Bill ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.status = 'pending'
      union all
      select 'bill_scan_error', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Scan ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.scan_status = 'error'
      union all
      select 'catalog_barcode_gap', bm.barcode_norm, null::smallint,
             coalesce(nullif(bm.sample_raw,''), bm.barcode_norm),
             bm.miss_count || case when bm.miss_count = 1 then ' scan' else ' scans' end
               || ', no product',
             bm.first_seen
        from public.catalog_barcode_miss bm
       where not exists (
               select 1 from public."MEDICINE" m
                where m.barcode is not null and btrim(m.barcode) <> ''
                  and public._norm_barcode(m.barcode) = bm.barcode_norm)
         and not exists (
               select 1 from public.product_barcode pb2
                where public._norm_barcode(pb2.barcode) = bm.barcode_norm)
    ) b
    join public.ops_board_class c
      on c.key = b.class_key and c.enabled
   where b.since < now() - make_interval(hours => c.sla_hours::int)
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. WIRING: the WhatsApp route, and three cron_task rows on the ONE
--     dispatcher (never a bare */N — see the connection-exhaustion outage).
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.wa_event_routes(event_key, label, description, enabled,
                                   legacy_routed_to, dedupe_minutes, audience,
                                   push_enabled, push_title, push_body)
values ('delivery_eta_update', 'Updated arrival time',
        'CHANGE #702 — sent when the learned ETA passes the promised time. Free text inside the 24h window; throttled by eta_renotify_minutes.',
        true, '{delivery_eta_update}', 20, 'customer',
        true, 'Updated arrival', 'Order {{order_code}} is running a little late.')
on conflict (event_key) do nothing;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note,
                             base_interval_s, run_at_ist)
values
  ('eta_model_fit', 940, 'poll', 'select public.eta_model_fit()', true,
   'CHANGE #702 — nightly fit of the per-zone hour multipliers, per-rider dwell and the error band. Runs in the quiet window.',
   3600, '02:20:00'),
  ('eta_offline_rebase', 941, 'poll', 'select public.eta_offline_rebase_tick()', true,
   'CHANGE #702 — a rider whose GPS has been quiet longer than eta_offline_minutes gets their run rebased from the last known point.',
   120, null),
  ('eta_breach_notify', 942, 'poll', 'select public.eta_breach_tick()', true,
   'CHANGE #702 — predicted promise breaches: one throttled re-ETA message to the customer, one ops-inbox row for the partner.',
   180, null)
on conflict (name) do update
  set work_sql = excluded.work_sql,
      note     = excluded.note,
      enabled  = excluded.enabled;

-- The no-delivery fallback gains the same `breach` key the real block carries,
-- so every reader can test one shape.
create or replace function public._delivery_eta_for_order(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select public._delivery_eta_block(d.id) from public.deliveries d
      where d.order_id = p_order_id order by d.created_at desc limit 1),
    jsonb_build_object('has', false, 'state','none','label','','window_label','',
                       'countdown_label','','stops_ahead',0,'stops_ahead_label','',
                       'breach', jsonb_build_object('has', false)));
$function$;

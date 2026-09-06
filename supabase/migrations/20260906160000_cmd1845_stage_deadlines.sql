-- CMD #1845 — STAGE DEADLINES: a clock time per stage, not minutes from arrival.
--
-- CHANGE #688 gave every open order one clock: minutes elapsed since it entered
-- the stage it is sitting in. That is the wrong shape for this trade. A 9am
-- order and an 11am order do not get their own private twelve o'clock — the
-- day has ONE accept cut-off, ONE inquiry run, ONE collect round and ONE
-- dispatch. Measuring each order from its own arrival time meant the 11am order
-- was still "green" at 4pm while the van it needed to be on had already left.
--
-- So every stage now carries a MODE:
--   clock    (the new default) — a time of day. Every order in that stage is
--            due at that same wall-clock time. An order that enters AFTER the
--            time has passed rolls to the same time on the next working day.
--   duration (what #688 did)   — minutes from stage entry, kept for the stages
--            that genuinely suit it.
--
-- The deadline is a TIMESTAMP computed in SQL (ops_stage_deadline). Nothing in
-- Flutter knows what a cut-off is, what a working day is, or how to print a
-- time: the board, the timeline, the alerts and the WhatsApp text all read the
-- same computed deadline and the same backend-written label.
--
-- Two more permanent rules land here:
--   TIME FORMAT — every stored deadline is Asia/Kolkata and every printed time
--   is 12-hour with AM/PM. ist_fmt(..,'time12') and ops_clock_label() are the
--   only two places a time becomes text.
--   RENAME — no user-facing string says "SLA" any more. The feature is called
--   "Stage deadlines" everywhere a human can read it. Tables, columns and RPC
--   names are deliberately NOT renamed: this is a label change, and renaming
--   sla_config would break every caller for zero user benefit.
--
-- Idempotent throughout: a resumed worker re-applies this file silently.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE MODE, ON THE ROW THAT ALREADY HOLDS THE SLA
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.sla_config add column if not exists mode      text;
alter table public.sla_config add column if not exists due_time  time;

update public.sla_config set mode = 'duration' where mode is null;

alter table public.sla_config alter column mode set default 'clock';
alter table public.sla_config alter column mode set not null;

do $$ begin
  alter table public.sla_config
    add constraint sla_config_mode_ck check (mode in ('clock', 'duration'));
exception when duplicate_object then null; end $$;

-- A clock row without a time would have no deadline at all, so the check is
-- structural rather than a runtime guess.
do $$ begin
  alter table public.sla_config
    add constraint sla_config_clock_needs_time_ck
    check (mode <> 'clock' or due_time is not null);
exception when duplicate_object then null; end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE WORKING WEEK — what "next working day" actually means
--
-- The spec's rollover rule needs a definition of a working day and mediBO had
-- none: no calendar, no weekly-off, nothing on `zones`. Inventing a closure
-- nobody asked for would be worse than no rule at all, so the default is every
-- day of the week — the rollover then means "tomorrow" — and ops can switch a
-- day off per zone from the Stage deadlines sheet the moment a zone genuinely
-- closes. zone_id NULL is the platform row; a zone row overrides it.
--
-- ISO day numbers (1 = Monday … 7 = Sunday), which is what extract(isodow) gives.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.ops_working_week (
  zone_id    smallint,
  week_days  smallint[]  not null default '{1,2,3,4,5,6,7}',
  updated_at timestamptz not null default now(),
  updated_by text
);
create unique index if not exists ops_working_week_uk
  on public.ops_working_week (coalesce(zone_id, (-1)::smallint));

insert into public.ops_working_week (zone_id, week_days, updated_by)
select null, '{1,2,3,4,5,6,7}'::smallint[], 'CMD #1845'
 where not exists (select 1 from public.ops_working_week where zone_id is null);

alter table public.ops_working_week enable row level security;
do $$ begin
  create policy ops_working_week_read on public.ops_working_week
    for select to authenticated using (true);
exception when duplicate_object then null; end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE WORKING-DAY WALK
--
-- Bounded at 14 days so a zone that (wrongly) has every day switched off can
-- never spin: it falls back to the next calendar day rather than looping.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_week_days(p_zone smallint default null)
returns smallint[]
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select w.week_days from ops_working_week w
      where w.zone_id is not distinct from p_zone and cardinality(w.week_days) > 0),
    (select w.week_days from ops_working_week w
      where w.zone_id is null and cardinality(w.week_days) > 0),
    '{1,2,3,4,5,6,7}'::smallint[]);
$$;

create or replace function public.ops_is_working_day(p_day date, p_zone smallint default null)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select extract(isodow from p_day)::smallint = any (public.ops_week_days(p_zone));
$$;

create or replace function public.ops_next_working_day(p_day date, p_zone smallint default null)
returns date
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_days smallint[] := public.ops_week_days(p_zone); d date := p_day + 1; i int := 0;
begin
  while i < 14 loop
    if extract(isodow from d)::smallint = any (v_days) then return d; end if;
    d := d + 1; i := i + 1;
  end loop;
  return p_day + 1;   -- every day switched off: never spin, just roll one day
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE DEADLINE — the one function every surface asks
--
-- duration : entered_at + N minutes (exactly #688's clock, unchanged).
-- clock    : the due time on the day the order entered the stage, IST. If that
--            moment has already passed — the 4pm order for a 12pm cut-off — it
--            rolls to the same time on the next working day. If the entry day
--            is itself a non-working day it rolls too, so a Sunday order in a
--            zone that is closed on Sunday is due Monday noon, not Sunday noon
--            in the past.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_stage_deadline(
  p_entered_at   timestamptz,
  p_mode         text,
  p_sla_minutes  int,
  p_due_time     time,
  p_zone         smallint default null)
returns timestamptz
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_local timestamp;
  v_day   date;
  v_cand  timestamp;
begin
  if p_entered_at is null then return null; end if;

  if coalesce(p_mode, 'duration') <> 'clock' or p_due_time is null then
    if p_sla_minutes is null then return null; end if;
    return p_entered_at + make_interval(mins => p_sla_minutes);
  end if;

  v_local := (p_entered_at at time zone 'Asia/Kolkata');
  v_day   := v_local::date;

  if not public.ops_is_working_day(v_day, p_zone) then
    v_day := public.ops_next_working_day(v_day, p_zone);
  end if;

  v_cand := v_day + p_due_time;
  if v_cand <= v_local then
    v_day  := public.ops_next_working_day(v_day, p_zone);
    v_cand := v_day + p_due_time;
  end if;

  return (v_cand at time zone 'Asia/Kolkata');
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. HOW A DEADLINE IS SPOKEN — 12-hour, always, and never in Dart
--
-- "12:00 PM" today, "Tomorrow 12:00 PM", "8 Sep 12:00 PM" beyond that. The day
-- words are ui_copy rows, so a rewording is an UPDATE.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_clock_label(p_ts timestamptz)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  d       timestamp;
  today   date := (now() at time zone 'Asia/Kolkata')::date;
  t       text;
  diff    int;
begin
  if p_ts is null then return ''; end if;
  d := (p_ts at time zone 'Asia/Kolkata');
  t := to_char(d, 'FMHH12:MI AM');
  diff := d::date - today;
  if diff = 0 then return t; end if;
  if diff = 1 then
    return replace(public.uic('ops_board.deadline_tomorrow', 'Tomorrow {t}'), '{t}', t);
  end if;
  if diff = -1 then
    return replace(public.uic('ops_board.deadline_yesterday', 'Yesterday {t}'), '{t}', t);
  end if;
  return replace(replace(public.uic('ops_board.deadline_dated', '{d} {t}'),
                         '{d}', to_char(d, 'FMDD Mon')), '{t}', t);
end $$;

-- The one place a stage's promise becomes a chip: "Deadline 12:00 PM" for a
-- clock stage, "Deadline 30m" for a duration stage.
create or replace function public.ops_deadline_chip(
  p_mode text, p_deadline timestamptz, p_sla_minutes int)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when coalesce(p_mode, 'duration') = 'clock' and p_deadline is not null then
      replace(public.uic('ops_board.deadline_clock_label', 'Deadline {t}'),
              '{t}', public.ops_clock_label(p_deadline))
    when p_sla_minutes is not null then
      replace(public.uic('ops_board.deadline_dur_label', 'Deadline {d}'),
              '{d}', public.ops_dur_label(p_sla_minutes * 60))
    else '' end;
$$;

-- A time of day, printed 12-hour. The Stage deadlines sheet calls this after a
-- pick so that even a not-yet-saved time is worded by the backend.
create or replace function public.ops_time_label(p_hour int, p_minute int default 0)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when p_hour is null or p_hour < 0 or p_hour > 23
      or coalesce(p_minute, 0) < 0 or coalesce(p_minute, 0) > 59
    then jsonb_build_object('ok', false, 'label', '')
    else jsonb_build_object(
      'ok', true,
      'hour', p_hour, 'minute', coalesce(p_minute, 0),
      'label', to_char(make_time(p_hour, coalesce(p_minute, 0), 0), 'FMHH12:MI AM'))
  end;
$$;

grant execute on function public.ops_stage_deadline(timestamptz, text, int, time, smallint) to authenticated;
grant execute on function public.ops_clock_label(timestamptz)          to authenticated;
grant execute on function public.ops_deadline_chip(text, timestamptz, int) to authenticated;
grant execute on function public.ops_time_label(int, int)              to authenticated;
grant execute on function public.ops_week_days(smallint)               to authenticated;
grant execute on function public.ops_is_working_day(date, smallint)    to authenticated;
grant execute on function public.ops_next_working_day(date, smallint)  to authenticated;

-- These are staff surfaces. anon must not reach any of them (constraint #92).
revoke execute on function public.ops_stage_deadline(timestamptz, text, int, time, smallint) from anon;
revoke execute on function public.ops_clock_label(timestamptz)          from anon;
revoke execute on function public.ops_deadline_chip(text, timestamptz, int) from anon;
revoke execute on function public.ops_time_label(int, int)              from anon;
revoke execute on function public.ops_week_days(smallint)               from anon;
revoke execute on function public.ops_is_working_day(date, smallint)    from anon;
revoke execute on function public.ops_next_working_day(date, smallint)  from anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE BOARD, ON DEADLINES
--
-- Same screen, same sort, same three buckets — but the clock is now the
-- distance to a computed DEADLINE rather than the distance to an anniversary
-- of the order's own arrival. amber_pct survives and keeps its meaning: it is
-- the share of the run-up (entry → deadline) that must be gone before the row
-- turns amber, which for a duration stage is exactly what it was before.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ops_board(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text     := coalesce(public.get_my_role(), 'none');
  v_partner bigint   := public.my_partner_id();
  v_access  text     := 'none';
  v_zone    smallint;
  v_rows    jsonb    := '[]'::jsonb;
  v_date    date     := public.admin_active_date();
  v_red int := 0; v_amber int := 0; v_green int := 0; v_total int := 0;
begin
  if v_partner is not null then
    v_access := coalesce(public.partner_access('partner.ops_board', v_partner), 'none');
  elsif v_role in ('admin', 'super_admin') then
    v_access := coalesce(public.admin_access('fulfill.ops_board'), 'none');
  end if;

  if v_access = 'none' then
    return jsonb_build_object(
      'ok', false, 'error', 'not_authorized',
      'title',   public.uic('ops_board.title', 'Ops board'),
      'message', public.uic('ops_board.not_authorized', ''),
      'rows', '[]'::jsonb, 'has_any', false);
  end if;

  -- A partner sees ITS zone and only its zone; zones are separate shops.
  v_zone := case when v_partner is not null then public.partner_zone_id()
                 else coalesce(p_zone, public.admin_active_zone()) end;

  with cur as (
    select s.* from public._ops_order_stage(v_zone) s
  ), joined as (
    select c.order_id, c.order_code, c.customer, c.amount, c.zone_id, c.created_at,
           c.stage_key,
           st.label       as stage_label,
           st.sort_order  as stage_sort,
           st.owner_role, st.owner_label, st.next_action,
           coalesce(h.entered_at, c.since, c.created_at) as entered_at,
           cfg.sla_minutes, cfg.amber_pct, cfg.mode, cfg.due_time
      from cur c
      join sla_stage st on st.stage_key = c.stage_key and st.is_active
      left join order_stage_history h
             on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
      left join lateral (
        select f.sla_minutes, f.amber_pct, f.mode, f.due_time
          from sla_config f
         where f.stage_key = c.stage_key and f.is_active
           and (f.zone_id = c.zone_id or f.zone_id is null)
         order by (f.zone_id is null)      -- a zone row beats the platform default
         limit 1) cfg on true
  ), dated as (
    -- CMD #1845 — the promise is a MOMENT now, not a length. A clock stage
    -- resolves to the same wall-clock time for every order in it; a duration
    -- stage resolves to exactly what #688 measured.
    select j.*,
           public.order_hold_paused_seconds(j.order_id, j.entered_at) as pause_sec,
           public.ops_stage_deadline(j.entered_at, j.mode, j.sla_minutes,
                                     j.due_time, j.zone_id)           as raw_deadline_at
      from joined j
  ), clocked as (
    select d.*,
           -- CHANGE #708 kept: time spent parked never counts. Against a clock
           -- deadline that means the DEADLINE moves out by the paused time,
           -- which is the same promise expressed against a moment.
           (d.raw_deadline_at + make_interval(secs => d.pause_sec))       as deadline_at,
           greatest(extract(epoch from (d.raw_deadline_at - d.entered_at))::numeric, 1) as span_sec,
           extract(epoch from (now() - d.entered_at))::numeric
             - d.pause_sec                                               as elapsed_sec,
           extract(epoch from ((d.raw_deadline_at + make_interval(secs => d.pause_sec)) - now()))::numeric
                                                                         as left_sec
      from dated d
     where d.raw_deadline_at is not null
  ), toned as (
    select k.*,
           case when k.left_sec <= 0 then 'red'
                when k.elapsed_sec >= k.span_sec * k.amber_pct / 100.0 then 'amber'
                else 'green' end as tone
      from clocked k
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'order_id',       t.order_id::text,
      'order_code',     t.order_code,
      'customer',       t.customer,
      'amount_display', public.inr_money(t.amount),
      'stage_key',      t.stage_key,
      'hold',           public.order_hold_state(t.order_id),
      'stage_label',    t.stage_label,
      'owner_role',     t.owner_role,
      'owner_label',    t.owner_label,
      'next_action',    t.next_action,
      'entered_label',  public.ist_fmt(t.entered_at, 'relative'),
      'entered_at',     t.entered_at,
      'age_label',      public.ops_age_label(t.entered_at),
      'mode',           t.mode,
      'deadline_at',    t.deadline_at,
      -- "Deadline 12:00 PM" for a clock stage, "Deadline 30m" for a duration
      -- one. `sla_label` stays as an alias of the same string so a browser
      -- still holding the previous bundle prints the new wording, never the old.
      'deadline_label', public.ops_deadline_chip(t.mode, t.deadline_at, t.sla_minutes),
      'sla_label',      public.ops_deadline_chip(t.mode, t.deadline_at, t.sla_minutes),
      'due_label',      replace(public.uic('ops_board.due_label', 'Due {t}'),
                                '{t}', public.ops_clock_label(t.deadline_at)),
      'clock_label',    case when t.left_sec <= 0
                             then replace(public.uic('ops_board.over_label', '{d} over'),
                                          '{d}', public.ops_dur_label(-t.left_sec))
                             else replace(public.uic('ops_board.left_label', '{d} left'),
                                          '{d}', public.ops_dur_label(t.left_sec)) end,
      'overdue',        (t.left_sec <= 0),
      'seconds_left',   round(t.left_sec)::bigint,
      'tone',           t.tone,
      'tone_label',     case t.tone
                          when 'red'   then public.uic('ops_board.tone_red',   'Breached')
                          when 'amber' then public.uic('ops_board.tone_amber', 'Due soon')
                          else              public.uic('ops_board.tone_green', 'On time') end
      )
      -- SORTED BY BREACH: red, then amber, then green; inside a tone the most
      -- overdue (smallest seconds left) is on top.
      order by case t.tone when 'red' then 0 when 'amber' then 1 else 2 end,
               t.left_sec asc, t.entered_at asc), '[]'::jsonb),
    count(*) filter (where t.tone = 'red')::int,
    count(*) filter (where t.tone = 'amber')::int,
    count(*) filter (where t.tone = 'green')::int,
    count(*)::int
    into v_rows, v_red, v_amber, v_green, v_total
    from toned t;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'is_partner', (v_partner is not null),
    'access', v_access,
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from zones z where z.id = v_zone),
                           public.uic('ops_board.all_zones', 'All zones')),
    'active_date', v_date,
    'date_label',  public.ist_fmt((v_date::timestamp at time zone 'Asia/Kolkata'), 'day_mon_year'),
    'title',    public.uic('ops_board.title', 'Ops board'),
    'subtitle', public.uic('ops_board.subtitle', ''),
    'rows', v_rows,
    'has_any', v_total > 0,
    'total', v_total,
    'counts', jsonb_build_object('red', v_red, 'amber', v_amber, 'green', v_green),
    'chips', jsonb_build_array(
      jsonb_build_object('tone', 'red',   'count', v_red,
        'label', replace(public.uic('ops_board.chip_red',   'Breached {n}'), '{n}', v_red::text)),
      jsonb_build_object('tone', 'amber', 'count', v_amber,
        'label', replace(public.uic('ops_board.chip_amber', 'Due soon {n}'), '{n}', v_amber::text)),
      jsonb_build_object('tone', 'green', 'count', v_green,
        'label', replace(public.uic('ops_board.chip_green', 'On time {n}'), '{n}', v_green::text)))
      -- CHANGE #708 — a fourth chip, only when something IS parked. The header
      -- renders chips[] generically, so the count needs no client change.
      || case when coalesce((public.order_hold_count(v_zone)->>'count')::int, 0) > 0
              then jsonb_build_array(jsonb_build_object(
                     'tone', 'amber',
                     'count', (public.order_hold_count(v_zone)->>'count')::int,
                     'label', public.order_hold_count(v_zone)->>'badge'))
              else '[]'::jsonb end,
    'hold_count', public.order_hold_count(v_zone),
    'refresh_ms', greatest(coalesce(nullif(public.uic('ops_board.refresh_ms', ''), '')::int, 30000), 5000),
    'updated_label', replace(public.uic('ops_board.updated_label', 'Updated {t}'),
                             '{t}', public.ist_fmt(now(), 'time12')),
    'can_edit_sla', (v_role = 'super_admin'),
    'deadline_button', public.uic('ops_board.deadline_button', 'Stage deadline settings'),
    'sla_button',      public.uic('ops_board.deadline_button', 'Stage deadline settings'),
    'empty_title',   public.uic('ops_board.empty_title', 'Nothing open'),
    'empty_message', public.uic('ops_board.empty_message', ''));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. ONE ORDER'S TIMELINE, ON DEADLINES
--
-- Each stage prints the deadline that stage visit was measured against — the
-- clock time for a clock stage, the duration for a duration stage — and is
-- toned by whether it left before that moment.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ops_order_detail(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text   := coalesce(public.get_my_role(), 'none');
  v_partner bigint := public.my_partner_id();
  v_access  text   := 'none';
  v_o       record;
  v_cur     record;
  v_steps   jsonb  := '[]'::jsonb;
begin
  if v_partner is not null then
    v_access := coalesce(public.partner_access('partner.ops_board', v_partner), 'none');
  elsif v_role in ('admin', 'super_admin') then
    v_access := coalesce(public.admin_access('fulfill.ops_board'), 'none');
  end if;
  if v_access = 'none' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''));
  end if;

  select o.id, coalesce(o.order_code, '') as order_code, o.total_amount, o.created_at,
         coalesce(o.zone_id, pp.zone_id)::smallint as zone_id,
         coalesce(nullif(btrim(pp.pharmacy_name), ''), nullif(btrim(o.pharmacy_name), ''), '') as customer,
         o.status
    into v_o
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
   where o.id = p_order_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found',
      'title', public.uic('ops_board.detail_not_found_title', 'Order not found'),
      'message', public.uic('ops_board.detail_not_found_message', ''));
  end if;

  if v_partner is not null and v_o.zone_id is distinct from public.partner_zone_id() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''));
  end if;

  select * into v_cur from public._ops_order_stage(null) s where s.order_id = p_order_id;

  -- CMD #1845 — every stage prints the deadline that VISIT was measured
  -- against: a time of day for a clock stage, a length for a duration one.
  with steps as (
    select st.stage_key, st.label, st.owner_label, st.next_action, st.sort_order,
           h.entered_at, h.left_at,
           cfg.sla_minutes, cfg.amber_pct, cfg.mode,
           public.ops_stage_deadline(h.entered_at, cfg.mode, cfg.sla_minutes,
                                     cfg.due_time, v_o.zone_id) as deadline_at
      from sla_stage st
      left join order_stage_history h on h.order_id = p_order_id and h.stage_key = st.stage_key
      left join lateral (
        select f.sla_minutes, f.amber_pct, f.mode, f.due_time from sla_config f
         where f.stage_key = st.stage_key and f.is_active
           and (f.zone_id = v_o.zone_id or f.zone_id is null)
         order by (f.zone_id is null) limit 1) cfg on true
     where st.is_active
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key',   s.stage_key,
           'label',       s.label,
           'owner_label', s.owner_label,
           'next_action', s.next_action,
           'is_current',  (s.left_at is null and s.entered_at is not null),
           'reached',     (s.entered_at is not null),
           'mode',        s.mode,
           'entered_label', case when s.entered_at is null then ''
                                 else public.ist_fmt(s.entered_at, 'datetime') end,
           'spent_label', case
              when s.entered_at is null then ''
              when s.left_at is not null then public.ops_dur_label(extract(epoch from (s.left_at - s.entered_at)))
              else public.ops_dur_label(extract(epoch from (now() - s.entered_at))) end,
           'deadline_at',    s.deadline_at,
           'deadline_label', public.ops_deadline_chip(s.mode, s.deadline_at, s.sla_minutes),
           'sla_label',      public.ops_deadline_chip(s.mode, s.deadline_at, s.sla_minutes),
           'due_label',   case when s.deadline_at is null then ''
                               else replace(public.uic('ops_board.due_label', 'Due {t}'),
                                            '{t}', public.ops_clock_label(s.deadline_at)) end,
           'tone', case
              when s.entered_at is null  then 'neutral'
              when s.deadline_at is null then 'neutral'
              when coalesce(s.left_at, now()) >= s.deadline_at then 'red'
              when extract(epoch from (coalesce(s.left_at, now()) - s.entered_at))
                   >= greatest(extract(epoch from (s.deadline_at - s.entered_at)), 1)
                      * s.amber_pct / 100.0 then 'amber'
              else 'green' end)
           order by s.sort_order), '[]'::jsonb)
    into v_steps
    from steps s;

  return jsonb_build_object(
    'ok', true,
    -- CHANGE #708 — hold, its sheet and the stock it is reserving.
    'hold', public.order_hold_state(p_order_id),
    'hold_sheet', public.order_hold_sheet(p_order_id),
    'hold_stock', public.order_hold_stock(p_order_id),
    'order_id', v_o.id::text,
    'order_code', v_o.order_code,
    'customer', v_o.customer,
    'amount_display', public.inr_money(coalesce(v_o.total_amount, 0)),
    'zone_label', coalesce((select z.name from zones z where z.id = v_o.zone_id), ''),
    'placed_label', replace(public.uic('ops_board.placed_label', 'Placed {t}'), '{t}',
                            public.ist_fmt(v_o.created_at, 'datetime')),
    'status_label', coalesce((select l.label from order_status_label l where l.status = v_o.status), v_o.status),
    'current_stage', coalesce(v_cur.stage_key, ''),
    'next_action', coalesce((select st.next_action from sla_stage st where st.stage_key = v_cur.stage_key), ''),
    -- CHANGE #691 (gap 126): the same proof block the customer sees.
    'proof', public._delivery_proof_block(p_order_id),
    'timeline_title', public.uic('ops_board.timeline_title', 'Stage timeline'),
    'steps', v_steps);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE STAGE DEADLINES SHEET — read
--
-- Zone- and date-scoped like every other admin surface: with no explicit zone
-- it reads admin_active_zone(), and the preview each clock row shows is
-- computed for admin_active_date(). The sheet holds NO logic: the mode options,
-- the day names, the 12-hour time strings and the preview sentence are all
-- written here.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_sla_config_get(p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role text     := coalesce(public.get_my_role(), 'none');
  v_zone smallint := coalesce(p_zone, public.admin_active_zone());
  v_date date     := public.admin_active_date();
  v_days smallint[];
  v_rows jsonb;
  v_week jsonb;
begin
  if v_role not in ('admin', 'super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.deadline_readonly', ''), 'rows', '[]'::jsonb);
  end if;

  v_days := public.ops_week_days(v_zone);

  select coalesce(jsonb_agg(jsonb_build_object(
           'n',     d.n,
           'label', public.uic('ops_board.day_' || d.n::text, d.fallback),
           'on',    (d.n = any (v_days))) order by d.n), '[]'::jsonb)
    into v_week
    from (values (1, 'Mon'), (2, 'Tue'), (3, 'Wed'), (4, 'Thu'),
                 (5, 'Fri'), (6, 'Sat'), (7, 'Sun')) as d(n, fallback);

  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key',   st.stage_key,
           'label',       st.label,
           'owner_label', st.owner_label,
           'mode',        coalesce(cfg.mode, 'clock'),
           'mode_label',  case when coalesce(cfg.mode, 'clock') = 'clock'
                               then public.uic('ops_board.mode_clock', 'Clock time')
                               else public.uic('ops_board.mode_duration', 'Duration') end,
           'sla_minutes', coalesce(cfg.sla_minutes, 60),
           'amber_pct',   coalesce(cfg.amber_pct, 70),
           -- The picker needs numbers, the human needs a 12-hour string. Both
           -- come from here; Dart formats neither.
           'due_hour',    case when cfg.due_time is null then null
                               else extract(hour   from cfg.due_time)::int end,
           'due_minute',  case when cfg.due_time is null then null
                               else extract(minute from cfg.due_time)::int end,
           'due_time_display', case when cfg.due_time is null then ''
                                    else to_char(cfg.due_time, 'FMHH12:MI AM') end,
           'value_label', case when coalesce(cfg.mode, 'clock') = 'clock'
                               then coalesce(nullif(to_char(cfg.due_time, 'FMHH12:MI AM'), ''), '')
                               else public.ops_dur_label(coalesce(cfg.sla_minutes, 60) * 60) end,
           'preview_label', case
              when coalesce(cfg.mode, 'clock') = 'clock' and cfg.due_time is not null
                then replace(public.uic('ops_board.due_label', 'Due {t}'), '{t}',
                             public.ops_clock_label(((v_date + cfg.due_time) at time zone 'Asia/Kolkata')))
              when cfg.sla_minutes is not null
                then replace(public.uic('ops_board.deadline_dur_label', 'Deadline {d}'),
                             '{d}', public.ops_dur_label(cfg.sla_minutes * 60))
              else '' end,
           'is_override', (cfg.zone_id is not null),
           'source_label', case when cfg.zone_id is not null
                                then public.uic('ops_board.deadline_source_zone', 'Zone override')
                                else public.uic('ops_board.deadline_source_default', 'Platform default') end)
           order by st.sort_order), '[]'::jsonb)
    into v_rows
    from sla_stage st
    left join lateral (
      select f.zone_id, f.sla_minutes, f.amber_pct, f.mode, f.due_time from sla_config f
       where f.stage_key = st.stage_key and f.is_active
         and (f.zone_id = v_zone or f.zone_id is null)
       order by (f.zone_id is null) limit 1) cfg on true
   where st.is_active;

  return jsonb_build_object(
    'ok', true,
    'can_edit', (v_role = 'super_admin'),
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from zones z where z.id = v_zone),
                           public.uic('ops_board.all_zones', 'All zones')),
    'active_date', v_date,
    'date_label',  public.ist_fmt((v_date::timestamp at time zone 'Asia/Kolkata'), 'day_mon_year'),
    'title',    public.uic('ops_board.deadline_title', 'Stage deadlines'),
    'subtitle', public.uic('ops_board.deadline_subtitle', ''),
    'modes', jsonb_build_array(
      jsonb_build_object('key', 'clock',
        'label', public.uic('ops_board.mode_clock', 'Clock time'),
        'hint',  public.uic('ops_board.mode_clock_hint', '')),
      jsonb_build_object('key', 'duration',
        'label', public.uic('ops_board.mode_duration', 'Duration'),
        'hint',  public.uic('ops_board.mode_duration_hint', ''))),
    'mode_label',    public.uic('ops_board.mode_label', 'Mode'),
    'time_label',    public.uic('ops_board.time_label', 'Due time'),
    'minutes_label', public.uic('ops_board.minutes_label', 'Minutes'),
    'time_picker_title', public.uic('ops_board.time_picker_title', 'Pick the due time'),
    'week', jsonb_build_object(
      'title',    public.uic('ops_board.week_title', 'Working days'),
      'subtitle', public.uic('ops_board.week_subtitle', ''),
      'days',     v_week),
    'save_label',       public.uic('ops_board.deadline_save', 'Save'),
    'saved_message',    public.uic('ops_board.deadline_saved', ''),
    'readonly_message', public.uic('ops_board.deadline_readonly', ''),
    'rows', v_rows);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE STAGE DEADLINES SHEET — write
--
-- Nonsense is IGNORED, never clamped (the #688 rule, kept): a clock row with no
-- time and a duration row with a silly minute count are both skipped, so the
-- sheet simply shows the value that was already there back. Saving takes effect
-- on the board's very next refresh — there is no deploy in this loop.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_sla_config_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_zone smallint := nullif(p->>'zone_id', '')::smallint;
  v_who  text     := coalesce((select lower(btrim(u.email)) from auth.users u where u.id = auth.uid()), public._actor());
  v_n    int      := 0;
  v_skip int      := 0;
  v_mode text;
  v_min  int;
  v_h    int;
  v_m    int;
  v_time time;
  v_days smallint[];
  r      jsonb;
begin
  if coalesce(public.get_my_role(), 'none') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.deadline_readonly', ''));
  end if;

  -- The working week, when the sheet sent one. An empty or nonsense set is
  -- ignored: a zone with no working day at all has no deadline to roll to.
  if p ? 'week_days' then
    select array_agg(x)::smallint[] into v_days
      from (select distinct (jsonb_array_elements_text(coalesce(p->'week_days','[]'::jsonb)))::int as x) s
     where s.x between 1 and 7;
    if v_days is not null and cardinality(v_days) > 0 then
      insert into ops_working_week (zone_id, week_days, updated_at, updated_by)
      values (v_zone, v_days, now(), v_who)
      on conflict (coalesce(zone_id, (-1)::smallint)) do update
         set week_days = excluded.week_days, updated_at = now(), updated_by = excluded.updated_by;
    else
      v_skip := v_skip + 1;
    end if;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
    if coalesce(r->>'stage_key', '') = '' then continue; end if;
    if not exists (select 1 from sla_stage s where s.stage_key = r->>'stage_key') then continue; end if;

    v_mode := lower(btrim(coalesce(r->>'mode', 'clock')));
    if v_mode not in ('clock', 'duration') then v_skip := v_skip + 1; continue; end if;

    v_min := nullif(btrim(coalesce(r->>'sla_minutes', '')), '')::int;
    v_h   := nullif(btrim(coalesce(r->>'due_hour', '')), '')::int;
    v_m   := coalesce(nullif(btrim(coalesce(r->>'due_minute', '')), '')::int, 0);

    if v_mode = 'clock' then
      if v_h is null or v_h < 0 or v_h > 23 or v_m < 0 or v_m > 59 then
        v_skip := v_skip + 1; continue;
      end if;
      v_time := make_time(v_h, v_m, 0);
      -- A clock row still carries a minute figure: it is what the stage falls
      -- back to if it is ever switched to duration, so it is preserved rather
      -- than zeroed.
      v_min := coalesce(v_min, (select f.sla_minutes from sla_config f
                                 where f.stage_key = r->>'stage_key'
                                   and f.zone_id is not distinct from v_zone), 60);
      if v_min < 1 or v_min > 100000 then v_min := 60; end if;
    else
      v_time := case when v_h between 0 and 23 and v_m between 0 and 59
                     then make_time(v_h, v_m, 0) else null end;
      if v_min is null or v_min < 1 or v_min > 100000 then
        v_skip := v_skip + 1; continue;
      end if;
    end if;

    insert into sla_config (zone_id, stage_key, sla_minutes, amber_pct, mode, due_time, updated_at, updated_by)
    values (v_zone, r->>'stage_key', v_min,
            greatest(least(coalesce((r->>'amber_pct')::int, 70), 100), 1),
            v_mode, v_time, now(), v_who)
    on conflict (coalesce(zone_id, (-1)::smallint), stage_key) do update
       set sla_minutes = excluded.sla_minutes,
           amber_pct   = excluded.amber_pct,
           mode        = excluded.mode,
           due_time    = excluded.due_time,
           is_active   = true,
           updated_at  = now(),
           updated_by  = excluded.updated_by;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'saved', v_n, 'skipped', v_skip,
    'message', public.uic('ops_board.deadline_saved', ''));
end $$;

grant execute on function public.ops_sla_config_get(smallint) to authenticated;
grant execute on function public.ops_sla_config_set(jsonb)    to authenticated;
revoke execute on function public.ops_sla_config_get(smallint) from anon;
revoke execute on function public.ops_sla_config_set(jsonb)    from anon;
revoke execute on function public.ops_board(smallint)          from anon;
revoke execute on function public.ops_order_detail(uuid)       from anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE ALERT — fired by the deadline, worded by the deadline
--
-- Unchanged in shape (one alert per stage visit, a crossing window, a per-tick
-- cap); the crossing it watches for is now "past the computed deadline", and
-- the WhatsApp text says WHEN it was due rather than how many minutes an
-- invisible timer ran for.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_sla_tick(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_stamp jsonb;
  v_lim   int := greatest(least(coalesce(p_limit, 20), 100), 1);
  v_win   int := greatest(coalesce(nullif(public.uic('ops_board.alert_window_min', ''), '')::int, 180), 5);
  r       record;
  v_fired int := 0; v_sent int := 0;
  v_res   jsonb;
begin
  v_stamp := public.ops_stage_stamp(null);

  -- ONE pass over _ops_order_stage (it is the expensive part): the deadline is
  -- computed in the same CTE rather than joining the staging function twice.
  for r in
    with staged as (
      select c.order_id, c.order_code, c.customer, c.zone_id, c.stage_key,
             coalesce(h.entered_at, c.since, c.created_at) as entered_at,
             cfg.mode, cfg.sla_minutes, cfg.due_time
        from public._ops_order_stage(null) c
        left join order_stage_history h
               on h.order_id = c.order_id and h.stage_key = c.stage_key and h.left_at is null
        join lateral (
          select f.sla_minutes, f.mode, f.due_time from sla_config f
           where f.stage_key = c.stage_key and f.is_active
             and (f.zone_id = c.zone_id or f.zone_id is null)
           order by (f.zone_id is null) limit 1) cfg on true
    ), dated as (
      select s.*, public.ops_stage_deadline(s.entered_at, s.mode, s.sla_minutes,
                                            s.due_time, s.zone_id) as deadline_at
        from staged s
    )
    select d.order_id, d.order_code, d.customer, d.zone_id, d.stage_key,
           st.label as stage_label, st.next_action,
           d.entered_at, d.deadline_at,
           extract(epoch from (now() - d.deadline_at)) / 60.0 as over_min
      from dated d
      join sla_stage st on st.stage_key = d.stage_key and st.is_active
     where d.deadline_at is not null
       and now() >= d.deadline_at
       and now() <= d.deadline_at + make_interval(mins => v_win)
       and not exists (
             select 1 from ops_sla_alert a
              where a.order_id = d.order_id
                and a.stage_key = d.stage_key
                and a.entered_at = d.entered_at)
     order by (now() - d.deadline_at) desc
     limit v_lim
  loop
    begin
      v_res := public.notify_partner('partner_sla_breach', jsonb_build_object(
                 'order_id',    r.order_id::text,
                 'order_code',  r.order_code,
                 'customer',    r.customer,
                 'zone_id',     coalesce(r.zone_id, 0)::text,
                 'stage',       r.stage_label,
                 'next_action', r.next_action,
                 'due',         public.ops_clock_label(r.deadline_at),
                 'overdue',     public.ops_dur_label(greatest(r.over_min, 0) * 60)));
    exception when others then
      v_res := jsonb_build_object('ok', false, 'reason', 'notify_failed');
    end;

    insert into ops_sla_alert (order_id, order_code, stage_key, zone_id, tone,
                               entered_at, over_minutes, notify_result)
    values (r.order_id, r.order_code, r.stage_key, r.zone_id, 'red',
            r.entered_at, greatest(round(r.over_min)::int, 0), coalesce(v_res, '{}'::jsonb))
    on conflict (order_id, stage_key, entered_at) do nothing;

    v_fired := v_fired + 1;
    if coalesce((v_res->>'ok')::boolean, false) then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'stamped', v_stamp,
                            'breaches', v_fired, 'notified', v_sent);
end $$;

-- The WhatsApp / push route. Same event key (renaming it would orphan every
-- partner's existing subscription row) — new WORDS, which is all the rename is.
update public.wa_event_routes
   set label       = 'Partner · Stage deadline missed',
       description = 'An open order has passed its stage deadline and needs action now.',
       push_title  = 'Stage deadline missed',
       push_body   = '{{order_code}} is stuck at {{stage}} · due {{due}} · {{overdue}} over · {{next_action}}'
 where event_key = 'partner_sla_breach';

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. THE RENAME — every user-facing "SLA" becomes "Stage deadlines"
--
-- ui_copy is an UPSERT here on purpose. The #688 rows landed with
-- `on conflict do nothing`, so a plain re-insert would leave the old wording in
-- place and the rename would silently not happen.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('ops_board.subtitle',              to_jsonb('Every open order, worst deadline first'::text)),
  ('ops_board.deadline_button',       to_jsonb('Stage deadline settings'::text)),
  ('ops_board.deadline_title',        to_jsonb('Stage deadlines'::text)),
  ('ops_board.deadline_subtitle',     to_jsonb('When work in each stage is due. A clock stage is due at the same time for every order.'::text)),
  ('ops_board.deadline_clock_label',  to_jsonb('Deadline {t}'::text)),
  ('ops_board.deadline_dur_label',    to_jsonb('Deadline {d}'::text)),
  ('ops_board.deadline_tomorrow',     to_jsonb('Tomorrow {t}'::text)),
  ('ops_board.deadline_yesterday',    to_jsonb('Yesterday {t}'::text)),
  ('ops_board.deadline_dated',        to_jsonb('{d} {t}'::text)),
  ('ops_board.due_label',             to_jsonb('Due {t}'::text)),
  ('ops_board.deadline_save',         to_jsonb('Save deadlines'::text)),
  ('ops_board.deadline_saved',        to_jsonb('Stage deadlines saved — the board uses them on the next refresh.'::text)),
  ('ops_board.deadline_readonly',     to_jsonb('Only a super admin can change a stage deadline.'::text)),
  ('ops_board.deadline_source_zone',    to_jsonb('Zone override'::text)),
  ('ops_board.deadline_source_default', to_jsonb('Platform default'::text)),
  ('ops_board.mode_label',            to_jsonb('Mode'::text)),
  ('ops_board.mode_clock',            to_jsonb('Clock time'::text)),
  ('ops_board.mode_clock_hint',       to_jsonb('Same time of day for every order'::text)),
  ('ops_board.mode_duration',         to_jsonb('Duration'::text)),
  ('ops_board.mode_duration_hint',    to_jsonb('Minutes from entering the stage'::text)),
  ('ops_board.time_label',            to_jsonb('Due time'::text)),
  ('ops_board.minutes_label',         to_jsonb('Minutes'::text)),
  ('ops_board.time_picker_title',     to_jsonb('Pick the due time'::text)),
  ('ops_board.week_title',            to_jsonb('Working days'::text)),
  ('ops_board.week_subtitle',         to_jsonb('A deadline that has already passed rolls to the same time on the next working day.'::text)),
  ('ops_board.day_1', to_jsonb('Mon'::text)), ('ops_board.day_2', to_jsonb('Tue'::text)),
  ('ops_board.day_3', to_jsonb('Wed'::text)), ('ops_board.day_4', to_jsonb('Thu'::text)),
  ('ops_board.day_5', to_jsonb('Fri'::text)), ('ops_board.day_6', to_jsonb('Sat'::text)),
  ('ops_board.day_7', to_jsonb('Sun'::text)),
  -- The old SLA keys are kept as aliases of the new wording so a browser still
  -- holding the previous bundle prints "Stage deadlines", never "SLA".
  ('ops_board.sla_button',            to_jsonb('Stage deadline settings'::text)),
  ('ops_board.sla_title',             to_jsonb('Stage deadlines'::text)),
  ('ops_board.sla_subtitle',          to_jsonb('When work in each stage is due.'::text)),
  ('ops_board.sla_save',              to_jsonb('Save deadlines'::text)),
  ('ops_board.sla_saved',             to_jsonb('Stage deadlines saved — the board uses them on the next refresh.'::text)),
  ('ops_board.sla_readonly',          to_jsonb('Only a super admin can change a stage deadline.'::text)),
  ('ops_board.sla_minutes_label',     to_jsonb('Minutes'::text)),
  ('ops_board.sla_label',             to_jsonb('Deadline {d}'::text))
on conflict (key) do update set value = excluded.value;

insert into public.fw_ui_label (key, value) values
  ('ops_board_deadlines', 'Stage deadlines'),
  ('ops_board_error',     'Could not load the ops board.')
on conflict (key) do update set value = excluded.value;

-- The tab's own search terms and blurb are read by a human in the search box.
update public.feature_registry
   set search_terms = 'ops board stage deadline clock cut-off breach overdue promise amber red',
       description  = 'Every open order against its stage deadline, worst breach first'
 where feature_key = 'fulfill.ops_board';
update public.feature_registry
   set search_terms = 'ops board stage deadline clock breach overdue'
 where feature_key = 'partner.ops_board';

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. MIGRATE THE EXISTING VALUES TO CLOCK MODE
--
-- The stage catalogue is re-asserted first (a branch or a restored database can
-- have the table without #688's seed), then every stage gets a daily time that
-- reads like the trade day the spec describes: accept before noon, the inquiry
-- run at 12:05, collection through the afternoon, dispatch at six.
--
-- Existing rows KEEP their minutes and their amber_pct, and a zone override
-- stays an override — only the mode and a missing due_time are written, so an
-- admin who later picks a different time is never overwritten by a re-run.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.sla_stage (stage_key, label, sort_order, owner_role, owner_label, next_action) values
  ('accept',         'Accept',         10, 'partner',  'Partner',  'Accept and start inquiry'),
  ('inquiry',        'Inquiry answer', 20, 'supplier', 'Supplier', 'Ask the next supplier'),
  ('supplier_order', 'Supplier order', 30, 'partner',  'Partner',  'Raise the supplier order'),
  ('collect',        'Collect',        40, 'partner',  'Partner',  'Collect from the shop'),
  ('arrival',        'Arrival',        50, 'partner',  'Partner',  'Receive at the warehouse'),
  ('count',          'Count',          60, 'partner',  'Partner',  'Count in at the warehouse'),
  ('bag',            'Bag',            70, 'partner',  'Partner',  'Allocate to a bag'),
  ('pack',           'Pack',           80, 'partner',  'Partner',  'Pack the order'),
  ('dispatch',       'Dispatch',       90, 'partner',  'Partner',  'Assign a rider and dispatch'),
  ('delivered',      'Delivered',     100, 'rider',    'Rider',    'Close the delivery with proof')
on conflict (stage_key) do update
   set label       = excluded.label,
       sort_order  = excluded.sort_order,
       owner_role  = excluded.owner_role,
       owner_label = excluded.owner_label,
       next_action = excluded.next_action;

-- The daily times, inline: a temp table would be dropped by the first commit
-- when this file is replayed statement-by-statement.
insert into public.sla_config (zone_id, stage_key, sla_minutes, amber_pct, mode, due_time, updated_by)
select null, s.stage_key, v.mins, 70, 'clock', v.t, 'CMD #1845'
  from public.sla_stage s
  join (values
        ('accept', time '12:00',  30), ('inquiry', time '12:05', 120),
        ('supplier_order', time '13:00', 60), ('collect', time '16:00', 180),
        ('arrival', time '16:30', 120), ('count', time '17:00', 60),
        ('bag', time '17:15', 45), ('pack', time '17:30', 45),
        ('dispatch', time '18:00', 60), ('delivered', time '21:00', 240)
       ) as v(k, t, mins) on v.k = s.stage_key
 where not exists (select 1 from public.sla_config f
                    where f.stage_key = s.stage_key and f.zone_id is null);

-- Every row that has never been given a time — platform default OR zone
-- override — moves to clock mode at that stage's daily time. A row that
-- already carries a due_time was set deliberately and is left alone.
update public.sla_config f
   set mode       = 'clock',
       due_time   = v.t,
       updated_at = now(),
       updated_by = 'CMD #1845'
  from (values
        ('accept', time '12:00'), ('inquiry', time '12:05'),
        ('supplier_order', time '13:00'), ('collect', time '16:00'),
        ('arrival', time '16:30'), ('count', time '17:00'),
        ('bag', time '17:15'), ('pack', time '17:30'),
        ('dispatch', time '18:00'), ('delivered', time '21:00')
       ) as v(k, t)
 where v.k = f.stage_key
   and f.due_time is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. GRANTS — the anon review (constraint #92)
--
-- A function is created with EXECUTE granted to PUBLIC, and `revoke … from
-- anon` does NOT take that away: anon inherits it through PUBLIC. So every
-- function this change owns is revoked from PUBLIC first and then granted to
-- the roles that may actually call it. ops_sla_tick is included deliberately —
-- it was reachable by anon since #688 and it WRITES (it stamps history and
-- fires alerts); it belongs to the cron dispatcher and to nobody else.
-- ─────────────────────────────────────────────────────────────────────────────
revoke execute on function public.ops_stage_deadline(timestamptz, text, int, time, smallint) from public, anon;
revoke execute on function public.ops_clock_label(timestamptz)             from public, anon;
revoke execute on function public.ops_deadline_chip(text, timestamptz, int) from public, anon;
revoke execute on function public.ops_time_label(int, int)                 from public, anon;
revoke execute on function public.ops_week_days(smallint)                  from public, anon;
revoke execute on function public.ops_is_working_day(date, smallint)       from public, anon;
revoke execute on function public.ops_next_working_day(date, smallint)     from public, anon;
revoke execute on function public.ops_board(smallint)                      from public, anon;
revoke execute on function public.ops_order_detail(uuid)                   from public, anon;
revoke execute on function public.ops_sla_config_get(smallint)             from public, anon;
revoke execute on function public.ops_sla_config_set(jsonb)                from public, anon;
revoke execute on function public.ops_sla_tick(integer)                    from public, anon, authenticated;

grant execute on function public.ops_stage_deadline(timestamptz, text, int, time, smallint) to authenticated, service_role;
grant execute on function public.ops_clock_label(timestamptz)              to authenticated, service_role;
grant execute on function public.ops_deadline_chip(text, timestamptz, int) to authenticated, service_role;
grant execute on function public.ops_time_label(int, int)                  to authenticated, service_role;
grant execute on function public.ops_week_days(smallint)                   to authenticated, service_role;
grant execute on function public.ops_is_working_day(date, smallint)        to authenticated, service_role;
grant execute on function public.ops_next_working_day(date, smallint)      to authenticated, service_role;
grant execute on function public.ops_board(smallint)                       to authenticated, service_role;
grant execute on function public.ops_order_detail(uuid)                    to authenticated, service_role;
grant execute on function public.ops_sla_config_get(smallint)              to authenticated, service_role;
grant execute on function public.ops_sla_config_set(jsonb)                 to authenticated, service_role;
grant execute on function public.ops_sla_tick(integer)                     to service_role;

revoke all on table public.ops_working_week from anon;
grant select on table public.ops_working_week to authenticated;

-- The picker's formatter is a partner-visible read as well: the sheet is
-- read-only for a partner, and it still has to print a time.
insert into public.partner_rpc_allow (proname, source, note)
values ('ops_time_label', 'cmd1845', 'Stage deadlines sheet — formats a picked time, reads nothing')
on conflict (proname) do nothing;
select public.partner_rpc_allow_refresh();

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. PROOF — one call that shows the whole change is wired
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.cmd1845_stage_deadline_proof()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'stages',        (select count(*) from sla_stage where is_active),
    'clock_rows',    (select count(*) from sla_config where mode = 'clock' and due_time is not null),
    'duration_rows', (select count(*) from sla_config where mode = 'duration'),
    'week_rows',     (select count(*) from ops_working_week),
    'sample',        (select jsonb_object_agg(stage_key, to_char(due_time, 'FMHH12:MI AM'))
                        from sla_config where zone_id is null and due_time is not null),
    -- The rule itself, proved rather than described: an order that enters at
    -- 9am and one that enters at 4pm against a 12:00 cut-off.
    'nine_am_due',   public.ops_clock_label(public.ops_stage_deadline(
                       ((current_date + time '09:00') at time zone 'Asia/Kolkata'), 'clock', null, '12:00', null)),
    'four_pm_due',   public.ops_clock_label(public.ops_stage_deadline(
                       ((current_date + time '16:00') at time zone 'Asia/Kolkata'), 'clock', null, '12:00', null)),
    'anon_blocked',  (select not bool_or(has_function_privilege('anon', p.oid, 'execute'))
                        from pg_proc p where p.pronamespace = 'public'::regnamespace
                         and p.proname in ('ops_board','ops_order_detail','ops_sla_config_get',
                                           'ops_sla_config_set','ops_sla_tick','ops_stage_deadline')),
    'copy_renamed',  (select count(*) from ui_copy
                       where key like 'ops_board.%' and value::text ilike '%SLA%'),
    'wa_route',      (select push_title from wa_event_routes where event_key = 'partner_sla_breach'));
$$;
revoke execute on function public.cmd1845_stage_deadline_proof() from public, anon;
grant execute on function public.cmd1845_stage_deadline_proof() to authenticated, service_role;

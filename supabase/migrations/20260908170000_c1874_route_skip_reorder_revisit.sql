-- CMD #1874 — Route stops: Skip / reorder with backend re-sequencing;
-- Converted opens Add customer pre-filled; the revisit engine resurfaces leads.
--
-- Three gaps this closes, all of them backend gaps:
--
-- 1. A rep could CHECK IN on a stop (#1873) but could not take one OUT of the
--    day or move one earlier. The only re-sequencer in the database,
--    _route_rebuild_one(), DELETES every stop of the route and re-inserts it —
--    which would throw away the visit_status, note and photo #1873 stores on
--    the stop row. _c1874_resequence() does the same arithmetic (the same
--    _dm()/_ds() OSRM matrix, the same lead_is_open_at()/lead_next_open() wait
--    rule, the same dwell) but UPDATES the rows in place, so re-ordering a
--    route never loses a check-in.
--
-- 2. "Converted" wrote the outcome onto the lead and stopped there. The
--    registration form (#1887) and lead_customer_prefill() already existed, but
--    saving through it went to admin_import_customer() alone, which knows
--    nothing about scraped_leads — so a shop the rep converted on the doorstep
--    stayed an unlinked lead. lead_import_customer() is the same import in the
--    same transaction, plus the link back.
--
-- 3. The revisit engine was half-built: every plan-build predicate already read
--    revisit_after, but the line ABOVE it excluded last_visit_status
--    'not_interested' outright — and 'not_interested' is the ONLY status that
--    ever sets revisit_after. A parked lead could therefore never come back, no
--    matter how old its revisit date was. _c1874_visit_eligible() is now the one
--    predicate all three call sites share, and a due revisit is eligible again.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT DO
-- NOTHING, and a guarded textual patch that verifies its own result.

-- ── 1. A stop can be skipped without being deleted ────────────────────────
alter table public.route_plan_stops
  add column if not exists skipped_at timestamptz,
  add column if not exists skipped_by uuid;

create index if not exists route_plan_stops_skipped_idx
  on public.route_plan_stops (route_id, skipped_at);

-- ── 2. Copy (wording is an UPDATE on ui_copy, never a deploy) ─────────────
insert into ui_copy(key, value) values
  ('route_stop.skip_stop',        '"Skip this stop"'::jsonb),
  ('route_stop.unskip_stop',      '"Put back on the route"'::jsonb),
  ('route_stop.skipped_chip',     '"Skipped"'::jsonb),
  ('route_stop.menu_title',       '"{name}"'::jsonb),
  ('route_stop.menu_hint',        '"Skipping keeps the shop on the plan and takes it out of today''s order — every ETA after it moves up."'::jsonb),
  ('route_stop.menu_cancel',      '"Cancel"'::jsonb),
  ('route_stop.skipped_msg',      '"{name} skipped. {n} stops left."'::jsonb),
  ('route_stop.unskipped_msg',    '"{name} is back on the route at stop {seq}."'::jsonb),
  ('route_stop.reorder_hint',     '"Drag a stop to move it. Long-press for more."'::jsonb),
  ('route_stop.reorder_saved',    '"Order saved · {km} km · finishes {eta}."'::jsonb),
  ('route_stop.reorder_bad',      '"That order no longer matches this route — pull to refresh."'::jsonb),
  ('route_stop.reorder_locked',   '"Check in on a stop before re-ordering the rest."'::jsonb),
  ('route_stop.add_customer',     '"Add customer"'::jsonb),
  ('route_stop.add_customer_hint','"Pre-filled from this shop''s lead. Everything is editable."'::jsonb),
  ('route_stop.linked_msg',       '"{name} is now a customer."'::jsonb),
  ('route_stop.link_failed',      '"Customer saved, but the lead could not be linked."'::jsonb),
  ('sleads.revisit_chip',         '"Revisit"'::jsonb),
  ('sleads.revisit_due',          '"Revisit due {date}"'::jsonb)
on conflict (key) do nothing;

-- ── 3. The one visit/revisit eligibility rule ─────────────────────────────
-- Three call sites (route_lead_count, _route_plan_build, _route_plan_build_road)
-- each carried their OWN copy of this predicate, and all three carried the same
-- bug. They now share this function, so the rule is changed in ONE place.
--
--   * converted / permanently_closed are never planned again, full stop.
--   * a lead whose revisit_after has come due is eligible AGAIN, whichever
--     fresh/visited chip is on — that is what "revisit" means. Before this, a
--     'not_interested' lead was excluded by status forever and its revisit date
--     was dead data.
--   * a revisit date still in the future parks the lead until then.
--   * everything else is the old fresh/visited chip rule, unchanged.
create or replace function public._c1874_visit_eligible(
  p_visit        text[],
  p_visit_count  integer,
  p_last_status  text,
  p_revisit_after date)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(p_last_status, '') not in ('permanently_closed', 'converted')
     and case
           when p_revisit_after is not null
             then p_revisit_after <= (now() at time zone 'Asia/Kolkata')::date
           else coalesce(p_last_status, '') <> 'not_interested'
            and ( ('fresh'   = any(p_visit) and coalesce(p_visit_count, 0) = 0)
               or ('visited' = any(p_visit) and coalesce(p_visit_count, 0) > 0) )
         end;
$function$;

grant execute on function public._c1874_visit_eligible(text[], integer, text, date) to authenticated;

-- ── 4. Point the three planners at it ─────────────────────────────────────
-- The predicate is three identical lines inside three large functions whose
-- bodies are otherwise untouched. Re-typing 300 lines to change 4 of them is
-- how a transcription bug gets shipped, so the old lines are replaced in the
-- live definition and the result is VERIFIED — a silent no-op raises here
-- instead of quietly leaving the old rule in place.
do $patch$
declare
  v_names text[] := array['route_lead_count', '_route_plan_build', '_route_plan_build_road'];
  v_name  text;
  v_oid   oid;
  v_def   text;
  v_new   text;
begin
  foreach v_name in array v_names loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name
     limit 1;
    if v_oid is null then
      raise exception 'c1874: % not found', v_name;
    end if;

    v_def := pg_get_functiondef(v_oid);

    if position('_c1874_visit_eligible' in v_def) = 0 then
      v_new := regexp_replace(
        v_def,
        'and\s*\(\s*\(''fresh''\s*=\s*any\(p_visit\)\s*and\s*(s2?)\.visit_count\s*=\s*0\)\s*'
        || 'or\s*\(''visited''\s*=\s*any\(p_visit\)\s*and\s*\1\.visit_count\s*>\s*0\)\s*\)\s*'
        || 'and\s*coalesce\(\1\.last_visit_status,''''\)\s*not\s+in\s*'
        || '\(''not_interested'',''permanently_closed'',''converted''\)\s*'
        || 'and\s*\(\s*\1\.revisit_after\s+is\s+null\s*'
        || 'or\s*\1\.revisit_after\s*<=\s*\(now\(\)\s*at\s+time\s+zone\s*''Asia/Kolkata''\)::date\s*\)',
        'and public._c1874_visit_eligible(p_visit, \1.visit_count, \1.last_visit_status, \1.revisit_after)',
        'gi');

      if v_new = v_def then
        raise exception 'c1874: eligibility predicate not found in % — patch would be a silent no-op', v_name;
      end if;
      execute v_new;

      if position('_c1874_visit_eligible' in pg_get_functiondef(v_oid)) = 0 then
        raise exception 'c1874: % did not take the new predicate', v_name;
      end if;
    end if;
  end loop;
end
$patch$;

-- ── 5. Re-sequence a route IN PLACE ───────────────────────────────────────
-- Same arithmetic as _route_rebuild_one(): the OSRM matrix (_dm metres,
-- _ds seconds), the plan's own start_min / dow / dwell_min, and the
-- lead_is_open_at + lead_next_open wait rule that lets a rep arrive early and
-- wait up to two hours for a shutter. The difference is that this UPDATES the
-- stop rows instead of deleting them, so every check-in survives.
--
-- Skipped stops keep their row and sink below the sequence with no ETA at all;
-- the route's own totals count the active stops only.
create or replace function public._c1874_resequence(p_route_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_plan   record;
  r        record;
  v_prev   bigint  := 0;      -- 0 is the hub in the distance matrix
  v_seq    integer := 0;
  v_cum_m  integer := 0;
  v_closed integer := 0;
  v_start  integer;
  v_t      integer;
  v_leg_m  integer;
  v_arrive integer;
  v_wait   integer;
  v_open   boolean;
  v_next   integer;
  v_home_m integer;
begin
  select pp.dow, coalesce(pp.start_min, 0) as start_min,
         coalesce(pp.dwell_min, 10) as dwell
    into v_plan
    from route_plan_routes rr
    join route_plans pp on pp.id = rr.plan_id
   where rr.id = p_route_id;
  if not found then return; end if;

  v_start := v_plan.start_min;
  v_t     := v_start;

  for r in
    select st.id, st.lead_id, sl.hours_json as hours
      from route_plan_stops st
      join scraped_leads sl on sl.id = st.lead_id
     where st.route_id = p_route_id and st.included and st.skipped_at is null
     order by st.seq, st.id
  loop
    v_seq    := v_seq + 1;
    v_leg_m  := public._dm(v_prev, r.lead_id);
    v_cum_m  := v_cum_m + v_leg_m;
    v_arrive := v_t + ceil(public._ds(v_prev, r.lead_id) / 60.0)::int;
    v_wait   := 0;
    v_open   := lead_is_open_at(r.hours, v_plan.dow, least(v_arrive, 1439)::int);
    if v_open is false then
      v_next := lead_next_open(r.hours, v_plan.dow, least(v_arrive, 1439)::int);
      if v_next is not null and v_next > v_arrive and (v_next - v_arrive) <= 120 then
        v_wait := v_next - v_arrive; v_arrive := v_next; v_open := true;
      else
        v_closed := v_closed + 1;
      end if;
    end if;

    update route_plan_stops set
      seq         = v_seq,
      leg_km      = round(v_leg_m / 1000.0, 2),
      cum_km      = round(v_cum_m / 1000.0, 2),
      eta_min     = v_arrive,
      wait_min    = v_wait,
      open_at_eta = coalesce(v_open, true)
     where id = r.id;

    v_t    := v_arrive + v_plan.dwell;
    v_prev := r.lead_id;
  end loop;

  -- Skipped / excluded stops keep their order relative to each other but hold
  -- no place in the day: no leg, no ETA, nothing for a rep to read as a plan.
  with tail as (
    select st.id, row_number() over (order by st.seq, st.id) as k
      from route_plan_stops st
     where st.route_id = p_route_id
       and (st.skipped_at is not null or not st.included))
  update route_plan_stops st set
    seq = v_seq + tail.k, leg_km = null, cum_km = null,
    eta_min = null, wait_min = 0, open_at_eta = null
   from tail where tail.id = st.id;

  v_home_m := case when v_seq > 0 then public._dm(v_prev, 0) else 0 end;

  update route_plan_routes rr set
    n_stops      = v_seq,
    total_km     = round((v_cum_m + v_home_m) / 1000.0, 2),
    total_min    = case when v_seq > 0
                     then (v_t + ceil(public._ds(v_prev, 0) / 60.0)::int) - v_start
                     else 0 end,
    closed_count = v_closed
   where rr.id = p_route_id;
end;
$function$;

-- ── 6. Skip / restore one stop ────────────────────────────────────────────
create or replace function public.route_stop_skip(
  p_stop_id uuid,
  p_skipped boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy jsonb;
  v_st   record;
  v_left integer;
  v_seq  integer;
  v_msg  text;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  select s.id, s.route_id, l.name
    into v_st
    from route_plan_stops s
    join scraped_leads l on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'stop_not_found',
      'message', coalesce(v_copy->>'route_stop.not_found',
                          'That stop is no longer on this route.'));
  end if;

  if not public._c1873_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot check in on this route.'));
  end if;

  update route_plan_stops set
    skipped_at = case when p_skipped then now() end,
    skipped_by = case when p_skipped then auth.uid() end
   where id = p_stop_id;

  perform public._c1874_resequence(v_st.route_id);

  select count(*) into v_left
    from route_plan_stops
   where route_id = v_st.route_id and included and skipped_at is null;
  select seq into v_seq from route_plan_stops where id = p_stop_id;

  if p_skipped then
    v_msg := replace(replace(
               coalesce(v_copy->>'route_stop.skipped_msg', '{name} skipped. {n} stops left.'),
               '{name}', coalesce(v_st.name, '')),
               '{n}', v_left::text);
  else
    v_msg := replace(replace(
               coalesce(v_copy->>'route_stop.unskipped_msg',
                        '{name} is back on the route at stop {seq}.'),
               '{name}', coalesce(v_st.name, '')),
               '{seq}', coalesce(v_seq, 0)::text);
  end if;

  return jsonb_build_object(
    'ok',      true,
    'stop_id', p_stop_id,
    'skipped', p_skipped,
    'message', v_msg,
    'stops',   public.route_stops_today(v_st.route_id));
end;
$function$;

-- ── 7. Re-order the whole route ───────────────────────────────────────────
-- p_stop_ids is the ACTIVE stops in their new order, exactly as the list on
-- screen reads. A partial or stale list is refused with the backend's own
-- sentence rather than half-applied.
create or replace function public.route_reorder(
  p_route_id uuid,
  p_stop_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy  jsonb;
  v_have  integer;
  v_sent  integer := coalesce(array_length(p_stop_ids, 1), 0);
  v_mine  integer;
  v_km    numeric;
  v_min   integer;
  v_start integer;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  if not public._c1873_route_ok(p_route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot check in on this route.'));
  end if;

  select count(*) into v_have
    from route_plan_stops
   where route_id = p_route_id and included and skipped_at is null;

  select count(distinct s.id) into v_mine
    from route_plan_stops s
   where s.route_id = p_route_id and s.included and s.skipped_at is null
     and s.id = any(p_stop_ids);

  if v_sent <> v_have or v_mine <> v_sent then
    return jsonb_build_object('ok', false, 'error', 'stale_order',
      'message', coalesce(v_copy->>'route_stop.reorder_bad',
                          'That order no longer matches this route — pull to refresh.'),
      'stops', public.route_stops_today(p_route_id));
  end if;

  -- Park the new order well above every live seq first, so nothing collides
  -- while the update runs; _c1874_resequence then renumbers 1..n from it.
  update route_plan_stops s set seq = 100000 + u.ord::int
    from unnest(p_stop_ids) with ordinality u(id, ord)
   where s.id = u.id and s.route_id = p_route_id;

  perform public._c1874_resequence(p_route_id);

  select rr.total_km, rr.total_min, coalesce(pp.start_min, 0)
    into v_km, v_min, v_start
    from route_plan_routes rr
    join route_plans pp on pp.id = rr.plan_id
   where rr.id = p_route_id;

  return jsonb_build_object(
    'ok',       true,
    'route_id', p_route_id,
    'message',  replace(replace(
                  coalesce(v_copy->>'route_stop.reorder_saved',
                           'Order saved · {km} km · finishes {eta}.'),
                  '{km}',  to_char(coalesce(v_km, 0), 'FM990.0')),
                  '{eta}', to_char((time '00:00' + make_interval(
                             mins => v_start + coalesce(v_min, 0)))::time,
                           'FMHH12:MI AM')),
    'stops',    public.route_stops_today(p_route_id));
end;
$function$;

-- ── 8. The stop list learns about skipping and dragging ───────────────────
-- Same payload as #1873 plus: the skipped chip, the long-press menu (which is
-- where Skip and Restore live) and the route-level reorder block. Dart still
-- decides nothing — it draws this.
create or replace function public.route_stops_today(p_route_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy  jsonb;
  v_rows  jsonb := '[]'::jsonb;
  v_n     integer := 0;
  v_act   integer := 0;
  r       record;
  v_meta  jsonb;
  v_shut  boolean;
  v_acts  jsonb;
  v_menu  jsonb;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  if not public._c1873_route_ok(p_route_id) then
    return jsonb_build_object(
      'ok', false, 'route_id', p_route_id, 'stops', '[]'::jsonb,
      'can_reorder', false,
      'title',       coalesce(v_copy->>'route_stop.stops_title', 'Stops'),
      'count_label', '',
      'empty_label', coalesce(v_copy->>'route_stop.stops_locked',
                              'This route is not in the active zone or date.'));
  end if;

  for r in
    select st.id as stop_id, st.lead_id, st.seq, st.eta_min, st.open_at_eta,
           st.visit_status, st.visited_at, st.note, st.photo_url, st.skipped_at,
           l.name, coalesce(nullif(btrim(l.short_address), ''), l.address) as addr,
           pp.start_min
      from route_plan_stops st
      join scraped_leads    l  on l.id = st.lead_id
      join route_plan_routes rr on rr.id = st.route_id
      join route_plans      pp on pp.id = rr.plan_id
     where st.route_id = p_route_id and st.included
     order by (st.skipped_at is not null), st.seq
  loop
    v_meta := public._c1873_status_meta(r.visit_status);
    -- "Closed at ETA" is a WARNING about the shop's hours, not an outcome: it
    -- disappears the moment the stop has one, and a skipped stop has no ETA to
    -- be closed at.
    v_shut := (r.open_at_eta is false) and r.visit_status is null
              and r.skipped_at is null;

    v_acts := '[]'::jsonb;
    v_menu := '[]'::jsonb;

    if r.skipped_at is null then
      v_acts := v_acts || jsonb_build_object(
        'key',   'checkin',
        'label', case when r.visit_status is null
                   then coalesce(v_copy->>'route_stop.checkin_action', 'Check in')
                   else coalesce(v_copy->>'route_stop.redo_action', 'Change') end,
        'tone',  'brand');
      if v_shut then
        -- One tap: the Skip button posts THIS status to route_stop_checkin.
        -- Dart never decides what skipping means.
        v_acts := v_acts || jsonb_build_object(
          'key',    'skip',
          'label',  coalesce(v_copy->>'route_stop.skip_action', 'Skip'),
          'status', 'closed',
          'tone',   'warning');
      end if;
      v_menu := v_menu || jsonb_build_object(
        'key',     'stop_skip',
        'label',   coalesce(v_copy->>'route_stop.skip_stop', 'Skip this stop'),
        'skipped', true,
        'tone',    'warning');
      v_act := v_act + 1;
    else
      v_acts := v_acts || jsonb_build_object(
        'key',   'unskip',
        'label', coalesce(v_copy->>'route_stop.unskip_stop', 'Put back on the route'),
        'tone',  'brand');
      v_menu := v_menu || jsonb_build_object(
        'key',     'stop_unskip',
        'label',   coalesce(v_copy->>'route_stop.unskip_stop', 'Put back on the route'),
        'skipped', false,
        'tone',    'brand');
    end if;

    v_rows := v_rows || jsonb_build_object(
      'stop_id',      r.stop_id,
      'lead_id',      r.lead_id,
      'seq',          r.seq,
      'seq_label',    case when r.skipped_at is null then r.seq::text else '–' end,
      'name',         coalesce(r.name, ''),
      'address',      coalesce(r.addr, ''),
      'eta_label',    case when r.eta_min is not null and r.skipped_at is null then
                        -- eta_min is ABSOLUTE minutes past midnight: the
                        -- planner seeds its clock at the plan's start_min
                        -- before the first leg (_route_rebuild_one), so adding
                        -- start_min again here — as #1873 did — printed a
                        -- 10:00 start as 8:01 PM.
                        replace(coalesce(v_copy->>'route_stop.eta', 'ETA {eta}'), '{eta}',
                          to_char((time '00:00' + make_interval(
                            mins => r.eta_min))::time,
                            'FMHH12:MI AM')) end,
      'closed_label', case when v_shut then
                        coalesce(v_copy->>'route_stop.closed_at_eta', 'Closed at ETA') end,
      'is_closed_at_eta', v_shut,
      'skipped',      (r.skipped_at is not null),
      'skipped_label', case when r.skipped_at is not null then
                        coalesce(v_copy->>'route_stop.skipped_chip', 'Skipped') end,
      'can_drag',     (r.skipped_at is null),
      'status_key',   r.visit_status,
      'status_label', case when v_meta is not null then
                        replace(replace(
                          coalesce(v_copy->>'route_stop.done_at', '{status} · {time}'),
                          '{status}', v_meta->>'label'),
                          '{time}', to_char(r.visited_at at time zone 'Asia/Kolkata', 'FMHH12:MI AM'))
                      else coalesce(v_copy->>'route_stop.pending', 'Not checked in') end,
      'status_tone',  coalesce(v_meta->>'tone', 'neutral'),
      'note_label',   case when nullif(btrim(coalesce(r.note, '')), '') is not null then
                        replace(coalesce(v_copy->>'route_stop.note_line', 'Note: {note}'),
                                '{note}', btrim(r.note)) end,
      'photo_url',    r.photo_url,
      'photo_label',  case when r.photo_url is not null then
                        coalesce(v_copy->>'route_stop.photo_open', 'View photo') end,
      'actions',      v_acts,
      'menu',         v_menu,
      'menu_title',   replace(coalesce(v_copy->>'route_stop.menu_title', '{name}'),
                              '{name}', coalesce(r.name, '')),
      'menu_hint',    coalesce(v_copy->>'route_stop.menu_hint', ''),
      'menu_cancel',  coalesce(v_copy->>'route_stop.menu_cancel', 'Cancel')
    );
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object(
    'ok',          true,
    'route_id',    p_route_id,
    'title',       coalesce(v_copy->>'route_stop.stops_title', 'Stops'),
    'count_label', case when v_act = 1
                     then coalesce(v_copy->>'route_stop.stops_one', '1 stop')
                     else replace(coalesce(v_copy->>'route_stop.stops_many', '{n} stops'),
                                  '{n}', v_act::text) end,
    'count',       v_n,
    'active',      v_act,
    'stops',       v_rows,
    -- One stop cannot be re-ordered against itself; the hint is what tells a
    -- rep the list is draggable at all.
    'can_reorder',   (v_act > 1),
    'reorder_hint',  case when v_act > 1
                       then coalesce(v_copy->>'route_stop.reorder_hint',
                                     'Drag a stop to move it. Long-press for more.') end,
    'empty_label', case when v_n = 0 then
                     coalesce(v_copy->>'route_stop.stops_empty',
                              'No stops on this route yet.') end);
end;
$function$;

-- ── 9. Converted hands the rep straight to the registration form ──────────
-- Same signature and same writes as #1873; the addition is next_action, which
-- is how the backend (not Dart) decides that a conversion opens Add customer.
create or replace function public.route_stop_checkin(
  p_stop_id uuid,
  p_status  text,
  p_note    text default null,
  p_photo   text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy   jsonb;
  v_st     record;
  v_meta   jsonb;
  v_url    text;
  v_base   text;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_worker uuid := public.my_worker_id();
  v_lead   scraped_leads%rowtype;
  v_msg    text;
  v_next   jsonb;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  v_meta := public._c1873_status_meta(p_status);
  if v_meta is null then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', coalesce(v_copy->>'route_stop.bad_status', 'Unknown outcome.'));
  end if;

  select s.id, s.route_id, s.lead_id, rr.assignment_id, l.name
    into v_st
    from route_plan_stops s
    join route_plan_routes rr on rr.id = s.route_id
    join scraped_leads     l  on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'stop_not_found',
      'message', coalesce(v_copy->>'route_stop.not_found',
                          'That stop is no longer on this route.'));
  end if;

  if not public._c1873_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot check in on this route.'));
  end if;

  if nullif(btrim(coalesce(p_photo, '')), '') is not null then
    v_base := coalesce((select value #>> '{}' from app_settings where key='storage_public_base'),
                       'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public');
    v_url  := v_base || '/lead-photos/' || btrim(p_photo);
  end if;

  update route_plan_stops set
    visit_status = p_status,
    visited_at   = now(),
    visited_by   = auth.uid(),
    note         = v_note,
    photo_url    = coalesce(v_url, photo_url)
  where id = p_stop_id;

  insert into lead_visits (lead_id, worker_id, assignment_id, status, note,
                           photo_url, verified, suspicious)
  values (v_st.lead_id, v_worker, v_st.assignment_id, p_status, v_note,
          v_url, true, false);

  select * into v_lead from scraped_leads where id = v_st.lead_id;

  if p_status = 'not_interested' and v_lead.revisit_after is not null then
    v_msg := replace(replace(replace(
               coalesce(v_copy->>'route_stop.saved_revisit',
                        '{name} — {status}. Back on a route after {date}.'),
               '{name}',   coalesce(v_st.name, '')),
               '{status}', v_meta->>'label'),
               '{date}',   to_char(v_lead.revisit_after, 'FMDD Mon YYYY'));
  else
    v_msg := replace(replace(
               coalesce(v_copy->>'route_stop.saved', '{name} — {status}.'),
               '{name}',   coalesce(v_st.name, '')),
               '{status}', v_meta->>'label');
  end if;

  -- Converted, and this shop is not a customer yet: the rep is handed the
  -- registration form pre-filled from the lead. A shop already linked gets
  -- no second form.
  if p_status = 'converted' and v_lead.matched_customer_id is null then
    v_next := jsonb_build_object(
      'key',     'add_customer',
      'lead_id', v_st.lead_id,
      'label',   coalesce(v_copy->>'route_stop.add_customer', 'Add customer'),
      'hint',    coalesce(v_copy->>'route_stop.add_customer_hint', ''));
  end if;

  return jsonb_build_object(
    'ok',            true,
    'stop_id',       p_stop_id,
    'lead_id',       v_st.lead_id,
    'status',        p_status,
    'status_label',  v_meta->>'label',
    'status_tone',   v_meta->>'tone',
    'photo_url',     v_url,
    'visit_count',   v_lead.visit_count,
    'revisit_after', v_lead.revisit_after,
    'next_action',   v_next,
    'message',       v_msg);
end;
$function$;

-- ── 10. Import a customer AND link the lead, in one transaction ───────────
-- admin_import_customer() is the shared registration write and knows nothing
-- about scraped_leads. Calling it and then linking from Dart would leave an
-- unlinked lead behind whenever the second call lost the network. This is the
-- same import plus the link-back, so either both land or neither does.
create or replace function public.lead_import_customer(p jsonb, p_lead_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_res  jsonb;
  v_id   uuid;
  v_lead scraped_leads%rowtype;
  v_copy text;
begin
  v_res := public.admin_import_customer(p);
  v_id  := nullif(v_res->>'customer_id', '')::uuid;

  if v_id is null or p_lead_id is null then
    return v_res;
  end if;

  select * into v_lead from scraped_leads where id = p_lead_id;
  if not found then
    return v_res || jsonb_build_object(
      'lead_linked', false,
      'link_message', coalesce((select value #>> '{}' from ui_copy
                                 where key = 'route_stop.link_failed'),
                               'Customer saved, but the lead could not be linked.'));
  end if;

  update scraped_leads set
    status              = 'converted',
    matched_kind        = 'customer',
    matched_customer_id = v_id,
    match_reason        = 'converted from lead',
    lead_score          = 0
   where id = p_lead_id
     and matched_customer_id is null;

  v_copy := replace(coalesce((select value #>> '{}' from ui_copy
                               where key = 'route_stop.linked_msg'),
                             '{name} is now a customer.'),
                    '{name}', coalesce(v_lead.name, ''));

  return v_res || jsonb_build_object(
    'lead_id',      p_lead_id,
    'lead_linked',  true,
    'customer_id',  v_id,
    'link_message', v_copy);
end;
$function$;

-- ── 11. The Revisit chip in S Leads ───────────────────────────────────────
-- get_scraped_leads() does not carry the visit ledger, so the page joins the
-- lead back for the two columns the chip needs. Due today or earlier = the
-- lead is planable again (rule 3 above) and says so. Everything else in this
-- function is #1867/#1869/#1871's body, unchanged — same 13-argument
-- signature, so no overload is created.
CREATE OR REPLACE FUNCTION public.sleads_page(p_city text DEFAULT NULL::text, p_class text DEFAULT NULL::text, p_targets_only boolean DEFAULT true, p_with_phone boolean DEFAULT false, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_open_now boolean DEFAULT false, p_with_email boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_classes text[] DEFAULT NULL::text[], p_include_closed boolean DEFAULT false, p_filters jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy   jsonb;
  v_rows   jsonb := '[]'::jsonb;
  v_total  bigint := 0;
  v_n      integer := 0;
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_next   integer;
  v_more   boolean;
  v_f      jsonb;
  v_cls    text[];
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'sleads.%';

  -- One filter shape, whichever way the caller spelled it.
  v_f := case
           when p_filters is not null then public._sleads_filters_norm(p_filters)
           else public._sleads_filters_norm(jsonb_build_object(
                  'city', p_city,
                  'search', p_search,
                  'status', p_status,
                  'with_phone', coalesce(p_with_phone,false),
                  'open_now', coalesce(p_open_now,false),
                  'with_email', coalesce(p_with_email,false),
                  'show_non_targets', not coalesce(p_targets_only, true),
                  'show_closed', coalesce(p_include_closed,false),
                  'show_matched', coalesce(p_include_closed,false),
                  'classes', case when coalesce(p_classes, case when nullif(btrim(coalesce(p_class,'')),'') is null
                                                            then null
                                                            else string_to_array(p_class, ',') end) is null
                               then '[]'::jsonb
                               else to_jsonb(coalesce(p_classes, string_to_array(p_class, ','))) end))
         end;

  select coalesce(array_agg(x), null) into v_cls
    from jsonb_array_elements_text(v_f->'classes') x;

  with page as (
    select g.*,
           rv.revisit_after     as rv_revisit_after,
           rv.last_visit_status as rv_last_status,
           row_number() over () as ord
      from public.get_scraped_leads(
             p_city             => v_f->>'city',
             p_class            => null,
             p_targets_only     => true,
             p_with_phone       => (v_f->>'with_phone')::boolean,
             p_search           => v_f->>'search',
             -- CMD #1869
      p_status           => case when (v_f->>'archived')::boolean
                             then 'archived' else v_f->>'status' end,
             p_open_now         => (v_f->>'open_now')::boolean,
             p_with_email       => (v_f->>'with_email')::boolean,
             p_limit            => v_limit,
             p_offset           => v_offset,
             p_classes          => v_cls,
             p_include_closed   => false,
             p_min_score        => (v_f->>'min_score')::int,
             p_show_non_targets => (v_f->>'show_non_targets')::boolean,
             p_show_closed      => (v_f->>'show_closed')::boolean,
             p_show_matched     => (v_f->>'show_matched')::boolean,
             p_show_stale       => (v_f->>'show_stale')::boolean,
             p_preset           => v_f->>'preset',
             -- CMD #1871
             p_collapse_branches => not coalesce((v_f->>'show_all_branches')::boolean, false)) g
      -- CMD #1874 — get_scraped_leads() does not carry the visit ledger, so the
      -- two columns the Revisit chip needs are joined back per row.
      left join scraped_leads rv on rv.id = g.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            p.id,
           'title',         p.name,
           'type_label',    nullif(btrim(coalesce(p.type_label, '')), ''),
           'rating_label',  case when p.rating is not null
                              then trim(to_char(p.rating, 'FM90.0')) || ' ★'
                                   || case when coalesce(p.user_ratings, 0) > 0
                                        then ' (' || to_char(p.user_ratings, 'FM999,999,999') || ')'
                                        else '' end
                            end,
           'open_label',    case when p.open_now is true
                                 then coalesce(v_copy->>'sleads.open_now', 'Open now')
                                 when p.open_now is false
                                 then coalesce(v_copy->>'sleads.closed_now', 'Closed now') end,
           'open_bg',       case when p.open_now is true then '#D1FAE5'
                                 when p.open_now is false then '#FEE2E2' end,
           'open_fg',       case when p.open_now is true then '#065F46'
                                 when p.open_now is false then '#991B1B' end,
           'address_label', nullif(btrim(coalesce(p.short_address, p.address, '')), ''),
           'phone_label',   nullif(btrim(coalesce(p.phone, '')), ''),
           'has_photo',     (p.photo_url is not null and p.photo_url <> ''),
           -- CMD #1869 — the class chip and the Restore button, per row.
           'class_key',     p.effective_class,
           'class_label',   coalesce(v_copy->>('sleads.filters.class_' || p.effective_class),
                                     initcap(replace(p.effective_class, '_', ' '))),
           'archived',      (p.status = 'archived'),
           -- CMD #1871 — the branch chip travels with the row.
           'branches',            p.branches,
           'branches_label',      p.branches_label,
           'branches_expandable', p.branches_expandable
           ,
           -- CMD #1874 — the revisit engine's chip. Due today or earlier means
           -- _c1874_visit_eligible() will let this lead back into a plan.
           'revisit',       (p.rv_revisit_after is not null
                             and p.rv_revisit_after <= (now() at time zone 'Asia/Kolkata')::date),
           'revisit_label', case when p.rv_revisit_after is not null
                                  and p.rv_revisit_after <= (now() at time zone 'Asia/Kolkata')::date
                              then coalesce(v_copy->>'sleads.revisit_chip', 'Revisit') end,
           'revisit_due_label', case when p.rv_revisit_after is not null
                              then replace(coalesce(v_copy->>'sleads.revisit_due', 'Revisit due {date}'),
                                           '{date}', to_char(p.rv_revisit_after, 'FMDD Mon YYYY')) end,
           'last_visit_status', p.rv_last_status
         ) order by p.ord), '[]'::jsonb),
         coalesce(max(p.total_count), 0),
         count(*)
    into v_rows, v_total, v_n
    from page p;

  v_next := v_offset + v_n;
  v_more := v_next < v_total;

  return jsonb_build_object(
    'ok',            true,
    'page_size',     v_limit,
    'offset',        v_offset,
    'rows',          v_rows,
    'total',         v_total,
    'filters',       v_f,
    'count_chip',    replace(coalesce(v_copy->>'sleads.filters.count_chip','S Leads ({n})'),
                             '{n}', to_char(v_total, 'FM999,999,999')),
    'count_label',   replace(case when v_total = 1
                               then coalesce(v_copy->>'sleads.count_one',  '{n} lead')
                               else coalesce(v_copy->>'sleads.count_many', '{n} leads') end,
                             '{n}', to_char(v_total, 'FM999,999,999')),
    'has_more',      v_more,
    'next_offset',   case when v_more then v_next end,
    -- CMD #1869 — the bulk toolbar's labels and rules travel with the page.
    'bulk',          public.sleads_bulk_block(),
    'empty_label',   case when (v_f->>'archived')::boolean
                       then coalesce(v_copy->>'sleads.archived_empty', 'Nothing archived')
                       else coalesce(v_copy->>'sleads.empty', '0 leads match these filters') end,
    'more_label',    coalesce(v_copy->>'sleads.loading_more', 'Loading more…'),
    'end_label',     case when v_total > 0 and not v_more
                       then replace(coalesce(v_copy->>'sleads.end', 'All {n} leads shown'),
                                    '{n}', to_char(v_total, 'FM999,999,999')) end
  );
end;
$function$;

grant execute on function public._c1874_resequence(uuid) to authenticated;
grant execute on function public.route_stop_skip(uuid, boolean) to authenticated;
grant execute on function public.route_reorder(uuid, uuid[]) to authenticated;
grant execute on function public.lead_import_customer(jsonb, bigint) to authenticated;

-- ── 12. The ETA a rep reads is the ETA the planner wrote ──────────────────
-- route_plan_stops.eta_min is ABSOLUTE (minutes past midnight): the planner
-- starts its clock at the plan's start_min before the first leg. #1872 added
-- start_min to it a second time, so a route starting at 10:00 with a 23-minute
-- day reported "ETA 8:01 PM" on the card. The fallback — a route whose stops
-- carry no ETA at all — is still start_min + the route's own duration, which
-- IS relative. Guarded and verified, like the predicate patch above.
do $eta$
declare
  v_oid oid;
  v_def text;
  v_new text;
begin
  select p.oid into v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'routes_today' limit 1;
  if v_oid is null then raise exception 'c1874: routes_today not found'; end if;

  v_def := pg_get_functiondef(v_oid);
  v_new := replace(v_def,
    'v_etamin := coalesce(r.start_min, 0) + coalesce(v_etamin, coalesce(r.total_min, 0));',
    'v_etamin := coalesce(v_etamin, coalesce(r.start_min, 0) + coalesce(r.total_min, 0));');

  if v_new <> v_def then
    execute v_new;
  elsif position('v_etamin := coalesce(v_etamin, coalesce(r.start_min, 0)' in v_def) = 0 then
    raise exception 'c1874: routes_today ETA line not found — patch would be a silent no-op';
  end if;
end
$eta$;

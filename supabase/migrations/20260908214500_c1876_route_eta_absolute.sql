-- CMD #1876 — the stop times in the two WhatsApps were ten hours late.
--
-- Proved on the live build: assigning R3 · Changurabhata (plan start_min 600 =
-- 10:00 am) queued a worker message whose summary read "starts 10:00 am" while
-- its first stop read "08:05 pm". route_plan_stops.eta_min is ALREADY an
-- absolute minute-of-day (605 = 10:05 am) — the same number route_plan_get
-- prints as "ETA 10:05 AM" — so adding route_plans.start_min to it counted the
-- start twice. _c1876_route_summary was right because it formats start_min on
-- its own; the two places that formatted a STOP were wrong.
--
-- Fix: format eta_min verbatim, and fall back to the plan's start only when a
-- stop carries no eta at all. Idempotent: both objects are replaced whole.

create or replace function public._c1876_stop_list(p_route_id uuid, p_max integer default 12)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_txt text; v_n integer; v_extra integer; v_start integer;
begin
  select p.start_min into v_start
    from route_plan_routes r join route_plans p on p.id = r.plan_id
   where r.id = p_route_id;

  select count(*) into v_n
    from route_plan_stops s where s.route_id = p_route_id and s.included;

  select string_agg(x.line, ' · ' order by x.seq) into v_txt from (
    select s.seq,
           s.seq::text || '. '
             || coalesce(nullif(btrim(l.name), ''), '#' || l.id::text)
             -- eta_min is a minute-of-day, not an offset from the start.
             || coalesce(' ' || hhmm(coalesce(s.eta_min, v_start)), '')
             as line
      from route_plan_stops s
      join scraped_leads l on l.id = s.lead_id
     where s.route_id = p_route_id and s.included
     order by s.seq
     limit greatest(coalesce(p_max, 12), 1)) x;

  v_extra := greatest(coalesce(v_n, 0) - greatest(coalesce(p_max, 12), 1), 0);
  if v_extra > 0 then
    v_txt := v_txt || ' · '
      || replace(public._c1876_copy('routes.stop_more', '+{n} more'), '{n}', v_extra::text);
  end if;
  return coalesce(v_txt, '');
end;
$function$;

grant execute on function public._c1876_stop_list(uuid, integer) to authenticated;

create or replace function public.route_message_stops(p_route_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  r route_plan_routes%ROWTYPE;
  st record;
  v_res jsonb; v_ok boolean; v_reason text;
  v_sent integer := 0; v_skipped integer := 0; v_total integer := 0;
  v_rows jsonb := '[]'::jsonb;
  v_start integer; v_phone text; v_area text; v_date date;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO r FROM route_plan_routes WHERE id = p_route_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error','route_not_found'); END IF;
  IF NOT public._c1876_route_visible(p_route_id) THEN
    RETURN jsonb_build_object('ok', false, 'error','not_in_zone',
      'message', public._c1876_reason_label('not_visible'));
  END IF;

  v_date := public.admin_active_date();
  SELECT p.start_min INTO v_start
    FROM route_plans p WHERE p.id = r.plan_id;

  FOR st IN
    SELECT s.seq, s.eta_min, l.id AS lead_id, l.name, l.phone, l.area, l.locality, l.city
      FROM route_plan_stops s
      JOIN scraped_leads l ON l.id = s.lead_id
     WHERE s.route_id = p_route_id AND s.included
     ORDER BY s.seq
  LOOP
    v_total := v_total + 1;
    v_phone := nullif(btrim(coalesce(st.phone, '')), '');
    v_area  := coalesce(nullif(btrim(coalesce(st.area, st.locality, '')), ''), coalesce(st.city, ''));

    IF v_phone IS NULL THEN
      v_ok := false; v_reason := 'no_phone';
    ELSE
      v_res := public.wa_send_event_or_fallback(
                 'route_visiting_today', NULL,
                 jsonb_build_object(
                   'lead_name', coalesce(nullif(btrim(coalesce(st.name,'')),''), 'there'),
                   'visit_area', coalesce(nullif(v_area,''), 'your area'),
                   -- eta_min is a minute-of-day, not an offset from the start.
                   'visit_eta',  coalesce(hhmm(coalesce(st.eta_min, v_start)), 'today')),
                 v_phone, NULL);
      v_ok := coalesce((v_res->>'ok')::boolean, false);
      v_reason := v_res->>'reason';
    END IF;

    IF v_ok THEN v_sent := v_sent + 1; ELSE v_skipped := v_skipped + 1; END IF;

    v_rows := v_rows || jsonb_build_object(
      'seq',   st.seq,
      'name',  coalesce(nullif(btrim(coalesce(st.name,'')),''), '#' || st.lead_id::text),
      'ok',    v_ok,
      'tone',  CASE WHEN v_ok THEN 'success' ELSE 'warning' END,
      'label', CASE WHEN v_ok
                 THEN public._c1876_copy('routes.msg_stops_sent', '{n} sent')
                 ELSE public._c1876_reason_label(v_reason) END,
      'reason', v_reason);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'route_id', p_route_id,
    'title', replace(public._c1876_copy('routes.msg_stops_title', 'Visiting today — {route}'),
                     '{route}', coalesce(r.label, '')),
    'sent', v_sent,
    'skipped', v_skipped,
    'total', v_total,
    'sent_label',    replace(public._c1876_copy('routes.msg_stops_sent', '{n} sent'), '{n}', v_sent::text),
    'skipped_label', replace(public._c1876_copy('routes.msg_stops_skipped', '{n} skipped'), '{n}', v_skipped::text),
    'summary_label', CASE WHEN v_total = 0
      THEN public._c1876_copy('routes.msg_stops_empty', 'This route has no included stops yet')
      ELSE replace(replace(replace(
             public._c1876_copy('routes.msg_stops_summary', '{sent} sent · {skipped} skipped of {total} stops'),
             '{sent}', v_sent::text), '{skipped}', v_skipped::text), '{total}', v_total::text) END,
    'for_date', to_char(v_date, 'DD Mon YYYY'),
    'rows', v_rows);
END;
$function$;

grant execute on function public.route_message_stops(uuid) to authenticated;

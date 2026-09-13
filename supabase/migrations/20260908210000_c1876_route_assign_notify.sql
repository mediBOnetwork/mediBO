-- ─────────────────────────────────────────────────────────────────────────────
-- CMD #1876 — Routes: assign a route to a worker from the card, WhatsApp him
-- the ordered stop list, and bulk-message every stop "we are visiting today".
--
-- Nothing here is a NEW sending path. Both messages go through the existing
-- switchboard (wa_send_event_or_fallback → wa_event_routes → wa_templates),
-- which is also where the rails already live: notif_is_enabled() for the
-- audience switch, wa_suppression for MARKETING opt-out, and dedupe_minutes
-- (measured on wa_send_attempts) for frequency. This migration only adds two
-- event routes, their template seeds, the tokens they print, and two RPCs that
-- BUILD the tokens and REPORT the switchboard's own verdicts verbatim.
--
-- Every list/count/report below is zone- and date-scoped: admin_active_zone()
-- (NULL = super admin, all zones; a partner is locked to their own) via the
-- same _c1872_zone_match() the Routes tab already uses, and admin_active_date()
-- for the day a route is assigned to.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Copy — every string this feature prints ───────────────────────────────
insert into ui_copy (key, value) values
  ('routes.assign_wa_queued',   to_jsonb('WhatsApp sent to {name}'::text)),
  ('routes.assign_wa_blocked',  to_jsonb('Assigned. WhatsApp not sent — {reason}'::text)),
  ('routes.assign_wa_no_phone', to_jsonb('Assigned. {name} has no WhatsApp number on file'::text)),
  ('routes.msg_stops_btn',      to_jsonb('Message stops'::text)),
  ('routes.msg_stops_title',    to_jsonb('Visiting today — {route}'::text)),
  ('routes.msg_stops_confirm',  to_jsonb('Send a "visiting today" WhatsApp to every stop on this route that has a phone number?'::text)),
  ('routes.msg_stops_send',     to_jsonb('Send messages'::text)),
  ('routes.msg_stops_cancel',   to_jsonb('Cancel'::text)),
  ('routes.msg_stops_sent',     to_jsonb('{n} sent'::text)),
  ('routes.msg_stops_skipped',  to_jsonb('{n} skipped'::text)),
  ('routes.msg_stops_none',     to_jsonb('No stop on this route has a phone number'::text)),
  ('routes.msg_stops_summary',  to_jsonb('{sent} sent · {skipped} skipped of {total} stops'::text)),
  ('routes.msg_stops_empty',    to_jsonb('This route has no included stops yet'::text)),
  ('routes.msg_stops_reach',    to_jsonb('{n} of {total} stops have a phone number'::text)),
  ('routes.stops_one',          to_jsonb('{n} stop'::text)),
  ('routes.stops_many',         to_jsonb('{n} stops'::text)),
  ('routes.starts_at',          to_jsonb('starts {t}'::text)),
  ('routes.open_link_label',    to_jsonb('Open route'::text)),
  ('routes.stop_more',          to_jsonb('+{n} more'::text)),
  ('routes.wa_reason.no_phone',                  to_jsonb('no WhatsApp number'::text)),
  ('routes.wa_reason.suppressed',                to_jsonb('opted out of promotions'::text)),
  ('routes.wa_reason.notification_off',          to_jsonb('this notification is switched off'::text)),
  ('routes.wa_reason.already_delivered_recently',to_jsonb('already messaged recently'::text)),
  ('routes.wa_reason.legacy_already_delivered',  to_jsonb('already messaged recently'::text)),
  ('routes.wa_reason.template_not_approved',     to_jsonb('template still awaiting WhatsApp approval'::text)),
  ('routes.wa_reason.route_disabled',            to_jsonb('template still awaiting WhatsApp approval'::text)),
  ('routes.wa_reason.unknown_event',             to_jsonb('template still awaiting WhatsApp approval'::text)),
  ('routes.wa_reason.missing_values',            to_jsonb('a message value is missing'::text)),
  ('routes.wa_reason.missing_header_media',      to_jsonb('a message image is missing'::text)),
  ('routes.wa_reason.exception',                 to_jsonb('WhatsApp send failed'::text)),
  ('routes.wa_reason.not_visible',               to_jsonb('outside the active zone'::text)),
  ('routes.wa_reason.other',                     to_jsonb('not sent'::text))
on conflict (key) do nothing;

-- ── 2. Tokens the two templates print ────────────────────────────────────────
insert into wa_tokens (key, label, group_label, source_kind, source_ref, format,
                       example, enabled, is_system, sort_order)
values
  ('worker_name',    'Field worker name',   'Routes', 'computed', 'worker_name',    'title_case', 'Ramesh Kumar', true, true, 400),
  ('route_summary',  'Route summary line',  'Routes', 'computed', 'route_summary',  'plain', 'Route 2 · 9 stops · starts 09:30 am', true, true, 401),
  ('route_stop_list','Ordered stop list',   'Routes', 'computed', 'route_stop_list','plain', '1. Sharma Medical 09:45 am · 2. City Chemist 10:10 am', true, true, 402),
  ('route_link',     'Open-route link',     'Routes', 'computed', 'route_link',     'plain', 'https://medibo.in/admin/customers?tab=routes&route=…', true, true, 403),
  ('visit_date',     'Visit date',          'Routes', 'computed', 'visit_date',     'plain', '08 Sep 2026', true, true, 404),
  ('lead_name',      'Shop name (lead)',    'Routes', 'computed', 'lead_name',      'title_case', 'Sharma Medical Store', true, true, 405),
  ('visit_area',     'Area being visited',  'Routes', 'computed', 'visit_area',     'title_case', 'Shankar Nagar, Raipur', true, true, 406),
  ('visit_eta',      'Approximate visit time','Routes','computed', 'visit_eta',      'plain', '11:20 am', true, true, 407)
on conflict (key) do nothing;

-- ── 3. Template seeds — the autopilot creates, policy-reviews, submits and
--       enables these; wa_event_autopilot_10min runs every 10 minutes.
insert into wa_event_template_seeds (name, category, language, components, token_map)
values
  ('route_worker_assigned', 'UTILITY', 'en',
   '[{"type":"BODY","text":"Hi {{1}}, your visit route for {{2}} is ready: {{3}}. Stops in order: {{4}}. Open it here: {{5}} — please check in at every stop from the app.","example":{"body_text":[["Ramesh Kumar","08 Sep 2026","Route 2 · 9 stops · starts 09:30 am","1. Sharma Medical 09:45 am · 2. City Chemist 10:10 am","https://medibo.in/admin/customers?tab=routes"]]}},
     {"type":"FOOTER","text":"mediBO — B2B pharmacy supply"}]'::jsonb,
   '["worker_name","visit_date","route_summary","route_stop_list","route_link"]'::jsonb),
  ('route_visiting_today', 'MARKETING', 'en',
   '[{"type":"BODY","text":"Hi {{1}}, our mediBO representative is visiting {{2}} today and would like to meet you around {{3}}. Reply here if you would like a price list or want us to carry anything specific.","example":{"body_text":[["Sharma Medical Store","Shankar Nagar, Raipur","11:20 am"]]}},
     {"type":"FOOTER","text":"mediBO — B2B pharmacy supply"},
     {"type":"BUTTONS","buttons":[{"type":"QUICK_REPLY","text":"Stop promotions"}]}]'::jsonb,
   '["lead_name","visit_area","visit_eta"]'::jsonb)
on conflict (name) do update
  set category = excluded.category,
      components = excluded.components,
      token_map = excluded.token_map;

-- ── 4. Event routes — the switchboard entries. auto_manage lets the autopilot
--       attach the approved template id when Meta answers.
insert into wa_event_routes (event_key, label, description, audience, enabled,
                             auto_manage, auto_template_name, language,
                             variable_map, dedupe_minutes, wa_category, emitter_hint)
values
  ('route_worker_assigned',
   'Route assigned to a worker',
   'Sent to the field worker when an admin assigns him a route: the ordered stop list, the start time and a link that opens the route.',
   'worker', true, true, 'route_worker_assigned', 'en',
   '["{{worker_name}}","{{visit_date}}","{{route_summary}}","{{route_stop_list}}","{{route_link}}"]'::jsonb,
   60, 'utility', 'route_plan_assign()'),
  ('route_visiting_today',
   'Visiting your shop today',
   'Bulk "we are visiting today" message to every stop on a route that has a phone number.',
   'customer', true, true, 'route_visiting_today', 'en',
   '["{{lead_name}}","{{visit_area}}","{{visit_eta}}"]'::jsonb,
   720, 'marketing', 'route_message_stops()')
on conflict (event_key) do update
  set label = excluded.label,
      description = excluded.description,
      audience = excluded.audience,
      auto_manage = excluded.auto_manage,
      auto_template_name = excluded.auto_template_name,
      variable_map = excluded.variable_map,
      dedupe_minutes = excluded.dedupe_minutes,
      wa_category = excluded.wa_category,
      emitter_hint = excluded.emitter_hint;

-- ── 5. Helpers ───────────────────────────────────────────────────────────────

-- copy with a literal fallback: _c() returns '' (never NULL) for a missing key,
-- so coalesce() alone would never reach the fallback.
create or replace function public._c1876_copy(p_key text, p_fallback text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$ select coalesce(nullif(public._c(p_key), ''), p_fallback); $function$;

-- Is this route inside the caller's active zone? NULL zone = all zones.
create or replace function public._c1876_route_visible(p_route_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public._c1872_zone_match(
           public.admin_active_zone(),
           (select p.city from route_plan_routes r
              join route_plans p on p.id = r.plan_id
             where r.id = p_route_id),
           (select l.zone_id
              from route_plan_stops s
              join scraped_leads l on l.id = s.lead_id
             where s.route_id = p_route_id and s.included and l.zone_id is not null
             group by l.zone_id order by count(*) desc limit 1));
$function$;

-- A skip reason turned into words. Unknown reasons print the backend's own
-- text rather than a blank — a silent skip is the bug this avoids.
create or replace function public._c1876_reason_label(p_reason text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    nullif(public._c('routes.wa_reason.' || coalesce(p_reason, 'other')), ''),
    nullif(coalesce(p_reason,''), ''),
    public._c1876_copy('routes.wa_reason.other', 'not sent'));
$function$;

-- The ordered stop list as ONE line. A WhatsApp template parameter may not
-- contain a newline (Meta rejects the send), so the separator is ' · '.
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
             || coalesce(' ' || hhmm(coalesce(v_start, 0) + coalesce(s.eta_min, 0)), '')
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

-- The link that opens exactly this route in the app.
create or replace function public._c1876_route_link(p_route_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public._c417_base_url() || '/admin/customers?tab=routes&route=' || p_route_id::text;
$function$;

-- "Route 2 · 9 stops · starts 09:30 am"
create or replace function public._c1876_route_summary(p_route_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(nullif(btrim(r.label), ''), 'Route ' || r.seq::text)
         || ' · ' || replace(
              case when n.c = 1
                then public._c1876_copy('routes.stops_one',  '{n} stop')
                else public._c1876_copy('routes.stops_many', '{n} stops') end,
              '{n}', n.c::text)
         || coalesce(' · ' || replace(public._c1876_copy('routes.starts_at', 'starts {t}'),
                                      '{t}', hhmm(p.start_min)), '')
    from route_plan_routes r
    join route_plans p on p.id = r.plan_id
    cross join lateral (select count(*)::int as c from route_plan_stops s
                         where s.route_id = r.id and s.included) n
   where r.id = p_route_id;
$function$;

grant execute on function public._c1876_copy(text, text) to authenticated;
grant execute on function public._c1876_route_visible(uuid) to authenticated;
grant execute on function public._c1876_reason_label(text) to authenticated;
grant execute on function public._c1876_stop_list(uuid, integer) to authenticated;
grant execute on function public._c1876_route_link(uuid) to authenticated;
grant execute on function public._c1876_route_summary(uuid) to authenticated;

-- ── 6. route_plan_assign — same signature, same writes, now it also tells the
--       worker. The WhatsApp verdict is the switchboard's, printed verbatim.
create or replace function public.route_plan_assign(
  p_route_id uuid, p_worker_id uuid, p_for_date date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_a uuid; d date; r route_plan_routes%ROWTYPE; v_zone bigint;
  w lead_workers%ROWTYPE;
  v_wa jsonb; v_ok boolean; v_reason text; v_wa_label text; v_phone text;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO r FROM route_plan_routes WHERE id = p_route_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error','route_not_found'); END IF;
  IF NOT public._c1876_route_visible(p_route_id) THEN
    RETURN jsonb_build_object('ok', false, 'error','not_in_zone',
      'message', public._c1876_reason_label('not_visible'));
  END IF;

  SELECT * INTO w FROM lead_workers WHERE id = p_worker_id;
  d := COALESCE(p_for_date, public.admin_active_date());

  SELECT l.zone_id INTO v_zone
    FROM route_plan_stops s
    JOIN scraped_leads l ON l.id = s.lead_id
   WHERE s.route_id = p_route_id AND s.included AND l.zone_id IS NOT NULL
   GROUP BY l.zone_id
   ORDER BY count(*) DESC
   LIMIT 1;

  INSERT INTO lead_assignments (zone_id, worker_id, assigned_by, for_date,
                                target_stops, min_score)
  VALUES (v_zone, p_worker_id, auth.uid(), d, r.n_stops, 1)
  RETURNING id INTO v_a;

  UPDATE route_plan_routes SET worker_id = p_worker_id, assignment_id = v_a
   WHERE id = p_route_id;

  -- ── the WhatsApp. Existing switchboard, existing rails, nothing new. ──
  v_phone := nullif(btrim(coalesce(w.phone, '')), '');
  IF v_phone IS NULL THEN
    v_ok := false; v_reason := 'no_phone';
    v_wa_label := replace(public._c1876_copy('routes.assign_wa_no_phone',
                    'Assigned. {name} has no WhatsApp number on file'),
                  '{name}', coalesce(w.name, 'This worker'));
  ELSE
    v_wa := public.wa_send_event_or_fallback(
              'route_worker_assigned', NULL,
              jsonb_build_object(
                'worker_name',     coalesce(w.name, ''),
                'visit_date',      to_char(d, 'DD Mon YYYY'),
                'route_summary',   public._c1876_route_summary(p_route_id),
                'route_stop_list', public._c1876_stop_list(p_route_id, 12),
                'route_link',      public._c1876_route_link(p_route_id)),
              v_phone, NULL);
    v_ok := coalesce((v_wa->>'ok')::boolean, false);
    v_reason := v_wa->>'reason';
    IF v_ok THEN
      v_wa_label := replace(public._c1876_copy('routes.assign_wa_queued',
                      'WhatsApp sent to {name}'), '{name}', coalesce(w.name, ''));
    ELSE
      v_wa_label := replace(public._c1876_copy('routes.assign_wa_blocked',
                      'Assigned. WhatsApp not sent — {reason}'),
                    '{reason}', public._c1876_reason_label(v_reason));
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'assignment_id', v_a,
    'route_link', public._c1876_route_link(p_route_id),
    'wa', jsonb_build_object('ok', v_ok, 'reason', v_reason, 'label', v_wa_label,
                             'phone', v_phone),
    'message', coalesce(w.name, 'Worker') || ' assigned ' || coalesce(r.n_stops, 0)
               || ' stops on ' || coalesce(r.label, '') || ' — ' || v_wa_label);
END;
$function$;

grant execute on function public.route_plan_assign(uuid, uuid, date) to authenticated;

-- ── 7. route_message_stops — the bulk "visiting today". One switchboard call
--       per stop; every skip carries the switchboard's own reason in words.
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
                   'visit_eta',  coalesce(hhmm(coalesce(v_start,0) + coalesce(st.eta_min,0)), 'today')),
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

-- ── 8. route_message_stops_sheet — what the card needs BEFORE it asks: the
--       button caption, the confirm copy and how many stops can be reached.
create or replace function public.route_message_stops_sheet(p_route_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
DECLARE r route_plan_routes%ROWTYPE; v_total integer; v_with_phone integer;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO r FROM route_plan_routes WHERE id = p_route_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error','route_not_found'); END IF;

  SELECT count(*), count(*) FILTER (WHERE nullif(btrim(coalesce(l.phone,'')),'') IS NOT NULL)
    INTO v_total, v_with_phone
    FROM route_plan_stops s JOIN scraped_leads l ON l.id = s.lead_id
   WHERE s.route_id = p_route_id AND s.included;

  RETURN jsonb_build_object(
    'ok', true,
    'route_id', p_route_id,
    'button_label', public._c1876_copy('routes.msg_stops_btn', 'Message stops'),
    'title',   replace(public._c1876_copy('routes.msg_stops_title', 'Visiting today — {route}'),
                       '{route}', coalesce(r.label, '')),
    'body',    public._c1876_copy('routes.msg_stops_confirm',
                 'Send a "visiting today" WhatsApp to every stop on this route that has a phone number?'),
    'send_label',   public._c1876_copy('routes.msg_stops_send', 'Send messages'),
    'cancel_label', public._c1876_copy('routes.msg_stops_cancel', 'Cancel'),
    'reachable', coalesce(v_with_phone, 0),
    'total',     coalesce(v_total, 0),
    'can_send',  coalesce(v_with_phone, 0) > 0,
    'blocked_label', CASE WHEN coalesce(v_with_phone,0) = 0
      THEN CASE WHEN coalesce(v_total,0) = 0
             THEN public._c1876_copy('routes.msg_stops_empty', 'This route has no included stops yet')
             ELSE public._c1876_copy('routes.msg_stops_none', 'No stop on this route has a phone number') END
      END,
    'count_label', replace(replace(
       public._c1876_copy('routes.msg_stops_reach', '{n} of {total} stops have a phone number'),
       '{n}', coalesce(v_with_phone,0)::text), '{total}', coalesce(v_total,0)::text));
END;
$function$;

grant execute on function public.route_message_stops_sheet(uuid) to authenticated;

-- ── 9. route_open — a link carries a ROUTE id; the screen needs the plan that
--       holds it. Resolving that here keeps the deep link one backend answer
--       rather than a client-side search through every plan.
create or replace function public.route_open(p_route_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
DECLARE r route_plan_routes%ROWTYPE; p route_plans%ROWTYPE;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO r FROM route_plan_routes WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error','route_not_found',
      'message', public._c1876_copy('routes.open_not_found',
                   'That route no longer exists'));
  END IF;
  SELECT * INTO p FROM route_plans WHERE id = r.plan_id;
  IF NOT public._c1876_route_visible(p_route_id) THEN
    RETURN jsonb_build_object('ok', false, 'error','not_in_zone',
      'message', public._c1876_reason_label('not_visible'));
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'plan_id',  r.plan_id,
    'route_id', r.id,
    'tab',      'routes',
    'title',    public._c1876_route_summary(p_route_id),
    'plan_title', coalesce(p.city,'') || ' · ' || coalesce(p.k,0)::text || ' routes');
END;
$function$;

grant execute on function public.route_open(uuid) to authenticated;

insert into ui_copy (key, value) values
  ('routes.open_not_found', to_jsonb('That route no longer exists'::text))
on conflict (key) do nothing;

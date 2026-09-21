-- CMD #2147 — Header v2 + floating dock.
--
-- 1. order_hours_state().pill — the header's order-hours pill, decided here in
--    full: which of the six states the zone is in, the words, the tone
--    ({bg, fg, dot}), whether the dot pulses and how fast, and when the app
--    should ask again (refresh_s lands on the next minute boundary, so a
--    "Closes in 40 min" countdown switches exactly at the minute).
--    order_hours_state().sheet — what tapping the pill opens.
--    Flutter holds NO time logic: it prints label, paints tone, pulses on
--    pulse, and re-fetches after refresh_s.
-- 2. The words are ui_copy rows (one UPDATE re-words the pill, no deploy).
-- 3. ui_design touch.headerBand = 52 — the header row is 52 px (spec), and the
--    band travels by the same token.
--
-- Idempotent: replayed on live once at deploy.

-- ── 2. copy ──────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('order_hours.pill_open_till',      to_jsonb('Open till {time}'::text)),
  ('order_hours.pill_open_now',       to_jsonb('Open now'::text)),
  ('order_hours.pill_closes_in',      to_jsonb('Closes in {min} min'::text)),
  ('order_hours.pill_opens_in',       to_jsonb('Opens in {min} min'::text)),
  ('order_hours.pill_opens_tonight',  to_jsonb('Opens tonight {time}'::text)),
  ('order_hours.pill_opens_today',    to_jsonb('Opens today {time}'::text)),
  ('order_hours.pill_opens_tomorrow', to_jsonb('Opens tomorrow {time}'::text)),
  ('order_hours.pill_closed_today',   to_jsonb('Closed today'::text)),
  ('order_hours.sheet_title',         to_jsonb('Today''s order hours'::text)),
  ('order_hours.sheet_hours',         to_jsonb('{open} – {close}'::text)),
  ('order_hours.sheet_hours_open_only', to_jsonb('Opens {open}'::text)),
  ('order_hours.sheet_hours_close_only', to_jsonb('Open now · closes {close}'::text)),
  ('order_hours.sheet_hours_none',    to_jsonb('Set by mediBO each day'::text)),
  ('order_hours.sheet_note_open',     to_jsonb('Orders placed before closing are processed today.'::text)),
  ('order_hours.sheet_note_closed',   to_jsonb('You can keep adding to your cart. Place the order once we open.'::text))
on conflict (key) do nothing;

-- ── 1. the pill ──────────────────────────────────────────────────────────────
create or replace function public._c2147_copy(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select value #>> '{}' from public.ui_copy where key = p_key), '');
$$;

-- '12:00' -> '12 pm', '00:05' -> '12:05 am'
create or replace function public._c2147_clock(p_t time)
returns text language sql immutable as $$
  select case when p_t is null then ''
    else replace(lower(to_char(p_t, 'FMHH12:MI AM')), ':00 ', ' ') end;
$$;

create or replace function public._order_hours_pill(p_zone smallint, p_open boolean)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  h public.order_hours%rowtype;
  v_ts timestamp := (public.now_eff() at time zone 'Asia/Kolkata');
  v_now time := v_ts::time;
  v_mins int;
  v_state text; v_label text; v_tone text; v_pulse boolean := false;
  v_target timestamp;
  v_hours text; v_note text;
  v_refresh int;
begin
  select * into h from public.order_hours where zone_id = p_zone;
  if h.id is null then select * into h from public.order_hours order by id limit 1; end if;

  if p_open then
    if h.auto_close_time is null then
      v_state := 'open'; v_tone := 'success'; v_pulse := true;
      v_label := public._c2147_copy('order_hours.pill_open_now');
    else
      v_mins := ceil(extract(epoch from (h.auto_close_time - v_now)) / 60.0)::int;
      if v_mins <= 0 then v_mins := v_mins + 1440; end if;
      if v_mins <= 60 then
        v_state := 'last_hour'; v_tone := 'warning'; v_pulse := true;
        v_label := replace(public._c2147_copy('order_hours.pill_closes_in'), '{min}', v_mins::text);
      else
        v_state := 'open'; v_tone := 'success'; v_pulse := true;
        v_label := replace(public._c2147_copy('order_hours.pill_open_till'), '{time}',
                           public._c2147_clock(h.auto_close_time));
      end if;
    end if;
  elsif h.auto_open_time is null then
    v_state := 'closed_today'; v_tone := 'danger';
    v_label := public._c2147_copy('order_hours.pill_closed_today');
  else
    v_mins := ceil(extract(epoch from (h.auto_open_time - v_now)) / 60.0)::int;
    if v_mins <= 0 then v_mins := v_mins + 1440; end if;
    v_target := v_ts + make_interval(mins => v_mins);
    if v_mins <= 60 then
      v_state := 'opening_soon'; v_tone := 'info'; v_pulse := true;
      v_label := replace(public._c2147_copy('order_hours.pill_opens_in'), '{min}', v_mins::text);
    elsif v_target::date = v_ts::date then
      v_tone := 'neutral';
      if h.auto_open_time >= time '18:00' then
        v_state := 'opens_tonight';
        v_label := public._c2147_copy('order_hours.pill_opens_tonight');
      else
        v_state := 'opens_today';
        v_label := public._c2147_copy('order_hours.pill_opens_today');
      end if;
      v_label := replace(v_label, '{time}', public._c2147_clock(h.auto_open_time));
    else
      v_tone := 'neutral';
      -- A just-after-midnight opening is still "tonight" to a shopper.
      if h.auto_open_time < time '04:00' then
        v_state := 'opens_tonight';
        v_label := public._c2147_copy('order_hours.pill_opens_tonight');
      else
        v_state := 'opens_tomorrow';
        v_label := public._c2147_copy('order_hours.pill_opens_tomorrow');
      end if;
      v_label := replace(v_label, '{time}', public._c2147_clock(h.auto_open_time));
    end if;
  end if;

  -- The sheet: today's hours and one line of what it means.
  v_hours := case
    when h.auto_open_time is not null and h.auto_close_time is not null then
      replace(replace(public._c2147_copy('order_hours.sheet_hours'),
        '{open}', public._c2147_clock(h.auto_open_time)),
        '{close}', public._c2147_clock(h.auto_close_time))
    when h.auto_open_time is not null then
      replace(public._c2147_copy('order_hours.sheet_hours_open_only'),
        '{open}', public._c2147_clock(h.auto_open_time))
    when h.auto_close_time is not null then
      replace(public._c2147_copy('order_hours.sheet_hours_close_only'),
        '{close}', public._c2147_clock(h.auto_close_time))
    else public._c2147_copy('order_hours.sheet_hours_none') end;
  v_note := case when p_open then public._c2147_copy('order_hours.sheet_note_open')
                 else coalesce(nullif(h.closed_message, ''),
                               public._c2147_copy('order_hours.sheet_note_closed')) end;

  -- Ask again one second after the next minute boundary: every label above
  -- is minute-precise, so that is exactly when it can next change.
  v_refresh := 61 - floor(extract(second from v_ts))::int;

  return jsonb_build_object(
    'pill', jsonb_build_object(
      'state', v_state,
      'label', v_label,
      'tone', case v_tone
        when 'success' then jsonb_build_object('bg', '#E8F5EE', 'fg', '#1B7A43', 'dot', '#1B7A43')
        when 'warning' then jsonb_build_object('bg', '#FEF3C7', 'fg', '#92400E', 'dot', '#D97706')
        when 'info'    then jsonb_build_object('bg', '#EFF6FF', 'fg', '#1E40AF', 'dot', '#2563EB')
        when 'danger'  then jsonb_build_object('bg', '#FEE2E2', 'fg', '#991B1B', 'dot', '#DC2626')
        else                jsonb_build_object('bg', '#F3F4F6', 'fg', '#4B5563', 'dot', '#9CA3AF') end,
      'pulse', v_pulse,
      'pulse_ms', 1600,
      'refresh_s', v_refresh),
    'sheet', jsonb_build_object(
      'title', public._c2147_copy('order_hours.sheet_title'),
      'hours', v_hours,
      'note',  v_note));
end $$;

revoke all on function public._order_hours_pill(smallint, boolean) from public, anon, authenticated;
revoke all on function public._c2147_copy(text) from public, anon, authenticated;

-- order_hours_state: unchanged body, plus pill + sheet.
create or replace function public.order_hours_state(p_zone smallint default null::smallint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
DECLARE
  h order_hours%ROWTYPE; v_now time := (public.now_eff() AT TIME ZONE 'Asia/Kolkata')::time;
  v_open boolean;
  v_mins int; v_next text; v_zone smallint; v_zname text;
BEGIN
  v_zone := public.zone_effective(p_zone);
  SELECT * INTO h FROM order_hours WHERE zone_id = v_zone;
  IF h.id IS NULL THEN SELECT * INTO h FROM order_hours ORDER BY id LIMIT 1; END IF;
  SELECT name INTO v_zname FROM zones WHERE id = v_zone;
  -- CMD #1850 — on the real clock this IS h.is_open, byte for byte. Only a
  -- session that has pinned its clock sees the schedule's answer instead.
  v_open := public.order_hours_open_eff(v_zone);

  IF v_open AND h.auto_close_time IS NOT NULL THEN
    v_mins := (EXTRACT(epoch FROM (h.auto_close_time - v_now)) / 60)::int;
    IF v_mins < 0 THEN v_mins := v_mins + 1440; END IF;
    v_next := 'Auto-closes in ' || (v_mins/60) || 'h ' || lpad((v_mins%60)::text,2,'0') || 'm';
  ELSIF (NOT v_open) AND h.auto_open_time IS NOT NULL THEN
    v_mins := (EXTRACT(epoch FROM (h.auto_open_time - v_now)) / 60)::int;
    IF v_mins < 0 THEN v_mins := v_mins + 1440; END IF;
    v_next := 'Auto-opens in ' || (v_mins/60) || 'h ' || lpad((v_mins%60)::text,2,'0') || 'm';
  END IF;

  RETURN jsonb_build_object(
    'is_open', v_open, 'can_order', v_open,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,''),
    'status_label', CASE WHEN v_open THEN 'OPEN' ELSE 'CLOSED' END,
    'status_since', CASE WHEN v_open
      THEN 'Open since ' || to_char(h.last_opened_at AT TIME ZONE 'Asia/Kolkata','FMHH12:MI AM')
      ELSE 'Closed since ' || to_char(h.last_closed_at AT TIME ZONE 'Asia/Kolkata','FMHH12:MI AM') END,
    'schedule_label',
      COALESCE('Opens ' || to_char(h.auto_open_time,'FMHH12:MI AM'), 'No auto-open') || '  ·  ' ||
      COALESCE('Closes ' || to_char(h.auto_close_time,'FMHH12:MI AM'), 'No auto-close'),
    'next_change_label', v_next,
    'auto_open_label',  to_char(h.auto_open_time,'FMHH12:MI AM'),
    'auto_close_label', to_char(h.auto_close_time,'FMHH12:MI AM'),
    'auto_open_time',   to_char(h.auto_open_time,'HH24:MI'),
    'auto_close_time',  to_char(h.auto_close_time,'HH24:MI'),
    'now_label',        to_char(public.now_eff() AT TIME ZONE 'Asia/Kolkata','FMHH12:MI AM'),
    'closed_message', h.closed_message,
    'button_label',   CASE WHEN v_open THEN 'Place Order' ELSE 'Order hours closed' END,
    'popup_title',    CASE WHEN NOT v_open THEN 'Order hours are closed' END,
    'popup_message',  CASE WHEN NOT v_open THEN h.closed_message END,
    'updated_at', h.updated_at)
    || public._order_hours_pill(v_zone, v_open);
END; $function$;

-- ── 3. the header row is 52 px ───────────────────────────────────────────────
do $$
declare _touch jsonb;
begin
  if to_regprocedure('public.ui_design_set(jsonb)') is null then return; end if;
  select coalesce(value -> 'touch', '{}'::jsonb) into _touch
    from public.dev_runner_config where key = 'ui_design';
  perform public.ui_design_set(jsonb_build_object('touch',
    coalesce(_touch, '{}'::jsonb) || jsonb_build_object('headerBand', 52)));
end $$;

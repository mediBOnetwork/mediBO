-- CMD #2187 (Om, live on CHANGE #1527) — THE PILL HAS ONE AUTHOR, AND
-- order_hours_state() MUST QUOTE IT.
--
-- Om, incognito on live: "the pill is not rolling". The backend was right —
-- header_status_pill() returned the three lines, hold_ms and the 32/16 style
-- all along. But the header reads order_hours_state(), whose OWN copy of the
-- pill was still #2147's one-line shape:
--
--   pill = {label:'Opens tonight 12:05 am', tone:{…}, state, pulse}
--
-- One line, and a CLOCK in it — the two things this command exists to remove.
-- A client rendering that faithfully is a still pill, which is exactly what
-- Om saw. The branch database had the fix applied by hand and no migration
-- file carried it, so the live replay never saw it (lesson 388).
--
-- So: order_hours_state() re-takes the pill from header_status_pill() — the
-- ONE author — and resolves its zone through header_zone_scope() like every
-- other header door, so a visitor with no zone is 'universal' and is never
-- quietly given Raipur. Every other key of the payload is unchanged.
--
-- Idempotent: CREATE OR REPLACE, same signature.

CREATE OR REPLACE FUNCTION public.order_hours_state(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  h order_hours%rowtype; v_now time := (public.now_eff() at time zone 'Asia/Kolkata')::time;
  v_open boolean;
  v_mins int; v_next text; v_zone smallint; v_zname text;
  v_zs jsonb := public.header_zone_scope(p_zone);
begin
  v_zone := (v_zs->>'zone')::smallint;
  select * into h from order_hours where zone_id = v_zone;
  if h.id is null then select * into h from order_hours order by id limit 1; end if;
  select name into v_zname from zones where id = v_zone;
  v_open := public.order_hours_open_eff(v_zone);

  if v_open and h.auto_close_time is not null then
    v_mins := (extract(epoch from (h.auto_close_time - v_now)) / 60)::int;
    if v_mins < 0 then v_mins := v_mins + 1440; end if;
    v_next := 'Auto-closes in ' || (v_mins/60) || 'h ' || lpad((v_mins%60)::text,2,'0') || 'm';
  elsif (not v_open) and h.auto_open_time is not null then
    v_mins := (extract(epoch from (h.auto_open_time - v_now)) / 60)::int;
    if v_mins < 0 then v_mins := v_mins + 1440; end if;
    v_next := 'Auto-opens in ' || (v_mins/60) || 'h ' || lpad((v_mins%60)::text,2,'0') || 'm';
  end if;

  return jsonb_build_object(
    'is_open', v_open, 'can_order', v_open,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,''),
    'scope', v_zs->>'scope',
    'status_label', case when v_open then 'OPEN' else 'CLOSED' end,
    'status_since', case when v_open
      then 'Open since ' || to_char(h.last_opened_at at time zone 'Asia/Kolkata','FMHH12:MI AM')
      else 'Closed since ' || to_char(h.last_closed_at at time zone 'Asia/Kolkata','FMHH12:MI AM') end,
    'schedule_label',
      coalesce('Opens ' || to_char(h.auto_open_time,'FMHH12:MI AM'), 'No auto-open') || '  ·  ' ||
      coalesce('Closes ' || to_char(h.auto_close_time,'FMHH12:MI AM'), 'No auto-close'),
    'next_change_label', v_next,
    'auto_open_label',  to_char(h.auto_open_time,'FMHH12:MI AM'),
    'auto_close_label', to_char(h.auto_close_time,'FMHH12:MI AM'),
    'auto_open_time',   to_char(h.auto_open_time,'HH24:MI'),
    'auto_close_time',  to_char(h.auto_close_time,'HH24:MI'),
    'now_label',        to_char(public.now_eff() at time zone 'Asia/Kolkata','FMHH12:MI AM'),
    'closed_message', h.closed_message,
    'button_label',   case when v_open then 'Place Order' else 'Order hours closed' end,
    'popup_title',    case when not v_open then 'Order hours are closed' end,
    'popup_message',  case when not v_open then h.closed_message end,
    'updated_at', h.updated_at)
    || public._order_hours_pill(v_zone, v_open)
    -- The pill (and only the pill) is re-taken from the ONE pill author, so
    -- the header's chip, its palette and its refresh_at are the same object
    -- shell_style() ships.
    -- The zone is already resolved, so the pill is asked for THAT zone and
    -- wears the scope this call resolved — passing a zone in would otherwise
    -- make the pill report 'zone' to a visitor who has none.
    || jsonb_build_object('pill',
         public.header_status_pill(v_zone) || jsonb_build_object('scope', v_zs->>'scope'));
end $function$

;

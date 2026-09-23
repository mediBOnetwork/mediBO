-- CMD #2191 — the header pill hugs its text, and the words fit the phone.
--
-- WHAT WAS WRONG. Two separate causes, both visible as "Ordering clo…":
--   1. LAYOUT (Dart, see shell_mobile_chrome.dart): the pill was a
--      Flexible(loose) sitting beside a Spacer(), and a Row splits its free
--      space between flex children — so the pill was handed HALF the room the
--      row had left and ellipsised inside it while the space next to it sat
--      empty.
--   2. WORDS (here): the longest line the backend can send is
--      "We are packing today's orders" — 203.9 px in DMSans 600 @14, so
--      241.9 px of pill once the dot, its gap and pad_x are added. A 360 dp
--      header row leaves 233 px for the pill (360 − 28 inset − 49 mark − 10
--      gap − 40 bell) and a 320 dp row leaves 193. No layout can make 242 fit
--      in 193: below ~369 dp the SENTENCE has to be shorter, not the type.
--
-- THE RULE THIS KEEPS. The pill's text size never shrinks (CMD #2164) and the
-- roll is the only motion (CMD #2187), so a marquee is out. What changes is
-- the COPY, and copy is the backend's: the client reports the width it has
-- (p_w, logical px of the viewport) and this function answers with the tier
-- that fits it. Dart still prints `lines[]` verbatim and still paints
-- `style{}` verbatim — it decides nothing, it only reports its width.
--
--   p_w null or >= narrow.max_screen_w → the full wording, as before
--   p_w <  narrow.max_screen_w         → pill.copy.narrow's wording, merged
--                                        key-by-key over the full one
--
-- Every narrow string is <= 122.5 px, i.e. 160.5 px of pill, which fits the
-- 193 px a 320 dp row leaves with 32 px to spare.
--
-- ALSO: order_hours_state(p_zone, p_w) forwards the width to the ONE pill
-- author (lesson 388 — a payload that is "reported by" another RPC drifts the
-- moment only one of them is migrated).
--
-- Idempotent: drops the old single-argument signatures before creating the
-- two-argument ones, so a replay on live lands exactly once.

-- ── 1. the narrow wording, merged into pill.copy ─────────────────────────
insert into public.app_settings (key, value)
values ('pill.copy', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings set value = value || jsonb_build_object(
  'narrow', jsonb_build_object(
    -- Below this viewport width (logical px) the narrow wording is used.
    -- 369 = 127 px of header furniture + 242 px of the widest full pill.
    'max_screen_w', 369,
    'join', ' · ',
    'cta', jsonb_build_object('universal', 'Register to order'),
    'time', jsonb_build_object(
      'tomorrow',         'Opens tomorrow',
      'hour_left',        '1 hr left',
      'hours_left',       '{n} hrs left',
      'minute_left',      'Only 1 min left',
      'minutes_left',     'Only {n} min left',
      'open_no_close',    'Open all day',
      'opens_in_hour',    'Opens in 1 hr',
      'opens_in_hours',   'Opens in {n} hrs',
      'opens_in_minute',  'Opens in 1 min',
      'opens_in_minutes', 'Opens in {n} min'),
    'activity', jsonb_build_object(
      'bag',            'Packing orders',
      'idle',           'Taking orders',
      'pack',           'Packing orders',
      'count',          'Counting items',
      'accept',         'Accepting orders',
      'arrival',        'Items arriving',
      'collect',        'Collecting items',
      'inquiry',        'Asking suppliers',
      'dispatch',       'Ready to dispatch',
      'delivered',      'Out for delivery',
      'supplier_order', 'Ordering stock'),
    'fallback', jsonb_build_object(
      'l1',       'Closed today',
      'l2',       'Opens tomorrow',
      'l3',       'Packing orders',
      'activity', 'Taking orders'),
    'states', jsonb_build_object(
      'open',         jsonb_build_object('l1', 'Open now',         'l3', 'Order now'),
      'closed',       jsonb_build_object('l1', 'Closed today',     'l3', '{activity}'),
      'closed_today', jsonb_build_object('l1', 'Closed today',     'l3', '{activity}'),
      'closed_later', jsonb_build_object('l1', 'Closed today',     'l3', '{activity}'),
      'closing_soon', jsonb_build_object('l1', 'Open now',         'l3', 'Order fast'),
      'closing_now',  jsonb_build_object('l1', 'Closing soon',     'l3', 'Last chance'),
      'opening_soon', jsonb_build_object('l1', 'Closed right now', 'l3', 'List ready'))))
where key = 'pill.copy';

-- ── 2. the pill author, now width-aware ──────────────────────────────────
drop function if exists public.header_status_pill(smallint);

create or replace function public.header_status_pill(
  p_zone smallint default null,
  p_w    int      default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_all    jsonb := coalesce((select value from public.app_settings where key = 'pill.copy'), '{}'::jsonb);
  v_nar    jsonb := coalesce(v_all->'narrow', '{}'::jsonb);
  -- The tier IS the decision, and it is made here: a client that reports no
  -- width (an old build, a server-side caller) keeps the full wording.
  v_narrow boolean := p_w is not null
                  and p_w < coalesce((v_nar->>'max_screen_w')::int, 0);
  v_cfg    jsonb;
  v_time   jsonb;
  v_win    jsonb;
  v_fb     jsonb;
  v_zs     jsonb := public.header_zone_scope(null);
  v_scope  text  := coalesce(nullif(v_zs->>'scope',''), 'universal');
  v_zone   smallint := coalesce(p_zone, (v_zs->>'zone')::smallint);
  v_open   boolean;
  h        public.order_hours%rowtype;
  v_ts     timestamp := (public.now_eff() at time zone 'Asia/Kolkata');
  v_now    time;
  v_target timestamp;
  v_mins   int;
  v_hrs    int;
  v_state  text;
  v_st     jsonb;
  v_style  jsonb;
  v_l1 text; v_l2 text; v_l3 text;
  v_actkey text;
  v_act    text;
  v_oid    uuid;
  v_olabel text;
  v_refresh int;
begin
  -- The narrow tier is the full config with its own blocks merged OVER it,
  -- key by key, so a word the narrow tier does not name keeps the full one.
  if v_narrow then
    v_cfg := v_all
          || jsonb_build_object(
               'time',     coalesce(v_all->'time','{}'::jsonb)     || coalesce(v_nar->'time','{}'::jsonb),
               'activity', coalesce(v_all->'activity','{}'::jsonb) || coalesce(v_nar->'activity','{}'::jsonb),
               'fallback', coalesce(v_all->'fallback','{}'::jsonb) || coalesce(v_nar->'fallback','{}'::jsonb),
               'cta',      coalesce(v_all->'cta','{}'::jsonb)      || coalesce(v_nar->'cta','{}'::jsonb),
               'style',    coalesce(v_all->'style','{}'::jsonb)    || coalesce(v_nar->'style','{}'::jsonb),
               -- The UNION of both sides' state keys: a state the narrow tier
               -- names but the full one does not must still arrive worded.
               'states',   (select coalesce(jsonb_object_agg(k,
                                     coalesce(v_all->'states'->k, '{}'::jsonb)
                                  || coalesce(v_nar->'states'->k, '{}'::jsonb)), '{}'::jsonb)
                              from (select jsonb_object_keys(coalesce(v_all->'states','{}'::jsonb)) as k
                                    union
                                    select jsonb_object_keys(coalesce(v_nar->'states','{}'::jsonb))) as e));
  else
    v_cfg := v_all;
  end if;

  v_time := coalesce(v_cfg->'time', '{}'::jsonb);
  v_win  := coalesce(v_cfg->'windows', '{}'::jsonb);
  v_fb   := coalesce(v_cfg->'fallback', '{}'::jsonb);
  v_now  := v_ts::time;

  select * into h from public.order_hours where zone_id = v_zone;
  if h.id is null then select * into h from public.order_hours order by id limit 1; end if;

  begin v_open := public.order_hours_open_eff(v_zone);
  exception when others then v_open := false;
  end;

  -- ── the state, and line 2's RELATIVE wording ──
  if coalesce(v_open, false) then
    if h.auto_close_time is null then
      v_state := 'open';
      v_l2 := v_time->>'open_no_close';
    else
      v_mins := ceil(extract(epoch from (h.auto_close_time - v_now)) / 60.0)::int;
      if v_mins <= 0 then v_mins := v_mins + 1440; end if;
      if    v_mins <= coalesce((v_win->>'closing_now_min')::int, 30)  then v_state := 'closing_now';
      elsif v_mins <= coalesce((v_win->>'closing_soon_min')::int, 120) then v_state := 'closing_soon';
      else  v_state := 'open';
      end if;
      if v_mins < 60 then
        v_l2 := case when v_mins = 1 then v_time->>'minute_left'
                     else replace(v_time->>'minutes_left', '{n}', v_mins::text) end;
      else
        v_hrs := floor(v_mins / 60.0)::int;
        v_l2 := case when v_hrs = 1 then v_time->>'hour_left'
                     else replace(v_time->>'hours_left', '{n}', v_hrs::text) end;
      end if;
    end if;
  elsif h.auto_open_time is null then
    v_state := 'closed_today';
    v_l2 := v_time->>'tomorrow';
  else
    v_mins := ceil(extract(epoch from (h.auto_open_time - v_now)) / 60.0)::int;
    if v_mins <= 0 then v_mins := v_mins + 1440; end if;
    v_target := v_ts + make_interval(mins => v_mins);
    if v_mins <= coalesce((v_win->>'opening_soon_min')::int, 60) then
      v_state := 'opening_soon';
    elsif v_target::date = v_ts::date then
      v_state := 'closed_later';
    else
      v_state := 'closed';
    end if;
    if v_state = 'closed' then
      v_l2 := v_time->>'tomorrow';
    elsif v_mins < 60 then
      v_l2 := case when v_mins = 1 then v_time->>'opens_in_minute'
                   else replace(v_time->>'opens_in_minutes', '{n}', v_mins::text) end;
    else
      v_hrs := floor(v_mins / 60.0)::int;
      v_l2 := case when v_hrs = 1 then v_time->>'opens_in_hour'
                   else replace(v_time->>'opens_in_hours', '{n}', v_hrs::text) end;
    end if;
  end if;

  v_st := coalesce(v_cfg->'states'->v_state, '{}'::jsonb);

  -- ── scope: universal → zone → order. A live order outranks the zone. ──
  if v_scope = 'zone' then
    begin
      select o.id into v_oid
        from public.orders o
        join public.pharmacy_profiles pp on pp.id = o.customer_id
       where pp.user_id = auth.uid()
         and o.status <> 'cancelled'
         and o.closed_at is null
       order by o.created_at desc
       limit 1;
    exception when others then v_oid := null;
    end;
    if v_oid is not null then v_scope := 'order'; end if;
  end if;

  -- ── {activity}: the stage the zone (or their own order) is actually in ──
  if v_scope = 'order' then
    begin v_olabel := public._order_customer_stage(v_oid)->>'label';
    exception when others then v_olabel := null;
    end;
  end if;
  begin
    select s.stage_key into v_actkey
      from public._ops_order_stage(v_zone) s
     group by s.stage_key
     order by count(*) desc, min(s.since) asc
     limit 1;
  exception when others then v_actkey := null;
  end;
  v_act := coalesce(nullif(v_cfg->'activity'->>coalesce(v_actkey, 'idle'), ''),
                    nullif(v_cfg->'activity'->>'idle', ''),
                    nullif(v_fb->>'activity', ''), '');

  -- ── the three lines ──
  v_l1 := coalesce(nullif(v_st->>'l1', ''), v_fb->>'l1', '');
  v_l2 := coalesce(nullif(v_l2, ''), v_fb->>'l2', '');
  v_l3 := coalesce(nullif(v_st->>'l3', ''), v_fb->>'l3', '');
  if v_scope = 'universal' then
    v_l3 := coalesce(nullif(v_cfg->'cta'->>'universal', ''), v_l3);
  elsif v_scope = 'order' then
    -- A customer's own order stage is the long wording; on a narrow phone the
    -- zone's short activity word is what fits, so the narrow tier keeps it.
    if v_narrow then
      v_l3 := coalesce(nullif(v_act, ''), nullif(v_olabel, ''), v_l3);
    else
      v_l3 := coalesce(nullif(v_olabel, ''), v_l3);
    end if;
  end if;
  v_l3 := replace(v_l3, '{activity}', v_act);
  v_l3 := coalesce(nullif(btrim(v_l3), ''), v_fb->>'l3', '');
  v_l2 := replace(v_l2, '{activity}', v_act);

  -- ── style: the shared geometry, the state's tone, the state's overrides ──
  v_style := coalesce(v_cfg->'style', '{}'::jsonb)
          || coalesce(v_cfg->'tones'->(v_st->>'tone'), '{}'::jsonb)
          || coalesce((select jsonb_object_agg(e.k, e.v)
                         from jsonb_each(v_st) as e(k, v)
                        where e.k in ('height', 'radius', 'text')), '{}'::jsonb);

  -- Minute-precise wording, so ask again one second after the next minute.
  v_refresh := 61 - floor(extract(second from v_ts))::int;

  return jsonb_build_object(
    'show',   true,
    'state',  v_state,
    'scope',  v_scope,
    'zone_id', v_zone,
    -- The tier the words came from, so the app can be SEEN to be on the right
    -- one (render-log c2191_pill_tier) instead of it being inferred.
    'tier',   case when v_narrow then 'narrow' else 'full' end,
    'lines', jsonb_build_array(
      jsonb_build_object('kind', 'status', 'text', v_l1),
      jsonb_build_object('kind', 'time',   'text', v_l2),
      jsonb_build_object('kind', 'action', 'text', v_l3)),
    'hold_ms', coalesce((v_cfg->'roll'->>'hold_ms')::int, 3000),
    'roll_ms', coalesce((v_cfg->'roll'->>'roll_ms')::int, 400),
    'label',  concat_ws(coalesce(v_cfg->>'join', ' · '), nullif(v_l1,''), nullif(v_l2,''), nullif(v_l3,'')),
    'text',   concat_ws(coalesce(v_cfg->>'join', ' · '), nullif(v_l1,''), nullif(v_l2,''), nullif(v_l3,'')),
    'pulse',  coalesce((v_st->>'pulse')::boolean, false),
    'pulse_ms', coalesce((v_cfg->>'pulse_ms')::int, 1600),
    'style',  v_style,
    'refresh_s', v_refresh,
    'refresh_at', to_char(v_ts + make_interval(secs => v_refresh), 'HH24:MI:SS'));
end $function$;

-- ── 3. the reporter forwards the width to the author ─────────────────────
drop function if exists public.order_hours_state(smallint);

create or replace function public.order_hours_state(
  p_zone smallint default null,
  p_w    int      default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
    -- The pill (and only the pill) is re-taken from the ONE pill author, and
    -- now WITH the width this caller reported, so the copy this reporter
    -- quotes is the copy the author would have sent (lesson 388).
    || jsonb_build_object('pill',
         public.header_status_pill(v_zone, p_w) || jsonb_build_object('scope', v_zs->>'scope'));
end $function$;

grant execute on function public.header_status_pill(smallint, int) to anon, authenticated, service_role;
grant execute on function public.order_hours_state(smallint, int)  to anon, authenticated, service_role;

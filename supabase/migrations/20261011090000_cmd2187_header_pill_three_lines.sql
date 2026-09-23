-- CMD #2187 — the header pill speaks in THREE lines, and one thing moves.
--
-- #2175 gave the pill one label ("Open till 9:00 PM") and #2147's
-- _order_hours_pill() wrote it with a CLOCK in it. Om's design (23 Sep,
-- "Pill, three lines, every state") replaces both: the pill always carries
-- exactly three lines — STATUS, TIME (relative only, never a clock) and
-- ACTION — and rolls them one at a time.
--
-- Every line, colour, height, radius, text size, pulse, threshold and timing
-- is a key of app_settings['pill.copy']. Reword the pill, retime the roll or
-- move a state's boundary with an UPDATE; Flutter reads lines[] and style{}
-- and computes nothing.
--
-- Idempotent: one upsert and three create-or-replaces.

-- ─────────────────── 1. pill.copy — the whole pill, as data ──────────────────
insert into public.app_settings (key, value) values ('pill.copy', jsonb_build_object(
  -- The roll: each line holds, then travels. Flutter reads these, never a
  -- Duration of its own.
  'roll', jsonb_build_object('hold_ms', 3000, 'roll_ms', 400),

  -- The separator an old one-line client (and every screen reader) gets.
  'join', ' · ',

  -- The pill's geometry, shared by every state. A state may override height,
  -- radius or text — that is what lets the pill change colour AND size
  -- mid-cycle without a deploy.
  'style', jsonb_build_object(
    'height', 40, 'radius', 20, 'text', 14,
    'pad_x', 12, 'dot_size', 8, 'min_w', 120, 'max_w', 210),

  -- Muted state colours, the design system's own.
  'tones', jsonb_build_object(
    'success', jsonb_build_object('bg', '#D1FAE5', 'fg', '#065F46', 'dot', '#065F46'),
    'warning', jsonb_build_object('bg', '#FEF3C7', 'fg', '#92400E', 'dot', '#92400E'),
    'danger',  jsonb_build_object('bg', '#FEE2E2', 'fg', '#991B1B', 'dot', '#991B1B'),
    'info',    jsonb_build_object('bg', '#EFF6FF', 'fg', '#1E40AF', 'dot', '#1E40AF'),
    'neutral', jsonb_build_object('bg', '#F5F6F8', 'fg', '#6B7280', 'dot', '#6B7280')),

  -- Where one state ends and the next begins, in minutes.
  'windows', jsonb_build_object(
    'closing_now_min', 30, 'closing_soon_min', 120, 'opening_soon_min', 60),

  -- The seven states, each with its own three lines. {time} is the relative
  -- wording below; {activity} is what mediBO is doing for this zone right now.
  'states', jsonb_build_object(
    'open',         jsonb_build_object('l1','Open',  'l2','{time}','l3','Order now',
                                       'tone','success','pulse',true),
    'closing_soon', jsonb_build_object('l1','Open',  'l2','{time}','l3','Order fast',
                                       'tone','warning','pulse',true),
    'closing_now',  jsonb_build_object('l1','Open',  'l2','{time}','l3','Last chance',
                                       'tone','danger','pulse',true),
    'opening_soon', jsonb_build_object('l1','Closed','l2','{time}','l3','Get your list ready',
                                       'tone','info','pulse',true),
    'closed_later', jsonb_build_object('l1','Closed','l2','{time}','l3','{activity}',
                                       'tone','neutral','pulse',false),
    'closed',       jsonb_build_object('l1','Closed','l2','{time}','l3','{activity}',
                                       'tone','neutral','pulse',false),
    'closed_today', jsonb_build_object('l1','Closed','l2','{time}','l3','Browse and save',
                                       'tone','danger','pulse',false)),

  -- RELATIVE time only. There is no clock string anywhere in this block, and
  -- that is the point of the design.
  'time', jsonb_build_object(
    'minute_left',      '1 minute left',
    'minutes_left',     '{n} minutes left',
    'hour_left',        '1 hour left',
    'hours_left',       '{n} hours left',
    'open_no_close',    'Open all day',
    'opens_in_minute',  'Opens in 1 minute',
    'opens_in_minutes', 'Opens in {n} minutes',
    'opens_in_hour',    'Opens in 1 hour',
    'opens_in_hours',   'Opens in {n} hours',
    'tomorrow',         'Tomorrow'),

  -- Line 3 when the state asks for {activity}: the pipeline stage the zone is
  -- actually in, keyed by _ops_order_stage()'s own stage_key.
  'activity', jsonb_build_object(
    'idle',           'Taking orders',
    'accept',         'Accepting your orders',
    'inquiry',        'Asking suppliers',
    'supplier_order', 'Ordering to suppliers',
    'collect',        'Collecting items',
    'arrival',        'Receiving at warehouse',
    'count',          'Counting items',
    'bag',            'Packing your bag',
    'pack',           'Packing your bag',
    'dispatch',       'Ready to dispatch',
    'delivered',      'Out for delivery'),

  -- Scope: nobody who cannot order is told to order.
  'cta', jsonb_build_object('universal', 'Register to order'),

  'fallback', jsonb_build_object(
    'l1','Closed','l2','Tomorrow','l3','Browse and save','activity','Taking orders')
))
on conflict (key) do update set value = public.app_settings.value || excluded.value;

-- ──────────────── 2. shell.motion — one thing animates at a time ─────────────
-- Om: "the pill rolls every 3 s and the placeholder rotates every 5 s, 10 dp
-- apart — on two clocks they drift into each other and read as broken."
-- Whichever is on screen owns the motion. The POLICY is a row, not a rule in
-- Dart: `one_at_a_time=false` hands both their clocks back with no deploy.
insert into public.app_settings (key, value) values ('shell.motion', jsonb_build_object(
  'one_at_a_time', true,
  -- The header row's own travel. The placeholder may not start until the row
  -- is fully gone, so neither moves during the slide.
  'handover_ms', 200,
  'placeholder_rotate_when', 'header_hidden',
  'placeholder_rotate_ms', 5000
))
on conflict (key) do update set value = public.app_settings.value || excluded.value;

-- ───────────────────────── 3. header_status_pill() ───────────────────────────
create or replace function public.header_status_pill(p_zone smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_cfg    jsonb := coalesce((select value from public.app_settings where key = 'pill.copy'), '{}'::jsonb);
  v_time   jsonb := coalesce(v_cfg->'time', '{}'::jsonb);
  v_win    jsonb := coalesce(v_cfg->'windows', '{}'::jsonb);
  v_fb     jsonb := coalesce(v_cfg->'fallback', '{}'::jsonb);
  -- The VIEWER's own scope, never p_zone's. header_zone_scope(<a zone>) always
  -- answers 'zone', which is what made a signed-out visitor read as zoned.
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
  v_now := v_ts::time;

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
    v_l3 := coalesce(nullif(v_olabel, ''), v_l3);
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
    'lines', jsonb_build_array(
      jsonb_build_object('kind', 'status', 'text', v_l1),
      jsonb_build_object('kind', 'time',   'text', v_l2),
      jsonb_build_object('kind', 'action', 'text', v_l3)),
    'hold_ms', coalesce((v_cfg->'roll'->>'hold_ms')::int, 3000),
    'roll_ms', coalesce((v_cfg->'roll'->>'roll_ms')::int, 400),
    -- One line for an old client and for a screen reader: the same three,
    -- joined by the backend's own separator. Dart never concatenates.
    'label',  concat_ws(coalesce(v_cfg->>'join', ' · '), nullif(v_l1,''), nullif(v_l2,''), nullif(v_l3,'')),
    'text',   concat_ws(coalesce(v_cfg->>'join', ' · '), nullif(v_l1,''), nullif(v_l2,''), nullif(v_l3,'')),
    'pulse',  coalesce((v_st->>'pulse')::boolean, false),
    'pulse_ms', coalesce((v_cfg->>'pulse_ms')::int, 1600),
    'style',  v_style,
    'refresh_s', v_refresh,
    'refresh_at', to_char(v_ts + make_interval(secs => v_refresh), 'HH24:MI:SS'));
end $$;

-- ───────────────────── 4. shell_style() — the motion policy ──────────────────
create or replace function public.shell_style()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select value from public.app_settings where key = 'shell.style'), '{}'::jsonb)
      || jsonb_build_object('pill', public.header_status_pill(null))
      -- CMD #2187 — one thing animates at a time. The pill's own hold/roll are
      -- reported here too, so the shell reads ONE motion block.
      || jsonb_build_object('motion',
           coalesce((select value from public.app_settings where key = 'shell.motion'), '{}'::jsonb)
           || jsonb_build_object(
                'pill_hold_ms', coalesce(((select value from public.app_settings where key = 'pill.copy')
                                          ->'roll'->>'hold_ms')::int, 3000),
                'pill_roll_ms', coalesce(((select value from public.app_settings where key = 'pill.copy')
                                          ->'roll'->>'roll_ms')::int, 400)))
      || jsonb_build_object('search',
           coalesce((select jsonb_build_object(
                       'box_h',        value->'shell'->'box_h',
                       'pad_y',        value->'shell'->'pad_y',
                       'box_radius',   value->'shell'->'box_radius',
                       'text_align_v', value->'shell'->'text_align_v')
                       from public.dev_runner_config where key = 'ui_design'), '{}'::jsonb)
           -- CMD #2187 — WHEN the placeholder is allowed to rotate. The pill
           -- owns the motion while the header row is on screen.
           || jsonb_build_object(
                'placeholder_rotate_when',
                  coalesce((select value->>'placeholder_rotate_when' from public.app_settings
                             where key = 'shell.motion'), 'header_hidden'),
                'placeholder_rotate_ms',
                  coalesce((select (value->>'placeholder_rotate_ms')::int from public.app_settings
                             where key = 'shell.motion'), 5000))
           || jsonb_build_object(
           'tabs', jsonb_build_object(
             'home',      jsonb_build_object('scope', 'catalog',  'placeholder', public._c('shell.search_home')),
             'catalogue', jsonb_build_object('scope', 'catalog',  'placeholder', public._c('shell.search_catalogue')),
             'bulk',      jsonb_build_object('scope', 'catalog',  'placeholder', public._c('shell.search_bulk')),
             'orders',    jsonb_build_object('scope', 'orders',   'placeholder', public._c('shell.search_orders')),
             'profile',   jsonb_build_object('scope', 'profile',  'placeholder', public._c('shell.search_profile')))));
$$;

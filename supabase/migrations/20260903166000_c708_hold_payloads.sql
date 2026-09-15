-- CHANGE #708 (6/6a) — the payloads the three surfaces render.
--
-- The customer card, the ops board row and the timeline all learn about a hold
-- from the SAME block (order_hold_state), added to the payload each of them
-- already reads. Nothing is computed on the client, and the badge cannot
-- disagree with the freeze because both read one function.
-- Idempotent: each patch is applied from the live definition and skipped once
-- its hook is present.

-- ── 1. the customer's own card ────────────────────────────────────────────
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = '_order_customer_card';
  if v_def is not null and v_def not like '%order_hold_state%' then
    v_new := replace(v_def,
      '    ''situation'',       v_sit);',
      '    -- CHANGE #708 — the hold, from the one function every surface reads.'
      || chr(10) || '    ''hold'',            public.order_hold_state(p_order_id),'
      || chr(10) || '    ''hold_sheet'',      public.order_hold_sheet(p_order_id),'
      || chr(10) || '    ''situation'',       v_sit);');
    if v_new = v_def then raise exception 'c708: _order_customer_card anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 2. the ops board row: the chip, and the SLA credit ────────────────────
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'ops_board';
  if v_def is not null and v_def not like '%order_hold_paused_seconds%' then
    -- (a) the clock is paused by CREDIT: the seconds this order spent held
    --     inside the current stage never count against its SLA.
    v_new := replace(v_def,
      '           (j.sla_minutes * 60)::numeric                                  as sla_sec,
           extract(epoch from (now() - j.entered_at))::numeric            as elapsed_sec,
           (j.sla_minutes * 60)::numeric
             - extract(epoch from (now() - j.entered_at))::numeric        as left_sec',
      '           (j.sla_minutes * 60)::numeric                                  as sla_sec,
           -- CHANGE #708: minus the time it sat on hold in this stage.
           extract(epoch from (now() - j.entered_at))::numeric
             - public.order_hold_paused_seconds(j.order_id, j.entered_at)  as elapsed_sec,
           (j.sla_minutes * 60)::numeric
             - (extract(epoch from (now() - j.entered_at))::numeric
                - public.order_hold_paused_seconds(j.order_id, j.entered_at)) as left_sec');
    if v_new = v_def then raise exception 'c708: ops_board clock anchor missing'; end if;
    v_def := v_new;

    -- (b) the row says it is parked, in the backend's own words.
    v_new := replace(v_def,
      '      ''stage_key'',      t.stage_key,',
      '      ''stage_key'',      t.stage_key,
      ''hold'',           public.order_hold_state(t.order_id),');
    if v_new = v_def then raise exception 'c708: ops_board row anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 3. ops_order_detail: the hold, the sheet and the reserved stock ───────
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'ops_order_detail';
  if v_def is not null and v_def not like '%order_hold_sheet%' then
    v_new := regexp_replace(v_def,
      '(\s+)''ok'',\s*true,',
      E'\\1''ok'', true,'
      || E'\\1-- CHANGE #708 — hold, its sheet and the stock it is reserving.'
      || E'\\1''hold'', public.order_hold_state(p_order_id),'
      || E'\\1''hold_sheet'', public.order_hold_sheet(p_order_id),'
      || E'\\1''hold_stock'', public.order_hold_stock(p_order_id),', 'n');
    if v_new = v_def then raise exception 'c708: ops_order_detail anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 4. the timeline says when it was parked and when it came back ─────────
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = '_order_timeline_events';
  if v_def is not null and v_def not like '%order_hold%' then
    v_new := replace(v_def,
      '  -- ── 2. inquiry: asked / answered / advanced / nobody had it ───────────────',
      '  -- ── 1b. held / resumed (CHANGE #708) ─────────────────────────────────────
  for r in
    select h.held_at, h.resumed_at, h.status, h.reason_label, h.held_by_label,
           h.resume_note, greatest(coalesce(h.resumed_at, now())::date - h.held_at::date, 0) as days
      from public.order_hold h where h.order_id = p_order_id
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      ''ts'', r.held_at, ''stage'',''placed'', ''hint'',0, ''internal'',false,
      ''label'',  public._cf(''order_hold.timeline_held'',
                    jsonb_build_object(''reason'', r.reason_label)),
      ''detail'', coalesce(nullif(r.held_by_label,''''), ''''),
      ''tone'',''warning'',
      ''actor_kind'',''customer'', ''actor_name'', v_cust, ''actor_phone'', v_cust_phone,
      ''action_kind'',''call_customer'', ''action_args'',''{}''::jsonb));
    if r.resumed_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        ''ts'', r.resumed_at, ''stage'',''placed'', ''hint'',0, ''internal'',false,
        ''label'', case r.status when ''cancelled''
                     then public._cf(''order_hold.timeline_cancelled'',
                            jsonb_build_object(''n'', r.days::text))
                     else public._c(''order_hold.timeline_resumed'') end,
        ''detail'', coalesce(nullif(r.resume_note,''''), ''''),
        ''tone'', case r.status when ''cancelled'' then ''danger'' else ''success'' end,
        ''actor_kind'',''customer'', ''actor_name'', v_cust, ''actor_phone'', v_cust_phone,
        ''action_kind'',''call_customer'', ''action_args'',''{}''::jsonb));
    end if;
  end loop;

  -- ── 2. inquiry: asked / answered / advanced / nobody had it ───────────────');
    if v_new = v_def then raise exception 'c708: timeline anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 5. the dashboard count ────────────────────────────────────────────────
create or replace function public.order_hold_count(p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_role text := coalesce(public.get_my_role(),'none');
        v_partner bigint := public.my_partner_id();
        v_zone smallint; v_n int := 0;
begin
  if v_partner is not null then
    if coalesce(public.partner_access('partner.ops_board', v_partner),'none') = 'none' then
      return jsonb_build_object('allowed', false, 'count', 0, 'badge','', 'title','');
    end if;
    v_zone := public.partner_zone_id();
  elsif v_role in ('admin','super_admin') then
    v_zone := coalesce(p_zone, public.admin_active_zone());
  else
    return jsonb_build_object('allowed', false, 'count', 0, 'badge','', 'title','');
  end if;

  select count(*)::int into v_n
    from order_hold h
    join orders o on o.id = h.order_id
    left join pharmacy_profiles pp on pp.id = o.customer_id
   where h.status = 'active'
     and o.status <> 'cancelled' and o.closed_at is null
     and (v_zone is null or coalesce(o.zone_id, pp.zone_id) = v_zone);

  return jsonb_build_object(
    'allowed', true,
    'count', v_n,
    'title', _c('order_hold.dash_title'),
    'badge', case when v_n = 0 then ''
                  else _cf('order_hold.count_label', jsonb_build_object('n', v_n::text)) end,
    'tone', case when v_n = 0 then 'neutral' else 'warning' end,
    'route_key', 'ops_board');
end
$fn$;

revoke all on function public.order_hold_count(smallint) from public, anon, authenticated;
grant execute on function public.order_hold_count(smallint) to authenticated;

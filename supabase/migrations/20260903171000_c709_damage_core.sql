-- CHANGE #709 (2/6) — the two verbs and the one reader.
--
-- damage_log() is the worker's sentence about what happened; damage_confirm()
-- is the partner's decision, and it is the ONLY thing that moves a ledger.
-- damage_state(order) is what every surface reads — the pack list, the bill,
-- the customer's line note and the report all ask it rather than each carrying
-- their own idea of "damaged".
--
-- Who may log: the worker holding the fulfil task (#707's my_fulfil_worker_id),
-- a partner with partner.fulfil_tasks write, or an admin. Who may confirm:
-- a partner or an admin — never the worker who logged it.
-- Idempotent throughout.

-- ── how much of a line survives ───────────────────────────────────────────
create or replace function public.damage_qty_for_item(p_item uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(sum(d.qty), 0)::numeric
    from handling_damage d
   where d.order_item_id = p_item and d.status = 'confirmed';
$fn$;

comment on function public.damage_qty_for_item(uuid) is
  'CHANGE #709 — the confirmed damaged quantity on one order line. Everything '
  'that bills, packs or counts subtracts this; nothing rewrites the ordered qty.';

-- ── who is asking ─────────────────────────────────────────────────────────
create or replace function public._c709_actor(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_worker bigint := public.my_fulfil_worker_id();
  v_partner bigint := public.my_partner_id();
  v_zone smallint; v_ozone smallint; v_name text;
begin
  if v_role in ('admin','super_admin') then
    return jsonb_build_object('has', true, 'kind','admin', 'can_confirm', true,
      'label', coalesce(nullif(public.my_login_email(),''),'mediBO'));
  end if;

  select coalesce(o.zone_id, p.zone_id) into v_ozone
    from orders o left join pharmacy_profiles p on p.id = o.customer_id
   where o.id = p_order_id;

  if v_partner is not null then
    v_zone := public.partner_zone_id();
    if coalesce(public.partner_access('partner.fulfil_tasks', v_partner),'none') <> 'none'
       and (v_zone is null or v_zone = v_ozone) then
      return jsonb_build_object('has', true, 'kind','partner', 'can_confirm', true,
        'label', 'partner:'||v_partner::text);
    end if;
    return jsonb_build_object('has', false, 'can_confirm', false, 'reason','not_yours');
  end if;

  if v_worker is not null then
    select coalesce(nullif(btrim(w.full_name),''), 'worker') into v_name
      from fulfil_worker w where w.id = v_worker;
    return jsonb_build_object('has', true, 'kind','worker', 'can_confirm', false,
      'worker_id', v_worker, 'label', coalesce(v_name,'worker'));
  end if;

  return jsonb_build_object('has', false, 'can_confirm', false, 'reason','not_yours');
end
$fn$;

-- ── the one reader ────────────────────────────────────────────────────────
create or replace function public.damage_state(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_rows jsonb; v_conf numeric := 0; v_pend int := 0; v_n int := 0;
  v_unit text := _c('damage.unit_default');
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'order_item_id', d.order_item_id,
           'product_name', coalesce(d.product_name,''),
           'supplier', coalesce(d.supplier_name,''),
           'stage_key', d.stage_key,
           'stage_label', coalesce(st.label, d.stage_key),
           'stage_line', _cf('damage.stage_label',
                           jsonb_build_object('stage', coalesce(st.label, d.stage_key))),
           'qty', d.qty,
           'reason_code', d.reason_code,
           'reason', d.reason_label,
           'note', coalesce(d.note,''),
           'bucket', d.bucket,
           'bucket_label', coalesce(d.bucket_label, _c('damage.bucket.'||d.bucket)),
           'status', d.status,
           'status_label', case d.status
                             when 'pending'   then _c('damage.pending_label')
                             when 'confirmed' then _c('damage.confirmed_label')
                             when 'rejected'  then _c('damage.rejected_label')
                             else _c('damage.none_label') end,
           'status_tone', case d.status when 'confirmed' then 'success'
                                        when 'rejected' then 'danger' else 'warning' end,
           'worker_label', coalesce(d.worker_label,''),
           'photo_bucket', coalesce(d.photo_bucket,''),
           'photo_path', coalesce(d.photo_path,''),
           'has_photo', (nullif(btrim(coalesce(d.photo_path,'')),'') is not null),
           'logged_at', d.logged_at,
           'line_note', _cf('damage.line_note', jsonb_build_object(
                          'qty', rtrim(rtrim(to_char(d.qty,'FM999999990.99'),'0'),'.'),
                          'unit', v_unit))
         ) order by d.logged_at desc), '[]'::jsonb)
    into v_rows
    from handling_damage d
    left join handling_damage_stage st on st.stage_key = d.stage_key
   where d.order_id = p_order_id and d.status in ('pending','confirmed');

  select coalesce(sum(qty) filter (where status='confirmed'), 0),
         count(*) filter (where status='pending')::int,
         count(*)::int
    into v_conf, v_pend, v_n
    from handling_damage where order_id = p_order_id and status in ('pending','confirmed');

  return jsonb_build_object(
    'has', (v_n > 0),
    'confirmed_qty', v_conf,
    'pending_count', v_pend,
    'count', v_n,
    'count_label', _cf('damage.count_label', jsonb_build_object('n', v_n::text)),
    'order_note', case when v_conf > 0
                       then _cf('damage.line_note', jsonb_build_object(
                              'qty', rtrim(rtrim(to_char(v_conf,'FM999999990.99'),'0'),'.'),
                              'unit', v_unit))
                       else '' end,
    'rows', v_rows);
end
$fn$;

-- ── the sheet a worker sees on one line ──────────────────────────────────
create or replace function public.damage_sheet(p_order_item_id uuid, p_stage text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  oi order_items%rowtype; v_act jsonb; v_cfg jsonb;
  v_stage text; v_allow boolean; v_left numeric;
begin
  select * into oi from order_items where id = p_order_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_item',
      'title', _c('damage.title'), 'message', _c('damage.err_no_item'));
  end if;
  v_act := public._c709_actor(oi.order_id);
  if not coalesce((v_act->>'has')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', _c('damage.title'), 'message', _c('damage.err_not_authorized'));
  end if;
  v_cfg := coalesce((select value from app_settings where key='handling_damage'),'{}'::jsonb);
  v_stage := lower(btrim(coalesce(nullif(p_stage,''), 'count')));
  select coalesce(allow,false) into v_allow from handling_damage_stage where stage_key = v_stage;
  v_left := greatest(coalesce(oi.quantity,0) - public.damage_qty_for_item(oi.id), 0);

  return jsonb_build_object(
    'ok', true,
    'order_id', oi.order_id,
    'order_item_id', oi.id,
    'product_name', coalesce(oi.product_name,''),
    'supplier', coalesce(oi.assigned_supplier,''),
    'ordered_qty', coalesce(oi.quantity,0),
    'remaining_qty', v_left,
    'title', _c('damage.title'),
    'subtitle', _c('damage.subtitle'),
    'qty_label', _c('damage.qty_label'),
    'reason_label', _c('damage.reason_label'),
    'note_label', _c('damage.note_label'),
    'note_hint', _c('damage.note_hint'),
    'photo_label', _c('damage.photo_label'),
    'photo_hint', _c('damage.photo_hint'),
    'submit_label', _c('damage.submit'),
    'bucket', 'damage-photos',
    'upload_prefix', 'order/'||oi.order_id::text,
    'stage_key', v_stage,
    'can_log', (coalesce((v_cfg->>'enabled')::boolean, true) and coalesce(v_allow,false)
                and v_left > 0),
    'message', case
      when not coalesce((v_cfg->>'enabled')::boolean, true) then _c('damage.err_disabled')
      when not coalesce(v_allow,false) then _c('damage.err_stage')
      when v_left <= 0 then _cf('damage.err_qty_over', jsonb_build_object('n','0'))
      else '' end,
    'actor_kind', v_act->>'kind',
    'can_confirm', coalesce((v_act->>'can_confirm')::boolean,false),
    'stages', coalesce((select jsonb_agg(jsonb_build_object(
                          'key', s.stage_key, 'label', coalesce(s.label, s.stage_key))
                          order by s.sort_order)
                          from handling_damage_stage s where s.allow), '[]'::jsonb),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object(
                           'code', r.code, 'label', r.label,
                           'needs_photo', r.needs_photo)
                           order by r.sort_order)
                           from handling_damage_reason r where r.is_active), '[]'::jsonb),
    'state', public.damage_state(oi.order_id));
end
$fn$;

-- ── LOG ───────────────────────────────────────────────────────────────────
create or replace function public.damage_log(
  p_order_item_id uuid, p_qty numeric, p_reason_code text,
  p_stage text default 'count', p_note text default null,
  p_photo_path text default null, p_task_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  oi order_items%rowtype; r handling_damage_reason%rowtype;
  v_act jsonb; v_cfg jsonb; v_sheet jsonb;
  v_stage text := lower(btrim(coalesce(nullif(p_stage,''),'count')));
  v_left numeric; v_zone smallint; v_id bigint; v_bucket text; v_photo text;
begin
  v_sheet := public.damage_sheet(p_order_item_id, v_stage);
  if not coalesce((v_sheet->>'ok')::boolean,false) then return v_sheet; end if;
  if not coalesce((v_sheet->>'can_log')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_allowed', 'tone','danger',
      'message', v_sheet->>'message');
  end if;

  select * into oi from order_items where id = p_order_item_id;
  v_act := public._c709_actor(oi.order_id);
  v_cfg := coalesce((select value from app_settings where key='handling_damage'),'{}'::jsonb);

  select * into r from handling_damage_reason
   where code = lower(btrim(coalesce(p_reason_code,''))) and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'error','bad_reason', 'tone','danger',
      'message', _c('damage.err_reason'));
  end if;
  if coalesce(p_qty,0) <= 0 then
    return jsonb_build_object('ok', false, 'error','bad_qty', 'tone','danger',
      'message', _c('damage.err_qty'));
  end if;
  v_left := (v_sheet->>'remaining_qty')::numeric;
  if p_qty > v_left then
    return jsonb_build_object('ok', false, 'error','qty_over', 'tone','danger',
      'message', _cf('damage.err_qty_over',
                   jsonb_build_object('n', rtrim(rtrim(to_char(v_left,'FM999999990.99'),'0'),'.'))));
  end if;
  v_photo := nullif(btrim(coalesce(p_photo_path,'')),'');
  if r.needs_photo and v_photo is null then
    return jsonb_build_object('ok', false, 'error','need_photo', 'tone','danger',
      'message', _c('damage.err_photo'));
  end if;

  select coalesce(o.zone_id, p.zone_id) into v_zone
    from orders o left join pharmacy_profiles p on p.id = o.customer_id
   where o.id = oi.order_id;

  -- Who carries it: the zone's own answer if it has one, else the reason's.
  v_bucket := coalesce(nullif(v_cfg->'zone_bucket'->>coalesce(v_zone::text,'-'),''),
                       r.default_bucket);

  insert into handling_damage (order_id, order_item_id, product_id, product_name,
      supplier_name, stage_key, qty, reason_code, reason_label, note, bucket,
      bucket_label, photo_bucket, photo_path, worker_id, worker_label, task_id,
      zone_id, logged_by, status)
  values (oi.order_id, oi.id, oi.product_id, coalesce(oi.product_name,''),
      nullif(btrim(coalesce(oi.assigned_supplier,'')),''), v_stage, p_qty, r.code, r.label,
      nullif(btrim(coalesce(p_note,'')),''), v_bucket, _c('damage.bucket.'||v_bucket),
      case when v_photo is null then null else 'damage-photos' end, v_photo,
      nullif(v_act->>'worker_id','')::bigint, v_act->>'label', p_task_id,
      v_zone, auth.uid(),
      case when coalesce((v_cfg->>'confirm_required')::boolean, true)
                and coalesce(v_act->>'kind','') = 'worker'
           then 'pending' else 'confirmed' end)
  returning id into v_id;

  -- A partner or an admin logging it IS the confirmation, so the ledger moves
  -- in the same call rather than waiting for a second person who is already here.
  if (select status from handling_damage where id = v_id) = 'confirmed' then
    perform public.damage_apply(v_id);
  end if;

  return jsonb_build_object('ok', true, 'tone','success', 'damage_id', v_id,
    'message', case when (select status from handling_damage where id = v_id) = 'pending'
                    then _c('damage.logged_toast')
                    else _cf('damage.confirmed_toast', jsonb_build_object(
                           'qty', rtrim(rtrim(to_char(p_qty,'FM999999990.99'),'0'),'.'))) end,
    'state', public.damage_state(oi.order_id),
    'sheet', public.damage_sheet(p_order_item_id, v_stage));
end
$fn$;

-- ── CONFIRM / REJECT ─────────────────────────────────────────────────────
create or replace function public.damage_confirm(
  p_damage_id bigint, p_confirm boolean default true, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare d handling_damage%rowtype; v_act jsonb;
begin
  select * into d from handling_damage where id = p_damage_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_row', 'tone','danger',
      'message', _c('damage.err_no_item'));
  end if;
  v_act := public._c709_actor(d.order_id);
  if not coalesce((v_act->>'can_confirm')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('damage.err_confirm_auth'));
  end if;
  if d.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error','done', 'tone','danger',
      'message', _c('damage.err_done'), 'state', public.damage_state(d.order_id));
  end if;

  if coalesce(p_confirm, true) then
    update handling_damage
       set status='confirmed', confirmed_by=auth.uid(), confirmed_at=now(), updated_at=now()
     where id = d.id;
    perform public.damage_apply(d.id);
  else
    update handling_damage
       set status='rejected', confirmed_by=auth.uid(), confirmed_at=now(),
           reject_reason = nullif(btrim(coalesce(p_reason,'')),''), updated_at=now()
     where id = d.id;
  end if;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', case when coalesce(p_confirm,true)
                    then _cf('damage.confirmed_toast', jsonb_build_object(
                           'qty', rtrim(rtrim(to_char(d.qty,'FM999999990.99'),'0'),'.')))
                    else _c('damage.rejected_toast') end,
    'state', public.damage_state(d.order_id));
end
$fn$;

revoke all on function public._c709_actor(uuid) from public, anon, authenticated;
revoke all on function public.damage_qty_for_item(uuid) from public, anon, authenticated;
revoke all on function public.damage_state(uuid) from public, anon, authenticated;
revoke all on function public.damage_sheet(uuid,text) from public, anon, authenticated;
revoke all on function public.damage_log(uuid,numeric,text,text,text,text,bigint)
  from public, anon, authenticated;
revoke all on function public.damage_confirm(bigint,boolean,text) from public, anon, authenticated;

grant execute on function public.damage_state(uuid) to authenticated;
grant execute on function public.damage_sheet(uuid,text) to authenticated;
grant execute on function public.damage_log(uuid,numeric,text,text,text,text,bigint) to authenticated;
grant execute on function public.damage_confirm(bigint,boolean,text) to authenticated;

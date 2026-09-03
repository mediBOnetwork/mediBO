-- CHANGE #708 (2/6) — the two verbs, and the one place that decides.
--
-- order_hold() and order_resume() are the only writers. Everything else asks
-- order_hold_state() — the single answer to "is this order parked, and what do
-- I print?" — so the badge on the customer's card, the chip on the ops board,
-- the freeze in the waterfall and the SLA credit can never disagree.
--
-- The SLA clocks (#688) are paused by CREDIT, not by a second clock:
-- order_hold_paused_seconds(order, since) is the time this order spent held
-- inside a window, and ops_board subtracts it from elapsed. A paused clock that
-- is stored twice is a clock that drifts.
-- Idempotent throughout.

-- ── who is asking, and may they ────────────────────────────────────────────
create or replace function public._c708_actor(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_zone smallint; v_ozone smallint;
begin
  if v_role in ('admin','super_admin') then
    return jsonb_build_object('has', true, 'kind','staff',
      'label', _c('order_hold.held_by_staff'),
      'who', coalesce(nullif(public.my_login_email(),''), 'admin'));
  end if;

  if v_partner is not null then
    select coalesce(o.zone_id, p.zone_id) into v_ozone
      from orders o left join pharmacy_profiles p on p.id = o.customer_id
     where o.id = p_order_id;
    v_zone := public.partner_zone_id();
    if coalesce(public.partner_access('partner.ops_board', v_partner),'none') <> 'none'
       and (v_zone is null or v_zone = v_ozone) then
      return jsonb_build_object('has', true, 'kind','staff',
        'label', _c('order_hold.held_by_staff'), 'who', 'partner:'||v_partner::text);
    end if;
    return jsonb_build_object('has', false, 'reason','not_yours');
  end if;

  if exists (select 1 from orders o join pharmacy_profiles p on p.id = o.customer_id
              where o.id = p_order_id and p.user_id = auth.uid()) then
    return jsonb_build_object('has', true, 'kind','customer',
      'label', _c('order_hold.held_by_customer'), 'who', auth.uid()::text);
  end if;

  return jsonb_build_object('has', false, 'reason','not_yours');
end
$fn$;

-- ── the stage this order is at ─────────────────────────────────────────────
create or replace function public._c708_stage(p_order_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_stage text; v_zone smallint;
begin
  -- order_stage_history is the board's own live row; it is the cheap answer.
  select h.stage_key into v_stage
    from order_stage_history h
   where h.order_id = p_order_id and h.left_at is null
   order by h.entered_at desc limit 1;
  if v_stage is not null then return v_stage; end if;

  -- No history row yet (an order placed before #688, or mid-transition): ask
  -- the same resolver the board asks, scoped to this order's own zone.
  select coalesce(o.zone_id, p.zone_id) into v_zone
    from orders o left join pharmacy_profiles p on p.id = o.customer_id
   where o.id = p_order_id;
  select s.stage_key into v_stage
    from public._ops_order_stage(v_zone) s where s.order_id = p_order_id limit 1;
  return v_stage;
end
$fn$;

-- ── the one answer every surface reads ─────────────────────────────────────
create or replace function public.order_hold_state(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  h order_hold%rowtype;
  v_days int;
begin
  select * into h from order_hold
   where order_id = p_order_id and status = 'active' limit 1;
  if not found then
    return jsonb_build_object('held', false, 'badge','', 'reason_code','', 'reason','',
                              'held_at', null, 'resume_on', null);
  end if;
  v_days := greatest((now() at time zone 'Asia/Kolkata')::date - h.held_at::date, 0);
  return jsonb_build_object(
    'held',        true,
    'hold_id',     h.id,
    'reason_code', h.reason_code,
    'reason',      h.reason_label,
    'note',        coalesce(h.note,''),
    'stage_key',   coalesce(h.stage_key,''),
    'held_at',     h.held_at,
    'held_by_kind',h.held_by_kind,
    'held_by_label', coalesce(h.held_by_label,''),
    'held_label',  _cf('order_hold.badge_reason', jsonb_build_object('reason', h.reason_label)),
    'badge',       case when h.resume_on is null
                        then _cf('order_hold.badge_reason', jsonb_build_object('reason', h.reason_label))
                        else _cf('order_hold.badge_until',
                               jsonb_build_object('d', to_char(h.resume_on,'FMDD Mon'))) end,
    'badge_tone',  'warning',
    'resume_on',   h.resume_on,
    'resume_label',case when h.resume_on is null then _c('order_hold.no_date_label')
                        else _cf('order_hold.badge_until',
                               jsonb_build_object('d', to_char(h.resume_on,'FMDD Mon YYYY'))) end,
    'auto_cancel_on', h.auto_cancel_on,
    'auto_cancel_note', case when h.auto_cancel_on is null then ''
                             else _cf('order_hold.auto_cancel_note',
                                    jsonb_build_object('d', to_char(h.auto_cancel_on,'FMDD Mon YYYY'))) end,
    'days_held',   v_days,
    'billing_note', _c('order_hold.no_billing_note'));
end
$fn$;

-- ── the SLA credit ────────────────────────────────────────────────────────
create or replace function public.order_hold_paused_seconds(
  p_order_id uuid, p_since timestamptz default null)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $fn$
  -- Every hold that overlaps [since, now): the seconds inside the window. An
  -- ACTIVE hold is credited up to now, which is what freezes the clock while
  -- the order sits parked.
  select coalesce(sum(
           greatest(0, extract(epoch from (
             least(coalesce(h.resumed_at, now()), now())
             - greatest(h.held_at, coalesce(p_since, h.held_at))))))::numeric, 0)
    from order_hold h
   where h.order_id = p_order_id
     and coalesce(h.resumed_at, now()) > coalesce(p_since, h.held_at);
$fn$;

-- ── the sheet: chips, copy, and whether this order may be held at all ─────
create or replace function public.order_hold_sheet(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_act jsonb := public._c708_actor(p_order_id);
  v_cfg jsonb := coalesce((select value from app_settings where key='order_hold'),'{}'::jsonb);
  o orders%rowtype;
  v_stage text; v_allow boolean; v_stage_label text;
  v_state jsonb; v_chips jsonb; v_kind text;
  v_can boolean := false; v_err text := ''; v_msg text := '';
  v_max int := coalesce((v_cfg->>'max_resume_days')::int, 60);
begin
  select * into o from orders where id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'title', _c('order_hold.title'), 'message', _c('order_hold.err_not_found'));
  end if;
  if not coalesce((v_act->>'has')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_yours',
      'title', _c('order_hold.title'), 'message', _c('order_hold.err_not_yours'));
  end if;
  v_kind := v_act->>'kind';

  v_state := public.order_hold_state(p_order_id);
  v_stage := public._c708_stage(p_order_id);
  select coalesce(s.allow,false), coalesce(st.label, v_stage)
    into v_allow, v_stage_label
    from order_hold_stage s
    left join sla_stage st on st.stage_key = s.stage_key
   where s.stage_key = v_stage;

  if not coalesce((v_cfg->>'enabled')::boolean, true) then
    v_err := 'disabled'; v_msg := _c('order_hold.err_disabled');
  elsif o.status = 'cancelled' or o.closed_at is not null then
    v_err := 'closed'; v_msg := _c('order_hold.err_closed');
  elsif coalesce((v_state->>'held')::boolean,false) then
    v_err := 'already'; v_msg := _c('order_hold.err_already');
  elsif v_stage is null or not coalesce(v_allow,false) then
    v_err := 'stage';
    v_msg := _cf('order_hold.err_stage',
               jsonb_build_object('stage', coalesce(nullif(v_stage_label,''), coalesce(v_stage,'—'))));
  else
    v_can := true;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', r.code, 'label', r.label, 'needs_note', r.needs_note)
           order by r.sort_order, r.code), '[]'::jsonb)
    into v_chips
    from order_hold_reason r
   where r.is_active and (r.audience = 'both' or r.audience = case v_kind when 'customer' then 'customer' else 'staff' end);

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_code', coalesce(o.order_code,''),
    'actor_kind', v_kind,
    'title', _c('order_hold.title'),
    'subtitle', _c('order_hold.subtitle'),
    'reason_label', _c('order_hold.reason_label'),
    'note_label', _c('order_hold.note_label'),
    'note_hint', _c('order_hold.note_hint'),
    'note_max', coalesce((v_cfg->>'note_max')::int, 240),
    'resume_label', _c('order_hold.resume_label'),
    'resume_hint', _c('order_hold.resume_hint'),
    'submit_label', _c('order_hold.submit'),
    'resume_submit_label', _c('order_hold.resume_submit'),
    'billing_note', _c('order_hold.no_billing_note'),
    'max_resume_days', v_max,
    'stage_key', coalesce(v_stage,''),
    'stage_label', coalesce(v_stage_label,''),
    'can_hold', v_can,
    'can_resume', coalesce((v_state->>'held')::boolean,false),
    'blocked_reason', v_err,
    'message', v_msg,
    'reasons', v_chips,
    'state', v_state);
end
$fn$;

-- ── HOLD ──────────────────────────────────────────────────────────────────
create or replace function public.order_hold(
  p_order_id uuid, p_reason_code text, p_note text default null,
  p_resume_on date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_sheet jsonb := public.order_hold_sheet(p_order_id);
  v_cfg jsonb := coalesce((select value from app_settings where key='order_hold'),'{}'::jsonb);
  r order_hold_reason%rowtype;
  v_act jsonb := public._c708_actor(p_order_id);
  v_code text := lower(btrim(coalesce(p_reason_code,'')));
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_max int := coalesce((v_cfg->>'max_resume_days')::int, 60);
  v_cancel_days int := coalesce((v_cfg->>'auto_cancel_days')::int, 14);
  v_id bigint; v_phone text; v_cust uuid;
begin
  if not coalesce((v_sheet->>'ok')::boolean,false) then return v_sheet; end if;
  if not coalesce((v_sheet->>'can_hold')::boolean,false) then
    return jsonb_build_object('ok', false, 'error', v_sheet->>'blocked_reason',
      'tone','danger', 'message', v_sheet->>'message', 'state', v_sheet->'state');
  end if;

  select * into r from order_hold_reason where code = v_code and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'error','bad_reason', 'tone','danger',
      'message', _c('order_hold.err_reason'));
  end if;
  if r.needs_note and v_note is null then
    return jsonb_build_object('ok', false, 'error','need_note', 'tone','danger',
      'message', _c('order_hold.err_note'));
  end if;
  if p_resume_on is not null and p_resume_on < v_today then
    return jsonb_build_object('ok', false, 'error','resume_past', 'tone','danger',
      'message', _c('order_hold.err_resume_past'));
  end if;
  if p_resume_on is not null and p_resume_on > v_today + v_max then
    return jsonb_build_object('ok', false, 'error','resume_far', 'tone','danger',
      'message', _cf('order_hold.err_resume_far', jsonb_build_object('n', v_max::text)));
  end if;

  insert into order_hold (order_id, stage_key, reason_code, reason_label, note,
                          resume_on, auto_cancel_on, held_by_kind, held_by,
                          held_by_label)
  values (p_order_id, nullif(v_sheet->>'stage_key',''), r.code, r.label, v_note,
          p_resume_on, v_today + v_cancel_days, v_act->>'kind', auth.uid(),
          v_act->>'label')
  returning id into v_id;

  -- The customer is told, and a staff hold is told louder — but a missing
  -- notification route must never stop an order being parked.
  begin
    select o.customer_id, coalesce(nullif(pp.whatsapp_no,''), nullif(pp.phone,''), o.phone)
      into v_cust, v_phone
      from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = p_order_id;
    perform public.wa_send_event('order_held', v_cust,
      jsonb_build_object('code', coalesce(v_sheet->>'order_code',''),
                         'reason', r.label,
                         'd', coalesce(to_char(p_resume_on,'DD/MM/YYYY'),''),
                         'link','https://medibo.in/'),
      v_phone, p_order_id);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'tone','warning', 'hold_id', v_id,
    'message', _c('order_hold.held_toast'),
    'state', public.order_hold_state(p_order_id),
    'sheet', public.order_hold_sheet(p_order_id));
end
$fn$;

-- ── RESUME ────────────────────────────────────────────────────────────────
create or replace function public.order_resume(
  p_order_id uuid, p_note text default null, p_kind text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  h order_hold%rowtype;
  v_act jsonb;
  v_kind text := nullif(btrim(coalesce(p_kind,'')),'');
  v_reranked int := 0; v_cust uuid; v_phone text; v_code text;
begin
  select * into h from order_hold where order_id = p_order_id and status='active' limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_held', 'tone','danger',
      'message', _c('order_hold.err_not_held'),
      'state', public.order_hold_state(p_order_id));
  end if;

  if v_kind = 'system' then
    v_act := jsonb_build_object('has', true, 'kind','system',
                                'label', _c('order_hold.held_by_system'));
  else
    v_act := public._c708_actor(p_order_id);
    if not coalesce((v_act->>'has')::boolean,false) then
      return jsonb_build_object('ok', false, 'error','not_yours', 'tone','danger',
        'message', _c('order_hold.err_not_yours'));
    end if;
  end if;

  update order_hold
     set status = 'resumed',
         resumed_at = now(),
         resumed_by = auth.uid(),
         resumed_kind = v_act->>'kind',
         resume_note = nullif(btrim(coalesce(p_note,'')),''),
         held_seconds = greatest(0, extract(epoch from (now() - held_at)))::bigint
   where id = h.id;

  -- The waterfall may have moved on while this order was parked: a supplier
  -- that has since gone dark, or a new standby that now outranks the one we
  -- were waiting on. Re-ranking is the engine's own job — ask it, do not
  -- reimplement it here.
  begin
    v_reranked := coalesce((public.start_inquiry_for_suppliers(null, false)->>'asked')::int, 0);
  exception when others then v_reranked := 0;
  end;

  begin
    select o.order_code, o.customer_id,
           coalesce(nullif(pp.whatsapp_no,''), nullif(pp.phone,''), o.phone)
      into v_code, v_cust, v_phone
      from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = p_order_id;
    perform public.wa_send_event('order_resumed', v_cust,
      jsonb_build_object('code', coalesce(v_code,''), 'link','https://medibo.in/'),
      v_phone, p_order_id);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', _c('order_hold.resumed_toast'),
    'reranked', v_reranked,
    'state', public.order_hold_state(p_order_id),
    'sheet', public.order_hold_sheet(p_order_id));
end
$fn$;

-- Grants: engine internals stay unreachable (the #705 lesson — a grant is not a
-- guard, and Postgres hands EXECUTE to PUBLIC by default).
revoke all on function public._c708_actor(uuid) from public, anon, authenticated;
revoke all on function public._c708_stage(uuid) from public, anon, authenticated;
revoke all on function public.order_hold_paused_seconds(uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function public.order_hold_state(uuid) from public, anon, authenticated;
revoke all on function public.order_hold_sheet(uuid) from public, anon, authenticated;
revoke all on function public.order_hold(uuid,text,text,date) from public, anon, authenticated;
revoke all on function public.order_resume(uuid,text,text) from public, anon, authenticated;

grant execute on function public.order_hold_state(uuid) to authenticated;
grant execute on function public.order_hold_sheet(uuid) to authenticated;
grant execute on function public.order_hold(uuid,text,text,date) to authenticated;
grant execute on function public.order_resume(uuid,text,text) to authenticated;

insert into public.wa_event_routes (event_key, label, description, audience, enabled,
                                    push_enabled, push_title, push_body)
values
  ('order_held', 'Order held',
   'Sent when an order is parked — by the pharmacy itself or by mediBO.',
   'customer', true, true, 'Order on hold',
   'Order {{code}} is on hold ({{reason}}). Nothing moves until you resume it.'),
  ('order_resumed', 'Order resumed',
   'Sent when a held order starts moving again.',
   'customer', true, true, 'Order resumed',
   'Order {{code}} is moving again. Track it at {{link}}'),
  ('order_hold_reminder', 'Hold ending tomorrow',
   'Sent the day before a held order is due to resume.',
   'customer', true, true, 'Order resumes tomorrow',
   'Order {{code}} comes off hold on {{d}}. Tell us if you need longer.'),
  ('order_hold_cancelled', 'Held order cancelled',
   'Sent when an order is cancelled after sitting on hold past the limit.',
   'customer', true, true, 'Order cancelled',
   'Order {{code}} was cancelled after {{n}} days on hold.')
on conflict (event_key) do nothing;

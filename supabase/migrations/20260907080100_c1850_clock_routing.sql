-- replay-target: production
-- CMD #1850 — ROUTING. Everything that today asks "what time is it?" in order
-- to DECIDE something now asks public.now_eff().
--
-- Read this file as two halves.
--
-- READS (the first half) are safe by construction: now_eff() is now() for
-- every request that does not carry a live pinned session's token, so every
-- one of these functions returns exactly what it returned yesterday for every
-- real customer, every supplier, every cron job and every anonymous visitor.
--
-- WRITES (the second half) are guarded, because "the clock is only yours" has
-- to survive a tick that CANCELS ORDERS. order_cutoff_tick keeps working on
-- the effective clock but, while a clock is pinned, scopes itself to that
-- session's own orders. The other three write global rows or notify real
-- people, so under a pinned clock they refuse to run at all and say so.
--
-- One deliberate exception: test_session_expire_sweep and test_session_mine()
-- keep reading now(). A session must never be able to postpone its own expiry.

begin;

-- The order-hours question, asked once. On the real clock this is the stored
-- flag order_hours_tick maintains — the same value, the same table, unchanged.
-- Under a pinned clock it is what that flag WOULD say at the effective time,
-- computed and never written, so closing time is testable at 2pm.
create or replace function public.order_hours_open_eff(p_zone smallint)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
declare h public.order_hours%rowtype; v_now time;
begin
  select * into h from public.order_hours where zone_id = p_zone;
  if h.id is null then select * into h from public.order_hours order by id limit 1; end if;
  if h.id is null then return true; end if;
  if public.test_clock_session() is null then return coalesce(h.is_open, true); end if;
  if h.auto_open_time is null or h.auto_close_time is null then
    return coalesce(h.is_open, true);
  end if;
  v_now := (public.now_eff() at time zone 'Asia/Kolkata')::time;
  if h.auto_open_time <= h.auto_close_time then
    return v_now >= h.auto_open_time and v_now < h.auto_close_time;
  end if;
  -- A window that wraps past midnight.
  return v_now >= h.auto_open_time or v_now < h.auto_close_time;
exception when others then
  return coalesce(h.is_open, true);
end $$;

revoke all on function public.order_hours_open_eff(smallint) from public;
grant execute on function public.order_hours_open_eff(smallint) to anon, authenticated, service_role;

-- -------------------------------------------------------------------------
-- ORDER HOURS — the state the storefront prints
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_hours_state(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'updated_at', h.updated_at);
END; $function$;


-- -------------------------------------------------------------------------
-- ORDER HOURS — the gate on the order itself
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_orders_order_hours_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE h order_hours%ROWTYPE; v_zone smallint;
BEGIN
  IF COALESCE(NEW.placed_by_admin,false) THEN RETURN NEW; END IF;
  v_zone := COALESCE(NEW.zone_id,
                     (SELECT pp.zone_id FROM pharmacy_profiles pp WHERE pp.id = NEW.customer_id),
                     (SELECT id FROM zones WHERE is_default LIMIT 1));
  SELECT * INTO h FROM order_hours WHERE zone_id = v_zone;
  IF NOT FOUND THEN SELECT * INTO h FROM order_hours ORDER BY id LIMIT 1; END IF;
  -- CMD #1850 — the gate asks the SAME question the storefront printed.
  IF FOUND AND public.order_hours_open_eff(v_zone) IS FALSE THEN
    RAISE EXCEPTION 'order_hours_closed' USING HINT = h.closed_message;
  END IF;
  RETURN NEW;
END; $function$;


-- -------------------------------------------------------------------------
-- THE RESTORATION WINDOW
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_cutoff_window_open(p_zone smallint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1 from public.order_cutoff_run r
     where (p_zone is null or r.zone_id = p_zone)
       and r.state = 'cancelled'
       and r.restore_until is not null
       and public.now_eff() < r.restore_until);
$function$;


-- -------------------------------------------------------------------------
-- THE CUT-OFF CONSOLE ROW — every countdown it prints
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._order_cutoff_row(r order_cutoff_run)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  o public.orders%rowtype; cfg public.order_alert_config;
  v_eff timestamptz; v_adv jsonb; v_name text; v_secs bigint; v_left text;
  v_win boolean; v_wsecs bigint;
begin
  select * into o from public.orders where id = r.order_id;
  if o.id is null then return null; end if;
  cfg := public._oa_cfg();
  v_eff := public._order_cutoff_effective(r.cutoff_at, r.extra_min);
  v_adv := public._order_advance_state(r.order_id);
  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''), '')
    into v_name from public.pharmacy_profiles pp where pp.id = o.customer_id;

  v_secs := greatest(extract(epoch from (v_eff - public.now_eff()))::bigint, 0);
  v_left := case when r.state in ('watching','warned')
                 then case when v_eff <= public.now_eff() then public.oa_label('cutoff_state_cancelled')
                           else (v_secs/3600)::text || 'h ' || lpad(((v_secs%3600)/60)::text,2,'0') || 'm' end
                 else '' end;

  v_wsecs := case when r.restore_until is null then 0
                  else greatest(extract(epoch from (r.restore_until - public.now_eff()))::bigint, 0) end;
  v_win := r.state = 'cancelled' and r.restore_until is not null and public.now_eff() < r.restore_until;

  return jsonb_build_object(
    'order_id',      r.order_id,
    'order_code',    coalesce(o.order_code,''),
    'customer',      coalesce(v_name,''),
    'state',         r.state,
    'state_label',   public.oa_label('cutoff_state_' || r.state),
    'state_tone',    case r.state when 'cancelled' then 'danger'
                                  when 'held' then 'warning'
                                  when 'warned' then 'warning'
                                  when 'paid' then 'success'
                                  when 'restored' then 'success'
                                  when 'exempt' then 'info'
                                  else 'neutral' end,
    'cutoff_label',  to_char(v_eff at time zone 'Asia/Kolkata','FMHH12:MI AM'),
    'countdown',     v_left,
    'extended_label', case when coalesce(r.extra_min,0) > 0
                           then '+' || r.extra_min || ' min' else '' end,
    'due_label',     v_adv->>'due_display',
    'required_label',v_adv->>'required_display',
    'paid_label',    v_adv->>'verified_display',
    'advance_ok',    (v_adv->>'ok')::boolean,
    'reason',        coalesce(r.reason,''),
    'window_open',   v_win,
    'window_label',  case when v_win
                          then (v_wsecs/60)::text || 'm ' || lpad((v_wsecs%60)::text,2,'0') || 's'
                          else '' end,
    'can_restore',   v_win,
    'can_extend_window', v_win,
    'can_extend',    r.state in ('watching','warned'),
    'can_cancel_now',r.state in ('watching','warned'),
    'can_exempt',    not coalesce(r.exempt,false) and r.state <> 'cancelled',
    'can_unexempt',  coalesce(r.exempt,false),
    'restore_label', public.oa_label('cutoff_restore_label'),
    'extend_window_label', '+' || greatest(coalesce(cfg.cutoff_extend_min,10),1) || ' min',
    'extend_label',  '+' || greatest(coalesce(cfg.cutoff_extend_min,10),1) || ' min',
    'cancel_now_label', public.oa_label('cutoff_cancel_now_label'),
    'exempt_label',  public.oa_label('cutoff_exempt_label'),
    'unexempt_label',public.oa_label('cutoff_unexempt_label'));
end $function$;


-- -------------------------------------------------------------------------
-- THE DELIVERY SLA BLOCK — on time, due soon, breached
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sla_block(d deliveries)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_grace int := coalesce((public._dcfg(d.zone_id)->>'on_time_grace_min')::int, 15);
  v_due timestamptz := d.promised_at;
  v_end timestamptz;
  v_state text; v_chip text; v_tone jsonb; v_late_min int;
begin
  if v_due is null then
    return jsonb_build_object(
      'has', false,
      'label', public._c('delivery.promise_none'),
      'state', 'none');
  end if;

  v_end := v_due + make_interval(mins => v_grace);

  if d.status = 'delivered' then
    v_state := case when d.delivered_at <= v_end then 'on_time' else 'breached' end;
    v_late_min := greatest(0, ceil(extract(epoch from (d.delivered_at - v_due))/60))::int;
  elsif d.status in ('failed','rto','cancelled') then
    v_state := 'closed';
    v_late_min := 0;
  elsif public.now_eff() > v_end then
    v_state := 'breached';
    v_late_min := ceil(extract(epoch from (public.now_eff() - v_due))/60)::int;
  elsif public.now_eff() > v_due - interval '30 minutes' then
    v_state := 'due_soon';
    v_late_min := 0;
  else
    v_state := 'pending';
    v_late_min := 0;
  end if;

  v_chip := case v_state
              when 'on_time'  then public._c('delivery.promise_ontime_chip')
              when 'breached' then public._c('delivery.promise_breached_chip')
              when 'due_soon' then public._c('delivery.promise_due_soon_chip')
              else '' end;

  -- Muted state colours, straight off the design system.
  v_tone := case v_state
              when 'on_time'  then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
              when 'breached' then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
              when 'due_soon' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
              else jsonb_build_object('bg','#EFF6FF','fg','#1E40AF') end;

  return jsonb_build_object(
    'has', true,
    'state', v_state,
    'promised_at', v_due,
    'promise_label', public._c('delivery.promise_label'),
    'promised_label', to_char(v_due at time zone 'Asia/Kolkata','DD Mon, hh12:MI am'),
    'promised_time_label', to_char(v_due at time zone 'Asia/Kolkata','hh12:MI am'),
    'chip', v_chip,
    'chip_colors', v_tone,
    'late_minutes', v_late_min,
    'is_breached', (v_state = 'breached'));
end $function$;


-- -------------------------------------------------------------------------
-- THE STOCK EXPIRY WARNING
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._expiry_warning(p_exp date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when p_exp is null then jsonb_build_object('show', false)
    when p_exp < (public.now_eff() at time zone 'Asia/Kolkata')::date then
      jsonb_build_object('show', true, 'level', 'expired',
        'label', 'EXPIRED — ' || to_char(p_exp,'DD Mon YYYY'),
        'colors', jsonb_build_object('bg','#FEE2E2','fg','#B42318','border','#F04438'))
    when p_exp < (public.now_eff() at time zone 'Asia/Kolkata')::date + 180 then
      jsonb_build_object('show', true, 'level', 'short_expiry',
        'label', 'Short expiry — ' || to_char(p_exp,'DD Mon YYYY'),
        'colors', jsonb_build_object('bg','#FEF3C7','fg','#92400E','border','#F59E0B'))
    else jsonb_build_object('show', false, 'level', 'ok',
        'label', 'Exp ' || to_char(p_exp,'Mon YYYY'))
  end
$function$;


-- -------------------------------------------------------------------------
-- TOKEN EXPIRY — the public stock-update form
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_stock_update_form(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f record; v_items jsonb;
begin
  select * into f from stock_update_forms where token = p_token;

  if f.token is null then
    return jsonb_build_object(
      'error','invalid',
      'error_title','This link is no longer valid',
      'error_note','Please contact mediBO for assistance.');
  end if;

  if f.status = 'expired' or (f.expires_at is not null and f.expires_at < public.now_eff()) then
    return jsonb_build_object(
      'error','expired',
      'error_title','This stock update link has expired',
      'error_note','Please contact mediBO for a new link.');
  end if;

  -- decorate each item with its own finished "OOS since dd/mm/yy" line
  select coalesce(jsonb_agg(
           e || jsonb_build_object(
             'oos_label', case when coalesce(e->>'oos_since','') = '' then ''
                               else 'OOS since ' || (e->>'oos_since') end,
             'company',    coalesce(e->>'company',''),
             'category',   coalesce(e->>'category',''),
             'pack_label', coalesce(e->>'pack_label',''),
             'image',      coalesce(e->>'image',''),
             'product_name', coalesce(e->>'product_name',''))
           order by ord), '[]'::jsonb)
    into v_items
  from jsonb_array_elements(coalesce(f.items,'[]'::jsonb)) with ordinality t(e, ord);

  return jsonb_build_object(
    'kind', 'stock_update',
    'supplier_name', coalesce(f.supplier_name,''),
    'status', coalesce(f.status,''),
    'title', 'Stock update',
    'eyebrow', 'mediBO · Stock update',
    'intro', 'Please confirm which of these are back in stock.',
    'submit_label', 'Submit',
    'submitting_label', 'Submitting…',
    'success_title', 'Thank you — stock update received',
    'success_note', 'Your answers have been saved.',
    'already_note', 'You have already responded to this stock update.',
    'empty_text', 'Nothing to confirm right now.',
    'submit_error', 'Submission failed. Please try again.',
    'answered_suffix', 'answered',
    'item_count', jsonb_array_length(v_items),
    'items', v_items,
    'buttons', jsonb_build_array(
      jsonb_build_object('key','still_oos','label','Still Out of Stock','side','left','tone','oos'),
      jsonb_build_object('key','back_in_stock','label','Back in Stock','side','right','tone','available')));
end $function$;


-- -------------------------------------------------------------------------
-- TOKEN EXPIRY — the public feedback form
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_feedback_form(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.order_feedback_token%rowtype;
begin
  select * into t from public.order_feedback_token where token = p_token;
  if t.token is null then
    return jsonb_build_object('ok', false, 'error','unknown',
      'title', public._c('feedback.wa_title'),
      'message', public._c('feedback.err_unknown'));
  end if;
  if t.used_at is not null
     or exists (select 1 from public.order_feedback f
                 where f.order_id = t.order_id and not f.skipped) then
    return jsonb_build_object('ok', false, 'error','used',
      'title', public._c('feedback.wa_title'),
      'message', public._c('feedback.err_used'));
  end if;
  if t.expires_at < public.now_eff() then
    return jsonb_build_object('ok', false, 'error','expired',
      'title', public._c('feedback.wa_title'),
      'message', public._c('feedback.err_expired'));
  end if;
  return jsonb_build_object('ok', true, 'intro', public._c('feedback.wa_intro'))
         || public._order_feedback_card(t.order_id);
end $function$;


-- -------------------------------------------------------------------------
-- TOKEN EXPIRY — the KYC upload token
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kyc_token_form(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t kyc_upload_token%rowtype; v_name text; v_state jsonb;
begin
  select * into t from kyc_upload_token where token = btrim(coalesce(p_token,''));
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown',
      'title', _c('kyc_token.title'), 'message', _c('kyc_token.err_unknown'));
  end if;
  if t.expires_at < public.now_eff() then
    return jsonb_build_object('ok', false, 'error','expired',
      'title', _c('kyc_token.title'), 'message', _c('kyc_token.err_expired'));
  end if;

  if t.owner_kind = 'pharmacy' then
    select pharmacy_name into v_name from pharmacy_profiles where id = t.owner_id;
  else
    select supplier_name into v_name from supplier_profiles where id = t.owner_id;
  end if;

  update kyc_upload_token set opened_at = coalesce(opened_at, now()) where token = t.token;
  v_state := public.kyc_state(t.owner_kind, t.owner_id);

  return jsonb_build_object(
    'ok', true,
    'token', t.token,
    'title', _c('kyc_token.title'),
    'subtitle', _c('kyc_token.subtitle'),
    'for_line', _cf('kyc_token.for_label', jsonb_build_object('name', coalesce(v_name,''))),
    'deadline_line', case when (v_state->>'grace_until') is null then ''
                          else _cf('kyc_token.deadline', jsonb_build_object(
                                 'd', to_char((v_state->>'grace_until')::date,'FMDD Mon YYYY'))) end,
    'kind', 'drug_licence',
    'kind_label', _c('kyc.kind.drug_licence'),
    'number_label', _c('kyc.number_label'),
    'number_hint', _c('kyc_token.number_hint'),
    'expiry_hint', _c('kyc_token.expiry_hint'),
    'file_hint', _c('kyc_token.file_hint'),
    'submit_label', _c('kyc_token.submit'),
    'done_title', _c('kyc_token.done_title'),
    'done_body', _c('kyc_token.done_body'),
    'bucket', 'kyc-docs',
    'upload_prefix', 'token/'||t.token,
    'already_done', (t.used_at is not null),
    'used_message', _c('kyc_token.err_used'),
    'state', v_state);
end
$function$;

-- -------------------------------------------------------------------------
-- THE CUT-OFF TICK — the session clock decides, the session's own orders only
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_cutoff_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.order_alert_config;
  h   public.order_hours%rowtype;
  z   record; r record; o public.orders%rowtype;
  v_today date := public.today_eff();
  -- Non-null ONLY while this very request is a pinned test session. The tick
  -- then works on that session's own orders and nothing else — a pinned clock
  -- must never cancel a real pharmacy's order.
  v_clock_sess bigint := public.test_clock_session();
  v_cut timestamptz; v_eff timestamptz; v_adv jsonb; v_vars jsonb;
  v_watched int := 0; v_warn1 int := 0; v_warn2 int := 0;
  v_cancelled int := 0; v_held int := 0; v_paid int := 0; v_paused int := 0;
  v_snap jsonb; v_name text; v_reason text;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.cutoff_enabled, false) then
    return jsonb_build_object('ok', true, 'skipped', 'disabled');
  end if;

  for z in select id from public.zones
            where coalesce(is_active,true) and not coalesce(is_synthetic,false)
            order by id
  loop
    v_cut := public._order_cutoff_at(z.id::smallint, v_today);

    -- Pause outside business hours: a shut counter neither warns nor cancels.
    if coalesce(cfg.cutoff_pause_outside_hours, true) then
      select * into h from public.order_hours where zone_id = z.id;
      if h.id is null then select * into h from public.order_hours order by id limit 1; end if;
      if h.id is not null and coalesce(h.is_open, true) = false then
        v_paused := v_paused + 1;
        continue;
      end if;
    end if;

    -- Everything placed today in this zone goes on the clock.
    insert into public.order_cutoff_run (order_id, zone_id, cutoff_on, cutoff_at)
    select o2.id, z.id::smallint, v_today, v_cut
      from public.orders o2
     where coalesce(o2.zone_id, z.id::smallint) = z.id::smallint
       and (o2.created_at at time zone 'Asia/Kolkata')::date = v_today
       and o2.closed_at is null
       -- 'accepted' is the admin's own decision and order_is_paid() already
       -- treats it as settled; the clock never touches a decided order.
       and coalesce(o2.status,'pending') not in ('accepted','cancelled','rejected','delivered','completed')
       and (v_clock_sess is null or o2.test_session_id = v_clock_sess)
    on conflict (order_id) do nothing;

    -- 1. The two warnings, through the switchboard, with the pay link.
    for r in select cr.* from public.order_cutoff_run cr
              where cr.cutoff_on = v_today and cr.zone_id = z.id::smallint
                and cr.state in ('watching','warned')
                and (v_clock_sess is null or exists (
                      select 1 from public.orders o3
                       where o3.id = cr.order_id and o3.test_session_id = v_clock_sess))
              order by cr.cutoff_at
    loop
      select * into o from public.orders where id = r.order_id;
      if o.id is null then continue; end if;
      v_watched := v_watched + 1;
      v_eff := public._order_cutoff_effective(r.cutoff_at, r.extra_min);
      v_adv := public._order_advance_state(r.order_id);

      if coalesce(o.status,'') = 'accepted'
         or coalesce((v_adv->>'ok')::boolean, false) then
        update public.order_cutoff_run set state = 'paid', acted_at = now(),
               reason = 'advance_verified', updated_at = now() where order_id = r.order_id;
        v_paid := v_paid + 1;
        continue;
      end if;
      if public._order_cutoff_exempt(r.order_id) then
        update public.order_cutoff_run set state = 'exempt', acted_at = now(),
               reason = 'never_auto_cancel', updated_at = now() where order_id = r.order_id;
        continue;
      end if;

      select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''), '')
        into v_name from public.pharmacy_profiles pp where pp.id = o.customer_id;

      v_vars := jsonb_build_object(
        'customer',   coalesce(v_name,''),
        'order_code', coalesce(o.order_code,''),
        'amount',     v_adv->>'due_display',
        'cutoff',     to_char(v_eff at time zone 'Asia/Kolkata','FMHH12:MI AM'),
        'pay_link',   public._order_cutoff_pay_link(r.order_id, (v_adv->>'due')::numeric),
        'order_id',   r.order_id::text,
        'customer_id', coalesce(o.customer_id::text,''));

      if r.warn1_at is null
         and public.now_eff() >= v_eff - make_interval(mins => greatest(coalesce(cfg.cutoff_warn1_min,0),0))
         and public.now_eff() < v_eff then
        begin perform public.notify('order_cutoff_warning', null,
                v_vars || jsonb_build_object('message',
                  public.notif_render(coalesce(cfg.cutoff_warn_text,''), v_vars)));
        exception when others then null; end;
        update public.order_cutoff_run set warn1_at = now(), state = 'warned',
               updated_at = now() where order_id = r.order_id;
        v_warn1 := v_warn1 + 1;
        continue;
      end if;

      if r.warn2_at is null
         and public.now_eff() >= v_eff - make_interval(mins => greatest(coalesce(cfg.cutoff_warn2_min,0),0))
         and public.now_eff() < v_eff then
        begin perform public.notify('order_cutoff_final_warning', null,
                v_vars || jsonb_build_object('message',
                  public.notif_render(coalesce(cfg.cutoff_warn_text,''), v_vars)));
        exception when others then null; end;
        update public.order_cutoff_run set warn2_at = now(), state = 'warned',
               updated_at = now() where order_id = r.order_id;
        v_warn2 := v_warn2 + 1;
        continue;
      end if;

      -- 2. The cut-off itself.
      if public.now_eff() >= v_eff + make_interval(mins => greatest(coalesce(cfg.cutoff_cancel_after_min,0),0)) then
        -- Sourcing already started: this order is NEVER auto-cancelled. It is
        -- held as Payment pending instead (#708's order_hold, which every
        -- fulfilment surface already respects).
        if public._order_sourcing_started(r.order_id)
           or coalesce(cfg.cutoff_behaviour,'cancel') = 'hold' then
          v_reason := case when public._order_sourcing_started(r.order_id)
                           then 'sourcing_started' else 'behaviour_hold' end;
          -- The SAME order_hold row order_hold() writes — every fulfilment
          -- surface reads order_hold_state(), so nothing else has to learn a
          -- new state. Written directly because the cron has no actor and
          -- _c708_actor() would refuse the RPC wrapper.
          insert into public.order_hold (order_id, status, stage_key, reason_code,
                 reason_label, note, held_by_kind, held_by_label, held_at)
          values (r.order_id, 'active', public._c708_stage(r.order_id),
                  'payment_pending', public.oa_label('cutoff_state_held'),
                  public.oa_label('cutoff_state_cancelled'), 'system', 'system', now())
          on conflict (order_id) where status = 'active' do nothing;
          update public.order_cutoff_run set state = 'held', acted_at = now(),
                 reason = v_reason, updated_at = now() where order_id = r.order_id;
          perform public.audit_write('order_cutoff_hold','order', r.order_id::text,
                    to_jsonb(r), jsonb_build_object('state','held','reason',v_reason));
          v_held := v_held + 1;
          continue;
        end if;

        -- Snapshot first: a restore must put back items, quantities and prices
        -- EXACTLY as they were.
        select jsonb_build_object(
                 'order', jsonb_build_object(
                   'status', o.status, 'closed_at', o.closed_at, 'closed_by', o.closed_by,
                   'closed_reason', o.closed_reason, 'close_mode', o.close_mode,
                   'fulfillment_status', o.fulfillment_status),
                 'items', coalesce((select jsonb_agg(jsonb_build_object(
                     'id', oi.id, 'quantity', oi.quantity, 'mrp', oi.mrp,
                     'price', oi.price, 'fulfillment_state', oi.fulfillment_state,
                     'inquiry_id', oi.inquiry_id) order by oi.id)
                   from public.order_items oi where oi.order_id = r.order_id), '[]'::jsonb),
                 'inquiries', coalesce((select jsonb_agg(jsonb_build_object(
                     'id', q.id, 'inquiry_phase', q.inquiry_phase) order by q.id)
                   from public.inquiry q
                  where q.id in (select oi.inquiry_id from public.order_items oi
                                  where oi.order_id = r.order_id and oi.inquiry_id is not null)), '[]'::jsonb))
          into v_snap;

        perform public._order_cancel_core(r.order_id, 'unpaid_cutoff',
                  public.oa_label('cutoff_state_cancelled'), null, 'system');

        update public.order_cutoff_run
           set state = 'cancelled', acted_at = now(), snapshot = v_snap,
               reason = 'advance_not_verified_by_cutoff',
               restore_until = public.now_eff() + make_interval(mins => greatest(coalesce(cfg.cutoff_restore_min,0),0)),
               updated_at = now()
         where order_id = r.order_id;

        perform public.audit_write('order_cutoff_cancel','order', r.order_id::text,
                  v_snap, jsonb_build_object('state','cancelled',
                    'reason','advance_not_verified_by_cutoff',
                    'cutoff_at', v_eff, 'advance', v_adv));

        begin perform public.notify('order_cutoff_cancelled', null, v_vars);
        exception when others then null; end;
        v_cancelled := v_cancelled + 1;
      end if;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'day', v_today,
    'test_session', v_clock_sess,
    'watched', v_watched, 'warn1', v_warn1, 'warn2', v_warn2,
    'cancelled', v_cancelled, 'held', v_held, 'paid', v_paid, 'zones_paused', v_paused);
end $function$;


-- -------------------------------------------------------------------------
-- ORDER HOURS TICK — the flag it flips is global, so a pinned clock never runs it
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_hours_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record; v_now time := (now() at time zone 'Asia/Kolkata')::time;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_opened int := 0; v_closed int := 0;
begin
  -- CMD #1850 — A PINNED CLOCK NEVER REACHES A SCHEDULED JOB. pg_cron carries
  -- no request headers, so this is already null there; it is non-null only when
  -- a person with a pinned session invokes the tick by hand, and then the tick
  -- refuses rather than flipping a flag every real customer reads.
  if public.test_clock_session() is not null then
    return jsonb_build_object('ok', true, 'skipped', 'test_clock');
  end if;

  for r in select * from order_hours where zone_id is not null loop
    if r.auto_open_time is not null and not r.is_open
       and v_now >= r.auto_open_time
       and coalesce(r.last_auto_open_on, date '1900-01-01') < v_today
       and (r.auto_close_time is null or v_now < r.auto_close_time) then
      update order_hours set is_open = true, last_opened_at = now(),
             last_auto_open_on = v_today, updated_at = now() where id = r.id;
      v_opened := v_opened + 1;
    elsif r.auto_close_time is not null and r.is_open
       and v_now >= r.auto_close_time
       and coalesce(r.last_auto_close_on, date '1900-01-01') < v_today then
      update order_hours set is_open = false, last_closed_at = now(),
             last_auto_close_on = v_today, updated_at = now() where id = r.id;
      v_closed := v_closed + 1;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'opened',v_opened,'closed',v_closed,
    'zones_checked',(select count(*) from order_hours where zone_id is not null));
end $function$;


-- -------------------------------------------------------------------------
-- LICENCE EXPIRY SWEEP — it notifies real partners, so a pinned clock never runs it
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partner_licence_expiry_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_window int := coalesce((select (value #>> '{}')::int from app_settings
                              where key='partner_licence_window_days'), 30);
  r record; v_sent int := 0; v_expired int := 0;
begin
  -- CMD #1850 — A PINNED CLOCK NEVER REACHES A SCHEDULED JOB. pg_cron carries
  -- no request headers, so this is already null there; it is non-null only when
  -- a person with a pinned session invokes the tick by hand, and then the tick
  -- refuses rather than flipping a flag every real customer reads.
  if public.test_clock_session() is not null then
    return jsonb_build_object('ok', true, 'skipped', 'test_clock');
  end if;

  for r in
    select rp.id as partner_id, rp.partner_name, t.kind, t.label, t.expiry
      from region_partners rp
      cross join lateral (values
        ('gstin',     public._c('partner_licence.gstin_label'),     rp.gstin_expiry),
        ('dl_20b',    public._c('partner_licence.dl_20b_label'),    rp.dl_20b_expiry),
        ('dl_21b',    public._c('partner_licence.dl_21b_label'),    rp.dl_21b_expiry),
        ('agreement', public._c('partner_licence.agreement_label'), rp.agreement_expiry)
      ) as t(kind, label, expiry)
     where coalesce(rp.is_active, false)
       and t.expiry is not null
       and t.expiry <= current_date + v_window
       and not exists (select 1 from partner_licence_reminder m
                        where m.partner_id = rp.id and m.kind = t.kind and m.expiry = t.expiry)
  loop
    begin
      perform public.notify_partner('partner_licence_expiry', jsonb_build_object(
        'partner_id', r.partner_id::text,
        'label', r.label,
        'partner', r.partner_name,
        'd', to_char(r.expiry,'DD/MM/YYYY'),
        'title', public._c('partner_licence.reminder_title'),
        'body', public._cf('partner_licence.reminder_body', jsonb_build_object(
                  'label', r.label, 'partner', r.partner_name,
                  'd', to_char(r.expiry,'DD/MM/YYYY')))));
    exception when others then
      null;  -- a missing notification route must never stall the sweep
    end;

    insert into partner_licence_reminder(partner_id, kind, expiry)
    values (r.partner_id, r.kind, r.expiry) on conflict do nothing;

    insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
    values (r.partner_id, null, 'partner.onboarding', 'licence_expiry_reminder',
            jsonb_build_object('kind', r.kind, 'expiry', r.expiry,
              'summary', public._cf('partner_licence.reminder_body', jsonb_build_object(
                'label', r.label, 'partner', r.partner_name,
                'd', to_char(r.expiry,'DD/MM/YYYY')))));

    v_sent := v_sent + 1;
    if r.expiry < current_date then v_expired := v_expired + 1; end if;
  end loop;

  if v_expired > 0 then
    insert into rg_alerts(fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('partner_licence_expired', 'warn', 'partner', 'partner licence expired',
            jsonb_build_object('count', v_expired), now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          detail = excluded.detail;
  end if;

  return jsonb_build_object('ok', true, 'reminded', v_sent, 'expired', v_expired,
                            'window_days', v_window);
end $function$;


-- -------------------------------------------------------------------------
-- STOCK-UPDATE TOKEN SWEEP — same rule
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stock_update_expire()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cfg record; v int := 0;
begin
  -- CMD #1850 — A PINNED CLOCK NEVER REACHES A SCHEDULED JOB. pg_cron carries
  -- no request headers, so this is already null there; it is non-null only when
  -- a person with a pinned session invokes the tick by hand, and then the tick
  -- refuses rather than flipping a flag every real customer reads.
  if public.test_clock_session() is not null then return 0; end if;

  select * into cfg from stock_followup_config where id;
  update stock_update_queue q
     set asked_at = null
   where q.resolved_at is null
     and q.asked_at is not null
     and q.asked_at < now() - make_interval(days => cfg.ask_ttl_days)
     and q.ask_count < cfg.max_asks;
  get diagnostics v = row_count;
  return v;
end $function$;

commit;

-- ---------------------------------------------------------------------------
-- THE TWO INVARIANTS, AS PERMANENT LIVE PROBES
-- ---------------------------------------------------------------------------
-- The protected Dart suite holds down the printer half of spec 5 (the unpinned
-- banner is byte-identical, one install's pinned time never reaches another's
-- screen). These two hold down the SQL half, on the live database, on every
-- rg_check run. Both bodies end in RG_ROLLBACK, so neither ever leaves a row.
begin;

insert into public.rg_behavior_tests(name, body, enabled, note) values
('c1850_clock_unpinned_is_identical', $probe$
do $b$
declare v_stored boolean; v_zone smallint; v_eff boolean;
begin
  perform set_config('request.headers', '{}', true);
  if public.test_clock_session() is not null then
    raise exception 'a clock resolved for a request carrying no session header';
  end if;
  if public.now_eff() <> now() then
    raise exception 'now_eff() drifted from now() with no session';
  end if;
  if public.today_eff() <> (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'today_eff() drifted with no session';
  end if;
  select zone_id, is_open into v_zone, v_stored from public.order_hours order by id limit 1;
  if v_zone is not null then
    v_eff := public.order_hours_open_eff(v_zone);
    if v_eff is distinct from coalesce(v_stored, true) then
      raise exception 'order_hours_open_eff() diverged from the stored flag with no session';
    end if;
  end if;
  if (public.order_hours_tick() ? 'skipped') then
    raise exception 'the order-hours tick refused to run for a caller with no pinned clock';
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$probe$, true,
 'CMD #1850 — with no session header every clock reader is the real clock and every tick runs.'),

('c1850_clock_is_one_sessions_own', $probe$
do $b$
declare v_tok text := 'rg1850' || replace(gen_random_uuid()::text, '-', '');
        v_id bigint; v_want text := '23:47';
begin
  -- Only one session may be live at a time (#573's index). Ending whatever is
  -- live is rolled back with everything else in this body.
  update public.test_sessions set status = 'ended', ended_at = coalesce(ended_at, now())
   where status = 'live';
  insert into public.test_sessions(label, scope, status, origin, started_by_label,
                                   expires_at, token)
  values ('rg c1850', 'install', 'live', 'human', 'rg', now() + interval '10 minutes', v_tok)
  returning id into v_id;

  perform set_config('request.headers',
    json_build_object('x-medibo-test-session', v_tok)::text, true);
  if coalesce((public.test_clock_pin(
        (now() at time zone 'Asia/Kolkata')::date::text || ' ' || v_want) ->> 'ok')::boolean,
      false) is not true then
    raise exception 'test_clock_pin refused a live session';
  end if;
  if public.test_clock_session() is distinct from v_id then
    raise exception 'the pin did not bind to the session that set it';
  end if;
  if to_char(public.now_eff() at time zone 'Asia/Kolkata', 'HH24:MI') <> v_want then
    raise exception 'the pinned clock did not move';
  end if;

  -- The same database, the same instant, a request that carries no token.
  perform set_config('request.headers', '{}', true);
  if public.test_clock_session() is not null then
    raise exception 'a pinned session was visible to a request that is not in it';
  end if;
  if public.now_eff() <> now() then
    raise exception 'a pinned clock reached a reader outside the session';
  end if;
  if (public.order_hours_tick() ? 'skipped') then
    raise exception 'a pinned session made a scheduled job refuse for everyone';
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$probe$, true,
 'CMD #1850 — a pinned clock moves time for its own header and for nothing else.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

commit;

-- CMD #1847 — the Om-facing half: the console (orders on the clock with their
-- countdown), the per-order actions, and the settings folded into the screen
-- that already saves the auto-cancel.

-- One clock row rendered. Nothing here is computed in Dart: every word, every
-- rupee and the countdown itself are strings in this payload.
create or replace function public._order_cutoff_row(r public.order_cutoff_run)
returns jsonb language plpgsql stable as $$
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

  v_secs := greatest(extract(epoch from (v_eff - now()))::bigint, 0);
  v_left := case when r.state in ('watching','warned')
                 then case when v_eff <= now() then public.oa_label('cutoff_state_cancelled')
                           else (v_secs/3600)::text || 'h ' || lpad(((v_secs%3600)/60)::text,2,'0') || 'm' end
                 else '' end;

  v_wsecs := case when r.restore_until is null then 0
                  else greatest(extract(epoch from (r.restore_until - now()))::bigint, 0) end;
  v_win := r.state = 'cancelled' and r.restore_until is not null and now() < r.restore_until;

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
end $$;

-- THE CONSOLE. Zone and date come from the header picker
-- (admin_active_zone() / admin_active_date()); a partner is clamped to his own
-- zone by admin_active_zone() itself.
create or replace function public.order_cutoff_console(p_zone smallint default null,
                                                       p_date date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_zone smallint; v_date date; cfg public.order_alert_config; v_rows jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg  := public._oa_cfg();
  v_zone := coalesce(public.partner_zone_id(), p_zone, public.admin_active_zone());
  v_date := coalesce(p_date, public.admin_active_date());

  select coalesce(jsonb_agg(x order by (x->>'order_code')), '[]'::jsonb) into v_rows
    from (select public._order_cutoff_row(r) x
            from public.order_cutoff_run r
           where r.cutoff_on = v_date
             and (v_zone is null or r.zone_id = v_zone)) s
   where x is not null;

  return jsonb_build_object(
    'ok', true,
    'title',       public.oa_label('cutoff_clock_title'),
    'empty_label', public.oa_label('cutoff_clock_empty'),
    'zone_id',     v_zone,
    'date',        v_date,
    'date_label',  to_char(v_date,'DD/MM/YYYY'),
    'cutoff_label',to_char(public._order_cutoff_at(v_zone, v_date) at time zone 'Asia/Kolkata',
                           'FMHH12:MI AM'),
    'enabled',     coalesce(cfg.cutoff_enabled,false),
    'window_open', public.order_cutoff_window_open(v_zone),
    'window_note', public.oa_label('cutoff_window_open'),
    'count',       jsonb_array_length(v_rows),
    'items',       v_rows);
end $$;

-- RESTORE — items, quantities and prices exactly as they were, replayed from
-- the snapshot the engine took the instant before it cancelled.
create or replace function public.order_cutoff_restore(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.order_cutoff_run%rowtype; v_snap jsonb; it jsonb; v_before jsonb;
  v_who text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into r from public.order_cutoff_run where order_id = p_order_id;
  if not found or r.state <> 'cancelled' or r.restore_until is null
     or now() >= r.restore_until then
    return jsonb_build_object('ok', false, 'error','window_closed',
      'message', public.oa_label('cutoff_restore_closed'));
  end if;
  v_snap := coalesce(r.snapshot,'{}'::jsonb);
  v_who  := coalesce(nullif(public.my_login_email(),''), 'admin');

  select to_jsonb(oc) into v_before from public.order_cancellations oc
   where oc.order_id = p_order_id order by oc.cancelled_at desc limit 1;

  -- The lines first, each one back to the exact quantity, price and state it
  -- was cancelled from.
  for it in select * from jsonb_array_elements(coalesce(v_snap->'items','[]'::jsonb))
  loop
    update public.order_items
       set quantity          = (it->>'quantity')::numeric,
           mrp               = nullif(it->>'mrp','')::numeric,
           price             = nullif(it->>'price','')::numeric,
           fulfillment_state = it->>'fulfillment_state'
     where id = (it->>'id')::uuid;
  end loop;

  for it in select * from jsonb_array_elements(coalesce(v_snap->'inquiries','[]'::jsonb))
  loop
    update public.inquiry set inquiry_phase = it->>'inquiry_phase'
     where id = (it->>'id')::bigint;
  end loop;

  -- The cancellation record goes; it is preserved whole in audit_log below, and
  -- leaving it would keep every gate reading this order as closed.
  delete from public.order_cancellations where order_id = p_order_id;

  update public.orders
     set status             = coalesce(v_snap->'order'->>'status','pending'),
         closed_at          = nullif(v_snap->'order'->>'closed_at','')::timestamptz,
         closed_by          = nullif(v_snap->'order'->>'closed_by',''),
         closed_reason      = nullif(v_snap->'order'->>'closed_reason',''),
         close_mode         = nullif(v_snap->'order'->>'close_mode',''),
         fulfillment_status = coalesce(v_snap->'order'->>'fulfillment_status','open')
   where id = p_order_id;

  update public.order_cutoff_run
     set state = 'restored', restored_at = now(), restored_by = v_who,
         restore_until = null, reason = 'restored_in_window', updated_at = now()
   where order_id = p_order_id;

  perform public.audit_write('order_cutoff_restore','order', p_order_id::text,
            coalesce(v_before,'{}'::jsonb) || jsonb_build_object('snapshot', v_snap),
            jsonb_build_object('state','restored','by', v_who, 'at', now()));

  return jsonb_build_object('ok', true,
    'message', public.oa_label('cutoff_restored'),
    'row', public._order_cutoff_row((select cr from public.order_cutoff_run cr where cr.order_id = p_order_id)));
end $$;

-- THE PER-ORDER ACTIONS from the card.
create or replace function public.order_cutoff_action(p_order_id uuid, p_action text,
                                                      p_minutes int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.order_cutoff_run%rowtype; cfg public.order_alert_config;
  v_act text := lower(btrim(coalesce(p_action,''))); v_min int; v_snap jsonb;
  o public.orders%rowtype; v_who text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg := public._oa_cfg();
  v_who := coalesce(nullif(public.my_login_email(),''), 'admin');
  v_min := greatest(coalesce(p_minutes, cfg.cutoff_extend_min, 10), 1);

  if v_act = 'restore' then return public.order_cutoff_restore(p_order_id); end if;

  select * into r from public.order_cutoff_run where order_id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_on_clock');
  end if;

  if v_act = 'extend' then
    update public.order_cutoff_run
       set extra_min = greatest(coalesce(extra_min,0),0) + v_min, updated_at = now()
     where order_id = p_order_id;
  elsif v_act = 'extend_window' then
    update public.order_cutoff_run
       set restore_until = greatest(coalesce(restore_until, now()), now())
                           + make_interval(mins => v_min),
           restore_extra_min = coalesce(restore_extra_min,0) + v_min, updated_at = now()
     where order_id = p_order_id and state = 'cancelled';
  elsif v_act = 'exempt' then
    update public.order_cutoff_run
       set exempt = true, state = 'exempt', reason = 'exempt_by_admin', updated_at = now()
     where order_id = p_order_id;
  elsif v_act = 'unexempt' then
    update public.order_cutoff_run
       set exempt = false, state = 'watching', reason = '', updated_at = now()
     where order_id = p_order_id;
  elsif v_act = 'cancel_now' then
    select * into o from public.orders where id = p_order_id;
    select jsonb_build_object(
             'order', jsonb_build_object(
               'status', o.status, 'closed_at', o.closed_at, 'closed_by', o.closed_by,
               'closed_reason', o.closed_reason, 'close_mode', o.close_mode,
               'fulfillment_status', o.fulfillment_status),
             'items', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', oi.id, 'quantity', oi.quantity, 'mrp', oi.mrp, 'price', oi.price,
                 'fulfillment_state', oi.fulfillment_state, 'inquiry_id', oi.inquiry_id)
               order by oi.id) from public.order_items oi where oi.order_id = p_order_id), '[]'::jsonb),
             'inquiries', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', q.id, 'inquiry_phase', q.inquiry_phase) order by q.id)
               from public.inquiry q
              where q.id in (select oi.inquiry_id from public.order_items oi
                              where oi.order_id = p_order_id and oi.inquiry_id is not null)), '[]'::jsonb))
      into v_snap;
    perform public._order_cancel_core(p_order_id, 'unpaid_cutoff',
              public.oa_label('cutoff_state_cancelled'), auth.uid(), 'admin');
    update public.order_cutoff_run
       set state = 'cancelled', acted_at = now(), snapshot = v_snap,
           reason = 'cancelled_by_admin',
           restore_until = now() + make_interval(mins => greatest(coalesce(cfg.cutoff_restore_min,0),0)),
           updated_at = now()
     where order_id = p_order_id;
  else
    return jsonb_build_object('ok', false, 'error','unknown_action');
  end if;

  perform public.audit_write('order_cutoff_' || v_act, 'order', p_order_id::text,
            to_jsonb(r), jsonb_build_object('by', v_who, 'minutes', v_min, 'at', now()));

  return jsonb_build_object('ok', true, 'message', public.oa_label('cutoff_saved'),
    'row', public._order_cutoff_row((select cr from public.order_cutoff_run cr where cr.order_id = p_order_id)));
end $$;

revoke all on function public.order_cutoff_console(smallint, date) from public, anon;
revoke all on function public.order_cutoff_restore(uuid) from public, anon;
revoke all on function public.order_cutoff_action(uuid, text, int) from public, anon;
revoke all on function public.order_cutoff_window_open(smallint) from public, anon;
revoke all on function public._order_cutoff_row(public.order_cutoff_run) from public, anon;
revoke all on function public._order_advance_state(uuid) from public, anon;
revoke all on function public._order_sourcing_started(uuid) from public, anon;
revoke all on function public._order_cutoff_exempt(uuid) from public, anon;
revoke all on function public._order_cutoff_pay_link(uuid, numeric) from public, anon;
grant execute on function public.order_cutoff_console(smallint, date) to authenticated, service_role;
grant execute on function public.order_cutoff_restore(uuid) to authenticated, service_role;
grant execute on function public.order_cutoff_action(uuid, text, int) to authenticated, service_role;

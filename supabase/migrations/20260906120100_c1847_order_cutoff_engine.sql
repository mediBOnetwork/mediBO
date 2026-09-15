-- replay-target: production
-- CMD #1847 — the cut-off engine. Helpers, the tick, and the one cron row.

-- The cut-off instant for a zone on a day: the zone's own time, else the first
-- order_hours row's (the same fallback order_hours_state() uses), else the
-- configured default. Reads no auth, so the cron can call it.
create or replace function public._order_cutoff_at(p_zone smallint, p_on date)
returns timestamptz language sql stable as $$
  select ((p_on::text || ' ' || to_char(
            coalesce((select h.cutoff_time from public.order_hours h
                       where h.zone_id = p_zone and h.cutoff_time is not null),
                     (select h.cutoff_time from public.order_hours h
                       where h.cutoff_time is not null order by h.id limit 1),
                     (select c.cutoff_default_time from public.order_alert_config c
                       where c.id = 'singleton'),
                     time '12:00'), 'HH24:MI:SS'))::timestamp)
         at time zone 'Asia/Kolkata';
$$;

-- "Advance payment verified" — the SAME definition customer_order_payment_panel
-- prints: required = MRP total x billing_config.advance_pct, verified = claims
-- that reached received/verified, plus anything Razorpay actually captured.
create or replace function public._order_advance_state(p_order_id uuid)
returns jsonb language plpgsql stable as $$
declare v_mrp numeric; v_pct numeric; v_req numeric; v_ver numeric;
begin
  select coalesce(sum(oi.quantity * oi.mrp), 0) into v_mrp
    from public.order_items oi where oi.order_id = p_order_id;
  select advance_pct into v_pct from public.billing_config where id = 1;
  v_req := round(v_mrp * coalesce(v_pct, 30) / 100, 2);
  select coalesce(sum(amount) filter (where status in ('received','verified')), 0)
    into v_ver from public.payment_claims where order_id = p_order_id;
  v_ver := greatest(coalesce(v_ver,0), coalesce(public.order_paid_amount(p_order_id),0));
  return jsonb_build_object(
    'required', v_req, 'required_display', public.inr_money(v_req),
    'verified', v_ver, 'verified_display', public.inr_money(v_ver),
    'due', greatest(v_req - v_ver, 0),
    'due_display', public.inr_money(greatest(v_req - v_ver, 0)),
    'ok', case when v_req > 0 then v_ver >= v_req else v_ver > 0 end);
end $$;

-- Sourcing having started. Lifted verbatim out of _order_change_gate so BOTH
-- the customer gate and the cut-off engine answer the question the same way:
-- a supplier was asked, a supplier order was cut, fulfilment left 'open', or a
-- line physically moved.
create or replace function public._order_sourcing_started(p_order_id uuid)
returns boolean language plpgsql stable as $$
declare o public.orders%rowtype; v boolean;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return false; end if;
  select exists (
    select 1
      from public.order_items oi
      left join lateral (
        select q.* from public.inquiry q
         where q.id = oi.inquiry_id
            or (oi.inquiry_id is null
                and q.product_id = oi.product_id
                and q.batch_date = coalesce(oi.order_date, o.order_date)
                and (q.zone_id is not distinct from coalesce(oi.zone_id, o.zone_id)
                     or q.zone_id is null))
         order by (q.id = oi.inquiry_id) desc, q.id desc
         limit 1) i on true
     where oi.order_id = p_order_id
       and (i.asked_at is not null or i.supplier_order_id is not null)) into v;
  if v or coalesce(o.fulfillment_status,'open') <> 'open' then return true; end if;
  select exists (
    select 1 from public.order_items oi
     where oi.order_id = p_order_id
       and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
            or coalesce(oi.received_qty,0) > 0
            or coalesce(oi.at_warehouse,false)
            or coalesce(oi.packed,false)
            or oi.shop_qty is not null
            or oi.assigned_supplier is not null)) into v;
  return coalesce(v,false);
end $$;

-- This pharmacy is never auto-cancelled (customer_credit, the row that already
-- carries its credit policy).
create or replace function public._order_cutoff_exempt(p_order_id uuid)
returns boolean language sql stable as $$
  select coalesce((select cc.never_auto_cancel from public.customer_credit cc
                    join public.orders o on o.customer_id = cc.customer_id
                   where o.id = p_order_id), false)
      or coalesce((select r.exempt from public.order_cutoff_run r
                    where r.order_id = p_order_id), false);
$$;

-- The pay link on the warning: the platform UPI account and the SAME deeplink
-- builder khata uses (upi_qr_string).
create or replace function public._order_cutoff_pay_link(p_order_id uuid, p_amount numeric)
returns text language plpgsql stable as $$
declare v record; v_code text;
begin
  select pa, pn into v from public.payment_upi_accounts
   where is_active order by created_at limit 1;
  if v.pa is null then return ''; end if;
  select order_code into v_code from public.orders where id = p_order_id;
  return public.upi_qr_string(v.pa, coalesce(v.pn,'mediBO'),
           greatest(coalesce(p_amount,0),0), coalesce(v_code,''));
end $$;

-- The effective cut-off for one clock row (base + whatever the admin added).
create or replace function public._order_cutoff_effective(p_cutoff_at timestamptz, p_extra_min int)
returns timestamptz language sql immutable as $$
  select p_cutoff_at + make_interval(mins => greatest(coalesce(p_extra_min,0),0));
$$;

-- Is the restoration window open for this zone/day right now? This is what
-- holds the inquiry back.
create or replace function public.order_cutoff_window_open(p_zone smallint)
returns boolean language sql stable as $$
  select exists (
    select 1 from public.order_cutoff_run r
     where (p_zone is null or r.zone_id = p_zone)
       and r.state = 'cancelled'
       and r.restore_until is not null
       and now() < r.restore_until);
$$;

-- ── THE TICK ─────────────────────────────────────────────────────────────────
create or replace function public.order_cutoff_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg public.order_alert_config;
  h   public.order_hours%rowtype;
  z   record; r record; o public.orders%rowtype;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
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
    on conflict (order_id) do nothing;

    -- 1. The two warnings, through the switchboard, with the pay link.
    for r in select cr.* from public.order_cutoff_run cr
              where cr.cutoff_on = v_today and cr.zone_id = z.id::smallint
                and cr.state in ('watching','warned')
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
         and now() >= v_eff - make_interval(mins => greatest(coalesce(cfg.cutoff_warn1_min,0),0))
         and now() < v_eff then
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
         and now() >= v_eff - make_interval(mins => greatest(coalesce(cfg.cutoff_warn2_min,0),0))
         and now() < v_eff then
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
      if now() >= v_eff + make_interval(mins => greatest(coalesce(cfg.cutoff_cancel_after_min,0),0)) then
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
               restore_until = now() + make_interval(mins => greatest(coalesce(cfg.cutoff_restore_min,0),0)),
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
    'watched', v_watched, 'warn1', v_warn1, 'warn2', v_warn2,
    'cancelled', v_cancelled, 'held', v_held, 'paid', v_paid, 'zones_paused', v_paused);
end $$;

revoke all on function public.order_cutoff_tick() from public, anon, authenticated;

insert into public.cron_task(name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                             enabled, max_interval_s, business_hours_only, dml)
select 'order-cutoff', 46, 'poll',
       'select coalesce((select cutoff_enabled from public.order_alert_config where id=''singleton''),false)',
       'select public.order_cutoff_tick()', 12000, true, 3600, false, true
where not exists (select 1 from public.cron_task where name = 'order-cutoff');

insert into public.order_hold_reason(code, label, audience, sort_order, is_active, needs_note)
select 'payment_pending', 'Payment pending', 'staff', 15, true, false
where not exists (select 1 from public.order_hold_reason where code = 'payment_pending');

-- CMD #1847 — the two transitions this rule needs, as ROWS in the state machine
-- (#469) rather than an exception around it: the system cancelling an unpaid
-- order at the cut-off, and the restore putting it back inside the window.
insert into public.order_state_transitions(entity_kind, from_state, to_state, actor_role, note, is_active)
select v.k, v.f, v.t, v.a, v.n, true
  from (values
    ('order','pending','cancelled','system','CMD #1847 — unpaid at the order cut-off'),
    ('order','cancelled','pending','system','CMD #1847 — restored inside the restoration window'),
    ('order','cancelled','pending','admin','CMD #1847 — restored inside the restoration window')
  ) as v(k,f,t,a,n)
 where not exists (select 1 from public.order_state_transitions t
                    where t.entity_kind = v.k and t.from_state = v.f
                      and t.to_state = v.t and t.actor_role = v.a);

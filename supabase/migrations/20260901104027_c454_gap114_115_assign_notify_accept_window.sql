-- CMD #454 — feature_gaps #114 and #115
--
-- #114 "The rider is never told a delivery was assigned to them": delivery_assign
--      inserted the row, wrote a delivery_events line and returned. No push, no
--      WhatsApp, no in-app signal — a new stop appeared only if the rider
--      happened to pull-to-refresh.
-- #115 "An unaccepted assignment never expires and blocks the order forever":
--      accept_status started 'pending' and nothing aged it. delivery_start_run
--      only promotes accepted stops, so an unopened stop was skipped by the trip
--      and sat pending forever while admin_delivery_queue still showed it
--      assigned.

-- ── the notification route (#114) ────────────────────────────────────────────
insert into public.wa_event_routes(event_key, label, description, audience,
                                   enabled, push_enabled, push_title, push_body,
                                   deep_link_kind)
values ('delivery_assigned', 'Delivery assigned to rider',
        'Fires the moment a stop is assigned, so the rider does not have to poll.',
        'delivery', true, true,
        'New delivery assigned', '{{pharmacy}} — {{zone}}. Open the app to accept.',
        'delivery')
on conflict (event_key) do update
  set push_enabled = true, audience = 'delivery',
      push_title = coalesce(nullif(btrim(public.wa_event_routes.push_title),''), excluded.push_title),
      push_body  = coalesce(nullif(btrim(public.wa_event_routes.push_body),''),  excluded.push_body);

insert into public.ui_copy(key, value) values
  ('delivery.assigned_inbox_title', to_jsonb('New delivery assigned'::text)),
  ('delivery.assigned_inbox_body',  to_jsonb('Open Deliveries to accept it.'::text)),
  ('delivery.accept_expired_note',  to_jsonb('Not accepted in time — released back to the queue'::text)),
  ('delivery.accept_expired_inbox_title', to_jsonb('Delivery released'::text)),
  ('delivery.accept_expired_inbox_body',  to_jsonb('You did not accept it in time, so it went back to the queue.'::text))
on conflict (key) do nothing;

create or replace function public._delivery_notify_assigned(p_delivery_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare d deliveries%rowtype; p delivery_partner_registrations%rowtype;
        v_pharm text; v_zone text; v_vars jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return; end if;
  select * into p from delivery_partner_registrations where id = d.partner_id;
  if p.id is null then return; end if;

  select coalesce(o.pharmacy_name,'') into v_pharm from orders o where o.id = d.order_id;
  select coalesce(z.name, '') into v_zone from zones z where z.id = d.zone_id;
  v_vars := jsonb_build_object('pharmacy', coalesce(v_pharm,''), 'zone', coalesce(v_zone,''));

  -- The in-app signal is the one that must never fail: it is a plain insert.
  begin
    perform public._delivery_inbox(p.user_id, p.email, 'delivery_assigned',
      public.uic('delivery.assigned_inbox_title','New delivery assigned'),
      coalesce(nullif(v_pharm,''), public.uic('delivery.assigned_inbox_body','Open Deliveries to accept it.')),
      '/delivery');
  exception when others then null;
  end;

  -- Push, then WhatsApp as the fallback. Both wrapped: a provider outage must
  -- never abort the assignment that is being notified about.
  begin
    perform public.notif_push_send('delivery_assigned', right(regexp_replace(coalesce(p.phone,''),'[^0-9]','','g'),10),
                                   p.user_id, d.order_id, v_vars, 'delivery');
  exception when others then null;
  end;

  begin
    perform public.wa_notify_event('delivery_assigned', null, v_vars,
                                   right(regexp_replace(coalesce(p.phone,''),'[^0-9]','','g'),10),
                                   d.order_id, null, null);
  exception when others then null;
  end;
end $function$;

-- ── the accept window (#115) ─────────────────────────────────────────────────
alter table public.delivery_config
  add column if not exists accept_window_min integer;
update public.delivery_config set accept_window_min = 15
 where id = 1 and accept_window_min is null;

create or replace function public.delivery_accept_expiry_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_min int; r record; v_n int := 0; v_sug jsonb;
begin
  select coalesce(accept_window_min, 15) into v_min from public.delivery_config where id = 1;
  if coalesce(v_min,0) <= 0 then
    return jsonb_build_object('ok', true, 'expired', 0, 'window_min', v_min, 'disabled', true);
  end if;

  for r in
    select d.id, d.order_id, d.partner_id
      from public.deliveries d
     where d.accept_status = 'pending'
       and d.status = 'assigned'
       and d.assigned_at is not null
       and d.assigned_at < now() - make_interval(mins => v_min)
     limit 200
  loop
    update public.deliveries
       set accept_status = 'expired', status = 'pending_reassign',
           run_id = null, partner_id = null
     where id = r.id and accept_status = 'pending';

    insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (r.id, r.order_id, r.partner_id, 'accept_expired',
            public.uic('delivery.accept_expired_note',
                       'Not accepted in time — released back to the queue'), 'system');

    begin
      perform public._delivery_inbox(
        (select user_id from public.delivery_partner_registrations where id = r.partner_id),
        null, 'delivery_accept_expired',
        public.uic('delivery.accept_expired_inbox_title','Delivery released'),
        public.uic('delivery.accept_expired_inbox_body',
                   'You did not accept it in time, so it went back to the queue.'),
        '/delivery');
    exception when others then null;
    end;

    -- re-suggest, so the released stop lands somewhere instead of idling
    begin
      v_sug := public.delivery_suggest_partner(r.order_id);
      if coalesce(v_sug->>'partner_id','') <> ''
         and (v_sug->>'partner_id')::uuid <> r.partner_id then
        perform public._delivery_assign_core(array[r.order_id],
                  (v_sug->>'partner_id')::uuid, 'accept_expiry', null);
      end if;
    exception when others then null;
    end;

    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'expired', v_n, 'window_min', v_min);
end $function$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note, base_interval_s, max_interval_s)
values ('delivery_accept_expiry', 941, 'poll',
        'select public.delivery_accept_expiry_tick()', true,
        'CMD #454 gap#115 — releases a stop the rider never accepted inside delivery_config.accept_window_min and re-suggests a partner.',
        300, 900)
on conflict (name) do update
  set work_sql = excluded.work_sql, mode = excluded.mode, note = excluded.note,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      enabled = true;

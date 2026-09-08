-- CHANGE #294 (part C) — bound the guard sweep, and seed the ledger from history
-- so it can never re-send a confirmation for an order that is already old news.

-- The sweep only chases CONFIRMATIONS THAT ARE STILL MEANINGFUL. An order-placed
-- message for an order from yesterday is noise, not a fix.
create or replace function public.wa_notify_sweep()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_fixed int := 0; v_seen int := 0;
begin
  for r in
    select o.id, o.order_code
      from orders o
     where o.created_at between now() - interval '3 hours' and now() - interval '4 minutes'
       and not exists (select 1 from wa_send_attempts a
                        where a.order_id = o.id and a.event_key = 'order_placed' and a.ok)
       and (select count(*) from wa_send_attempts a
             where a.order_id = o.id and a.event_key = 'order_placed') < 3
     order by o.created_at
     limit 25
  loop
    v_seen := v_seen + 1;
    begin
      perform public.wa_notify_customer_event(
        'order_placed', r.id, null,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
        jsonb_build_object('order_id', r.id, 'event', 'placed'));
      v_fixed := v_fixed + 1;
    exception when others then
      perform public._wa_log_attempt('order_placed', r.id, null, 'skipped', false,
                                     'sweep_error: ' || sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'checked', v_seen, 'reattempted', v_fixed);
end $$;

comment on function public.wa_notify_sweep() is
  'CHANGE #294 — no order may exist without an attempted order_placed notification. '
  'Bounded to the last 3 hours so it can never resurrect a stale confirmation. '
  'Offset schedule (never a bare */N) per the connection-exhaustion lesson.';

-- Seed the ledger from what actually happened, so day-one of the ledger is not
-- read as "nothing was ever attempted" for every order already on the books.
insert into public.wa_send_attempts(event_key, order_id, phone, path, ok, reason, created_at)
select 'order_placed', o.id,
       right(regexp_replace(m.sender_phone,'\D','','g'),10),
       'freeform',
       coalesce(m.wa_status,'') in ('sent','delivered','read','accepted'),
       'seeded_from_history: ' || coalesce(m.wa_status,'unknown')
         || coalesce(' / ' || m.wa_fail_reason, ''),
       m.created_at
  from orders o
  join whatsapp_messages m
    on m.direction = 'out'
   and regexp_replace(coalesce(m.routed_to,''),'_error$','') = 'order_notify_placed'
   and m.file_name like 'mediBO-' || o.order_code || '%'
 where o.created_at > now() - interval '30 days'
   and not exists (select 1 from wa_send_attempts a
                    where a.order_id = o.id and a.event_key = 'order_placed');

-- Anything older than the sweep window with no attempt at all is recorded as
-- "never attempted" rather than silently missing — that is the audit trail.
insert into public.wa_send_attempts(event_key, order_id, path, ok, reason, created_at)
select 'order_placed', o.id, 'skipped', false,
       'never_attempted_before_change_294', o.created_at
  from orders o
 where o.created_at between now() - interval '30 days' and now() - interval '3 hours'
   and not exists (select 1 from wa_send_attempts a
                    where a.order_id = o.id and a.event_key = 'order_placed');

-- Move the sweep off minute 7, which wa_event_autopilot_10min already owns.
do $$
begin perform cron.unschedule('wa_notify_sweep'); exception when others then null; end $$;
select cron.schedule('wa_notify_sweep', '6-59/10 * * * *', $$select public.wa_notify_sweep();$$);

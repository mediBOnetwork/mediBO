-- CMD #454 — feature_gaps #103
-- "Failed deliveries are never re-queued and never auto-RTO."
--
-- delivery_fail set next_attempt_on = tomorrow whenever the reason allowed a
-- re-attempt, and bumped attempt_no. Nothing read next_attempt_on anywhere —
-- the only delivery cron row was delivery_docs_remind — and no cap was applied
-- at any attempt count. So a failed delivery sat at status='failed' forever and
-- the rider's "will be reattempted tomorrow" was backed by nothing.

alter table public.delivery_config
  add column if not exists max_delivery_attempts integer;
update public.delivery_config set max_delivery_attempts = 3
 where id = 1 and max_delivery_attempts is null;

insert into public.ui_copy(key, value) values
  ('delivery.reattempt_queued', to_jsonb('Re-queued for another attempt'::text)),
  ('delivery.attempts_exhausted', to_jsonb('Attempt limit reached — returning to origin'::text))
on conflict (key) do nothing;

create or replace function public.delivery_reattempt_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_cap int; r record; v_sug jsonb; v_pid uuid;
  v_requeued int := 0; v_rto int := 0;
begin
  select coalesce(max_delivery_attempts, 3) into v_cap from public.delivery_config where id = 1;

  for r in
    select d.id, d.order_id, d.partner_id, coalesce(d.attempt_no,0) as attempt_no
      from public.deliveries d
     where d.status = 'failed'
       and d.next_attempt_on is not null
       and d.next_attempt_on <= (now() at time zone 'Asia/Kolkata')::date
     order by d.next_attempt_on
     limit 200
  loop
    if r.attempt_no >= v_cap then
      -- the cap the register said did not exist
      update public.deliveries
         set status = 'rto', rto_at = coalesce(rto_at, now()), next_attempt_on = null
       where id = r.id;
      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
      values (r.id, r.order_id, r.partner_id, 'rto',
              public.uic('delivery.attempts_exhausted','Attempt limit reached — returning to origin')
              || ' (' || r.attempt_no || '/' || v_cap || ')', 'system');
      v_rto := v_rto + 1;
      continue;
    end if;

    -- back into the queue: prefer the same rider, fall back to the suggestion
    v_pid := r.partner_id;
    begin
      v_sug := public.delivery_suggest_partner(r.order_id);
      if coalesce(v_sug->>'partner_id','') <> '' then
        v_pid := (v_sug->>'partner_id')::uuid;
      end if;
    exception when others then null;
    end;

    update public.deliveries
       set status = 'pending_reassign', accept_status = 'pending',
           next_attempt_on = null, fail_reason = null
     where id = r.id;

    insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (r.id, r.order_id, r.partner_id, 'reattempt',
            public.uic('delivery.reattempt_queued','Re-queued for another attempt')
            || ' (' || (r.attempt_no + 1) || '/' || v_cap || ')', 'system');

    if v_pid is not null then
      begin
        perform public._delivery_assign_core(array[r.order_id], v_pid, 'reattempt', null);
      exception when others then null;
      end;
    end if;
    v_requeued := v_requeued + 1;
  end loop;

  return jsonb_build_object('ok', true, 'requeued', v_requeued, 'auto_rto', v_rto,
                            'cap', v_cap);
end $function$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note, run_at_ist)
values ('delivery_reattempt', 942, 'poll',
        'select public.delivery_reattempt_tick()', true,
        'CMD #454 gap#103 — re-queues deliveries whose next_attempt_on has arrived and auto-RTOs past delivery_config.max_delivery_attempts.',
        '07:20:00')
on conflict (name) do update
  set work_sql = excluded.work_sql, mode = excluded.mode, note = excluded.note,
      run_at_ist = excluded.run_at_ist, enabled = true;

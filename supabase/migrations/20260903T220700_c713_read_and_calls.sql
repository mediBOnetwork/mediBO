-- CHANGE #713 (8/8) — the messages that matter, and the calls they turn into.
--
-- Two silences were invisible before this. A customer who never READ the
-- payment reminder, the delivery OTP, the sourcing result or the return
-- decision looked identical to one who read it and did nothing. And a customer
-- who RANG the zone number and got no answer left no trace at all.
--
-- Both become the same object: an open call task on the customer's thread,
-- owned by whoever owns the thread, with the masked-call button the platform
-- already has, and an outcome that has to be logged before it closes.

-- ── which outbounds are critical, as data ───────────────────────────────────
create table if not exists public.thread_critical_event (
  event_key  text primary key,
  critical_key text not null,
  copy_key   text not null,
  active     boolean not null default true
);
insert into public.thread_critical_event (event_key, critical_key, copy_key) values
  ('payment_due',      'payment_due',      'thread.critical_payment_due'),
  ('payment_utr_request','payment_due',    'thread.critical_payment_due'),
  ('delivery_otp',     'delivery_otp',     'thread.critical_delivery_otp'),
  ('sourcing_done',    'sourcing_done',    'thread.critical_sourcing_done'),
  ('return_approved',  'return_decision',  'thread.critical_return_decision'),
  ('return_rejected',  'return_decision',  'thread.critical_return_decision')
on conflict (event_key) do update
  set critical_key = excluded.critical_key,
      copy_key     = excluded.copy_key,
      active       = true;

-- ── a critical outbound becomes a message on the thread ─────────────────────
-- The trigger is on notification_log, so the conversation records what the
-- platform actually SENT rather than what a screen remembered to log. A
-- failure here must never break a send.
create or replace function public.trg_c713_critical_outbound()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_ce record; v_tid uuid; v_body text;
begin
  if new.order_id is null then return new; end if;
  if coalesce(new.status,'') not in ('sent','delivered','read') then return new; end if;

  select * into v_ce from public.thread_critical_event
   where event_key = new.event_key and active;
  if v_ce.event_key is null then return new; end if;

  begin
    v_tid := public.order_thread_ensure(new.order_id);
    if v_tid is null then return new; end if;
    -- One message per (event, order): a retry of the same reminder is the same
    -- reminder, not a second thing the customer failed to read.
    if exists (select 1 from public.order_thread_message m
                where m.thread_id = v_tid and m.critical_key = v_ce.critical_key) then
      return new;
    end if;
    v_body := coalesce(nullif(new.body,''), nullif(new.title,''),
                       public._c(v_ce.copy_key));
    perform public._thread_append(v_tid, v_body, 'system', null, null,
              public._c('thread.actor_system'), 'engine', '[]'::jsonb, v_ce.critical_key);
  exception when others then null;
  end;
  return new;
end $$;

drop trigger if exists c713_critical_outbound_trg on public.notification_log;
create trigger c713_critical_outbound_trg after insert on public.notification_log
  for each row execute function public.trg_c713_critical_outbound();

-- ── an unread critical becomes a call task ──────────────────────────────────
create or replace function public.thread_call_task_scan(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_n int := 0; v_sla public.thread_sla_config;
        v_lim int := greatest(least(coalesce(p_limit,50),200),1);
begin
  for r in
    select m.id as message_id, m.critical_key, m.created_at,
           t.id as thread_id, t.order_id, t.customer_id, t.zone_id,
           t.owner_partner_id, t.tag
      from public.order_thread_message m
      join public.order_thread t on t.id = m.thread_id
     where m.critical_key is not null
       and t.status <> 'closed'
       and not exists (select 1 from public.order_thread_read rd
                        where rd.message_id = m.id and rd.viewer_kind = 'customer')
       and not exists (select 1 from public.thread_call_task k
                        where k.thread_id = t.id
                          and k.reason_key = m.critical_key
                          and k.kind = 'unread_critical')
     order by m.created_at
     limit v_lim
  loop
    v_sla := public._thread_sla(r.tag);
    -- The window is config, in hours, per tag: a delivery OTP nobody read is
    -- urgent in a way a month-end payment reminder is not.
    continue when r.created_at > now() - make_interval(mins => (v_sla.unread_critical_hours * 60)::int);

    insert into public.thread_call_task
      (thread_id, order_id, customer_id, zone_id, partner_id, kind, reason_key,
       message_id, due_at)
    values (r.thread_id, r.order_id, r.customer_id, r.zone_id, r.owner_partner_id,
            'unread_critical', r.critical_key, r.message_id,
            public._thread_business_due(now(), v_sla.callback_sla_minutes,
              v_sla.business_start_ist, v_sla.business_end_ist))
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;

  -- A task whose message has since been read is done: the customer read it,
  -- which is what the call was for. Nobody has to close it by hand.
  update public.thread_call_task k
     set status = 'cancelled', closed_at = now()
   where k.status = 'open' and k.kind = 'unread_critical'
     and exists (select 1 from public.order_thread_read rd
                  where rd.message_id = k.message_id and rd.viewer_kind = 'customer');

  return jsonb_build_object('ok', true, 'opened', v_n);
end $$;

-- ── a missed inbound call becomes a callback task ───────────────────────────
-- call_inbound_match() already rejects a leg that matches no live masked
-- session and writes it to masked_calls with status 'rejected'. That row IS
-- the missed call: somebody rang the zone number and nothing connected them.
create or replace function public.thread_missed_call_scan(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_n int := 0; v_tid uuid; v_sla public.thread_sla_config;
        v_lim int := greatest(least(coalesce(p_limit,50),200),1);
begin
  for r in
    select c.id, c.created_at,
           right(regexp_replace(coalesce(c.raw->>'from',''), '\D','','g'), 10) as phone10
      from public.masked_calls c
     where c.direction = 'inbound'
       and c.status = 'rejected'
       and c.created_at > now() - interval '2 days'
       and coalesce(c.raw->>'c713_handled','') = ''
     order by c.created_at
     limit v_lim
  loop
    if coalesce(r.phone10,'') = '' then
      update public.masked_calls set raw = coalesce(raw,'{}'::jsonb)
             || jsonb_build_object('c713_handled','no_phone') where id = r.id;
      continue;
    end if;

    -- The caller's LATEST open thread. A customer rings about the order they
    -- are waiting on, so that is the conversation the callback belongs to —
    -- and if we cannot place them, we say so on the row rather than opening a
    -- task nobody can act on.
    select t.id into v_tid
      from public.order_thread t
      join public.pharmacy_profiles pp on pp.id = t.customer_id
     where t.status <> 'closed'
       and right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),
                 '\D','','g'), 10) = r.phone10
     order by coalesce(t.last_message_at, t.created_at) desc
     limit 1;

    if v_tid is null then
      update public.masked_calls set raw = coalesce(raw,'{}'::jsonb)
             || jsonb_build_object('c713_handled','no_thread') where id = r.id;
      continue;
    end if;

    v_sla := public._thread_sla((select tag from public.order_thread where id = v_tid));

    insert into public.thread_call_task
      (thread_id, order_id, customer_id, zone_id, partner_id, kind, reason_key, due_at)
    select v_tid, t.order_id, t.customer_id, t.zone_id, t.owner_partner_id,
           'missed_callback', 'call:' || r.id::text,
           public._thread_business_due(now(), v_sla.callback_sla_minutes,
             v_sla.business_start_ist, v_sla.business_end_ist)
      from public.order_thread t where t.id = v_tid
    on conflict do nothing;

    update public.masked_calls set raw = coalesce(raw,'{}'::jsonb)
           || jsonb_build_object('c713_handled','task') where id = r.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'opened', v_n);
end $$;

-- ── the owner's call list, with the platform's own call button ──────────────
create or replace function public.thread_call_tasks(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_s jsonb := public._thread_scope(); v_all boolean; v_zone smallint;
        v_lim int := greatest(least(coalesce(p_limit,50),200),1);
begin
  if coalesce((v_s->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('thread.err_not_yours'));
  end if;
  v_all  := (v_s->>'view') = 'admin';
  v_zone := nullif(v_s->>'zone','')::smallint;

  return jsonb_build_object(
    'ok', true,
    'title',       public._c('thread.tasks_title'),
    'empty_title', public._c('thread.tasks_empty_title'),
    'empty_note',  public._c('thread.tasks_empty_note'),
    'log_cta',     public._c('thread.task_log_cta'),
    'note_hint',   public._c('thread.task_note_hint'),
    'outcomes', coalesce((select jsonb_agg(jsonb_build_object(
                            'code', o.code, 'label', o.label, 'tone', o.tone)
                            order by o.sort)
                            from public.thread_call_outcome o where o.active), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'task_id',   k.id::text,
        'thread_id', k.thread_id::text,
        'order_id',  coalesce(k.order_id::text,''),
        'title',     case k.kind
                       when 'unread_critical' then
                         public._cf('thread.task_unread_critical', jsonb_build_object(
                           'what', coalesce((select public._c(ce.copy_key)
                                              from public.thread_critical_event ce
                                             where ce.critical_key = k.reason_key limit 1),
                                            public._c('thread.title'))))
                       else public._c('thread.task_missed_callback') end,
        'customer_label', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                     where pp.id = k.customer_id), ''),
        'order_label', coalesce((select public._cf('thread.order_label',
                                   jsonb_build_object('code', o.order_code))
                                   from public.orders o where o.id = k.order_id), ''),
        'due_label', case when k.due_at < now()
                          then public._cf('thread.task_overdue',
                                 jsonb_build_object('age', public._ist_age(k.due_at)))
                          else public._cf('thread.task_due',
                                 jsonb_build_object('at', public._ist_stamp(k.due_at))) end,
        'due_tone',  case when k.due_at < now() then 'danger' else 'warning' end,
        -- The call button is the platform's own descriptor and carries no
        -- phone number: _call_action_block decides whether this caller may
        -- ring this counterparty at all (#404).
        'call',      coalesce(public._call_action_block(
                       case when v_all then 'employee' else 'partner' end,
                       'customer', k.order_id), '{}'::jsonb))
        order by k.due_at)
        from public.thread_call_task k
       where k.status = 'open'
         and (v_all or k.zone_id = v_zone)
       limit v_lim), '[]'::jsonb));
end $$;

-- ── logging the outcome is what closes it ───────────────────────────────────
create or replace function public.thread_call_task_log(
  p_task_id bigint, p_outcome_code text, p_note text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_s jsonb := public._thread_scope(); k record; v_all boolean; v_zone smallint;
begin
  if coalesce((v_s->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('thread.err_not_yours'));
  end if;
  v_all  := (v_s->>'view') = 'admin';
  v_zone := nullif(v_s->>'zone','')::smallint;

  select * into k from public.thread_call_task where id = p_task_id and status = 'open';
  if k.id is null or not (v_all or k.zone_id = v_zone) then
    return jsonb_build_object('ok', false, 'error','task_gone',
      'message', public._c('thread.task_gone'));
  end if;
  if not exists (select 1 from public.thread_call_outcome
                  where code = p_outcome_code and active) then
    return jsonb_build_object('ok', false, 'error','bad_outcome',
      'message', public._c('thread.task_gone'));
  end if;

  update public.thread_call_task
     set status = 'done', outcome_code = p_outcome_code,
         note = nullif(btrim(coalesce(p_note,'')),''),
         logged_by = auth.uid(), logged_at = now(), closed_at = now()
   where id = p_task_id;

  -- The outcome is written INTO the conversation, so the next person to open
  -- the thread reads "we rang, no answer" instead of wondering.
  perform public._thread_append(k.thread_id,
    (select o.label from public.thread_call_outcome o where o.code = p_outcome_code)
      || case when coalesce(btrim(p_note),'') = '' then ''
              else ' — ' || btrim(p_note) end,
    'system', null, null, public._c('thread.actor_system'), 'system');

  return jsonb_build_object('ok', true, 'toast', public._c('thread.task_logged_toast'))
         || public.thread_call_tasks();
end $$;

revoke all on function public.thread_call_tasks(integer) from public;
revoke all on function public.thread_call_task_log(bigint, text, text) from public;
grant execute on function public.thread_call_tasks(integer) to authenticated, service_role;
grant execute on function public.thread_call_task_log(bigint, text, text) to authenticated, service_role;
grant execute on function public.thread_call_task_scan(integer) to service_role;
grant execute on function public.thread_missed_call_scan(integer) to service_role;

-- ── the dispatcher rows ─────────────────────────────────────────────────────
insert into public.cron_task (name, ord, mode, gate_sql, work_sql,
                              base_interval_s, max_interval_s, note, enabled)
values
  ('c713-unread-critical', 75, 'poll',
   'select exists (select 1 from public.order_thread_message m '
     'join public.order_thread t on t.id = m.thread_id '
     'where m.critical_key is not null and t.status <> ''closed'' '
     'and not exists (select 1 from public.order_thread_read r '
     'where r.message_id = m.id and r.viewer_kind = ''customer''))',
   'select public.thread_call_task_scan(50)', 300, 1800,
   'CHANGE #713 — a critical outbound (payment reminder, delivery OTP, '
   'sourcing result, return decision) the customer has not read past the '
   'tag''s window becomes a call task for the thread''s owner.', true),
  ('c713-missed-calls', 76, 'poll',
   'select exists (select 1 from public.masked_calls c where c.direction = ''inbound'' '
     'and c.status = ''rejected'' and c.created_at > now() - interval ''2 days'' '
     'and coalesce(c.raw->>''c713_handled'','''') = '''')',
   'select public.thread_missed_call_scan(50)', 60, 600,
   'CHANGE #713 — an inbound call to the zone number that connected to '
   'nothing opens a callback task on the caller''s latest open thread.', true)
on conflict (name) do update
  set mode = excluded.mode, gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      note = excluded.note, enabled = true;

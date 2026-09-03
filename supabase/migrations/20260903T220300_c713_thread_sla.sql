-- CHANGE #713 (4/8) — the clock, and what happens when it runs out.
--
-- An SLA nobody enforces is a sentence in a spec. This is the enforcement:
-- one tick, on the cron dispatcher, that turns "the partner has not answered"
-- into four things at once —
--   * the thread is escalated to the mediBO office (owner_kind flips to admin,
--     and a system message says so IN the conversation, so the customer can
--     see it was escalated rather than dropped),
--   * the office is notified,
--   * the breach appears on the exceptions console (#690) by itself and
--     disappears when the thread is answered — nobody closes it by hand,
--   * and it is written to the partner's scorecard feed (#693), which is
--     exception_scorecard_input: the same table #690 closes exceptions into,
--     so #693 reads these the moment it lands with no extra wiring.
--
-- The WhatsApp nudge rides notify_partner('partner_sla_breach'), the route
-- ops_sla_tick already uses — one escalation vocabulary, not two.

-- ── the reason, and the console feed ────────────────────────────────────────
insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind,
   action_route, sort_rank, enabled)
values
  ('thread_sla_breach', 'order_thread', 2, 0, 'zone', 'route', 'order_threads', 72, true)
on conflict (reason_code) do update
  set source_key   = excluded.source_key,
      severity     = excluded.severity,
      owner_kind   = excluded.owner_kind,
      action_kind  = excluded.action_kind,
      action_route = excluded.action_route,
      sort_rank    = excluded.sort_rank,
      enabled      = true;

insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind,
   action_route, sort_rank, enabled)
values
  ('thread_call_task_open', 'thread_call_task', 3, 0, 'zone', 'route',
   'order_threads', 71, true)
on conflict (reason_code) do update
  set source_key   = excluded.source_key,
      severity     = excluded.severity,
      owner_kind   = excluded.owner_kind,
      action_kind  = excluded.action_kind,
      action_route = excluded.action_route,
      sort_rank    = excluded.sort_rank,
      enabled      = true;

-- The row IS the unanswered thread. It stands while the customer is still
-- waiting and vanishes the moment somebody replies, because the reply clears
-- awaiting_since — the console can never disagree with the conversation.
create or replace function public._c713_thread_sla_rows()
returns table(reason_code text, ref_id text, zone_id smallint, title text,
              subtitle text, since timestamptz, supplier_key text, action_ref text)
language sql stable security definer set search_path to 'public' as $$
  select 'thread_sla_breach'::text,
         t.id::text,
         t.zone_id,
         coalesce(nullif(o.order_code,''),
                  nullif(pp.pharmacy_name,''),
                  'Thread ' || left(t.id::text, 8)),
         coalesce(nullif(pp.pharmacy_name,''), '-'),
         t.awaiting_since,
         null::text,
         coalesce(t.order_id::text, t.id::text)
    from public.order_thread t
    left join public.orders o on o.id = t.order_id
    left join public.pharmacy_profiles pp on pp.id = t.customer_id
   where t.awaiting_since is not null
     and t.status <> 'closed'
     and t.sla_due_at is not null
     and t.sla_due_at < now()

  union all
  -- A call task nobody has made. Same shape, same console, so "somebody must
  -- ring this customer" is not a second place to look.
  select 'thread_call_task_open'::text,
         k.id::text,
         k.zone_id,
         coalesce(nullif(o.order_code,''),
                  nullif(pp.pharmacy_name,''),
                  'Call ' || k.id::text),
         coalesce(nullif(pp.pharmacy_name,''), '-'),
         k.created_at,
         null::text,
         coalesce(k.order_id::text, k.thread_id::text)
    from public.thread_call_task k
    left join public.orders o on o.id = k.order_id
    left join public.pharmacy_profiles pp on pp.id = k.customer_id
   where k.status = 'open'
     and k.due_at < now()
$$;

-- ── the tick ────────────────────────────────────────────────────────────────
create or replace function public.thread_sla_tick(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r record; v_n int := 0; v_notified int := 0; v_res jsonb;
  v_sla public.thread_sla_config; v_lim int := greatest(least(coalesce(p_limit,20),100),1);
begin
  for r in
    select t.id, t.order_id, t.zone_id, t.customer_id, t.tag,
           t.owner_partner_id, t.awaiting_since, t.sla_due_at,
           o.order_code, pp.pharmacy_name
      from public.order_thread t
      left join public.orders o on o.id = t.order_id
      left join public.pharmacy_profiles pp on pp.id = t.customer_id
     where t.awaiting_since is not null
       and t.escalated_at is null
       and t.status <> 'closed'
       and t.sla_due_at is not null
       and t.sla_due_at < now()
     order by t.sla_due_at
     limit v_lim
  loop
    v_sla := public._thread_sla(r.tag);

    update public.order_thread
       set escalated_at = now(),
           owner_kind   = 'admin',
           owner_label  = public._c('thread.owner_admin'),
           updated_at   = now()
     where id = r.id;

    -- The escalation is visible IN the conversation. A customer who was
    -- waiting sees that it moved, not silence; and the partner sees, on their
    -- own screen, exactly when it left them.
    perform public._thread_append(r.id,
      public._cf('thread.escalated_system_line',
        jsonb_build_object('mins', v_sla.sla_minutes::text)),
      'system', null, null, public._c('thread.actor_system'), 'system');

    -- The office.
    begin
      v_res := public.notify('order_alert_escalation', null, jsonb_build_object(
        'order_id',   coalesce(r.order_id::text,''),
        'order_code', coalesce(r.order_code,''),
        'customer',   coalesce(r.pharmacy_name,''),
        'zone_id',    coalesce(r.zone_id,0)::text,
        'reason',     public._c('thread.inbox_breached'),
        'age',        public._ist_age(r.awaiting_since)));
      if coalesce((v_res->>'ok')::boolean,false) then v_notified := v_notified + 1; end if;
    exception when others then null;
    end;

    -- The nudge, on the route the ops SLA already uses.
    if v_sla.escalate_wa_nudge then
      begin
        perform public.notify_partner('partner_sla_breach', jsonb_build_object(
          'order_id',    coalesce(r.order_id::text,''),
          'order_code',  coalesce(r.order_code,''),
          'customer',    coalesce(r.pharmacy_name,''),
          'zone_id',     coalesce(r.zone_id,0)::text,
          'stage',       public._c('thread.title'),
          'next_action', public._c('thread.inbox_waiting'),
          'overdue',     public._ist_age(r.sla_due_at)));
      exception when others then null;
      end;
    end if;

    -- The scorecard feed. subject_kind 'partner' with the partner's own id,
    -- weight from the reason's severity so #693 does not have to invent one.
    if r.owner_partner_id is not null then
      begin
        insert into public.exception_scorecard_input
          (subject_kind, subject_key, reason_code, outcome_code, weight,
           exception_id, zone_id, closed_at, closed_by)
        values ('partner', r.owner_partner_id::text, 'thread_sla_breach',
                'thread_sla_breach',
                (select severity from public.exception_reason
                  where reason_code = 'thread_sla_breach'),
                'thread_sla_breach:' || r.id::text, r.zone_id, now(), 'engine');
      exception when others then null;
      end;
    end if;

    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'escalated', v_n, 'notified', v_notified);
end $$;

revoke all on function public.thread_sla_tick(integer) from public;
grant execute on function public.thread_sla_tick(integer) to service_role;

-- ── the dispatcher row ──────────────────────────────────────────────────────
-- Gated, so a quiet queue costs one cheap EXISTS rather than the whole tick,
-- and NEVER on a bare */N schedule: the one dispatcher runs it (#273).
insert into public.cron_task (name, ord, mode, gate_sql, work_sql,
                              base_interval_s, max_interval_s, note, enabled)
values ('c713-thread-sla', 74, 'poll',
        'select exists (select 1 from public.order_thread where awaiting_since is not null '
          'and escalated_at is null and status <> ''closed'' and sla_due_at < now())',
        'select public.thread_sla_tick(20)',
        60, 900,
        'CHANGE #713 — a customer message the zone partner has not answered '
        'inside the tag''s SLA escalates to the office, nudges the partner on '
        'WhatsApp, shows on the exceptions console and feeds the partner scorecard.',
        true)
on conflict (name) do update
  set mode = excluded.mode, gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      note = excluded.note, enabled = true;

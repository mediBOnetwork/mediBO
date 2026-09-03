-- CHANGE #713 (7/8) — the ticket's conversation moves into the thread.
--
-- support_ticket_message is retired as a WRITE target. Its four rows are
-- copied into order_thread_message and the three ticket RPCs re-pointed, so
-- the ticket and the order thread cannot drift: there is one store, and both
-- surfaces read it.
--
-- The ticket row itself stays, and stays useful: the reference the customer
-- quotes, the status they see, the topic they picked. What it loses is a
-- private copy of what was said.

-- ── every ticket gets its thread, and its history moves ─────────────────────
do $$
declare r record; v_tid uuid; v_zone smallint; v_tag text;
begin
  for r in select * from public.support_ticket order by created_at loop
    if r.thread_id is not null then continue; end if;

    if r.order_id is not null then
      v_tid := public.order_thread_ensure(r.order_id);
    else
      -- A ticket that names no order still gets a conversation of its own.
      select o.zone_id into v_zone from public.orders o
       where o.customer_id = r.customer_id order by o.created_at desc limit 1;
      insert into public.order_thread (customer_id, zone_id, partner_id, tag)
      values (r.customer_id, v_zone, public._thread_zone_partner(v_zone), 'other')
      returning id into v_tid;
    end if;

    select t.tag into v_tag from public.support_topic t where t.code = r.topic_code;

    update public.support_ticket
       set thread_id = v_tid,
           zone_id   = coalesce(zone_id,
                        (select o.zone_id from public.orders o where o.id = r.order_id)),
           owner_partner_id = coalesce(owner_partner_id,
                        (select ot.owner_partner_id from public.order_thread ot where ot.id = v_tid))
     where id = r.id;

    update public.order_thread
       set tag = coalesce(v_tag, tag, 'other')
     where id = v_tid;
  end loop;
end $$;

-- The history. wa_message_id is null on all of these, so the partial unique
-- index cannot swallow them; the guard against a second run is the NOT EXISTS.
insert into public.order_thread_message
  (thread_id, ticket_id, body, actor_role, actor_id, actor_label, source, created_at)
select st.thread_id, m.ticket_id, m.body,
       case when m.sender_role = 'customer' then 'customer' else 'admin' end,
       m.sender_id,
       case when m.sender_role = 'customer' then '' else public._c('thread.actor_admin') end,
       'ticket', m.created_at
  from public.support_ticket_message m
  join public.support_ticket st on st.id = m.ticket_id
 where st.thread_id is not null
   and not exists (select 1 from public.order_thread_message x
                    where x.ticket_id = m.ticket_id
                      and x.created_at = m.created_at
                      and x.body = m.body);

-- The threads that just inherited history need their own summary state.
update public.order_thread t
   set last_message_at = s.at,
       last_actor_role = s.role,
       updated_at      = now()
  from (select m.thread_id, max(m.created_at) as at,
               (array_agg(m.actor_role order by m.created_at desc))[1] as role
          from public.order_thread_message m group by m.thread_id) s
 where s.thread_id = t.id
   and t.last_message_at is distinct from s.at;

-- ── the three ticket RPCs, re-pointed ───────────────────────────────────────
create or replace function public.support_ticket_open(
  p_topic_code text, p_message text, p_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_ref text; v_cust uuid; t public.support_ticket%rowtype;
        v_tid uuid; v_zone smallint; v_tag text; v_actor jsonb;
begin
  if p_order_id is not null and not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('support.err_not_your_order'));
  end if;
  if nullif(btrim(coalesce(p_message,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'message_required',
      'message', public._c('support.err_message_required'));
  end if;
  if not exists (select 1 from public.support_topic where code = p_topic_code and active) then
    return jsonb_build_object('ok', false, 'error', 'topic_unknown',
      'message', public._c('support.err_topic_unknown'));
  end if;

  v_cust := public.my_customer_id();
  v_ref  := public._support_next_ref();
  select s.tag into v_tag from public.support_topic s where s.code = p_topic_code;

  -- One conversation per order: a ticket on an order joins the order's thread
  -- rather than starting a second place to look.
  if p_order_id is not null then
    v_tid := public.order_thread_ensure(p_order_id);
    select o.zone_id into v_zone from public.orders o where o.id = p_order_id;
  else
    select o.zone_id into v_zone from public.orders o
     where o.customer_id = v_cust order by o.created_at desc limit 1;
    insert into public.order_thread (customer_id, zone_id, partner_id, tag)
    values (v_cust, v_zone, public._thread_zone_partner(v_zone), coalesce(v_tag,'other'))
    returning id into v_tid;
  end if;

  -- The tag follows the topic the customer just picked: the SLA is per tag, so
  -- a billing question opened on a delivery thread is policed as billing.
  update public.order_thread set tag = coalesce(v_tag, tag, 'other') where id = v_tid;

  insert into public.support_ticket
    (ref, customer_id, user_id, order_id, topic_code, thread_id, zone_id, owner_partner_id)
  values (v_ref, v_cust, auth.uid(), p_order_id, p_topic_code, v_tid, v_zone,
          (select ot.owner_partner_id from public.order_thread ot where ot.id = v_tid))
  returning id into v_id;

  v_actor := public._thread_actor();
  perform public._thread_append(v_tid, p_message, 'customer', auth.uid(), null,
            v_actor->>'label', 'ticket', '[]'::jsonb);
  update public.order_thread_message
     set ticket_id = v_id
   where thread_id = v_tid and ticket_id is null and actor_role = 'customer'
     and created_at = (select max(created_at) from public.order_thread_message
                        where thread_id = v_tid);

  update public.support_ticket
     set owner_partner_id = (select ot.owner_partner_id from public.order_thread ot
                              where ot.id = v_tid)
   where id = v_id;

  select * into t from public.support_ticket where id = v_id;
  return jsonb_build_object('ok', true, 'toast', public._c('support.opened_toast'),
                            'thread_id', v_tid::text,
                            'ticket', public._support_ticket_row(t, false));
end $$;

create or replace function public.support_ticket_reply(p_ticket_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_admin boolean := public._is_admin(); v_role text; v_tid uuid;
        v_actor jsonb; v_msg uuid;
begin
  if not public._support_can_see(p_ticket_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_ticket',
      'message', public._c('support.err_not_your_ticket'));
  end if;
  if nullif(btrim(coalesce(p_body,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'message_required',
      'message', public._c('support.err_message_required'));
  end if;

  select thread_id into v_tid from public.support_ticket where id = p_ticket_id;
  v_actor := public._thread_actor();
  -- 'support' was the ticket's own word for our side. The thread's actor_role
  -- is the real one, so a partner reply is a partner reply and the customer's
  -- view still calls both "mediBO".
  v_role := v_actor->>'role';
  if v_role = 'customer' and v_admin then v_role := 'admin'; end if;

  if v_tid is not null then
    v_msg := public._thread_append(v_tid, p_body, v_role, auth.uid(),
               nullif(v_actor->>'partner_id','')::bigint, v_actor->>'label', 'ticket');
    if v_msg is not null then
      update public.order_thread_message set ticket_id = p_ticket_id where id = v_msg;
    end if;
  end if;

  update public.support_ticket
     set updated_at = now(),
         last_reply_by = case when v_role = 'customer' then 'customer' else 'support' end,
         status = case when coalesce(status,'open') = 'closed' then 'open'
                       when v_role <> 'customer' then 'answered' else 'open' end,
         unread_for_admin    = (v_role = 'customer'),
         unread_for_customer = (v_role <> 'customer'),
         closed_at = case when coalesce(status,'open') = 'closed' then null else closed_at end
   where id = p_ticket_id;

  return jsonb_build_object('ok', true, 'toast', public._c('support.replied_toast'))
         || public.support_ticket_thread(p_ticket_id);
end $$;

create or replace function public.support_ticket_thread(p_ticket_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t public.support_ticket%rowtype; v_admin boolean := public._is_admin();
        v_view text;
begin
  if not public._support_can_see(p_ticket_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_ticket',
      'message', public._c('support.err_not_your_ticket'));
  end if;
  select * into t from public.support_ticket where id = p_ticket_id;

  if v_admin then
    update public.support_ticket set unread_for_admin = false where id = p_ticket_id;
  else
    update public.support_ticket set unread_for_customer = false where id = p_ticket_id;
  end if;

  v_view := case when t.thread_id is null then (case when v_admin then 'admin' else 'customer' end)
                 else coalesce(nullif(public._thread_view(t.thread_id),''),
                               case when v_admin then 'admin' else 'customer' end) end;
  if t.thread_id is not null then
    perform public._thread_mark_read(t.thread_id, v_view);
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',      public._c('support.thread_title'),
    'reply_hint', public._c('support.reply_hint'),
    'reply_cta',  public._c('support.reply_cta'),
    'close_cta',  public._c('support.close_cta'),
    'reopen_cta', public._c('support.reopen_cta'),
    'can_close',  (coalesce(t.status,'open') <> 'closed'),
    'can_reopen', (coalesce(t.status,'open') = 'closed'),
    'thread_id',  coalesce(t.thread_id::text,''),
    'ticket',     public._support_ticket_row(t, v_admin),
    -- The ONE store. A message that arrived on WhatsApp, or on the order
    -- thread, is part of this ticket's conversation now — which is the whole
    -- point of the change.
    'messages', coalesce((select jsonb_agg(public._thread_msg_row(m, v_view)
                                    order by m.created_at, m.id)
                            from public.order_thread_message m
                           where t.thread_id is not null and m.thread_id = t.thread_id), '[]'::jsonb));
end $$;

-- ── support_inbox: zone-scoped for partners, all zones for the office ───────
-- Same shape as before, so the admin screen that reads it is untouched. What
-- changes is who may call it and what they see.
create or replace function public.support_inbox(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_s jsonb := public._thread_scope(); v_all boolean; v_zone smallint;
begin
  if coalesce((v_s->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  v_all  := (v_s->>'view') = 'admin';
  v_zone := nullif(v_s->>'zone','')::smallint;

  return jsonb_build_object(
    'ok', true,
    'title',       public._c('support.admin_title'),
    'zone_label',  coalesce(v_s->>'zone_label',''),
    'empty_title', public._c('support.admin_empty_title'),
    'empty_note',  public._c('support.admin_empty_note'),
    'filters', jsonb_build_array(
      jsonb_build_object('key','open',    'label','Open'),
      jsonb_build_object('key','answered','label','Answered'),
      jsonb_build_object('key','closed',  'label','Sorted'),
      jsonb_build_object('key','',        'label','All')),
    'open_count', (select count(*) from public.support_ticket t
                    where t.status = 'open'
                      and (v_all or coalesce(t.zone_id, -1) = v_zone)),
    'tickets', coalesce((select jsonb_agg(public._support_ticket_row(t, true)
                                  order by t.updated_at desc)
                           from public.support_ticket t
                          where (v_all or coalesce(t.zone_id, -1) = v_zone)
                            and (nullif(btrim(coalesce(p_status,'')),'') is null
                                 or t.status = p_status)), '[]'::jsonb));
end $$;

grant execute on function public.support_inbox(text) to authenticated, service_role;

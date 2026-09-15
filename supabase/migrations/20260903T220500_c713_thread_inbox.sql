-- CHANGE #713 (6/8) — a ticket IS a thread, and the inbox is zone-scoped.
--
-- support_ticket keeps what only a ticket has: a reference a customer can
-- quote, a status they can see, and a topic. What it stops having is its own
-- private copy of the conversation. support_ticket_message rows are moved into
-- order_thread_message and the three ticket RPCs are re-pointed at the one
-- store, so a customer who wrote on WhatsApp, opened a ticket and typed in the
-- app is ONE conversation on every screen instead of three.
--
-- The inbox is the same clamp every partner surface already has: a partner
-- reads its own zone, the office reads all of them, and the clamp is the zone
-- on the row rather than a filter the screen passes in.

-- ── who may read an inbox, and over which zone ──────────────────────────────
create or replace function public._thread_scope()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pid bigint; v_zone smallint;
begin
  if public._is_admin() or public._is_service_role() then
    return jsonb_build_object('ok', true, 'view','admin', 'zone', null,
      'zone_label', public._c('thread.inbox_zone_all'));
  end if;
  v_pid := public.my_partner_id();
  if v_pid is not null then
    select rp.zone_id::smallint into v_zone from public.region_partners rp where rp.id = v_pid;
    return jsonb_build_object('ok', true, 'view','partner', 'zone', v_zone,
      'zone_label', coalesce((select z.name from public.zones z where z.id = v_zone), ''));
  end if;
  return jsonb_build_object('ok', false, 'view','', 'zone', null);
end $$;

-- ── one row of the inbox ────────────────────────────────────────────────────
create or replace function public._thread_inbox_row(t public.order_thread)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'thread_id',   t.id::text,
    'order_id',    coalesce(t.order_id::text,''),
    'title',       coalesce(
                     (select public._cf('thread.order_label',
                        jsonb_build_object('code', o.order_code))
                        from public.orders o where o.id = t.order_id),
                     public._c('thread.title')),
    'customer_label', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                 where pp.id = t.customer_id), ''),
    'tag',         coalesce(t.tag,''),
    'tag_label',   coalesce((select g.label from public.thread_topic_tag g where g.tag = t.tag), ''),
    'tag_tone',    coalesce((select g.tone  from public.thread_topic_tag g where g.tag = t.tag), 'info'),
    'status',      t.status,
    'status_label',case t.status when 'open' then public._c('thread.status_open')
                                 when 'answered' then public._c('thread.status_answered')
                                 else public._c('thread.status_closed') end,
    'status_tone', case t.status when 'open' then 'warning'
                                 when 'answered' then 'success' else 'info' end,
    'owner_label', coalesce(nullif(t.owner_label,''), public._c('thread.owner_none')),
    'sla_label',   case
                     when t.awaiting_since is null then public._c('thread.sla_clear')
                     when t.escalated_at is not null
                       then public._cf('thread.sla_escalated',
                              jsonb_build_object('age', public._ist_age(t.awaiting_since)))
                     when t.sla_due_at < now()
                       then public._cf('thread.sla_breached',
                              jsonb_build_object('age', public._ist_age(t.sla_due_at)))
                     else public._cf('thread.sla_due',
                              jsonb_build_object('at', public._ist_stamp(t.sla_due_at)))
                   end,
    'sla_tone',    case
                     when t.awaiting_since is null then 'success'
                     when t.escalated_at is not null then 'danger'
                     when t.sla_due_at < now() then 'danger' else 'warning' end,
    'last_line',   coalesce((select m.body from public.order_thread_message m
                              where m.thread_id = t.id
                              order by m.created_at desc, m.id desc limit 1), ''),
    'last_by',     case when coalesce(t.last_actor_role,'') = 'customer'
                        then public._c('thread.last_by_customer')
                        when coalesce(t.last_actor_role,'') = '' then ''
                        else public._c('thread.last_by_us') end,
    'at_label',    case when t.last_message_at is null then ''
                        else public._ist_stamp(t.last_message_at) end,
    'unread',      (select count(*) from public.order_thread_message m
                     where m.thread_id = t.id and m.actor_role = 'customer'
                       and not exists (select 1 from public.order_thread_read r
                                        where r.message_id = m.id
                                          and r.viewer_kind in ('partner','admin'))),
    'ticket_ref',  coalesce((select st.ref from public.support_ticket st
                              where st.thread_id = t.id and st.status <> 'closed'
                              order by st.created_at desc limit 1), ''));
$$;

-- ── the inbox ───────────────────────────────────────────────────────────────
create or replace function public.thread_inbox(
  p_filter text default '', p_tag text default '', p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_s jsonb := public._thread_scope(); v_zone smallint; v_all boolean;
  v_f text := lower(coalesce(nullif(btrim(p_filter),''),''));
  v_tag text := coalesce(nullif(btrim(p_tag),''),'');
  v_lim int := greatest(least(coalesce(p_limit,100), 300), 1);
begin
  if coalesce((v_s->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('thread.err_not_yours'));
  end if;
  v_all  := (v_s->>'view') = 'admin';
  v_zone := nullif(v_s->>'zone','')::smallint;

  return jsonb_build_object(
    'ok', true,
    'view',        v_s->>'view',
    'title',       public._c('thread.inbox_title'),
    'zone_label',  coalesce(v_s->>'zone_label',''),
    'empty_title', public._c('thread.inbox_empty_title'),
    'empty_note',  public._c('thread.inbox_empty_note'),
    'filter',      v_f,
    'tag',         v_tag,
    'filters', jsonb_build_array(
      jsonb_build_object('key','waiting',  'label', public._c('thread.inbox_waiting'),
        'count', (select count(*) from public.order_thread t
                   where (v_all or t.zone_id = v_zone)
                     and t.awaiting_since is not null and t.status <> 'closed')),
      jsonb_build_object('key','breached', 'label', public._c('thread.inbox_breached'),
        'count', (select count(*) from public.order_thread t
                   where (v_all or t.zone_id = v_zone)
                     and t.awaiting_since is not null and t.status <> 'closed'
                     and t.sla_due_at is not null and t.sla_due_at < now())),
      jsonb_build_object('key','answered', 'label', public._c('thread.inbox_answered'),
        'count', (select count(*) from public.order_thread t
                   where (v_all or t.zone_id = v_zone) and t.status = 'answered')),
      jsonb_build_object('key','',         'label', public._c('thread.inbox_all'),
        'count', (select count(*) from public.order_thread t
                   where (v_all or t.zone_id = v_zone)
                     and exists (select 1 from public.order_thread_message m
                                  where m.thread_id = t.id)))),
    'tags', coalesce((select jsonb_agg(jsonb_build_object(
                        'key', g.tag, 'label', g.label, 'tone', g.tone) order by g.sort)
                        from public.thread_topic_tag g where g.active), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(public._thread_inbox_row(t)
                              order by (t.awaiting_since is null),
                                       t.sla_due_at nulls last,
                                       t.last_message_at desc nulls last)
                        from public.order_thread t
                       where (v_all or t.zone_id = v_zone)
                         and (v_tag = '' or t.tag = v_tag)
                         and case v_f
                               when 'waiting'  then t.awaiting_since is not null and t.status <> 'closed'
                               when 'breached' then t.awaiting_since is not null and t.status <> 'closed'
                                                    and t.sla_due_at is not null and t.sla_due_at < now()
                               when 'answered' then t.status = 'answered'
                               when 'closed'   then t.status = 'closed'
                               else exists (select 1 from public.order_thread_message m
                                             where m.thread_id = t.id)
                             end
                       limit v_lim), '[]'::jsonb));
end $$;

-- ── close / reopen a conversation ───────────────────────────────────────────
create or replace function public.thread_set_status(p_thread_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_view text := public._thread_view(p_thread_id);
begin
  if v_view = '' then
    return jsonb_build_object('ok', false, 'error','not_your_thread',
      'message', public._c('thread.err_not_yours'));
  end if;
  if coalesce(p_status,'') not in ('open','answered','closed') then
    return jsonb_build_object('ok', false, 'error','bad_status',
      'message', public._c('thread.err_no_thread'));
  end if;
  update public.order_thread
     set status = p_status,
         awaiting_since = case when p_status = 'closed' then null else awaiting_since end,
         sla_due_at     = case when p_status = 'closed' then null else sla_due_at end,
         updated_at = now()
   where id = p_thread_id;
  -- Closing the conversation closes the tickets that live on it: two words for
  -- one state is how a customer ends up reading "open" on a sorted matter.
  if p_status = 'closed' then
    update public.support_ticket
       set status = 'closed', closed_at = now(), updated_at = now()
     where thread_id = p_thread_id and status <> 'closed';
    update public.thread_call_task
       set status = 'cancelled', closed_at = now()
     where thread_id = p_thread_id and status = 'open';
  end if;
  return jsonb_build_object('ok', true) || public.order_thread_get(null, p_thread_id);
end $$;

-- ── the nav badge ───────────────────────────────────────────────────────────
create or replace function public._thread_badge_count()
returns bigint language plpgsql stable security definer set search_path to 'public' as $$
declare v_s jsonb := public._thread_scope();
begin
  if coalesce((v_s->>'ok')::boolean,false) is not true then return 0; end if;
  return (select count(*) from public.order_thread t
           where t.awaiting_since is not null and t.status <> 'closed'
             and ((v_s->>'view') = 'admin' or t.zone_id = nullif(v_s->>'zone','')::smallint));
end $$;

create or replace function public.nav_badge_counts()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'pending_orders',     (select count(*) from orders where status = 'pending'),
    'flagged_bills',      (select count(*) from pending_bills where verdict in ('needs_approval','fake')),
    'pending_customers',  (select count(*) from pharmacy_profiles where coalesce(approved,false) = false),
    'deletion_requests',  (select count(*) from account_deletion_requests where status = 'pending'),
    'order_alerts',       (select count(*) from order_alert where actioned_at is null),
    'disputes',           (select count(*) from supplier_disputes where coalesce(status,'open') = 'open'),
    'contact_inquiries',  (select count(*) from contact_inquiries),
    -- CHANGE #713 — customer messages waiting on an answer, in the caller's
    -- own zone (all zones for the office). The count is the same clamp the
    -- inbox uses, so the badge can never promise work the screen then hides.
    'customer_threads',   public._thread_badge_count()
  );
$$;

revoke all on function public.thread_inbox(text, text, integer) from public;
revoke all on function public.thread_set_status(uuid, text) from public;
grant execute on function public.thread_inbox(text, text, integer) to authenticated, service_role;
grant execute on function public.thread_set_status(uuid, text) to authenticated, service_role;

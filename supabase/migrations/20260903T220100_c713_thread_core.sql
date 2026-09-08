-- CHANGE #713 (2/8) — the conversation: read it, write to it, own it.
--
-- Every string on both screens is built here. The customer's view calls the
-- partner and the admin by ONE name because this file collapses the two roles
-- into the brand's own word — the client never learns there were two.
--
-- Ownership is assigned at WRITE time, not by a nightly job: the moment a
-- customer speaks, the thread's owner is the active partner of the order's
-- zone and the clock starts. That is the difference between "somebody should
-- answer this" and "this is yours, by this time".

-- ── who is the caller, on this thread ───────────────────────────────────────
create or replace function public._thread_actor()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pid bigint; v_name text;
begin
  if public._is_admin() then
    return jsonb_build_object('role','admin','id', auth.uid(),
      'partner_id', null, 'label', public._c('thread.actor_admin'));
  end if;
  v_pid := public.my_partner_id();
  if v_pid is not null then
    select rp.partner_name into v_name from public.region_partners rp where rp.id = v_pid;
    return jsonb_build_object('role','partner','id', auth.uid(),
      'partner_id', v_pid, 'label', coalesce(nullif(v_name,''), public._c('thread.actor_partner')));
  end if;
  select pp.pharmacy_name into v_name
    from public.pharmacy_profiles pp where pp.id = public.my_customer_id();
  return jsonb_build_object('role','customer','id', auth.uid(),
    'partner_id', null, 'label', coalesce(nullif(v_name,''), public._c('thread.actor_customer')));
end $$;

-- ── the zone's partner ──────────────────────────────────────────────────────
create or replace function public._thread_zone_partner(p_zone smallint)
returns bigint language sql stable security definer set search_path to 'public' as $$
  select rp.id from public.region_partners rp
   where rp.zone_id = p_zone and rp.is_active and rp.suspended_at is null
   order by rp.id limit 1;
$$;

-- ── the SLA row for a tag, with '' as the fallback ──────────────────────────
create or replace function public._thread_sla(p_tag text)
returns public.thread_sla_config language sql stable security definer
set search_path to 'public' as $$
  select (r).* from (
    select c as r, case when c.tag = coalesce(nullif(p_tag,''),'') then 0 else 1 end as rank
      from public.thread_sla_config c
     where c.enabled and c.tag in (coalesce(nullif(p_tag,''),''), '')
     order by 2 limit 1) s;
$$;

-- ── "30 minutes" means 30 WORKING minutes, in IST ───────────────────────────
-- A customer who writes at 22:40 is not owed an answer at 23:10. The clock
-- starts at the next opening and only ever counts time inside the window, so
-- the promise the copy makes is the promise the tick enforces.
create or replace function public._thread_business_due(
  p_from timestamptz, p_minutes integer, p_start time, p_end time)
returns timestamptz language plpgsql immutable set search_path to 'public' as $$
declare
  v_left  numeric := greatest(coalesce(p_minutes,0), 0);
  v_ist   timestamp := (p_from at time zone 'Asia/Kolkata');
  v_day   date;
  v_open  timestamp; v_close timestamp; v_avail numeric;
  v_guard int := 0;
begin
  if v_left = 0 then return p_from; end if;
  -- A window that is empty or inverted means "always open": the promise is
  -- then wall-clock, which is a legitimate config, not an error to raise.
  if p_start >= p_end then
    return p_from + make_interval(mins => v_left::int);
  end if;
  v_day := v_ist::date;
  loop
    v_guard := v_guard + 1;
    exit when v_guard > 14;
    v_open  := v_day + p_start;
    v_close := v_day + p_end;
    if v_ist < v_open then v_ist := v_open; end if;
    if v_ist < v_close then
      v_avail := extract(epoch from (v_close - v_ist)) / 60.0;
      if v_left <= v_avail then
        return ((v_ist + make_interval(mins => v_left::int)) at time zone 'Asia/Kolkata');
      end if;
      v_left := v_left - v_avail;
    end if;
    v_day := v_day + 1;
    v_ist := v_day + p_start;
  end loop;
  -- Fourteen closed days is not a promise anybody can keep; hand back the
  -- wall-clock answer rather than a null the tick would have to guess about.
  return p_from + make_interval(mins => coalesce(p_minutes,0));
end $$;

-- ── one thread per order, created on demand and by trigger ──────────────────
create or replace function public.order_thread_ensure(p_order_id uuid)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; o record; v_tag text;
begin
  if p_order_id is null then return null; end if;
  select id into v_id from public.order_thread where order_id = p_order_id;
  if v_id is not null then return v_id; end if;

  select o2.id, o2.customer_id, o2.zone_id into o
    from public.orders o2 where o2.id = p_order_id;
  if o.id is null then return null; end if;

  select t.tag into v_tag from public.support_ticket st
    join public.support_topic t on t.code = st.topic_code
   where st.order_id = p_order_id order by st.created_at desc limit 1;

  insert into public.order_thread (order_id, customer_id, zone_id, partner_id, tag)
  values (p_order_id, o.customer_id, o.zone_id,
          public._thread_zone_partner(o.zone_id), coalesce(v_tag,'other'))
  on conflict (order_id) where order_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.order_thread where order_id = p_order_id;
  end if;
  return v_id;
end $$;

-- Auto-created, so "one conversation per order" is true of an order placed a
-- second ago and not only of one somebody opened a sheet on. A failure here
-- must never block an order being placed.
create or replace function public.trg_c713_order_thread()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.order_thread_ensure(new.id);
  exception when others then null;
  end;
  return new;
end $$;

drop trigger if exists c713_order_thread_trg on public.orders;
create trigger c713_order_thread_trg after insert on public.orders
  for each row execute function public.trg_c713_order_thread();

-- Backfill: every order that already exists gets its thread, so the inbox is
-- not empty for history. 37 orders today — a set-based insert, no batching.
insert into public.order_thread (order_id, customer_id, zone_id, partner_id, tag)
select o.id, o.customer_id, o.zone_id, public._thread_zone_partner(o.zone_id), 'other'
  from public.orders o
 where not exists (select 1 from public.order_thread t where t.order_id = o.id)
on conflict do nothing;

-- ── what a message looks like to whoever is reading it ──────────────────────
-- The customer sees ONE counterparty. That collapse is made here: partner and
-- admin both render as the brand's own name, so no client has to know that
-- two different logins answered.
create or replace function public._thread_msg_row(m public.order_thread_message, p_view text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'id',        m.id::text,
    'body',      m.body,
    'role',      m.actor_role,
    'mine',      case
                   when p_view = 'customer' then m.actor_role = 'customer'
                   when p_view = 'partner'  then m.actor_role in ('partner','admin')
                   else m.actor_role in ('admin','partner')
                 end,
    'who_label', case
                   when p_view = 'customer' and m.actor_role = 'customer'
                     then public._c('thread.you')
                   when p_view = 'customer'
                     then public._c('thread.brand')
                   when m.actor_role = 'customer'
                     then coalesce(nullif(m.actor_label,''), public._c('thread.actor_customer'))
                   when m.actor_role = 'system'
                     then public._c('thread.actor_system')
                   else coalesce(nullif(m.actor_label,''), public._c('thread.brand'))
                 end,
    'at_label',  public._ist_stamp(m.created_at),
    'source',    m.source,
    'source_label', case when m.source = 'whatsapp'
                         then public._c('thread.via_whatsapp') else '' end,
    'is_critical',  (m.critical_key is not null),
    'read_label', case
                    when p_view = 'customer' or m.actor_role = 'customer' then ''
                    when exists (select 1 from public.order_thread_read r
                                  where r.message_id = m.id and r.viewer_kind = 'customer')
                      then public._c('thread.read')
                    else public._c('thread.unread')
                  end,
    'attachments', coalesce((select jsonb_agg(jsonb_build_object(
                        'name',     coalesce(a->>'name',''),
                        'bucket',   coalesce(a->>'bucket',''),
                        'path',     coalesce(a->>'path',''),
                        'is_image', coalesce(a->>'mime','') like 'image/%',
                        'open_label', public._c('thread.attach_open'))
                      ) from jsonb_array_elements(m.attachments) a), '[]'::jsonb));
$$;

-- ── may the caller see this thread, and as whom ─────────────────────────────
create or replace function public._thread_view(p_thread_id uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare t record; v_pid bigint;
begin
  select ot.id, ot.customer_id, ot.zone_id, ot.order_id into t
    from public.order_thread ot where ot.id = p_thread_id;
  if t.id is null then return ''; end if;
  if public._is_admin() or public._is_service_role() then return 'admin'; end if;
  v_pid := public.my_partner_id();
  if v_pid is not null then
    -- A partner reads its OWN zone and nothing else. The clamp is the zone on
    -- the thread, not a filter the screen passes in.
    if exists (select 1 from public.region_partners rp
                where rp.id = v_pid and rp.zone_id = t.zone_id) then
      return 'partner';
    end if;
    return '';
  end if;
  if t.customer_id is not null and t.customer_id = public.my_customer_id() then
    return 'customer';
  end if;
  if t.order_id is not null and public._order_is_mine(t.order_id) then
    return 'customer';
  end if;
  return '';
end $$;

-- ── mark read, for the side that is looking ─────────────────────────────────
create or replace function public._thread_mark_read(p_thread_id uuid, p_view text)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_n integer := 0;
begin
  insert into public.order_thread_read (message_id, viewer_kind, viewer_id, read_at)
  select m.id, p_view,
         coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid), now()
    from public.order_thread_message m
   where m.thread_id = p_thread_id
     -- The customer's side reads what the OTHER side wrote, and vice versa.
     -- Nobody is credited with reading their own message here; _thread_append
     -- does that for the writer.
     and case when p_view = 'customer' then m.actor_role <> 'customer'
              else m.actor_role = 'customer' end
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ── READ the conversation ───────────────────────────────────────────────────
create or replace function public.order_thread_get(
  p_order_id uuid default null, p_thread_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id uuid := p_thread_id; v_view text; t record; v_sla public.thread_sla_config;
  v_unread int;
begin
  if v_id is null and p_order_id is not null then
    -- Ensuring is safe for a customer: it is their own order, and the ensure
    -- itself refuses an order that does not exist.
    if not (public._is_admin() or public._is_service_role()
            or public.my_partner_id() is not null
            or public._order_is_mine(p_order_id)) then
      return jsonb_build_object('ok', false, 'error','not_your_order',
        'message', public._c('thread.err_not_yours'));
    end if;
    v_id := public.order_thread_ensure(p_order_id);
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error','no_thread',
      'message', public._c('thread.err_no_thread'));
  end if;

  v_view := public._thread_view(v_id);
  if v_view = '' then
    return jsonb_build_object('ok', false, 'error','not_your_thread',
      'message', public._c('thread.err_not_yours'));
  end if;

  select * into t from public.order_thread where id = v_id;
  v_sla := public._thread_sla(t.tag);

  perform public._thread_mark_read(v_id, v_view);

  select count(*) into v_unread
    from public.order_thread_message m
   where m.thread_id = v_id and m.actor_role = 'customer'
     and not exists (select 1 from public.order_thread_read r
                      where r.message_id = m.id and r.viewer_kind in ('partner','admin'));

  return jsonb_build_object(
    'ok', true,
    'thread_id',   t.id::text,
    'view',        v_view,
    'title',       public._c('thread.title'),
    'order_id',    coalesce(t.order_id::text,''),
    'order_label', coalesce((select public._cf('thread.order_label',
                               jsonb_build_object('code', o.order_code))
                               from public.orders o where o.id = t.order_id), ''),
    'customer_label', case when v_view = 'customer' then ''
                      else coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                      where pp.id = t.customer_id), '') end,
    'tag',         coalesce(t.tag,''),
    'tag_label',   coalesce((select g.label from public.thread_topic_tag g
                              where g.tag = t.tag), ''),
    'tag_tone',    coalesce((select g.tone from public.thread_topic_tag g
                              where g.tag = t.tag), 'info'),
    'status',      t.status,
    'status_label',case t.status
                     when 'open'     then public._c('thread.status_open')
                     when 'answered' then public._c('thread.status_answered')
                     else public._c('thread.status_closed') end,
    'status_tone', case t.status when 'open' then 'warning'
                                 when 'answered' then 'success' else 'info' end,
    'owner_label', case when v_view = 'customer' then ''
                        else coalesce(nullif(t.owner_label,''),
                                      public._c('thread.owner_none')) end,
    'sla_label',   case
                     when v_view = 'customer' then ''
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
    'sla_minutes', v_sla.sla_minutes,
    'unread_from_customer', coalesce(v_unread,0),
    'compose_hint',public._c('thread.compose_hint'),
    'send_cta',    public._c('thread.send_cta'),
    'attach_cta',  public._c('thread.attach_cta'),
    'can_write',   true,
    'empty_title', public._c('thread.empty_title'),
    'empty_note',  public._c('thread.empty_note'),
    'brand_note',  case when v_view = 'customer' then public._c('thread.brand_note') else '' end,
    'messages', coalesce((select jsonb_agg(public._thread_msg_row(m, v_view)
                                    order by m.created_at, m.id)
                            from public.order_thread_message m
                           where m.thread_id = v_id), '[]'::jsonb));
end $$;

-- ── WRITE to the conversation ───────────────────────────────────────────────
-- The one writer every surface uses. It stamps the role, assigns the owner and
-- starts (or stops) the clock — so "who owns this" is never a second call
-- somebody can forget to make.
create or replace function public._thread_append(
  p_thread_id uuid, p_body text, p_role text, p_actor uuid, p_partner bigint,
  p_label text, p_source text, p_attachments jsonb default '[]'::jsonb,
  p_critical text default null, p_wa_id text default null, p_wa_phone text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare
  v_msg uuid; t record; v_sla public.thread_sla_config; v_owner bigint; v_oname text;
begin
  select * into t from public.order_thread where id = p_thread_id;
  if t.id is null then return null; end if;

  insert into public.order_thread_message
    (thread_id, body, actor_role, actor_id, actor_partner_id, actor_label,
     source, attachments, critical_key, wa_message_id, wa_phone10)
  values (p_thread_id, coalesce(btrim(p_body),''), p_role, p_actor, p_partner,
          coalesce(p_label,''), coalesce(p_source,'app'),
          coalesce(p_attachments,'[]'::jsonb), nullif(p_critical,''),
          nullif(p_wa_id,''), nullif(p_wa_phone,''))
  on conflict (wa_message_id) where wa_message_id is not null do nothing
  returning id into v_msg;
  if v_msg is null then return null; end if;   -- a WhatsApp id we already have

  -- The writer has read everything up to their own message, by definition.
  perform public._thread_mark_read(p_thread_id,
            case when p_role = 'customer' then 'customer'
                 when p_role = 'partner'  then 'partner' else 'admin' end);

  v_sla := public._thread_sla(t.tag);

  if p_role = 'customer' then
    v_owner := coalesce(t.owner_partner_id, public._thread_zone_partner(t.zone_id));
    select rp.partner_name into v_oname from public.region_partners rp where rp.id = v_owner;
    update public.order_thread
       set last_message_at = now(),
           last_actor_role = p_role,
           status          = 'open',
           -- The clock starts on the FIRST unanswered message and is not
           -- pushed back by the customer writing again: a customer who chases
           -- must not reset the promise they are chasing.
           awaiting_since  = coalesce(awaiting_since, now()),
           sla_due_at      = coalesce(sla_due_at,
                               public._thread_business_due(now(), v_sla.sla_minutes,
                                 v_sla.business_start_ist, v_sla.business_end_ist)),
           owner_kind      = case when owner_kind = 'admin' then 'admin'
                                  when v_owner is not null then 'partner'
                                  else 'admin' end,
           owner_partner_id = coalesce(owner_partner_id, v_owner),
           owner_label     = case when owner_kind = 'admin' then public._c('thread.owner_admin')
                                  else coalesce(nullif(v_oname,''), public._c('thread.owner_admin')) end,
           updated_at      = now()
     where id = p_thread_id;
  else
    update public.order_thread
       set last_message_at = now(),
           last_actor_role = p_role,
           status          = case when status = 'closed' then 'answered'
                                  when p_role = 'system' then status else 'answered' end,
           awaiting_since  = case when p_role = 'system' then awaiting_since else null end,
           sla_due_at      = case when p_role = 'system' then sla_due_at else null end,
           escalated_at    = case when p_role = 'system' then escalated_at else null end,
           updated_at      = now()
     where id = p_thread_id;
  end if;

  return v_msg;
end $$;

create or replace function public.order_thread_post(
  p_thread_id uuid default null, p_body text default '',
  p_attachments jsonb default '[]'::jsonb, p_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := p_thread_id; v_view text; v_a jsonb := coalesce(p_attachments,'[]'::jsonb);
        a jsonb; v_ok jsonb := '[]'::jsonb; v_actor jsonb; v_msg uuid;
begin
  if v_id is null and p_order_id is not null then
    v_id := public.order_thread_ensure(p_order_id);
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error','no_thread',
      'message', public._c('thread.err_no_thread'));
  end if;
  v_view := public._thread_view(v_id);
  if v_view = '' then
    return jsonb_build_object('ok', false, 'error','not_your_thread',
      'message', public._c('thread.err_not_yours'));
  end if;
  if coalesce(btrim(p_body),'') = '' and jsonb_array_length(v_a) = 0 then
    return jsonb_build_object('ok', false, 'error','empty',
      'message', public._c('thread.err_empty'));
  end if;

  -- An attachment without a bucket and a path is not an attachment; drop it
  -- rather than storing a row nothing can open.
  for a in select * from jsonb_array_elements(v_a) loop
    if coalesce(a->>'bucket','') <> '' and coalesce(a->>'path','') <> '' then
      v_ok := v_ok || jsonb_build_array(a);
    end if;
  end loop;

  v_actor := public._thread_actor();
  v_msg := public._thread_append(v_id, p_body, v_actor->>'role',
             nullif(v_actor->>'id','')::uuid,
             nullif(v_actor->>'partner_id','')::bigint,
             v_actor->>'label', 'app', v_ok);
  if v_msg is null then
    return jsonb_build_object('ok', false, 'error','not_written',
      'message', public._c('thread.err_empty'));
  end if;

  return jsonb_build_object('ok', true, 'toast', public._c('thread.sent_toast'))
         || public.order_thread_get(null, v_id);
end $$;

revoke all on function public.order_thread_get(uuid, uuid) from public;
revoke all on function public.order_thread_post(uuid, text, jsonb, uuid) from public;
grant execute on function public.order_thread_get(uuid, uuid) to authenticated, service_role;
grant execute on function public.order_thread_post(uuid, text, jsonb, uuid) to authenticated, service_role;
grant execute on function public.order_thread_ensure(uuid) to authenticated, service_role;

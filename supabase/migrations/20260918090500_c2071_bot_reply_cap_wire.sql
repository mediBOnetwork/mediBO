-- CMD #2071 part 2 — wire the gate in front of every automated reply lane,
-- and give the two admin surfaces the flag + the label to render.
-- Idempotent: safe to replay on live.

-- ── Which notification EVENT is an automated bot reply, and as which route ──
-- Data again: a new bot lane is one INSERT, not a deploy.
create table if not exists public.whatsapp_bot_reply_event (
  event_key  text primary key,
  routed_to  text not null references public.whatsapp_bot_reply_route(routed_to),
  note       text,
  updated_at timestamptz not null default now()
);

insert into public.whatsapp_bot_reply_event (event_key, routed_to, note) values
  ('wa_assistant_reply',   'wa_assistant', 'AI assistant answer + handoff line'),
  ('wa_assistant_handoff', 'wa_assistant', 'assistant handoff notice'),
  ('wa_bot_reply',         'bot_reply',    'menu / greeting / fallback bot reply')
on conflict (event_key) do nothing;

-- ── LANE 1: the assistant. Every reply it sends leaves through this door. ──
-- wa_assistant_handle() calls this for its answer, its handoff line and the
-- payment-alert answer, so gating here covers all three without rewriting the
-- 200-line body (and without it drifting from live).
create or replace function public.wa_notify_customer_event(
  p_event_key text,
  p_order_id uuid default null::uuid,
  p_phone text default null::text,
  p_legacy_url text default null::text,
  p_legacy_body jsonb default null::jsonb,
  p_tokens jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_route text; v_gate jsonb;
begin
  -- CMD #2071 — the 24h automated-reply cap. Only events mapped in
  -- whatsapp_bot_reply_event are gated; OTP/login, order and payment
  -- notifications are not in that map and pass straight through, as does a
  -- human admin's manual reply (it never comes through here at all).
  select routed_to into v_route
    from public.whatsapp_bot_reply_event where event_key = p_event_key;

  if v_route is not null then
    v_gate := public.wa_bot_reply_allowed(p_phone, v_route, p_event_key);
    if not coalesce((v_gate->>'allowed')::boolean, true) then
      return jsonb_build_object('ok', false, 'path','skipped',
                                'reason','bot_reply_cap', 'cap', v_gate);
    end if;
  end if;

  return public.wa_notify_event(p_event_key, null, coalesce(p_tokens,'{}'::jsonb),
                                p_phone, p_order_id, p_legacy_url, p_legacy_body);
end $function$;

-- ── LANE 2: the menu / greeting / fallback bot. ────────────────────────────
-- wa_bot_enabled() is what the inbound webhook asks before it replies at all.
-- The cap sits above the old burst guards; they stay exactly as they were.
create or replace function public.wa_bot_enabled(p_phone text)
returns boolean
language plpgsql
as $function$
declare
  v_enabled boolean; v_paused timestamptz;
  v_n10 int := 0; v_std10 numeric := 999; v_n15 int := 0;
  v_ai_hour int := 0; v_ai_day int := 0;
begin
  select coalesce(
    (select bot_enabled from whatsapp_bot_state where phone = p_phone),
    (select bot_enabled from whatsapp_allowed_senders
       where phone = p_phone or phone = regexp_replace(p_phone,'^0','91') limit 1),
    true) into v_enabled;
  if v_enabled is false then return false; end if;

  select bot_paused_until into v_paused from whatsapp_bot_state where phone = p_phone;
  if v_paused is not null and now() < v_paused then return false; end if;

  -- CMD #2071 — the rolling-24h reply cap, read from whatsapp_bot_config.
  -- It logs its own skip (reason 'bot_reply_cap') and needs no pause window:
  -- the window moves on its own, so the bot resumes by itself.
  if not coalesce((public.wa_bot_reply_allowed(p_phone, 'bot_reply')->>'allowed')::boolean, true) then
    return false;
  end if;

  -- existing FAST-burst guard (unchanged)
  with ins as (
    select received_at, lag(received_at) over (order by received_at) prev
    from whatsapp_messages
    where sender_phone = p_phone and direction = 'in' and received_at > now() - interval '10 minutes'
  ),
  g as (select extract(epoch from (received_at - prev)) gap from ins where prev is not null)
  select count(*) + 1, coalesce(stddev_pop(gap), 999) into v_n10, v_std10 from g;

  select count(*) into v_n15 from whatsapp_messages
   where sender_phone = p_phone and direction = 'in' and received_at > now() - interval '15 minutes';

  if (v_n10 >= 20 and v_std10 < 5) or (v_n15 >= 50) then
    insert into whatsapp_bot_state(phone, bot_enabled, bot_paused_until, updated_at)
    values (p_phone, coalesce(v_enabled, true), now() + interval '3 hours', now())
    on conflict (phone) do update set bot_paused_until = excluded.bot_paused_until, updated_at = now();
    return false;
  end if;

  -- existing slow-spam guard (unchanged)
  select count(*) into v_ai_hour from whatsapp_messages
   where sender_phone = p_phone and direction = 'out' and received_at > now() - interval '1 hour';
  select count(*) into v_ai_day  from whatsapp_messages
   where sender_phone = p_phone and direction = 'out' and received_at > now() - interval '24 hours';

  if v_ai_hour >= 30 or v_ai_day >= 150 then
    insert into whatsapp_bot_state(phone, bot_enabled, bot_paused_until, updated_at)
    values (p_phone, coalesce(v_enabled, true), now() + interval '6 hours', now())
    on conflict (phone) do update set bot_paused_until = excluded.bot_paused_until, updated_at = now();
    return false;
  end if;

  return true;
end;
$function$;

-- ── SURFACE 1: the chat list row. ─────────────────────────────────────────
create or replace function public.wa_conversations(
  p_type text default null::text, p_zone smallint default null::smallint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_all jsonb; v_zone smallint; v_cap int; v_label text;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return '[]'::jsonb; end if;
  v_zone := public.scope_zone(p_zone);
  v_all := public._wa_conversations_core(p_type);
  if v_all is null or jsonb_typeof(v_all) <> 'array' then return coalesce(v_all,'[]'::jsonb); end if;

  if v_zone is not null then
    v_all := coalesce((
      select jsonb_agg(c)
      from jsonb_array_elements(v_all) c
      where public.wa_zone_visible(c->>'sender_phone', v_zone)
    ), '[]'::jsonb);
  end if;

  -- CMD #2071 — one counting pass for the whole list, then the backend's own
  -- label on the rows that hit the cap. The row renders it verbatim.
  select coalesce(max(bot_reply_cap_24h), 25) into v_cap
    from public.whatsapp_bot_config where id = 1;
  v_label := public.uic('wa.bot_cap.chat_label','Bot paused — cap reached');

  return coalesce((
    select jsonb_agg(
      c || jsonb_build_object(
        'bot_sent_24h', coalesce(s.n, 0),
        'bot_cap',      v_cap,
        'bot_capped',   coalesce(s.n, 0) >= v_cap,
        'bot_cap_label', case when coalesce(s.n, 0) >= v_cap then v_label end)
      order by c->>'last_at' desc)
    from jsonb_array_elements(v_all) c
    left join lateral (
      select count(*)::int as n
        from public.whatsapp_messages m
        join public.whatsapp_bot_reply_route r on r.routed_to = m.routed_to
                                              and r.counts_toward_cap
       where m.direction = 'out'
         and right(regexp_replace(m.sender_phone,'\D','','g'),10)
           = right(regexp_replace(c->>'sender_phone','\D','','g'),10)
         and m.received_at > now() - interval '24 hours'
    ) s on true
  ), '[]'::jsonb);
end $function$;

-- ── SURFACE 2: the thread header. ─────────────────────────────────────────
create or replace function public.wa_thread(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v jsonb; v_name text; v_label text; v_type text; v_p10 text; v_cap jsonb;
BEGIN
  IF role_for_medibo_only() NOT IN ('admin','super_admin') THEN RETURN jsonb_build_object('error','not_authorized'); END IF;
  v_p10 := right(regexp_replace(p_phone,'\D','','g'),10);
  v_name := public.wa_resolve_name(p_phone);
  SELECT label INTO v_label FROM whatsapp_allowed_senders
   WHERE right(regexp_replace(phone,'\D','','g'),10) = v_p10 LIMIT 1;
  SELECT sender_type INTO v_type FROM whatsapp_messages
   WHERE right(regexp_replace(sender_phone,'\D','','g'),10) = v_p10
   ORDER BY received_at DESC LIMIT 1;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'direction', m.direction, 'msg_type', m.msg_type,
           'text', m.text_body, 'caption', m.caption, 'file_path', m.file_path,
           'media_bucket', m.media_bucket, 'mime_type', m.mime_type, 'file_name', m.file_name,
           'latitude', m.latitude, 'longitude', m.longitude,
           'location_name', m.location_name, 'location_address', m.location_address,
           'contact_name', m.contact_name, 'contact_phone', m.contact_phone,
           'routed_to', m.routed_to, 'received_at', m.received_at,
           'wa_status', m.wa_status, 'wa_status_at', m.wa_status_at, 'wa_fail_reason', m.wa_fail_reason
         ) ORDER BY m.received_at), '[]'::jsonb)
    INTO v
  FROM whatsapp_messages m
  WHERE right(regexp_replace(m.sender_phone,'\D','','g'),10) = v_p10;

  -- CMD #2071 — the same gate the sender asks, reported to the header. The
  -- composer is untouched: a human reply is never capped.
  v_cap := public.wa_bot_reply_cap_state(p_phone);

  RETURN jsonb_build_object('status','ok','phone',p_phone,'name',v_name,'label',v_label,
                            'sender_type',v_type,'messages',v,
                            'bot_capped',    coalesce((v_cap->>'capped')::boolean, false),
                            'bot_cap',       (v_cap->>'cap')::int,
                            'bot_sent_24h',  (v_cap->>'sent_24h')::int,
                            'bot_cap_label', case when coalesce((v_cap->>'capped')::boolean,false)
                                                  then public.uic('wa.bot_cap.thread_label','Bot paused — cap reached') end,
                            'bot_cap_note',  v_cap->>'note');
END; $function$;

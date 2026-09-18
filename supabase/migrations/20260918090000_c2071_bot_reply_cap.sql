-- CMD #2071 — cap WhatsApp bot auto-replies at N per number per rolling 24h.
--
-- Why: +91 88844 10295 is another business's bot. Ours answered it, it answered
-- back, and the pair produced 910 out / 910 in in a single day. wa_bot_enabled()
-- already had a 150/day guard, but the ASSISTANT lane (wa_assistant_handle)
-- never consulted it, so 1,656 of the 1,814 outbound rows walked straight past.
-- This puts ONE gate in front of every automated reply and makes the number,
-- the classification and the label data instead of code.
--
-- Idempotent: safe to replay on live.

-- ── 1. The cap value lives in whatsapp_bot_config, editable, not hardcoded ──
alter table public.whatsapp_bot_config
  add column if not exists bot_reply_cap_24h integer not null default 25;

update public.whatsapp_bot_config
   set bot_reply_cap_24h = 25
 where id = 1 and bot_reply_cap_24h is null;

-- ── 2. WHICH outbound rows are an automated bot reply — data, not code ──────
-- An ALLOWLIST on purpose: only a route listed here with counts_toward_cap
-- counts against the cap and is stopped by it. Everything not listed — a human
-- admin's manual reply (routed_to null), login/OTP templates, order and payment
-- notifications, campaigns — is excluded by default and can never be capped,
-- which is exactly the exclusion the spec asks for.
create table if not exists public.whatsapp_bot_reply_route (
  routed_to         text primary key,
  counts_toward_cap boolean not null default true,
  note              text,
  updated_at        timestamptz not null default now()
);

insert into public.whatsapp_bot_reply_route (routed_to, counts_toward_cap, note) values
  ('wa_assistant', true,  'AI assistant auto-reply (wa_assistant_handle)'),
  ('bot_reply',    true,  'menu / greeting / fallback bot reply'),
  ('bot_qr_sent',  true,  'bot-initiated payment QR'),
  ('login_otp',        false, 'excluded: OTP'),
  ('user_notify_login',false, 'excluded: login template'),
  ('login_confirm',    false, 'excluded: login template'),
  ('login_logout',     false, 'excluded: login template'),
  ('order_notify_placed', false, 'excluded: order notification'),
  ('payment_qr_to_customer', false, 'excluded: payment notification'),
  ('inquiry_notify',   false, 'excluded: supplier inquiry'),
  ('stock_notify',     false, 'excluded: stock notification'),
  ('campaign',         false, 'excluded: admin-scheduled campaign')
on conflict (routed_to) do nothing;

comment on table public.whatsapp_bot_reply_route is
  'CMD #2071 — allowlist of outbound routed_to values that count as an automated bot reply. Only counts_toward_cap=true rows are counted by, and stopped by, the 24h reply cap.';

-- ── 3. Every skipped reply is said out loud ─────────────────────────────────
create table if not exists public.whatsapp_bot_skip_log (
  id         bigserial primary key,
  phone      text        not null,
  reason     text        not null,
  routed_to  text,
  event_key  text,
  sent_24h   integer,
  cap        integer,
  detail     jsonb       not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_wa_bot_skip_phone_time
  on public.whatsapp_bot_skip_log (phone, created_at desc);
create index if not exists idx_wa_bot_skip_reason_time
  on public.whatsapp_bot_skip_log (reason, created_at desc);

alter table public.whatsapp_bot_skip_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='whatsapp_bot_skip_log'
                    and policyname='admin_read_bot_skip_log') then
    create policy admin_read_bot_skip_log on public.whatsapp_bot_skip_log
      for select using (public.get_my_role() in ('admin','super_admin'));
  end if;
end $$;

-- The cap counts outbound bot rows fast, on every inbound message.
create index if not exists idx_wa_msg_out_bot_cap
  on public.whatsapp_messages (sender_phone, received_at desc)
  where direction = 'out';

-- ── 4. The copy. Backend words, rendered verbatim. ─────────────────────────
insert into public.ui_copy (key, value) values
  ('wa.bot_cap.chat_label',  to_jsonb('Bot paused — cap reached'::text)),
  ('wa.bot_cap.thread_label',to_jsonb('Bot paused — cap reached'::text)),
  ('wa.bot_cap.thread_note', to_jsonb('This number hit the automatic-reply limit for the last 24 hours. Replies you send yourself still go out normally.'::text))
on conflict (key) do nothing;

-- ── 5. THE GATE. One function every automated reply asks first. ────────────
create or replace function public.wa_bot_reply_cap_state(p_phone text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg as (
    select coalesce(max(bot_reply_cap_24h), 25) as cap
      from public.whatsapp_bot_config where id = 1
  ),
  p as (select right(regexp_replace(coalesce(p_phone,''), '\D','','g'), 10) as p10),
  sent as (
    select count(*)::int as n
      from public.whatsapp_messages m
      join public.whatsapp_bot_reply_route r on r.routed_to = m.routed_to
                                            and r.counts_toward_cap
      cross join p
     where m.direction = 'out'
       and right(regexp_replace(m.sender_phone,'\D','','g'),10) = p.p10
       and p.p10 <> ''
       and m.received_at > now() - interval '24 hours'
  )
  select jsonb_build_object(
    'phone',    (select p10 from p),
    'cap',      cfg.cap,
    'sent_24h', sent.n,
    'capped',   (sent.n >= cfg.cap),
    'reason',   case when sent.n >= cfg.cap then 'bot_reply_cap' end,
    'label',    case when sent.n >= cfg.cap
                     then public.uic('wa.bot_cap.chat_label','Bot paused — cap reached') end,
    'note',     case when sent.n >= cfg.cap
                     then public.uic('wa.bot_cap.thread_note','') end)
  from cfg, sent;
$function$;

-- The write half: ask, and record the refusal when it is one.
create or replace function public.wa_bot_reply_allowed(
  p_phone text, p_routed_to text default 'wa_assistant', p_event_key text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  -- A route that does not count toward the cap is never stopped by it:
  -- manual admin replies, OTP/login templates, order and payment notifications.
  if not exists (select 1 from public.whatsapp_bot_reply_route
                  where routed_to = p_routed_to and counts_toward_cap) then
    return jsonb_build_object('allowed', true, 'reason', 'not_capped_route',
                              'routed_to', p_routed_to);
  end if;

  v := public.wa_bot_reply_cap_state(p_phone);

  if coalesce((v->>'capped')::boolean, false) then
    begin
      insert into public.whatsapp_bot_skip_log
             (phone, reason, routed_to, event_key, sent_24h, cap, detail)
      values (v->>'phone', 'bot_reply_cap', p_routed_to, p_event_key,
              (v->>'sent_24h')::int, (v->>'cap')::int, v);
    exception when others then null;   -- logging must never block the refusal
    end;
    return v || jsonb_build_object('allowed', false);
  end if;

  return v || jsonb_build_object('allowed', true);
end $function$;

grant execute on function public.wa_bot_reply_cap_state(text) to authenticated, service_role;
grant execute on function public.wa_bot_reply_allowed(text, text, text) to service_role;

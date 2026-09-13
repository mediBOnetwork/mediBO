-- CMD #1849 — OUTBOUND SANDBOX: one chokepoint, and a receipt instead of silence.
--
-- #1848 gave a person's test session a hard outbound BLOCK. A block is silence,
-- and silence proves nothing: you cannot tell a working inquiry waterfall from
-- one that never fired. This migration replaces the block with an INTERCEPT that
-- records the full intended effect and lets the flow continue.
--
-- WHY A CHOKEPOINT AND NOT MORE GUARDS. Production carries roughly a dozen
-- scattered senders (notify, notif_push_send, notif_send_email, notify_partner,
-- notify_enqueue_retry, notify_test_send, wa_send_event_now, _c425_send,
-- _send_customer_bill_wa_auto, _send_payment_qr_wa_auto, order_alert_push,
-- delivery_send_otp, delivery_reg_send_otp) plus Razorpay's own path
-- (rzp_checkout_prepare, rzp_qr_prepare, rzp_send_order_qr_wa,
-- rzp_reconcile_tick). A gate written at each call site WILL miss one, and a
-- missed one means a real supplier is phoned about an order that does not exist.
--
-- HOW THE CHOKEPOINT IS INSTALLED. Each sender is RENAMED to <fn>_raw and a thin
-- gate wrapper is created under the original name with the identical signature
-- and defaults. Every caller keeps passing exactly what it passed before; the
-- wrapper asks public.outbound_dispatch() and either records the intent or hands
-- straight through to <fn>_raw. Nothing else about a real send changes: same
-- template, same retries, same notification_log row, written by the same body.
--
-- Idempotent: the rename runs only while <fn>_raw is absent, so a replay on live
-- re-issues the wrapper and never wraps a wrapper.

-- ---------------------------------------------------------------------------
-- 1. THE RECEIPT. One row per intended effect, in the order it was intended.
-- ---------------------------------------------------------------------------
create table if not exists public.outbound_receipt (
  id              bigserial primary key,
  session_id      bigint references public.test_sessions(id) on delete cascade,
  at              timestamptz not null default now(),
  channel         text        not null,
  verdict         text        not null,
  event_key       text,
  recipient       text,
  recipient_label text,
  template        text,
  body            text,
  amount          numeric,
  ref_kind        text,
  ref_id          text,
  order_code      text,
  reason          text,
  source_fn       text,
  meta            jsonb       not null default '{}'::jsonb
);

create index if not exists outbound_receipt_session_idx on public.outbound_receipt (session_id, id);
create index if not exists outbound_receipt_at_idx      on public.outbound_receipt (at desc);

comment on table public.outbound_receipt is
  'CMD #1849 — every outbound effect a test session WOULD have produced, in payload order. verdict: sandboxed (a test row, recorded not sent) | held (undetermined, fail-closed) | leaked_blocked (a call site that did not route through the dispatcher, caught at the transport).';

alter table public.outbound_receipt enable row level security;

do $rls$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='outbound_receipt'
                    and policyname='outbound_receipt_admin_read') then
    create policy outbound_receipt_admin_read on public.outbound_receipt
      for select to authenticated using (public.is_admin());
  end if;
end $rls$;

revoke all on public.outbound_receipt from anon;
grant select on public.outbound_receipt to authenticated;
grant all    on public.outbound_receipt to service_role;
grant usage, select on sequence public.outbound_receipt_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- 2. THE DISPATCHER. Every outbound effect asks this one question.
-- ---------------------------------------------------------------------------
-- Resolution, in order:
--   a. a live human session on THIS connection (the header #1848 installed)
--      → sandbox everything this request would emit, whatever it names;
--   b. an explicit session id in the meta;
--   c. the order / customer / supplier / inquiry row the call names;
--   d. the call NAMES a ref that resolves to nothing → HOLD. Fail closed:
--      silence is recoverable, a real supplier phoning about a fake order is not;
--   e. the call names no row at all and no session is live → SEND. A cron digest
--      with no row is not an undetermined row, and treating it as one would
--      silence the real path that spec item 6 requires to be unchanged.
create or replace function public._outbound_session_for(
  p_order_id    uuid,
  p_customer_id uuid,
  p_meta        jsonb
) returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_sess bigint; v_named boolean := false; v_found boolean := false;
  v_code text; v_sup uuid; v_inq text;
begin
  -- (a) the person's own request. Nothing they touch leaves the building.
  v_sess := public.test_session_mine();
  if v_sess is not null and public.test_outbound_silenced(v_sess) then
    return jsonb_build_object('decision','sandbox','session_id',v_sess,'reason','session_on_connection');
  end if;

  -- (b) an explicit stamp carried by the caller.
  if coalesce(p_meta->>'test_session_id','') <> '' then
    v_named := true;
    v_sess  := nullif(p_meta->>'test_session_id','')::bigint;
    if v_sess is not null then
      v_found := true;
      if public.test_outbound_silenced(v_sess) then
        return jsonb_build_object('decision','sandbox','session_id',v_sess,'reason','explicit_stamp');
      end if;
    end if;
  end if;

  -- (c) the row the call names.
  if p_order_id is not null then
    v_named := true;
    select o.test_session_id, o.order_code into v_sess, v_code
      from public.orders o where o.id = p_order_id;
    if found then
      v_found := true;
      if v_sess is not null and public.test_outbound_silenced(v_sess) then
        return jsonb_build_object('decision','sandbox','session_id',v_sess,
                                  'order_code',v_code,'reason','order_row');
      end if;
    end if;
  end if;

  if p_customer_id is not null then
    v_named := true;
    select pp.test_session_id into v_sess
      from public.pharmacy_profiles pp where pp.id = p_customer_id;
    if found then
      v_found := true;
      if v_sess is not null and public.test_outbound_silenced(v_sess) then
        return jsonb_build_object('decision','sandbox','session_id',v_sess,'reason','customer_row');
      end if;
    end if;
  end if;

  v_sup := nullif(p_meta->>'supplier_id','')::uuid;
  if v_sup is not null then
    v_named := true;
    select sp.test_session_id into v_sess
      from public.supplier_profiles sp where sp.id = v_sup;
    if found then
      v_found := true;
      if v_sess is not null and public.test_outbound_silenced(v_sess) then
        return jsonb_build_object('decision','sandbox','session_id',v_sess,'reason','supplier_row');
      end if;
    end if;
  end if;

  v_inq := nullif(p_meta->>'inquiry_code','');
  if v_inq is not null then
    v_named := true;
    select i.test_session_id into v_sess
      from public.inquiry i where i.inquiry_code = v_inq limit 1;
    if found then
      v_found := true;
      if v_sess is not null and public.test_outbound_silenced(v_sess) then
        return jsonb_build_object('decision','sandbox','session_id',v_sess,'reason','inquiry_row');
      end if;
    end if;
  end if;

  -- (d) a ref was named and nothing answered to it. Fail closed.
  if v_named and not v_found then
    return jsonb_build_object('decision','hold','session_id',null,'reason','ref_not_resolved');
  end if;

  -- (e) a real row, or no row at all.
  return jsonb_build_object('decision','send','session_id',null,'reason','no_test_row');
exception when others then
  -- The dispatcher itself failed. It cannot tell whether this is a test row,
  -- so it does not send — but it never raises, so the order's own processing
  -- is not blocked or delayed by an outbound question.
  return jsonb_build_object('decision','hold','session_id',null,
                            'reason','dispatch_error: '||coalesce(sqlerrm,'?'));
end $$;

create or replace function public.outbound_dispatch(
  p_channel     text,
  p_event_key   text    default null,
  p_recipient   text    default null,
  p_body        text    default null,
  p_amount      numeric default null,
  p_order_id    uuid    default null,
  p_customer_id uuid    default null,
  p_meta        jsonb   default '{}'::jsonb
) returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v      jsonb;
  v_dec  text;
  v_sess bigint;
  v_rid  bigint;
  v_code text;
  v_msg  text;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
begin
  v      := public._outbound_session_for(p_order_id, p_customer_id, v_meta);
  v_dec  := v->>'decision';
  v_sess := nullif(v->>'session_id','')::bigint;
  v_code := nullif(v->>'order_code','');

  if v_dec = 'send' then
    return jsonb_build_object('ok', true, 'decision','send', 'session_id', null);
  end if;

  if v_code is null and p_order_id is not null then
    select o.order_code into v_code from public.orders o where o.id = p_order_id;
  end if;

  insert into public.outbound_receipt (
    session_id, channel, verdict, event_key, recipient, recipient_label,
    template, body, amount, ref_kind, ref_id, order_code, reason, source_fn, meta)
  values (
    v_sess,
    coalesce(nullif(btrim(p_channel),''),'unknown'),
    case when v_dec = 'sandbox' then 'sandboxed' else 'held' end,
    nullif(btrim(coalesce(p_event_key,'')),''),
    nullif(btrim(coalesce(p_recipient,'')),''),
    public._outbound_recipient_label(p_channel, p_recipient, p_order_id, p_customer_id, v_meta),
    nullif(btrim(coalesce(v_meta->>'template','')),''),
    nullif(btrim(coalesce(p_body,'')),''),
    p_amount,
    case when p_order_id is not null then 'order'
         when p_customer_id is not null then 'customer'
         when v_meta ? 'supplier_id' then 'supplier'
         when v_meta ? 'inquiry_code' then 'inquiry' end,
    coalesce(p_order_id::text, p_customer_id::text, v_meta->>'supplier_id', v_meta->>'inquiry_code'),
    v_code,
    v->>'reason',
    nullif(btrim(coalesce(v_meta->>'fn','')),''),
    v_meta)
  returning id into v_rid;

  if v_dec = 'hold' then
    -- Held, not sent, and said out loud. The caller still gets ok:true so the
    -- real order's own processing continues at full speed.
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('c1849|held|'||coalesce(p_channel,'?')||'|'||coalesce(p_event_key,'?')),
            'warn', 'outbound_held',
            format('an outbound %s was held: %s', coalesce(p_channel,'?'), v->>'reason'),
            jsonb_build_object('receipt_id', v_rid, 'channel', p_channel,
                               'event_key', p_event_key, 'reason', v->>'reason'))
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = public.rg_alerts.seen_count + 1,
          detail = excluded.detail;
    v_msg := public.uic('outbound.held',
      'This message was held: the system could not tell whether it belonged to a test run. Nothing was sent.');
  else
    v_msg := public.uic('outbound.sandboxed',
      'Test mode: recorded on the receipt instead of sent.');
  end if;

  return jsonb_build_object('ok', true, 'decision', v_dec, 'sandboxed', v_dec = 'sandbox',
                            'session_id', v_sess, 'receipt_id', v_rid, 'message', v_msg);
exception when others then
  -- Recording must never break a real order. If even the receipt write fails,
  -- the answer is still "do not send".
  return jsonb_build_object('ok', true, 'decision','hold', 'sandboxed', false,
                            'session_id', null, 'receipt_id', null,
                            'message', public.uic('outbound.held',
                              'This message was held: the system could not tell whether it belonged to a test run. Nothing was sent.'));
end $$;

-- The name a person reads on the receipt. Backend-rendered, never assembled in Dart.
create or replace function public._outbound_recipient_label(
  p_channel text, p_recipient text, p_order_id uuid, p_customer_id uuid, p_meta jsonb
) returns text
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v text;
begin
  if coalesce(p_meta->>'recipient_label','') <> '' then return p_meta->>'recipient_label'; end if;
  if nullif(p_meta->>'supplier_id','') is not null then
    select coalesce(nullif(btrim(sp.supplier_name),''), 'Supplier') into v
      from public.supplier_profiles sp where sp.id = (p_meta->>'supplier_id')::uuid;
    if v is not null then return v; end if;
  end if;
  if p_customer_id is not null then
    select coalesce(nullif(btrim(pp.pharmacy_name),''), 'Customer') into v
      from public.pharmacy_profiles pp where pp.id = p_customer_id;
    if v is not null then return v; end if;
  end if;
  if p_order_id is not null then
    select coalesce(nullif(btrim(pp.pharmacy_name),''), 'Customer') into v
      from public.orders o
      join public.pharmacy_profiles pp on pp.user_id = o.user_id
     where o.id = p_order_id limit 1;
    if v is not null then return v; end if;
  end if;
  if coalesce(p_recipient,'') <> '' then return p_recipient; end if;
  return public.uic('outbound.recipient_unknown','Unnamed recipient');
exception when others then
  return nullif(btrim(coalesce(p_recipient,'')),'');
end $$;

revoke all on function public.outbound_dispatch(text,text,text,text,numeric,uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public._outbound_session_for(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public._outbound_recipient_label(text,text,uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.outbound_dispatch(text,text,text,text,numeric,uuid,uuid,jsonb) to service_role;
grant execute on function public._outbound_session_for(uuid,uuid,jsonb) to service_role;
grant execute on function public._outbound_recipient_label(text,text,uuid,uuid,jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. EVERY SENDER, ROUTED. Rename to <fn>_raw, wrap under the original name.
-- ---------------------------------------------------------------------------
-- One helper does the rename so the intent is stated once and the guard is
-- identical everywhere: rename only while the _raw twin is absent.
create or replace function public._c1849_rename_once(p_sig text, p_new text)
 returns void language plpgsql as $$
begin
  if to_regprocedure('public.'||p_new||'('||split_part(split_part(p_sig,'(',2),')',1)||')') is null
     and to_regprocedure('public.'||p_sig) is not null then
    execute format('alter function public.%s rename to %I', p_sig, p_new);
  end if;
end $$;

do $wrap$
begin
  perform public._c1849_rename_once('notify(text,text,jsonb)', 'notify_raw');
  perform public._c1849_rename_once('notif_push_send(text,text,uuid,uuid,jsonb,text)', 'notif_push_send_raw');
  perform public._c1849_rename_once('notif_send_email(text,text,jsonb,uuid,uuid,bigint,boolean)', 'notif_send_email_raw');
  perform public._c1849_rename_once('notify_partner(text,jsonb)', 'notify_partner_raw');
  perform public._c1849_rename_once('notify_enqueue_retry(text,text,jsonb,text,uuid,uuid,text,boolean)', 'notify_enqueue_retry_raw');
  perform public._c1849_rename_once('notify_test_send(text,jsonb)', 'notify_test_send_raw');
  perform public._c1849_rename_once('wa_send_event_now(text,uuid,jsonb,text,uuid)', 'wa_send_event_now_raw');
  perform public._c1849_rename_once('_c425_send(uuid,text,text,text,text,jsonb,boolean)', '_c425_send_raw');
  perform public._c1849_rename_once('_send_customer_bill_wa_auto(uuid,text)', '_send_customer_bill_wa_auto_raw');
  perform public._c1849_rename_once('_send_payment_qr_wa_auto(uuid,text,numeric,text)', '_send_payment_qr_wa_auto_raw');
  perform public._c1849_rename_once('order_alert_push(bigint,text,text)', 'order_alert_push_raw');
  perform public._c1849_rename_once('delivery_send_otp(uuid)', 'delivery_send_otp_raw');
  perform public._c1849_rename_once('delivery_reg_send_otp(jsonb)', 'delivery_reg_send_otp_raw');
  perform public._c1849_rename_once('rzp_checkout_prepare(uuid,text,text)', 'rzp_checkout_prepare_raw');
  perform public._c1849_rename_once('rzp_qr_prepare(uuid,text)', 'rzp_qr_prepare_raw');
  perform public._c1849_rename_once('rzp_send_order_qr_wa(uuid)', 'rzp_send_order_qr_wa_raw');
  perform public._c1849_rename_once('rzp_reconcile_tick()', 'rzp_reconcile_tick_raw');
end $wrap$;

-- WhatsApp — the main event path. Every customer, supplier and admin template
-- in production ends up here.
create or replace function public.notify(p_event_key text, p_recipient text default null, p_vars jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch(
         coalesce(nullif(p_vars->>'channel',''),'whatsapp'), p_event_key, p_recipient,
         nullif(p_vars->>'legacy_body',''), null,
         nullif(p_vars->>'order_id','')::uuid, nullif(p_vars->>'customer_id','')::uuid,
         jsonb_build_object('fn','notify','template',p_event_key,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'reason','outbound_'||(g->>'decision'),
                              'receipt_id', g->'receipt_id', 'message', g->>'message');
  end if;
  return public.notify_raw(p_event_key, p_recipient, p_vars);
end $$;

-- Push.
create or replace function public.notif_push_send(p_event_key text, p_phone10 text,
  p_user_id uuid default null, p_order_id uuid default null,
  p_vars jsonb default '{}'::jsonb, p_audience text default 'customer')
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('push', p_event_key, p_phone10, null, null,
         p_order_id, nullif(p_vars->>'customer_id','')::uuid,
         jsonb_build_object('fn','notif_push_send','template',p_event_key,
                            'audience',p_audience,'user_id',p_user_id,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.notif_push_send_raw(p_event_key, p_phone10, p_user_id, p_order_id, p_vars, p_audience);
end $$;

-- Email.
create or replace function public.notif_send_email(p_event_key text, p_to text default null,
  p_vars jsonb default '{}'::jsonb, p_user_id uuid default null, p_order_id uuid default null,
  p_parent_log_id bigint default null, p_dry_run boolean default false)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  -- A dry run never left the building in the first place: it is the preview
  -- path and must stay byte-identical.
  if coalesce(p_dry_run,false) then
    return public.notif_send_email_raw(p_event_key, p_to, p_vars, p_user_id, p_order_id, p_parent_log_id, p_dry_run);
  end if;
  g := public.outbound_dispatch('email', p_event_key, p_to, null, null,
         p_order_id, nullif(p_vars->>'customer_id','')::uuid,
         jsonb_build_object('fn','notif_send_email','template',p_event_key,
                            'user_id',p_user_id,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.notif_send_email_raw(p_event_key, p_to, p_vars, p_user_id, p_order_id, p_parent_log_id, p_dry_run);
end $$;

-- Partner / admin paging.
create or replace function public.notify_partner(p_event_key text, p_vars jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('admin_page', p_event_key, nullif(p_vars->>'phone',''), null, null,
         nullif(p_vars->>'order_id','')::uuid, nullif(p_vars->>'customer_id','')::uuid,
         jsonb_build_object('fn','notify_partner','template',p_event_key,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.notify_partner_raw(p_event_key, p_vars);
end $$;

-- The retry queue. A sandboxed intent is recorded once; it is never queued,
-- because a queued row is a message that still means to go out later.
create or replace function public.notify_enqueue_retry(p_event_key text, p_recipient text,
  p_vars jsonb, p_reason text, p_order_id uuid default null, p_customer_id uuid default null,
  p_channel text default 'whatsapp', p_force_template boolean default false)
 returns bigint language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch(coalesce(p_channel,'whatsapp'), p_event_key, p_recipient, null, null,
         p_order_id, p_customer_id,
         jsonb_build_object('fn','notify_enqueue_retry','template',p_event_key,
                            'retry_reason',p_reason,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return null::bigint;
  end if;
  return public.notify_enqueue_retry_raw(p_event_key, p_recipient, p_vars, p_reason,
                                         p_order_id, p_customer_id, p_channel, p_force_template);
end $$;

-- The admin "send me one now" button.
create or replace function public.notify_test_send(p_event_key text, p_vars jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('whatsapp', p_event_key, nullif(p_vars->>'phone',''), null, null,
         nullif(p_vars->>'order_id','')::uuid, nullif(p_vars->>'customer_id','')::uuid,
         jsonb_build_object('fn','notify_test_send','template',p_event_key,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.notify_test_send_raw(p_event_key, p_vars);
end $$;

-- The immediate customer/supplier event send.
create or replace function public.wa_send_event_now(p_event_key text, p_customer_id uuid default null,
  p_tokens jsonb default '{}'::jsonb, p_phone text default null, p_order_id uuid default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('whatsapp', p_event_key, p_phone, null, null,
         p_order_id, p_customer_id,
         jsonb_build_object('fn','wa_send_event_now','template',p_event_key,'vars',coalesce(p_tokens,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.wa_send_event_now_raw(p_event_key, p_customer_id, p_tokens, p_phone, p_order_id);
end $$;

-- The four WhatsApp shop loops (#425). p_shop is a customer id.
create or replace function public._c425_send(p_shop uuid, p_kind text, p_dedupe text,
  p_event_key text, p_text text, p_vars jsonb, p_needs_optin boolean default true)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('whatsapp', p_event_key, null, p_text, null,
         nullif(p_vars->>'order_id','')::uuid, p_shop,
         jsonb_build_object('fn','_c425_send','template',coalesce(p_event_key,p_kind),
                            'kind',p_kind,'vars',coalesce(p_vars,'{}'::jsonb)));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public._c425_send_raw(p_shop, p_kind, p_dedupe, p_event_key, p_text, p_vars, p_needs_optin);
end $$;

-- The auto customer bill.
create or replace function public._send_customer_bill_wa_auto(p_order_id uuid, p_phone text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('whatsapp', 'customer_bill', p_phone, null, null, p_order_id, null,
         jsonb_build_object('fn','_send_customer_bill_wa_auto','template','customer_bill'));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public._send_customer_bill_wa_auto_raw(p_order_id, p_phone);
end $$;

-- The auto payment QR message — money, so it carries the amount onto the receipt.
create or replace function public._send_payment_qr_wa_auto(p_order_id uuid, p_phone text,
  p_amount numeric, p_kind text default 'remaining')
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'payment_qr', p_phone, null, p_amount, p_order_id, null,
         jsonb_build_object('fn','_send_payment_qr_wa_auto','template','payment_qr','kind',p_kind));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public._send_payment_qr_wa_auto_raw(p_order_id, p_phone, p_amount, p_kind);
end $$;

-- Order alerts to the ops audience.
create or replace function public.order_alert_push(p_alert_id bigint, p_kind text default 'new',
  p_audience text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb; v_order uuid;
begin
  begin
    select a.order_id into v_order from public.order_alert a where a.id = p_alert_id;
  exception when others then v_order := null; end;
  g := public.outbound_dispatch('admin_page', 'order_alert', null, null, null, v_order, null,
         jsonb_build_object('fn','order_alert_push','template','order_alert',
                            'kind',p_kind,'audience',p_audience,'alert_id',p_alert_id));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.order_alert_push_raw(p_alert_id, p_kind, p_audience);
end $$;

-- Delivery OTP to the customer.
create or replace function public.delivery_send_otp(p_delivery_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb; v_order uuid;
begin
  begin
    select d.order_id into v_order from public.deliveries d where d.id = p_delivery_id;
  exception when others then v_order := null; end;
  g := public.outbound_dispatch('whatsapp', 'delivery_otp', null, null, null, v_order, null,
         jsonb_build_object('fn','delivery_send_otp','template','delivery_otp','delivery_id',p_delivery_id));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.delivery_send_otp_raw(p_delivery_id);
end $$;

-- Rider registration OTP. This one is identity, not an order effect: it names no
-- row, so it only ever sandboxes for the person whose own session is live.
create or replace function public.delivery_reg_send_otp(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('whatsapp', 'rider_reg_otp', nullif(p->>'phone',''), null, null, null, null,
         jsonb_build_object('fn','delivery_reg_send_otp','template','rider_reg_otp'));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.delivery_reg_send_otp_raw(p);
end $$;

-- ---------------------------------------------------------------------------
-- 4. RAZORPAY. Live keys, real money — the highest-risk lane on the platform.
--    A test session reaches NO Razorpay endpoint: not order creation, not QR
--    generation, not a refund, not reconciliation. Each of these is the SQL the
--    edge function must call before it may touch api.razorpay.com, so refusing
--    here is refusing the endpoint.
-- ---------------------------------------------------------------------------
create or replace function public.rzp_checkout_prepare(p_order_id uuid, p_kind text default 'advance',
  p_mode text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'rzp_checkout', null,
         null, public.rzp_amount_due(p_order_id, case when lower(coalesce(p_kind,'advance'))='advance' then 'advance' else 'balance' end),
         p_order_id, null,
         jsonb_build_object('fn','rzp_checkout_prepare','template','rzp_checkout',
                            'endpoint','payment_link.create','kind',p_kind));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', false, 'error','test_mode_outbound_blocked',
                              'sandboxed', g->'sandboxed', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.rzp_checkout_prepare_raw(p_order_id, p_kind, p_mode);
end $$;

create or replace function public.rzp_qr_prepare(p_order_id uuid, p_kind text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'rzp_qr', null,
         null, public.rzp_amount_due(p_order_id, case when lower(coalesce(p_kind,'advance'))='advance' then 'advance' else 'balance' end),
         p_order_id, null,
         jsonb_build_object('fn','rzp_qr_prepare','template','rzp_qr','endpoint','qr_code.create','kind',p_kind));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', false, 'enabled', true, 'error','test_mode_outbound_blocked',
                              'sandboxed', g->'sandboxed', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.rzp_qr_prepare_raw(p_order_id, p_kind);
end $$;

create or replace function public.rzp_send_order_qr_wa(p_order_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'rzp_qr_wa', null, null, null, p_order_id, null,
         jsonb_build_object('fn','rzp_send_order_qr_wa','template','rzp_qr_wa','endpoint','qr_code.create'));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', false, 'error','test_mode_outbound_blocked',
                              'sandboxed', g->'sandboxed', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.rzp_send_order_qr_wa_raw(p_order_id);
end $$;

-- Reconciliation walks REAL attempts only. A test session's attempt never
-- reaches Razorpay's API, so it is never reconciled against it either.
create or replace function public.rzp_reconcile_tick()
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'rzp_reconcile', null, null, null, null, null,
         jsonb_build_object('fn','rzp_reconcile_tick','template','rzp_reconcile','endpoint','payment.fetch'));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'path', g->>'decision', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.rzp_reconcile_tick_raw();
end $$;

-- The payment gate the Razorpay EDGE functions ask before a single byte goes to
-- api.razorpay.com. Refund and account creation have no prepare RPC of their
-- own, so this is their chokepoint.
create or replace function public.outbound_payment_gate(p_endpoint text, p_order_id uuid default null,
  p_amount numeric default null, p_meta jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'rzp_'||coalesce(p_endpoint,'call'), null, null, p_amount,
         p_order_id, null,
         coalesce(p_meta,'{}'::jsonb) || jsonb_build_object('fn','outbound_payment_gate',
           'template','rzp_'||coalesce(p_endpoint,'call'), 'endpoint', p_endpoint));
  return jsonb_build_object('ok', g->>'decision' = 'send', 'decision', g->>'decision',
                            'allowed', g->>'decision' = 'send',
                            'receipt_id', g->'receipt_id',
                            'message', coalesce(g->>'message',''));
end $$;

revoke all on function public.outbound_payment_gate(text,uuid,numeric,jsonb) from public, anon;
grant execute on function public.outbound_payment_gate(text,uuid,numeric,jsonb) to service_role;

-- The _raw twins are internal. Only the wrappers (SECURITY DEFINER, owned by
-- the same role) may reach them; nothing signed in can call one to skip the gate.
do $rev$
declare r record;
begin
  for r in select p.oid::regprocedure::text as sig from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like '%\_raw'
             and p.proname in ('notify_raw','notif_push_send_raw','notif_send_email_raw',
                 'notify_partner_raw','notify_enqueue_retry_raw','notify_test_send_raw',
                 'wa_send_event_now_raw','_c425_send_raw','_send_customer_bill_wa_auto_raw',
                 '_send_payment_qr_wa_auto_raw','order_alert_push_raw','delivery_send_otp_raw',
                 'delivery_reg_send_otp_raw','rzp_checkout_prepare_raw','rzp_qr_prepare_raw',
                 'rzp_send_order_qr_wa_raw','rzp_reconcile_tick_raw')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $rev$;

-- ---------------------------------------------------------------------------
-- 5. THE BACKSTOP. Two of them, because "a per-call-site gate WILL miss one"
--    is a statement about the FUTURE as much as about today.
-- ---------------------------------------------------------------------------
-- 5a. Build time. Every public function that can put bytes on the wire is
--     classified, and an unclassified one is a LEAK the guard reports. A new
--     exemption is one INSERT into this table — never a deploy.
create table if not exists public.outbound_route (
  fn_name text primary key,
  kind    text not null,          -- routed | exempt
  note    text not null default ''
);
comment on table public.outbound_route is
  'CMD #1849 — the outbound call-site registry. routed: goes through outbound_dispatch. exempt: puts bytes on the wire but produces no effect a person receives (documents, OCR, worker kicks, internal probes).';

revoke all on public.outbound_route from anon;
grant select on public.outbound_route to authenticated;
grant all    on public.outbound_route to service_role;

insert into public.outbound_route (fn_name, kind, note) values
  ('notify','routed','the WhatsApp event path every customer/supplier/admin template ends in'),
  ('notif_push_send','routed','push'),
  ('notif_send_email','routed','email'),
  ('notify_partner','routed','partner and admin paging'),
  ('notify_enqueue_retry','routed','the retry queue'),
  ('notify_test_send','routed','the admin send-me-one-now button'),
  ('wa_send_event_now','routed','the immediate event send'),
  ('_c425_send','routed','the four WhatsApp shop loops'),
  ('_send_customer_bill_wa_auto','routed','the auto customer bill'),
  ('_send_payment_qr_wa_auto','routed','the auto payment QR message'),
  ('order_alert_push','routed','order alerts to the ops audience'),
  ('delivery_send_otp','routed','the delivery OTP'),
  ('delivery_reg_send_otp','routed','the rider registration OTP'),
  ('rzp_checkout_prepare','routed','Razorpay payment link creation'),
  ('rzp_qr_prepare','routed','Razorpay QR creation'),
  ('rzp_send_order_qr_wa','routed','Razorpay QR delivered on WhatsApp'),
  ('rzp_reconcile_tick','routed','Razorpay reconciliation reads'),
  ('outbound_payment_gate','routed','the gate the Razorpay edge functions ask'),
  ('push_admin_screen','exempt','a read-only admin screen payload; it sends nothing'),
  ('_c429_dispatch','exempt','renders a sheet document'),
  ('_c710_doc_enqueue','exempt','renders a debit note document'),
  ('_chaos_edge_delay_past_timeout','exempt','a chaos drill against our own edge'),
  ('_devq_forward','exempt','the dev-queue control plane bridge'),
  ('_kyc_ocr_enqueue','exempt','OCR of a document already uploaded'),
  ('_phv_dispatch','exempt','pharmacy bill vault OCR'),
  ('agency_invoice_doc_request','exempt','renders an invoice document'),
  ('bill_jobs_tick','exempt','renders bill documents'),
  ('bulk_ocr_kick_worker','exempt','OCR worker kick'),
  ('bulk_ocr_sweep_stuck','exempt','OCR worker kick'),
  ('dispatch_supplier_matches','exempt','kicks the match worker; the messages it causes go out through notify'),
  ('khata_statement_request','exempt','renders a statement document'),
  ('kyc_ocr_sweep','exempt','OCR worker kick'),
  ('lead_scrape_call','exempt','reads a public listing'),
  ('login_request_otp','exempt','identity, not an order effect: silencing a login locks a real person out of a real account'),
  ('my_statement_request','exempt','renders a statement document'),
  ('partner_agreement_sign_start','exempt','renders an agreement document'),
  ('partner_doc_request','exempt','renders a partner document'),
  ('pharmacy_audit_pdf_request','exempt','renders an audit document'),
  ('pharmacy_audit_photo_add','exempt','uploads a photo'),
  ('pharmacy_gst_pack_request','exempt','renders a GST pack'),
  ('pharmacy_vault_sweep','exempt','vault OCR sweep'),
  ('pos_invoice_request','exempt','renders an invoice document'),
  ('px_distance','exempt','asks our own OSRM for a road distance'),
  ('px_invoice_request','exempt','renders an invoice document'),
  ('recording_promote','exempt','dev-queue recording'),
  ('rg_probe_edges','exempt','the regression guard probing our own edges'),
  ('settlement_invoice_request','exempt','renders a settlement invoice'),
  ('supplier_doc_request','exempt','renders a supplier document'),
  ('supplier_doc_sweep','exempt','renders supplier documents'),
  ('trg_supplier_regeocode','exempt','geocodes an address'),
  ('trigger_scan_bill','exempt','bill OCR'),
  ('version_watch','exempt','reads our own version.json'),
  ('wa_media_refresh_tick','exempt','refreshes a template media handle with Meta'),
  ('wa_media_upload_detached','exempt','uploads template media to Meta'),
  ('wa_policy_review_start','exempt','submits a template for review'),
  ('wa_template_delete','exempt','edits a template at Meta'),
  ('wa_template_set_header_media','exempt','edits a template at Meta'),
  ('wa_template_translate_clone','exempt','clones a template at Meta'),
  ('wa_token_ai_search','exempt','asks Gemini about token names'),
  ('wa_waba_refresh','exempt','reads our own WABA account state'),
  ('wa_assistant_tick','exempt','asks the assistant edge function to CLASSIFY an inbound message; the reply it causes goes out through notify'),
  ('trg_c425_wa_inbound','exempt','reacts to an inbound message; anything it sends goes out through _c425_send'),
  ('_outbound_net_guard','exempt','the transport backstop itself')
on conflict (fn_name) do update set kind = excluded.kind, note = excluded.note;

create or replace function public.outbound_leak_scan()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_routed text[];
  v_leaks  jsonb := '[]'::jsonb;
  r record;
  v_def text;
  v_ok boolean;
  n text;
begin
  select coalesce(array_agg(fn_name), '{}') into v_routed
    from public.outbound_route where kind = 'routed';

  for r in
    select p.proname, pg_get_functiondef(p.oid) as def
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.prokind = 'f'
       and p.proname not like '%\_raw'
       and pg_get_functiondef(p.oid) ~* 'net\.http_(post|get)'
  loop
    v_def := r.def;
    v_ok := v_def ~* '(outbound_dispatch|outbound_payment_gate)'
         or exists (select 1 from public.outbound_route o
                     where o.fn_name = r.proname);
    if not v_ok then
      foreach n in array v_routed loop
        if v_def ~ ('\m' || n || '\M') then v_ok := true; exit; end if;
      end loop;
    end if;
    if not v_ok then
      v_leaks := v_leaks || jsonb_build_object('fn', r.proname);
    end if;
  end loop;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_leaks) = 0,
    'leaks', v_leaks,
    'leak_count', jsonb_array_length(v_leaks),
    'routed', coalesce(array_length(v_routed,1),0),
    'label', case when jsonb_array_length(v_leaks) = 0
                  then public.uic('outbound.scan_clean','Every outbound call site is routed through the dispatcher.')
                  else public.uic('outbound.scan_leak','An outbound call site does not go through the dispatcher.') end);
end $$;

revoke all on function public.outbound_leak_scan() from public, anon;
grant execute on function public.outbound_leak_scan() to authenticated, service_role;

-- 5b. Run time. The one place every DB-originated HTTP request is written down.
--     While a person's test session is live on THIS connection, nothing this
--     connection asks for is put on the wire — even if a call site nobody has
--     routed yet asked for it. The intent is written to the receipt instead.
--
--     ROLLBACK NOTE: pg_net's queue is owned by supabase_admin, so this trigger
--     can be created (the TRIGGER privilege) but not dropped by us. The rollback
--     is therefore to replace the body of _outbound_net_guard with `return new`,
--     which makes it a no-op pass-through. Every failure path already does that,
--     so a bug here can never take production's outbound HTTP offline.
create or replace function public._outbound_net_guard()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare v_sess bigint;
begin
  v_sess := public.test_session_mine();
  if v_sess is null or not public.test_outbound_silenced(v_sess) then
    return new;                                   -- the real path, untouched
  end if;
  insert into public.outbound_receipt
    (session_id, channel, verdict, event_key, recipient, recipient_label,
     reason, source_fn, body, meta)
  values (v_sess, 'http', 'leaked_blocked', 'net.http_request',
          left(coalesce(new.url,''), 300), public.uic('outbound.recipient_http','An external service'),
          'unrouted_call_site', 'net.http_post',
          left(coalesce(new.body::text,''), 2000),
          jsonb_build_object('url', new.url, 'method', new.method));
  return null;                                    -- never queued, never sent
exception when others then
  return new;   -- a bug in the belt must never cut the braces
end $$;

do $trg$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = to_regclass('net.http_request_queue')
                    and tgname = 'outbound_net_guard' and not tgisinternal)
     and to_regclass('net.http_request_queue') is not null then
    begin
      execute 'create trigger outbound_net_guard before insert on net.http_request_queue '
              'for each row execute function public._outbound_net_guard()';
    exception when insufficient_privilege or others then
      -- The registry scan (5a) is the guarantee that survives; the transport
      -- belt is a bonus wherever the role is allowed to install it.
      raise notice 'c1849: could not install the pg_net backstop trigger (%), the call-site registry still holds', sqlerrm;
    end;
  end if;
end $trg$;

-- ---------------------------------------------------------------------------
-- 6. REFUNDS AND RECONCILIATION. A refund has no prepare-then-call pair of its
--    own beyond refund_prepare, so that is where it is gated: the edge function
--    cannot reach api.razorpay.com without it.
-- ---------------------------------------------------------------------------
do $wrap2$
begin
  perform public._c1849_rename_once('refund_prepare(uuid)', 'refund_prepare_raw');
  perform public._c1849_rename_once('rzp_reconcile_due(integer)', 'rzp_reconcile_due_raw');
end $wrap2$;

create or replace function public.refund_prepare(p_refund_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb; v_order uuid; v_amt numeric;
begin
  begin
    select r.order_id into v_order from public.refunds r where r.id = p_refund_id;
  exception when others then v_order := null; end;
  g := public.outbound_dispatch('payment', 'rzp_refund', null, null, v_amt, v_order, null,
         jsonb_build_object('fn','refund_prepare','template','rzp_refund',
                            'endpoint','payments.refund','refund_id',p_refund_id));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', false, 'error','test_mode_outbound_blocked',
                              'sandboxed', g->'sandboxed', 'receipt_id', g->'receipt_id',
                              'message', g->>'message');
  end if;
  return public.refund_prepare_raw(p_refund_id);
end $$;

-- Reconciliation asks Razorpay about attempts. A test session's attempt is not
-- one of them, and while a person's session is live nothing is asked at all.
create or replace function public.rzp_reconcile_due(p_limit integer default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare g jsonb;
begin
  g := public.outbound_dispatch('payment', 'rzp_reconcile_due', null, null, null, null, null,
         jsonb_build_object('fn','rzp_reconcile_due','template','rzp_reconcile_due',
                            'endpoint','payments.fetch'));
  if g->>'decision' <> 'send' then
    return jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'path', g->>'decision',
                              'receipt_id', g->'receipt_id', 'message', g->>'message');
  end if;
  return public.rzp_reconcile_due_raw(p_limit);
end $$;

insert into public.outbound_route (fn_name, kind, note) values
  ('refund_prepare','routed','Razorpay refunds — the edge function cannot reach the API without this'),
  ('rzp_reconcile_due','routed','the list reconciliation walks before it asks Razorpay')
on conflict (fn_name) do update set kind = excluded.kind, note = excluded.note;

do $rev2$
declare r record;
begin
  for r in select p.oid::regprocedure::text as sig from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('refund_prepare_raw','rzp_reconcile_due_raw')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $rev2$;

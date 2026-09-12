-- CHANGE #398 (3/4) — PARTNER IS A NOTIFICATION AUDIENCE.
--
-- notify() has always spoken to one recipient with an audience taken from
-- wa_event_routes: customer, supplier, delivery, worker, mr, company, admin.
-- The one party doing the physical fulfilment — the zone partner — was not on
-- that list, so nothing that happened to an order in their zone ever reached
-- them unless a human forwarded it.
--
-- 'partner' is now an audience like every other, with two differences that are
-- properties of what a partner IS:
--   1. It is a GROUP, not a phone. notify_partner() resolves the order's zone
--      to that zone's partner and fans out to its active staff, then hands each
--      recipient to the SAME notify() — push first, WhatsApp behind it, one
--      notification_log row each. No new sending path exists.
--   2. It never reaches a supplier. Supplier sends stay exactly where they are.

-- ── Who a partner's staff are, as phone numbers ─────────────────────────────
-- Resolved from the partner_users row (auth phone, then the identity itself
-- when it IS a phone, then the device token's phone) — never from a role word.
create or replace function public._partner_phones(p_partner bigint)
returns text[]
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(array_agg(distinct p), '{}'::text[])
    from (
      select right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10) as p
        from partner_users pu
        join region_partners rp on rp.id = pu.partner_id
        left join auth.users u on u.id = pu.auth_user_id
       where pu.partner_id = p_partner
         and coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
      union all
      select right(regexp_replace(coalesce(pu.identity,''),'\D','','g'),10)
        from partner_users pu
        join region_partners rp on rp.id = pu.partner_id
       where pu.partner_id = p_partner
         and coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
      union all
      select right(regexp_replace(coalesce(t.phone10,''),'\D','','g'),10)
        from push_tokens t
       where t.is_active
         and t.user_id in (select pu.auth_user_id from partner_users pu
                            where pu.partner_id = p_partner
                              and coalesce(pu.is_active,true)
                              and pu.auth_user_id is not null)
    ) s
   where length(p) = 10
$function$;

-- The partner an event belongs to: the order's zone decides, never the caller.
create or replace function public._partner_for_event(p_vars jsonb)
returns bigint
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_zone smallint; v_pid bigint; v_order uuid;
begin
  v_pid := nullif(p_vars->>'partner_id','')::bigint;
  if v_pid is not null then return v_pid; end if;

  v_zone := nullif(p_vars->>'zone_id','')::smallint;
  if v_zone is null then
    v_order := nullif(p_vars->>'order_id','')::uuid;
    if v_order is not null then
      select coalesce(o.zone_id, pp.zone_id) into v_zone
        from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
       where o.id = v_order;
    end if;
  end if;
  if v_zone is null then return null; end if;

  select rp.id into v_pid from region_partners rp
   where rp.zone_id = v_zone and coalesce(rp.is_active,true) order by rp.id limit 1;
  return v_pid;
end $function$;

-- ── The fan-out ─────────────────────────────────────────────────────────────
-- One recipient row per active staff member, and the channel is decided by what
-- that member actually has:
--   * a phone  -> notify(), which is push-first with WhatsApp behind it;
--   * no phone -> notif_push_send() addressed by USER ID, the same dispatcher
--     notify() would have called. A partner staffer who signed in with Google
--     and never gave a number is exactly the common case, and dropping her
--     because the audience was modelled as "a phone" was the bug in waiting.
create or replace function public._partner_recipients(p_partner bigint)
returns table(user_id uuid, phone10 text)
language sql
stable security definer
set search_path to 'public'
as $function$
  select pu.auth_user_id,
         nullif((select p from (values
             (right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10)),
             (right(regexp_replace(coalesce(pu.identity,''),'\D','','g'),10)),
             (right(regexp_replace(coalesce(
                (select min(t.phone10) from push_tokens t
                  where t.is_active and t.user_id = pu.auth_user_id),''),'\D','','g'),10))
           ) as v(p) where length(p) = 10 limit 1), '')
    from partner_users pu
    join region_partners rp on rp.id = pu.partner_id
    left join auth.users u on u.id = pu.auth_user_id
   where pu.partner_id = p_partner
     and coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
$function$;

create or replace function public.notify_partner(p_event_key text, p_vars jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pid bigint; v_zone smallint; r record;
  v_vars jsonb := coalesce(p_vars,'{}'::jsonb);
  v_n int := 0; v_sent int := 0; v_fail int := 0; v_push int := 0; v_res jsonb;
begin
  if coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_event_key');
  end if;

  v_pid := public._partner_for_event(v_vars);
  if v_pid is null then
    perform public.notify_log(p_event_key, null, 'push', 'skipped', 'none',
      null, 'no_partner_for_zone', null,
      nullif(v_vars->>'order_id','')::uuid, null, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_partner_for_zone');
  end if;

  select rp.zone_id::smallint into v_zone from region_partners rp where rp.id = v_pid;
  v_vars := v_vars || jsonb_build_object('partner_id', v_pid::text,
                                         'zone_id', coalesce(v_zone,0)::text);

  for r in select * from public._partner_recipients(v_pid) loop
    v_n := v_n + 1;
    begin
      if coalesce(r.phone10,'') <> '' then
        v_res := public.notify(p_event_key, r.phone10, v_vars);
      elsif r.user_id is not null then
        v_res := public.notif_push_send(p_event_key, null, r.user_id,
                   nullif(v_vars->>'order_id','')::uuid, v_vars, 'partner');
        v_push := v_push + 1;
      else
        v_res := jsonb_build_object('ok', false, 'reason','no_channel');
      end if;
      if coalesce((v_res->>'ok')::boolean,false) then v_sent := v_sent + 1;
      else v_fail := v_fail + 1; end if;
    exception when others then
      v_fail := v_fail + 1;
    end;
  end loop;

  if v_n = 0 then
    perform public.notify_log(p_event_key, null, 'push', 'skipped', 'none',
      null, 'no_partner_recipient', null,
      nullif(v_vars->>'order_id','')::uuid, null, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_partner_recipient',
                              'partner_id', v_pid);
  end if;

  return jsonb_build_object('ok', v_sent > 0, 'partner_id', v_pid,
    'zone_id', v_zone, 'recipients', v_n, 'push_only', v_push,
    'sent', v_sent, 'failed', v_fail);
end $function$;

revoke all on function public.notify_partner(text, jsonb) from public, anon, authenticated;
grant execute on function public.notify_partner(text, jsonb) to service_role;

-- ── The four events a partner must not miss ─────────────────────────────────
-- Wording lives here, in the route row, exactly like every other event: a
-- re-word is an UPDATE, never a deploy.
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, push_enabled, email_enabled,
   auto_manage, wa_category, deep_link_kind, push_title, push_body)
values
  ('partner_order_placed',      'Partner · new order',
   'A new order landed in this partner''s zone.', 'partner', true, true, false,
   false, 'utility', '/partner', 'New order in your zone',
   '{{customer}} · {{amount}} · {{order_code}}'),
  ('partner_payment_verified',  'Partner · payment verified',
   'A customer payment for an order in this zone was verified.', 'partner', true, true, false,
   false, 'utility', '/partner', 'Payment verified',
   '{{customer}} paid {{amount}} · {{order_code}}'),
  ('partner_delivery_failed',   'Partner · delivery failed',
   'A delivery in this zone came back failed.', 'partner', true, true, false,
   false, 'utility', '/partner', 'Delivery failed',
   '{{order_code}} could not be delivered · {{reason}}'),
  ('partner_settlement_ready',  'Partner · settlement statement',
   'This partner''s settlement statement for the period is ready.', 'partner', true, true, false,
   false, 'utility', '/partner', 'Settlement statement ready',
   '{{period}} · your share {{amount}}')
on conflict (event_key) do update
  set audience = excluded.audience,
      push_enabled = excluded.push_enabled,
      deep_link_kind = excluded.deep_link_kind,
      push_title = excluded.push_title,
      push_body  = excluded.push_body;

-- ── Issue auto-solved: the push dispatcher could not address a PERSON ────────
-- notif_push_send() takes a user_id, and every caller until now passed a phone
-- with it. A partner staffer who signed in with Google has no phone at all, so
-- the log insert hit `null value in column "recipient"` and the push died with
-- a raise instead of a reply. order_alert_push() already had the answer —
-- fall back to the user id as the recipient key — so that same fallback is
-- applied here rather than inventing a second convention.
create or replace function public.notif_push_send(p_event_key text, p_phone10 text,
  p_user_id uuid default null, p_order_id uuid default null,
  p_vars jsonb default '{}'::jsonb, p_audience text default 'customer')
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare
  cfg record; r record; u record;
  v_tokens jsonb; v_lang text; v_title text; v_body text; v_link text;
  v_log_id bigint; v_sent int := 0; v_users int := 0; v_req bigint;
begin
  select * into cfg from push_config where id = 'singleton';
  if cfg.id is null or not cfg.enabled or coalesce(nullif(btrim(cfg.sender_id),''),'') = '' then
    return jsonb_build_object('ok', false, 'reason','push_not_configured');
  end if;

  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('ok', false, 'reason','unknown_event');
  end if;
  if not coalesce(r.push_enabled, false) then
    return jsonb_build_object('ok', false, 'reason','push_disabled_for_event');
  end if;
  if coalesce(nullif(btrim(r.push_body),''),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_push_body');
  end if;

  for u in
    select t.user_id, min(t.phone10) as phone10,
           jsonb_agg(distinct t.token) as tokens
      from push_tokens t
     where t.is_active
       and ( (p_user_id is not null and t.user_id = p_user_id)
          or (p_phone10  is not null and t.phone10 = p_phone10) )
     group by t.user_id
  loop
    v_users := v_users + 1;
    if not public.notif_user_allows(u.user_id, coalesce(r.audience,p_audience), p_event_key, 'push') then
      continue;
    end if;

    v_lang  := public.notif_language_for(u.user_id, coalesce(u.phone10, p_phone10), null);
    v_title := public.notif_render(
                 case when v_lang = 'hi' then coalesce(nullif(r.push_title_hi,''), r.push_title)
                      else r.push_title end, p_vars);
    v_body  := public.notif_render(
                 case when v_lang = 'hi' then coalesce(nullif(r.push_body_hi,''), r.push_body)
                      else r.push_body end, p_vars);
    v_link  := public.notif_deep_link(p_event_key, p_order_id, coalesce(r.audience,p_audience), p_vars);
    v_tokens := u.tokens;

    insert into notification_log (event_key, recipient, channel, status, ok,
            audience, recipient_id, user_id, order_id, customer_id, title, body,
            deep_link, language, vars, payload, path)
    values (p_event_key,
            coalesce(nullif(btrim(u.phone10),''), nullif(btrim(p_phone10),''), u.user_id::text),
            'push', 'queued', null,
            coalesce(r.audience, p_audience), u.user_id, u.user_id, p_order_id,
            nullif(p_vars->>'customer_id','')::uuid, v_title, v_body, v_link, v_lang,
            coalesce(p_vars,'{}'::jsonb),
            jsonb_build_object('tokens', jsonb_array_length(v_tokens)), 'push')
    returning id into v_log_id;

    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('log_id', v_log_id, 'tokens', v_tokens,
                                    'title', v_title, 'body', v_body,
                                    'deep_link', v_link,
                                    'event_key', p_event_key,
                                    'order_id', p_order_id),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  if v_users = 0 then
    return jsonb_build_object('ok', false, 'reason','no_active_token');
  end if;
  if v_sent = 0 then
    return jsonb_build_object('ok', false, 'reason','push_opted_out');
  end if;
  -- The reply shape is UNCHANGED from the version this replaces: notify() logs
  -- `reason` verbatim on the push path, so renaming a key here would quietly
  -- rewrite the ledger for every audience.
  return jsonb_build_object('ok', true, 'reason','push_queued',
                            'users', v_sent, 'log_id', v_log_id);
end $function$;

-- ── The wiring: four triggers, each one fact ────────────────────────────────
create or replace function public.trg_partner_order_placed()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  begin
    perform public.notify_partner('partner_order_placed', jsonb_build_object(
      'order_id',   new.id::text,
      'order_code', coalesce(new.order_code, new.payment_id, ''),
      'customer',   coalesce(new.pharmacy_name,''),
      'amount',     public.inr_money(coalesce(new.total_amount,0))));
  exception when others then null;   -- a notification must never fail an order
  end;
  return new;
end $function$;

drop trigger if exists trg_partner_order_placed on public.orders;
create trigger trg_partner_order_placed
  after insert on public.orders
  for each row execute function public.trg_partner_order_placed();

create or replace function public.trg_partner_payment_verified()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_name text;
begin
  if coalesce(new.status,'') = 'verified'
     and coalesce(old.status,'') is distinct from 'verified'
     and new.order_id is not null then
    begin
      select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(o.pharmacy_name),''), '')
        into v_name
        from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
       where o.id = new.order_id;
      perform public.notify_partner('partner_payment_verified', jsonb_build_object(
        'order_id',   new.order_id::text,
        'order_code', coalesce((select coalesce(o.order_code,o.payment_id,'')
                                  from orders o where o.id = new.order_id),''),
        'customer',   coalesce(v_name,''),
        'amount',     public.inr_money(coalesce(new.amount,0))));
    exception when others then null;
    end;
  end if;
  return new;
end $function$;

drop trigger if exists trg_partner_payment_verified on public.payment_claims;
create trigger trg_partner_payment_verified
  after update on public.payment_claims
  for each row execute function public.trg_partner_payment_verified();

create or replace function public.trg_partner_delivery_failed()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(new.status,'') in ('failed','rto')
     and coalesce(old.status,'') is distinct from coalesce(new.status,'') then
    begin
      perform public.notify_partner('partner_delivery_failed', jsonb_build_object(
        'order_id',   new.order_id::text,
        'zone_id',    coalesce(new.zone_id,0)::text,
        'order_code', coalesce((select coalesce(o.order_code,o.payment_id,'')
                                  from orders o where o.id = new.order_id),''),
        'reason',     coalesce(nullif(btrim(new.fail_reason),''), new.status)));
    exception when others then null;
    end;
  end if;
  return new;
end $function$;

do $$ begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='deliveries'
                and column_name='fail_reason') then
    execute 'drop trigger if exists trg_partner_delivery_failed on public.deliveries';
    execute 'create trigger trg_partner_delivery_failed after update on public.deliveries
             for each row execute function public.trg_partner_delivery_failed()';
  end if;
end $$;

create or replace function public.trg_partner_settlement_ready()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(new.status,'') in ('due','settled')
     and coalesce(old.status,'') is distinct from coalesce(new.status,'') then
    begin
      perform public.notify_partner('partner_settlement_ready', jsonb_build_object(
        'partner_id', new.partner_id::text,
        'zone_id',    coalesce(new.zone_id,0)::text,
        'period',     to_char(new.period_start,'DD Mon') || ' – ' || to_char(new.period_end,'DD Mon YYYY'),
        'amount',     public.inr_money(coalesce(new.partner_share,0))));
    exception when others then null;
    end;
  end if;
  return new;
end $function$;

drop trigger if exists trg_partner_settlement_ready on public.partner_settlement_periods;
create trigger trg_partner_settlement_ready
  after update on public.partner_settlement_periods
  for each row execute function public.trg_partner_settlement_ready();

-- ── Recorded verification ───────────────────────────────────────────────────
create or replace function public.c398_notify_proof()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'partner_routes', (select count(*) from wa_event_routes where audience='partner'),
    'route_keys',     (select coalesce(jsonb_agg(event_key order by event_key),'[]'::jsonb)
                         from wa_event_routes where audience='partner'),
    'triggers',       (select coalesce(jsonb_agg(tgname order by tgname),'[]'::jsonb)
                         from pg_trigger where tgname like 'trg_partner_%' and not tgisinternal),
    'recipients_zone1', (select count(*) from public._partner_recipients(
                           (select rp.id from region_partners rp
                             where coalesce(rp.is_active,true) order by rp.id limit 1))),
    'recipients_with_phone', (select count(*) from public._partner_recipients(
                           (select rp.id from region_partners rp
                             where coalesce(rp.is_active,true) order by rp.id limit 1))
                          where coalesce(phone10,'') <> ''),
    'supplier_routes_untouched',
                      (select count(*) from wa_event_routes where audience='supplier'))
$function$;
grant execute on function public.c398_notify_proof() to service_role;

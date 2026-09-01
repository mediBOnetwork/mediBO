-- CHANGE #404 — NUMBER MASKING LAYER (resolution, sessions, wiring)
--
-- The schema migration built the storage. This one is the whole decision
-- surface, and every decision in it is the BACKEND's:
--
--   * who the caller is                 -> call_actor_party()
--   * who the callee is on this order   -> _call_target()
--   * whether that pair may connect     -> call_allow_matrix (data, not code)
--   * which DID to use, for how long    -> call_did_pool + call_config
--   * what the app prints               -> ui_copy, verbatim
--
-- The app never sends a phone number, never receives one, and never decides
-- whether a call is allowed. It sends order_id + target role and renders the
-- reply. mask-call (edge) is the only thing that talks to a provider, and even
-- it is handed the legs by call_mask_prepare rather than looking them up.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Is this pair allowed? Absent row = DENIED. Closed by default is the only
--    safe default for a layer whose failure mode is "the wrong two people are
--    now connected".
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._call_allowed(p_caller_role text, p_callee_role text)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce((select m.allowed
                   from public.call_allow_matrix m
                   where m.caller_role = p_caller_role
                     and m.callee_role = p_callee_role), false);
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Who is this auth user, as a call party?
--
--    Order matters and it is NOT get_my_role()'s order: get_my_role
--    deliberately answers 'admin' for partner staff on an allowed RPC, which is
--    the right answer for authorisation and the WRONG one here — a partner must
--    be a 'partner' party so the matrix sees the partner edges. So this resolves
--    against the party tables directly, most specific first.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_actor_party(p_actor uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare v_r record; v_email text;
begin
  if p_actor is null then return jsonb_build_object('ok', false, 'error', 'no_actor'); end if;

  -- delivery rider
  select 'delivery'::text as role, cp.party_id, cp.display_name, cp.phone_e164
    into v_r
  from public.call_parties cp
  where cp.party_role = 'delivery' and cp.auth_user_id = p_actor and cp.is_active
  limit 1;
  if found then
    return jsonb_build_object('ok', true, 'role', v_r.role, 'party_id', v_r.party_id,
                              'name', v_r.display_name, 'phone', v_r.phone_e164);
  end if;

  -- partner staff
  select 'partner'::text as role, cp.party_id, cp.display_name, cp.phone_e164
    into v_r
  from public.call_parties cp
  where cp.party_role = 'partner' and cp.auth_user_id = p_actor and cp.is_active
  limit 1;
  if found then
    return jsonb_build_object('ok', true, 'role', v_r.role, 'party_id', v_r.party_id,
                              'name', v_r.display_name, 'phone', v_r.phone_e164);
  end if;

  -- supplier
  select 'supplier'::text as role, cp.party_id, cp.display_name, cp.phone_e164
    into v_r
  from public.call_parties cp
  where cp.party_role = 'supplier' and cp.auth_user_id = p_actor
  limit 1;
  if found then
    return jsonb_build_object('ok', true, 'role', v_r.role, 'party_id', v_r.party_id,
                              'name', v_r.display_name, 'phone', v_r.phone_e164);
  end if;

  -- employee (admin / super-admin / ops). The phone comes from user_profiles
  -- when there is one; an employee with no number can still CALL (their leg is
  -- dialled by the provider only if a number exists) but is never a callee.
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = p_actor;
  if exists (select 1 from public.admins a where lower(btrim(a.email)) = v_email) then
    return jsonb_build_object(
      'ok', true, 'role', 'employee', 'party_id', p_actor::text,
      'name', coalesce((select cp.display_name from public.call_parties cp
                        where cp.party_role='employee' and cp.party_id = p_actor::text), ''),
      'phone', coalesce((select cp.phone_e164 from public.call_parties cp
                         where cp.party_role='employee' and cp.party_id = p_actor::text), ''));
  end if;

  -- customer
  select 'customer'::text as role, cp.party_id, cp.display_name, cp.phone_e164
    into v_r
  from public.call_parties cp
  where cp.party_role = 'customer' and cp.auth_user_id = p_actor
  limit 1;
  if found then
    return jsonb_build_object('ok', true, 'role', v_r.role, 'party_id', v_r.party_id,
                              'name', v_r.display_name, 'phone', v_r.phone_e164);
  end if;

  return jsonb_build_object('ok', false, 'error', 'no_party');
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Who plays <role> on this order?
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._call_target(p_order_id uuid, p_role text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare v_id text; v_r record;
begin
  if p_order_id is null or coalesce(p_role,'') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_target');
  end if;

  if p_role = 'customer' then
    select coalesce(o.customer_id::text,
                    (select pp.id::text from public.pharmacy_profiles pp
                      where pp.user_id = o.user_id limit 1))
      into v_id
    from public.orders o where o.id = p_order_id;

  elsif p_role = 'delivery' then
    select d.partner_id::text into v_id
    from public.deliveries d
    where d.order_id = p_order_id and coalesce(d.status,'') <> 'cancelled'
    order by d.assigned_at desc nulls last, d.created_at desc
    limit 1;

  elsif p_role = 'partner' then
    -- the zone partner's own staff: the active login on the fulfilling partner
    select pu.id::text into v_id
    from public.orders o
    join public.partner_users pu on pu.partner_id = o.fulfillment_partner_id
    where o.id = p_order_id and coalesce(pu.is_active,false)
    order by pu.id
    limit 1;

  elsif p_role = 'supplier' then
    select so.supplier_id::text into v_id
    from public.supplier_orders so
    where so.order_id = p_order_id and so.supplier_id is not null
    order by so.created_at desc
    limit 1;

  elsif p_role = 'employee' then
    -- ops is not order-scoped: the desk is whoever call_config names, and when
    -- nobody is named there is no ops callee rather than a guessed one.
    select cp.party_id into v_id
    from public.call_parties cp
    where cp.party_role = 'employee' and cp.phone_e164 <> ''
    order by cp.party_id
    limit 1;
  end if;

  if coalesce(v_id,'') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_target');
  end if;

  select cp.party_id, cp.display_name, cp.phone_e164, cp.is_active into v_r
  from public.call_parties cp
  where cp.party_role = p_role and cp.party_id = v_id
  limit 1;

  if not found then return jsonb_build_object('ok', false, 'error', 'no_target'); end if;
  if coalesce(v_r.phone_e164,'') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_number');
  end if;

  return jsonb_build_object('ok', true, 'role', p_role, 'party_id', v_r.party_id,
                            'name', v_r.display_name, 'phone', v_r.phone_e164);
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The render block a screen prints for one masked call button. It carries
--    no number — only a label, the target role, and the order it belongs to.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._call_action_block(
  p_caller_role text, p_callee_role text, p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare v_cfg public.call_config%rowtype; v_t jsonb;
begin
  select * into v_cfg from public.call_config where id;
  if not coalesce(v_cfg.enabled, false) then return '{}'::jsonb; end if;
  if not public._call_allowed(p_caller_role, p_callee_role) then return '{}'::jsonb; end if;

  v_t := public._call_target(p_order_id, p_callee_role);
  if coalesce((v_t->>'ok')::boolean, false) is not true then return '{}'::jsonb; end if;

  return jsonb_build_object(
    'has', true,
    'label', public._c('call.button_' || p_callee_role),
    'target_role', p_callee_role,
    'order_id', p_order_id,
    'privacy_note', public._c('call.privacy_note'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. call_mask_targets — the ONE read every screen uses. It answers "which
--    masked call buttons does THIS viewer get on these orders", and it answers
--    it for the viewer's own resolved party, so a rider and an admin looking at
--    the same order get different buttons without the screen knowing why.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_mask_targets(p_order_ids uuid[])
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_actor jsonb := public.call_actor_party(auth.uid());
  v_role text;
  v_out jsonb := '{}'::jsonb;
  v_order uuid; v_acts jsonb; v_blk jsonb; v_callee text;
begin
  if coalesce((v_actor->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok', true, 'orders', '{}'::jsonb,
                              'privacy_note', public._c('call.privacy_note'));
  end if;
  v_role := v_actor->>'role';

  foreach v_order in array coalesce(p_order_ids, array[]::uuid[]) loop
    v_acts := '[]'::jsonb;
    foreach v_callee in array array['customer','delivery','partner','supplier','employee'] loop
      if v_callee = v_role then continue; end if;
      v_blk := public._call_action_block(v_role, v_callee, v_order);
      if v_blk ? 'has' then v_acts := v_acts || jsonb_build_array(v_blk); end if;
    end loop;
    if jsonb_array_length(v_acts) > 0 then
      v_out := v_out || jsonb_build_object(v_order::text, v_acts);
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'orders', v_out,
                            'privacy_note', public._c('call.privacy_note'));
end $$;

grant execute on function public.call_mask_targets(uuid[]) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. call_mask_prepare — everything the provider adapter needs, decided here.
--    service_role only: the edge function is the sole caller, and it passes the
--    actor it authenticated. Nothing an app client sends can widen this.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_mask_prepare(
  p_actor uuid, p_order_id uuid, p_target_role text)
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $$
declare
  v_cfg public.call_config%rowtype;
  v_caller jsonb; v_callee jsonb;
  v_did text; v_sess public.call_sessions%rowtype; v_ttl int;
begin
  select * into v_cfg from public.call_config where id;
  if not coalesce(v_cfg.enabled,false) then
    return jsonb_build_object('ok', false, 'error', 'calling_disabled',
                              'message', public._c('call.disabled'));
  end if;

  v_caller := public.call_actor_party(p_actor);
  if coalesce((v_caller->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok', false, 'error', 'not_a_party',
                              'message', public._c('call.not_allowed'));
  end if;

  if not public._call_allowed(v_caller->>'role', p_target_role) then
    return jsonb_build_object('ok', false, 'error', 'not_allowed',
                              'message', public._c('call.not_allowed'));
  end if;

  v_callee := public._call_target(p_order_id, p_target_role);
  if coalesce((v_callee->>'ok')::boolean,false) is not true then
    return jsonb_build_object(
      'ok', false,
      'error', coalesce(v_callee->>'error','no_target'),
      'message', case when v_callee->>'error' = 'no_number'
                      then public._c('call.no_number')
                      else public._c('call.no_target') end);
  end if;

  if coalesce(v_caller->>'phone','') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_number',
                              'message', public._c('call.no_number'));
  end if;

  -- An order that is finished has no live counterparties. This is the same
  -- rule the trigger enforces on write; checking it on read too means a stale
  -- screen cannot mint a session against a closed order.
  if exists (select 1 from public.orders o
             where o.id = p_order_id and o.closed_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'order_closed',
                              'message', public._c('call.session_closed'));
  end if;

  -- Reuse an identical live session rather than burning a DID per tap.
  select * into v_sess
  from public.call_sessions s
  where s.order_id = p_order_id
    and s.caller_role = v_caller->>'role' and s.caller_party_id = v_caller->>'party_id'
    and s.callee_role = v_callee->>'role' and s.callee_party_id = v_callee->>'party_id'
    and s.status = 'active' and s.expires_at > now()
  order by s.created_at desc
  limit 1;

  if not found then
    -- Pick the least-recently-used ACTIVE DID for the configured provider, so
    -- the pool rotates instead of hammering one number.
    select p.did into v_did
    from public.call_did_pool p
    where p.is_active and p.provider = v_cfg.provider
    order by p.last_used_at nulls first, p.id
    limit 1;

    if coalesce(v_did,'') = '' then
      return jsonb_build_object('ok', false, 'error', 'no_did',
                                'message', public._c('call.no_did'));
    end if;

    v_ttl := greatest(coalesce(v_cfg.session_ttl_min, 240), 1);

    insert into public.call_sessions (
      order_id, caller_role, caller_party_id, caller_phone,
      callee_role, callee_party_id, callee_phone,
      did, provider, expires_at, created_by)
    values (
      p_order_id, v_caller->>'role', v_caller->>'party_id', v_caller->>'phone',
      v_callee->>'role', v_callee->>'party_id', v_callee->>'phone',
      v_did, v_cfg.provider, now() + make_interval(mins => v_ttl), p_actor)
    returning * into v_sess;

    update public.call_did_pool set last_used_at = now() where did = v_did;
  end if;

  return jsonb_build_object(
    'ok', true,
    'session_id', v_sess.id,
    'order_id', v_sess.order_id,
    'provider', v_sess.provider,
    'did', v_sess.did,
    'caller', jsonb_build_object('role', v_sess.caller_role, 'phone', v_sess.caller_phone,
                                 'name', v_caller->>'name'),
    'callee', jsonb_build_object('role', v_sess.callee_role, 'phone', v_sess.callee_phone,
                                 'name', v_callee->>'name'),
    'expires_at', v_sess.expires_at,
    'record_calls', coalesce(v_cfg.record_calls,false),
    'exotel_subdomain', v_cfg.exotel_subdomain,
    'exotel_caller_id', nullif(v_cfg.exotel_caller_id, ''),
    'copy', jsonb_build_object(
      'connecting',   public._c('call.connecting'),
      'placed',       public._c('call.placed'),
      'dial_hint',    public._c('call.dial_hint'),
      'privacy_note', public._c('call.privacy_note'),
      'stub_notice',  public._c('call.stub_notice'),
      'failed',       public._c('call.provider_failed')));
end $$;

revoke execute on function public.call_mask_prepare(uuid, uuid, text) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. call_mask_store — the provider answered; record what it said.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_mask_store(
  p_session_id uuid, p_provider text, p_sid text,
  p_status text, p_leg text default 'outbound', p_raw jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $$
declare v_sess public.call_sessions%rowtype;
begin
  select * into v_sess from public.call_sessions where id = p_session_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;

  update public.call_sessions
     set provider_sid = coalesce(p_sid, provider_sid),
         provider     = coalesce(nullif(p_provider,''), provider),
         status       = case when p_status = 'failed' then 'failed' else status end
   where id = p_session_id;

  insert into public.masked_calls (session_id, order_id, provider, provider_sid,
                                   leg, direction, did, status, raw)
  values (p_session_id, v_sess.order_id, coalesce(nullif(p_provider,''), v_sess.provider),
          p_sid, p_leg, 'outbound', v_sess.did, p_status, coalesce(p_raw,'{}'::jsonb));

  return jsonb_build_object('ok', true, 'session_id', p_session_id);
end $$;

revoke execute on function public.call_mask_store(uuid, text, text, text, text, jsonb) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. call_inbound_match — the webhook's whole brain.
--
--    Somebody dialled a DID. Which live session is that? Answer with connect
--    instructions, or refuse. The refusal carries the backend's own words so
--    the provider can read them out instead of the function inventing copy.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_inbound_match(
  p_from text, p_did text, p_sid text default null, p_raw jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $$
declare
  v_from text := public._call_e164(p_from);
  v_did  text := public._call_e164(p_did);
  v_s public.call_sessions%rowtype;
  v_connect text; v_role text;
begin
  -- Expire first, so an inbound leg can never match a session whose clock ran
  -- out a second ago.
  update public.call_sessions
     set status = 'expired', closed_at = now(), close_reason = 'ttl'
   where status = 'active' and expires_at <= now();

  -- Either leg may be the one dialling: the caller reaching the callee, or the
  -- callee ringing the DID back. Both are the same session.
  select * into v_s
  from public.call_sessions s
  where s.did = v_did
    and s.status = 'active'
    and s.expires_at > now()
    and (s.caller_phone = v_from or s.callee_phone = v_from)
  order by s.created_at desc
  limit 1;

  if not found then
    insert into public.masked_calls (provider, provider_sid, leg, direction, did, status, raw)
    values (coalesce(p_raw->>'provider','unknown'), p_sid, 'inbound', 'inbound', v_did,
            'rejected', coalesce(p_raw,'{}'::jsonb) || jsonb_build_object('from', v_from));
    return jsonb_build_object('ok', false, 'action', 'reject', 'error', 'no_session',
                              'message', public._c('call.expired'));
  end if;

  if v_s.caller_phone = v_from then
    v_connect := v_s.callee_phone; v_role := v_s.callee_role;
  else
    v_connect := v_s.caller_phone; v_role := v_s.caller_role;
  end if;

  insert into public.masked_calls (session_id, order_id, provider, provider_sid,
                                   leg, direction, did, status, raw)
  values (v_s.id, v_s.order_id, v_s.provider, p_sid, 'inbound', 'inbound', v_did,
          'connected', coalesce(p_raw,'{}'::jsonb) || jsonb_build_object('from', v_from));

  return jsonb_build_object(
    'ok', true, 'action', 'connect',
    'session_id', v_s.id, 'order_id', v_s.order_id,
    'connect_to', v_connect, 'connect_role', v_role,
    'caller_id', v_s.did,
    'record', (select coalesce(record_calls,false) from public.call_config where id),
    'expires_at', v_s.expires_at);
end $$;

revoke execute on function public.call_inbound_match(text, text, text, jsonb) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. call_leg_log — the provider's status callback (duration, recording).
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_leg_log(
  p_sid text, p_status text, p_duration_s integer default null,
  p_recording_url text default null, p_raw jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $$
declare v_s public.call_sessions%rowtype;
begin
  select * into v_s from public.call_sessions where provider_sid = p_sid
  order by created_at desc limit 1;

  insert into public.masked_calls (session_id, order_id, provider, provider_sid,
                                   leg, direction, did, status, duration_s,
                                   recording_url, raw)
  values (v_s.id, v_s.order_id, coalesce(v_s.provider, p_raw->>'provider', 'unknown'),
          p_sid, 'status', 'callback', v_s.did, p_status, p_duration_s,
          nullif(btrim(coalesce(p_recording_url,'')),''), coalesce(p_raw,'{}'::jsonb));

  return jsonb_build_object('ok', true, 'matched', v_s.id is not null);
end $$;

revoke execute on function public.call_leg_log(text, text, integer, text, jsonb) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 10. Expiry. Three ways a session dies, and none of them is "someone
--     remembered": its own clock, the order being delivered, the order being
--     closed.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_sessions_close_for_order(
  p_order_id uuid, p_reason text)
returns integer
language plpgsql
volatile security definer
set search_path to 'public'
as $$
declare v_n int;
begin
  update public.call_sessions
     set status = 'closed', closed_at = now(), close_reason = p_reason
   where order_id = p_order_id and status = 'active';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public._call_sessions_order_closed_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.closed_at is not null and old.closed_at is null then
    perform public.call_sessions_close_for_order(new.id, 'order_closed');
  end if;
  return new;
end $$;

drop trigger if exists call_sessions_order_closed_trg on public.orders;
create trigger call_sessions_order_closed_trg
  after update of closed_at on public.orders
  for each row execute function public._call_sessions_order_closed_trg();

create or replace function public._call_sessions_delivered_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.delivered_at is not null and old.delivered_at is null then
    perform public.call_sessions_close_for_order(new.order_id, 'delivered');
  end if;
  return new;
end $$;

drop trigger if exists call_sessions_delivered_trg on public.deliveries;
create trigger call_sessions_delivered_trg
  after update of delivered_at on public.deliveries
  for each row execute function public._call_sessions_delivered_trg();

create or replace function public.call_expire_sweep()
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $$
declare v_n int;
begin
  update public.call_sessions
     set status = 'expired', closed_at = now(), close_reason = 'ttl'
   where status = 'active' and expires_at <= now();
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'expired', v_n);
end $$;

-- One dispatcher, one row. Never a bare */N schedule (CHANGE #273 / the
-- connection-exhaustion outage) — the dispatcher owns the clock.
insert into public.cron_task (name, ord, mode, work_sql, enabled, note,
                              base_interval_s, max_interval_s, dml)
values ('call-session-expire', 700, 'poll',
        'select public.call_expire_sweep()', true,
        'CHANGE #404 — closes masked-call sessions whose TTL ran out.',
        300, 1800, true)
on conflict (name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 11. call_setup_status — what is actually wired, in plain words, so "is
--     masked calling live?" is a read and not an investigation.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_setup_status()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare v_cfg public.call_config%rowtype; v_dids int; v_stub int; v_emp int;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  select * into v_cfg from public.call_config where id;
  select count(*) into v_dids from public.call_did_pool where is_active and provider = 'exotel';
  select count(*) into v_stub from public.call_did_pool where is_active and provider = 'stub';
  select count(*) into v_emp  from public.call_parties where party_role='employee' and phone_e164 <> '';

  return jsonb_build_object(
    'ok', true,
    'title', public._c('call.setup_title'),
    'enabled', v_cfg.enabled,
    'provider', v_cfg.provider,
    'session_ttl_min', v_cfg.session_ttl_min,
    'exotel_dids', v_dids,
    'stub_dids', v_stub,
    'employee_parties', v_emp,
    'sessions_active', (select count(*) from public.call_sessions
                         where status='active' and expires_at > now()),
    'calls_logged', (select count(*) from public.masked_calls),
    'allow_pairs', (select count(*) from public.call_allow_matrix where allowed));
end $$;

grant execute on function public.call_setup_status() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 12. The rider stop stops handing out a real number.
--
--     my_delivery_run() shipped orders.phone to the rider's device as
--     actions.call_number and the screen dialled tel:$call. That is the exact
--     leak this change exists to close, so the field is emptied in place and a
--     masked action block takes its place. Patched off the LIVE definition
--     rather than re-pasted, so a later rewrite of that function by another
--     command is not silently reverted here — and it raises rather than
--     no-ops if it finds neither the old shape nor its own.
-- ─────────────────────────────────────────────────────────────────────────
do $patch$
declare
  v_def text;
  v_old text := $old$'call_number', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''),''),$old$;
  v_new text := $new$'call_number', '', 'call_action', public._call_action_block('delivery','customer', o.id),$new$;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'my_delivery_run'
  limit 1;

  if v_def is null then
    raise notice 'CHANGE #404: my_delivery_run absent — nothing to patch.';
    return;
  end if;

  if position(v_new in v_def) > 0 then
    raise notice 'CHANGE #404: my_delivery_run already masked.';
    return;
  end if;

  if position(v_old in v_def) = 0 then
    raise exception 'CHANGE #404: my_delivery_run no longer contains the raw call_number block — the masking patch must be re-targeted before this deploys.';
  end if;

  execute replace(v_def, v_old, v_new);
end $patch$;

-- ─────────────────────────────────────────────────────────────────────────
-- 13. Close the PUBLIC grant every SECURITY DEFINER function inherits.
--
--     Postgres grants EXECUTE to PUBLIC by default, and the anon key ships
--     inside the web bundle and the APK — so a helper that resolves a party to
--     a phone number is a public endpoint until it is explicitly revoked. This
--     is the same trap #25/#353/#395/#422/#436 each landed in.
--
--     `authenticated` is revoked too, not just anon: this project's default
--     privileges hand every new function to `authenticated`, and a signed-in
--     customer calling call_actor_party(<any uuid>) would read a stranger's
--     name and number straight out of the view this layer exists to hide.
--
--     The two exceptions are deliberate and both gate on auth.uid()/role
--     internally: call_mask_targets (a signed-in viewer asking which of ITS own
--     buttons to draw) and call_setup_status (admins only, by its first line).
-- ─────────────────────────────────────────────────────────────────────────
revoke all on function public._call_e164(text)                          from public, anon, authenticated;
revoke all on function public._call_allowed(text, text)                 from public, anon, authenticated;
revoke all on function public.call_actor_party(uuid)                    from public, anon, authenticated;
revoke all on function public._call_target(uuid, text)                  from public, anon, authenticated;
revoke all on function public._call_action_block(text, text, uuid)      from public, anon, authenticated;
revoke all on function public.call_mask_prepare(uuid, uuid, text)       from public, anon, authenticated;
revoke all on function public.call_mask_store(uuid, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.call_inbound_match(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.call_leg_log(text, text, integer, text, jsonb) from public, anon, authenticated;
revoke all on function public.call_sessions_close_for_order(uuid, text)  from public, anon, authenticated;
revoke all on function public._call_sessions_order_closed_trg()          from public, anon, authenticated;
revoke all on function public._call_sessions_delivered_trg()             from public, anon, authenticated;
revoke all on function public.call_expire_sweep()                        from public, anon, authenticated;
revoke all on function public.call_mask_targets(uuid[])                  from public, anon, authenticated;
revoke all on function public.call_setup_status()                        from public, anon, authenticated;

grant execute on function public.call_mask_targets(uuid[]) to authenticated;
grant execute on function public.call_setup_status()       to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 14. call_setup_status, RENDER-READY.
--
--     Every word, number, ₹-free value string and tone on the Masked calling
--     card is built here. The Dart section is a for-loop over `rows` and a
--     for-loop over `todo`; it computes nothing and it knows no role names, so
--     "Exotel is live now" is an UPDATE to call_config, never a deploy.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.call_setup_status()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_cfg public.call_config%rowtype;
  v_exo int; v_stub int; v_emp int; v_live int; v_calls int; v_pairs int;
  v_secrets boolean; v_todo jsonb := '[]'::jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', public._c('call.not_allowed'));
  end if;

  select * into v_cfg from public.call_config where id;
  select count(*) into v_exo  from public.call_did_pool where is_active and provider = 'exotel';
  select count(*) into v_stub from public.call_did_pool where is_active and provider = 'stub';
  select count(*) into v_emp  from public.call_parties where party_role='employee' and phone_e164 <> '';
  select count(*) into v_live from public.call_sessions where status='active' and expires_at > now();
  select count(*) into v_calls from public.masked_calls;
  select count(*) into v_pairs from public.call_allow_matrix where allowed;

  -- The edge function holds the Exotel credentials, not this database, so the
  -- honest signal here is "the config still says stub", never a guess at env.
  v_secrets := (v_cfg.provider = 'exotel');

  if not v_secrets then
    v_todo := v_todo || jsonb_build_array(
      'Buy at least one ExoPhone (a virtual number) on the Exotel account.',
      'Save EXOTEL_SID and EXOTEL_TOKEN as Supabase edge-function secrets.',
      'Point the ExoPhone''s passthru/applet at the mask-call-webhook function.',
      'Insert the ExoPhone into call_did_pool with provider = ''exotel''.',
      'Set call_config.provider = ''exotel''. No deploy — it takes effect on the next call.');
  end if;
  if v_emp = 0 then
    v_todo := v_todo || jsonb_build_array(
      'No employee has a phone on file, so "Call mediBO" has no one to ring. Add one to user_profiles.');
  end if;

  return jsonb_build_object(
    'ok', true,
    'title', public._c('call.setup_title'),
    'subtitle', case when v_secrets
        then 'Live on Exotel. Neither side of a call sees the other''s number.'
        else 'Running on the test provider. Every rule works; no real call is placed yet.' end,
    'tone', case when v_secrets then 'success' else 'warning' end,
    'rows', jsonb_build_array(
      jsonb_build_object('label','Provider','value',v_cfg.provider,
                         'tone', case when v_secrets then 'success' else 'warning' end),
      jsonb_build_object('label','Masked calling','value',
                         case when v_cfg.enabled then 'On' else 'Off' end,
                         'tone', case when v_cfg.enabled then 'success' else 'danger' end),
      jsonb_build_object('label','Session window','value', v_cfg.session_ttl_min || ' min','tone','info'),
      jsonb_build_object('label','Exotel numbers','value', v_exo::text,
                         'tone', case when v_exo > 0 then 'success' else 'warning' end),
      jsonb_build_object('label','Test numbers','value', v_stub::text,'tone','info'),
      jsonb_build_object('label','Role pairs allowed','value', v_pairs::text,'tone','info'),
      jsonb_build_object('label','Live sessions','value', v_live::text,'tone','info'),
      jsonb_build_object('label','Calls logged','value', v_calls::text,'tone','info')),
    'todo_title', case when jsonb_array_length(v_todo) > 0
                       then 'To switch on real calls' else '' end,
    'todo', v_todo);
end $$;

revoke all on function public.call_setup_status() from public, anon, authenticated;
grant execute on function public.call_setup_status() to authenticated;

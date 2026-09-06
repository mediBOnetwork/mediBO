-- CMD #1848 — Test mode becomes a PER-USER session the REAL checkout honours.
--
-- Measured on production, 6 Sep 2026: Om, signed in as a REAL approved
-- pharmacy while his own test session was live, was refused with
-- account_pending_approval. The synthetic branch of enforce_order_approval
-- demanded a SYNTHETIC profile, so a real pharmacy could never place a test
-- order, and the error named the wrong reason.
--
-- What changes, and nothing else:
--   1. ONE reader — test_session_for(uid) — decides whose live session a
--      write belongs to. A human session stamps ONLY its owner's (and its
--      listed actors') writes. 'global' no longer means everyone.
--   2. _place_order_v2_core asks it once. No session → the function is
--      byte-identical to before (explicit is_synthetic=false / null session
--      are the column defaults; the lookup is wrapped so a failure is "no
--      test session", never a refused real order).
--   3. enforce_order_approval accepts a synthetic order from a REAL approved
--      profile when the order carries a live session owned by that user. The
--      bots' synthetic-profile path is untouched. The refusal is
--      test_mode.needs_session, not account_pending_approval.
--   4. RLS shadow tenant: a restrictive SELECT policy on every stamped table
--      returns a session-stamped row ONLY to that session's participants.
--      (Definer RPCs run as postgres, which BYPASSRLS — those are covered by
--      the checkout-surface checks in this command's proof, not by RLS.)
--   5. Hard outbound silence for human sessions: no WhatsApp, Razorpay,
--      push, email or admin paging for that session's rows. Not a toggle.
--   6. test_session_end_purge(): End & purge in one tap, owner-only, and the
--      banner is per-user and names WHOSE session it is.

begin;

-- ---------------------------------------------------------------------------
-- 1. THE READER.
-- ---------------------------------------------------------------------------
create or replace function public.test_session_for(p_uid uuid)
 returns bigint
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  if p_uid is null then return null; end if;
  if exists (select 1 from public.test_session_exempt e where e.user_id = p_uid) then
    return null;
  end if;
  select s.id into v_id
    from public.test_sessions s
   where s.status = 'live' and s.ended_at is null and now() < s.expires_at
     and coalesce(s.scope,'global') <> 'canary'
     and (s.started_by = p_uid
          or exists (select 1 from public.test_session_actor a
                      where a.session_id = s.id and a.user_id = p_uid))
   order by s.id desc
   limit 1;
  return v_id;
exception when others then
  -- A bug in test mode must never touch a real pharmacy's order: any failure
  -- here reads as NO TEST SESSION.
  return null;
end $$;

create or replace function public.test_session_mine()
 returns bigint
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_uid uuid;
begin
  begin v_uid := auth.uid(); exception when others then return null; end;
  return public.test_session_for(v_uid);
exception when others then
  return null;
end $$;

revoke all on function public.test_session_for(uuid) from public, anon;
grant execute on function public.test_session_for(uuid) to authenticated, service_role;
revoke all on function public.test_session_mine() from public;
grant execute on function public.test_session_mine() to anon, authenticated, service_role;

-- Every consumer routes through the reader.
create or replace function public._test_session_stamps(p_session bigint, p_scope text)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_uid uuid;
begin
  if p_session is null then return false; end if;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;

  if v_uid is not null and exists (
       select 1 from public.test_session_exempt e where e.user_id = v_uid) then
    return false;
  end if;

  -- The bot lane: a machine caller writing inside an automated session.
  if p_scope = 'automated' and public._test_caller_is_backend() then return true; end if;

  -- CMD #1848 — a person's session stamps ONLY its owner's and its actors'
  -- writes. A real pharmacy checking out while Om is testing is untouched.
  -- coalesce: a NULL here once read as "not false" in the caller's IF and
  -- stamped a stranger's order (caught by the build-branch scenario S2).
  return v_uid is not null and coalesce(public.test_session_for(v_uid) = p_session, false);
exception when others then
  return false;
end $$;

create or replace function public._test_session_ambient()
 returns bigint
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_scope text;
begin
  select id, scope into v_id, v_scope
    from public.test_sessions
   where status = 'live' and ended_at is null and now() < expires_at
   limit 1;
  if v_id is null then return null; end if;
  if not coalesce(public._test_session_stamps(v_id, v_scope), false) then return null; end if;
  return v_id;
exception when others then
  return null;
end $$;

create or replace function public._synthetic_inherit()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_key text; v_hit boolean; v_sess bigint; v_j jsonb; v_parent bigint;
begin
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- CMD #1848 — the ONE reader. Owner/actor of the live session, or the
    -- bot lane; anybody else's insert is never stamped.
    v_sess := public._test_session_ambient();
  end if;
  if v_sess is not null then
    new.is_synthetic := true;
    v_j := to_jsonb(new);
    if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
      new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_sess));
    end if;
    return new;
  end if;

  if coalesce(new.is_synthetic,false) then return new; end if;

  -- A legacy explicit run context (part 1) still stamps.
  if coalesce(current_setting('medibo.synthetic', true),'') = 'on' then
    new.is_synthetic := true;
    return new;
  end if;

  for r in select * from public.synthetic_inherit_rule
            where child_table = tg_table_name loop
    v_key := to_jsonb(new) ->> r.child_col;
    continue when v_key is null;
    execute format(
      'select p.is_synthetic, p.test_session_id from public.%I p where p.%I = $1::%s limit 1',
      r.parent_table, r.parent_col, r.parent_type)
      into v_hit, v_parent using v_key;
    if coalesce(v_hit,false) then
      new.is_synthetic := true;
      if v_parent is not null then
        v_j := to_jsonb(new);
        if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
          new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_parent));
        end if;
      end if;
      return new;
    end if;
  end loop;
  return new;
end $$;

-- A human session is scoped to its user from now on. History keeps its word.
update public.test_sessions set scope = 'user'
 where origin = 'human' and coalesce(scope,'global') = 'global' and status = 'live';

create or replace function public.test_session_start(p_label text DEFAULT NULL::text, p_hours numeric DEFAULT NULL::numeric)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_hours numeric; v_uid uuid; v_label text;
        v_origin text; v_scope text; v_cap numeric;
        v_live_id bigint; v_live_origin text; v_live_owner uuid;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not (select enabled from public.test_mode_config where id=1) then
    return jsonb_build_object('ok',false,'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_origin := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  if v_origin = 'automated' then v_uid := null; end if;

  update public.test_sessions
     set status='ended', ended_at=coalesce(ended_at, expires_at), auto_expired=true
   where status='live' and (ended_at is not null or now() >= expires_at);

  select id, origin, started_by into v_live_id, v_live_origin, v_live_owner
    from public.test_sessions
   where status='live' and ended_at is null and now() < expires_at
   limit 1;

  if v_live_id is not null then
    if v_origin = 'automated' and v_live_origin = 'human' then
      return jsonb_build_object('ok',false,'error','human_session_live',
        'session_id', v_live_id,
        'message', public.uic('test_session.human_live',
          'A person has test mode on. Automated runs do not join it.'));
    end if;
    if v_origin = 'human' and v_live_origin = 'automated' then
      update public.test_sessions
         set status='ended', ended_at=coalesce(ended_at, now()), ended_kind='superseded'
       where id = v_live_id;
      v_live_id := null;
    elsif v_origin = 'human' and v_live_origin = 'human'
          and public.test_session_for(v_uid) is distinct from v_live_id then
      -- CMD #1848 — somebody ELSE's session. It is theirs, not the platform's:
      -- joining it silently would stamp this person's writes to a run they
      -- never started.
      return jsonb_build_object('ok',false,'error','busy','session_id', v_live_id,
        'message', public.uic('test_session.busy','Another test session is already open.'));
    else
      return jsonb_build_object('ok',true,'already',true,'session_id',v_live_id,
        'origin', v_live_origin,
        'message', public.uic('test_session.already_on','Test mode is already on.'));
    end if;
  end if;

  if v_origin = 'automated' then
    v_scope := 'automated';
    v_cap := coalesce((select automated_session_hours from public.test_mode_config where id=1), 1);
    v_hours := least(coalesce(nullif(p_hours,0), v_cap), v_cap);
  else
    v_scope := 'user';
    v_hours := coalesce(nullif(p_hours,0),
                        (select session_hours from public.test_mode_config where id=1), 12);
  end if;

  v_label := coalesce(nullif(btrim(p_label),''),
                      to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' run');

  insert into public.test_sessions (label, scope, origin, started_by, started_by_label,
                                    started_by_kind, expires_at, before_fp)
  values (v_label, v_scope, v_origin, v_uid,
          case when v_origin = 'automated' then 'automated'
               else coalesce((select email from auth.users where id = v_uid), 'admin') end,
          v_origin,
          now() + make_interval(mins => greatest(1, (v_hours*60)::int)),
          public.test_fingerprint())
  returning id into v_id;

  return jsonb_build_object('ok',true,'session_id',v_id,'origin',v_origin,'scope',v_scope,
    'banner', (v_origin = 'human'),
    'message', case when v_origin = 'human'
      then public.uic('test_session.started','Test mode is ON. Everything you do now is a test.')
      else public.uic('test_session.started_automated','Automated test run open — no banner, bot scope only.') end);
end $$;

-- ---------------------------------------------------------------------------
-- 2 + 3. THE REAL CHECKOUT AND THE APPROVAL GATE.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_order_approval()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
declare v_sess bigint;
begin
  if get_my_role() = 'super_admin' then
    return new;
  end if;

  if coalesce(new.is_synthetic, false) then
    -- (a) The bots' synthetic cast — unchanged.
    if exists (
      select 1 from public.pharmacy_profiles
       where id = new.customer_id
         and is_synthetic
         and approved = true
         and (status is null or status not in ('suspended'))
         and (is_deleted is null or is_deleted = false)
    ) then
      return new;
    end if;
    -- (b) CMD #1848 — a REAL approved pharmacy inside its own live session.
    begin v_sess := public.test_session_for(new.user_id); exception when others then v_sess := null; end;
    if v_sess is not null
       and (new.test_session_id is null or new.test_session_id = v_sess)
       and exists (
         select 1 from public.pharmacy_profiles
          where user_id = new.user_id
            and approved = true
            and (status is null or status not in ('suspended'))
            and (is_deleted is null or is_deleted = false)
       ) then
      if new.test_session_id is null then new.test_session_id := v_sess; end if;
      return new;
    end if;
    raise exception 'test_mode.needs_session'
      using hint = public.uic('test_mode.needs_session',
        'This is a test order, but you have no live test session.');
  end if;

  if not exists (
    select 1 from public.pharmacy_profiles
     where user_id = new.user_id
       and approved = true
       and (status is null or status not in ('suspended'))
       and (is_deleted is null or is_deleted = false)
  ) then
    raise exception 'account_pending_approval';
  end if;
  return new;
end $$;

create or replace function public._place_order_v2_core(p_client_action_id uuid DEFAULT NULL::uuid)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v_sess jsonb := public.my_session();
  v_cart jsonb;
  v_cust uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_act  uuid := public.my_acting_as();
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_net numeric; v_id uuid; v_code text;
  v_addr text; v_copy jsonb;
  v_checkout   jsonb;
  v_delivery   jsonb;
  v_rx         jsonb;
  v_total      numeric;
  v_prev       jsonb;
  v_out        jsonb;
  v_test       bigint;
begin
  -- CHANGE #472 — the replay gate, before anything is read or written.
  v_prev := public._idem_claim('order.place', p_client_action_id);
  if v_prev is not null then return v_prev; end if;

  if v_uid is null then
    raise exception 'not_authenticated'
      using hint = 'Session missing or expired; sign in again and retry.';
  end if;

  -- CMD #1848 — ONE question, asked once: is this person inside a live test
  -- session of their own? Any failure reads as NO, so test mode can never
  -- break, delay or mis-stamp a real pharmacy's order.
  begin v_test := public.test_session_for(v_uid); exception when others then v_test := null; end;

  if (v_sess->>'can_place_order') is distinct from 'true' then
    raise exception 'order_gate_blocked'
      using hint = coalesce(v_sess->'order_gate'->>'message', 'Ordering is not available.');
  end if;

  v_cart := public.cart_state(null);
  v_items := coalesce(v_cart->'items', '[]'::jsonb);
  if jsonb_array_length(v_items) = 0 then
    raise exception 'empty_cart' using hint = 'No items to order.';
  end if;

  -- #461/#170: Schedule H/H1 stock needs a licence on file. In 'warn' mode the
  -- order still goes through and the licence state is recorded; in 'block' mode
  -- it is refused with the BACKEND's own copy.
  v_rx := public.cart_rx_gate(v_cust, v_items);
  if coalesce((v_rx->>'blocked')::boolean, false) then
    return public._idem_store_ok('order.place', p_client_action_id,
      jsonb_build_object('error','rx_licence_required',
        'message', coalesce(v_rx->>'message',''),
        'title',   coalesce(v_rx->>'title',''),
        'rx_gate', v_rx));
  end if;

  v_net := coalesce((v_cart->'pricing'->>'net_payable')::numeric, 0);

  -- #461/#167: the delivery line, computed by the SAME block the cart rendered.
  v_delivery := public.delivery_charge_block(v_cust, v_net);
  v_total    := round(v_net + coalesce((v_delivery->>'total')::numeric, 0), 2);

  select * into pp from pharmacy_profiles where id = v_cust;

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  -- is_synthetic / test_session_id: (false, null) — the column defaults — when
  -- there is no session, so the real path writes exactly what it wrote before.
  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id,
     delivery_charge, delivery_charge_gst, delivery_charge_waived, delivery_charge_label,
     rx_line_count, licence_snapshot, client_action_id,
     is_synthetic, test_session_id)
  values
    (v_uid, v_cust, coalesce(pp.pharmacy_name,''), v_items, v_total,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending',
     'website',
     (v_act is not null),
     public.next_order_number(),
     coalesce((v_delivery->>'amount')::numeric, 0),
     coalesce((v_delivery->>'gst')::numeric, 0),
     coalesce((v_delivery->>'waived')::boolean, false),
     coalesce(v_delivery->>'label',''),
     coalesce((v_rx->>'rx_count')::int, 0),
     coalesce(v_rx->'licence', '{}'::jsonb),
     p_client_action_id,
     (v_test is not null), v_test)
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);
  v_checkout := public.checkout_action();

  -- A test order never reaches Razorpay or WhatsApp (item 5).
  if v_test is null
     and (v_checkout->>'acting_as')::boolean
     and (v_checkout->>'collection_mode') = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  v_out := jsonb_build_object(
    'ok',              true,
    'id',              coalesce(v_id::text,''),
    'order_code',      coalesce(v_code,''),
    'amount',          v_total,
    'amount_display',  public.inr_money(v_total),
    'items_amount',    v_net,
    'delivery',        v_delivery,
    'rx_gate',         v_rx,
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);

  -- Additive: these keys exist ONLY for a stamped order, so the ordinary
  -- payload is verbatim what it was.
  if v_test is not null then
    v_out := v_out || jsonb_build_object(
      'test_session_id', v_test,
      'test_badge', public.uic('test_mode.badge','TEST'),
      'test_note',  public.uic('test_mode.placed_note',''));
  end if;

  return public._idem_store_ok('order.place', p_client_action_id, v_out);
end $$;

-- ---------------------------------------------------------------------------
-- 4. RLS SHADOW TENANT — enforced in the database, on every stamped table.
-- ---------------------------------------------------------------------------
do $rls$
declare t text; v_has_synth boolean;
begin
  for t in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and exists (select 1 from information_schema.columns ic
                    where ic.table_schema = 'public' and ic.table_name = c.relname
                      and ic.column_name = 'test_session_id')
       and exists (select 1 from information_schema.columns ic
                    where ic.table_schema = 'public' and ic.table_name = c.relname
                      and ic.column_name = 'is_synthetic')
     order by 1
  loop
    execute format('drop policy if exists c573_synthetic_hidden on public.%I', t);
    execute format('drop policy if exists c1848_test_session_hidden on public.%I', t);
    -- Ordinary rows for everyone; a session-stamped row only for that
    -- session's participants; a legacy synthetic row with no session stays
    -- admin-only exactly as c573 left it.
    execute format($p$
      create policy c1848_test_session_hidden on public.%I
        as restrictive for select to anon, authenticated
        using (
          (test_session_id is null and not coalesce(is_synthetic, false))
          or (test_session_id is not null
              and test_session_id = (select public.test_session_mine()))
          or (test_session_id is null and coalesce(is_synthetic, false) and public.is_admin())
        )$p$, t);
  end loop;
end $rls$;

-- ---------------------------------------------------------------------------
-- 5. HARD OUTBOUND SILENCE. A human session's rows never leave the building.
-- ---------------------------------------------------------------------------
create or replace function public.test_outbound_silenced(p_session bigint)
 returns boolean
 language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select s.origin = 'human' from public.test_sessions s where s.id = p_session), false);
$$;

create or replace function public.test_order_silenced(p_order_id uuid)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v boolean;
begin
  if p_order_id is null then return false; end if;
  select public.test_outbound_silenced(o.test_session_id)
         or (coalesce(o.is_synthetic,false) and public.test_session_for(o.user_id) is not null)
    into v
    from public.orders o where o.id = p_order_id;
  return coalesce(v, false);
exception when others then
  return false;
end $$;

create or replace function public.test_customer_silenced(p_customer_id uuid)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_sess bigint;
begin
  if p_customer_id is null then return false; end if;
  select public.test_session_for(pp.user_id) into v_sess
    from public.pharmacy_profiles pp where pp.id = p_customer_id;
  return v_sess is not null and public.test_outbound_silenced(v_sess);
exception when others then
  return false;
end $$;

revoke all on function public.test_outbound_silenced(bigint) from public, anon;
revoke all on function public.test_order_silenced(uuid) from public, anon;
revoke all on function public.test_customer_silenced(uuid) from public, anon;
grant execute on function public.test_outbound_silenced(bigint) to authenticated, service_role;
grant execute on function public.test_order_silenced(uuid) to authenticated, service_role;
grant execute on function public.test_customer_silenced(uuid) to authenticated, service_role;

create or replace function public._synthetic_outbound_gate()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
declare v_to text; v_new jsonb; v_hard boolean := false;
begin
  if not coalesce(new.is_synthetic,false) then return new; end if;
  v_new := to_jsonb(new);

  -- CMD #1848 — a human session is silent, full stop. The test-number escape
  -- hatch (allow_outbound + test_phone) is the BOT lane's, not a person's.
  begin
    v_hard := public.test_outbound_silenced(nullif(v_new->>'test_session_id','')::bigint);
  exception when others then v_hard := false; end;

  v_to := case tg_table_name
            when 'wa_campaign_recipients'    then v_new->>'phone'
            when 'notification_retry_queue'  then v_new->>'recipient'
            when 'whatsapp_messages'         then v_new->>'sender_phone'
          end;

  if not v_hard and public.synthetic_outbound_allowed(v_to) then
    return new;                              -- Om's own test number, on purpose
  end if;

  if tg_table_name = 'wa_campaign_recipients' then
    new.status      := 'skipped';
    new.skip_reason := 'synthetic_suppressed';
    return new;                              -- kept as evidence, never sent
  end if;

  if tg_table_name = 'whatsapp_messages' then
    if coalesce(v_new->>'direction','') <> 'out' then return new; end if;
    new.wa_status      := 'suppressed';
    new.wa_fail_reason := 'synthetic_suppressed';
    return new;
  end if;

  return null;                               -- retry queue: never enqueued
end $$;

create or replace function public._synthetic_rzp_guard()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
begin
  if coalesce(new.is_synthetic,false) and public.test_outbound_silenced(new.test_session_id) then
    raise exception 'test_mode.outbound_blocked'
      using errcode = '23514',
            hint = public.uic('test_mode.outbound_blocked',
              'Test mode: nothing leaves the building.');
  end if;
  if coalesce(new.is_synthetic,false) and not public.synthetic_rzp_is_test() then
    raise exception
      'synthetic_live_razorpay_blocked: a test order cannot touch Razorpay while LIVE keys are configured'
      using errcode = '23514';
  end if;
  return new;
end $$;

-- The flag said one thing and its note said another. Settle it: outbound is
-- hard-blocked for a person's session regardless of this flag; the flag only
-- ever opens the bot lane's test-number hatch.
update public.test_mode_config
   set allow_outbound = false,
       updated_at = now(),
       updated_by = 'runner-1 #1848: outbound is hard-blocked for human sessions; this flag opens only the bot lane test-number hatch'
 where id = 1;

-- (The http-calling functions are re-issued below with a one-line guard each.)

-- ---------------------------------------------------------------------------
-- 6. THE BANNER IS PER-USER; END & PURGE IS ONE TAP; ACTORS.
-- ---------------------------------------------------------------------------
create or replace function public.test_session_banner()
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $$
declare s public.test_sessions%rowtype; c public.test_mode_config%rowtype;
        v_uid uuid; v_id bigint; v_owner boolean;
begin
  select * into c from public.test_mode_config where id = 1;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  v_id := public.test_session_for(v_uid);
  if v_id is not null then
    select * into s from public.test_sessions
     where id = v_id and origin = 'human';
  end if;
  if v_id is null or s.id is null then
    return jsonb_build_object('on', false, 'poll_ms', coalesce(c.banner_poll_ms, 20000));
  end if;
  v_owner := (s.started_by = v_uid);
  return jsonb_build_object(
    'on', true,
    'poll_ms', coalesce(c.banner_poll_ms, 20000),
    'session_id', s.id,
    'text',  public.uic('test_session.banner','TEST MODE — nothing here is real'),
    'label', s.label,
    'hint',  public.uic('test_session.banner_hint',''),
    'owner_label', public.uic('test_session.owner_label','Started by') || ' ' ||
                   coalesce(nullif(s.started_by_label,''), 'admin'),
    'ends_label', public.uic('test_session.expiry_label','Auto-ends') || ' ' ||
                  to_char(s.expires_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
    'badge', public.uic('test_mode.badge','TEST'),
    'tone', 'danger',
    'is_owner', v_owner,
    'can_end', true,
    'end_action',  public.uic('test_session.end_purge_action','End & purge'),
    'end_confirm', public.uic('test_session.confirm_end_purge',''),
    'end_cancel',  public.uic('test_session.confirm_cancel','Keep testing'));
end $$;

create or replace function public.test_session_end(p_session bigint DEFAULT NULL::bigint)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_uid uuid; v_kind text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_id := coalesce(p_session, public.test_session_mine(), public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  v_kind := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         ended_by = coalesce(ended_by, v_uid),
         ended_kind = coalesce(ended_kind, v_kind)
   where id = v_id;
  return jsonb_build_object('ok',true,'session_id',v_id,
    'residue', public.test_session_residue(v_id),
    'message', public.uic('test_session.ended','Test mode is OFF.'));
end $$;

-- Who may end a session from the banner: the person who started it, or one of
-- its listed actors (Om on his pharmacy login is an actor of his own run).
create or replace function public._test_session_participant(p_session bigint)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_uid uuid;
begin
  begin v_uid := auth.uid(); exception when others then return false; end;
  if v_uid is null or p_session is null then return false; end if;
  return exists (select 1 from public.test_sessions s where s.id = p_session and s.started_by = v_uid)
      or exists (select 1 from public.test_session_actor a where a.session_id = p_session and a.user_id = v_uid);
end $$;

create or replace function public.test_session_end_purge(p_session bigint DEFAULT NULL::bigint)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_end jsonb; v_purge jsonb; v_uid uuid; v_kind text;
begin
  v_id := coalesce(p_session, public.test_session_mine());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  if not (public._test_session_participant(v_id) or public._test_guard()) then
    return jsonb_build_object('ok',false,'error','not_owner',
      'message', public.uic('test_session.not_owner',
        'Only the person who started this session can end it.'));
  end if;

  -- End (the participant may not be an admin, so the end is done here, not
  -- through the admin-guarded RPC) …
  v_kind := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         ended_by = coalesce(ended_by, v_uid),
         ended_kind = coalesce(ended_kind, v_kind)
   where id = v_id;

  -- … then purge, as the platform (the purge RPC is admin-guarded; a
  -- participant has just been authorised above).
  perform set_config('request.jwt.claim.role', 'service_role', true);
  v_purge := public.test_session_purge(v_id, 20000);

  return jsonb_build_object('ok', coalesce((v_purge->>'ok')::boolean, false),
    'session_id', v_id,
    'ended', true,
    'purge', v_purge,
    'done', coalesce((v_purge->>'done')::boolean, false),
    'message', case when coalesce((v_purge->>'done')::boolean, false)
      then public.uic('test_session.end_purged','Test session ended and its rows purged.')
      else public.uic('test_session.end_purge_partial','Session ended; the purge is still running — tap again to finish.') end);
end $$;

revoke all on function public.test_session_end_purge(bigint) from public, anon;
grant execute on function public.test_session_end_purge(bigint) to authenticated, service_role;
revoke all on function public._test_session_participant(bigint) from public, anon;
grant execute on function public._test_session_participant(bigint) to authenticated, service_role;

-- Actors: the logins a session's owner will also test from (Om starts from
-- his admin login and orders from a pharmacy login — that pharmacy login must
-- belong to the session, or its order is refused with needs_session).
create or replace function public.test_session_actor_set(p_session bigint, p_identity text, p_on boolean DEFAULT true)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_uid uuid; v_label text; v_norm text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_id := coalesce(p_session, public.test_session_mine(), public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',false,'error','no_session',
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  v_norm := public.identity_norm(coalesce(p_identity,''));
  if coalesce(v_norm,'') = '' then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public.uic('test_session.actor_not_found','No login matches that email or phone.'));
  end if;
  select u.id, coalesce(u.email, u.phone) into v_uid, v_label
    from auth.users u
   where public.identity_norm(u.email) = v_norm or public.identity_norm(u.phone) = v_norm
   order by u.created_at limit 1;
  if v_uid is null then
    select pp.user_id, coalesce(pp.pharmacy_name, pp.phone) into v_uid, v_label
      from public.pharmacy_profiles pp
     where pp.user_id is not null and coalesce(pp.is_deleted,false) = false
       and (public.identity_norm(pp.phone) = v_norm or public.identity_norm(pp.email) = v_norm)
     order by pp.created_at limit 1;
  end if;
  if v_uid is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public.uic('test_session.actor_not_found','No login matches that email or phone.'));
  end if;
  if coalesce(p_on, true) then
    insert into public.test_session_actor (session_id, user_id, label)
    values (v_id, v_uid, v_label)
    on conflict (session_id, user_id) do update set label = excluded.label;
    return jsonb_build_object('ok',true,'session_id',v_id,'user_id',v_uid,'label',v_label,
      'message', public.uic('test_session.actor_added','Added. Orders from that login now belong to this session.'));
  else
    delete from public.test_session_actor where session_id = v_id and user_id = v_uid;
    return jsonb_build_object('ok',true,'session_id',v_id,'user_id',v_uid,
      'message', public.uic('test_session.actor_removed','Removed.'));
  end if;
end $$;

revoke all on function public.test_session_actor_set(bigint, text, boolean) from public, anon;
grant execute on function public.test_session_actor_set(bigint, text, boolean) to authenticated, service_role;

create or replace function public.test_session_actors(p_session bigint)
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb; s public.test_sessions%rowtype;
begin
  select * into s from public.test_sessions where id = p_session;
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', a.user_id,
           'label', coalesce(nullif(a.label,''), u.email, u.phone, a.user_id::text),
           'can_remove', true) order by coalesce(u.email, a.user_id::text)), '[]'::jsonb)
    into v_rows
    from public.test_session_actor a
    left join auth.users u on u.id = a.user_id
   where a.session_id = p_session;
  return jsonb_build_object(
    'session_id', p_session,
    'title', public.uic('test_session.actors_title','Also testing as'),
    'hint',  public.uic('test_session.actors_hint',''),
    'owner_label', public.uic('test_session.owner_label','Started by') || ' ' ||
                   coalesce(nullif(s.started_by_label,''), 'admin'),
    'empty', public.uic('test_session.actors_empty','Only the person who started it, so far.'),
    'add_label',  public.uic('test_session.actor_add_label','Add a login (email or phone)'),
    'add_action', public.uic('test_session.actor_add_action','Add'),
    'remove_action', public.uic('test_session.actor_remove_action','Remove'),
    'rows', v_rows);
end $$;

revoke all on function public.test_session_actors(bigint) from public, anon;
grant execute on function public.test_session_actors(bigint) to authenticated, service_role;

create or replace function public.test_mode_action(p_key text, p_arg jsonb DEFAULT '{}'::jsonb)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  case p_key
    when 'session_start' then v := public.test_session_start(nullif(btrim(coalesce(p_arg->>'label','')),''));
    when 'session_end'   then v := public.test_session_end(nullif(p_arg->>'session_id','')::bigint);
    when 'session_purge' then v := public.test_session_purge(nullif(p_arg->>'session_id','')::bigint);
    when 'session_end_purge' then v := public.test_session_end_purge(nullif(p_arg->>'session_id','')::bigint);
    when 'actor_add'     then v := public.test_session_actor_set(nullif(p_arg->>'session_id','')::bigint, p_arg->>'identity', true);
    when 'actor_remove'  then v := public.test_session_actor_set(nullif(p_arg->>'session_id','')::bigint, p_arg->>'identity', false);
    when 'run_full'      then v := public.test_run_full(nullif(btrim(coalesce(p_arg->>'label','')),''));
    when 'purge'         then v := public.test_purge(false);
    when 'purge_all'     then v := public.test_purge(true);
    else v := jsonb_build_object('ok',false,'error','unknown_action');
  end case;
  return jsonb_build_object('result', v, 'screen', public.test_mode_screen());
end $$;

create or replace function public.test_mode_screen()
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v jsonb; v_live bigint; v_sessions jsonb; v_actions jsonb; v_actors jsonb;
begin
  v := public._test_mode_screen_base();
  if not coalesce((v->>'ok')::boolean, false) then return v; end if;

  v_live     := public.test_session_live_id();
  v_sessions := public.test_session_list(20);

  v_actions := case when v_live is null then
      jsonb_build_array(jsonb_build_object(
        'key','session_start','label', public.uic('test_session.start_action','Test mode ON'),
        'tone','danger','confirm', null))
    else
      jsonb_build_array(
        jsonb_build_object('key','session_end','label', public.uic('test_session.end_action','Test mode OFF'),
                           'tone','brand','confirm', public.uic('test_session.confirm_end','')),
        jsonb_build_object('key','session_purge','label', public.uic('test_session.purge_action','Purge this session'),
                           'tone','danger','confirm', public.uic('test_session.confirm_purge','')))
    end;

  -- CMD #1848 — the live HUMAN session's participants, so the admin who
  -- started it can add the pharmacy / supplier login he will test from.
  v_actors := case when v_live is not null
                    and exists (select 1 from public.test_sessions s where s.id = v_live and s.origin = 'human')
               then public.test_session_actors(v_live) || jsonb_build_object('has', true)
               else jsonb_build_object('has', false) end;

  return v
    || jsonb_build_object('sessions', v_sessions || jsonb_build_object(
         'subtitle', public.uic('test_session.subtitle',''),
         'live_id',  v_live,
         'residue_label', public.uic('test_session.residue_label','Rows still held'),
         'files_label',   public.uic('test_session.files_label','Files still held'),
         'proof_clean',   public.uic('test_session.proof_clean',''),
         'proof_dirty',   public.uic('test_session.proof_dirty',''),
         'purge_row_label', public.uic('test_session.purge_action','Purge this session'),
         'confirm_purge',   public.uic('test_session.confirm_purge','')))
    || jsonb_build_object('actors', v_actors)
    || jsonb_build_object('banner', public.test_session_banner())
    || jsonb_build_object('actions', v_actions || coalesce(v->'actions','[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- COPY. Every word the app shows comes from here.
-- ---------------------------------------------------------------------------
insert into public.ui_copy (key, value) values
  ('test_mode.needs_session',       to_jsonb('This is a test order, but this login has no live test session. Start test mode, or ask the admin who started it to add this login under "Also testing as", then try again.'::text)),
  ('test_mode.outbound_blocked',    to_jsonb('Test mode: nothing leaves the building. No payment link, QR, WhatsApp, push or email is sent for a test order.'::text)),
  ('test_mode.placed_note',         to_jsonb('Test order — it belongs to your test session only, is invisible to everyone else, and is deleted when the session is purged.'::text)),
  ('test_session.owner_label',      to_jsonb('Started by'::text)),
  ('test_session.end_purge_action', to_jsonb('End & purge'::text)),
  ('test_session.confirm_end_purge',to_jsonb('End this test session and delete every row, file and message it created? Real business data is untouched.'::text)),
  ('test_session.confirm_cancel',   to_jsonb('Keep testing'::text)),
  ('test_session.end_purged',       to_jsonb('Test session ended and its rows purged.'::text)),
  ('test_session.end_purge_partial',to_jsonb('Session ended; the purge is still running — tap again to finish.'::text)),
  ('test_session.not_owner',        to_jsonb('Only the person who started this session can end it.'::text)),
  ('test_session.actors_title',     to_jsonb('Also testing as'::text)),
  ('test_session.actors_hint',      to_jsonb('Logins whose orders and writes belong to this session. Add the pharmacy or supplier login you will test from — without it, that login''s order is refused.'::text)),
  ('test_session.actors_empty',     to_jsonb('Only the person who started it, so far.'::text)),
  ('test_session.actor_add_label',  to_jsonb('Add a login (email or phone)'::text)),
  ('test_session.actor_add_action', to_jsonb('Add'::text)),
  ('test_session.actor_remove_action', to_jsonb('Remove'::text)),
  ('test_session.actor_not_found',  to_jsonb('No login matches that email or phone.'::text)),
  ('test_session.actor_added',      to_jsonb('Added. Orders from that login now belong to this session.'::text)),
  ('test_session.actor_removed',    to_jsonb('Removed.'::text))
on conflict (key) do nothing;

-- The banner copy now names the person, so the old platform-wide wording is
-- replaced only where it still reads as the platform-wide claim it no longer is.
update public.ui_copy
   set value = to_jsonb('Banner shown to the person who started it and to the logins listed under "Also testing as"'::text)
 where key = 'test_session.banner_shown'
   and value #>> '{}' = 'Banner shown platform-wide';


-- ---------------------------------------------------------------------------
-- 5b. THE HTTP-CALLING FUNCTIONS, each with ONE guard line before any call.
--     Bodies are otherwise verbatim from the live definitions of 6 Sep 2026.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rzp_checkout_prepare(p_order_id uuid, p_kind text DEFAULT 'advance'::text, p_mode text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_mode text; v_kind text; v_amount numeric; v_code text; v_hours integer;
  v_open public.rzp_payment_attempt%rowtype; v_ref text;
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id) then
    return jsonb_build_object('ok', false, 'error','test_mode_outbound_blocked',
      'message', public.uic('test_mode.outbound_blocked','Test mode: nothing leaves the building.'));
  end if;
  select order_code into v_code from orders where id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'error','order_not_found');
  end if;

  v_mode := coalesce(nullif(btrim(coalesce(p_mode,'')),''), public.rzp_pay_mode(p_order_id));
  if v_mode = 'manual' then
    return jsonb_build_object('ok', false, 'pay_mode','manual', 'provider','upi_manual');
  end if;

  v_kind   := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  v_amount := public.rzp_amount_due(p_order_id, v_kind);
  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'error','nothing_due',
                              'message', public._rzp_copy('nothing_due_label'));
  end if;

  select greatest(coalesce(razorpay_close_hours,24),1) into v_hours
    from payment_config where id = 1;
  v_hours := coalesce(v_hours, 24);

  -- RESUME, never duplicate: an attempt that is still open for this exact
  -- order+kind+amount is handed straight back with the SAME Razorpay link.
  select * into v_open from public.rzp_payment_attempt
   where order_id = p_order_id and kind = v_kind
     and status in ('pending','attempted')
     and round(amount,2) = round(v_amount,2)
     and coalesce(expires_at, created_at + make_interval(hours => v_hours)) > now()
     and short_url is not null
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'reused', true, 'pay_mode', v_mode,
                              'view', public._rzp_attempt_view(v_open.id));
  end if;

  -- A stale open attempt for a DIFFERENT amount is closed, not left dangling.
  update public.rzp_payment_attempt
     set status = 'expired', failure_reason = 'superseded'
   where order_id = p_order_id and kind = v_kind
     and status in ('pending','attempted');

  insert into public.rzp_payment_attempt (order_id, kind, mode, amount, expires_at)
  values (p_order_id, v_kind, v_mode, v_amount, now() + make_interval(hours => v_hours))
  returning * into v_open;

  -- Unique per attempt by construction. Razorpay refuses a repeated
  -- reference_id, so this is also what stops it minting two links for one tap.
  v_ref := public._rzp_reference_id(v_code, v_kind, v_open.id);
  update public.rzp_payment_attempt set reference_id = v_ref where id = v_open.id;

  return jsonb_build_object(
    'ok', true, 'reused', false, 'pay_mode', v_mode,
    'attempt_id', v_open.id,
    'kind', v_kind,
    'order_code', v_code,
    'amount', v_amount,
    'amount_paise', (round(v_amount, 2) * 100)::bigint,
    'reference_id', v_ref,
    'expire_by', (extract(epoch from v_open.expires_at))::bigint,
    'description', 'mediBO ' || v_code || ' — ' || v_kind,
    'notes', jsonb_build_object('order_id', p_order_id::text, 'order_code', v_code,
                                'kind', v_kind, 'attempt_id', v_open.id::text));
end $function$;
CREATE OR REPLACE FUNCTION public.rzp_qr_prepare(p_order_id uuid, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_enabled boolean; v_hours integer; v_kind text;
  v_amount numeric;  v_code text; v_open public.razorpay_qr%rowtype;
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id) then
    return jsonb_build_object('ok', false, 'enabled', true, 'error','test_mode_outbound_blocked',
      'message', public.uic('test_mode.outbound_blocked','Test mode: nothing leaves the building.'));
  end if;
  v_enabled := (public.payment_collection_mode() = 'gateway');
  select greatest(coalesce(razorpay_close_hours,24),1) into v_hours
    from payment_config where id = 1;
  v_hours := coalesce(v_hours, 24);

  if not v_enabled then
    return jsonb_build_object('ok', false, 'enabled', false, 'provider', 'upi_manual');
  end if;

  select order_code into v_code from orders where id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'enabled', true, 'error', 'order_not_found');
  end if;

  v_kind   := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  v_amount := public.rzp_amount_due(p_order_id, v_kind);

  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'enabled', true, 'error', 'nothing_due',
                              'message', public._rzp_copy('nothing_due_label'));
  end if;

  -- NEVER a second QR for the same order+kind while one is still open.
  select * into v_open from public.razorpay_qr
   where order_id = p_order_id and kind = v_kind and status = 'active'
     and round(amount,2) = round(v_amount,2)
     and created_at > now() - make_interval(hours => v_hours)
   order by created_at desc limit 1;

  if found then
    return jsonb_build_object('ok', true, 'enabled', true, 'reused', true,
                              'view', public.rzp_qr_view(v_open.id));
  end if;

  return jsonb_build_object(
    'ok', true, 'enabled', true, 'reused', false,
    'kind', v_kind,
    'order_code', v_code,
    'amount', v_amount,
    'amount_paise', (round(v_amount, 2) * 100)::bigint,
    'close_by', (extract(epoch from (now() + make_interval(hours => v_hours))))::bigint,
    'description', 'mediBO ' || v_code || ' — ' ||
                   case when v_kind = 'advance' then 'advance' else 'balance' end,
    'notes', jsonb_build_object('order_id', p_order_id::text, 'order_code', v_code, 'kind', v_kind)
  );
end $function$;
CREATE OR REPLACE FUNCTION public.rzp_send_order_qr_wa(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ph text; v_owner uuid; v_due numeric;
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id) then
    return jsonb_build_object('ok', false, 'error','test_mode_outbound_blocked');
  end if;
  if public.payment_collection_mode() <> 'gateway' then
    return jsonb_build_object('ok', false, 'error', 'not_gateway_mode');
  end if;
  select o.user_id into v_owner from orders o where o.id = p_order_id;
  if v_owner is null then return jsonb_build_object('ok', false, 'error','no_order'); end if;

  v_due := public.rzp_amount_due(p_order_id, 'advance');
  if coalesce(v_due,0) <= 0 then
    return jsonb_build_object('ok', false, 'error','nothing_due');
  end if;

  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
    into v_ph from pharmacy_profiles pp
   where pp.user_id = v_owner and coalesce(pp.is_deleted,false) = false limit 1;
  if length(coalesce(v_ph,'')) <> 10 then
    return jsonb_build_object('ok', false, 'error','bad_phone');
  end if;

  return public._send_payment_qr_wa_auto(p_order_id, v_ph, v_due, 'advance');
end $function$;
CREATE OR REPLACE FUNCTION public.notify(p_event_key text, p_recipient text DEFAULT NULL::text, p_vars jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  r            record;
  v            jsonb;
  v_vars       jsonb := coalesce(p_vars, '{}'::jsonb);
  v_channel    text  := coalesce(nullif(v_vars->>'channel',''), 'whatsapp');
  v_order      uuid  := nullif(v_vars->>'order_id','')::uuid;
  v_cust       uuid  := nullif(v_vars->>'customer_id','')::uuid;
  v_url        text  := nullif(v_vars->>'legacy_url','');
  v_body       jsonb := case when v_vars ? 'legacy_body' then v_vars->'legacy_body' end;
  v_force_tpl  boolean := coalesce((v_vars->>'force_template')::boolean, false);
  v_retry      bigint := nullif(v_vars->>'_retry_id','')::bigint;
  v_req        bigint;
  v_tokens     jsonb;
  v_ph         text;
  v_aud        text;
  v_win        jsonb;
  v_open       boolean;
  v_reason     text;
  v_push       jsonb;   -- CHANGE #298
  v_uid        uuid;    -- CHANGE #712 — the recipient, for the per-user switch
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(nullif(p_vars->>'order_id','')::uuid)
     or public.test_customer_silenced(nullif(p_vars->>'customer_id','')::uuid) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_event_key');
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  v_aud := coalesce(r.audience, 'customer');

  v_tokens := v_vars - 'order_id' - 'customer_id' - 'legacy_url' - 'legacy_body'
                     - 'channel' - 'force_template' - '_retry_id' - '_no_push';

  v_ph := nullif(right(regexp_replace(coalesce(p_recipient,''),'\D','','g'),10),'');
  if coalesce(length(v_ph),0) <> 10 and v_order is not null then
    v_ph := right(regexp_replace(coalesce(public._order_customer_phone(v_order),''),'\D','','g'),10);
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_cust is not null then
    select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
      into v_ph from public.pharmacy_profiles pp where pp.id = v_cust;
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_aud = 'admin' then
    v_ph := right(regexp_replace(
              coalesce((select value #>> '{}' from public.app_settings where key='admin_wa_phone'),''),
              '\D','','g'), 10);
  end if;

  -- No route at all → legacy passthrough, byte-for-byte what the caller used
  -- to post on its own, plus a ledger row.
  if r.event_key is null then
    if v_url is null then
      perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
        null, 'unknown_event', null, v_order, v_cust, v_vars);
      return jsonb_build_object('ok', false, 'reason','unknown_event');
    end if;
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'legacy',
      v_req::text, null, null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', true, 'path','legacy', 'reason','no_route',
                              'request_id', v_req);
  end if;

  if coalesce(length(v_ph),0) <> 10 then
    perform public._wa_log_attempt(p_event_key, v_order, null, 'skipped', false, 'no_phone');
    perform public.notify_log(p_event_key, null, v_channel, 'skipped', 'none',
      null, 'no_phone', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  if not public.notif_should_send(v_aud, p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'notification_off');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'notification_off', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','notification_off');
  end if;

  -- CHANGE #712 · the per-user switch, honoured on the WIRE and not only in
  -- the settings screen. notif_optout_set() has written user rows since the
  -- opt-out surface shipped, and nothing read them here: notif_should_send is
  -- the GLOBAL setting, and the push path was handed p_user_id => null, so
  -- notif_user_allows could never see a row. A recipient who switched an event
  -- off still received it on every channel. The user is resolved from the
  -- order (or the pharmacy behind it) and passed on to push below, and the
  -- test allowlist still overrides everything — that is what it is for.
  if v_uid is null then
    if v_order is not null then
      select o.user_id into v_uid from public.orders o where o.id = v_order;
    end if;
    if v_uid is null and v_cust is not null then
      select pp.user_id into v_uid from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
  end if;

  if v_uid is not null
     and not public.notif_user_allows(v_uid, v_aud, p_event_key, 'whatsapp')
     and not public.notif_phone_allowlisted(v_aud, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'user_opted_out');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'user_opted_out', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','user_opted_out');
  end if;

  v_win  := public.notify_window(v_ph);
  v_open := coalesce((v_win->>'open')::boolean, false);

  -- 0. PUSH FIRST (CHANGE #298). Free and instant, so it is tried before the
  --    paid channel. WhatsApp stays the fallback: no active device token, push
  --    switched off for this event, a per-user opt-out, or an FCM failure all
  --    fall straight through to the template path below. A push FCM accepts
  --    returns here; if it later fails, the edge function calls
  --    notif_push_result(), which re-enters notify() with _no_push set, so
  --    this branch can never loop.
  if not coalesce((v_vars->>'_no_push')::boolean, false) then
    begin
      v_push := public.notif_push_send(p_event_key, v_ph, v_uid, v_order, v_tokens, v_aud);
    exception when others then
      v_push := jsonb_build_object('ok', false, 'reason', 'push_exception',
                                   'message', sqlerrm);
    end;
    if coalesce((v_push->>'ok')::boolean, false) then
      perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'push', true,
                                     coalesce(v_push->>'reason', 'push_queued'), v_push);
      return jsonb_build_object('ok', true, 'path', 'push', 'detail', v_push);
    end if;
  end if;

  -- 1. TEMPLATE FIRST. Always. This is the order_placed fix.
  begin
    v := public.wa_send_event_or_fallback(p_event_key, v_cust, v_tokens, v_ph, v_order);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason','exception', 'message', sqlerrm);
  end;

  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'template',
      v->>'recipient_id', null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','template', 'window_open', v_open, 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  -- 2. FREE-FORM, and only inside the tracked window.
  if v_url is not null and v_open and not v_force_tpl then
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'freeform', true,
                                   'window_open_no_template: ' || v_reason, v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'freeform',
      v_req::text, null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','freeform', 'window_open', true,
                              'reason', v_reason, 'request_id', v_req);
  end if;

  -- 3. Nothing legal to send right now → QUEUE it. Never a silent drop.
  perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, v_reason, v);
  perform public.notify_log(p_event_key, v_ph, v_channel, 'queued', 'none',
    null, v_reason, null, v_order, v_cust, v_vars, v);

  if v_retry is not null then
    update public.notification_retry_queue
       set attempts = attempts + 1, last_reason = v_reason,
           next_attempt_at = now() + public.notify_backoff(attempts + 1),
           status = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
           updated_at = now()
     where id = v_retry;
  else
    perform public.notify_enqueue_retry(p_event_key, v_ph, v_vars, v_reason,
                                        v_order, v_cust, v_channel, v_force_tpl);
  end if;

  return jsonb_build_object('ok', false, 'path','queued', 'window_open', v_open,
                            'reason', v_reason);
end $function$;
CREATE OR REPLACE FUNCTION public.notif_push_send(p_event_key text, p_phone10 text, p_user_id uuid DEFAULT NULL::uuid, p_order_id uuid DEFAULT NULL::uuid, p_vars jsonb DEFAULT '{}'::jsonb, p_audience text DEFAULT 'customer'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  cfg record; r record; u record;
  v_tokens jsonb; v_lang text; v_title text; v_body text; v_link text;
  v_log_id bigint; v_sent int := 0; v_users int := 0; v_req bigint;
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id)
     or public.test_customer_silenced(nullif(p_vars->>'customer_id','')::uuid) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
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
CREATE OR REPLACE FUNCTION public.notif_send_email(p_event_key text, p_to text DEFAULT NULL::text, p_vars jsonb DEFAULT '{}'::jsonb, p_user_id uuid DEFAULT NULL::uuid, p_order_id uuid DEFAULT NULL::uuid, p_parent_log_id bigint DEFAULT NULL::bigint, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg      record;
  r        record;
  v_to     text := nullif(trim(coalesce(p_to,'')), '');
  v_uid    uuid := p_user_id;
  v_lang   text;
  tpl      jsonb;
  v_subj   text;
  v_bodyt  text;
  v_html   text;
  v_log    bigint;
  v_dedupe int;
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  select * into cfg from notification_email_config where id = 'singleton';
  if cfg is null or cfg.enabled is not true then
    return jsonb_build_object('ok', false, 'reason', 'email_channel_off');
  end if;

  select * into r from wa_event_routes where event_key = p_event_key;
  if r is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_event');
  end if;
  if r.email_enabled is not true or r.email_mode = 'off' then
    return jsonb_build_object('ok', false, 'reason', 'email_off_for_event');
  end if;

  -- Address and identity: whichever half the caller knows, we find the other.
  if v_to is null and v_uid is not null then
    select nullif(trim(email),'') into v_to from pharmacy_profiles where user_id = v_uid;
  end if;
  if v_uid is null and v_to is not null then
    select user_id into v_uid from pharmacy_profiles where lower(coalesce(email,'')) = lower(v_to) limit 1;
  end if;
  if v_to is null or position('@' in v_to) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_email_on_file');
  end if;

  if v_uid is not null
     and not public.notif_user_allows(v_uid, r.audience, p_event_key, 'email') then
    return jsonb_build_object('ok', false, 'reason', 'opted_out');
  end if;

  v_lang := public.notif_language_for(v_uid, null, v_to);
  tpl    := public.notif_email_template(p_event_key, v_lang);
  v_subj := public.notif_render(tpl->>'subject', p_vars);
  v_bodyt:= public.notif_render(tpl->>'body',    p_vars);
  if coalesce(v_subj,'') = '' or coalesce(v_bodyt,'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_email_template', 'language', v_lang);
  end if;

  -- Same event, same mailbox, inside the route's own dedupe window: one email.
  v_dedupe := coalesce(r.dedupe_minutes, 0);
  if v_dedupe > 0 and exists (
       select 1 from notification_log
        where channel = 'email' and event_key = p_event_key
          and lower(coalesce(recipient,'')) = lower(v_to)
          and created_at > now() - make_interval(mins => v_dedupe)
          and coalesce(status,'') <> 'failed') then
    return jsonb_build_object('ok', false, 'reason', 'deduped');
  end if;

  v_html := public.notif_email_html(v_subj, v_bodyt, v_lang);

  insert into notification_log
    (event_key, channel, audience, recipient_id, recipient, language,
     status, subject, body, vars, order_id, parent_log_id, wa_category)
  values
    (p_event_key, 'email', r.audience, v_uid, v_to, v_lang,
     case when p_dry_run then 'preview' else 'queued' end,
     v_subj, v_bodyt, coalesce(p_vars,'{}'::jsonb), p_order_id, p_parent_log_id, r.wa_category)
  returning id into v_log;

  if p_dry_run then
    return jsonb_build_object('ok', true, 'dry_run', true, 'log_id', v_log,
                              'language', v_lang, 'to', v_to,
                              'subject', v_subj, 'body', v_bodyt, 'html', v_html);
  end if;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/email-send',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('to', v_to, 'subject', v_subj, 'html', v_html,
                                  'text', v_bodyt, 'from', cfg.from_display,
                                  'reply_to', cfg.reply_to, 'log_id', v_log,
                                  'event_key', p_event_key),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'log_id', v_log, 'language', v_lang, 'to', v_to);
end $function$;
CREATE OR REPLACE FUNCTION public.wa_send_event_now(p_event_key text, p_customer_id uuid DEFAULT NULL::uuid, p_tokens jsonb DEFAULT '{}'::jsonb, p_phone text DEFAULT NULL::text, p_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_rec uuid; v_ph text;
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id) or public.test_customer_silenced(p_customer_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  v := public.wa_send_event(p_event_key, p_customer_id, p_tokens, p_phone, p_order_id);
  if not coalesce((v->>'ok')::boolean, false) then return v; end if;

  v_ph := coalesce(public.wa_normalize_phone(p_phone), v->>'phone');

  select r.id into v_rec from wa_campaign_recipients r
   where r.is_event and r.status = 'pending'
     and (v_ph is null or r.phone = v_ph)
     and r.created_at > now() - interval '30 seconds'
   order by r.created_at desc limit 1;

  if v_rec is null then return v || jsonb_build_object('instant', false); end if;

  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-campaign-send',
    headers := jsonb_build_object('Content-Type','application/json','x-notify-secret','medibo_order_notify_2027'),
    body := jsonb_build_object('recipient_id', v_rec));

  return v || jsonb_build_object('instant', true, 'recipient_id', v_rec);
end $function$;
CREATE OR REPLACE FUNCTION public.order_alert_push(p_alert_id bigint, p_kind text DEFAULT 'new'::text, p_audience text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; u record;
  v_vars jsonb; v_title text; v_body text; v_count int; v_tok text;
  v_log bigint; v_req bigint; v_sent int := 0; v_alert jsonb; v_ongoing text;
  v_aud text; v_deep text; v_uids uuid[];
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', false, 'reason','alerts_disabled');
  end if;
  select * into a from public.order_alert where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'reason','no_alert'); end if;
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_outbound_silenced(a.test_session_id) or public.test_order_silenced(a.order_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if a.state <> 'ringing' or not a.ring then
    return jsonb_build_object('ok', false, 'reason','not_ringing');
  end if;

  v_aud := coalesce(nullif(btrim(p_audience),''), public._oa_audience(a));
  v_deep := case when v_aud = 'partner' then '/partner' else '/admin/order-alerts' end;
  if v_aud = 'partner' then
    v_uids := public._oa_partner_user_ids(a.partner_id);
    if coalesce(array_length(v_uids,1),0) = 0 then
      v_aud := 'admin';
      v_deep := '/admin/order-alerts';
    end if;
  end if;

  v_count := (select count(*)::int from public.order_alert al
               where al.state = 'ringing'
                 and (v_aud <> 'partner' or al.partner_id = a.partner_id));
  v_vars := jsonb_build_object(
    'customer',   coalesce(a.customer_name,''),
    'order_code', coalesce(a.order_code,''),
    'amount',     public.inr_money(a.amount),
    'age',        public._oa_age_label(a.created_at),
    'count',      v_count::text);

  v_title := public.oa_label(case when p_kind='critical' then 'push_title_critical'
                                  else 'push_title' end, v_vars);
  v_body  := public.oa_label(case when p_kind='critical' then 'push_body_critical'
                                  else 'push_body' end, v_vars);
  v_ongoing := case when v_count = 1 then public.oa_label('ongoing_title_one', v_vars)
                    else public.oa_label('ongoing_title', v_vars) end;

  for u in
    select t.user_id, min(t.phone10) as phone10, jsonb_agg(distinct t.token) tokens
      from public.push_tokens t
     where t.is_active and t.user_id is not null
       and ( (v_aud = 'partner' and t.user_id = any (v_uids))
          or (v_aud <> 'partner' and t.role in ('admin','super_admin')) )
     group by t.user_id
  loop
    v_tok := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
    insert into public.order_alert_token (token, alert_id, user_id, expires_at)
    values (v_tok, a.id, u.user_id, coalesce(a.expires_at, now() + interval '6 hours'));

    insert into public.notification_log
      (event_key, recipient, channel, status, ok, audience, recipient_id, user_id,
       order_id, customer_id, title, body, deep_link, language, vars, payload, path)
    values
      ('order_alert_new',
       coalesce(nullif(btrim(u.phone10),''), u.user_id::text),
       'push', 'queued', null, v_aud, u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, v_deep, 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind, 'audience', v_aud), 'push')
    returning id into v_log;

    v_alert := jsonb_build_object(
      'kind',                'order_alert',
      'alert_id',            a.id,
      'push_title',          v_title,
      'push_body',           v_body,
      'order_id',            a.order_id,
      'order_code',          coalesce(a.order_code,''),
      'customer',            coalesce(a.customer_name,''),
      'amount',              public.inr_money(a.amount),
      'critical',            (p_kind = 'critical'),
      'credit_note',         coalesce(a.credit_note,''),
      'credit_blocked',      a.credit_blocked,
      'audience',            v_aud,
      'accept_label',        public.oa_label('accept_label'),
      'reject_label',        public.oa_label('reject_label'),
      'view_label',          public.oa_label('view_label'),
      'channel_id',          'medibo_order_alert',
      'channel_name',        public.oa_label('channel_name'),
      'channel_description', public.oa_label('channel_description'),
      'ring_seconds',        cfg.ring_seconds,
      'full_screen',         true,
      'pending_count',       v_count,
      'ongoing_title',       v_ongoing,
      'ongoing_body',        public.oa_label('ongoing_body'),
      'action_token',        v_tok,
      'action_url',          'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-alert-action');

    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('log_id', v_log, 'tokens', u.tokens,
                                    'title', v_title, 'body', v_body,
                                    'deep_link', v_deep,
                                    'event_key', 'order_alert_new',
                                    'order_id', a.order_id,
                                    'alert', v_alert),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  update public.order_alert
     set push_count    = push_count + 1,
         last_push_at  = now(),
         first_push_at = coalesce(first_push_at, now()),
         audience      = v_aud,
         partner_push_count = partner_push_count + case when v_aud='partner' then 1 else 0 end,
         partner_first_push_at = case when v_aud='partner'
                                      then coalesce(partner_first_push_at, now())
                                      else partner_first_push_at end
   where id = a.id;

  if v_sent = 0 then
    return jsonb_build_object('ok', false, 'audience', v_aud,
      'reason', case when v_aud='partner' then 'no_partner_device' else 'no_admin_device' end);
  end if;
  return jsonb_build_object('ok', true, 'devices', v_sent, 'kind', p_kind, 'audience', v_aud);
end $function$;

-- Purge defaults to the CALLER's own session before the platform's.
CREATE OR REPLACE FUNCTION public.test_session_purge(p_session bigint DEFAULT NULL::bigint, p_budget_ms integer DEFAULT 20000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id bigint; s public.test_sessions%rowtype;
        v_tables text[]; v_i int; v_done boolean := true;
        t text; n bigint; v_deleted jsonb; v_files bigint;
        r record; v_paths text[]; v_bucket text; v_started timestamptz := clock_timestamp();
        v_after jsonb; v_res jsonb; v_clean boolean;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  -- A purge must be INERT. Deleting a synthetic inquiry row fired
  -- trg_inquiry_rebuild_spo -> inquiry_engine_sync(), which rewrites every
  -- inquiry_forms row on the platform; the first live purge died on a lock
  -- timeout there. Nothing downstream should react to a test row LEAVING —
  -- it was never real. Replica mode is transaction-local and only covers the
  -- deletes below.
  begin
    set local session_replication_role = 'replica';
  exception when others then null;   -- not permitted here: fall back to plain deletes
  end;
  set local lock_timeout = '5s';

  v_id := coalesce(p_session, public.test_session_mine(), public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',false,'error','no_session',
      'message', public.uic('test_session.no_session','There is no test session to purge.'));
  end if;
  select * into s from public.test_sessions where id = v_id;
  if not found then return jsonb_build_object('ok',false,'error','no_session'); end if;

  -- Ending is implicit: you cannot purge a run you are still inside.
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         purge_started_at = coalesce(purge_started_at, now())
   where id = v_id;

  v_tables  := public._test_session_tables();
  v_i       := coalesce((s.purge_state->>'i')::int, 0);
  v_deleted := coalesce(s.purge_state->'deleted', '{}'::jsonb);
  v_files   := coalesce((s.purge_state->>'files')::bigint, 0);

  -- Step 0 — the storage objects, BEFORE the rows that point at them.
  if v_i = 0 then
    for r in select * from public.test_storage_rule loop
      if not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name=r.src_table and column_name='test_session_id')
        then continue; end if;
      begin
        execute format(
          'select coalesce(array_agg(distinct %I), ''{}'') from public.%I
             where test_session_id = $1 and %I is not null and %I <> ''''',
          r.path_col, r.src_table, r.path_col, r.path_col)
          into v_paths using v_id;
      exception when others then v_paths := '{}'; end;
      if coalesce(array_length(v_paths,1),0) = 0 then continue; end if;

      if r.bucket is not null then
        v_files := v_files + public._test_storage_delete(r.bucket, v_paths);
      else
        for v_bucket in
          execute format('select distinct %I from public.%I where test_session_id = $1 and %I is not null',
                         r.bucket_col, r.src_table, r.bucket_col) using v_id
        loop
          v_files := v_files + public._test_storage_delete(v_bucket, v_paths);
        end loop;
      end if;
    end loop;
    v_i := 1;
  end if;

  -- Steps 1..N — the rows, in dependency order, one table per step so an
  -- interrupted purge resumes at the table it stopped on.
  while v_i <= array_length(v_tables,1) loop
    t := v_tables[v_i];
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name=t and column_name='test_session_id') then
      -- CHANGE #1823: this purge runs in replica mode, so ON DELETE CASCADE
      -- never fires. An order the session stamped whose lines were NOT stamped
      -- (the bot's pipeline stamps the order after the fact, its lines were
      -- written under no auth.uid()) left orphan order_items behind; the next
      -- run's supplier-answer broadcast then touched those orphans and died on
      -- order_items_order_id_fkey1. The lines go first, whatever they carry.
      if t = 'orders' then
        delete from public.order_items oi
         where oi.order_id in (select o.id from public.orders o where o.test_session_id = v_id);
        get diagnostics n = row_count;
        if n > 0 then
          v_deleted := v_deleted || jsonb_build_object('order_items', coalesce((v_deleted->>'order_items')::bigint,0) + n);
        end if;
      end if;
      execute format('delete from public.%I where test_session_id = $1', t) using v_id;
      get diagnostics n = row_count;
      if n > 0 then
        v_deleted := v_deleted || jsonb_build_object(t, coalesce((v_deleted->>t)::bigint,0) + n);
      end if;
    end if;
    v_i := v_i + 1;
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > p_budget_ms
       and v_i <= array_length(v_tables,1) then
      v_done := false;
      exit;
    end if;
  end loop;

  update public.test_sessions
     set purge_state = jsonb_build_object('i', v_i, 'deleted', v_deleted, 'files', v_files)
   where id = v_id;

  if not v_done then
    return jsonb_build_object('ok',true,'done',false,'session_id',v_id,
      'deleted',v_deleted,'files',v_files,
      'message', public.uic('test_session.purge_more','Still purging — tap again to continue.'));
  end if;

  -- CHANGE #1823: whatever an earlier purge left dangling. Synthetic lines
  -- whose order is gone are residue by definition, never business data.
  delete from public.order_items oi
   where coalesce(oi.is_synthetic,false)
     and not exists (select 1 from public.orders o where o.id = oi.order_id);

  -- Finished: the run ledger, then the proof.
  delete from public.test_event  where run_id in (select id from public.test_run where test_session_id = v_id);
  delete from public.test_run    where test_session_id = v_id;
  delete from public.synthetic_blocked_write
   where created_at >= s.started_at
     and created_at <= coalesce(s.ended_at, now());

  v_after := public.test_fingerprint();
  v_res   := public.test_session_residue(v_id);
  v_clean := (coalesce((v_res->>'total')::bigint,0) = 0)
             and (coalesce((v_res->>'files')::bigint,0) = 0)
             and (s.before_fp is null or s.before_fp = v_after);

  update public.test_sessions
     set status='purged', purged_at=now(), after_fp=v_after,
         proof = jsonb_build_object(
           'clean', v_clean,
           'rows_deleted', v_deleted,
           'files_deleted', v_files,
           'residue', v_res,
           'business_unchanged', (s.before_fp is not null and s.before_fp = v_after),
           'tables_compared', (select count(*) from jsonb_object_keys(v_after)))
   where id = v_id;

  return jsonb_build_object('ok',true,'done',true,'session_id',v_id,
    'deleted',v_deleted,'files',v_files,'clean',v_clean,'residue',v_res,
    'business_unchanged',(s.before_fp is not null and s.before_fp = v_after),
    'message', case when v_clean
      then public.uic('test_session.purged_clean','Purged. Nothing of that session is left and no business row moved.')
      else public.uic('test_session.purged_dirty','Purged, but something is still left — open the session to see what.') end);
end $function$;


-- ---------------------------------------------------------------------------
-- 5c. BOUNDARIES a stamped row must never cross.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.orders_merge_same_day()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today   date := (coalesce(NEW.created_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
  v_target  public.orders%rowtype;
  v_arr     jsonb;
  it        jsonb;
  v_idx     int;
  v_eq      numeric;
  v_nq      numeric;
  v_el      numeric;
  v_nl      numeric;
BEGIN
  -- Only consolidate real, itemised orders; otherwise leave the new row alone.
  IF NEW.items IS NULL OR jsonb_typeof(NEW.items) <> 'array' OR jsonb_array_length(NEW.items) = 0 THEN
    RETURN NULL;
  END IF;

  -- Earliest OPEN order for the same customer, same IST date (excluding this row).
  SELECT o.* INTO v_target
  FROM public.orders o
  WHERE o.id <> NEW.id
    AND coalesce(o.fulfillment_status,'open') = 'open'
    -- CMD #1848 — a test order NEVER folds into a real one (or vice versa), and
    -- two sessions never fold into each other. Caught on the build branch: a
    -- stamped order merged into the same pharmacy's real order of the day and
    -- left a synthetic line inside a real order.
    AND coalesce(o.is_synthetic,false) = coalesce(NEW.is_synthetic,false)
    AND o.test_session_id IS NOT DISTINCT FROM NEW.test_session_id
    AND (
          (NEW.user_id IS NOT NULL AND o.user_id = NEW.user_id)
       OR (NEW.user_id IS NULL AND o.user_id IS NULL
           AND lower(btrim(coalesce(o.pharmacy_name,'')))
             = lower(btrim(coalesce(NEW.pharmacy_name,''))))
        )
    AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_today
  ORDER BY o.created_at ASC, o.id ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;  -- first (or only open) order of the day: keep as-is
  END IF;

  -- Merge NEW.items into the target's items.
  v_arr := CASE WHEN jsonb_typeof(coalesce(v_target.items,'[]'::jsonb)) = 'array'
                THEN coalesce(v_target.items,'[]'::jsonb) ELSE '[]'::jsonb END;

  FOR it IN SELECT * FROM jsonb_array_elements(NEW.items) LOOP
    SELECT ord - 1 INTO v_idx
    FROM jsonb_array_elements(v_arr) WITH ORDINALITY AS t(elem, ord)
    WHERE lower(btrim(coalesce(t.elem->>'product_name', t.elem->>'name','')))
        = lower(btrim(coalesce(it->>'product_name', it->>'name','')))
      AND coalesce(btrim(coalesce(it->>'product_name', it->>'name','')),'') <> ''
    LIMIT 1;

    IF v_idx IS NOT NULL THEN
      v_eq := coalesce((v_arr->v_idx->>'quantity')::numeric, (v_arr->v_idx->>'qty')::numeric, 0);
      v_nq := coalesce((it->>'quantity')::numeric, (it->>'qty')::numeric, 0);
      v_el := coalesce((v_arr->v_idx->>'line_total')::numeric, 0);
      v_nl := coalesce((it->>'line_total')::numeric, 0);
      v_arr := jsonb_set(v_arr, ARRAY[v_idx::text,'quantity'],   to_jsonb(v_eq + v_nq));
      v_arr := jsonb_set(v_arr, ARRAY[v_idx::text,'line_total'], to_jsonb(v_el + v_nl));
    ELSE
      v_arr := v_arr || jsonb_build_array(it);
    END IF;
    v_idx := NULL;
  END LOOP;

  UPDATE public.orders
     SET items        = v_arr,
         total_amount = coalesce(v_target.total_amount,0) + coalesce(NEW.total_amount,0)
   WHERE id = v_target.id;

  DELETE FROM public.orders WHERE id = NEW.id;  -- order_items cascade

  RETURN NULL;
END;
$function$;

create or replace function public._synthetic_party_guard()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
declare v_row boolean := coalesce(new.is_synthetic,false); v_name text; v_id uuid; v_sess bigint;
begin
  -- CMD #1848 — a PERSON's test order walks the real flow, so it may name a
  -- real supplier: outbound to that supplier is silenced at the door
  -- (_synthetic_outbound_gate, the http guards) and the row is purged with
  -- the session. The bots' cast rule below is untouched.
  if v_row then
    begin v_sess := (to_jsonb(new)->>'test_session_id')::bigint; exception when others then v_sess := null; end;
    if public.test_outbound_silenced(v_sess) then return new; end if;
  end if;

  if tg_table_name = 'supplier_orders' then
    v_name := new.supplier_name; v_id := new.supplier_id;
  elsif tg_table_name = 'inquiry' then
    v_name := coalesce(new.manual_supplier, new.current_supplier);
  elsif tg_table_name = 'order_items' then
    v_name := new.assigned_supplier;
  end if;

  if v_name is not null or v_id is not null then
    if public.synthetic_supplier_known(v_name, v_id)
       and public.synthetic_supplier_is(v_name, v_id) <> v_row then
      raise exception
        'synthetic_party_mismatch: % row (is_synthetic=%) cannot name supplier %',
        tg_table_name, v_row, coalesce(v_name, v_id::text)
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;


-- ---------------------------------------------------------------------------
-- 5d. THE DEFINER LISTS. RLS cannot reach a SECURITY DEFINER body (postgres
--     BYPASSRLS), so the ordinary lists apply the SAME rule through ONE helper.
-- ---------------------------------------------------------------------------
create or replace function public.test_row_visible(p_synthetic boolean, p_session bigint)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
begin
  -- The SAME rule the c1848 RLS policy applies, for the definer RPCs that
  -- postgres's BYPASSRLS carries past the policy: ordinary rows for everyone,
  -- a session-stamped row only for that session's participants, a legacy
  -- synthetic row (no session) admin-only exactly as c573 left it.
  if p_session is null and not coalesce(p_synthetic,false) then return true; end if;
  if p_session is not null then return coalesce(p_session = public.test_session_mine(), false); end if;
  return coalesce(p_synthetic,false) and public.is_admin();
exception when others then
  return p_session is null and not coalesce(p_synthetic,false);
end $$;
revoke all on function public.test_row_visible(boolean, bigint) from public;
grant execute on function public.test_row_visible(boolean, bigint) to anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION public.admin_customer_orders(p_date date DEFAULT admin_active_date())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='customer_orders_screen_copy'),'{}'::jsonb);
  v_act  jsonb := coalesce((SELECT value FROM app_settings WHERE key='customer_order_actions_copy'),'{}'::jsonb);
  v_cols jsonb := coalesce((SELECT value FROM app_settings WHERE key='order_tab_columns'),'{}'::jsonb);
  v_sep  text  := coalesce(v_copy->>'summary_sep',' • ');
  v_zone smallint := public.admin_active_zone();
  v_n int; v_items int; v_amt numeric;
BEGIN
  IF public.role_for_medibo_only() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  WITH base AS (
    SELECT o.*, (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS items_count,
           (lower(coalesce(o.status,'')) = 'pending') AS can_confirm
    FROM orders o
    WHERE public._date_in_scope(o.created_at, p_date, false)
      AND public.test_row_visible(o.is_synthetic, o.test_session_id)   -- CMD #1848
      AND (v_zone IS NULL OR o.zone_id = v_zone)
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'order_id',b.id,'order_code',coalesce(b.order_code,''),'customer_id',b.customer_id,
      'user_id',b.user_id,'phone',coalesce(b.phone,''),'zone_id',b.zone_id,
      'title', CASE WHEN coalesce(btrim(b.pharmacy_name),'') <> '' THEN b.pharmacy_name
                    ELSE coalesce(v_copy->>'unnamed','') END,
      'code_label',coalesce(b.order_code,''),'show_code',(coalesce(btrim(b.order_code),'') <> ''),
      'phone_label', CASE WHEN coalesce(btrim(b.phone),'') <> '' THEN b.phone
                          ELSE coalesce(v_copy->>'no_phone','') END,
      'has_phone',(coalesce(btrim(b.phone),'') <> ''),
      'status_chip', public.status_chip('customer_status', b.status),
      'fulfillment_chip', public.status_chip('fulfillment', b.fulfillment_status),
      'source_chip', public.status_chip('source', b.source),
      'payment_chip', public.order_payment_chip(b.id),
      'zone_label', coalesce((SELECT name FROM zones WHERE id = b.zone_id),''),
      'admin_chip', CASE WHEN coalesce(b.placed_by_admin,false)
            THEN jsonb_build_object('label',coalesce(v_copy->>'admin_placed',''),
                   'bg','#E6F1FB','fg','#0C447C','border','#B6D4F0','show',true)
            ELSE jsonb_build_object('label','','bg','#FFFFFF','fg','#FFFFFF','border','#FFFFFF','show',false) END,
      'amount',coalesce(b.total_amount,0),'amount_label',public.inr_money(coalesce(b.total_amount,0)),
      'items_count',b.items_count,
      'items_label',public.count_label(v_copy,'items_one','items_many',b.items_count::int),
      'created_at',b.created_at,
      'time_label',to_char(b.created_at AT TIME ZONE 'Asia/Kolkata','HH12:MI AM'),
      'date_label',to_char(b.created_at AT TIME ZONE 'Asia/Kolkata','DD/MM/YYYY'),
      'can_confirm',b.can_confirm,
      'actions', jsonb_build_object('show',b.can_confirm,
        'accept', jsonb_build_object('label',coalesce(v_act->>'accept_label',''),'status','accepted',
                    'show',b.can_confirm,'note',coalesce(v_act->>'accepted_note',''))
                  || public.tone_colors(coalesce(v_act->>'accept_tone','green')),
        'reject', jsonb_build_object('label',coalesce(v_act->>'reject_label',''),'status','rejected',
                    'show',b.can_confirm,'note',coalesce(v_act->>'rejected_note',''))
                  || public.tone_colors(coalesce(v_act->>'reject_tone','red')))
    ) ORDER BY b.created_at DESC),'[]'::jsonb),
    count(*), coalesce(sum(b.items_count),0), coalesce(sum(b.total_amount),0)
  INTO v_rows, v_n, v_items, v_amt FROM base b;

  RETURN jsonb_build_object('status','ok','date',p_date,
    'date_label',to_char(p_date,'DD/MM/YYYY'),
    'zone_id', v_zone,
    'zone_label', coalesce((SELECT name FROM zones WHERE id = v_zone),'All zones'),
    'orders',v_rows,'count',v_n,'has_orders',(v_n > 0),
    'columns',coalesce(v_cols->'customer_orders','[]'::jsonb),
    'summary', jsonb_build_object('orders',v_n,'items',v_items,'amount',v_amt,
      'amount_label',public.inr_money(v_amt),
      'label', public.count_label(v_copy,'orders_one','orders_many',v_n)||v_sep||
               public.count_label(v_copy,'items_one','items_many',v_items)||v_sep||
               public.inr_money(v_amt)),
    'empty', jsonb_build_object('show',(v_n=0),
      'title',coalesce(v_copy->>'empty_title',''),'note',coalesce(v_copy->>'empty_note','')));
END;
$function$;
CREATE OR REPLACE FUNCTION public.pack_list_orders_core(p_date date DEFAULT admin_active_date(), p_include_older boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'order_code', o.order_code,
           'pharmacy_name', o.pharmacy_name,
           'dispatch_ready', COALESCE(o.dispatch_ready,false),
           'created_at', o.created_at,
           'items_total', x.n_items, 'items_packed', x.n_packed,
           'fulfillment_status', COALESCE(o.fulfillment_status,''),
           -- NEW: backend-owned order status label + colours
           'status_label', CASE COALESCE(o.fulfillment_status,'')
                             WHEN 'ready' THEN 'Ready'
                             WHEN 'partial_ready' THEN 'Partially ready'
                             WHEN 'in_transit' THEN 'In transit'
                             WHEN 'collecting' THEN 'Collecting'
                             WHEN 'open' THEN 'Open'
                             WHEN 'shipped' THEN 'Shipped'
                             WHEN 'delivered' THEN 'Delivered'
                             WHEN '' THEN 'Open'
                             ELSE initcap(replace(COALESCE(o.fulfillment_status,''),'_',' ')) END,
           'status_colors', CASE
                             WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                             WHEN COALESCE(o.fulfillment_status,'') IN ('partial_ready','in_transit') THEN jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                             WHEN COALESCE(o.fulfillment_status,'') IN ('shipped','delivered') THEN jsonb_build_object('bg','#E6F1FB','fg','#0C447C')
                             ELSE jsonb_build_object('bg','#FEF3C7','fg','#92400E') END,
           'dot', jsonb_build_object(
             'state', CASE WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN 'green'
                           WHEN COALESCE(o.fulfillment_status,'') IN ('partial_ready','in_transit') THEN 'light_yellow'
                           ELSE 'yellow' END,
             'fill',  CASE WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN '#1B7A43'
                           WHEN COALESCE(o.fulfillment_status,'') IN ('partial_ready','in_transit') THEN '#FEF3C7'
                           ELSE '#FCD34D' END,
             'border',CASE WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN '#1B7A43'
                           ELSE '#F59E0B' END),
           'pack_button', jsonb_build_object(
             'label', CASE WHEN x.n_items <= 0 THEN 'Start Packing'
                           WHEN x.n_packed = 0 THEN 'Start Packing'
                           WHEN x.n_packed >= x.n_items THEN 'Packed ✓ — View'
                           ELSE 'Resume Packing (' || x.n_packed || '/' || x.n_items || ')' END,
             'fill', '#1B7A43'),
           'can_mark_ready', x.can_ready
         ) ORDER BY o.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM orders o
  JOIN LATERAL (
    SELECT count(*) AS n_items,
           count(*) FILTER (WHERE COALESCE(q.packed,false)) AS n_packed,
           (count(*) FILTER (WHERE q.fulfillment_state IN ('received','short')) > 0
            AND count(*) FILTER (
                  WHERE q.fulfillment_state IN ('received','short')
                    AND NOT ( COALESCE(q.packed_qty,0) >= q.packable_qty
                              AND COALESCE(q.packed_qty,0) > 0
                              AND q.pack_counted_qty IS NOT NULL
                              AND COALESCE(q.pack_counted_qty,0) >= q.packable_qty
                              AND COALESCE(q.pack_counted_qty,0) > 0 )
                ) = 0) AS can_ready
    FROM (
      SELECT oi.packed, oi.packed_qty, oi.pack_counted_qty, oi.fulfillment_state,
             least(
               COALESCE((SELECT sum(bic.qty) FROM bag_item_counts bic
                         WHERE bic.assigned_supplier = oi.assigned_supplier
                           AND bic.product_id = oi.product_id AND bic.qty > 0),0),
               oi.quantity
             ) AS packable_qty
      FROM order_items oi
      WHERE oi.order_id = o.id AND oi.fulfillment_state NOT IN ('shipped','cancelled')
    ) q
  ) x ON true
  WHERE x.n_items > 0
    AND public.test_row_visible(o.is_synthetic, o.test_session_id)   -- CMD #1848
    AND NOT public._c708_order_held(o.id)   -- CHANGE #708
    AND (p_date IS NULL OR (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = p_date);

  RETURN jsonb_build_object('status','ok','orders',v_rows,
    'older_open', 0, 'date', p_date, 'include_older', false);
END;
$function$;
CREATE OR REPLACE FUNCTION public.admin_supplier_orders(p_date date DEFAULT admin_active_date())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='supplier_orders_screen_copy'),'{}'::jsonb);
  v_cols jsonb := coalesce((SELECT value FROM app_settings WHERE key='order_tab_columns'),'{}'::jsonb);
  v_sep  text  := coalesce(v_copy->>'summary_sep',' • ');
  v_zone smallint := public.admin_active_zone();
  v_n int; v_items int; v_amt numeric;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  WITH base AS (
    SELECT so.*, coalesce(jsonb_array_length(so.items),0) AS items_count
    FROM supplier_orders so
    WHERE coalesce(so.order_date,(so.created_at AT TIME ZONE 'Asia/Kolkata')::date) = p_date
      AND public.test_row_visible(so.is_synthetic, so.test_session_id)   -- CMD #1848
      AND lower(coalesce(so.status,'')) <> 'cancelled'
      AND coalesce(jsonb_array_length(so.items),0) > 0
      AND (v_zone IS NULL OR so.zone_id = v_zone)
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'supplier_order_id',b.id,'supplier_id',b.supplier_id,'order_code',coalesce(b.order_code,''),
      'order_id',b.order_id,'supplier_name',coalesce(b.supplier_name,''),'zone_id',b.zone_id,
      'title', CASE WHEN coalesce(btrim(b.supplier_name),'') <> '' THEN b.supplier_name
                    ELSE coalesce(v_copy->>'unnamed','') END,
      'code_label',coalesce(b.order_code,''),'show_code',(coalesce(btrim(b.order_code),'') <> ''),
      'description',coalesce(b.description,''),
      'description_label', CASE WHEN coalesce(btrim(b.description),'') <> '' THEN b.description
                                ELSE public.count_label(v_copy,'items_one','items_many',b.items_count::int) END,
      'order_no',b.order_no,
      'order_no_label', CASE WHEN b.order_no IS NULL THEN ''
                             ELSE replace(coalesce(v_copy->>'order_no',''),'{n}',b.order_no::text) END,
      'show_order_no',(b.order_no IS NOT NULL),
      'status_chip',public.status_chip('supplier_status',b.status),
      'zone_label', coalesce((SELECT name FROM zones WHERE id = b.zone_id),''),
      'amount',coalesce(b.total_amount,0),'amount_label',public.inr_money(coalesce(b.total_amount,0)),
      'items_count',b.items_count,
      'items_label',public.count_label(v_copy,'items_one','items_many',b.items_count::int),
      'created_at',b.created_at,
      'time_label',to_char(b.created_at AT TIME ZONE 'Asia/Kolkata','HH12:MI AM'),
      'order_date',b.order_date,
      'date_label',to_char(coalesce(b.order_date,(b.created_at AT TIME ZONE 'Asia/Kolkata')::date),'DD/MM/YYYY'),
      'packed',coalesce(b.packed,false),
      'send_button',public._sup_order_send_state(b.order_code)
    ) ORDER BY b.supplier_name),'[]'::jsonb),
    count(*), coalesce(sum(b.items_count),0), coalesce(sum(b.total_amount),0)
  INTO v_rows, v_n, v_items, v_amt FROM base b;

  RETURN jsonb_build_object('status','ok','date',p_date,
    'date_label',to_char(p_date,'DD/MM/YYYY'),
    'zone_id', v_zone,
    'zone_label', coalesce((SELECT name FROM zones WHERE id = v_zone),'All zones'),
    'supplier_orders',v_rows,'count',v_n,'has_orders',(v_n > 0),
    'columns',coalesce(v_cols->'supplier_orders','[]'::jsonb),
    'summary', jsonb_build_object('orders',v_n,'items',v_items,'amount',v_amt,
      'amount_label',public.inr_money(v_amt),
      'label', public.count_label(v_copy,'orders_one','orders_many',v_n)||v_sep||
               public.count_label(v_copy,'items_one','items_many',v_items)||v_sep||
               public.inr_money(v_amt)),
    'empty', jsonb_build_object('show',(v_n=0),
      'title',coalesce(v_copy->>'empty_title',''),'note',coalesce(v_copy->>'empty_note','')));
END;
$function$;
CREATE OR REPLACE FUNCTION public.supplier_my_orders(p_supplier_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(order_id uuid, order_no integer, created_at timestamp with time zone, status text, status_label text, status_tone text, total_amount numeric, item_count integer, items jsonb, order_code text, packed boolean, packed_via text, pack_button jsonb, pricing jsonb, accept jsonb, line_details jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text;
begin
  if p_supplier_id is null then
    select sp.supplier_name into v_name from current_supplier_profile() sp;
  else
    if get_my_role() <> 'super_admin' then RETURN; end if;
    select sp.supplier_name into v_name from supplier_profiles sp where sp.id = p_supplier_id;
  end if;
  if v_name is null then return; end if;

  return query
  select so.id, so.order_no, so.created_at, so.status,
         -- CHANGE #671 gap 51: the word on the chip and the TONE it is
         -- drawn in. The screen used to switch on the status string to
         -- pick one of five hardcoded hex pairs; that is a display
         -- decision, so it is made here and the app performs one lookup.
         public.supplier_status_label(so.status)  as status_label,
         public.supplier_status_tone(so.status)   as status_tone,
         so.total_amount,
         coalesce(jsonb_array_length(so.items),0) as item_count,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'product_id',        it->>'product_id',
                    'product_name',      it->>'product_name',
                    'quantity',          (it->>'quantity')::numeric,
                    'asked_qty',         it->'asked_qty',
                    'partial',           coalesce((it->>'partial')::boolean, false),
                    'pack_type',         nullif(btrim(med.pack_type),''),
                    'image_url',         nullif(btrim(med.image_url_1),''),
                    'therapeutic_class', nullif(btrim(med.therapeutic_class),''),
                    'company',           nullif(btrim(med.marketer),''),
                    'rate',              it->'rate',
                    'rate_source',       it->>'rate_source',
                    'rate_display',      it->>'rate_display',
                    'mrp_display',       it->>'mrp_display',
                    'line_total',        it->'line_total',
                    'line_total_display', it->>'line_total_display',
                    'price_basis_label', it->>'price_basis_label',
                    'batch_no',          d.batch_no,
                    'expiry',            d.expiry,
                    'hsn',               d.hsn
                  ) order by it->>'product_name')
           from jsonb_array_elements(so.items) it
           left join "MEDICINE" med on med.id = (it->>'product_id')::bigint
           left join public.supplier_order_line_detail d
                  on d.supplier_order_id = so.id
                 and d.product_id = (it->>'product_id')::bigint
         ), '[]'::jsonb) as items,
         so.order_code,
         coalesce(so.packed,false) as packed,
         so.packed_via,
         jsonb_build_object(
           'label',       case when coalesce(so.packed,false) then 'Packed ✓' else 'Mark Packed' end,
           'next_packed', not coalesce(so.packed,false),
           'enabled',     (coalesce(so.accept_state,'pending') in ('accepted','partial')),
           'blocked_reason',
             case when coalesce(so.accept_state,'pending') in ('accepted','partial') then null
                  else public.uic('supplier_po.pack_blocked','Accept the order before you mark it packed') end,
           'bg',          case when coalesce(so.packed,false) then '#E1F5EE' else '#1B7A43' end,
           'fg',          case when coalesce(so.packed,false) then '#0F6E56' else '#FFFFFF' end
         ) as pack_button,
         public.po_pricing_block(so.id) as pricing,
         -- CHANGE #687: the same accept block, plus the countdown the supplier
         -- is racing. Absent clock (pre-#687 rows) => has:false => nothing draws.
         (public.supplier_po_accept_block(coalesce(so.accept_state,'pending'),
                                          coalesce(so.packed,false), so.decline_reason)
          || jsonb_build_object('deadline',
               public.supplier_po_deadline_block(so.accept_due_at,
                                                 coalesce(so.accept_state,'pending')))) as accept,
         jsonb_build_object(
           'title',        public.uic('supplier_po.details_title','Batch & expiry'),
           'hint',         public.uic('supplier_po.details_hint','Required on the purchase bill'),
           'batch_label',  public.uic('supplier_po.batch_label','Batch no.'),
           'expiry_label', public.uic('supplier_po.expiry_label','Expiry (MM/YY)'),
           'hsn_label',    public.uic('supplier_po.hsn_label','HSN'),
           'save_label',   public.uic('supplier_po.save_details','Save batch & expiry'),
           'status_label',
             case when exists (select 1 from public.supplier_order_line_detail d
                                where d.supplier_order_id = so.id
                                  and d.batch_no is not null and d.expiry is not null)
                  then public.uic('supplier_po.details_done','Batch and expiry filled')
                  else public.uic('supplier_po.details_missing','Batch and expiry not filled') end,
           'complete',
             not exists (select 1 from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it2
                          where not exists (select 1 from public.supplier_order_line_detail d2
                                             where d2.supplier_order_id = so.id
                                               and d2.product_id = (it2->>'product_id')::bigint
                                               and d2.batch_no is not null
                                               and d2.expiry is not null))
         ) as line_details
  from supplier_orders so
  where so.supplier_name = v_name
    and public.test_row_visible(so.is_synthetic, so.test_session_id)   -- CMD #1848
  order by so.created_at desc, so.order_no desc;
end $function$;
CREATE OR REPLACE FUNCTION public.my_orders_screen(p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_cfg  jsonb := coalesce((select value from app_settings where key='order_status_config'), '{}'::jsonb);
  v_copy jsonb := coalesce((select value from app_settings where key='orders_screen_copy'), '{}'::jsonb);
  v_unf  jsonb := coalesce((select value from app_settings where key='unfulfilled_copy'), '{}'::jsonb);
  v_tone jsonb := coalesce((select value from app_settings where key='item_status_tones'),
                    '{"green":{"bg":"#E1F5EE","fg":"#0F6E56"},
                      "yellow":{"bg":"#FEF3C7","fg":"#92400E"},
                      "red":{"bg":"#FBE9E7","fg":"#B42318"}}'::jsonb);
  v_rows jsonb; v_title text; v_note text;
begin
  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;

  select coalesce(jsonb_agg(o order by o->>'placed_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'id',                coalesce(ord.id::text,''),
      'order_code',        coalesce(ord.order_code,''),
      'placed_at',         coalesce(ord.created_at::text,''),
      'placed_at_label',   public._ist_stamp(ord.created_at),
      'status',            coalesce(ord.status,'pending'),
      -- CMD #1848 — a stamped order says so on the buyer's own list.
      'test_badge',        case when coalesce(ord.is_synthetic,false) then public.uic('test_mode.badge','TEST') else '' end,
      'status_label',      coalesce(nullif(v_cfg->lower(coalesce(ord.status,'pending'))->>'label',''),
                                    initcap(coalesce(ord.status,'pending'))),
      'status_color',      coalesce(v_cfg->lower(coalesce(ord.status,'pending'))->>'color',
                                    v_cfg->'_default'->>'color', '#F59E0B'),
      'total',             coalesce(ord.total_amount,0),
      'total_display',     public.inr_money(coalesce(ord.total_amount,0)),
      'placed_by_admin',   coalesce(ord.placed_by_admin,false),
      'unique_item_count', coalesce(g.n_ok,0),
      'unit_count',        coalesce(g.units_ok,0),
      'total_item_count',  coalesce(g.n_ok,0) + coalesce(g.n_bad,0),
      'lines',             coalesce(g.ok_lines, '[]'::jsonb),
      'has_unfulfilled',   (coalesce(g.n_bad,0) > 0),
      'unfulfilled_count', coalesce(g.n_bad,0),
      'unfulfilled_title', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items'),
      'unfulfilled_note',  coalesce(nullif(v_unf->>'note',''),''),
      'unfulfilled_label', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items')
                             || ' (' || coalesce(g.n_bad,0)::text || ')',
      'unfulfilled_collapsed', true,
      'unfulfilled_lines', coalesce(g.bad_lines, '[]'::jsonb),
      -- CHANGE #408 — the edit window travels WITH the order.
      'edit',              public._order_edit_gate(ord.id),
      -- CMD #452 — and so does every other door a buyer has on this order:
      -- track (#133), cancel (#130), returns (#131), help (#132). The card
      -- renders this list in payload order and decides nothing.
      'actions',           public._order_customer_actions(ord.id)
    ) as o
    from orders ord
    left join lateral (
      select
        count(*) filter (where d.unfulfillable = false)                       as n_ok,
        count(*) filter (where d.unfulfillable)                               as n_bad,
        coalesce(sum(d.qty) filter (where d.unfulfillable = false),0)::int     as units_ok,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'batch_block', public._order_product_batch_block(ord.id, d.product_id),
            'status_label', d.status_text,
            'status_tone',  d.status_tone,
            'status_ok',    (d.status_text = 'Available'),
            'status_text', d.status_text,
            'status_colors', coalesce(v_tone->d.status_tone, v_tone->'yellow'))
          order by d.product_name) filter (where d.unfulfillable = false)      as ok_lines,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'batch_block', public._order_product_batch_block(ord.id, d.product_id),
            'status_label', coalesce(d.reason, d.status_text),
            'status_tone',  'red',
            'status_ok',    false,
            'status_text', coalesce(d.reason, d.status_text),
            'status_colors', coalesce(v_unf->'chip_colors', v_tone->'red'))
          order by d.product_name) filter (where d.unfulfillable)              as bad_lines
      from (
        select oi.product_id,
               max(oi.product_name)                       as product_name,
               sum(coalesce(oi.quantity,0))               as qty,
               max(coalesce(oi.price, oi.mrp, 0))         as unit_price,
               sum(coalesce(oi.line_total,
                     coalesce(oi.quantity,0) * coalesce(oi.price, oi.mrp, 0))) as line_total,
               bool_or(oi.unfulfillable)                  as unfulfillable,
               max(oi.unfulfillable_reason)               as reason,
               coalesce(max(inq.current_status), 'Confirmation Pending') as status_text,
               case coalesce(max(inq.current_status), 'Confirmation Pending')
                 when 'Available'            then 'green'
                 when 'No Supplier Available' then 'red'
                 else 'yellow' end                        as status_tone,
               max(nullif(btrim(m.image_url_1),''))       as image_url,
               max(upper(nullif(btrim(m.marketer),'')))   as company,
               max(nullif(btrim(regexp_replace(coalesce(m.pack_qty,''),'(\d)\.0(\D)','\1\2','g')),'')) as pack_label,
               trim_scale(sum(coalesce(oi.quantity,0)))::text || ' ' ||
                 case when max(m.pack_type) is null
                        then case when sum(coalesce(oi.quantity,0)) > 1 then 'Units' else 'Unit' end
                      when sum(coalesce(oi.quantity,0)) > 1 and lower(max(m.pack_type)) ~ '(s|x|z|ch|sh)$'
                        then max(m.pack_type) || 'es'
                      when sum(coalesce(oi.quantity,0)) > 1 then max(m.pack_type) || 's'
                      else max(m.pack_type) end           as qty_label
        from order_items oi
        left join "MEDICINE" m on m.id = oi.product_id
        left join lateral (
          select q.current_status from inquiry q
           where q.product_id = oi.product_id
             and (q.zone_id is null or coalesce(oi.zone_id, ord.zone_id) is null
                  or q.zone_id = coalesce(oi.zone_id, ord.zone_id))
           order by (q.batch_date = (ord.created_at at time zone 'Asia/Kolkata')::date) desc nulls last,
                    q.batch_date desc nulls last, q.id desc limit 1) inq on true
        where oi.order_id = ord.id
        group by oi.product_id
      ) d
    ) g on true
    where v_cust is not null and ord.customer_id = v_cust
    order by ord.created_at desc
  ) s;

  if v_cust is null and v_admin then
    v_title := 'Admin account';
    v_note  := 'This login is an admin, not a pharmacy. Customer orders live in the admin Orders tab.';
  else
    v_title := coalesce(nullif(v_copy->>'empty_title',''), 'No purchase orders yet');
    v_note  := coalesce(nullif(v_copy->>'empty_note',''),  'Placed orders will appear here.');
  end if;

  return jsonb_build_object(
    'orders',      v_rows,
    'count',       jsonb_array_length(v_rows),
    'has_orders',  (jsonb_array_length(v_rows) > 0),
    'is_admin_session', v_admin,
    'no_customer_account', (v_cust is null),
    'empty_title', v_title,
    'empty_note',  v_note,
    'customer_id', coalesce(v_cust::text,''));
end $function$;

commit;

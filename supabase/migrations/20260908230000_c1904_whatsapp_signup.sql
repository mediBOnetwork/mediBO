-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1904 — WhatsApp OTP signs new numbers up, it does not turn them away.
--
-- Before this, login_request_otp asked login_owner_state first and returned
-- "No account found for this number" for anything it did not recognise, so
-- WhatsApp was login-only while Google happily created the user. Send code is
-- now a one-way door: it always lands on the Enter login code screen, and the
-- code either signs an existing owner in or signs a new number up.
--
-- Everything the flow says or decides is DATA:
--   ui_copy               — every sentence (5 new keys)
--   app_settings.login_signup — blocked roles, rate limits, signup route
-- Idempotent: re-runnable on live, no drops, no data loss.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Attempt ledger — what the rate limits are counted from ──────────────
create table if not exists public.login_otp_attempt (
  id         bigint generated always as identity primary key,
  identity   text        not null,
  ip         text        not null default '',
  created_at timestamptz not null default now()
);
create index if not exists login_otp_attempt_identity_ix
  on public.login_otp_attempt (identity, created_at desc);
create index if not exists login_otp_attempt_ip_ix
  on public.login_otp_attempt (ip, created_at desc);
alter table public.login_otp_attempt enable row level security;
-- No policies, exactly like login_otp: only the SECURITY DEFINER login RPCs
-- read or write it, and nothing on the client may see another number's rate.

-- ── 2. Copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('login.new_number',
   to_jsonb('New here? We''ll send a code and set you up'::text)),
  ('login.new_number_note',
   to_jsonb('First time on mediBO — enter the code and we''ll set up your account'::text)),
  ('login.blocked_owner',
   to_jsonb('This number already logs in on another mediBO account. Use the sign-in for that account.'::text)),
  ('login.too_many_number',
   to_jsonb('Too many codes for this number. Try again in an hour.'::text)),
  ('login.too_many_ip',
   to_jsonb('Too many codes from this device. Try again in an hour.'::text))
on conflict (key) do nothing;

-- ── 3. Settings — the numbers and the role list, tunable with no deploy ────
insert into public.app_settings (key, value) values
  ('login_signup', jsonb_build_object(
     'blocked_owner_types', jsonb_build_array('supplier','admin','mr','worker','delivery'),
     'resend_seconds',  30,
     'per_number_hour', 5,
     'per_ip_hour',     20,
     'signup_route',    '/complete-registration',
     'internal_email_domain', 'wa.medibo.in'))
on conflict (key) do nothing;

create or replace function public.login_signup_cfg()
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  -- Defaults first, the stored row on top: a half-filled app_settings row can
  -- never leave a limit null and turn a guard off by accident.
  select jsonb_build_object(
           'blocked_owner_types', jsonb_build_array('supplier','admin','mr','worker','delivery'),
           'resend_seconds',  30,
           'per_number_hour', 5,
           'per_ip_hour',     20,
           'signup_route',    '/complete-registration',
           'internal_email_domain', 'wa.medibo.in')
         || coalesce((select value from public.app_settings where key = 'login_signup'),
                     '{}'::jsonb);
$function$;

-- ── 4. Caller IP, best effort ──────────────────────────────────────────────
create or replace function public.login_client_ip()
returns text
language plpgsql stable
as $function$
declare v text := '';
begin
  -- PostgREST publishes the request headers; a direct psql caller has none.
  -- No header is not an error, it is simply an unlimited-by-IP caller.
  begin
    v := btrim(split_part(
           coalesce(nullif(current_setting('request.headers', true), '')::jsonb
                    ->> 'x-forwarded-for', ''), ',', 1));
  exception when others then v := '';
  end;
  return coalesce(v, '');
end $function$;

-- ── 5. Does the row an identity points at still exist? ─────────────────────
create or replace function public.login_owner_row_exists(p_owner_type text, p_owner_id text)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $function$
declare n int := 0;
begin
  if coalesce(btrim(coalesce(p_owner_id,'')),'') = '' then return false; end if;
  begin
    case p_owner_type
      when 'customer' then select count(*) into n from pharmacy_profiles              where id::text = p_owner_id;
      when 'supplier' then select count(*) into n from supplier_profiles              where id::text = p_owner_id;
      when 'worker'   then select count(*) into n from lead_workers                   where id::text = p_owner_id;
      when 'mr'       then select count(*) into n from mr_registrations               where id::text = p_owner_id;
      when 'delivery' then select count(*) into n from delivery_partner_registrations where id::text = p_owner_id;
      when 'company'  then select count(*) into n from company_profiles               where id::text = p_owner_id;
      when 'partner'  then select count(*) into n from partner_users                  where id::text = p_owner_id;
      else n := 1;   -- admin / customer_staff are not row-backed here; unchanged
    end case;
  exception when others then n := 1;   -- a lookup error must never block a login
  end;
  return n > 0;
end $function$;

-- ── 6. Claiming an unclaimed identity ──────────────────────────────────────
create or replace function public.login_identity_claim(p_owner_type text, p_owner_id text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_key text; v_n int := 0;
begin
  if auth.uid() is null or coalesce(btrim(coalesce(p_owner_id,'')),'') = '' then
    return jsonb_build_object('ok', false, 'claimed', 0);
  end if;
  foreach v_key in array coalesce(public.my_identity_keys(), '{}'::text[]) loop
    -- Repoint ONLY a blank owner_id. An identity that already belongs to
    -- somebody is never taken over by a new registration.
    update public.login_identities
       set owner_type = p_owner_type, owner_id = p_owner_id
     where identity = v_key and coalesce(btrim(owner_id),'') = '';
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'claimed', v_n);
end $function$;

-- ── 7. Is this owner type allowed on the WhatsApp door at all? ─────────────
create or replace function public.login_owner_blocked(p_owner_type text)
returns boolean
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(p_owner_type,'') in (
    select jsonb_array_elements_text(
             coalesce(public.login_signup_cfg()->'blocked_owner_types','[]'::jsonb)));
$function$;
-- ── login_owner_state: the sentence an unknown number gets ────────────────
CREATE OR REPLACE FUNCTION public.login_owner_state(p_identity text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; ok boolean := true; msg text := ''; nm text := '';
begin
  select owner_type, owner_id into r from login_identities where identity = p_identity;
  if not found then
    -- CMD #1904 — an unknown number is not an error any more. It is a new
    -- customer, and login_request_otp sends it a code like any other.
    return jsonb_build_object('found',false,'ok',false,'is_new_user',true,
      'message', public.uic('login.new_number',
                            'New here? We''ll send a code and set you up'));
  end if;

  if r.owner_type = 'supplier' then
    select sp.supplier_name,
           (sp.approved is true and coalesce(sp.status,'active') <> 'suspended')
      into nm, ok
      from supplier_profiles sp where sp.id::text = r.owner_id;
    if not ok then msg := 'This supplier account is not active yet'; end if;
  elsif r.owner_type = 'customer' then
    select pp.pharmacy_name,
           (coalesce(pp.is_deleted,false) = false
            and lower(btrim(coalesce(pp.status,''))) <> 'suspended')
      into nm, ok
      from pharmacy_profiles pp where pp.id::text = r.owner_id;
    if nm is null then ok := false; end if;
    if not ok then msg := 'This account is closed — contact mediBO'; end if;
  elsif r.owner_type = 'worker' then
    select lw.name, coalesce(lw.active,false) into nm, ok
      from lead_workers lw where lw.id::text = r.owner_id;
    if not ok then msg := 'This worker account is inactive'; end if;
  elsif r.owner_type = 'partner' then
    select rp.partner_name,
           (coalesce(pu.is_active,false) and coalesce(rp.is_active,false))
      into nm, ok
      from partner_users pu
      join region_partners rp on rp.id = pu.partner_id
     where pu.id::text = r.owner_id;
    if nm is null then ok := false; end if;
    if not ok then msg := 'This partner login is not active'; end if;
  end if;

  return jsonb_build_object(
    'found', true, 'ok', coalesce(ok,false),
    'owner_type', r.owner_type, 'owner_id', r.owner_id,
    'display_name', coalesce(nm,''),
    'message', case when coalesce(ok,false) then 'Sending code on WhatsApp' else msg end
  );
end $function$;

insert into public.ui_copy (key, value) values
  ('login.resend_wait', to_jsonb('Code already sent, wait {s} seconds'::text))
on conflict (key) do nothing;

-- ── 8. Sending the code ────────────────────────────────────────────────────
create or replace function public.login_request_otp(p_input text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare k text; s jsonb; cfg jsonb; v_code text; v_prev login_otp%rowtype;
        v_new boolean; v_ip text; v_cap int; v_wait int;
        v_owner_type text; v_owner_id text;
        c_demo_number constant text := '9000000000';
        c_demo_code   constant text := '123456';
begin
  k := identity_norm(p_input);
  if k is null then
    return jsonb_build_object('ok',false,'message','Enter a valid 10-digit number');
  end if;

  cfg := public.login_signup_cfg();
  s   := public.login_owner_state(k);
  v_new := not coalesce((s->>'found')::boolean, false);

  -- CMD #1904 — a number that already logs in as a supplier / admin / MR /
  -- worker / delivery partner has its own door. It is never signed up as a
  -- customer here, and it is never sent a code here. The role list is data
  -- (app_settings.login_signup.blocked_owner_types), not a literal.
  if not v_new and public.login_owner_blocked(s->>'owner_type') then
    return jsonb_build_object('ok',false,'is_new_user',false,'blocked',true,
      'message', public.uic('login.blocked_owner',
        'This number already logs in on another mediBO account. Use the sign-in for that account.'));
  end if;

  -- A known owner that is closed or not approved yet still stops here with the
  -- backend's own sentence. That is not a new number, it is a shut one.
  if not v_new and not coalesce((s->>'ok')::boolean, false) then
    return jsonb_build_object('ok',false,'is_new_user',false,'message', s->>'message');
  end if;

  -- 'new' is a real owner_type on login_otp (both columns are NOT NULL): it is
  -- what login_verify_otp reads to know it is signing somebody up.
  v_owner_type := coalesce(nullif(s->>'owner_type',''), 'new');
  v_owner_id   := coalesce(s->>'owner_id', '');

  if k = c_demo_number then
    insert into login_otp (identity, code_hash, owner_type, owner_id, ticket, attempts,
                           sent_at, expires_at, consumed_at, send_status, send_via, send_error)
    values (k, md5(k || ':' || c_demo_code), v_owner_type, v_owner_id, null, 0,
            now(), now() + interval '10 years', null, 'sent', 'demo_static', null)
    on conflict (identity) do update
      set code_hash = excluded.code_hash, owner_type = excluded.owner_type,
          owner_id = excluded.owner_id, ticket = null, attempts = 0, sent_at = now(),
          expires_at = excluded.expires_at, consumed_at = null,
          send_status = 'sent', send_via = 'demo_static', send_error = null;
    return jsonb_build_object('ok',true,'is_new_user',v_new,
                              'message','Enter the code to continue','ttl_seconds',600,
                              'note', case when v_new
                                        then public.uic('login.new_number_note','') else '' end,
                              'poll','login_otp_status');
  end if;

  -- The 30-second resend guard, kept exactly as it was. Only the number and
  -- the sentence moved into data.
  v_wait := greatest(coalesce((cfg->>'resend_seconds')::int, 30), 0);
  select * into v_prev from login_otp where identity = k;
  if found and v_wait > 0 and v_prev.sent_at > now() - make_interval(secs => v_wait) then
    return jsonb_build_object('ok',false,'is_new_user',v_new,
      'message', replace(public.uic('login.resend_wait','Code already sent, wait {s} seconds'),
                         '{s}', v_wait::text));
  end if;

  v_ip := public.login_client_ip();

  -- Rate limits, counted from login_otp_attempt — which only ever records a
  -- send that actually went out, so a blocked attempt can never lock a number
  -- out on its own.
  v_cap := coalesce((cfg->>'per_number_hour')::int, 5);
  if v_cap > 0 and (select count(*) from login_otp_attempt a
                     where a.identity = k
                       and a.created_at > now() - interval '1 hour') >= v_cap then
    return jsonb_build_object('ok',false,'is_new_user',v_new,'rate_limited','number',
      'message', public.uic('login.too_many_number',
        'Too many codes for this number. Try again in an hour.'));
  end if;

  v_cap := coalesce((cfg->>'per_ip_hour')::int, 20);
  if v_ip <> '' and v_cap > 0 and (select count(*) from login_otp_attempt a
                     where a.ip = v_ip
                       and a.created_at > now() - interval '1 hour') >= v_cap then
    return jsonb_build_object('ok',false,'is_new_user',v_new,'rate_limited','ip',
      'message', public.uic('login.too_many_ip',
        'Too many codes from this device. Try again in an hour.'));
  end if;

  v_code := lpad((floor(random()*1000000))::int::text, 6, '0');

  insert into login_otp (identity, code_hash, owner_type, owner_id, ticket, attempts,
                         sent_at, expires_at, consumed_at, send_status, send_via, send_error)
  values (k, md5(k || ':' || v_code), v_owner_type, v_owner_id, null, 0,
          now(), now() + interval '5 minutes', null, 'pending', null, null)
  on conflict (identity) do update
    set code_hash = excluded.code_hash, owner_type = excluded.owner_type,
        owner_id = excluded.owner_id, ticket = null, attempts = 0, sent_at = now(),
        expires_at = excluded.expires_at, consumed_at = null,
        send_status = 'pending', send_via = null, send_error = null;

  insert into login_otp_attempt (identity, ip) values (k, v_ip);
  delete from login_otp_attempt where created_at < now() - interval '2 days';

  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
    headers := jsonb_build_object('Content-Type','application/json','x-login-secret','medibo_login_otp_2027'),
    body := jsonb_build_object('mode','send','phone', k, 'code', v_code));

  perform public.notify_log('login_otp', k, 'whatsapp', 'sent', 'auth',
                            null, null, null, null, null, '{}'::jsonb,
                            jsonb_build_object('note','auth transport, not route-gated',
                                               'is_new_user', v_new));

  return jsonb_build_object('ok',true,'is_new_user',v_new,
    'message', case when v_new
                 then public.uic('login.new_number','New here? We''ll send a code and set you up')
                 else coalesce(nullif(s->>'message',''),'Sending code on WhatsApp') end,
    'note', case when v_new then public.uic('login.new_number_note','') else '' end,
    'ttl_seconds',300,
    'poll','login_otp_status');
end $function$;

-- ── 9. Checking the code — and signing a new number up ─────────────────────
create or replace function public.login_verify_otp(p_input text, p_code text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare k text; v login_otp%rowtype; v_ticket uuid; v_new boolean := false;
        c_demo_number constant text := '9000000000';
        c_demo_code   constant text := '123456';
begin
  k := identity_norm(p_input);

  -- DEMO EXCEPTION: always accept 123456, re-arm for next time, never "already used"/"expired"
  if k = c_demo_number then
    if coalesce(btrim(p_code),'') <> c_demo_code then
      return jsonb_build_object('ok',false,'message','OTP invalid');
    end if;
    select * into v from login_otp where identity = k;
    if not found then
      -- self-heal: rebuild the demo OTP row from the owner state
      perform public.login_request_otp(k);
      select * into v from login_otp where identity = k;
    end if;
    v_ticket := gen_random_uuid();
    update login_otp
       set consumed_at = now(), ticket = v_ticket,
           code_hash = md5(k || ':' || c_demo_code),   -- re-arm
           expires_at = now() + interval '10 years',
           attempts = 0, send_status = 'sent', send_via = 'demo_static'
     where identity = k;
    return jsonb_build_object(
      'ok', true, 'message','Verified', 'is_new_user', (coalesce(v.owner_type,'') = 'new'),
      'owner_type', v.owner_type, 'owner_id', v.owner_id,
      'next', jsonb_build_object(
        'function','login-otp',
        'url','https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
        'body', jsonb_build_object('mode','session','phone',k,'ticket',v_ticket),
        'then','set_session_then_call_my_session'));
  end if;

  select * into v from login_otp where identity = k;
  if not found then return jsonb_build_object('ok',false,'message','Request a code first'); end if;
  if v.consumed_at is not null and v.ticket is null then
    return jsonb_build_object('ok',false,'message','Code already used');
  end if;
  if now() > v.expires_at then
    return jsonb_build_object('ok',false,'message','Code expired, request a new one');
  end if;
  if v.attempts >= 5 then
    return jsonb_build_object('ok',false,'message','Too many wrong attempts, request a new code');
  end if;
  if v.code_hash <> md5(k || ':' || coalesce(btrim(p_code),'')) then
    update login_otp set attempts = attempts + 1 where identity = k;
    return jsonb_build_object('ok',false,'message','OTP invalid');
  end if;

  v_new := (coalesce(v.owner_type,'') = 'new');

  if v_new then
    -- The guard again, on the far side of the code: an identity can have been
    -- created for another role in the five minutes the code was alive.
    if exists (select 1 from login_identities li
                where li.identity = k and public.login_owner_blocked(li.owner_type)) then
      return jsonb_build_object('ok',false,'blocked',true,
        'message', public.uic('login.blocked_owner',
          'This number already logs in on another mediBO account. Use the sign-in for that account.'));
    end if;

    -- Sign the number up. The auth user itself is minted by the login-otp
    -- edge function on the very next call (mode=session already creates one
    -- when none exists), so this is the part that must be true FIRST: the
    -- number is a customer identity from now on, which is what makes the next
    -- login an ordinary login instead of a second signup.
    --
    -- owner_id stays '' — the pharmacy row does not exist yet, and inventing
    -- one would take the user off the Signed-up list. submit_registration
    -- claims this row the moment the registration form is filled in
    -- (login_identity_claim), and until then login_bind_owner leaves it alone.
    -- registration_stage needs no write: it is derived by _c1886_stage_sync on
    -- pharmacy_profiles, and a user with no profile row IS the signed_up stage
    -- that customers_signed_up lists.
    insert into login_identities (identity, kind, owner_type, owner_id)
    values (k, 'whatsapp', 'customer', '')
    on conflict (identity) do nothing;
  end if;

  v_ticket := gen_random_uuid();
  update login_otp set consumed_at = now(), ticket = v_ticket where identity = k;

  return jsonb_build_object(
    'ok', true, 'message','Verified', 'is_new_user', v_new,
    'owner_type', v.owner_type, 'owner_id', v.owner_id,
    'next', jsonb_build_object(
      'function','login-otp',
      'url','https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
      'body', jsonb_build_object('mode','session','phone',k,'ticket',v_ticket),
      'then','set_session_then_call_my_session'));
end $function$;
CREATE OR REPLACE FUNCTION public.login_bind_owner(p_identity text, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_uids uuid[]; v_orders int := 0; v_cart int := 0;
        n int := 0; v_changed int := 0;
        nil uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_user_id is null then return jsonb_build_object('ok',false,'message','no user'); end if;
  select owner_type, owner_id into r from login_identities where identity = p_identity;
  if not found then return jsonb_build_object('ok',false,'message','no owner'); end if;

  -- CMD #1904: a WhatsApp signup writes its identity BEFORE the pharmacy row
  -- exists (owner_id ''), so the owner is UNCLAIMED. Binding on an unclaimed
  -- identity would clear this auth user off every profile it owns — including
  -- the one it registers a minute later — so it does nothing at all until
  -- submit_registration claims the identity.
  if not public.login_owner_row_exists(r.owner_type, r.owner_id) then
    return jsonb_build_object('ok',false,'unclaimed',true,
                              'message','identity not claimed yet');
  end if;

  -- CHANGE #643: clear this auth user off every OTHER owner row. The row we
  -- are about to bind is excluded, so the old clear-then-set-it-straight-back
  -- pair (two WAL records and two realtime broadcasts per session poll) is
  -- now zero writes when the binding is already correct.
  update pharmacy_profiles set user_id = nil
   where user_id = p_user_id
     and not (r.owner_type = 'customer' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update supplier_profiles set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'supplier' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update lead_workers set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'worker' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update mr_registrations set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'mr' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update delivery_partner_registrations set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'delivery' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update company_profiles set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'company' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update partner_users set auth_user_id = null
   where auth_user_id = p_user_id
     and not (r.owner_type = 'partner' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  -- …and bind the one that should hold it, only if it does not already.
  if    r.owner_type = 'customer' then
    update pharmacy_profiles set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'supplier' then
    update supplier_profiles set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'worker' then
    update lead_workers set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'mr' then
    update mr_registrations set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'delivery' then
    update delivery_partner_registrations set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'company' then
    update company_profiles set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'partner' then
    update partner_users set auth_user_id = p_user_id, updated_at = now()
     where id::text = r.owner_id and auth_user_id is distinct from p_user_id;
  end if;
  get diagnostics n = row_count; v_changed := v_changed + n;

  -- CHANGE #643: the order/cart migration runs ONLY on a real re-bind.
  -- It used to run on every call, so with two logins on one pharmacy each
  -- session poll dragged all 34 orders to whoever polled last and the other
  -- login dragged them straight back — the single biggest source of orders
  -- realtime traffic. A binding that did not change moves nothing.
  if r.owner_type = 'customer' and v_changed > 0 then
    v_uids := public.owner_auth_user_ids(r.owner_type, r.owner_id);
    update orders o set user_id = p_user_id
     where o.user_id = any (v_uids) and o.user_id <> p_user_id;
    get diagnostics v_orders = row_count;
    delete from cart_items c
     where c.user_id = any (v_uids) and c.user_id <> p_user_id
       and exists (select 1 from cart_items k
                    where k.user_id = p_user_id and k.product_id = c.product_id);
    update cart_items c set user_id = p_user_id
     where c.user_id = any (v_uids) and c.user_id <> p_user_id;
    get diagnostics v_cart = row_count;
  end if;

  return jsonb_build_object('ok',true,'owner_type',r.owner_type,'owner_id',r.owner_id,
                            'orders_moved',v_orders,'cart_moved',v_cart,
                            'rows_changed',v_changed);
end $function$;

CREATE OR REPLACE FUNCTION public.my_customer_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with k as (select public.my_identity_keys() keys),
  mapped as (select 1 from login_identities li, k
             where li.identity = any (k.keys)
               -- CMD #1904: an UNCLAIMED signup identity (owner_id '') is not a
               -- mapping; without this the user_id fallback below stops firing the
               -- moment a WhatsApp signup writes its identity, and the pharmacy the
               -- user registers right after would never resolve.
               and coalesce(btrim(li.owner_id),'') <> '' limit 1)
  select pp.id
  from pharmacy_profiles pp, k
  where coalesce(pp.is_deleted,false) = false
    and (
      exists (select 1 from login_identities li
               where li.owner_type = 'customer' and li.owner_id = pp.id::text
                 and li.identity = any (k.keys))
      -- CHANGE #408 — a staff login on this pharmacy, by identity or by the
      -- auth user it was bound to.
      or exists (select 1 from customer_users cu
                  where cu.customer_id = pp.id
                    and coalesce(cu.is_active, true)
                    and (cu.identity = any (k.keys) or cu.auth_user_id = auth.uid()))
      or (not exists (select 1 from mapped) and pp.user_id = auth.uid())
    )
  order by pp.id
  limit 1
$function$;

CREATE OR REPLACE FUNCTION public.my_session_core()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text; v_owner record; v_name text; v_cfg record;
  v_sup uuid; v_cust uuid; pp pharmacy_profiles%rowtype; sp supplier_profiles%rowtype;
  ap pharmacy_profiles%rowtype;
  v_profile jsonb := '{}'::jsonb; v_registered boolean := false; v_surface text;
  v_has_cust boolean := false; v_suspended boolean := false;
  v_pend_sup_name text := null; v_sup_status text := 'not_found';
  v_is_staff boolean := false; v_can_order boolean := false;
  v_needs_profile boolean := false; v_act uuid;
  v_reason text; v_copy jsonb; v_gate jsonb;
begin
  if auth.uid() is null then
    v_copy := coalesce((select value from app_settings where key='order_gate_copy'), '{}'::jsonb)
              -> 'signed_out';
    return jsonb_build_object(
      'signed_in', false, 'auth_user_id','', 'login_email','', 'role','none',
      'is_admin', false, 'is_super_admin', false, 'is_supplier', false,
      'is_customer', false, 'is_registered_customer', false, 'is_worker', false,
      'surface','public', 'owner_type','', 'owner_id','', 'display_name','',
      'supplier_id','', 'supplier_name','', 'customer_id','', 'customer_name','',
      'home_route','/login', 'home_label','Login', 'header_title','',
      'status_label','', 'profile','{}'::jsonb, 'identities','[]'::jsonb,
      'message','Please log in',
      'has_customer_account', false, 'is_suspended', false,
      'is_pending_supplier', false, 'supplier_status','not_found',
      'needs_profile', false, 'can_place_order', false, 'acting_as','',
      'order_gate', jsonb_build_object(
        'has_blocker',  true, 'reason','signed_out',
        'title',        coalesce(v_copy->>'title',''),
        'message',      coalesce(v_copy->>'message',''),
        'action_label', coalesce(v_copy->>'action_label',''),
        'action_route', coalesce(v_copy->>'action_route',''),
        'short_label',  coalesce(v_copy->>'short_label','')));
  end if;

  perform public.login_sync_current_user();

  v_role := coalesce(public.get_my_role(), 'none');
  select owner_type, owner_id into v_owner from public.my_owner();
  select * into v_cfg from login_role_config where role = v_role;

  v_sup  := public.my_supplier_id();
  v_cust := public.my_customer_id();
  v_act  := public.my_acting_as();
  v_is_staff := v_role in ('admin','super_admin','worker');

  if v_sup is not null then
    select * into sp from supplier_profiles where id = v_sup;
    v_name := sp.supplier_name;
    v_sup_status := 'ok';
  elsif v_cust is not null then
    select * into pp from pharmacy_profiles where id = v_cust;
    v_name := coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''));
    v_registered := (coalesce(pp.approved,false) = true
                     or lower(coalesce(pp.status,'')) in ('approved','active'));
    v_profile := jsonb_build_object(
      'contact_name',   coalesce(pp.customer_name,''),
      'business_name',  coalesce(pp.pharmacy_name,''),
      'store_type',     coalesce(nullif(btrim(pp.store_type),''), '—'),
      'delivery_range', coalesce(nullif(btrim(pp.range_zone),''), '—'),
      'local_address',  coalesce(nullif(btrim(pp.address_local),''), '—'),
      'city',           coalesce(nullif(btrim(pp.city),''), '—'),
      'state',          coalesce(nullif(btrim(pp.state),''), '—'),
      'phone',          coalesce(pp.phone,''),
      'whatsapp_no',    coalesce(pp.whatsapp_no,''),
      'email',          coalesce(pp.email,''),
      'gstin',          coalesce(nullif(btrim(pp.gstin),''), '—'),
      'drug_license',   coalesce(nullif(btrim(pp.drug_license),''), '—'),
      'payment_term',   coalesce(nullif(btrim(pp.payment_term),''), '—'),
      'note',           'To update your details, contact support.');
  elsif v_role in ('admin','super_admin') then
    v_name := public.my_login_email();
  end if;

  v_has_cust := (v_cust is not null);
  v_suspended := (v_cust is not null and lower(coalesce(pp.status,'')) = 'suspended');

  if v_sup is null then
    select s.supplier_name into v_pend_sup_name
    from supplier_profiles s
    join login_identities li
      on li.owner_type = 'supplier' and li.owner_id = s.id::text
    where li.identity = any (public.my_identity_keys())
      and coalesce(s.is_deleted,false) = false
      and coalesce(s.approved,false) = false
    order by s.id
    limit 1;
    if v_pend_sup_name is not null then v_sup_status := 'pending_approval'; end if;
  end if;

  -- FIX 1: a supplier (approved or pending) is never "missing a profile".
  v_needs_profile := (not v_is_staff and v_sup is null and v_pend_sup_name is null
                      and not v_has_cust and v_act is null);

  v_surface := case
    when v_role in ('admin','super_admin') and v_act is not null then 'customer'
    when v_role in ('admin','super_admin') then 'admin'
    when v_sup is not null then 'supplier'
    when v_pend_sup_name is not null then 'pending_supplier'
    when v_role = 'worker' then 'worker'
    else 'customer' end;

  -- FIX 3: under View As the gate judges the IMPERSONATED customer, which is
  -- the account the order is actually placed for.
  if v_act is not null then
    select * into ap from pharmacy_profiles where id = v_act;
    v_can_order := (ap.id is not null
                    and lower(coalesce(ap.status,'')) <> 'suspended'
                    and (coalesce(ap.approved,false) = true
                         or lower(coalesce(ap.status,'')) in ('approved','active')));
    v_reason := case when v_can_order then 'none' else 'viewas_pending_approval' end;
  else
    v_can_order := (v_has_cust and v_registered and not v_suspended);
    -- FIX 2: order matters — a supplier or staff account is not an
    -- unregistered pharmacy, and must never be told to go and register.
    v_reason := case
      when v_can_order                     then 'none'
      when v_suspended                     then 'suspended'
      when v_sup is not null
        or v_pend_sup_name is not null     then 'supplier_account'
      when v_is_staff                      then 'staff_account'
      when not v_has_cust                  then 'not_registered'
      else 'pending_approval' end;
  end if;

  -- CMD #1889 — an approved customer with no drug licence on file is refused
  -- HERE, by the backend, with the backend's own sentence. Flutter checks
  -- nothing: _place_order_v2_core already raises on this same gate, so the
  -- storefront and the order path can never disagree.
  if v_reason = 'none' then
    declare v_lic uuid := coalesce(v_act, v_cust);
    begin
      if v_lic is not null
         and coalesce((public.licence_order_block(v_lic)->>'blocked')::boolean, false) then
        v_can_order := false;
        v_reason := 'licence_required';
      end if;
    exception when others then null;
    end;
  end if;

  if v_reason = 'none' then
    v_gate := jsonb_build_object('has_blocker', false, 'reason','none',
      'title','', 'message','', 'action_label','', 'action_route','', 'short_label','');
  else
    v_copy := coalesce((select value from app_settings where key='order_gate_copy'), '{}'::jsonb)
              -> v_reason;
    v_gate := jsonb_build_object(
      'has_blocker',  true, 'reason', v_reason,
      'title',        coalesce(v_copy->>'title',''),
      'message',      coalesce(v_copy->>'message',''),
      'action_label', coalesce(v_copy->>'action_label',''),
      'action_route', coalesce(v_copy->>'action_route',''),
      'short_label',  coalesce(v_copy->>'short_label',''));
  end if;

  return jsonb_build_object(
    'signed_in',              true,
    'auth_user_id',           coalesce(auth.uid()::text,''),
    'login_email',            coalesce(public.my_login_email(),''),
    'role',                   v_role,
    'is_admin',               (v_role in ('admin','super_admin')),
    'is_super_admin',         (v_role = 'super_admin'),
    'is_supplier',            (v_sup is not null),
    'is_customer',            (v_cust is not null),
    'is_registered_customer', v_registered,
    'is_worker',              (v_role = 'worker'),
    'surface',                v_surface,
    'owner_type',             coalesce(v_owner.owner_type,
                                case when v_role in ('admin','super_admin') then 'admin' else 'customer' end),
    'owner_id',               coalesce(v_owner.owner_id, v_sup::text, v_cust::text, ''),
    'supplier_id',            coalesce(v_sup::text,''),
    'supplier_name',          coalesce(sp.supplier_name, v_pend_sup_name, ''),
    'customer_id',            coalesce(v_cust::text,''),
    'customer_name',          coalesce(v_name,''),
    'display_name',           coalesce(nullif(ap.pharmacy_name,''),
                                nullif(ap.customer_name,''), v_name, ''),
    'acting_as_name',         coalesce(nullif(ap.pharmacy_name,''),
                                nullif(ap.customer_name,''), ''),
    'header_title',           coalesce(nullif(ap.pharmacy_name,''),
                                nullif(ap.customer_name,''),
                                nullif(v_name,''), 'My Account'),
    'status_label',           public.my_session_status_label(
                                (v_sup is not null), (v_pend_sup_name is not null),
                                v_has_cust, v_registered, v_suspended,
                                (v_role in ('admin','super_admin'))),
    'profile',                v_profile,
    'home_route',             coalesce(v_cfg.home_route,'/store'),
    'home_label',             coalesce(v_cfg.home_label,'Store'),
    'identities',             coalesce((select jsonb_agg(jsonb_build_object(
                                          'identity', coalesce(li.identity,''),
                                          'kind', coalesce(li.kind,''))
                                        order by li.kind, li.identity)
                                        from login_identities li
                                        where li.owner_type = v_owner.owner_type
                                          and li.owner_id = v_owner.owner_id), '[]'::jsonb),
    'message',                'Signed in',
    'has_customer_account',   v_has_cust,
    'is_suspended',           v_suspended,
    'is_pending_supplier',    (v_pend_sup_name is not null),
    'supplier_status',        v_sup_status,
    'needs_profile',          v_needs_profile,
    -- CMD #1904: where a signed-up-but-unregistered user is sent. Empty for
    -- everybody else, so the login screen keeps using home_route.
    'signup_route',           case when v_needs_profile
                                then coalesce(public.login_signup_cfg()->>'signup_route','')
                                else '' end,
    -- …and what that form starts with. The synthetic <number>@wa.medibo.in
    -- address the WhatsApp login mints is NOT an email the customer has, so
    -- it is never prefilled into a field they would then save.
    'signup_prefill',         (select jsonb_build_object(
        'phone', coalesce(
                   nullif(right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10),''),
                   coalesce(u.raw_user_meta_data->>'phone','')),
        'email', case when lower(coalesce(u.email,'')) like
                        ('%@' || coalesce(public.login_signup_cfg()->>'internal_email_domain',
                                          'wa.medibo.in'))
                      then '' else coalesce(u.email,'') end)
      from auth.users u where u.id = auth.uid()),
    'can_place_order',        v_can_order,
    'acting_as',              coalesce(v_act::text,''),
    'order_gate',             v_gate,
    'pending_supplier_screen', (select jsonb_build_object(
        'title',   coalesce(c->>'title_prefix','')
                   || coalesce(nullif(v_pend_sup_name,''), c->>'fallback_name', ''),
        'message', coalesce(c->>'message',''),
        'sign_out_label', coalesce(c->>'sign_out_label',''))
      from (select (select value from app_settings where key='pending_supplier_screen') as c) z),
    'bulk_wa_gate',           (select jsonb_build_object(
                                 'label',   coalesce(c->>'label',''),
                                 'note',    coalesce(c->>'note',''),
                                 'enabled', coalesce((c->>'enabled')::boolean,false),
                                 'action',  coalesce(c->>'action','none'),
                                 'has_note',(coalesce(c->>'note','') <> ''))
                               from (select (select value from app_settings
                                             where key='bulk_wa_gate_copy') -> v_reason as c) z));
end $function$;

CREATE OR REPLACE FUNCTION public.submit_registration(p_kind text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_allowed text[];
  v_key text; v_cols text[] := '{}'; v_vals text[] := '{}';
  v_rejected text[] := '{}';
  v_table text; v_id text;
  -- privilege columns an applicant may never set for themselves
  v_forbidden text[] := array['status','approved','approved_at','approved_by',
                              'is_deleted','deleted_at','deleted_by','user_id','id'];
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  -- CHANGE #705 — the customer "Complete Registration" flow joins the same
  -- door every other kind already used, so a pharmacy gets the same allow-list,
  -- the same forbidden-column guard and the same review + reason feedback.
  if p_kind = 'pharmacy' then
    v_table := 'pharmacy_profiles';
    v_allowed := array['pharmacy_name','customer_name','owner_name','phone','whatsapp_no',
                       'other_contact_no','email','address','address_local','city','district',
                       'state','pincode','gstin','gst_no','drug_license','dl_20b','dl_21b',
                       'store_type','store_location_link'];
  elsif p_kind = 'supplier' then
    v_table := 'supplier_profiles';
    v_allowed := array['supplier_name','contact_name','phone','whatsapp_no','email',
                       'city','state','address','gstin','drug_license','notes',
                       'supplier_code'];
  elsif p_kind = 'mr' then
    v_table := 'mr_registrations';
    v_allowed := array['full_name','phone','email','company_represented',
                       'territory_zone','city','state','address','id_proof_type'];
  elsif p_kind = 'company' then
    v_table := 'company_profiles';
    v_allowed := array['company_name','contact_person','phone','email','gst_no',
                       'drug_license','product_categories','registered_address',
                       'city','state','website'];
  elsif p_kind = 'delivery_partner' then
    v_table := 'delivery_partner_registrations';
    v_allowed := array['full_name','phone','email','vehicle_type','delivery_zone',
                       'city','state','address','id_proof_type'];
  else
    raise exception 'unknown_registration_kind: %', p_kind;
  end if;

  for v_key in select jsonb_object_keys(coalesce(p_payload,'{}'::jsonb)) loop
    if v_key = any(v_forbidden) then
      v_rejected := v_rejected || v_key;          -- reported, never applied
    elsif v_key = any(v_allowed) then
      v_cols := v_cols || quote_ident(v_key);
      v_vals := v_vals || quote_nullable(nullif(btrim(coalesce(p_payload->>v_key,'')), ''));
    else
      v_rejected := v_rejected || v_key;
    end if;
  end loop;

  -- The server sets identity and approval state, always.
  v_cols := v_cols || quote_ident('user_id');
  v_vals := v_vals || quote_literal(v_uid::text);
  v_cols := v_cols || quote_ident('status');
  v_vals := v_vals || quote_literal('pending');
  if p_kind in ('supplier','pharmacy') then
    v_cols := v_cols || quote_ident('approved');
    v_vals := v_vals || 'false'::text;
  end if;

  execute format('insert into %I (%s) values (%s) returning id::text',
                 v_table, array_to_string(v_cols, ', '), array_to_string(v_vals, ', '))
     into v_id;

  -- CMD #1904: a WhatsApp signup holds an UNCLAIMED identity row (owner_id '')
  -- until the row it belongs to exists. This is where it starts existing, so
  -- the identity is pointed at it and every identity-keyed read (my_owner,
  -- my_customer_id, login_bind_owner) resolves from here on. Only a blank
  -- owner_id is ever repointed — a registration never steals someone's login.
  perform public.login_identity_claim(
            case p_kind when 'pharmacy'         then 'customer'
                        when 'delivery_partner' then 'delivery'
                        else p_kind end, v_id);

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind,
    'id', coalesce(v_id,''),
    'status', 'pending',
    'rejected_keys', to_jsonb(v_rejected),
    'had_rejected', (array_length(v_rejected,1) is not null));
end $function$;

-- ── 10. The identity sync trigger learns what "unclaimed" means ────────────
-- Every owner table already keeps login_identities in step with its phone and
-- email columns, and refuses an identity that belongs to somebody else. A
-- WhatsApp signup's row belongs to NOBODY yet (owner_id ''), so without this
-- the very registration the signup exists to reach died on
-- "identity_taken: … is already linked to another customer account".
-- An unclaimed row is now claimed by the row being written, and it still
-- refuses an identity that a real owner holds.
create or replace function public._login_identities_sync()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_type text := TG_ARGV[0];
  v_cols text[] := string_to_array(TG_ARGV[1], ',');
  j jsonb; v_id text; v_dead boolean;
  c text; raw text; part text; k text;
  v_keys text[] := '{}';
  v_conf record;
begin
  if TG_OP = 'DELETE' then
    delete from login_identities
     where owner_type = v_type and owner_id = (to_jsonb(OLD)->>'id');
    return OLD;
  end if;

  j := to_jsonb(NEW);
  v_id := j->>'id';
  v_dead := coalesce((j->>'is_deleted')::boolean, false);

  if not v_dead then
    foreach c in array v_cols loop
      raw := j->>c;
      if raw is not null then
        foreach part in array string_to_array(raw, ',') loop
          k := identity_norm(btrim(part));
          if k is not null and not (k = any(v_keys)) then v_keys := v_keys || k; end if;
        end loop;
      end if;
    end loop;
  end if;

  select li.identity, li.owner_type into v_conf
  from login_identities li
  where li.identity = any(v_keys)
    and not (li.owner_type = v_type and li.owner_id = v_id)
    -- CMD #1904: a blank owner_id is a signup waiting for its row, not a
    -- conflict. Nothing else in the table is ever allowed to be blank.
    and coalesce(btrim(li.owner_id),'') <> ''
  limit 1;

  if found then
    raise exception 'identity_taken: % is already linked to another % account - remove it there first',
      v_conf.identity, v_conf.owner_type using errcode = '23505';
  end if;

  -- CMD #1904: claim the signup's own row rather than colliding with it. The
  -- kind it was written with (whatsapp) is kept — this is the same number.
  update login_identities
     set owner_type = v_type, owner_id = v_id
   where identity = any(v_keys) and coalesce(btrim(owner_id),'') = '';

  delete from login_identities
   where owner_type = v_type and owner_id = v_id and identity <> all(v_keys);

  insert into login_identities (identity, kind, owner_type, owner_id)
  select x, case when position('@' in x) > 0 then 'email' else 'phone' end, v_type, v_id
  from unnest(v_keys) x
  on conflict (identity) do nothing;

  return NEW;
end $function$;

-- ── 11. The registration screen's own words ────────────────────────────────
-- /complete-registration is a real route, so it can be opened cold, on a slow
-- connection, or by somebody whose session has already expired. Each of those
-- is a state with a sentence, and every sentence is here rather than in Dart.
insert into public.ui_copy (key, value) values
  ('signup.complete_title',
   to_jsonb('Complete registration'::text)),
  ('signup.needs_login',
   to_jsonb('Sign in first — we''ll bring you straight back here'::text)),
  ('signup.needs_login_cta', to_jsonb('Sign in'::text)),
  ('signup.load_error',
   to_jsonb('Couldn''t load your account just now'::text)),
  ('signup.retry', to_jsonb('Retry'::text)),
  ('signup.already_done',
   to_jsonb('Your registration is already in — nothing more to fill in here'::text)),
  ('signup.already_done_cta', to_jsonb('Continue'::text))
on conflict (key) do nothing;

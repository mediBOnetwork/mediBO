-- CHANGE #463 · feature_gaps row 121 —
-- "Rider identity is never verified beyond an OCR read of a document".
--
-- The register row's own finding: delivery_partner_registrations carried
-- id_doc_* + ocr_payload and NOTHING else — no proof the phone number on file
-- belongs to the applicant, no face, and no verification state a reviewer
-- could move. delivery_otp is not reusable for this: it is keyed by
-- delivery_id and exists for proof-of-delivery at the door.
--
-- This migration builds the three directions the row asked for, in one pass so
-- none of them lands as an orphan:
--   1. a registration-time phone OTP with attempts + lockout, sent through the
--      login-otp edge function that already carries mediBO's WhatsApp OTPs;
--   2. a selfie in a PRIVATE bucket, with policies mirroring the id_doc
--      handling — plus a scoped read so a customer sees the face of the rider
--      who is on their doorstep and of nobody else;
--   3. a verification state machine surfaced to the admin reviewer on the
--      screen that already reviews these rows.
--
-- Idempotent end to end: every add is "if not exists", every function is
-- "create or replace", every seed is "on conflict". Re-applying is a no-op.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. SCHEMA
-- ═══════════════════════════════════════════════════════════════════════

alter table public.delivery_partner_registrations
  add column if not exists phone_verified_at   timestamptz,
  add column if not exists selfie_path         text,
  add column if not exists selfie_at           timestamptz,
  add column if not exists verification_status text default 'unverified',
  add column if not exists verification_note   text,
  add column if not exists verified_by         uuid,
  add column if not exists verified_at         timestamptz;

update public.delivery_partner_registrations
   set verification_status = 'unverified'
 where verification_status is null;

-- Thresholds live in config, never in the RPC.
alter table public.delivery_config
  add column if not exists reg_otp_ttl_minutes    int     default 10,
  add column if not exists reg_otp_max_attempts   int     default 5,
  add column if not exists reg_otp_lock_minutes   int     default 15,
  add column if not exists reg_otp_resend_seconds int     default 30,
  add column if not exists reg_phone_otp_required boolean default true,
  add column if not exists reg_selfie_required    boolean default true;

update public.delivery_config
   set reg_otp_ttl_minutes    = coalesce(reg_otp_ttl_minutes, 10),
       reg_otp_max_attempts   = coalesce(reg_otp_max_attempts, 5),
       reg_otp_lock_minutes   = coalesce(reg_otp_lock_minutes, 15),
       reg_otp_resend_seconds = coalesce(reg_otp_resend_seconds, 30),
       reg_phone_otp_required = coalesce(reg_phone_otp_required, true),
       reg_selfie_required    = coalesce(reg_selfie_required, true)
 where id = 1;

-- The pre-submit staging row. A rider verifies a phone and takes a selfie
-- BEFORE delivery_partner_register() creates their registration, so the state
-- cannot hang off the registration id — it hangs off the signed-in account.
create table if not exists public.delivery_reg_identity (
  user_id          uuid primary key,
  phone            text,
  code_hash        text,
  sent_at          timestamptz,
  expires_at       timestamptz,
  attempts         int default 0,
  locked_until     timestamptz,
  verified_phone   text,
  phone_verified_at timestamptz,
  selfie_path      text,
  selfie_at        timestamptz,
  updated_at       timestamptz default now()
);

alter table public.delivery_reg_identity enable row level security;

-- No policy on purpose: every read and write goes through the SECURITY DEFINER
-- RPCs below, so a code hash is never reachable from a client session.

-- ═══════════════════════════════════════════════════════════════════════
-- 2. THE SELFIE BUCKET — private, unlike partner-docs
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public)
values ('rider-selfies', 'rider-selfies', false)
on conflict (id) do update set public = false;

drop policy if exists rider_selfies_owner_insert on storage.objects;
create policy rider_selfies_owner_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'rider-selfies'
              and name like 'selfies/' || auth.uid()::text || '/%');

drop policy if exists rider_selfies_owner_read on storage.objects;
create policy rider_selfies_owner_read on storage.objects
  for select to authenticated
  using (bucket_id = 'rider-selfies'
         and name like 'selfies/' || auth.uid()::text || '/%');

drop policy if exists rider_selfies_admin_all on storage.objects;
create policy rider_selfies_admin_all on storage.objects
  for all to authenticated
  using (bucket_id = 'rider-selfies' and public.is_admin())
  with check (bucket_id = 'rider-selfies' and public.is_admin());

-- The scoped customer read. A buyer may look at the face of the rider who is
-- carrying THEIR order, while that stop is live, and only once an admin has
-- verified the identity. Not before, not after, and never for anyone else.
drop policy if exists rider_selfies_customer_read on storage.objects;
create policy rider_selfies_customer_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'rider-selfies'
    and exists (
      select 1
        from public.delivery_partner_registrations r
        join public.deliveries dd on dd.partner_id = r.id
        join public.orders o      on o.id = dd.order_id
        join public.pharmacy_profiles pp on pp.id = o.customer_id
       where r.selfie_path = storage.objects.name
         and coalesce(r.verification_status,'') = 'verified'
         and dd.status in ('assigned','out_for_delivery')
         and pp.user_id = auth.uid()
    )
  );

-- ═══════════════════════════════════════════════════════════════════════
-- 3. COPY — every sentence the rider or the admin reads
-- ═══════════════════════════════════════════════════════════════════════

insert into public.ui_copy (key, value) values
  ('delivery.verif_title',        to_jsonb('Verify your identity'::text)),
  ('delivery.verif_note',         to_jsonb('We verify every rider before the first delivery. It takes a minute.'::text)),
  ('delivery.verif_phone_label',  to_jsonb('Mobile number'::text)),
  ('delivery.verif_phone_hint',   to_jsonb('We send a 6-digit code on WhatsApp.'::text)),
  ('delivery.verif_send',         to_jsonb('Send code'::text)),
  ('delivery.verif_resend',       to_jsonb('Send again'::text)),
  ('delivery.verif_code_label',   to_jsonb('6-digit code'::text)),
  ('delivery.verif_check',        to_jsonb('Verify'::text)),
  ('delivery.verif_sent',         to_jsonb('Code sent on WhatsApp'::text)),
  ('delivery.verif_wait',         to_jsonb('Code already sent — wait a moment before asking again.'::text)),
  ('delivery.verif_bad_phone',    to_jsonb('Enter a valid 10-digit mobile number.'::text)),
  ('delivery.verif_bad_code',     to_jsonb('That code is not right.'::text)),
  ('delivery.verif_expired',      to_jsonb('That code has expired — ask for a new one.'::text)),
  ('delivery.verif_locked',       to_jsonb('Too many wrong codes. Try again later.'::text)),
  ('delivery.verif_phone_ok',     to_jsonb('Mobile number verified'::text)),
  ('delivery.verif_selfie_label', to_jsonb('Your photo'::text)),
  ('delivery.verif_selfie_hint',  to_jsonb('A clear photo of your face. Customers see it only while you are delivering to them.'::text)),
  ('delivery.verif_selfie_cta',   to_jsonb('Take photo'::text)),
  ('delivery.verif_selfie_retake',to_jsonb('Retake photo'::text)),
  ('delivery.verif_selfie_ok',    to_jsonb('Photo saved'::text)),
  ('delivery.verif_selfie_bad',   to_jsonb('That photo could not be saved — try again.'::text)),
  ('delivery.verif_no_session',   to_jsonb('Sign in first so we can attach the verification to your account.'::text)),
  ('delivery.verif_need_phone',   to_jsonb('Verify your mobile number before submitting.'::text)),
  ('delivery.verif_need_selfie',  to_jsonb('Add your photo before submitting.'::text)),
  ('delivery.verif_ready',        to_jsonb('Identity checks done — you can submit.'::text)),
  ('delivery.vs_unverified',      to_jsonb('Not verified'::text)),
  ('delivery.vs_phone_verified',  to_jsonb('Phone verified'::text)),
  ('delivery.vs_selfie_captured', to_jsonb('Photo on file'::text)),
  ('delivery.vs_verified',        to_jsonb('Identity verified'::text)),
  ('delivery.vs_rejected',        to_jsonb('Identity rejected'::text)),
  ('delivery.verif_admin_title',  to_jsonb('Identity'::text)),
  ('delivery.verif_view_selfie',  to_jsonb('View photo'::text)),
  ('delivery.verif_mark_ok',      to_jsonb('Mark verified'::text)),
  ('delivery.verif_mark_bad',     to_jsonb('Reject identity'::text)),
  ('delivery.verif_saved',        to_jsonb('Identity status updated'::text)),
  ('delivery.verif_not_allowed',  to_jsonb('You are not allowed to change identity status.'::text)),
  ('delivery.verif_unknown',      to_jsonb('That identity status is not one we use.'::text)),
  ('delivery.verif_no_partner',   to_jsonb('That registration no longer exists.'::text)),
  ('delivery.rider_photo_label',  to_jsonb('Your delivery partner'::text))
on conflict (key) do nothing;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. HELPERS
-- ═══════════════════════════════════════════════════════════════════════

-- The chip, in one place, so the rider's own screen and the admin queue can
-- never disagree about what a status is called or what colour it reads as.
create or replace function public._delivery_verif_chip(p_status text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'key',   coalesce(p_status,'unverified'),
    'label', case coalesce(p_status,'unverified')
               when 'phone_verified'  then public.uic('delivery.vs_phone_verified','Phone verified')
               when 'selfie_captured' then public.uic('delivery.vs_selfie_captured','Photo on file')
               when 'verified'        then public.uic('delivery.vs_verified','Identity verified')
               when 'rejected'        then public.uic('delivery.vs_rejected','Identity rejected')
               else public.uic('delivery.vs_unverified','Not verified') end,
    -- a semantic tone, never a hex string: register row 112 is exactly what
    -- happens when a payload posts colours at a screen.
    'tone',  case coalesce(p_status,'unverified')
               when 'verified' then 'good'
               when 'rejected' then 'bad'
               when 'unverified' then 'warn'
               else 'info' end);
$$;

-- The rider's face on a tracking payload — the half of register row 117 that
-- had no column to stand on until this migration. It carries a bucket and a
-- path, never a URL: the storage policy above decides who may sign it.
create or replace function public._rider_photo_block(p_partner_id uuid, p_status text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select jsonb_build_object(
        'has',    true,
        'bucket', 'rider-selfies',
        'path',   r.selfie_path,
        'label',  public.uic('delivery.rider_photo_label','Your delivery partner'))
       from delivery_partner_registrations r
      where r.id = p_partner_id
        and coalesce(r.selfie_path,'') <> ''
        and coalesce(r.verification_status,'') = 'verified'
        and coalesce(p_status,'') in ('assigned','out_for_delivery')),
    jsonb_build_object('has', false));
$$;

-- One place that decides what state an applicant is in, from the facts.
create or replace function public._delivery_verif_status(p_phone_ok boolean, p_selfie_ok boolean)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_phone_ok,false) and coalesce(p_selfie_ok,false) then 'selfie_captured'
    when coalesce(p_phone_ok,false) then 'phone_verified'
    else 'unverified' end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- 5. THE RIDER'S OWN SURFACE
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.delivery_reg_verification()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_id  delivery_reg_identity%rowtype;
  v_reg delivery_partner_registrations%rowtype;
  c     delivery_config%rowtype;
  v_phone_ok boolean; v_selfie_ok boolean; v_status text; v_block text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', public.uic('delivery.verif_no_session',
        'Sign in first so we can attach the verification to your account.'));
  end if;

  select * into c from delivery_config where id = 1;
  select * into v_id  from delivery_reg_identity where user_id = auth.uid();
  select * into v_reg from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false
     and coalesce(status,'') <> 'rejected'
   order by submitted_at desc limit 1;

  -- A submitted registration is the authority once it exists; before that the
  -- staging row is.
  v_phone_ok  := coalesce(v_reg.phone_verified_at, v_id.phone_verified_at) is not null;
  v_selfie_ok := coalesce(nullif(coalesce(v_reg.selfie_path, v_id.selfie_path),''),'') <> '';
  v_status    := coalesce(v_reg.verification_status,
                          public._delivery_verif_status(v_phone_ok, v_selfie_ok));

  v_block := case
    when coalesce(c.reg_phone_otp_required, true) and not v_phone_ok
      then public.uic('delivery.verif_need_phone','Verify your mobile number before submitting.')
    when coalesce(c.reg_selfie_required, true) and not v_selfie_ok
      then public.uic('delivery.verif_need_selfie','Add your photo before submitting.')
    else '' end;

  return jsonb_build_object(
    'ok', true,
    'title', public.uic('delivery.verif_title','Verify your identity'),
    'note',  public.uic('delivery.verif_note',
              'We verify every rider before the first delivery. It takes a minute.'),
    'phone', jsonb_build_object(
        'verified',       v_phone_ok,
        'required',       coalesce(c.reg_phone_otp_required, true),
        'value',          coalesce(v_reg.phone, v_id.verified_phone, v_id.phone, ''),
        'label',          public.uic('delivery.verif_phone_label','Mobile number'),
        'hint',           public.uic('delivery.verif_phone_hint','We send a 6-digit code on WhatsApp.'),
        'send_label',     case when v_id.sent_at is null
                               then public.uic('delivery.verif_send','Send code')
                               else public.uic('delivery.verif_resend','Send again') end,
        'code_label',     public.uic('delivery.verif_code_label','6-digit code'),
        'verify_label',   public.uic('delivery.verif_check','Verify'),
        'ok_label',       public.uic('delivery.verif_phone_ok','Mobile number verified'),
        'awaiting_code',  (v_id.code_hash is not null
                           and coalesce(v_id.expires_at, now()) > now()
                           and not v_phone_ok),
        'resend_seconds', coalesce(c.reg_otp_resend_seconds, 30)),
    'selfie', jsonb_build_object(
        'has',        v_selfie_ok,
        'required',   coalesce(c.reg_selfie_required, true),
        'label',      public.uic('delivery.verif_selfie_label','Your photo'),
        'hint',       public.uic('delivery.verif_selfie_hint',
                        'A clear photo of your face. Customers see it only while you are delivering to them.'),
        'cta',        case when v_selfie_ok
                           then public.uic('delivery.verif_selfie_retake','Retake photo')
                           else public.uic('delivery.verif_selfie_cta','Take photo') end,
        'bucket',     'rider-selfies',
        'path',       coalesce(v_reg.selfie_path, v_id.selfie_path, '')),
    'status', public._delivery_verif_chip(v_status),
    'can_submit', (v_block = ''),
    'blocked_message', v_block,
    'ready_message', case when v_block = ''
                          then public.uic('delivery.verif_ready','Identity checks done — you can submit.')
                          else '' end);
end $function$;

create or replace function public.delivery_reg_send_otp(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c delivery_config%rowtype; v_id delivery_reg_identity%rowtype;
  k text; v_code text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', public.uic('delivery.verif_no_session',
        'Sign in first so we can attach the verification to your account.'));
  end if;

  select * into c from delivery_config where id = 1;
  k := public.identity_norm(coalesce(p->>'phone',''));
  if k is null then
    return jsonb_build_object('ok', false, 'error', 'bad_phone',
      'message', public.uic('delivery.verif_bad_phone','Enter a valid 10-digit mobile number.'));
  end if;

  select * into v_id from delivery_reg_identity where user_id = auth.uid();

  if v_id.locked_until is not null and v_id.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked',
      'message', public.uic('delivery.verif_locked','Too many wrong codes. Try again later.'));
  end if;

  -- The same 30-second floor the login OTP keeps, read from config.
  if v_id.sent_at is not null and v_id.phone = k
     and v_id.sent_at > now() - make_interval(secs => coalesce(c.reg_otp_resend_seconds, 30)) then
    return jsonb_build_object('ok', false, 'error', 'too_soon',
      'message', public.uic('delivery.verif_wait',
        'Code already sent — wait a moment before asking again.'));
  end if;

  v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');

  insert into delivery_reg_identity as t
    (user_id, phone, code_hash, sent_at, expires_at, attempts, locked_until, updated_at)
  values (auth.uid(), k, md5(k || ':' || v_code), now(),
          now() + make_interval(mins => coalesce(c.reg_otp_ttl_minutes, 10)), 0, null, now())
  on conflict (user_id) do update
    set phone = excluded.phone, code_hash = excluded.code_hash,
        sent_at = excluded.sent_at, expires_at = excluded.expires_at,
        attempts = 0, locked_until = null, updated_at = now();

  -- The transport the platform already uses for OTPs. Nothing new is stood up
  -- here and no second sender exists to drift.
  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-login-secret','medibo_login_otp_2027'),
    body := jsonb_build_object('mode','send','phone', k, 'code', v_code));

  return jsonb_build_object('ok', true,
    'message', public.uic('delivery.verif_sent','Code sent on WhatsApp'),
    'state', public.delivery_reg_verification());
end $function$;

create or replace function public.delivery_reg_verify_otp(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c delivery_config%rowtype; v_id delivery_reg_identity%rowtype;
  k text; v_code text; v_selfie_ok boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', public.uic('delivery.verif_no_session',
        'Sign in first so we can attach the verification to your account.'));
  end if;

  select * into c from delivery_config where id = 1;
  select * into v_id from delivery_reg_identity where user_id = auth.uid();
  v_code := btrim(coalesce(p->>'code',''));
  k := coalesce(public.identity_norm(coalesce(p->>'phone','')), v_id.phone);

  if v_id.user_id is null or v_id.code_hash is null then
    return jsonb_build_object('ok', false, 'error', 'expired',
      'message', public.uic('delivery.verif_expired','That code has expired — ask for a new one.'));
  end if;
  if v_id.locked_until is not null and v_id.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked',
      'message', public.uic('delivery.verif_locked','Too many wrong codes. Try again later.'));
  end if;
  if coalesce(v_id.expires_at, now()) <= now() then
    return jsonb_build_object('ok', false, 'error', 'expired',
      'message', public.uic('delivery.verif_expired','That code has expired — ask for a new one.'));
  end if;

  if v_id.code_hash <> md5(coalesce(k,'') || ':' || v_code) then
    update delivery_reg_identity
       set attempts = coalesce(attempts,0) + 1,
           locked_until = case
             when coalesce(attempts,0) + 1 >= coalesce(c.reg_otp_max_attempts, 5)
               then now() + make_interval(mins => coalesce(c.reg_otp_lock_minutes, 15))
             else locked_until end,
           updated_at = now()
     where user_id = auth.uid();
    return jsonb_build_object('ok', false, 'error', 'bad_code',
      'message', public.uic('delivery.verif_bad_code','That code is not right.'),
      'state', public.delivery_reg_verification());
  end if;

  update delivery_reg_identity
     set verified_phone = k, phone_verified_at = now(),
         code_hash = null, attempts = 0, locked_until = null, updated_at = now()
   where user_id = auth.uid();

  -- If the application is already in, the verification lands on it too, so an
  -- admin reviewing tomorrow sees today's proof.
  select coalesce(nullif(coalesce(selfie_path,''),''),'') <> ''
    into v_selfie_ok
    from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false
   order by submitted_at desc limit 1;

  update delivery_partner_registrations
     set phone_verified_at = now(),
         verification_status = case
           when verification_status in ('verified','rejected') then verification_status
           else public._delivery_verif_status(true, coalesce(v_selfie_ok,false)) end
   where user_id = auth.uid() and coalesce(is_deleted,false) = false
     and coalesce(status,'') <> 'rejected';

  return jsonb_build_object('ok', true,
    'message', public.uic('delivery.verif_phone_ok','Mobile number verified'),
    'state', public.delivery_reg_verification());
end $function$;

create or replace function public.delivery_reg_selfie_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_path text; v_phone_ok boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', public.uic('delivery.verif_no_session',
        'Sign in first so we can attach the verification to your account.'));
  end if;

  v_path := btrim(coalesce(p->>'path',''));
  -- The path must be inside this account's own folder. A client that posts
  -- someone else's object gets nothing.
  if v_path = '' or v_path not like 'selfies/' || auth.uid()::text || '/%' then
    return jsonb_build_object('ok', false, 'error', 'bad_path',
      'message', public.uic('delivery.verif_selfie_bad','That photo could not be saved — try again.'));
  end if;

  insert into delivery_reg_identity as t (user_id, selfie_path, selfie_at, updated_at)
  values (auth.uid(), v_path, now(), now())
  on conflict (user_id) do update
    set selfie_path = excluded.selfie_path, selfie_at = now(), updated_at = now();

  select phone_verified_at is not null into v_phone_ok
    from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false
   order by submitted_at desc limit 1;

  update delivery_partner_registrations
     set selfie_path = v_path, selfie_at = now(),
         verification_status = case
           when verification_status in ('verified','rejected') then verification_status
           else public._delivery_verif_status(coalesce(v_phone_ok,false), true) end
   where user_id = auth.uid() and coalesce(is_deleted,false) = false
     and coalesce(status,'') <> 'rejected';

  return jsonb_build_object('ok', true,
    'message', public.uic('delivery.verif_selfie_ok','Photo saved'),
    'state', public.delivery_reg_verification());
end $function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 6. THE ADMIN'S SURFACE
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.admin_delivery_verification_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_status text; v_id uuid; v_found uuid;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_allowed',
      'message', public.uic('delivery.verif_not_allowed',
        'You are not allowed to change identity status.'));
  end if;

  v_status := btrim(coalesce(p->>'status',''));
  if v_status not in ('unverified','phone_verified','selfie_captured','verified','rejected') then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', public.uic('delivery.verif_unknown','That identity status is not one we use.'));
  end if;

  begin
    v_id := (p->>'partner_id')::uuid;
  exception when others then
    v_id := null;
  end;

  update delivery_partner_registrations
     set verification_status = v_status,
         verification_note   = nullif(btrim(coalesce(p->>'note','')),''),
         verified_by         = auth.uid(),
         verified_at         = now()
   where id = v_id
   returning id into v_found;

  if v_found is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.uic('delivery.verif_no_partner','That registration no longer exists.'));
  end if;

  return jsonb_build_object('ok', true,
    'message', public.uic('delivery.verif_saved','Identity status updated'),
    'verification', public._delivery_verif_chip(v_status));
end $function$;

-- The reviewer queue carries the state, so it has a surface on day one.
create or replace function public.admin_delivery_partners(p_zone smallint DEFAULT NULL::smallint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_zone smallint; v_zname text; v_pending jsonb; v_active jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false);
  end if;
  v_zone := public.scope_zone(p_zone);
  select name into v_zname from zones where id = v_zone;

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',p.id,'full_name',coalesce(p.full_name,''),'phone',coalesce(p.phone,''),
      'vehicle_type',coalesce(p.vehicle_type,''),'city',coalesce(p.city,''),
      'id_doc_type',coalesce(p.id_doc_type,''),'id_doc_number',coalesce(p.id_doc_number,''),
      'id_doc_path',coalesce(p.id_doc_path,''),'ocr_payload',p.ocr_payload,
      'submitted_at',p.submitted_at,'has_login',(p.user_id is not null),
      -- CHANGE #463 (register row 121): the identity block the reviewer acts on.
      'verification', public._delivery_verif_chip(p.verification_status)
        || jsonb_build_object(
             'title',        public.uic('delivery.verif_admin_title','Identity'),
             'phone_verified', (p.phone_verified_at is not null),
             'note',         coalesce(p.verification_note,''),
             'selfie_bucket','rider-selfies',
             'selfie_path',  coalesce(p.selfie_path,''),
             'view_label',   public.uic('delivery.verif_view_selfie','View photo'),
             'verify_label', public.uic('delivery.verif_mark_ok','Mark verified'),
             'reject_label', public.uic('delivery.verif_mark_bad','Reject identity'))
    ) order by p.submitted_at desc), '[]'::jsonb)
    into v_pending
  from delivery_partner_registrations p
  where coalesce(p.is_deleted,false)=false and p.is_active = false
    and coalesce(p.status,'pending') <> 'rejected';

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',p.id,'full_name',coalesce(p.full_name,''),'phone',coalesce(p.phone,''),
      'partner_type',p.partner_type,
      'type_label', case when p.partner_type='agency' then 'Agency' else 'Delivery boy' end,
      'type_colors', case when p.partner_type='agency'
                          then jsonb_build_object('bg','#E6F1FB','fg','#0C447C')
                          else jsonb_build_object('bg','#E1F5EE','fg','#0F6E56') end,
      'zone_id',p.zone_id,
      'zone_label', coalesce((select z.name from zones z where z.id = p.zone_id),'Not set'),
      'parent_agency_id',p.parent_agency_id,
      'parent_agency_name', coalesce((select a.full_name from delivery_partner_registrations a
                                       where a.id = p.parent_agency_id),''),
      'max_stops',p.max_stops,'per_drop_rate',p.per_drop_rate,
      'rider_count', (select count(*) from delivery_partner_registrations c
                       where c.parent_agency_id = p.id and coalesce(c.is_deleted,false)=false),
      'open_stops', (select count(*) from deliveries d where d.partner_id = p.id
                      and d.status in ('assigned','out_for_delivery')),
      'on_shift', exists(select 1 from delivery_partner_shifts s
                          where s.partner_id = p.id and s.ended_at is null),
      'has_login',(p.user_id is not null),
      'verification', public._delivery_verif_chip(p.verification_status)
        || jsonb_build_object(
             'title',        public.uic('delivery.verif_admin_title','Identity'),
             'phone_verified', (p.phone_verified_at is not null),
             'note',         coalesce(p.verification_note,''),
             'selfie_bucket','rider-selfies',
             'selfie_path',  coalesce(p.selfie_path,''),
             'view_label',   public.uic('delivery.verif_view_selfie','View photo'),
             'verify_label', public.uic('delivery.verif_mark_ok','Mark verified'),
             'reject_label', public.uic('delivery.verif_mark_bad','Reject identity'))
    ) order by p.partner_type desc, p.full_name), '[]'::jsonb)
    into v_active
  from delivery_partner_registrations p
  where coalesce(p.is_deleted,false)=false and p.is_active
    and public.scope_zone_ok(p.zone_id, v_zone);

  return jsonb_build_object(
    'allowed', true, 'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'),
    'pending', v_pending, 'pending_count', jsonb_array_length(v_pending),
    'partners', v_active, 'partner_count', jsonb_array_length(v_active),
    'type_options', jsonb_build_array(
        jsonb_build_object('value','boy','label','Delivery boy',
          'note','Delivers assigned orders. Sees only their own stops.'),
        jsonb_build_object('value','agency','label','Delivery agency',
          'note','Can add its own riders and hand stops to them.')),
    'pending_title','Awaiting approval',
    'pending_note','Approve a registration, choose whether they are a delivery boy or an agency, and set their zone.');
end $function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 7. REGISTRATION CARRIES THE PROOF
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.delivery_partner_register(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid; v_ocr jsonb := coalesce(p->'ocr_payload','{}'::jsonb); r record; v_name text;
  v_phone text; v_pincode text; v_zone_txt text; v_zone_id smallint;
  c delivery_config%rowtype; v_idn delivery_reg_identity%rowtype;
  v_phone_ok boolean; v_selfie text;
begin
  -- CHANGE #462 (gap 110): an anonymous caller used to create a row with
  -- user_id null — invisible to every RLS policy and claimable by no rider.
  if auth.uid() is null then
    return jsonb_build_object('ok',false,'error','not_signed_in',
      'message', public.uic('delivery.reg_no_session',
        'Sign in before applying so we can attach the application to your account.'));
  end if;

  if exists(select 1 from delivery_partner_registrations
             where user_id = auth.uid() and coalesce(is_deleted,false)=false
               and coalesce(status,'') <> 'rejected') then
    return jsonb_build_object('ok',false,'error','already_registered',
      'message', public.uic('delivery.reg_already','You have already applied — check the status below.'));
  end if;

  v_phone := coalesce(nullif(btrim(coalesce(p->>'phone','')),''),
                      nullif(btrim(coalesce(v_ocr->>'phone','')),''));

  -- CHANGE #462 (gap 110): and the same phone cannot carry two live applications.
  if v_phone is not null and exists(
       select 1 from delivery_partner_registrations
        where phone = v_phone and coalesce(is_deleted,false)=false
          and coalesce(status,'') <> 'rejected') then
    return jsonb_build_object('ok',false,'error','phone_taken',
      'message', public.uic('delivery.reg_phone_taken',
        'An application already exists for this phone number.'));
  end if;

  -- CHANGE #463 (register row 121): the identity checks are a GATE, not a
  -- decoration. The phone on the form must be the phone that answered the OTP,
  -- so a verified number cannot be swapped for an unverified one at submit.
  select * into c from delivery_config where id = 1;
  select * into v_idn from delivery_reg_identity where user_id = auth.uid();

  v_phone_ok := v_idn.phone_verified_at is not null
                and v_idn.verified_phone is not null
                and v_idn.verified_phone = public.identity_norm(coalesce(v_phone,''));
  v_selfie := nullif(coalesce(v_idn.selfie_path,''),'');

  if coalesce(c.reg_phone_otp_required, true) and not v_phone_ok then
    return jsonb_build_object('ok',false,'error','phone_not_verified',
      'message', public.uic('delivery.verif_need_phone',
        'Verify your mobile number before submitting.'));
  end if;
  if coalesce(c.reg_selfie_required, true) and v_selfie is null then
    return jsonb_build_object('ok',false,'error','selfie_missing',
      'message', public.uic('delivery.verif_need_selfie','Add your photo before submitting.'));
  end if;

  -- CHANGE #462 (gap 109): the pincode the form has always posted (and the OCR
  -- prefilled) is stored, and the free-text zone is RESOLVED to a zone_id — via
  -- the pincode map first, the zone's own code/name second, the default zone
  -- last — so the assign queue can actually see this rider.
  v_pincode := coalesce(nullif(btrim(coalesce(p->>'pincode','')),''),
                        nullif(btrim(coalesce(v_ocr->>'pincode','')),''));
  v_zone_txt := nullif(btrim(coalesce(p->>'delivery_zone','')),'');

  if v_pincode is not null then
    select s.zone_id into v_zone_id from delivery_serviceability s
     where s.pincode = v_pincode and coalesce(s.is_active,true) limit 1;
  end if;
  if v_zone_id is null and v_zone_txt is not null then
    select z.id into v_zone_id from zones z
     where coalesce(z.is_active,true)
       and (lower(btrim(z.code)) = lower(v_zone_txt) or lower(btrim(z.name)) = lower(v_zone_txt))
     limit 1;
  end if;
  if v_zone_id is null then
    select z.id into v_zone_id from zones z where coalesce(z.is_default,false) limit 1;
  end if;

  insert into delivery_partner_registrations(
    user_id, full_name, phone, email, vehicle_type, delivery_zone, zone_id, pincode,
    address, city, state,
    id_proof_type, id_doc_type, id_doc_number, id_doc_path, ocr_payload,
    partner_type, status, is_active, submitted_at,
    phone_verified_at, selfie_path, selfie_at, verification_status)
  values (auth.uid(),
    coalesce(nullif(btrim(coalesce(p->>'full_name','')),''), nullif(btrim(coalesce(v_ocr->>'name','')),'')),
    v_phone,
    nullif(btrim(coalesce(p->>'email','')),''),
    nullif(btrim(coalesce(p->>'vehicle_type','')),''),
    v_zone_txt,
    v_zone_id,
    v_pincode,
    coalesce(nullif(btrim(coalesce(p->>'address','')),''), nullif(btrim(coalesce(v_ocr->>'address','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'city','')),''), nullif(btrim(coalesce(v_ocr->>'city','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'state','')),''), nullif(btrim(coalesce(v_ocr->>'state','')),'')),
    nullif(btrim(coalesce(p->>'id_doc_type','')),''),
    nullif(btrim(coalesce(p->>'id_doc_type','')),''),
    coalesce(nullif(btrim(coalesce(p->>'id_doc_number','')),''), nullif(btrim(coalesce(v_ocr->>'id_number','')),'')),
    nullif(btrim(coalesce(p->>'id_doc_path','')),''),
    v_ocr,
    coalesce(nullif(btrim(coalesce(p->>'partner_type','')),''),'boy'),
    'pending', false, now(),
    case when v_phone_ok then v_idn.phone_verified_at end,
    v_selfie,
    v_idn.selfie_at,
    public._delivery_verif_status(v_phone_ok, v_selfie is not null))
  returning id, full_name into v_id, v_name;

  -- the admin alert the audit found missing: one inbox row per admin account
  for r in select a.email, u.id as uid from admins a
             left join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
  loop
    perform public._delivery_inbox(r.uid, r.email, 'delivery_partner_applied',
      public.uic('delivery.reg_admin_title','New rider application'),
      coalesce(v_name,'') , '/admin?tab=delivery');
  end loop;

  perform public._delivery_inbox(auth.uid(), null, 'delivery_partner_submitted',
    public.uic('delivery.reg_submitted_title','Application submitted'),
    public.uic('delivery.reg_submitted_body','An admin will review it and you will see the decision here.'),
    '/delivery-register');

  return jsonb_build_object('ok',true,'registration_id',v_id,
    'zone_id', v_zone_id, 'pincode', coalesce(v_pincode,''),
    'message', public.uic('delivery.reg_submitted_toast','Registration submitted — an admin will review it'));
end $function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 8. THE FACE ON THE TRACKING PAYLOAD (register row 117's deferred half)
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.customer_track_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid())
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
    ) into v_allowed;
  if not coalesce(v_allowed,false) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_tl := public.order_timeline(p_order_id);

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null then
    return jsonb_build_object('ok',true,'tracking',false,'status','preparing',
      'status_label','Preparing your order', 'timeline', v_tl);
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;

  select count(*) into v_ahead from deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  -- CHANGE #462 (gap 104)
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  return jsonb_build_object(
    'ok', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', d.status,
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    -- CHANGE #463 (register row 117's deferred half, unblocked by row 121):
    -- the rider's verified face, for the buyer at whose door they are standing.
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    'stops_ahead', coalesce(v_ahead,0),
    'stops_ahead_label', case when d.status not in ('assigned','out_for_delivery') then null
                              when coalesce(v_ahead,0) = 0 then 'You are next'
                              when v_ahead = 1 then '1 stop before you'
                              else v_ahead::text || ' stops before you' end,
    'rider_lat', case when d.status in ('assigned','out_for_delivery') then v_loc.lat end,
    'rider_lng', case when d.status in ('assigned','out_for_delivery') then v_loc.lng end,
    'location_updated_at', v_loc.updated_at,
    'destination_lat', d.lat, 'destination_lng', d.lng,
    'rider_arrived', (d.arrived_at is not null),
    'qr_token', case when v_show_qr then d.qr_token end,
    'delivered_at', d.delivered_at, 'proof_method', d.proof_method,
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    'timeline', v_tl);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════
-- 9. GRANTS
-- ═══════════════════════════════════════════════════════════════════════

revoke all on function public.delivery_reg_verification()        from public, anon;
revoke all on function public.delivery_reg_send_otp(jsonb)       from public, anon;
revoke all on function public.delivery_reg_verify_otp(jsonb)     from public, anon;
revoke all on function public.delivery_reg_selfie_save(jsonb)    from public, anon;
revoke all on function public.admin_delivery_verification_set(jsonb) from public, anon;

grant execute on function public.delivery_reg_verification()     to authenticated, service_role;
grant execute on function public.delivery_reg_send_otp(jsonb)    to authenticated, service_role;
grant execute on function public.delivery_reg_verify_otp(jsonb)  to authenticated, service_role;
grant execute on function public.delivery_reg_selfie_save(jsonb) to authenticated, service_role;
grant execute on function public.admin_delivery_verification_set(jsonb) to authenticated, service_role;
grant execute on function public._delivery_verif_chip(text)      to authenticated, service_role;
grant execute on function public._rider_photo_block(uuid, text)  to authenticated, service_role;
grant execute on function public._delivery_verif_status(boolean, boolean) to authenticated, service_role;

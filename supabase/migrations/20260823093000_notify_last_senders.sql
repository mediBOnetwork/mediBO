-- CHANGE — #297 part 1, step 3b: the last two senders that still posted on
-- their own, plus the cron that drains the retry queue and watches health.
--
-- The login OTP keeps its own transport on purpose. It is an AUTH path with
-- its own secret, its own send_status/send_error columns and its own poll
-- (login_otp_status); routing it through the route/template chooser would let
-- an unapproved template lock a user out of the app. It now writes a ledger
-- row instead, so it is visible in the same place as everything else.

begin;

create or replace function public.tg_notify_contact_inquiry()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.notify('contact_inquiry', null,
    jsonb_build_object(
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/notify-contact-inquiry',
      'legacy_body', jsonb_build_object('record', to_jsonb(NEW))));
  return NEW;
end $$;

create or replace function public.login_request_otp(p_input text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare k text; s jsonb; v_code text; v_prev login_otp%rowtype;
        c_demo_number constant text := '9000000000';
        c_demo_code   constant text := '123456';
begin
  k := identity_norm(p_input);
  if k is null then
    return jsonb_build_object('ok',false,'message','Enter a valid 10-digit number');
  end if;

  s := public.login_owner_state(k);
  if not (s->>'found')::boolean or not (s->>'ok')::boolean then
    return jsonb_build_object('ok',false,'message', s->>'message');
  end if;

  if k = c_demo_number then
    insert into login_otp (identity, code_hash, owner_type, owner_id, ticket, attempts,
                           sent_at, expires_at, consumed_at, send_status, send_via, send_error)
    values (k, md5(k || ':' || c_demo_code), s->>'owner_type', s->>'owner_id', null, 0,
            now(), now() + interval '10 years', null, 'sent', 'demo_static', null)
    on conflict (identity) do update
      set code_hash = excluded.code_hash, owner_type = excluded.owner_type,
          owner_id = excluded.owner_id, ticket = null, attempts = 0, sent_at = now(),
          expires_at = excluded.expires_at, consumed_at = null,
          send_status = 'sent', send_via = 'demo_static', send_error = null;
    return jsonb_build_object('ok',true,'message','Enter the code to continue','ttl_seconds',600,
                              'poll','login_otp_status');
  end if;

  select * into v_prev from login_otp where identity = k;
  if found and v_prev.sent_at > now() - interval '30 seconds' then
    return jsonb_build_object('ok',false,'message','Code already sent, wait 30 seconds');
  end if;

  v_code := lpad((floor(random()*1000000))::int::text, 6, '0');

  insert into login_otp (identity, code_hash, owner_type, owner_id, ticket, attempts,
                         sent_at, expires_at, consumed_at, send_status, send_via, send_error)
  values (k, md5(k || ':' || v_code), s->>'owner_type', s->>'owner_id', null, 0,
          now(), now() + interval '5 minutes', null, 'pending', null, null)
  on conflict (identity) do update
    set code_hash = excluded.code_hash, owner_type = excluded.owner_type,
        owner_id = excluded.owner_id, ticket = null, attempts = 0, sent_at = now(),
        expires_at = excluded.expires_at, consumed_at = null,
        send_status = 'pending', send_via = null, send_error = null;

  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
    headers := jsonb_build_object('Content-Type','application/json','x-login-secret','medibo_login_otp_2027'),
    body := jsonb_build_object('mode','send','phone', k, 'code', v_code));

  perform public.notify_log('login_otp', k, 'whatsapp', 'sent', 'auth',
                            null, null, null, null, null, '{}'::jsonb,
                            jsonb_build_object('note','auth transport, not route-gated'));

  return jsonb_build_object('ok',true,'message','Sending code on WhatsApp','ttl_seconds',300,
                            'poll','login_otp_status');
end $$;

commit;

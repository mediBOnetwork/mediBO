-- #297 QA fix (1/2) — the login/logout WhatsApp button replies were the last
-- sends still posting straight at the wa-reply edge function. They never
-- appeared in notification_log, never reached the retry queue and never counted
-- toward a health alert, which is the whole point of part 1: notify() is the
-- ONLY send entry point. Payloads stay byte-for-byte identical (these replies
-- are always inside an open 24 h window, so notify()'s legacy passthrough posts
-- exactly what the trigger posted before) — the only change is that every one
-- of them now leaves a ledger row. The copy moves out of SQL literals into
-- ui_copy so wording is an UPDATE, not a migration.
-- Idempotent: insert ... on conflict do nothing + create or replace.

insert into public.ui_copy(key, value) values
  ('wa.login.confirm_safe',  to_jsonb('Thank you{name}. Your account is safe and nothing has changed.'::text)),
  ('wa.login.already_out',   to_jsonb('You are already signed out. Open mediBO and sign in whenever you are ready.'::text)),
  ('wa.login.stale_alert',   to_jsonb('That alert is old, so nothing was changed. Sign in normally, or contact mediBO if you did not expect it.'::text)),
  ('wa.login.no_account',    to_jsonb('We could not find an account for this number. Please contact mediBO support.'::text)),
  ('wa.login.logout_none',   to_jsonb('Logout successful. No device was signed in, so nothing was left open.'::text)),
  ('wa.login.logout_done',   to_jsonb('Logout successful. {n} signed-in device(s) have been ended.'::text))
on conflict (key) do nothing;

-- Copy reader. Falls back to the shipped default so a deleted row can never
-- send an empty WhatsApp message.
create or replace function public._wa_login_copy(p_key text, p_args jsonb default '{}'::jsonb)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_txt text; k text;
begin
  select value #>> '{}' into v_txt from public.ui_copy where key = p_key;
  v_txt := nullif(btrim(coalesce(v_txt,'')),'');
  if v_txt is null then
    v_txt := case p_key
      when 'wa.login.confirm_safe' then 'Thank you{name}. Your account is safe and nothing has changed.'
      when 'wa.login.already_out'  then 'You are already signed out. Open mediBO and sign in whenever you are ready.'
      when 'wa.login.stale_alert'  then 'That alert is old, so nothing was changed. Sign in normally, or contact mediBO if you did not expect it.'
      when 'wa.login.no_account'   then 'We could not find an account for this number. Please contact mediBO support.'
      when 'wa.login.logout_none'  then 'Logout successful. No device was signed in, so nothing was left open.'
      when 'wa.login.logout_done'  then 'Logout successful. {n} signed-in device(s) have been ended.'
      else '' end;
  end if;
  for k in select jsonb_object_keys(coalesce(p_args,'{}'::jsonb)) loop
    v_txt := replace(v_txt, '{' || k || '}', coalesce(p_args->>k,''));
  end loop;
  return v_txt;
end $function$;

-- One send site for the whole trigger, and it goes through notify().
create or replace function public._wa_login_reply(p_event_key text, p_phone text, p_text text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  return public.notify(p_event_key, p_phone, jsonb_build_object(
    'legacy_url', 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
    'legacy_body', jsonb_build_object(
      'to',   p_phone,
      'tag',  case when p_event_key = 'login_confirm' then 'login_confirm' else 'login_logout' end,
      'text', p_text)));
end $function$;

create or replace function public._wa_login_button()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_ph text; v_txt text; v_killed int := 0; v_users int := 0; v_name text; v_ids uuid[];
begin
  if coalesce(new.direction,'') <> 'in' or coalesce(new.msg_type,'') <> 'button' then return new; end if;
  v_txt := lower(btrim(coalesce(new.text_body,'')));
  if v_txt not in ('yes its me','log out','logout') then return new; end if;

  v_ph := wa_normalize_phone(new.sender_phone);
  if v_ph is null then return new; end if;

  select coalesce(nullif(btrim(p.customer_name),''), p.pharmacy_name) into v_name
    from pharmacy_profiles p
   where right(wa_normalize_phone(coalesce(p.whatsapp_no,p.phone)),10) = right(v_ph,10) limit 1;

  if v_txt = 'yes its me' then
    delete from auth_force_logout f using auth.users u
     where f.user_id = u.id and (right(coalesce(u.phone,''),10) = right(v_ph,10)
        or lower(u.email) in (select lower(email) from pharmacy_profiles
                               where right(wa_normalize_phone(coalesce(whatsapp_no,phone)),10)=right(v_ph,10)
                              union all
                              select lower(email) from supplier_profiles
                               where right(wa_normalize_phone(coalesce(whatsapp_no,contact_no,phone)),10)=right(v_ph,10)));
    perform public._wa_login_reply('login_confirm', v_ph,
      public._wa_login_copy('wa.login.confirm_safe',
        jsonb_build_object('name', coalesce(' ' || v_name, ''))));
    return new;
  end if;

  -- one tap = one logout: ignore a repeat within 10 minutes
  if exists (select 1 from wa_logout_events le
              where le.phone = v_ph and le.created_at > now() - interval '10 minutes') then
    perform public._wa_login_reply('login_logout', v_ph,
      public._wa_login_copy('wa.login.already_out'));
    return new;
  end if;

  -- a button on an OLD alert refers to a session that is long gone
  if not exists (select 1 from whatsapp_messages om
                  where om.sender_phone = new.sender_phone and om.direction = 'out'
                    and om.routed_to = 'campaign'
                    and om.received_at > now() - interval '30 minutes') then
    perform public._wa_login_reply('login_logout', v_ph,
      public._wa_login_copy('wa.login.stale_alert'));
    return new;
  end if;

  -- every account this number can sign in with
  select coalesce(array_agg(u.id), '{}') into v_ids
  from auth.users u
  where right(coalesce(u.phone,''),10) = right(v_ph,10)
     or lower(u.email) in (select lower(email) from pharmacy_profiles
                            where right(wa_normalize_phone(coalesce(whatsapp_no,phone)),10)=right(v_ph,10)
                           union all
                           select lower(email) from supplier_profiles
                            where right(wa_normalize_phone(coalesce(whatsapp_no,contact_no,phone)),10)=right(v_ph,10));

  v_users := coalesce(array_length(v_ids,1),0);
  if v_users > 0 then
    select count(*) into v_killed from auth.sessions where user_id = any(v_ids);
    delete from auth.refresh_tokens where user_id = any(select u::text from unnest(v_ids) u);
    delete from auth.sessions where user_id = any(v_ids);
    insert into auth_force_logout(user_id, reason, requested_by)
    select unnest(v_ids), 'You signed out from WhatsApp', 'whatsapp_button'
    on conflict (user_id) do update set requested_at = now();
    insert into wa_logout_events(phone, wa_message_id, sessions_killed)
    values (v_ph, new.wa_message_id, v_killed);
  end if;

  perform public._wa_login_reply('login_logout', v_ph,
    case when v_users = 0 then public._wa_login_copy('wa.login.no_account')
         when v_killed = 0 then public._wa_login_copy('wa.login.logout_none')
         else public._wa_login_copy('wa.login.logout_done',
                jsonb_build_object('n', v_killed::text)) end);
  return new;
exception when others then
  return new;
end $function$;

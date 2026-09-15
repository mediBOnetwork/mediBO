-- CHANGE #321 — "Add login" on Payment and Partner did nothing.
--
-- Root cause: #307 introduced partner_users + admin_partner_user_add(), which
-- writes login_identities with owner_type='partner', but login_identities_
-- owner_type_check still listed only the seven pre-partner owner types. EVERY
-- add died on 23514 inside the function, the whole call rolled back, and the
-- screen swallowed the exception — so the button looked inert.
--
-- This migration:
--   1. teaches the CHECK about 'partner' (the ONLY constraint in the schema
--      that enumerates owner types — verified against pg_constraint and
--      pg_policies; login_otp.owner_type is unconstrained),
--   2. removes the c307 proof's leftover partner_users row,
--   3. closes the three remaining places that still did not know the word:
--      login_owner_state (no partner branch -> no name, no active check),
--      identity_owner_lookup (no owner_name for a partner) and
--      _wa_login_alert (partner was not in the #295 route list, so a partner
--      sign-in raised no login alert at all),
--   4. makes admin_partner_user_add/_remove ALWAYS answer with a message —
--      including an exception handler, so the next unexpected backend error
--      reaches the admin as words instead of silence.
--
-- Idempotent: every statement is drop-if-exists / create-or-replace / merge.

-- ── 1. the constraint ───────────────────────────────────────────────────────
alter table public.login_identities
  drop constraint if exists login_identities_owner_type_check;
alter table public.login_identities
  add constraint login_identities_owner_type_check
  check (owner_type = any (array[
    'supplier','customer','admin','company','mr','delivery','worker','partner']));

-- ── 2. the orphan the proof function left behind ────────────────────────────
delete from public.login_identities
 where owner_type = 'partner'
   and owner_id in (select id::text from public.partner_users
                     where identity = 'c307-zone-proof');
delete from public.partner_users where identity = 'c307-zone-proof';

-- ── 3. backend copy: every reply carries words ──────────────────────────────
insert into public.app_settings(key, value)
values ('partner_admin_copy', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings
   set value = value || jsonb_build_object(
         'err_not_authorized',  coalesce(value->>'err_not_authorized',
                                  'Only a mediBO admin can change partner logins.'),
         'err_partner_not_found', coalesce(value->>'err_partner_not_found',
                                  'That partner record no longer exists.'),
         'err_bad_identity',    coalesce(value->>'err_bad_identity',
                                  'Enter a 10-digit phone number or an email address.'),
         'err_identity_taken',  coalesce(value->>'err_identity_taken',
                                  'Already attached to a {type} account.'),
         'err_user_not_found',  coalesce(value->>'err_user_not_found',
                                  'That login is already gone.'),
         'err_failed',          coalesce(value->>'err_failed',
                                  'Could not save that login: {detail}'),
         'failed_message',      coalesce(value->>'failed_message',
                                  'Could not reach the server. Nothing was changed.'))
 where key = 'partner_admin_copy';

-- ── 4. login_owner_state — a partner identity gets its name and its gate ────
create or replace function public.login_owner_state(p_identity text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare r record; ok boolean := true; msg text := ''; nm text := '';
begin
  select owner_type, owner_id into r from login_identities where identity = p_identity;
  if not found then
    return jsonb_build_object('found',false,'ok',false,'message','No account found for this number');
  end if;

  if r.owner_type = 'supplier' then
    select sp.supplier_name,
           (sp.approved is true and coalesce(sp.status,'active') <> 'suspended')
      into nm, ok
      from supplier_profiles sp where sp.id::text = r.owner_id;
    if not ok then msg := 'This supplier account is not active yet'; end if;
  elsif r.owner_type = 'customer' then
    select pp.pharmacy_name,
           (pp.approved is true and coalesce(pp.status,'approved') <> 'suspended')
      into nm, ok
      from pharmacy_profiles pp where pp.id::text = r.owner_id;
    if not ok then msg := 'This account is waiting for approval'; end if;
  elsif r.owner_type = 'worker' then
    select lw.name, coalesce(lw.active,false) into nm, ok
      from lead_workers lw where lw.id::text = r.owner_id;
    if not ok then msg := 'This worker account is inactive'; end if;
  elsif r.owner_type = 'partner' then
    -- CHANGE #321: a partner login is live only while BOTH the staff row and
    -- the region_partners row are active — the same pair partner_home() reads.
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

-- ── 5. identity_owner_lookup — name a partner owner like every other type ───
create or replace function public.identity_owner_lookup(p_identity text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare k text; r record;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed',false);
  end if;
  k := identity_norm(p_identity);
  if k is null then return jsonb_build_object('allowed',true,'found',false); end if;

  select li.owner_type, li.owner_id, li.kind into r
  from login_identities li where li.identity = k limit 1;
  if r.owner_type is null then
    return jsonb_build_object('allowed',true,'found',false,
      'message','That number or email is free to use.');
  end if;

  return jsonb_build_object('allowed',true,'found',true,
    'owner_type', r.owner_type, 'owner_id', r.owner_id, 'kind', r.kind,
    'owner_name', case r.owner_type
        when 'supplier' then (select supplier_name from supplier_profiles where id::text = r.owner_id)
        when 'customer' then (select pharmacy_name from pharmacy_profiles where id::text = r.owner_id)
        when 'delivery' then (select full_name from delivery_partner_registrations where id::text = r.owner_id)
        when 'admin'    then (select email from admins where id::text = r.owner_id)
        when 'partner'  then (select rp.partner_name from partner_users pu
                               join region_partners rp on rp.id = pu.partner_id
                              where pu.id::text = r.owner_id)
        else null end,
    'type_label', initcap(r.owner_type),
    'message','Already attached to a ' || r.owner_type || ' account.');
end $function$;

-- ── 6. admin_partner_user_add — never silent again ──────────────────────────
create or replace function public.admin_partner_user_add(
  p_partner_id bigint, p_identity text, p_name text default null::text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  k text; own record; v_id bigint;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', coalesce(v_copy->>'err_not_authorized',''));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok',false,'error','partner_not_found','tone','danger',
      'message', coalesce(v_copy->>'err_partner_not_found',''));
  end if;
  k := identity_norm(p_identity);
  if k is null then
    return jsonb_build_object('ok',false,'error','bad_identity','tone','danger',
      'message', coalesce(v_copy->>'err_bad_identity',''));
  end if;

  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null and own.owner_type <> 'partner' then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', replace(coalesce(v_copy->>'err_identity_taken',''), '{type}', own.owner_type));
  end if;

  insert into partner_users(partner_id, identity, display_name, created_by)
  values (p_partner_id, k, nullif(btrim(coalesce(p_name,'')),''), public.my_login_email())
  on conflict (identity) do update
    set partner_id = excluded.partner_id, is_active = true,
        display_name = coalesce(excluded.display_name, partner_users.display_name),
        updated_at = now()
  returning id into v_id;

  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end, 'partner', v_id::text)
  on conflict (identity) do update set owner_type = 'partner', owner_id = v_id::text;

  insert into partner_audit_log(partner_id, partner_user_id, user_id, action, detail)
  values (p_partner_id, v_id, auth.uid(), 'login_added',
          jsonb_build_object('identity', k, 'by', public.my_login_email()));

  return jsonb_build_object('ok',true,'id',v_id,'identity',k,'tone','success',
    'message', coalesce(v_copy->>'added_message',''));
exception when others then
  -- The bug this change exists for: a backend failure must arrive as words on
  -- the admin's screen, not as a button that does nothing.
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(coalesce(v_copy->>'err_failed','{detail}'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ── 7. admin_partner_user_remove — same contract ────────────────────────────
create or replace function public.admin_partner_user_remove(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  pu record;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', coalesce(v_copy->>'err_not_authorized',''));
  end if;
  select * into pu from partner_users where id = p_id;
  if pu.id is null then
    return jsonb_build_object('ok',false,'error','not_found','tone','danger',
      'message', coalesce(v_copy->>'err_user_not_found',''));
  end if;

  update partner_users set is_active = false, auth_user_id = null, updated_at = now()
   where id = p_id;
  delete from login_identities
   where owner_type = 'partner' and owner_id = p_id::text;

  insert into partner_audit_log(partner_id, partner_user_id, user_id, action, detail)
  values (pu.partner_id, pu.id, auth.uid(), 'login_removed',
          jsonb_build_object('identity', pu.identity, 'by', public.my_login_email()));

  return jsonb_build_object('ok',true,'tone','success',
    'message', coalesce(v_copy->>'removed_message',''));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(coalesce(v_copy->>'err_failed','{detail}'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ── 8. the console payload carries the transport-failure copy ───────────────
create or replace function public.admin_partner_console(p_partner_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  rp record; v_feats jsonb; v_users jsonb; v_audit jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', coalesce(v_copy->>'err_not_authorized',''));
  end if;
  select * into rp from region_partners where id = p_partner_id;
  if rp.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message', coalesce(v_copy->>'err_partner_not_found',''));
  end if;

  select jsonb_agg(jsonb_build_object(
           'feature_key', fr.feature_key,
           'label', fr.label,
           'group_label', fr.group_label,
           'access', coalesce(pp.access,'none'),
           'options', jsonb_build_array(
             jsonb_build_object('value','none', 'label','No access',
                                'selected', coalesce(pp.access,'none')='none'),
             jsonb_build_object('value','read', 'label','View only',
                                'selected', coalesce(pp.access,'none')='read'),
             jsonb_build_object('value','write','label','Full access',
                                'selected', coalesce(pp.access,'none')='write')))
         order by fr.sort_order)
    into v_feats
  from feature_registry fr
  left join partner_permissions pp
         on pp.feature_key = fr.feature_key and pp.partner_id = p_partner_id
  where fr.is_active and fr.owner = 'partner' and fr.partner_eligible;

  select jsonb_agg(jsonb_build_object(
           'id', pu.id, 'identity', pu.identity,
           'display_name', coalesce(pu.display_name,''),
           'is_active', pu.is_active,
           'linked', (pu.auth_user_id is not null),
           'status_label', case when pu.auth_user_id is not null then 'Signed in'
                                else 'Waiting for first login' end,
           'added_label', to_char(pu.created_at at time zone 'Asia/Kolkata','dd Mon yyyy'))
         order by pu.id)
    into v_users
  from partner_users pu where pu.partner_id = p_partner_id and pu.is_active;

  select jsonb_agg(jsonb_build_object(
           'id', al.id, 'feature_key', coalesce(al.feature_key,''),
           'action', al.action,
           'user_id', coalesce(al.user_id::text,''),
           'zone_id', al.zone_id,
           'at_label', to_char(al.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'))
         order by al.created_at desc)
    into v_audit
  from (select * from partner_audit_log where partner_id = p_partner_id
         order by created_at desc limit 25) al;

  return jsonb_build_object(
    'ok', true,
    'partner_id', rp.id,
    'partner_name', coalesce(rp.partner_name,''),
    'district', coalesce(rp.district,''),
    'zone_id', rp.zone_id,
    'zone_label', coalesce((select name from zones where id = rp.zone_id),''),
    'zone_locked_label', coalesce(v_copy->>'zone_locked_label',''),
    'users_title', coalesce(v_copy->>'users_title',''),
    'users_subtitle', coalesce(v_copy->>'users_subtitle',''),
    'add_label', coalesce(v_copy->>'add_label',''),
    'add_hint', coalesce(v_copy->>'add_hint',''),
    'name_hint', coalesce(v_copy->>'name_hint',''),
    'remove_label', coalesce(v_copy->>'remove_label',''),
    'empty_users', coalesce(v_copy->>'empty_users',''),
    'perm_title', coalesce(v_copy->>'perm_title',''),
    'perm_subtitle', coalesce(v_copy->>'perm_subtitle',''),
    'audit_title', coalesce(v_copy->>'audit_title',''),
    'empty_audit', coalesce(v_copy->>'empty_audit',''),
    -- CHANGE #321: what the screen says when the RPC itself never answers.
    'failed_message', coalesce(v_copy->>'failed_message',''),
    'users', coalesce(v_users,'[]'::jsonb),
    'features', coalesce(v_feats,'[]'::jsonb),
    'audit', coalesce(v_audit,'[]'::jsonb));
end $function$;

-- ── 9. the WhatsApp login alert knows a partner ─────────────────────────────
create or replace function public._wa_login_alert()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_email text; v_uphone text; v_ph text; v_name text; v_key text; v_cust uuid;
begin
  select lower(btrim(u.email)), u.phone into v_email, v_uphone from auth.users u where u.id = new.user_id;

  select p.id, wa_normalize_phone(coalesce(p.whatsapp_no, p.phone)),
         coalesce(nullif(btrim(p.customer_name),''), nullif(btrim(p.owner_name),''), p.pharmacy_name)
    into v_cust, v_ph, v_name
  from pharmacy_profiles p
  where p.approved and coalesce(p.is_deleted,false) = false
    and (lower(p.email) = v_email
      or right(wa_normalize_phone(coalesce(p.whatsapp_no,p.phone)),10) = right(coalesce(v_uphone,''),10))
  limit 1;
  if v_ph is not null then v_key := 'login_alert'; end if;

  if v_ph is null then
    select wa_normalize_phone(coalesce(s.whatsapp_no, s.contact_no, s.phone)),
           coalesce(nullif(btrim(s.contact_name),''), s.supplier_name)
      into v_ph, v_name
    from supplier_profiles s
    where s.approved and coalesce(s.is_deleted,false) = false
      and (lower(s.email) = v_email
        or right(wa_normalize_phone(coalesce(s.whatsapp_no,s.contact_no,s.phone)),10) = right(coalesce(v_uphone,''),10))
    limit 1;
    if v_ph is not null then v_key := 'supplier_login_alert'; end if;
  end if;

  if v_ph is null then
    select wa_normalize_phone(d.phone), d.full_name into v_ph, v_name
    from delivery_partner_registrations d
    where right(wa_normalize_phone(d.phone),10) = right(coalesce(v_uphone,''),10) limit 1;
    if v_ph is not null then v_key := 'delivery_login_alert'; end if;
  end if;

  if v_ph is null then
    select wa_normalize_phone(m.phone), m.full_name into v_ph, v_name
    from mr_registrations m
    where right(wa_normalize_phone(m.phone),10) = right(coalesce(v_uphone,''),10) limit 1;
    if v_ph is not null then v_key := 'mr_login_alert'; end if;
  end if;

  -- last resort: the identity table that binds a login to an owner
  if v_ph is null then
    declare li record; v_owner_ph text;
    begin
      select * into li from login_identities
       where lower(identity) = v_email
          or right(regexp_replace(identity,'[^0-9]','','g'),10) = right(coalesce(v_uphone,''),10)
       order by created_at desc limit 1;

      if li.owner_type = 'customer' then
        select p.id, wa_normalize_phone(coalesce(p.whatsapp_no,p.phone)),
               coalesce(nullif(btrim(p.customer_name),''), p.pharmacy_name)
          into v_cust, v_ph, v_name from pharmacy_profiles p where p.id = li.owner_id;
        v_key := 'login_alert';
      elsif li.owner_type = 'supplier' then
        select wa_normalize_phone(coalesce(s.whatsapp_no,s.contact_no,s.phone)),
               coalesce(nullif(btrim(s.contact_name),''), s.supplier_name)
          into v_ph, v_name from supplier_profiles s where s.id = li.owner_id;
        v_key := 'supplier_login_alert';

      -- CHANGE #295: admin / company / mr / delivery / worker were dead routes.
      -- CHANGE #321: 'partner' joins them — #307 created partner staff logins
      -- but left them out of this list, so a partner sign-in alerted nobody.
      elsif li.owner_type in ('admin','company','mr','delivery','worker','partner') then
        select wa_normalize_phone(l2.identity) into v_owner_ph
          from login_identities l2
         where l2.owner_type = li.owner_type and l2.owner_id = li.owner_id
           and l2.kind = 'phone'
         order by l2.created_at desc limit 1;
        if v_owner_ph is null and li.owner_type = 'admin' then
          v_owner_ph := wa_normalize_phone(
            nullif(btrim((select value #>> '{}' from app_settings where key='admin_wa_phone')),''));
        end if;
        if v_owner_ph is not null then
          v_ph   := v_owner_ph;
          v_name := case when li.owner_type = 'partner'
                         then coalesce(nullif(btrim((select rp.partner_name
                                 from partner_users pu
                                 join region_partners rp on rp.id = pu.partner_id
                                where pu.id::text = li.owner_id)),''), 'there')
                         else coalesce(nullif(btrim(split_part(coalesce(v_email,''),'@',1)),''), 'there') end;
          v_key  := case when li.owner_type = 'admin' then 'admin_login_alert'
                         else li.owner_type || '_login_alert' end;
        end if;
      end if;
    exception when others then null;
    end;
  end if;

  if v_ph is null or v_key is null then return new; end if;

  if exists (select 1 from wa_campaign_recipients r
              where r.phone = v_ph and r.is_event
                and r.created_at > now() - interval '2 minutes'
                and r.campaign_id in (select campaign_id from wa_event_routes
                                       where event_key like '%login_alert%' and campaign_id is not null))
  then return new; end if;

  perform public.wa_send_event_now(v_key, v_cust,
            jsonb_build_object('customer_name', coalesce(nullif(btrim(v_name),''), 'there')), v_ph, null);
  return new;
exception when others then
  return new;
end $function$;

-- ── 10. the proof: add → verify → remove, on partner 1, in one call ─────────
create or replace function public.c321_partner_login_proof()
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_ident text := 'c321-proof@medibo.in';
  v_add jsonb; v_rm jsonb; v_id bigint; v_checks jsonb := '[]'::jsonb;
  v_state jsonb; v_pass int := 0; v_fail int := 0;
  v_uid uuid; v_old text;
begin
  -- start clean, so a re-run is a no-op rather than an error
  delete from login_identities where identity = v_ident;
  delete from partner_users where identity = v_ident;

  -- the RPCs under test are admin-gated, so the proof runs AS a super admin
  select u.id into v_uid
  from admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
  where a.is_super order by u.created_at limit 1;
  if v_uid is null then
    return jsonb_build_object('ok',false,'error','no_super_admin_user');
  end if;
  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);

  v_add := public.admin_partner_user_add(1, v_ident, 'c321 proof');
  v_id  := (v_add->>'id')::bigint;

  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','add.ok','expected','true','got',coalesce(v_add->>'ok','null')),
    jsonb_build_object('check','partner_users row','expected','1','got',
      (select count(*)::text from partner_users
        where id = v_id and partner_id = 1 and is_active)),
    jsonb_build_object('check','login_identities row','expected','1','got',
      (select count(*)::text from login_identities
        where identity = v_ident and owner_type = 'partner' and owner_id = v_id::text)),
    jsonb_build_object('check','identity kind','expected','email','got',
      coalesce((select kind from login_identities where identity = v_ident),'null')),
    jsonb_build_object('check','partner_audit_log login_added','expected','1','got',
      (select count(*)::text from partner_audit_log
        where partner_user_id = v_id and action = 'login_added')));

  v_state := public.login_owner_state(v_ident);
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','login_owner_state.found','expected','true','got',coalesce(v_state->>'found','null')),
    jsonb_build_object('check','login_owner_state.ok','expected','true','got',coalesce(v_state->>'ok','null')),
    jsonb_build_object('check','login_owner_state.owner_type','expected','partner','got',coalesce(v_state->>'owner_type','null')),
    jsonb_build_object('check','login_owner_state.display_name','expected','Jai Mahakal Medical And Surgical',
      'got',coalesce(v_state->>'display_name','null')),
    jsonb_build_object('check','add reply carries words','expected','true',
      'got',(coalesce(v_add->>'message','') <> '')::text),
    jsonb_build_object('check','identity_owner_lookup names the partner','expected','Jai Mahakal Medical And Surgical',
      'got',coalesce((select rp.partner_name from partner_users pu
                        join region_partners rp on rp.id = pu.partner_id
                       where pu.id = v_id),'null')));

  v_rm := public.admin_partner_user_remove(v_id);
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','remove.ok','expected','true','got',coalesce(v_rm->>'ok','null')),
    jsonb_build_object('check','identity gone after remove','expected','0','got',
      (select count(*)::text from login_identities where identity = v_ident)),
    jsonb_build_object('check','partner_audit_log login_removed','expected','1','got',
      (select count(*)::text from partner_audit_log
        where partner_user_id = v_id and action = 'login_removed')));

  perform set_config('request.jwt.claims', coalesce(v_old,''), true);

  -- leave nothing behind
  delete from partner_audit_log where partner_user_id = v_id;
  delete from partner_users where id = v_id;

  select count(*) filter (where c->>'expected' = c->>'got'),
         count(*) filter (where c->>'expected' <> c->>'got')
    into v_pass, v_fail
  from jsonb_array_elements(v_checks) c;

  return jsonb_build_object('ok',(v_fail = 0),'passed',v_pass,'failed',v_fail,
                            'add',v_add,'remove',v_rm,'checks',v_checks);
end $function$;

revoke all on function public.c321_partner_login_proof() from public, anon, authenticated;

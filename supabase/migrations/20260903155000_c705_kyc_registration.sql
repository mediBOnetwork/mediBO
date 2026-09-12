-- CHANGE #705 (6/6) — one registration door for every kind.
--
-- submit_registration already carried supplier / mr / company /
-- delivery_partner, each with the same allow-list and the same
-- forbidden-column guard (status, approved, user_id, id can never be set by the
-- applicant). Pharmacy was the one kind that did NOT go through it, so a
-- customer's "Complete Registration" wrote its own path and got none of the
-- review-and-reason feedback the other kinds share.
--
-- admin_review_registration likewise knew mr / company / delivery_partner but
-- neither pharmacy nor supplier. Both now go through the same door — and an
-- approval there still meets the KYC trigger from (3/5), so a pharmacy with no
-- verified drug licence is refused with the backend's own sentence instead of
-- being quietly approved.
--
-- Both functions are reproduced verbatim from the live definitions with the
-- branches added, so a resumed worker re-applies exactly this.
-- Idempotent throughout.

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

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind,
    'id', coalesce(v_id,''),
    'status', 'pending',
    'rejected_keys', to_jsonb(v_rejected),
    'had_rejected', (array_length(v_rejected,1) is not null));
end $function$;

CREATE OR REPLACE FUNCTION public.admin_review_registration(p_kind text, p_id uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := coalesce(public.get_my_role(), 'none');
  v_uid uuid := auth.uid(); v_table text; v_found int; v_reason text;
  v_has_reason boolean; d delivery_partner_registrations%rowtype;
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'forbidden' using hint = 'Only an admin may review a registration.';
  end if;
  -- CHANGE #705 — pharmacy and supplier review through the SAME door as every
  -- other kind, so the reason an applicant is given is written once.
  v_table := case p_kind
               when 'mr' then 'mr_registrations'
               when 'company' then 'company_profiles'
               when 'delivery_partner' then 'delivery_partner_registrations'
               when 'pharmacy' then 'pharmacy_profiles'
               when 'supplier' then 'supplier_profiles'
               else null end;
  if v_table is null then raise exception 'unknown_registration_kind: %', p_kind; end if;
  v_reason := nullif(btrim(coalesce(p_reason,'')),'');

  select exists(select 1 from information_schema.columns
                 where table_schema='public' and table_name=v_table and column_name='review_reason')
    into v_has_reason;

  if p_kind in ('pharmacy','supplier') then
    -- These two carry approved/approved_at/approved_by, not reviewed_*. The KYC
    -- trigger (CHANGE #705) still has the last word on an approval, so a
    -- pharmacy with no verified drug licence is refused here with the backend's
    -- own sentence rather than quietly approved.
    execute format(
      'update %I set status = %L, approved = %L, approved_at = case when %L then now() else approved_at end,'
      || ' approved_by = %L where id = %L',
      v_table, p_status, (lower(p_status) = 'approved'), (lower(p_status) = 'approved'),
      coalesce(nullif(public.my_login_email(),''), v_uid::text, 'unknown'), p_id);
  elsif v_has_reason then
    execute format(
      'update %I set status = %L, reviewed_by = %L::uuid, reviewed_at = now(), review_reason = %L where id = %L',
      v_table, p_status, v_uid, v_reason, p_id);
  else
    execute format(
      'update %I set status = %L, reviewed_by = %L::uuid, reviewed_at = now() where id = %L',
      v_table, p_status, v_uid, p_id);
  end if;
  get diagnostics v_found = row_count;
  if v_found = 0 then raise exception 'registration_not_found: %/%', p_kind, p_id; end if;

  -- tell the applicant what happened to their application
  if p_kind = 'delivery_partner' then
    select * into d from delivery_partner_registrations where id = p_id;
    perform public._delivery_inbox(
      d.user_id, coalesce(d.email, d.phone), 'delivery_partner_' || lower(coalesce(p_status,'reviewed')),
      case lower(coalesce(p_status,''))
        when 'approved' then public.uic('delivery.reg_approved_title','Your rider application is approved')
        when 'rejected' then public.uic('delivery.reg_rejected_title','Your rider application was not accepted')
        else public.uic('delivery.reg_reviewed_title','Your rider application was reviewed') end,
      coalesce(v_reason,
        case lower(coalesce(p_status,''))
          when 'approved' then public.uic('delivery.reg_approved_body','You can start taking deliveries once an admin activates you.')
          when 'rejected' then public.uic('delivery.reg_rejected_body','No reason was recorded.')
          else '' end),
      '/delivery-register');
  end if;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'id', p_id::text,
    'status', p_status,
    'reason', coalesce(v_reason,''),
    'reviewed_by', coalesce(v_uid::text,''),
    'reviewed_by_email', coalesce(public.my_login_email(),''),
    'message', case lower(coalesce(p_status,''))
                 when 'approved' then public.uic('delivery.reg_approve_toast','Registration approved')
                 when 'rejected' then public.uic('delivery.reg_reject_toast','Registration rejected')
                 else public.uic('delivery.reg_reviewed_toast','Registration updated') end);
end $function$;

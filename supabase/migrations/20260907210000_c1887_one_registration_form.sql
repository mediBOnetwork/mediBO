-- CHANGE #1887 — ONE registration form for self-signup, Import customer and
-- Convert lead, and admin_import_customer provisions the auth user itself.
--
-- Before this change:
--   • self-signup (business_details_screen) and Import customer collected
--     DIFFERENT fields, in a different order, with labels written in Dart;
--   • admin_import_customer() refused without a user_id, so adding a shop
--     meant calling the customer-import edge function first — never one tap;
--   • the Import path auto-approved, which the #1886 KYC approval guard
--     blocks for a shop that has no verified licence yet.
--
-- After it:
--   • customer_form_schema(context) is the ONE field list — order, labels,
--     required flags, defaults, dropdown options — and it is DATA
--     (customer_form_section / customer_form_field), so wording or order is
--     an UPDATE, never a deploy;
--   • admin_import_customer() creates the auth user itself when user_id is
--     absent, keys the login to the WhatsApp number
--     (login_identities kind='whatsapp'), sets no password, and leaves the
--     shop for the #1886 registration pipeline to approve;
--   • every save path lands on the stage the data supports, via the
--     #1886 trg_c1886_stage_sync trigger.
--
-- Idempotent: safe to replay on live.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. login_identities may now carry a WhatsApp identity
-- ─────────────────────────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_constraint
              where conrelid = 'public.login_identities'::regclass
                and conname  = 'login_identities_kind_check') then
    alter table public.login_identities drop constraint login_identities_kind_check;
  end if;
  alter table public.login_identities
    add constraint login_identities_kind_check
    check (kind = any (array['email'::text, 'phone'::text, 'whatsapp'::text]));
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. The form is DATA
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.customer_form_section (
  key         text primary key,
  title       text not null,
  sort_order  int  not null default 100,
  is_active   boolean not null default true
);

create table if not exists public.customer_form_field (
  key           text primary key,
  section_key   text not null references public.customer_form_section(key) on update cascade,
  label         text not null,
  hint          text,
  field_type    text not null default 'text',   -- text | textarea | select | number | email | phone
  options_key   text,                           -- key into customer_form_options()
  required      boolean not null default false,
  sort_order    int     not null default 100,
  half_width    boolean not null default false,
  max_lines     int     not null default 1,
  contexts      text[]  not null default array['admin','signup'],
  default_value text,
  is_active     boolean not null default true
);

alter table public.customer_form_section enable row level security;
alter table public.customer_form_field   enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='customer_form_section'
                    and policyname='customer_form_section_read') then
    create policy customer_form_section_read on public.customer_form_section
      for select using (true);
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='customer_form_field'
                    and policyname='customer_form_field_read') then
    create policy customer_form_field_read on public.customer_form_field
      for select using (true);
  end if;
end $$;

grant select on public.customer_form_section, public.customer_form_field to anon, authenticated;

insert into public.customer_form_section (key, title, sort_order) values
  ('business',  'BUSINESS',   10),
  ('contact',   'CONTACT',    20),
  ('address',   'ADDRESS',    30),
  ('statutory', 'STATUTORY',  40)
on conflict (key) do update
  set title = excluded.title, sort_order = excluded.sort_order;

-- One list. Order, label, required flag and default all live here.
insert into public.customer_form_field
  (key, section_key, label, field_type, options_key, required, sort_order,
   half_width, max_lines, contexts, hint) values
  ('pharmacy_name',       'business',  'Pharmacy name',        'text',     null,           true,   10, false, 1, array['admin','signup'], 'Name on the board'),
  ('customer_name',       'business',  'Owner name',           'text',     null,           false,  20, false, 1, array['admin','signup'], null),
  ('store_type',          'business',  'Store type',           'select',   'store_type',   false,  30, false, 1, array['admin','signup'], null),
  ('whatsapp_no',         'contact',   'WhatsApp number',      'phone',    null,           true,   40, true,  1, array['admin','signup'], '10 digits — this is the login'),
  ('phone',               'contact',   'Phone',                'phone',    null,           false,  50, true,  1, array['admin','signup'], null),
  ('other_contact_no',    'contact',   'Other contact',        'phone',    null,           false,  60, true,  1, array['admin','signup'], null),
  ('email',               'contact',   'Email',                'email',    null,           false,  70, true,  1, array['admin','signup'], null),
  ('address',             'address',   'Address',              'textarea', null,           true,   80, false, 2, array['admin','signup'], null),
  ('city',                'address',   'City',                 'text',     null,           false,  90, true,  1, array['admin','signup'], null),
  ('district',            'address',   'District',             'text',     null,           false, 100, true,  1, array['admin'],          null),
  ('state',               'address',   'State',                'text',     null,           false, 110, true,  1, array['admin','signup'], null),
  ('pincode',             'address',   'Pincode',              'number',   null,           false, 120, true,  1, array['admin','signup'], '6 digits'),
  ('latitude',            'address',   'Latitude',             'text',     null,           false, 130, true,  1, array['admin'],          null),
  ('longitude',           'address',   'Longitude',            'text',     null,           false, 140, true,  1, array['admin'],          null),
  ('store_location_link', 'address',   'Store location link',  'text',     null,           false, 150, false, 1, array['admin','signup'], null),
  ('range_zone',          'address',   'Delivery range',       'select',   'range_zone',   false, 160, false, 1, array['admin','signup'], null),
  ('payment_term',        'address',   'Payment term',         'select',   'payment_term', false, 170, false, 1, array['admin','signup'], null),
  ('gstin',               'statutory', 'GSTIN',                'text',     null,           false, 180, false, 1, array['admin','signup'], null),
  ('dl_20b',              'statutory', 'Drug licence 20B',     'text',     null,           false, 190, true,  1, array['admin','signup'], null),
  ('dl_21b',              'statutory', 'Drug licence 21B',     'text',     null,           false, 200, true,  1, array['admin','signup'], null),
  ('dl_expiry',           'statutory', 'Licence valid till',   'date',     null,           false, 210, true,  1, array['admin','signup'], 'YYYY-MM-DD')
on conflict (key) do update
  set section_key = excluded.section_key,
      label       = excluded.label,
      field_type  = excluded.field_type,
      options_key = excluded.options_key,
      required    = excluded.required,
      sort_order  = excluded.sort_order,
      half_width  = excluded.half_width,
      max_lines   = excluded.max_lines,
      contexts    = excluded.contexts,
      hint        = excluded.hint,
      is_active   = true;

-- Copy the form itself renders. Wording is an UPDATE here, never a deploy.
insert into public.ui_copy (key, value) values
  ('customer_form.title_admin',        '"Add customer"'::jsonb),
  ('customer_form.title_signup',       '"Your pharmacy details"'::jsonb),
  ('customer_form.title_lead_convert', '"Convert lead to customer"'::jsonb),
  ('customer_form.subtitle',           '"Everything is editable. Only the starred fields are needed to save."'::jsonb),
  ('customer_form.btn_save',           '"Save customer"'::jsonb),
  ('customer_form.btn_cancel',         '"Cancel"'::jsonb),
  ('customer_form.required_suffix',    '" *"'::jsonb),
  ('customer_form.loading',            '"Loading the form…"'::jsonb),
  ('customer_form.flag_check_this',    '"check this"'::jsonb),
  ('customer_form.missing_required',   '"Fill in the starred fields first."'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. customer_form_schema() — the ONE field list every surface renders
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.customer_form_schema(p_context text default 'admin')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ctx  text := case lower(btrim(coalesce(p_context,'admin')))
                   when 'signup'       then 'signup'
                   when 'lead_convert' then 'admin'
                   else 'admin' end;
  v_raw  text := lower(btrim(coalesce(p_context,'admin')));
  v_opts jsonb := public.customer_form_options();
  v_fields jsonb;
  v_sections jsonb;
begin
  select coalesce(jsonb_agg(f order by (f->>'sort_order')::int), '[]'::jsonb)
    into v_fields
  from (
    select jsonb_build_object(
             'key',         cf.key,
             'section',     cf.section_key,
             'label',       cf.label,
             'hint',        cf.hint,
             'type',        cf.field_type,
             'required',    cf.required,
             'sort_order',  cf.sort_order,
             'half_width',  cf.half_width,
             'max_lines',   cf.max_lines,
             'default',     cf.default_value,
             'options',     case when cf.options_key is null then '[]'::jsonb
                                 else coalesce(v_opts->cf.options_key, '[]'::jsonb) end
           ) as f
    from public.customer_form_field cf
    where cf.is_active and v_ctx = any (cf.contexts)
  ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', cs.key, 'title', cs.title,
           'fields', coalesce((
             select jsonb_agg(x order by (x->>'sort_order')::int)
             from jsonb_array_elements(v_fields) x
             where x->>'section' = cs.key), '[]'::jsonb))
         order by cs.sort_order), '[]'::jsonb)
    into v_sections
  from public.customer_form_section cs
  where cs.is_active
    and exists (select 1 from jsonb_array_elements(v_fields) x where x->>'section' = cs.key);

  return jsonb_build_object(
    'ok', true,
    'context', v_raw,
    'title', case v_raw
               when 'signup'       then public._c('customer_form.title_signup')
               when 'lead_convert' then public._c('customer_form.title_lead_convert')
               else public._c('customer_form.title_admin') end,
    'subtitle',        public._c('customer_form.subtitle'),
    'required_suffix', public._c('customer_form.required_suffix'),
    'loading_label',   public._c('customer_form.loading'),
    'flag_label',      public._c('customer_form.flag_check_this'),
    'missing_required_message', public._c('customer_form.missing_required'),
    'save_label',      public._c('customer_form.btn_save'),
    'cancel_label',    public._c('customer_form.btn_cancel'),
    'sections',        v_sections,
    'fields',          v_fields,
    'required_fields', coalesce((select jsonb_agg(x->>'key')
                                   from jsonb_array_elements(v_fields) x
                                  where (x->>'required')::boolean), '[]'::jsonb)
  );
end $function$;

grant execute on function public.customer_form_schema(text) to anon, authenticated, service_role;

-- customer_form_options() keeps its old shape for anything still reading it,
-- but its required_fields now agree with the one field list above.
create or replace function public.customer_form_options()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_core int; v_ext int; v_marg int;
begin
  select coalesce(core_km,25), coalesce(ext_km,60), coalesce(marg_km,120)
    into v_core, v_ext, v_marg
  from lead_hub order by updated_at desc nulls last limit 1;
  v_core := coalesce(v_core,25); v_ext := coalesce(v_ext,60); v_marg := coalesce(v_marg,120);

  return jsonb_build_object(
    'store_type', jsonb_build_array(
      'Retail Pharmacy','Hospital Pharmacy','Clinic','Medical Store','Wholesaler','Nursing Home','Other'),
    'payment_term', jsonb_build_array(
      'Advance Payment','Cash on Delivery','Credit 7 days','Credit 15 days','Credit 30 days'),
    'range_zone', jsonb_build_array(
      'Local (0–' || v_core || ' km)',
      'Extended (' || v_core || '–' || v_ext || ' km)',
      'Outer (' || v_ext || '–' || v_marg || ' km)',
      'Outstation (' || v_marg || '+ km)'),
    'single_select', coalesce((select jsonb_agg(key order by sort_order)
                                 from customer_form_field
                                where is_active and field_type = 'select'), '[]'::jsonb),
    'hidden_fields', jsonb_build_array('customer_code','address_local'),
    'required_fields', coalesce((select jsonb_agg(key order by sort_order)
                                   from customer_form_field
                                  where is_active and required), '[]'::jsonb));
end $function$;

grant execute on function public.customer_form_options() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Provision the login here, not in an edge function
-- ─────────────────────────────────────────────────────────────────────────
-- Creates (or reuses) the auth user whose identity is a WhatsApp number.
-- No password is ever set: the shop signs in with the WhatsApp OTP lane
-- (login_request_otp -> login_verify_otp -> login-otp mode=session).
create or replace function public.auth_user_for_whatsapp(p_phone text, p_meta jsonb default '{}'::jsonb)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_p10  text := public._phone10(coalesce(p_phone,''));
  v_e164 text;
  v_uid  uuid;
begin
  if v_p10 is null or length(v_p10) <> 10 then
    raise exception 'a valid 10-digit WhatsApp number is required';
  end if;
  v_e164 := '91' || v_p10;

  select u.id into v_uid from auth.users u
   where right(regexp_replace(coalesce(u.phone,''), '\D', '', 'g'), 10) = v_p10
   order by u.created_at limit 1;
  if v_uid is not null then return v_uid; end if;

  v_uid := gen_random_uuid();
  insert into auth.users (
    id, instance_id, aud, role,
    phone, phone_confirmed_at,
    encrypted_password,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  values (
    v_uid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated',
    v_e164, now(),
    null,
    jsonb_build_object('provider','whatsapp','providers', jsonb_build_array('whatsapp')),
    coalesce(p_meta,'{}'::jsonb) || jsonb_build_object('phone', v_e164, 'created_by','admin_import_customer'),
    now(), now(),
    '', '', '', '');

  return v_uid;
end $function$;

revoke all on function public.auth_user_for_whatsapp(text, jsonb) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. admin_import_customer — one tap, no edge function
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.admin_import_customer(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_id    uuid;
  v_uid   uuid := nullif(btrim(p->>'user_id'), '')::uuid;
  v_made_login boolean := false;
  v_name  text := nullif(btrim(p->>'pharmacy_name'), '');
  v_owner text := nullif(btrim(p->>'customer_name'), '');
  v_phone text := nullif(public._phone10(coalesce(p->>'phone','')), '');
  v_wa    text := nullif(public._phone10(coalesce(p->>'whatsapp_no','')), '');
  v_other text := nullif(public._phone10(coalesce(p->>'other_contact_no','')), '');
  v_code  text := nullif(btrim(p->>'customer_code'), '');
  v_addr  text := nullif(btrim(p->>'address'), '');
  v_city  text := nullif(btrim(p->>'city'), '');
  v_pin   text := nullif(regexp_replace(coalesce(p->>'pincode',''), '\D', '', 'g'), '');
  v_lat   double precision := nullif(btrim(coalesce(p->>'latitude','')),'')::double precision;
  v_lng   double precision := nullif(btrim(coalesce(p->>'longitude','')),'')::double precision;
  v_zone  text := nullif(btrim(p->>'range_zone'), '');
  v_stage public.registration_stage;
  v_dupe  record;
  v_req   text[];
  k       text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'not_authorized'; END IF;

  -- Required set is the SAME data the one field list marks required, so the
  -- form and the write can never disagree.
  select coalesce(array_agg(key order by sort_order), '{}')
    into v_req
    from customer_form_field
   where is_active and required and 'admin' = any(contexts);

  foreach k in array v_req loop
    if nullif(btrim(coalesce(p->>k,'')),'') is null then
      raise exception '% is required',
        coalesce((select label from customer_form_field where key = k), k);
    end if;
  end loop;

  IF v_wa IS NULL OR length(v_wa) <> 10 THEN
    RAISE EXCEPTION 'a valid 10-digit WhatsApp number is required';
  END IF;
  IF v_pin IS NOT NULL AND length(v_pin) <> 6 THEN
    RAISE EXCEPTION 'pincode must be 6 digits, got %', v_pin;
  END IF;

  -- Duplicate-phone guard — unchanged, and it runs BEFORE any login is made.
  SELECT pharmacy_name, customer_code INTO v_dupe
    FROM pharmacy_profiles
   WHERE coalesce(is_deleted,false) = false
     AND public._phone10(coalesce(whatsapp_no, phone,'')) IN (coalesce(v_wa,'~'), coalesce(v_phone,'~'))
   LIMIT 1;
  IF v_dupe.pharmacy_name IS NOT NULL THEN
    RAISE EXCEPTION 'this number already belongs to % (%)', v_dupe.pharmacy_name, v_dupe.customer_code;
  END IF;

  -- CHANGE #1887: no user_id? make the login here. The WhatsApp number is the
  -- identity, there is no password, and the owner signs in by OTP later.
  IF v_uid IS NULL THEN
    v_uid := public.auth_user_for_whatsapp(v_wa, jsonb_build_object('pharmacy_name', v_name));
    v_made_login := true;
  ELSIF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid) THEN
    RAISE EXCEPTION 'user_id % does not exist in auth.users', v_uid;
  END IF;

  IF EXISTS (SELECT 1 FROM pharmacy_profiles pp
              WHERE pp.user_id = v_uid AND coalesce(pp.is_deleted,false) = false) THEN
    RAISE EXCEPTION 'this login already has a customer profile';
  END IF;

  IF v_code IS NULL THEN
    v_code := public.next_customer_code(v_name);
  ELSIF public.is_customer_code_taken(v_code) THEN
    RAISE EXCEPTION 'customer_code % already taken', v_code;
  END IF;

  IF v_zone IS NULL AND v_lat IS NOT NULL AND v_lng IS NOT NULL THEN
    v_zone := public.range_zone_for(v_lat, v_lng)->>'range_zone';
  END IF;

  -- CHANGE #1887: the row is NOT auto-approved any more. #1886 made approval a
  -- KYC-gated step (_kyc_approval_guard blocks approving a shop with no
  -- verified licence), so importing with approved=true simply raised. The shop
  -- lands on the stage its data supports and the registration pipeline
  -- approves it.
  INSERT INTO pharmacy_profiles (
    user_id, pharmacy_name, customer_name, owner_name,
    phone, whatsapp_no, other_contact_no, email,
    address, address_local, city, district, state, pincode,
    latitude, longitude, store_location_link,
    store_type, range_zone, payment_term,
    gstin, gst_no, drug_license, dl_20b, dl_21b, dl_expiry,
    customer_code, approved, is_deleted
  ) VALUES (
    v_uid, v_name, v_owner, v_owner,
    coalesce(v_phone, v_wa), v_wa, v_other, nullif(btrim(p->>'email'),''),
    v_addr, v_addr, coalesce(v_city,''), nullif(btrim(p->>'district'),''), nullif(btrim(p->>'state'),''), coalesce(v_pin,''),
    v_lat, v_lng, nullif(btrim(p->>'store_location_link'),''),
    nullif(btrim(p->>'store_type'),''), v_zone, nullif(btrim(p->>'payment_term'),''),
    nullif(btrim(p->>'gstin'),''), nullif(btrim(p->>'gstin'),''),
    nullif(concat_ws(' / ', nullif(btrim(p->>'dl_20b'),''), nullif(btrim(p->>'dl_21b'),'')),''),
    nullif(btrim(p->>'dl_20b'),''), nullif(btrim(p->>'dl_21b'),''),
    nullif(btrim(coalesce(p->>'dl_expiry','')),'')::date,
    v_code, false, false
  )
  RETURNING id, registration_stage INTO v_id, v_stage;

  -- The WhatsApp number IS the login. _login_identities_sync has already
  -- written the row from the profile columns; name it for what it is.
  UPDATE login_identities
     SET kind = 'whatsapp'
   WHERE identity = public.identity_norm(v_wa)
     AND owner_type = 'customer' AND owner_id = v_id::text;

  RETURN jsonb_build_object(
    'status','ok', 'ok', true,
    'customer', (SELECT to_jsonb(pp) FROM pharmacy_profiles pp WHERE pp.id = v_id),
    'customer_id', v_id,
    'customer_code', v_code,
    'user_id', v_uid,
    'login_created', v_made_login,
    'range_zone', v_zone,
    'approved', false,
    'registration_stage', v_stage,
    'stage_label', coalesce(public.customer_stage_chip(v_stage)->>'label', v_stage::text),
    'message', public._c('customer_form.saved_message'));
END $function$;

insert into public.ui_copy (key, value) values
  ('customer_form.saved_message', '"Shop added. The owner can sign in on WhatsApp OTP with this number."'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. Self-signup writes the SAME field names
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.save_customer_profile(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id   uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_addr text := coalesce(nullif(btrim(coalesce(p->>'address','')),''),
                          nullif(btrim(coalesce(p->>'address_local','')),''));
  v_gst  text := coalesce(nullif(btrim(coalesce(p->>'gstin','')),''),
                          nullif(btrim(coalesce(p->>'gst_no','')),''));
  v_wa   text := nullif(btrim(coalesce(p->>'whatsapp_no','')),'');
  v_ph   text := coalesce(nullif(btrim(coalesce(p->>'phone','')),''), v_wa);
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  if v_id is null then
    insert into pharmacy_profiles (
      user_id, customer_name, owner_name, pharmacy_name, store_type, range_zone,
      address, address_local, city, district, state, pincode, store_location_link,
      phone, whatsapp_no, other_contact_no, email, dl_20b, dl_21b, dl_expiry, gst_no, gstin,
      payment_term, customer_code)
    values (
      v_uid,
      nullif(btrim(coalesce(p->>'customer_name','')),''),
      nullif(btrim(coalesce(p->>'customer_name','')),''),
      nullif(btrim(coalesce(p->>'pharmacy_name','')),''),
      nullif(btrim(coalesce(p->>'store_type','')),''),
      nullif(btrim(coalesce(p->>'range_zone','')),''),
      coalesce(v_addr,''), coalesce(v_addr,''),
      coalesce(nullif(btrim(coalesce(p->>'city','')),''),''),
      nullif(btrim(coalesce(p->>'district','')),''),
      nullif(btrim(coalesce(p->>'state','')),''),
      coalesce(nullif(regexp_replace(coalesce(p->>'pincode',''), '\D', '', 'g'),''),''),
      nullif(btrim(coalesce(p->>'store_location_link','')),''),
      v_ph, v_wa,
      nullif(btrim(coalesce(p->>'other_contact_no','')),''),
      nullif(btrim(coalesce(p->>'email','')),''),
      nullif(btrim(coalesce(p->>'dl_20b','')),''),
      nullif(btrim(coalesce(p->>'dl_21b','')),''),
      nullif(btrim(coalesce(p->>'dl_expiry','')),'')::date,
      v_gst, v_gst,
      nullif(btrim(coalesce(p->>'payment_term','')),''),
      nullif(btrim(coalesce(p->>'customer_code','')),''))
    returning id into v_id;
  else
    update pharmacy_profiles set
      customer_name       = coalesce(nullif(btrim(coalesce(p->>'customer_name','')),''), customer_name),
      owner_name          = coalesce(nullif(btrim(coalesce(p->>'customer_name','')),''), owner_name),
      pharmacy_name       = coalesce(nullif(btrim(coalesce(p->>'pharmacy_name','')),''), pharmacy_name),
      store_type          = coalesce(nullif(btrim(coalesce(p->>'store_type','')),''), store_type),
      range_zone          = coalesce(nullif(btrim(coalesce(p->>'range_zone','')),''), range_zone),
      address             = coalesce(v_addr, address),
      address_local       = coalesce(v_addr, address_local),
      city                = coalesce(nullif(btrim(coalesce(p->>'city','')),''), city),
      district            = coalesce(nullif(btrim(coalesce(p->>'district','')),''), district),
      state               = coalesce(nullif(btrim(coalesce(p->>'state','')),''), state),
      pincode             = coalesce(nullif(regexp_replace(coalesce(p->>'pincode',''), '\D','','g'),''), pincode),
      store_location_link = coalesce(nullif(btrim(coalesce(p->>'store_location_link','')),''), store_location_link),
      phone               = coalesce(v_ph, phone),
      whatsapp_no         = coalesce(v_wa, whatsapp_no),
      other_contact_no    = coalesce(nullif(btrim(coalesce(p->>'other_contact_no','')),''), other_contact_no),
      email               = coalesce(nullif(btrim(coalesce(p->>'email','')),''), email),
      dl_20b              = coalesce(nullif(btrim(coalesce(p->>'dl_20b','')),''), dl_20b),
      dl_21b              = coalesce(nullif(btrim(coalesce(p->>'dl_21b','')),''), dl_21b),
      dl_expiry           = coalesce(nullif(btrim(coalesce(p->>'dl_expiry','')),'')::date, dl_expiry),
      gst_no              = coalesce(v_gst, gst_no),
      gstin               = coalesce(v_gst, gstin),
      payment_term        = coalesce(nullif(btrim(coalesce(p->>'payment_term','')),''), payment_term),
      customer_code       = coalesce(nullif(btrim(coalesce(p->>'customer_code','')),''), customer_code)
    where id = v_id;
  end if;

  return public.my_session();
end $function$;

grant execute on function public.save_customer_profile(jsonb) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. A shop the admin just added can sign in on its WhatsApp number
-- ─────────────────────────────────────────────────────────────────────────
-- login_owner_state() refused every customer whose profile was not `approved`.
-- Since #1886 approval is a KYC-gated step, so a one-tap import is pending by
-- definition and the owner could never reach the profile the admin just made —
-- while the very same owner signing up in the app DOES get a session and sees
-- the pending state. This lines the OTP lane up with that: possession of the
-- WhatsApp number still has to be proved, a deleted or suspended shop is still
-- refused, and `approved` still gates ordering (my_session().can_place_order).
create or replace function public.login_owner_state(p_identity text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
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

-- ─────────────────────────────────────────────────────────────────────────
-- 8. Convert lead -> the same write, so every path lands on the same stage
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.lead_convert_to_customer(p_lead_id bigint, p_owner_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare L scraped_leads%rowtype; v jsonb; v_id uuid;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select * into L from scraped_leads where id = p_lead_id;
  if not found then return jsonb_build_object('error','lead_not_found'); end if;
  if L.matched_customer_id is not null then
    return jsonb_build_object('error','already_a_customer','customer_id',L.matched_customer_id);
  end if;

  -- CHANGE #1887: one write for every path. admin_import_customer() provisions
  -- the login, keeps the duplicate-phone guard and lands the stage.
  v := public.admin_import_customer(jsonb_build_object(
         'pharmacy_name',       L.name,
         'customer_name',       p_owner_name,
         'whatsapp_no',         coalesce(L.phone10, L.phone),
         'phone',               coalesce(L.phone10, L.phone),
         'email',               L.emails[1],
         'address',             coalesce(nullif(btrim(L.address),''), nullif(btrim(L.short_address),'')),
         'city',                coalesce(nullif(btrim(L.locality),''), nullif(btrim(L.city),'')),
         'district',            nullif(btrim(L.district),''),
         'state',               coalesce(nullif(btrim(L.state),''),'Chhattisgarh'),
         'pincode',             nullif(regexp_replace(coalesce(L.pincode,''), '\D','','g'),''),
         'latitude',            L.lat::text,
         'longitude',           L.lng::text,
         'store_location_link', coalesce(L.maps_uri,
                                  case when L.lat is not null
                                    then 'https://www.google.com/maps?q=' || L.lat || ',' || L.lng end)));

  v_id := (v->>'customer_id')::uuid;

  update scraped_leads
     set status='converted', matched_kind='customer', matched_customer_id=v_id,
         match_reason='converted from lead', lead_score=0
   where id = p_lead_id;

  return jsonb_build_object('ok',true,'customer_id',v_id,
                            'customer_code', v->>'customer_code',
                            'registration_stage', v->>'registration_stage',
                            'pharmacy_name', L.name,
                            'note', v->>'message');
end $function$;

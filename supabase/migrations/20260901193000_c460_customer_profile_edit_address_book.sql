-- ============================================================================
-- CHANGE #460 — feature_gaps 164: "A customer cannot edit their own profile or
-- keep a second delivery address."
--
-- Reproduced 2026-09-01:
--   * my_session().profile carries note "To update your details, contact
--     support." and lib/screens/profile_screen.dart renders every field through
--     _InfoRow — read-only, no edit affordance anywhere.
--   * save_customer_profile(jsonb) DOES update an existing row, but nothing in
--     the app calls it after registration (business_details_screen.dart is the
--     only caller and it is the sign-up form). A backend RPC with no reachable
--     frontend does not exist (§11).
--   * pharmacy_profiles holds exactly ONE address per account and there is no
--     table anywhere whose name contains "address". A chain with two branches
--     cannot ship to both.
--
-- What lands: an address book with a default ship-to that order placement
-- actually uses, and a profile editor whose EDITABILITY IS DATA — which field
-- a customer may change lives in a table, so opening one up later is an UPDATE
-- and not a deploy. Licence and identity fields stay locked with the backend's
-- own reason: a pharmacy silently editing its own drug-licence number on an
-- approved B2B account is not a feature.
-- ============================================================================

-- ── the address book ───────────────────────────────────────────────────────
create table if not exists public.customer_addresses (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  label         text not null default '',
  contact_name  text not null default '',
  contact_phone text not null default '',
  address       text not null default '',
  city          text not null default '',
  state         text not null default '',
  pincode       text not null default '',
  map_link      text,
  latitude      numeric,
  longitude     numeric,
  is_default    boolean not null default false,
  is_deleted    boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid
);

create index if not exists customer_addresses_cust_idx
  on public.customer_addresses (customer_id) where is_deleted = false;
-- Exactly one default per customer, enforced by the database rather than by
-- whoever remembers to clear the old one.
create unique index if not exists customer_addresses_one_default_idx
  on public.customer_addresses (customer_id) where is_default and not is_deleted;

alter table public.customer_addresses enable row level security;

-- Which order ships where. Nullable: every existing order predates the book.
alter table public.orders add column if not exists ship_to_address_id uuid
  references public.customer_addresses(id);

-- ── editability is DATA, not an if-statement ───────────────────────────────
create table if not exists public.customer_profile_field (
  key           text primary key,
  section_key   text not null,
  section_label text not null,
  ord           int  not null default 100,
  label         text not null,
  hint          text not null default '',
  input_type    text not null default 'text',   -- text|phone|email|multiline
  editable      boolean not null default false,
  locked_note   text not null default '',
  required      boolean not null default false,
  max_len       int  not null default 120
);
alter table public.customer_profile_field enable row level security;

insert into public.customer_profile_field
  (key, section_key, section_label, ord, label, hint, input_type, editable, locked_note, required, max_len) values
  ('customer_name',    'business','Business details', 10,'Owner name','Who runs this account','text',     true, '', true, 120),
  ('pharmacy_name',    'business','Business details', 20,'Pharmacy name','','text',                       false,'Your registered pharmacy name is on your approved account. Contact support to change it.', false,160),
  ('store_type',       'business','Business details', 30,'Store type','','text',                          true, '', false,80),
  ('address_local',    'address', 'Delivery address', 10,'Address','Street, area, landmark','multiline',  true, '', true, 300),
  ('city',             'address', 'Delivery address', 20,'City','','text',                                true, '', true, 80),
  ('state',            'address', 'Delivery address', 30,'State','','text',                               true, '', true, 80),
  ('pincode',          'address', 'Delivery address', 40,'PIN code','6 digits','text',                    true, '', true, 6),
  ('store_location_link','address','Delivery address',50,'Map link','Paste a Google Maps link','text',    true, '', false,400),
  ('whatsapp_no',      'contact', 'Contact',          10,'WhatsApp number','Order updates go here','phone',true, '', true, 15),
  ('other_contact_no', 'contact', 'Contact',          20,'Other number','','phone',                       true, '', false,15),
  ('email',            'contact', 'Contact',          30,'Email','','email',                              true, '', false,160),
  ('dl_20b',           'licence', 'Drug licences',    10,'DL 20B','','text',                              false,'Licence numbers are verified at approval. Contact support to update them.', false,60),
  ('dl_21b',           'licence', 'Drug licences',    20,'DL 21B','','text',                              false,'Licence numbers are verified at approval. Contact support to update them.', false,60),
  ('gst_no',           'licence', 'Drug licences',    30,'GSTIN','','text',                               false,'Your GSTIN is verified at approval. Contact support to update it.', false,20)
on conflict (key) do nothing;

-- ── every string these screens print ───────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cust_profile.edit_title',      to_jsonb('Edit profile'::text)),
  ('cust_profile.edit_entry',      to_jsonb('Edit my details'::text)),
  ('cust_profile.edit_note',       to_jsonb('Contact and delivery details update immediately. Licence and registration details are verified, so support changes those for you.'::text)),
  ('cust_profile.save',            to_jsonb('Save changes'::text)),
  ('cust_profile.saved',           to_jsonb('Profile updated.'::text)),
  ('cust_profile.no_change',       to_jsonb('Nothing changed.'::text)),
  ('cust_profile.locked_chip',     to_jsonb('Verified'::text)),
  ('cust_profile.required_error',  to_jsonb('{field} is required.'::text)),
  ('cust_profile.pincode_error',   to_jsonb('PIN code must be 6 digits.'::text)),
  ('cust_profile.phone_error',     to_jsonb('Enter a 10-digit mobile number.'::text)),
  ('cust_profile.not_customer',    to_jsonb('This account does not have a customer profile yet.'::text)),
  ('cust_addr.title',              to_jsonb('Delivery addresses'::text)),
  ('cust_addr.entry',              to_jsonb('Delivery addresses'::text)),
  ('cust_addr.note',               to_jsonb('Orders ship to the default address unless you pick another one.'::text)),
  ('cust_addr.add',                to_jsonb('Add an address'::text)),
  ('cust_addr.edit_title',         to_jsonb('Edit address'::text)),
  ('cust_addr.add_title',          to_jsonb('New address'::text)),
  ('cust_addr.save',               to_jsonb('Save address'::text)),
  ('cust_addr.saved',              to_jsonb('Address saved.'::text)),
  ('cust_addr.deleted',            to_jsonb('Address removed.'::text)),
  ('cust_addr.default_set',        to_jsonb('Default delivery address updated.'::text)),
  ('cust_addr.default_badge',      to_jsonb('Default'::text)),
  ('cust_addr.make_default',       to_jsonb('Make default'::text)),
  ('cust_addr.delete',             to_jsonb('Remove'::text)),
  ('cust_addr.cannot_delete_last', to_jsonb('This is your only delivery address, so it cannot be removed.'::text)),
  ('cust_addr.empty_title',        to_jsonb('No saved addresses'::text)),
  ('cust_addr.empty_note',         to_jsonb('Add a branch or warehouse address and orders can ship straight to it.'::text)),
  ('cust_addr.from_profile',       to_jsonb('From your registration'::text)),
  ('cust_addr.f_label',            to_jsonb('Name this address'::text)),
  ('cust_addr.f_label_hint',       to_jsonb('Main branch, Warehouse, Second shop'::text)),
  ('cust_addr.f_contact',          to_jsonb('Contact person'::text)),
  ('cust_addr.f_phone',            to_jsonb('Contact number'::text)),
  ('cust_addr.f_address',          to_jsonb('Address'::text)),
  ('cust_addr.f_city',             to_jsonb('City'::text)),
  ('cust_addr.f_state',            to_jsonb('State'::text)),
  ('cust_addr.f_pincode',          to_jsonb('PIN code'::text)),
  ('cust_addr.f_map',              to_jsonb('Map link'::text)),
  ('cust_addr.not_found',          to_jsonb('That address is no longer on your account.'::text))
on conflict (key) do nothing;

create or replace function public._cust_uic(p_key text, p_default text)
returns text language sql stable as $$
  select coalesce((select value #>> '{}' from public.ui_copy where key = p_key), p_default);
$$;

-- ── the profile editor ─────────────────────────────────────────────────────
create or replace function public.my_profile_edit()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_cust uuid := public.my_customer_id(); pp pharmacy_profiles%rowtype; v jsonb;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer',
      'message', public._cust_uic('cust_profile.not_customer','This account does not have a customer profile yet.'));
  end if;
  select * into pp from pharmacy_profiles where id = v_cust;
  v := to_jsonb(pp);

  return jsonb_build_object(
    'ok', true,
    'title',       public._cust_uic('cust_profile.edit_title','Edit profile'),
    'note',        public._cust_uic('cust_profile.edit_note',''),
    'save_label',  public._cust_uic('cust_profile.save','Save changes'),
    'locked_chip', public._cust_uic('cust_profile.locked_chip','Verified'),
    'sections', (
      select coalesce(jsonb_agg(sec order by sec_ord), '[]'::jsonb) from (
        select f.section_key, min(f.ord) as sec_ord,
               jsonb_build_object(
                 'key', f.section_key,
                 'title', min(f.section_label),
                 'fields', jsonb_agg(jsonb_build_object(
                    'key', f.key, 'label', f.label, 'hint', f.hint,
                    'input_type', f.input_type, 'editable', f.editable,
                    'locked_note', f.locked_note, 'required', f.required,
                    'max_len', f.max_len,
                    'value', coalesce(v->>f.key, '')) order by f.ord)) as sec
          from public.customer_profile_field f
         group by f.section_key) q));
end $function$;

create or replace function public.my_profile_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cust uuid := public.my_customer_id();
  r record; v_new text; v_changed int := 0; v_hit int; v_err text;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer',
      'message', public._cust_uic('cust_profile.not_customer','This account does not have a customer profile yet.'));
  end if;

  -- Validate against the SAME table the form was drawn from, so a rule can
  -- never be true on one side and false on the other.
  for r in select * from public.customer_profile_field where editable order by ord loop
    if not (p ? r.key) then continue; end if;
    v_new := btrim(coalesce(p->>r.key, ''));

    if r.required and v_new = '' then
      return jsonb_build_object('ok', false, 'error', 'required',
        'message', replace(public._cust_uic('cust_profile.required_error','{field} is required.'), '{field}', r.label));
    end if;
    if r.key = 'pincode' and v_new <> '' and v_new !~ '^[0-9]{6}$' then
      return jsonb_build_object('ok', false, 'error', 'bad_pincode',
        'message', public._cust_uic('cust_profile.pincode_error','PIN code must be 6 digits.'));
    end if;
    if r.input_type = 'phone' and v_new <> '' and length(regexp_replace(v_new,'[^0-9]','','g')) < 10 then
      return jsonb_build_object('ok', false, 'error', 'bad_phone',
        'message', public._cust_uic('cust_profile.phone_error','Enter a 10-digit mobile number.'));
    end if;
    if length(v_new) > r.max_len then
      v_new := left(v_new, r.max_len);
    end if;

    -- Only columns named by customer_profile_field are ever written, and the
    -- key is matched against the catalogue before it reaches the statement.
    execute format('update public.pharmacy_profiles set %I = $1 where id = $2 and coalesce(%I,'''') is distinct from $1', r.key, r.key)
      using v_new, v_cust;
    get diagnostics v_hit = row_count;
    v_changed := v_changed + v_hit;

    -- address_local is the field the customer edits; `address` is the legacy
    -- mirror every downstream report still reads.
    if r.key = 'address_local' then
      update public.pharmacy_profiles set address = v_new where id = v_cust;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'changed', v_changed,
    'message', case when v_changed > 0
                 then public._cust_uic('cust_profile.saved','Profile updated.')
                 else public._cust_uic('cust_profile.no_change','Nothing changed.') end,
    'session', public.my_session());
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('ok', false, 'error', 'save_failed', 'message', v_err);
end $function$;

-- ── the address book ───────────────────────────────────────────────────────
create or replace function public.my_addresses()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_cust uuid := public.my_customer_id(); v_items jsonb; v_n int;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer',
      'message', public._cust_uic('cust_profile.not_customer','This account does not have a customer profile yet.'));
  end if;

  select count(*)::int into v_n from public.customer_addresses
   where customer_id = v_cust and not is_deleted;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id,
           'label', case when btrim(a.label) <> '' then a.label
                         else public._cust_uic('cust_addr.from_profile','From your registration') end,
           'lines', (select coalesce(jsonb_agg(l order by ord), '[]'::jsonb)
                       from unnest(array[
                              nullif(btrim(a.address),''),
                              nullif(btrim(concat_ws(', ', nullif(btrim(a.city),''), nullif(btrim(a.state),''), nullif(btrim(a.pincode),''))),''),
                              nullif(btrim(concat_ws(' · ', nullif(btrim(a.contact_name),''), nullif(btrim(a.contact_phone),''))),'')
                            ]) with ordinality as t(l, ord)
                      where l is not null),
           'is_default', a.is_default,
           'default_badge', case when a.is_default then public._cust_uic('cust_addr.default_badge','Default') else '' end,
           'make_default_label', case when a.is_default then '' else public._cust_uic('cust_addr.make_default','Make default') end,
           'delete_label', public._cust_uic('cust_addr.delete','Remove'),
           'can_delete', (v_n > 1),
           'cannot_delete_note', case when v_n > 1 then ''
                else public._cust_uic('cust_addr.cannot_delete_last','This is your only delivery address, so it cannot be removed.') end,
           'map_link', coalesce(a.map_link,''),
           'raw', jsonb_build_object('label', a.label, 'contact_name', a.contact_name,
                    'contact_phone', a.contact_phone, 'address', a.address, 'city', a.city,
                    'state', a.state, 'pincode', a.pincode, 'map_link', coalesce(a.map_link,''))
         ) order by a.is_default desc, a.created_at), '[]'::jsonb)
    into v_items
    from public.customer_addresses a
   where a.customer_id = v_cust and not a.is_deleted;

  return jsonb_build_object(
    'ok', true,
    'title',       public._cust_uic('cust_addr.title','Delivery addresses'),
    'note',        public._cust_uic('cust_addr.note',''),
    'add_label',   public._cust_uic('cust_addr.add','Add an address'),
    'save_label',  public._cust_uic('cust_addr.save','Save address'),
    'add_title',   public._cust_uic('cust_addr.add_title','New address'),
    'edit_title',  public._cust_uic('cust_addr.edit_title','Edit address'),
    'empty_title', public._cust_uic('cust_addr.empty_title','No saved addresses'),
    'empty_note',  public._cust_uic('cust_addr.empty_note',''),
    'count', v_n,
    'fields', jsonb_build_array(
      jsonb_build_object('key','label','label', public._cust_uic('cust_addr.f_label','Name this address'),
                         'hint', public._cust_uic('cust_addr.f_label_hint',''), 'input_type','text','required',true,'max_len',60),
      jsonb_build_object('key','contact_name','label', public._cust_uic('cust_addr.f_contact','Contact person'),
                         'hint','', 'input_type','text','required',false,'max_len',120),
      jsonb_build_object('key','contact_phone','label', public._cust_uic('cust_addr.f_phone','Contact number'),
                         'hint','', 'input_type','phone','required',false,'max_len',15),
      jsonb_build_object('key','address','label', public._cust_uic('cust_addr.f_address','Address'),
                         'hint','', 'input_type','multiline','required',true,'max_len',300),
      jsonb_build_object('key','city','label', public._cust_uic('cust_addr.f_city','City'),
                         'hint','', 'input_type','text','required',true,'max_len',80),
      jsonb_build_object('key','state','label', public._cust_uic('cust_addr.f_state','State'),
                         'hint','', 'input_type','text','required',false,'max_len',80),
      jsonb_build_object('key','pincode','label', public._cust_uic('cust_addr.f_pincode','PIN code'),
                         'hint','', 'input_type','text','required',true,'max_len',6),
      jsonb_build_object('key','map_link','label', public._cust_uic('cust_addr.f_map','Map link'),
                         'hint','', 'input_type','text','required',false,'max_len',400)),
    'items', v_items);
end $function$;

create or replace function public.my_address_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cust uuid := public.my_customer_id(); v_id uuid; v_first boolean; v_pin text;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer',
      'message', public._cust_uic('cust_profile.not_customer',''));
  end if;

  if btrim(coalesce(p->>'label','')) = '' then
    return jsonb_build_object('ok', false, 'error', 'required',
      'message', replace(public._cust_uic('cust_profile.required_error','{field} is required.'),
                         '{field}', public._cust_uic('cust_addr.f_label','Name this address')));
  end if;
  if btrim(coalesce(p->>'address','')) = '' then
    return jsonb_build_object('ok', false, 'error', 'required',
      'message', replace(public._cust_uic('cust_profile.required_error','{field} is required.'),
                         '{field}', public._cust_uic('cust_addr.f_address','Address')));
  end if;
  v_pin := btrim(coalesce(p->>'pincode',''));
  if v_pin !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_pincode',
      'message', public._cust_uic('cust_profile.pincode_error','PIN code must be 6 digits.'));
  end if;

  v_id := nullif(p->>'id','')::uuid;
  select not exists (select 1 from public.customer_addresses
                      where customer_id = v_cust and not is_deleted) into v_first;

  if v_id is null then
    insert into public.customer_addresses
      (customer_id, label, contact_name, contact_phone, address, city, state, pincode,
       map_link, is_default, created_by)
    values (v_cust, left(btrim(p->>'label'),60), left(btrim(coalesce(p->>'contact_name','')),120),
            left(btrim(coalesce(p->>'contact_phone','')),15), left(btrim(p->>'address'),300),
            left(btrim(coalesce(p->>'city','')),80), left(btrim(coalesce(p->>'state','')),80), v_pin,
            nullif(btrim(coalesce(p->>'map_link','')),''), v_first, auth.uid())
    returning id into v_id;
  else
    update public.customer_addresses set
      label = left(btrim(p->>'label'),60),
      contact_name = left(btrim(coalesce(p->>'contact_name','')),120),
      contact_phone = left(btrim(coalesce(p->>'contact_phone','')),15),
      address = left(btrim(p->>'address'),300),
      city = left(btrim(coalesce(p->>'city','')),80),
      state = left(btrim(coalesce(p->>'state','')),80),
      pincode = v_pin,
      map_link = nullif(btrim(coalesce(p->>'map_link','')),''),
      updated_at = now()
     where id = v_id and customer_id = v_cust and not is_deleted;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found',
        'message', public._cust_uic('cust_addr.not_found',''));
    end if;
  end if;

  return public.my_addresses() || jsonb_build_object(
    'saved_id', v_id, 'toast', public._cust_uic('cust_addr.saved','Address saved.'));
end $function$;

create or replace function public.my_address_set_default(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cust uuid := public.my_customer_id();
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer', 'message', public._cust_uic('cust_profile.not_customer',''));
  end if;
  if not exists (select 1 from public.customer_addresses
                  where id = p_id and customer_id = v_cust and not is_deleted) then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', public._cust_uic('cust_addr.not_found',''));
  end if;
  -- Clear first, then set: the partial unique index allows exactly one.
  update public.customer_addresses set is_default = false, updated_at = now()
   where customer_id = v_cust and is_default and not is_deleted;
  update public.customer_addresses set is_default = true, updated_at = now()
   where id = p_id and customer_id = v_cust;
  return public.my_addresses() || jsonb_build_object(
    'toast', public._cust_uic('cust_addr.default_set','Default delivery address updated.'));
end $function$;

create or replace function public.my_address_delete(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_cust uuid := public.my_customer_id(); v_n int; v_was_default boolean;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_customer', 'message', public._cust_uic('cust_profile.not_customer',''));
  end if;
  select count(*)::int into v_n from public.customer_addresses where customer_id = v_cust and not is_deleted;
  if v_n <= 1 then
    return jsonb_build_object('ok', false, 'error', 'last_address',
      'message', public._cust_uic('cust_addr.cannot_delete_last',''));
  end if;
  select is_default into v_was_default from public.customer_addresses
   where id = p_id and customer_id = v_cust and not is_deleted;
  if v_was_default is null then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', public._cust_uic('cust_addr.not_found',''));
  end if;

  update public.customer_addresses set is_deleted = true, is_default = false, updated_at = now()
   where id = p_id and customer_id = v_cust;

  -- The account is never left without a default.
  if v_was_default then
    update public.customer_addresses set is_default = true
     where id = (select id from public.customer_addresses
                  where customer_id = v_cust and not is_deleted
                  order by created_at limit 1);
  end if;

  return public.my_addresses() || jsonb_build_object(
    'toast', public._cust_uic('cust_addr.deleted','Address removed.'));
end $function$;

grant execute on function public.my_profile_edit()            to authenticated;
grant execute on function public.my_profile_save(jsonb)       to authenticated;
grant execute on function public.my_addresses()               to authenticated;
grant execute on function public.my_address_save(jsonb)       to authenticated;
grant execute on function public.my_address_set_default(uuid) to authenticated;
grant execute on function public.my_address_delete(uuid)      to authenticated;

-- ── seed the book from the registration address ───────────────────────────
-- Every existing account gets its approved registration address as address #1
-- and default, so the book is never empty and the order path below finds a row
-- on day one. Idempotent: an account that already has an address is skipped.
insert into public.customer_addresses
  (customer_id, label, contact_name, contact_phone, address, city, state, pincode, map_link, is_default)
select p.id,
       public._cust_uic('cust_addr.from_profile','From your registration'),
       coalesce(nullif(btrim(p.customer_name),''), coalesce(p.owner_name,'')),
       coalesce(nullif(btrim(p.whatsapp_no),''), coalesce(p.phone,'')),
       coalesce(nullif(btrim(p.address_local),''), coalesce(p.address,'')),
       coalesce(p.city,''), coalesce(p.state,''), coalesce(p.pincode,''),
       nullif(btrim(coalesce(p.store_location_link,'')),''),
       true
  from public.pharmacy_profiles p
 where coalesce(p.is_deleted,false) = false
   and not exists (select 1 from public.customer_addresses a
                    where a.customer_id = p.id and not a.is_deleted);

-- ── order placement uses the default ship-to ──────────────────────────────
-- Same shape as before, one change: the delivery address on the order comes
-- from the customer's DEFAULT address book entry when there is one, and the
-- order records WHICH entry it was. A customer with a single branch sees no
-- difference; a chain finally can ship to the branch that ordered.
create or replace function public._place_order_v2_core()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_sess jsonb := public.my_session();
  v_cart jsonb;
  v_cust uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_act  uuid := public.my_acting_as();
  pp pharmacy_profiles%rowtype;
  ca customer_addresses%rowtype;
  v_items jsonb; v_net numeric; v_id uuid; v_code text;
  v_addr text; v_phone text; v_copy jsonb;
  v_checkout   jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated'
      using hint = 'Session missing or expired; sign in again and retry.';
  end if;

  if (v_sess->>'can_place_order') is distinct from 'true' then
    raise exception 'order_gate_blocked'
      using hint = coalesce(v_sess->'order_gate'->>'message', 'Ordering is not available.');
  end if;

  v_cart := public.cart_state(null);
  v_items := coalesce(v_cart->'items', '[]'::jsonb);
  if jsonb_array_length(v_items) = 0 then
    raise exception 'empty_cart' using hint = 'No items to order.';
  end if;

  v_net := coalesce((v_cart->'pricing'->>'net_payable')::numeric, 0);

  select * into pp from pharmacy_profiles where id = v_cust;
  select * into ca from customer_addresses
   where customer_id = v_cust and is_default and not is_deleted limit 1;

  if ca.id is not null then
    v_addr := array_to_string(array_remove(array_remove(array[
                nullif(btrim(coalesce(ca.address,'')), ''),
                nullif(btrim(coalesce(ca.city,'')), ''),
                nullif(btrim(coalesce(ca.pincode,'')), '')], null), ''), ', ');
    v_phone := coalesce(nullif(btrim(coalesce(ca.contact_phone,'')),''), coalesce(pp.phone,''));
  else
    v_addr := array_to_string(array_remove(array_remove(array[
                nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
                nullif(btrim(coalesce(pp.city,'')), ''),
                nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');
    v_phone := coalesce(pp.phone,'');
  end if;

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id, ship_to_address_id)
  values
    (v_uid, v_cust, coalesce(pp.pharmacy_name,''), v_items, v_net,
     v_phone, coalesce(v_addr,''), 'pending',
     'website',
     (v_act is not null),
     public.next_order_number(), ca.id)
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);
  v_checkout := public.checkout_action();

  if (v_checkout->>'acting_as')::boolean
     and (v_checkout->>'collection_mode') = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object(
    'ok',              true,
    'id',              coalesce(v_id::text,''),
    'order_code',      coalesce(v_code,''),
    'amount',          v_net,
    'amount_display',  coalesce(v_cart->'pricing'->>'net_payable_display', public.inr_money(v_net)),
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);
end $function$;

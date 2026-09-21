-- CMD #2129 — ONE Add customer flow for every staff entry point.
--
-- Customers tab (manual + photo), Today's visit, every plan (current and
-- past), the lead list and a file-imported lead all open the SAME staff flow:
-- the Registration v3 steps (General · Location · Documents, from
-- customer_registration_wizard) + a staff-only Terms step + a Saved screen.
-- The write stays ONE door: admin_import_customer / lead_import_customer.
--
-- Everything the flow prints is here: step list, captions, the live WhatsApp
-- number verdict, the terms options, the Saved checklist. Idempotent.

alter table public.pharmacy_profiles add column if not exists delivery_pref text;

-- ── copy ────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('addcust.title',            to_jsonb('Add customer'::text)),
  ('addcust.close',            to_jsonb('Close'::text)),
  ('addcust.photo_title',      to_jsonb('Photograph board or GST certificate'::text)),
  ('addcust.photo_line',       to_jsonb('We fill name, GSTIN and address'::text)),
  ('addcust.photo_reading',    to_jsonb('Reading the photo…'::text)),
  ('addcust.read_from_photo',  to_jsonb('✓ Read from photo'::text)),
  ('addcust.photo_failed',     to_jsonb('Could not read that photo — type the details instead.'::text)),
  ('addcust.save',             to_jsonb('Save'::text)),
  ('addcust.save_hint',        to_jsonb('Name, WhatsApp and pin are enough to save'::text)),
  ('addcust.save_customer',    to_jsonb('Save customer'::text)),
  ('addcust.saving',           to_jsonb('Saving…'::text)),
  ('addcust.need_name',        to_jsonb('Pharmacy name is required.'::text)),
  ('addcust.need_pin',         to_jsonb('Place the pin on the shop to save.'::text)),
  ('addcust.error',            to_jsonb('Could not save. Try again.'::text)),
  ('addcust.retry',            to_jsonb('Try again'::text)),
  ('addcust.from_lead',        to_jsonb('From lead: {name}'::text)),
  ('addcust.resumed',          to_jsonb('Resuming {name} — fill what is left.'::text)),
  ('addcust.out_of_zone',      to_jsonb('This shop is outside your zone.'::text)),
  ('addcust.num_checking',     to_jsonb('Checking…'::text)),
  ('addcust.num_new',          to_jsonb('✓ New'::text)),
  ('addcust.num_invalid',      to_jsonb('Enter a 10-digit WhatsApp number'::text)),
  ('addcust.num_customer',     to_jsonb('Already a customer: {name}'::text)),
  ('addcust.num_unfinished',   to_jsonb('{name} started registering and did not finish'::text)),
  ('addcust.num_other_role',   to_jsonb('This number is another team''s login — use a different number'::text)),
  ('addcust.num_removed',      to_jsonb('{name} was removed'::text)),
  ('addcust.num_open',         to_jsonb('Open'::text)),
  ('addcust.num_use_another',  to_jsonb('Use another'::text)),
  ('addcust.num_resume',       to_jsonb('Resume theirs'::text)),
  ('addcust.num_restore',      to_jsonb('Restore'::text)),
  ('addcust.num_fresh',        to_jsonb('Start fresh'::text)),
  ('addcust.num_blocked',      to_jsonb('Pick a number that is not taken.'::text)),
  ('addcust.skip',             to_jsonb('Skip'::text)),
  ('addcust.customer_will_add',to_jsonb('Customer will add'::text)),
  ('addcust.terms_step',       to_jsonb('Terms'::text)),
  ('addcust.terms_done',       to_jsonb('✓ Terms'::text)),
  ('addcust.terms_title',      to_jsonb('Terms for this customer'::text)),
  ('addcust.terms_sub',        to_jsonb('Customers never see this step.'::text)),
  ('addcust.payment_label',    to_jsonb('Payment term'::text)),
  ('addcust.delivery_label',   to_jsonb('Delivery'::text)),
  ('addcust.zone_label',       to_jsonb('Zone'::text)),
  ('addcust.slab_label',       to_jsonb('Advance slab'::text)),
  ('addcust.slab_none',        to_jsonb('None'::text)),
  ('addcust.invite_label',     to_jsonb('Send WhatsApp invite'::text)),
  ('addcust.on',               to_jsonb('On'::text)),
  ('addcust.off',              to_jsonb('Off'::text)),
  ('addcust.deliv_same',       to_jsonb('Same day'::text)),
  ('addcust.deliv_next',       to_jsonb('Next day'::text)),
  ('addcust.deliv_weekly',     to_jsonb('Weekly route'::text)),
  ('addcust.saved_title',      to_jsonb('Customer added'::text)),
  ('addcust.invite_sent',      to_jsonb('✓ WhatsApp invite sent to {phone}'::text)),
  ('addcust.invite_off',       to_jsonb('No WhatsApp invite sent'::text)),
  ('addcust.row_shop',         to_jsonb('Shop details'::text)),
  ('addcust.row_location',     to_jsonb('Location'::text)),
  ('addcust.row_licences',     to_jsonb('Drug licences'::text)),
  ('addcust.row_terms',        to_jsonb('Terms'::text)),
  ('addcust.done',             to_jsonb('Done'::text)),
  ('addcust.saved_note',       to_jsonb('When they log in with {phone} they land on the same form, already filled, to finish the rest.'::text)),
  ('addcust.open_customer',    to_jsonb('Open customer'::text)),
  ('addcust.add_another',      to_jsonb('Add another'::text)),
  ('addcust.button',           to_jsonb('+ Add customer'::text))
on conflict (key) do nothing;

-- The console search now covers GSTIN, so its hint says so.
update public.ui_copy set value = to_jsonb('Search name, number, GSTIN'::text), updated_at = now()
 where key = 'admin_cus2.search_hint';

-- ── helpers ─────────────────────────────────────────────────────────────────
create or replace function public._addcust_is_super()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((public.access_subject()->>'role') = 'super_admin', false);
$$;

create or replace function public._addcust_phone_label(p text)
returns text language sql immutable as $$
  select case when length(coalesce(p,'')) = 10
              then substr(p,1,5) || ' ' || substr(p,6,5) else coalesce(p,'') end;
$$;

create or replace function public._addcust_term_label(p text)
returns text language sql immutable as $$
  select case p when 'Advance Payment'  then 'Advance'
                when 'Cash on Delivery' then 'COD'
                when 'Credit 7 days'    then 'Credit 7d'
                when 'Credit 15 days'   then 'Credit 15d'
                when 'Credit 30 days'   then 'Credit 30d'
                else coalesce(p,'') end;
$$;

create or replace function public._addcust_deliv_label(p text)
returns text language sql stable security definer set search_path = public as $$
  select case p when 'same_day' then public._c('addcust.deliv_same')
                when 'next_day' then public._c('addcust.deliv_next')
                when 'weekly_route' then public._c('addcust.deliv_weekly')
                else '' end;
$$;

-- The zone's in-force first rung, printed "1st order · 10%".
create or replace function public._addcust_slab_label(p_zone smallint)
returns text language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select s.order_no, s.pct into r
    from public.advance_slabs s
   where s.active and s.valid_from <= coalesce(public.admin_active_date(), current_date)
     and (s.zone_id = p_zone or s.zone_id is null)
   order by (s.zone_id is null), s.order_no
   limit 1;
  if not found then return public._c('addcust.slab_none'); end if;
  return public._advance_ordinal(r.order_no) || ' order · ' || public._advance_pct_text(r.pct) || '%';
end $$;

-- The zone a set of form values belongs to.
create or replace function public._addcust_zone_for(p_values jsonb)
returns smallint language plpgsql stable security definer set search_path = public as $$
declare v smallint;
begin
  if nullif(btrim(coalesce(p_values->>'district', p_values->>'city','')),'') is not null then
    begin
      v := public.zone_resolve(p_values->>'district', p_values->>'city', false);
    exception when others then v := null; end;
  end if;
  return coalesce(v, public.admin_active_zone());
end $$;

-- The customer row as form values (resume).
create or replace function public._addcust_values_of(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'pharmacy_name', pp.pharmacy_name, 'customer_name', coalesce(pp.customer_name, pp.owner_name),
    'store_type', pp.store_type, 'whatsapp_no', public._phone10(coalesce(pp.whatsapp_no, pp.phone,'')),
    'email', pp.email, 'address', pp.address, 'landmark', pp.landmark, 'city', nullif(pp.city,''),
    'district', pp.district, 'state', pp.state, 'pincode', nullif(pp.pincode,''),
    'latitude', pp.latitude::text, 'longitude', pp.longitude::text, 'gstin', pp.gstin))
  from public.pharmacy_profiles pp where pp.id = p_id;
$$;

-- ── the live number verdict ─────────────────────────────────────────────────
create or replace function public.addcust_number_check(p_number text, p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_n text := public._phone10(coalesce(p_number,''));
  r record;
  v_owner text;
  act jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'state','not_authorized', 'allow', false);
  end if;
  if length(coalesce(v_n,'')) <> 10 then
    return jsonb_build_object('ok', true, 'state','invalid', 'allow', false, 'tone','danger',
                              'label', public._c('addcust.num_invalid'), 'actions','[]'::jsonb);
  end if;

  select pp.id, pp.pharmacy_name, pp.approved, pp.registration_stage::text as stage
    into r
    from public.pharmacy_profiles pp
   where coalesce(pp.is_deleted,false) = false
     and pp.id is distinct from p_customer_id
     and public._phone10(coalesce(pp.whatsapp_no, pp.phone,'')) = v_n
   order by pp.created_at desc limit 1;
  if found then
    if not coalesce(r.approved,false) and r.stage in ('signed_up','details','documents') then
      return jsonb_build_object('ok', true, 'state','unfinished', 'allow', false, 'tone','warning',
        'customer_id', r.id,
        'label', replace(public._c('addcust.num_unfinished'), '{name}', coalesce(r.pharmacy_name,'')),
        'actions', jsonb_build_array(jsonb_build_object('key','resume','label',public._c('addcust.num_resume'),'customer_id',r.id)));
    end if;
    return jsonb_build_object('ok', true, 'state','customer', 'allow', false, 'tone','warning',
      'customer_id', r.id,
      'label', replace(public._c('addcust.num_customer'), '{name}', coalesce(r.pharmacy_name,'')),
      'actions', jsonb_build_array(
         jsonb_build_object('key','open','label',public._c('addcust.num_open'),'customer_id',r.id),
         jsonb_build_object('key','use_another','label',public._c('addcust.num_use_another'))));
  end if;

  select li.owner_type into v_owner
    from public.login_identities li
   where li.identity = public.identity_norm(v_n) and li.owner_type <> 'customer'
   limit 1;
  if v_owner is not null then
    return jsonb_build_object('ok', true, 'state','other_role', 'allow', false, 'tone','danger',
      'label', public._c('addcust.num_other_role'), 'actions','[]'::jsonb);
  end if;

  select pp.id, pp.pharmacy_name into r
    from public.pharmacy_profiles pp
   where coalesce(pp.is_deleted,false) = true
     and public._phone10(coalesce(pp.whatsapp_no, pp.phone,'')) = v_n
   order by pp.deleted_at desc nulls last limit 1;
  if found then
    return jsonb_build_object('ok', true, 'state','removed', 'allow', false, 'tone','warning',
      'customer_id', r.id,
      'label', replace(public._c('addcust.num_removed'), '{name}', coalesce(r.pharmacy_name,'')),
      'actions', jsonb_build_array(
         jsonb_build_object('key','restore','label',public._c('addcust.num_restore'),'customer_id',r.id),
         jsonb_build_object('key','fresh','label',public._c('addcust.num_fresh'))));
  end if;

  return jsonb_build_object('ok', true, 'state','new', 'allow', true, 'tone','success',
                            'label', public._c('addcust.num_new'), 'actions','[]'::jsonb);
end $$;

-- ── terms block ─────────────────────────────────────────────────────────────
create or replace function public._addcust_terms(p_zone smallint, p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_term text := 'Advance Payment'; v_del text := 'next_day';
  v_super boolean := public._addcust_is_super();
  v_active smallint := public.admin_active_zone();
  v_zone smallint := p_zone;
  v_zones jsonb;
begin
  if p_customer_id is not null then
    select coalesce(pp.payment_term, v_term), coalesce(pp.delivery_pref, v_del), coalesce(pp.zone_id, v_zone)
      into v_term, v_del, v_zone
      from public.pharmacy_profiles pp where pp.id = p_customer_id;
  end if;
  if not v_super and v_active is not null then v_zone := v_active; end if;
  select coalesce(jsonb_agg(jsonb_build_object('value', z.id, 'label', regexp_replace(z.name, '\s+Zone$', ''))
                            order by z.id), '[]'::jsonb)
    into v_zones
    from public.zones z
   where z.id <> 99
     and (v_super or v_active is null or z.id = v_active);
  return jsonb_build_object(
    'title',    public._c('addcust.terms_title'),
    'subtitle', public._c('addcust.terms_sub'),
    'payment',  jsonb_build_object('label', public._c('addcust.payment_label'), 'value', v_term,
                  'options', (select jsonb_agg(jsonb_build_object('value', t #>> '{}', 'label', public._addcust_term_label(t #>> '{}')))
                                from jsonb_array_elements(public.customer_form_options()->'payment_term') t)),
    'delivery', jsonb_build_object('label', public._c('addcust.delivery_label'), 'value', v_del,
                  'options', jsonb_build_array(
                    jsonb_build_object('value','same_day','label',public._c('addcust.deliv_same')),
                    jsonb_build_object('value','next_day','label',public._c('addcust.deliv_next')),
                    jsonb_build_object('value','weekly_route','label',public._c('addcust.deliv_weekly')))),
    'zone',     jsonb_build_object('label', public._c('addcust.zone_label'), 'value', v_zone,
                  'locked', (not v_super and v_active is not null), 'options', v_zones),
    'slab',     jsonb_build_object('label', public._c('addcust.slab_label'),
                  'value_label', public._addcust_slab_label(v_zone)),
    'invite',   jsonb_build_object('label', public._c('addcust.invite_label'), 'on', true,
                  'on_label', public._c('addcust.on'), 'off_label', public._c('addcust.off')));
end $$;

-- ── licences, staff words ───────────────────────────────────────────────────
create or replace function public.addcust_licences(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_zone smallint; b jsonb; g jsonb; rw jsonb; groups jsonb := '[]'::jsonb; rows jsonb;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'show', false); end if;
  select zone_id into v_zone from public.pharmacy_profiles where id = p_customer_id;
  b := public.custreg_licences_block(coalesce(v_zone, public.admin_active_zone()), p_customer_id);
  for g in select * from jsonb_array_elements(coalesce(b->'groups','[]'::jsonb)) loop
    rows := '[]'::jsonb;
    for rw in select * from jsonb_array_elements(coalesce(g->'rows','[]'::jsonb)) loop
      if rw ? 'dont_have' then
        rw := jsonb_set(rw, '{dont_have}', (rw->'dont_have') || jsonb_build_object(
                'label', public._c('addcust.skip'),
                'skipped_label', public._c('addcust.customer_will_add'),
                'skipped_tone', 'warning'));
      end if;
      rows := rows || jsonb_build_array(rw);
    end loop;
    groups := groups || jsonb_build_array(jsonb_set(g, '{rows}', rows));
  end loop;
  return jsonb_build_object('ok', true, 'customer_id', p_customer_id) || b
         || jsonb_build_object('groups', groups);
end $$;

-- ── open: everything the flow draws ─────────────────────────────────────────
create or replace function public.addcust_open(p_lead_id bigint default null,
                                               p_customer_id uuid default null,
                                               p_prefill jsonb default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_schema jsonb; v_vals jsonb := '{}'::jsonb; v_wiz jsonb; v_steps jsonb;
  v_lead jsonb; v_link jsonb := jsonb_build_object('show', false); v_name text;
  v_zone smallint; v_note text := '';
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('addcust.error'), 'retry_label', public._c('addcust.retry'));
  end if;
  v_schema := public.customer_form_schema('signup');

  if p_customer_id is not null then
    v_vals := coalesce(public._addcust_values_of(p_customer_id), '{}'::jsonb);
    v_note := replace(public._c('addcust.resumed'), '{name}', coalesce(v_vals->>'pharmacy_name',''));
  elsif p_lead_id is not null then
    v_lead := public.lead_customer_prefill(p_lead_id);
    if v_lead ? 'customer' then
      v_vals := jsonb_strip_nulls(v_lead->'customer');
      v_name := coalesce(v_vals->>'pharmacy_name', '');
      v_link := jsonb_build_object('show', true, 'lead_id', p_lead_id,
                  'label', replace(public._c('addcust.from_lead'), '{name}', v_name));
    end if;
  end if;
  v_vals := v_vals || jsonb_strip_nulls(coalesce(p_prefill, '{}'::jsonb));
  v_zone := public._addcust_zone_for(v_vals);

  v_wiz := public.customer_registration_wizard(v_schema, v_vals, '{}'::jsonb, true, '', null, v_vals, 0);
  v_steps := coalesce(v_wiz->'steps', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
     'n', jsonb_array_length(coalesce(v_wiz->'steps','[]'::jsonb)) + 1,
     'key','terms', 'label', public._c('addcust.terms_step'), 'done_label', public._c('addcust.terms_done'),
     'title', public._c('addcust.terms_title'), 'subtitle', public._c('addcust.terms_sub'),
     'terms', true, 'docs', false, 'complete', false, 'fields','[]'::jsonb));

  return jsonb_build_object(
    'ok', true,
    'title', public._c('addcust.title'),
    'close_label', public._c('addcust.close'),
    'customer_id', p_customer_id,
    'lead_id', p_lead_id,
    'link', v_link,
    'note', v_note,
    'schema', v_schema,
    'prefill', v_vals,
    'wizard', (v_wiz - 'done') || jsonb_build_object(
                'steps', v_steps, 'resume_step', 0, 'field_notes', '{}'::jsonb,
                'submit_label', public._c('addcust.save_customer'),
                'submitting_label', public._c('addcust.saving')),
    'photo', jsonb_build_object('title', public._c('addcust.photo_title'), 'line', public._c('addcust.photo_line'),
               'reading_label', public._c('addcust.photo_reading'), 'read_note', public._c('addcust.read_from_photo'),
               'failed_label', public._c('addcust.photo_failed')),
    'save', jsonb_build_object('label', public._c('addcust.save'), 'hint', public._c('addcust.save_hint'),
              'saving_label', public._c('addcust.saving')),
    'number', jsonb_build_object('key','whatsapp_no', 'debounce_ms', 500,
              'checking_label', public._c('addcust.num_checking')),
    'terms', public._addcust_terms(v_zone, p_customer_id),
    'error_label', public._c('addcust.error'),
    'retry_label', public._c('addcust.retry'));
end $$;

-- ── save: create (one door) or update ───────────────────────────────────────
create or replace function public.addcust_save(p_values jsonb,
                                               p_lead_id bigint default null,
                                               p_customer_id uuid default null,
                                               p_step text default 'save')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v jsonb := coalesce(p_values, '{}'::jsonb);
  v_chk jsonb; v_res jsonb; v_id uuid := p_customer_id;
  v_zone smallint; v_active smallint := public.admin_active_zone();
  v_lat text := nullif(btrim(coalesce(v->>'latitude','')),'');
  v_lng text := nullif(btrim(coalesce(v->>'longitude','')),'');
  v_fresh boolean := coalesce((v->>'_fresh')::boolean, false);
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('custdoc.err_not_authorized'));
  end if;
  if nullif(btrim(coalesce(v->>'pharmacy_name','')),'') is null then
    return jsonb_build_object('ok', false, 'field','pharmacy_name', 'message', public._c('addcust.need_name'));
  end if;
  v_chk := public.addcust_number_check(v->>'whatsapp_no', p_customer_id);
  if not coalesce((v_chk->>'allow')::boolean, false)
     and not (v_fresh and v_chk->>'state' = 'removed') then
    return jsonb_build_object('ok', false, 'field','whatsapp_no', 'number', v_chk,
      'message', case when v_chk->>'state' = 'invalid' then v_chk->>'label' else public._c('addcust.num_blocked') end);
  end if;
  -- The Shop step only needs to be judged, not written.
  if p_step = 'shop' and v_id is null then
    return jsonb_build_object('ok', true, 'step', 'shop');
  end if;
  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'field','store_pin', 'message', public._c('addcust.need_pin'));
  end if;

  v_zone := public._addcust_zone_for(v);
  if not public._addcust_is_super() and v_active is not null and v_zone is distinct from v_active then
    return jsonb_build_object('ok', false, 'message', public._c('addcust.out_of_zone'));
  end if;

  if nullif(btrim(coalesce(v->>'address','')),'') is null then
    v := v || jsonb_build_object('address', coalesce(
            nullif(concat_ws(', ', nullif(btrim(v->>'landmark'),''), nullif(btrim(v->>'city'),''),
                             nullif(btrim(v->>'district'),''), nullif(btrim(v->>'state'),'')), ''),
            v_lat || ', ' || v_lng));
  end if;

  if v_id is null then
    v := (v - '_fresh') || jsonb_build_object('location_source', 'pin');
    begin
      if p_lead_id is not null then
        v_res := public.lead_import_customer(v, p_lead_id);
      else
        v_res := public.admin_import_customer(v);
      end if;
    exception when others then
      return jsonb_build_object('ok', false, 'message', sqlerrm);
    end;
    v_id := nullif(v_res->>'customer_id','')::uuid;
    if v_id is null then
      return jsonb_build_object('ok', false, 'message', coalesce(v_res->>'message', public._c('addcust.error')));
    end if;
  else
    update public.pharmacy_profiles pp set
      pharmacy_name = coalesce(nullif(btrim(v->>'pharmacy_name'),''), pp.pharmacy_name),
      customer_name = coalesce(nullif(btrim(v->>'customer_name'),''), pp.customer_name),
      owner_name    = coalesce(nullif(btrim(v->>'customer_name'),''), pp.owner_name),
      store_type    = coalesce(nullif(btrim(v->>'store_type'),''), pp.store_type),
      whatsapp_no   = coalesce(nullif(public._phone10(coalesce(v->>'whatsapp_no','')),''), pp.whatsapp_no),
      email         = coalesce(nullif(btrim(v->>'email'),''), pp.email),
      address       = coalesce(nullif(btrim(v->>'address'),''), pp.address),
      landmark      = coalesce(nullif(btrim(v->>'landmark'),''), pp.landmark),
      city          = coalesce(nullif(btrim(v->>'city'),''), pp.city),
      district      = coalesce(nullif(btrim(v->>'district'),''), pp.district),
      state         = coalesce(nullif(btrim(v->>'state'),''), pp.state),
      pincode       = coalesce(nullif(regexp_replace(coalesce(v->>'pincode',''),'\D','','g'),''), pp.pincode),
      latitude      = v_lat::double precision,
      longitude     = v_lng::double precision
    where pp.id = v_id and coalesce(pp.is_deleted,false) = false;
  end if;

  update public.pharmacy_profiles
     set zone_id  = coalesce(v_zone, zone_id),
         district = coalesce(nullif(btrim(v->>'district'),''), district),
         landmark = coalesce(nullif(btrim(v->>'landmark'),''), landmark)
   where id = v_id;

  return jsonb_build_object('ok', true, 'customer_id', v_id, 'step', p_step,
                            'licences', public.addcust_licences(v_id),
                            'terms', public._addcust_terms(v_zone, v_id));
end $$;

-- ── finish: terms + invite + the Saved screen ───────────────────────────────
create or replace function public.addcust_finish(p_customer_id uuid,
                                                 p_terms jsonb default '{}'::jsonb,
                                                 p_skips jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t jsonb := coalesce(p_terms, '{}'::jsonb);
  r record;
  v_term text := nullif(btrim(coalesce(t->>'payment_term','')),'');
  v_del  text := nullif(btrim(coalesce(t->>'delivery','')),'');
  v_zone smallint := nullif(btrim(coalesce(t->>'zone_id','')),'')::smallint;
  v_invite boolean := coalesce((t->>'invite')::boolean, true);
  v_active smallint := public.admin_active_zone();
  v_sent boolean := false; v_phone text; v_lic_total int; v_lic_done int; v_lic jsonb;
  v_skipped boolean;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('custdoc.err_not_authorized'));
  end if;
  select * into r from public.pharmacy_profiles where id = p_customer_id and coalesce(is_deleted,false) = false;
  if not found then return jsonb_build_object('ok', false, 'message', public._c('addcust.error')); end if;

  if v_term is not null and not ((public.customer_form_options()->'payment_term') ? v_term) then v_term := null; end if;
  if v_del not in ('same_day','next_day','weekly_route') then v_del := null; end if;
  if v_zone is not null and not public._addcust_is_super() and v_active is not null and v_zone <> v_active then
    return jsonb_build_object('ok', false, 'message', public._c('addcust.out_of_zone'));
  end if;

  update public.pharmacy_profiles
     set payment_term  = coalesce(v_term, payment_term),
         delivery_pref = coalesce(v_del, delivery_pref, 'next_day'),
         zone_id       = coalesce(v_zone, zone_id)
   where id = p_customer_id;
  if v_term is not null and v_term is distinct from r.payment_term then
    begin
      insert into public.customer_payment_term_log (customer_id, zone_id, from_term, to_term, reason, changed_by)
      values (p_customer_id, coalesce(v_zone, r.zone_id), r.payment_term, v_term, 'Add customer', auth.uid());
    exception when others then null; end;
  end if;

  select * into r from public.pharmacy_profiles where id = p_customer_id;
  v_phone := public._phone10(coalesce(r.whatsapp_no, r.phone, ''));

  if v_invite then
    begin
      perform public.wa_send_event('customer_imported', p_customer_id,
        jsonb_build_object('name', r.pharmacy_name, 'pharmacy_name', r.pharmacy_name, 'phone', v_phone),
        v_phone, null);
      v_sent := true;
    exception when others then v_sent := false; end;
  end if;

  v_lic := public.addcust_licences(p_customer_id);
  select count(*) filter (where true), count(*) filter (where rw->>'state' = 'uploaded')
    into v_lic_total, v_lic_done
    from jsonb_array_elements(coalesce(v_lic->'groups','[]'::jsonb)) g,
         jsonb_array_elements(coalesce(g->'rows','[]'::jsonb)) rw
   where coalesce((g->>'required')::boolean, g->>'key' = 'required', false);
  v_skipped := jsonb_array_length(coalesce(p_skips,'[]'::jsonb)) > 0 or v_lic_done < v_lic_total;

  return jsonb_build_object(
    'ok', true, 'customer_id', p_customer_id,
    'title', public._c('addcust.saved_title'),
    'line', concat_ws(' · ', r.pharmacy_name, nullif(r.city,'')),
    'invite', jsonb_build_object('show', true, 'tone', case when v_sent then 'success' else 'neutral' end,
               'label', case when v_sent then replace(public._c('addcust.invite_sent'), '{phone}', public._addcust_phone_label(v_phone))
                             else public._c('addcust.invite_off') end),
    'checklist', jsonb_build_array(
      jsonb_build_object('label', public._c('addcust.row_shop'), 'value', public._c('addcust.done'), 'tone','success'),
      jsonb_build_object('label', public._c('addcust.row_location'), 'value', public._c('addcust.done'), 'tone','success'),
      jsonb_build_object('label', public._c('addcust.row_licences'),
                         'value', case when v_skipped then public._c('addcust.customer_will_add') else public._c('addcust.done') end,
                         'tone', case when v_skipped then 'warning' else 'success' end),
      jsonb_build_object('label', public._c('addcust.row_terms'),
                         'value', concat_ws(' · ', public._addcust_term_label(r.payment_term),
                                            nullif(public._addcust_deliv_label(r.delivery_pref),'')),
                         'tone','success')),
    'note', replace(public._c('addcust.saved_note'), '{phone}', public._addcust_phone_label(v_phone)),
    'open_label', public._c('addcust.open_customer'),
    'another_label', public._c('addcust.add_another'));
end $$;

-- ── the Customers tab's own entry ───────────────────────────────────────────
create or replace function public.addcust_entry()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('show', public.is_admin(), 'label', public._c('addcust.button'),
                            'zone_id', public.admin_active_zone(), 'date', public.admin_active_date());
$$;

-- ── console search covers GSTIN ─────────────────────────────────────────────
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p
   where p.proname = 'admin_customers_console' and p.pronamespace = 'public'::regnamespace limit 1;
  if d is not null and position($q$x.gstin$q$ in d) = 0
     and position($q$or lower(coalesce(x.city,''))          like '%'||v_q||'%')$q$ in d) > 0 then
    d := replace(d,
      $q$or lower(coalesce(x.city,''))          like '%'||v_q||'%')$q$,
      $q$or lower(coalesce(x.city,''))          like '%'||v_q||'%'
                     or lower(coalesce(x.gstin,''))         like '%'||v_q||'%')$q$);
    execute d;
  end if;
end $$;

-- ── grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.addcust_number_check(text,uuid)', 'public.addcust_licences(uuid)',
    'public.addcust_open(bigint,uuid,jsonb)', 'public.addcust_save(jsonb,bigint,uuid,text)',
    'public.addcust_finish(uuid,jsonb,jsonb)', 'public.addcust_entry()',
    'public._addcust_terms(smallint,uuid)', 'public._addcust_zone_for(jsonb)',
    'public._addcust_values_of(uuid)', 'public._addcust_slab_label(smallint)',
    'public._addcust_is_super()', 'public._addcust_deliv_label(text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

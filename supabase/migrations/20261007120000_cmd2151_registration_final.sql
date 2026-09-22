-- CMD #2151 — Registration + Add customer / Import, final (Om, 22 Sep 2026).
-- One General screen for both surfaces; only the mandatory set differs.
--  • Staff Add customer / Import: required = Pharmacy name + WhatsApp here and
--    the shop pin on Location (app_settings.addcust_rules.required). Owner and
--    email are optional for staff; the customer keeps signup's own list.
--  • Staff last step is "Invite"; payment term + delivery are hidden unless
--    addcust_rules.show_payment / show_delivery turn them on.
--  • Documents: no Skip anywhere (dont_have.show=false); the tag reads
--    Mandatory / Optional.
--  • Live contact check: the cleaned number (+91 / leading 0 dropped) comes
--    back as `value` with a "from → to · checked" note, and a taken card says
--    how Login opens (login_mode: otp for a number, google for an email).
--  • Reverse geocode v5: the pincode is the pin's OWN address first, never a
--    nearby landmark's result.
--  • An imported customer always opens General first, with the "filled from
--    your distributor" note.
-- Idempotent: copy is inserted or moved off its old default only; functions
-- are patched by text replace guarded on the new text being absent.

insert into public.ui_copy(key, value) values
  ('custreg.imported_note', to_jsonb('✓ Filled from your distributor — check and continue'::text)),
  ('custreg.v4_cleaned',    to_jsonb('{from} → {to} · checked'::text))
on conflict (key) do nothing;

update public.ui_copy set value = to_jsonb('Mandatory'::text), updated_at = now()
 where key = 'custreg.v4_needed' and value = to_jsonb('Needed'::text);
update public.ui_copy set value = to_jsonb('Invite'::text), updated_at = now()
 where key = 'addcust.terms_step' and value = to_jsonb('Terms'::text);
update public.ui_copy set value = to_jsonb('✓ Invite'::text), updated_at = now()
 where key = 'addcust.terms_done' and value = to_jsonb('✓ Terms'::text);
update public.ui_copy set value = to_jsonb('Invite'::text), updated_at = now()
 where key = 'addcust.terms_title' and value = to_jsonb('Terms for this customer'::text);
update public.ui_copy set value = to_jsonb(''::text), updated_at = now()
 where key = 'addcust.terms_sub' and value = to_jsonb('Customers never see this step.'::text);

insert into public.app_settings(key, value) values
  ('addcust_rules', jsonb_build_object(
     'required', jsonb_build_array('pharmacy_name', 'whatsapp_no', 'store_pin'),
     'show_payment', false, 'show_delivery', false))
on conflict (key) do nothing;

-- ── Staff schema: the same fields, staff's own required set ────────────────
create or replace function public._addcust_staff_schema(p_schema jsonb)
returns jsonb language sql stable security definer set search_path = public as $$
  with r as (
    select coalesce((select value->'required' from public.app_settings where key = 'addcust_rules'),
                    '["pharmacy_name","whatsapp_no","store_pin"]'::jsonb) as req)
  select coalesce(p_schema, '{}'::jsonb)
         || jsonb_build_object(
              'required_fields', (select req from r),
              'fields', (select coalesce(jsonb_agg(
                                  f || jsonb_build_object('required', (select req from r) ? (f->>'key'))
                                  order by o), '[]'::jsonb)
                           from jsonb_array_elements(coalesce(p_schema->'fields', '[]'::jsonb))
                                with ordinality t(f, o)))
$$;
revoke all on function public._addcust_staff_schema(jsonb) from public, anon;

do $$
declare d text;
begin
  select pg_get_functiondef('public.addcust_open'::regproc) into d;
  if position('_addcust_staff_schema' in d) = 0 then
    execute replace(d, 'v_schema := public.customer_form_schema(''signup'');',
                       'v_schema := public._addcust_staff_schema(public.customer_form_schema(''signup''));');
  end if;
end $$;

-- ── Invite step: payment term + delivery hidden unless turned on ───────────
create or replace function public._addcust_terms(p_zone smallint, p_customer_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_term text := 'Advance Payment'; v_del text := 'next_day';
  v_super boolean := public._addcust_is_super();
  v_active smallint := public.admin_active_zone();
  v_zone smallint := p_zone;
  v_zones jsonb;
  v_rules jsonb := coalesce((select value from public.app_settings where key = 'addcust_rules'), '{}'::jsonb);
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
                  'show', coalesce((v_rules->>'show_payment')::boolean, false),
                  'options', (select jsonb_agg(jsonb_build_object('value', t #>> '{}', 'label', public._addcust_term_label(t #>> '{}')))
                                from jsonb_array_elements(public.customer_form_options()->'payment_term') t)),
    'delivery', jsonb_build_object('label', public._c('addcust.delivery_label'), 'value', v_del,
                  'show', coalesce((v_rules->>'show_delivery')::boolean, false),
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
end $function$;

-- ── Documents: no Skip anywhere ────────────────────────────────────────────
do $$
declare d text;
begin
  select pg_get_functiondef('public.custreg_licences_block'::regproc) into d;
  if position('''show'',  (s.state in (''needed'',''skipped'',''rejected'')),' in d) > 0 then
    execute replace(d, '''show'',  (s.state in (''needed'',''skipped'',''rejected'')),',
                       '''show'',  false,');
  end if;
end $$;

-- ── Contact check: cleaned value + note, and how Login opens ───────────────
do $$
declare d text;
begin
  select pg_get_functiondef('public.custreg_contact_check(text, text, uuid)'::regprocedure) into d;
  if position('login_mode' in d) = 0 then
    d := replace(d,
      '''login_number'', case when v_kind = ''phone'' and not v_staff then v_n else '''' end));',
      '''login_number'', case when v_kind = ''phone'' and not v_staff then v_n else '''' end,'
      || chr(10) || '        ''login_mode'', case when v_staff then '''' when v_kind = ''phone'' then ''otp'' else ''google'' end),'
      || chr(10) || '      ''value'', v_n,'
      || chr(10) || '      ''note'', case when v_kind = ''phone'' and regexp_replace(v_raw, ''\D'', '''', ''g'') <> v_n'
      || chr(10) || '                  then public._cf(''custreg.v4_cleaned'', jsonb_build_object(''from'', v_raw, ''to'', v_n)) else '''' end);');
    d := replace(d,
      '''suffix'', public._c(''custreg.v4_ok''), ''tone'', ''success'', ''value'', v_n);',
      '''suffix'', public._c(''custreg.v4_ok''), ''tone'', ''success'', ''value'', v_n,'
      || chr(10) || '    ''note'', case when v_kind = ''phone'' and regexp_replace(v_raw, ''\D'', '''', ''g'') <> v_n'
      || chr(10) || '                then public._cf(''custreg.v4_cleaned'', jsonb_build_object(''from'', v_raw, ''to'', v_n)) else '''' end);');
    execute d;
  end if;
end $$;

-- ── Reverse geocode v5: the pin's own pincode first ────────────────────────
do $$
declare d text;
begin
  select pg_get_functiondef('public.geo_reverse_parse'::regproc) into d;
  if position('''parse'',        ''v5''' in d) = 0 then
    d := replace(d,
      '    select c->>''long_name'' into v_pin' || chr(10) ||
      '      from jsonb_array_elements(coalesce(p_body->''results'',''[]''::jsonb)) with ordinality t(res, o),',
      '    -- CMD #2151 — the pin''s OWN result first; then the first result that' || chr(10) ||
      '    -- is an address (not a landmark / POI); any result only as a last resort.' || chr(10) ||
      '    select c->>''long_name'' into v_pin' || chr(10) ||
      '      from jsonb_array_elements(coalesce(v_best->''address_components'',''[]''::jsonb)) c' || chr(10) ||
      '     where c->''types'' ? ''postal_code'' limit 1;' || chr(10) ||
      '    if v_pin is null then' || chr(10) ||
      '      select c->>''long_name'' into v_pin' || chr(10) ||
      '        from jsonb_array_elements(coalesce(p_body->''results'',''[]''::jsonb)) with ordinality t(res, o),' || chr(10) ||
      '             jsonb_array_elements(coalesce(res->''address_components'',''[]''::jsonb)) c' || chr(10) ||
      '       where c->''types'' ? ''postal_code''' || chr(10) ||
      '         and not (coalesce(res->''types'',''[]''::jsonb) ?| array[''establishment'',''point_of_interest'',''plus_code''])' || chr(10) ||
      '       order by o limit 1;' || chr(10) ||
      '    end if;' || chr(10) ||
      '    if v_pin is null then' || chr(10) ||
      '    select c->>''long_name'' into v_pin' || chr(10) ||
      '      from jsonb_array_elements(coalesce(p_body->''results'',''[]''::jsonb)) with ordinality t(res, o),');
    d := replace(d,
      '     where c->''types'' ? ''postal_code''' || chr(10) || '     order by o limit 1;' || chr(10) || '    v_addr',
      '     where c->''types'' ? ''postal_code''' || chr(10) || '     order by o limit 1;' || chr(10) || '    end if;' || chr(10) || '    v_addr');
    d := replace(d, '''parse'',        ''v4''', '''parse'',        ''v5''');
    execute d;
  end if;
  select pg_get_functiondef('public.geo_reverse'::regproc) into d;
  if position('''v5''' in d) = 0 then
    execute replace(d, 'v_out->>''parse'' = ''v4''', 'v_out->>''parse'' = ''v5''');
  end if;
end $$;

-- ── Imported customer: always General first ────────────────────────────────
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_payload'::regproc) into d;
  if position('case when v_imported then null else v_draft->>''_step'' end' in d) = 0 then
    execute replace(d, 'coalesce(v_stage, ''''), v_draft->>''_step'', v_pre,',
                       'coalesce(v_stage, ''''), case when v_imported then null else v_draft->>''_step'' end, v_pre,');
  end if;
end $$;

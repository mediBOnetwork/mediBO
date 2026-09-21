-- CMD #2133 — ships #2127's QA fix (commit df174a34, which #2127 could not deploy
-- itself: CMD #1975 refuses a second deploy of a live command).
--
-- A hand-made custreg_location_resolve(123, 500) answered ok:true and echoed the
-- point into values + store_location_link; customer_registration_submit cast
-- latitude/longitude to numeric with no range check. One predicate,
-- _custreg_coord_ok(key, text), now decides both: absent ok, latitude -90..90,
-- longitude -180..180, NaN / text / Infinity refused.
--
-- Both functions below are pg_get_functiondef of what was LIVE on 2026-09-21
-- (diffed: identical to #2127's bodies) plus ONLY the two guarded blocks, so
-- no later change to either function is reverted. Idempotent.

begin;

insert into public.ui_copy(key, value) values
  ('custreg.loc_invalid_point', to_jsonb('That point is not on the map — drag the pin onto your shop'::text))
on conflict (key) do nothing;

create or replace function public._custreg_coord_ok(p_key text, p_val text)
returns boolean
language plpgsql
immutable
set search_path to 'public'
as $function$
declare
  v numeric;
begin
  -- Absent is absent: an empty coordinate clears nothing and breaks nothing.
  if nullif(btrim(coalesce(p_val, '')), '') is null then
    return true;
  end if;
  begin
    v := btrim(p_val)::numeric;
  exception when others then
    return false;
  end;
  if v = 'NaN'::numeric then
    return false;
  end if;
  return case p_key
           when 'latitude'  then v between -90  and 90
           when 'longitude' then v between -180 and 180
           else true
         end;
end $function$;

revoke all on function public._custreg_coord_ok(text, text) from public, anon, authenticated;
grant execute on function public._custreg_coord_ok(text, text) to service_role;
CREATE OR REPLACE FUNCTION public.custreg_location_resolve(p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_values jsonb DEFAULT '{}'::jsonb, p_geocode boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_vals jsonb := coalesce(p_values, '{}'::jsonb);
  v_geo  jsonb := '{}'::jsonb;
  v_tmpl text;
  v_note text := '';
  v_tone text := 'neutral';
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;

  -- CMD #2127 QA — a pin off the globe is not a place. The map can never
  -- produce one, so only a hand-made call reaches this: it is refused with
  -- the backend's own sentence and NEVER echoed back into the form values.
  if not public._custreg_coord_ok('latitude',  p_lat::text)
     or not public._custreg_coord_ok('longitude', p_lng::text) then
    return jsonb_build_object('ok', false, 'error', 'invalid_point', 'tone', 'warning',
                              'message', public._c('custreg.loc_invalid_point'));
  end if;

  if p_lat is not null and p_lng is not null then
    v_vals := v_vals
           || jsonb_build_object('latitude',  round(p_lat, 6)::text,
                                 'longitude', round(p_lng, 6)::text);
    select nullif(btrim(coalesce(point_deeplink,'')),'') into v_tmpl
      from public.map_config order by id limit 1;
    if nullif(btrim(coalesce(v_tmpl,'')),'') is not null then
      v_vals := v_vals || jsonb_build_object('store_location_link',
                  replace(replace(v_tmpl, '{lat}', round(p_lat,6)::text),
                          '{lng}', round(p_lng,6)::text));
    end if;

    if coalesce(p_geocode, true) then
      begin v_geo := public.geo_reverse(p_lat, p_lng);
      exception when others then v_geo := jsonb_build_object('ok', false); end;
      if coalesce((v_geo->>'ok')::boolean, false) then
        -- The pin is the answer: what it reads REPLACES what was there, and
        -- Edit is how a shop disagrees with it.
        v_vals := v_vals || jsonb_strip_nulls(jsonb_build_object(
          'address',  nullif(btrim(coalesce(v_geo->>'address','')), ''),
          'landmark', nullif(btrim(coalesce(v_geo->>'landmark','')), ''),
          'city',     nullif(btrim(coalesce(v_geo->>'city','')), ''),
          'state',    nullif(btrim(coalesce(v_geo->>'state','')), ''),
          'district', nullif(btrim(coalesce(v_geo->>'district','')), ''),
          'pincode',  nullif(btrim(coalesce(v_geo->>'pincode','')), '')));
        v_note := public._c('custreg.loc_read_ok');
        v_tone := 'success';
      else
        v_note := public._c('custreg.loc_read_failed');
        v_tone := 'warning';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'ok',     true,
    'values', v_vals,
    'card',   public.custreg_location_card(v_vals),
    'note',   v_note,
    'tone',   v_tone,
    'source', coalesce(v_geo->>'source', 'edit'));
end $function$

;

CREATE OR REPLACE FUNCTION public.customer_registration_submit(p_values jsonb DEFAULT '{}'::jsonb, p_skips jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_cid uuid;
  v_sess jsonb;
  v_allowed text[] := array['pharmacy_name','customer_name','owner_name','phone','whatsapp_no',
                            'other_contact_no','email','address','address_local','city','district',
                            'state','pincode','gstin','gst_no','drug_license','dl_20b','dl_21b',
                            'dl_expiry','store_type','store_location_link','latitude','longitude',
                            'landmark'];
  v_key text; v_sets text[] := '{}'; v_rejected text[] := '{}';
  v_sub jsonb; v_skip text; v_zone smallint;
  v_missing text := ''; v_stage public.registration_stage;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' or p_values = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','no_values',
                              'message', public._c('custreg.err_no_values'));
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  if v_cid is null then
    -- New shop: the same guarded door every other registration kind uses. It
    -- sets user_id, status and approved itself and refuses a privilege key.
    v_sub := public.submit_registration('pharmacy', p_values - 'dl_expiry' - 'latitude' - 'longitude' - 'landmark');
    v_cid := nullif(v_sub->>'id','')::uuid;
    v_rejected := coalesce((select array_agg(x #>> '{}') from jsonb_array_elements(v_sub->'rejected_keys') x), '{}');
  end if;

  if v_cid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','save_failed',
                              'message', public._c('custreg.err_save'));
  end if;

  -- An imported shop already had a row: the form UPDATES it, and only the
  -- columns the form is allowed to write. Approval state is never among them.
  for v_key in select jsonb_object_keys(p_values) loop
    if v_key = any (v_allowed) then
      if v_key = 'dl_expiry' then
        v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::date', v_key, p_values->>v_key);
      elsif v_key in ('latitude','longitude') then
        -- CMD #2127 QA — only a coordinate ON the globe is stored. Anything
        -- else (off the map, not a number) is listed in rejected_keys like a
        -- key the form may not write, instead of failing the whole cast.
        if public._custreg_coord_ok(v_key, p_values->>v_key) then
          v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::numeric', v_key, p_values->>v_key);
        else
          v_rejected := v_rejected || v_key;
        end if;
      else
        v_sets := v_sets || format('%I = coalesce(nullif(btrim(%L),''''), %I)', v_key, p_values->>v_key, v_key);
      end if;
    else
      v_rejected := v_rejected || v_key;
    end if;
  end loop;

  if array_length(v_sets, 1) is not null then
    execute format('update public.pharmacy_profiles set %s, updated_at = now() where id = %L and user_id = %L',
                   array_to_string(v_sets, ', '), v_cid, v_uid);
    -- A brand-new row was just inserted by submit_registration under this
    -- user, so the user_id guard above always matches. An imported row whose
    -- identity was claimed at login matches too; anything else writes nothing.
  end if;

  select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;

  -- "I don't have this" — recorded on the document ledger with the ledger's
  -- own vocabulary, so every reader (the form, the admin page, the reminder
  -- ladder) sees one truth. It is NOT a submission: the paper is still owed.
  if p_skips is not null and jsonb_typeof(p_skips) = 'array' then
    for v_skip in select x #>> '{}' from jsonb_array_elements(p_skips) x loop
      continue when coalesce(btrim(v_skip),'') = '';
      continue when coalesce(public.custdoc_mode_for(v_zone, v_skip), 'off') = 'off';
      if not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = v_cid
                        and kd.kind = v_skip
                        and kd.status in ('pending','submitted','verified')) then
        insert into public.kyc_documents(owner_kind, owner_id, kind, bucket, path,
                                         status, submitted_by, submitted_at, source, zone_id)
        values ('pharmacy', v_cid, btrim(v_skip), 'kyc-docs', '',
                'not_available', v_uid, now(), 'app', v_zone);
      end if;
    end loop;
  end if;

  begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
  exception when others then v_missing := ''; end;

  -- The stage the account lands in. A starred paper still out is
  -- "documents" — Docs pending — and customer_approve_gate refuses from there.
  select registration_stage into v_stage from public.pharmacy_profiles where id = v_cid;
  if coalesce(v_stage::text,'') not in ('approved','verified') then
    update public.pharmacy_profiles
       set registration_stage = case when v_missing = '' then 'verified'::public.registration_stage
                                     else 'documents'::public.registration_stage end,
           updated_at = now()
     where id = v_cid;
  end if;

  begin perform public.customer_reg_draft_clear('signup'); exception when others then null; end;

  return jsonb_build_object(
    'ok', true, 'tone', case when v_missing = '' then 'success' else 'warning' end,
    'customer_id', v_cid,
    'message', case when v_missing = '' then public._c('custreg.saved_message')
                    else public._cf('custreg.pending_line', jsonb_build_object('docs', v_missing)) end,
    'docs_pending', (v_missing <> ''),
    'docs_missing', v_missing,
    'rejected_keys', to_jsonb(v_rejected),
    'payload', public.customer_registration_payload());
end $function$

;

revoke all on function public.custreg_location_resolve(numeric, numeric, jsonb, boolean) from public, anon;
grant execute on function public.custreg_location_resolve(numeric, numeric, jsonb, boolean) to authenticated, service_role;

commit;

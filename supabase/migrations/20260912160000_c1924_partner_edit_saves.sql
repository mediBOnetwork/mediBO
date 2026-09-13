-- CMD #1924 — the door was closed AND the room was locked.
--
-- The spec asks for two things: make the Payment and Partner screen reachable
-- again, and CONFIRM every field saves. Restoring the door (the sibling
-- migration) proved the second half was broken: a partner can be created once
-- and then never edited again.
--
-- WHY. save_region_partner() writes with `insert ... on conflict (district) do
-- update`. Postgres fires BEFORE INSERT triggers on the PROPOSED row before it
-- detects the conflict, so _kyc_identity_guard() runs with tg_op='INSERT':
-- OLD is not available, so v_old_dl is NULL, the guard reads an unchanged
-- drug licence as "a change", and kyc_identity_conflict() is asked to exclude
-- `new.id` — a fresh sequence value, never the id of the row the upsert is
-- about to update. The existing row therefore collides with ITSELF:
--   ERROR: This drug licence number is already registered to <that same partner>
--   DETAIL: duplicate_dl   HINT: kyc_identity: partner/3
-- Reproduced on the build branch (whose save_region_partner and
-- _kyc_identity_guard are byte-identical to production, md5 1c661b09… /
-- 08430643…): the first save returns ok:true, and editing the address with the
-- licence untouched is refused. Om would have found the restored screen and
-- been unable to change a single field on any partner that carries a DL or a
-- GSTIN — which is every real one.
--
-- THE FIX. Say what is meant: UPDATE an existing district, INSERT a new one.
-- The guard then sees tg_op='UPDATE' with real OLD values and judges only an
-- actual change of identity number, which is what its own comment says it is
-- for. Nothing else moves — the admin check, the copy keys, the zone-scoped
-- deactivation, the is_active rule and the returned payload are unchanged, and
-- a genuine duplicate licence is still refused, by the same guard.
--
-- Idempotent: create or replace. Safe to replay.

create or replace function public.save_region_partner(
  p_area text, p_partner_name text, p_address text default null::text,
  p_gstin text default null::text, p_dl_20b text default null::text,
  p_dl_21b text default null::text, p_state text default null::text,
  p_make_active boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_d text; v_id bigint; v_first boolean; v_zone bigint; v_exists boolean;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized','message',public.partner_msg('not_authorized'));
  end if;
  v_d := public.norm_district(p_area);
  if v_d is null then
    return jsonb_build_object('ok',false,'error','area_required','message',public.partner_msg('area_required'));
  end if;
  if coalesce(btrim(p_partner_name),'') = '' then
    return jsonb_build_object('ok',false,'error','name_required','message',public.partner_msg('name_required'));
  end if;

  v_zone := public.zone_for_area(v_d);
  v_first := not exists (select 1 from region_partners);
  -- activation is scoped to the SAME zone only
  if coalesce(p_make_active,false) or v_first then
    update region_partners set is_active = false
     where is_active and district <> v_d and zone_id is not distinct from v_zone;
  end if;

  select true into v_exists from region_partners where district = v_d limit 1;

  if coalesce(v_exists,false) then
    -- The edit path. tg_op='UPDATE' gives _kyc_identity_guard the OLD row, so
    -- an untouched licence or GSTIN is not judged as a new number.
    update region_partners set
      partner_name = btrim(p_partner_name),
      address      = nullif(btrim(coalesce(p_address,'')),''),
      gstin        = nullif(btrim(coalesce(p_gstin,'')),''),
      dl_20b       = nullif(btrim(coalesce(p_dl_20b,'')),''),
      dl_21b       = nullif(btrim(coalesce(p_dl_21b,'')),''),
      state        = coalesce(nullif(btrim(coalesce(p_state,'')),''),'Chhattisgarh'),
      zone_id      = v_zone,
      is_active    = case when coalesce(p_make_active,false) then true else region_partners.is_active end
    where district = v_d
    returning id into v_id;
  else
    insert into region_partners (district, partner_name, address, gstin, dl_20b, dl_21b, state, is_active, zone_id)
    values (v_d, btrim(p_partner_name), nullif(btrim(coalesce(p_address,'')),''),
            nullif(btrim(coalesce(p_gstin,'')),''), nullif(btrim(coalesce(p_dl_20b,'')),''),
            nullif(btrim(coalesce(p_dl_21b,'')),''),
            coalesce(nullif(btrim(coalesce(p_state,'')),''),'Chhattisgarh'),
            (coalesce(p_make_active,false) or v_first), v_zone)
    returning id into v_id;
  end if;

  return jsonb_build_object('ok',true,'id',v_id,'area',v_d,'message',public.partner_msg('saved'));
end $function$;

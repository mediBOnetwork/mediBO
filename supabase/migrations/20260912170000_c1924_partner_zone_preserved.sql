-- CMD #1924 (hostile QA round 1, blocker) — an edit must never cost a partner
-- its zone.
--
-- The sibling migration made save_region_partner() take an UPDATE path for an
-- existing district, which is what finally lets Om edit a partner. That UPDATE
-- was written to set every column the screen sends, zone_id included:
--     zone_id = v_zone          -- v_zone := zone_for_area(v_d)
-- and zone_for_area() is an EXACT name match:
--     select id from zones where lower(name) = lower(norm_district(p_area))
-- Production's zones are named 'Raipur Zone' and 'Bilaspur Zone'; the districts
-- on region_partners — and all three options partner_screen_config() offers in
-- the picker ('Raipur', 'Bilaspur', 'Durg') — are the bare city names. Every one
-- of them resolves to NULL. So the first save on either live partner (id 1 zone
-- 1, id 22 zone 2) would have written zone_id = NULL.
--
-- That is not cosmetic. _c694_zone_owner(), _thread_zone_partner() and
-- _partner_for_event() all find the partner with `rp.zone_id = p_zone and
-- rp.is_active`, so a zone-less partner stops owning its zone, stops receiving
-- partner threads and stops being the recipient of partner events; the
-- UNIQUE(zone_id) WHERE is_active index stops constraining, because NULLs do
-- not collide; and nothing backfills it — trg_region_partners_touch only
-- stamps updated_at. The value is derived from a lookup that cannot find it
-- again, so the loss is permanent and silent.
--
-- It was unreachable until now (the old upsert threw on the KYC guard for any
-- partner carrying a DL or GSTIN, which is both of them), which is exactly why
-- it has to be closed in the command that opens the door.
--
-- THE FIX, one word: coalesce. A zone the lookup CAN resolve still moves the
-- partner — renaming a zone to match its district makes the edit adopt it — and
-- a lookup that comes back empty leaves the stored zone exactly as it was.
-- Everything else in the function is untouched.
--
-- The INSERT path is deliberately left alone: a brand-new district has no
-- stored zone to preserve, and giving it a guessed one would be a product
-- decision this command was told not to make ("do not change the screen").
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
      -- an unresolvable area keeps the zone this partner already has
      zone_id      = coalesce(v_zone, region_partners.zone_id),
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

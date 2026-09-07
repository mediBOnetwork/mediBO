-- CHANGE #1888 (follow-up) — the pincode fallback was never asked for.
--
-- Measured on live after the first pass: 5 shops still carried no pin. The
-- geocoder answered "no match" for every one of their addresses ("abcd,
-- Raigarh", "Test Counter, Civil Lines", a village string with no house) —
-- which is the correct answer for a junk address. But two of those shops
-- (pincode 495001 and 202393) then had NOTHING left to try: geo_geocode only
-- ever queued the full address, so a pincode the lookup table does not hold
-- was never asked about, the district was never learned, and the shop stayed
-- pinless forever.
--
-- The centroid fallback the header of section 3 already promises is now
-- actually requested: when the pincode is a real 6-digit code and the lookup
-- does not hold it, the bare pincode is queued alongside the address. The
-- answer fills geo_pincode, so it costs one network call per pincode for the
-- whole town, not one per shop — and the address stays queued too, so a shop
-- whose address DOES resolve still gets its own doorstep rather than the
-- middle of the postal area.
--
-- Idempotent: safe to replay on live.

create or replace function public.geo_geocode(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pin  text := nullif(regexp_replace(coalesce(p->>'pincode',''), '\D', '', 'g'), '');
  r      public.geo_pincode;
  v_q    text;
begin
  perform public.geo_collect();

  if v_pin ~ '^[0-9]{6}$' then
    r := public.geo_pincode_row(v_pin);
  end if;

  v_q := nullif(btrim(concat_ws(', ',
           nullif(btrim(coalesce(p->>'address','')),''),
           nullif(btrim(coalesce(p->>'city','')),''),
           nullif(btrim(coalesce(p->>'state','')),''),
           v_pin, 'India')), '');

  if r.lat is not null and r.lng is not null then
    -- Known pincode centroid. Still queue the full address so the pin lands on
    -- the shop rather than the middle of the postal area.
    if v_q is not null then perform public.geo_enqueue('address', v_q, p->>'ref_id'); end if;
    return jsonb_build_object(
      'ok', true, 'lat', r.lat, 'lng', r.lng,
      'district', r.district, 'state', r.state,
      'source', 'geocoded', 'via', 'pincode_centroid');
  end if;

  if v_q is not null then perform public.geo_enqueue('address', v_q, p->>'ref_id'); end if;

  -- The fallback, finally asked for: an unknown pincode is a question the
  -- geocoder can answer once for every shop that will ever carry it. Asked at
  -- most twice — 409221 is not a real Indian pincode and never will be, and a
  -- backfill that runs nightly must not ask about it nightly.
  if v_pin ~ '^[0-9]{6}$' and r.lat is null
     and (select count(*) from geo_lookup_queue q
           where q.query = v_pin || ', India' and q.status = 'error') < 2 then
    perform public.geo_enqueue('pincode', v_pin || ', India', p->>'ref_id');
  end if;

  return jsonb_build_object(
    'ok', false, 'lat', null, 'lng', null,
    'district', r.district, 'state', r.state,
    'source', null, 'via', 'queued');
end $function$;

grant execute on function public.geo_geocode(jsonb) to service_role;

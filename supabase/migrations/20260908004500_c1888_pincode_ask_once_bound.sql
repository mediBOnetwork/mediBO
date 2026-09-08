-- CHANGE #1888 (follow-up 2) — an unanswerable pincode must stop being asked.
--
-- Measured on live right after the fallback landed: 495001 -> Bilaspur and
-- 202393 -> Bulandshahr were learned first try, but '495002, India' came back
-- as a Kanpur street. That answer is a MATCH, so the queue row closed as
-- 'done' — and the "asked at most twice" guard only counted rows that closed
-- as 'error'. 495002 therefore stayed unlearned AND stayed askable: every
-- backfill from here to forever would fire one more Nominatim request that
-- cannot succeed. (The Kanpur reply did no damage — geo_collect files an
-- answer under the postcode the geocoder itself returned, 208012, never under
-- the pincode that was asked — so only the repeat is the bug.)
--
-- The bound now counts every CLOSED ask, whatever it closed as. A pincode the
-- geocoder can answer is answered on the first try; one it cannot is asked
-- twice and then left to the seed, which is what the lookup table is for.
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
  -- most twice — counting every ask that has CLOSED, not only the ones that
  -- closed red, because a wrong-but-matching answer closes green and would
  -- otherwise leave the question open for ever.
  if v_pin ~ '^[0-9]{6}$' and r.lat is null
     and (select count(*) from geo_lookup_queue q
           where q.query = v_pin || ', India'
             and q.status in ('error', 'done')) < 2 then
    perform public.geo_enqueue('pincode', v_pin || ', India', p->>'ref_id');
  end if;

  return jsonb_build_object(
    'ok', false, 'lat', null, 'lng', null,
    'district', r.district, 'state', r.state,
    'source', null, 'via', 'queued');
end $function$;

grant execute on function public.geo_geocode(jsonb) to service_role;

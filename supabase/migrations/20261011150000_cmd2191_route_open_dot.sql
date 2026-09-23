-- CMD #2191 (Om, mid-build) — NO DART DECISION MAY TURN ON AN ENGLISH WORD.
--
-- Om asked for a grep of every literal the pill could print. It came back with
-- exactly one hit in the whole app: the rep route card coloured its open/closed
-- dot with `openLabel == 'Open now'`. The pill itself never printed it — but
-- that comparison made an English string a contract between
-- _lead_plan_route_core() and a Dart `==`, so rewording 'Open now' (or ever
-- translating it) would silently have turned every dot grey.
--
-- The colour becomes what it always should have been: a field. Same two
-- values, authored in the backend. Idempotent — CREATE OR REPLACE of the one
-- function, additive key only, every other line byte-identical to live.
CREATE OR REPLACE FUNCTION public._lead_plan_route_core(p_zone_id bigint, p_top_n integer, p_start_lat double precision, p_start_lng double precision, p_min_score integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  h lead_hub%ROWTYPE;
  cur_lat double precision; cur_lng double precision;
  nxt record; seq int := 0; total_km numeric := 0;
  legs jsonb := '[]'::jsonb; done bigint[] := '{}';
  ph text; today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  SELECT * INTO h FROM lead_hub WHERE id = 1;
  cur_lat := COALESCE(p_start_lat, h.lat);
  cur_lng := COALESCE(p_start_lng, h.lng);

  LOOP
    EXIT WHEN seq >= p_top_n;
    SELECT s.*, _km(cur_lat, cur_lng, s.lat, s.lng) AS leg_km
      INTO nxt
    FROM scraped_leads s
    WHERE s.zone_id = p_zone_id
      AND NOT (s.id = ANY(done))
      AND s.lat IS NOT NULL
      AND COALESCE(s.lead_score,0) >= GREATEST(p_min_score,1)
      -- rep already settled these — never route to them again
      AND COALESCE(s.last_visit_status,'') NOT IN
          ('not_interested','permanently_closed','converted')
      -- closed today / revisit-later: hidden until the date comes round
      AND (s.revisit_after IS NULL OR s.revisit_after <= today)
    ORDER BY _km(cur_lat, cur_lng, s.lat, s.lng)
    LIMIT 1;
    EXIT WHEN NOT FOUND;

    seq := seq + 1; done := done || nxt.id;
    total_km := total_km + round(nxt.leg_km::numeric,2);
    cur_lat := nxt.lat; cur_lng := nxt.lng;
    ph := _phone10(nxt.phone);

    legs := legs || jsonb_build_object(
      'seq', seq, 'lead_id', nxt.id, 'name', nxt.name, 'photo_url', nxt.photo_url,
      'score', nxt.lead_score, 'score_label', nxt.lead_score::text || '/100',
      'band', CASE WHEN nxt.lead_score >= 80 THEN 'hot'
                   WHEN nxt.lead_score >= 60 THEN 'warm' ELSE 'cold' END,
      'address_line', COALESCE(NULLIF(concat_ws(', ', nxt.area, nxt.locality), ''), nxt.address),
      'pincode', nxt.pincode, 'phone', nxt.phone,
      'call_link', CASE WHEN ph IS NOT NULL THEN 'tel:+91' || ph END,
      'wa_link',   CASE WHEN ph IS NOT NULL THEN 'https://wa.me/91' || ph END,
      'email', nxt.emails[1],
      'open_label', CASE WHEN nxt.open_now IS TRUE THEN 'Open now'
                         WHEN nxt.open_now IS FALSE THEN 'Closed' END,
      -- CMD #2191 (Om) — the DOT's colour, so the app never decides a colour by
      -- comparing a label to an English word. The card drew its dot green when
      -- open_label happened to equal 'Open now', which made that string a
      -- silent contract between this function and a Dart `==`: rewording it
      -- (or translating it) would have turned every dot grey. Same two
      -- colours as before, now authored here.
      'open_dot',   CASE WHEN nxt.open_now IS TRUE THEN '#16A34A'
                         WHEN nxt.open_now IS FALSE THEN '#9CA3AF' END,
      'today_hours', NULLIF(regexp_replace(COALESCE(nxt.hours_text[1],''), '^[A-Za-z]+:\s*', ''), ''),
      'branch_label', CASE WHEN nxt.same_phone_count > 1
                           THEN nxt.same_phone_count::text || ' shops share this number' END,
      'stale_label', _stale_label(nxt.last_review_age),
      'pin_label',   CASE WHEN nxt.pin_corrected THEN 'Pin corrected by rep' END,
      'visit_label', CASE WHEN nxt.visit_count > 0
                          THEN 'Visited ' || nxt.visit_count || 'x · last: ' || nxt.last_visit_status END,
      'leg_label', round(nxt.leg_km::numeric,1)::text || ' km',
      'cum_label', total_km::text || ' km so far',
      'maps_link', COALESCE(nxt.maps_uri, 'https://www.google.com/maps?q=' || nxt.lat || ',' || nxt.lng),
      'nav_link', 'https://www.google.com/maps/dir/?api=1&travelmode=driving&destination='
                    || nxt.lat || ',' || nxt.lng,
      'lat', nxt.lat, 'lng', nxt.lng
    );
  END LOOP;

  RETURN jsonb_build_object(
    'zone_id', p_zone_id, 'zone', (SELECT name FROM lead_zones WHERE id = p_zone_id),
    'stops', seq, 'stops_label', seq::text || ' stops',
    'total_km', total_km, 'total_label', total_km::text || ' km total',
    'min_score', p_min_score, 'start_label', 'Start: ' || h.name,
    'empty_label', CASE WHEN seq = 0
      THEN 'Nothing left to visit in this zone at score ' || p_min_score || '+.' END,
    'maps_links', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label','Open stops ' || (grp*10+1) || '–' || least((grp+1)*10, seq) || ' in Maps',
               'url', url) ORDER BY grp), '[]'::jsonb)
      FROM (SELECT ((l->>'seq')::int - 1)/10 AS grp,
                   'https://www.google.com/maps/dir/?api=1&travelmode=driving&waypoints='
                   || string_agg((l->>'lat')||','||(l->>'lng'), '|' ORDER BY (l->>'seq')::int) AS url
            FROM jsonb_array_elements(legs) l GROUP BY ((l->>'seq')::int - 1)/10) q),
    'route', legs
  );
END;
$function$;

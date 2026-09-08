-- CHANGE #280 (c) — never advertise a category on one mis-tagged row.
--
-- The area→sentence map is only as true as the area tag on the commands in the
-- release. #279 was a Google sign-in fix tagged area='fulfillment', and the
-- generator dutifully produced "• Better order packing and receiving, so orders
-- leave sooner." for a release that changed nothing of the sort. That sentence
-- would have gone onto a public Play listing.
--
-- So a category line now needs enough evidence to stand behind it: at least two
-- completed commands in that area for this release. A thinner release gets the
-- neutral default, which is true of every build. The lines themselves are also
-- softened from promises ("so orders leave sooner") to statements about what
-- changed — a claim we can always support.
--
-- Om can still write anything he likes in the notes box; this is the floor for
-- what ships unattended.

update play_notes_area set line = 'Storefront updates — product pages, search and cart.'
  where area = 'storefront';
update play_notes_area set line = 'Supplier availability updates.'
  where area = 'inquiry';
update play_notes_area set line = 'Supplier quoting and stock-update improvements.'
  where area = 'supplier';
update play_notes_area set line = 'Order packing and receiving improvements.'
  where area = 'fulfillment';
update play_notes_area set line = 'Delivery tracking and proof-of-delivery improvements.'
  where area = 'delivery';
update play_notes_area set line = 'Billing and payment screen improvements.'
  where area = 'billing';
update play_notes_area set line = 'Sign-in improvements, including Google sign-in.'
  where area = 'auth';
update play_notes_area set line = 'Speed and reliability improvements throughout the app.'
  where area in ('infra','devops');

create or replace function play_notes_generate(p_since_code int default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE
  v_since   timestamptz;
  v_rows    jsonb := '[]'::jsonb;
  v_lines   text[] := '{}';
  v_text    text;
  v_default text;
  r         record;
  -- How many commands an area needs before its sentence is allowed to ship.
  k_min_per_area constant int := 2;
BEGIN
  PERFORM _dev_guard();

  SELECT max(finished_at) INTO v_since
    FROM play_release
   WHERE status = 'submitted'
     AND (p_since_code IS NULL OR version_code <= p_since_code);
  IF v_since IS NULL THEN
    SELECT max(released_at) INTO v_since FROM app_releases WHERE platform = 'android';
  END IF;
  v_since := coalesce(v_since, now() - interval '14 days');

  SELECT line INTO v_default FROM play_notes_area WHERE area = '_default';

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'area', d.area,
                                               'title', d.title)
                            ORDER BY d.finished_at DESC), '[]'::jsonb)
    INTO v_rows
    FROM dev_commands d
   WHERE d.status = 'completed' AND d.finished_at > v_since
     AND coalesce(d.kind,'dev') <> 'gcp';

  FOR r IN
    SELECT coalesce(a.line, v_default) AS line, coalesce(a.sort_order, 99) AS sort_order
      FROM (SELECT coalesce(area,'infra') AS area, count(*) AS n
              FROM dev_commands
             WHERE status = 'completed' AND finished_at > v_since
               AND coalesce(kind,'dev') <> 'gcp'
             GROUP BY 1
            HAVING count(*) >= k_min_per_area) ch
      LEFT JOIN play_notes_area a ON a.area = ch.area
     GROUP BY 1, 2
     ORDER BY 2
  LOOP
    IF NOT (r.line = ANY(v_lines)) THEN v_lines := v_lines || r.line; END IF;
    EXIT WHEN array_length(v_lines,1) >= 5;
  END LOOP;

  -- Nothing cleared the evidence bar → say the one thing that is always true.
  IF array_length(v_lines,1) IS NULL THEN v_lines := ARRAY[v_default]; END IF;

  v_text := '• ' || array_to_string(v_lines, E'\n• ');
  WHILE length(v_text) > 500 AND array_length(v_lines,1) > 1 LOOP
    v_lines := v_lines[1:array_length(v_lines,1)-1];
    v_text  := '• ' || array_to_string(v_lines, E'\n• ');
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'notes', left(v_text,500),
                            'since', v_since, 'source', v_rows);
END $$;

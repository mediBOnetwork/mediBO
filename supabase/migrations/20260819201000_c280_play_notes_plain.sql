-- CHANGE #280 (b) — release notes in plain CUSTOMER language.
--
-- The first cut composed the notes from dev_commands.title, and the very first
-- generated line read "• Fix 16 KB page-size alignment + restore all 3 ABIs,
-- rebuild 1". That is a builder's sentence, truncated by the title deriver, and
-- it would have shipped verbatim onto a public Play listing. plain_summary is
-- empty on every completed row, so there is no plain text to lift.
--
-- So the notes are composed from what a PHARMACY would notice: which AREAS of
-- the app changed since the last release, each mapped to one sentence a
-- customer can read. The mapping is a table — new wording is an UPDATE, not a
-- deploy. Command-level detail still rides along in notes_source for the audit
-- trail, and Om can overwrite the whole body from the screen before publishing.

create table if not exists play_notes_area (
  area       text primary key,
  line       text not null,
  sort_order int  not null default 100,
  updated_at timestamptz not null default now()
);

insert into play_notes_area(area, line, sort_order) values
  ('storefront',  'Faster, clearer browsing — product pages, search and cart.',            10),
  ('inquiry',     'Quicker answers on what your suppliers have in stock.',                 20),
  ('supplier',    'Smoother supplier quoting and stock updates.',                          30),
  ('fulfillment', 'Better order packing and receiving, so orders leave sooner.',           40),
  ('delivery',    'Clearer delivery tracking and proof of delivery.',                      50),
  ('billing',     'Clearer bills, payments and pending-amount screens.',                   60),
  ('auth',        'Sign-in fixes, including Google sign-in on this app.',                  70),
  ('infra',       'Speed and reliability improvements throughout the app.',                80),
  ('devops',      'Speed and reliability improvements throughout the app.',                80),
  ('_default',    'Speed and stability improvements across the app.',                      99)
on conflict (area) do nothing;

create or replace function play_notes_generate(p_since_code int default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE
  v_since timestamptz;
  v_rows  jsonb := '[]'::jsonb;
  v_lines text[] := '{}';
  v_text  text;
  r       record;
BEGIN
  PERFORM _dev_guard();

  -- "This release" = everything completed since the last version Play took.
  SELECT max(finished_at) INTO v_since
    FROM play_release
   WHERE status = 'submitted'
     AND (p_since_code IS NULL OR version_code <= p_since_code);
  IF v_since IS NULL THEN
    SELECT max(released_at) INTO v_since FROM app_releases WHERE platform = 'android';
  END IF;
  -- A brand-new install of this feature has no history to measure against; a
  -- 14-day window is the honest default rather than "nothing changed".
  v_since := coalesce(v_since, now() - interval '14 days');

  -- The audit trail keeps the real commands, jargon and all.
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'area', d.area,
                                               'title', d.title)
                            ORDER BY d.finished_at DESC), '[]'::jsonb)
    INTO v_rows
    FROM dev_commands d
   WHERE d.status='completed' AND d.finished_at > v_since
     AND coalesce(d.kind,'dev') <> 'gcp';

  -- The customer-facing body: one line per area that actually changed.
  FOR r IN
    SELECT coalesce(a.line, (SELECT line FROM play_notes_area WHERE area='_default')) AS line,
           coalesce(a.sort_order, 99) AS sort_order
      FROM (SELECT DISTINCT coalesce(area,'infra') AS area
              FROM dev_commands
             WHERE status='completed' AND finished_at > v_since
               AND coalesce(kind,'dev') <> 'gcp') ch
      LEFT JOIN play_notes_area a ON a.area = ch.area
     GROUP BY 1,2
     ORDER BY 2
  LOOP
    IF NOT (r.line = ANY(v_lines)) THEN v_lines := v_lines || r.line; END IF;
    EXIT WHEN array_length(v_lines,1) >= 5;
  END LOOP;

  IF array_length(v_lines,1) IS NULL THEN
    v_lines := ARRAY[(SELECT line FROM play_notes_area WHERE area='_default')];
  END IF;

  v_text := '• ' || array_to_string(v_lines, E'\n• ');
  -- Play's release-notes body caps at 500 characters; drop whole lines rather
  -- than shipping a sentence cut in half.
  WHILE length(v_text) > 500 AND array_length(v_lines,1) > 1 LOOP
    v_lines := v_lines[1:array_length(v_lines,1)-1];
    v_text  := '• ' || array_to_string(v_lines, E'\n• ');
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'notes', left(v_text,500),
                            'since', v_since, 'source', v_rows);
END $$;

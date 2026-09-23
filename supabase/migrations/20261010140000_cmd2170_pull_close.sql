-- CMD #2170 — "Pull down to close on every screen + close back into the card".
--
-- WHY THIS IS A MIGRATION AND NOT A HANDFUL OF DART CONSTANTS
-- The whole gesture is a set of ANSWERS: how far is far enough (120 dp), how
-- fast is a flick (700 dp/s), how long the spring back takes (200 ms), how long
-- the close takes (250 ms), how round the page's top corners get while it
-- follows the finger (24 dp), how dark the screen behind goes, which routes may
-- be closed this way at all, and which tab roots pull back to Home instead.
-- Every one of those is the backend's to decide, so they all live in the ONE
-- design token block the app already boots with (`ui_boot().design`), beside
-- colours, radii and motion. Re-tuning the gesture is an UPDATE, not a deploy:
--
--   select ui_design_set('{"pull_close":{"threshold_dp":90}}'::jsonb);
--
-- The Dart side (Ds.pullClose) carries the same numbers ONLY as the values the
-- first frame uses before the payload lands.
--
-- WHY A DENY LIST AND NOT AN ALLOW LIST
-- The spec says "every customer screen", and naming them one by one means the
-- next customer screen someone adds silently misses the gesture. So the rule is
-- inverted: every pushed page participates EXCEPT the prefixes named here (the
-- staff/admin surfaces and the two auth pages, which keep the platform
-- transition they have always had). Adding a screen needs no change; carving
-- one out is one UPDATE.
--
-- Idempotent: the row is created if it is missing, and an existing
-- `pull_close` object WINS over these defaults, so replaying this file can
-- never undo a tuning someone made afterwards.

DO $$
DECLARE
  v_defaults jsonb := jsonb_build_object(
    -- Master switch. false → every route keeps the platform transition.
    'enabled',        true,
    -- The gesture (all in logical pixels / dp).
    'threshold_dp',   120,     -- past this the page closes
    'fling_dps',      700,     -- …or at this downward speed, however short
    'slop_dp',        8,       -- claimed from the list after this much pull
    'follow',         1.0,     -- 1.0 = the page tracks the finger exactly
    -- The look while it follows the finger.
    'corner_dp',      24,      -- top corners round off as the page leaves
    'scale_min',      0.92,    -- the page shrinks a little as it goes
    'scrim',          '#000000',
    'scrim_opacity',  0.45,    -- the dim layer over the screen behind, at rest
    -- The two timings the spec names.
    'spring_ms',      200,     -- a short pull springs back
    'close_ms',       250,     -- a committed close (and every push) takes this
    -- Tab roots: a pull on one of these goes to the Home tab instead of
    -- popping a route. 0 (Home) is deliberately absent — Home's pull is the
    -- refresh it already has.
    'home_index',     0,
    'tab_pages',      jsonb_build_array(1, 2, 12, 15),
    -- The staff/admin surfaces and the auth pages keep the platform default.
    'deny_prefixes',  jsonb_build_array(
                        '/admin', '/partner', '/supplier', '/staff', '/dev',
                        '/login', '/register', '/signup'),
    -- Read out by the gesture's Semantics node, verbatim.
    'hint',           'Pull down to close'
  );
  v_existing jsonb;
BEGIN
  SELECT coalesce(value, '{}'::jsonb) INTO v_existing
    FROM public.dev_runner_config WHERE key = 'ui_design';

  IF v_existing IS NULL THEN
    INSERT INTO public.dev_runner_config(key, value)
    VALUES ('ui_design', jsonb_build_object('pull_close', v_defaults))
    ON CONFLICT (key) DO NOTHING;
  ELSE
    UPDATE public.dev_runner_config
       SET value = jsonb_set(
             v_existing, '{pull_close}',
             -- defaults first, the live block second: anything already tuned
             -- keeps its value, anything new arrives.
             v_defaults || coalesce(v_existing->'pull_close', '{}'::jsonb))
     WHERE key = 'ui_design';
  END IF;
END $$;

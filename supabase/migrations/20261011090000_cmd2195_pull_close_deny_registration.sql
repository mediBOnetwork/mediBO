-- CMD #2195 — "App freezes on every screen": the deny list that never matched
-- the screen it was written for.
--
-- CMD #2170 put pull-to-close on every pushed page EXCEPT a named list of
-- prefixes, "the staff/admin surfaces and the two auth pages". The auth pages
-- it named are '/login', '/register' and '/signup'. The registration form's
-- real addresses are '/complete-registration' (lib/main.dart) and
-- '/customer/documents' (the same screen, scrolled to the papers), and
-- '/register' is a prefix of neither. So the gesture was live on the one
-- screen the list existed to keep it off — the long form, with the file
-- picker and the camera on it, which is exactly where the freeze was reported
-- most often.
--
-- The freeze itself is fixed in the recogniser (a pull that starts always
-- ends, even when Android never delivers the finger's release because another
-- activity took the window). This file is the other half: the rule the
-- backend wrote is made true, so a registration form is not driving the
-- navigator's user gesture at all.
--
-- Idempotent: prefixes already present are not duplicated, anything tuned
-- since is untouched, and replaying the file is a no-op.

DO $$
DECLARE
  v_add     text[] := ARRAY[
                        '/complete-registration',
                        '/customer/documents',
                        '/delivery-register'];
  v_cur     jsonb;
  v_deny    jsonb;
  v_p       text;
BEGIN
  SELECT value INTO v_cur
    FROM public.dev_runner_config WHERE key = 'ui_design';

  IF v_cur IS NULL THEN
    -- No token row yet: CMD #2170's own migration creates it with these
    -- prefixes included the next time it runs, so there is nothing to patch.
    RETURN;
  END IF;

  v_deny := coalesce(v_cur #> '{pull_close,deny_prefixes}', '[]'::jsonb);

  FOREACH v_p IN ARRAY v_add LOOP
    IF NOT (v_deny @> to_jsonb(v_p)) THEN
      v_deny := v_deny || to_jsonb(v_p);
    END IF;
  END LOOP;

  UPDATE public.dev_runner_config
     SET value = jsonb_set(
           jsonb_set(value, '{pull_close}',
                     coalesce(value->'pull_close', '{}'::jsonb), true),
           '{pull_close,deny_prefixes}', v_deny, true)
   WHERE key = 'ui_design';
END $$;

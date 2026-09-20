-- CMD #2116 — the bottom bar's action button is ONE rectangle, and the backend
-- owns how wide it is.
--
-- THE BUG
-- #2112 and #2114 put the update bar, the registration bar and the login bar
-- into one slot, drawn by one widget, so that "same position, same shape, same
-- size" would be a fact rather than a coincidence. It very nearly was: the one
-- thing still left to chance was the BUTTON, which sized itself to its own
-- label. `Continue` is longer than `Login`, so the registration bar drew a
-- wider, differently-placed box than the login bar did, and a visitor who saw
-- one and then the other saw the chrome jump.
--
-- Worse, it made a backend-owned string change the layout: rewording
-- `loginbar.cta` moved the button. A word is supposed to be free.
--
-- THE FIX, BACKEND SIDE
-- The width becomes a design token like every other measurement in the app:
-- `ui_design -> touch -> barActionWidth`, read through `ui_boot().design` into
-- `Ds.touch.barActionWidth`. The button is exactly that wide whatever it says,
-- and retuning it is `ui_design_set('{"touch":{"barActionWidth":N}}')` with no
-- deploy at all.
--
-- Idempotent: it seeds the row when there is none and patches only this one
-- key when there is, so it can be replayed on live as many times as the
-- replay ledger likes without disturbing any other token.

DO $$
DECLARE v jsonb;
BEGIN
  SELECT value INTO v FROM public.dev_runner_config WHERE key = 'ui_design';

  IF v IS NULL THEN
    INSERT INTO public.dev_runner_config (key, value)
    VALUES ('ui_design',
            jsonb_build_object(
              'version', 1,
              'touch', jsonb_build_object('barActionWidth', 120)))
    ON CONFLICT (key) DO NOTHING;
  ELSE
    -- Patch the one key. `touch` may not exist yet; coalesce keeps the merge
    -- from wiping a group that does.
    v := jsonb_set(
           v,
           '{touch}',
           coalesce(v -> 'touch', '{}'::jsonb)
             || jsonb_build_object('barActionWidth', 120),
           true);
    UPDATE public.dev_runner_config SET value = v WHERE key = 'ui_design';
  END IF;
END $$;

-- CHANGE #340 — the predictor was OVER-chaining, which is the same disease as
-- parking wearing the other mask.
--
-- #340's spec said the prediction rules were already shard-aware and only
-- needed verifying. Verifying them showed otherwise: after the shard, a cart
-- spec and a login spec STILL predicted an overlapping file set, so they would
-- still auto-chain and still run one after the other.
--
-- The cause was the matcher, not the rules: `pattern matches OR area matches`.
-- An area match alone contributed the rule's ENTIRE path list, so every
-- command tagged `storefront` claimed storefront_screen, product_detail_screen,
-- product_card, shell_sidebar and shell_mobile_chrome whether or not it went
-- near them. Every storefront command therefore intersected every other one and
-- the scheduler serialised work that does not conflict — the exact opposite of
-- #327's goal that "non-overlapping work keeps full parallelism".
--
-- The pattern IDENTIFIES the work; the area only SCOPES it. A rule with no
-- pattern is a pure-area rule and still fires on area alone.
--
-- Measured after this change:
--   cart spec  -> cart_screen, shell_cart_panel, cust_pay_panel
--   login spec -> shell_login_panel, signin_diag_screen
--   overlap    -> none, so they build in parallel
--   two cart specs -> identical set, so they still chain (correctness kept)
--
-- Leases are untouched and remain the last-resort correctness guard, exactly as
-- #327 requires: a prediction miss costs one lease refusal, while the
-- over-prediction cost every storefront build its parallelism.
create or replace function public.dev_cmd_predict_files(p_title text, p_spec text, p_area text default null)
returns text[] language plpgsql stable security definer set search_path to 'public' as $function$
DECLARE t text; v text[]; v_chars int;
BEGIN
  SELECT coalesce((value->'routing'->>'predict_spec_chars')::int, 600)
    INTO v_chars FROM dev_runner_config WHERE key='worker_pool';
  v_chars := coalesce(v_chars, 600);
  t := lower(coalesce(p_title,'') || ' ' || left(coalesce(p_spec,''), v_chars));
  SELECT coalesce(array_agg(DISTINCT p), '{}')
    INTO v
  FROM file_predict_rule r, unnest(r.paths) p
  WHERE r.active
    AND (
          (r.pattern IS NOT NULL AND t ~ r.pattern
             AND (r.area IS NULL OR r.area = p_area))
       OR (r.pattern IS NULL AND r.area IS NOT NULL AND r.area = p_area)
        );
  RETURN v;
END $function$;

-- CHANGE #340, correction — the first cut of this fix traded over-chaining for
-- lease collisions, which is the WORSE half of the trade.
--
-- 20260831170000 made a pattern rule fire only when
--   `t ~ r.pattern AND (r.area IS NULL OR r.area = p_area)`.
-- Hostile QA measured that over all 160 dev_commands rows: 72 commands that had
-- a prediction lost EVERY prediction. The reason is that `file_predict_rule.area`
-- is the RULE's own domain label ('supplier', 'delivery', …), not a filter on
-- the calling command's area — and 59 rows carry area NULL while others carry
-- areas no rule uses ('infra', 'inquiry'). So every one of the seven area-scoped
-- rules went silent for them: two supplier commands filed under 'inquiry' both
-- predicted {} , stopped chaining, and would have raced into a lease refusal on
-- lib/screens/supplier/%. #327 keeps leases as the last-resort guard precisely
-- because a prediction miss should be rare, not routine.
--
-- The right rule is the one the comment already claimed: THE PATTERN IDENTIFIES
-- THE WORK. It fires on its own, whatever area the command is filed under. A
-- rule with no pattern is a pure-area rule and fires on area alone (none exist
-- today; this is the contract for the first one that does).
--
-- Measured over all 160 rows, old (pattern OR area) vs this:
--   commands with a prediction : 125 -> 106   (the 19 dropped are area-label
--                                              false positives, e.g. #280
--                                              "Publish to Play", filed
--                                              storefront, predicting
--                                              product_card)
--   vs the broken cut          :  53 -> 106   (53 commands get their
--                                              predictions back)
--   cart spec / login spec     : still disjoint, so they still build in parallel
--   two cart specs             : identical set, so they still chain
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
          (r.pattern IS NOT NULL AND t ~ r.pattern)
       OR (r.pattern IS NULL AND r.area IS NOT NULL AND r.area = p_area)
        );
  RETURN v;
END $function$;

-- "product page" is the phrase four real storefront commands used for the PDP
-- (#160, #167, #168 wishlist) while the rule only knew "product detail"/"pdp".
-- Under area-triggering those matched by accident; under pattern-triggering the
-- vocabulary has to be in the rule, where it is visible and editable as data.
update file_predict_rule
   set pattern = '(\mstorefront\M|\mproduct card\M|\mpdp\M|\mproduct detail\M|\mproduct page\M|\msearch medicines\M)'
 where id = 5;

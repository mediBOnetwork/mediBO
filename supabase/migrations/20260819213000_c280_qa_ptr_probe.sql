-- CHANGE #280 (f) — give journey qa-274-57 something to assert against.
--
-- qa-274-57 ("no PTR reaches an anonymous storefront") has existed since #274
-- with `required=true` and NO runner: the probe reported "browser runner needs
-- 1 more run" forever, so every storefront command's completion gate was blocked
-- on a journey nothing could ever run. #280 hit that wall.
--
-- The assertion needs the live PTR values to search the anon payload for. This
-- is the read-only, runner-only door to them — never anon-readable, which is the
-- very property the journey is defending.
create or replace function qa_ptr_sample()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
BEGIN
  PERFORM _dev_guard();
  -- Formatted with inr_money(), because that is the exact token the app would
  -- print if a PTR ever reached a card — the journey searches for THAT string,
  -- not a rounded guess. (The first cut rounded in JavaScript and flagged
  -- ₹82.50 as a leaked "₹83", a false positive against a real selling price.)
  RETURN jsonb_build_object(
    'ok', true,
    'ptrs', coalesce((SELECT jsonb_agg(DISTINCT ptr) FROM medicine_pricing
                       WHERE ptr IS NOT NULL AND ptr > 0), '[]'::jsonb),
    'tokens', coalesce((SELECT jsonb_agg(DISTINCT inr_money(ptr)) FROM medicine_pricing
                         WHERE ptr IS NOT NULL AND ptr > 0), '[]'::jsonb));
END $$;

revoke all on function qa_ptr_sample() from anon, authenticated;

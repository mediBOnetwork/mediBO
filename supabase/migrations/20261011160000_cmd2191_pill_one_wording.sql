-- CMD #2191 (Om, mid-build) — ONE WORDING, AT EVERY WIDTH.
--
-- Om: "The header pill still shows text that is NOT in the backend. Right now
-- it renders 'Open now' as line 1. That string does not exist in app_settings
-- anywhere." … "the backend returns, for a signed-out visitor: 'Ordering is
-- open' / '11 hours left to order' / 'Register to order'. That is exactly what
-- must appear on screen, in that order, 3 seconds each."
--
-- He was right about the screen and right that no app_settings ROW holds it:
-- 'Open now' is the NARROW TIER's wording, which header_status_pill() picks
-- when the app reports a viewport below pill.copy.narrow.max_screen_w (369).
-- On his phone that is every visit, so the sentence he verified was never the
-- sentence he saw. It is backend copy, not a Dart literal — the grep is empty
-- either way — but it is still a second author of the pill's words, and the
-- tier only ever existed because the pill had a FIXED width and the long line
-- did not fit.
--
-- CMD #2191 removed that reason: the pill now hugs the line it is showing and
-- grows to style.max_w, so 'Ordering is open' / '11 hours left to order' /
-- 'Register to order' fit a 360 px phone with room to spare. The breakpoint
-- goes to 0, which is the tier's own OFF value (v_narrow is
-- `p_w < max_screen_w`, and no viewport is below 0), so every width gets the
-- full wording and the pill prints exactly one set of strings.
--
-- The narrow COPY stays exactly where it is. Nothing is dropped: restoring the
-- tier for a genuinely tiny screen is one UPDATE of this same number, never a
-- deploy — which is the whole point of the copy living in app_settings.
--
-- Idempotent: re-running re-asserts 0 and touches nothing else.

do $$
declare
  v_before int;
begin
  select (value->'narrow'->>'max_screen_w')::int
    into v_before
    from public.app_settings
   where key = 'pill.copy';

  if v_before is distinct from 0 then
    update public.app_settings
       set value = jsonb_set(value, '{narrow,max_screen_w}', '0'::jsonb, true)
     where key = 'pill.copy'
       and value ? 'narrow';
    raise notice 'cmd2191: pill narrow tier retired (max_screen_w % -> 0)', v_before;
  end if;
end $$;

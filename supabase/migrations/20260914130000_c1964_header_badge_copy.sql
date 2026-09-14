-- ─────────────────────────────────────────────────────────────────────────────
-- CMD #1964 — the header badge's copy, on the payload the app already polls
--
-- 20260914120000 put the isolation underneath test mode: with a session on, a
-- caller sees only synthetic rows, without one only real rows. The signal that
-- says WHICH world you are in was #573's full-width strip, which is mounted
-- above every route — and which a route that reflows can carry off the top.
-- The header cannot, so the badge goes there too (lib/widgets/test_mode_badge.dart).
--
-- The app renders and never decides, so the badge's word AND its long-press
-- line have to arrive on a payload rather than be written in Dart.
-- `test_session_banner()` already carries `badge`; this adds `badge_hint` next
-- to it, so the whole badge — whether it shows at all (`on`), what it says, and
-- what it explains — is one backend answer and re-wording it is an UPDATE.
--
-- The function is patched by REWRITING ITS OWN DEFINITION rather than by being
-- retyped here. #1848, #1851 and #1821 each added a key to this payload and the
-- next one will too; a full `create or replace` in this file would silently
-- revert whichever of them landed last. Idempotent: the patch is skipped once
-- the key is present, so a replay is a no-op.
-- ─────────────────────────────────────────────────────────────────────────────

do $mig$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'test_session_banner'
     and p.pronargs = 0;

  if v_src is null then
    raise notice 'c1964: test_session_banner() not present — nothing to patch';
    return;
  end if;

  if v_src ~ 'badge_hint' then
    raise notice 'c1964: test_session_banner() already carries badge_hint';
    return;
  end if;

  -- Anchored on the `badge` entry this payload has carried since #1821, so the
  -- new key lands beside it whatever else the object has grown.
  v_new := regexp_replace(
    v_src,
    '(''badge''\s*,\s*public\.uic\(\s*''test_mode\.badge''\s*,\s*''[^'']*''\s*\))',
    '\1, ''badge_hint'', public.uic(''test_mode.badge_hint'','''')',
    'g');

  if v_new = v_src then
    raise exception 'c1964: could not find the badge key in test_session_banner() — patch the payload by hand before replaying';
  end if;

  execute v_new;
end $mig$;

-- The hint was written in 20260914120000 for a row-level tooltip ("Synthetic
-- row — …"). It is the HEADER badge's line now, so it describes the session.
-- Guarded on the old default: a hint an admin has already re-worded is left
-- exactly as they left it.
update public.ui_copy
   set value = to_jsonb('Test mode is on — you are seeing test data only. Nothing here is real.'::text)
 where key = 'test_mode.badge_hint'
   and value = to_jsonb('Synthetic row — test mode only'::text);

insert into public.ui_copy(key, value) values
  ('test_mode.badge_hint',
   to_jsonb('Test mode is on — you are seeing test data only. Nothing here is real.'::text))
on conflict (key) do nothing;

-- CMD #1896 — qa-274-57 asserts a contract CHANGE #1895 deliberately retired.
--
-- The journey's job is unchanged and still worth having: an unentitled viewer
-- must never receive PTR, and must always be TOLD why the trade price is
-- hidden. What moved is WHERE that sentence lives. Before #1895 the card
-- itself carried it as `card_price.note` / `card_price.has_note`; #1895 took
-- the sentence off the card ("the sentence left the card. It is the sheet's
-- note now.") and left the very same string in `card_price.locked_note` and
-- `locked_prompt.note`, which is what the storefront card and the PDP sheet
-- both render today.
--
-- So the probe was reading a field the payload is no longer supposed to fill
-- and reporting "any card missing the locked note=true" on a payload that is
-- correct — a required storefront journey red for every command in the area,
-- for a reason no build could fix. Standing lesson 282: a 'missing' object may
-- have been removed on purpose by a later command.
--
-- The assertion is re-pointed at the fields that now carry the sentence. It is
-- not weakened: a card that carries neither locked_note nor locked_prompt.note
-- still fails, which is the leak-adjacent failure the journey exists to catch.
--
-- Spliced and marker-guarded like every other edit to this function
-- (the c290 pattern), and it is a NO-OP wherever dev_journey_probe is the
-- production stub — the replay runs on live, where the real probe does not
-- exist by design (#1803).

do $c1896p$
declare v_def text; v_new text; v_before text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';

  -- live carries the stub (it raises "must run on the build branch"); there is
  -- nothing to patch there and nothing to complain about.
  if v_def is null then return; end if;
  if position('qa-274-57' in v_def) = 0 then return; end if;
  if position('c1896-locked-note' in v_def) > 0 then return; end if;

  v_new := v_def;

  v_before := v_new;
  v_new := replace(v_new,
$a$           bool_or(coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
               and coalesce(card->'pricing'->'card_price'->>'note','') = ''),$a$,
$a$           -- c1896-locked-note: #1895 moved the sentence off the card body.
           -- The locked note now ships as card_price.locked_note (and as
           -- locked_prompt.note for the sheet); card_price.note is empty by
           -- design. Assert the sentence REACHES the viewer, wherever the
           -- payload chooses to carry it.
           bool_or(coalesce(card->'pricing'->'card_price'->>'locked_note','') = ''
               and coalesce(card->'pricing'->'locked_prompt'->>'note','') = ''),$a$);
  if v_new = v_before then raise exception 'c1896: qa-274-57 locked-note anchor moved'; end if;

  execute v_new;
end $c1896p$;

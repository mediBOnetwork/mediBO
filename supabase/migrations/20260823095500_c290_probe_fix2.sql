-- CHANGE #290 — qa-274-57 must aggregate to booleans, not to counts.
--
-- The strengthened probe read `count(*) filter (...)` into BOOLEAN variables.
-- That survives a clean payload only by accident: 0 and 1 are valid boolean
-- input, so `0 -> false` looked like it worked. Under the actual mutation every
-- one of the 562 cards leaks, the count is 562, and the assignment cast dies
-- with `invalid input syntax for type boolean: "562"` — the trial recorded
-- `not_applied` and the leak went unchallenged. A probe that crashes on the
-- exact input it exists to detect is worse than a weak one: it looks undecided
-- rather than red.
--
-- bool_or aggregates the counterexample directly and returns NULL on an empty
-- payload, which the existing `not coalesce(v_aN,true)` already treats as fail.
--
-- Found by the post-fix sweep, which is why the audit re-runs after
-- strengthening instead of trusting the edit.

do $c290g$
declare v_def text; v_new text; v_before text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';
  if v_def is null then raise exception 'c290: dev_journey_probe not found'; end if;
  if position('c290-bool-or' in v_def) > 0 then return; end if;

  v_before := v_def;
  v_new := replace(v_def,
$a$    select count(*),
           count(*) filter (where (card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           count(*) filter (where coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           count(*) filter (where coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
                              and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           count(*) filter (where coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;$a$,
$a$    -- c290-bool-or: aggregate the counterexample as a boolean. A count above
    -- 1 cannot be assigned to a boolean, and under the real leak the count is
    -- every card.
    select count(*),
           bool_or((card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           bool_or(coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           bool_or(coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
               and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           bool_or(coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;$a$);
  if v_new = v_before then raise exception 'c290: qa-274-57 aggregate anchor moved'; end if;

  execute v_new;
end $c290g$;

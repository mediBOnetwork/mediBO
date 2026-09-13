-- CMD #1953b — what the first pass on the real 372,454 rows taught us.
--
-- The extractor ran on live and the derived vocabulary said this out loud:
--
--   "Gastroesophageal reflux disease (acid reflux"   ← a trimmed ')'
--   "Hypertension (high blood pressure"              ← same
--   "20 ml" · "60 n" · "1 kg"                        ← pack text, not a use
--   "Paste"                                          ← a dosage form
--   "Indicated to support"                           ← prose, not a condition
--
-- A shopper would have read every one of those on the Use door, so the rules
-- are fixed here and the pass is re-planned. Everything still lives in
-- use_extract_rule / use_synonym / use_extract_config — this file edits DATA
-- and one function, and a later correction is an INSERT, not a deploy.
--
-- It also fixes the reason the ledger never moved on its own: cron_task's
-- default step_timeout_ms is 20 s, the whole tick is ONE transaction, and a
-- cancelled tick rolls back every batch it had done — so runs stayed at 0
-- forever. The task now gets a step timeout that fits a real batch and only
-- runs at night, which is when a full re-derive belongs.

-- ── the extractor, with parentheses handled ───────────────────────────────
create or replace function public.use_phrases(
  p_uses  text,
  p_split text[],
  p_strip text[],
  p_junk  text[],
  p_min_len int default 3,
  p_max_len int default 48)
returns text[]
language plpgsql
immutable
set search_path to 'public'
as $fn$
declare
  v_src text; v_parts text[]; v_part text; v_out text[] := '{}'; v_rx text; v_prev text;
begin
  if nullif(btrim(coalesce(p_uses,'')),'') is null then return '{}'; end if;

  v_src := lower(p_uses);
  foreach v_rx in array coalesce(p_split,'{}') loop
    v_src := regexp_replace(v_src, v_rx, E'\n', 'g');
  end loop;
  v_parts := string_to_array(v_src, E'\n');

  foreach v_part in array coalesce(v_parts,'{}') loop
    v_part := btrim(regexp_replace(v_part, '\s+', ' ', 'g'));

    -- A gloss in brackets is not a second condition, and half a bracket is
    -- not a word: "reflux disease (acid reflux)" is "reflux disease", and the
    -- split above can leave the opening half on its own.
    v_part := regexp_replace(v_part, '\s*\([^()]*\)\s*', ' ', 'g');
    if position('(' in v_part) > 0 then
      v_part := left(v_part, position('(' in v_part) - 1);
    end if;
    v_part := replace(v_part, ')', ' ');
    v_part := btrim(regexp_replace(v_part, '\s+', ' ', 'g'));
    v_part := btrim(v_part, ' .:-–—*[]"''');

    loop
      v_prev := v_part;
      foreach v_rx in array coalesce(p_strip,'{}') loop
        v_part := regexp_replace(v_part, v_rx, '');
      end loop;
      v_part := btrim(v_part, ' .:-–—*[]"''');
      exit when v_part = v_prev;
    end loop;
    v_part := btrim(regexp_replace(v_part, '\s+', ' ', 'g'));

    if v_part = '' then continue; end if;
    if length(v_part) < p_min_len or length(v_part) > p_max_len then continue; end if;
    continue when exists (select 1 from unnest(coalesce(p_junk,'{}')) j where v_part ~ j);

    if not (v_out @> array[v_part]) then v_out := v_out || v_part; end if;
  end loop;

  return v_out;
end $fn$;

-- ── the junk the catalogue actually contains ──────────────────────────────
insert into public.use_extract_rule(kind, pattern, ord, note) values
  ('junk', '^[0-9]+(\.[0-9]+)?\s*(ml|l|ltr|litre|mg|mcg|g|gm|kg|iu|n|s|no|nos|pcs|piece|pieces|unit|units|tab|tabs|cap|caps|%)$', 50,
           'pack text: 20 ml, 60 n, 1 kg'),
  ('junk', '^(paste|lotion|spray|soap|shampoo|sachet|granule|granules|oil|serum|patch|inhaler|liquid|emulsion|foam|balm|jelly|mouthwash|infusion|kit|device|refill|combo|sanitizer|wipes)$', 45,
           'a dosage form is not a use'),
  -- \y, not \b: Postgres regexes are POSIX AREs, where \b is a BACKSPACE and
  -- the rule silently matches nothing at all.
  ('junk', '^(indicated|recommended|advised|suggested|prescribed|intended)\y', 60,
           'prose that survived the prefix strip'),
  ('junk', '^(this|it|they|which|whose|that|these|those)\y', 65, null),
  ('junk', '^(adult|adults|child|children|infant|infants|male|female|men|women|patient|patients)$', 70,
           'who, not what'),
  ('junk', '^[^a-z]*$', 75, 'nothing a shopper can read')
on conflict (kind, pattern) do nothing;

-- the \b spellings from the first draft of this file never matched anything
delete from public.use_extract_rule where kind = 'junk' and pattern in (
  '^(indicated|recommended|advised|suggested|prescribed|intended)\b',
  '^(this|it|they|which|whose|that|these|those)\b');

insert into public.use_extract_rule(kind, pattern, ord, note) values
  ('strip', '^(is\s+)?(used|indicated)\s+(to|for|in)\s+(the\s+)?(treatment|management|prevention|relief)\s+of\s+', 6, null),
  ('strip', '^helps\s+(in|to|with)\s+', 75, null),
  ('strip', '^(short|long)\s*-?\s*term\s+(treatment|management)\s+of\s+', 12, null)
on conflict (kind, pattern) do nothing;

-- ── sizing, so the tick finishes inside its own step ──────────────────────
-- Measured on live: a 20,000-row scan batch is ~7 s, `decide` is ~19 s and an
-- apply batch is ~241 s, because MEDICINE carries 36 indexes and writing one
-- more column is not a HOT update. So the apply phase is night work, one
-- batch at a time, and the step timeout has to be able to hold one.
update public.use_extract_config set value = to_jsonb(12000) where key = 'batch_rows';
update public.use_extract_config set value = to_jsonb(25000) where key = 'budget_ms';

update public.cron_task
   set step_timeout_ms = 240000,
       night_only      = true,
       base_interval_s = 120,
       note = 'CMD #1953 — drains the MEDICINE.condition ledger one bounded batch at a time, at night. A full apply pass writes 3.7 lakh rows against 36 indexes, so it never runs in shop hours. Gated: nothing pending, no work.'
 where name = 'use_condition_backfill';

-- The rules changed, so the vocabulary derived from them is stale. Re-plan:
-- the ledger is rewritten and the next drain re-derives from scratch.
select public.use_condition_plan('full');

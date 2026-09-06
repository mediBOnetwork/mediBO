-- CMD #1835 — Product page "Supply record": the chip, and nothing after it.
--
-- The block printed a green chip ("100% fill rate") and then spelled the same
-- fact out again as a sentence: "Filled 4 of 4 asks · last 180 days". The
-- sentence is the chip in longhand, plus two numbers the buyer cannot act on
-- and a window they never chose — the same raw-tally exposure CMD #1826 took
-- out of the supply block. So the sentence goes, at the source: the wording is
-- deleted from app_settings and the field is deleted from the payload, rather
-- than left in the RPC for the page to skip.
--
-- What stays: the chip (label, tone) exactly as it was, `fill_rate.has`,
-- `fill_rate.label` and `fill_rate.tone` (product_compare's fill row reads
-- those three), and the cold-chain chip with its own note.
-- What goes: fill_rate.note, fill_rate.asks, fill_rate.filled, the fill-rate
-- chip's `note`, and the two config strings that only ever fed them
-- (fill_note_fmt, fill_low_asks — the latter fed a note on a block that emits
-- no chip at all, so it has never been on screen).
-- Idempotent: CREATE OR REPLACE plus a jsonb key subtraction.

create or replace function public.product_trust_strip(
  p_product_id bigint,
  p_cold_chain boolean default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_cfg    jsonb := coalesce((select value from app_settings where key='pdp_trust_config'), '{}'::jsonb);
  v_days   int  := coalesce((v_cfg->>'window_days')::int, 180);
  v_min    int  := coalesce((v_cfg->>'min_asks')::int, 3);
  v_good   int  := coalesce((v_cfg->>'good_pct')::int, 85);
  v_okp    int  := coalesce((v_cfg->>'ok_pct')::int, 60);
  v_asks   int  := 0;
  v_filled int  := 0;
  v_pct    int;
  v_tone   text;
  v_chips  jsonb := '[]'::jsonb;
  v_fill   jsonb;
  v_cold   jsonb;
  v_has_fill boolean := false;
  v_is_cold boolean := coalesce(p_cold_chain, false);
begin
  -- An "ask" is a resolved inquiry: the waterfall either found a supplier or
  -- ran out of them. A still-pending inquiry is not evidence either way and is
  -- excluded, so a busy day cannot drag the number down. The tallies decide
  -- the band and then stay here — they never reach the payload.
  select count(*),
         count(*) filter (where q.current_status = 'Available')
    into v_asks, v_filled
  from inquiry q
  where q.product_id = p_product_id
    and q.current_status in ('Available', 'No Supplier Available')
    and coalesce(q.batch_date, (q.created_at at time zone 'Asia/Kolkata')::date)
        >= (now() at time zone 'Asia/Kolkata')::date - v_days;

  v_has_fill := (v_asks >= v_min);

  if v_has_fill then
    v_pct  := round(v_filled * 100.0 / v_asks)::int;
    v_tone := case when v_pct >= v_good then 'success'
                   when v_pct >= v_okp  then 'warning'
                   else 'danger' end;
    v_fill := jsonb_build_object(
      'has',   true,
      'pct',   v_pct,
      'label', v_pct::text || '% ' || coalesce(v_cfg->>'fill_suffix','fill rate'),
      'tone',  v_tone);
    -- No `note`: the chip already says it, in three words instead of eight.
    v_chips := v_chips || jsonb_build_array(
      jsonb_build_object('key','fill_rate',
                         'label', v_fill->>'label',
                         'tone',  v_tone));
  else
    v_fill := jsonb_build_object(
      'has', false, 'pct', 0, 'label', '', 'tone', 'neutral');
  end if;

  if v_is_cold then
    v_cold := jsonb_build_object(
      'has',   true,
      'label', coalesce(v_cfg->>'cold_label','Cold chain'),
      'note',  coalesce(v_cfg->>'cold_note',''),
      'tone',  'info');
    v_chips := v_chips || jsonb_build_array(
      jsonb_build_object('key','cold_chain',
                         'label', v_cold->>'label',
                         'note',  v_cold->>'note',
                         'tone',  'info'));
  else
    v_cold := jsonb_build_object('has', false, 'label', '', 'note', '', 'tone', 'neutral');
  end if;

  return jsonb_build_object(
    'has',        (jsonb_array_length(v_chips) > 0),
    'title',      coalesce(v_cfg->>'title',''),
    'chips',      v_chips,
    'fill_rate',  v_fill,
    'cold_chain', v_cold);
end
$function$;

-- Grants: untouched on purpose. This is not a new RPC — CREATE OR REPLACE keeps
-- the existing ACL (PUBLIC/anon/authenticated/service_role execute), which is
-- what a signed-out storefront product page needs. Re-granting here would only
-- risk narrowing it.

-- The wording itself, deleted. Nothing can print a string that no longer exists.
update public.app_settings
   set value = value - 'fill_note_fmt' - 'fill_low_asks'
 where key = 'pdp_trust_config'
   and (value ? 'fill_note_fmt' or value ? 'fill_low_asks');

-- CHANGE #287 (Om, mid-build) — strip the trailing ".0" from MEDICINE.pack_qty.
--
-- The catalogue stores "10.0 tablets in 1 strip", "1.0 Injection in 1 vial",
-- "100.0 ml in 1 bottle". #287 prints that column VERBATIM on every storefront
-- card (the chip above the product name), so the wording had to be fixed in the
-- DATA, not in a formatter — a Dart-side trim would be the app deciding, and a
-- view-side trim would leave the stored value wrong for every other reader.
--
-- The pattern only strips a ".0" that is NOT followed by another digit, so
-- genuine decimals survive:
--     10.0 tablets in 1 strip  → 10 tablets in 1 strip
--     1.0 Injection in 1 vial  → 1 Injection in 1 vial
--     2.5 ml in 1 bottle       → unchanged
--     1.05 ml in 1 vial        → unchanged
--     10.00 ml in 1 bottle     → unchanged
--
-- 170,426 of 562,549 rows matched when this ran. ONE statement over the whole
-- table times out (and holds row locks long enough to make every concurrent
-- storefront read wait), so it is applied in id windows through
-- `_c287_pack_qty_strip(from, to)`, one transaction per window. The helper sets
-- its own statement_timeout because PostgREST's role timeout is 8s.
--
-- Idempotent by construction: the WHERE clause matches only rows that still
-- carry a trailing ".0", so a re-run is a no-op once the table is clean, and a
-- resumed worker can simply run it again.

create or replace function public._c287_pack_qty_strip(p_from bigint, p_to bigint)
returns integer
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '240s'
as $function$
declare v_n integer;
begin
  update "MEDICINE"
     set pack_qty = regexp_replace(pack_qty, '(\d+)\.0([^0-9]|$)', '\1\2', 'g')
   where id >= p_from and id < p_to
     and pack_qty ~ '\d+\.0([^0-9]|$)';
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

create or replace function public._c287_pack_qty_remaining()
returns integer
language sql
stable
security definer
set search_path to 'public'
set statement_timeout to '120s'
as $function$
  select count(*)::int from "MEDICINE" where pack_qty ~ '\d+\.0([^0-9]|$)';
$function$;

grant execute on function public._c287_pack_qty_strip(bigint, bigint) to service_role;
grant execute on function public._c287_pack_qty_remaining()          to service_role;

-- The sweep itself: 10,000-id windows across the catalogue's id range
-- (min 176025, max 744955). Each window is its own autonomous statement here;
-- the live run drove the same helper from the runner so each call committed on
-- its own and a lock timeout could be retried per window.
-- The guard matters on replay: a DO block is ONE transaction, so sweeping 57
-- windows again on an already-clean table would spend minutes proving there is
-- nothing to do. One count first, and the loop is skipped entirely.
do $sweep$
declare
  v_from bigint;
  v_max  bigint;
begin
  if public._c287_pack_qty_remaining() = 0 then
    raise notice 'pack_qty already clean — nothing to strip';
    return;
  end if;
  select min(id), max(id) into v_from, v_max from "MEDICINE";
  while v_from <= v_max loop
    perform public._c287_pack_qty_strip(v_from, v_from + 10000);
    v_from := v_from + 10000;
  end loop;
end;
$sweep$;

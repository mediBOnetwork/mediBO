-- CHANGE #288 — MEDICINE.pack_qty never carries a trailing ".0" again.
--
-- The column stores a rendered sentence ("10.0 tablets in 1 strip",
-- "1.0 Injection in 1 vial", "100.0 ml in 1 bottle"). The ".0" is an artefact
-- of the source feed writing a float where the pack sentence wanted an
-- integer, and CHANGE #287 put that sentence on the face of every storefront
-- card (`sf_pack_qty_label` renders pack_qty VERBATIM), so the artefact is now
-- visible to every customer.
--
-- Two halves, because fixing only the stored rows lasts until the next import:
--   1. `_pack_qty_strip_dot_zero(text)` — the one definition of the rule.
--   2. `medicine_pack_qty_norm_trg` — a BEFORE INSERT OR UPDATE OF pack_qty
--      row trigger, so EVERY write path is normalised: admin_write_medicines
--      (a generic dynamic writer — patching it would not have covered the
--      others), barcode_import_apply, admin_approve_pending_medicine, and any
--      direct load. The rule lives in the backend, once.
--
-- Scope of the regex — deliberately narrow. `(\d+)\.0([^0-9]|$)` only strips a
-- ".0" that is the WHOLE fractional part. Genuine decimals are untouched:
-- "2.5 kg Powder", "0.4 ml in 1 prefilled syringe", "2.27 kg Powder" all
-- survive byte-identical (1,548 such rows measured before the backfill; the
-- ".0" set and the genuine-decimal set partition the 289,996 dotted rows with
-- zero overlap). "10.05" keeps its 0 because a digit follows.
--
-- The trigger is scoped `UPDATE OF pack_qty` and carries a WHEN guard, so the
-- table's big unrelated batch jobs (buyable_recompute_tick, the r2_* image
-- migration, backfill_supplier_count) never pay for it.
--
-- Idempotent: create or replace + drop trigger if exists.

-- ── 1. the rule ──────────────────────────────────────────────────────────────
create or replace function public._pack_qty_strip_dot_zero(p_text text)
returns text
language sql
immutable
as $function$
  select case
           when p_text is null then null
           else regexp_replace(p_text, '(\d+)\.0([^0-9]|$)', '\1\2', 'g')
         end;
$function$;

comment on function public._pack_qty_strip_dot_zero(text) is
  'CHANGE #288 — strips a trailing ".0" from every number in a pack sentence ("10.0 tablets in 1 strip" -> "10 tablets in 1 strip"). Genuine decimals (2.5, 0.4, 2.27) are left alone: the ".0" must be the whole fractional part.';

-- ── 2. the ingest guard ──────────────────────────────────────────────────────
create or replace function public.medicine_pack_qty_norm()
returns trigger
language plpgsql
as $function$
begin
  new.pack_qty := public._pack_qty_strip_dot_zero(new.pack_qty);
  return new;
end;
$function$;

comment on function public.medicine_pack_qty_norm() is
  'CHANGE #288 — BEFORE trigger body: no import can reintroduce a ".0" into MEDICINE.pack_qty, whichever RPC or bulk load wrote it.';

drop trigger if exists medicine_pack_qty_norm_trg on public."MEDICINE";

create trigger medicine_pack_qty_norm_trg
before insert or update of pack_qty on public."MEDICINE"
for each row
when (new.pack_qty ~ '\d+\.0([^0-9]|$)')
execute function public.medicine_pack_qty_norm();

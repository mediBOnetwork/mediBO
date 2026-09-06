-- CMD #1812 — the journey that keeps this fixed.
--
-- Abbott Gel Hand Sanitizer was refused with a red "Discontinued" chip and a
-- "Not for sale" bar on a pack a supplier in the customer's zone could send,
-- because 1mg's scraped MEDICINE.status was allowed a vote. This probe asserts
-- the ONE rule, on rows it seeds itself and then rolls back, so it works on a
-- build branch that carries no catalogue.
--
--   standby = master zone supplier list − (out of stock + nostock)
--   available when standby > 0 — and nothing else may speak.

CREATE OR REPLACE FUNCTION public._journey_qa_1812_standby_only()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_id     bigint := -18120001;      -- negative: this probe owns its SKU
  v_zone   smallint := -99;
  v_code   text := 'blp';            -- a zone whose z_* columns exist on MEDICINE
  v_live   int;  v_dead int;
  v_cta_live jsonb; v_cta_dead jsonb;
  v_left   text;
  v_sig    text;
  a1 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean;
begin
  perform public._dev_guard();

  -- 1. The columns are gone. scrapping_status is a different field and stays.
  a1 := not exists (
          select 1 from information_schema.columns
           where table_schema = 'public' and table_name = 'MEDICINE'
             and column_name in ('status', 'status_reason'))
        and exists (
          select 1 from information_schema.columns
           where table_schema = 'public' and table_name = 'MEDICINE'
             and column_name = 'scrapping_status');

  -- 2. storefront_cta cannot be told a status: one signature, two arguments,
  --    and no input of any shape produces the old blocked_by:'status' branch.
  select string_agg(pg_get_function_identity_arguments(p.oid), ' ;; ')
    into v_sig
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'storefront_cta';
  a2 := v_sig = 'p_supplier_count integer, p_resolved boolean'
        and (public.storefront_cta(1, true)  ->> 'blocked_by') is null
        and (public.storefront_cta(0, true)  ->> 'blocked_by') = 'no_supplier'
        and (public.storefront_cta(-1, true) ->> 'blocked_by') = 'no_supplier'
        and (public.storefront_cta(0, true)  ->> 'cta_label')  = 'Unavailable';

  -- 3. THE JOURNEY ITSELF, on a real row: one zone supplier and the pack is
  --    addable; move that same supplier to out-of-stock and it is not. The
  --    fixture is seeded and rolled back inside this sub-block, so the probe
  --    leaves no rows behind and needs no catalogue to exist.
  begin
    insert into public.zones (id, code, name, is_active, is_default, is_synthetic)
    values (v_zone, v_code, 'c1812 probe zone', true, false, true)
    on conflict (id) do nothing;

    -- marketer stays NULL on purpose: sync_marketer_to_company would create a
    -- company row, and that trigger chain writes z_<code>_sup columns for every
    -- ACTIVE zone — including any zone whose columns this database does not
    -- carry. The probe is about availability, not about the company map.
    insert into public."MEDICINE" (id, _row_id, product_name, mrp,
                                   buyable, data_source, cold_chain,
                                   z_blp_sup, z_blp_av, z_blp_oos, z_blp_nostock,
                                   z_rpr_sup, z_rpr_av, z_rpr_oos, z_rpr_nostock)
    values (v_id, v_id, 'c1812 Probe Gel Hand Sanitizer',
            '250.00', true, 'c1812_probe', false,
            '{}'::text[], '{}'::text[], '{}'::text[], '{}'::text[],
            '{}'::text[], '{}'::text[], '{}'::text[], '{}'::text[]);

    -- ① the master zone supplier list. Written by its own UPDATE because
    -- medicine_zone_from_marketer() rebuilds z_*_sup on INSERT and would wipe
    -- a value passed in the VALUES list; it only re-fires on UPDATE OF marketer.
    update public."MEDICINE" set z_blp_sup = array['C1812SUP'] where id = v_id;

    -- standby > 0 → the approved pharmacy is offered Add.
    v_live := public.medicine_zone_standby(v_id, v_zone);
    v_cta_live := public.storefront_cta(v_live, true);

    -- ③ the same supplier goes out of stock → standby 0 → Unavailable.
    update public."MEDICINE" set z_blp_oos = array['C1812SUP'] where id = v_id;
    v_dead := public.medicine_zone_standby(v_id, v_zone);
    v_cta_dead := public.storefront_cta(v_dead, true);

    raise exception using errcode = 'P0001', message = 'c1812_probe_rollback';
  exception when others then
    null;   -- the sub-transaction unwinds; the reads above survive in the vars
  end;

  a3 := coalesce(v_live, 0) = 1
        and coalesce(v_dead, -1) = 0
        and coalesce((v_cta_live ->> 'can_add')::boolean, false) is true
        and (v_cta_live ->> 'cta_label') = 'Add to cart'
        and coalesce((v_cta_dead ->> 'can_add')::boolean, true) is false
        and (v_cta_dead ->> 'cta_label') = 'Unavailable'
        and (v_cta_dead ->> 'blocked_by') = 'no_supplier';

  -- 4. Nothing anywhere still reads the status layer — not a helper, not the
  --    policy table, not the browse-universe filter that used the same column.
  select string_agg(p.proname, ', ' order by p.proname)
    into v_left
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and p.proname <> '_journey_qa_1812_standby_only'
     and (p.prosrc ilike '%med_status_block%'
       or p.prosrc ilike '%med_status_sellable%'
       or p.prosrc ilike '%_med_status_key%'
       or p.prosrc ilike '%medicine_status_policy%'
       or p.prosrc ilike '%catalogue_universe_ok%'
       or p.prosrc ilike '%status_reason%');
  a4 := v_left is null
        and to_regprocedure('public.med_status_block(text)')    is null
        and to_regprocedure('public.med_status_sellable(text)') is null
        and to_regclass('public.medicine_status_policy')        is null;

  -- 5. No storefront payload carries a status field any more, so no screen can
  --    render one even by accident.
  a5 := not (coalesce(public.storefront_page('All', 0, 1) -> 'items' -> 0, '{}'::jsonb) ? 'status')
        and not (coalesce(public.storefront_page('All', 0, 1) -> 'items' -> 0, '{}'::jsonb) ? 'status_block')
        and not (public.storefront_gate() ? 'not_for_sale')
        and not (public.storefront_gate() ? 'blocked_statuses');

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'MEDICINE.status/status_reason gone, scrapping_status kept=' || a1::text
   || ' | storefront_cta signature=' || coalesce(v_sig, 'MISSING')
   || ', no status branch=' || a2::text
   || ' | zone standby ' || coalesce(v_live::text, 'null') || ' -> "'
   || coalesce(v_cta_live ->> 'cta_label', 'null') || '", standby '
   || coalesce(v_dead::text, 'null') || ' -> "'
   || coalesce(v_cta_dead ->> 'cta_label', 'null') || '" ('
   || coalesce(v_cta_dead ->> 'blocked_by', 'null') || ')=' || a3::text
   || ' | nothing reads the status layer=' || a4::text
   || coalesce(' -> still referencing: ' || v_left, '')
   || ' | no storefront payload carries status=' || a5::text));
end
$function$;

GRANT EXECUTE ON FUNCTION public._journey_qa_1812_standby_only() TO service_role;

INSERT INTO public.dev_journeys (name, area, kind, steps, assertions, required, enabled)
VALUES ('qa-1812-standby-only', 'storefront', 'api',
  '["seed one catalogue row with a single zone supplier and no out-of-stock mark",
    "read medicine_zone_standby for that zone — expect 1 — and storefront_cta on it",
    "move the same supplier to out-of-stock, re-read standby — expect 0 — and storefront_cta",
    "roll the fixture back and assert the status layer is gone from schema and payloads"]'::jsonb,
  '["an approved pharmacy sees Add on a product 1mg called DISCONTINUED while its zone standby > 0",
    "the same pack reads Unavailable / no_supplier when zone standby is 0",
    "MEDICINE.status and MEDICINE.status_reason no longer exist; scrapping_status still does",
    "storefront_cta takes (integer, boolean) only and can never answer blocked_by:status",
    "no function references med_status_block / med_status_sellable / _med_status_key / medicine_status_policy / catalogue_universe_ok",
    "no storefront payload carries status, status_block, not_for_sale or blocked_statuses"]'::jsonb,
  false, true)
ON CONFLICT (name) DO UPDATE
  SET area = excluded.area, kind = excluded.kind, steps = excluded.steps,
      assertions = excluded.assertions, enabled = true;

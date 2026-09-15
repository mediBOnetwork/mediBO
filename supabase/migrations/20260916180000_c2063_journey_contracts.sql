-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2063 — the standby journey asserts TODAY's availability contract.
--
-- Debug pass on #2059. qa-1812-standby-only has been red on every command
-- since #2023 (CHANGE #1387, "one zone_available() truth") and it was never a
-- regression in the build it was reported against: #2023 deliberately made
-- `not_available_in_zone` the single blocked_by reason that storefront_cta
-- returns for an unavailable pack, replacing 'no_supplier'. The probe's own
-- EVIDENCE line was updated to print the new value — the three assertion
-- literals underneath it were not, so the probe has been failing the very
-- contract it is meant to hold down, and reporting it as "no status branch".
--
-- Nothing about the app changes here. The probe now expects what #2023 ships.
-- Idempotent: CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public._journey_qa_1812_standby_only()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c2063_standby$
declare
  v_id     bigint := -18120001;      -- negative: this probe owns its SKU
  v_zone   smallint;
  v_code   text := 'blp';            -- a zone whose z_* columns exist on MEDICINE
  v_live   int;  v_dead int;
  v_cta_live jsonb; v_cta_dead jsonb;
  v_left   text;
  v_sig    text;
  v_err    text;
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
        and (public.storefront_cta(0, true)  ->> 'blocked_by') = 'not_available_in_zone'
        and (public.storefront_cta(-1, true) ->> 'blocked_by') = 'not_available_in_zone'
        and (public.storefront_cta(0, true)  ->> 'cta_label')  = 'Unavailable';

  -- 3. THE JOURNEY ITSELF, on a real row: one zone supplier and the pack is
  --    addable; move that same supplier to out-of-stock and it is not. The
  --    fixture is seeded and rolled back inside this sub-block, so the probe
  --    leaves no rows behind and needs no catalogue to exist.
  begin
    -- CMD #1848 — the zone that carries this code is REUSED when it exists
    -- (zones.code is unique; a seeded branch and live both carry 'blp'), and
    -- seeded only when it does not.
    select z.id into v_zone from public.zones z where z.code = v_code limit 1;
    if v_zone is null then
      v_zone := -99;
      insert into public.zones (id, code, name, is_active, is_default, is_synthetic)
      values (v_zone, v_code, 'c1812 probe zone', true, false, true)
      on conflict (id) do nothing;
    end if;

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
    -- the sub-transaction unwinds; the reads above survive in the vars. A
    -- fixture error is NAMED in the evidence instead of being swallowed.
    if sqlerrm <> 'c1812_probe_rollback' then v_err := left(sqlerrm, 160); end if;
  end;

  a3 := coalesce(v_live, 0) = 1
        and coalesce(v_dead, -1) = 0
        and coalesce((v_cta_live ->> 'can_add')::boolean, false) is true
        and (v_cta_live ->> 'cta_label') = 'Add to cart'
        and coalesce((v_cta_dead ->> 'can_add')::boolean, true) is false
        and (v_cta_dead ->> 'cta_label') = 'Unavailable'
        and (v_cta_dead ->> 'blocked_by') = 'not_available_in_zone';

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
   || ' | zone ' || coalesce(v_zone::text, 'null') || ' (' || v_code || ') standby '
   || coalesce(v_live::text, 'null') || ' -> "'
   || coalesce(v_cta_live ->> 'cta_label', 'null') || '", standby '
   || coalesce(v_dead::text, 'null') || ' -> "'
   || coalesce(v_cta_dead ->> 'cta_label', 'null') || '" ('
   || coalesce(v_cta_dead ->> 'blocked_by', 'null') || ')=' || a3::text
   || coalesce(' fixture error: ' || v_err, '')
   || ' | nothing reads the status layer=' || a4::text
   || coalesce(' -> still referencing: ' || v_left, '')
   || ' | no storefront payload carries status=' || a5::text));
end
$c2063_standby$;

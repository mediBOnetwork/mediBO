-- CMD #1848 (c) — two storefront journey probes stopped being able to seed
-- their own fixtures on a seeded build branch (CHANGE #1803 seeds zones and a
-- catalogue slice from live; #1837 purged live orders), so both reported
-- "failed" for a reason that had nothing to do with the code under test:
--
--   qa-1812-standby-only  inserted its OWN zone with code 'blp' — the code of
--                         the real Bilaspur zone — and hit zones_code_key. The
--                         sub-block swallowed the error, standby read null and
--                         the probe failed. It now REUSES the zone that carries
--                         that code and only seeds one when none exists.
--   qa-698-substitute     looked for its product through order_items and its
--                         customer through orders; an empty order book meant
--                         "no live customer or no zone-stocked substitutable
--                         product" every time, although the catalogue slice
--                         carried products with zone-stocked equals and an
--                         approved real pharmacy sat in pharmacy_profiles. Both
--                         lookups keep their original first choice and fall
--                         back: any approved, non-deleted, non-synthetic
--                         pharmacy for the customer; a bounded scan of the
--                         catalogue stocked in that pharmacy's zone for the
--                         product. Every assertion is unchanged, every write
--                         is still rolled back.
--
-- Idempotent: CREATE OR REPLACE only.

create or replace function public._journey_qa_1812_standby_only()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
        and (public.storefront_cta(0, true)  ->> 'blocked_by') = 'no_supplier'
        and (public.storefront_cta(-1, true) ->> 'blocked_by') = 'no_supplier'
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
$function$;

create or replace function public._journey_c698_substitute()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
 set statement_timeout to '200s'
as $function$
declare
  -- static guarantees
  v_anon_page   boolean; v_anon_apply boolean; v_one_ask boolean;
  v_cron        boolean; v_routes int; v_probe_arm boolean;
  v_blocked     boolean; v_allowed boolean; v_no_price boolean; v_hooked boolean;
  -- the live chain
  v_cust uuid; v_user uuid; v_ord uuid; v_line uuid; v_ask bigint; v_tok text;
  v_ids bigint[]; v_inq bigint; v_sup text; v_slot int;
  v_opts int := 0; v_probes int := 0; v_demand numeric := 0;
  v_joined boolean := false; v_qty numeric := 0; v_orig_unf boolean := false;
  v_loser_gone boolean := false; v_blocked_line_asked boolean := true;
  v_chain text := 'not run'; v_ok boolean;
  v_pid bigint; v_warf bigint; v_l2 uuid;
  -- CMD #1848 — fixture fallbacks for an order book that is empty
  v_zone smallint; v_zcode text; v_cand bigint; v_pid_from text := 'order history';
  v_cust_from text := 'order history';
  v_opt jsonb; v_ranked jsonb; v_seeded int := 0;
begin
  perform public._dev_guard();

  -- ── 1. the fence: the token page is anonymous, the machinery is not ──────
  v_anon_page := has_function_privilege('anon',
      'public.substitute_ask_page(text)', 'execute')
    and has_function_privilege('anon',
      'public.substitute_ask_submit(text, bigint[], boolean)', 'execute')
    and has_function_privilege('anon', 'public.substitute_ask_skip(text)', 'execute');
  v_anon_apply := has_function_privilege('anon',
      'public.substitute_apply(bigint, bigint)', 'execute')
    or has_function_privilege('anon', 'public.substitute_ask_open(uuid)', 'execute')
    or has_function_privilege('anon', 'public.substitute_ask_tick(integer)', 'execute');

  -- ── 2. "one ask per line, never repeated" is an INDEX, not a code path ───
  v_one_ask := exists (
    select 1 from pg_indexes
     where schemaname = 'public' and tablename = 'order_substitute_ask'
       and indexdef ilike '%unique%' and indexdef ilike '%order_item_id%');

  v_cron := coalesce((select enabled from public.cron_task
                       where name = 'substitute_ask_tick'), false);
  select count(*) into v_routes from public.wa_event_routes
   where event_key in ('order_substitute_ask','order_substitute_applied',
                       'order_substitute_none') and enabled;

  -- ── 3. the waterfall can SEE a ticked substitute ─────────────────────────
  select coalesce(p.prosrc,'') ilike '%order_substitute_probe%' into v_probe_arm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'inquiry_demand_qty' limit 1;

  -- and the finalizer is where the ask is opened from, so an unfulfilled line
  -- can never be shipped past without the customer having been asked.
  select coalesce(p.prosrc,'') ilike '%substitute_ask_open%' into v_hooked
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'order_finalize_unfulfilled' limit 1;

  -- ── 4. never a narrow-therapeutic-index or Schedule X molecule ───────────
  select m.id into v_warf from public."MEDICINE" m
   where m.salt_composition ilike '%warfarin%' and m.buyable is true limit 1;
  v_blocked := v_warf is null or not public.med_substitutable(v_warf);

  -- THE CUSTOMER. First choice unchanged: the newest real order of an
  -- approved pharmacy. CMD #1848 fallback: with no order on the book (a seeded
  -- build branch, or live right after a purge) any approved, non-deleted,
  -- non-synthetic pharmacy will do — the probe writes its own order anyway.
  select o.customer_id, o.user_id into v_cust, v_user
    from public.orders o
    join public.pharmacy_profiles pp
      on pp.user_id = o.user_id and pp.approved
     and coalesce(pp.is_deleted,false) = false
   where o.user_id is not null and coalesce(o.is_synthetic,false) = false
   order by o.created_at desc limit 1;
  if v_cust is null then
    select pp.id, pp.user_id into v_cust, v_user
      from public.pharmacy_profiles pp
     where pp.approved and coalesce(pp.is_deleted,false) = false
       and pp.user_id is not null and coalesce(pp.is_synthetic,false) = false
     order by pp.created_at limit 1;
    if v_cust is not null then v_cust_from := 'pharmacy_profiles fallback'; end if;
  end if;
  select coalesce(pp.zone_id, public.zone_default_id()) into v_zone
    from public.pharmacy_profiles pp where pp.id = v_cust;
  v_zone := coalesce(v_zone, public.zone_default_id());

  -- CHANGE #850 — this used to call substitute_candidates() once per scanned
  -- order line (the scalar-helper-scan anti-pattern): 241 calls at ~195 ms,
  -- 47 s of a 55 s statement budget, so the probe timed out instead of
  -- answering and #850 could not close on it. The assertion is unchanged --
  -- a REAL order line, newest first, whose product has live substitutes (two
  -- at least, because the chain below ticks two and ranks them) --
  -- but the expensive helper now runs over a bounded, de-duplicated recent
  -- window instead of the whole table.
  select s.product_id into v_pid
    from (
      select distinct on (oi.product_id) oi.product_id, oi.zone_id, oi.created_at
        from (
          select oi2.product_id, oi2.zone_id, oi2.created_at
            from public.order_items oi2
           where oi2.zone_id is not null
           order by oi2.created_at desc
           limit 400
        ) oi
        join public."MEDICINE" m on m.id = oi.product_id
       order by oi.product_id, oi.created_at desc
    ) s
   where jsonb_array_length(
           public.substitute_candidates(s.product_id, s.zone_id, null, 3)->'items') >= 2
   order by s.created_at desc
   limit 1;

  -- CMD #1848 fallback: no order line to learn from → a bounded walk of the
  -- catalogue stocked in the customer's zone (its own z_<code>_sup column),
  -- best sellers first, stopping at the first product with a live equal.
  if v_pid is null then
    select z.code into v_zcode from public.zones z where z.id = v_zone;
    if v_zcode is not null and exists (
         select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'MEDICINE'
            and column_name = 'z_' || v_zcode || '_sup') then
      for v_cand in execute format(
        'select m.id from public."MEDICINE" m where m.buyable is true and cardinality(m.%I) > 0 '
        || 'order by coalesce(m.sales_count, 0) desc, m.id limit 120', 'z_' || v_zcode || '_sup')
      loop
        -- two equals at least: the chain ticks two and ranks them by the taps
        if jsonb_array_length(public.substitute_candidates(v_cand, v_zone, null, 3)->'items') >= 2 then
          v_pid := v_cand; v_pid_from := 'catalogue fallback (zone ' || v_zcode || ')';
          exit;
        end if;
      end loop;
    end if;
  end if;
  v_allowed := v_pid is not null and public.med_substitutable(v_pid);

  -- ── 5. NO PRICES. mediBO sells at the supplier's rate; an offer that
  -- carried a number we have not got yet would be a promise we cannot keep.
  v_no_price := v_pid is null or not (
    public.substitute_candidates(v_pid, null, null, 3)::text
      ~* '"(price|mrp|rate|amount|net|margin|saving|pricing)[^"]*"\s*:');

  -- ── 6. THE LIVE CHAIN, rolled back before this function answers ──────────
  begin
    if v_cust is null or v_pid is null then
      v_chain := 'no live customer or no zone-stocked substitutable product to test with';
      raise exception 'C698_PROBE_ROLLBACK';
    end if;

    insert into public.orders (customer_id, user_id, pharmacy_name, order_code,
                               status, fulfillment_status, total_amount,
                               zone_id, phone, placed_by_admin)
    select v_cust, v_user, coalesce(pp.pharmacy_name,''), 'C698-PROBE',
           'accepted', 'open', 0, v_zone,
           '9999999999', true
      from public.pharmacy_profiles pp where pp.id = v_cust
    returning id into v_ord;

    insert into public.order_items (order_id, product_id, product_name, quantity,
                                    mrp, gst_percent, pharmacy_name)
    select v_ord, m.id, coalesce(m.product_name,''), 5,
           nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
           m.gst_percent, ''
      from public."MEDICINE" m where m.id = v_pid
    returning id into v_line;

    if v_warf is not null then
      insert into public.order_items (order_id, product_id, product_name, quantity,
                                      mrp, gst_percent, pharmacy_name)
      select v_ord, m.id, coalesce(m.product_name,''), 1,
             nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
             m.gst_percent, ''
        from public."MEDICINE" m where m.id = v_warf
      returning id into v_l2;
    end if;

    update public.order_items set unfulfillable = true,
           unfulfillable_reason = 'No supplier available', unfulfillable_at = now()
     where order_id = v_ord;

    -- The ask is opened the way order_finalize_unfulfilled opens it (that hook
    -- is asserted separately, from the function's own source). The probe calls
    -- substitute_ask_open directly so it never takes the orders-total write
    -- lock the finalizer takes — a journey that runs on every command must not
    -- be able to deadlock with a live order being finalized beside it.
    perform public.substitute_ask_open(v_line);
    if v_l2 is not null then perform public.substitute_ask_open(v_l2); end if;

    select a.id, a.token, jsonb_array_length(a.options)
      into v_ask, v_tok, v_opts
      from public.order_substitute_ask a where a.order_item_id = v_line;
    if v_ask is null then
      v_chain := 'no ask opened for a substitutable unfulfilled line';
      raise exception 'C698_PROBE_ROLLBACK';
    end if;
    -- the blocked molecule must have been passed over in SILENCE
    v_blocked_line_asked := v_l2 is not null and exists (
      select 1 from public.order_substitute_ask where order_item_id = v_l2);

    -- CMD #1848 — the waterfall resolves a ranked distributor name against
    -- ACTIVE supplier_profiles (compute_current_supplier_fx); a seeded branch
    -- carries the catalogue's supplier lists but not the suppliers, so every
    -- probe inquiry would sit with current_supplier NULL and nothing could
    -- answer. For each offered substitute whose ranked list resolves to no
    -- active supplier, seed one active row under the first ranked name. Live
    -- always resolves, so live never seeds; and everything is rolled back.
    for v_opt in select * from jsonb_array_elements(
                   (select a.options from public.order_substitute_ask a where a.id = v_ask)) loop
      v_ranked := coalesce(public.oi_zone_ps_payload((v_opt->>'product_id')::bigint, v_zone)->'ranked',
                           '[]'::jsonb);
      if jsonb_array_length(v_ranked) > 0 and not exists (
           select 1 from public.supplier_profiles sp
             join jsonb_array_elements_text(v_ranked) r
               on lower(btrim(sp.supplier_name)) = lower(btrim(r))
            where sp.status ilike 'active' and coalesce(sp.is_deleted,false) = false) then
        insert into public.supplier_profiles (supplier_name, status, zone_id)
        values (v_ranked->>0, 'active', v_zone);
        v_seeded := v_seeded + 1;
      end if;
    end loop;

    -- tick the LAST option first: the order of the taps is the ranking
    select array[(a.options->(v_opts-1)->>'product_id')::bigint,
                 (a.options->0->>'product_id')::bigint]
      into v_ids from public.order_substitute_ask a where a.id = v_ask;
    perform public.substitute_ask_submit(v_tok, v_ids, false);

    select count(*) into v_probes from public.order_substitute_probe where ask_id = v_ask;
    select coalesce(public.inquiry_demand_qty(p.product_id, i.current_supplier, true), 0)
      into v_demand
      from public.order_substitute_probe p
      join public.inquiry i on i.id = p.inquiry_id
     where p.ask_id = v_ask and p.rank = 1;
    v_demand := coalesce(v_demand, 0);

    -- the SECOND-ranked substitute answers Available first
    select p.inquiry_id into v_inq
      from public.order_substitute_probe p where p.ask_id = v_ask and p.rank = 2;
    select i.current_supplier into v_sup from public.inquiry i where i.id = v_inq;
    select s into v_slot from generate_series(1,30) s
     where (to_jsonb((select q from public.inquiry q where q.id = v_inq)) ->> ('PS'||s)) = v_sup
     limit 1;
    if v_slot is not null then
      execute format('update public.inquiry set %I = %L where id = %s',
                     'AS'||v_slot, 'Available', v_inq);
    end if;

    perform public.substitute_ask_tick(50);

    select true, sub.quantity into v_joined, v_qty
      from public.order_items sub
     where sub.order_id = v_ord and sub.substitute_for = v_line limit 1;
    select oi.unfulfillable into v_orig_unf
      from public.order_items oi where oi.id = v_line;
    -- a losing probe leaves NOTHING on a distributor's purchase order
    v_loser_gone := not exists (
      select 1 from public.order_substitute_probe p
       where p.ask_id = v_ask and p.rank = 1
         and p.inquiry_id is not null
         and exists (select 1 from public.inquiry i where i.id = p.inquiry_id));

    v_chain := 'ran';
    raise exception 'C698_PROBE_ROLLBACK';
  exception when others then
    if sqlerrm <> 'C698_PROBE_ROLLBACK' and v_chain = 'not run' then
      v_chain := 'error: ' || left(sqlerrm, 120);
    end if;
  end;

  v_ok := v_anon_page and not v_anon_apply and v_one_ask and v_cron
      and v_routes = 3 and coalesce(v_probe_arm, false) and coalesce(v_hooked, false)
      and v_blocked and v_allowed and v_no_price
      and v_chain = 'ran'
      and v_opts > 0 and v_probes = 2 and v_demand > 0
      and coalesce(v_joined, false) and coalesce(v_orig_unf, false)
      and v_loser_gone and not v_blocked_line_asked;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'anon may read+answer the token page=' || v_anon_page::text ||
      ' | anon may apply/open/tick=' || v_anon_apply::text || ' (must be false)' ||
      ' | one-ask-per-line is a unique index=' || v_one_ask::text ||
      ' | tick cron enabled=' || v_cron::text ||
      ' | wa routes active=' || v_routes::text || '/3' ||
      ' | inquiry_demand_qty counts probe demand=' || coalesce(v_probe_arm::text,'?') ||
      ' | order_finalize_unfulfilled opens the ask=' || coalesce(v_hooked::text,'?') ||
      ' | narrow-therapeutic molecule refused=' || coalesce(v_blocked::text,'false') ||
      ' | an ordinary product is allowed=' || coalesce(v_allowed::text,'false') ||
      ' (product ' || coalesce(v_pid::text, 'none') || ' from ' || v_pid_from || ')' ||
      ' | customer from ' || v_cust_from ||
      ' | supplier fixtures seeded=' || v_seeded::text ||
      ' | offer carries no price key=' || coalesce(v_no_price::text,'false') ||
      ' | live chain=' || v_chain ||
      ' | options offered=' || coalesce(v_opts::text,'0') ||
      ' | probes started=' || coalesce(v_probes::text,'0') ||
      ' | waterfall sees the demand=' || coalesce(v_demand::text,'null') ||
      ' | substitute joined the same order=' || coalesce(v_joined::text,'false') ||
      ' at qty ' || coalesce(v_qty::text,'-') ||
      ' | original line still unfulfilled=' || coalesce(v_orig_unf::text,'false') ||
      ' | losing probe left nothing on a PO=' || coalesce(v_loser_gone::text,'false') ||
      ' | blocked molecule was asked about=' || coalesce(v_blocked_line_asked::text,'false') ||
        ' (must be false)' ||
      ' | every write rolled back=true'));
end $function$;

-- ── qa-697-feedback: the chain needs a CLOSED order; seed one when the book has none ──
CREATE OR REPLACE FUNCTION public._journey_c697_feedback()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order   uuid;
  v_uid     uuid;
  v_claims  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_token   text;
  v_prompt  jsonb; v_form jsonb; v_sub jsonb; v_again jsonb; v_twice jsonb;
  v_dims    int := 0; v_chips int := 0;
  v_tickets int := 0; v_dim_tag text := ''; v_feeds int := 0; v_weeks int := 0;
  -- CHANGE #799 — the tickets that were ALREADY on this order before the
  -- probe touched it. See the count below for why they have to be excluded.
  v_pre     uuid[] := '{}';
  v_anon_form boolean := false;
  v_ran     boolean := false;
  -- grants: the two writers must be unreachable, the two token entry points open
  v_writer_closed boolean;
  v_anon_open     boolean;
  v_once_only     boolean;
  v_routes        int;
  v_crons         int;
  v_nav           boolean;
  v_ok            boolean;
  -- CMD #1848 — fixture fallback for an order book with no closed order
  v_cust          uuid;
  v_seed          boolean := false;
begin
  perform public._dev_guard();

  -- ── Structure. These hold whether or not a fixture order exists.
  v_writer_closed :=
    not has_function_privilege('anon',
      'public._order_feedback_write(uuid,jsonb,integer,text,text[],text,uuid,uuid)', 'execute')
    and not has_function_privilege('authenticated',
      'public._order_feedback_write(uuid,jsonb,integer,text,text[],text,uuid,uuid)', 'execute');

  v_anon_open :=
    has_function_privilege('anon', 'public.order_feedback_form(text)', 'execute')
    and has_function_privilege('anon',
      'public.order_feedback_submit_token(text,jsonb,integer,text,text[])', 'execute');

  -- One row per order is a CONSTRAINT, not a convention — that is what makes
  -- "never asked twice" true even when two tabs answer at once.
  select exists (
    select 1 from pg_index i
      join pg_class c on c.oid = i.indrelid
      join pg_attribute a on a.attrelid = c.oid and a.attnum = i.indkey[0]
     where c.relname = 'order_feedback' and i.indisunique
       and i.indnatts = 1 and a.attname = 'order_id')
    into v_once_only;

  select count(*) into v_routes from public.wa_event_routes
   where event_key in ('order_feedback_request','order_feedback_low') and enabled;

  select count(*) into v_crons from public.cron_task
   where name in ('order_feedback_sweep','order_feedback_rollup') and enabled;

  select (route_key = 'feedback' and is_active) into v_nav
    from public.feature_registry where feature_key = 'admin.feedback';

  -- ── The live chain, against a real closed order, then rolled back.
  select o.id, pp.user_id into v_order, v_uid
    from public.orders o
    join public.pharmacy_profiles pp on pp.id = o.customer_id
   where o.closed_at is not null and pp.user_id is not null
   order by o.closed_at desc limit 1;

  -- CHANGE #799 — remember what was there first.
  --
  -- The probe picks the NEWEST closed order and rolls its own writes back, but
  -- a ticket a real customer opened on that order does not roll back — it was
  -- never the probe's. Counting every feedback ticket on the order therefore
  -- counts strangers: on 2026-09-03 a genuine 'support' ticket (MB-2609-0004)
  -- landed on exactly that order and this journey read 3 where it had made 2,
  -- and went red for every command after it while the feedback loop itself was
  -- working perfectly. A probe must assert on what IT did.
  select coalesce(array_agg(t.id), '{}') into v_pre
    from public.support_ticket t
   where t.order_id = v_order and t.topic_code = 'feedback';

  -- CMD #1848 — a seeded build branch (and live right after a purge) has no
  -- closed order to borrow. The chain then seeds its own: a closed order for
  -- any approved, non-deleted, non-synthetic pharmacy that has a login. It is
  -- written INSIDE the block below, so the raise at the bottom removes it with
  -- everything else; live, which always has a closed order, never seeds.
  if v_order is null then
    select pp.id, pp.user_id into v_cust, v_uid
      from public.pharmacy_profiles pp
     where pp.approved and coalesce(pp.is_deleted,false) = false
       and pp.user_id is not null and coalesce(pp.is_synthetic,false) = false
     order by pp.created_at limit 1;
    v_seed := v_cust is not null;
  end if;

  if v_order is not null or v_seed then
    begin
      v_ran := true;
      if v_seed then
        insert into public.orders (customer_id, user_id, pharmacy_name, order_code,
                                   status, fulfillment_status, total_amount,
                                   zone_id, phone, placed_by_admin, closed_at)
        select v_cust, v_uid, coalesce(pp.pharmacy_name,''), 'C697-PROBE',
               'delivered', 'shipped', 0,
               coalesce(pp.zone_id, public.zone_default_id()),
               '9999999999', true, now()
          from public.pharmacy_profiles pp where pp.id = v_cust
        returning id into v_order;
      end if;
      -- The order may already carry an answer; inside this block that is ours
      -- to clear, because none of it survives the raise at the bottom.
      delete from public.order_feedback where order_id = v_order;
      delete from public.order_feedback_token where order_id = v_order;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

      v_prompt := public.order_feedback_prompt(v_order);
      v_dims   := jsonb_array_length(coalesce(v_prompt->'dimensions','[]'::jsonb));
      select count(*)::int into v_chips
        from jsonb_array_elements(coalesce(v_prompt->'dimensions','[]'::jsonb)) d
       where jsonb_array_length(coalesce(d->'chips','[]'::jsonb)) > 0;

      v_token := public.order_feedback_send_wa(v_order) ->> 'token';

      -- The WhatsApp page, as a signed-out browser sees it.
      perform set_config('request.jwt.claims',
        json_build_object('role','anon')::text, true);
      v_form := public.order_feedback_form(v_token);
      v_anon_form := coalesce((v_form->>'ok')::boolean, false)
                 and coalesce(v_form->>'title','') <> '';

      v_sub := public.order_feedback_submit_token(v_token,
        '{"ordering":5,"packaging":1,"delivery":4,"products":5,"support":2}'::jsonb,
        5, 'boxes arrived crushed', array['pkg_damaged']);

      select count(*)::int, coalesce(string_agg(distinct feedback_dim, ','), '')
        into v_tickets, v_dim_tag
        from public.support_ticket
       where order_id = v_order and topic_code = 'feedback'
         and not (id = any (v_pre));

      select count(*)::int into v_feeds
        from public.exception_scorecard_input
       where exception_id like 'ofb:' || v_order::text || '%';

      perform public.order_feedback_rollup(4);
      select count(*)::int into v_weeks from public.order_feedback_weekly;

      -- Asked once: the customer's own prompt, and the link, both close.
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_again := public.order_feedback_prompt(v_order);
      v_twice := public.order_feedback_submit_token(v_token,
        '{"ordering":5,"packaging":5,"delivery":5,"products":5,"support":5}'::jsonb, 10);

      raise exception using errcode = 'ZZ697', message = 'c697 journey rollback';
    exception when sqlstate 'ZZ697' then
      null;  -- every write above is gone; the answers are still in the variables
    end;
  end if;

  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_writer_closed and v_anon_open and coalesce(v_once_only,false)
      and v_routes = 2 and v_crons = 2 and coalesce(v_nav,false)
      and v_ran
      and coalesce((v_prompt->>'show')::boolean,false)
      and v_dims = 5 and v_chips = 5
      and v_anon_form
      and coalesce((v_sub->>'ok')::boolean,false)
      and coalesce((v_sub->>'ticket_opened')::boolean,false)
      and v_tickets = 2 and v_dim_tag like '%packaging%'
      and v_feeds >= 3
      and v_weeks >= 1
      and coalesce((v_again->>'show')::boolean, true) = false
      and coalesce(v_twice->>'error','') = 'used';

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
        'internal writers closed to anon+authenticated=' || v_writer_closed::text
     || ' | anon may read+submit the token page=' || v_anon_open::text
     || ' | one feedback row per order is a unique index=' || coalesce(v_once_only::text,'?')
     || ' | wa routes live=' || v_routes || '/2'
     || ' | cron tasks enabled=' || v_crons || '/2'
     || ' | Feedback desk registered at route feedback=' || coalesce(v_nav::text,'?')
     || ' | live chain ran=' || v_ran::text
     || case when v_seed then ' (order seeded by the probe)' else '' end
     || ' | prompt.show=' || coalesce(v_prompt->>'show','-')
     || ' dimensions=' || v_dims || ' of 5, all with chips=' || v_chips
     || ' | anon form ok=' || v_anon_form::text
     || ' | token submit ok=' || coalesce(v_sub->>'ok','-')
     || ' ticket_opened=' || coalesce(v_sub->>'ticket_opened','-')
     || ' | tickets=' || v_tickets || ' tagged ' || coalesce(nullif(v_dim_tag,''),'-')
     || ' | scorecard inputs=' || v_feeds
     || ' | weekly rollup rows=' || v_weeks
     || ' | asked twice=' || coalesce(v_again->>'show','-')
     || ' | token reused=' || coalesce(v_twice->>'error','-')
     || ' | every write above was rolled back'));
end $function$;

-- CHANGE #1354 — the repo catches up with two functions that only ever
-- existed on LIVE.
--
-- The regression guard went red after #1115 with four function diffs. Two were
-- real work already committed and were rebaselined:
--   dev_agent_sessions_status()          — #1268, byte-identical to
--                                          20260904150000_c1268_one_command_per_runner.sql
--   supplier_account_tab_performance()   — #850,  byte-identical to
--                                          20260904160000_c850_spn_tips_fix.sql
--
-- The other two were DRIFT in the only direction that matters here: live was
-- RIGHT and the repo was wrong, so a rebuild from migrations would have
-- silently undone them.
--
--   _journey_qa_850_512()  existed nowhere in supabase/migrations at all, and
--     neither did its dev_journeys row — #850 created both straight on live.
--     The journey is required=true, so a rebuilt database would fail every
--     storefront command's finish gate on a probe it could not find.
--
--   _journey_c698_substitute()  live carries a statement_timeout and a bounded
--     `distinct on (...) ... limit 400` scan over order_items; the committed
--     version from 20260903T160000_c698_substitute_journey.sql still had the
--     unbounded join that made this probe time out (the 'canceling statement
--     due to lock timeout' failures behind CHANGE #1069). Replaying the repo
--     would put the slow one back.
--
-- Both are captured here verbatim from pg_get_functiondef, so the guard's
-- baseline, the live database and the repo finally say the same thing.
-- Idempotent: create-or-replace plus an upsert.

create or replace function public._journey_qa_850_512()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_build text; v_fresh boolean; v_change text; v_norm boolean;
begin
  perform public._dev_guard();
  -- CHANGE #850 — this journey was auto-created from a QA "Version check
  -- failed" blocker that was never a product defect: qa_agent.sh appends
  -- /version.json to whatever URL it is handed, and it had been handed a
  -- ROUTE. The app is a single-page app behind a catch-all, so that path
  -- served index.html. The repair is in the harness (it now strips the path
  -- to an origin); what this journey holds down is the fact the version
  -- check exists to establish -- the live build identifies itself.
  select rl.build_hash,
         (rl.updated_at > now() - interval '2 days'),
         coalesce(rl.data->>'change', '')
    into v_build, v_fresh, v_change
    from public.render_log rl where rl.id = 'singleton';

  v_norm := coalesce(v_build,'') <> '' and v_fresh;

  return jsonb_build_object(
    'status', case when v_norm and v_change <> '' then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'live build hash published=' || coalesce(nullif(v_build,''),'<none>')
      || ' | render log fresh=' || coalesce(v_fresh::text,'false')
      || ' | change published=' || coalesce(nullif(v_change,''),'<none>')
      || ' | version check must read the ORIGIN, never a route (SPA catch-all serves index.html)=true'));
end $function$

;

create or replace function public._journey_c698_substitute()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '200s'
AS $function$
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

  -- CHANGE #850 — this used to call substitute_candidates() once per scanned
  -- order line (the scalar-helper-scan anti-pattern): 241 calls at ~195 ms,
  -- 47 s of a 55 s statement budget, so the probe timed out instead of
  -- answering and #850 could not close on it. The assertion is unchanged --
  -- a REAL order line, newest first, whose product has live substitutes --
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
           public.substitute_candidates(s.product_id, s.zone_id, null, 3)->'items') > 0
   order by s.created_at desc
   limit 1;
  v_allowed := v_pid is not null and public.med_substitutable(v_pid);

  -- ── 5. NO PRICES. mediBO sells at the supplier's rate; an offer that
  -- carried a number we have not got yet would be a promise we cannot keep.
  v_no_price := v_pid is null or not (
    public.substitute_candidates(v_pid, null, null, 3)::text
      ~* '"(price|mrp|rate|amount|net|margin|saving|pricing)[^"]*"\s*:');

  -- ── 6. THE LIVE CHAIN, rolled back before this function answers ──────────
  begin
    select o.customer_id, o.user_id into v_cust, v_user
      from public.orders o
      join public.pharmacy_profiles pp
        on pp.user_id = o.user_id and pp.approved
       and coalesce(pp.is_deleted,false) = false
     where o.user_id is not null and coalesce(o.is_synthetic,false) = false
     order by o.created_at desc limit 1;
    if v_cust is null or v_pid is null then
      v_chain := 'no live customer or no zone-stocked substitutable product to test with';
      raise exception 'C698_PROBE_ROLLBACK';
    end if;

    insert into public.orders (customer_id, user_id, pharmacy_name, order_code,
                               status, fulfillment_status, total_amount,
                               zone_id, phone, placed_by_admin)
    select v_cust, v_user, coalesce(pp.pharmacy_name,''), 'C698-PROBE',
           'accepted', 'open', 0, coalesce(pp.zone_id, public.zone_default_id()),
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

    -- tick the LAST option first: the order of the taps is the ranking
    select array[(a.options->(v_opts-1)->>'product_id')::bigint,
                 (a.options->0->>'product_id')::bigint]
      into v_ids from public.order_substitute_ask a where a.id = v_ask;
    perform public.substitute_ask_submit(v_tok, v_ids, false);

    select count(*) into v_probes from public.order_substitute_probe where ask_id = v_ask;
    select public.inquiry_demand_qty(p.product_id, i.current_supplier, true)
      into v_demand
      from public.order_substitute_probe p
      join public.inquiry i on i.id = p.inquiry_id
     where p.ask_id = v_ask and p.rank = 1;

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
      ' | narrow-therapeutic molecule refused=' || v_blocked::text ||
      ' | an ordinary product is allowed=' || v_allowed::text ||
      ' | offer carries no price key=' || v_no_price::text ||
      ' | live chain=' || v_chain ||
      ' | options offered=' || v_opts::text ||
      ' | probes started=' || v_probes::text ||
      ' | waterfall sees the demand=' || v_demand::text ||
      ' | substitute joined the same order=' || coalesce(v_joined::text,'false') ||
      ' at qty ' || coalesce(v_qty::text,'-') ||
      ' | original line still unfulfilled=' || coalesce(v_orig_unf::text,'false') ||
      ' | losing probe left nothing on a PO=' || v_loser_gone::text ||
      ' | blocked molecule was asked about=' || v_blocked_line_asked::text ||
        ' (must be false)' ||
      ' | every write rolled back=true'));
end $function$

;

-- #850's journey row, which lived only in the live table.
insert into public.dev_journeys (name, area, kind, steps, assertions, source_bug, required, enabled)
values ('qa-850-512', 'storefront', 'api',
        '["TODO implement before completing #850 — must reproduce QA blocker: Version check failed"]'::jsonb,
        '[]'::jsonb, 850, true, true)
on conflict (name) do update
  set area = excluded.area, kind = excluded.kind, required = excluded.required,
      enabled = excluded.enabled;

-- CHANGE #442 — debug pass on #424: an empty shelf line is not a lot.
--
-- FOUND BY THE 360, not by a user: three stored estimates broke their own
-- invariants —
--   inferred_sold = -3, left_high = -3 while left_low = 0, inferred_left > qty_in.
--
-- ROOT CAUSE. `pharmacy_stock.qty` MAY be negative, on purpose (#412: an
-- oversold shelf line is a real thing and the ledger records it rather than
-- hiding it). `pharmacy_infer_lots` walked every stock row as if it were a lot,
-- so for qty_in = -3 the pour computed `least(demand, -3) = -3` sold, and the
-- band's upper edge `least(qty_in, …)` came out BELOW its lower edge. Nothing
-- was displayed — the screen filters `inferred_left > 0` — which is exactly why
-- this had to be caught by an invariant sweep instead of by a screenshot.
--
-- THE FIX, at the root and not at the display:
--   1. A stock row with nothing on it (qty <= 0) or with an unknown quantity
--      (#423's `is_unquantified`) is NOT a lot the engine can reason about. It
--      is skipped by the walk and its stale estimate is deleted.
--   2. Every number the pour writes is clamped to its own definition, so no
--      future path can store a negative sale or an upside-down band.
--   3. The invariants join journey qa-424-237, which is how this class of bug
--      is retired rather than this one row being fixed.

-- ── 1. the pour: skip what is not a lot, and clamp what is ──────────────────

create or replace function public.pharmacy_infer_lots(p_shop uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg public.pharmacy_infer_config := public._c424_cfg();
  v_today date := public._c424_today();
  r record;
  v_sku bigint := null;
  v_rate numeric := 0;        -- units/day currently in charge for this SKU
  v_clock date;               -- the day the shelf became empty of older lots
  v_start date; v_days numeric; v_take numeric; v_demand numeric;
  v_left numeric; v_low numeric; v_high numeric;
  v_sd numeric; v_cv numeric; v_conf numeric; v_method text;
  v_n integer := 0;
begin
  if p_shop is null then return jsonb_build_object('ok', false, 'error', 'no_shop'); end if;

  -- CHANGE #442 — a shelf line with nothing on it, or with a quantity nobody
  -- could read off the bill, carries no estimate. Clear any stale one first so
  -- a lot that has since gone to zero stops claiming a remainder.
  delete from public.pharmacy_lot_inference li
   using public.pharmacy_stock s
   where li.lot_id = s.id and li.pharmacy_id = p_shop
     and (s.qty <= 0 or coalesce(s.is_unquantified, false) or s.medicine_id is null);

  -- FEFO order, with a CLOCK. A lot cannot sell before it arrives and cannot
  -- start selling before the lot in front of it has run out, so the pour walks
  -- forward in time: each lot absorbs only the demand generated while it was
  -- actually the front of the queue.
  for r in
    select s.id as lot_id, s.medicine_id, s.qty as qty_in, s.received_on, s.expiry_on,
           coalesce(v.per_day, 0)               as per_day,
           coalesce(v.alpha, v_cfg.prior_shape) as alpha,
           coalesce(v.beta,  v_cfg.prior_rate)  as beta,
           coalesce(v.source, 'prior')          as vsource,
           c.actual_left,
           (select coalesce(sum(sl.qty), 0)
              from public.pos_sale_lines sl
              join public.pos_sales ps on ps.id = sl.sale_id
             where ps.pharmacy_id = p_shop and ps.status = 'completed'
               and sl.medicine_id = s.medicine_id
               and ps.sold_on >= coalesce(
                     (select min(s2.received_on) from public.pharmacy_stock s2
                       where s2.pharmacy_id = p_shop and s2.medicine_id = s.medicine_id
                         and s2.qty > 0),
                     v_today)) as pos_units,
           (select count(*) from public.pos_sale_lines sl
              join public.pos_sales ps on ps.id = sl.sale_id
             where ps.pharmacy_id = p_shop and ps.status = 'completed'
               and sl.medicine_id = s.medicine_id) as pos_lines,
           (select min(s2.received_on) from public.pharmacy_stock s2
             where s2.pharmacy_id = p_shop and s2.medicine_id = s.medicine_id
               and s2.qty > 0) as sku_first_on
      from public.pharmacy_stock s
      left join public.pharmacy_sku_velocity v
        on v.pharmacy_id = s.pharmacy_id and v.medicine_id = s.medicine_id
      left join lateral (
        select actual_left from public.pharmacy_lot_correction
         where lot_id = s.id order by created_at desc limit 1) c on true
     where s.pharmacy_id = p_shop and s.medicine_id is not null
       and s.qty > 0                                   -- CHANGE #442
       and coalesce(s.is_unquantified, false) = false  -- CHANGE #442
     order by s.medicine_id,
              s.expiry_on nulls last,      -- FEFO: earliest expiry leaves first
              s.received_on nulls last,
              s.id
  loop
    if v_sku is distinct from r.medicine_id then
      v_sku  := r.medicine_id;
      v_clock := coalesce(r.sku_first_on, r.received_on, v_today);
      if r.pos_lines > 0 then
        v_rate := case when (v_today - v_clock) > 0
                       then r.pos_units / (v_today - v_clock)::numeric else 0 end;
      else
        v_rate := coalesce(r.per_day, 0);
      end if;
    end if;

    v_start := greatest(v_clock, coalesce(r.received_on, v_today));
    v_days  := greatest((v_today - v_start)::numeric, 0);
    v_demand := greatest(v_rate * v_days, 0);
    v_method := case when r.pos_lines > 0 then 'pos_actual' else 'inferred' end;

    if r.actual_left is not null then
      -- Ground truth outranks the estimate, and it is still bounded by the lot:
      -- "twelve left" on a lot of ten is a typo, not a discovery.
      v_left := least(greatest(r.actual_left, 0), r.qty_in);
      v_take := greatest(r.qty_in - v_left, 0);
      v_clock := case when v_rate > 0
                      then v_start + (v_take / v_rate)::int else v_today end;
      insert into public.pharmacy_lot_inference as li
        (lot_id, pharmacy_id, medicine_id, received_on, expiry_on, qty_in,
         inferred_sold, inferred_left, left_low, left_high, confidence, method,
         per_day, days_live, computed_at)
      values (r.lot_id, p_shop, r.medicine_id, r.received_on, r.expiry_on, r.qty_in,
              v_take, v_left, v_left, v_left, 1.0, 'corrected',
              v_rate, v_days, now())
      on conflict (lot_id) do update
        set inferred_sold = excluded.inferred_sold, inferred_left = excluded.inferred_left,
            left_low = excluded.left_low, left_high = excluded.left_high,
            confidence = 1.0, method = 'corrected', qty_in = excluded.qty_in,
            expiry_on = excluded.expiry_on, received_on = excluded.received_on,
            medicine_id = excluded.medicine_id,
            per_day = excluded.per_day, days_live = excluded.days_live,
            computed_at = now();
      v_n := v_n + 1;
      continue;
    end if;

    -- CHANGE #442 — every number below is clamped to its own definition:
    -- 0 <= sold <= qty_in, left = qty_in - sold, and low <= left <= high.
    v_take := least(greatest(v_demand, 0), r.qty_in);
    v_left := greatest(r.qty_in - v_take, 0);
    v_clock := case when v_rate > 0 and v_take >= r.qty_in
                    then v_start + (r.qty_in / v_rate)::int
                    else v_today end;

    v_sd := v_days * sqrt(greatest(r.alpha, 0.0001)) / greatest(r.beta, 0.0001);
    v_cv := case when v_take > 0 then v_sd / v_take else 1.0 end;
    v_conf := case
                when r.pos_lines > 0 then 0.95
                when r.vsource = 'own'  then greatest(0.15, least(0.9, 1 - v_cv))
                when r.vsource = 'zone' then greatest(0.15, least(0.6, 1 - v_cv))
                else 0.2 end;
    v_low  := greatest(v_left - 1.2816 * v_sd, 0);
    v_high := least(greatest(v_left + 1.2816 * v_sd, v_low), r.qty_in);

    insert into public.pharmacy_lot_inference as li
      (lot_id, pharmacy_id, medicine_id, received_on, expiry_on, qty_in,
       inferred_sold, inferred_left, left_low, left_high, confidence, method,
       per_day, days_live, computed_at)
    values (r.lot_id, p_shop, r.medicine_id, r.received_on, r.expiry_on, r.qty_in,
            round(v_take, 2), round(v_left, 2), round(v_low, 2), round(v_high, 2),
            round(v_conf, 3), v_method, v_rate, v_days, now())
    on conflict (lot_id) do update
      set medicine_id = excluded.medicine_id, received_on = excluded.received_on,
          expiry_on = excluded.expiry_on, qty_in = excluded.qty_in,
          inferred_sold = excluded.inferred_sold, inferred_left = excluded.inferred_left,
          left_low = excluded.left_low, left_high = excluded.left_high,
          confidence = excluded.confidence, method = excluded.method,
          per_day = excluded.per_day, days_live = excluded.days_live,
          computed_at = now()
      where li.method <> 'corrected';
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'lots', v_n);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

revoke execute on function public.pharmacy_infer_lots(uuid) from public, anon, authenticated;

-- ── 2. the same guard where a correction lands ──────────────────────────────
-- A correction wrote straight through to the lot, so "12 left" on a lot of ten
-- would have stored an impossible remainder and taught the posterior a negative
-- sale. It is bounded here as well as in the pour, because the pour is not the
-- only door.
create or replace function public._c424_correct(p_shop uuid, p_lot_id uuid, p_left numeric)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := p_shop;
  v_lot record; v_sold numeric; v_days numeric; v_was numeric; v_left numeric;
begin
  if v_shop is null then return public._c424_denied(); end if;
  if p_lot_id is null or p_left is null or p_left < 0 then
    return jsonb_build_object('ok', false, 'tone', 'danger',
      'message', public.ui_text('infer424.correct_failed'));
  end if;

  select s.id, s.medicine_id, s.qty, s.received_on
    into v_lot
    from public.pharmacy_stock s
   where s.id = p_lot_id and s.pharmacy_id = v_shop;
  if found and (v_lot.medicine_id is null or coalesce(v_lot.qty, 0) <= 0) then
    -- Nothing to teach: a lot with no SKU, or a shelf line with nothing on it.
    return jsonb_build_object('ok', false, 'tone', 'danger',
      'message', public.ui_text('infer424.correct_failed'));
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'tone', 'danger',
      'message', public.ui_text('infer424.correct_failed'));
  end if;

  select inferred_left into v_was from public.pharmacy_lot_inference where lot_id = p_lot_id;

  v_left := least(p_left, coalesce(v_lot.qty, 0));   -- CHANGE #442
  v_sold := greatest(coalesce(v_lot.qty, 0) - v_left, 0);
  v_days := greatest((public._c424_today() - coalesce(v_lot.received_on,
                       public._c424_today()))::numeric, 1);

  insert into public.pharmacy_lot_correction
    (lot_id, pharmacy_id, medicine_id, actual_left, inferred_was, source, created_by)
  values (p_lot_id, v_shop, v_lot.medicine_id, v_left, v_was, 'alert', auth.uid());

  insert into public.pharmacy_sku_velocity as v
    (pharmacy_id, medicine_id, alpha, beta, per_day, units_seen, days_seen,
     source, corrections, updated_at)
  values (v_shop, v_lot.medicine_id,
          (select prior_shape from public.pharmacy_infer_config where id) + v_sold,
          (select prior_rate  from public.pharmacy_infer_config where id) + v_days,
          v_sold / v_days, v_sold, v_days, 'corrected', 1, now())
  on conflict (pharmacy_id, medicine_id) do update
    set alpha = v.alpha + v_sold,
        beta  = v.beta  + v_days,
        per_day = (v.alpha + v_sold) / nullif(v.beta + v_days, 0),
        units_seen = v.units_seen + v_sold,
        days_seen  = v.days_seen  + v_days,
        source = 'corrected',
        corrections = v.corrections + 1,
        updated_at = now();

  perform public.pharmacy_infer_lots(v_shop);

  return jsonb_build_object('ok', true, 'tone', 'success',
    'left', v_left,
    'message', public.ui_text_f('infer424.corrected',
                 jsonb_build_object('n', public._c424_qty(v_left))));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM, 'tone', 'danger',
                            'message', public.ui_text('infer424.correct_failed'));
end $$;

revoke execute on function public._c424_correct(uuid, uuid, numeric) from public, anon, authenticated;

-- ── 3. clear the rows the old pour already wrote ────────────────────────────
delete from public.pharmacy_lot_inference li
 using public.pharmacy_stock s
 where li.lot_id = s.id
   and (s.qty <= 0 or coalesce(s.is_unquantified, false) or s.medicine_id is null);

delete from public.pharmacy_lot_inference
 where inferred_sold < 0 or inferred_left < 0
    or inferred_left > qty_in or left_low > left_high;

-- ── 4. the invariants join the journey, so the class is retired ─────────────
create or replace function public._journey_c424_shop_fence()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean;
        v_open text; v_missing text; v_broken integer;
begin
  -- 1. No function in this feature that takes a shop id as an ARGUMENT may be
  --    executable by a client (the #424 blocker).
  select string_agg(p.proname, ', ') into v_open
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proname like 'pharmacy\_%' or p.proname like '\_c424\_%')
     and pg_get_function_identity_arguments(p.oid) like '%uuid%'
     and pg_get_function_identity_arguments(p.oid) like '%p_shop%'
     and p.prosrc like '%c424%'
     and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
          or has_function_privilege('anon', p.oid, 'EXECUTE'));
  a1 := v_open is null;

  -- 2. The two client surfaces still resolve the shop from the SESSION.
  select string_agg(x.fn, ', ') into v_missing
    from (values ('pharmacy_inference_screen'), ('pharmacy_lot_correct')) x(fn)
   where not exists (
     select 1 from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = x.fn
        and p.prosrc like '%pos_shop()%'
        and has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  a2 := v_missing is null;

  -- 3. The fixture still reproduces the spec's numbers.
  a3 := coalesce((public.c424_montikop_proof() ->> 'ok')::boolean, false);

  -- 4. CHANGE #442 — every STORED estimate obeys its own definition. An
  --    oversold shelf line (qty < 0) once produced sold = -3 and a band whose
  --    top was below its bottom, and nothing on screen could have shown it.
  select count(*) into v_broken
    from public.pharmacy_lot_inference
   where inferred_sold < 0
      or inferred_left < 0
      or inferred_left > qty_in
      or left_low > left_high
      or left_low > inferred_left
      or left_high < inferred_left
      or confidence < 0 or confidence > 1;
  a4 := v_broken = 0;

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'no shop-id engine function is client-reachable=' || a1::text
   || coalesce(' -> ' || v_open, '')
   || ' | both session-scoped surfaces reachable=' || a2::text
   || coalesce(' -> missing ' || v_missing, '')
   || ' | montikop fixture still green=' || a3::text
   || ' | stored estimates breaking their own invariants=' || v_broken::text));
end $$;

revoke execute on function public._journey_c424_shop_fence() from public, anon, authenticated;

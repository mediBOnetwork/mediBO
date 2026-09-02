-- CMD #464 — MEDIUM defects, supplier surface, batch A (feature_gaps 32,44,45,46,47,48).
-- Idempotent: every statement is create-or-replace / if-not-exists / on-conflict.

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 32 — ordered_medicine_points was structurally always zero.
--
-- Both point-writers joined the basket's marketers to company.S1_name ..
-- S100_name.  Those columns DO NOT EXIST on company (0 of its 236 columns match
-- ^S[0-9]+_name$), so `to_jsonb(mc) ->> 'S1_name'` returned NULL for all 3,400
-- slot reads and the coverage CTE was empty on every run.  All 37 supplier rows
-- therefore sat on 0 for one of the five SPN components.
--
-- supplier_company is the live company↔supplier map (1,222 rows, every one with
-- a supplier_id) and is what the coverage join should always have read.  It also
-- joins on supplier_id, so a supplier whose supplier_name is punctuated
-- differently in the two tables is no longer silently dropped.
-- ─────────────────────────────────────────────────────────────────────────────

-- One definition of "which suppliers cover this basket, and for how much",
-- shared by the cron refresher and the trigger recompute so the two can never
-- drift apart again.
create or replace function public.supplier_omp_coverage()
returns table (supplier_id uuid, pts bigint)
language sql
stable
as $$
  with basket as (
    select lower(btrim(m.marketer)) as marketer_key,
           coalesce(i.mrp,
                    nullif(regexp_replace(m.mrp, '[^0-9.]', '', 'g'), '')::numeric,
                    0) * coalesce(i.quantity, 0) as line_value
    from inquiry i
    join "MEDICINE" m on m.id = i.product_id
    where coalesce(i.inquiry_phase,'draft') <> 'sent'
      and i.product_id is not null
  ),
  declared as (
    select sc.supplier_id, lower(btrim(j.cname)) as company_key
    from public.supplier_company sc
    cross join lateral (
      select (to_jsonb(sc) ->> ('company_'||g)) as cname
      from generate_series(1,30) g
    ) j
    where sc.supplier_id is not null
      and j.cname is not null and btrim(j.cname) <> ''
  )
  select d.supplier_id, round(sum(b.line_value))::bigint as pts
  from basket b
  join declared d on d.company_key = b.marketer_key
  group by d.supplier_id;
$$;

comment on function public.supplier_omp_coverage() is
  'cmd #464 gap 32: basket value covered per supplier, from supplier_company. '
  'Replaces the dead company.S1_name..S100_name join, which read columns that '
  'do not exist and returned zero on every run.';

create or replace function public.refresh_ordered_medicine_points()
returns void
language plpgsql
security definer
set search_path = books, public
as $$
DECLARE
  v_dirty boolean;
  v_basket int;
  v_changed int := 0;
BEGIN
  select dirty into v_dirty from public.job_dirty_state where job='ordered_medicine_points';
  if not coalesce(v_dirty, true) then
    return;                       -- nothing changed since last run
  end if;
  -- clear FIRST so concurrent writes re-dirty and nothing is missed
  update public.job_dirty_state set dirty=false where job='ordered_medicine_points';

  select count(*) into v_basket
    from inquiry
   where coalesce(inquiry_phase,'draft') <> 'sent' and product_id is not null;

  if v_basket = 0 then
    update supplier_profiles set ordered_medicine_points = 0
     where coalesce(ordered_medicine_points,0) <> 0;
    update public.job_dirty_state
       set last_run_at=now(), last_result=jsonb_build_object('skipped','empty_basket')
     where job='ordered_medicine_points';
    return;
  end if;

  -- cmd #464 gap 32: coverage comes from supplier_company via supplier_id.
  UPDATE supplier_profiles sp
  SET ordered_medicine_points = COALESCE(cov.pts, 0)
  FROM (
    SELECT sp2.id, c2.pts
    FROM supplier_profiles sp2
    LEFT JOIN public.supplier_omp_coverage() c2 ON c2.supplier_id = sp2.id
  ) cov
  WHERE cov.id = sp.id AND sp.ordered_medicine_points IS DISTINCT FROM COALESCE(cov.pts, 0);

  GET DIAGNOSTICS v_changed = ROW_COUNT;

  -- cmd #526 gap 33: current_supplier ONLY — see recompute_ordered_medicine_points().
  -- Naming product_id here is what re-dirtied the job it had just cleared.
  IF v_changed > 0 THEN
    UPDATE inquiry
       SET current_supplier = current_supplier
     WHERE COALESCE(inquiry_phase,'draft') <> 'sent';
  END IF;

  update public.job_dirty_state
     set last_run_at=now(),
         last_result=jsonb_build_object('suppliers_changed', v_changed, 'basket_rows', v_basket)
   where job='ordered_medicine_points';
END;
$$;

create or replace function public.recompute_ordered_medicine_points()
returns trigger
language plpgsql
set search_path = books, public
as $$
BEGIN
  IF current_setting('medibo.dynspn', true) = '1' THEN
    RETURN NULL;
  END IF;
  PERFORM set_config('medibo.dynspn', '1', true);

  -- cmd #464 gap 32: same coverage definition as the cron refresher.
  UPDATE supplier_profiles sp
  SET ordered_medicine_points = COALESCE(cov.pts, 0)
  FROM (
    SELECT sp2.id, c2.pts
    FROM supplier_profiles sp2
    LEFT JOIN public.supplier_omp_coverage() c2 ON c2.supplier_id = sp2.id
  ) cov
  WHERE cov.id = sp.id
    AND sp.ordered_medicine_points IS DISTINCT FROM COALESCE(cov.pts, 0);

  -- cmd #526 gap 33: current_supplier ONLY. Naming product_id here re-armed
  -- trg_inquiry_omp_dirty and re-dirtied the job this statement just finished.
  UPDATE inquiry
  SET current_supplier = current_supplier
  WHERE COALESCE(inquiry_phase,'draft') <> 'sent';

  -- ...and finish the job in the same pass that did the work, so the flag
  -- reflects reality instead of the write above.
  UPDATE public.job_dirty_state
     SET dirty = false, last_run_at = now()
   WHERE job = 'ordered_medicine_points';

  RETURN NULL;
END;
$$;

revoke all on function public.supplier_omp_coverage() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 47 — re-inquiry wrote an answer the supplier never gave.
--
-- _reinquiry_exclude_and_advance stamped the literal 'Out of Stock' into the
-- excluded supplier's AS slot purely so the cascade would step past it.  The
-- supplier had said Available and then short-supplied; the record then read as
-- if they had declined, and that is the answer their own read-only receipt
-- renders.  A distinct state advances the cascade without putting words in
-- their mouth.
--
-- compute_current_supplier_fx already treats anything that is not NULL/''/
-- 'Available' as ineligible, so the new state skips there with no change;
-- advance_to_next_supplier's skip list is explicit and is extended below.
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.app_settings (key, value)
values ('inquiry_short_supply_answer', to_jsonb('Short supplied'::text))
on conflict (key) do nothing;

create or replace function public.inquiry_short_supply_answer()
returns text
language sql
stable
as $$
  select coalesce(
    (select value #>> '{}' from public.app_settings where key='inquiry_short_supply_answer'),
    'Short supplied');
$$;

revoke all on function public.inquiry_short_supply_answer() from public, anon, authenticated;
grant execute on function public.inquiry_short_supply_answer() to anon, authenticated, service_role;

-- The badge the supplier's receipt renders for the new state. Same source the
-- other three answers already read, so nothing is worded in Dart.
update public.app_settings
   set value = value || jsonb_build_object(
         lower(public.inquiry_short_supply_answer()),
         jsonb_build_object('label','Short supplied','bg','#FEF3C7','fg','#92400E'))
 where key = 'inquiry_answer_badges'
   and not (value ? lower(public.inquiry_short_supply_answer()));

create or replace function public._reinquiry_exclude_and_advance(
  p_product_id bigint, p_exclude_supplier text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_id bigint; r inquiry%rowtype; i int; ps_val text; v_missing numeric;
        v_short text := public.inquiry_short_supply_answer();
begin
  v_id := public._reinquiry_pick(p_product_id, p_exclude_supplier);
  if v_id is null then return; end if;

  select coalesce(sum(greatest(coalesce(quantity,0) - coalesce(received_qty,0),0)),0)
    into v_missing
    from order_items
   where product_id = p_product_id
     and (assigned_supplier is null or assigned_supplier = p_exclude_supplier)
     and fulfillment_state not in ('shipped','cancelled');

  if v_missing <= 0 then
    insert into receiving_log(order_item_id, order_id, supplier_name, action, qty, note, actor)
    select oi.id, oi.order_id, p_exclude_supplier, 'rebuy_skipped_fully_received', 0,
           'c345 guard: no shortfall, cascade NOT advanced', 'system'
      from order_items oi
     where oi.product_id = p_product_id and oi.assigned_supplier = p_exclude_supplier
       and oi.fulfillment_state not in ('shipped','cancelled') limit 1;
    return;
  end if;

  select * into r from inquiry where id = v_id;
  for i in 1..30 loop
    execute format('select ($1).%I','PS'||i) into ps_val using r;
    if ps_val is null or btrim(ps_val) = '' then exit; end if;
    if lower(btrim(ps_val)) = lower(btrim(p_exclude_supplier)) then
      -- cmd #464 gap 47: the cascade advances on a SHORT SUPPLY state. Writing
      -- 'Out of Stock' here rewrote an answer the supplier never gave.
      execute format('update inquiry set %I = %L where id = %s','AS'||i, v_short, v_id);
    end if;
  end loop;
  update inquiry set quantity = v_missing where id = v_id;
  perform advance_to_next_supplier(v_id);
end;
$$;

create or replace function public.advance_to_next_supplier(p_id bigint)
returns void
language plpgsql
as $$
DECLARE r inquiry%ROWTYPE; i int; ps_val text; as_val text;
        cur text; nxt text; found int := 0;
        v_short text := public.inquiry_short_supply_answer();
BEGIN
  SELECT * INTO r FROM inquiry WHERE id = p_id;
  FOR i IN 1..30 LOOP
    EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING r;
    IF ps_val IS NULL OR btrim(ps_val)='' THEN EXIT; END IF;
    -- cmd #464 gap 47: a short supply steps the cascade on exactly like an
    -- 'Out of Stock', without claiming the supplier said it.
    IF as_val='Out of Stock' OR as_val='We don''t stock this product'
       OR as_val = v_short THEN CONTINUE; END IF;
    found := found + 1;
    IF found = 1 THEN cur := ps_val;
    ELSIF found = 2 THEN nxt := ps_val; EXIT; END IF;
  END LOOP;
  UPDATE inquiry SET current_supplier = cur, next_supplier = nxt, asked_at = now()
  WHERE id = p_id;

  -- dead-end surfacing, scoped to THIS inquiry's date and zone
  IF cur IS NULL THEN
    UPDATE order_items oi
       SET fulfillment_state = 'unfillable'
      FROM orders o
     WHERE o.id = oi.order_id
       AND oi.product_id = r.product_id
       AND oi.assigned_supplier IS NULL
       AND oi.fulfillment_state = 'pending'
       AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = r.batch_date
       AND (r.zone_id IS NULL OR oi.zone_id = r.zone_id);
  END IF;
END;
$$;

-- The state is a cascade fact, never a stock answer: it must not become the
-- pre-tick on the supplier's NEXT inquiry.
delete from public.supplier_item_memory
 where last_answer = public.inquiry_short_supply_answer();

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 48 — ranking ties broke alphabetically, forever.
--
-- inquiry_engine_ranked_suppliers ordered by SPN DESC, p.sup. Eight suppliers
-- sit on SPN 335000, three on 735000 and twelve on 0, so the same name won the
-- tier on every single sync and the others were never given a first look.
--
-- Ties now rotate on least-recently-asked. A supplier holding a LIVE window
-- keeps rank 1 for as long as that window is open, so rotation decides who gets
-- the NEXT window and never switches suppliers mid-window.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.supplier_profiles
  add column if not exists last_asked_at timestamptz;

comment on column public.supplier_profiles.last_asked_at is
  'cmd #464 gap 48: when the inquiry engine last opened a window for this '
  'supplier. Least-recently-asked breaks an SPN tie so tied suppliers rotate.';

create or replace function public.inquiry_engine_ranked_suppliers()
returns table (supplier_name text, spn integer, pending_items integer, rnk integer, is_open boolean)
language plpgsql
security definer
set search_path = public
as $$
DECLARE v_bundle boolean;
BEGIN
  v_bundle := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_bundle_mode'), false);
  RETURN QUERY
  WITH pend AS (
    SELECT i.current_supplier AS sup,
           i.zone_id          AS zid,
           count(*)::int      AS pend_items,
           max(COALESCE(i.mrp,0)) AS top_mrp
    FROM inquiry i
    WHERE i.current_supplier IS NOT NULL AND btrim(i.current_supplier) <> ''
      AND i.supplier_order_id IS NULL
      AND COALESCE(i.current_status,'') <> 'Available'
      AND inquiry_demand_qty(i.product_id, i.current_supplier, true) > 0
    GROUP BY i.current_supplier, i.zone_id
  ),
  ranked AS (
    SELECT p.sup, p.zid,
           COALESCE(sp."SPN",0)::int AS spn_val,
           p.pend_items,
           row_number() OVER (
             PARTITION BY p.zid
             ORDER BY CASE WHEN v_bundle THEN p.top_mrp ELSE COALESCE(sp."SPN",0)::numeric END DESC,
                      -- cmd #464 gap 48: an OPEN, unexpired window keeps its
                      -- holder first. Rotation picks who gets the next window,
                      -- it never moves the waterfall mid-window.
                      CASE WHEN f.status = 'pending' AND f.expires_at > now()
                           THEN 0 ELSE 1 END,
                      -- ...then least-recently-asked, so tied suppliers rotate
                      -- instead of the alphabet deciding forever.
                      COALESCE(sp.last_asked_at, '-infinity'::timestamptz) ASC,
                      p.sup)::int AS rnk_val
    FROM pend p
    LEFT JOIN supplier_profiles sp
           ON sp.supplier_name = p.sup
          AND sp.zone_id IS NOT DISTINCT FROM p.zid
    LEFT JOIN inquiry_forms f
           ON f.supplier_name = p.sup
  )
  SELECT r.sup, r.spn_val, r.pend_items, r.rnk_val, (r.rnk_val = 1)
  FROM ranked r ORDER BY r.zid, r.rnk_val;
END;
$$;

create or replace function public.inquiry_engine_sync()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_lock boolean; v_engine boolean; v_auto boolean; r record;
  v_drafted int := 0; v_sent int := 0; v_opens jsonb := '[]'::jsonb;
BEGIN
  v_engine := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_engine_mode'), false);
  IF NOT v_engine THEN RETURN jsonb_build_object('engine','off'); END IF;

  v_lock := public.inquiry_any_locked();
  IF NOT v_lock THEN
    UPDATE inquiry_forms SET status='draft', expires_at=NULL, auto_wa_sent_at=NULL
     WHERE status NOT IN ('responded','partially_responded');
    UPDATE inquiry SET asked_at=NULL WHERE asked_at IS NOT NULL;
    RETURN jsonb_build_object('engine','on','lock','off','action','all_draft');
  END IF;

  v_auto := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_auto_meta'), false);

  -- draft everyone who is not their zone's open supplier
  FOR r IN SELECT rs.supplier_name AS s FROM inquiry_engine_ranked_suppliers() rs WHERE NOT rs.is_open LOOP
    UPDATE inquiry_forms SET status='draft', expires_at=NULL, auto_wa_sent_at=NULL
     WHERE supplier_name=r.s AND status NOT IN ('responded','partially_responded');
    UPDATE inquiry SET asked_at=NULL
     WHERE current_supplier=r.s AND supplier_order_id IS NULL AND asked_at IS NOT NULL;
    v_drafted := v_drafted + 1;
  END LOOP;

  -- open ONE supplier per zone
  IF v_auto THEN
    FOR r IN SELECT rs.supplier_name AS s FROM inquiry_engine_ranked_suppliers() rs WHERE rs.is_open LOOP
      v_opens := v_opens || to_jsonb(r.s);

      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
      VALUES (r.s, now(), now()+interval '10 minutes','pending')
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        status = CASE WHEN inquiry_forms.status IN ('responded','partially_responded')
                      THEN inquiry_forms.status ELSE 'pending' END,
        last_sent_at = COALESCE(inquiry_forms.last_sent_at, now()),
        expires_at   = COALESCE(inquiry_forms.expires_at, now()+interval '10 minutes');

      -- cmd #464 gap 48: stamp the rotation clock the moment a window opens.
      -- The open-window key in inquiry_engine_ranked_suppliers keeps this
      -- supplier at rank 1 until the window closes, so the fresh timestamp
      -- decides only who is asked NEXT.
      UPDATE supplier_profiles SET last_asked_at = now() WHERE supplier_name = r.s;

      UPDATE inquiry SET asked_at = COALESCE(asked_at, now())
       WHERE current_supplier=r.s AND supplier_order_id IS NULL;

      IF NOT EXISTS (SELECT 1 FROM inquiry_forms WHERE supplier_name=r.s AND auto_wa_sent_at IS NOT NULL) THEN
        PERFORM send_supplier_inquiry_wa(r.s);
        UPDATE inquiry_forms SET auto_wa_sent_at=now() WHERE supplier_name=r.s AND status='pending';
        v_sent := v_sent + 1;
      END IF;
    END LOOP;
  ELSE
    SELECT coalesce(jsonb_agg(rs.supplier_name),'[]'::jsonb) INTO v_opens
    FROM inquiry_engine_ranked_suppliers() rs WHERE rs.is_open;
  END IF;

  RETURN jsonb_build_object('engine','on',
    'mode', CASE WHEN v_auto THEN 'auto' ELSE 'manual' END,
    'open', v_opens->>0,                -- legacy key, first zone's open supplier
    'open_by_zone', v_opens,
    'others_drafted', v_drafted,
    'wa_send_fired', (v_sent > 0),
    'wa_sends', v_sent);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 44 — the public supplier form scanned the whole inquiry table per load.
--
-- _get_inquiry_form_core ran `FOR r IN SELECT * FROM inquiry LOOP` and, per row,
-- up to 30 dynamic `EXECUTE format('select ($1).PSn, ($1).ASn')` calls, then a
-- per-row inquiry_demand_qty() (which itself scans order_items) and a per-row
-- MEDICINE lookup. Measured on live data: 175 ms to return an EMPTY item list.
--
-- The slots are unpivoted ONCE per row via to_jsonb, demand is one joined
-- aggregate, and MEDICINE / supplier_item_memory are ordinary joins.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.inquiry_demand_qty_map(
  p_supplier text, p_today_only boolean default true)
returns table (product_id bigint, qty numeric)
language sql
stable
set search_path = public
as $$
  with sz as (
    select sp.zone_id
    from supplier_profiles sp
    where lower(btrim(sp.supplier_name)) = lower(btrim(p_supplier))
      and not coalesce(sp.is_deleted,false)
    limit 1
  )
  select oi.product_id, sum(oi.quantity)::numeric
  from order_items oi
  join orders o on o.id = oi.order_id
  where o.status = 'accepted'
    and o.fulfillment_status not in ('shipped','cancelled')
    and coalesce(oi.received_qty,0) = 0
    and not coalesce(oi.collect_locked,false)
    and not coalesce(oi.received_locked,false)
    and not coalesce(oi.at_warehouse,false)
    and oi.fulfillment_state not in ('received','packed','shipped','short','wrong','not_coming')
    and (oi.zone_id IS NOT DISTINCT FROM (select zone_id from sz)
         or (select zone_id from sz) is null)
    and exists (
      select 1 from inquiry i
       where i.product_id = oi.product_id
         and i.batch_date = oi.order_date
         and i.current_supplier = p_supplier
         and i.zone_id IS NOT DISTINCT FROM oi.zone_id)
    and ( not p_today_only
          or oi.order_date = (now() at time zone 'Asia/Kolkata')::date )
  group by oi.product_id;
$$;

comment on function public.inquiry_demand_qty_map(text, boolean) is
  'cmd #464 gap 44: the set-based twin of inquiry_demand_qty — one aggregate '
  'for every product a supplier is currently being asked about, instead of one '
  'order_items scan per inquiry row.';

revoke all on function public.inquiry_demand_qty_map(text, boolean) from public, anon, authenticated;

create or replace function public._get_inquiry_form_core(p_token text, p_secret text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_supplier text; v_status text; v_expires timestamptz;
  v_items jsonb := '[]'::jsonb; n_pre int := 0;
  v_receipt jsonb; v_r jsonb; v_gate jsonb;
BEGIN
  SELECT f.supplier_name, f.status, f.expires_at INTO v_supplier, v_status, v_expires
  FROM inquiry_forms f WHERE f.token = p_token;

  IF NOT FOUND THEN
    v_r := public.resolve_code(p_token, p_secret);
    IF v_r ? 'token' THEN
      p_token  := v_r->>'token';
      -- resolve_code already validated the secret it found in the URL; carry it
      -- forward so the gate below sees the same second factor.
      p_secret := COALESCE(NULLIF(btrim(COALESCE(p_secret,'')),''), v_r->>'secret');
      SELECT f.supplier_name, f.status, f.expires_at INTO v_supplier, v_status, v_expires
      FROM inquiry_forms f WHERE f.token = p_token;
    END IF;
    IF v_supplier IS NULL THEN RETURN jsonb_build_object('error','invalid'); END IF;
  END IF;

  -- cmd #526 gap 28: ONE gate owns expiry + the link_secret second factor, and
  -- an ABSENT expires_at now reads as expired rather than as "forever".
  v_gate := public._inquiry_form_gate(p_token, p_secret);
  IF NOT (v_gate->>'ok')::boolean THEN
    IF v_gate->>'error' = 'expired' AND v_status IS DISTINCT FROM 'expired' THEN
      UPDATE inquiry_forms SET status='expired' WHERE inquiry_forms.token = p_token;
    END IF;
    RETURN jsonb_build_object('error', v_gate->>'error');
  END IF;

  -- cmd #464 gap 44: ONE set-based pass. The PS/AS slots are unpivoted once per
  -- inquiry row (to_jsonb, not 30 dynamic EXECUTEs), demand is one joined
  -- aggregate instead of a per-row order_items scan, and MEDICINE /
  -- supplier_item_memory are ordinary joins.
  WITH slot AS (
    SELECT i.id, i.product_id, i.product_name, i.supplier_order_id, i.batch_date,
           i.current_supplier, s.slot_n, s.as_val
    FROM inquiry i
    CROSS JOIN LATERAL (
      SELECT g AS slot_n, (to_jsonb(i) ->> ('AS'||g)) AS as_val
      FROM generate_series(1,30) g
      WHERE (to_jsonb(i) ->> ('PS'||g)) = v_supplier
      ORDER BY g
      LIMIT 1
    ) s
  ),
  keep AS (
    SELECT s.*
    FROM slot s
    WHERE (s.current_supplier IS NOT DISTINCT FROM v_supplier OR s.as_val IS NOT NULL)
      AND NOT public.inq_is_ordered(s.supplier_order_id, s.batch_date)
  ),
  demand AS (
    SELECT d.product_id, d.qty FROM public.inquiry_demand_qty_map(v_supplier, true) d
  ),
  built AS (
    SELECT
      k.id, k.product_id, k.product_name, k.slot_n, k.as_val, dm.qty,
      COALESCE(NULLIF(btrim(med.pack_size),''), NULLIF(btrim(med.pack_type),'')) AS m_pack,
      NULLIF(btrim(med.therapeutic_class),'') AS m_therap,
      NULLIF(btrim(med.marketer),'')          AS m_company,
      NULLIF(btrim(med.image_url_1),'')       AS m_image,
      mem.last_answer                         AS mem
    FROM keep k
    JOIN demand dm ON dm.product_id = k.product_id AND dm.qty > 0
    LEFT JOIN "MEDICINE" med ON med.id = k.product_id
    LEFT JOIN supplier_item_memory mem
           ON mem.supplier_name = v_supplier AND mem.product_id = k.product_id
  ),
  shaped AS (
    SELECT b.*,
           CASE WHEN b.as_val IS NOT NULL THEN b.as_val
                WHEN b.mem = 'Available'  THEN 'Available' END AS v_default,
           CASE WHEN b.as_val IS NOT NULL THEN NULL
                WHEN b.mem = 'Available'  THEN public.uic('inquiry_form.memory_hint_available',
                                              'You had this in stock last time')
                WHEN b.mem = 'Out of Stock' THEN public.uic('inquiry_form.memory_hint_oos',
                                              'You were out of stock last time') END AS v_hint
    FROM built b
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'inquiry_id', sh.id, 'product_id', sh.product_id,
      'product_name', sh.product_name,
      'quantity', sh.qty,
      'pack_size', sh.m_pack, 'therapeutic_class', sh.m_therap,
      'company', sh.m_company, 'image_url', sh.m_image,
      'slot', sh.slot_n, 'slot_index', sh.slot_n,
      'answer', sh.as_val, 'locked', (sh.as_val IS NOT NULL),
      'flags', public.inquiry_item_flags(sh.slot_n, 'current', (sh.as_val IS NOT NULL), false),
      -- cmd #464 gap 46: the answer badge is the backend's, from the same
      -- app_settings map every other surface reads. Dart no longer switches.
      'badge', public.inquiry_answer_badge(sh.as_val),
      'default_answer', sh.v_default, 'last_answer', sh.mem, 'memory_hint', sh.v_hint)
      -- SINGLE SOURCE OF TRUTH: company A-Z -> therapeutic_class A-Z -> name A-Z
      ORDER BY lower(coalesce(nullif(sh.m_company,''),'zzz')) ASC,
               lower(coalesce(nullif(sh.m_therap,''),'zzz')) ASC,
               lower(coalesce(sh.product_name,'')) ASC), '[]'::jsonb),
    COUNT(*) FILTER (WHERE sh.as_val IS NULL AND sh.mem = 'Available')::int
  INTO v_items, n_pre
  FROM shaped sh;

  SELECT jsonb_agg(jsonb_build_object(
           'product_id',   rc.product_id,
           'product_name', rc.product_name,
           'company',      rc.company,
           'image_url',    rc.image_url,
           'answer',       rc.answer,
           'badge',        public.inquiry_answer_badge(rc.answer)))
    INTO v_receipt
  FROM get_supplier_inquiry_receipt(v_supplier) rc;

  RETURN jsonb_build_object(
    'supplier_name', v_supplier, 'status', v_status, 'expires_at', v_expires,
    'items', COALESCE(v_items,'[]'::jsonb),
    'submitted', (v_status IN ('responded','partially_responded')),
    'submitted_items', COALESCE(v_receipt,'[]'::jsonb),
    'prefilled', n_pre,
    'prefill_note', CASE WHEN n_pre > 0 THEN
      public.uicf('inquiry_form.prefill_note',
                  jsonb_build_object('a', n_pre),
                  '{a} item(s) pre-filled from your last reply — check and submit.') END,
    'answer_options', jsonb_build_array(
      'Available','Out of Stock','We don''t stock this product'),
    'dont_stock_warning',
      public.uic('inquiry_form.dont_stock_warning',
        'Choosing "We don''t stock this product" removes it permanently — you will not be asked about it again.'));
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 45 — money was formatted in Dart on the supplier orders screen.
--
-- supplier_orders_screen.dart built '₹${totalAmount % 1 == 0 ? .toInt() :
-- .toStringAsFixed(2)}' itself, so the rounding rule for a supplier's order
-- total lived in Flutter. po_pricing_block already returns payable_display
-- (inr_money of the same number) — it only lacked the "should this be shown at
-- all" decision, which was also being made in Dart as `totalAmount > 0`.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.po_pricing_block(p_oid uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare so record; v_basis text; v_label text; v_tone text;
begin
  select coalesce(pricing_basis,'mrp_provisional') basis, coalesce(rate_pending,0) pending,
         coalesce(trade_total,0) trade, coalesce(mrp_total,0) mrpt, coalesce(total_amount,0) pay
    into so from supplier_orders where id = p_oid;
  if not found then return jsonb_build_object('has', false); end if;

  v_basis := so.basis;
  v_label := case v_basis
               when 'quote' then public.uic('supplier_po.basis_quote','Priced at the supplier''s quoted rate')
               when 'mixed' then public.uic('supplier_po.basis_mixed','Some lines are still awaiting a supplier rate')
               when 'empty' then public.uic('supplier_po.basis_empty','No lines on this order yet')
               else public.uic('supplier_po.basis_mrp','Rates pending — totals are provisional at MRP')
             end;
  v_tone := case v_basis when 'quote' then 'success' when 'mixed' then 'warning'
                         when 'empty' then 'info' else 'warning' end;

  return jsonb_build_object(
    'has',                true,
    'basis',              v_basis,
    'label',              v_label,
    'tone',               v_tone,
    'rate_pending',       so.pending,
    'payable_total',      round(so.pay,2),
    'payable_display',    public.inr_money(round(so.pay,2)),
    -- cmd #464 gap 45: whether the row shows a total is the BACKEND's call.
    -- Dart used to decide it with `totalAmount > 0` next to its own ₹ string.
    'show_payable',       (round(so.pay,2) > 0),
    'trade_total',        round(so.trade,2),
    'trade_display',      public.inr_money(round(so.trade,2)),
    'mrp_total',          round(so.mrpt,2),
    'mrp_display',        public.inr_money(round(so.mrpt,2)),
    'mrp_note',           public.uic('supplier_po.mrp_note','MRP is the printed ceiling — reference only, never the trade price'),
    'payable_label',      public.uic('supplier_po.payable_label','Payable'),
    'rate_column_label',  public.uic('supplier_po.rate_column','Rate'),
    'mrp_column_label',   public.uic('supplier_po.mrp_column','MRP'));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 46 — the public inquiry form hardcoded its English copy in Dart.
--
-- The expired/invalid page wrote its four sentences as Dart literals and the
-- receipt card built 'Available' / 'Out of Stock' / "Don't stock" in a Dart
-- switch even though inquiry_answer_badge() has existed all along. The badge is
-- now on every item and every receipt row (above); the page copy becomes
-- ui_copy keys the screen reads with c().
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ui_copy (key, value) values
  ('inquiry_form_screen.expired_title',   'This inquiry link has expired'),
  ('inquiry_form_screen.expired_body',    'Please contact mediBO for a new link.'),
  ('inquiry_form_screen.invalid_title',   'This link is no longer valid'),
  ('inquiry_form_screen.invalid_body',    'Please contact mediBO for assistance.'),
  ('inquiry_form.memory_hint_available',  'You had this in stock last time'),
  ('inquiry_form.memory_hint_oos',        'You were out of stock last time'),
  ('inquiry_form.prefill_note',           '{a} item(s) pre-filled from your last reply — check and submit.'),
  ('inquiry_form.dont_stock_warning',     'Choosing "We don''t stock this product" removes it permanently — you will not be asked about it again.')
on conflict (key) do nothing;

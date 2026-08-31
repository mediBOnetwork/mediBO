-- cmd #401 (2/3) — READY-FOR-PICKUP, and the closed badge on the admin card.
--
-- "Packed" answered one question — are the goods in a bag? — and the collect
-- run was then sequenced purely by geography (`sort_corder`, the medical-complex
-- ordering in fw_list_arrivals_core). So the rider could arrive first at the
-- nearest shop that would not be ready for another two hours, and last at the
-- shop that finished at nine. Two facts fix that, and they can only come from
-- the supplier: when the goods will actually be ready, and how many parcels the
-- rider needs room for.
--
-- Both are OPTIONAL. A supplier who just taps Packed, as today, gets exactly
-- today's behaviour: ready_after NULL sorts after every stated time rather than
-- before it, because "he didn't say" must never be read as "it's ready now".

alter table supplier_orders add column if not exists ready_after   timestamptz;
alter table supplier_orders add column if not exists parcel_count  integer;

-- ── one rendered ready/parcels block per supplier, for every surface ────────
create or replace function public.supplier_ready_block(p_supplier text, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_ready timestamptz; v_parcels int; v_now timestamptz := now();
begin
  select min(so.ready_after), sum(so.parcel_count)
    into v_ready, v_parcels
  from supplier_orders so
  where lower(btrim(so.supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
    and (p_date is null or so.order_date = p_date);

  return jsonb_build_object(
    'has_ready',   v_ready is not null,
    'ready_after', v_ready,
    -- The rider reads a clock time, not a timestamp, and reads it in IST.
    'ready_label', case
      when v_ready is null then _c('supplier.ready_unknown')
      when v_ready <= v_now then _c('supplier.ready_now')
      else _cf('supplier.ready_at',
             jsonb_build_object('time', to_char(v_ready at time zone 'Asia/Kolkata','HH12:MI AM'))) end,
    'ready_tone', case when v_ready is null then 'neutral'
                       when v_ready <= v_now then 'success' else 'warning' end,
    'has_parcels', coalesce(v_parcels,0) > 0,
    'parcels', coalesce(v_parcels,0),
    'parcels_label', case when coalesce(v_parcels,0) = 0 then null
                          else _cf('supplier.parcels_n',
                                 jsonb_build_object('n', v_parcels::text)) end);
end $$;

-- ── the packed call carries them ───────────────────────────────────────────
-- DROP the 3-argument version first. `create or replace` with two extra
-- defaulted parameters does NOT replace it — it creates a second overload, and
-- PostgREST then answers every 3-argument call with
-- "function supplier_set_packed(text, boolean, unknown) is not unique". The
-- defaults on the new signature are what keep those callers working; the old
-- body must go.
drop function if exists public.supplier_set_packed(text, boolean, text);

-- The two new parameters are appended WITH DEFAULTS, so every existing caller
-- (the supplier order tab, the barcode flow, admin) keeps working unchanged and
-- keeps writing NULL — which is the honest value for "he didn't say".
create or replace function public.supplier_set_packed(p_order_code text, p_packed boolean,
                                                      p_via text default 'order_tab',
                                                      p_ready_after timestamptz default null,
                                                      p_parcels integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_self text; v_is_admin boolean; v_row supplier_orders%rowtype;
begin
  select sp.supplier_name into v_self from current_supplier_profile() sp;
  v_is_admin := get_my_role() in ('admin','super_admin');

  select * into v_row from supplier_orders where order_code = p_order_code;
  if not found then return jsonb_build_object('error','not_found'); end if;

  if not v_is_admin and lower(btrim(v_row.supplier_name)) <> lower(btrim(coalesce(v_self,''))) then
    return jsonb_build_object('error','not_authorized');
  end if;

  if p_parcels is not null and p_parcels < 0 then
    return jsonb_build_object('error','bad_parcels','message',_c('supplier.parcels_bad'));
  end if;

  update supplier_orders
     set packed      = p_packed,
         packed_at   = case when p_packed then now() else null end,
         packed_via  = case when p_packed then coalesce(p_via,'order_tab') else null end,
         -- Un-packing clears both: a bag that is no longer packed has no
         -- ready time and no parcel count to plan a pickup around.
         ready_after  = case when p_packed then coalesce(p_ready_after, ready_after) else null end,
         parcel_count = case when p_packed then coalesce(p_parcels, parcel_count) else null end
   where order_code = p_order_code;

  return jsonb_build_object('ok', true, 'order_code', p_order_code,
                            'packed', p_packed,
                            'packed_via', case when p_packed then coalesce(p_via,'order_tab') else null end,
                            'ready', public.supplier_ready_block(v_row.supplier_name, v_row.order_date),
                            'message', case when p_packed then _c('supplier.packed_toast')
                                            else _c('supplier.unpacked_toast') end);
end $$;

-- ── the collect queue: sequenced by when the goods are ready ────────────────
-- Only two things change in this function: every supplier card gains the
-- rendered `ready` and `closed` blocks, and the ordering puts a stated ready
-- time ahead of geography. NULLS LAST is the whole safety property — a supplier
-- who stated nothing keeps today's geographic position instead of jumping to
-- the front of the run.
create or replace function public.fw_list_arrivals_core(p_date date DEFAULT admin_active_date(), p_include_older boolean DEFAULT false)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  WITH scope AS (
    SELECT oi.*, (o.created_at AT TIME ZONE 'Asia/Kolkata')::date AS odate
    FROM order_items oi JOIN orders o ON o.id = oi.order_id
    WHERE oi.fulfillment_state NOT IN ('shipped','cancelled')
  ),
  sel AS (SELECT * FROM scope WHERE p_date IS NULL OR odate = p_date),
  agg AS (
    SELECT sel.assigned_supplier,
           COALESCE(m.mode,'shop')              AS mode,
           COALESCE(m.arrivals_confirmed,false) AS arrivals_confirmed,
           (m.assigned_supplier IS NOT NULL OR public._supplier_forwarded_on(sel.assigned_supplier, p_date))    AS forwarded,
           COALESCE(m.set_at, now())            AS set_at,
           count(*)                             AS n_items,
           coalesce(sum(coalesce(sel.received_qty,0)),0) AS received_total,
           coalesce(sum(coalesce(sel.shop_qty,0)),0)     AS shop_total,
           count(*) FILTER (WHERE sel.shop_qty IS NOT NULL)          AS shop_counted_items,
           count(*) FILTER (WHERE coalesce(sel.received_qty,0) > 0)  AS wh_counted_items,
           bool_or(coalesce(sel.collect_locked,false))   AS any_locked,
           bool_or(coalesce(sel.shop_qty,0) > 0)         AS any_counted,
           (bool_or(coalesce(sel.collect_locked,false) OR coalesce(sel.received_locked,false))
            OR COALESCE(m.arrivals_confirmed,false)
            OR COALESCE(m.mode,'shop') <> 'shop') AS response_submitted
    FROM sel
    LEFT JOIN supplier_count_mode m ON m.assigned_supplier = sel.assigned_supplier
                                    AND m.mode_date = coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date)
    WHERE sel.assigned_supplier IS NOT NULL AND btrim(sel.assigned_supplier) <> ''
    GROUP BY sel.assigned_supplier, m.mode, m.arrivals_confirmed, m.assigned_supplier, m.set_at
  ),
  g2 AS (
    SELECT agg.*,
           COALESCE((SELECT bool_or(so.packed) FROM supplier_orders so
                     WHERE so.supplier_name = agg.assigned_supplier
                       AND (p_date IS NULL OR so.order_date = p_date)),false) AS is_packed,
           CASE WHEN NOT agg.response_submitted THEN 'none'
                WHEN EXISTS (select 1 from supplier_count_mode scm
                              where scm.assigned_supplier = agg.assigned_supplier
                                and scm.mode_date = p_date and scm.mode = 'warehouse')
                  THEN 'warehouse'
                WHEN agg.any_locked THEN 'shop'
                ELSE 'warehouse' END AS submit_method
    FROM agg
  ),
  rows AS (
    SELECT jsonb_build_object(
             'supplier',           g.assigned_supplier,
             'supplier_name',      g.assigned_supplier,
             'mode',               g.mode,
             'arrivals_confirmed', g.arrivals_confirmed,
             'forwarded',          g.forwarded,
             'has_supplier_order', hs.has_so,
             'items_total',        g.n_items,
             'received_total',     g.received_total,
             'shop_counted_total', g.shop_total,
             'shop_progress', jsonb_build_object('counted', g.shop_counted_items, 'total', g.n_items,
                                'label', g.shop_counted_items || '/' || g.n_items),
             'warehouse_received_total', g.received_total,
             'warehouse_progress', jsonb_build_object('counted', g.wh_counted_items, 'total', g.n_items,
                                'label', g.wh_counted_items || '/' || g.n_items),
             'packed',             g.is_packed,
             -- cmd #401
             'ready',              rp.blk,
             'closed',             public.supplier_closure_state(g.assigned_supplier),
             'submit_method',      g.submit_method,
             'submit_banner',      public.fw_submit_banner(g.assigned_supplier, coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date)),
             'submitted',          g.response_submitted,
             'counted',            g.any_counted,
             'badge', jsonb_build_object(
               'letter', CASE WHEN g.mode <> 'shop' THEN 'CR' WHEN NOT g.forwarded THEN 'P' ELSE 'C' END,
               'color',  CASE WHEN g.mode <> 'shop' THEN 'red' WHEN NOT g.forwarded THEN 'yellow' ELSE 'green' END),
             'dot_packed', jsonb_build_object(
               'state', CASE WHEN g.is_packed THEN 'green' ELSE 'yellow' END,
               'fill',  CASE WHEN g.is_packed THEN '#1B7A43' ELSE '#FCD34D' END,
               'border',CASE WHEN g.is_packed THEN '#1B7A43' ELSE '#F59E0B' END),
             'dot_method', jsonb_build_object(
               'state', CASE g.submit_method WHEN 'shop' THEN 'green' WHEN 'warehouse' THEN 'yellow' ELSE 'grey' END,
               'fill',  CASE g.submit_method WHEN 'shop' THEN '#1B7A43' WHEN 'warehouse' THEN '#FCD34D' ELSE '#E5E7EB' END,
               'border',CASE g.submit_method WHEN 'shop' THEN '#1B7A43' WHEN 'warehouse' THEN '#F59E0B' ELSE '#D1D5DB' END),
             'dot_submit', jsonb_build_object(
               'state', CASE WHEN g.response_submitted THEN 'green' ELSE 'yellow' END,
               'fill',  CASE WHEN g.response_submitted THEN '#1B7A43' ELSE '#FCD34D' END,
               'border',CASE WHEN g.response_submitted THEN '#1B7A43' ELSE '#F59E0B' END),
             'dots_shop', jsonb_build_array(
               jsonb_build_object('key','packed'),
               jsonb_build_object('key','method'),
               jsonb_build_object('key','submit')),
             'dots_warehouse', jsonb_build_array(
               jsonb_build_object('key','method'),
               jsonb_build_object('key','packed')),
             'show_in_warehouse', (g.mode <> 'shop' OR g.forwarded)
           ) AS j, g.set_at, g.forwarded, hs.has_so, g.mode,
           prof.sort_corder, prof.sort_shop_no,
           (rp.blk->>'ready_after')::timestamptz AS sort_ready
    FROM g2 g
    CROSS JOIN LATERAL (
      SELECT EXISTS (SELECT 1 FROM supplier_orders so
        WHERE so.supplier_name = g.assigned_supplier
          AND (p_date IS NULL OR so.order_date = p_date)) AS has_so
    ) hs
    CROSS JOIN LATERAL (
      SELECT public.supplier_ready_block(g.assigned_supplier, p_date) AS blk
    ) rp
    LEFT JOIN LATERAL (
      SELECT
        CASE
          WHEN lower(coalesce(sp.street_address,'')) ~ 'old\s*medical\s*complex' THEN 1
          WHEN lower(coalesce(sp.street_address,'')) ~ 'new\s*medical\s*complex' THEN 2
          WHEN lower(coalesce(sp.street_address,'')) ~ 'farista'    THEN 3
          WHEN lower(coalesce(sp.street_address,'')) ~ 'tarun'      THEN 4
          WHEN lower(coalesce(sp.street_address,'')) ~ 'sanved'     THEN 5
          WHEN lower(coalesce(sp.street_address,'')) ~ 'bjp'        THEN 6
          WHEN lower(coalesce(sp.street_address,'')) ~ 'dumartarai' THEN 7
          WHEN lower(coalesce(sp.street_address,'')) ~ 'birgao|birgoa' THEN 8
          ELSE 99
        END AS sort_corder,
        NULLIF((regexp_match(coalesce(sp.street_address,''), '([0-9]+)'))[1], '')::int AS sort_shop_no
      FROM supplier_profiles sp
      WHERE sp.supplier_name = g.assigned_supplier
      LIMIT 1
    ) prof ON true
  )
  SELECT jsonb_build_object(
    'status','ok', 'date', p_date, 'include_older', false, 'older_open', 0,
    'suppliers',           coalesce((SELECT jsonb_agg(j ORDER BY sort_ready NULLS LAST, sort_corder NULLS LAST, sort_shop_no NULLS LAST, (j->>'supplier')) FROM rows WHERE has_so),'[]'::jsonb),
    'arrivals',            coalesce((SELECT jsonb_agg(j ORDER BY set_at DESC) FROM rows WHERE has_so AND (mode <> 'shop' OR forwarded)),'[]'::jsonb),
    'items',               coalesce((SELECT jsonb_agg(j ORDER BY set_at DESC) FROM rows WHERE has_so AND (mode <> 'shop' OR forwarded)),'[]'::jsonb),
    'warehouse_suppliers', coalesce((SELECT jsonb_agg(j ORDER BY set_at DESC) FROM rows WHERE has_so AND (mode <> 'shop' OR forwarded)),'[]'::jsonb),
    'count',               (SELECT count(*) FROM rows WHERE has_so),
    'warehouse_count',     (SELECT count(*) FROM rows WHERE has_so AND (mode <> 'shop' OR forwarded))
  );
$function$;

-- ── the run stop: the same two facts, on the rider's own list ──────────────
create or replace function public.collect_run_plan(p_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
        v jsonb; v_stops jsonb;
begin
  if get_my_role() not in ('admin','super_admin','delivery') then
    return jsonb_build_object('error','not_authorized');
  end if;
  v := public.fw_list_arrivals_core(v_date, false);
  v_stops := coalesce(v->'suppliers','[]'::jsonb);

  return jsonb_build_object(
    'ok', true,
    'date', v_date,
    'screen_title', _c('supplier.run_title'),
    'intro', _c('supplier.run_intro'),
    'empty_label', _c('supplier.run_empty'),
    'stop_count', jsonb_array_length(v_stops),
    'parcels_total', (select coalesce(sum((s->'ready'->>'parcels')::int),0)
                        from jsonb_array_elements(v_stops) s),
    'parcels_total_label', _cf('supplier.run_parcels_total',
        jsonb_build_object('n', (select coalesce(sum((s->'ready'->>'parcels')::int),0)::text
                                   from jsonb_array_elements(v_stops) s))),
    -- Stops arrive in the order fw_list_arrivals_core already put them in:
    -- ready time first, then the geographic run. The rider's list and the
    -- admin's Collect tab are therefore literally the same sequence.
    'stops', (select coalesce(jsonb_agg(jsonb_build_object(
                 'seq', ord,
                 'supplier', s->>'supplier',
                 'ready', s->'ready',
                 'closed', s->'closed',
                 'packed', s->'packed',
                 'items_total', s->'items_total') order by ord), '[]'::jsonb)
              from jsonb_array_elements(v_stops) with ordinality t(s, ord)));
end $$;

insert into ui_copy (key, value) values
  ('supplier.ready_unknown',     to_jsonb('Ready time not given'::text)),
  ('supplier.ready_now',         to_jsonb('Ready now'::text)),
  ('supplier.ready_at',          to_jsonb('Ready from {time}'::text)),
  ('supplier.parcels_n',         to_jsonb('{n} parcel(s)'::text)),
  ('supplier.parcels_bad',       to_jsonb('Parcel count cannot be negative.'::text)),
  ('supplier.packed_toast',      to_jsonb('Marked packed. Thank you.'::text)),
  ('supplier.unpacked_toast',    to_jsonb('Packed mark removed.'::text)),
  ('supplier.ready_hint',        to_jsonb('Ready for pickup from (optional)'::text)),
  ('supplier.parcels_hint',      to_jsonb('How many parcels? (optional)'::text)),
  ('supplier.run_title',         to_jsonb('Collect run'::text)),
  ('supplier.run_intro',         to_jsonb('Stops in pickup order — shops that told us a ready time come first, then the usual route.'::text)),
  ('supplier.run_empty',         to_jsonb('No collections due today.'::text)),
  ('supplier.run_parcels_total', to_jsonb('{n} parcel(s) to collect today'::text))
on conflict (key) do nothing;

revoke execute on function public.supplier_ready_block(text, date) from public, anon;
revoke execute on function public.collect_run_plan(date) from public, anon;
grant execute on function public.supplier_ready_block(text, date) to authenticated, service_role;
grant execute on function public.collect_run_plan(date) to authenticated;

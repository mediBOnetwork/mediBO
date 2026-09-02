-- CHANGE #465 — MEDIUM defects · supplier batch B (register rows 49, 51, 63, 64, 65).
-- Batch A (#464) owns rows 32-48; nothing here touches them.
--
-- ── GAP 49 · Bundle mode ranks suppliers by MRP ─────────────────────────────
-- Reproduced in the live definition of inquiry_engine_ranked_suppliers():
--     ORDER BY CASE WHEN v_bundle THEN p.top_mrp
--                   ELSE COALESCE(sp."SPN",0)::numeric END DESC, p.sup
-- where top_mrp is max(COALESCE(i.mrp,0)) over the supplier's pending lines.
--
-- MRP is the printed regulatory ceiling. The business context is explicit:
-- "MRP ... is the legal ceiling and a display field, never the selling price.
-- Any build that prices, totals, or reports revenue on MRP is wrong." Ranking
-- the waterfall on it means the supplier asked first in bundle mode is the one
-- who happens to hold the most expensively PRINTED pack — a fact about a
-- manufacturer's carton, not about that supplier's price, performance or how
-- much of the basket they can actually serve.
--
-- What bundle mode is FOR is asking the supplier who can fill the most of the
-- basket in one go. So it ranks on the basket, and WHICH measure of the basket
-- is a setting:
--   inquiry_bundle_rank_by = 'trade_value_then_lines'  (default)
--                          | 'line_count'
--                          | 'spn'                      (bundle mode off, effectively)
--
-- Honest note on trade value: medicine_pricing carries a PTR for 4 products
-- today, so 'trade_value_then_lines' behaves as line_count in practice right
-- now and starts ranking on real trade value the moment pricing fills in — no
-- deploy needed. That is deliberate: line count is the honest signal available
-- today, and the value key is already in place for when it is not.
--
-- Also cheaper than what it replaces: inquiry_demand_qty() was called once in
-- the WHERE and would have been called a second time to total the basket. The
-- lateral evaluates it ONCE per row and both the filter and the sum read it
-- (the scalar-helper-scan trap, CHANGE #301's latency lessons).
--
-- NOT changed here: the `p.sup` alphabetical tiebreak. That is register row 48,
-- which belongs to batch A (#464) — two commands must not rewrite one ORDER BY.

insert into app_settings (key, value) values
  ('inquiry_bundle_rank_by', '"trade_value_then_lines"'::jsonb)
on conflict (key) do nothing;

create or replace function public.inquiry_engine_ranked_suppliers()
returns table(supplier_name text, spn integer, pending_items integer, rnk integer, is_open boolean)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_bundle boolean;
  v_by     text;
begin
  v_bundle := coalesce((select (value #>> '{}')::boolean from app_settings where key='inquiry_bundle_mode'), false);
  v_by     := coalesce((select (value #>> '{}')    from app_settings where key='inquiry_bundle_rank_by'),
                       'trade_value_then_lines');
  -- 'spn' is the escape hatch: it turns bundle ranking off without touching the
  -- bundle-mode flag every other caller reads.
  if v_by = 'spn' then v_bundle := false; end if;

  return query
  with pend as (
    select i.current_supplier as sup,
           i.zone_id          as zid,
           count(*)::int      as pend_items,
           -- The basket, in money, where a trade rate is known. NEVER mrp.
           coalesce(sum(d.qty * coalesce(mp.ptr, 0)), 0)::numeric as bundle_value
    from inquiry i
    cross join lateral (
      select inquiry_demand_qty(i.product_id, i.current_supplier, true) as qty
    ) d
    left join medicine_pricing mp on mp.product_id = i.product_id
    where i.current_supplier is not null and btrim(i.current_supplier) <> ''
      and i.supplier_order_id is null
      and coalesce(i.current_status,'') <> 'Available'
      and d.qty > 0
    group by i.current_supplier, i.zone_id
  ),
  ranked as (
    select p.sup, p.zid,
           coalesce(sp."SPN",0)::int as spn_val,
           p.pend_items,
           row_number() over (
             partition by p.zid
             order by
               -- primary key: the basket in money when bundle mode wants that,
               -- otherwise SPN. Never MRP, in either branch.
               case when v_bundle and v_by = 'trade_value_then_lines' then p.bundle_value
                    when v_bundle and v_by = 'line_count'             then 0
                    else coalesce(sp."SPN",0)::numeric end desc,
               -- secondary key: how much of the basket they can serve. It is
               -- the whole ranking under 'line_count', and the tiebreak under
               -- 'trade_value_then_lines' — which is what makes an unpriced
               -- catalog rank sensibly instead of ranking on zero.
               case when v_bundle then p.pend_items else 0 end desc,
               p.sup)::int as rnk_val
    from pend p
    left join supplier_profiles sp
           on sp.supplier_name = p.sup
          and sp.zone_id is not distinct from p.zid
  )
  select r.sup, r.spn_val, r.pend_items, r.rnk_val, (r.rnk_val = 1)
  from ranked r order by r.zid, r.rnk_val;
end;
$function$;

-- CHANGE #709 (4/6) — who pays for what we broke.
--
-- The settlement already has exactly one way for a cost to reach a partner:
-- an order_costs row whose cost_type is a registered cost type. So a damage
-- cost is an order_costs row of type 'handling_damage', kept in step with the
-- ledger by damage_cost_sync(order) — one row per order, recomputed from the
-- confirmed damage that the PARTNER bears.
--
-- Three buckets, decided per zone (app_settings.handling_damage.zone_bucket)
-- with the reason's own default as the fallback:
--   partner  — the partner's settlement carries it (an order_costs row)
--   medibo   — nobody is charged; it lands in the report and nowhere else
--   supplier — a debit note against the supplier, through supplier_debit_note
--              if that surface exists, and never as a partner cost
-- Idempotent throughout.

create or replace function public.damage_cost_sync(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_partner numeric := 0; v_supplier numeric := 0; v_medibo numeric := 0;
  v_frozen boolean; v_n int := 0;
begin
  -- Value anything that had no trade rate when it was confirmed. A line
  -- usually gets its rate later (the supplier bill lands, or the catalogue is
  -- priced), and the cost must follow it rather than stay stuck at "unknown".
  update handling_damage d
     set amount = round(d.qty * r.rate, 2), updated_at = now()
    from (select oi.id as item_id,
                 coalesce(nullif(oi.price,0),
                          (select mp.ptr from medicine_pricing mp
                            where mp.product_id = oi.product_id)) as rate
            from order_items oi where oi.order_id = p_order_id) r
   where d.order_item_id = r.item_id
     and d.order_id = p_order_id
     and d.status = 'confirmed'
     and d.amount is null
     and r.rate is not null;

  select coalesce(sum(amount) filter (where bucket='partner'), 0),
         coalesce(sum(amount) filter (where bucket='supplier'), 0),
         coalesce(sum(amount) filter (where bucket='medibo'), 0),
         count(*)::int
    into v_partner, v_supplier, v_medibo, v_n
    from handling_damage
   where order_id = p_order_id and status = 'confirmed' and amount is not null;

  -- A settled period is closed history: a later confirmation must never
  -- reach back into a statement that has already been paid.
  v_frozen := exists (
    select 1 from partner_settlements s
      join partner_settlement_periods p on p.id = s.period_id
     where s.order_id = p_order_id and p.status <> 'open');

  if not v_frozen then
    if v_partner > 0 then
      insert into order_costs (order_id, cost_type, basis, base_value, rate_value,
                               computed_amount, driver_value, driver_label, source, note)
      values (p_order_id, 'handling_damage', 'flat', v_partner, 0, v_partner,
              v_n, public._cf('damage.count_label', jsonb_build_object('n', v_n::text)),
              'auto', public._c('damage.cost_type_label'))
      on conflict (order_id, cost_type) do update
        set computed_amount = excluded.computed_amount,
            base_value = excluded.base_value,
            driver_value = excluded.driver_value,
            driver_label = excluded.driver_label,
            updated_at = now();
    else
      -- Only ever removes the line this function owns: cost_type identifies it,
      -- and an admin's hand-entered override (source='manual') is left alone.
      delete from order_costs
       where order_id = p_order_id and cost_type = 'handling_damage'
         and coalesce(source,'auto') = 'auto';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'partner', v_partner, 'supplier', v_supplier,
                            'medibo', v_medibo, 'rows', v_n, 'frozen', v_frozen);
end
$fn$;

revoke all on function public.damage_cost_sync(uuid) from public, anon, authenticated;

-- ── the supplier's share, as a debit note where the surface exists ────────
-- CHANGE #690/#753 already own supplier debits. This only records the INTENT
-- and the amount on the damage row itself; whichever debit surface is live
-- reads handling_damage the way it reads every other debit reason, so there is
-- no second copy of "what the supplier owes us" here.
create or replace function public.damage_supplier_debits(p_supplier text default null,
                                                         p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_rows jsonb; v_total numeric := 0;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('damage.err_confirm_auth'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier', coalesce(d.supplier_name,''),
           'reports', d.n, 'qty', d.qty, 'amount', d.amount,
           'amount_display', public.inr_money(d.amount))
         order by d.amount desc), '[]'::jsonb), coalesce(sum(d.amount),0)
    into v_rows, v_total
    from (
      select supplier_name, count(*)::int as n, sum(qty) as qty, sum(coalesce(amount,0)) as amount
        from handling_damage
       where status = 'confirmed' and bucket = 'supplier'
         and logged_at >= now() - make_interval(days => greatest(coalesce(p_days,30),1))
         and (p_supplier is null or supplier_name = p_supplier)
       group by supplier_name) d;

  return jsonb_build_object('ok', true, 'rows', v_rows,
    'total', v_total, 'total_display', public.inr_money(v_total),
    'window_days', greatest(coalesce(p_days,30),1));
end
$fn$;

revoke all on function public.damage_supplier_debits(text,integer) from public, anon, authenticated;
grant execute on function public.damage_supplier_debits(text,integer) to authenticated;

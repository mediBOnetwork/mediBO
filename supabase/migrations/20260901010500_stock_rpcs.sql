-- CHANGE #396 part 2b — the stock RPCs.
--
-- stock_derive_unallocated() reads the live fulfilment tables and writes one
-- lot per way goods end up unclaimed. It is idempotent: the lot is keyed on
-- (source_kind, source_order_item_id) and a re-run only tops a lot up, never
-- doubles it, and never drops below what has already been consumed.

create table if not exists public.stock_config (
  id             smallint primary key default 1,
  stall_days     integer not null default 21,   -- received, unpacked, order gone quiet
  aged_days      integer not null default 30,   -- "ageing" tone on the card
  near_expiry_days integer not null default 90,
  updated_at     timestamptz not null default now(),
  constraint stock_config_singleton check (id = 1)
);
insert into public.stock_config (id) values (1) on conflict (id) do nothing;
alter table public.stock_config enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='stock_config'
                   and policyname='stock_config_no_direct') then
    create policy stock_config_no_direct on public.stock_config for select using (false);
  end if;
end $$;

-- ── the derive ─────────────────────────────────────────────────────────────
create or replace function public.stock_derive_unallocated()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_stall int;
  v_created int := 0;
  v_updated int := 0;
  v_closed  int := 0;
begin
  select stall_days into v_stall from stock_config where id = 1;
  v_stall := coalesce(v_stall, 21);

  -- One derived lot per order_item. The CASE picks exactly ONE kind, so an
  -- item can never be counted twice (an item that was packed and shipped is
  -- not also sitting in the building).
  with src as (
    select
      i.id                                as order_item_id,
      i.order_id,
      i.product_id,
      i.product_name,
      i.assigned_supplier                 as supplier_name,
      o.zone_id,
      coalesce(i.received_at, i.arrived_at, o.created_at) as received_at,
      coalesce(i.received_qty,0)          as recv,
      coalesce(i.packed_qty,0)            as packed,
      coalesce(i.quantity,0)              as ordered,
      o.status                            as order_status,
      o.closed_at,
      -- batch / expiry / trade rate come from the SUPPLIER bill when the bill
      -- has been matched to this line; otherwise they are honestly unknown.
      bl.batch_no, bl.expiry, bl.ptr,
      i.price                             as line_price
    from order_items i
    join orders o on o.id = i.order_id
    left join lateral (
      select b.batch_no, b.expiry, b.ptr
        from bill_line_allocations a
        join bill_lines b on b.id = a.bill_line_id
       where a.order_item_id = i.id
       order by b.created_at desc
       limit 1
    ) bl on true
    where coalesce(i.received_qty,0) > 0
  ), classified as (
    select s.*,
      case
        when s.closed_at is not null or lower(coalesce(s.order_status,'')) in ('cancelled','canceled')
          then 'cancelled'
        when s.recv > s.ordered
          then 'over_supply'
        when lower(coalesce(s.order_status,'')) in ('delivered','completed','closed')
          then 'residue'
        when s.packed < s.recv
             and s.received_at < now() - make_interval(days => v_stall)
          then 'stalled'
        else null
      end as kind,
      case
        when s.recv > s.ordered
             and not (s.closed_at is not null or lower(coalesce(s.order_status,'')) in ('cancelled','canceled'))
          then s.recv - s.ordered
        else greatest(s.recv - s.packed, 0)
      end as qty
    from src s
  ), ins as (
    insert into public.stock_lot
      (product_id, product_name, batch_no, expiry, supplier_name, source_kind,
       source_order_id, source_order_item_id, qty_in, trade_rate, received_at,
       zone_id, status)
    select c.product_id,
           coalesce(nullif(btrim(c.product_name),''), 'Product ' || coalesce(c.product_id::text,'?')),
           c.batch_no, c.expiry, c.supplier_name, c.kind,
           c.order_id, c.order_item_id, c.qty,
           coalesce(nullif(c.ptr,0), nullif(c.line_price,0)),
           c.received_at, c.zone_id,
           case when c.qty > 0 then 'available' else 'consumed' end
      from classified c
     where c.kind is not null and c.qty > 0
    on conflict (source_kind, source_order_item_id) where source_order_item_id is not null
    do update
      set qty_in       = greatest(excluded.qty_in, public.stock_lot.qty_out),
          batch_no     = coalesce(excluded.batch_no, public.stock_lot.batch_no),
          expiry       = coalesce(excluded.expiry,   public.stock_lot.expiry),
          trade_rate   = coalesce(public.stock_lot.trade_rate, excluded.trade_rate),
          supplier_name= coalesce(excluded.supplier_name, public.stock_lot.supplier_name),
          status       = case when public.stock_lot.status = 'written_off' then 'written_off'
                              when greatest(excluded.qty_in, public.stock_lot.qty_out) > public.stock_lot.qty_out
                              then 'available' else 'consumed' end,
          updated_at   = now()
    returning (xmax = 0) as inserted
  )
  select count(*) filter (where inserted), count(*) filter (where not inserted)
    into v_created, v_updated from ins;

  -- A lot whose source is no longer unclaimed (the item finally got packed,
  -- the order re-opened) closes itself rather than lingering as a phantom.
  update public.stock_lot l
     set status = 'consumed', updated_at = now()
   where l.status = 'available'
     and l.source_kind <> 'manual'
     and l.source_order_item_id is not null
     and not exists (
       select 1 from order_items i
        where i.id = l.source_order_item_id
          and coalesce(i.received_qty,0) > coalesce(i.packed_qty,0)
     );
  get diagnostics v_closed = row_count;

  -- the movement ledger gets an 'in' row for every lot that has none yet
  insert into public.stock_movement (lot_id, kind, qty, order_id, order_item_id, actor, note)
  select l.id, 'in', l.qty_in, l.source_order_id, l.source_order_item_id,
         'derive', l.source_kind
    from public.stock_lot l
   where not exists (select 1 from public.stock_movement m
                      where m.lot_id = l.id and m.kind = 'in');

  return jsonb_build_object('ok', true, 'created', v_created,
    'updated', v_updated, 'closed', v_closed,
    'lots_available', (select count(*) from public.stock_lot where status='available'));
end $$;

-- ── the screen ─────────────────────────────────────────────────────────────
create or replace function public.stock_on_hand(
  p_q text default null, p_kind text default null,
  p_limit integer default 100, p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_like text := '%' || lower(btrim(coalesce(p_q,''))) || '%';
  v_lim  int  := least(greatest(coalesce(p_limit,100),1), 300);
  v_off  int  := greatest(coalesce(p_offset,0),0);
  v_aged int;
  v_rows jsonb;
  v_tot  record;
  v_kinds jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.admins_only','Admins only.'));
  end if;
  select aged_days into v_aged from stock_config where id = 1;
  v_aged := coalesce(v_aged, 30);

  select
    count(*)::int                                as lots,
    coalesce(sum(qty_available),0)               as units,
    coalesce(sum(value_at_trade),0)              as value,
    count(*) filter (where age_days >= v_aged)::int as aged_lots,
    coalesce(sum(value_at_trade) filter (where age_days >= v_aged),0) as aged_value
    into v_tot
    from stock_lot_v where status = 'available' and qty_available > 0;

  select jsonb_agg(x order by ord) into v_kinds from (
    select l.source_kind as ord,
           jsonb_build_object(
             'key', l.source_kind,
             'label', public._stk_copy('stock.src_' || l.source_kind, l.source_kind),
             'lots', count(*)::int,
             'units', sum(l.qty_available),
             'chip_label', public._stk_copy('stock.src_' || l.source_kind, l.source_kind)
                           || ' · ' || count(*)::text
                           || ' · ' || public._stk_money(sum(l.value_at_trade)),
             'value_display', public._stk_money(sum(l.value_at_trade))) as x
      from stock_lot_v l
     where l.status='available' and l.qty_available > 0
     group by l.source_kind
  ) s;

  select jsonb_agg(x order by age_days desc nulls last, value_at_trade desc) into v_rows from (
    select l.age_days, l.value_at_trade,
      jsonb_build_object(
        'lot_id',       l.id,
        'product_id',   l.product_id,
        'product_name', l.product_name,
        'batch_label',  coalesce(nullif(btrim(l.batch_no),''),
                                 public._stk_copy('stock.batch_unknown','Batch not recorded')),
        'has_batch',    nullif(btrim(coalesce(l.batch_no,'')),'') is not null,
        'expiry_label', coalesce(nullif(btrim(l.expiry),''),
                                 public._stk_copy('stock.expiry_unknown','Expiry not recorded')),
        'has_expiry',   nullif(btrim(coalesce(l.expiry,'')),'') is not null,
        'supplier_name',coalesce(l.supplier_name,''),
        'source_key',   l.source_kind,
        'source_label', public._stk_copy('stock.src_' || l.source_kind, l.source_kind),
        'order_code',   coalesce(o.order_code,''),
        'order_id',     l.source_order_id,
        'qty',          l.qty_available,
        'qty_label',    trim(to_char(l.qty_available,'FM999999990.##')),
        'age_days',     l.age_days,
        'age_label',    case when l.age_days is null then ''
                             when l.age_days = 0 then 'today'
                             when l.age_days = 1 then '1 day'
                             else l.age_days || ' days' end,
        'age_tone',     case when coalesce(l.age_days,0) >= v_aged then 'danger'
                             when coalesce(l.age_days,0) >= v_aged/2 then 'warning'
                             else 'neutral' end,
        'rate_display', public._stk_money(l.trade_rate),
        'qty_rate_display', trim(to_char(l.qty_available,'FM999999990.##'))
                            || ' × ' || public._stk_money(l.trade_rate),
        'source_order_label', array_to_string(array_remove(array[
                                nullif(coalesce(o.order_code,''),''),
                                nullif(coalesce(l.supplier_name,''),'')], null), ' · '),
        'has_rate',     l.trade_rate is not null,
        'value_display',public._stk_money(l.value_at_trade)) as x
      from stock_lot_v l
      left join orders o on o.id = l.source_order_id
     where l.status='available' and l.qty_available > 0
       and (btrim(coalesce(p_kind,'')) = '' or l.source_kind = p_kind)
       and (btrim(coalesce(p_q,'')) = ''
            or lower(l.product_name) like v_like
            or lower(coalesce(l.batch_no,'')) like v_like
            or lower(coalesce(l.supplier_name,'')) like v_like
            or lower(coalesce(o.order_code,'')) like v_like)
     order by l.age_days desc nulls last, l.value_at_trade desc
     limit v_lim offset v_off
  ) s;

  return jsonb_build_object(
    'ok', true,
    'title',    public._stk_copy('stock.title','Stock on hand'),
    'subtitle', public._stk_copy('stock.subtitle',''),
    'empty_label', public._stk_copy('stock.empty',''),
    'refresh_label', public._stk_copy('stock.refresh','Re-scan warehouse'),
    'retry_label', public._stk_copy('stock.retry','Retry'),
    'writeoff_label', public._stk_copy('stock.writeoff','Write off'),
    'aged_days', v_aged,
    'tiles', jsonb_build_array(
      jsonb_build_object('key','lots','label',public._stk_copy('stock.tile_lots','Lots'),
        'value', v_tot.lots::text,'tone','neutral'),
      jsonb_build_object('key','units','label',public._stk_copy('stock.tile_units','Units'),
        'value', trim(to_char(v_tot.units,'FM999999990.##')),'tone','neutral'),
      jsonb_build_object('key','value','label',public._stk_copy('stock.tile_value','Value at trade'),
        'value', public._stk_money(v_tot.value),'tone','info'),
      jsonb_build_object('key','aged','label',public._stk_copy('stock.tile_aged','Ageing over 30 days'),
        'value', public._stk_money(v_tot.aged_value),
        'tone', case when v_tot.aged_lots > 0 then 'danger' else 'neutral' end)),
    'kinds', coalesce(v_kinds,'[]'::jsonb),
    'columns', jsonb_build_array(
      public._stk_copy('stock.col_product','Product'),
      public._stk_copy('stock.col_batch','Batch / expiry'),
      public._stk_copy('stock.col_age','Age'),
      public._stk_copy('stock.col_qty','Qty'),
      public._stk_copy('stock.col_value','Value')),
    'rows', coalesce(v_rows,'[]'::jsonb),
    'has_more', (select count(*) from stock_lot_v
                  where status='available' and qty_available > 0) > (v_off + v_lim));
end $$;

-- ── re-scan from the screen ────────────────────────────────────────────────
create or replace function public.stock_rescan()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_role text := coalesce(public.get_my_role(),'none'); v_r jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.admins_only','Admins only.'));
  end if;
  v_r := public.stock_derive_unallocated();
  return v_r || jsonb_build_object('message', public._stk_copy('stock.refreshed','Warehouse re-scanned.'));
end $$;

-- ── write off a lot (damage, expiry, loss) ─────────────────────────────────
create or replace function public.stock_write_off(p_lot_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_role text := coalesce(public.get_my_role(),'none'); v_qty numeric;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._stk_copy('stock.admins_only','Admins only.'));
  end if;
  select greatest(qty_in - qty_out,0) into v_qty from stock_lot where id = p_lot_id;
  if v_qty is null then
    return jsonb_build_object('ok', false, 'message', 'Lot not found.');
  end if;
  update stock_lot set qty_out = qty_in, status = 'written_off',
         note = coalesce(nullif(btrim(p_reason),''), note), updated_at = now()
   where id = p_lot_id;
  insert into stock_movement (lot_id, kind, qty, actor, note)
  values (p_lot_id, 'write_off', v_qty, coalesce(auth.uid()::text,'admin'), p_reason);
  return jsonb_build_object('ok', true, 'lot_id', p_lot_id, 'qty', v_qty,
    'message', 'Written off.');
end $$;

revoke all on function public.stock_derive_unallocated() from public;
grant execute on function public.stock_on_hand(text,text,integer,integer) to authenticated;
grant execute on function public.stock_rescan()                            to authenticated;
grant execute on function public.stock_write_off(bigint,text)              to authenticated;

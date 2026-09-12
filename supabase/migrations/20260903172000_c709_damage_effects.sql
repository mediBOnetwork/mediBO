-- CHANGE #709 (3/6) — what a confirmed damage actually MOVES.
--
-- One function does it, once: damage_apply(id) is idempotent on applied_at, so
-- a re-confirm, a resumed worker or a replayed sweep can call it again and
-- nothing moves twice.
--
--   * the bag ledger      — bag_allocations for that line and bag_item_counts
--                           for that supplier/product/bag come down by the qty
--   * the pack            — packed_qty and pack_counted_qty are capped at what
--                           actually survives, so Pack cannot report more than
--                           exists
--   * the customer line   — never rewritten. The ordered quantity is what the
--                           pharmacy asked for; every reader subtracts
--                           damage_qty_for_item()
--   * zero                — a line with nothing left joins the unfulfilled
--                           split with the backend's own reason
--   * the shortfall       — optionally re-inquired, through the SAME helper the
--                           short-count path already uses
--                           (_reinquiry_same_supplier_first), never a second
--                           copy of the waterfall
-- Idempotent throughout.

create or replace function public.damage_apply(p_damage_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  d handling_damage%rowtype; oi order_items%rowtype;
  v_cfg jsonb := coalesce((select value from app_settings where key='handling_damage'),'{}'::jsonb);
  v_left numeric; v_amount numeric; v_bag int := 0; v_counts int := 0;
  v_zeroed boolean := false; v_reinq boolean := false; v_new uuid;
  v_take numeric; v_row record;
begin
  select * into d from handling_damage where id = p_damage_id;
  if not found then return jsonb_build_object('ok', false, 'error','no_row'); end if;
  if d.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'error','not_confirmed');
  end if;
  if d.applied_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  select * into oi from order_items where id = d.order_item_id;
  if not found then
    update handling_damage set applied_at = now() where id = d.id;
    return jsonb_build_object('ok', true, 'no_line', true);
  end if;

  -- ── the bag ledger ──────────────────────────────────────────────────────
  v_take := d.qty;
  for v_row in
    select ba.id, ba.qty, ba.bag_no, ba.assigned_supplier, ba.product_id
      from bag_allocations ba
     where ba.order_item_id = oi.id and ba.state = 'reserved'
     order by ba.id
  loop
    exit when v_take <= 0;
    if v_row.qty <= v_take then
      delete from bag_allocations where id = v_row.id;   -- qty > 0 is a CHECK
      v_take := v_take - v_row.qty;
    else
      update bag_allocations set qty = qty - v_take where id = v_row.id;
      v_take := 0;
    end if;
    v_bag := v_bag + 1;

    update bag_item_counts
       set qty = greatest(qty - least(v_row.qty, d.qty), 0), updated_at = now()
     where assigned_supplier = v_row.assigned_supplier
       and product_id = v_row.product_id
       and bag_no = v_row.bag_no;
    v_counts := v_counts + 1;
  end loop;

  -- ── the pack cannot report more than survives ──────────────────────────
  v_left := greatest(coalesce(oi.quantity,0) - public.damage_qty_for_item(oi.id), 0);
  update order_items
     set packed_qty = least(coalesce(packed_qty,0), v_left),
         pack_counted_qty = case when pack_counted_qty is null then null
                                 else least(pack_counted_qty, v_left) end,
         received_qty = case when received_qty is null then null
                             else least(received_qty, v_left) end
   where id = oi.id;

  -- ── nothing left: it joins the unfulfilled split ───────────────────────
  if v_left <= 0 then
    update order_items
       set unfulfillable = true,
           unfulfillable_reason = _c('damage.zero_line_reason'),
           unfulfillable_at = coalesce(unfulfillable_at, now()),
           packed = false
     where id = oi.id;
    v_zeroed := true;
  end if;

  -- ── the shortfall, through the helper the short-count path already uses ─
  if coalesce((v_cfg->>'auto_reinquiry')::boolean, true)
     and oi.product_id is not null
     and coalesce(oi.assigned_supplier,'') <> '' then
    begin
      insert into order_items (order_id, product_id, product_name, pharmacy_name,
             quantity, status, fulfillment_state, assigned_supplier, bag_no,
             mrp, price, gst_percent, inquiry_id, received_qty, zone_id, order_date)
      values (oi.order_id, oi.product_id, oi.product_name, oi.pharmacy_name,
             d.qty, coalesce(oi.status,'accepted'), 'pending', null, oi.bag_no,
             oi.mrp, oi.price, oi.gst_percent, oi.inquiry_id, 0, oi.zone_id, oi.order_date)
      returning id into v_new;
      perform public._reinquiry_same_supplier_first(oi.product_id, oi.assigned_supplier);
      v_reinq := true;
    exception when others then
      v_reinq := false;    -- a quiet engine must never block the ledger move
    end;
  end if;

  -- ── what it cost, at this line's own TRADE rate ────────────────────────
  -- MRP is the legal ceiling and a display field, never a price (the business
  -- rule every bill in this system obeys), so a line with no trade rate yet is
  -- worth an HONEST NULL rather than a confident zero: damage_cost_sync fills
  -- it in the moment a rate exists.
  v_amount := (select round(d.qty * r, 2)
                 from (select coalesce(nullif(oi.price,0),
                                       (select mp.ptr from medicine_pricing mp
                                         where mp.product_id = oi.product_id)) as r) z
                where z.r is not null);

  update handling_damage
     set applied_at = now(), amount = v_amount, updated_at = now()
   where id = d.id;

  -- the money lands through the settlement's own machinery (4/6)
  begin
    perform public.damage_cost_sync(d.order_id);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'damage_id', d.id,
    'bag_lines_touched', v_bag, 'bag_counts_touched', v_counts,
    'remaining_qty', v_left, 'line_zeroed', v_zeroed,
    'reinquired', v_reinq, 'new_line', v_new, 'amount', v_amount);
end
$fn$;

revoke all on function public.damage_apply(bigint) from public, anon, authenticated;

-- ── the bill excludes it, and says so in the backend's own words ─────────
-- _bill_lines_for_order is reproduced from the live definition with the
-- damaged quantity subtracted in BOTH branches (a supplier-bill line and a
-- catalogue-priced line), and a line with nothing left dropped.
create or replace function public._bill_lines_for_order(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with billable as (
    select oi.* from order_items oi
     where oi.order_id = p_order_id
       and oi.fulfillment_state not in ('shipped','cancelled')
       and coalesce(oi.unfulfillable,false) = false
  ),
  covered as (
    select a.order_item_id,
           coalesce(m.product_name, b.raw_name) as product,
           m.marketer as company, m.pack_qty as pack,
           b.hsn, b.batch_no, b.expiry,
           -- CHANGE #709: what we broke never reaches the bill.
           greatest(a.qty - public.damage_qty_for_item(a.order_item_id), 0) as qty,
           b.free_qty, b.mrp, b.ptr, coalesce(b.gst_pct,0) as gst_pct,
           'supplier_bill'::text as rate_source
      from bill_line_allocations a
      join bill_lines b on b.id = a.bill_line_id
      left join public."MEDICINE" m on m.id = b.product_id
     where a.order_id = p_order_id and b.verified and b.needs_fix is null
  ),
  from_catalogue as (
    select bi.id as order_item_id,
           coalesce(m.product_name, bi.product_name) as product,
           m.marketer as company, m.pack_qty as pack,
           coalesce(nullif(btrim(bi.hsn),''), null) as hsn,
           nullif(btrim(bi.batch_no),'') as batch_no,
           nullif(btrim(bi.expiry),'')   as expiry,
           greatest(bi.quantity::numeric - public.damage_qty_for_item(bi.id), 0) as qty,
           0::numeric as free_qty,
           nullif(regexp_replace(coalesce(bi.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp,
           mp.ptr,
           coalesce(mp.gst_pct, bi.gst_percent, m.gst_percent, 0)::numeric as gst_pct,
           'catalogue_rate'::text as rate_source
      from billable bi
      left join public."MEDICINE" m on m.id = bi.product_id
      join public.medicine_pricing mp on mp.product_id = bi.product_id
                                     and mp.ptr is not null
     where not exists (select 1 from covered c where c.order_item_id = bi.id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'product', x.product, 'company', x.company, 'pack', x.pack,
           'hsn', x.hsn, 'batch_no', x.batch_no, 'expiry', x.expiry,
           'qty', x.qty, 'free_qty', x.free_qty, 'mrp', x.mrp, 'ptr', x.ptr,
           'gst_pct', x.gst_pct, 'rate_source', x.rate_source,
           -- the sentence the pharmacy reads next to a short line
           'damage_note', case when public.damage_qty_for_item(x.order_item_id) > 0
                               then public._cf('damage.line_note', jsonb_build_object(
                                      'qty', rtrim(rtrim(to_char(
                                               public.damage_qty_for_item(x.order_item_id),
                                               'FM999999990.99'),'0'),'.'),
                                      'unit', public._c('damage.unit_default')))
                               else '' end)
         order by x.product, x.batch_no), '[]'::jsonb)
    from (select * from covered union all select * from from_catalogue) x
   where x.qty > 0;
$fn$;

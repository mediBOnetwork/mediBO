-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #468 — Daily heartbeat order.
--
-- One synthetic order walks the ENTIRE live pipeline every morning: order →
-- payment → inquiry → simulated supplier answer → supplier order → collect →
-- count → bag → pack → assign rider → deliver → bill → close. Every stage
-- asserts its own expected state inside its own timeout. The FIRST failure
-- stops the run and fires an urgent alert naming the stage, the error and the
-- order. A green run writes one summary line.
--
-- The canary never touches the business: the order is is_synthetic, the
-- outbound gate suppresses every message that is not Om's own test number, the
-- books triggers refuse the ledgers, and this migration closes the READ side
-- too (P&L, GST, settlements, demand engine, dashboards).
--
-- Idempotent throughout: create-or-replace, add-column-if-not-exists,
-- on-conflict-do-update. A resumed worker re-applies it as a no-op.
-- ═══════════════════════════════════════════════════════════════════════════

set lock_timeout = '30s';

-- ── A. A CANARY SESSION IS A PURGE SCOPE, NEVER AN AMBIENT STAMPER ─────────
-- A live test session stamps EVERY insert on 57 tables as synthetic. That is
-- right for Om's own incognito run and catastrophic for a daily job: a real
-- customer order placed in the same second would be adopted and then purged.
-- scope='canary' therefore owns rows (so the purge can find them) without ever
-- stamping anything it did not create and without raising the test banner.

create or replace function public._test_session_ambient()
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id bigint; v_scope text; v_uid uuid;
begin
  select id, scope into v_id, v_scope
    from public.test_sessions
   where status = 'live' and ended_at is null and now() < expires_at
     and coalesce(scope,'global') <> 'canary'
   limit 1;

  if v_id is not null then
    begin v_uid := auth.uid(); exception when others then v_uid := null; end;
    if v_uid is not null and exists (select 1 from public.test_session_exempt e where e.user_id = v_uid) then
      v_id := null;                       -- the escape hatch wins over the session
    elsif v_scope = 'actors' then
      if v_uid is null or not exists (
           select 1 from public.test_session_actor a
            where a.session_id = v_id and a.user_id = v_uid) then
        v_id := null;
      end if;
    end if;
  end if;

  return v_id;
end $function$;

create or replace function public.test_session_live_id()
 returns bigint
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select id from public.test_sessions
   where status = 'live' and ended_at is null and now() < expires_at
     and coalesce(scope,'global') <> 'canary'
   limit 1;
$function$;

CREATE OR REPLACE FUNCTION public._synthetic_inherit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_key text; v_hit boolean; v_sess bigint; v_j jsonb; v_parent bigint;
        v_scope text; v_uid uuid;
begin
  -- Once synthetic, always synthetic: only the purge removes these rows.
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;

  -- An ambient TEST SESSION stamps everything CREATED while it is live. This
  -- is the whole point of Om's scope change: he never picks an account and
  -- never ticks a box, he just switches the platform to incognito.
  --
  -- INSERT ONLY, and that is a safety rule, not a shortcut. On UPDATE the
  -- ambient stamp would convert a REAL row that merely got touched during the
  -- session into a synthetic one — and the session purge would then delete it.
  -- c573b_proof check 7 (business data byte-identical before vs after) caught
  -- exactly that. A session may create test data; it may never adopt live data.
  --
  -- The lookup is INLINE rather than a call to _test_session_ambient(), and it
  -- is guarded by tg_op first. This trigger now sits on 57 tables, several of
  -- them hot (order_items, whatsapp_messages, notification_log,
  -- stock_movement), so the no-session path has to cost one index probe on the
  -- partial unique index and nothing else — no SECURITY DEFINER call per row.
  if tg_op = 'INSERT' then
    -- CHANGE #468: a canary session owns its rows for the purge but never
    -- stamps ambiently, or the daily heartbeat would adopt (and then
    -- delete) any real order created in the same second.
    select id, scope into v_sess, v_scope from public.test_sessions
     where status = 'live' and ended_at is null and now() < expires_at
       and coalesce(scope,'global') <> 'canary' limit 1;
    if v_sess is not null then
      begin v_uid := auth.uid(); exception when others then v_uid := null; end;
      if v_uid is not null and exists (
           select 1 from public.test_session_exempt e where e.user_id = v_uid) then
        v_sess := null;                    -- the escape hatch wins over the session
      elsif v_scope = 'actors' and (v_uid is null or not exists (
           select 1 from public.test_session_actor a
            where a.session_id = v_sess and a.user_id = v_uid)) then
        v_sess := null;
      end if;
    end if;
  end if;
  if v_sess is not null then
    new.is_synthetic := true;
    v_j := to_jsonb(new);
    if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
      new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_sess));
    end if;
    return new;
  end if;

  if coalesce(new.is_synthetic,false) then return new; end if;

  -- A legacy explicit run context (part 1) still stamps.
  if coalesce(current_setting('medibo.synthetic', true),'') = 'on' then
    new.is_synthetic := true;
    return new;
  end if;

  for r in select * from public.synthetic_inherit_rule
            where child_table = tg_table_name loop
    v_key := to_jsonb(new) ->> r.child_col;
    continue when v_key is null;
    execute format(
      'select p.is_synthetic, p.test_session_id from public.%I p where p.%I = $1::%s limit 1',
      r.parent_table, r.parent_col, r.parent_type)
      into v_hit, v_parent using v_key;
    if coalesce(v_hit,false) then
      new.is_synthetic := true;
      -- A child of a synthetic parent joins the parent's session, so a purge
      -- of that session takes it too.
      if v_parent is not null then
        v_j := to_jsonb(new);
        if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
          new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_parent));
        end if;
      end if;
      return new;
    end if;
  end loop;
  return new;
end $function$;

-- ── B. EXCLUSION CHOKE POINTS (generated from the live definitions) ───────
-- ── C468 exclusion choke points ────────────────────────────────

create or replace view public.pnl_line_v as
 WITH base AS (
         SELECT a.id AS alloc_id,
            a.order_id,
            a.order_item_id,
            a.qty,
            b_1.id AS bill_line_id,
            COALESCE(b_1.ptr, 0::numeric) AS ptr,
            COALESCE(b_1.mrp, 0::numeric) AS mrp,
            COALESCE(b_1.disc_pct, 0::numeric) AS disc_pct,
            COALESCE(b_1.free_qty, 0::numeric) AS free_qty,
            COALESCE(b_1.qty, 0::numeric) AS bill_qty,
            COALESCE(b_1.gst_pct, 0::numeric) AS gst_pct,
            b_1.product_id,
            COALESCE(m.product_name, b_1.raw_name) AS product,
            b_1.supplier_order_id,
            COALESCE(so.supplier_name, b_1.supplier_name) AS supplier_name,
            so.supplier_id,
            o.order_code,
            COALESCE(o.order_date, (o.created_at AT TIME ZONE 'Asia/Kolkata'::text)::date) AS order_date,
            o.zone_id,
            z.name AS zone_name,
            COALESCE(pp.id::text, o.customer_id::text, o.user_id::text) AS customer_key,
            COALESCE(pp.pharmacy_name, o.pharmacy_name) AS customer_name
           FROM bill_line_allocations a
             JOIN bill_lines b_1 ON b_1.id = a.bill_line_id AND b_1.verified
             JOIN orders o ON o.id = a.order_id AND NOT COALESCE(o.is_synthetic, false)
             LEFT JOIN "MEDICINE" m ON m.id = b_1.product_id
             LEFT JOIN supplier_orders so ON so.id = b_1.supplier_order_id
             LEFT JOIN zones z ON z.id = o.zone_id
             LEFT JOIN LATERAL ( SELECT p.id,
                    p.user_id,
                    p.owner_name,
                    p.pharmacy_name,
                    p.phone,
                    p.gstin,
                    p.drug_license,
                    p.address,
                    p.city,
                    p.pincode,
                    p.created_at,
                    p.customer_name,
                    p.store_type,
                    p.range_zone,
                    p.address_local,
                    p.state,
                    p.store_location_link,
                    p.whatsapp_no,
                    p.other_contact_no,
                    p.email,
                    p.dl_20b,
                    p.dl_21b,
                    p.gst_no,
                    p.payment_term,
                    p.customer_code,
                    p.approved,
                    p.status,
                    p.approved_at,
                    p.approved_by,
                    p.is_deleted,
                    p.deleted_at,
                    p.deleted_by,
                    p.deleted_snapshot,
                    p.last_payment_wa_no,
                    p.district,
                    p.latitude,
                    p.longitude,
                    p.zone_id,
                    p.wa_language
                   FROM pharmacy_profiles p
                  WHERE o.customer_id IS NOT NULL AND p.id = o.customer_id OR o.customer_id IS NULL AND p.user_id = o.user_id
                 LIMIT 1) pp ON true
        ), tot AS (
         SELECT base.order_id,
            sum(round(base.qty * base.ptr, 2)) AS ptr_total
           FROM base
          GROUP BY base.order_id
        ), slab AS (
         SELECT t.order_id,
            COALESCE(o.bill_discount_pct, s_1.slab_pct, ptr_discount_pct(t.ptr_total), 0::numeric) AS slab_pct,
            o.bill_discount_pct IS NOT NULL OR s_1.order_id IS NOT NULL AS slab_frozen
           FROM tot t
             JOIN orders o ON o.id = t.order_id
             LEFT JOIN order_pnl_slab s_1 ON s_1.order_id = t.order_id
        )
 SELECT b.alloc_id,
    b.order_id,
    b.order_item_id,
    b.bill_line_id,
    b.order_code,
    b.order_date,
    to_char(b.order_date::timestamp with time zone, 'YYYY-MM'::text) AS order_month,
    b.zone_id,
    b.zone_name,
    b.customer_key,
    b.customer_name,
    b.supplier_id,
    b.supplier_name,
    b.product_id,
    b.product,
    b.qty,
    b.ptr,
    b.mrp,
    b.gst_pct,
    b.disc_pct,
    b.free_qty,
    b.bill_qty,
    s.slab_pct,
    s.slab_frozen,
        CASE
            WHEN b.free_qty > 0::numeric AND (b.bill_qty + b.free_qty) > 0::numeric THEN b.bill_qty / (b.bill_qty + b.free_qty)
            ELSE 1::numeric
        END AS amort,
    round(b.qty * b.ptr, 2) AS line_value,
    round(round(b.qty * b.ptr, 2) * s.slab_pct / 100::numeric, 2) AS cust_disc,
    round(b.qty * b.ptr, 2) - round(round(b.qty * b.ptr, 2) * s.slab_pct / 100::numeric, 2) AS cust_taxable,
    round(b.qty * b.ptr * (1::numeric - b.disc_pct / 100::numeric), 2) AS sup_taxable_unamortised,
    round(b.qty * b.ptr * (1::numeric - b.disc_pct / 100::numeric) *
        CASE
            WHEN b.free_qty > 0::numeric AND (b.bill_qty + b.free_qty) > 0::numeric THEN b.bill_qty / (b.bill_qty + b.free_qty)
            ELSE 1::numeric
        END, 2) AS sup_taxable,
    round(b.qty * b.ptr * (1::numeric - b.disc_pct / 100::numeric), 2) - round(b.qty * b.ptr * (1::numeric - b.disc_pct / 100::numeric) *
        CASE
            WHEN b.free_qty > 0::numeric AND (b.bill_qty + b.free_qty) > 0::numeric THEN b.bill_qty / (b.bill_qty + b.free_qty)
            ELSE 1::numeric
        END, 2) AS scheme_saving,
    round(b.qty * b.ptr, 2) - round(round(b.qty * b.ptr, 2) * s.slab_pct / 100::numeric, 2) - round(b.qty * b.ptr * (1::numeric - b.disc_pct / 100::numeric) *
        CASE
            WHEN b.free_qty > 0::numeric AND (b.bill_qty + b.free_qty) > 0::numeric THEN b.bill_qty / (b.bill_qty + b.free_qty)
            ELSE 1::numeric
        END, 2) AS margin
   FROM base b
     JOIN slab s ON s.order_id = b.order_id;;

CREATE OR REPLACE FUNCTION public._c427_bill_units(p_from date, p_to date)
 RETURNS TABLE(zone_id smallint, medicine_id bigint, product_name text, pack_label text, pharmacy_id uuid, bill_id uuid, invoice_date date, units numeric, rate numeric, supplier_key text, supplier_label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p.zone_id,
         l.medicine_id,
         coalesce(nullif(m.product_name, ''), nullif(l.product_name, ''), '—') as product_name,
         nullif(coalesce(l.pack_label, m.pack_size), '')                        as pack_label,
         b.pharmacy_id,
         b.id,
         b.invoice_date,
         coalesce(l.qty, 0) + coalesce(l.free_qty, 0)                           as units,
         -- The rate the pharmacy actually paid per unit, in that order of
         -- trust: the OCR's own unit cost, then the printed rate, then the
         -- taxable value spread over the billed quantity. MRP is never used —
         -- it is a ceiling, not a price (business context).
         coalesce(nullif(l.unit_cost, 0),
                  nullif(l.rate, 0),
                  case when coalesce(l.qty, 0) > 0
                       then round(l.taxable / l.qty, 4) end)                    as rate,
         lower(btrim(coalesce(nullif(b.supplier_gstin, ''), nullif(b.supplier_name, ''), 'unknown')))
                                                                                as supplier_key,
         coalesce(nullif(b.supplier_name, ''), nullif(b.supplier_gstin, ''), '—') as supplier_label
    from public.pharmacy_purchase_bill_line l
    join public.pharmacy_purchase_bill b on b.id = l.bill_id
    join public.pharmacy_profiles p      on p.id = b.pharmacy_id
    left join public."MEDICINE" m        on m.id = l.medicine_id
   where b.status in ('confirmed', 'applied')
     and not coalesce(b.is_synthetic, false)
     and not coalesce(p.is_synthetic, false)
     and b.invoice_date is not null
     and b.invoice_date >= p_from and b.invoice_date <= p_to
     and l.medicine_id is not null
     and coalesce(l.qty, 0) + coalesce(l.free_qty, 0) > 0
     and p.zone_id is not null
     and coalesce(p.is_deleted, false) = false
     and public._c419_sharing(b.pharmacy_id);
$function$;

CREATE OR REPLACE FUNCTION public.admin_dashboard_counts(p_date date DEFAULT NULL::date, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'books', 'public'
AS $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint; v_date date; v_zname text;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false,
      'medicines',0,'pending_bills',0,'flagged_bills',0,
      'pending_orders',0,'contact_inquiries',0,'pending_customers',0);
  end if;
  v_zone := public.scope_zone(p_zone);
  v_date := public.scope_date(p_date);
  select name into v_zname from zones where id = v_zone;

  return jsonb_build_object('allowed', true,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'), 'the_date', v_date,
    'medicines', (select count(*) from "MEDICINE"),
    'pending_bills', (select count(*) from pending_bills pb
                      where pb.status='pending'
                        and not coalesce(pb.is_synthetic,false)
                        and public.scope_zone_ok(
                              public._c529_bill_zone(pb.supplier_id, pb.supplier_name), v_zone)),
    'flagged_bills', (select count(*) from pending_bills pb
                      where pb.verdict in ('needs_approval','fake')
                        and not coalesce(pb.is_synthetic,false)
                        and public.scope_zone_ok(
                              public._c529_bill_zone(pb.supplier_id, pb.supplier_name), v_zone)),
    'unresolved_bills', (select count(*) from pending_bills pb
                          where pb.status='pending'
                            and not coalesce(pb.is_synthetic,false)
                            and public._c529_bill_zone(pb.supplier_id, pb.supplier_name) is null),
    'unresolved_bills_label', public._c('bills.unresolved_label'),
    'unresolved_bills_note',  public._c('bills.unresolved_note'),
    'pending_orders', (select count(*) from orders o
                        left join pharmacy_profiles pp on pp.id = o.customer_id
                       where o.status='pending'
                         and not coalesce(o.is_synthetic,false)
                         and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'orders_today', (select count(*) from orders o
                      left join pharmacy_profiles pp on pp.id = o.customer_id
                     where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
                       and not coalesce(o.is_synthetic,false)
                       and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'contact_inquiries', (select count(*) from contact_inquiries),
    'pending_customers', (select count(*) from pharmacy_profiles pp
                           where coalesce(pp.approved,false) = false
                             and not coalesce(pp.is_synthetic,false)
                             and public.scope_zone_ok(pp.zone_id, v_zone)),
    'deliveries_today', (select count(*) from deliveries d
                          join orders o on o.id = d.order_id
                         where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
                       and not coalesce(o.is_synthetic,false)
                           and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone)));
end $function$;

CREATE OR REPLACE FUNCTION public.settlement_snapshot_order(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.order_fulfilment_snapshot
    (order_id, zone_id, mode, partner_id, partner_name, split_pct, source)
  select o.id,
         o.zone_id,
         coalesce(m.mode, 'self'),
         case when coalesce(m.mode,'self') = 'partner' then m.partner_id end,
         case when coalesce(m.mode,'self') = 'partner' then rp.partner_name end,
         case when coalesce(m.mode,'self') = 'partner' then coalesce(m.split_pct, 0) else 0 end,
         'bill'
    from public.orders o
    left join public.zone_fulfilment_mode m on m.zone_id = o.zone_id
    left join public.region_partners rp     on rp.id = m.partner_id
   where o.id = p_order_id
     and not coalesce(o.is_synthetic, false)
  on conflict (order_id) do nothing;
end $function$;

CREATE OR REPLACE FUNCTION public.gst_ledger_build_output(p_from date, p_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seller text; v_prefix text; v_n int;
begin
  select seller_gstin, coalesce(invoice_prefix,'MB')
    into v_seller, v_prefix from public.billing_config where id = 1;

  with elig as (
    select o.id, o.order_code, o.user_id,
           coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as inv_dt,
           o.delivery_charge, o.delivery_charge_gst, o.delivery_charge_waived,
           o.delivery_charge_at, o.delivery_charge_label
      from public.orders o
     where not coalesce(o.is_synthetic, false)
       and exists (select 1 from public.bill_line_allocations a
                     join public.bill_lines b on b.id = a.bill_line_id
                    where a.order_id = o.id and b.verified)
       and not exists (
             select 1 from public.order_items oi
              where oi.order_id = o.id
                and oi.fulfillment_state not in ('shipped','cancelled')
                and coalesce(oi.unfulfillable,false) = false
                and not exists (select 1 from public.bill_line_allocations a2
                                  join public.bill_lines b2 on b2.id = a2.bill_line_id
                                 where a2.order_item_id = oi.id
                                   and b2.verified and b2.needs_fix is null))
  ), scoped as (
    select * from elig where inv_dt >= p_from and inv_dt < p_to
  ), buyer as (
    select s.*,
           coalesce(ph.pharmacy_name, o.pharmacy_name) as buyer_nm,
           public.gst_norm_gstin(coalesce(ph.gstin, ph.gst_no)) as buyer_gstin,
           ph.user_id::text as buyer_id
      from scoped s
      join public.orders o on o.id = s.id
      left join lateral (select * from public.pharmacy_profiles p
                          where p.user_id = s.user_id limit 1) ph on true
  ), tot as (
    select b.id, coalesce(sum(a.qty * bl.ptr), 0) as ptr_total
      from buyer b
      join public.bill_line_allocations a on a.order_id = b.id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
     group by b.id
  ), pct as (
    select t.id, public.ptr_discount_pct(t.ptr_total) as pct from tot t
  ), goods as (
    select b.id as order_id, b.order_code, b.inv_dt, b.buyer_nm, b.buyer_gstin, b.buyer_id,
           a.id::text as line_ref,
           coalesce(nullif(btrim(coalesce(bl.hsn,'')),''),
                    (select default_hsn from public.billing_config where id=1), '3004') as hsn,
           coalesce(m.product_name, bl.raw_name) as product_nm,
           a.qty,
           coalesce(bl.gst_pct,0) as rate,
           round(a.qty * bl.ptr, 2)
             - round(round(a.qty * bl.ptr, 2) * p.pct / 100.0, 2) as taxable
      from buyer b
      join public.bill_line_allocations a on a.order_id = b.id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
      join pct p on p.id = b.id
      left join public."MEDICINE" m on m.id = bl.product_id
  ), delivery as (
    -- Only a FROZEN, non-waived charge is a taxable outward supply. The rate is
    -- read back off the frozen pair, never assumed.
    select b.id as order_id, b.order_code, b.inv_dt, b.buyer_nm, b.buyer_gstin, b.buyer_id,
           'delivery'::text as line_ref,
           coalesce(nullif(public._c('gst.delivery_hsn'),''),'9968') as hsn,
           coalesce(nullif(b.delivery_charge_label,''), nullif(public._c('gst.delivery_label'),''), 'Delivery charge') as product_nm,
           1::numeric as qty,
           round(coalesce(b.delivery_charge_gst,0) * 100.0 / nullif(b.delivery_charge,0), 2) as rate,
           coalesce(b.delivery_charge,0) as taxable
      from buyer b
     where b.delivery_charge_at is not null
       and coalesce(b.delivery_charge_waived,true) = false
       and coalesce(b.delivery_charge,0) > 0
  ), all_lines as (
    select * from goods union all select * from delivery
  ), split as (
    select l.*, public.gst_split(l.taxable, l.rate, v_seller, l.buyer_gstin) as sp
      from all_lines l
  )
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply,
    order_id, order_code)
  select
    'output', 'customer_bill', s.order_id, s.line_ref, date_trunc('month', s.inv_dt)::date,
    v_prefix || '-' || coalesce(s.order_code,''), s.inv_dt,
    to_char(s.inv_dt,'DD/MM/YYYY'),
    s.buyer_id, s.buyer_nm, s.buyer_gstin,
    s.hsn, s.product_nm, s.qty, s.taxable, s.rate,
    (s.sp->>'cgst')::numeric, (s.sp->>'sgst')::numeric, (s.sp->>'igst')::numeric,
    (s.sp->>'is_interstate')::boolean, (s.sp->>'gstin_missing')::boolean, s.sp->>'place_of_supply',
    s.order_id, s.order_code
  from split s
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply,
    order_id = excluded.order_id, order_code = excluded.order_code, built_at = now();

  get diagnostics v_n = row_count;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.gst_ledger_build_credit_notes(p_from date, p_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seller text; v_prefix text; v_hsn_default text; v_n int;
begin
  select seller_gstin, coalesce(invoice_prefix,'MB'), coalesce(default_hsn,'3004')
    into v_seller, v_prefix, v_hsn_default
    from public.billing_config where id = 1;

  with cn as (
    select r.id as return_id, r.order_id, r.qty, r.product_name,
           coalesce(r.credit_taxable,0) as taxable,
           coalesce(r.gst_pct,0)        as rate,
           coalesce(r.credited_at, r.approved_at, r.raised_at) as at_ts,
           o.order_code, o.user_id,
           coalesce(bl.hsn_pick, v_hsn_default) as hsn
      from public.order_returns r
      join public.orders o on o.id = r.order_id
      left join lateral (
        select coalesce(nullif(btrim(coalesce(b.hsn,'')),''), v_hsn_default) as hsn_pick
          from public.bill_line_allocations a
          join public.bill_lines b on b.id = a.bill_line_id and b.verified
         where a.order_item_id = r.order_item_id
         limit 1) bl on true
     where r.status in ('approved','credited')
       and not coalesce(o.is_synthetic, false)
       and coalesce(r.credit_total,0) > 0
  ), scoped as (
    select c.*,
           (c.at_ts at time zone 'Asia/Kolkata')::date as cn_dt
      from cn c
  ), win as (
    select * from scoped where cn_dt >= p_from and cn_dt < p_to
  ), buyer as (
    select w.*,
           coalesce(ph.pharmacy_name, o.pharmacy_name) as buyer_nm,
           public.gst_norm_gstin(coalesce(ph.gstin, ph.gst_no)) as buyer_gstin,
           ph.user_id::text as buyer_id
      from win w
      join public.orders o on o.id = w.order_id
      left join lateral (select * from public.pharmacy_profiles p
                          where p.user_id = w.user_id limit 1) ph on true
  ), split as (
    select b.*, public.gst_split(b.taxable, b.rate, v_seller, b.buyer_gstin) as sp
      from buyer b
  )
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply,
    order_id, order_code)
  select
    'output', 'credit_note', s.return_id, 'return',
    date_trunc('month', s.cn_dt)::date,
    v_prefix || '-CN-' || coalesce(s.order_code,''), s.cn_dt,
    to_char(s.cn_dt,'DD/MM/YYYY'),
    s.buyer_id, s.buyer_nm, s.buyer_gstin,
    s.hsn, s.product_name, -s.qty, -s.taxable, s.rate,
    -(s.sp->>'cgst')::numeric, -(s.sp->>'sgst')::numeric, -(s.sp->>'igst')::numeric,
    (s.sp->>'is_interstate')::boolean, (s.sp->>'gstin_missing')::boolean,
    s.sp->>'place_of_supply',
    s.order_id, s.order_code
  from split s
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply,
    order_id = excluded.order_id, order_code = excluded.order_code, built_at = now();

  get diagnostics v_n = row_count;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.gst_ledger_build_input(p_from date, p_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seller text; v_n int;
begin
  select seller_gstin into v_seller from public.billing_config where id = 1;

  with src as (
    select
      b.id                                              as line_id,
      pb.id                                             as bill_id,
      pb.supplier_id                                    as supplier_id,
      coalesce(sp.supplier_name, pb.supplier_name, b.supplier_name) as supplier_nm,
      public.gst_norm_gstin(coalesce(sp.gstin, sp.gst)) as supplier_gstin,
      nullif(btrim(coalesce(pb.scan_result->>'invoice_no','')),'')   as inv_no,
      nullif(btrim(coalesce(pb.scan_result->>'invoice_date','')),'') as inv_dt_text,
      public.gst_parse_date(pb.scan_result->>'invoice_date',
        (coalesce(pb.received_at, pb.created_at) at time zone 'Asia/Kolkata')::date) as inv_dt,
      b.hsn, coalesce(m.product_name, b.raw_name) as product_nm,
      coalesce(b.qty,0) as qty,
      round(coalesce(b.qty,0) * coalesce(b.ptr,0), 2) as gross,
      coalesce(b.disc_pct,0) as disc_pct,
      coalesce(b.gst_pct,0)  as rate
    from public.bill_lines b
    join public.pending_bills pb on pb.id = b.pending_bill_id
    left join public.supplier_profiles sp on sp.id::text = pb.supplier_id
    left join public."MEDICINE" m on m.id = b.product_id
    where pb.status = 'imported'
      and not coalesce(pb.is_synthetic, false)
      and not coalesce(b.is_synthetic, false)
      and coalesce(b.qty,0) > 0
      and coalesce(b.ptr,0) > 0
      and b.gst_pct is not null
  ), calc as (
    select s.*, s.gross - round(s.gross * s.disc_pct / 100.0, 2) as taxable from src s
  ), split as (
    select c.*, public.gst_split(c.taxable, c.rate, v_seller, c.supplier_gstin) as sp
      from calc c where c.inv_dt >= p_from and c.inv_dt < p_to
  )
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply)
  select
    'input', 'supplier_bill', s.bill_id, s.line_id::text, date_trunc('month', s.inv_dt)::date,
    s.inv_no, s.inv_dt, s.inv_dt_text,
    s.supplier_id, s.supplier_nm, s.supplier_gstin,
    coalesce(nullif(btrim(coalesce(s.hsn,'')),''), (select default_hsn from public.billing_config where id=1), '3004'),
    s.product_nm, s.qty, s.taxable, s.rate,
    (s.sp->>'cgst')::numeric, (s.sp->>'sgst')::numeric, (s.sp->>'igst')::numeric,
    (s.sp->>'is_interstate')::boolean, (s.sp->>'gstin_missing')::boolean, s.sp->>'place_of_supply'
  from split s
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply, built_at = now();

  get diagnostics v_n = row_count;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.pnl_bill_generated(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pct numeric; v_n int := 0; cfg public.pnl_cost_config%rowtype;
begin
  if exists (select 1 from public.orders where id = p_order_id and coalesce(is_synthetic,false)) then
    return jsonb_build_object('ok', true, 'skipped', 'synthetic');
  end if;
  v_pct := public.pnl_slab_capture(p_order_id);
  select * into cfg from public.pnl_cost_config where id = 1;

  insert into public.pnl_alert (order_id, order_code, bill_line_id, product, qty,
                                cust_taxable, sup_taxable, margin, detail)
  select v.order_id, v.order_code, v.bill_line_id, v.product, v.qty,
         v.cust_taxable, v.sup_taxable, v.margin,
         jsonb_build_object('slab_pct', v.slab_pct, 'ptr', v.ptr,
                            'disc_pct', v.disc_pct, 'free_qty', v.free_qty,
                            'supplier', v.supplier_name)
    from public.pnl_line_v v
   where v.order_id = p_order_id and v.margin < 0
  on conflict (order_id, bill_line_id) do update
    set margin       = excluded.margin,
        cust_taxable = excluded.cust_taxable,
        sup_taxable  = excluded.sup_taxable,
        detail       = excluded.detail,
        created_at   = now(),
        seen_at      = null;

  get diagnostics v_n = row_count;

  if v_n > 0 and coalesce(cfg.negative_alert_enabled, true) then
    begin
      perform public.notify('pnl_negative_margin', cfg.negative_alert_phone,
        jsonb_build_object(
          'order_id', p_order_id::text,
          'audience', 'admin',
          'count',    v_n::text,
          'order',    coalesce((select order_code from public.orders where id = p_order_id), '')));
    exception when others then
      null;  -- a notification that cannot go out never becomes a billing fault
    end;
  end if;

  return jsonb_build_object('ok', true, 'slab_pct', v_pct, 'below_cost', v_n);
end $function$;

-- ── C. THE CANARY'S OWN TABLES ────────────────────────────────────────────
-- A run, its stages, the stage catalogue (data, so a stage is retimed with an
-- UPDATE and never a deploy) and one config row.

create table if not exists public.heartbeat_config (
  id                 int primary key default 1,
  enabled            boolean not null default true,
  default_timeout_ms int     not null default 20000,
  alert_event_key    text    not null default 'heartbeat_failed',
  alert_phone        text,
  retain_days        int     not null default 30,
  updated_at         timestamptz not null default now(),
  updated_by         text,
  constraint heartbeat_config_singleton check (id = 1)
);
insert into public.heartbeat_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.heartbeat_stage (
  ord        int  not null,
  stage_key  text primary key,
  label      text not null,
  timeout_ms int,
  enabled    boolean not null default true,
  note       text
);
create unique index if not exists heartbeat_stage_ord_uq on public.heartbeat_stage (ord);

create table if not exists public.heartbeat_run (
  id              bigserial primary key,
  kind            text not null default 'daily',
  status          text not null default 'running',
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  ms              int,
  order_id        uuid,
  order_code      text,
  test_session_id bigint,
  break_stage     text,
  stages_total    int not null default 0,
  stages_passed   int not null default 0,
  failed_stage    text,
  failed_label    text,
  error           text,
  summary_line    text,
  alert_sent      boolean not null default false,
  alert_detail    jsonb,
  cleanup         jsonb,
  clean           boolean,
  exclusions      jsonb
);
create index if not exists heartbeat_run_started_idx on public.heartbeat_run (started_at desc);

create table if not exists public.heartbeat_stage_run (
  id         bigserial primary key,
  run_id     bigint not null references public.heartbeat_run(id) on delete cascade,
  ord        int not null,
  stage_key  text not null,
  label      text not null,
  status     text not null default 'running',
  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  ms         int,
  timeout_ms int,
  detail     jsonb,
  error      text
);
create index if not exists heartbeat_stage_run_run_idx on public.heartbeat_stage_run (run_id, ord);

alter table public.heartbeat_config    enable row level security;
alter table public.heartbeat_stage     enable row level security;
alter table public.heartbeat_run       enable row level security;
alter table public.heartbeat_stage_run enable row level security;

-- No policy on purpose: every read goes through the SECURITY DEFINER RPCs
-- below, which check the role themselves. Anon/authenticated see nothing.

-- The stage catalogue. Adding a stage is one INSERT here plus one branch in
-- _hb_stage(); retiming one is an UPDATE with no deploy at all.
insert into public.heartbeat_stage (ord, stage_key, label, timeout_ms, note) values
  (10, 'fixtures',       'Synthetic cast',       15000, 'test pharmacy, supplier, rider and zone exist and are marked'),
  (20, 'order',          'Order placed',         20000, 'a two-line order on the test pharmacy'),
  (30, 'payment',        'Payment verified',     15000, 'simulated capture; Razorpay only in test mode'),
  (40, 'inquiry',        'Inquiry raised',       30000, 'the real inquiry engine, on the synthetic zone'),
  (50, 'supplier_answer','Supplier answered',    20000, 'SIMULATED — the dummy numbers stay uncontacted'),
  (60, 'supplier_order', 'Supplier order cut',   20000, 'rebuilt by the real engine'),
  (70, 'collect',        'Collected at shop',    20000, 'shop-stage counting marks the lines'),
  (80, 'count',          'Counted in warehouse', 25000, 'confirm counting, then warehouse receive'),
  (90, 'bag',            'Bagged and received',  25000, 'bag counts entered, then warehouse receive allocates them'),
  (100,'pack',           'Packed',               20000, 'lines packed and the order marked dispatch-ready'),
  (110,'assign',         'Rider assigned',       20000, 'assigned to the synthetic rider only'),
  (120,'deliver',        'Delivered',            20000, 'the real OTP proof path; only the tap is simulated'),
  (105,'bill',           'Bill generated',       30000, 'invoice on the TEST series, PDF attached, balance settled'),
  (140,'close',          'Order closed',         20000, 'the order reaches a closed state'),
  (150,'exclusions',     'Books untouched',      30000, 'P&L, GST, settlements, demand and dashboards unmoved')
on conflict (stage_key) do update
  set ord = excluded.ord, label = excluded.label,
      timeout_ms = excluded.timeout_ms, note = excluded.note;

-- Every string the screen prints. Wording changes are an UPDATE here.
insert into public.ui_copy (key, value) values
  ('heartbeat.title',            '"Daily heartbeat"'::jsonb),
  ('heartbeat.subtitle',         '"One synthetic order walks the whole pipeline every morning."'::jsonb),
  ('heartbeat.empty',            '"No heartbeat has run yet. Run one now to see every stage."'::jsonb),
  ('heartbeat.run_now',          '"Run heartbeat now"'::jsonb),
  ('heartbeat.run_drill',        '"Run alert drill"'::jsonb),
  ('heartbeat.drill_hint',       '"The drill breaks one stage on purpose to prove the alert fires."'::jsonb),
  ('heartbeat.section_runs',     '"Recent runs"'::jsonb),
  ('heartbeat.section_stages',   '"Stages"'::jsonb),
  ('heartbeat.status_passed',    '"Passed"'::jsonb),
  ('heartbeat.status_failed',    '"Failed"'::jsonb),
  ('heartbeat.status_running',   '"Running"'::jsonb),
  ('heartbeat.status_skipped',   '"Skipped"'::jsonb),
  ('heartbeat.alert_sent',       '"Alert sent"'::jsonb),
  ('heartbeat.alert_not_sent',   '"Alert not sent"'::jsonb),
  ('heartbeat.clean',            '"Artifacts cleaned up"'::jsonb),
  ('heartbeat.not_clean',        '"Artifacts left behind"'::jsonb),
  ('heartbeat.busy',             '"Test mode is live — the heartbeat waits for it to end."'::jsonb),
  ('heartbeat.disabled',         '"The daily heartbeat is switched off."'::jsonb),
  ('heartbeat.error_title',      '"Could not load the heartbeat"'::jsonb),
  ('heartbeat.retry',            '"Retry"'::jsonb),
  ('heartbeat.never',            '"never"'::jsonb),
  ('heartbeat.stage_of',         '"{{done}} of {{total}} stages"'::jsonb),
  ('heartbeat.alert_push_title', '"Heartbeat FAILED at {{stage}}"'::jsonb),
  ('heartbeat.alert_push_body',  '"Order {{order}} stopped at {{stage}}: {{error}}"'::jsonb),
  ('admin_nav.overflow_heartbeat','"Heartbeat"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── D. THE STAGE DRIVERS ──────────────────────────────────────────────────

-- Drive the REAL admin RPCs as the platform's own operator. The claim is
-- transaction-local: it dies with the run, and heartbeat_run_once is itself
-- only callable by service_role/postgres/admin.
create or replace function public._hb_impersonate()
 returns uuid language plpgsql security definer set search_path to 'public','auth'
as $function$
declare v_uid uuid; v_email text;
begin
  select u.id, u.email into v_uid, v_email
    from auth.users u
    join public.admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false)
   order by u.created_at limit 1;
  if v_uid is null then return null; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'email', v_email, 'role','authenticated')::text, true);
  return v_uid;
end $function$;

create or replace function public._hb_fix(p_key text)
 returns uuid language sql stable security definer set search_path to 'public'
as $function$ select entity_id from public.test_fixture where key = p_key $function$;

-- Products the canary may use: buyable, and NOT in today's real inquiry or in
-- any real order today. The canary must never merge its quantity into a live
-- inquiry line — inquiry_start_batch_for_order reuses a row per product+date.
create or replace function public._hb_pick_products(p_n int)
 returns table(id bigint, product_name text, mrp numeric, gst numeric)
 language sql stable security definer set search_path to 'public'
as $function$
  select m.id, m.product_name,
         coalesce(nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric, 100),
         coalesce(m.gst_percent, 12)
    from public."MEDICINE" m
   where coalesce(m.buyable,false) and m.product_name is not null
     and not exists (select 1 from public.inquiry i
                      where i.product_id = m.id
                        and i.batch_date = (now() at time zone 'Asia/Kolkata')::date)
     and not exists (select 1 from public.order_items oi
                      where oi.product_id = m.id
                        and oi.order_date = (now() at time zone 'Asia/Kolkata')::date)
   order by m.id
   limit greatest(coalesce(p_n,2), 1);
$function$;

-- One stage. Returns {ok, error, ctx, ...detail}. Every branch asserts the
-- state it is supposed to have produced — a call that returns ok while the
-- pipeline did not move is still a failure.
create or replace function public._hb_stage(p_key text, p_run bigint, p_ctx jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_order uuid   := nullif(p_ctx->>'order_id','')::uuid;
  v_sup   text   := nullif(p_ctx->>'supplier_name','');
  v_supid uuid   := nullif(p_ctx->>'supplier_id','')::uuid;
  v_zone  smallint := nullif(p_ctx->>'zone_id','')::smallint;
  v_date  date   := coalesce(nullif(p_ctx->>'order_date','')::date, (now() at time zone 'Asia/Kolkata')::date);
  v_since timestamptz := coalesce(nullif(p_ctx->>'since','')::timestamptz, now() - interval '1 hour');
  v_fix jsonb; v_ph uuid; v_rider uuid; v_name text; v_total numeric := 0;
  v_items jsonb := '[]'::jsonb; r record; v_n int := 0; v_res jsonb; v_bag int;
  v_inq bigint; v_so uuid; v_del uuid; v_code text; v_msgs int; v_lines int;
begin
  ---------------------------------------------------------------- fixtures --
  if p_key = 'fixtures' then
    v_fix := public.test_fixtures_ensure();
    if not coalesce((v_fix->>'ok')::boolean,false) then
      return jsonb_build_object('ok', false, 'error', coalesce(v_fix->>'error','fixtures_failed'), 'fixtures', v_fix);
    end if;
    v_ph    := (v_fix->>'pharmacy_id')::uuid;
    v_supid := (v_fix->>'supplier_id')::uuid;
    v_rider := (v_fix->>'rider_id')::uuid;
    v_zone  := (v_fix->>'zone_id')::smallint;
    if v_ph is null or v_supid is null or v_rider is null then
      return jsonb_build_object('ok', false, 'error','fixture_missing', 'fixtures', v_fix);
    end if;
    -- the cast must be MARKED, or nothing downstream is excluded
    if not (select coalesce(is_synthetic,false) from public.pharmacy_profiles where id = v_ph)
       or not (select coalesce(is_synthetic,false) from public.supplier_profiles where id = v_supid) then
      return jsonb_build_object('ok', false, 'error','fixture_not_marked_synthetic');
    end if;
    -- A rider cannot take a stop until training is passed. The synthetic rider
    -- will never sit a module, so use the platform's own admin override — the
    -- same door a real onboarding uses — rather than writing training rows.
    begin
      if coalesce((public.delivery_training_state(v_rider)->>'blocks_assignment')::boolean, false) then
        v_res := public.admin_training_override(v_rider, 'synthetic heartbeat rider');
      end if;
    exception when others then v_res := jsonb_build_object('error', sqlerrm); end;
    select label into v_name from public.test_fixture where key='supplier';
    return jsonb_build_object('ok', true, 'fixtures', v_fix, 'training', v_res,
      'ctx', jsonb_build_object('pharmacy_id', v_ph, 'supplier_id', v_supid,
                                'supplier_name', v_name, 'rider_id', v_rider,
                                'zone_id', v_zone, 'order_date', v_date));
  end if;

  ------------------------------------------------------------------- order --
  if p_key = 'order' then
    v_ph := nullif(p_ctx->>'pharmacy_id','')::uuid;
    select label into v_name from public.test_fixture where key='pharmacy';
    insert into public.orders (customer_id, user_id, pharmacy_name, phone, address, status,
                               fulfillment_status, source, zone_id, order_date, total_amount,
                               items, placed_by_admin, is_synthetic)
    values (v_ph, null, v_name, '9000000573', 'Synthetic Test Lane', 'accepted',
            'open', 'website', v_zone, v_date, 0, '[]'::jsonb, true, true)
    returning id into v_order;

    for r in select * from public._hb_pick_products(2) loop
      insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                      gst_percent, line_total, pharmacy_name, status, order_date, zone_id)
      values (v_order, r.id, r.product_name, 2, r.mrp, round(r.mrp * 0.80, 2), r.gst,
              round(r.mrp * 0.80 * 2, 2), v_name, 'pending', v_date, v_zone);
      v_total := v_total + round(r.mrp * 0.80 * 2, 2);
      v_items := v_items || jsonb_build_object('product_id', r.id, 'name', r.product_name,
                                               'qty', 2, 'price', round(r.mrp * 0.80, 2));
      v_n := v_n + 1;
    end loop;
    update public.orders set total_amount = v_total, items = v_items where id = v_order;
    select order_code into v_code from public.orders where id = v_order;

    if v_n < 2 then
      return jsonb_build_object('ok', false, 'error','no_free_products',
        'note','every candidate medicine already has a live inquiry or order today', 'lines', v_n);
    end if;
    if not (select coalesce(is_synthetic,false) from public.orders where id = v_order) then
      return jsonb_build_object('ok', false, 'error','order_not_marked_synthetic', 'order_id', v_order);
    end if;
    return jsonb_build_object('ok', true, 'lines', v_n, 'total', v_total, 'order_code', v_code,
      'ctx', jsonb_build_object('order_id', v_order, 'order_code', v_code, 'lines', v_n));
  end if;

  ----------------------------------------------------------------- payment --
  if p_key = 'payment' then
    v_res := public.test_sim_payment_capture(v_order, null, null);
    if not coalesce((v_res->>'ok')::boolean,false) then
      return jsonb_build_object('ok', false, 'error', coalesce(v_res->>'error','payment_failed'), 'detail', v_res);
    end if;
    if not exists (select 1 from public.payment_claims
                    where order_id = v_order and status='verified' and is_synthetic) then
      return jsonb_build_object('ok', false, 'error','no_verified_claim', 'detail', v_res);
    end if;
    if not public.order_is_paid(v_order) then
      return jsonb_build_object('ok', false, 'error','order_not_paid', 'detail', v_res);
    end if;
    return jsonb_build_object('ok', true, 'payment', v_res);
  end if;

  ----------------------------------------------------------------- inquiry --
  if p_key = 'inquiry' then
    perform public.inquiry_start_batch_for_order(v_order);
    select count(*) into v_lines from public.order_items
     where order_id = v_order and inquiry_id is not null;
    if v_lines < coalesce((p_ctx->>'lines')::int, 1) then
      return jsonb_build_object('ok', false, 'error','lines_not_inquired',
        'inquired', v_lines, 'expected', (p_ctx->>'lines')::int);
    end if;
    -- the canary must never have joined a REAL inquiry line
    if exists (select 1 from public.order_items oi
                 join public.inquiry i on i.id = oi.inquiry_id
                where oi.order_id = v_order and not coalesce(i.is_synthetic,false)) then
      return jsonb_build_object('ok', false, 'error','joined_a_real_inquiry_line');
    end if;
    update public.inquiry set zone_id = coalesce(zone_id, v_zone), batch_date = coalesce(batch_date, v_date)
     where id in (select inquiry_id from public.order_items where order_id = v_order and inquiry_id is not null);
    return jsonb_build_object('ok', true, 'inquired', v_lines);
  end if;

  --------------------------------------------------------- supplier_answer --
  -- SIMULATED on purpose. The synthetic supplier's number is a dummy and stays
  -- uncontacted: the outbound gate suppresses anything that is not Om's own
  -- test number, and this stage proves it after the fact.
  if p_key = 'supplier_answer' then
    for r in select oi.id, oi.inquiry_id, oi.quantity, oi.mrp, oi.gst_percent
               from public.order_items oi where oi.order_id = v_order loop
      update public.inquiry
         set "PS1" = v_sup, "AS1" = 'Available',
             current_supplier = v_sup, current_status = 'Available',
             asked_at = now(), quantity = r.quantity,
             mrp = coalesce(mrp, r.mrp), zone_id = coalesce(zone_id, v_zone),
             batch_date = coalesce(batch_date, v_date)
       where id = r.inquiry_id;
      update public.order_items
         set assigned_supplier = v_sup, fulfillment_state = 'pending',
             unfulfillable = false, unfulfillable_at = null
       where id = r.id;
      v_n := v_n + 1;
    end loop;
    if v_n = 0 then return jsonb_build_object('ok', false, 'error','no_lines_answered'); end if;
    select count(*) into v_msgs from public.whatsapp_messages
     where created_at >= v_since and coalesce(direction,'') = 'out'
       and coalesce(is_synthetic,false) and coalesce(wa_status,'') <> 'suppressed';
    if v_msgs > 0 then
      return jsonb_build_object('ok', false, 'error','synthetic_outbound_escaped', 'messages', v_msgs);
    end if;
    return jsonb_build_object('ok', true, 'answered', v_n, 'supplier', v_sup,
      'outbound_to_real_numbers', 0);
  end if;

  ---------------------------------------------------------- supplier_order --
  if p_key = 'supplier_order' then
    v_so := public.commit_supplier_order(v_sup);
    if v_so is null then
      select id into v_so from public.supplier_orders
       where supplier_name = v_sup and order_date = v_date
       order by created_at desc limit 1;
    end if;
    if v_so is null then
      return jsonb_build_object('ok', false, 'error','no_supplier_order_cut', 'supplier', v_sup);
    end if;
    if not (select coalesce(is_synthetic,false) from public.supplier_orders where id = v_so) then
      return jsonb_build_object('ok', false, 'error','supplier_order_not_marked_synthetic',
                                'supplier_order_id', v_so);
    end if;
    return jsonb_build_object('ok', true, 'supplier_order_id', v_so,
      'ctx', jsonb_build_object('supplier_order_id', v_so));
  end if;

  ----------------------------------------------------------------- collect --
  if p_key = 'collect' then
    -- _supplier_shop_stage() is "no supplier_count_mode row exists". A row left
    -- by yesterday's canary would put this supplier straight into the warehouse
    -- and the shop count would never happen — so clear the SYNTHETIC supplier's
    -- own rows and start the cycle where a real one starts it.
    delete from public.supplier_count_mode where assigned_supplier = v_sup;
    v_res := public.fw_mark_all_received(v_sup);
    select count(*) into v_n from public.order_items
     where order_id = v_order and coalesce(shop_qty,0) >= quantity;
    if v_n < coalesce((p_ctx->>'lines')::int,1) then
      return jsonb_build_object('ok', false, 'error','lines_not_collected',
        'collected', v_n, 'detail', v_res);
    end if;
    return jsonb_build_object('ok', true, 'collected', v_n, 'detail', v_res);
  end if;

  ------------------------------------------------------------------- count --
  if p_key = 'count' then
    v_res := public.fw_confirm_counting(v_sup, v_date, true);
    if coalesce(v_res->>'error','') <> '' then
      return jsonb_build_object('ok', false, 'error', v_res->>'error', 'confirm', v_res);
    end if;
    select count(*) into v_n from public.order_items
     where order_id = v_order and coalesce(collect_locked,false);
    if v_n < coalesce((p_ctx->>'lines')::int,1) then
      return jsonb_build_object('ok', false, 'error','not_forwarded_to_warehouse',
        'forwarded', v_n, 'confirm', v_res);
    end if;
    return jsonb_build_object('ok', true, 'forwarded', v_n, 'confirm', v_res);
  end if;

  --------------------------------------------------------------------- bag --
  if p_key = 'bag' then
    -- In the real warehouse the bag count IS the count: bag_count_set writes
    -- bag_item_counts, and receiving then allocates the group into that bag
    -- (_bag_alloc_on_received). Bagging after the lines are received is too
    -- late — the line is locked by then.
    select coalesce(max(bag_no),0) + 1 into v_bag from public.bags;
    insert into public.bags (bag_no, status, note, is_synthetic)
    values (v_bag, 'empty', 'heartbeat canary bag', true)
    on conflict (bag_no) do nothing;
    for r in select oi.id, oi.product_id, oi.quantity
               from public.order_items oi where oi.order_id = v_order loop
      v_items := v_items || jsonb_build_object('count_set',
        public.bag_count_set(v_sup, r.product_id, r.quantity, 'heartbeat', v_bag, v_date));
    end loop;
    -- now receive it in the warehouse; the trigger allocates into the bag
    v_res := public.fw_mark_all_received(v_sup);
    select count(*) into v_n from public.order_items
     where order_id = v_order and coalesce(received_qty,0) >= quantity and coalesce(at_warehouse,false);
    if v_n < coalesce((p_ctx->>'lines')::int,1) then
      return jsonb_build_object('ok', false, 'error','lines_not_received',
        'received', v_n, 'receive', v_res, 'counts', v_items);
    end if;
    select count(*) into v_lines from public.bag_allocations where order_id = v_order;
    if v_lines = 0 then
      return jsonb_build_object('ok', false, 'error','nothing_bagged',
        'bag_no', v_bag, 'counts', v_items, 'receive', v_res);
    end if;
    if exists (select 1 from public.bag_allocations
                where order_id = v_order and not coalesce(is_synthetic,false)) then
      return jsonb_build_object('ok', false, 'error','bag_allocation_not_marked_synthetic');
    end if;
    return jsonb_build_object('ok', true, 'allocations', v_lines, 'received', v_n, 'bag_no', v_bag);
  end if;

  -------------------------------------------------------------------- pack --
  if p_key = 'pack' then
    -- Dispatch-ready needs BOTH halves the pack screen asks for: the pack-stage
    -- count and the packed quantity. Marking packed alone leaves the order
    -- 'not_fully_counted' and it never reaches a rider.
    for r in select oi.id, oi.quantity from public.order_items oi
              where oi.order_id = v_order loop
      v_items := v_items || jsonb_build_object(
        'counted', public.pack_set_counted_item(r.id, r.quantity),
        'packed',  public.pack_mark_item(r.id, true, r.quantity));
    end loop;
    v_res := public.pack_set_dispatch_ready(v_order, true);
    if not coalesce((select dispatch_ready from public.orders where id = v_order), false) then
      return jsonb_build_object('ok', false,
        'error', coalesce(nullif(v_res->>'error',''), 'not_dispatch_ready'),
        'detail', v_res, 'lines', v_items);
    end if;
    select count(*) into v_n from public.order_items where order_id = v_order and coalesce(packed,false);
    return jsonb_build_object('ok', true, 'packed', v_n, 'dispatch_ready', true);
  end if;

  ------------------------------------------------------------------ assign --
  if p_key = 'assign' then
    v_rider := nullif(p_ctx->>'rider_id','')::uuid;
    begin v_res := public.delivery_assign(array[v_order]::uuid[], v_rider);
    exception when others then v_res := jsonb_build_object('error', sqlerrm); end;
    if not exists (select 1 from public.deliveries where order_id = v_order and partner_id = v_rider) then
      return jsonb_build_object('ok', false, 'error','not_assigned', 'detail', v_res);
    end if;
    if exists (select 1 from public.deliveries where order_id = v_order and partner_id <> v_rider) then
      return jsonb_build_object('ok', false, 'error','assigned_to_a_real_rider');
    end if;
    return jsonb_build_object('ok', true, 'assign', v_res);
  end if;

  ----------------------------------------------------------------- deliver --
  if p_key = 'deliver' then
    -- The REAL proof-of-delivery path, end to end: the rider's OTP is sent,
    -- read back from delivery_otp (this is the canary's own delivery) and
    -- verified. Only the human tapping is simulated.
    select id into v_del from public.deliveries where order_id = v_order limit 1;
    if v_del is null then
      return jsonb_build_object('ok', false, 'error','no_delivery_row');
    end if;
    -- the rider's own taps are the simulated part; everything the PLATFORM
    -- does — handover evidence, OTP issue, OTP verification — is the real code
    update public.deliveries
       set accept_status = 'accepted', accepted_at = coalesce(accepted_at, now())
     where id = v_del and coalesce(accept_status,'') <> 'accepted';
    v_items := jsonb_build_object('handover', public.delivery_handover_scan(
      (select qr_token from public.deliveries where id = v_del), null, null, 'qr'));
    v_items := v_items || jsonb_build_object('otp_sent', public.delivery_send_otp(v_del));
    select code into v_code from public.delivery_otp where delivery_id = v_del;
    if coalesce(v_code,'') = '' then
      return jsonb_build_object('ok', false, 'error','no_otp_issued', 'detail', v_items);
    end if;
    v_res := public.delivery_verify_otp(v_del, v_code, null, null, 'TEST RECEIVER (SYNTHETIC)');
    if (select status from public.deliveries where id = v_del) <> 'delivered' then
      return jsonb_build_object('ok', false,
        'error', coalesce(nullif(v_res->>'error',''),'not_delivered'),
        'detail', v_res, 'otp', v_items);
    end if;
    if not exists (select 1 from public.deliveries where id = v_del and coalesce(is_synthetic,false)) then
      return jsonb_build_object('ok', false, 'error','delivery_not_marked_synthetic');
    end if;
    return jsonb_build_object('ok', true, 'delivery_id', v_del, 'verify', v_res);
  end if;

  -------------------------------------------------------------------- bill --
  if p_key = 'bill' then
    v_res := public.customer_invoice_issue(v_order);
    select invoice_no into v_code from public.orders where id = v_order;
    if coalesce(v_code,'') = '' then
      return jsonb_build_object('ok', false, 'error','no_invoice_number', 'detail', v_res);
    end if;
    -- a canary invoice comes off the TEST series; the real one must not move
    if not exists (select 1 from public.customer_invoice_series
                    where fy like 'TEST-%' and coalesce(is_synthetic,false)) then
      return jsonb_build_object('ok', false, 'error','invoice_off_the_real_series',
                                'invoice_no', v_code, 'detail', v_res);
    end if;

    -- the bill PDF: the real job, with the renderer's callback simulated
    v_items := public.bill_job_enqueue(v_order, true);
    if nullif(v_items->>'job_id','') is null then
      return jsonb_build_object('ok', false,
        'error', coalesce(nullif(v_items->>'reason',''),'no_bill_job'), 'detail', v_items,
        'ready', public._bill_ready(v_order));
    end if;
    v_items := v_items || jsonb_build_object('report', public.bill_job_report(
      (v_items->>'job_id')::uuid, true, 'customer-bills',
      'synthetic/heartbeat/' || v_order::text || '.pdf', 'heartbeat-bill.pdf', null));
    if nullif((select cust_bill_path from public.orders where id = v_order),'') is null then
      return jsonb_build_object('ok', false, 'error','bill_not_attached', 'detail', v_items);
    end if;

    -- the customer settles the bill: capture whatever the bill still shows due
    declare v_bill jsonb; v_rem numeric; begin
      v_bill := public.customer_bill(v_order);
      v_rem  := coalesce((v_bill->'totals'->>'remaining')::numeric, 0);
      if v_rem > 0 then
        v_items := v_items || jsonb_build_object('settle',
          public.test_sim_payment_capture(v_order, v_rem, null));
      end if;
      v_items := v_items || jsonb_build_object('bill_ready', v_bill->>'ready',
                                               'remaining_before', v_rem);
    end;

    v_res := public.delivery_eligibility(v_order);
    if not coalesce((v_res->>'can_assign')::boolean, false) then
      return jsonb_build_object('ok', false,
        'error', 'bill_stage_left_order_ineligible: ' || coalesce(v_res->>'blocked_label',''),
        'eligibility', v_res, 'detail', v_items);
    end if;
    return jsonb_build_object('ok', true, 'invoice_no', v_code,
      'eligibility', v_res, 'detail', v_items);
  end if;

  ------------------------------------------------------------------- close --
  if p_key = 'close' then
    v_res := public.order_try_close(v_order, 'auto', 'heartbeat', 'daily heartbeat canary');
    if (select closed_at from public.orders where id = v_order) is null then
      return jsonb_build_object('ok', false, 'error','order_not_closed', 'detail', v_res);
    end if;
    return jsonb_build_object('ok', true, 'close', v_res);
  end if;

  -------------------------------------------------------------- exclusions --
  if p_key = 'exclusions' then
    v_res := public.heartbeat_exclusion_audit(v_since);
    if not coalesce((v_res->>'ok')::boolean,false) then
      return jsonb_build_object('ok', false, 'error', coalesce(v_res->>'error','books_touched'), 'audit', v_res);
    end if;
    return jsonb_build_object('ok', true, 'audit', v_res, 'ctx', jsonb_build_object('audit', v_res));
  end if;

  return jsonb_build_object('ok', false, 'error','unknown_stage:'||coalesce(p_key,''));
end $function$;

-- ── E. THE EXCLUSION AUDIT ────────────────────────────────────────────────
-- Not a claim, a measurement. Every business surface named in the spec is
-- asked, with a synthetic order sitting in the database, whether it can see it.

create or replace function public.heartbeat_exclusion_audit(p_since timestamptz default now() - interval '1 day')
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v jsonb := '{}'::jsonb; v_bad text[] := '{}'; v_zone smallint;
  v_dash jsonb; v_dash_orders int; v_real_orders int; v_synth_orders int;
  v_pnl int; v_dem int; v_from date; v_to date;
begin
  -- 1. the ledgers: a synthetic row must never exist at all
  v := v || jsonb_build_object(
    'gst_ledger',          (select count(*) from public.gst_ledger where is_synthetic),
    'pharmacy_gst_ledger', (select count(*) from public.pharmacy_gst_ledger where is_synthetic),
    'partner_settlements', (select count(*) from public.partner_settlements where is_synthetic),
    'order_pnl_slab',      (select count(*) from public.order_pnl_slab where is_synthetic),
    'loyalty_ledger',      (select count(*) from public.loyalty_ledger where is_synthetic),
    'incentive_earnings',  (select count(*) from public.incentive_earnings where is_synthetic),
    'delivery_payout_lines',(select count(*) from public.delivery_payout_lines where is_synthetic));
  if (v->>'gst_ledger')::int > 0            then v_bad := v_bad || 'gst_ledger'; end if;
  if (v->>'pharmacy_gst_ledger')::int > 0   then v_bad := v_bad || 'pharmacy_gst_ledger'; end if;
  if (v->>'partner_settlements')::int > 0   then v_bad := v_bad || 'partner_settlements'; end if;
  if (v->>'order_pnl_slab')::int > 0        then v_bad := v_bad || 'order_pnl_slab'; end if;
  if (v->>'loyalty_ledger')::int > 0        then v_bad := v_bad || 'loyalty_ledger'; end if;
  if (v->>'incentive_earnings')::int > 0    then v_bad := v_bad || 'incentive_earnings'; end if;
  if (v->>'delivery_payout_lines')::int > 0 then v_bad := v_bad || 'delivery_payout_lines'; end if;

  -- 2. P&L (#319) and partner settlements (#323) both read through pnl_line_v
  select count(*) into v_pnl
    from public.pnl_order_v pv join public.orders o on o.id = pv.order_id
   where coalesce(o.is_synthetic,false);
  v := v || jsonb_build_object('pnl_order_v_synthetic_orders', v_pnl);
  if v_pnl > 0 then v_bad := v_bad || 'pnl_order_v'; end if;

  -- 3. the demand engine (#427) reads through _c427_bill_units
  v_to := (now() at time zone 'Asia/Kolkata')::date;
  v_from := v_to - 7;
  select count(*) into v_dem
    from public._c427_bill_units(v_from, v_to) u
    join public.pharmacy_profiles p on p.id = u.pharmacy_id
   where coalesce(p.is_synthetic,false);
  v := v || jsonb_build_object('demand_units_synthetic', v_dem);
  if v_dem > 0 then v_bad := v_bad || 'demand_engine'; end if;

  -- 4. the admin dashboard tile must print the real number, not the real+1
  v_zone := public.scope_zone(null);
  v_dash := public.admin_dashboard_counts(null, null);
  v_dash_orders := coalesce((v_dash->>'orders_today')::int, -1);
  select count(*) into v_real_orders from public.orders o
    left join public.pharmacy_profiles pp on pp.id = o.customer_id
   where (o.created_at at time zone 'Asia/Kolkata')::date = public.scope_date(null)
     and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)
     and not coalesce(o.is_synthetic,false);
  select count(*) into v_synth_orders from public.orders o
   where (o.created_at at time zone 'Asia/Kolkata')::date = public.scope_date(null)
     and coalesce(o.is_synthetic,false);
  v := v || jsonb_build_object('dashboard_orders_today', v_dash_orders,
                               'dashboard_real_orders_today', v_real_orders,
                               'synthetic_orders_today', v_synth_orders);
  if coalesce((v_dash->>'allowed')::boolean,false) and v_dash_orders <> v_real_orders then
    v_bad := v_bad || 'admin_dashboard_counts';
  end if;

  -- 5. WhatsApp: the dummy numbers stayed uncontacted
  v := v || public._test_outbound_count(p_since);
  if (v->>'wa_out')::int > 0     then v_bad := v_bad || 'whatsapp_out'; end if;
  if (v->>'wa_queued')::int > 0  then v_bad := v_bad || 'whatsapp_queued'; end if;
  if (v->>'retry_queued')::int > 0 then v_bad := v_bad || 'notification_retry'; end if;

  return jsonb_build_object(
    'ok', coalesce(array_length(v_bad,1),0) = 0,
    'error', case when coalesce(array_length(v_bad,1),0) > 0
                  then 'books_touched: ' || array_to_string(v_bad, ', ') end,
    'touched', to_jsonb(v_bad),
    'surfaces', v,
    'blocked_writes', (select count(*) from public.synthetic_blocked_write));
end $function$;

-- ── F. THE ALERT — first failure, urgent, naming the stage ────────────────
insert into public.wa_event_routes (event_key, label, description, audience, enabled,
                                    push_enabled, push_title, push_body, deep_link_kind)
values ('heartbeat_failed', 'Heartbeat failed',
        'The daily end-to-end canary stopped at a stage. Urgent: the pipeline is broken.',
        'admin', true, true,
        'Heartbeat FAILED at {{stage}}',
        'Order {{order}} stopped at {{stage}}: {{error}}',
        'admin')
on conflict (event_key) do update
  set audience = 'admin', enabled = true, push_enabled = true,
      push_title = excluded.push_title, push_body = excluded.push_body,
      label = excluded.label, description = excluded.description;

create or replace function public.heartbeat_alert(p_run bigint)
 returns jsonb language plpgsql security definer set search_path to 'public','net'
as $function$
declare r public.heartbeat_run%rowtype; cfg public.heartbeat_config%rowtype;
        v_phone text; v_vars jsonb; v_res jsonb; v_fp text; v_push jsonb; v_uid uuid;
begin
  select * into r from public.heartbeat_run where id = p_run;
  if r.id is null then return jsonb_build_object('ok', false, 'error','no_run'); end if;
  select * into cfg from public.heartbeat_config where id = 1;

  v_phone := coalesce(nullif(btrim(cfg.alert_phone),''),
                      (select value #>> '{}' from public.app_settings where key='admin_wa_phone'));
  v_vars := jsonb_build_object(
    'stage',      coalesce(r.failed_label, r.failed_stage, 'unknown'),
    'stage_key',  coalesce(r.failed_stage,''),
    'error',      coalesce(r.error,''),
    'order',      coalesce(r.order_code,''),
    'order_id',   coalesce(r.order_id::text,''),
    'run_id',     r.id::text,
    'audience',   'admin');

  -- PUSH FIRST, addressed by USER not by phone. Admin push tokens carry no
  -- phone10, so notify()'s phone-matched push finds nothing and the alert
  -- silently degrades to a queued WhatsApp with no approved template. The
  -- device push IS the urgent path, so it is asked for by user id.
  select u.id into v_uid
    from auth.users u
    join public.admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false)
     and exists (select 1 from public.push_tokens t
                  where t.is_active and t.user_id = u.id)
   order by u.created_at limit 1;
  if v_uid is null then
    select t.user_id into v_uid from public.push_tokens t
     where t.is_active and t.role in ('admin','super_admin') and t.user_id is not null
     order by t.created_at desc limit 1;
  end if;
  if v_uid is not null then
    begin
      v_push := public.notif_push_send(coalesce(cfg.alert_event_key,'heartbeat_failed'),
                                       v_phone, v_uid, null, v_vars, 'admin');
    exception when others then
      v_push := jsonb_build_object('ok', false, 'error', sqlerrm);
    end;
  else
    v_push := jsonb_build_object('ok', false, 'reason','no_admin_push_token');
  end if;

  begin
    v_res := public.notify(coalesce(cfg.alert_event_key,'heartbeat_failed'), v_phone,
                           v_vars || jsonb_build_object('_no_push', true));
  exception when others then
    v_res := jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  -- the same row Om reads at Dev Queue -> Cron health, so a missed push is
  -- still a visible, standing alarm rather than a lost message.
  v_fp := 'heartbeat_failed:' || coalesce(r.failed_stage,'unknown');
  insert into public.rg_alerts (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
  values (v_fp, 'critical', 'heartbeat', 'Daily heartbeat failed',
          jsonb_build_object('run_id', r.id, 'stage', r.failed_stage,
                             'stage_label', r.failed_label, 'error', r.error,
                             'order_id', r.order_id, 'order_code', r.order_code,
                             'notify', v_res, 'push', v_push),
          now(), now(), 1)
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = public.rg_alerts.seen_count + 1,
        severity = 'critical', detail = excluded.detail;

  update public.heartbeat_run
     set alert_sent = true,
         alert_detail = jsonb_build_object('notify', v_res, 'push', v_push,
                                           'delivered', coalesce((v_push->>'ok')::boolean,false)
                                                     or coalesce((v_res->>'ok')::boolean,false),
                                           'phone_present', v_phone is not null,
                                           'fingerprint', v_fp)
   where id = p_run;

  return jsonb_build_object('ok', true, 'notify', v_res, 'push', v_push, 'fingerprint', v_fp);
end $function$;

-- ── G. CLEANUP, THE RUNNER, THE CRON AND THE SCREEN'S PAYLOAD ─────────────

insert into public.ui_copy (key, value) values
  ('heartbeat.summary_ok',      '"Heartbeat OK — {{passed}}/{{total}} stages in {{secs}}s · order {{order}} · artifacts cleaned"'::jsonb),
  ('heartbeat.summary_fail',    '"Heartbeat FAILED at {{stage}} — {{error}} · order {{order}}"'::jsonb),
  ('heartbeat.summary_skipped', '"Heartbeat skipped — {{reason}}"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- Every row this run created joins the run's purge scope, so nothing it made
-- outlives it. Scoped by time as well as by the synthetic flag: a run never
-- adopts residue it did not create.
create or replace function public._hb_claim_rows(p_session bigint, p_since timestamptz)
 returns int language plpgsql security definer set search_path to 'public'
as $function$
declare t text; n int; v_total int := 0;
begin
  foreach t in array public._test_session_tables() loop
    -- The TEST invoice counter is deliberately NOT claimed. Purging it resets
    -- the series to 0001 while a leftover synthetic order still holds that
    -- number, and the next run dies on orders_invoice_no_uidx. The counter is
    -- infrastructure, not an artifact.
    continue when t = 'customer_invoice_series';
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=t and column_name='test_session_id')
      then continue; end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=t and column_name='is_synthetic')
      then continue; end if;
    begin
      -- Every synthetic row in these tables with no owning session is orphaned
      -- test residue: the books already ignore it and no purge will ever come
      -- for it. The cast itself (pharmacy/supplier/rider profiles) is not in
      -- this list, so adopting orphans can never delete the fixtures.
      execute format('update public.%I set test_session_id = $1
                       where coalesce(is_synthetic,false) and test_session_id is null', t)
        using p_session;
      get diagnostics n = row_count;
      v_total := v_total + n;
    exception when others then null;   -- a table that refuses the stamp shows up as residue
    end;
  end loop;
  return v_total;
end $function$;

create or replace function public.heartbeat_cleanup(p_run bigint)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare r public.heartbeat_run%rowtype; v_claimed int; v_purge jsonb;
        v_res jsonb; v_i int := 0;
begin
  select * into r from public.heartbeat_run where id = p_run;
  if r.id is null or r.test_session_id is null then
    return jsonb_build_object('ok', false, 'error','no_session');
  end if;
  v_claimed := public._hb_claim_rows(r.test_session_id, r.started_at - interval '1 minute');
  v_purge := public.test_session_purge(r.test_session_id);
  while coalesce((v_purge->>'ok')::boolean,false)
        and not coalesce((v_purge->>'done')::boolean,true) and v_i < 10 loop
    v_purge := public.test_session_purge(r.test_session_id);
    v_i := v_i + 1;
  end loop;
  v_res := jsonb_build_object(
    'ok', true, 'claimed_rows', v_claimed, 'purge', v_purge,
    'residue', public.test_session_residue(r.test_session_id));
  update public.heartbeat_run
     set cleanup = v_res,
         clean = coalesce((v_res#>>'{residue,total}')::bigint, 1) = 0
   where id = p_run;
  return v_res;
end $function$;

-- The run itself. One transaction, one stage at a time, first failure stops it.
create or replace function public.heartbeat_run_once(p_kind text default 'daily',
                                                     p_break_stage text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.heartbeat_config%rowtype;
  st record; v_run bigint; v_sess bigint; v_ctx jsonb; v_res jsonb;
  v_ok boolean; v_err text; v_t0 timestamptz; v_ms int; v_started timestamptz := clock_timestamp();
  v_total int; v_passed int := 0; v_fail_key text; v_fail_label text;
  v_order uuid; v_code text; v_secs numeric; v_line text; v_tpl text;
  v_clean jsonb; v_break text := nullif(btrim(coalesce(p_break_stage,'')),'');
  v_try int;
begin
  if not public._test_guard() then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select * into cfg from public.heartbeat_config where id = 1;
  if not coalesce(cfg.enabled, true) and coalesce(p_kind,'daily') = 'daily' then
    return jsonb_build_object('ok', true, 'skipped','disabled',
      'summary_line', public.notif_render(public.uic('heartbeat.summary_skipped',''),
                        jsonb_build_object('reason', public.uic('heartbeat.disabled',''))));
  end if;
  -- Om's own test session stamps every insert on the platform. The canary
  -- never runs underneath one: it would adopt his rows and he would be
  -- debugging against a database that moves on its own.
  if public.test_session_live_id() is not null then
    return jsonb_build_object('ok', true, 'skipped','test_mode_live',
      'summary_line', public.notif_render(public.uic('heartbeat.summary_skipped',''),
                        jsonb_build_object('reason', public.uic('heartbeat.busy',''))));
  end if;

  -- status 'canary', never 'live': test_sessions_one_live is a unique index on
  -- (true) where status='live', so a canary claiming it would lock Om out of
  -- his own test mode and serialise every run behind that one index tuple.
  insert into public.test_sessions (label, scope, status, started_by_label, expires_at)
  values ('heartbeat ' || to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
          'canary', 'canary', 'heartbeat', now() + interval '2 hours')
  returning id into v_sess;

  select count(*) into v_total from public.heartbeat_stage where enabled;
  insert into public.heartbeat_run (kind, status, test_session_id, break_stage, stages_total)
  values (coalesce(p_kind,'daily'), 'running', v_sess, v_break, v_total)
  returning id into v_run;

  -- everything created from here to the reset below is the canary's own
  perform set_config('medibo.synthetic', 'on', true);
  perform public._hb_impersonate();

  v_ctx := jsonb_build_object('since', v_started::text,
                              'order_date', (now() at time zone 'Asia/Kolkata')::date::text);

  for st in select * from public.heartbeat_stage where enabled order by ord loop
    v_t0 := clock_timestamp();
    insert into public.heartbeat_stage_run (run_id, ord, stage_key, label, status, timeout_ms)
    values (v_run, st.ord, st.stage_key, st.label, 'running',
            coalesce(st.timeout_ms, cfg.default_timeout_ms));
    v_try := 0;
    <<attempt>>
    loop
      v_try := v_try + 1;
      begin
        perform set_config('statement_timeout',
                           coalesce(st.timeout_ms, cfg.default_timeout_ms)::text, true);
        -- the session default is 5 s, which a busy warehouse refresh can exceed
        -- without anything being wrong; bound the wait by THIS stage's budget.
        perform set_config('lock_timeout',
                           least(coalesce(st.timeout_ms, cfg.default_timeout_ms), 15000)::text, true);
        if v_break is not null and st.stage_key = v_break then
          raise exception 'deliberate drill break at stage %', st.stage_key using errcode = 'P0001';
        end if;
        v_res := public._hb_stage(st.stage_key, v_run, v_ctx);
        v_ok  := coalesce((v_res->>'ok')::boolean, false);
        v_err := nullif(v_res->>'error','');
        if v_ok then v_ctx := v_ctx || coalesce(v_res->'ctx','{}'::jsonb); end if;
      exception
        when lock_not_available or serialization_failure or deadlock_detected then
          v_ok := false;
          v_err := sqlstate || ': ' || sqlerrm;
          v_res := jsonb_build_object('ok', false, 'error', v_err, 'contention', true, 'attempt', v_try);
        when query_canceled then
          v_ok := false;
          v_err := 'timed out after ' || coalesce(st.timeout_ms, cfg.default_timeout_ms)::text || ' ms';
          v_res := jsonb_build_object('ok', false, 'error', v_err, 'timeout', true);
        when others then
          v_ok := false;
          v_err := sqlstate || ': ' || sqlerrm;
          v_res := jsonb_build_object('ok', false, 'error', v_err);
      end;
      exit attempt when v_ok
                     or v_try >= 3
                     or not coalesce((v_res->>'contention')::boolean, false);
      perform pg_sleep(2);            -- two honest retries, then it is a failure
    end loop;
    perform set_config('statement_timeout', '0', true);
    perform set_config('lock_timeout', '5s', true);
    v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;

    update public.heartbeat_stage_run
       set status = case when v_ok then 'passed' else 'failed' end,
           ended_at = now(), ms = v_ms, detail = v_res, error = v_err
     where run_id = v_run and stage_key = st.stage_key;

    if not v_ok then
      v_fail_key := st.stage_key; v_fail_label := st.label;
      exit;                                    -- FIRST failure stops the run
    end if;
    v_passed := v_passed + 1;
  end loop;

  -- Anything still pending never ran; say so rather than leaving it blank.
  insert into public.heartbeat_stage_run (run_id, ord, stage_key, label, status, timeout_ms, ended_at)
  select v_run, s.ord, s.stage_key, s.label, 'skipped', s.timeout_ms, now()
    from public.heartbeat_stage s
   where s.enabled
     and not exists (select 1 from public.heartbeat_stage_run r
                      where r.run_id = v_run and r.stage_key = s.stage_key);

  -- the alert is a REAL message: stop stamping before it is written
  perform set_config('medibo.synthetic', 'off', true);

  v_order := nullif(v_ctx->>'order_id','')::uuid;
  v_code  := nullif(v_ctx->>'order_code','');
  v_secs  := round(extract(epoch from (clock_timestamp() - v_started))::numeric, 1);

  update public.heartbeat_run
     set status = case when v_fail_key is null then 'passed' else 'failed' end,
         ended_at = now(),
         ms = (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int,
         order_id = v_order, order_code = v_code,
         stages_passed = v_passed, failed_stage = v_fail_key, failed_label = v_fail_label,
         error = (select error from public.heartbeat_stage_run
                   where run_id = v_run and stage_key = v_fail_key),
         exclusions = v_ctx->'audit'
   where id = v_run;

  v_clean := public.heartbeat_cleanup(v_run);

  if v_fail_key is null then
    v_tpl := public.uic('heartbeat.summary_ok','');
    v_line := public.notif_render(v_tpl, jsonb_build_object(
      'passed', v_passed::text, 'total', v_total::text,
      'secs', v_secs::text, 'order', coalesce(v_code,'—')));
  else
    v_tpl := public.uic('heartbeat.summary_fail','');
    v_line := public.notif_render(v_tpl, jsonb_build_object(
      'stage', coalesce(v_fail_label, v_fail_key),
      'error', coalesce((select error from public.heartbeat_stage_run
                          where run_id = v_run and stage_key = v_fail_key), ''),
      'order', coalesce(v_code,'—')));
  end if;
  update public.heartbeat_run set summary_line = v_line where id = v_run;

  if v_fail_key is not null then
    perform public.heartbeat_alert(v_run);
  end if;

  return jsonb_build_object(
    'ok', v_fail_key is null, 'run_id', v_run, 'kind', coalesce(p_kind,'daily'),
    'order_id', v_order, 'order_code', v_code,
    'stages_passed', v_passed, 'stages_total', v_total,
    'failed_stage', v_fail_key, 'failed_label', v_fail_label,
    'summary_line', v_line, 'cleanup', v_clean,
    'clean', coalesce((select clean from public.heartbeat_run where id = v_run), false));
end $function$;

-- The cron entry point: run, then trim old runs.
create or replace function public.heartbeat_tick()
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare cfg public.heartbeat_config%rowtype; v jsonb;
begin
  select * into cfg from public.heartbeat_config where id = 1;
  v := public.heartbeat_run_once('daily', null);
  delete from public.heartbeat_run
   where started_at < now() - make_interval(days => greatest(coalesce(cfg.retain_days,30), 1));
  return v;
end $function$;

insert into public.cron_task (name, ord, mode, work_sql, enabled, run_at_ist, dml, note)
values ('heartbeat-daily', 470, 'poll', 'select public.heartbeat_tick()', true,
        '04:47:00', true,
        'CHANGE #468 — one synthetic order walks the whole pipeline. Offset minute on purpose: never a bare */N and never minute 0.')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = excluded.enabled,
      run_at_ist = excluded.run_at_ist, dml = excluded.dml,
      mode = excluded.mode, ord = excluded.ord, note = excluded.note;

-- ── H. THE SCREEN'S PAYLOAD — every string decided here, not in Dart ──────

create or replace function public._hb_tone(p_status text)
 returns text language sql immutable as $function$
  select case p_status when 'passed' then 'success'
                       when 'failed' then 'danger'
                       when 'running' then 'info'
                       else 'neutral' end;
$function$;

create or replace function public._hb_status_label(p_status text)
 returns text language sql stable security definer set search_path to 'public'
as $function$
  select case p_status
    when 'passed'  then public.uic('heartbeat.status_passed','Passed')
    when 'failed'  then public.uic('heartbeat.status_failed','Failed')
    when 'running' then public.uic('heartbeat.status_running','Running')
    else public.uic('heartbeat.status_skipped','Skipped') end;
$function$;

create or replace function public._hb_ms_label(p_ms int)
 returns text language sql immutable as $function$
  select case when p_ms is null then '—'
              when p_ms < 1000 then p_ms::text || ' ms'
              else round(p_ms / 1000.0, 1)::text || ' s' end;
$function$;

create or replace function public._hb_when(p_at timestamptz)
 returns text language sql stable security definer set search_path to 'public'
as $function$
  select case when p_at is null then public.uic('heartbeat.never','never')
              else to_char(p_at at time zone 'Asia/Kolkata', 'DD Mon, HH24:MI') || ' IST' end;
$function$;

create or replace function public._hb_run_row(r public.heartbeat_run)
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'id',            r.id,
    'kind',          r.kind,
    'status',        r.status,
    'status_label',  public._hb_status_label(r.status),
    'status_tone',   public._hb_tone(r.status),
    'when_label',    public._hb_when(r.started_at),
    'duration_label',public._hb_ms_label(r.ms),
    'summary_line',  coalesce(r.summary_line,''),
    'order_code',    coalesce(r.order_code,''),
    'failed_stage',  coalesce(r.failed_label, r.failed_stage,''),
    'error',         coalesce(r.error,''),
    'stage_label',   public.notif_render(public.uic('heartbeat.stage_of','{{done}} of {{total}} stages'),
                       jsonb_build_object('done', r.stages_passed::text, 'total', r.stages_total::text)),
    'alert_label',   case when r.status = 'failed'
                          then case when r.alert_sent
                                    then public.uic('heartbeat.alert_sent','Alert sent')
                                    else public.uic('heartbeat.alert_not_sent','Alert not sent') end
                     end,
    'alert_tone',    case when r.status = 'failed'
                          then case when r.alert_sent then 'warning' else 'danger' end end,
    'clean_label',   case when r.ended_at is not null
                          then case when coalesce(r.clean,false)
                                    then public.uic('heartbeat.clean','Artifacts cleaned up')
                                    else public.uic('heartbeat.not_clean','Artifacts left behind') end
                     end,
    'clean_tone',    case when r.ended_at is not null
                          then case when coalesce(r.clean,false) then 'success' else 'warning' end end,
    'is_drill',      r.break_stage is not null,
    'break_stage',   coalesce(r.break_stage,''));
$function$;

create or replace function public.heartbeat_home(p_limit int default 12)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare cfg public.heartbeat_config%rowtype; v_last public.heartbeat_run%rowtype;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin')
     and not public._test_guard() then
    return jsonb_build_object('ok', false, 'allowed', false,
      'error_title', public.uic('heartbeat.error_title','Could not load the heartbeat'));
  end if;
  select * into cfg from public.heartbeat_config where id = 1;
  select * into v_last from public.heartbeat_run order by started_at desc limit 1;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title',        public.uic('heartbeat.title','Daily heartbeat'),
    'subtitle',     public.uic('heartbeat.subtitle',''),
    'empty_label',  public.uic('heartbeat.empty',''),
    'error_title',  public.uic('heartbeat.error_title','Could not load the heartbeat'),
    'retry_label',  public.uic('heartbeat.retry','Retry'),
    'section_runs', public.uic('heartbeat.section_runs','Recent runs'),
    'section_stages', public.uic('heartbeat.section_stages','Stages'),
    'enabled',      coalesce(cfg.enabled, true),
    'disabled_note', case when not coalesce(cfg.enabled,true)
                          then public.uic('heartbeat.disabled','') end,
    'schedule_label', (select case when run_at_ist is null then '—'
                                   else to_char(run_at_ist,'HH24:MI') || ' IST daily' end
                         from public.cron_task where name = 'heartbeat-daily'),
    'actions', jsonb_build_array(
      jsonb_build_object('key','run',  'label', public.uic('heartbeat.run_now','Run heartbeat now'),
                         'tone','brand'),
      jsonb_build_object('key','drill','label', public.uic('heartbeat.run_drill','Run alert drill'),
                         'tone','neutral', 'hint', public.uic('heartbeat.drill_hint',''))),
    'last', case when v_last.id is not null then public._hb_run_row(v_last) end,
    'runs', coalesce((select jsonb_agg(public._hb_run_row(r) order by r.started_at desc)
                        from (select * from public.heartbeat_run
                               order by started_at desc limit greatest(coalesce(p_limit,12),1)) r),
                     '[]'::jsonb),
    'stages', coalesce((select jsonb_agg(jsonb_build_object(
                          'ord', s.ord, 'key', s.stage_key, 'label', s.label,
                          'note', coalesce(s.note,''),
                          'timeout_label', public._hb_ms_label(coalesce(s.timeout_ms, cfg.default_timeout_ms)))
                          order by s.ord)
                        from public.heartbeat_stage s where s.enabled), '[]'::jsonb));
end $function$;

create or replace function public.heartbeat_run_detail(p_run bigint)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare r public.heartbeat_run%rowtype;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin')
     and not public._test_guard() then
    return jsonb_build_object('ok', false, 'allowed', false);
  end if;
  select * into r from public.heartbeat_run where id = p_run;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'empty_label', public.uic('heartbeat.empty',''));
  end if;
  return jsonb_build_object('ok', true, 'allowed', true,
    'run', public._hb_run_row(r),
    'section_stages', public.uic('heartbeat.section_stages','Stages'),
    'stages', coalesce((select jsonb_agg(jsonb_build_object(
        'ord', sr.ord, 'key', sr.stage_key, 'label', sr.label,
        'status', sr.status,
        'status_label', public._hb_status_label(sr.status),
        'status_tone',  public._hb_tone(sr.status),
        'ms_label', public._hb_ms_label(sr.ms),
        'error', coalesce(sr.error,'')) order by sr.ord)
      from public.heartbeat_stage_run sr where sr.run_id = r.id), '[]'::jsonb),
    'exclusions', coalesce(r.exclusions, '{}'::jsonb),
    'cleanup', coalesce(r.cleanup, '{}'::jsonb));
end $function$;

create or replace function public.heartbeat_run_now(p_break_stage text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin')
     and not public._test_guard() then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  return public.heartbeat_run_once(
    case when coalesce(btrim(p_break_stage),'') = '' then 'manual' else 'drill' end,
    p_break_stage);
end $function$;

grant execute on function public.heartbeat_home(int)            to authenticated;
grant execute on function public.heartbeat_run_detail(bigint)   to authenticated;
grant execute on function public.heartbeat_run_now(text)        to authenticated;
grant execute on function public.heartbeat_exclusion_audit(timestamptz) to authenticated;
revoke execute on function public.heartbeat_run_once(text, text) from authenticated, anon;
revoke execute on function public.heartbeat_tick()               from authenticated, anon;

-- ── I. A WAKE SIGNAL MUST NEVER BLOCK A CUSTOMER ORDER ───────────────────
-- Found while proving the canary: every insert into `orders` fires
-- trg_cron_wake_unfulfilled -> cron_wake(), which upserts one row of
-- cron_signal. The dispatcher holds those rows for its whole run, so an order
-- placed while cron_dispatch() is working waits on a transactionid lock — the
-- canary hit 55P03 three runs in a row, and a real customer order takes the
-- same wait. A wake is a HINT, not a ledger entry: if the dispatcher is
-- holding the row it is already running, which is precisely what the hint was
-- for. Take it without waiting or skip it.
create or replace function public.cron_wake(p_task text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if exists (select 1 from public.cron_signal where task = p_task) then
    -- bump it only if the row is free RIGHT NOW; never queue behind a dispatch
    if exists (select 1 from public.cron_signal where task = p_task for update skip locked) then
      update public.cron_signal set last_at = now(), n = n + 1 where task = p_task;
    end if;
    return;
  end if;
  insert into public.cron_signal (task) values (p_task)
  on conflict (task) do nothing;
exception
  when foreign_key_violation then return;
  when lock_not_available   then return;   -- a missed hint costs one poll interval
end $function$;

-- ── J. A DIRTY FLAG MUST NEVER BLOCK A CUSTOMER ORDER ────────────────────
-- The second contention the canary found, same shape as cron_wake. An order
-- accepted on the storefront fires tg_reset_inquiry_on_accept -> the inquiry
-- row changes -> trg_omp_dirty updates ONE row of job_dirty_state. The
-- dispatcher's recompute_ordered_medicine_points holds that row for the whole
-- recompute (90 s+ measured here), so every order placed in that window waits
-- on a transactionid lock. The canary hit it three runs running; a real
-- customer order takes exactly the same wait.
--
-- Marking a job dirty is a HINT. If the row is locked the job is running RIGHT
-- NOW, which is what the hint asks for; skipping costs at worst one refresh
-- interval, while waiting costs the order. It is never allowed to fail the
-- write that triggered it.
create or replace function public.job_mark_dirty(p_jobs text[])
 returns int
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare j text; n int := 0;
begin
  foreach j in array coalesce(p_jobs, '{}') loop
    begin
      if exists (select 1 from public.job_dirty_state
                  where job = j and not coalesce(dirty,false) for update skip locked) then
        update public.job_dirty_state set dirty = true where job = j;
        n := n + 1;
      end if;
    exception when lock_not_available or others then null;
    end;
  end loop;
  return n;
end $function$;

create or replace function public.trg_omp_dirty()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  perform public.job_mark_dirty(array['ordered_medicine_points']);
  return null;
end $function$;

create or replace function public.trg_medicine_marks_refresh_jobs_dirty()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  perform public.job_mark_dirty(
    array['therapeutic_categories','storefront_feed','medicine_companies']);
  return null;
end $function$;

-- ── K. THE SCREEN'S ENTRY POINT — one registry row, no Dart list ──────────
-- The dev-tools sheet is drawn from feature_registry, so the Heartbeat screen
-- becomes reachable by INSERTING a row. The only Dart that has to know the key
-- is _handleAdminNav's case in home_shell.dart.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, search_terms, description, canonical_key)
values
  ('devtool.heartbeat', 'Daily heartbeat', 'Runtime & health', 'timeline',
   'heartbeat', 46, 'medibo', false, 'none', true, 'system', 'dev_tools',
   array['super_admin']::text[],
   'heartbeat canary daily synthetic order end to end pipeline alert drill stages',
   'One synthetic order walks the whole pipeline every morning; the first failure alerts',
   'devtool.heartbeat')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      sort_order = excluded.sort_order, is_active = excluded.is_active,
      surface = excluded.surface, roles_allowed = excluded.roles_allowed,
      search_terms = excluded.search_terms, description = excluded.description;

-- ── L. THE PROTECTED PROOF, IN SQL ───────────────────────────────────────
-- The exclusion is a database property, so its permanent test is a database
-- test: rg_check() runs this before every command completes. It proves both
-- halves — the ledgers REFUSE a synthetic write, and the two leaf views the
-- whole of P&L, settlements and the demand engine read through still carry
-- their filter. Re-creating pnl_line_v or _c427_bill_units without it turns
-- this red in the same command that did it.
insert into public.rg_behavior_tests (name, body, enabled, note) values
('heartbeat_synthetic_excluded', $body$do $rg$
declare n int; v text;
begin
  -- 1. the ledgers refuse a synthetic write outright
  insert into public.order_pnl_slab (order_id, slab_pct, ptr_total, source, is_synthetic)
  values (gen_random_uuid(), 0, 0, 'rg', true);
  select count(*) into n from public.order_pnl_slab where source = 'rg';
  if n > 0 then raise exception 'RG_FAIL: a synthetic row reached order_pnl_slab'; end if;

  -- 2. the seven books tables all still carry the block
  select count(*) into n
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
   where p.proname = '_synthetic_books_block' and not t.tgisinternal;
  if n < 7 then
    raise exception 'RG_FAIL: only % books-block triggers left (expected >= 7)', n;
  end if;

  -- 3. P&L and partner settlements read through pnl_line_v
  select pg_get_viewdef('public.pnl_line_v'::regclass, true) into v;
  if v !~* 'is_synthetic' then
    raise exception 'RG_FAIL: pnl_line_v lost its synthetic filter — P&L and settlements can see a canary order';
  end if;

  -- 4. the whole demand engine reads through _c427_bill_units
  select pg_get_functiondef(p.oid) into v from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_c427_bill_units';
  if v !~* 'is_synthetic' then
    raise exception 'RG_FAIL: _c427_bill_units lost its synthetic filter — the demand engine can see a canary bill';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;$body$, true,
'CHANGE #468 — a synthetic order must stay invisible to every book: the ledgers refuse the write, and pnl_line_v / _c427_bill_units keep the filter that hides it from P&L, settlements, GST and the demand engine.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

-- The door itself. surface_route is the declaration the #570 surface-map audit
-- checks: a live tile whose route no dispatcher declares is a door onto
-- nothing. openDevTool() in dev_queue_screen.dart is the dispatcher.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('heartbeat', 'devtool.heartbeat', 'feature', 'dev_queue_screen',
        'CHANGE #468 — openDevTool() pushes AdminHeartbeatScreen.', true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true;

-- ── M. THE SUPPLIER BILL PAIRING — settle and the panel now agree ────────
CREATE OR REPLACE FUNCTION public.supplier_order_try_settle(p_supplier_order_id uuid, p_mode text DEFAULT 'auto'::text, p_actor text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st jsonb; so supplier_orders%rowtype; v_day date; v_sid uuid;
begin
  select * into so from supplier_orders where id = p_supplier_order_id;
  if not found then return jsonb_build_object('ok',false,'error','supplier_order_not_found'); end if;
  if so.settled_at is not null then
    return public._supplier_settle_state(p_supplier_order_id) || jsonb_build_object('already', true);
  end if;
  if coalesce(so.status,'') = 'cancelled' then
    return jsonb_build_object('ok',true,'closed',false,'skipped','cancelled');
  end if;

  st := public._supplier_settle_state(p_supplier_order_id);
  if coalesce((st->>'ok')::boolean,false) is not true then return st; end if;
  if p_mode <> 'override' and coalesce((st->>'can_close')::boolean,false) is not true then
    return st;
  end if;

  perform set_config('medibo.closing', '1', true);
  v_day := coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date);
  v_sid := coalesce(so.supplier_id,
             (select id from supplier_profiles where lower(supplier_name)=lower(so.supplier_name) limit 1));

  update supplier_orders
     set status         = 'closed',
         settled_at     = now(),
         settled_by     = coalesce(p_actor,'system'),
         settled_reason = p_reason,
         settle_mode    = case when p_mode = 'override' then 'override' else 'auto' end
   where id = p_supplier_order_id;

  -- The bill itself is stamped settled — same supplier, same IST day, which is
  -- the exact pairing sup_order_bill_panel() totals the money from.
  --
  -- CHANGE #468: it was NOT the same pairing. This used v_day
  -- (= coalesce(order_date, created IST)) while the panel matches on the
  -- CREATED date alone — the strict rule locked with Om on 23 Jul. The two
  -- agree only while order_date equals the created date, so the moment a
  -- rebuild re-stamped created_at, a settled supplier order's bill was never
  -- stamped settled and stayed open money on the supplier ledger. Match the
  -- panel exactly.
  update pending_bills pb
     set settled_at = now(), settled_order_id = p_supplier_order_id
   where pb.settled_at is null
     and lower(coalesce(pb.verdict,'')) <> 'fake'
     and (pb.imported_at is not null or lower(coalesce(pb.status,'')) = 'imported')
     and (pb.received_at at time zone 'Asia/Kolkata')::date
         = (so.created_at at time zone 'Asia/Kolkata')::date
     and ((v_sid is not null and pb.supplier_id = v_sid::text)
       or (pb.supplier_id is null and pb.supplier_name is not null
           and lower(pb.supplier_name) = lower(so.supplier_name)));

  -- 'shipped' IS the removal from the supplier open-order scope: it is the
  -- filter bill_lines_from_scan() matches a scanned line against.
  update order_items oi
     set fulfillment_state = 'shipped'
    from orders o
   where o.id = oi.order_id
     and oi.assigned_supplier = so.supplier_name
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
     and coalesce(oi.fulfillment_state,'') not in ('cancelled','shipped');

  insert into order_closure_log(kind, supplier_order_id, event, mode, actor, reason, blockers)
  values ('supplier_order', p_supplier_order_id, 'settled',
          case when p_mode = 'override' then 'override' else 'auto' end,
          coalesce(p_actor,'system'), p_reason, coalesce(st->'blockers','[]'::jsonb));

  perform set_config('medibo.closing', '', true);
  return public._supplier_settle_state(p_supplier_order_id) || jsonb_build_object('just_closed', true);
end $function$;

update public.rg_behavior_tests
   set body = $ocs$

do $rg$
declare v_soid uuid; v_sname text; v_day date; v_ss jsonb; v_amt numeric; v_panel jsonb;
        v_reopened int;
begin
  set local statement_timeout = '60s';
  set local lock_timeout = '5s';
  set local idle_in_transaction_session_timeout = '60s';
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email)=lower(u.email) limit 1), true);

  select so.id, so.supplier_name, coalesce(so.order_date,(so.created_at at time zone 'Asia/Kolkata')::date)
    into v_soid, v_sname, v_day
    from supplier_orders so
   where so.settled_at is null and coalesce(so.status,'') not in ('closed','shipped','cancelled')
     and exists (select 1 from order_items x join orders o on o.id=x.order_id
                  where x.assigned_supplier = so.supplier_name
                    and (o.created_at at time zone 'Asia/Kolkata')::date =
                        coalesce(so.order_date,(so.created_at at time zone 'Asia/Kolkata')::date)
                    and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable','shipped'))
   order by so.created_at desc limit 1;
  -- CHANGE #229 (auto-heal) — never pass vacuously. Settling marks a supplier
  -- order 'closed' and its lines 'shipped', so once settlement works the
  -- candidate query above finds nothing and the old early RG_ROLLBACK would
  -- report green forever. Re-open the newest settled/closed supplier order
  -- (and its lines) inside this rolled-back transaction instead.
  if v_soid is null then
    select so.id, so.supplier_name,
           coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date)
      into v_soid, v_sname, v_day
      from supplier_orders so
     where exists (select 1 from order_items x join orders o on o.id = x.order_id
                    where x.assigned_supplier = so.supplier_name
                      and (o.created_at at time zone 'Asia/Kolkata')::date =
                          coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date))
     order by so.created_at desc limit 1;
    if v_soid is null then raise exception 'RG_ROLLBACK'; end if;  -- no supplier orders at all
    update supplier_orders
       set status = 'pending', settled_at = null, settled_by = null,
           settled_reason = null, settle_mode = null
     where id = v_soid;
    update order_items x set fulfillment_state = 'pending'
      from orders o
     where o.id = x.order_id and x.assigned_supplier = v_sname
       and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
       and coalesce(x.fulfillment_state, '') = 'shipped';
    update orders o set closed_at = null, close_mode = null, closed_by = null,
                        closed_reason = null, status = 'accepted'
     where o.closed_at is not null
       and exists (select 1 from order_items x where x.order_id = o.id
                     and x.assigned_supplier = v_sname
                     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day);
    select count(*) into v_reopened from order_items x join orders o on o.id = x.order_id
     where x.assigned_supplier = v_sname
       and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
       and coalesce(x.fulfillment_state, '') not in ('cancelled', 'unfillable', 'shipped');
    if coalesce(v_reopened, 0) = 0 then
      raise exception 'RG_FAIL: settlement fixture re-open produced no live lines'; end if;
  end if;

  insert into supplier_count_mode(assigned_supplier) values (v_sname) on conflict do nothing;

  update order_items x set fulfillment_state='received', received_locked=true
    from orders o
   where o.id = x.order_id and x.assigned_supplier = v_sname
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
     and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable');

  update supplier_disputes set status='resolved', resolved_at=now()
   where coalesce(status,'') not in ('resolved','cancelled')
     and order_item_id in (select x.id from order_items x join orders o on o.id=x.order_id
                            where x.assigned_supplier=v_sname
                              and (o.created_at at time zone 'Asia/Kolkata')::date = v_day);

  v_amt := 1234.00;
  insert into pending_bills(file_path,file_name,supplier_name,status,imported_at,received_at,scan_result,scan_status)
  values ('rg/sup.pdf','rgsup.pdf', v_sname, 'imported', now(),
          -- CHANGE #468: the panel's STRICT DATE MATCH is the supplier order's
          -- CREATED date (IST), not its order_date. The fixture used v_day
          -- (order_date when present), so the moment a rebuild re-stamped
          -- created_at the bill stopped attaching and this test went red on a
          -- fixture bug rather than a defect.
          (((select (created_at at time zone 'Asia/Kolkata')::date
               from supplier_orders where id = v_soid)::text || ' 12:00')::timestamp
             at time zone 'Asia/Kolkata'),
          jsonb_build_object('total', v_amt::text), 'done');

  v_panel := public.sup_order_bill_panel(v_soid);
  if coalesce((v_panel->>'any_bill_imported')::boolean,false) is not true then
    raise exception 'RG_FAIL: fixture bill not attached: %', v_panel; end if;

  v_ss := public._supplier_settle_state(v_soid);
  if (v_ss->>'can_close')::boolean then raise exception 'RG_FAIL: settleable while the bill is unpaid: %', v_ss; end if;

  insert into supplier_payments(supplier_order_id, supplier_name, amount, mode, kind, created_by)
  values (v_soid, v_sname,
          coalesce((v_panel->>'bills_amount_total')::numeric,0) + coalesce((v_panel->>'adjustments_total')::numeric,0)
            - coalesce((v_panel->>'total_paid')::numeric,0),
          'online','balance','rg');

  v_ss := public._supplier_settle_state(v_soid);
  if (v_ss->>'closed')::boolean is not true then
    raise exception 'RG_FAIL: received+undisputed+paid supplier order did NOT settle: %', v_ss; end if;
  if (select status from supplier_orders where id=v_soid) <> 'closed' then
    raise exception 'RG_FAIL: settled supplier order status is %', (select status from supplier_orders where id=v_soid); end if;
  if (select settled_at from supplier_orders where id=v_soid) is null then
    raise exception 'RG_FAIL: settled_at not stamped'; end if;
  if exists (select 1 from order_items x join orders o on o.id=x.order_id
              where x.assigned_supplier=v_sname
                and (o.created_at at time zone 'Asia/Kolkata')::date=v_day
                and coalesce(x.fulfillment_state,'') not in ('shipped','cancelled')) then
    raise exception 'RG_FAIL: settled supplier lines still sit in the bill-matching scope'; end if;
  if not exists (select 1 from order_closure_log where supplier_order_id=v_soid and event='settled') then
    raise exception 'RG_FAIL: settlement not logged'; end if;
  if not exists (select 1 from pending_bills where settled_order_id = v_soid and settled_at is not null) then
    raise exception 'RG_FAIL: the supplier bill itself was not stamped settled'; end if;
  if not exists (select 1 from pending_bills where settled_order_id = v_soid
                   and (imported_at is not null or lower(coalesce(status,''))='imported')) then
    raise exception 'RG_FAIL: settling un-imported the bill'; end if;

  raise exception 'RG_ROLLBACK';
end $rg$;$ocs$
 where name = 'order_closure_supplier';

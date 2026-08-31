-- CHANGE #396 part 1 — CUSTOMER 360.
--
-- One pharmacy, whole, in ONE payload. Nothing is stitched in Dart: identity,
-- zone, lifetime and monthly value, the discount slab actually applied, every
-- order with its own money, payments and outstanding, disputes and returns,
-- the margin we earned from them (straight off the #319 P&L view), delivery
-- success and the WhatsApp thread all arrive already worded and formatted.

create table if not exists public.order_status_label (
  status text primary key,
  label  text not null,
  tone   text not null default 'neutral',
  sort_order int not null default 100
);
alter table public.order_status_label enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='order_status_label' and policyname='osl_read') then
    create policy osl_read on public.order_status_label for select using (true);
  end if;
end $$;
insert into public.order_status_label (status,label,tone,sort_order) values
  ('pending','Pending','warning',10),
  ('accepted','Accepted','info',20),
  ('packed','Packed','info',30),
  ('shipped','Out for delivery','info',40),
  ('delivered','Delivered','success',50),
  ('completed','Completed','success',60),
  ('cancelled','Cancelled','danger',70),
  ('closed','Closed','neutral',80)
on conflict (status) do nothing;

create table if not exists public.c360_label (
  key text primary key,
  label text not null
);
alter table public.c360_label enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='c360_label' and policyname='c360_label_read') then
    create policy c360_label_read on public.c360_label for select using (true);
  end if;
end $$;
insert into public.c360_label (key,label) values
  ('title','Customer 360'),
  ('sec_identity','Identity'), ('sec_money','Money'), ('sec_orders','Orders'),
  ('sec_payments','Payments and outstanding'), ('sec_disputes','Disputes and returns'),
  ('sec_margin','What we earn from them'), ('sec_delivery','Delivery performance'),
  ('sec_whatsapp','WhatsApp conversation'), ('sec_slab','Discount slab'),
  ('tile_lifetime','Lifetime order value'), ('tile_orders','Orders'),
  ('tile_month','This month'), ('tile_outstanding','Outstanding'),
  ('lbl_paid','Paid'), ('lbl_billed','Billed'), ('lbl_zone','Zone'),
  ('lbl_code','Customer code'), ('lbl_gstin','GSTIN'), ('lbl_dl','Drug licence'),
  ('lbl_term','Payment term'), ('lbl_credit','Credit limit'), ('lbl_prepaid','Prepaid only'),
  ('lbl_contribution','Contribution'), ('lbl_gross_margin','Gross margin'),
  ('lbl_revenue','Revenue'), ('lbl_delivered','Delivered'), ('lbl_attempted','Attempts'),
  ('lbl_failed','Failed'), ('lbl_success','Success rate'),
  ('empty_orders','No orders yet.'), ('empty_payments','No payments recorded.'),
  ('empty_disputes','No disputes or returns.'),
  ('empty_whatsapp','No WhatsApp messages from this number.'),
  ('empty_margin','No verified supplier bill yet, so margin cannot be computed.'),
  ('empty_delivery','No delivery attempted yet.'),
  ('not_found','No such customer.'), ('admins_only','Admins only.'),
  ('slab_none','No slab captured yet.'),
  ('slab_basis','From the most recent bill'),
  ('slab_expected','Expected at their average order size'),
  ('sec_months','Month by month'),
  ('lbl_owner','Owner'), ('lbl_phone','Phone'), ('lbl_whatsapp','WhatsApp'),
  ('lbl_city','City'), ('lbl_address','Address'),
  ('lbl_first_order','First order'), ('lbl_last_order','Last order'),
  ('lbl_outstanding','Outstanding'), ('lbl_orders_col','Orders'),
  ('lbl_retry','Retry')
on conflict (key) do nothing;

create or replace function public._c360(p_key text)
returns text language sql stable as $q$
  select coalesce((select label from public.c360_label where key = p_key), p_key);
$q$;
create or replace function public._c360_money(p_v numeric)
returns text language sql immutable as $q$
  select '₹' || trim(to_char(round(coalesce(p_v,0), 2), 'FM99999999990.00'));
$q$;

create or replace function public.customer_360(p_customer_id uuid, p_wa_limit integer default 40)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_p record; v_zone text; v_credit record;
  v_o jsonb; v_ids uuid[];
  v_orders jsonb; v_months jsonb; v_pay jsonb; v_disp jsonb; v_wa jsonb;
  v_tot record; v_marg record; v_del record; v_slab jsonb; v_ladder jsonb;
  v_phones text[]; v_walim int := least(greatest(coalesce(p_wa_limit,40),1),200);
  v_slab_pct numeric; v_slab_basis text;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'message', public._c360('admins_only'));
  end if;

  select * into v_p from pharmacy_profiles where id = p_customer_id;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'message', public._c360('not_found'));
  end if;
  select name into v_zone from zones where id = v_p.zone_id;
  select * into v_credit from customer_credit where customer_id = p_customer_id;

  v_phones := array_remove(array[
      public.identity_norm(v_p.phone), public.identity_norm(v_p.whatsapp_no),
      public.identity_norm(v_p.other_contact_no), public.identity_norm(v_p.last_payment_wa_no)], null);

  -- every order this pharmacy placed, each already carrying its own money
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'order_code', coalesce(o.order_code,''),
           'created_at', o.created_at, 'status', coalesce(o.status,''),
           'items', (select count(*)::int from order_items oi where oi.order_id = o.id),
           'value', coalesce((select sum(coalesce(oi.line_total, oi.quantity*oi.price))
                                from order_items oi
                               where oi.order_id = o.id
                                 and coalesce(oi.unfulfillable,false) = false),0),
           'paid',  coalesce((select sum(pc.amount) from payment_claims pc
                               where pc.order_id = o.id
                                 and coalesce(pc.status,'') not in ('rejected','duplicate','need_details')),0)
         )), '[]'::jsonb), coalesce(array_agg(o.id), '{}'::uuid[])
    into v_o, v_ids
    from orders o
   where o.customer_id = p_customer_id
      or (o.customer_id is null and v_p.user_id is not null and o.user_id = v_p.user_id);

  select count(*)::int as orders,
         coalesce(sum(x.value),0) as lifetime,
         coalesce(sum(x.paid),0)  as paid,
         coalesce(sum(x.value) filter (
           where date_trunc('month', x.created_at at time zone 'Asia/Kolkata')
               = date_trunc('month', now() at time zone 'Asia/Kolkata')),0) as month_value,
         min(x.created_at) as first_at, max(x.created_at) as last_at
    into v_tot
    from jsonb_to_recordset(v_o) as x(order_id uuid, order_code text, created_at timestamptz,
                                      status text, items int, value numeric, paid numeric);

  select jsonb_agg(y order by ord desc) into v_orders from (
    select x.created_at as ord, jsonb_build_object(
      'order_id', x.order_id,
      'order_code', x.order_code,
      'date_label', to_char(x.created_at at time zone 'Asia/Kolkata','DD Mon YYYY'),
      'status_key', x.status,
      'status_label', coalesce(sl.label, initcap(x.status)),
      'status_tone',  coalesce(sl.tone,'neutral'),
      'items', x.items,
      'items_label', x.items || case when x.items = 1 then ' item' else ' items' end,
      'value_display', public._c360_money(x.value),
      'paid_display',  public._c360_money(x.paid),
      'outstanding_display', public._c360_money(greatest(x.value - x.paid,0)),
      'is_settled', (x.value - x.paid) <= 0.009) as y
      from jsonb_to_recordset(v_o) as x(order_id uuid, order_code text, created_at timestamptz,
                                        status text, items int, value numeric, paid numeric)
      left join order_status_label sl on sl.status = x.status
  ) s;

  select jsonb_agg(y order by ord) into v_months from (
    select m.mon as ord, jsonb_build_object(
             'month', to_char(m.mon,'YYYY-MM'),
             'label', to_char(m.mon,'Mon YYYY'),
             'orders', m.n,
             'value', m.v,
             'value_display', public._c360_money(m.v)) as y
      from (
        select date_trunc('month', x.created_at at time zone 'Asia/Kolkata') as mon,
               count(*)::int as n, sum(x.value) as v
          from jsonb_to_recordset(v_o) as x(order_id uuid, order_code text, created_at timestamptz,
                                            status text, items int, value numeric, paid numeric)
         where x.created_at >= (now() - interval '12 months')
         group by 1
      ) m
  ) s;

  select jsonb_agg(y order by ord desc) into v_pay from (
    select pc.received_at as ord, jsonb_build_object(
      'claim_id', pc.id,
      'date_label', to_char(coalesce(pc.paid_ts, pc.received_at) at time zone 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM'),
      'amount_display', public._c360_money(pc.amount),
      'status_key', coalesce(pc.status,''),
      'status_label', initcap(replace(coalesce(pc.status,''),'_',' ')),
      'status_tone', case when coalesce(pc.status,'') in ('rejected','duplicate','need_details') then 'danger'
                          when coalesce(pc.status,'') in ('verified','matched','linked') then 'success'
                          else 'warning' end,
      'utr', coalesce(pc.utr,''),
      'method', coalesce(pc.payment_method, pc.app, ''),
      'order_code', coalesce((select o2.order_code from orders o2 where o2.id = pc.order_id),'')) as y
      from payment_claims pc
     where pc.order_id = any (v_ids)
        or (cardinality(v_phones) > 0 and pc.sender_phone is not null
            and public.identity_norm(pc.sender_phone) = any (v_phones))
     order by pc.received_at desc
     limit 100
  ) s;

  select jsonb_agg(y order by ord desc) into v_disp from (
    select d.created_at as ord, jsonb_build_object(
      'kind','dispute',
      'ref', coalesce(d.dispute_code,''),
      'date_label', to_char(d.created_at at time zone 'Asia/Kolkata','DD Mon YYYY'),
      'product_name', coalesce(d.product_name,''),
      'supplier', coalesce(d.assigned_supplier,''),
      'detail', coalesce(d.kind,'') || ' · ordered ' || coalesce(d.ordered_qty,0)::text
                || ', received ' || coalesce(d.received_qty,0)::text,
      'status_label', initcap(replace(coalesce(d.status,''),'_',' ')),
      'status_tone', case when coalesce(d.status,'') in ('resolved','closed') then 'success' else 'warning' end,
      'order_code', coalesce(o.order_code,'')) as y
      from supplier_disputes d
      join order_items oi on oi.id = d.order_item_id
      join orders o on o.id = oi.order_id
     where o.id = any (v_ids)
    union all
    select coalesce(dl.rto_at, dl.created_at) as ord, jsonb_build_object(
      'kind','return',
      'ref', '',
      'date_label', to_char(coalesce(dl.rto_at, dl.created_at) at time zone 'Asia/Kolkata','DD Mon YYYY'),
      'product_name', '',
      'supplier', '',
      'detail', 'returned ' || coalesce(dl.returned_qty,0)::text
                || coalesce(' · ' || nullif(dl.fail_reason,''), ''),
      'status_label', initcap(replace(coalesce(dl.status,''),'_',' ')),
      'status_tone', 'danger',
      'order_code', coalesce(o.order_code,'')) as y
      from deliveries dl join orders o on o.id = dl.order_id
     where dl.order_id = any (v_ids)
       and (coalesce(dl.returned_qty,0) > 0 or dl.rto_at is not null)
  ) s;

  -- margin comes off the #319 P&L view; it is never recomputed here
  select coalesce(sum(v.revenue),0) revenue, coalesce(sum(v.gross_margin),0) gm,
         coalesce(sum(v.contribution),0) contrib, count(*)::int n
    into v_marg from pnl_order_v v where v.order_id = any (v_ids);

  select count(*)::int attempts,
         count(*) filter (where dl.status = 'delivered')::int delivered,
         count(*) filter (where dl.status in ('failed','rto') or dl.fail_reason is not null)::int failed
    into v_del from deliveries dl where dl.order_id = any (v_ids);

  select o.bill_discount_pct into v_slab_pct
    from orders o where o.id = any (v_ids) and o.bill_discount_pct is not null
   order by o.created_at desc limit 1;
  if v_slab_pct is not null then
    v_slab_basis := public._c360('slab_basis');
  else
    select ds.discount_pct into v_slab_pct from discount_slabs ds
     where ds.active and ds.min_amount <= coalesce(v_tot.lifetime / nullif(v_tot.orders,0), 0)
     order by ds.min_amount desc limit 1;
    v_slab_basis := public._c360('slab_expected');
  end if;

  select jsonb_agg(jsonb_build_object(
           'label', trim(to_char(ds.discount_pct,'FM990.##')) || '%',
           'from_display', public._c360_money(ds.min_amount),
           'active', ds.discount_pct = v_slab_pct) order by ds.min_amount)
    into v_ladder from discount_slabs ds where ds.active;

  v_slab := jsonb_build_object(
    'has', v_slab_pct is not null,
    'pct_display', case when v_slab_pct is null then public._c360('slab_none')
                        else trim(to_char(v_slab_pct,'FM990.##')) || '%' end,
    'basis_label', coalesce(v_slab_basis,''),
    'ladder', coalesce(v_ladder,'[]'::jsonb));

  select jsonb_agg(y order by ord desc) into v_wa from (
    select m.received_at as ord, jsonb_build_object(
      'at_label', to_char(m.received_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
      'direction', coalesce(m.direction,'in'),
      'is_out', lower(coalesce(m.direction,'in')) = 'out',
      'kind', coalesce(m.msg_type,'text'),
      'body', coalesce(nullif(btrim(m.text_body),''), nullif(btrim(m.caption),''),
                       upper(coalesce(m.msg_type,'message'))),
      'status', coalesce(m.wa_status,'')) as y
      from whatsapp_messages m
     where cardinality(v_phones) > 0
       and public.identity_norm(m.sender_phone) = any (v_phones)
     order by m.received_at desc
     limit v_walim
  ) s;

  return jsonb_build_object(
    'ok', true,
    'customer_id', p_customer_id,
    'title', public._c360('title'),
    'header', jsonb_build_object(
      'name', coalesce(nullif(btrim(v_p.pharmacy_name),''), v_p.customer_name, 'Customer'),
      'owner', coalesce(v_p.owner_name, v_p.customer_name, ''),
      'code', coalesce(v_p.customer_code,''),
      'phone', coalesce(v_p.phone,''),
      'whatsapp', coalesce(v_p.whatsapp_no,''),
      'city', coalesce(v_p.city,''),
      'district', coalesce(v_p.district,''),
      'address', coalesce(nullif(btrim(v_p.address),''), v_p.address_local, ''),
      'zone_label', coalesce(v_zone,''),
      'gstin', coalesce(nullif(v_p.gstin,''), v_p.gst_no, ''),
      'drug_license', coalesce(nullif(v_p.drug_license,''), v_p.dl_20b, ''),
      'payment_term', coalesce(v_p.payment_term,''),
      'status_label', case when coalesce(v_p.approved,false) then 'Approved' else 'Pending approval' end,
      'status_tone',  case when coalesce(v_p.approved,false) then 'success' else 'warning' end,
      'first_order_label', case when v_tot.first_at is null then ''
                                else to_char(v_tot.first_at at time zone 'Asia/Kolkata','DD Mon YYYY') end,
      'last_order_label',  case when v_tot.last_at is null then ''
                                else to_char(v_tot.last_at at time zone 'Asia/Kolkata','DD Mon YYYY') end,
      'fields', (select coalesce(jsonb_agg(f.x order by f.n),'[]'::jsonb) from (
          select 1 n, jsonb_build_object('label', public._c360('lbl_owner'),
                 'value', coalesce(v_p.owner_name, v_p.customer_name, '')) x
          union all select 2, jsonb_build_object('label', public._c360('lbl_phone'),
                 'value', coalesce(v_p.phone,''))
          union all select 3, jsonb_build_object('label', public._c360('lbl_whatsapp'),
                 'value', coalesce(v_p.whatsapp_no,''))
          union all select 4, jsonb_build_object('label', public._c360('lbl_zone'),
                 'value', coalesce(v_zone,''))
          union all select 5, jsonb_build_object('label', public._c360('lbl_city'),
                 'value', coalesce(v_p.city,''))
          union all select 6, jsonb_build_object('label', public._c360('lbl_address'),
                 'value', coalesce(nullif(btrim(v_p.address),''), v_p.address_local, ''))
          union all select 7, jsonb_build_object('label', public._c360('lbl_code'),
                 'value', coalesce(v_p.customer_code,''))
          union all select 8, jsonb_build_object('label', public._c360('lbl_gstin'),
                 'value', coalesce(nullif(v_p.gstin,''), v_p.gst_no, ''))
          union all select 9, jsonb_build_object('label', public._c360('lbl_dl'),
                 'value', coalesce(nullif(v_p.drug_license,''), v_p.dl_20b, ''))
          union all select 10, jsonb_build_object('label', public._c360('lbl_term'),
                 'value', coalesce(v_p.payment_term,''))
          union all select 11, jsonb_build_object('label', public._c360('lbl_first_order'),
                 'value', case when v_tot.first_at is null then ''
                               else to_char(v_tot.first_at at time zone 'Asia/Kolkata','DD Mon YYYY') end)
          union all select 12, jsonb_build_object('label', public._c360('lbl_last_order'),
                 'value', case when v_tot.last_at is null then ''
                               else to_char(v_tot.last_at at time zone 'Asia/Kolkata','DD Mon YYYY') end)
        ) f where f.x->>'value' <> '')),
    'credit', jsonb_build_object(
      'has', v_credit.customer_id is not null,
      'limit_label', public._c360('lbl_credit'),
      'prepaid_label', public._c360('lbl_prepaid'),
      'limit_display', public._c360_money(coalesce(v_credit.credit_limit,0)),
      'prepaid_only', coalesce(v_credit.prepaid_only,false),
      'note', coalesce(v_credit.note,'')),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','lifetime','label',public._c360('tile_lifetime'),
        'value', public._c360_money(v_tot.lifetime),'tone','info'),
      jsonb_build_object('key','orders','label',public._c360('tile_orders'),
        'value', v_tot.orders::text,'tone','neutral'),
      jsonb_build_object('key','month','label',public._c360('tile_month'),
        'value', public._c360_money(v_tot.month_value),'tone','neutral'),
      jsonb_build_object('key','outstanding','label',public._c360('tile_outstanding'),
        'value', public._c360_money(greatest(v_tot.lifetime - v_tot.paid,0)),
        'tone', case when (v_tot.lifetime - v_tot.paid) > 0.009 then 'danger' else 'success' end)),
    'slab', v_slab,
    'months_label', public._c360('sec_months'),
    'orders_column_label', public._c360('lbl_orders_col'),
    'retry_label', public._c360('lbl_retry'),
    'months', coalesce(v_months,'[]'::jsonb),
    'orders', jsonb_build_object('label', public._c360('sec_orders'),
       'empty', public._c360('empty_orders'), 'rows', coalesce(v_orders,'[]'::jsonb)),
    'payments', jsonb_build_object('label', public._c360('sec_payments'),
       'empty', public._c360('empty_payments'),
       'billed_label', public._c360('lbl_billed'),
       'note', public._c360('note_outstanding'),
       'billed_display', public._c360_money(v_tot.lifetime),
       'paid_label', public._c360('lbl_paid'),
       'outstanding_label', public._c360('lbl_outstanding'),
       'paid_display', public._c360_money(v_tot.paid),
       'outstanding_display', public._c360_money(greatest(v_tot.lifetime - v_tot.paid,0)),
       'rows', coalesce(v_pay,'[]'::jsonb)),
    'disputes', jsonb_build_object('label', public._c360('sec_disputes'),
       'empty', public._c360('empty_disputes'),
       'count', coalesce(jsonb_array_length(v_disp),0),
       'rows', coalesce(v_disp,'[]'::jsonb)),
    'margin', jsonb_build_object('label', public._c360('sec_margin'),
       'has', coalesce(v_marg.n,0) > 0,
       'empty', public._c360('empty_margin'),
       'revenue_label', public._c360('lbl_revenue'),
       'gross_margin_label', public._c360('lbl_gross_margin'),
       'contribution_label', public._c360('lbl_contribution'),
       'revenue_display', public._c360_money(v_marg.revenue),
       'gross_margin_display', public._c360_money(v_marg.gm),
       'contribution_display', public._c360_money(v_marg.contrib),
       'pct_display', case when coalesce(v_marg.revenue,0) > 0
                           then trim(to_char(round(v_marg.contrib*100/v_marg.revenue,1),'FM990.0')) || '%'
                           else '' end,
       'orders_costed', coalesce(v_marg.n,0)),
    'delivery', jsonb_build_object('label', public._c360('sec_delivery'),
       'has', coalesce(v_del.attempts,0) > 0,
       'empty', public._c360('empty_delivery'),
       'attempts_label', public._c360('lbl_attempted'),
       'delivered_label', public._c360('lbl_delivered'),
       'failed_label', public._c360('lbl_failed'),
       'attempts', coalesce(v_del.attempts,0),
       'delivered', coalesce(v_del.delivered,0),
       'failed', coalesce(v_del.failed,0),
       'success_display', case when coalesce(v_del.attempts,0) = 0 then ''
                               else trim(to_char(round(v_del.delivered*100.0/v_del.attempts,1),'FM990.0')) || '%' end,
       'success_tone', case when coalesce(v_del.attempts,0) = 0 then 'neutral'
                            when v_del.delivered*100.0/v_del.attempts >= 90 then 'success'
                            when v_del.delivered*100.0/v_del.attempts >= 70 then 'warning'
                            else 'danger' end),
    'whatsapp', jsonb_build_object('label', public._c360('sec_whatsapp'),
       'empty', public._c360('empty_whatsapp'),
       'count', coalesce(jsonb_array_length(v_wa),0),
       'rows', coalesce(v_wa,'[]'::jsonb)),
    'section_labels', jsonb_build_object(
       'identity', public._c360('sec_identity'),
       'money', public._c360('sec_money'),
       'slab', public._c360('sec_slab')));
end $fn$;

grant execute on function public.customer_360(uuid,integer) to authenticated;

-- Honesty about what "outstanding" means here: mediBO bills from PTR ±
-- discount + GST when the customer bill is generated, so until that exists the
-- only truthful figure is order value less verified payments. The label says so.
update public.c360_label set label = 'Order value' where key = 'lbl_billed';
insert into public.c360_label (key,label) values
  ('note_outstanding','Order value less verified payments. The final bill can differ once it is generated.')
on conflict (key) do update set label = excluded.label;

-- c527 · feature_gaps #62 — "The supplier has no payment ledger at all"
--
-- sup_record_payment() opened with `if get_my_role() <> 'super_admin' then
-- raise exception 'forbidden'`, supplier_payments carried no RLS policy, and
-- the only place a payment appeared anywhere was sup_order_bill_panel — one PO
-- at a time, and no supplier screen rendered a statement. A supplier could not
-- see what was owed, what was paid, against which PO, or what was outstanding.
--
-- WRITING a payment stays admin-only (money out of the platform is never a
-- supplier's own write). READING his own statement is now his.

-- ── 1 · his own rows, and only his own ─────────────────────────────────────
alter table public.supplier_payments enable row level security;

drop policy if exists supplier_payments_own_read on public.supplier_payments;
create policy supplier_payments_own_read on public.supplier_payments
  for select to authenticated
  using (
    public.get_my_role() in ('admin','super_admin')
    or lower(btrim(supplier_name)) = lower(btrim(coalesce(
         (select sp.supplier_name from public.current_supplier_profile() sp), '~none~')))
  );

-- ── 2 · the copy ───────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('supplier_pay.title',        '"Payments"'::jsonb),
  ('supplier_pay.subtitle',     '"What we owe you, and what we have paid"'::jsonb),
  ('supplier_pay.empty',        '"No purchase orders yet — your statement appears here once we buy from you."'::jsonb),
  ('supplier_pay.tile_payable', '"Order value"'::jsonb),
  ('supplier_pay.tile_paid',    '"Paid to you"'::jsonb),
  ('supplier_pay.tile_due',     '"Outstanding"'::jsonb),
  ('supplier_pay.tile_advance', '"Advance received"'::jsonb),
  ('supplier_pay.col_order',    '"Order"'::jsonb),
  ('supplier_pay.col_payable',  '"Value"'::jsonb),
  ('supplier_pay.col_paid',     '"Paid"'::jsonb),
  ('supplier_pay.col_due',      '"Due"'::jsonb),
  ('supplier_pay.settled',      '"Settled"'::jsonb),
  ('supplier_pay.due_label',    '"Due"'::jsonb),
  ('supplier_pay.no_payments',  '"No payment recorded yet"'::jsonb),
  ('supplier_pay.payments_n',   '"{n} payment(s)"'::jsonb),
  ('supplier_pay.not_supplier', '"This login is not a supplier account."'::jsonb),
  ('supplier_pay.retry',        '"Try again"'::jsonb),
  ('supplier_pay.feature_label','"Payments"'::jsonb)
on conflict (key) do nothing;

-- ── 3 · the statement ──────────────────────────────────────────────────────
-- Every rupee, every date and every plural is formatted HERE. The screen prints
-- the strings and computes nothing.
create or replace function public.supplier_my_payments(
  p_limit int default 60,
  p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_name text; v_rows jsonb; v_lim int; v_off int;
  v_payable numeric := 0; v_paid numeric := 0; v_adv numeric := 0; v_total int := 0;
begin
  select sp.supplier_name into v_name from current_supplier_profile() sp;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_supplier',
      'message', public.uic('supplier_pay.not_supplier','This login is not a supplier account.'));
  end if;

  v_lim := least(greatest(coalesce(p_limit,60), 1), 200);
  v_off := greatest(coalesce(p_offset,0), 0);

  with po as (
    select so.id, coalesce(so.total_amount,0) as payable
      from supplier_orders so
     where so.supplier_name = v_name
       and coalesce(so.status,'') <> 'cancelled'
  ),
  pay as (
    select p.supplier_order_id,
           coalesce(sum(p.amount),0) as paid,
           coalesce(sum(p.amount) filter (where p.kind = 'advance'),0) as advance
      from supplier_payments p
     where p.supplier_name = v_name
     group by p.supplier_order_id
  )
  select coalesce(sum(po.payable),0), coalesce(sum(pay.paid),0),
         coalesce(sum(pay.advance),0), count(*)
    into v_payable, v_paid, v_adv, v_total
    from po left join pay on pay.supplier_order_id = po.id;

  with po as (
    select so.id, so.order_code, so.order_no, so.created_at, so.order_date,
           so.settled_at, so.accept_state,
           coalesce(so.total_amount,0) as payable
      from supplier_orders so
     where so.supplier_name = v_name
       and coalesce(so.status,'') <> 'cancelled'
  ),
  pay as (
    select p.supplier_order_id,
           coalesce(sum(p.amount),0) as paid,
           count(*) as n,
           jsonb_agg(jsonb_build_object(
             'id', p.id,
             'kind', p.kind,
             'amount_display', public.inr_money(p.amount),
             'mode', p.mode,
             'note', p.note,
             'utr', p.utr,
             'at_label', to_char(p.created_at at time zone 'Asia/Kolkata','DD Mon YYYY')
           ) order by p.created_at desc) as rows
      from supplier_payments p
     where p.supplier_name = v_name
     group by p.supplier_order_id
  ),
  joined as (
    select po.*, coalesce(pay.paid,0) paid, coalesce(pay.n,0) n,
           coalesce(pay.rows,'[]'::jsonb) rows,
           round(greatest(po.payable - coalesce(pay.paid,0), 0),2) as due
      from po left join pay on pay.supplier_order_id = po.id
     order by po.created_at desc
     limit v_lim offset v_off
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id',        j.id,
           'order_code',      j.order_code,
           'order_no',        j.order_no,
           'date_label',      to_char(coalesce(j.order_date, (j.created_at at time zone 'Asia/Kolkata')::date),
                                      'DD Mon YYYY'),
           'payable_display', public.inr_money(j.payable),
           'paid_display',    public.inr_money(j.paid),
           'due_display',     public.inr_money(j.due),
           'due_tone',        case when j.due <= 0 then 'success' else 'warning' end,
           'status_label',    case when j.settled_at is not null or j.due <= 0
                                   then public.uic('supplier_pay.settled','Settled')
                                   else public.uic('supplier_pay.due_label','Due') end,
           'payments_label',  case when j.n = 0
                                   then public.uic('supplier_pay.no_payments','No payment recorded yet')
                                   else public.uicf('supplier_pay.payments_n',
                                          jsonb_build_object('n', j.n::text), '{n} payment(s)') end,
           'payments',        j.rows
         ) order by j.created_at desc), '[]'::jsonb)
    into v_rows
    from joined j;

  return jsonb_build_object(
    'ok', true,
    'supplier_name', v_name,
    'title',    public.uic('supplier_pay.title','Payments'),
    'subtitle', public.uic('supplier_pay.subtitle',''),
    'empty',    public.uic('supplier_pay.empty',''),
    'summary', jsonb_build_array(
      jsonb_build_object('key','payable',
        'label', public.uic('supplier_pay.tile_payable','Order value'),
        'value', public.inr_money(v_payable), 'tone','info'),
      jsonb_build_object('key','paid',
        'label', public.uic('supplier_pay.tile_paid','Paid to you'),
        'value', public.inr_money(v_paid), 'tone','success'),
      jsonb_build_object('key','due',
        'label', public.uic('supplier_pay.tile_due','Outstanding'),
        'value', public.inr_money(round(greatest(v_payable - v_paid, 0),2)),
        'tone', case when v_payable - v_paid <= 0 then 'success' else 'warning' end),
      jsonb_build_object('key','advance',
        'label', public.uic('supplier_pay.tile_advance','Advance received'),
        'value', public.inr_money(v_adv), 'tone','info')),
    'columns', jsonb_build_array(
      public.uic('supplier_pay.col_order','Order'),
      public.uic('supplier_pay.col_payable','Value'),
      public.uic('supplier_pay.col_paid','Paid'),
      public.uic('supplier_pay.col_due','Due')),
    'orders', v_rows,
    'order_count', v_total,
    'has_more', (v_off + v_lim) < v_total);
end $function$;

grant execute on function public.supplier_my_payments(int, int) to authenticated;

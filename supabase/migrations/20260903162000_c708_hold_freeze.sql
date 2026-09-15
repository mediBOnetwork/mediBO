-- CHANGE #708 (3/6) — the freeze: what "on hold" actually stops.
--
-- A badge is not a hold. If the waterfall still advances, the pack queue still
-- lists it, a rider can still be assigned and an invoice is still raised, then
-- "on hold" is decoration. So the freeze is applied at each surface's OWN choke
-- point, and each one asks the same question — order_hold_state — rather than
-- carrying its own idea of parked:
--
--   * the inquiry waterfall     — start_inquiry_for_suppliers + advance_to_next_supplier
--   * the pack queue            — pack_list_orders_core + fw_pack_orders_core
--   * delivery assignment       — delivery_eligibility (every assign path reads it:
--                                 manual, wave and agency all go through
--                                 _delivery_assign_core, which asks it per order)
--   * billing                   — customer_invoice_issue (raising the invoice IS
--                                 the billing act; a proforma read is harmless)
--
-- Bag allocations and supplier orders are deliberately NOT touched: keeping the
-- collected stock exactly where it is is the whole point of a hold, and (5/6)
-- gives the partner a way to release it back on purpose.
-- Idempotent throughout: the patches are applied from the live definition and
-- skipped once the hook is present.

create or replace function public._c708_order_held(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (select 1 from order_hold h
                  where h.order_id = p_order_id and h.status = 'active');
$fn$;

create or replace function public._c708_inquiry_held(p_inquiry_id bigint)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (
    select 1 from order_items oi
      join order_hold h on h.order_id = oi.order_id and h.status = 'active'
     where oi.inquiry_id = p_inquiry_id);
$fn$;

comment on function public._c708_order_held(uuid) is
  'CHANGE #708 — the one question every frozen surface asks.';

revoke all on function public._c708_order_held(uuid) from public, anon, authenticated;
revoke all on function public._c708_inquiry_held(bigint) from public, anon, authenticated;

insert into public.ui_copy (key, value) values
  ('order_hold.block_pack',     to_jsonb('On hold — not for packing'::text)),
  ('order_hold.block_delivery', to_jsonb('On hold — resume it before assigning a rider'::text)),
  ('order_hold.block_invoice',  to_jsonb('This order is on hold. Nothing is billed until it resumes.'::text))
on conflict (key) do nothing;

-- ── 1. the waterfall must not ask, and must not advance ────────────────────
do $do$
declare v_def text; v_new text; v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'start_inquiry_for_suppliers';
  if v_def is not null and v_def not like '%_c708_inquiry_held%' then
    v_hits := (length(v_def) - length(replace(v_def,
      'AND coalesce(inquiry_phase,''draft'') IN (''draft'',''sent'')','')))
      / length('AND coalesce(inquiry_phase,''draft'') IN (''draft'',''sent'')');
    if v_hits <> 2 then
      raise exception 'c708: waterfall anchor found % times, expected 2', v_hits;
    end if;
    v_new := replace(v_def,
      'AND coalesce(inquiry_phase,''draft'') IN (''draft'',''sent'')',
      'AND coalesce(inquiry_phase,''draft'') IN (''draft'',''sent'')'
      || chr(10) || '         AND NOT public._c708_inquiry_held(inquiry.id)');
    execute v_new;
  end if;
end $do$;

do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'advance_to_next_supplier';
  if v_def is not null and v_def not like '%_c708_inquiry_held%' then
    v_new := replace(v_def,
      'SELECT * INTO r FROM inquiry WHERE id = p_id;',
      '-- CHANGE #708: a parked order does not step the cascade. The row keeps'
      || chr(10) || '  -- the supplier it was waiting on, so resume picks up exactly here.'
      || chr(10) || '  IF public._c708_inquiry_held(p_id) THEN RETURN; END IF;'
      || chr(10) || '  SELECT * INTO r FROM inquiry WHERE id = p_id;');
    if v_new = v_def then raise exception 'c708: advance_to_next_supplier anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 2. the pack queue hides it ─────────────────────────────────────────────
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'pack_list_orders_core';
  if v_def is not null and v_def not like '%_c708_order_held%' then
    v_new := replace(v_def,
      'WHERE x.n_items > 0',
      'WHERE x.n_items > 0' || chr(10)
      || '    AND NOT public._c708_order_held(o.id)   -- CHANGE #708');
    if v_new = v_def then raise exception 'c708: pack_list_orders_core anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'fw_pack_orders_core';
  if v_def is not null and v_def not like '%_c708_order_held%' then
    v_new := replace(v_def,
      'FROM orders o
  WHERE o.fulfillment_status NOT IN (''shipped'',''cancelled'')',
      'FROM orders o
  WHERE o.fulfillment_status NOT IN (''shipped'',''cancelled'')
    AND NOT public._c708_order_held(o.id)   -- CHANGE #708');
    if v_new = v_def then raise exception 'c708: fw_pack_orders_core anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 3. no rider on a parked order ─────────────────────────────────────────
-- Reproduced from the live definition with the hold blocker added FIRST, so
-- the reason a dispatcher reads is the hold and not "Bill not sent".
create or replace function public.delivery_eligibility(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  o orders%rowtype; v_bill jsonb; v_ready boolean; v_rem numeric; v_sent boolean;
  v_blockers text[] := '{}';
  v_hold jsonb;
begin
  select * into o from orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('ok',false,'error','order_not_found'); end if;

  -- CHANGE #708 — a held order is not assignable, and it says so first.
  v_hold := public.order_hold_state(p_order_id);
  if coalesce((v_hold->>'held')::boolean,false) then
    v_blockers := v_blockers || public._c('order_hold.block_delivery');
  end if;

  if not coalesce(o.dispatch_ready,false) then
    v_blockers := v_blockers || 'Not fully packed'::text;
  end if;

  begin
    v_bill := public.customer_bill(p_order_id);
  exception when others then
    v_bill := jsonb_build_object('ready', false);
  end;
  v_ready := coalesce((v_bill->>'ready')::boolean, true);
  if v_ready is not true then
    v_blockers := v_blockers || 'Bill not ready'::text;
  end if;

  v_sent := (nullif(btrim(coalesce(o.cust_bill_path,'')),'') is not null);
  if not v_sent then v_blockers := v_blockers || 'Bill not sent'::text; end if;

  v_rem := coalesce((v_bill->'totals'->>'remaining')::numeric, null);
  if v_rem is null then
    if v_ready is true then v_blockers := v_blockers || 'Payment not confirmed'::text; end if;
  elsif v_rem > 0 then
    v_blockers := v_blockers || 'Payment pending'::text;
  end if;

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'can_assign', (array_length(v_blockers,1) is null),
    'packed', coalesce(o.dispatch_ready,false),
    'bill_ready', (v_ready is true),
    'bill_sent', v_sent,
    'remaining', v_rem,
    'remaining_label', coalesce(v_bill->'totals'->>'remaining_label',''),
    'hold', v_hold,
    'blockers', to_jsonb(v_blockers),
    'blocked_label', case when array_length(v_blockers,1) is null then 'Ready to assign'
                          else array_to_string(v_blockers, ' • ') end);
end
$fn$;

-- ── 4. nothing is billed while it is parked ───────────────────────────────
create or replace function public.customer_invoice_issue(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_no text; v_supplied boolean; v_syn boolean;
begin
  select invoice_no, coalesce(is_synthetic,false) into v_no, v_syn
    from orders where id = p_order_id;
  if v_no is not null then
    return jsonb_build_object('ok', true, 'already', true, 'invoice_no', v_no);
  end if;

  -- CHANGE #708 — raising the invoice IS the billing act, so this is where the
  -- hold lands. Reading a proforma stays harmless and stays allowed.
  if public._c708_order_held(p_order_id) then
    return jsonb_build_object('ok', false, 'reason','on_hold',
      'message', public._c('order_hold.block_invoice'),
      'hold', public.order_hold_state(p_order_id));
  end if;

  v_supplied := public._order_is_supplied(p_order_id);
  if not v_supplied then
    return jsonb_build_object('ok', false, 'reason','not_supplied',
      'message', public.uic('bill.proforma_reason',
                            'A tax invoice is raised when the order is dispatched.'));
  end if;

  v_no := public._next_customer_invoice_no(coalesce(v_syn,false));
  update orders set invoice_no = v_no, invoice_issued_at = now()
   where id = p_order_id and invoice_no is null;

  select invoice_no into v_no from orders where id = p_order_id;
  return jsonb_build_object('ok', true, 'already', false, 'invoice_no', v_no);
end
$fn$;

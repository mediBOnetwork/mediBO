-- c527 · feature_gaps #60 — "Availability is all-or-nothing; no partial quantity"
--
-- The answer vocabulary in submit_inquiry_form was (answer, rate, scheme) with
-- no quantity anywhere, so a supplier holding 5 of 10 had to answer Available
-- for all 10. The shortfall only surfaced later at receiving, as a dispute, and
-- _reinquiry_exclude_and_advance then had to rewrite his answer to Out of Stock
-- and restart the whole cascade for the remainder.
--
-- Now: the answer carries offered_qty. The PO takes the offered quantity, and
-- ONLY the unmet remainder cascades — at answer time, not at receiving time.
--
-- The remainder re-uses the SAME inquiry row rather than a clone, because
-- inquiry_broadcast_to_oi matches order_items on (product_id, order_date =
-- batch_date): a clone on the same date would fight the original row over
-- order_items.assigned_supplier. Re-pointing the row is exactly what
-- _reinquiry_exclude_and_advance already does after a short receive.

-- ── 0 · one backend copy formatter (ui_copy + {placeholder} substitution) ───
-- There is uic(key, fallback) for a plain string but nothing for a string with
-- a slot in it, so every caller was inlining its own concatenation in Dart.
create or replace function public.uicf(p_key text, p_params jsonb, p_fallback text default '')
returns text
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v text; k text;
begin
  v := public.uic(p_key, p_fallback);
  if p_params is null or jsonb_typeof(p_params) <> 'object' then return v; end if;
  for k in select jsonb_object_keys(p_params) loop
    v := replace(v, '{'||k||'}', coalesce(p_params->>k, ''));
  end loop;
  return v;
end $function$;

-- ── 1 · what the supplier committed to ──────────────────────────────────────
alter table public.inquiry
  add column if not exists offered_qty numeric;

comment on column public.inquiry.offered_qty is
  'c527 #60 — quantity this supplier committed to when he answered Available. NULL means the whole ask. The PO line takes coalesce(offered_qty, quantity).';

-- ── 2 · the permanent record of every split ─────────────────────────────────
create table if not exists public.inquiry_partial_log (
  id                bigserial primary key,
  inquiry_id        bigint,
  product_id        bigint,
  supplier_name     text,
  batch_date        date,
  asked_qty         numeric,
  offered_qty       numeric,
  remainder_qty     numeric,
  supplier_order_id uuid,
  next_supplier     text,
  reason            text,
  created_at        timestamptz not null default now()
);

create index if not exists inquiry_partial_log_inq_idx
  on public.inquiry_partial_log (inquiry_id, created_at desc);
create index if not exists inquiry_partial_log_sup_idx
  on public.inquiry_partial_log (supplier_name, created_at desc);

alter table public.inquiry_partial_log enable row level security;

-- ── 3 · cascade ONLY the remainder ──────────────────────────────────────────
-- p_kept_qty is what the supplier is actually supplying (already on the PO).
-- Everything above it goes back into the waterfall on the same inquiry row.
create or replace function public._inquiry_cascade_remainder(
  p_inquiry_id bigint,
  p_supplier   text,
  p_kept_qty   numeric,
  p_reason     text default 'partial_availability')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r inquiry%rowtype; i int; ps_val text; slot_n int;
  v_ask numeric; v_rem numeric; v_next text; v_po uuid;
begin
  select * into r from inquiry where id = p_inquiry_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'inquiry_not_found');
  end if;

  v_ask := coalesce(r.quantity, 0);
  v_rem := round(greatest(v_ask - coalesce(p_kept_qty, 0), 0), 3);
  v_po  := r.supplier_order_id;

  if v_rem <= 0 then
    return jsonb_build_object('ok', false, 'error', 'no_remainder',
                              'asked_qty', v_ask, 'kept_qty', p_kept_qty);
  end if;

  -- this supplier has given all he has: his slot is closed for the remainder
  slot_n := null;
  for i in 1..30 loop
    execute format('select ($1).%I', 'PS'||i) into ps_val using r;
    if ps_val is null or btrim(ps_val) = '' then exit; end if;
    if lower(btrim(ps_val)) = lower(btrim(p_supplier)) then
      slot_n := i;
      execute format('update inquiry set %I = %L where id = %s',
                     'AS'||i, 'Out of Stock', p_inquiry_id);
      exit;
    end if;
  end loop;

  -- the row now represents the REMAINDER only; the offered part is on the PO
  update inquiry
     set quantity          = v_rem,
         offered_qty       = null,
         supplier_order_id = null
   where id = p_inquiry_id;

  perform public.advance_to_next_supplier(p_inquiry_id);

  select current_supplier into v_next from inquiry where id = p_inquiry_id;

  insert into public.inquiry_partial_log(
    inquiry_id, product_id, supplier_name, batch_date,
    asked_qty, offered_qty, remainder_qty, supplier_order_id, next_supplier, reason)
  values (p_inquiry_id, r.product_id, p_supplier, r.batch_date,
          v_ask, p_kept_qty, v_rem, v_po, v_next, p_reason);

  return jsonb_build_object('ok', true, 'inquiry_id', p_inquiry_id,
    'asked_qty', v_ask, 'offered_qty', p_kept_qty, 'remainder_qty', v_rem,
    'slot', slot_n, 'next_supplier', v_next, 'supplier_order_id', v_po);
end;
$function$;

-- ── 4 · the PO line takes the OFFERED quantity ──────────────────────────────
create or replace function public._po_merge_inquiry_lines(p_oid uuid, p_ids bigint[])
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_items jsonb; v_add jsonb;
BEGIN
  IF p_oid IS NULL OR p_ids IS NULL OR array_length(p_ids,1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(so.items, '[]'::jsonb) INTO v_items
    FROM supplier_orders so WHERE so.id = p_oid FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Only ADD products the PO does not already list. An existing line is left
  -- exactly as sent — a quantity already quoted to a supplier is not rewritten.
  -- c527 #60: the quantity is what he OFFERED, not what he was asked.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id',   i.product_id,
           'product_name', i.product_name,
           'quantity',     COALESCE(i.offered_qty, i.quantity),
           'asked_qty',    i.quantity,
           'partial',      (i.offered_qty IS NOT NULL AND i.offered_qty < i.quantity),
           'mrp',          i.mrp,
           'pack_type',    NULLIF(btrim(med.pack_type),''))), '[]'::jsonb)
    INTO v_add
    FROM (SELECT DISTINCT ON (q.product_id) q.*
            FROM inquiry q WHERE q.id = ANY(p_ids) AND q.product_id IS NOT NULL
           ORDER BY q.product_id, q.id) i
    LEFT JOIN "MEDICINE" med ON med.id = i.product_id
   WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x
                      WHERE (x->>'product_id') = i.product_id::text);

  IF v_add = '[]'::jsonb THEN
    PERFORM public.po_retotal(p_oid);   -- rates may have arrived since
    RETURN;
  END IF;

  UPDATE supplier_orders so SET items = v_items || v_add WHERE so.id = p_oid;
  -- #29: the total is NEVER sum(mrp*qty) any more. po_retotal() prices each
  -- line from the supplier's quote and marks anything still unquoted.
  PERFORM public.po_retotal(p_oid);
END;
$function$;

-- ── 5 · the answer carries a quantity ───────────────────────────────────────
-- NOTE: the live form of these two functions is the MERGED 3-arg version in
-- 20260901_c527_gap60_merge_c526_secret_gate.sql. Command #526 landed its
-- gap-28 secret gate while this command was building, so the part-quantity
-- capture is applied ON TOP of that gate rather than instead of it.

-- the part-quantity affordance is its own decorator, so get_inquiry_form stays
-- the two-line composer it has always been.
create or replace function public._inquiry_partial_qty_items(p_items jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(
           t.e || jsonb_build_object('partial_qty', jsonb_build_object(
             'enabled',     true,
             'label',       public.uic('inquiry_partial.qty_label','How many can you give?'),
             'hint',        public.uic('inquiry_partial.qty_hint','Leave blank for the full quantity'),
             'asked_label', public.uicf('inquiry_partial.asked_label',
                              jsonb_build_object('asked', coalesce(t.e->>'quantity','')),
                              'Asked: {asked}'),
             'max',         coalesce(nullif(t.e->>'quantity','')::numeric, 0)))
           order by t.ord), p_items)
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality t(e, ord);
$function$;

-- ── 6 · the form offers the quantity box (backend-owned copy) ───────────────
insert into public.ui_copy(key, value) values
  ('inquiry_partial.qty_label',     '"How many can you give?"'::jsonb),
  ('inquiry_partial.qty_hint',      '"Leave blank for the full quantity"'::jsonb),
  ('inquiry_partial.error_invalid', '"Enter how many you can give as a number"'::jsonb),
  ('inquiry_partial.error_range',   '"Enter a quantity between 1 and {asked}"'::jsonb),
  ('inquiry_partial.chip',          '"Part quantity"'::jsonb),
  ('inquiry_partial.asked_label',   '"Asked: {asked}"'::jsonb)
on conflict (key) do nothing;

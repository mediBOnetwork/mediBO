-- c527 · feature_gaps #61 — "No batch, expiry or HSN is captured at quote or PO time"
--
-- supplier_orders.items[] held only product_id, product_name, quantity,
-- pack_type and mrp. Neither the inquiry answer path nor the PO carried a batch
-- number, an expiry or an HSN code — though a pharma purchase bill legally
-- needs all three, and bill_lines already has batch_no / expiry / hsn columns
-- sitting empty waiting for them.
--
-- Captured at PO ACKNOWLEDGEMENT (the supplier knows his batch only once he is
-- picking the stock, not when he is quoting a rate), and carried into
-- bill_lines automatically so the bill no longer has to re-key them.

-- ── 1 · the per-line detail the supplier acknowledges ───────────────────────
create table if not exists public.supplier_order_line_detail (
  id                uuid primary key default gen_random_uuid(),
  supplier_order_id uuid not null,
  product_id        bigint not null,
  batch_no          text,
  expiry            text,
  hsn               text,
  free_qty          numeric,
  accepted_qty      numeric,
  updated_by        text,
  updated_at        timestamptz not null default now(),
  created_at        timestamptz not null default now()
);

create unique index if not exists supplier_order_line_detail_uq
  on public.supplier_order_line_detail (supplier_order_id, product_id);

alter table public.supplier_order_line_detail enable row level security;

-- ── 2 · validation lives here, once, for every caller ──────────────────────
-- Expiry is stored as the supplier typed it, normalised to MM/YYYY. A pharma
-- pack prints MM/YY or MM/YYYY; anything else is refused rather than silently
-- coerced (a stripped '13/25' would otherwise become a real-looking date).
create or replace function public._c527_norm_expiry(p_raw text)
returns text
language plpgsql
immutable
as $function$
declare v text; mm int; yy int;
begin
  v := upper(btrim(coalesce(p_raw,'')));
  if v = '' then return null; end if;
  v := replace(replace(v, '-', '/'), '.', '/');
  if v ~ '^[0-9]{1,2}/[0-9]{2}$' then
    mm := split_part(v,'/',1)::int; yy := 2000 + split_part(v,'/',2)::int;
  elsif v ~ '^[0-9]{1,2}/[0-9]{4}$' then
    mm := split_part(v,'/',1)::int; yy := split_part(v,'/',2)::int;
  elsif v ~ '^[0-9]{4}/[0-9]{1,2}$' then
    yy := split_part(v,'/',1)::int; mm := split_part(v,'/',2)::int;
  else
    return '!';                                   -- caller reports invalid
  end if;
  if mm < 1 or mm > 12 or yy < 2000 or yy > 2099 then return '!'; end if;
  return lpad(mm::text, 2, '0') || '/' || yy::text;
end $function$;

-- ── 3 · the supplier writes his own line details ───────────────────────────
create or replace function public.supplier_set_line_details(
  p_order_code text,
  p_lines      jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_sid uuid; v_name text; v_oid uuid; ln record; v_exp text; v_hsn text;
  v_written int := 0; v_actor text;
begin
  select sp.id, sp.supplier_name into v_sid, v_name from current_supplier_profile() sp;
  if v_sid is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_supplier',
      'message', public.uic('supplier_po.err_not_supplier','This login is not a supplier account.'));
  end if;
  v_actor := coalesce(v_name, 'supplier');

  select so.id into v_oid from supplier_orders so
   where so.supplier_name = v_name
     and (so.order_code = p_order_code or so.id::text = p_order_code)
   limit 1;
  if v_oid is null then
    return jsonb_build_object('ok', false, 'error', 'order_not_found',
      'message', public.uic('supplier_po.err_not_found','That order is not on your account.'));
  end if;

  for ln in select * from jsonb_to_recordset(coalesce(p_lines,'[]'::jsonb))
              as x(product_id bigint, batch_no text, expiry text, hsn text,
                   free_qty numeric, accepted_qty numeric) loop
    if ln.product_id is null then continue; end if;

    v_exp := public._c527_norm_expiry(ln.expiry);
    if v_exp = '!' then
      return jsonb_build_object('ok', false, 'error', 'invalid_expiry',
        'product_id', ln.product_id,
        'message', public.uic('supplier_po.err_expiry','Expiry must be MM/YY or MM/YYYY'));
    end if;

    v_hsn := nullif(regexp_replace(coalesce(ln.hsn,''), '[^0-9]', '', 'g'), '');
    if v_hsn is not null and length(v_hsn) not between 4 and 8 then
      return jsonb_build_object('ok', false, 'error', 'invalid_hsn',
        'product_id', ln.product_id,
        'message', public.uic('supplier_po.err_hsn','HSN must be 4 to 8 digits'));
    end if;

    insert into public.supplier_order_line_detail(
      supplier_order_id, product_id, batch_no, expiry, hsn, free_qty, accepted_qty, updated_by)
    values (v_oid, ln.product_id, nullif(btrim(coalesce(ln.batch_no,'')),''), v_exp, v_hsn,
            ln.free_qty, ln.accepted_qty, v_actor)
    on conflict (supplier_order_id, product_id) do update set
      batch_no     = coalesce(excluded.batch_no,     supplier_order_line_detail.batch_no),
      expiry       = coalesce(excluded.expiry,       supplier_order_line_detail.expiry),
      hsn          = coalesce(excluded.hsn,          supplier_order_line_detail.hsn),
      free_qty     = coalesce(excluded.free_qty,     supplier_order_line_detail.free_qty),
      accepted_qty = coalesce(excluded.accepted_qty, supplier_order_line_detail.accepted_qty),
      updated_by   = excluded.updated_by,
      updated_at   = now();

    v_written := v_written + 1;
  end loop;

  -- anything already billed for this PO picks the details up immediately
  perform public.po_details_to_bill_lines(v_oid);

  return jsonb_build_object('ok', true, 'supplier_order_id', v_oid,
    'lines_written', v_written,
    'message', public.uicf('supplier_po.details_saved',
                 jsonb_build_object('n', v_written::text),
                 'Saved batch and expiry for {n} item(s)'));
end $function$;

grant execute on function public.supplier_set_line_details(text, jsonb) to authenticated;

-- ── 4 · carry into bill_lines ──────────────────────────────────────────────
create or replace function public.po_details_to_bill_lines(p_supplier_order_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int;
begin
  if p_supplier_order_id is null then return 0; end if;
  update bill_lines bl
     set batch_no = coalesce(bl.batch_no, d.batch_no),
         expiry   = coalesce(bl.expiry,   d.expiry),
         hsn      = coalesce(bl.hsn,      d.hsn)
    from public.supplier_order_line_detail d
   where d.supplier_order_id = p_supplier_order_id
     and bl.supplier_order_id = d.supplier_order_id
     and bl.product_id = d.product_id
     and (bl.batch_no is null or bl.expiry is null or bl.hsn is null);
  get diagnostics v_n = row_count;
  return coalesce(v_n, 0);
end $function$;

-- a bill line that arrives later fills itself from the acknowledged PO detail
create or replace function public._c527_bill_line_fill_from_po()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.supplier_order_line_detail%rowtype;
begin
  if NEW.supplier_order_id is null or NEW.product_id is null then return NEW; end if;
  if NEW.batch_no is not null and NEW.expiry is not null and NEW.hsn is not null then
    return NEW;
  end if;
  select * into d from public.supplier_order_line_detail
   where supplier_order_id = NEW.supplier_order_id and product_id = NEW.product_id;
  if not found then return NEW; end if;
  NEW.batch_no := coalesce(NEW.batch_no, d.batch_no);
  NEW.expiry   := coalesce(NEW.expiry,   d.expiry);
  NEW.hsn      := coalesce(NEW.hsn,      d.hsn);
  return NEW;
end $function$;

drop trigger if exists trg_c527_bill_line_fill_from_po on public.bill_lines;
create trigger trg_c527_bill_line_fill_from_po
  before insert on public.bill_lines
  for each row execute function public._c527_bill_line_fill_from_po();

-- ── 5 · the copy the supplier screen prints ────────────────────────────────
insert into public.ui_copy(key, value) values
  ('supplier_po.details_title',   '"Batch & expiry"'::jsonb),
  ('supplier_po.details_hint',    '"Required on the purchase bill"'::jsonb),
  ('supplier_po.batch_label',     '"Batch no."'::jsonb),
  ('supplier_po.expiry_label',    '"Expiry (MM/YY)"'::jsonb),
  ('supplier_po.hsn_label',       '"HSN"'::jsonb),
  ('supplier_po.details_saved',   '"Saved batch and expiry for {n} item(s)"'::jsonb),
  ('supplier_po.details_missing', '"Batch and expiry not filled"'::jsonb),
  ('supplier_po.details_done',    '"Batch and expiry filled"'::jsonb),
  ('supplier_po.err_expiry',      '"Expiry must be MM/YY or MM/YYYY"'::jsonb),
  ('supplier_po.err_hsn',         '"HSN must be 4 to 8 digits"'::jsonb),
  ('supplier_po.err_not_supplier','"This login is not a supplier account."'::jsonb),
  ('supplier_po.err_not_found',   '"That order is not on your account."'::jsonb),
  ('supplier_po.save_details',    '"Save batch & expiry"'::jsonb)
on conflict (key) do nothing;

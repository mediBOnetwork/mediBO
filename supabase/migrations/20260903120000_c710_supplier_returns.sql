-- CHANGE #710 — Return-to-supplier flow with an automatic debit note.
--
-- Verified before building: supplier_debits_list() only LISTS (it reads
-- order_returns + supplier_disputes through _c403_debit_rows). There was no way
-- to send physical stock back to a supplier, and no debit note anywhere in the
-- system. Disputes settle a COUNT difference at the shop; this settles goods
-- that physically travel back.
--
-- Money is never computed in Dart and never from MRP: every line is valued from
-- the supplier's own verified bill line (pnl_line_v -> ptr, gst_pct) through the
-- existing _return_line_money(), so a debit note can only debit what the
-- supplier actually billed.
--
-- Idempotent by construction (#233): every object is create-if-not-exists /
-- create-or-replace / on-conflict.

-- ── 1. Schema ───────────────────────────────────────────────────────────────

create table if not exists public.supplier_return (
  id                uuid primary key default gen_random_uuid(),
  zone_id           smallint,
  supplier_id       uuid,
  supplier_name     text        not null default '',
  supplier_order_id uuid,
  status            text        not null default 'drafted',
  debit_no          text,
  fy                text,
  ack_token         text unique,
  item_count        integer     not null default 0,
  qty_total         numeric     not null default 0,
  taxable_total     numeric     not null default 0,
  gst_total         numeric     not null default 0,
  grand_total       numeric     not null default 0,
  applied_amount    numeric     not null default 0,
  carried_amount    numeric     not null default 0,
  note              text        not null default '',
  doc_id            uuid,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  sent_at           timestamptz,
  sent_by           uuid,
  acknowledged_at   timestamptz,
  acknowledged_note text        not null default '',
  credited_at       timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text        not null default '',
  is_synthetic      boolean     not null default false,
  test_session_id   bigint
);

create table if not exists public.supplier_return_item (
  id              uuid primary key default gen_random_uuid(),
  return_id       uuid not null references public.supplier_return(id) on delete cascade,
  order_item_id   uuid,
  order_id        uuid,
  product_id      bigint,
  product_name    text    not null default '',
  batch_no        text    not null default '',
  expiry          text    not null default '',
  pending_bill_id uuid,
  reason_code     text    not null default '',
  qty             numeric not null default 0,
  rate            numeric not null default 0,
  gst_percent     numeric not null default 0,
  taxable         numeric not null default 0,
  gst_amount      numeric not null default 0,
  line_total      numeric not null default 0,
  photo_bucket    text    not null default '',
  photo_path      text    not null default '',
  note            text    not null default '',
  bag_released    boolean not null default false,
  reinquiry_fired boolean not null default false,
  created_at      timestamptz not null default now()
);

-- One number series per ZONE per financial year, exactly like the customer
-- invoice series (_next_customer_invoice_no) but keyed by zone as well: two
-- partners must never share a debit-note counter.
create table if not exists public.supplier_return_series (
  zone_id    smallint not null,
  fy         text     not null,
  prefix     text     not null default 'DN',
  next_no    integer  not null default 1,
  updated_at timestamptz not null default now(),
  primary key (zone_id, fy)
);

-- The supplier-level credit ledger. kind:
--   'applied'   — the part of a debit note booked against its own supplier bill
--   'carry'     — the part that could not be booked (bill already paid)
--   'carry_use' — carry consumed by a later supplier order (negative amount)
create table if not exists public.supplier_return_credit_ledger (
  id                uuid primary key default gen_random_uuid(),
  supplier_id       uuid,
  supplier_name     text not null default '',
  return_id         uuid references public.supplier_return(id) on delete cascade,
  supplier_order_id uuid,
  kind              text not null,
  amount            numeric not null default 0,
  note              text not null default '',
  created_by        uuid,
  created_at        timestamptz not null default now()
);

create index if not exists supplier_return_supplier_idx
  on public.supplier_return (supplier_name, status);
create index if not exists supplier_return_so_idx
  on public.supplier_return (supplier_order_id);
create index if not exists supplier_return_zone_idx
  on public.supplier_return (zone_id, created_at desc);
create index if not exists supplier_return_item_return_idx
  on public.supplier_return_item (return_id);
create index if not exists supplier_return_item_oi_idx
  on public.supplier_return_item (order_item_id);
create index if not exists supplier_return_ledger_sup_idx
  on public.supplier_return_credit_ledger (supplier_id, kind);
create index if not exists supplier_return_ledger_so_idx
  on public.supplier_return_credit_ledger (supplier_order_id);

alter table public.supplier_return                enable row level security;
alter table public.supplier_return_item           enable row level security;
alter table public.supplier_return_series         enable row level security;
alter table public.supplier_return_credit_ledger  enable row level security;

-- No policies on purpose: every read and write goes through the SECURITY
-- DEFINER RPCs below, which check partner / supplier / admin identity
-- themselves. RLS on with no policy = the tables are unreachable directly.

-- ── 2. Reasons (data, not Dart) ─────────────────────────────────────────────

insert into public.order_reason_option (scope, code, label, sort, active, requires_photo, tone, customer_visible)
values
  ('supplier_return','wrong_item',        'Wrong item sent',        10, true,  true,  'danger',  false),
  ('supplier_return','damaged_on_receipt','Damaged on receipt',     20, true,  true,  'danger',  false),
  ('supplier_return','short_pack',        'Short pack / part pack', 30, true,  false, 'warning', false),
  ('supplier_return','near_expiry',       'Near expiry',            40, true,  true,  'warning', false),
  ('supplier_return','not_ordered',       'Not ordered',            50, true,  false, 'info',    false)
on conflict (scope, code) do nothing;

-- ── 3. Copy (every string the screens print lives here, not in Dart) ────────

insert into public.ui_copy (key, value) values
  ('sup_return.title',            '"Returns to supplier"'::jsonb),
  ('sup_return.subtitle',         '"Stock sent back, and the debit note it raised"'::jsonb),
  ('sup_return.empty',            '"No returns raised yet."'::jsonb),
  ('sup_return.new_label',        '"New return"'::jsonb),
  ('sup_return.pick_order_label', '"Pick the supplier collection"'::jsonb),
  ('sup_return.pick_order_empty', '"No supplier collection in this zone yet."'::jsonb),
  ('sup_return.editor_title',     '"Return to {supplier}"'::jsonb),
  ('sup_return.candidates_label', '"What came in"'::jsonb),
  ('sup_return.candidates_empty', '"Nothing on this collection can be returned."'::jsonb),
  ('sup_return.items_label',      '"Going back"'::jsonb),
  ('sup_return.items_empty',      '"Add a line to raise a debit note."'::jsonb),
  ('sup_return.reason_label',     '"Reason"'::jsonb),
  ('sup_return.qty_label',        '"Qty"'::jsonb),
  ('sup_return.qty_value',        '"{qty}"'::jsonb),
  ('sup_return.max_qty_label',    '"Up to {qty}"'::jsonb),
  ('sup_return.note_label',       '"Note"'::jsonb),
  ('sup_return.photo_label',      '"Photo"'::jsonb),
  ('sup_return.photo_required',   '"A photo is required for this reason."'::jsonb),
  ('sup_return.add_label',        '"Add line"'::jsonb),
  ('sup_return.remove_label',     '"Remove"'::jsonb),
  ('sup_return.send_label',       '"Send & raise debit note"'::jsonb),
  ('sup_return.cancel_label',     '"Cancel return"'::jsonb),
  ('sup_return.col_product',      '"Product"'::jsonb),
  ('sup_return.col_batch',        '"Batch"'::jsonb),
  ('sup_return.col_qty',          '"Qty"'::jsonb),
  ('sup_return.col_reason',       '"Reason"'::jsonb),
  ('sup_return.col_rate',         '"Rate"'::jsonb),
  ('sup_return.col_gst',          '"GST"'::jsonb),
  ('sup_return.col_amount',       '"Amount"'::jsonb),
  ('sup_return.taxable_label',    '"Taxable"'::jsonb),
  ('sup_return.gst_total_label',  '"GST"'::jsonb),
  ('sup_return.total_label',      '"Debit note total"'::jsonb),
  ('sup_return.count_label',      '"Lines"'::jsonb),
  ('sup_return.debit_no_label',   '"Debit note"'::jsonb),
  ('sup_return.rate_pending',     '"Rate pending — bill not imported"'::jsonb),
  ('sup_return.status_drafted',      '"Draft"'::jsonb),
  ('sup_return.status_sent',         '"Sent"'::jsonb),
  ('sup_return.status_acknowledged', '"Acknowledged"'::jsonb),
  ('sup_return.status_credited',     '"Credited"'::jsonb),
  ('sup_return.status_cancelled',    '"Cancelled"'::jsonb),
  ('sup_return.sent_toast',       '"Debit note {no} raised and sent to {supplier}."'::jsonb),
  ('sup_return.ack_toast',        '"Acknowledged. The bill has been adjusted."'::jsonb),
  ('sup_return.cancel_toast',     '"Return cancelled."'::jsonb),
  ('sup_return.doc_label',        '"Debit note PDF"'::jsonb),
  ('sup_return.doc_building',     '"Preparing the debit note…"'::jsonb),
  ('sup_return.doc_ready',        '"Debit note ready."'::jsonb),
  ('sup_return.doc_failed',       '"The debit note could not be prepared. Try again."'::jsonb),
  ('sup_return.err_not_authorized','"You do not have access to returns."'::jsonb),
  ('sup_return.err_not_found',    '"That return no longer exists."'::jsonb),
  ('sup_return.err_already_sent', '"This return has already been sent."'::jsonb),
  ('sup_return.err_nothing',      '"Add at least one line before sending."'::jsonb),
  ('sup_return.err_qty',          '"Only {qty} of that line can be returned."'::jsonb),
  ('sup_return.err_reason',       '"Pick a reason for the return."'::jsonb),
  ('sup_return.err_no_order',     '"That supplier collection no longer exists."'::jsonb),
  ('sup_return.tab_returns',      '"Returns"'::jsonb),
  ('sup_return.sup_title',        '"Returns raised on you"'::jsonb),
  ('sup_return.sup_subtitle',     '"Stock sent back by mediBO, and the debit note against your bill"'::jsonb),
  ('sup_return.sup_empty',        '"No returns raised on you."'::jsonb),
  ('sup_return.ack_label',        '"Acknowledge"'::jsonb),
  ('sup_return.ack_done_label',   '"Acknowledged on {at}"'::jsonb),
  ('sup_return.effect_label',     '"Reduces your bill by {amount}"'::jsonb),
  ('sup_return.carry_label',      '"Carried to your next bill"'::jsonb),
  ('sup_return.page_title',       '"Debit note {no}"'::jsonb),
  ('sup_return.page_eyebrow',     '"mediBO · Return to supplier"'::jsonb),
  ('sup_return.page_intro',       '"These goods have been sent back. Please acknowledge the debit note."'::jsonb),
  ('sup_return.page_note_hint',   '"Add a note (optional)"'::jsonb),
  ('sup_return.page_done_title',  '"Thank you — acknowledgement received"'::jsonb),
  ('sup_return.page_done_note',   '"Your bill has been adjusted by this debit note."'::jsonb),
  ('sup_return.page_already',     '"You have already acknowledged this debit note."'::jsonb),
  ('sup_return.page_invalid_title','"This link is no longer valid"'::jsonb),
  ('sup_return.page_invalid_note','"Please contact mediBO for assistance."'::jsonb),
  ('sup_return.page_submitting',  '"Submitting…"'::jsonb),
  ('sup_return.page_error',       '"Submission failed. Please try again."'::jsonb),
  ('sup_return.doc_title',        '"Debit note {no}"'::jsonb),
  ('sup_return.doc_lines_heading','"Goods returned"'::jsonb),
  ('sup_return.doc_lbl_supplier', '"Supplier"'::jsonb),
  ('sup_return.doc_lbl_debit_no', '"Debit note no."'::jsonb),
  ('sup_return.doc_lbl_date',     '"Date"'::jsonb),
  ('sup_return.doc_lbl_against',  '"Against collection"'::jsonb),
  ('sup_return.doc_lbl_status',   '"Status"'::jsonb),
  ('sup_return.doc_empty',        '"No lines on this debit note."'::jsonb),
  ('sup_return.doc_note',         '"Goods debited at the rate billed by the supplier. GST reversed on the same rate. This debit note reduces the amount payable against the supplier bill it names."'::jsonb),
  ('sup_return.bill_debit_label', '"Debit notes"'::jsonb),
  ('sup_return.bill_carry_label', '"Credit carried"'::jsonb),
  ('sup_return.bill_debit_note',  '"Debit notes reduce this bill by {amount}."'::jsonb),
  ('sup_return.credit_available', '"Credit available"'::jsonb),
  ('sup_return.credit_apply',     '"Apply credit"'::jsonb),
  ('sup_return.credit_applied',   '"{amount} credit applied to this bill."'::jsonb),
  ('sup_return.credit_none',      '"No credit available for this supplier."'::jsonb),
  ('sup_return.spn_title',        '"Returns raised on you"'::jsonb),
  ('sup_return.spn_count_label',  '"Debit notes"'::jsonb),
  ('sup_return.spn_value_label',  '"Debited"'::jsonb),
  ('sup_return.spn_none',         '"No returns in this window"'::jsonb)
on conflict (key) do nothing;

-- ── 4. Where it lives — nav + tabs are DATA ─────────────────────────────────

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   search_terms, description)
values
  ('partner.supplier_returns', 'Returns to supplier', 'Sourcing', 'inventory',
   'supplier_returns', 35, 'partner', true, 'write', true, 'orders', 'dashboard',
   array['admin','super_admin']::text[],
   'return debit note supplier damaged near expiry wrong short',
   'CHANGE #710 — send wrong, damaged, short or near-expiry stock back to a supplier and raise the debit note that reduces their bill.')
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      group_label = excluded.group_label, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true,
      partner_eligible = true, category = excluded.category,
      surface = excluded.surface, description = excluded.description;

insert into public.access_role_default (role, feature_key, can_view, can_write) values
  ('super_admin','partner.supplier_returns', true,  true),
  ('admin',      'partner.supplier_returns', true,  true),
  ('partner',    'partner.supplier_returns', true,  true)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write;

insert into public.supplier_record_tab (tab_key, copy_key, icon_key, sort_order, is_active)
values ('returns', 'sup_return.tab_returns', 'assignment_return', 25, true)
on conflict (tab_key) do update
  set copy_key = excluded.copy_key, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true;

-- ── 5. Helpers ──────────────────────────────────────────────────────────────

-- Who may work returns. Platform staff always; a partner through the same
-- access_effective() ladder every other partner feature uses.
create or replace function public._c710_access()
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
begin
  if public.role_for_medibo_only() in ('admin','super_admin') then return 'write'; end if;
  if public.my_partner_id() is null then return 'none'; end if;
  return public.partner_access('partner.supplier_returns');
end $fn$;

create or replace function public._c710_denied()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object('ok', false, 'error', 'not_authorized',
           'message', public.uic('sup_return.err_not_authorized',
                                 'You do not have access to returns.'))
$fn$;

create or replace function public._c710_err(p_error text, p_key text, p_fallback text, p_vars jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v text := public.uic(p_key, p_fallback); k text;
begin
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    v := replace(v, '{'||k||'}', coalesce(p_vars->>k,''));
  end loop;
  return jsonb_build_object('ok', false, 'error', p_error, 'message', v);
end $fn$;

create or replace function public._c710_fmt(p_key text, p_fallback text, p_vars jsonb default '{}'::jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare v text := public.uic(p_key, p_fallback); k text;
begin
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    v := replace(v, '{'||k||'}', coalesce(p_vars->>k,''));
  end loop;
  return v;
end $fn$;

-- One number series per zone per financial year. Same shape as
-- _next_customer_invoice_no, keyed by zone as well so two partners never share
-- a counter: DN/Z2/2026-27/0007.
create or replace function public._c710_next_debit_no(p_zone smallint, p_synthetic boolean default false)
returns text language plpgsql security definer set search_path to 'public' as $fn$
declare v_fy text := public._fy_ist(); v_prefix text := 'DN'; v_no int; v_zone smallint := coalesce(p_zone, 0);
begin
  if p_synthetic then v_fy := 'TEST-' || v_fy; v_prefix := 'TEST'; end if;
  insert into public.supplier_return_series (zone_id, fy, prefix, next_no)
  values (v_zone, v_fy, v_prefix, 1)
  on conflict (zone_id, fy) do nothing;
  update public.supplier_return_series
     set next_no = next_no + 1, updated_at = now()
   where zone_id = v_zone and fy = v_fy
  returning next_no - 1 into v_no;
  return v_prefix || '/Z' || v_zone::text || '/' || v_fy || '/' || to_char(v_no, 'FM0000');
end $fn$;

-- What is still returnable on one order line. The base is what the supplier
-- BILLED (verified allocations) when a bill has been imported, and what was
-- physically received when it has not — a return must be possible before the
-- bill arrives. Prior returns on the same line are deducted either way.
create or replace function public._c710_returnable_qty(p_order_item_id uuid)
returns numeric language sql stable security definer set search_path to 'public' as $fn$
  select greatest(
    coalesce(
      nullif((select sum(a.qty) from public.bill_line_allocations a
                join public.bill_lines b on b.id = a.bill_line_id
               where a.order_item_id = p_order_item_id and b.verified), 0),
      (select coalesce(oi.received_qty, 0) from public.order_items oi where oi.id = p_order_item_id))
  - coalesce((select sum(i.qty) from public.supplier_return_item i
                join public.supplier_return r on r.id = i.return_id
               where i.order_item_id = p_order_item_id
                 and r.status in ('drafted','sent','acknowledged','credited')), 0), 0)
$fn$;

-- The money on one returned line, always from the SUPPLIER's own rate.
-- _return_line_money() slices the verified bill allocations at PTR + GST; when
-- no bill has been imported yet the rate is genuinely unknown and the line
-- carries zero with has_rate:false, so a debit note can never invent a number.
create or replace function public._c710_line_money(p_order_item_id uuid, p_qty numeric)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare m jsonb; v_bill uuid; v_rate numeric; v_gst numeric; v_tax numeric; v_g numeric;
begin
  m := public._return_line_money(p_order_item_id, p_qty);
  select b.pending_bill_id into v_bill
    from public.bill_line_allocations a
    join public.bill_lines b on b.id = a.bill_line_id
   where a.order_item_id = p_order_item_id and b.verified
   order by a.created_at desc limit 1;

  if coalesce((m->>'qty_matched')::numeric, 0) > 0 then
    v_rate := coalesce((m->>'ptr')::numeric, 0);
    v_gst  := coalesce((m->>'gst_pct')::numeric, 0);
    v_tax  := coalesce((m->>'taxable')::numeric, 0);
    v_g    := coalesce((m->>'gst')::numeric, 0);
    return jsonb_build_object(
      'has_rate', true, 'rate', round(v_rate, 4), 'gst_pct', v_gst,
      'taxable', round(v_tax, 2), 'gst', round(v_g, 2),
      'total', round(v_tax + v_g, 2), 'pending_bill_id', v_bill);
  end if;

  return jsonb_build_object(
    'has_rate', false, 'rate', 0, 'gst_pct',
    coalesce((select oi.gst_percent from public.order_items oi where oi.id = p_order_item_id), 0),
    'taxable', 0, 'gst', 0, 'total', 0, 'pending_bill_id', v_bill);
end $fn$;

create or replace function public._c710_status_label(p_status text)
returns text language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(nullif(public.uic('sup_return.status_' || coalesce(p_status,''), ''), ''),
                  coalesce(p_status, ''))
$fn$;

create or replace function public._c710_status_tone(p_status text)
returns text language sql immutable as $fn$
  select case coalesce(p_status,'')
           when 'drafted'      then 'info'
           when 'sent'         then 'warning'
           when 'acknowledged' then 'info'
           when 'credited'     then 'success'
           when 'cancelled'    then 'danger'
           else 'info' end
$fn$;

-- Re-total the header from its own lines. Called after every line write, so
-- the header is never a stale copy of the items.
create or replace function public._c710_retotal(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.supplier_return r
     set item_count    = coalesce(t.n, 0),
         qty_total     = coalesce(t.q, 0),
         taxable_total = round(coalesce(t.tx, 0), 2),
         gst_total     = round(coalesce(t.g, 0), 2),
         grand_total   = round(coalesce(t.tx, 0) + coalesce(t.g, 0), 2)
    from (select count(*)::int n, coalesce(sum(qty),0) q,
                 coalesce(sum(taxable),0) tx, coalesce(sum(gst_amount),0) g
            from public.supplier_return_item where return_id = p_id) t
   where r.id = p_id;
end $fn$;

-- One return, as a list row. Every string is finished here.
create or replace function public._c710_row(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype;
begin
  select * into r from public.supplier_return where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', r.id,
    'supplier_name', r.supplier_name,
    'supplier_order_id', r.supplier_order_id,
    'order_label', coalesce((select so.order_code from public.supplier_orders so
                              where so.id = r.supplier_order_id), ''),
    'status', r.status,
    'status_label', public._c710_status_label(r.status),
    'status_tone', public._c710_status_tone(r.status),
    'debit_no', coalesce(r.debit_no, ''),
    'debit_no_label', public.uic('sup_return.debit_no_label','Debit note'),
    'has_debit_no', (coalesce(r.debit_no,'') <> ''),
    'count_label', public.uic('sup_return.count_label','Lines'),
    'count_value', r.item_count::text,
    'qty_label', public.uic('sup_return.qty_label','Qty'),
    'qty_value', trim_scale(r.qty_total)::text,
    'taxable_label', public.uic('sup_return.taxable_label','Taxable'),
    'taxable_value', public.inr_money(r.taxable_total),
    'gst_label', public.uic('sup_return.gst_total_label','GST'),
    'gst_value', public.inr_money(r.gst_total),
    'total_label', public.uic('sup_return.total_label','Debit note total'),
    'total_value', public.inr_money(r.grand_total),
    'effect_label', public._c710_fmt('sup_return.effect_label','Reduces your bill by {amount}',
                      jsonb_build_object('amount', public.inr_money(r.grand_total))),
    'at_label', public.ist_fmt(coalesce(r.sent_at, r.created_at), 'dmy_hm'),
    'acknowledged', (r.acknowledged_at is not null),
    -- The DONE sentence. The button's own label is 'ack_label', added by the
    -- surface that offers the button, so the two never collide in one object.
    'ack_done_label', case when r.acknowledged_at is null then ''
                      else public._c710_fmt('sup_return.ack_done_label','Acknowledged on {at}',
                             jsonb_build_object('at', public.ist_fmt(r.acknowledged_at,'dmy_hm'))) end,
    'ack_note', r.acknowledged_note,
    'carried', (r.carried_amount > 0),
    'carry_label', case when r.carried_amount > 0
                        then public.uic('sup_return.carry_label','Carried to your next bill') else '' end,
    'carry_value', case when r.carried_amount > 0 then public.inr_money(r.carried_amount) else '' end,
    'note', r.note,
    'can_edit',  (r.status = 'drafted'),
    'can_send',  (r.status = 'drafted' and r.item_count > 0),
    'can_cancel',(r.status in ('drafted','sent')),
    'can_doc',   (coalesce(r.debit_no,'') <> ''));
end $fn$;

create unique index if not exists supplier_return_item_uniq
  on public.supplier_return_item (return_id, order_item_id);

-- ── 6. The partner surface ──────────────────────────────────────────────────

-- The candidate lines on one supplier collection: what physically came in from
-- that supplier on that day, and how much of it can still go back.
create or replace function public._c710_candidates(p_supplier_order_id uuid, p_return_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare so public.supplier_orders%rowtype; v_day date; v_rows jsonb;
begin
  select * into so from public.supplier_orders where id = p_supplier_order_id;
  if not found then return '[]'::jsonb; end if;
  v_day := coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date);

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_rows
  from (
    select row_number() over (order by oi.product_name, oi.id) ord,
           jsonb_build_object(
             'order_item_id', oi.id,
             'order_id', oi.order_id,
             'product_id', oi.product_id,
             'product_name', coalesce(oi.product_name,''),
             'batch_no', coalesce(oi.batch_no,''),
             'expiry', coalesce(oi.expiry,''),
             'order_label', coalesce(o.order_code,''),
             'received_label', public._c710_fmt('sup_return.qty_value','{qty}',
                                 jsonb_build_object('qty', trim_scale(coalesce(oi.received_qty,0))::text)),
             'max_qty', public._c710_returnable_qty(oi.id)
                        + coalesce((select i.qty from public.supplier_return_item i
                                     where i.return_id = p_return_id and i.order_item_id = oi.id), 0),
             'max_qty_label', public._c710_fmt('sup_return.max_qty_label','Up to {qty}',
                                jsonb_build_object('qty', trim_scale(
                                  public._c710_returnable_qty(oi.id)
                                  + coalesce((select i.qty from public.supplier_return_item i
                                               where i.return_id = p_return_id and i.order_item_id = oi.id), 0))::text)),
             'money', public._c710_line_money(oi.id, 1),
             'rate_label', case when coalesce((public._c710_line_money(oi.id, 1)->>'has_rate')::boolean, false)
                                then public.inr_money((public._c710_line_money(oi.id, 1)->>'rate')::numeric)
                                else public.uic('sup_return.rate_pending','Rate pending — bill not imported') end,
             'in_return', exists (select 1 from public.supplier_return_item i
                                   where i.return_id = p_return_id and i.order_item_id = oi.id)) x
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where oi.assigned_supplier = so.supplier_name
       and coalesce(oi.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) = v_day
       and coalesce(oi.fulfillment_state,'') not in ('cancelled')
       and coalesce(oi.unfulfillable, false) = false
       and (coalesce(oi.received_qty,0) > 0
            or exists (select 1 from public.bill_line_allocations a where a.order_item_id = oi.id))
       and (public._c710_returnable_qty(oi.id) > 0
            or exists (select 1 from public.supplier_return_item i
                        where i.return_id = p_return_id and i.order_item_id = oi.id))
  ) s;
  return v_rows;
end $fn$;

create or replace function public._c710_reasons()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', o.code, 'label', o.label, 'tone', coalesce(o.tone,'info'),
           'requires_photo', coalesce(o.requires_photo,false)) order by o.sort, o.code), '[]'::jsonb)
    from public.order_reason_option o
   where o.scope = 'supplier_return' and coalesce(o.active,true)
$fn$;

create or replace function public.partner_return_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
        v_items jsonb; v_zone smallint;
begin
  if v_acc = 'none' then return public._c710_denied(); end if;
  select * into r from public.supplier_return where id = p_id;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  v_zone := public.partner_zone_id();
  if v_zone is not null and r.zone_id is distinct from v_zone
     and public.role_for_medibo_only() not in ('admin','super_admin') then
    return public._c710_denied();
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id,
           'order_item_id', i.order_item_id,
           'product_name', i.product_name,
           'batch_no', i.batch_no,
           'expiry', i.expiry,
           'reason_code', i.reason_code,
           'reason_label', coalesce((select o.label from public.order_reason_option o
                                      where o.scope='supplier_return' and o.code = i.reason_code), i.reason_code),
           'qty', i.qty,
           'qty_value', trim_scale(i.qty)::text,
           'rate_value', case when i.rate > 0 then public.inr_money(i.rate)
                              else public.uic('sup_return.rate_pending','Rate pending — bill not imported') end,
           'gst_value', trim_scale(i.gst_percent)::text || '%',
           'amount_value', public.inr_money(i.line_total),
           'note', i.note,
           'has_photo', (coalesce(i.photo_path,'') <> ''),
           'photo_bucket', i.photo_bucket,
           'photo_path', i.photo_path) order by i.created_at, i.id), '[]'::jsonb)
    into v_items from public.supplier_return_item i where i.return_id = r.id;

  return jsonb_build_object(
    'ok', true,
    'access', v_acc,
    'can_write', (v_acc = 'write'),
    'title', public._c710_fmt('sup_return.editor_title','Return to {supplier}',
               jsonb_build_object('supplier', r.supplier_name)),
    'row', public._c710_row(r.id),
    'candidates_label', public.uic('sup_return.candidates_label','What came in'),
    'candidates_empty', public.uic('sup_return.candidates_empty','Nothing on this collection can be returned.'),
    'candidates', public._c710_candidates(r.supplier_order_id, r.id),
    'items_label', public.uic('sup_return.items_label','Going back'),
    'items_empty', public.uic('sup_return.items_empty','Add a line to raise a debit note.'),
    'items', v_items,
    'reason_label', public.uic('sup_return.reason_label','Reason'),
    'reasons', public._c710_reasons(),
    'qty_label', public.uic('sup_return.qty_label','Qty'),
    'note_label', public.uic('sup_return.note_label','Note'),
    'photo_label', public.uic('sup_return.photo_label','Photo'),
    'photo_bucket', 'dispute-proofs',
    'add_label', public.uic('sup_return.add_label','Add line'),
    'remove_label', public.uic('sup_return.remove_label','Remove'),
    'send_label', public.uic('sup_return.send_label','Send & raise debit note'),
    'cancel_label', public.uic('sup_return.cancel_label','Cancel return'),
    'doc_label', public.uic('sup_return.doc_label','Debit note PDF'),
    'columns', jsonb_build_array(
      jsonb_build_object('key','product','label', public.uic('sup_return.col_product','Product'),'align','left'),
      jsonb_build_object('key','qty','label', public.uic('sup_return.col_qty','Qty'),'align','right'),
      jsonb_build_object('key','rate','label', public.uic('sup_return.col_rate','Rate'),'align','right'),
      jsonb_build_object('key','gst','label', public.uic('sup_return.col_gst','GST'),'align','right'),
      jsonb_build_object('key','amount','label', public.uic('sup_return.col_amount','Amount'),'align','right')));
end $fn$;

create or replace function public.partner_returns_console(p_limit integer default 40)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); v_zone smallint := public.partner_zone_id();
        v_rows jsonb; v_orders jsonb;
begin
  if v_acc = 'none' then return public._c710_denied(); end if;

  select coalesce(jsonb_agg(public._c710_row(s.id) order by s.created_at desc), '[]'::jsonb)
    into v_rows
    from (select r.id, r.created_at from public.supplier_return r
           where (v_zone is null or r.zone_id is not distinct from v_zone)
           order by r.created_at desc
           limit greatest(coalesce(p_limit,40),1)) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier_order_id', so.id,
           'supplier_name', coalesce(so.supplier_name,''),
           'order_label', coalesce(nullif(so.order_code,''), nullif(so.order_no::text,''), ''),
           'date_label', public.ist_fmt(so.created_at, 'day_mon_time12')) order by so.created_at desc), '[]'::jsonb)
    into v_orders
    from public.supplier_orders so
   where (v_zone is null or so.zone_id is not distinct from v_zone)
     and so.created_at >= now() - interval '45 days'
   limit 60;

  return jsonb_build_object(
    'ok', true,
    'access', v_acc,
    'can_write', (v_acc = 'write'),
    'zone_id', v_zone,
    'title', public.uic('sup_return.title','Returns to supplier'),
    'subtitle', public.uic('sup_return.subtitle','Stock sent back, and the debit note it raised'),
    'empty_text', public.uic('sup_return.empty','No returns raised yet.'),
    'new_label', public.uic('sup_return.new_label','New return'),
    'pick_order_label', public.uic('sup_return.pick_order_label','Pick the supplier collection'),
    'pick_order_empty', public.uic('sup_return.pick_order_empty','No supplier collection in this zone yet.'),
    'orders', v_orders,
    'rows', v_rows);
end $fn$;

create or replace function public.partner_return_start(p_supplier_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); v_zone smallint := public.partner_zone_id();
        so public.supplier_orders%rowtype; v_id uuid; v_sid uuid;
begin
  if v_acc <> 'write' then return public._c710_denied(); end if;
  select * into so from public.supplier_orders where id = p_supplier_order_id;
  if not found then
    return public._c710_err('no_order','sup_return.err_no_order','That supplier collection no longer exists.');
  end if;
  if v_zone is not null and so.zone_id is distinct from v_zone
     and public.role_for_medibo_only() not in ('admin','super_admin') then
    return public._c710_denied();
  end if;

  select id into v_id from public.supplier_return
   where supplier_order_id = so.id and status = 'drafted' limit 1;

  if v_id is null then
    v_sid := coalesce(so.supplier_id,
              (select sp.id from public.supplier_profiles sp
                where lower(sp.supplier_name) = lower(so.supplier_name) limit 1));
    insert into public.supplier_return
      (zone_id, supplier_id, supplier_name, supplier_order_id, status, created_by, is_synthetic)
    values (coalesce(so.zone_id, v_zone), v_sid, coalesce(so.supplier_name,''), so.id, 'drafted',
            auth.uid(), coalesce(so.is_synthetic,false))
    returning id into v_id;
  end if;

  perform public.partner_audit('partner.supplier_returns','start',
    jsonb_build_object('supplier_order_id', so.id, 'return_id', v_id));
  return public.partner_return_get(v_id);
end $fn$;

create or replace function public.partner_return_line_set(
  p_id uuid, p_order_item_id uuid, p_qty numeric,
  p_reason_code text default null, p_note text default null,
  p_photo_bucket text default null, p_photo_path text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
        oi public.order_items%rowtype; v_max numeric; v_have numeric := 0; m jsonb;
        v_reason text := nullif(btrim(coalesce(p_reason_code,'')),'');
begin
  if v_acc <> 'write' then return public._c710_denied(); end if;
  select * into r from public.supplier_return where id = p_id for update;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  if r.status <> 'drafted' then
    return public._c710_err('already_sent','sup_return.err_already_sent','This return has already been sent.');
  end if;

  select coalesce(qty,0) into v_have from public.supplier_return_item
   where return_id = r.id and order_item_id = p_order_item_id;
  v_have := coalesce(v_have, 0);

  if coalesce(p_qty,0) <= 0 then
    delete from public.supplier_return_item
     where return_id = r.id and order_item_id = p_order_item_id;
    perform public._c710_retotal(r.id);
    return public.partner_return_get(r.id);
  end if;

  if v_reason is null then
    return public._c710_err('bad_reason','sup_return.err_reason','Pick a reason for the return.');
  end if;
  if not exists (select 1 from public.order_reason_option o
                  where o.scope='supplier_return' and o.code = v_reason and coalesce(o.active,true)) then
    return public._c710_err('bad_reason','sup_return.err_reason','Pick a reason for the return.');
  end if;

  select * into oi from public.order_items where id = p_order_item_id;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;

  v_max := public._c710_returnable_qty(p_order_item_id) + v_have;
  if p_qty > v_max then
    return public._c710_err('qty_too_high','sup_return.err_qty','Only {qty} of that line can be returned.',
             jsonb_build_object('qty', trim_scale(v_max)::text));
  end if;

  m := public._c710_line_money(p_order_item_id, p_qty);

  insert into public.supplier_return_item
    (return_id, order_item_id, order_id, product_id, product_name, batch_no, expiry,
     pending_bill_id, reason_code, qty, rate, gst_percent, taxable, gst_amount, line_total,
     photo_bucket, photo_path, note)
  values (r.id, p_order_item_id, oi.order_id, oi.product_id, coalesce(oi.product_name,''),
          coalesce(oi.batch_no,''), coalesce(oi.expiry,''),
          nullif(m->>'pending_bill_id','')::uuid, v_reason, p_qty,
          coalesce((m->>'rate')::numeric,0), coalesce((m->>'gst_pct')::numeric,0),
          coalesce((m->>'taxable')::numeric,0), coalesce((m->>'gst')::numeric,0),
          coalesce((m->>'total')::numeric,0),
          coalesce(nullif(btrim(coalesce(p_photo_bucket,'')),''),''),
          coalesce(nullif(btrim(coalesce(p_photo_path,'')),''),''),
          coalesce(btrim(coalesce(p_note,'')),''))
  on conflict (return_id, order_item_id) do update
    set reason_code = excluded.reason_code, qty = excluded.qty, rate = excluded.rate,
        gst_percent = excluded.gst_percent, taxable = excluded.taxable,
        gst_amount = excluded.gst_amount, line_total = excluded.line_total,
        pending_bill_id = excluded.pending_bill_id,
        photo_bucket = case when excluded.photo_bucket <> '' then excluded.photo_bucket
                            else public.supplier_return_item.photo_bucket end,
        photo_path  = case when excluded.photo_path <> '' then excluded.photo_path
                           else public.supplier_return_item.photo_path end,
        note = excluded.note;

  perform public._c710_retotal(r.id);
  return public.partner_return_get(r.id);
end $fn$;

create or replace function public.partner_return_cancel(p_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
begin
  if v_acc <> 'write' then return public._c710_denied(); end if;
  select * into r from public.supplier_return where id = p_id for update;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  if r.status not in ('drafted','sent') then
    return public._c710_err('already_sent','sup_return.err_already_sent','This return has already been sent.');
  end if;
  update public.supplier_return
     set status = 'cancelled', cancelled_at = now(),
         cancel_reason = coalesce(btrim(coalesce(p_reason,'')),'')
   where id = r.id;
  perform public.partner_audit('partner.supplier_returns','cancel',
    jsonb_build_object('return_id', r.id));
  return public.partner_return_get(r.id)
         || jsonb_build_object('toast', public.uic('sup_return.cancel_toast','Return cancelled.'));
end $fn$;

-- ── 7. The debit note document ──────────────────────────────────────────────
-- Same contract as _c403_doc_payload: {ok, stamp, file_name, doc{...}}, drawn
-- by the existing bill-render edge function. Nothing new to deploy.

create or replace function public._c710_doc_payload(p_return_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype; v_rows jsonb; v_bills text;
begin
  select * into r from public.supplier_return where id = p_return_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sn', ord::text,
           'product', i.product_name,
           'batch', i.batch_no,
           'expiry', i.expiry,
           'reason', coalesce((select o.label from public.order_reason_option o
                                where o.scope='supplier_return' and o.code = i.reason_code), i.reason_code),
           'qty', trim_scale(i.qty)::text,
           'rate', public.inr_money(i.rate),
           'gst', trim_scale(i.gst_percent)::text || '%',
           'amount', public.inr_money(i.line_total)) order by ord), '[]'::jsonb)
    into v_rows
    from (select row_number() over (order by created_at, id) ord, *
            from public.supplier_return_item where return_id = r.id) i;

  select string_agg(distinct coalesce(nullif(pb.scan_result->>'invoice_no',''), pb.file_name), ', ')
    into v_bills
    from public.supplier_return_item i
    join public.pending_bills pb on pb.id = i.pending_bill_id
   where i.return_id = r.id;

  return jsonb_build_object(
    'ok', true,
    'stamp', md5(coalesce(r.status,'') || coalesce(r.debit_no,'') || r.grand_total::text
                 || r.item_count::text || coalesce(r.acknowledged_at,'epoch'::timestamptz)::text),
    'file_name', 'DN-' || regexp_replace(coalesce(r.debit_no, left(r.id::text,8)), '[^0-9A-Za-z-]','','g') || '.pdf',
    'doc', jsonb_build_object(
      'title', public._c710_fmt('sup_return.doc_title','Debit note {no}',
                 jsonb_build_object('no', coalesce(r.debit_no,''))),
      'subtitle', public.ui_textf('supplier_doc.subtitle',
                    jsonb_build_object('at', public.ist_fmt(now(),'dmy_hm'))),
      'brand', public.ui_text('supplier_doc.brand'),
      'header', jsonb_build_array(
        jsonb_build_object('label', public.uic('sup_return.doc_lbl_supplier','Supplier'), 'value', r.supplier_name),
        jsonb_build_object('label', public.uic('sup_return.doc_lbl_debit_no','Debit note no.'), 'value', coalesce(r.debit_no,'')),
        jsonb_build_object('label', public.uic('sup_return.doc_lbl_date','Date'),
                           'value', public.ist_fmt(coalesce(r.sent_at, r.created_at),'dmy')),
        jsonb_build_object('label', public.uic('sup_return.doc_lbl_against','Against collection'),
                           'value', coalesce((select so.order_code from public.supplier_orders so
                                               where so.id = r.supplier_order_id), '')
                                    || case when coalesce(v_bills,'') <> '' then ' · ' || v_bills else '' end),
        jsonb_build_object('label', public.uic('sup_return.doc_lbl_status','Status'),
                           'value', public._c710_status_label(r.status))),
      'sections', jsonb_build_array(jsonb_build_object(
        'heading', public.uic('sup_return.doc_lines_heading','Goods returned'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','sn','label','#','align','left','width',20),
          jsonb_build_object('key','product','label',public.uic('sup_return.col_product','Product'),'align','left','width',180),
          jsonb_build_object('key','batch','label',public.uic('sup_return.col_batch','Batch'),'align','left','width',58),
          jsonb_build_object('key','reason','label',public.uic('sup_return.col_reason','Reason'),'align','left','width',120),
          jsonb_build_object('key','qty','label',public.uic('sup_return.col_qty','Qty'),'align','right','width',40),
          jsonb_build_object('key','rate','label',public.uic('sup_return.col_rate','Rate'),'align','right','width',66),
          jsonb_build_object('key','gst','label',public.uic('sup_return.col_gst','GST'),'align','right','width',44),
          jsonb_build_object('key','amount','label',public.uic('sup_return.col_amount','Amount'),'align','right','width',76)),
        'rows', v_rows,
        'empty_label', public.uic('sup_return.doc_empty','No lines on this debit note.'))),
      'totals', jsonb_build_array(
        jsonb_build_object('label', public.uic('sup_return.count_label','Lines'), 'value', r.item_count::text),
        jsonb_build_object('label', public.uic('sup_return.taxable_label','Taxable'), 'value', public.inr_money(r.taxable_total)),
        jsonb_build_object('label', public.uic('sup_return.gst_total_label','GST'), 'value', public.inr_money(r.gst_total)),
        jsonb_build_object('label', public.uic('sup_return.total_label','Debit note total'),
                           'value', public.inr_money(r.grand_total), 'bold', true)),
      'notes', jsonb_build_array(public.uic('sup_return.doc_note',
                 'Goods debited at the rate billed by the supplier.')),
      'footer', public.ui_text('supplier_doc.footer')));
end $fn$;

-- Queue the PDF through the SAME chain every other supplier document uses
-- (supplier_document row -> bill-render -> supplier_doc_report).
create or replace function public._c710_doc_enqueue(p_return_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'net' as $fn$
declare r public.supplier_return%rowtype; pay jsonb; v_id uuid;
begin
  select * into r from public.supplier_return where id = p_return_id;
  if not found or r.supplier_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_supplier');
  end if;
  pay := public._c710_doc_payload(p_return_id);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  insert into public.supplier_document
    (supplier_id, kind, ref_key, title, file_name, status, attempts,
     source_stamp, requested_by, requested_at, started_at, last_error)
  values (r.supplier_id, 'debit_note', r.id::text, pay->'doc'->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (supplier_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name, status = 'queued',
        attempts = 0, source_stamp = excluded.source_stamp, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  update public.supplier_return set doc_id = v_id where id = r.id;

  begin
    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('supplier_doc_id', v_id),
      timeout_milliseconds := 20000);
  exception when others then
    null;  -- the render is retried by supplier_doc_sweep; never fail the send
  end;

  return jsonb_build_object('ok', true, 'doc_id', v_id, 'poll_ms', 1500,
    'status', 'building', 'message', public.uic('sup_return.doc_building','Preparing the debit note…'));
end $fn$;

create or replace function public.partner_return_doc(p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
        d public.supplier_document%rowtype;
begin
  if v_acc = 'none' then return public._c710_denied(); end if;
  select * into r from public.supplier_return where id = p_id;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  select * into d from public.supplier_document
   where supplier_id = r.supplier_id and kind = 'debit_note' and ref_key = r.id::text;

  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (public._c710_doc_payload(r.id)->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name, 'expires_s', 300,
      'message', public.uic('sup_return.doc_ready','Debit note ready.'));
  end if;
  return public._c710_doc_enqueue(r.id);
end $fn$;

create or replace function public.partner_return_doc_status(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
        d public.supplier_document%rowtype;
begin
  if v_acc = 'none' then return public._c710_denied(); end if;
  select * into r from public.supplier_return where id = p_id;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  select * into d from public.supplier_document
   where supplier_id = r.supplier_id and kind = 'debit_note' and ref_key = r.id::text;
  if not found then
    return jsonb_build_object('ok', true, 'status','building', 'poll_ms', 1500,
      'message', public.uic('sup_return.doc_building','Preparing the debit note…'));
  end if;
  if d.status = 'ready' and coalesce(d.path,'') <> '' then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name, 'expires_s', 300,
      'message', public.uic('sup_return.doc_ready','Debit note ready.'));
  end if;
  if d.status = 'failed' then
    return jsonb_build_object('ok', false, 'status','failed', 'doc_id', d.id, 'error','render_failed',
      'message', public.uic('sup_return.doc_failed','The debit note could not be prepared. Try again.'));
  end if;
  return jsonb_build_object('ok', true, 'status','building', 'doc_id', d.id, 'poll_ms', 1500,
    'message', public.uic('sup_return.doc_building','Preparing the debit note…'));
end $fn$;

-- The renderer learns one more kind. Merged into the LIVE body (agency_invoice
-- delegation and the partner_document fallback are kept verbatim) — a
-- create-or-replace written from an older copy is a silent revert.
create or replace function public.supplier_doc_render_input(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare d public.supplier_document%rowtype; pay jsonb;
begin
  select * into d from public.supplier_document where id = p_doc_id;
  if not found then
    -- CMD #466 row 150 — a partner statement, drawn by the same renderer.
    if exists (select 1 from public.partner_document pd where pd.id = p_doc_id) then
      return public.partner_doc_render_input(p_doc_id);
    end if;
    return jsonb_build_object('ok', false, 'error', 'doc_not_found');
  end if;

  update public.supplier_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  if d.kind = 'agency_invoice' then
    pay := public._agency_invoice_doc_payload(d.ref_key::uuid);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'partner-receipts',
      'path', 'da' || d.supplier_id::text || '/invoice/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'invoice.pdf'),
      'document', pay->'doc');
  end if;

  -- CHANGE #710 — the debit note raised by a return to this supplier.
  if d.kind = 'debit_note' then
    pay := public._c710_doc_payload(d.ref_key::uuid);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'supplier-docs',
      'path', d.supplier_id::text || '/debit_note/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'debit-note.pdf'),
      'document', pay->'doc');
  end if;

  pay := public._c403_doc_payload(d.supplier_id, d.kind, d.ref_key);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'supplier-docs',
    'path', d.supplier_id::text || '/' || d.kind || '/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'document.pdf'),
    'document', pay->'doc');
end $fn$;

-- ── 8. Send: number, stock, re-inquiry, PDF, WhatsApp ───────────────────────

-- The returned quantity leaves the bag ledger and the received count. It is
-- not "received" any more: it physically went back to the supplier.
create or replace function public._c710_release_stock(p_item_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare it public.supplier_return_item%rowtype; r public.supplier_return%rowtype;
        oi public.order_items%rowtype; v_day date; v_bag integer;
begin
  select * into it from public.supplier_return_item where id = p_item_id;
  if not found or it.bag_released then return; end if;
  select * into r from public.supplier_return where id = it.return_id;
  select * into oi from public.order_items where id = it.order_item_id;
  if not found then return; end if;

  v_day := coalesce(oi.order_date,
             (select (o.created_at at time zone 'Asia/Kolkata')::date
                from public.orders o where o.id = oi.order_id));
  v_bag := oi.bag_no;

  with pick as (
    select b.id from public.bag_item_counts b
     where b.assigned_supplier = r.supplier_name
       and b.product_id = it.product_id
       and b.order_date is not distinct from v_day
     order by (b.bag_no is not distinct from v_bag) desc, b.qty desc
     limit 1)
  update public.bag_item_counts b
     set qty = greatest(coalesce(b.qty,0) - it.qty, 0), updated_at = now()
    from pick where b.id = pick.id;

  update public.order_items
     set received_qty = greatest(coalesce(received_qty,0) - it.qty, 0)
   where id = it.order_item_id;

  insert into public.receiving_log
    (order_item_id, order_id, supplier_name, action, qty, note, actor)
  values (it.order_item_id, it.order_id, r.supplier_name, 'supplier_return', it.qty,
          'CHANGE #710 · debit note ' || coalesce(r.debit_no,'') || ' · ' || it.reason_code,
          'partner');

  update public.supplier_return_item set bag_released = true where id = it.id;
end $fn$;

-- If the customer order still needs the line, the waterfall is restarted with
-- the supplier that just failed it EXCLUDED first. 'not_ordered' never
-- re-inquires: nobody asked for it.
create or replace function public._c710_reinquire(p_item_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare it public.supplier_return_item%rowtype; r public.supplier_return%rowtype;
        oi public.order_items%rowtype;
begin
  select * into it from public.supplier_return_item where id = p_item_id;
  if not found or it.reinquiry_fired then return; end if;
  if it.reason_code = 'not_ordered' then
    update public.supplier_return_item set reinquiry_fired = true where id = it.id;
    return;
  end if;
  select * into r from public.supplier_return where id = it.return_id;
  select * into oi from public.order_items where id = it.order_item_id;
  if not found or it.product_id is null then return; end if;
  if coalesce(oi.fulfillment_state,'') in ('shipped','cancelled')
     or coalesce(oi.unfulfillable,false) then
    update public.supplier_return_item set reinquiry_fired = true where id = it.id;
    return;
  end if;

  begin
    perform public._reinquiry_exclude_and_advance(it.product_id, r.supplier_name);
  exception when others then
    null;  -- a cascade that cannot advance must never block the return
  end;
  update public.supplier_return_item set reinquiry_fired = true where id = it.id;
end $fn$;

create or replace function public._c710_notify_supplier(p_return_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype; v_phone text;
begin
  select * into r from public.supplier_return where id = p_return_id;
  if not found or coalesce(r.ack_token,'') = '' then return; end if;
  begin
    v_phone := public.sup_pick_send_phone(r.supplier_name);
    perform public.notify('supplier_debit_note', v_phone, jsonb_build_object(
      'supplier_name',   r.supplier_name,
      'debit_no',        coalesce(r.debit_no,''),
      'debit_amount',    public.inr_money(r.grand_total),
      'debit_items',     r.item_count::text,
      'debit_ack_link',  'https://medibo.in/return-ack/' || r.ack_token));
  exception when others then
    null;  -- a WhatsApp hiccup must never fail the return
  end;
end $fn$;

create or replace function public.partner_return_send(p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
        it record; v_no text;
begin
  if v_acc <> 'write' then return public._c710_denied(); end if;
  select * into r from public.supplier_return where id = p_id for update;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  if r.status <> 'drafted' then
    return public._c710_err('already_sent','sup_return.err_already_sent','This return has already been sent.');
  end if;
  perform public._c710_retotal(r.id);
  select * into r from public.supplier_return where id = p_id;
  if coalesce(r.item_count,0) = 0 then
    return public._c710_err('nothing','sup_return.err_nothing','Add at least one line before sending.');
  end if;

  v_no := public._c710_next_debit_no(coalesce(r.zone_id,0)::smallint, coalesce(r.is_synthetic,false));

  update public.supplier_return
     set status = 'sent', sent_at = now(), sent_by = auth.uid(),
         debit_no = v_no, fy = public._fy_ist(),
         ack_token = coalesce(nullif(ack_token,''), encode(gen_random_bytes(16),'hex'))
   where id = r.id;

  for it in select id from public.supplier_return_item where return_id = r.id loop
    perform public._c710_release_stock(it.id);
    perform public._c710_reinquire(it.id);
  end loop;

  perform public._c710_doc_enqueue(r.id);
  perform public._c710_notify_supplier(r.id);
  perform public.partner_audit('partner.supplier_returns','send',
    jsonb_build_object('return_id', r.id, 'debit_no', v_no, 'total', r.grand_total));

  return public.partner_return_get(r.id)
    || jsonb_build_object('toast', public._c710_fmt('sup_return.sent_toast',
         'Debit note {no} raised and sent to {supplier}.',
         jsonb_build_object('no', v_no, 'supplier', r.supplier_name)));
end $fn$;

-- ── 9. Acknowledge → credit, and the carry ledger ───────────────────────────

-- Books the debit against the bill it names. What the bill can still absorb is
-- APPLIED; whatever is left (the bill was already paid) becomes CARRY, which
-- the next supplier order can consume.
create or replace function public._c710_credit_book(p_return_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype; v_panel jsonb; v_room numeric; v_apply numeric; v_carry numeric;
begin
  select * into r from public.supplier_return where id = p_return_id for update;
  if not found or r.status not in ('sent','acknowledged') then return; end if;

  v_room := null;
  if r.supplier_order_id is not null then
    begin
      v_panel := public.sup_order_bill_panel(r.supplier_order_id);
      v_room  := nullif(v_panel->>'remaining_due','')::numeric;
    exception when others then
      v_room := null;
    end;
  end if;
  -- remaining_due already has this debit subtracted, so the room the bill had
  -- BEFORE it is what is left plus what we are booking.
  v_apply := least(coalesce(r.grand_total,0), greatest(coalesce(v_room, 0) + coalesce(r.grand_total,0), 0));
  v_carry := greatest(coalesce(r.grand_total,0) - v_apply, 0);

  update public.supplier_return
     set applied_amount = round(v_apply,2), carried_amount = round(v_carry,2),
         status = 'credited', credited_at = now()
   where id = r.id;

  delete from public.supplier_return_credit_ledger where return_id = r.id and kind in ('applied','carry');
  if v_apply > 0 then
    insert into public.supplier_return_credit_ledger
      (supplier_id, supplier_name, return_id, supplier_order_id, kind, amount, note)
    values (r.supplier_id, r.supplier_name, r.id, r.supplier_order_id, 'applied', round(v_apply,2),
            coalesce(r.debit_no,''));
  end if;
  if v_carry > 0 then
    insert into public.supplier_return_credit_ledger
      (supplier_id, supplier_name, return_id, supplier_order_id, kind, amount, note)
    values (r.supplier_id, r.supplier_name, r.id, null, 'carry', round(v_carry,2),
            coalesce(r.debit_no,''));
  end if;
end $fn$;

create or replace function public._c710_ack(p_return_id uuid, p_note text, p_who text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype;
begin
  select * into r from public.supplier_return where id = p_return_id for update;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  if r.acknowledged_at is null then
    update public.supplier_return
       set status = 'acknowledged', acknowledged_at = now(),
           acknowledged_note = coalesce(btrim(coalesce(p_note,'')),'')
     where id = r.id;
    perform public._c710_credit_book(r.id);
    perform public._c710_doc_enqueue(r.id);
  end if;
  return jsonb_build_object('ok', true, 'id', r.id,
    'toast', public.uic('sup_return.ack_toast','Acknowledged. The bill has been adjusted.'),
    'row', public._c710_row(r.id));
end $fn$;

-- Open credit this supplier is still owed, after everything already consumed.
create or replace function public.supplier_return_credit_open(p_supplier_id uuid)
returns numeric language sql stable security definer set search_path to 'public' as $fn$
  select greatest(coalesce(sum(case when kind = 'carry' then amount
                                    when kind = 'carry_use' then -amount
                                    else 0 end), 0), 0)
    from public.supplier_return_credit_ledger where supplier_id = p_supplier_id
$fn$;

create or replace function public.partner_return_carry_apply(p_supplier_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); so public.supplier_orders%rowtype;
        v_sid uuid; v_open numeric; v_room numeric; v_use numeric; v_panel jsonb;
begin
  if v_acc <> 'write' then return public._c710_denied(); end if;
  select * into so from public.supplier_orders where id = p_supplier_order_id;
  if not found then
    return public._c710_err('no_order','sup_return.err_no_order','That supplier collection no longer exists.');
  end if;
  v_sid := coalesce(so.supplier_id,
            (select sp.id from public.supplier_profiles sp
              where lower(sp.supplier_name) = lower(so.supplier_name) limit 1));
  v_open := public.supplier_return_credit_open(v_sid);
  if coalesce(v_open,0) <= 0 then
    return public._c710_err('no_credit','sup_return.credit_none','No credit available for this supplier.');
  end if;

  v_panel := public.sup_order_bill_panel(p_supplier_order_id);
  v_room  := nullif(v_panel->>'remaining_due','')::numeric;
  v_use   := least(v_open, greatest(coalesce(v_room, 0), 0));
  if v_use <= 0 then
    return public._c710_err('no_credit','sup_return.credit_none','No credit available for this supplier.');
  end if;

  insert into public.supplier_return_credit_ledger
    (supplier_id, supplier_name, return_id, supplier_order_id, kind, amount, note, created_by)
  values (v_sid, coalesce(so.supplier_name,''), null, p_supplier_order_id, 'carry_use',
          round(v_use,2), coalesce(so.order_code,''), auth.uid());

  perform public.partner_audit('partner.supplier_returns','carry_apply',
    jsonb_build_object('supplier_order_id', p_supplier_order_id, 'amount', v_use));

  return jsonb_build_object('ok', true, 'amount', round(v_use,2),
    'toast', public._c710_fmt('sup_return.credit_applied','{amount} credit applied to this bill.',
               jsonb_build_object('amount', public.inr_money(v_use))));
end $fn$;

-- ── 10. The supplier's side ─────────────────────────────────────────────────

-- The public acknowledge page. PUBLIC and anonymous exactly like
-- /stock-update/<token>: the token in the URL is the authorisation, and it
-- carries no phone number, no bill and no other supplier's data.
create or replace function public.supplier_return_ack_form(p_token text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype; v_rows jsonb;
begin
  select * into r from public.supplier_return
   where ack_token = nullif(btrim(coalesce(p_token,'')),'');
  if not found or r.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'error','invalid',
      'error_title', public.uic('sup_return.page_invalid_title','This link is no longer valid'),
      'error_note',  public.uic('sup_return.page_invalid_note','Please contact mediBO for assistance.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_name', i.product_name,
           'batch_label', i.batch_no,
           'qty_value', trim_scale(i.qty)::text,
           'reason_label', coalesce((select o.label from public.order_reason_option o
                                      where o.scope='supplier_return' and o.code = i.reason_code), i.reason_code),
           'amount_value', public.inr_money(i.line_total)) order by i.created_at, i.id), '[]'::jsonb)
    into v_rows from public.supplier_return_item i where i.return_id = r.id;

  return jsonb_build_object(
    'ok', true,
    'kind', 'supplier_return_ack',
    'supplier_name', r.supplier_name,
    'status', r.status,
    'already', (r.acknowledged_at is not null),
    'eyebrow', public.uic('sup_return.page_eyebrow','mediBO · Return to supplier'),
    'title', public._c710_fmt('sup_return.page_title','Debit note {no}',
               jsonb_build_object('no', coalesce(r.debit_no,''))),
    'intro', public.uic('sup_return.page_intro',
               'These goods have been sent back. Please acknowledge the debit note.'),
    'date_label', public.ist_fmt(coalesce(r.sent_at, r.created_at), 'day_mon_year'),
    'columns', jsonb_build_array(
      jsonb_build_object('key','product','label', public.uic('sup_return.col_product','Product'),'align','left'),
      jsonb_build_object('key','qty','label', public.uic('sup_return.col_qty','Qty'),'align','right'),
      jsonb_build_object('key','reason','label', public.uic('sup_return.col_reason','Reason'),'align','left'),
      jsonb_build_object('key','amount','label', public.uic('sup_return.col_amount','Amount'),'align','right')),
    'items', v_rows,
    'empty_text', public.uic('sup_return.doc_empty','No lines on this debit note.'),
    'count_label', public.uic('sup_return.count_label','Lines'),
    'count_value', r.item_count::text,
    'taxable_label', public.uic('sup_return.taxable_label','Taxable'),
    'taxable_value', public.inr_money(r.taxable_total),
    'gst_label', public.uic('sup_return.gst_total_label','GST'),
    'gst_value', public.inr_money(r.gst_total),
    'total_label', public.uic('sup_return.total_label','Debit note total'),
    'total_value', public.inr_money(r.grand_total),
    'effect_label', public._c710_fmt('sup_return.effect_label','Reduces your bill by {amount}',
                      jsonb_build_object('amount', public.inr_money(r.grand_total))),
    'note_hint', public.uic('sup_return.page_note_hint','Add a note (optional)'),
    'submit_label', public.uic('sup_return.ack_label','Acknowledge'),
    'submitting_label', public.uic('sup_return.page_submitting','Submitting…'),
    'success_title', public.uic('sup_return.page_done_title','Thank you — acknowledgement received'),
    'success_note', public.uic('sup_return.page_done_note','Your bill has been adjusted by this debit note.'),
    'already_note', public.uic('sup_return.page_already','You have already acknowledged this debit note.'),
    'submit_error', public.uic('sup_return.page_error','Submission failed. Please try again.'));
end $fn$;

create or replace function public.supplier_return_ack_submit(p_token text, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype;
begin
  select * into r from public.supplier_return
   where ack_token = nullif(btrim(coalesce(p_token,'')),'');
  if not found or r.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'error','invalid',
      'message', public.uic('sup_return.page_invalid_note','Please contact mediBO for assistance.'));
  end if;
  return public._c710_ack(r.id, p_note, 'supplier_link');
end $fn$;

-- The in-app acknowledge, from the supplier's own Records -> Returns tab.
create or replace function public.supplier_return_ack(p_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sid uuid := public._c403_me(); r public.supplier_return%rowtype;
begin
  if sid is null then return public._c403_denied(); end if;
  select * into r from public.supplier_return where id = p_id;
  if not found or r.supplier_id is distinct from sid then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  if r.status = 'drafted' or r.status = 'cancelled' then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  return public._c710_ack(r.id, p_note, 'supplier_app');
end $fn$;

create or replace function public.supplier_returns_list(p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare sid uuid := public._c403_me(); v_rows jsonb; v_total numeric := 0; v_n int := 0;
        v_open numeric := 0;
begin
  if sid is null then return public._c403_denied(); end if;

  select coalesce(jsonb_agg(
           public._c710_row(s.id)
           || jsonb_build_object(
                'items', coalesce((select jsonb_agg(jsonb_build_object(
                    'product_name', i.product_name,
                    'batch_label', i.batch_no,
                    'qty_value', trim_scale(i.qty)::text,
                    'reason_label', coalesce((select o.label from public.order_reason_option o
                                               where o.scope='supplier_return' and o.code = i.reason_code), i.reason_code),
                    'amount_value', public.inr_money(i.line_total))
                    order by i.created_at, i.id)
                  from public.supplier_return_item i where i.return_id = s.id), '[]'::jsonb),
                'can_ack', (s.acknowledged_at is null and s.status in ('sent')),
                'ack_label', public.uic('sup_return.ack_label','Acknowledge'))
           order by s.created_at desc), '[]'::jsonb),
         count(*), coalesce(sum(s.grand_total),0)
    into v_rows, v_n, v_total
    from (select r.id, r.created_at, r.acknowledged_at, r.status, r.grand_total
            from public.supplier_return r
           where r.supplier_id = sid and r.status <> 'drafted'
           order by r.created_at desc
           limit least(greatest(coalesce(p_limit,60),1),200)) s;

  select coalesce(sum(r.grand_total),0) into v_open
    from public.supplier_return r
   where r.supplier_id = sid and r.status in ('sent','acknowledged');

  return jsonb_build_object(
    'ok', true,
    'title', public.uic('sup_return.sup_title','Returns raised on you'),
    'subtitle', public.uic('sup_return.sup_subtitle',
                  'Stock sent back by mediBO, and the debit note against your bill'),
    'empty_label', public.uic('sup_return.sup_empty','No returns raised on you.'),
    'summary', jsonb_build_array(
      jsonb_build_object('label', public.uic('sup_return.count_label','Lines'), 'value', v_n::text),
      jsonb_build_object('label', public.uic('sup_return.total_label','Debit note total'),
                         'value', public.inr_money(v_total), 'tone', 'danger'),
      jsonb_build_object('label', public.uic('sup_return.credit_available','Credit available'),
                         'value', public.inr_money(public.supplier_return_credit_open(sid)), 'tone', 'info')),
    'payable_note', public._c710_fmt('sup_return.bill_debit_note',
                      'Debit notes reduce this bill by {amount}.',
                      jsonb_build_object('amount', public.inr_money(v_open))),
    'doc_label', public.uic('sup_return.doc_label','Debit note PDF'),
    'rows', v_rows);
end $fn$;

-- The SPN input: what this supplier had sent back, in one window. Shown next to
-- the points it feeds, exactly like the response record (CHANGE #687).
create or replace function public.supplier_returns_stats(p_supplier text default null, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_since timestamptz := now() - make_interval(days => greatest(1, coalesce(p_days,30)));
        v_n int := 0; v_qty numeric := 0; v_amt numeric := 0; v_top text := '';
begin
  select count(*)::int, coalesce(sum(r.qty_total),0), coalesce(sum(r.grand_total),0)
    into v_n, v_qty, v_amt
    from public.supplier_return r
   where r.status in ('sent','acknowledged','credited')
     and coalesce(r.sent_at, r.created_at) >= v_since
     and (p_supplier is null
          or lower(btrim(r.supplier_name)) = lower(btrim(p_supplier)));

  select coalesce((select o.label from public.order_reason_option o
                    where o.scope='supplier_return' and o.code = t.reason_code), t.reason_code)
    into v_top
    from (select i.reason_code, count(*) n
            from public.supplier_return_item i
            join public.supplier_return r on r.id = i.return_id
           where r.status in ('sent','acknowledged','credited')
             and coalesce(r.sent_at, r.created_at) >= v_since
             and (p_supplier is null
                  or lower(btrim(r.supplier_name)) = lower(btrim(p_supplier)))
           group by i.reason_code order by count(*) desc limit 1) t;

  return jsonb_build_object(
    'ok', true,
    'has', (v_n > 0),
    'supplier', coalesce(p_supplier,''),
    'window_days', greatest(1, coalesce(p_days,30)),
    'title', public.uic('sup_return.spn_title','Returns raised on you'),
    'empty_label', public.uic('sup_return.spn_none','No returns in this window'),
    'count_label', public.uic('sup_return.spn_count_label','Debit notes'),
    'count_value', v_n::text,
    'qty_value', trim_scale(v_qty)::text,
    'value_label', public.uic('sup_return.spn_value_label','Debited'),
    'value_value', public.inr_money(v_amt),
    'value_tone', case when v_n = 0 then 'success' when v_n <= 2 then 'warning' else 'danger' end,
    'reason_label', public.uic('sup_return.col_reason','Reason'),
    'reason_value', coalesce(v_top,''));
end $fn$;

-- ── 11. The bill actually moves ─────────────────────────────────────────────

create or replace function public._c710_order_debits(p_supplier_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_total numeric := 0; v_rows jsonb := '[]'::jsonb; v_carry numeric := 0;
begin
  select coalesce(sum(r.grand_total),0),
         coalesce(jsonb_agg(jsonb_build_object(
           'return_id', r.id, 'debit_no', coalesce(r.debit_no,''),
           'status', r.status, 'status_label', public._c710_status_label(r.status),
           'status_tone', public._c710_status_tone(r.status),
           'items', r.item_count, 'amount', r.grand_total,
           'amount_display', public.inr_money(r.grand_total),
           'label', coalesce(r.debit_no,'') || ' · ' || r.item_count::text || ' × '
                    || public.uic('sup_return.col_product','Product'),
           'at', coalesce(r.sent_at, r.created_at)) order by coalesce(r.sent_at, r.created_at) desc), '[]'::jsonb)
    into v_total, v_rows
    from public.supplier_return r
   where r.supplier_order_id = p_supplier_order_id
     and r.status in ('sent','acknowledged','credited');

  select coalesce(sum(l.amount),0) into v_carry
    from public.supplier_return_credit_ledger l
   where l.supplier_order_id = p_supplier_order_id and l.kind = 'carry_use';

  return jsonb_build_object(
    'total', round(coalesce(v_total,0),2),
    'total_display', public.inr_money(coalesce(v_total,0)),
    'carry_used', round(coalesce(v_carry,0),2),
    'carry_used_display', public.inr_money(coalesce(v_carry,0)),
    'label', public.uic('sup_return.bill_debit_label','Debit notes'),
    'carry_label', public.uic('sup_return.bill_carry_label','Credit carried'),
    'note', case when coalesce(v_total,0) + coalesce(v_carry,0) > 0
                 then public._c710_fmt('sup_return.bill_debit_note',
                        'Debit notes reduce this bill by {amount}.',
                        jsonb_build_object('amount',
                          public.inr_money(coalesce(v_total,0) + coalesce(v_carry,0))))
                 else '' end,
    'rows', v_rows);
end $fn$;

-- The payable moves. remaining_due was bills + excess-kept adjustments - paid;
-- it is now also net of the debit notes raised against this collection and of
-- any carried credit consumed by it. Merged into the LIVE body — the ownership
-- gate (#25), the config-driven advance (#526 gap 30) and the strict bill date
-- match are kept verbatim.
create or replace function public.sup_order_bill_panel(p_supplier_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare so record; v_sid uuid; v_pa text; v_mrp numeric := 0; v_paid numeric := 0;
        v_adv_pct numeric;
        v_adv_paid numeric := 0; v_bill_total numeric := 0; v_any_imported boolean := false;
        v_adj_total numeric := 0; v_adjustments jsonb := '[]'::jsonb; v jsonb;
        v_order_date date; v_role text; v_me text; v_pay numeric := 0;
        v_deb jsonb; v_deb_total numeric := 0; v_carry_used numeric := 0; v_credit_open numeric := 0;
begin
  select id, supplier_id, supplier_name, order_code, created_at, items,
         coalesce(total_amount,0) total_amount
    into so from supplier_orders where id = p_supplier_order_id;
  if not found then return jsonb_build_object('found', false); end if;

  -- OWNERSHIP GATE (#25). Platform staff, or the supplier this PO belongs to.
  v_role := public.get_my_role();
  if v_role not in ('super_admin','admin') then
    select sp.supplier_name into v_me from public.current_supplier_profile() sp;
    if v_me is null or lower(btrim(v_me)) is distinct from lower(btrim(so.supplier_name)) then
      return jsonb_build_object(
        'found', false,
        'error', 'forbidden',
        'message', public.uic('sup_order_bill_panel.forbidden','This bill panel belongs to another supplier.'));
    end if;
  end if;

  -- cmd #526 gap 30: the advance share is CONFIG, not a literal.
  select coalesce(po_advance_percent, 30) into v_adv_pct from payment_config where id = 1;
  v_adv_pct := coalesce(v_adv_pct, 30);

  v_order_date := (so.created_at AT TIME ZONE 'Asia/Kolkata')::date;

  v_sid := coalesce(so.supplier_id,
             (select id from supplier_profiles where lower(supplier_name)=lower(so.supplier_name) limit 1));
  select payment_address into v_pa from supplier_profiles where id = v_sid;

  select coalesce(sum(coalesce(
           nullif(regexp_replace(coalesce(it->>'mrp',''),'[^0-9.]','','g'),'')::numeric,
           (select nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric
              from "MEDICINE" m where m.id = nullif(it->>'product_id','')::bigint)
         ,0) * coalesce(nullif(it->>'quantity','')::numeric,1)),0)
    into v_mrp
  from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it;

  -- #29: the advance is a share of what is PAYABLE (trade rate where the
  -- supplier has quoted one), not of the MRP ceiling.
  v_pay := case when so.total_amount > 0 then so.total_amount else v_mrp end;

  select coalesce(sum(amount),0), coalesce(sum(amount) filter (where kind='advance'),0)
    into v_paid, v_adv_paid from supplier_payments where supplier_order_id = so.id;

  select coalesce(sum(d.adj_amount),0),
         coalesce(jsonb_agg(jsonb_build_object(
             'dispute_id', d.id, 'dispute_code', d.dispute_code, 'product_name', d.product_name,
             'qty', d.adj_qty, 'rate', d.adj_rate, 'amount', d.adj_amount,
             'label', '+'||coalesce(d.adj_qty,0)||' units @ '||coalesce(d.adj_rate,0)||' (excess kept)',
             'at', d.resolved_at) order by d.resolved_at desc), '[]'::jsonb)
    into v_adj_total, v_adjustments
  from supplier_disputes d
  where d.adj_supplier_order_id = so.id and d.resolution_outcome = 'excess_kept'
    and coalesce(d.adj_amount,0) > 0;

  -- CHANGE #710 — returns sent back to this supplier against this collection.
  v_deb        := public._c710_order_debits(so.id);
  v_deb_total  := coalesce((v_deb->>'total')::numeric, 0);
  v_carry_used := coalesce((v_deb->>'carry_used')::numeric, 0);
  v_credit_open := coalesce(public.supplier_return_credit_open(v_sid), 0);

  with bl as (
    select id, file_path, file_name, coalesce(bucket, case when file_path like 'whatsapp/%' then 'whatsapp-media' else 'supplier-bills' end) bucket,
           source, received_at, scan_status, scan_result,
           (imported_at is not null or lower(coalesce(status,''))='imported') as imported
    from pending_bills
    where ((v_sid is not null and supplier_id = v_sid::text)
       or (supplier_id is null and supplier_name is not null and lower(supplier_name)=lower(so.supplier_name)))
      and lower(coalesce(verdict,'')) <> 'fake'
      -- STRICT DATE MATCH (locked with Om 23 Jul).
      and (received_at AT TIME ZONE 'Asia/Kolkata')::date = v_order_date
  ),
  nb as (select row_number() over (order by received_at asc) bill_no, * from bl)
  select coalesce(sum(nullif(regexp_replace(coalesce(scan_result->>'total',''),'[^0-9.]','','g'),'')::numeric) filter (where imported),0),
         coalesce(bool_or(imported), false),
         jsonb_build_object(
           'found', true,
           'supplier_order_id', so.id,
           'order_code', so.order_code,
           'supplier_name', so.supplier_name,
           'payment_address', v_pa,
           'bills_total',    count(*),
           'bills_imported', count(*) filter (where imported),
           'bills_left',     count(*) filter (where not imported),
           'bills', coalesce(jsonb_agg(jsonb_build_object(
               'bill_no', bill_no, 'id', id, 'bucket', bucket, 'file_path', file_path, 'file_name', file_name,
               'source', source, 'received_at', received_at, 'imported', imported, 'scan_status', scan_status,
               'bill_amount', nullif(regexp_replace(coalesce(scan_result->>'total',''),'[^0-9.]','','g'),'')::numeric
             ) order by bill_no) filter (where id is not null), '[]'::jsonb))
    into v_bill_total, v_any_imported, v
  from nb;

  v := coalesce(v, jsonb_build_object('found', true, 'supplier_order_id', so.id, 'order_code', so.order_code,
        'supplier_name', so.supplier_name, 'payment_address', v_pa,
        'bills_total',0,'bills_imported',0,'bills_left',0,'bills','[]'::jsonb));

  v := v || jsonb_build_object(
    'mrp_total',        round(v_mrp,2),
    'payable_total',    round(v_pay,2),
    'pricing',          public.po_pricing_block(so.id),
    'total_paid',       round(v_paid,2),
    'advance_required', round(v_pay * v_adv_pct / 100.0, 0),
    'advance_percent',  v_adv_pct,
    'advance_paid',     round(v_adv_paid,2),
    'any_bill_imported', v_any_imported,
    'bills_amount_total', round(v_bill_total,2),
    'adjustments',       v_adjustments,
    'adjustments_total', round(v_adj_total,2),
    'debits',            v_deb,
    'debits_total',      round(v_deb_total,2),
    'carry_used',        round(v_carry_used,2),
    'credit_available',  round(v_credit_open,2),
    'credit_available_display', public.inr_money(v_credit_open),
    'credit_available_label',   public.uic('sup_return.credit_available','Credit available'),
    'credit_apply_label',       public.uic('sup_return.credit_apply','Apply credit'),
    'can_apply_credit',  (v_credit_open > 0),
    'remaining_due', case when v_any_imported
      then round(greatest(v_bill_total + v_adj_total - v_deb_total - v_carry_used - v_paid, 0),2)
      else null end,
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
        'id',id,'kind',kind,'amount',amount,'mode',mode,'note',note,'at',created_at,
        'payee_name',payee_name,'payee_vpa',payee_vpa,'utr',utr,'txn_id',txn_id,'app',app,'paid_at',paid_at,
        'screenshot_path',screenshot_path,'screenshot_bucket',screenshot_bucket
      ) order by created_at desc) from supplier_payments where supplier_order_id = so.id), '[]'::jsonb));
  return v;
end $fn$;
CREATE OR REPLACE FUNCTION public.partner_supplier_payment_console(p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_zone smallint := public.partner_zone_id(); v_acc text; v_rows jsonb;
begin
  if public.my_partner_id() is null then
    return jsonb_build_object('ok',false,'error','not_partner',
      'message', public._pss_c('err_not_authorized'));
  end if;
  v_acc := public.partner_access('partner.supplier_payment');
  if v_acc = 'none' then
    perform public.partner_audit('partner.supplier_payment','open_denied','{}'::jsonb);
    return jsonb_build_object('ok',false,'error','no_access','access','none',
      'message', public._pss_c('err_not_authorized'));
  end if;

  select jsonb_agg(r order by (r->>'sort') desc) into v_rows from (
    select jsonb_build_object(
      'supplier_order_id', so.id,
      'sort', to_char(so.created_at,'YYYYMMDDHH24MISS'),
      'supplier_name', coalesce(so.supplier_name,''),
      'order_label', coalesce(nullif(so.order_code,''), nullif(so.order_no::text,''), ''),
      'date_label', to_char(so.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'),
      'total_text', public.inr_money(coalesce(so.trade_total, so.total_amount, 0)),
      'paid_label', public._pss_c('pay_paid_label'),
      'paid_text',  public.inr_money(coalesce(p.paid,0)),
      'due_label',  public._pss_c('pay_due_label'),
      -- CHANGE #710 — a debit note raised against this collection reduces what
      -- is payable, and so does any carried credit consumed by it. Both are
      -- read from the SAME helper the bill panel uses, so the two screens can
      -- never disagree about the due.
      'debit_label', public.uic('sup_return.bill_debit_label','Debit notes'),
      'debit_text',  (public._c710_order_debits(so.id)->>'total_display'),
      'debit_amount',(public._c710_order_debits(so.id)->>'total')::numeric,
      'has_debit',   (coalesce((public._c710_order_debits(so.id)->>'total')::numeric,0)
                      + coalesce((public._c710_order_debits(so.id)->>'carry_used')::numeric,0)) > 0,
      'debit_note',  (public._c710_order_debits(so.id)->>'note'),
      'credit_label', public.uic('sup_return.credit_available','Credit available'),
      'credit_text',  public.inr_money(coalesce(public.supplier_return_credit_open(so.supplier_id),0)),
      'can_apply_credit', (v_acc = 'write'
                           and coalesce(public.supplier_return_credit_open(so.supplier_id),0) > 0),
      'credit_apply_label', public.uic('sup_return.credit_apply','Apply credit'),
      'due_text',   public.inr_money(greatest(coalesce(so.trade_total, so.total_amount, 0)
                      - coalesce(p.paid,0)
                      - coalesce((public._c710_order_debits(so.id)->>'total')::numeric,0)
                      - coalesce((public._c710_order_debits(so.id)->>'carry_used')::numeric,0), 0)),
      'due_tone',   case when coalesce(so.trade_total, so.total_amount, 0) - coalesce(p.paid,0)
                              - coalesce((public._c710_order_debits(so.id)->>'total')::numeric,0)
                              - coalesce((public._c710_order_debits(so.id)->>'carry_used')::numeric,0) > 0
                         then 'warning' else 'success' end,
      -- CHANGE #402 — the approved payout detail, verbatim.
      'payout', case when so.supplier_id is null then null
                     else public.supplier_payout_active(so.supplier_id) end,
      'can_record', (v_acc = 'write')) as r
      from supplier_orders so
      left join lateral (select sum(sp.amount) paid from supplier_payments sp
                          where sp.supplier_order_id = so.id) p on true
     where so.zone_id is not null and so.zone_id::smallint = v_zone
     order by so.created_at desc
     limit greatest(coalesce(p_limit,40), 1)
  ) s;

  perform public.partner_audit('partner.supplier_payment','open',
    jsonb_build_object('access', v_acc));

  return jsonb_build_object(
    'ok', true, 'access', v_acc, 'can_write', (v_acc='write'),
    'zone_id', v_zone,
    'title',        public._pss_c('pay_title'),
    'subtitle',     public._pss_c('pay_subtitle'),
    'order_label',  public._pss_c('pay_order_label'),
    'amount_label', public._pss_c('pay_amount_label'),
    'kind_label',   public._pss_c('pay_kind_label'),
    'mode_label',   public._pss_c('pay_mode_label'),
    'ref_label',    public._pss_c('pay_ref_label'),
    'note_label',   public._pss_c('pay_note_label'),
    'proof_label',  public._pss_c('pay_proof_label'),
    'pick_label',   public._pss_c('pay_pick_label'),
    'save_label',   public._pss_c('pay_save_label'),
    'cancel_label', public._pss_c('cancel_label'),
    'empty_text',   public._pss_c('pay_empty'),
    'readonly_text',case when v_acc='write' then '' else public._pss_c('pay_readonly') end,
    'proof_bucket', 'partner-receipts',
    'kind_options', jsonb_build_array(
      jsonb_build_object('value','advance','label','Advance','selected',true),
      jsonb_build_object('value','balance','label','Balance','selected',false)),
    'mode_options', jsonb_build_array(
      jsonb_build_object('value','online','label','Online / UPI','selected',true),
      jsonb_build_object('value','cash','label','Cash','selected',false)),
    'rows', coalesce(v_rows,'[]'::jsonb));
end $function$


-- ── 12. The debit note served to whichever side asked ──────────────────────
-- The debit note, served to a caller the caller's own RPC has already
-- authorised: ready when the stamp still matches, queued otherwise.
create or replace function public._c710_doc_serve(p_return_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r public.supplier_return%rowtype; d public.supplier_document%rowtype;
begin
  select * into r from public.supplier_return where id = p_return_id;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  select * into d from public.supplier_document
   where supplier_id = r.supplier_id and kind = 'debit_note' and ref_key = r.id::text;
  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (public._c710_doc_payload(r.id)->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name, 'expires_s', 300,
      'message', public.uic('sup_return.doc_ready','Debit note ready.'));
  end if;
  return public._c710_doc_enqueue(r.id);
end $fn$;

create or replace function public.partner_return_doc(p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access();
begin
  if v_acc = 'none' then return public._c710_denied(); end if;
  return public._c710_doc_serve(p_id);
end $fn$;

-- The scorecard gains one more SPN input (merged into the live body).
CREATE OR REPLACE FUNCTION public.supplier_scorecard()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  sp     public.supplier_profiles%rowtype;
  v_id   uuid := public.my_supplier_id();
  v_rank int;
  v_of   int;
  v_act  boolean;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier',
      'message', public._c('spn.not_supplier'));
  end if;
  select * into sp from public.supplier_profiles where id = v_id;

  v_act := (lower(btrim(coalesce(sp.status,''))) = 'active');

  if sp.zone_id is not null then
    select r.rnk, r.n into v_rank, v_of from (
      select s.id,
             rank() over (order by coalesce(s."SPN",0) desc)::int as rnk,
             count(*) over ()::int                                as n
        from public.supplier_profiles s
       where s.zone_id = sp.zone_id
         and s.approved = true
         and coalesce(s.is_deleted,false) = false
    ) r where r.id = sp.id;
  end if;

  return jsonb_build_object(
    'ok',        true,
    'title',     public._c('spn.title'),
    'subtitle',  public._c('spn.subtitle'),
    'spn', jsonb_build_object(
      'value', coalesce(sp."SPN",0),
      'label', public._c('spn.value_label'),
      'value_label', to_char(coalesce(sp."SPN",0), 'FM999,999,999')),
    'status', jsonb_build_object(
      'is_active', v_act,
      'label',     coalesce(nullif(btrim(coalesce(sp.status,'')),''), ''),
      'note',      case when v_act then public._c('spn.active_note')
                        else public._c('spn.inactive_note') end,
      'tone',      case when v_act then 'success' else 'warning' end),
    'rank', jsonb_build_object(
      'has',       (v_rank is not null),
      'label',     public._c('spn.rank_label'),
      'value',     coalesce(v_rank,0),
      'value_label', case when v_rank is null then ''
                          else '#' || v_rank::text end,
      'of_label',  case when v_of is null then public._c('spn.no_rank')
                        else replace(public._c('spn.rank_of'), '{n}', v_of::text) end),
    -- CHANGE #687: the response record is an SPN INPUT, shown to the supplier
    -- next to the points it will feed.
    'response',  public.supplier_response_stats(sp.supplier_name, 30),
    -- CHANGE #710: returns raised on this supplier are an SPN INPUT too, shown
    -- beside the response record and read from the returns ledger.
    'returns',   public.supplier_returns_stats(sp.supplier_name, 30),
    'components_label', public._c('spn.components_label'),
    'components', jsonb_build_array(
      jsonb_build_object('key','margin','label', public._c('spn.component_margin'),
        'points', coalesce(sp.margin_points,0),
        'points_label', to_char(coalesce(sp.margin_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.margin::text,'')),''),'')),
      jsonb_build_object('key','behaviour','label', public._c('spn.component_behaviour'),
        'points', coalesce(sp.behaviour_points,0),
        'points_label', to_char(coalesce(sp.behaviour_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.behaviour::text,'')),''),'')),
      jsonb_build_object('key','cd_condition','label', public._c('spn.component_cd_condition'),
        'points', coalesce(sp.cd_points,0),
        'points_label', to_char(coalesce(sp.cd_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.cd_condition::text,'')),''),'')),
      jsonb_build_object('key','payment_term','label', public._c('spn.component_payment_term'),
        'points', coalesce(sp.payment_term_points,0),
        'points_label', to_char(coalesce(sp.payment_term_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.payment_term::text,'')),''),'')),
      jsonb_build_object('key','ordered_medicine','label', public._c('spn.component_ordered_medicine'),
        'points', coalesce(sp.ordered_medicine_points,0),
        'points_label', to_char(coalesce(sp.ordered_medicine_points,0),'FM999,999,999'),
        'choice_label', '')));
end $function$


-- supplier_doc_request learns the debit_note kind (merged into the live body).
CREATE OR REPLACE FUNCTION public.supplier_doc_request(p_kind text, p_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  sid uuid := public._c403_me();
  pay jsonb; d public.supplier_document%rowtype; v_id uuid;
begin
  if sid is null then return public._c403_denied(); end if;
  -- CHANGE #710 — the debit note is the supplier's own document too. Its
  -- payload comes from _c710_doc_payload (never _c403_doc_payload, which does
  -- not know the kind), and the return must belong to this supplier.
  if coalesce(p_kind,'') = 'debit_note' then
    if not exists (select 1 from public.supplier_return r
                    where r.id::text = p_ref and r.supplier_id = sid
                      and r.status <> 'drafted') then
      return jsonb_build_object('ok', false, 'error', 'not_found',
        'message', public.ui_text('supplier_docs.err_not_found'));
    end if;
    return public._c710_doc_serve(p_ref::uuid);
  end if;
  if coalesce(p_kind,'') not in ('purchase_order','bill_copy','monthly_statement') then
    return jsonb_build_object('ok', false, 'error', 'unknown_kind',
      'message', public.ui_text('supplier_docs.err_unknown_kind'));
  end if;

  pay := public._c403_doc_payload(sid, p_kind, p_ref);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public.ui_text('supplier_docs.err_not_found'));
  end if;

  select * into d from public.supplier_document
   where supplier_id = sid and kind = p_kind and ref_key = p_ref;

  -- Nothing changed since the last render: serve the file that already exists.
  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status', 'ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public.ui_text('supplier_docs.ready_message'));
  end if;

  insert into public.supplier_document(
      supplier_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (sid, p_kind, p_ref, pay->'doc'->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (supplier_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status', 'building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public.ui_text('supplier_docs.building_message'));
end $function$


-- ── 13. Grants — by PATTERN, never by a list of names ───────────────────────
-- Every function here is SECURITY DEFINER, and a definer function created
-- without a grant keeps the default PUBLIC EXECUTE — i.e. it is callable with
-- the anon key printed in the web bundle. #25 / #353 / #394 were that same bug
-- three times. The revoke is written as a pattern so a function added to this
-- family tomorrow is covered without editing a list.
do $grants$
declare f record;
begin
  for f in
    select p.oid::regprocedure::text sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like '\_c710\_%'
            or p.proname like 'partner\_return\_%'
            or p.proname in ('partner_returns_console','supplier_returns_list',
                             'supplier_returns_stats','supplier_return_ack',
                             'supplier_return_ack_form','supplier_return_ack_submit',
                             'supplier_return_credit_open'))
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $grants$;

-- The two PUBLIC ones, and only these two: the supplier opens the acknowledge
-- link from WhatsApp with no session, exactly like /stock-update/<token>.
grant execute on function public.supplier_return_ack_form(text)        to anon;
grant execute on function public.supplier_return_ack_submit(text,text) to anon;

-- ── 14. The WhatsApp route ──────────────────────────────────────────────────

insert into public.wa_event_routes
  (event_key, label, description, language, variable_map, enabled, auto_manage,
   auto_template_name, bypass_send_window, audience, wa_category, marketing_guard,
   dedupe_minutes, push_enabled, email_enabled, email_mode,
   push_title, push_body, email_subject, email_body)
values
  ('supplier_debit_note',
   'Debit note raised on a supplier',
   'CHANGE #710 — goods went back to the supplier; this asks them to acknowledge the debit note.',
   'en',
   '["{{supplier_name}}", "{{debit_no}}", "{{debit_amount}}", "{{debit_items}}", "{{debit_ack_link}}"]'::jsonb,
   true, true, 'supplier_debit_note', true, 'supplier', 'utility', true, 0,
   true, true, 'fallback',
   'Debit note {{debit_no}}',
   '{{debit_items}} item(s) returned. {{debit_amount}} debited.',
   'Debit note {{debit_no}} — {{debit_amount}}',
   'Dear {{supplier_name}},' || chr(10) || chr(10) ||
   '{{debit_items}} item(s) have been returned to you. Debit note {{debit_no}} for {{debit_amount}} has been raised against your bill.' || chr(10) || chr(10) ||
   'Please acknowledge here: {{debit_ack_link}}')
on conflict (event_key) do update
  set label = excluded.label, description = excluded.description,
      variable_map = excluded.variable_map, audience = excluded.audience,
      auto_manage = true, auto_template_name = excluded.auto_template_name,
      push_enabled = true, email_enabled = true, email_mode = excluded.email_mode,
      push_title = excluded.push_title, push_body = excluded.push_body,
      email_subject = excluded.email_subject, email_body = excluded.email_body,
      updated_at = now();

-- ── 15. Stock release, corrected against the triggers that already own it ───
--
-- Two things this had to learn the hard way, both from live triggers:
--
--  (a) bag_item_counts is DERIVED. trg_bag_alloc_on_received re-runs
--      _bag_realloc_group() on every received_qty change and
--      trg_bag_clear_on_received_zero deletes the group when it empties. Writing
--      that table by hand is the scalar-write-into-a-derived-table anti-pattern:
--      the trigger recomputes it a moment later and the manual number is lost.
--      So the return moves ONE number — received_qty — and the bag ledger
--      follows by itself.
--
--  (b) _enforce_receive_requires_forward() blocked the write. Its job is "no
--      RECEIVING before the Supplier Shop submit"; a return is the opposite of
--      receiving, and a strict decrease that touches neither at_warehouse nor
--      received_locked was never what it meant to stop. Widened below to admit
--      exactly that, which closes a false positive without loosening the guard.

create or replace function public._enforce_receive_requires_forward()
returns trigger language plpgsql set search_path to 'public' as $fn$
begin
  if new.assigned_supplier is null or btrim(new.assigned_supplier) = '' then return new; end if;
  -- CHANGE #710: a strict DECREASE of the received count, with the warehouse
  -- flags untouched, is stock going BACK to the supplier — never receiving.
  if tg_op = 'UPDATE'
     and coalesce(new.received_qty,0) < coalesce(old.received_qty,0)
     and new.at_warehouse    is not distinct from old.at_warehouse
     and new.received_locked is not distinct from old.received_locked then
    return new;
  end if;
  if (tg_op = 'INSERT'
      or new.received_qty    is distinct from old.received_qty
      or new.at_warehouse    is distinct from old.at_warehouse
      or new.received_locked is distinct from old.received_locked)
     and (coalesce(new.received_qty,0) > 0
          or coalesce(new.at_warehouse,false)
          or coalesce(new.received_locked,false))
     and not public._supplier_forwarded(new.assigned_supplier) then
    raise exception 'supplier "%" not forwarded — no receiving before Supplier Shop submit', new.assigned_supplier
      using errcode = 'check_violation';
  end if;
  return new;
end $fn$;

create or replace function public._c710_release_stock(p_item_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare it public.supplier_return_item%rowtype; r public.supplier_return%rowtype;
        oi public.order_items%rowtype;
begin
  select * into it from public.supplier_return_item where id = p_item_id;
  if not found or it.bag_released then return; end if;
  select * into r from public.supplier_return where id = it.return_id;
  select * into oi from public.order_items where id = it.order_item_id;
  if not found then return; end if;

  -- The one write. bag_item_counts follows through trg_bag_alloc_on_received /
  -- trg_bag_clear_on_received_zero — never written here by hand.
  update public.order_items
     set received_qty = greatest(coalesce(received_qty,0) - it.qty, 0)
   where id = it.order_item_id;

  insert into public.receiving_log
    (order_item_id, order_id, supplier_name, action, qty, note, actor)
  values (it.order_item_id, it.order_id, r.supplier_name, 'supplier_return', it.qty,
          'CHANGE #710 · debit note ' || coalesce(r.debit_no,'') || ' · ' || it.reason_code,
          'partner');

  update public.supplier_return_item set bag_released = true where id = it.id;
end $fn$;

insert into public.ui_copy (key, value) values
  ('sup_return.err_need_count',
   '"Returns move the received count, so Count access is needed to send this return."'::jsonb)
on conflict (key) do nothing;

-- Sending a return REDUCES the received count, which order_items guards behind
-- partner.count. Refuse in words rather than letting the row trigger raise.
create or replace function public.partner_return_send(p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_acc text := public._c710_access(); r public.supplier_return%rowtype;
        it record; v_no text;
begin
  if v_acc <> 'write' then return public._c710_denied(); end if;
  if public.is_partner() and public.partner_access('partner.count') <> 'write' then
    return public._c710_err('need_count','sup_return.err_need_count',
      'Returns move the received count, so Count access is needed to send this return.');
  end if;
  select * into r from public.supplier_return where id = p_id for update;
  if not found then
    return public._c710_err('not_found','sup_return.err_not_found','That return no longer exists.');
  end if;
  if r.status <> 'drafted' then
    return public._c710_err('already_sent','sup_return.err_already_sent','This return has already been sent.');
  end if;
  perform public._c710_retotal(r.id);
  select * into r from public.supplier_return where id = p_id;
  if coalesce(r.item_count,0) = 0 then
    return public._c710_err('nothing','sup_return.err_nothing','Add at least one line before sending.');
  end if;

  v_no := public._c710_next_debit_no(coalesce(r.zone_id,0)::smallint, coalesce(r.is_synthetic,false));

  update public.supplier_return
     set status = 'sent', sent_at = now(), sent_by = auth.uid(),
         debit_no = v_no, fy = public._fy_ist(),
         ack_token = coalesce(nullif(ack_token,''), encode(gen_random_bytes(16),'hex'))
   where id = r.id;

  for it in select id from public.supplier_return_item where return_id = r.id loop
    perform public._c710_release_stock(it.id);
    perform public._c710_reinquire(it.id);
  end loop;

  perform public._c710_doc_enqueue(r.id);
  perform public._c710_notify_supplier(r.id);
  perform public.partner_audit('partner.supplier_returns','send',
    jsonb_build_object('return_id', r.id, 'debit_no', v_no, 'total', r.grand_total));

  return public.partner_return_get(r.id)
    || jsonb_build_object('toast', public._c710_fmt('sup_return.sent_toast',
         'Debit note {no} raised and sent to {supplier}.',
         jsonb_build_object('no', v_no, 'supplier', r.supplier_name)));
end $fn$;

revoke all on function public.partner_return_send(uuid) from public, anon;
grant execute on function public.partner_return_send(uuid) to authenticated, service_role;
revoke all on function public._c710_release_stock(uuid) from public, anon;
grant execute on function public._c710_release_stock(uuid) to authenticated, service_role;
-- CHANGE #710 — register the new protected file in the canonical rule. A
-- targeted replace on the CURRENT body, so a concurrent edit is preserved.
do $m$
declare v_body text; v_new text; v_anchor text;
begin
  select body into v_body from public.agent_memory where section = 'protected_tests' for update;
  if v_body is null then return; end if;
  if position('supplier_return_test.dart' in v_body) > 0 then return; end if;

  v_anchor := 'The suite runs on the Dart VM in ~2s.';
  v_new := '- `supplier_return_test.dart` — the return-to-supplier flow and its' || chr(10) ||
'  debit note: no rupee, status word, tone, GST figure or return ceiling is' || chr(10) ||
'  computed in Dart (the fixture''s total deliberately does NOT equal the sum of' || chr(10) ||
'  its lines), Acknowledge is the backend''s can_ack flag while the' || chr(10) ||
'  "Acknowledged on …" sentence is its own `ack_done_label` key, rows and lines' || chr(10) ||
'  render in payload order, ok:false and an unknown /return-ack/<token> print' || chr(10) ||
'  the backend''s refusal instead of throwing, and the partner editor''s Send /' || chr(10) ||
'  Remove / PDF buttons are can_send / can_edit / can_doc.' || chr(10) || chr(10);

  update public.agent_memory
     set body = replace(v_body, v_anchor, v_new || v_anchor),
         version = version + 1,
         updated_at = now()
   where section = 'protected_tests';
end $m$;

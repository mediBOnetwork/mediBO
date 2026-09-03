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

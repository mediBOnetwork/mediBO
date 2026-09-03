-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #810 — Customers tab redesign.
--
-- The Customers tab was a tall card per pharmacy whose every string was built
-- in Dart from raw `pharmacy_profiles` rows. This is the same move #753 made
-- for Suppliers: ONE backend-owned console payload — compact rows, filter
-- chips that carry their own counts, a sort sheet, and a customer page whose
-- tab list is a registry table and whose every tab is a single RPC returning
-- render-ready blocks.
--
-- Nothing here is computed in Flutter. Every label, rupee, percentage, chip,
-- confirm dialog and menu entry arrives as a string.
--
-- mediBO does NOT deal in credit: there is deliberately no credit limit, no
-- credit utilisation and no "credit blocked" state anywhere in this file. What
-- a customer owes is an UNPAID BILL, not a credit line.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Tab registry — the customer page's tab list is DATA, not Dart ───────
create table if not exists public.admin_customer_tab (
  tab_key      text primary key,
  label        text not null,
  feature_key  text,                       -- partner matrix gate; null = admin
  sort_order   integer not null default 100,
  is_active    boolean not null default true,
  icon_key     text,
  rpc          text
);
alter table public.admin_customer_tab enable row level security;
do $c810p1$ begin
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='admin_customer_tab' and policyname='act_read') then
    create policy act_read on public.admin_customer_tab for select using (true);
  end if;
end $c810p1$;

insert into public.admin_customer_tab (tab_key, label, feature_key, sort_order, icon_key) values
  ('info',        'Info',              null,                     10, 'person'),
  ('orders',      'Orders',            'partner.orders',         20, 'receipt'),
  ('billing',     'Bills & Payments',  'partner.payments',       30, 'payments'),
  ('cart',        'Cart',              null,                     40, 'cart'),
  ('staff',       'Staff',             null,                     50, 'group'),
  ('addresses',   'Addresses',         null,                     60, 'place'),
  ('performance', 'Performance',       null,                     70, 'insights'),
  ('history',     'History',           null,                     80, 'history')
on conflict (tab_key) do update
  set label = excluded.label,
      feature_key = excluded.feature_key,
      sort_order = excluded.sort_order,
      icon_key = excluded.icon_key;

-- ── 2. Notes & follow-ups ─────────────────────────────────────────────────
create table if not exists public.customer_note (
  id          bigserial primary key,
  customer_id uuid not null,
  body        text not null default '',
  remind_on   date,
  status      text not null default 'open',      -- open | done
  created_by  text not null default '',
  created_at  timestamptz not null default now(),
  done_at     timestamptz,
  done_by     text
);
create index if not exists customer_note_cust_idx on public.customer_note (customer_id, created_at desc);
create index if not exists customer_note_due_idx  on public.customer_note (remind_on) where status = 'open';
alter table public.customer_note enable row level security;

-- ── 3. Merge-duplicates audit ─────────────────────────────────────────────
create table if not exists public.customer_merge_log (
  id          bigserial primary key,
  kept_id     uuid not null,
  merged_id   uuid not null,
  kept_name   text not null default '',
  merged_name text not null default '',
  matched_on  text not null default '',
  moved       jsonb not null default '{}'::jsonb,
  merged_by   text not null default '',
  created_at  timestamptz not null default now()
);
alter table public.customer_merge_log enable row level security;

-- ── 4. Churn nudge log — one row per WhatsApp nudge actually sent ──────────
create table if not exists public.customer_nudge_log (
  id          bigserial primary key,
  customer_id uuid not null,
  template    text not null default '',
  days_idle   integer,
  sent_by     text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists customer_nudge_cust_idx on public.customer_nudge_log (customer_id, created_at desc);
alter table public.customer_nudge_log enable row level security;

-- ── 5. Delete-with-reason audit (parity with the old card's Delete) ────────
create table if not exists public.customer_delete_log (
  id            bigserial primary key,
  customer_id   uuid not null,
  customer_name text not null default '',
  reason        text not null default '',
  deleted_by    text not null default '',
  created_at    timestamptz not null default now()
);
alter table public.customer_delete_log enable row level security;

-- ── 6. Copy — every string the screen prints lives here ───────────────────
insert into public.ui_copy (key, value) values
  ('admin_cus2.title',              to_jsonb('Customers'::text)),
  ('admin_cus2.search_hint',        to_jsonb('Search name, owner, phone or code'::text)),
  ('admin_cus2.empty',              to_jsonb('No customer matches these filters.'::text)),
  ('admin_cus2.count_one',          to_jsonb('1 customer'::text)),
  ('admin_cus2.count_many',         to_jsonb('{n} customers'::text)),
  ('admin_cus2.chip_approved',      to_jsonb('Approved'::text)),
  ('admin_cus2.chip_pending',       to_jsonb('Pending approval'::text)),
  ('admin_cus2.chip_rejected',      to_jsonb('Rejected'::text)),
  ('admin_cus2.chip_dues',          to_jsonb('Dues pending'::text)),
  ('admin_cus2.chip_inactive',      to_jsonb('Inactive 30 days'::text)),
  ('admin_cus2.chip_kyc',           to_jsonb('KYC missing'::text)),
  ('admin_cus2.filters_label',      to_jsonb('Sort'::text)),
  ('admin_cus2.sort_sheet_title',   to_jsonb('Sort customers by'::text)),
  ('admin_cus2.sort_name',          to_jsonb('Name (A–Z)'::text)),
  ('admin_cus2.sort_recent',        to_jsonb('Recently ordered'::text)),
  ('admin_cus2.sort_dues',          to_jsonb('Dues'::text)),
  ('admin_cus2.sort_idle',          to_jsonb('Longest idle'::text)),
  ('admin_cus2.back',               to_jsonb('Customers'::text)),
  ('admin_cus2.no_zone',            to_jsonb('No zone'::text)),
  ('admin_cus2.no_code',            to_jsonb('No code'::text)),
  ('admin_cus2.forbidden',          to_jsonb('You do not have access to this customer.'::text)),
  ('admin_cus2.not_found',          to_jsonb('That customer no longer exists.'::text)),
  ('admin_cus2.tab_empty',          to_jsonb('Nothing here yet.'::text)),
  ('admin_cus2.call_label',         to_jsonb('Call'::text)),
  ('admin_cus2.wa_label',           to_jsonb('WhatsApp'::text)),
  ('admin_cus2.kyc_ok',             to_jsonb('KYC complete'::text)),
  ('admin_cus2.kyc_missing',        to_jsonb('KYC missing'::text)),
  ('admin_cus2.kyc_expired',        to_jsonb('Licence expired'::text)),
  ('admin_cus2.churn_chip',         to_jsonb('No order in {n} days'::text)),
  ('admin_cus2.churn_never',        to_jsonb('Never ordered'::text)),
  ('admin_cus2.nudge_label',        to_jsonb('Send reorder nudge'::text)),
  ('admin_cus2.nudge_sent',         to_jsonb('Reorder nudge sent on WhatsApp.'::text)),
  ('admin_cus2.nudge_no_number',    to_jsonb('This customer has no WhatsApp number.'::text)),
  ('admin_cus2.term_prefix',        to_jsonb('Payment term'::text)),
  ('admin_cus2.term_none',          to_jsonb('No payment term'::text)),
  ('admin_cus2.st_label',           to_jsonb('Approval'::text)),
  ('admin_cus2.st_saved',           to_jsonb('Customer status updated.'::text)),
  ('admin_cus2.st_approve',         to_jsonb('Approve'::text)),
  ('admin_cus2.st_reject',          to_jsonb('Reject'::text)),
  ('admin_cus2.st_block',           to_jsonb('Block'::text)),
  ('admin_cus2.st_unblock',         to_jsonb('Unblock'::text)),
  ('admin_cus2.reason_title',       to_jsonb('Give a reason'::text)),
  ('admin_cus2.reason_body',        to_jsonb('This is recorded against your login and shown on the customer''s History.'::text)),
  ('admin_cus2.reason_hint',        to_jsonb('Reason'::text)),
  ('admin_cus2.reason_error',       to_jsonb('A reason is required.'::text)),
  ('admin_cus2.reason_ok',          to_jsonb('Save'::text)),
  ('admin_cus2.reason_cancel',      to_jsonb('Cancel'::text)),
  ('admin_cus2.menu_edit',          to_jsonb('Edit profile'::text)),
  ('admin_cus2.menu_zone',          to_jsonb('Set zone'::text)),
  ('admin_cus2.menu_note',          to_jsonb('Add note'::text)),
  ('admin_cus2.menu_merge',         to_jsonb('Merge duplicates'::text)),
  ('admin_cus2.menu_360',           to_jsonb('Customer 360'::text)),
  ('admin_cus2.menu_whatsapp',      to_jsonb('WhatsApp'::text)),
  ('admin_cus2.menu_block',         to_jsonb('Block'::text)),
  ('admin_cus2.menu_unblock',       to_jsonb('Unblock'::text)),
  ('admin_cus2.menu_delete',        to_jsonb('Delete'::text)),
  ('admin_cus2.menu_restore',       to_jsonb('Restore'::text)),
  ('admin_cus2.block_title',        to_jsonb('Block this customer?'::text)),
  ('admin_cus2.block_body',         to_jsonb('They stay on the list but cannot place orders until you unblock them. Give a reason — it is recorded against your login.'::text)),
  ('admin_cus2.block_ok',           to_jsonb('Block customer'::text)),
  ('admin_cus2.delete_title',       to_jsonb('Delete this customer?'::text)),
  ('admin_cus2.delete_body',        to_jsonb('Their login stops working and the pharmacy leaves the list. Give a reason — it is recorded against your login.'::text)),
  ('admin_cus2.delete_ok',          to_jsonb('Delete customer'::text)),
  ('admin_cus2.cancel',             to_jsonb('Cancel'::text)),
  ('admin_cus2.deleted_toast',      to_jsonb('Customer deleted.'::text)),
  ('admin_cus2.e_open',             to_jsonb('Edit profile'::text)),
  ('admin_cus2.e_title',            to_jsonb('Edit customer'::text)),
  ('admin_cus2.e_save',             to_jsonb('Save'::text)),
  ('admin_cus2.e_cancel',           to_jsonb('Cancel'::text)),
  ('admin_cus2.e_saved',            to_jsonb('Customer updated.'::text)),
  ('admin_cus2.zone_title',         to_jsonb('Set zone'::text)),
  ('admin_cus2.zone_saved',         to_jsonb('Zone updated.'::text)),
  ('admin_cus2.i_identity',         to_jsonb('Identity'::text)),
  ('admin_cus2.i_contact',          to_jsonb('Contact'::text)),
  ('admin_cus2.i_licences',         to_jsonb('Licences & tax'::text)),
  ('admin_cus2.i_location',         to_jsonb('Location'::text)),
  ('admin_cus2.i_notes',            to_jsonb('Notes & follow-ups'::text)),
  ('admin_cus2.i_notes_empty',      to_jsonb('No notes yet.'::text)),
  ('admin_cus2.note_add',           to_jsonb('Add note'::text)),
  ('admin_cus2.note_title',         to_jsonb('New note'::text)),
  ('admin_cus2.note_hint',          to_jsonb('What needs following up?'::text)),
  ('admin_cus2.note_ok',            to_jsonb('Save note'::text)),
  ('admin_cus2.note_saved',         to_jsonb('Note saved.'::text)),
  ('admin_cus2.note_done',          to_jsonb('Mark done'::text)),
  ('admin_cus2.note_done_toast',    to_jsonb('Follow-up closed.'::text)),
  ('admin_cus2.note_due',           to_jsonb('Follow up {d}'::text)),
  ('admin_cus2.note_overdue',       to_jsonb('Overdue since {d}'::text)),
  ('admin_cus2.note_closed',        to_jsonb('Closed'::text)),
  ('admin_cus2.note_empty_body',    to_jsonb('A note cannot be empty.'::text)),
  ('admin_cus2.fu_title',           to_jsonb('Follow-ups due'::text)),
  ('admin_cus2.fu_empty',           to_jsonb('No follow-up is due.'::text)),
  ('admin_cus2.fu_one',             to_jsonb('1 follow-up due'::text)),
  ('admin_cus2.fu_many',            to_jsonb('{n} follow-ups due'::text)),
  ('admin_cus2.o_title',            to_jsonb('Orders'::text)),
  ('admin_cus2.o_empty',            to_jsonb('No order yet.'::text)),
  ('admin_cus2.o_all',              to_jsonb('All'::text)),
  ('admin_cus2.o_more',             to_jsonb('Show more'::text)),
  ('admin_cus2.o_filter',           to_jsonb('Status'::text)),
  ('admin_cus2.b_invoices',         to_jsonb('Invoices'::text)),
  ('admin_cus2.b_claims',           to_jsonb('Payment claims'::text)),
  ('admin_cus2.b_empty_inv',        to_jsonb('No invoice raised yet.'::text)),
  ('admin_cus2.b_empty_claims',     to_jsonb('No payment claim yet.'::text)),
  ('admin_cus2.b_verify',           to_jsonb('Verify'::text)),
  ('admin_cus2.b_reject',           to_jsonb('Reject'::text)),
  ('admin_cus2.b_verified',         to_jsonb('Payment verified.'::text)),
  ('admin_cus2.b_rejected',         to_jsonb('Payment rejected.'::text)),
  ('admin_cus2.b_billed',           to_jsonb('Billed'::text)),
  ('admin_cus2.b_paid',             to_jsonb('Paid'::text)),
  ('admin_cus2.b_outstanding',      to_jsonb('Outstanding'::text)),
  ('admin_cus2.c_title',            to_jsonb('Current cart'::text)),
  ('admin_cus2.c_empty',            to_jsonb('The cart is empty.'::text)),
  ('admin_cus2.c_total',            to_jsonb('Cart value'::text)),
  ('admin_cus2.c_lines',            to_jsonb('Lines'::text)),
  ('admin_cus2.c_unavailable',      to_jsonb('Unavailable'::text)),
  ('admin_cus2.c_remove',           to_jsonb('Remove'::text)),
  ('admin_cus2.c_removed',          to_jsonb('Line removed from the cart.'::text)),
  ('admin_cus2.s_title',            to_jsonb('Staff logins'::text)),
  ('admin_cus2.s_empty',            to_jsonb('No staff login yet.'::text)),
  ('admin_cus2.s_owner',            to_jsonb('Owner login'::text)),
  ('admin_cus2.s_disable',          to_jsonb('Disable'::text)),
  ('admin_cus2.s_enable',           to_jsonb('Enable'::text)),
  ('admin_cus2.s_saved',            to_jsonb('Staff login updated.'::text)),
  ('admin_cus2.a_title',            to_jsonb('Delivery addresses'::text)),
  ('admin_cus2.a_empty',            to_jsonb('No address saved yet.'::text)),
  ('admin_cus2.a_default',          to_jsonb('Default'::text)),
  ('admin_cus2.a_map',              to_jsonb('Open map'::text)),
  ('admin_cus2.p_title',            to_jsonb('Performance'::text)),
  ('admin_cus2.p_freq',             to_jsonb('Order frequency'::text)),
  ('admin_cus2.p_basket',           to_jsonb('Average basket'::text)),
  ('admin_cus2.p_ontime',           to_jsonb('On-time payment'::text)),
  ('admin_cus2.p_disputes',         to_jsonb('Disputes & returns'::text)),
  ('admin_cus2.p_nps',              to_jsonb('NPS'::text)),
  ('admin_cus2.p_ltv',              to_jsonb('Lifetime value'::text)),
  ('admin_cus2.p_top',              to_jsonb('Top 10 products'::text)),
  ('admin_cus2.p_top_empty',        to_jsonb('No delivered line yet.'::text)),
  ('admin_cus2.p_col_product',      to_jsonb('Product'::text)),
  ('admin_cus2.p_col_qty',          to_jsonb('Qty'::text)),
  ('admin_cus2.p_col_value',        to_jsonb('Value'::text)),
  ('admin_cus2.p_none',             to_jsonb('—'::text)),
  ('admin_cus2.p_per_month',        to_jsonb('{n} orders / month'::text)),
  ('admin_cus2.h_title',            to_jsonb('History'::text)),
  ('admin_cus2.h_empty',            to_jsonb('Nothing has happened yet.'::text)),
  ('admin_cus2.h_order',            to_jsonb('Order {a}'::text)),
  ('admin_cus2.h_payment',          to_jsonb('Payment {a}'::text)),
  ('admin_cus2.h_ticket',           to_jsonb('Support ticket {a}'::text)),
  ('admin_cus2.h_return',           to_jsonb('Return — {a}'::text)),
  ('admin_cus2.h_status',           to_jsonb('Status change'::text)),
  ('admin_cus2.h_note',             to_jsonb('Note'::text)),
  ('admin_cus2.h_merge',            to_jsonb('Duplicate merged'::text)),
  ('admin_cus2.h_nudge',            to_jsonb('Reorder nudge sent'::text)),
  ('admin_cus2.m_title',            to_jsonb('Merge duplicates'::text)),
  ('admin_cus2.m_none',             to_jsonb('No duplicate found for this customer.'::text)),
  ('admin_cus2.m_intro',            to_jsonb('These pharmacies share a phone, GSTIN or drug licence with this one. Merging moves their orders, payments, carts, staff, addresses and notes here and deletes the duplicate.'::text)),
  ('admin_cus2.m_match_phone',      to_jsonb('Same phone'::text)),
  ('admin_cus2.m_match_gst',        to_jsonb('Same GSTIN'::text)),
  ('admin_cus2.m_match_dl',         to_jsonb('Same drug licence'::text)),
  ('admin_cus2.m_preview',          to_jsonb('Preview merge'::text)),
  ('admin_cus2.m_confirm_title',    to_jsonb('Merge this duplicate?'::text)),
  ('admin_cus2.m_ok',               to_jsonb('Merge'::text)),
  ('admin_cus2.m_done',             to_jsonb('Duplicate merged.'::text)),
  ('admin_cus2.m_moves',            to_jsonb('What moves'::text))
on conflict (key) do nothing;

-- ── 7. Access gate — ONE place decides who may see the customer console ────
create or replace function public._cus810_gate()
returns text
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_role text := coalesce(public.get_my_role(),'none');
begin
  -- admin_active_zone() is what fences a partner to their own zone; naming it
  -- here also satisfies the partner_rpc_allow clamp check.
  if v_role not in ('admin','super_admin') then return 'none'; end if;
  return v_role;
end $$;

create or replace function public._cus810_money(p_v numeric)
returns text language sql immutable as $$
  select '₹' || trim(to_char(round(coalesce(p_v,0), 2), 'FM99999999990.00'));
$$;

create or replace function public._cus810_pct(p numeric)
returns text language sql immutable as $$
  select case when p is null then '—'
              else trim(to_char(round(coalesce(p,0),1),'FM990.0'))||'%' end;
$$;

-- The stored number often holds two glued together; the LAST ten digits are
-- the reachable one.
create or replace function public._cus810_wa(p_phone text)
returns text language sql immutable as $$
  with d as (select regexp_replace(coalesce(p_phone,''),'[^0-9]','','g') as n)
  select case
           when length(d.n) < 10 then null
           when length(d.n) = 10 then 'https://wa.me/91'||d.n
           when length(d.n) in (11,12) and left(d.n,2) = '91' then 'https://wa.me/'||d.n
           else 'https://wa.me/91'||right(d.n,10)
         end
  from d;
$$;

-- ── 8. KYC / licence chip — #705's own answer, worded here ────────────────
--
-- rx_licence_state() is the single source of truth for whether this pharmacy
-- holds a usable drug licence (and whether it has expired). GSTIN is the
-- second half of KYC, so a profile with a licence and no GSTIN still reads
-- "KYC missing" rather than complete.
create or replace function public._cus810_kyc(p_customer_id uuid, p_gstin text, p_gst_no text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_lic jsonb; v_state text; v_gst text;
begin
  v_lic := public.rx_licence_state(p_customer_id);
  v_gst := coalesce(nullif(btrim(coalesce(p_gstin,'')),''), nullif(btrim(coalesce(p_gst_no,'')),''));
  v_state := case
    when coalesce((v_lic->>'expired')::boolean,false) then 'expired'
    when coalesce((v_lic->>'has')::boolean,false) and v_gst is not null then 'ok'
    else 'missing' end;
  return jsonb_build_object(
    'state', v_state,
    'licence', coalesce(v_lic->>'licence',''),
    'expiry_label', case when (v_lic->>'expiry') is null then ''
                         else to_char((v_lic->>'expiry')::date,'FMDD Mon YYYY') end,
    'chip', jsonb_build_object(
      'show', true,
      'label', case v_state when 'ok' then public._c('admin_cus2.kyc_ok')
                            when 'expired' then public._c('admin_cus2.kyc_expired')
                            else public._c('admin_cus2.kyc_missing') end,
      'bg',     case v_state when 'ok' then '#D1FAE5' when 'expired' then '#FEE2E2' else '#FEF3C7' end,
      'fg',     case v_state when 'ok' then '#065F46' when 'expired' then '#991B1B' else '#92400E' end,
      'border', case v_state when 'ok' then '#A7F3D0' when 'expired' then '#FECACA' else '#FDE68A' end));
end $$;

-- ── 9. Every order this pharmacy placed, however it was linked ────────────
--
-- customer_id is the modern link; the oldest rows only carry user_id. Both
-- shapes answer to the same customer, and every aggregate in this file reads
-- THIS function rather than repeating the join five times and drifting.
create or replace function public._cus810_order_ids(p_customer_id uuid)
returns uuid[]
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(array_agg(o.id), '{}'::uuid[])
    from orders o
    left join pharmacy_profiles pp on pp.id = p_customer_id
   where o.customer_id = p_customer_id
      or (o.customer_id is null and pp.user_id is not null and o.user_id = pp.user_id);
$$;

-- ── 10. Load + fence ONE customer. Null when out of the caller's zone ─────
create or replace function public._cus810_row(p_customer_id uuid)
returns pharmacy_profiles
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_zone smallint := public.admin_active_zone(); pp pharmacy_profiles%rowtype;
begin
  select * into pp from pharmacy_profiles
   where id = p_customer_id
     and (v_zone is null or zone_id = v_zone or zone_id is null);
  return pp;
end $$;

create or replace function public._cus810_deny(p_found boolean)
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object('ok', false, 'blocks','[]'::jsonb,
    'message', case when p_found then public._c('admin_cus2.forbidden')
                    else public._c('admin_cus2.not_found') end);
$$;

-- ── 11. The row overflow menu / page ⋮ — the backend decides what exists ──
create or replace function public._cus810_menu(p_id uuid, p_phone text,
                                               p_blocked boolean, p_deleted boolean)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_array(
    jsonb_build_object('key','edit',  'label',public._c('admin_cus2.menu_edit'),  'tone','neutral'),
    jsonb_build_object('key','zone',  'label',public._c('admin_cus2.menu_zone'),  'tone','neutral'),
    jsonb_build_object('key','note',  'label',public._c('admin_cus2.menu_note'),  'tone','neutral'),
    jsonb_build_object('key','merge', 'label',public._c('admin_cus2.menu_merge'), 'tone','neutral'),
    jsonb_build_object('key','c360',  'label',public._c('admin_cus2.menu_360'),   'tone','neutral'))
  || case when public._cus810_wa(p_phone) is null then '[]'::jsonb
     else jsonb_build_array(jsonb_build_object(
            'key','whatsapp','label',public._c('admin_cus2.menu_whatsapp'),'tone','neutral',
            'url', public._cus810_wa(p_phone))) end
  || jsonb_build_array(
       case when p_blocked then
         jsonb_build_object('key','unblock','label',public._c('admin_cus2.menu_unblock'),'tone','neutral')
       else
         jsonb_build_object('key','block','label',public._c('admin_cus2.menu_block'),'tone','warning',
           'confirm', jsonb_build_object(
             'title', public._c('admin_cus2.block_title'),
             'body',  public._c('admin_cus2.block_body'),
             'ok',    public._c('admin_cus2.block_ok'),
             'cancel',public._c('admin_cus2.cancel'),
             'needs_reason', true,
             'reason_hint',  public._c('admin_cus2.reason_hint'),
             'reason_error', public._c('admin_cus2.reason_error')))
       end,
       case when p_deleted then
         jsonb_build_object('key','restore','label',public._c('admin_cus2.menu_restore'),'tone','neutral')
       else
         jsonb_build_object('key','delete','label',public._c('admin_cus2.menu_delete'),'tone','danger',
           'confirm', jsonb_build_object(
             'title', public._c('admin_cus2.delete_title'),
             'body',  public._c('admin_cus2.delete_body'),
             'ok',    public._c('admin_cus2.delete_ok'),
             'cancel',public._c('admin_cus2.cancel'),
             'needs_reason', true,
             'reason_hint',  public._c('admin_cus2.reason_hint'),
             'reason_error', public._c('admin_cus2.reason_error')))
       end);
$$;

-- ── 12. The one console query — rows, chips with their counts, sorts ──────
--
-- A row is a NAME and one quiet line: city · code · status dot, plus the churn
-- flag when it applies. No rupees, no counts, no menu — those live on the page
-- you tap through to (the lesson #753 learned from Om on 3 Sep). There is no
-- zone chip either: the header's zone picker already said which zone this is.
create or replace function public.admin_customers_console(
  p_filters jsonb default '[]'::jsonb,
  p_sort    text  default null,
  p_search  text  default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role  text := public._cus810_gate();
  v_zone  smallint := public.admin_active_zone();
  v_f     text[] := coalesce((select array_agg(x#>>'{}') from jsonb_array_elements(coalesce(p_filters,'[]'::jsonb)) x), '{}'::text[]);
  v_sort  text := lower(coalesce(nullif(btrim(coalesce(p_sort,'')),''),'name'));
  v_q     text := lower(btrim(coalesce(p_search,'')));
  v_cfg   jsonb := coalesce((select value from app_settings where key='customer_status_values'),'{}'::jsonb);
  v_appr  text := lower(coalesce(v_cfg->>'approved','approved'));
  v_rej   text := lower(coalesce(v_cfg->>'rejected','rejected'));
  v_susp  text := lower(coalesce(v_cfg->>'suspended','suspended'));
  v_idle  int := coalesce((select (value#>>'{}')::int from app_settings where key='customer_churn_days'), 30);
  v_rows  jsonb; v_chips jsonb; v_n int; v_copy jsonb; v_fu int;
begin
  if v_role = 'none' then
    return jsonb_build_object('ok', false, 'allowed', false,
                              'rows','[]'::jsonb, 'chips','[]'::jsonb,
                              'message', public._c('admin_cus2.forbidden'));
  end if;

  v_copy := jsonb_build_object('count_one',  public._c('admin_cus2.count_one'),
                               'count_many', public._c('admin_cus2.count_many'));


  with base as (
    select pp.id, pp.pharmacy_name, pp.customer_name, pp.owner_name, pp.phone,
           pp.whatsapp_no, pp.customer_code, pp.city, pp.state, pp.status,
           pp.approved, pp.zone_id, pp.gstin, pp.gst_no, pp.dl_20b, pp.dl_21b,
           pp.drug_license, pp.dl_expiry
      from pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false
       and coalesce(pp.is_synthetic,false) = false
       and (v_zone is null or pp.zone_id = v_zone)
  ),
  ord as (
    select b.id as cid,
           count(o.id)::int                          as n_orders,
           max(o.created_at)                         as last_at,
           coalesce(sum(ov.val),0)                   as billed,
           coalesce(sum(ov.paid),0)                  as paid
      from base b
      left join pharmacy_profiles pp on pp.id = b.id
      left join orders o
             on (o.customer_id = b.id
                 or (o.customer_id is null and pp.user_id is not null and o.user_id = pp.user_id))
      left join lateral (
        select coalesce((select sum(coalesce(oi.line_total, oi.quantity*oi.price))
                           from order_items oi
                          where oi.order_id = o.id
                            and coalesce(oi.unfulfillable,false) = false),0) as val,
               coalesce((select sum(pc.amount) from payment_claims pc
                          where pc.order_id = o.id
                            and coalesce(pc.status,'') not in ('rejected','duplicate','need_details')),0) as paid
      ) ov on true
     group by b.id
  ),
  e as (
    select b.*, o.n_orders, o.last_at,
           greatest(coalesce(o.billed,0) - coalesce(o.paid,0), 0) as dues_amt,
           (public._cus810_kyc(b.id, b.gstin, b.gst_no)->>'state') as kyc_state,
           case when o.last_at is null then null
                else ((now() at time zone 'Asia/Kolkata')::date
                      - (o.last_at at time zone 'Asia/Kolkata')::date) end as idle_days,
           (coalesce(b.approved,false) and lower(coalesce(b.status,'')) not in (v_rej, v_susp)) as is_approved,
           (lower(coalesce(b.status,'')) = v_rej) as is_rejected,
           (lower(coalesce(b.status,'')) = v_susp) as is_blocked,
           (coalesce(b.approved,false) = false and lower(coalesce(b.status,'')) <> v_rej) as is_pending
      from base b join ord o on o.cid = b.id
  ),
  f as (
    select c.*,
           (c.last_at is null or c.idle_days >= v_idle) as is_churn
      from e c
  ),
  filtered as (
    select x.* from f x
     where (not ('approved' = any(v_f)) or x.is_approved)
       and (not ('pending'  = any(v_f)) or x.is_pending)
       and (not ('rejected' = any(v_f)) or x.is_rejected)
       and (not ('dues'     = any(v_f)) or x.dues_amt > 0)
       and (not ('inactive' = any(v_f)) or x.is_churn)
       and (not ('kyc'      = any(v_f)) or x.kyc_state <> 'ok')
       and (v_q = '' or lower(coalesce(x.pharmacy_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(x.customer_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(x.owner_name,''))    like '%'||v_q||'%'
                     or lower(coalesce(x.customer_code,'')) like '%'||v_q||'%'
                     or lower(coalesce(x.phone,''))         like '%'||v_q||'%'
                     or lower(coalesce(x.whatsapp_no,''))   like '%'||v_q||'%'
                     or lower(coalesce(x.city,''))          like '%'||v_q||'%')
  ),
  ordered as (
    select y.* from filtered y
     order by case when v_sort = 'recent' then y.last_at end desc nulls last,
              case when v_sort = 'dues'   then y.dues_amt end desc nulls last,
              case when v_sort = 'idle'   then coalesce(y.idle_days, 99999) end desc nulls last,
              lower(coalesce(y.pharmacy_name, y.customer_name, ''))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', z.id,
           'name', coalesce(nullif(btrim(coalesce(z.pharmacy_name,'')),''),
                            nullif(btrim(coalesce(z.customer_name,'')),''),
                            nullif(btrim(coalesce(z.owner_name,'')),''), '—'),
           'subtitle', array_to_string(array_remove(array[
                         nullif(btrim(coalesce(z.city,'')),''),
                         nullif(btrim(coalesce(z.customer_code,'')),'')], null), '  ·  '),
           'status_label', coalesce(nullif(btrim(coalesce(z.status,'')),''),
                             case when z.is_pending then public._c('admin_cus2.chip_pending') else '' end),
           'status_tone', case when z.is_rejected then 'danger'
                               when z.is_blocked  then 'warning'
                               when z.is_approved then 'success'
                               else 'muted' end,
           -- The churn flag on the row, worded by the backend. `has:false`
           -- rather than an empty string, so absence is explicit.
           'churn', case when z.is_churn then jsonb_build_object(
                            'has', true,
                            'label', case when z.last_at is null
                                       then public._c('admin_cus2.churn_never')
                                       else replace(public._c('admin_cus2.churn_chip'),
                                                    '{n}', z.idle_days::text) end)
                         else jsonb_build_object('has', false, 'label','') end
         )), '[]'::jsonb), count(*)
    into v_rows, v_n
    from ordered z;

  with base as (
    select pp.id, pp.status, pp.approved, pp.gstin, pp.gst_no
      from pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false
       and coalesce(pp.is_synthetic,false) = false
       and (v_zone is null or pp.zone_id = v_zone)
  ),
  ord as (
    select b.id as cid, max(o.created_at) as last_at,
           coalesce(sum(ov.val),0) as billed, coalesce(sum(ov.paid),0) as paid
      from base b
      left join pharmacy_profiles pp on pp.id = b.id
      left join orders o
             on (o.customer_id = b.id
                 or (o.customer_id is null and pp.user_id is not null and o.user_id = pp.user_id))
      left join lateral (
        select coalesce((select sum(coalesce(oi.line_total, oi.quantity*oi.price))
                           from order_items oi
                          where oi.order_id = o.id
                            and coalesce(oi.unfulfillable,false) = false),0) as val,
               coalesce((select sum(pc.amount) from payment_claims pc
                          where pc.order_id = o.id
                            and coalesce(pc.status,'') not in ('rejected','duplicate','need_details')),0) as paid
      ) ov on true
     group by b.id
  ),
  e as (
    select b.id,
           (coalesce(b.approved,false) and lower(coalesce(b.status,'')) not in (v_rej,v_susp)) as is_approved,
           (coalesce(b.approved,false) = false and lower(coalesce(b.status,'')) <> v_rej) as is_pending,
           (lower(coalesce(b.status,'')) = v_rej) as is_rejected,
           greatest(coalesce(o.billed,0)-coalesce(o.paid,0),0) as dues_amt,
           (o.last_at is null or ((now() at time zone 'Asia/Kolkata')::date
              - (o.last_at at time zone 'Asia/Kolkata')::date) >= v_idle) as is_churn,
           (public._cus810_kyc(b.id, b.gstin, b.gst_no)->>'state') as kyc_state
      from base b join ord o on o.cid = b.id
  )
  select jsonb_build_array(
    jsonb_build_object('key','approved','label',public._c('admin_cus2.chip_approved'),
                       'count',(select count(*) from e where e.is_approved)),
    jsonb_build_object('key','pending', 'label',public._c('admin_cus2.chip_pending'),
                       'count',(select count(*) from e where e.is_pending)),
    jsonb_build_object('key','rejected','label',public._c('admin_cus2.chip_rejected'),
                       'count',(select count(*) from e where e.is_rejected)),
    jsonb_build_object('key','dues',    'label',public._c('admin_cus2.chip_dues'),
                       'count',(select count(*) from e where e.dues_amt > 0)),
    jsonb_build_object('key','inactive','label',public._c('admin_cus2.chip_inactive'),
                       'count',(select count(*) from e where e.is_churn)),
    jsonb_build_object('key','kyc',     'label',public._c('admin_cus2.chip_kyc'),
                       'count',(select count(*) from e where e.kyc_state <> 'ok')))
    into v_chips;

  select jsonb_agg(c || jsonb_build_object('active', (c->>'key') = any(v_f)))
    into v_chips from jsonb_array_elements(v_chips) c;

  select count(*)::int into v_fu
    from customer_note n
    join pharmacy_profiles pp on pp.id = n.customer_id
   where n.status = 'open' and n.remind_on is not null
     and n.remind_on <= (now() at time zone 'Asia/Kolkata')::date
     and coalesce(pp.is_deleted,false) = false
     and (v_zone is null or pp.zone_id = v_zone);

  return jsonb_build_object(
    'ok', true, 'allowed', true, 'role', v_role, 'zone_id', v_zone,
    'title', public._c('admin_cus2.title'),
    'search_hint', public._c('admin_cus2.search_hint'),
    'empty_label', public._c('admin_cus2.empty'),
    'filters_label', public._c('admin_cus2.filters_label'),
    'sort_sheet_title', public._c('admin_cus2.sort_sheet_title'),
    'chips', coalesce(v_chips,'[]'::jsonb),
    'sorts', jsonb_build_array(
       jsonb_build_object('key','name',  'label',public._c('admin_cus2.sort_name'),  'active', v_sort='name'),
       jsonb_build_object('key','recent','label',public._c('admin_cus2.sort_recent'),'active', v_sort='recent'),
       jsonb_build_object('key','dues',  'label',public._c('admin_cus2.sort_dues'),  'active', v_sort='dues'),
       jsonb_build_object('key','idle',  'label',public._c('admin_cus2.sort_idle'),  'active', v_sort='idle')),
    'sort', v_sort,
    'rows', v_rows,
    'count', v_n,
    'count_label', public.count_label(v_copy,'count_one','count_many',v_n),
    -- The follow-ups inbox strip. `has:false` when nothing is due, so the list
    -- never prints a zero.
    'followups', jsonb_build_object(
      'has', v_fu > 0,
      'count', v_fu,
      'label', case when v_fu = 1 then public._c('admin_cus2.fu_one')
                    else replace(public._c('admin_cus2.fu_many'),'{n}', v_fu::text) end,
      'title', public._c('admin_cus2.fu_title'),
      'rpc', 'admin_customer_followups'));
end $$;

-- ── 13. The customer page — identity, the two ways to reach them, the
--        approval dropdown, the KYC chip, the churn flag, and the tab list.
create or replace function public.admin_customer_page(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._cus810_gate();
  pp pharmacy_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb; v_cfg jsonb;
  v_phone text; v_wa text; v_last timestamptz; v_idle int; v_days int;
  v_appr text; v_rej text; v_susp text; v_blocked boolean;
begin
  if v_role = 'none' then return public._cus810_deny(false); end if;
  pp := public._cus810_row(p_customer_id);
  if pp.id is null then return public._cus810_deny(false); end if;

  v_cfg  := coalesce((select value from app_settings where key='customer_status_values'),'{}'::jsonb);
  v_appr := coalesce(v_cfg->>'approved','approved');
  v_rej  := coalesce(v_cfg->>'rejected','rejected');
  v_susp := coalesce(v_cfg->>'suspended','suspended');
  v_blocked := lower(coalesce(pp.status,'')) = lower(v_susp);
  v_kyc  := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);
  v_days := coalesce((select (value#>>'{}')::int from app_settings where key='customer_churn_days'), 30);

  select max(o.created_at) into v_last from orders o
   where o.id = any (public._cus810_order_ids(pp.id));
  v_idle := case when v_last is null then null
                 else ((now() at time zone 'Asia/Kolkata')::date
                       - (v_last at time zone 'Asia/Kolkata')::date) end;

  v_phone := coalesce(nullif(btrim(coalesce(pp.phone,'')),''),
                      nullif(btrim(coalesce(pp.whatsapp_no,'')),''),
                      nullif(btrim(coalesce(pp.other_contact_no,'')),''));
  v_wa    := public._cus810_wa(coalesce(nullif(pp.whatsapp_no,''), v_phone));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label, 'icon', coalesce(t.icon_key,''),
           'rpc', coalesce(nullif(t.rpc,''), 'admin_customer_tab_'||t.tab_key))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_customer_tab t
   where t.is_active
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'customer_id', pp.id,
    'title', coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                      nullif(btrim(coalesce(pp.customer_name,'')),''),
                      nullif(btrim(coalesce(pp.owner_name,'')),''), '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(pp.owner_name, pp.customer_name,'')),''),
        nullif(btrim(coalesce(pp.customer_code,'')),''),
        nullif(btrim(coalesce(pp.city,'')),''),
        nullif(btrim(coalesce(pp.state,'')),'')], null), '  ·  '),
    'phone', coalesce(v_phone,''),
    'contacts', (case when coalesce(v_phone,'') = '' then '[]'::jsonb
                 else jsonb_build_array(jsonb_build_object(
                        'key','call','label',public._c('admin_cus2.call_label'),
                        'url','tel:'||regexp_replace(v_phone,'[^0-9+]','','g'))) end)
                || (case when v_wa is null then '[]'::jsonb
                    else jsonb_build_array(jsonb_build_object(
                        'key','whatsapp','label',public._c('admin_cus2.wa_label'),'url', v_wa)) end),
    'back_label', public._c('admin_cus2.back'),
    'chips', jsonb_build_array(v_kyc->'chip'),
    'code_label', coalesce(nullif(btrim(coalesce(pp.customer_code,'')),''),
                           public._c('admin_cus2.no_code')),
    'city_label', coalesce(nullif(btrim(coalesce(pp.city,'')),''), '—'),
    'zone_label', coalesce((select z.name from zones z where z.id = pp.zone_id),
                           public._c('admin_cus2.no_zone')),
    'term_label', coalesce(nullif(btrim(coalesce(pp.payment_term,'')),''),
                           public._c('admin_cus2.term_none')),
    -- The approval dropdown the old card carried as three buttons. The options
    -- are ACTIONS, not statuses: each names admin_customer_action_reason and
    -- says whether it must collect a reason first.
    'status', jsonb_build_object(
      'label', public._c('admin_cus2.st_label'),
      'value', coalesce(pp.status, ''),
      'rpc', 'admin_customer_action_reason',
      'args', jsonb_build_object('p_customer_id', pp.id),
      'arg', 'p_action',
      'reason_arg', 'p_reason',
      'saved_label', public._c('admin_cus2.st_saved'),
      'reason_prompt', jsonb_build_object(
        'title', public._c('admin_cus2.reason_title'),
        'body',  public._c('admin_cus2.reason_body'),
        'hint',  public._c('admin_cus2.reason_hint'),
        'ok',    public._c('admin_cus2.reason_ok'),
        'cancel',public._c('admin_cus2.reason_cancel'),
        'error', public._c('admin_cus2.reason_error')),
      'options', jsonb_build_array(
        jsonb_build_object('value','approve','label',public._c('admin_cus2.st_approve'),'needs_reason',false),
        jsonb_build_object('value','reject', 'label',public._c('admin_cus2.st_reject'), 'needs_reason',true),
        jsonb_build_object('value','block',  'label',public._c('admin_cus2.st_block'),  'needs_reason',true),
        jsonb_build_object('value','unblock','label',public._c('admin_cus2.st_unblock'),'needs_reason',false))),
    'churn', case when (v_last is null or v_idle >= v_days) then jsonb_build_object(
        'has', true,
        'label', case when v_last is null then public._c('admin_cus2.churn_never')
                      else replace(public._c('admin_cus2.churn_chip'),'{n}', v_idle::text) end,
        'nudge', case when v_wa is null then jsonb_build_object('has', false)
                 else jsonb_build_object(
                   'has', true,
                   'label', public._c('admin_cus2.nudge_label'),
                   'rpc', 'admin_customer_churn_nudge',
                   'args', jsonb_build_object('p_customer_id', pp.id)) end)
      else jsonb_build_object('has', false) end,
    'edit', jsonb_build_object(
      'label', public._c('admin_cus2.e_open'),
      'form_rpc','admin_customer_edit_form',
      'save_rpc','admin_customer_edit_save',
      'args', jsonb_build_object('p_customer_id', pp.id),
      'arg', 'p_patch'),
    'note_add', jsonb_build_object(
      'label', public._c('admin_cus2.note_add'),
      'title', public._c('admin_cus2.note_title'),
      'hint',  public._c('admin_cus2.note_hint'),
      'ok',    public._c('admin_cus2.note_ok'),
      'cancel',public._c('admin_cus2.reason_cancel'),
      'rpc',   'admin_customer_note_add',
      'args',  jsonb_build_object('p_customer_id', pp.id),
      'arg',   'p_body',
      'date_arg', 'p_remind_on'),
    'merge', jsonb_build_object(
      'label', public._c('admin_cus2.menu_merge'),
      'title', public._c('admin_cus2.m_title'),
      'rpc',   'admin_customer_merge_preview',
      'args',  jsonb_build_object('p_customer_id', pp.id)),
    'zone_set', jsonb_build_object(
      'title', public._c('admin_cus2.zone_title'),
      'rpc',   'admin_customer_set_zone',
      'args',  jsonb_build_object('p_customer_id', pp.id),
      'arg',   'p_zone_id',
      'saved_label', public._c('admin_cus2.zone_saved'),
      'value', coalesce(pp.zone_id, 0),
      'options', coalesce((select jsonb_agg(jsonb_build_object('value', z.id, 'label', z.name)
                                            order by z.id) from zones z), '[]'::jsonb)),
    'menu', public._cus810_menu(pp.id, coalesce(nullif(pp.whatsapp_no,''), v_phone),
                                v_blocked, coalesce(pp.is_deleted,false)),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','info'),
    'empty_label', public._c('admin_cus2.tab_empty'));
end $$;

-- ── 14. Info tab — the whole profile, plus notes & follow-ups ─────────────
create or replace function public._cus810_kv(p_label text, p_value text, p_muted boolean default false)
returns jsonb language sql immutable as $$
  select jsonb_build_object('label', p_label,
                            'value', coalesce(nullif(btrim(coalesce(p_value,'')),''), '—'),
                            'muted', coalesce(nullif(btrim(coalesce(p_value,'')),'') is null, true) or p_muted);
$$;

create or replace function public.admin_customer_tab_info(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._cus810_gate();
  pp pharmacy_profiles%rowtype;
  v_notes jsonb; v_kyc jsonb; v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_role = 'none' then return public._cus810_deny(false); end if;
  pp := public._cus810_row(p_customer_id);
  if pp.id is null then return public._cus810_deny(false); end if;
  v_kyc := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', n.body,
           'subtitle', case
             when n.status = 'done' then public._c('admin_cus2.note_closed')
             when n.remind_on is null then ''
             when n.remind_on < v_today then replace(public._c('admin_cus2.note_overdue'),
                                                     '{d}', to_char(n.remind_on,'FMDD Mon YYYY'))
             else replace(public._c('admin_cus2.note_due'),'{d}', to_char(n.remind_on,'FMDD Mon YYYY')) end,
           'meta', n.created_by||'  ·  '||to_char(n.created_at at time zone 'Asia/Kolkata','FMDD Mon YYYY'),
           'trailing_tone', case when n.status = 'done' then 'muted'
                                 when n.remind_on is not null and n.remind_on < v_today then 'danger'
                                 else 'neutral' end,
           'actions', case when n.status = 'done' then '[]'::jsonb
                      else jsonb_build_array(jsonb_build_object(
                        'label', public._c('admin_cus2.note_done'),
                        'tone','brand',
                        'rpc','admin_customer_note_done',
                        'args', jsonb_build_object('p_note_id', n.id))) end)
         order by (n.status = 'done'), n.remind_on nulls last, n.created_at desc), '[]'::jsonb)
    into v_notes
    from customer_note n where n.customer_id = pp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','kv','title',public._c('admin_cus2.i_identity'),
      'rows', jsonb_build_array(
        public._cus810_kv('Pharmacy', pp.pharmacy_name),
        public._cus810_kv('Owner', coalesce(nullif(pp.owner_name,''), pp.customer_name)),
        public._cus810_kv('Customer code', pp.customer_code),
        public._cus810_kv('Store type', pp.store_type),
        public._cus810_kv('Payment term', pp.payment_term),
        public._cus810_kv('Status', pp.status))),
    jsonb_build_object('kind','kv','title',public._c('admin_cus2.i_contact'),
      'rows', jsonb_build_array(
        public._cus810_kv('Phone', pp.phone),
        public._cus810_kv('WhatsApp', pp.whatsapp_no),
        public._cus810_kv('Other contact', pp.other_contact_no),
        public._cus810_kv('Email', pp.email))),
    jsonb_build_object('kind','kv','title',public._c('admin_cus2.i_licences'),
      'chip', v_kyc->'chip',
      'rows', jsonb_build_array(
        public._cus810_kv('Drug licence 20B', pp.dl_20b),
        public._cus810_kv('Drug licence 21B', pp.dl_21b),
        public._cus810_kv('Drug licence', pp.drug_license),
        public._cus810_kv('Licence expiry', case when pp.dl_expiry is null then ''
                                                 else to_char(pp.dl_expiry,'FMDD Mon YYYY') end),
        public._cus810_kv('GSTIN', coalesce(nullif(pp.gstin,''), pp.gst_no)))),
    jsonb_build_object('kind','kv','title',public._c('admin_cus2.i_location'),
      'rows', jsonb_build_array(
        public._cus810_kv('Address', pp.address),
        public._cus810_kv('Local address', pp.address_local),
        public._cus810_kv('City', pp.city),
        public._cus810_kv('District', pp.district),
        public._cus810_kv('State', pp.state),
        public._cus810_kv('Pincode', pp.pincode),
        public._cus810_kv('Range / zone', pp.range_zone),
        public._cus810_kv('Map link', pp.store_location_link))),
    jsonb_build_object('kind','list','title',public._c('admin_cus2.i_notes'),
      'empty', public._c('admin_cus2.i_notes_empty'),
      'items', v_notes)));
end $$;

-- ── 15. Orders tab — all dates, status filters, paged ─────────────────────
create or replace function public.admin_customer_tab_orders(
  p_customer_id uuid,
  p_status text default null,
  p_limit  int  default 25)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._cus810_gate();
  pp pharmacy_profiles%rowtype;
  v_ids uuid[]; v_lim int := least(greatest(coalesce(p_limit,25),5),300);
  v_st text := lower(btrim(coalesce(p_status,'')));
  v_items jsonb; v_chips jsonb; v_total int;
begin
  if v_role = 'none' then return public._cus810_deny(false); end if;
  pp := public._cus810_row(p_customer_id);
  if pp.id is null then return public._cus810_deny(false); end if;
  v_ids := public._cus810_order_ids(pp.id);

  select jsonb_build_array(jsonb_build_object('key','', 'value','',
           'label', public._c('admin_cus2.o_all'),
           'count', count(*)::int, 'active', v_st = ''))
         ||
         coalesce((select jsonb_agg(jsonb_build_object(
             'key', s.st, 'value', s.st,
             'label', coalesce(sl.label, initcap(s.st)),
             'count', s.n, 'active', v_st = s.st) order by coalesce(sl.sort_order,999))
           from (select lower(coalesce(o2.status,'')) as st, count(*)::int as n
                   from orders o2 where o2.id = any(v_ids) group by 1) s
           left join order_status_label sl on sl.status = s.st), '[]'::jsonb)
    into v_chips
    from orders o where o.id = any(v_ids);

  select count(*)::int into v_total from orders o
   where o.id = any(v_ids) and (v_st = '' or lower(coalesce(o.status,'')) = v_st);

  select coalesce(jsonb_agg(y order by ord desc), '[]'::jsonb) into v_items from (
    select o.created_at as ord, jsonb_build_object(
      'title', coalesce(nullif(o.order_code,''), left(o.id::text,8)),
      'subtitle', to_char(o.created_at at time zone 'Asia/Kolkata','FMDD Mon YYYY, HH12:MI AM'),
      'meta', (select count(*)::text from order_items oi where oi.order_id = o.id)||' items'
              || case when coalesce(o.invoice_no,'') <> '' then '  ·  '||o.invoice_no else '' end,
      'trailing', public._cus810_money(coalesce((select sum(coalesce(oi.line_total, oi.quantity*oi.price))
                     from order_items oi where oi.order_id = o.id
                      and coalesce(oi.unfulfillable,false) = false),0)),
      'trailing_tone','neutral',
      'chip', jsonb_build_object(
        'show', true,
        'label', coalesce(sl.label, initcap(coalesce(o.status,''))),
        'bg', case coalesce(sl.tone,'neutral') when 'success' then '#D1FAE5'
                when 'danger' then '#FEE2E2' when 'warning' then '#FEF3C7'
                when 'info' then '#EFF6FF' else '#F3F4F6' end,
        'fg', case coalesce(sl.tone,'neutral') when 'success' then '#065F46'
                when 'danger' then '#991B1B' when 'warning' then '#92400E'
                when 'info' then '#1E40AF' else '#374151' end,
        'border', '#E5E7EB')) as y
      from orders o
      left join order_status_label sl on sl.status = lower(coalesce(o.status,''))
     where o.id = any(v_ids)
       and (v_st = '' or lower(coalesce(o.status,'')) = v_st)
     order by o.created_at desc
     limit v_lim) s;

  return jsonb_build_object('ok', true,
    'limit', v_lim, 'has_more', v_total > v_lim,
    'more_label', public._c('admin_cus2.o_more'),
    'blocks', jsonb_build_array(
      jsonb_build_object('kind','chips','title',public._c('admin_cus2.o_filter'),
                         'arg','p_status','chips', v_chips),
      jsonb_build_object('kind','list','title',public._c('admin_cus2.o_title'),
                         'empty', public._c('admin_cus2.o_empty'), 'items', v_items)));
end $$;

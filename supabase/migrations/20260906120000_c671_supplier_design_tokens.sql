-- CHANGE #671 — feature_gaps row 51: the supplier screens sit outside the
-- design token system.
--
-- #465 took the first of the two public token pages (public_order_page, 21
-- literals -> 0) and left the rest queued to this command. This migration is
-- the BACKEND half of that work: the one display decision the supplier order
-- list was making client-side.
--
-- lib/screens/supplier/supplier_orders_screen.dart branched on the order
-- STATUS STRING in Dart to choose one of five hardcoded hex pairs. That is the
-- same class of bug as the literals themselves, only wearing a switch: an
-- 'accepted' order was green because Dart said so, and a status this build had
-- never heard of fell into a grey default no one chose. The tone and the word
-- are decided here now; the app maps a tone NAME onto a design token
-- (lib/widgets/ds_tone.dart) and decides nothing.
--
-- Idempotent: every object is create-or-replace, and the one function whose
-- RETURNS TABLE gains columns is dropped first (Postgres will not widen a
-- return type in place). The merge worker replays this file on live once.

-- ── The tone, in one place ────────────────────────────────────────────────
-- Deliberately a FUNCTION rather than a case expression copied into each RPC:
-- a new supplier order status is one line here, not a hunt through screens.
create or replace function public.supplier_status_tone(p_status text)
returns text
language sql
immutable
set search_path to 'public'
as $fn$
  select case lower(btrim(coalesce(p_status, '')))
           when 'accepted'  then 'success'
           when 'completed' then 'info'
           when 'delivered' then 'success'
           when 'confirmed' then 'success'
           when 'rejected'  then 'danger'
           when 'cancelled' then 'danger'
           when 'pending'   then 'warning'
           when 'submitted' then 'warning'
           when 'approved'  then 'success'
           else 'neutral'
         end
$fn$;

comment on function public.supplier_status_tone(text) is
  'CHANGE #671 — supplier order status -> design tone name (success/warning/danger/info/neutral). The app maps the NAME onto a token; it never picks a colour.';

-- ── The word on the chip ──────────────────────────────────────────────────
-- ui_copy-backed so the wording is an UPDATE, never a deploy. The raw status
-- is the fallback, which is exactly what the screen printed before, so this
-- can never blank a chip that used to read.
-- The prefix is an argument so ONE function serves every supplier surface that
-- prints a status word: the order list reads supplier_orders.status_<status>,
-- the add-medicine staging list reads supplier_add_medicine.status_<status>.
-- The single-argument form is dropped first — a defaulted new signature beside
-- a surviving old one is an ambiguous overload, not a replacement.
drop function if exists public.supplier_status_label(text);

create or replace function public.supplier_status_label(
  p_status text,
  p_prefix text default 'supplier_orders.status_')
returns text
language sql
stable
set search_path to 'public'
as $fn$
  select coalesce(
           nullif(btrim(public.uic(p_prefix ||
                                   lower(btrim(coalesce(p_status, ''))),
                                   btrim(coalesce(p_status, '')))), ''),
           btrim(coalesce(p_status, '')))
$fn$;

comment on function public.supplier_status_label(text, text) is
  'CHANGE #671 — a supplier-facing status word, overridable per status via the ui_copy key <p_prefix><status>. Falls back to the raw status, which is what the screens printed before.';

revoke all on function public.supplier_status_tone(text) from public;
revoke all on function public.supplier_status_label(text, text) from public;
grant execute on function public.supplier_status_tone(text) to anon, authenticated, service_role;
grant execute on function public.supplier_status_label(text, text) to anon, authenticated, service_role;

-- ── supplier_my_orders gains status_label + status_tone ───────────────────
-- RETURNS TABLE cannot gain columns in place, so the function is dropped and
-- recreated in the same batch. Only supplier_orders_screen.dart calls it, and
-- it is recreated four lines later.
drop function if exists public.supplier_my_orders(uuid);

create function public.supplier_my_orders(p_supplier_id uuid default null::uuid)
 returns table(order_id uuid, order_no integer, created_at timestamp with time zone,
               status text, status_label text, status_tone text,
               total_amount numeric, item_count integer, items jsonb,
               order_code text, packed boolean, packed_via text, pack_button jsonb,
               pricing jsonb, accept jsonb, line_details jsonb)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_name text;
begin
  if p_supplier_id is null then
    select sp.supplier_name into v_name from current_supplier_profile() sp;
  else
    if get_my_role() <> 'super_admin' then RETURN; end if;
    select sp.supplier_name into v_name from supplier_profiles sp where sp.id = p_supplier_id;
  end if;
  if v_name is null then return; end if;

  return query
  select so.id, so.order_no, so.created_at, so.status,
         -- CHANGE #671 gap 51: the word on the chip and the TONE it is
         -- drawn in. The screen used to switch on the status string to
         -- pick one of five hardcoded hex pairs; that is a display
         -- decision, so it is made here and the app performs one lookup.
         public.supplier_status_label(so.status)  as status_label,
         public.supplier_status_tone(so.status)   as status_tone,
         so.total_amount,
         coalesce(jsonb_array_length(so.items),0) as item_count,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'product_id',        it->>'product_id',
                    'product_name',      it->>'product_name',
                    'quantity',          (it->>'quantity')::numeric,
                    'asked_qty',         it->'asked_qty',
                    'partial',           coalesce((it->>'partial')::boolean, false),
                    'pack_type',         nullif(btrim(med.pack_type),''),
                    'image_url',         nullif(btrim(med.image_url_1),''),
                    'therapeutic_class', nullif(btrim(med.therapeutic_class),''),
                    'company',           nullif(btrim(med.marketer),''),
                    'rate',              it->'rate',
                    'rate_source',       it->>'rate_source',
                    'rate_display',      it->>'rate_display',
                    'mrp_display',       it->>'mrp_display',
                    'line_total',        it->'line_total',
                    'line_total_display', it->>'line_total_display',
                    'price_basis_label', it->>'price_basis_label',
                    'batch_no',          d.batch_no,
                    'expiry',            d.expiry,
                    'hsn',               d.hsn
                  ) order by it->>'product_name')
           from jsonb_array_elements(so.items) it
           left join "MEDICINE" med on med.id = (it->>'product_id')::bigint
           left join public.supplier_order_line_detail d
                  on d.supplier_order_id = so.id
                 and d.product_id = (it->>'product_id')::bigint
         ), '[]'::jsonb) as items,
         so.order_code,
         coalesce(so.packed,false) as packed,
         so.packed_via,
         jsonb_build_object(
           'label',       case when coalesce(so.packed,false) then 'Packed ✓' else 'Mark Packed' end,
           'next_packed', not coalesce(so.packed,false),
           'enabled',     (coalesce(so.accept_state,'pending') in ('accepted','partial')),
           'blocked_reason',
             case when coalesce(so.accept_state,'pending') in ('accepted','partial') then null
                  else public.uic('supplier_po.pack_blocked','Accept the order before you mark it packed') end,
           'bg',          case when coalesce(so.packed,false) then '#E1F5EE' else '#1B7A43' end,
           'fg',          case when coalesce(so.packed,false) then '#0F6E56' else '#FFFFFF' end
         ) as pack_button,
         public.po_pricing_block(so.id) as pricing,
         -- CHANGE #687: the same accept block, plus the countdown the supplier
         -- is racing. Absent clock (pre-#687 rows) => has:false => nothing draws.
         (public.supplier_po_accept_block(coalesce(so.accept_state,'pending'),
                                          coalesce(so.packed,false), so.decline_reason)
          || jsonb_build_object('deadline',
               public.supplier_po_deadline_block(so.accept_due_at,
                                                 coalesce(so.accept_state,'pending')))) as accept,
         jsonb_build_object(
           'title',        public.uic('supplier_po.details_title','Batch & expiry'),
           'hint',         public.uic('supplier_po.details_hint','Required on the purchase bill'),
           'batch_label',  public.uic('supplier_po.batch_label','Batch no.'),
           'expiry_label', public.uic('supplier_po.expiry_label','Expiry (MM/YY)'),
           'hsn_label',    public.uic('supplier_po.hsn_label','HSN'),
           'save_label',   public.uic('supplier_po.save_details','Save batch & expiry'),
           'status_label',
             case when exists (select 1 from public.supplier_order_line_detail d
                                where d.supplier_order_id = so.id
                                  and d.batch_no is not null and d.expiry is not null)
                  then public.uic('supplier_po.details_done','Batch and expiry filled')
                  else public.uic('supplier_po.details_missing','Batch and expiry not filled') end,
           'complete',
             not exists (select 1 from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it2
                          where not exists (select 1 from public.supplier_order_line_detail d2
                                             where d2.supplier_order_id = so.id
                                               and d2.product_id = (it2->>'product_id')::bigint
                                               and d2.batch_no is not null
                                               and d2.expiry is not null))
         ) as line_details
  from supplier_orders so
  where so.supplier_name = v_name
  order by so.created_at desc, so.order_no desc;
end $function$;

revoke all on function public.supplier_my_orders(uuid) from public;
grant execute on function public.supplier_my_orders(uuid) to authenticated, service_role;

-- ── The last English sentences that lived in Dart on the public dispute link ─
-- dispute_form_screen.dart printed four error sentences and three qty column
-- headings as Dart string literals, which meant a wording change on the page a
-- supplier reaches from a WhatsApp link required a deploy. They are ui_copy
-- rows now, read through c() like every other word on that screen.
-- ON CONFLICT DO NOTHING: an existing row (a wording someone already tuned)
-- always wins over this seed, and the file replays cleanly.
insert into public.ui_copy (key, value) values
  ('dispute_form_screen.invalid_title',
   to_jsonb('This dispute link is invalid or has expired.'::text)),
  ('dispute_form_screen.invalid_body',
   to_jsonb('Please contact mediBO.'::text)),
  ('dispute_form_screen.load_failed_title',
   to_jsonb('Unable to load. Please try again.'::text)),
  ('dispute_form_screen.load_failed_body',
   to_jsonb('Check your connection and try again.'::text)),
  ('dispute_form_screen.qty_ordered',  to_jsonb('Ordered'::text)),
  ('dispute_form_screen.qty_received', to_jsonb('Received'::text)),
  ('dispute_form_screen.qty_missing',  to_jsonb('Missing'::text))
on conflict (key) do nothing;

-- ── pending_staging_all: the approval chip stops being a Dart switch ───────
-- supplier_add_medicine_screen_web's _PendingRow switched on the staging status
-- ('approved' / 'rejected' / anything-else) to pick one of three hardcoded hex
-- pairs. Same bug, same fix: each row carries its own status_label and
-- status_tone and the row prints them.
-- returns jsonb, so no drop is needed — the rows simply gain two keys, and a
-- client that ignores them is unaffected.
create or replace function public.pending_staging_all(p_kind text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_table text; v jsonb;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode='28000'; end if;
  v_table := case p_kind when 'company' then 'supplier_pending_companies'
                         when 'medicine' then 'supplier_pending_medicines' else null end;
  if v_table is null then raise exception 'unknown_kind: %', p_kind; end if;
  execute format(
    'select coalesce(jsonb_agg(
        to_jsonb(t) || jsonb_build_object(
          ''status_label'', public.supplier_status_label(t.status, ''supplier_add_medicine.status_''),
          ''status_tone'',  public.supplier_status_tone(t.status))
        order by t.created_at desc), ''[]''::jsonb) from %I t', v_table)
    into v;
  return jsonb_build_object('rows', v, 'count', jsonb_array_length(v));
end $function$;

revoke all on function public.pending_staging_all(text) from public;
grant execute on function public.pending_staging_all(text) to authenticated, service_role;

-- dispute_card.dart is the ONE card the supplier portal and the public token
-- page share, and its three quantity headings were Dart literals there too.
insert into public.ui_copy (key, value) values
  ('dispute_card.qty_ordered',  to_jsonb('Ordered'::text)),
  ('dispute_card.qty_received', to_jsonb('Received'::text)),
  ('dispute_card.qty_missing',  to_jsonb('Missing'::text))
on conflict (key) do nothing;

-- dispute_token_page's invalid-link title and body were Dart literals too, on
-- the /dispute?token=<token> page a supplier opens straight from WhatsApp.
insert into public.ui_copy (key, value) values
  ('dispute_token_page.invalid_title', to_jsonb('Link invalid'::text)),
  ('dispute_token_page.invalid_body',
   to_jsonb('This dispute link has expired or is not valid.'::text))
on conflict (key) do nothing;

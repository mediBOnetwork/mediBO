-- CHANGE #686 — ui_copy rows carrying raw Dart source instead of copy.
--
-- Om, 02:22 IST, admin Customer order tab: the order header rendered as
-- "Ordered by: ${row.pharmacy.isNotEmpty ?". The 100%-backend copy sweep of
-- Aug 9 21:13 UTC lifted Dart EXPRESSIONS into ui_copy rather than the strings
-- they produce, and truncated each at the first quote — so 15 rows were left as
-- broken fragments of source code, shown to users verbatim.
--
-- Every call site was already correct: each one calls cf(key, {params}) with
-- sensible named parameters. The damage is entirely in the stored values, so
-- this is mostly a data fix — plus ONE real Dart bug (below) and a guard so the
-- class cannot come back.
--
-- THE HEADER IN OM'S SCREENSHOT WAS STILL BROKEN AFTER THE FIRST FIX.
-- admin_customer.ordered_by had been repaired to "Ordered by: {name}", but the
-- call site passes {a} and {b}, not {name}. cf() strips an unresolved
-- placeholder and then the dangling colon, so the header rendered as a bare
-- "Ordered by" with the customer's name MISSING — a different bug wearing the
-- same clothes. Both halves are fixed here: the two templates take the
-- parameters the screen actually has, and the screen stops composing copy in
-- Dart (it was building " · ${row.pharmacy}" itself, separator included).
-- Which of the two keys to use is a presence check on the pharmacy, which is
-- the reason both keys exist; the wording and the separator stay in the
-- backend.
--
-- PLURALS. Three keys interpolate a count. cf() is plain substitution and Dart
-- may not pluralise, so each is worded to read correctly for EVERY n
-- ("Marked as don't stock: 1" / ": 4") rather than smuggling an English plural
-- rule into either layer. That is a deliberate wording choice, logged as a
-- decision on the command.

-- ── the 15 broken rows, each with the parameters its call site really passes ──
insert into public.ui_copy (key, value) values
  -- lib/widgets/inquiry_v12.dart:201 — cf(..., {'n'})
  ('inquiry_v12.snack_bulk_marked',            '"Marked as don''t stock: {n}"'),
  -- admin_add_medicine_screen_web.dart:611 — cf(..., {'name','error'})
  ('admin_add_medicine.err_create_column_failed', '"Could not create column \"{name}\": {error}"'),
  -- admin_company_screen.dart:142 — cf(..., {'v'})
  ('admin_company.reviewed_by',                '"Reviewed by: {v}"'),
  -- admin_manage_admins_screen.dart:418 — cf(..., {'who'})
  ('admin_manage_admins.added_by',             '"Added by: {who}"'),
  -- admin_mr_screen.dart:139 — {v} is id_proof_type, NOT a reviewer. The sweep
  -- copied the neighbouring line's sentence onto this key.
  ('admin_mr.id_prefix',                       '"ID proof: {v}"'),
  -- admin_mr_screen.dart:140 — cf(..., {'v'})
  ('admin_mr.reviewed_by',                     '"Reviewed by: {v}"'),
  -- no call site in the app today (searched lib/ and supabase/functions/); the
  -- row is repaired rather than deleted so a caller that returns finds copy,
  -- not source.
  ('admin_supplier.toast_contact_error',       '"Contact error: {error}"'),
  -- wa_campaigns_screen.dart:174 / :572 — both cf(..., {'n'})
  ('wa_campaigns.toast_requeued',              '"Requeued: {n}"'),
  ('wa_campaigns.chip_run',                    '"Runs: {n}"'),
  -- cart_screen.dart:2161 — cf(..., {'qty','amount'}); the rupee sign and the
  -- middot are copy and belong here, not in the widget.
  ('cart.removed_line_summary',                '"×{qty}  ·  ₹{amount}"'),
  -- orders_screen.dart:1580/1582/1612/1631 — all cf(..., {'value'}).
  -- invoice_dl is the DRUG LICENCE line; the sweep gave it the GSTIN sentence.
  ('orders.invoice_gstin',                     '"GSTIN: {value}"'),
  ('orders.invoice_dl',                        '"DL: {value}"'),
  ('orders.invoice_date',                      '"Date: {value}"'),
  ('orders.invoice_billed_to',                 '"Billed to: {value}"'),
  -- cash_payment_sheet.dart:284 — cf(..., {'items'})
  ('cash_payment.missing_prefix',              '"Required: {items}"'),
  -- the header from the screenshot, with the parameters the screen has
  ('admin_customer.ordered_by',                '"Ordered by: {name}"'),
  ('admin_customer.ordered_by_with_pharmacy',  '"Ordered by: {name} · {pharmacy}"')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- THE GUARD (spec item 3). Two layers, because they fail at different times.
--
-- A CHECK constraint refuses the write itself, so a future sweep cannot land
-- source code in this table at all — the INSERT errors instead of shipping a
-- fragment to a user's screen. It is validated against all 6,057 existing rows
-- below, so it cannot be added on top of a violation.
--
-- The patterns are deliberately narrow: `${` is Dart string interpolation and
-- has no business in copy, and the method list is the set of Dart calls the
-- sweep actually left behind (.toString(, .join(, .replaceFirst( …). A general
-- "dot followed by a call" rule would reject ordinary prose, so it is not used.
-- Measured before writing this: of 6,057 rows, exactly the 15 repaired above
-- match, and nothing else does.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.ui_copy_is_source_code(p_value text)
 returns boolean
 language sql
 immutable
as $function$
  select coalesce(p_value, '') like '%${%'
      or coalesce(p_value, '') ~ '\.(isNotEmpty|isEmpty|toString|toStringAsFixed|join|replaceFirst|replaceAll|split|trim|toLowerCase|toUpperCase|substring|padLeft|padRight|elementAt|firstWhere)[[:space:]]*\(';
$function$;

comment on function public.ui_copy_is_source_code(text) is
  'CHANGE #686 — true when a ui_copy value is Dart source rather than copy. '
  'Used by the ui_copy CHECK constraint and by rg behaviour c686_ui_copy_is_copy.';

do $$ begin
  alter table public.ui_copy
    add constraint ui_copy_no_dart_source
    check (not public.ui_copy_is_source_code(value #>> '{}'));
exception when duplicate_object then null; end $$;

-- ── and the rg rule, for the rows that are already there. A constraint only
--    guards new writes; this one goes red if a value EVER matches, including
--    one written before the constraint existed or through a path that skips it.
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c686_ui_copy_is_copy', $rg$
do $x$
declare v_bad text; v_n int;
begin
  select count(*), string_agg(key || ' = ' || left(value #>> '{}', 60), ' | ' order by key)
    into v_n, v_bad
    from public.ui_copy
   where public.ui_copy_is_source_code(value #>> '{}');
  if v_n > 0 then
    raise exception
      'C686: % ui_copy row(s) contain Dart source instead of copy — a user sees this verbatim: %',
      v_n, v_bad;
  end if;

  -- and the constraint itself is still attached: a guard someone dropped is
  -- not a guard, and this test is the only thing that would notice.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ui_copy'::regclass
       and conname = 'ui_copy_no_dart_source') then
    raise exception 'C686: the ui_copy_no_dart_source CHECK constraint has been dropped';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$rg$, true,
 'CHANGE #686 — no ui_copy value may be Dart source. The Aug 9 copy sweep left 15 rows as raw ${...} fragments; one of them was the customer order header Om photographed.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

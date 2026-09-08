-- CHANGE #448 — debug pass on #430: close the grant holes the fence journey
-- found, in #430/#425's own helpers and in two it named next door.
--
-- WHAT THE JOURNEY ACTUALLY CAUGHT. Postgres grants EXECUTE on a new function
-- to PUBLIC by default, and this project additionally grants `anon` and
-- `authenticated` on everything. For an ordinary helper that is harmless. For a
-- SECURITY DEFINER helper that takes a pharmacy id as an ARGUMENT it is a
-- cross-tenant hole: the function runs as the owner, so it does not check who
-- is asking, and the caller chooses the shop.
--
-- Two of these were serious enough to be worth stating plainly:
--   * audit_log_append(shop, session, event, payload) — definer, and reachable
--     by anon. Anyone could append entries to ANY pharmacy's sealed audit log.
--     A hash chain whose writer is the public internet is not evidence; it is
--     decoration. This is the single worst defect #430 shipped.
--   * _c425_apply_answer(ask_id, qty, source) — definer, reachable by anon:
--     answering another shop's expiry question would move THEIR lot through
--     _c424_correct.
--
-- The rule this establishes for both commands: an internal helper is internal.
-- Client-facing RPCs keep `authenticated` and nothing else; helpers keep
-- service_role and nothing else.

do $$
declare r record; v_sig text; v_n integer := 0;
begin
  for r in
    select p.oid, p.proname,
           pg_get_function_identity_arguments(p.oid) as args, p.prosecdef
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like '\_c425%' or p.proname like '\_c430%'
            or p.proname = 'audit_log_append'
            or p.proname in ('radar_wa_inbound','radar_wa_bill_intake',
                             'pharmacy_audit_pdf_input','pharmacy_audit_pdf_report',
                             'pharmacy_audit_photo_report',
                             'pharmacy_radar_scan','pharmacy_radar_month_scan',
                             'pharmacy_radar_bill_confirm_sweep',
                             'pharmacy_radar_rebind'))
  loop
    v_sig := format('public.%I(%s)', r.proname, r.args);
    execute format('revoke all on function %s from public, anon, authenticated', v_sig);
    execute format('grant execute on function %s to service_role', v_sig);
    v_n := v_n + 1;
  end loop;
  raise notice 'c448: fenced % internal helper(s)', v_n;
end $$;

-- The client-facing surface keeps exactly one role: a signed-in user. `anon`
-- has no business on a pharmacy's own shelf.
do $$
declare r record; v_sig text;
begin
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'pharmacy\_audit\_%' or p.proname like 'pharmacy\_radar\_%')
       and p.proname not in ('pharmacy_audit_pdf_input','pharmacy_audit_pdf_report',
                             'pharmacy_audit_photo_report','pharmacy_radar_scan',
                             'pharmacy_radar_month_scan','pharmacy_radar_rebind',
                             'pharmacy_radar_bill_confirm_sweep')
  loop
    v_sig := format('public.%I(%s)', r.proname, r.args);
    execute format('revoke all on function %s from public, anon', v_sig);
    execute format('grant execute on function %s to authenticated, service_role', v_sig);
  end loop;
end $$;

-- Next door, and deliberately WITHOUT touching #432's file or its logic: two of
-- its helpers take a shop id and were reachable by anon. Every caller of both is
-- SECURITY DEFINER, so revoking the client grant cannot break that feature —
-- a definer function executes with the owner's rights, not the caller's.
do $$
declare r record; v_sig text;
begin
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('pharmacy_upi_can_edit','pharmacy_upi_history_rows')
  loop
    v_sig := format('public.%I(%s)', r.proname, r.args);
    execute format('revoke all on function %s from public, anon, authenticated', v_sig);
    execute format('grant execute on function %s to service_role', v_sig);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- THE BUG THE DEBUG PASS ACTUALLY FOUND
--
-- #413's spot check counts PRODUCTS, so it put a unique index on
-- (session_id, product_id, product_name) and dedupes its inserts against it.
-- #430 counts LOTS, because expiry and cost live on the batch — so the moment a
-- shop holds two batches of the same medicine (Isojol Tablet, here), starting an
-- audit raised
--     duplicate key value violates unique constraint
--     "pharmacy_count_line_session_product_idx"
-- and the whole session failed. #430's own proof never saw it because the lots
-- it seeded were all different products; every real shelf has repeats.
--
-- The fix keeps BOTH grains honest by splitting the constraint in two, rather
-- than dropping it and leaving #413's dedupe unguarded:
--   * a lot-grain line is unique per (session, lot)
--   * a product-grain line — one with no lot, i.e. #413's — keeps exactly the
--     old rule, unchanged.
drop index if exists public.pharmacy_count_line_session_product_idx;

create unique index if not exists pharmacy_count_line_session_lot_idx
  on public.pharmacy_count_line (session_id, stock_id)
  where stock_id is not null;

create unique index if not exists pharmacy_count_line_session_product_idx
  on public.pharmacy_count_line (session_id, coalesce(product_id, (-1)::bigint), product_name)
  where stock_id is null;

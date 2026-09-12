-- CHANGE #573 gate fix — the one-tap purge could never run from the app.
--
-- test_purge() shipped with three unqualified DELETEs. Every migration in this
-- repo is applied from a psql/management session, where that is legal, so the
-- proof lap passed. The admin Test mode screen and test_run_full() reach the
-- database through PostgREST, where pg_safeupdate is on for the API roles and
-- an unqualified DELETE raises 21000 "DELETE requires a WHERE clause" — the
-- purge aborted before it removed a single row and left every synthetic
-- artifact behind. `where true` is the idiom the rest of this codebase already
-- uses for a deliberate whole-table delete.
--
-- Idempotent: create or replace only.
create or replace function public.test_purge(p_include_fixtures boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare t text; n bigint; v_out jsonb := '{}'::jsonb; v_total bigint := 0;
  ordered text[] := array[
    'delivery_events','delivery_claims','delivery_payout_lines','deliveries','delivery_runs',
    'bag_allocations','bags','receiving_log','stock_movement',
    'bill_lines','pending_bills','supplier_payments','supplier_disputes',
    'payment_claims','rzp_payment_attempt','razorpay_qr','refunds','order_costs',
    'order_alert','order_fulfilment_snapshot','order_pnl_slab',
    'notification_log','notification_retry_queue','wa_campaign_recipients','whatsapp_messages',
    'loyalty_ledger','pharmacy_stock_move','pharmacy_stock','pharmacy_gst_ledger',
    'pharmacy_count_session','gst_ledger','partner_settlements','incentive_earnings',
    'order_items','inquiry','supplier_orders','orders','pending_orders',
    'supplier_count_sessions','bag_sessions','customer_invoice_series'];
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  foreach t in array ordered loop
    execute format('delete from public.%I where is_synthetic', t);
    get diagnostics n = row_count;
    if n > 0 then v_out := v_out || jsonb_build_object(t, n); v_total := v_total + n; end if;
  end loop;

  delete from public.synthetic_blocked_write where true; get diagnostics n = row_count;
  if n > 0 then v_out := v_out || jsonb_build_object('synthetic_blocked_write', n); v_total := v_total + n; end if;
  delete from public.test_event where true;
  delete from public.test_run  where true;

  if coalesce(p_include_fixtures,false) then
    delete from public.test_fixture where true;
    delete from public.delivery_partner_registrations where is_synthetic;
    delete from public.supplier_profiles where is_synthetic;
    delete from public.pharmacy_profiles where is_synthetic;
    v_out := v_out || jsonb_build_object('fixtures', 'removed');
  end if;

  return jsonb_build_object('ok', true, 'deleted', v_out, 'total', v_total,
    'message', public.uic('test_mode.purged','Synthetic artifacts purged.'));
end $fn$;

grant execute on function public.test_purge(boolean) to authenticated;

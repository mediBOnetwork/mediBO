-- CHANGE #635 — the shop-count stage must FORWARD the supplier, because that is
-- what the real Supplier Shop submit does and what receiving refuses without.
--
-- Found by this change's own critical-path smoke against CHANGE #1163: two of
-- the twenty-eight journeys failed, both of them the flagship one, both with
--
--   23514: supplier "TST TEST SUPPLIER - SYNTHETIC (DO NOT USE)" not forwarded
--          — no receiving before Supplier Shop submit
--
-- raised by _enforce_receive_requires_forward (CHANGE #710). That guard is
-- correct and stays untouched: warehouse receiving may not happen for a
-- supplier the day never forwarded. What was wrong is the SIMULATION. Stage 4
-- is "supplier shop counts the physical stock", and in production a shop count
-- only exists because the supplier was put in shop mode for that date — the
-- supplier_count_mode row IS the forward that _supplier_forwarded() reads. The
-- sim wrote shop_qty and skipped the row, so stage 4 reported success while
-- leaving the order in a state stage 5 is forbidden to enter. A pipeline that
-- can pass a stage into an impossible state is not a pipeline test.
--
-- Scope: only suppliers named on a SYNTHETIC order, and only through the
-- ordinary unique key (assigned_supplier, mode_date) with ON CONFLICT DO
-- NOTHING — a real supplier already forwarded for today keeps the mode a human
-- chose. prune_orphan_count_modes() reclaims the synthetic row on its own once
-- the synthetic order is gone.
select coalesce((
  select true from information_schema.tables
   where table_schema = 'public' and table_name = 'test_pipeline_stage'), false) as c635_here \gset
\if :c635_here
\else
\echo '[c635] no test_pipeline_stage here — the pipeline sim lives with the runs; nothing to do.'
\quit
\endif

create or replace function public.test_sim_shop_count(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0; v_sup uuid; v_fw int := 0;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic'); end if;
  perform public.test_fixtures_ensure();
  select entity_id into v_sup from public.test_fixture where key='supplier';

  -- shop_qty is what the supplier's shop counted; the warehouse recount is a
  -- separate column and a separate stage, so this must not fill both.
  update public.order_items
     set shop_qty = quantity,
         assigned_supplier = coalesce(assigned_supplier, v_sup::text)
   where order_id = p_order_id and coalesce(unfulfillable,false) = false;
  get diagnostics v_n = row_count;

  -- THE FORWARD. Every distinct supplier this synthetic order was assigned to
  -- is put in shop mode for its own count date, which is exactly the state a
  -- real Supplier Shop submit leaves behind and exactly what stage 5 asks for.
  insert into public.supplier_count_mode (assigned_supplier, mode, set_by, mode_date)
  select distinct oi.assigned_supplier, 'shop', 'autotest',
         public._supplier_count_date(oi.assigned_supplier, public.admin_active_date(), null)
    from public.order_items oi
   where oi.order_id = p_order_id
     and coalesce(oi.unfulfillable,false) = false
     and coalesce(btrim(oi.assigned_supplier),'') <> ''
     -- and it is a SYNTHETIC supplier, checked here rather than assumed.
     -- _synthetic_party_guard only refuses a mismatch it RECOGNISES, so a
     -- synthetic order carrying a name no supplier_profiles row knows would
     -- slip past it — and forwarding a real supplier is the one thing this
     -- statement must never do.
     and public.synthetic_supplier_is(oi.assigned_supplier, null)
  on conflict (assigned_supplier, mode_date) do nothing;
  get diagnostics v_fw = row_count;

  if p_run is not null then
    perform public.test_event_add(p_run, 'shop_counted',
      jsonb_build_object('lines', v_n, 'forwarded', v_fw));
  end if;
  return jsonb_build_object('ok', v_n > 0, 'lines', v_n, 'forwarded', v_fw,
                            'detail', v_n || ' line(s) counted at the supplier shop'
                                      || case when v_fw > 0
                                              then ', ' || v_fw || ' supplier(s) forwarded'
                                              else '' end);
end $function$;

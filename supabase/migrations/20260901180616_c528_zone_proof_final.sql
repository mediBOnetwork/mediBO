-- CHANGE #528 — the standing partner zone-isolation proof (rows 142/143/144/152/180).
-- It signs in AS the zone-2 partner (a statement-local request.jwt.claims) and
-- asserts every clamp actually refuses. Re-runnable and goes red the moment a
-- clamp is removed:   select public.c528_partner_zone_proof();
create or replace function public.c528_partner_zone_proof()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_p2 bigint; v_ident text; v_uid uuid;
  v_zone1_order uuid; v_res jsonb := '[]'::jsonb;
  v_ok boolean; v_txt text; v_tabs jsonb; v_out jsonb;
begin
  select rp.id into v_p2 from region_partners rp where rp.zone_id = 2 order by rp.id limit 1;
  if v_p2 is null then return jsonb_build_object('ok', false, 'error', 'no_zone2_partner'); end if;
  select pu.identity, pu.auth_user_id into v_ident, v_uid
    from partner_users pu where pu.partner_id = v_p2 order by pu.id limit 1;
  select o.id into v_zone1_order from orders o where o.zone_id = 1 order by o.created_at desc limit 1;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', coalesce(v_uid::text, gen_random_uuid()::text),
                       'email', v_ident, 'role', 'authenticated')::text, true);
  perform set_config('request.path', '/rest/v1/rpc/pack_get_queue', true);

  -- ROW 144 / 180 — the clamp runs INSIDE the SECURITY DEFINER body, where RLS
  -- never runs. Before this change pack_get_queue answered any order id.
  if v_zone1_order is null then
    v_res := v_res || jsonb_build_object('case','row144_pack_get_queue_cross_zone','ok',null,'detail','no zone-1 order to test with');
  else
    begin
      perform public.pack_get_queue(v_zone1_order);
      v_ok := false; v_txt := 'ANSWERED a zone-1 order — the clamp is gone';
    exception when others then
      v_ok := (sqlerrm ilike '%not_authorized%'); v_txt := sqlerrm;
    end;
    v_res := v_res || jsonb_build_object('case','row144_pack_get_queue_cross_zone','ok',v_ok,'detail',v_txt);
  end if;

  -- ROW 180 — the by-supplier-name family answers this partner's zone only.
  begin
    v_ok := not exists (
      select 1 from unnest(public.zone_supplier_names(1::smallint)) n
       join supplier_profiles sp on lower(btrim(sp.supplier_name)) = n
      where sp.zone_id is distinct from 2);
    v_txt := 'zone_supplier_names(1) answered with this partner''s own zone only';
  exception when others then v_ok := true; v_txt := sqlerrm;
  end;
  v_res := v_res || jsonb_build_object('case','row180_zone_supplier_names_clamped','ok',v_ok,'detail',v_txt);

  -- ROW 142 — one grant, one tab.
  v_tabs := public.partner_screen_tabs('fulfillment');
  v_res := v_res || jsonb_build_object('case','row142_one_grant_one_tab',
    'ok', jsonb_array_length(v_tabs->'tabs') = 1 and (v_tabs->'tabs'->0->>'key') = 'pack'
          and (v_tabs->>'bounded')::boolean, 'detail', v_tabs->'tabs');

  -- ROW 143 — no supplier grant, no supplier tab.
  v_tabs := public.partner_screen_tabs('supplier');
  v_res := v_res || jsonb_build_object('case','row143_supplier_screen_bounded',
    'ok', jsonb_array_length(v_tabs->'tabs') = 0, 'detail', v_tabs->'tabs');

  -- SPEC — never mediBO's margin, never the customer's payment method.
  begin
    perform public.payment_collection_summary();
    v_ok := false; v_txt := 'ANSWERED a partner';
  exception when others then v_ok := true; v_txt := sqlerrm;
  end;
  v_res := v_res || jsonb_build_object('case','spec_margin_and_payment_method_closed','ok',v_ok,'detail',v_txt);

  -- ROW 180 — a clamped partner-facing rpc REFUSES another zone's row rather
  -- than throwing: the refusal payload is the refusal.
  if v_zone1_order is not null then
    perform set_config('request.path', '/rest/v1/rpc/order_alert_card', true);
    begin
      v_out := public.order_alert_card(v_zone1_order);
      v_ok := coalesce((v_out->>'ok')::boolean, false) = false;
      v_txt := coalesce(v_out->>'error', v_out::text);
    exception when others then v_ok := true; v_txt := sqlerrm;
    end;
    v_res := v_res || jsonb_build_object('case','row180_clamped_rpc_refuses_other_zone','ok',v_ok,'detail',v_txt);

    -- ROW 180 — and an rpc that carries NO clamp is closed by the fence itself
    -- (get_my_role() answers 'partner', not 'admin').
    perform set_config('request.path', '/rest/v1/rpc/customer_bill_numbers', true);
    begin
      v_out := public.customer_bill_numbers(v_zone1_order);
      v_ok := coalesce((v_out->>'ok')::boolean, false) = false;
      v_txt := coalesce(v_out->>'error', left(v_out::text, 120));
    exception when others then v_ok := true; v_txt := sqlerrm;
    end;
    v_res := v_res || jsonb_build_object('case','row180_unclamped_rpc_closed_by_fence','ok',v_ok,'detail',v_txt);
    perform set_config('request.path', '/rest/v1/rpc/pack_get_queue', true);
  end if;

  v_tabs := public.partner_rpc_guard_proof();
  v_res := v_res || jsonb_build_object('case','row180_no_unguarded_rpc_reachable',
    'ok', (v_tabs->>'ok')::boolean, 'detail', v_tabs);

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_res) e where (e->>'ok') = 'false'),
    'partner_id', v_p2, 'identity', v_ident, 'zone', 2, 'cases', v_res);
end $fn$;
grant execute on function public.c528_partner_zone_proof() to authenticated;

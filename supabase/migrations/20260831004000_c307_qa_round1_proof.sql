-- CHANGE #307 QA round 1 — the proof that the three high findings are closed.
-- Runs as a simulated zone-1 partner session, restores everything it touches
-- (the order's zone is put straight back), and is safe to re-run.
-- Idempotent: CREATE OR REPLACE + an upserted synthetic proof login.
CREATE OR REPLACE FUNCTION public.c307_partner_guard_proof()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid   uuid := '00000307-0000-0000-0000-000000000307';
  v_checks jsonb := '[]'::jsonb;
  v_old   text;
  v_order uuid;
  v_zone0 smallint;
  v_audit jsonb;
  v_acc   text;
  v_msg   text;
  v_out   jsonb;
  v_pass  int := 0; v_fail int := 0;
  r jsonb;
begin
  insert into partner_users(partner_id, identity, display_name, auth_user_id, created_by)
  values (1, 'c307-zone-proof', 'c307 proof', v_uid, 'c307')
  on conflict (identity) do update
    set partner_id = 1, auth_user_id = v_uid, is_active = true;

  select id, zone_id into v_order, v_zone0 from orders order by id limit 1;

  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);

  v_audit := public.c307_medibo_only_audit();
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','medibo_only_audit.ok','expected','true','got',(v_audit->>'ok')));
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','medibo_only_audit.leaky_count','expected','0','got',(v_audit->>'leaky_count')));

  begin
    perform public.customer_order_payment_panel(v_order);
    v_msg := 'ALLOWED';
  exception when others then v_msg := 'refused';
  end;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','customer_order_payment_panel refused','expected','refused','got',v_msg));

  begin
    perform public.admin_payout_open();
    v_msg := 'ALLOWED';
  exception when others then v_msg := 'refused';
  end;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','admin_payout_open refused','expected','refused','got',v_msg));

  -- marketing: this family RETURNS an error object rather than raising
  begin
    v_out := public.wa_templates_screen();
    v_msg := case when v_out->>'error' = 'not_authorized' then 'refused' else 'ALLOWED' end;
  exception when others then v_msg := 'refused';
  end;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','wa_templates_screen refused','expected','refused','got',v_msg));

  begin
    v_out := public.lead_summary();
    v_msg := case when v_out->>'error' = 'not_authorized' then 'refused' else 'ALLOWED' end;
  exception when others then v_msg := 'refused';
  end;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','lead_summary refused','expected','refused','got',v_msg));

  begin
    perform public._assert_can_see_order(v_order);
    v_msg := 'allowed';
  exception when others then v_msg := 'REFUSED';
  end;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','in_zone order allowed','expected','allowed','got',v_msg));

  update orders set zone_id = 2 where id = v_order;
  begin
    perform public._assert_can_see_order(v_order);
    v_msg := 'ALLOWED';
  exception when others then v_msg := 'refused';
  end;
  update orders set zone_id = v_zone0 where id = v_order;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','cross_zone order refused','expected','refused','got',v_msg));
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','order zone restored','expected',coalesce(v_zone0::text,'null'),
    'got',coalesce((select zone_id::text from orders where id = v_order),'null')));

  v_acc := public.partner_access('partner.pack', 999999);
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','partner_access(other_partner) is own value','expected',
    public.partner_access('partner.pack'),'got',v_acc));

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','unknown feature defaults none','expected','none',
    'got',public.partner_access('partner.not_a_real_feature_'||gen_random_uuid()::text)));

  perform set_config('request.jwt.claims', coalesce(v_old,''), true);

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check','role_for_medibo_only == get_my_role off-partner','expected','true',
    'got',(public.role_for_medibo_only() = public.get_my_role())::text));

  for r in select * from jsonb_array_elements(v_checks) loop
    if (r->>'got') is not distinct from (r->>'expected')
      then v_pass := v_pass + 1; else v_fail := v_fail + 1; end if;
  end loop;

  return jsonb_build_object('ok', v_fail = 0, 'passed', v_pass, 'failed', v_fail,
                            'checks', v_checks);
end $function$;

grant execute on function public.c307_partner_guard_proof() to service_role;

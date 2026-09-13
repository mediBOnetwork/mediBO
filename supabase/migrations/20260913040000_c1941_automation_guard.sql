-- CMD #1941, QA round 1 — restore the guard the move dropped, server-side.
--
-- WHAT WENT WRONG
-- Before this command, the only UI that could switch `supplier_order_auto_meta`
-- ON was `_saveOrderAutoMeta()` in admin_supplier_screen_web.dart. It did a
-- pre-flight first: invoke the `meta-send-inquiry` edge function, and on
-- `error:'meta_not_configured'` show `admin_supplier.meta_not_configured_disabled`,
-- revert the switch AND write the setting back to false. #1941 deleted that
-- method with the rest of the strip and `dashboard_automation_set` replaced it
-- with a bare `set_app_setting(...)`. So the pill could arm an automation with
-- no sender behind it, and `autosend_pending_supplier_orders()` would then stamp
-- `auto_order_sent_at = now()` on supplier orders whether or not anything left
-- the building. The orphaned ui_copy key (still in the table, referenced by zero
-- Dart after the move) was the fingerprint.
--
-- WHY THE CHECK IS NOT THE EDGE FUNCTION
-- The Dart pre-flight asked the edge runtime whether WHATSAPP_TOKEN /
-- WHATSAPP_PHONE_ID / WHATSAPP_TEMPLATE were set. Postgres cannot ask that
-- synchronously — this database has pg_net (async) and no `http` extension, so
-- an RPC that must RETURN the verdict cannot wait on an HTTP round-trip. The
-- server owns a better fact anyway: `wa_waba_state`, which the WABA sync fills
-- from Meta itself. An account that is present, APPROVED and not carrying an
-- error is a configured sender; anything else is the same "not configured" the
-- admin used to be told about, and it additionally catches a sender that was
-- configured once and has since been suspended, which the env-var probe never
-- could.
--
-- The refusal shape is the one the frontend already renders: ok:false +
-- `message` + the CURRENT `automation` block, so the pill re-draws exactly as
-- the server still has it and nothing is written. test/protected/
-- dashboard_automation_test.dart already holds that contract down.
--
-- Also here: the two AutoFlow pills used to live on different Supplier
-- sub-tabs and could never be seen together, so both answering "Automatic by
-- Meta: ON" was harmless. Side by side in one strip it is not — whichever one
-- you tap, you get the same sentence. Each gets its own toast copy.
--
-- Idempotent: upserts and create-or-replace only.

begin;

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('admin_supplier.autoflow_inquiry_toast_on',  '"Inquiry AutoFlow: ON"'::jsonb),
  ('admin_supplier.autoflow_inquiry_toast_off', '"Inquiry AutoFlow: OFF"'::jsonb),
  ('admin_supplier.autoflow_orders_toast_on',   '"Orders AutoFlow: ON"'::jsonb),
  ('admin_supplier.autoflow_orders_toast_off',  '"Orders AutoFlow: OFF"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 2. Is there a sender behind the automation? ─────────────────────────────
-- One fact, one place. `reason` is for the ledger and for a future caller that
-- wants to say WHICH way it is not configured; the admin only ever sees the
-- ui_copy sentence.
create or replace function public._wa_meta_ready()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare s public.wa_waba_state%rowtype;
begin
  select * into s from public.wa_waba_state where id = 1;
  if s.id is null then
    return jsonb_build_object('ready', false, 'reason', 'no_waba_state');
  end if;
  if coalesce(btrim(s.waba_id), '') = '' then
    return jsonb_build_object('ready', false, 'reason', 'no_waba_id');
  end if;
  if s.error is not null then
    return jsonb_build_object('ready', false, 'reason', 'waba_error');
  end if;
  if upper(coalesce(s.review_status, '')) <> 'APPROVED' then
    return jsonb_build_object('ready', false, 'reason', 'not_approved');
  end if;
  return jsonb_build_object('ready', true, 'reason', 'ok');
end
$function$;

revoke all on function public._wa_meta_ready() from public, anon;
grant execute on function public._wa_meta_ready() to authenticated, service_role;

-- ── 3. The toggle writer, with the pre-flight back ──────────────────────────
create or replace function public.dashboard_automation_set(p_key text, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_res    jsonb;
  v_detail jsonb;
  v_toast  text;
  v_ready  jsonb;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('access.denied_view'));
  end if;

  if p_key = 'auto_meta' then
    perform public.set_app_setting('inquiry_auto_meta', to_jsonb(coalesce(p_on,false)));
    v_toast := case when coalesce(p_on,false)
                    then public._c('admin_supplier.autoflow_inquiry_toast_on')
                    else public._c('admin_supplier.autoflow_inquiry_toast_off') end;

  elsif p_key = 'order_auto_meta' then
    -- Arming it needs a sender. Switching it OFF never does — a kill switch
    -- that can only be reached when the thing it kills is healthy is not a
    -- kill switch.
    if coalesce(p_on,false) then
      v_ready := public._wa_meta_ready();
      if coalesce((v_ready->>'ready')::boolean, false) is not true then
        return jsonb_build_object('ok', false,
          'error', 'meta_not_configured',
          'reason', v_ready->>'reason',
          'message', public._c('admin_supplier.meta_not_configured_disabled'),
          'automation', public._dashboard_automation());
      end if;
    end if;
    perform public.set_app_setting('supplier_order_auto_meta', to_jsonb(coalesce(p_on,false)));
    v_toast := case when coalesce(p_on,false)
                    then public._c('admin_supplier.autoflow_orders_toast_on')
                    else public._c('admin_supplier.autoflow_orders_toast_off') end;

  elsif p_key = 'bundle' then
    v_res := public.apply_allocation_mode(
               case when coalesce(p_on,false) then 'fewest_baskets' else 'first_available' end);
    if coalesce(v_res->>'status','') <> 'ok' then
      return jsonb_build_object('ok', false,
        'error', coalesce(v_res->>'error','unknown'),
        'message', public._cf('admin_supplier.error_detail',
                     jsonb_build_object('a', coalesce(v_res->>'error','unknown'))),
        'automation', public._dashboard_automation());
    end if;
    if coalesce(p_on,false) then
      v_detail := coalesce(v_res->'detail','{}'::jsonb);
      v_toast  := public._cf('admin_supplier.bundled_items', jsonb_build_object(
                    'a', coalesce(v_detail->>'items_assigned','0'),
                    'b', coalesce(v_detail->>'baskets','0')));
    else
      v_toast := public._c('admin_supplier.back_to_first_available');
    end if;

  else
    return jsonb_build_object('ok', false, 'error', 'unknown_toggle',
                              'message', public._c('dashboard_home.automation_failed'),
                              'automation', public._dashboard_automation());
  end if;

  return jsonb_build_object('ok', true, 'toast', v_toast,
                            'automation', public._dashboard_automation());
end
$function$;

revoke all on function public.dashboard_automation_set(text, boolean) from public, anon;
grant execute on function public.dashboard_automation_set(text, boolean) to authenticated, service_role;

commit;

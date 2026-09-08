-- ============================================================================
-- CHANGE #306 — close the anon surface on this command's own functions.
--
-- Every function created here carried Postgres's default PUBLIC EXECUTE grant,
-- and `anon` inherits through PUBLIC — so the anon key that ships inside the
-- web bundle and the APK could call all of them. That is not theoretical:
--   order_alert_tick()      — force the escalation ladder, including auto-cancel
--   order_alert_push()      — ring every admin device on demand
--   customer_credit_state() — read any customer's outstanding balance
--   order_paid_amount()     — read what any order has paid
-- (Lesson from #305: `revoke ... from anon, authenticated` is a NO-OP; the
-- grant to revoke is the one to PUBLIC.)
--
-- The rule applied: a function a signed-in ADMIN calls from a screen keeps
-- `authenticated` (each one gates on get_my_role() itself and renders the
-- backend's own refusal); everything else — internals, the dispatcher tick, the
-- push, and the token door the edge function uses with the service key — is
-- service_role only.
-- ============================================================================
do $$
declare
  fn text;
  -- Called from a screen by a signed-in admin; each self-gates on get_my_role().
  admin_facing constant text[] := array[
    'order_alert_feed(integer)',
    'order_alert_card(uuid)',
    'order_alert_action(uuid,text,text)',
    'order_alert_settings()',
    'order_alert_settings_set(jsonb)',
    'customer_credit_list(text,integer)',
    'customer_credit_set(uuid,numeric,boolean,text)',
    'purchase_override_grant(uuid,text)',
    'purchase_override_revoke(bigint)'
  ];
  -- Backend-only: the tick, the push, the internals, and the token door.
  internal constant text[] := array[
    'order_alert_tick()',
    'order_alert_push(bigint,text)',
    'order_alert_raise(uuid)',
    'order_alert_action_by_token(text,text,text)',
    'order_alert_open_count()',
    'oa_label(text,jsonb)',
    '_oa_cfg()',
    '_oa_item(order_alert)',
    '_oa_age_label(timestamptz)',
    '_oa_admin_phones()',
    '_oa_admin_emails()',
    '_oa_apply_action(bigint,text,text,uuid,text,text)',
    '_oa_release_and_cancel(uuid,text,text)',
    'order_paid_amount(uuid)',
    'order_is_paid(uuid)',
    'order_purchase_blocked(uuid)',
    'purchase_gate_check(uuid)',
    '_purchase_gate_log(uuid,text,boolean,text,jsonb)',
    'customer_credit_state(uuid)'
  ];
begin
  -- Revoke from PUBLIC *and* from the two roles that were granted explicitly
  -- when the function was created: dropping the PUBLIC grant alone leaves an
  -- explicit `authenticated=X` behind, which would still let any signed-in
  -- CUSTOMER run the dispatcher tick or read another customer's balance.
  foreach fn in array admin_facing || internal loop
    if to_regprocedure('public.' || fn) is not null then
      execute format('revoke all on function public.%s from public', fn);
      execute format('revoke all on function public.%s from anon', fn);
      execute format('revoke all on function public.%s from authenticated', fn);
      execute format('grant execute on function public.%s to service_role', fn);
    end if;
  end loop;

  foreach fn in array admin_facing loop
    if to_regprocedure('public.' || fn) is not null then
      execute format('grant execute on function public.%s to authenticated', fn);
    end if;
  end loop;
end $$;

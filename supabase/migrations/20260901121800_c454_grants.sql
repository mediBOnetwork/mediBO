-- CMD #454 — every SECURITY DEFINER function inherits Postgres's default
-- GRANT EXECUTE TO PUBLIC, so a new RPC is anon-executable the moment it is
-- created (privileged_rpcs_are_not_anon). Close it for everything this command
-- added: the four client RPCs get authenticated + service_role, the cron ticks
-- and the internal helpers get service_role only.
do $$
declare f text;
begin
  foreach f in array array[
    'public.delivery_partial_lines(uuid, jsonb, text, numeric, numeric, text, text, text)',
    'public.delivery_redeliver(uuid, uuid)',
    'public.delivery_run_track(uuid)',
    'public.delivery_accept_expiry_tick()',
    'public.delivery_reattempt_tick()',
    'public.delivery_id_doc_purge_tick()',
    'public.delivery_location_purge_tick()',
    'public.c454_delivery_high_b_proof()',
    'public._delivery_notify_assigned(uuid)',
    'public._delivery_return_lines(uuid, jsonb, text, text, text)',
    'public._delivery_restock_line(uuid, numeric, text)',
    'public._pii_norm_doc(text)', 'public._pii_mask_doc(text)',
    'public._pii_hash_doc(text)', 'public._pii_redact_ocr(jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;

  -- the three a signed-in user actually calls
  foreach f in array array[
    'public.delivery_partial_lines(uuid, jsonb, text, numeric, numeric, text, text, text)',
    'public.delivery_redeliver(uuid, uuid)',
    'public.delivery_run_track(uuid)'
  ] loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- The four this command RE-CREATED were already anon-executable before it (a
-- create-or-replace preserves grants). They all refuse an anonymous caller at
-- their own guard, but an anon EXECUTE grant on a rider/admin RPC is not
-- something to leave behind once the function is in your hands.
do $$
declare f text;
begin
  foreach f in array array[
    'public.delivery_rto_receive(uuid)',
    'public.delivery_partial(uuid, integer, integer, text, numeric, numeric, text, text)',
    'public.delivery_update_location(numeric, numeric, numeric, numeric)',
    'public._delivery_assign_core(uuid[], uuid, text, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

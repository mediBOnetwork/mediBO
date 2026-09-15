-- CMD #2033 — RG red after #1390: the two CRITICAL behaviour failures.
--
-- The 54 schema diffs in that run are the zone-availability, catalogue and cart
-- work landing; they are rebaselined, not patched. Behaviour failures are never
-- rebaselined, so this file fixes both of them.
--
-- (1) c2017_zone99_hard_wall — "guarded path lost its guard: notify_raw"
--     notify_raw is registered in mode_guard_path as reading its scoped tables
--     through schema mode. CMD #2032 correctly moved the opt-out lookup off
--     mode.orders onto public.orders (the mode predicate was hiding the row and
--     silently ignoring the recipient's switch) — but that was the function's
--     only `mode.` reference, so the zone-99 wall lost its last hold on the SEND
--     lane. Restoring the mode.orders read would re-break #2032, so the guard is
--     restored in its proper send-lane form instead: mode_outbound_blocked(),
--     which is exactly the face of this guard built for outbound senders. A
--     synthetic row, or a row in the test zone, never leaves the building for a
--     session that is not itself in test mode. Real orders/customers are
--     untouched (mode_row_hidden is false for them).
--
-- (2) privileged_rpcs_are_not_anon — anon could EXECUTE the six new zone
--     functions. Every SECURITY DEFINER function inherits Postgres's default
--     GRANT TO PUBLIC, and the anon key ships inside the web bundle and the APK,
--     so those were public endpoints on a warehouse surface. None of them is
--     called from Dart (they are internal helpers behind catalogue/cart RPCs),
--     so PUBLIC/anon is revoked and authenticated + service_role granted back.
--
-- Idempotent: both halves patch whatever is live and do nothing when already
-- applied, so this file is safe to replay on live at deploy.

-- ── (1) the send-lane zone-99 guard ────────────────────────────────────────
do $mig2033a$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_raw'
   limit 1;

  if v_src is null then
    raise notice 'c2033: public.notify_raw not present — nothing to patch';
  elsif v_src ~ 'mode_outbound_blocked' then
    raise notice 'c2033: notify_raw already carries the send-lane guard';
  else
    v_new := regexp_replace(
      v_src,
      'or\s+public\.test_customer_silenced\(nullif\(p_vars->>''customer_id'',''''\)::uuid\)\s+then',
      'or public.test_customer_silenced(nullif(p_vars->>''customer_id'','''')::uuid)'
      || E'\n'
      || '     -- CMD #2033 — the zone-99 hard wall on the send lane: a synthetic'  || E'\n'
      || '     -- or test-zone row never leaves the building.'                      || E'\n'
      || '     or exists (select 1 from public.orders o'                            || E'\n'
      || '                 where o.id = nullif(p_vars->>''order_id'','''')::uuid'   || E'\n'
      || '                   and public.mode_outbound_blocked(o.is_synthetic, o.zone_id, o.test_session_id))' || E'\n'
      || '     or exists (select 1 from public.pharmacy_profiles pp'                || E'\n'
      || '                 where pp.id = nullif(p_vars->>''customer_id'','''')::uuid' || E'\n'
      || '                   and public.mode_outbound_blocked(pp.is_synthetic, pp.zone_id, pp.test_session_id))' || E'\n'
      || '  then',
      'i');

    if v_new = v_src then
      raise exception 'c2033: notify_raw guard anchor not found — the send-lane guard was NOT restored';
    end if;

    execute v_new;
    raise notice 'c2033: notify_raw send-lane zone-99 guard restored';
  end if;
end $mig2033a$;

-- ── (2) the anon grant on the new zone functions ───────────────────────────
do $mig2033b$
declare f record; v_n int := 0;
begin
  for f in
    select p.oid,
           'public.' || quote_ident(p.proname) || '(' ||
           pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname in ('_zone_avail_sync','_zone_avail_sync_trg','zone_avail_backfill',
                         'zone_availability_contract','zone_available','zone_available_products')
       and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
    v_n := v_n + 1;
  end loop;
  raise notice 'c2033: anon EXECUTE revoked on % zone function(s)', v_n;
end $mig2033b$;

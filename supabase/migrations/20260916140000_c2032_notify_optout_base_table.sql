-- CMD #2032 — RG red: c712_customer_events_fire_once
--
-- notify_raw() resolves the recipient's user_id from the order so it can honour
-- the per-user notification switch (CHANGE #712, "the switch honoured on the
-- WIRE and not only in the settings screen"). That lookup was reading
-- mode.orders, whose predicate hides every row whose is_synthetic flag does not
-- match the CALLING session's test mode. So whenever the caller's mode differs
-- from the order's flag the lookup returned NULL, the opt-out branch was never
-- reached, and the send fell through to the queue path — the recipient's switch
-- was silently ignored. The sibling lookup one line below already reads
-- public.pharmacy_profiles; mode.orders was the odd one out.
--
-- An internal preference lookup on the delivery path is not a mode-scoped READ:
-- notify_raw is not in mode_scoped_rpc, so reading the base table here does not
-- weaken test_mode_read_isolation.
--
-- Idempotent on purpose: it rewrites whatever notify_raw currently is, and does
-- nothing when the line already reads public.orders.
do $mig$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_raw'
   limit 1;

  if v_src is null then
    raise notice 'c2032: public.notify_raw not present — nothing to patch';
    return;
  end if;

  v_new := regexp_replace(
             v_src,
             'from\s+mode\.orders\s+o\s+where\s+o\.id\s*=\s*v_order',
             'from public.orders o where o.id = v_order',
             'gi');

  if v_new = v_src then
    raise notice 'c2032: notify_raw already reads public.orders — no change';
    return;
  end if;

  execute v_new;
  raise notice 'c2032: notify_raw opt-out lookup moved off mode.orders';
end $mig$;

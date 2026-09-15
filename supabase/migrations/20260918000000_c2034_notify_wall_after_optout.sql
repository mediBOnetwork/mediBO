-- CMD #2034 — RG red after #1391: the zone-99 send-lane wall, in the one place
-- it can stand without lying about WHY a message was not sent.
--
-- #2033 restored the wall that #2032 removed from notify_raw, but it put it in
-- the very first guard block — above the CHANGE #712 per-user switch. Every
-- notification for a synthetic or test-zone row then returned
-- reason='test_mode_silenced', including the one c712_customer_events_fire_once
-- sends AFTER the recipient switched that event off. c712 asserts that call
-- reports itself as 'user_opted_out', so the fix for c2017_zone99_hard_wall
-- would have traded one critical behaviour failure for another. (#2033 could
-- not see it: the build branch carried 11 of production's 89 behaviour tests
-- and c712 was not among them. Proven here by seeding the branch with all 89.)
--
-- So the wall moves DOWN: after the per-user switch has had its say, and still
-- above notify_window / notif_push_send / every WhatsApp path — a synthetic or
-- test-zone row never leaves the building, and an opt-out still reports itself
-- as an opt-out. The read is public.orders / public.pharmacy_profiles (NOT
-- mode.orders — that is exactly the hidden-row bug #2032 fixed); the decision
-- is public.mode_outbound_blocked(), the face of this guard built for senders.
--
-- Idempotent: it strips #2033's placement if present, does nothing if the wall
-- is already in its #2034 place, and is safe to replay on live at deploy.

do $mig2034$
declare v_src text; v_new text; v_stripped text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_raw'
   limit 1;

  if v_src is null then
    raise notice 'c2034: public.notify_raw not present — nothing to patch';
    return;
  end if;

  if v_src ~ 'CMD #2034' then
    raise notice 'c2034: notify_raw already carries the wall in its #2034 place';
    return;
  end if;

  -- (a) take #2033's placement back out, if this database has it
  v_stripped := regexp_replace(
    v_src,
    '\n[ ]*-- CMD #2033.*?mode_outbound_blocked\(pp\.is_synthetic, pp\.zone_id, pp\.test_session_id\)\)',
    '',
    'is');

  -- (b) put it back below the per-user switch
  v_new := regexp_replace(
    v_stripped,
    '(return jsonb_build_object\(''ok'', false, ''reason'',''user_opted_out''\);\s*\n\s*end if;\s*\n)',
    E'\\1'
    || E'\n'
    || '  -- CMD #2034 — the zone-99 hard wall on the send lane. It sits BELOW the'   || E'\n'
    || '  -- per-user switch so an opt-out still reports itself as one, and ABOVE'    || E'\n'
    || '  -- push and every WhatsApp path so a synthetic or test-zone row never'      || E'\n'
    || '  -- leaves the building.'                                                    || E'\n'
    || '  if exists (select 1 from public.orders o'                                   || E'\n'
    || '              where o.id = v_order'                                           || E'\n'
    || '                and public.mode_outbound_blocked(o.is_synthetic, o.zone_id, o.test_session_id))' || E'\n'
    || '     or exists (select 1 from public.pharmacy_profiles pp'                    || E'\n'
    || '                 where pp.id = v_cust'                                        || E'\n'
    || '                   and public.mode_outbound_blocked(pp.is_synthetic, pp.zone_id, pp.test_session_id))' || E'\n'
    || '  then'                                                                       || E'\n'
    || '    perform public.notify_log(p_event_key, v_ph, v_channel, ''skipped'', ''none'',' || E'\n'
    || '      null, ''test_mode_silenced'', null, v_order, v_cust, v_vars);'          || E'\n'
    || '    return jsonb_build_object(''ok'', false, ''reason'',''test_mode_silenced'');' || E'\n'
    || '  end if;'                                                                    || E'\n',
    '');

  if v_new = v_stripped then
    raise exception 'c2034: notify_raw user_opted_out anchor not found — the send-lane wall was NOT placed';
  end if;

  execute v_new;
  raise notice 'c2034: notify_raw send-lane zone-99 wall placed below the per-user switch';
end $mig2034$;

-- ── the second half of the same red: a tokenless caller must be RECORDED ───
-- privileged_rpcs_are_not_anon names the first offender it finds and stops, so
-- the run that filed this command showed only _zone_avail_sync. On live the
-- rule (prefixes _zone_%, zone_%, storefront_%, …) actually matches SIX
-- functions that anon can execute, all six from the zone-availability work:
-- _zone_avail_sync, _zone_avail_sync_trg, zone_avail_backfill,
-- zone_availability_contract, zone_available and zone_available_products.
-- None is called from Dart — they are internal helpers behind the catalogue
-- and cart RPCs, which are SECURITY DEFINER and so do not need the caller to
-- hold EXECUTE. #2033's file revokes them; this file only has to outlive it.
--
-- The seventh is not a mistake but a missing record: CMD #2026 grants anon
-- EXECUTE on public.storefront_search_bar() on purpose (the storefront search
-- bar renders for a logged-out visitor, exactly like storefront_page and
-- storefront_search_page, both of which are already on the allow list) and did
-- not write the matching rpc_anon_allow row. The guard offers precisely two
-- endings — revoke it, or record it — so it is recorded here, idempotently and
-- ahead of that deploy, instead of letting the guard go red on an intentional
-- grant. Inert until that function exists.
insert into public.rpc_anon_allow (fn_name, reason)
values ('storefront_search_bar',
        'CMD #2026 — the storefront search-bar spec renders for a logged-out visitor, like storefront_page/storefront_search_page. Recorded by CMD #2034.')
on conflict (fn_name) do nothing;

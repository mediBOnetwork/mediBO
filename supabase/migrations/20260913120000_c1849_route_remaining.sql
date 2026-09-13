-- ===========================================================================
-- CMD #1849 — the last two outbound call sites.
--
-- outbound_leak_scan() is the standing answer to "is every outbound effect
-- routed?", and it named two functions the first pass did not wrap:
--
--   _pa_ai_enqueue  — posts a payment alert to the payment-alert-ai edge
--                     function, which spends AI tokens and writes back to
--                     payment_alerts. A fake alert created by a test session
--                     must not buy a real inference.
--   geo_enqueue     — asks nominatim.openstreetmap.org to geocode an address.
--                     A third party, hit from our IP, for a row that does not
--                     exist outside the session.
--
-- The backstop trigger on net.http_request_queue already stopped both of them
-- reaching the wire; what it could not do is SAY so. A blocked request that
-- appears in the receipt only as 'net.http_request' is the silence this whole
-- command exists to end. Routed, each one becomes a line of the transcript in
-- the caller's own words, and the scan goes clean for the right reason.
--
-- Idempotent: the rename is _c1849_rename_once, the bodies are
-- create-or-replace, the registry rows are upserts.
-- ===========================================================================

do $wrap3$
begin
  perform public._c1849_rename_once('_pa_ai_enqueue(uuid)', '_pa_ai_enqueue_raw');
  perform public._c1849_rename_once('geo_enqueue(text,text,text)', 'geo_enqueue_raw');
end $wrap3$;

-- ---------------------------------------------------------------------------
-- The payment-alert AI parse. Returns void, so a sandboxed call is simply a
-- call that did nothing — exactly what the caller already tolerates, since the
-- sweep re-picks any alert the enqueue could not place.
-- ---------------------------------------------------------------------------
do $pa$
begin
  if to_regprocedure('public._pa_ai_enqueue_raw(uuid)') is null then
    return;   -- nothing to wrap on this database
  end if;
  execute $fn$
    create or replace function public._pa_ai_enqueue(p_alert_id uuid)
     returns void language plpgsql security definer set search_path to 'public'
    as $body$
    declare g jsonb;
    begin
      begin
        g := public.outbound_dispatch('api', 'payment_alert_ai', null, null, null, null, null,
               jsonb_build_object('fn','_pa_ai_enqueue', 'template','payment_alert_ai',
                                  'recipient_label',
                                  public.uic('outbound.recipient_ai','the AI payment-alert parser'),
                                  'alert_id', p_alert_id));
      exception when others then
        g := null;          -- fail OPEN on real work: a broken dispatcher must
      end;                  -- never stop a real alert being parsed
      if g is not null and g->>'decision' <> 'send' then
        return;
      end if;
      perform public._pa_ai_enqueue_raw(p_alert_id);
    end $body$;
  $fn$;
end $pa$;

-- ---------------------------------------------------------------------------
-- Geocoding. The queue row is still written and still returned, so every
-- caller's contract is unchanged; only the request to the third party is held.
-- The row stays 'queued', which is the same state geo.geocode_enabled=false
-- leaves behind — a state the sweep already knows how to live with.
-- ---------------------------------------------------------------------------
do $geo$
begin
  if to_regprocedure('public.geo_enqueue_raw(text,text,text)') is null then
    return;
  end if;
  execute $fn$
    create or replace function public.geo_enqueue(p_kind text, p_query text, p_ref text default null)
     returns bigint language plpgsql security definer set search_path to 'public'
    as $body$
    declare g jsonb; v_id bigint;
    begin
      begin
        g := public.outbound_dispatch('api', 'geocode', null, btrim(coalesce(p_query,'')),
               null, null, null,
               jsonb_build_object('fn','geo_enqueue','template','geocode',
                                  'recipient_label',
                                  public.uic('outbound.recipient_geo','the map service'),
                                  'kind', p_kind, 'ref', p_ref));
      exception when others then
        g := null;          -- fail OPEN on real work
      end;
      if g is not null and g->>'decision' <> 'send' then
        -- The row the caller is owed, without the request to the third party.
        if nullif(btrim(coalesce(p_query,'')),'') is null then return null; end if;
        select id into v_id from public.geo_lookup_queue
         where query = btrim(p_query) and status in ('queued','sent') limit 1;
        if v_id is not null then return v_id; end if;
        insert into public.geo_lookup_queue (kind, ref_id, query, status)
        values (p_kind, p_ref, btrim(p_query), 'queued')
        returning id into v_id;
        return v_id;
      end if;
      return public.geo_enqueue_raw(p_kind, p_query, p_ref);
    end $body$;
  $fn$;
end $geo$;

-- The raw bodies are ours alone, exactly like the other nineteen.
do $rev3$
declare r record;
begin
  for r in select p.oid::regprocedure::text as sig from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('_pa_ai_enqueue_raw','geo_enqueue_raw')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $rev3$;

-- The wrappers keep the grants their originals had.
do $grant3$
begin
  if to_regprocedure('public.geo_enqueue(text,text,text)') is not null then
    execute 'grant execute on function public.geo_enqueue(text,text,text) to authenticated, service_role';
  end if;
  if to_regprocedure('public._pa_ai_enqueue(uuid)') is not null then
    execute 'grant execute on function public._pa_ai_enqueue(uuid) to service_role';
  end if;
end $grant3$;

insert into public.outbound_route (fn_name, kind, note) values
  ('_pa_ai_enqueue','routed','the payment-alert AI parse — a fake alert must not buy a real inference'),
  ('geo_enqueue','routed','address geocoding against a third party')
on conflict (fn_name) do update set kind = excluded.kind, note = excluded.note;

-- The transcript needs a sentence for each of them; every other line already
-- has one. Wording is an UPDATE, never a deploy.
insert into public.ui_copy (key, value) values
  ('receipt.channel.api',        to_jsonb('External services'::text)),
  ('receipt.line.api',           to_jsonb('Would have called {who}'::text)),
  ('outbound.recipient_ai',      to_jsonb('the AI payment-alert parser'::text)),
  ('outbound.recipient_geo',     to_jsonb('the map service'::text))
on conflict (key) do nothing;

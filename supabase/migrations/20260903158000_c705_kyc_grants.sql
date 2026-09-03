-- CHANGE #705 (9/9) — the grants, found by this command's own journey.
--
-- Postgres grants EXECUTE on a new function to PUBLIC by default, so every one
-- of the fourteen kyc_* functions was reachable with the bundled anon key the
-- moment it was created — including kyc_expiry_sweep() (tokenless compute on a
-- 1 GB instance, and it writes rg_alerts) and kyc_drive_send() (it would fan
-- WhatsApp messages out to all 46 accounts). This is the class bug-436 and
-- bug-683 already retired twice; their probes only sweep admin_*/pack_* and
-- the zone/storefront jobs, so a new prefix walked straight past them, and
-- c705-kyc-pharmacy-chain is now the third fence for it.
--
-- Body-level guards were already in place (kyc_can_review, role_for_medibo_
-- only, kyc_owner_for_me), so nothing was exploitable through the review or
-- drive RPCs — but a grant is not a guard, and an unguarded sweep is.
-- Idempotent: revoke/grant are declarative.

do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname like 'kyc\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $do$;

-- The applicant's own surface: their panel and their upload, nothing else.
grant execute on function public.kyc_my_panel() to authenticated;
grant execute on function public.kyc_owner_for_me() to authenticated;
grant execute on function public.kyc_upload_register(text,text,text,text,date,date,text,bigint)
  to authenticated;

-- The review console (admin + zone-scoped partner; the body decides which).
grant execute on function public.kyc_can_review(text) to authenticated;
grant execute on function public.kyc_review_queue(text,text,integer,integer) to authenticated;
grant execute on function public.kyc_review_set(uuid,text,text) to authenticated;

-- The backfill drive card and its send button (admin-only in the body).
grant execute on function public.kyc_drive_card() to authenticated;
grant execute on function public.kyc_drive_send(text,integer) to authenticated;

-- The ONE anonymous door: the token page a WhatsApp browser opens.
grant execute on function public.kyc_token_form(text) to anon, authenticated;
grant execute on function public.kyc_token_submit(text,text,text,date,text) to anon, authenticated;

-- kyc_state / kyc_gate / kyc_supplier_blocked are ENGINE internals: every
-- caller is a SECURITY DEFINER function (cart_rx_gate, the approval trigger,
-- the inquiry waterfall, kyc_my_panel), which needs no grant. Handing them to
-- authenticated would let any login read another pharmacy's KYC state by id.
-- kyc_expiry_sweep runs on the cron dispatcher as the definer; a client must
-- never be able to start it.
grant execute on function public.kyc_expiry_sweep() to service_role;

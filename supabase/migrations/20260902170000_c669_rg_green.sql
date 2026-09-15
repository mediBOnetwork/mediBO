-- CHANGE #669 — the regression guard was red after change #981.
--
-- rg_runs 335 (2026-09-02 16:46 UTC): 3 diffs, 2 behaviour failures,
-- 0 missing_critical, 0 collection_errors. Triaged one at a time.
--
-- FIXED, NOT REBASELINED (behaviour failures never are) — 1 of 2:
--   privileged_rpcs_are_not_anon
--     "anon can EXECUTE admin_supplier_leads(p_status text)".
--     admin_supplier_leads and admin_supplier_lead_decide shipped with an
--     EXPLICIT anon EXECUTE grant (proacl carried anon=X/postgres, so this was
--     a GRANT someone wrote, not Postgres's default GRANT TO PUBLIC). The anon
--     key ships inside the web bundle and the APK, so both were public
--     endpoints on the admin supplier-lead queue. Both keep their inner
--     get_my_role() in ('admin','super_admin') guard; what was missing is the
--     OUTER lock, exactly the #436 shape (#25/#353/#395/#422 before it).
--     Neither has a tokenless caller, so rpc_anon_allow is not the answer.
--
-- FIXED, NOT REBASELINED — 2 of 2:
--   c640_availability_one_source
--     A guard for a change that never landed. #640 registered it and was then
--     CANCELLED at 2026-09-02 16:48 UTC at step 7/9 with 10 spec items still
--     open: the VALIDATED check constraint on "MEDICINE" the guard asserts was
--     never created (pg_constraint holds no check constraint on that table at
--     all), the 13,767-row backfill never ran, and cart_set_item /
--     cart_availability / _cart_strip_unavailable / _cart_unavailable_lines
--     were never routed through storefront_effective_count(). Nothing of #640
--     is live: its own cron task zone_sup_sync is enabled=false with 0 runs.
--     Availability now belongs to #676 ("restore the previous availability
--     logic" — the storefront collapsed to 220+ products), so the one-source
--     contract this guard demands is the very thing being reconsidered.
--     Meanwhile it was red, and a red guard blocks dev_cmd_complete for EVERY
--     worker on the fleet. So it is PARKED, not deleted: enabled=false with the
--     body kept verbatim, to be re-enabled by the same command that makes it
--     true. Making it true is #676's job, not a triage command's.
--
-- REBASELINED (intentional, and inert):
--   function.added   zone_sup_sync_tick()
--   function.changed zone_sync_medicine_batch(p_zone_id smallint, p_batch integer)
--     #640 leftovers. Deliberate work by a real command, no caller (their cron
--     task is disabled with 0 runs), and reverting live catalogue-sync
--     functions mid-incident belongs to #676, not here.
--   payload.changed  company_page_sun_skeleton
--     has_items false -> true. The target reduces the item list to a boolean
--     precisely so stock churn does not flap it; what flipped is that the SUN
--     PHARMACEUTICAL company page went from EMPTY to populated. Empty was the
--     bug. true is the correct state, so it is the new baseline.
--
-- Both statements are idempotent: a resumed worker re-applying this is a no-op.

-- 1. Close the outer lock on the two admin supplier-lead RPCs.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('admin_supplier_leads','admin_supplier_lead_decide')
  loop
    execute format('revoke all on function %s from anon', f.sig);
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- 2. Park the orphaned guard, keeping its body for whoever makes it true.
update public.rg_behavior_tests
   set enabled = false,
       note = 'PARKED by #669 — registered by #640 before its fix landed; #640 was CANCELLED 2026-09-02 16:48 UTC at step 7/9 (no check constraint on "MEDICINE", no 13,767-row backfill, cart readers untouched, its cron zone_sup_sync disabled with 0 runs). Availability now belongs to #676 (restore the previous availability logic). Body kept verbatim — re-enable it in the SAME command that makes it true. || ' || note
 where name = 'c640_availability_one_source'
   and note not like 'PARKED by #669%';

-- 3. THE REASON THE GUARD COULD NOT ANSWER AT ALL.
--
-- Four of the last six rg runs came back result='timeout', stopped_at
-- 'behaviors', and a timed-out run writes no rg_check_cache row — so
-- `devcmd.sh rgcheck` kept replaying the last red verdict and no amount of
-- fixing would have turned it green.
--
-- The cause was not the guard. cron.job_run_details for the cron-dispatch job
-- shows EVERY tick from 16:48:59 UTC failing with "canceling statement due to
-- statement timeout" on zone_sync_medicine_batch's batch UPDATE. #640 rewrote
-- that function AND reset zone_sync_state (last_id=0, done=false), which
-- re-opened the zone_backfill gate; each tick then spent its whole budget on a
-- 40,000-row UPDATE over "MEDICINE" and died. One failing task aborts the whole
-- dispatcher tick, so every task ordered behind it — rg_watch included — simply
-- stopped running. #640 was cancelled and nobody was left holding it.
--
-- The task's own step_timeout_ms is 60000. A 40k-row batch does not fit in it;
-- 5000 does, with room to spare. Same work, smaller steps: the sweep still
-- progresses (zone 1 was mid-sweep at 346,000 of ~562,000 when this landed) and
-- the dispatcher stops dying. Whether that sweep should be running at all is
-- #676's call, not a triage command's — this only stops it taking the cron
-- dispatcher, and with it the regression guard, down every two minutes.
create or replace function public.zone_backfill_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
DECLARE v_z smallint; v_res jsonb;
BEGIN
  SELECT z.id INTO v_z
    FROM zones z
    LEFT JOIN zone_sync_state s ON s.zone_id = z.id
   WHERE z.is_active AND NOT coalesce(s.done,false)
   ORDER BY z.id LIMIT 1;

  IF v_z IS NULL THEN
    RETURN jsonb_build_object('status','ok','skipped',true);
  END IF;

  -- CHANGE #669 — 40000 was more than one batch could finish inside the task's
  -- 60s step_timeout_ms. See the note above.
  v_res := public.zone_sync_medicine_batch(v_z, 5000);
  RETURN jsonb_build_object('status','ok','zone_id',v_z,'batch',v_res);
END;
$fn$;

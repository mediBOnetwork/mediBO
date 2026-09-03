-- CHANGE #705 (7/8) — the four DB fixtures the approval guard caught.
--
-- (3/5) made "approved" conditional on a verified drug licence with a BEFORE
-- trigger, which is the point: it catches the admin console, an import and a
-- hand-written UPDATE alike. It also caught four proof fixtures that create a
-- throwaway approved pharmacy inside one call and delete it again
-- (c419_cohort_proof, c424_montikop_proof, c427_network_proof, px_proof_c420),
-- and through c424 it turned the REQUIRED journey qa-424-237 red for the whole
-- fleet. A fixture is not an onboarding decision.
--
-- The marker already existed: pharmacy_profiles.is_synthetic / supplier_
-- profiles.is_synthetic, which test_fixtures_ensure already sets and which
-- #857 already excludes from every money report. An applicant cannot set it —
-- it is not on submit_registration's allow-list. kyc_state now reports
-- enforce=false for a synthetic owner and the guard returns early on one; these
-- four fixtures just have to SAY they are fixtures.
--
-- Patched in place from the live definition so the change is one line per
-- insert instead of 32 KB of reproduced fixture, and skipped entirely once the
-- flag is there — a resumed worker re-applies this as a no-op.

do $do$
declare v_def text; v_new text;
begin
  -- c419 / c427: the cohort and network proofs, one insert each in a loop
  foreach v_def in array array['c419_cohort_proof','c427_network_proof'] loop
    declare v_name text := v_def; v_src text;
    begin
      select pg_get_functiondef(p.oid) into v_src from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname = v_name;
      if v_src is null or v_src like '%is_synthetic%' then continue; end if;
      v_new := replace(v_src, 'zone_id, approved, status)',
                              'zone_id, approved, status, is_synthetic)');
      v_new := replace(v_new, 'else v_small end, true, ''approved'')',
                              'else v_small end, true, ''approved'', true)');
      if v_new = v_src then
        raise exception 'c705: % fixture patch did not apply', v_name;
      end if;
      execute v_new;
    end;
  end loop;

  -- c424: the montikop fixture qa-424-237 reads
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'c424_montikop_proof';
  if v_def is not null and v_def not like '%is_synthetic%' then
    v_new := replace(v_def, 'address, city, pincode, approved, status)',
                            'address, city, pincode, approved, status, is_synthetic)');
    v_new := replace(v_new, '''proof'', ''proof'', ''000000'', true, ''approved'')',
                            '''proof'', ''proof'', ''000000'', true, ''approved'', true)');
    if v_new = v_def then raise exception 'c705: c424 fixture patch did not apply'; end if;
    execute v_new;
  end if;

  -- px_proof_c420: two shops, same column list twice
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'px_proof_c420';
  if v_def is not null and v_def not like '%is_synthetic%' then
    v_new := replace(v_def, 'is_deleted, zone_id, latitude, longitude, gst_no, drug_license,',
                            'is_deleted, is_synthetic, zone_id, latitude, longitude, gst_no, drug_license,');
    v_new := replace(v_new, 'true, ''active'', false, v_zone,',
                            'true, ''active'', false, true, v_zone,');
    if v_new = v_def then raise exception 'c705: c420 fixture patch did not apply'; end if;
    execute v_new;
  end if;
end $do$;

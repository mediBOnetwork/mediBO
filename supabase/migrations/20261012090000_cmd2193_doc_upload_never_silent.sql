-- CMD #2193 — "That upload did not go through. Try again." and Mandatory
-- papers stuck at 0 of 3, with NOTHING in the kyc-docs bucket.
--
-- WHAT ACTUALLY HAPPENED. The file never reached storage, because the step
-- BEFORE storage threw. Registration v4 saves a paper the moment it is picked,
-- and a shop that has no profile row yet gets one first
-- (custreg_ensure_profile -> submit_registration -> insert pharmacy_profiles).
-- Four columns on that table are NOT NULL with no default — pharmacy_name,
-- address, city, pincode — and submit_registration inserts only the keys it is
-- given. A paper picked before the Location step is filled in therefore ended
-- as SQLSTATE 23502, "null value in column \"address\" ... violates not-null
-- constraint", which the screen caught and drew as the generic upload failure.
-- Reproduced live on test.cust1 before this migration:
--   custreg_ensure_profile({}) -> 23502 on address.
--
-- TWO FIXES, both idempotent:
--  1. Those four columns get a DEFAULT of ''. The NOT NULL stays — nothing may
--     store a null — but a profile may now be created from what is known so
--     far, which is exactly what an early paper needs. The Location step fills
--     the real values in the same draft.
--  2. custreg_ensure_profile stops being able to raise at all. Anything the
--     insert throws comes back as ok:false with the backend's own message plus
--     `detail` (the sqlstate and the message) for the app's log, so a failure
--     of this class is never again a blank "try again".
--
-- And the counter: `mandatory_done` is already counted from kyc_documents by
-- custreg_licences_block. It read 0 of 3 because nothing was stored; with the
-- store working it follows the rows. The screen now re-reads the block after
-- every save attempt so the count can never lag what is in the table.

begin;

-- ── 1. a profile may be created from what is known so far ──────────────────
alter table public.pharmacy_profiles alter column pharmacy_name set default '';
alter table public.pharmacy_profiles alter column address       set default '';
alter table public.pharmacy_profiles alter column city          set default '';
alter table public.pharmacy_profiles alter column pincode       set default '';

-- ── 2. copy: the words this failure speaks are the backend's ───────────────
insert into public.ui_copy (key, value) values
  ('custreg.err_profile_first',
   to_jsonb('We could not start your registration. Try once more.'::text))
on conflict (key) do nothing;

-- ── 3. ensure_profile never raises ─────────────────────────────────────────
create or replace function public.custreg_ensure_profile(p_values jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_cid uuid := public._custreg_owner(null); v_sub jsonb; v_vals jsonb;
  v_state text; v_msg text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in',
      'message', public._c('custreg.err_not_signed_in'));
  end if;
  if v_cid is not null then
    return jsonb_build_object('ok', true, 'customer_id', v_cid, 'created', false);
  end if;
  v_vals := (public.customer_reg_draft_get('signup') - '_step' - '_seen' - '_early')
            || coalesce(p_values, '{}'::jsonb);
  begin
    v_sub := public.submit_registration('pharmacy',
               jsonb_strip_nulls(jsonb_build_object(
                 'pharmacy_name', nullif(btrim(coalesce(v_vals->>'pharmacy_name','')),''),
                 'customer_name', nullif(btrim(coalesce(v_vals->>'customer_name','')),''),
                 'whatsapp_no',   nullif(btrim(coalesce(v_vals->>'whatsapp_no','')),''),
                 'phone',         nullif(btrim(coalesce(v_vals->>'phone','')),''),
                 'email',         nullif(btrim(coalesce(v_vals->>'email','')),''),
                 'store_type',    nullif(btrim(coalesce(v_vals->>'store_type','')),''),
                 'address',       nullif(btrim(coalesce(v_vals->>'address','')),''),
                 'city',          nullif(btrim(coalesce(v_vals->>'city','')),''),
                 'district',      nullif(btrim(coalesce(v_vals->>'district','')),''),
                 'state',         nullif(btrim(coalesce(v_vals->>'state','')),''),
                 'pincode',       nullif(btrim(coalesce(v_vals->>'pincode','')),''))));
  exception when others then
    -- The whole point of this command: a failure here used to surface as
    -- "that upload did not go through", with the real reason lost. It is
    -- carried back now, named, for the app to log.
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    return jsonb_build_object('ok', false, 'error','profile_failed',
      'message', public._c('custreg.err_profile_first'),
      'detail', v_state || ': ' || coalesce(v_msg,''));
  end;
  v_cid := nullif(v_sub->>'id','')::uuid;
  if v_cid is null then
    return jsonb_build_object('ok', false, 'error','save_failed',
      'message', public._c('custreg.err_save'));
  end if;
  update public.pharmacy_profiles
     set zone_id = coalesce(public.zone_resolve(district, city, false), zone_id)
   where id = v_cid;
  perform public.customer_reg_draft_save(jsonb_build_object('_early', true), 'signup');
  return jsonb_build_object('ok', true, 'customer_id', v_cid, 'created', true);
end $fn$;

comment on function public.custreg_ensure_profile(jsonb) is
  'CMD #2193 — makes the profile an early paper needs, and can no longer raise: a failed insert comes back as ok:false with the backend message and a sqlstate detail for the log.';

commit;

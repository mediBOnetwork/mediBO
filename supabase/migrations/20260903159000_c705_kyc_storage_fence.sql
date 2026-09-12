-- CHANGE #705 (10/10) — the storage fence, both halves of it.
--
-- Two holes the journeys could not see, because neither lives in SQL:
--
-- 1. The applicant's panel uploaded to `<owner_id>/…` — the PROFILE id — while
--    kyc_docs_owner_write admits only `<auth.uid()>/…`. Every authenticated
--    upload would have been refused by RLS at the storage layer, with the RPC
--    never reached. kyc_my_panel() now NAMES the prefix (upload_prefix, the way
--    the token page always did) and the panel renders it instead of guessing.
--
-- 2. Only an admin could READ the object. A zone-scoped partner holding
--    partner.kyc_review could see the row in the queue and could not open the
--    document — so "view doc, then verify or reject" was half a surface for
--    exactly the reviewer the spec put in the console. kyc_can_review('read')
--    is the same answer the queue itself gives, so the two can never disagree.
--
-- Read also admits the owner's PROFILE folder: a document filed under the
-- profile id (the token path, or a hand-fixed row) must stay readable by the
-- account it belongs to. Write stays on the one canonical prefix.
-- Idempotent throughout.

drop policy if exists kyc_docs_owner_read on storage.objects;
create policy kyc_docs_owner_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'kyc-docs'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or (storage.foldername(name))[1] in (
            select id::text from public.pharmacy_profiles where user_id = (select auth.uid())
            union all
            select id::text from public.supplier_profiles where user_id = (select auth.uid()))
      or public.get_my_role() in ('admin','super_admin')
      or public.kyc_can_review('read')
    )
  );

drop policy if exists kyc_docs_owner_write on storage.objects;
create policy kyc_docs_owner_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'kyc-docs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

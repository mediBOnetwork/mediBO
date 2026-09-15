-- replay-target: production
--   This file names feature_registry, which is in scripts/control_plane_tables.txt,
--   so the replay heuristic would route it to BOTH databases. Everything else in
--   here — my_account_tab_profile, pharmacy_profiles, kyc_documents, _acct840_*,
--   customer_feature_placement — exists on production ONLY, so a control-plane
--   pass dies on the first missing relation and takes the whole batch down with
--   it (that is what happened to #992 in batch 585). The customer's account tab
--   is a production concern either way.

-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1834 — Undo the Profile & KYC merge that #1815 (CHANGE #1194) made.
--
-- #1815 was right about the cart: a pharmacy mediBO has already approved by
-- hand is never stopped from ordering by a document, and the warning it shows
-- is a small chip. None of that is touched here.
--
-- Where it went too far was the profile area. Instead of simply retiring the
-- second "Edit profile" screen, it MOVED that screen's form INTO
-- My Account -> Profile & KYC as `{"kind":"embed","widget":"profile_form"}`.
-- Profile & KYC is the licence page; it is not the place a shop edits its
-- delivery address, its business details or its contact numbers.
--
-- So the tab goes back to the block list it had before CHANGE #1194 — the
-- Account facts with the KYC chip on them, Documents on file, and the
-- Licence & documents panel — and the profile form is not one of them.
--
-- What #1815 fixed and this KEEPS:
--   * the documents list reads owner_kind in ('pharmacy','customer').
--     kyc_upload_register writes 'pharmacy', so the pre-#1194 'customer'-only
--     read left this list permanently empty. Restoring THAT would be
--     restoring a bug, not a screen.
--   * every block carries its own `section` key, so the KYC chip's View action
--     (route_key cust_account / tab_key profile / section kyc) still lands on
--     Licence & documents instead of the top of the tab.
--
-- Idempotent: create or replace + a guarded update. Safe to replay on live.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.my_account_tab_profile()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  pp public.pharmacy_profiles%rowtype;
  v_kyc jsonb; v_zone text; v_docs jsonb;
begin
  pp := public._acct840_me();
  if pp.id is null then return public._acct840_deny(); end if;

  v_kyc  := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);
  v_zone := (select z.name from public.zones z where z.id = pp.zone_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'title',    coalesce(nullif(d.file_name,''), initcap(replace(d.kind,'_',' '))),
           'subtitle', initcap(replace(d.kind,'_',' '))
                       || case when coalesce(d.number,'') <> '' then '  ·  '||d.number else '' end,
           'meta',     case when d.valid_to is null then ''
                            else to_char(d.valid_to,'FMDD Mon YYYY') end,
           'chip',     public._acct840_chip(
                         initcap(replace(coalesce(d.status,'pending'),'_',' ')),
                         case when coalesce(d.status,'') in ('verified','approved') then
                                case when d.valid_to is not null and d.valid_to < current_date
                                     then 'danger' else 'success' end
                              when coalesce(d.status,'') in ('rejected') then 'danger'
                              else 'warning' end))
         order by d.created_at desc), '[]'::jsonb)
    into v_docs
    from public.kyc_documents d
   where d.owner_kind in ('pharmacy','customer') and d.owner_id = pp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    -- The facts that are NOT editable anywhere: who this account is to us.
    -- The KYC chip rides this block, so it is the first thing on the tab.
    jsonb_build_object('kind','kv','title', public._c('acct.p_account'),
      'section','account',
      'chip', v_kyc->'chip',
      'rows', jsonb_build_array(
        jsonb_build_object('label', public._c('acct.p_code'), 'value', public._acct840_v(pp.customer_code)),
        jsonb_build_object('label', public._c('acct.p_zone'), 'value', public._acct840_v(v_zone)),
        jsonb_build_object('label', public._c('acct.p_term'), 'value', public._acct840_v(pp.payment_term)))),
    jsonb_build_object('kind','list','title', public._c('acct.p_docs_title'),
                       'section','documents',
                       'empty', public._c('acct.p_docs_note'), 'items', v_docs),
    -- Licence & documents: drug licence, GST certificate, shop photo. This is
    -- where every KYC chip in the app lands.
    jsonb_build_object('kind','embed','widget','kyc_panel','section','kyc')));
end
$function$;

-- The second profile screen stays retired. #1815 deactivated this placement;
-- the row is re-asserted here so a replay on any environment ends the same
-- way, and CMD #1834 deletes the screen it pointed at.
update public.customer_feature_placement cp
   set is_active = false
  from public.feature_registry f
 where f.feature_key = cp.feature_key
   and f.route_key = 'cust_profile_edit'
   and cp.is_active is distinct from false;

-- The customer menu still offered "Edit my details" -> /customer/profile, the
-- door to the screen this command deletes. It is retired and recorded as
-- folded into My Account, so the feature map says where it went instead of
-- losing it. The Dart route survives as a redirect for old links only.
update public.feature_registry
   set is_active   = false,
       merged_into = 'cust.my_account'
 where route_key = 'cust_profile_edit'
   and (is_active is distinct from false or merged_into is distinct from 'cust.my_account');

-- CHANGE #236 (part 2) — make the new invoice fields REACHABLE.
--
-- The admin "Platform Details" dialog (Admin -> UPI & Partners -> Platform
-- Details -> Edit) renders whatever partner_screen_config().platform_fields
-- lists and saves through admin_save_platform_identity(). Both are backend
-- driven, so adding the invoice fields here puts them in front of Om with no
-- Flutter change and no deploy.
--
-- partner_screen_config() is a large hand-written function; rather than restate
-- it (and risk dropping an unrelated key), we patch its source in place and
-- guard on the marker so a re-run is a no-op.

do $patch$
declare src text; anchor text; addition text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'partner_screen_config';
  if src is null then
    raise notice 'partner_screen_config not found — skipping';
    return;
  end if;
  if position('bill_seller_fssai' in src) > 0 then
    raise notice 'invoice fields already present — skipping';
    return;
  end if;

  anchor := E'        union all select 13, jsonb_build_object(''key'',''mission''';
  if position(anchor in src) = 0 then
    raise exception 'partner_screen_config: anchor not found, refusing to patch';
  end if;

  addition :=
    E'        union all select 20, jsonb_build_object(''key'',''bill_seller_fssai'',''label'',''FSSAI Licence (on invoice)'',''type'',''text'',''value'',coalesce(bc.seller_fssai,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 21, jsonb_build_object(''key'',''bill_seller_phone'',''label'',''Invoice Contact Phone'',''type'',''text'',''value'',coalesce(bc.seller_phone,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 22, jsonb_build_object(''key'',''bill_seller_email'',''label'',''Invoice Contact Email'',''type'',''text'',''value'',coalesce(bc.seller_email,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 23, jsonb_build_object(''key'',''bill_bank_name'',''label'',''Bank Name (on invoice)'',''type'',''text'',''value'',coalesce(bc.bank_name,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 24, jsonb_build_object(''key'',''bill_bank_account'',''label'',''Bank Account Number'',''type'',''text'',''value'',coalesce(bc.bank_account,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 25, jsonb_build_object(''key'',''bill_bank_ifsc'',''label'',''Bank IFSC'',''type'',''text'',''value'',coalesce(bc.bank_ifsc,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 26, jsonb_build_object(''key'',''bill_bank_branch'',''label'',''Bank Branch'',''type'',''text'',''value'',coalesce(bc.bank_branch,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 27, jsonb_build_object(''key'',''bill_jurisdiction'',''label'',''Invoice Jurisdiction Line'',''type'',''text'',''value'',coalesce(bc.jurisdiction,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 28, jsonb_build_object(''key'',''bill_default_hsn'',''label'',''Default HSN Code'',''type'',''text'',''value'',coalesce(bc.default_hsn,'''')) from billing_config bc where bc.id=1\n'
 || E'        union all select 29, jsonb_build_object(''key'',''bill_invoice_terms'',''label'',''Invoice Terms Line'',''type'',''multiline'',''value'',coalesce(bc.invoice_terms,'''')) from billing_config bc where bc.id=1\n';

  execute replace(src, anchor, addition || anchor);
end $patch$;

-- The same dialog's save path. Keys are prefixed bill_ so they can never
-- collide with a platform_identity column.
create or replace function public.admin_save_platform_identity(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  update platform_identity set
    platform_name       = coalesce(p->>'platform_name', platform_name),
    tagline             = coalesce(p->>'tagline', tagline),
    operator_legal_name = coalesce(p->>'operator_legal_name', operator_legal_name),
    business_name       = coalesce(p->>'business_name', business_name),
    udyam_no            = coalesce(p->>'udyam_no', udyam_no),
    nic_line            = coalesce(p->>'nic_line', nic_line),
    address             = coalesce(p->>'address', address),
    phone               = coalesce(p->>'phone', phone),
    email               = coalesce(p->>'email', email),
    established         = coalesce(p->>'established', established),
    constitution        = coalesce(p->>'constitution', constitution),
    about_paragraph     = coalesce(p->>'about_paragraph', about_paragraph),
    mission             = coalesce(p->>'mission', mission),
    updated_at          = now()
  where id = 1;

  -- CHANGE #236: the invoice half of the same form. An empty string clears the
  -- field (that is how the dialog says "remove this line from the invoice").
  if p ?| array['bill_seller_fssai','bill_seller_phone','bill_seller_email',
                'bill_bank_name','bill_bank_account','bill_bank_ifsc','bill_bank_branch',
                'bill_jurisdiction','bill_default_hsn','bill_invoice_terms'] then
    update billing_config set
      seller_fssai  = case when p ? 'bill_seller_fssai'  then nullif(btrim(p->>'bill_seller_fssai'),'')  else seller_fssai  end,
      seller_phone  = case when p ? 'bill_seller_phone'  then nullif(btrim(p->>'bill_seller_phone'),'')  else seller_phone  end,
      seller_email  = case when p ? 'bill_seller_email'  then nullif(btrim(p->>'bill_seller_email'),'')  else seller_email  end,
      bank_name     = case when p ? 'bill_bank_name'     then nullif(btrim(p->>'bill_bank_name'),'')     else bank_name     end,
      bank_account  = case when p ? 'bill_bank_account'  then nullif(btrim(p->>'bill_bank_account'),'')  else bank_account  end,
      bank_ifsc     = case when p ? 'bill_bank_ifsc'     then nullif(btrim(p->>'bill_bank_ifsc'),'')     else bank_ifsc     end,
      bank_branch   = case when p ? 'bill_bank_branch'   then nullif(btrim(p->>'bill_bank_branch'),'')   else bank_branch   end,
      jurisdiction  = case when p ? 'bill_jurisdiction'  then nullif(btrim(p->>'bill_jurisdiction'),'')  else jurisdiction  end,
      default_hsn   = case when p ? 'bill_default_hsn'   then nullif(btrim(p->>'bill_default_hsn'),'')   else default_hsn   end,
      invoice_terms = case when p ? 'bill_invoice_terms' then nullif(btrim(p->>'bill_invoice_terms'),'') else invoice_terms end
    where id = 1;
  end if;

  return jsonb_build_object('ok', true, 'message', 'Platform details saved.');
end $fn$;

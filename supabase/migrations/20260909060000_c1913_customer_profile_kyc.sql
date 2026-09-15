-- CMD #1913 — Customer page > Profile & KYC, and the road from an upload to a
-- verdict.
--
-- Three separate faults, all proven on live before a line was written:
--
--  1. `admin_customer_tab` is SHARED between the admin customer page and the
--     customer's own My Account page. It grew `audience` / `cust_label` /
--     `cust_rpc` / `cust_sort` for the customer half, but admin_customer_page()
--     was never taught to read `audience`. So SIX customer-only tabs (profile,
--     shop, statement, calendar, rewards, preferences) were offered to admins,
--     and each one derived a function name that does not exist:
--         PostgrestException: public.admin_customer_tab_profile(p_customer_id)
--         does not exist
--     Fixed twice over: the list now filters on `audience`, AND it refuses to
--     offer a tab whose RPC is not installed. A missing function is an absent
--     tab, never an exception in a reviewer's face.
--
--  2. Profile & KYC is a tab an admin genuinely wants on a customer, so
--     `profile` joins the admin audience for real: admin_customer_tab_profile()
--     is created here and shows the licence facts, the KYC verdict and every
--     document the shop uploaded — with Verify / Reject on each pending one,
--     so a reviewer never has to leave the customer to clear them.
--
--  3. The verdict never came back. `_cus810_kyc()` — the chip on the admin Info
--     tab AND on the customer's own Profile & KYC tab — asked
--     rx_licence_state(), which reads pharmacy_profiles.dl_20b / dl_21b /
--     drug_license / dl_expiry and has never once looked at kyc_documents.
--     Approving a drug licence in KYC review therefore changed nothing anyone
--     could see. It is document-aware from here: kyc_state() decides whenever
--     the shop has actually uploaded something, and the licence columns stay as
--     the fallback for the shops that only ever typed a number in.
--
--  4. kyc_review_queue() counted and scoped off partner_zone_id() while the
--     dashboard badge that points at it (dash_kyc_review) scoped off
--     admin_active_zone() / admin_active_date(). Badge and queue could disagree
--     the moment a super admin touched the header picker. The queue now reads
--     the same two functions, so zone and date live only in the header.
--
-- Idempotent: every statement is CREATE OR REPLACE / INSERT ... ON CONFLICT /
-- UPDATE, and the guard at the foot re-asserts the outcome rather than trusting
-- the replay.

-- ── 1. Tabs an admin is offered ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_customer_page(p_customer_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := public._cus810_gate();
  pp pharmacy_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb; v_cfg jsonb;
  v_phone text; v_wa text; v_last timestamptz; v_idle int; v_days int;
  v_appr text; v_rej text; v_susp text; v_blocked boolean;
begin
  if v_role = 'none' then return public._cus810_deny(false); end if;
  pp := public._cus810_row(p_customer_id);
  if pp.id is null then return public._cus810_deny(false); end if;

  v_cfg  := coalesce((select value from app_settings where key='customer_status_values'),'{}'::jsonb);
  v_appr := coalesce(v_cfg->>'approved','approved');
  v_rej  := coalesce(v_cfg->>'rejected','rejected');
  v_susp := coalesce(v_cfg->>'suspended','suspended');
  v_blocked := lower(coalesce(pp.status,'')) = lower(v_susp);
  v_kyc  := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);
  v_days := coalesce((select (value#>>'{}')::int from app_settings where key='customer_churn_days'), 30);

  select max(o.created_at) into v_last from orders o
   where o.id = any (public._cus810_order_ids(pp.id));
  v_idle := case when v_last is null then null
                 else ((now() at time zone 'Asia/Kolkata')::date
                       - (v_last at time zone 'Asia/Kolkata')::date) end;

  v_phone := coalesce(nullif(btrim(coalesce(pp.phone,'')),''),
                      nullif(btrim(coalesce(pp.whatsapp_no,'')),''),
                      nullif(btrim(coalesce(pp.other_contact_no,'')),''));
  v_wa    := public._cus810_wa(coalesce(nullif(pp.whatsapp_no,''), v_phone));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label, 'icon', coalesce(t.icon_key,''),
           'rpc', coalesce(nullif(t.rpc,''), 'admin_customer_tab_'||t.tab_key))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_customer_tab t
   where t.is_active
     -- CMD #1913 — admin_customer_tab is SHARED with the customer's own My
     -- Account page (cust_label / cust_rpc / cust_sort). Six rows on it are
     -- customer-only (profile, shop, statement, calendar, rewards,
     -- preferences) and this list never looked at `audience`, so the admin
     -- customer page offered all six and every one of them blew up with
     -- `public.admin_customer_tab_<key>(p_customer_id) does not exist`.
     and ('admin' = any (coalesce(t.audience, array['admin'::text])))
     -- Belt and braces: a tab whose RPC is not actually installed is never
     -- offered. A missing function is now a tab that is absent, never a tab
     -- that throws PostgrestException in the user's face.
     and exists (select 1
                   from pg_proc p2
                   join pg_namespace n2 on n2.oid = p2.pronamespace
                  where n2.nspname = 'public'
                    and p2.proname = coalesce(nullif(t.rpc,''),
                                              'admin_customer_tab_'||t.tab_key))
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'customer_id', pp.id,
    'title', coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                      nullif(btrim(coalesce(pp.customer_name,'')),''),
                      nullif(btrim(coalesce(pp.owner_name,'')),''), '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(pp.owner_name, pp.customer_name,'')),''),
        nullif(btrim(coalesce(pp.customer_code,'')),''),
        nullif(btrim(coalesce(pp.city,'')),''),
        nullif(btrim(coalesce(pp.state,'')),'')], null), '  ·  '),
    'phone', coalesce(v_phone,''),
    'contacts', (case when coalesce(v_phone,'') = '' then '[]'::jsonb
                 else jsonb_build_array(jsonb_build_object(
                        'key','call','label',public._c('admin_cus2.call_label'),
                        'url','tel:'||regexp_replace(v_phone,'[^0-9+]','','g'))) end)
                || (case when v_wa is null then '[]'::jsonb
                    else jsonb_build_array(jsonb_build_object(
                        'key','whatsapp','label',public._c('admin_cus2.wa_label'),'url', v_wa)) end),
    'back_label', public._c('admin_cus2.back'),
    'chips', jsonb_build_array(v_kyc->'chip'),
    'code_label', coalesce(nullif(btrim(coalesce(pp.customer_code,'')),''),
                           public._c('admin_cus2.no_code')),
    'city_label', coalesce(nullif(btrim(coalesce(pp.city,'')),''), '—'),
    'zone_label', coalesce((select z.name from zones z where z.id = pp.zone_id),
                           public._c('admin_cus2.no_zone')),
    'term_label', coalesce(nullif(btrim(coalesce(pp.payment_term,'')),''),
                           public._c('admin_cus2.term_none')),
    -- The approval dropdown the old card carried as three buttons. The options
    -- are ACTIONS, not statuses: each names admin_customer_action_reason and
    -- says whether it must collect a reason first.
    'status', jsonb_build_object(
      'label', public._c('admin_cus2.st_label'),
      'value', coalesce(pp.status, ''),
      'rpc', 'admin_customer_action_reason',
      'args', jsonb_build_object('p_customer_id', pp.id),
      'arg', 'p_action',
      'reason_arg', 'p_reason',
      'saved_label', public._c('admin_cus2.st_saved'),
      'reason_prompt', jsonb_build_object(
        'title', public._c('admin_cus2.reason_title'),
        'body',  public._c('admin_cus2.reason_body'),
        'hint',  public._c('admin_cus2.reason_hint'),
        'ok',    public._c('admin_cus2.reason_ok'),
        'cancel',public._c('admin_cus2.reason_cancel'),
        'error', public._c('admin_cus2.reason_error')),
      'options', jsonb_build_array(
        jsonb_build_object('value','approve','label',public._c('admin_cus2.st_approve'),'needs_reason',false),
        jsonb_build_object('value','reject', 'label',public._c('admin_cus2.st_reject'), 'needs_reason',true),
        jsonb_build_object('value','block',  'label',public._c('admin_cus2.st_block'),  'needs_reason',true),
        jsonb_build_object('value','unblock','label',public._c('admin_cus2.st_unblock'),'needs_reason',false))),
    'churn', case when (v_last is null or v_idle >= v_days) then jsonb_build_object(
        'has', true,
        'label', case when v_last is null then public._c('admin_cus2.churn_never')
                      else replace(public._c('admin_cus2.churn_chip'),'{n}', v_idle::text) end,
        'nudge', case when v_wa is null then jsonb_build_object('has', false)
                 else jsonb_build_object(
                   'has', true,
                   'label', public._c('admin_cus2.nudge_label'),
                   'rpc', 'admin_customer_churn_nudge',
                   'args', jsonb_build_object('p_customer_id', pp.id)) end)
      else jsonb_build_object('has', false) end,
    'edit', jsonb_build_object(
      'label', public._c('admin_cus2.e_open'),
      'form_rpc','admin_customer_edit_form',
      'save_rpc','admin_customer_edit_save',
      'args', jsonb_build_object('p_customer_id', pp.id),
      'arg', 'p_patch'),
    'note_add', jsonb_build_object(
      'label', public._c('admin_cus2.note_add'),
      'title', public._c('admin_cus2.note_title'),
      'hint',  public._c('admin_cus2.note_hint'),
      'ok',    public._c('admin_cus2.note_ok'),
      'cancel',public._c('admin_cus2.reason_cancel'),
      'rpc',   'admin_customer_note_add',
      'args',  jsonb_build_object('p_customer_id', pp.id),
      'arg',   'p_body',
      'date_arg', 'p_remind_on'),
    'merge', jsonb_build_object(
      'label', public._c('admin_cus2.menu_merge'),
      'title', public._c('admin_cus2.m_title'),
      'rpc',   'admin_customer_merge_preview',
      'args',  jsonb_build_object('p_customer_id', pp.id)),
    'zone_set', jsonb_build_object(
      'title', public._c('admin_cus2.zone_title'),
      'rpc',   'admin_customer_set_zone',
      'args',  jsonb_build_object('p_customer_id', pp.id),
      'arg',   'p_zone_id',
      'saved_label', public._c('admin_cus2.zone_saved'),
      'value', coalesce(pp.zone_id, 0),
      'options', coalesce((select jsonb_agg(jsonb_build_object('value', z.id, 'label', z.name)
                                            order by z.id) from zones z), '[]'::jsonb)),
    'menu', public._cus810_menu(pp.id, coalesce(nullif(pp.whatsapp_no,''), v_phone),
                                v_blocked, coalesce(pp.is_deleted,false)),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','info'),
    'empty_label', public._c('admin_cus2.tab_empty'));
end $function$

;

-- ── 2. `profile` becomes a tab an admin also gets ─────────────────────────
-- The row already exists for the customer's own account page (cust_rpc =
-- my_account_tab_profile). Adding 'admin' to its audience is what puts
-- Profile & KYC on the customer page an admin opens; sort_order 15 sits it
-- directly after Info, where a reviewer looks first. `label` (the admin-side
-- caption) and `cust_label` are independent columns, so the customer's own
-- menu is untouched.
insert into public.admin_customer_tab
  (tab_key, label, feature_key, sort_order, icon_key, audience, cust_label, cust_rpc, cust_sort)
values
  ('profile', 'Profile & KYC', null, 15, 'badge',
   array['admin','customer']::text[], 'Profile & KYC', 'my_account_tab_profile', 10)
on conflict (tab_key) do update
  set label       = excluded.label,
      sort_order  = excluded.sort_order,
      icon_key    = coalesce(nullif(admin_customer_tab.icon_key,''), excluded.icon_key),
      audience    = (select array_agg(distinct a order by a)
                       from unnest(coalesce(admin_customer_tab.audience, '{}'::text[])
                                   || array['admin','customer']::text[]) a),
      cust_label  = coalesce(nullif(admin_customer_tab.cust_label,''), excluded.cust_label),
      cust_rpc    = coalesce(nullif(admin_customer_tab.cust_rpc,''), excluded.cust_rpc),
      cust_sort   = coalesce(admin_customer_tab.cust_sort, excluded.cust_sort),
      is_active   = true;

-- Every other row keeps an explicit audience so the filter above is never
-- guessing. Rows seeded by CHANGE #810 are admin-side by definition.
update public.admin_customer_tab
   set audience = array['admin']::text[]
 where audience is null or cardinality(audience) = 0;

-- ── 3. Copy the new tab renders ───────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_cus2.p_title',        to_jsonb('Profile & KYC'::text)),
  ('admin_cus2.p_status',       to_jsonb('KYC status'::text)),
  ('admin_cus2.p_state',        to_jsonb('Status'::text)),
  ('admin_cus2.p_licence',      to_jsonb('Drug licence'::text)),
  ('admin_cus2.p_expiry',       to_jsonb('Licence expiry'::text)),
  ('admin_cus2.p_gstin',        to_jsonb('GSTIN'::text)),
  ('admin_cus2.p_pan',          to_jsonb('PAN'::text)),
  ('admin_cus2.p_docs',         to_jsonb('Uploaded documents'::text)),
  ('admin_cus2.p_docs_empty',   to_jsonb('This shop has not uploaded anything yet. Ask them to add a drug licence from My Account → Profile & KYC.'::text)),
  ('admin_cus2.p_open_review',  to_jsonb('Open KYC review'::text)),
  ('admin_cus2.p_uploaded',     to_jsonb('Uploaded {age}'::text)),
  ('admin_cus2.p_no_expiry',    to_jsonb('No expiry on file'::text)),
  ('admin_cus2.p_reject_title', to_jsonb('Reject this document?'::text)),
  ('admin_cus2.p_reject_body',  to_jsonb('The shop sees your reason word for word, and can upload a replacement.'::text)),
  ('admin_cus2.p_reject_ok',    to_jsonb('Reject'::text)),
  ('admin_cus2.p_reject_cancel',to_jsonb('Cancel'::text)),
  ('admin_cus2.kyc_pending',    to_jsonb('KYC awaiting review'::text)),
  ('admin_cus2.kyc_rejected',   to_jsonb('KYC rejected'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 4. The KYC chip becomes document-aware ────────────────────────────────
-- This is fault (3). rx_licence_state() reads pharmacy_profiles.dl_20b /
-- dl_21b / drug_license / dl_expiry — typed-in numbers — and has never looked
-- at kyc_documents. Every chip in the customer console and on the customer's
-- own My Account page therefore said "KYC missing" no matter how many licences
-- had been uploaded and verified.
--
-- kyc_state() is the document truth and already reports missing / pending /
-- rejected / expired / verified off kyc_documents. It WINS whenever the shop
-- has actually uploaded a document; the licence columns remain the fallback for
-- the shops that only ever typed a number in, so nothing that reads clean today
-- starts reading dirty.
create or replace function public._cus810_kyc(p_customer_id uuid, p_gstin text, p_gst_no text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_lic jsonb; v_state text; v_gst text;
  v_docs jsonb; v_doc_state text; v_has_docs boolean;
begin
  v_lic := public.rx_licence_state(p_customer_id);
  v_gst := coalesce(nullif(btrim(coalesce(p_gstin,'')),''), nullif(btrim(coalesce(p_gst_no,'')),''));

  v_has_docs := exists (select 1 from public.kyc_documents
                         where owner_kind in ('pharmacy','customer')
                           and owner_id = p_customer_id
                           and status <> 'superseded');

  if v_has_docs then
    v_docs := public.kyc_state('pharmacy', p_customer_id);
    v_doc_state := coalesce(v_docs->>'state','');
    v_state := case v_doc_state
                 when 'verified' then case when v_gst is null then 'missing' else 'ok' end
                 when 'expired'  then 'expired'
                 when 'pending'  then 'pending'
                 when 'rejected' then 'rejected'
                 else 'missing' end;
  else
    v_state := case
      when coalesce((v_lic->>'expired')::boolean,false) then 'expired'
      when coalesce((v_lic->>'has')::boolean,false) and v_gst is not null then 'ok'
      else 'missing' end;
  end if;

  return jsonb_build_object(
    'state', v_state,
    'doc_state', coalesce(v_doc_state,''),
    'from_documents', v_has_docs,
    'licence', coalesce(v_lic->>'licence',''),
    'expiry_label', case when (v_lic->>'expiry') is null then ''
                         else to_char((v_lic->>'expiry')::date,'FMDD Mon YYYY') end,
    'chip', jsonb_build_object(
      'show', true,
      'label', case v_state when 'ok'       then public._c('admin_cus2.kyc_ok')
                            when 'expired'  then public._c('admin_cus2.kyc_expired')
                            when 'pending'  then public._c('admin_cus2.kyc_pending')
                            when 'rejected' then public._c('admin_cus2.kyc_rejected')
                            else public._c('admin_cus2.kyc_missing') end,
      'bg',     case v_state when 'ok' then '#D1FAE5'
                             when 'expired' then '#FEE2E2'
                             when 'rejected' then '#FEE2E2'
                             when 'pending' then '#EFF6FF' else '#FEF3C7' end,
      'fg',     case v_state when 'ok' then '#065F46'
                             when 'expired' then '#991B1B'
                             when 'rejected' then '#991B1B'
                             when 'pending' then '#1E40AF' else '#92400E' end,
      'border', case v_state when 'ok' then '#A7F3D0'
                             when 'expired' then '#FECACA'
                             when 'rejected' then '#FECACA'
                             when 'pending' then '#BFDBFE' else '#FDE68A' end));
end $$;

-- ── 5. The tab itself ─────────────────────────────────────────────────────
-- Profile facts, the KYC verdict, and every document the shop uploaded. A
-- pending document carries Verify / Reject inline (kyc_review_set, the same RPC
-- the KYC review console calls, with the same authorisation), so a reviewer
-- clears a shop without leaving it. Zone comes from _cus810_row(), which reads
-- admin_active_zone(): a partner opening a customer outside their zone gets the
-- same "not found" the other tabs give.
create or replace function public.admin_customer_tab_profile(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._cus810_gate();
  pp pharmacy_profiles%rowtype;
  v_kyc jsonb; v_state jsonb; v_docs jsonb;
  v_can_write boolean;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_role = 'none' then return public._cus810_deny(false); end if;
  pp := public._cus810_row(p_customer_id);
  if pp.id is null then return public._cus810_deny(false); end if;

  v_kyc   := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);
  v_state := public.kyc_state('pharmacy', pp.id);
  v_can_write := public.kyc_can_review('write');

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(public._c('kyc.kind.'||d.kind),''),
                             initcap(replace(d.kind,'_',' '))),
           'subtitle', array_to_string(array_remove(array[
                         nullif(btrim(coalesce(d.file_name,'')),''),
                         nullif(btrim(coalesce(d.number,'')),'')], null), '  ·  '),
           'meta', array_to_string(array_remove(array[
                     nullif(replace(public._c('admin_cus2.p_uploaded'), '{age}',
                                    public._ist_age(d.submitted_at)),''),
                     case when d.valid_to is null then public._c('admin_cus2.p_no_expiry')
                          else to_char(d.valid_to,'FMDD Mon YYYY') end,
                     nullif(btrim(coalesce(d.reason,'')),'')], null), '  ·  '),
           'chip', jsonb_build_object(
             'show', true,
             'label', coalesce(nullif(public._c('kyc.status.'||d.status),''),
                               initcap(replace(d.status,'_',' '))),
             'bg',     case when d.status = 'verified' and (d.valid_to is null or d.valid_to >= v_today) then '#D1FAE5'
                            when d.status in ('rejected','verified') then '#FEE2E2'
                            when d.status = 'pending' then '#EFF6FF' else '#F3F4F6' end,
             'fg',     case when d.status = 'verified' and (d.valid_to is null or d.valid_to >= v_today) then '#065F46'
                            when d.status in ('rejected','verified') then '#991B1B'
                            when d.status = 'pending' then '#1E40AF' else '#4B5563' end,
             'border', case when d.status = 'verified' and (d.valid_to is null or d.valid_to >= v_today) then '#A7F3D0'
                            when d.status in ('rejected','verified') then '#FECACA'
                            when d.status = 'pending' then '#BFDBFE' else '#E5E7EB' end),
           'actions', case when d.status = 'pending' and v_can_write then jsonb_build_array(
               jsonb_build_object(
                 'label', public._c('kyc_review.btn_verify'),
                 'tone',  'success',
                 'rpc',   'kyc_review_set',
                 'args',  jsonb_build_object('p_doc_id', d.id, 'p_status', 'verified')),
               jsonb_build_object(
                 'label', public._c('kyc_review.btn_reject'),
                 'tone',  'danger',
                 'rpc',   'kyc_review_set',
                 'args',  jsonb_build_object('p_doc_id', d.id, 'p_status', 'rejected'),
                 'confirm', jsonb_build_object(
                   'title',        public._c('admin_cus2.p_reject_title'),
                   'body',         public._c('admin_cus2.p_reject_body'),
                   'ok',           public._c('admin_cus2.p_reject_ok'),
                   'cancel',       public._c('admin_cus2.p_reject_cancel'),
                   'needs_reason', true,
                   'reason_arg',   'p_reason',
                   'reason_hint',  public._c('kyc_review.reason_hint'),
                   'reason_error', public._c('kyc_review.err_no_reason'))))
             else '[]'::jsonb end)
         order by (d.status <> 'pending'), d.submitted_at desc nulls last), '[]'::jsonb)
    into v_docs
    from public.kyc_documents d
   where d.owner_kind in ('pharmacy','customer')
     and d.owner_id = pp.id
     and d.status <> 'superseded';

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','kv','title', public._c('admin_cus2.p_status'),
      'section','kyc',
      'chip', v_kyc->'chip',
      'rows', jsonb_build_array(
        public._cus810_kv(public._c('admin_cus2.p_state'),
                          coalesce(nullif(public._c('kyc.status.'||coalesce(v_state->>'state','')),''),
                                   v_kyc->'chip'->>'label')),
        public._cus810_kv(public._c('admin_cus2.p_licence'),
                          coalesce(nullif(v_kyc->>'licence',''),
                                   nullif(btrim(coalesce(pp.dl_20b,'')),''),
                                   nullif(btrim(coalesce(pp.dl_21b,'')),''),
                                   pp.drug_license)),
        public._cus810_kv(public._c('admin_cus2.p_expiry'),
                          coalesce(nullif(v_state->>'expiry_label',''), v_kyc->>'expiry_label')),
        public._cus810_kv(public._c('admin_cus2.p_gstin'),
                          coalesce(nullif(btrim(coalesce(pp.gstin,'')),''), pp.gst_no)))),
    jsonb_build_object('kind','list','title', public._c('admin_cus2.p_docs'),
      'section','documents',
      'empty', public._c('admin_cus2.p_docs_empty'),
      'items', v_docs)));
end $$;

grant execute on function public.admin_customer_tab_profile(uuid) to authenticated, service_role;

-- ── 6. The queue reads the header, exactly like the badge that points at it ─
CREATE OR REPLACE FUNCTION public.kyc_review_queue(p_status text DEFAULT 'pending'::text, p_owner_kind text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status text := lower(coalesce(nullif(p_status,''),'pending'));
  v_kind   text := nullif(lower(btrim(coalesce(p_owner_kind,''))),'');
  -- CMD #1913 — zone and date live ONLY in the header picker. This used to
  -- read partner_zone_id() and let any admin see every zone, while the
  -- dashboard badge that points here (dash_kyc_review) already scoped on
  -- admin_active_zone() / admin_active_date(). Badge and queue could therefore
  -- disagree the moment a super admin changed the picker. Both read the same
  -- two functions now: a partner is pinned to their own zone (partner_zone_id()
  -- wins inside admin_active_zone()), a super admin with no zone picked sees
  -- every zone, a picked zone scopes them, and staff land on their own zone.
  v_admin  boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone   int := public.admin_active_zone();
  v_date   date := public.admin_active_date();
  v_end    timestamptz;
  v_lim    int := least(greatest(coalesce(p_limit,50),1), 200);
  v_off    int := greatest(coalesce(p_offset,0),0);
  v_rows jsonb; v_total int; v_pending int; v_auto int;
begin
  v_end := case when v_date is null then null
                else ((v_date + 1)::timestamp at time zone 'Asia/Kolkata') end;
  if not public.kyc_can_review('read') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'title', _c('kyc_review.title'),
      'message', _c('kyc_review.err_not_authorized'));
  end if;

  with scoped as (
    select d.*,
           case d.owner_kind when 'pharmacy' then p.pharmacy_name else s.supplier_name end as owner_name,
           case d.owner_kind when 'pharmacy' then p.phone         else s.phone         end as owner_phone,
           case d.owner_kind when 'pharmacy' then p.city          else s.city          end as owner_city
      from kyc_documents d
      left join pharmacy_profiles p on d.owner_kind = 'pharmacy' and p.id = d.owner_id
      left join supplier_profiles s on d.owner_kind = 'supplier' and s.id = d.owner_id
     where d.status = v_status
       and (v_kind is null or d.owner_kind = v_kind)
       and (v_zone is null or coalesce(d.zone_id, -1) = v_zone)
       and (v_end is null or d.created_at < v_end)
  )
  select coalesce(jsonb_agg(r order by ord), '[]'::jsonb), max(n_total)
    into v_rows, v_total
  from (
    select row_number() over (order by submitted_at desc) as ord,
           count(*) over () as n_total,
           jsonb_build_object(
             'doc_id', id,
             'owner_kind', owner_kind,
             'owner_id', owner_id,
             'owner_name', coalesce(owner_name,''),
             'owner_city', coalesce(owner_city,''),
             'kind', kind,
             'kind_label', _c('kyc.kind.'||kind),
             'number', coalesce(number,''),
             'number_label', _c('kyc.number_label'),
             'valid_to', valid_to,
             'expiry_label', case when valid_to is null then _c('kyc.no_expiry_label')
                                  else _cf('kyc.expiry_label',
                                         jsonb_build_object('d', to_char(valid_to,'FMDD Mon YYYY'))) end,
             'bucket', bucket,
             'path', path,
             'file_name', coalesce(file_name,''),
             'status', status,
             'status_label', _c('kyc.status.'||status),
             'status_tone', case status when 'verified' then 'success'
                                        when 'rejected' then 'danger' else 'info' end,
             'reason', coalesce(reason,''),
             'submitted_label', _cf('kyc_review.submitted_label',
                                  jsonb_build_object('age', _ist_age(submitted_at))),
             'view_label', _c('kyc_review.btn_view'),
             'verify_label', _c('kyc_review.btn_verify'),
             'reject_label', _c('kyc_review.btn_reject'),
             -- CMD #1889 — the expiry a reviewer confirms or corrects. The
             -- date OCR read is shown next to the field so confirming is one
             -- tap; a DIFFERENT date is a manual entry and the backend then
             -- demands a reason.
             'can_set_expiry', kind = 'drug_licence',
             'expiry_title',   _c('kyc_expiry.title'),
             'expiry_edit_label', _c('kyc_expiry.edit_label'),
             'expiry_field_label', _c('kyc_expiry.field_label'),
             'expiry_number_label', _c('kyc_expiry.number_label'),
             'expiry_save_label', _c('kyc_expiry.save_label'),
             'expiry_reason_label', _c('kyc_expiry.reason_label'),
             'expiry_reason_hint', _c('kyc_expiry.reason_hint'),
             'ocr_expiry',     (select nullif(btrim(coalesce(x.fields->>'valid_to','')),'')
                                  from kyc_doc_extract x where x.doc_id = id),
             'ocr_number',     (select coalesce(nullif(btrim(coalesce(x.fields->>'licence_number','')),''),'')
                                  from kyc_doc_extract x where x.doc_id = id),
             'ocr_read_label', case when exists (select 1 from kyc_doc_extract x
                                                  where x.doc_id = id and x.status = 'done'
                                                    and nullif(btrim(coalesce(x.fields->>'valid_to','')),'') is not null)
                                    then _c('kyc_expiry.read_label')
                                    else _c('kyc_expiry.none_label') end,
             -- CHANGE #706
             'verify', public.kyc_verify_panel(id)) as r
      from scoped
     order by submitted_at desc
     limit v_lim offset v_off
  ) x;

  select count(*) into v_pending from kyc_documents d
   where d.status = 'pending'
     and (v_zone is null or coalesce(d.zone_id,-1) = v_zone)
     and (v_end is null or d.created_at < v_end);

  select count(*) into v_auto from kyc_documents d
   where d.status = 'pending'
     and (v_zone is null or coalesce(d.zone_id,-1) = v_zone)
     and (v_end is null or d.created_at < v_end)
     and exists (select 1 from kyc_verify_run v where v.doc_id = d.id and v.tier = 'review');

  return jsonb_build_object(
    'ok', true,
    'title', _c('kyc_review.title'),
    'subtitle', _c('kyc_review.subtitle'),
    'empty_note', _c('kyc_review.empty'),
    'can_write', public.kyc_can_review('write'),
    'reason_label', _c('kyc_review.reason_label'),
    'reason_hint', _c('kyc_review.reason_hint'),
    'count_label', _cf('kyc_review.count_label', jsonb_build_object('n', v_pending)),
    'pending_count', v_pending,
    'flagged_count', v_auto,
    'flagged_label', case when v_auto = 0 then ''
                          else _cf('kyc_verify.mismatch_count', jsonb_build_object('n', v_auto)) end,
    'override_label', _c('kyc_verify.override_label'),
    'override_note_label', _c('kyc_verify.override_note_label'),
    'override_note_hint', _c('kyc_verify.override_note_hint'),
    'rerun_label', _c('kyc_verify.rerun_label'),
    'verify_title', _c('kyc_verify.title'),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','pending',  'label', _c('kyc_review.tab_pending')),
      jsonb_build_object('key','verified', 'label', _c('kyc_review.tab_verified')),
      jsonb_build_object('key','rejected', 'label', _c('kyc_review.tab_rejected'))),
    'status', v_status,
    'offset', v_off,
    'has_more', (v_off + v_lim) < coalesce(v_total, 0),
    'total', coalesce(v_total, 0),
    'rows', v_rows);
end $function$

;

grant execute on function public.kyc_review_queue(text,text,integer,integer) to authenticated, service_role;

-- ── 7. Guard: assert the outcome, do not trust the replay ─────────────────
do $c1913$
declare v_bad text;
begin
  if to_regprocedure('public.admin_customer_tab_profile(uuid)') is null then
    raise exception 'CMD #1913: admin_customer_tab_profile(uuid) was not created';
  end if;

  if not exists (select 1 from public.admin_customer_tab
                  where tab_key = 'profile' and is_active
                    and 'admin' = any (audience) and 'customer' = any (audience)) then
    raise exception 'CMD #1913: the profile tab is not offered to both audiences';
  end if;

  -- Every ACTIVE admin-audience tab must name a function that exists, or the
  -- customer page throws again the moment someone opens that tab.
  select string_agg(t.tab_key, ', ') into v_bad
    from public.admin_customer_tab t
   where t.is_active
     and 'admin' = any (coalesce(t.audience, array['admin'::text]))
     and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public'
                        and p.proname = coalesce(nullif(t.rpc,''),
                                                 'admin_customer_tab_'||t.tab_key));
  if v_bad is not null then
    raise exception 'CMD #1913: admin tabs with no RPC installed: %', v_bad;
  end if;

  if pg_get_functiondef('public.kyc_review_queue(text,text,integer,integer)'::regprocedure)
       not like '%admin_active_zone()%' then
    raise exception 'CMD #1913: kyc_review_queue no longer reads admin_active_zone()';
  end if;
  if pg_get_functiondef('public._cus810_kyc(uuid,text,text)'::regprocedure)
       not like '%kyc_state(%' then
    raise exception 'CMD #1913: _cus810_kyc is not document-aware';
  end if;
end $c1913$;

-- CHANGE #705 (2/5) — the verify surface.
--
-- An admin, or a partner holding partner.kyc_review, opens the queue, looks at
-- the document and either verifies it or rejects it WITH A REASON. The reason
-- is not a note for the reviewer: it reaches the applicant, in the app and over
-- WhatsApp, because a rejection nobody can act on is the same as no answer.
--
-- Partners are zone-scoped (partner_zone_ok) and matrix-gated (partner_can) —
-- the same two guards every other partner surface uses. Idempotent throughout.

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   canonical_key, description)
values
  ('partner.kyc_review', 'KYC review', 'Customers & Suppliers', 'fact_check', 'kyc_review',
   95, 'partner', true, 'none', true, 'parties', 'dashboard',
   array['admin','super_admin'], 'partner.kyc_review',
   'Verify or reject the drug licence and GST certificate a pharmacy or supplier uploaded.')
on conflict (feature_key) do nothing;

insert into public.ui_copy (key, value) values
  ('kyc_review.title',        to_jsonb('KYC review'::text)),
  ('kyc_review.subtitle',     to_jsonb('Documents waiting to be verified.'::text)),
  ('kyc_review.tab_pending',  to_jsonb('Pending'::text)),
  ('kyc_review.tab_verified', to_jsonb('Verified'::text)),
  ('kyc_review.tab_rejected', to_jsonb('Rejected'::text)),
  ('kyc_review.empty',        to_jsonb('Nothing waiting. Every document has been reviewed.'::text)),
  ('kyc_review.btn_verify',   to_jsonb('Verify'::text)),
  ('kyc_review.btn_reject',   to_jsonb('Reject'::text)),
  ('kyc_review.btn_view',     to_jsonb('View document'::text)),
  ('kyc_review.reason_hint',  to_jsonb('Tell them what is wrong — they see this word for word.'::text)),
  ('kyc_review.reason_label', to_jsonb('Reason for rejection'::text)),
  ('kyc_review.count_label',  to_jsonb('{n} waiting'::text)),
  ('kyc_review.verified_toast', to_jsonb('Verified.'::text)),
  ('kyc_review.rejected_toast', to_jsonb('Rejected. The applicant has been told why.'::text)),
  ('kyc_review.err_not_authorized', to_jsonb('You do not have access to KYC review.'::text)),
  ('kyc_review.err_no_doc',   to_jsonb('That document no longer exists.'::text)),
  ('kyc_review.err_no_reason',to_jsonb('A rejection needs a reason the applicant can act on.'::text)),
  ('kyc_review.err_bad_status', to_jsonb('A document can only be verified or rejected.'::text)),
  ('kyc_review.submitted_label', to_jsonb('Uploaded {age}'::text)),
  ('kyc.inbox_verified_title', to_jsonb('Document verified'::text)),
  ('kyc.inbox_verified_body',  to_jsonb('Your {label} has been verified. Your account is clear to trade.'::text)),
  ('kyc.inbox_rejected_title', to_jsonb('Document rejected'::text)),
  ('kyc.inbox_rejected_body',  to_jsonb('Your {label} was rejected: {reason}. Please upload a corrected copy.'::text))
on conflict (key) do nothing;

-- The WhatsApp route the rejection/verification rides. notif_render substitutes
-- DOUBLE braces here — ui_copy above uses single braces. Two renderers, one
-- feature; getting this wrong prints the raw token to a pharmacy.
insert into public.wa_event_routes (event_key, label, description, audience, enabled,
                                    push_enabled, push_title, push_body)
values
  ('kyc_document_verified', 'KYC document verified',
   'Sent to a pharmacy or supplier when a reviewer verifies an uploaded document.',
   'customer', true, true, 'Document verified',
   'Your {{label}} has been verified. Your mediBO account is clear to trade.'),
  ('kyc_document_rejected', 'KYC document rejected',
   'Sent to a pharmacy or supplier when a reviewer rejects an uploaded document, carrying the reason.',
   'customer', true, true, 'Document rejected',
   'Your {{label}} was rejected: {{reason}}. Please upload a corrected copy at {{link}}')
on conflict (event_key) do nothing;

-- ── may this session review, and over which zones? ─────────────────────────
create or replace function public.kyc_can_review(p_need text default 'read')
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select public.role_for_medibo_only() in ('admin','super_admin')
      or public.partner_can('partner.kyc_review', coalesce(p_need,'read'));
$fn$;

-- ── the queue ──────────────────────────────────────────────────────────────
create or replace function public.kyc_review_queue(
  p_status text default 'pending', p_owner_kind text default null,
  p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_status text := lower(coalesce(nullif(p_status,''),'pending'));
  v_kind   text := nullif(lower(btrim(coalesce(p_owner_kind,''))),'');
  v_admin  boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone   int := public.partner_zone_id();
  v_lim    int := least(greatest(coalesce(p_limit,50),1), 200);
  v_off    int := greatest(coalesce(p_offset,0),0);
  v_rows jsonb; v_total int; v_pending int;
begin
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
       and (v_admin or v_zone is null or coalesce(d.zone_id, -1) = v_zone)
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
             'reject_label', _c('kyc_review.btn_reject')) as r
      from scoped
     order by submitted_at desc
     limit v_lim offset v_off
  ) x;

  select count(*) into v_pending from kyc_documents d
   where d.status = 'pending' and (v_admin or v_zone is null or coalesce(d.zone_id,-1) = v_zone);

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
    'tabs', jsonb_build_array(
      jsonb_build_object('key','pending',  'label', _c('kyc_review.tab_pending')),
      jsonb_build_object('key','verified', 'label', _c('kyc_review.tab_verified')),
      jsonb_build_object('key','rejected', 'label', _c('kyc_review.tab_rejected'))),
    'status', v_status,
    'offset', v_off,
    'has_more', (v_off + v_lim) < coalesce(v_total, 0),
    'total', coalesce(v_total, 0),
    'rows', v_rows);
end
$fn$;

-- ── the verdict ────────────────────────────────────────────────────────────
create or replace function public.kyc_review_set(
  p_doc_id uuid, p_status text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  d kyc_documents%rowtype;
  v_status text := lower(btrim(coalesce(p_status,'')));
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_admin  boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone   int := public.partner_zone_id();
  v_label  text; v_phone text; v_uid uuid; v_name text;
begin
  if not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_review.err_not_authorized'));
  end if;
  if v_status not in ('verified','rejected') then
    return jsonb_build_object('ok', false, 'error','bad_status', 'tone','danger',
      'message', _c('kyc_review.err_bad_status'));
  end if;
  if v_status = 'rejected' and v_reason is null then
    return jsonb_build_object('ok', false, 'error','no_reason', 'tone','danger',
      'message', _c('kyc_review.err_no_reason'));
  end if;

  select * into d from kyc_documents where id = p_doc_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_doc', 'tone','danger',
      'message', _c('kyc_review.err_no_doc'));
  end if;
  if not v_admin and v_zone is not null and coalesce(d.zone_id,-1) <> v_zone then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_review.err_not_authorized'));
  end if;

  update kyc_documents
     set status = v_status, reason = v_reason,
         verified_by = auth.uid(), verified_at = now(), updated_at = now()
   where id = p_doc_id;

  v_label := _c('kyc.kind.'||d.kind);
  if d.owner_kind = 'pharmacy' then
    select coalesce(nullif(whatsapp_no,''), phone), user_id, pharmacy_name
      into v_phone, v_uid, v_name from pharmacy_profiles where id = d.owner_id;
  else
    select coalesce(nullif(whatsapp_no,''), phone), user_id, supplier_name
      into v_phone, v_uid, v_name from supplier_profiles where id = d.owner_id;
  end if;

  -- The applicant is told, in the app and over WhatsApp. Neither may stall the
  -- verdict: a missing route is not a reason to leave a document unreviewed.
  begin
    perform public.wa_send_event(
      case v_status when 'verified' then 'kyc_document_verified'
                    else 'kyc_document_rejected' end,
      case when d.owner_kind = 'pharmacy' then d.owner_id else null end,
      jsonb_build_object('label', v_label, 'reason', coalesce(v_reason,''),
                         'name', coalesce(v_name,''), 'link', 'https://medibo.in/'),
      v_phone, null);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'tone','success',
    'doc_id', p_doc_id, 'status', v_status,
    'message', case v_status when 'verified' then _c('kyc_review.verified_toast')
                             else _c('kyc_review.rejected_toast') end,
    'owner_state', public.kyc_state(d.owner_kind, d.owner_id));
end
$fn$;

grant execute on function public.kyc_can_review(text) to authenticated;
grant execute on function public.kyc_review_queue(text,text,integer,integer) to authenticated;
grant execute on function public.kyc_review_set(uuid,text,text) to authenticated;

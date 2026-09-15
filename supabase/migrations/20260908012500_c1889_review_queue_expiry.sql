-- CMD #1889 — the review queue carries the OCR read and the expiry-edit copy.
CREATE OR REPLACE FUNCTION public.kyc_review_queue(p_status text DEFAULT 'pending'::text, p_owner_kind text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status text := lower(coalesce(nullif(p_status,''),'pending'));
  v_kind   text := nullif(lower(btrim(coalesce(p_owner_kind,''))),'');
  v_admin  boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone   int := public.partner_zone_id();
  v_lim    int := least(greatest(coalesce(p_limit,50),1), 200);
  v_off    int := greatest(coalesce(p_offset,0),0);
  v_rows jsonb; v_total int; v_pending int; v_auto int;
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
   where d.status = 'pending' and (v_admin or v_zone is null or coalesce(d.zone_id,-1) = v_zone);

  select count(*) into v_auto from kyc_documents d
   where d.status = 'pending' and (v_admin or v_zone is null or coalesce(d.zone_id,-1) = v_zone)
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



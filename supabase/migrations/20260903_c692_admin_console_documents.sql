-- CHANGE #692 - the partner console carries the documents block.
-- Regenerated from the live definition with two keys added; nothing else moved.

CREATE OR REPLACE FUNCTION public.admin_partner_console(p_partner_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  rp record; v_feats jsonb; v_users jsonb; v_audit jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', coalesce(v_copy->>'err_not_authorized',''));
  end if;
  select * into rp from region_partners where id = p_partner_id;
  if rp.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message', coalesce(v_copy->>'err_partner_not_found',''));
  end if;

  select jsonb_agg(jsonb_build_object(
           'feature_key', fr.feature_key,
           'label', fr.label,
           'group_label', fr.group_label,
           'access', coalesce(pp.access,'none'),
           'options', jsonb_build_array(
             jsonb_build_object('value','none', 'label','No access',
                                'selected', coalesce(pp.access,'none')='none'),
             jsonb_build_object('value','read', 'label','View only',
                                'selected', coalesce(pp.access,'none')='read'),
             jsonb_build_object('value','write','label','Full access',
                                'selected', coalesce(pp.access,'none')='write')))
         order by fr.sort_order)
    into v_feats
  from feature_registry fr
  left join partner_permissions pp
         on pp.feature_key = fr.feature_key and pp.partner_id = p_partner_id
  where fr.is_active and fr.owner = 'partner' and fr.partner_eligible;

  select jsonb_agg(jsonb_build_object(
           'id', pu.id, 'identity', pu.identity,
           'display_name', coalesce(pu.display_name,''),
           'is_active', pu.is_active,
           'linked', (pu.auth_user_id is not null),
           'status_label', case when pu.auth_user_id is not null then 'Signed in'
                                else 'Waiting for first login' end,
           'added_label', to_char(pu.created_at at time zone 'Asia/Kolkata','dd Mon yyyy'))
         order by pu.id)
    into v_users
  from partner_users pu where pu.partner_id = p_partner_id and pu.is_active;

  -- CMD #467 row 155 — one composer for both surfaces.
  v_audit := public.admin_partner_audit_preview(p_partner_id, 25);

  return jsonb_build_object(
    'ok', true,
    'partner_id', rp.id,
    'partner_name', coalesce(rp.partner_name,''),
    'district', coalesce(rp.district,''),
    'zone_id', rp.zone_id,
    'zone_label', coalesce((select name from zones where id = rp.zone_id),''),
    'zone_locked_label', coalesce(v_copy->>'zone_locked_label',''),
    'users_title', coalesce(v_copy->>'users_title',''),
    'users_subtitle', coalesce(v_copy->>'users_subtitle',''),
    'add_label', coalesce(v_copy->>'add_label',''),
    'add_hint', coalesce(v_copy->>'add_hint',''),
    'name_hint', coalesce(v_copy->>'name_hint',''),
    'remove_label', coalesce(v_copy->>'remove_label',''),
    'empty_users', coalesce(v_copy->>'empty_users',''),
    'perm_title', coalesce(v_copy->>'perm_title',''),
    'perm_subtitle', coalesce(v_copy->>'perm_subtitle',''),
    'audit_title', coalesce(v_copy->>'audit_title',''),
    'empty_audit', coalesce(v_copy->>'empty_audit',''),
    -- CMD #467 row 155 — the door to the filterable, paged log. A build that
    -- has never heard of the screen simply renders no button.
    'audit_open', jsonb_build_object(
      'label', public.uic('partner_audit.open_label','View full activity'),
      'partner_id', rp.id),
    -- CHANGE #321: what the screen says when the RPC itself never answers.
    'failed_message', coalesce(v_copy->>'failed_message',''),
    -- CHANGE #352 — the Partner fence card: what this login can actually reach
    -- over the raw API. Composed entirely by partner_fence_card().
    'fence', public.partner_fence_card(),
    -- CMD #466 rows 153 + 154 — status/suspension and licence expiry.
    'lifecycle', public.partner_lifecycle_card(rp.id),
    'licences', public.partner_licence_card(rp.id),
    -- CHANGE #692 - the agreement this partner signed and the KYC documents
    -- they uploaded, plus the one sentence saying whether they may be given
    -- orders at all. Composed entirely by partner_documents_screen().
    'documents', public.partner_documents_screen(rp.id),
    'documents_open', jsonb_build_object(
      'label', public._c('partner_kyc.heading')),
    'users', coalesce(v_users,'[]'::jsonb),
    'features', coalesce(v_feats,'[]'::jsonb),
    'audit', coalesce(v_audit,'[]'::jsonb));
end $function$

;

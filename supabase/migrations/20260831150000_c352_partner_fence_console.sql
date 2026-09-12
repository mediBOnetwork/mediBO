-- CHANGE #352 — the fence needs a face. Rule 11: a backend a super-admin cannot
-- see and tap does not exist. This adds the Partner fence card to the screen
-- that already owns the partner's logins and matrix (Payment and Partner ->
-- a partner -> Partner console), so the reachable path is one that already
-- works rather than a new route nobody visits.
--
-- Every word on the card is composed HERE. Dart prints label/value/tone.

-- ---------------------------------------------------------------------------
-- 1. The copy.
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value)
values ('partner_admin_copy', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings set value = value || jsonb_build_object(
  'fence_title',        'Partner fence',
  'fence_subtitle',     'What a partner login can reach over the raw API, not just which tile it is shown.',
  'fence_ok_label',     'Enforced',
  'fence_bad_label',    'Not enforced',
  'fence_reachable',    'Fulfilment RPCs a partner may call',
  'fence_denied',       'Admin RPCs now closed to a partner',
  'fence_scoped',       'Fulfilment RPCs clamped to the partner zone',
  'fence_medibo',       'mediBO-only RPCs fenced off the partner surface',
  'fence_verify_label', 'Run the live check',
  'fence_verify_title', 'Live check, as this partner',
  'fence_pass_label',   'refused',
  'fence_fail_label',   'STILL OPEN',
  'fence_never_run',    'Not checked yet in this session.',
  'fence_unclamped',    'Clamp missing on'
) where key = 'partner_admin_copy';

-- ---------------------------------------------------------------------------
-- 2. The live check, wrapped for the screen. Super-admin only: it impersonates
--    the partner to reproduce each finding, and every write it makes is rolled
--    back by the proof itself.
-- ---------------------------------------------------------------------------
create or replace function public.partner_fence_verify()
 returns jsonb
 language plpgsql volatile security definer set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  v jsonb; v_rows jsonb;
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', coalesce(v_copy->>'err_not_authorized',''));
  end if;

  v := public.c352_partner_fence_proof();
  if coalesce((v->>'ok'), 'false') is null then
    return jsonb_build_object('ok', false, 'error','proof_failed');
  end if;

  select jsonb_agg(jsonb_build_object(
           'label', 'Gap #' || (e->>'gap_row') || ' · ' || (e->>'probe'),
           'value', case when (e->>'pass')::boolean
                         then coalesce(v_copy->>'fence_pass_label','')
                         else coalesce(v_copy->>'fence_fail_label','') end,
           'tone',  case when (e->>'pass')::boolean then 'success' else 'danger' end,
           'detail', (e->>'actual')))
    into v_rows
  from jsonb_array_elements(coalesce(v->'checks','[]'::jsonb)) e;

  return jsonb_build_object(
    'ok', (v->>'ok')::boolean,
    'title', coalesce(v_copy->>'fence_verify_title',''),
    'summary', (v->>'passed') || ' / ' || (v->>'total'),
    'tone', case when (v->>'ok')::boolean then 'success' else 'danger' end,
    'rows', coalesce(v_rows, '[]'::jsonb));
end $function$;

grant execute on function public.partner_fence_verify() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. The card itself, folded into the console payload the screen already reads.
-- ---------------------------------------------------------------------------
create or replace function public.partner_fence_card()
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  a jsonb := public.c352_partner_fence_audit();
begin
  return jsonb_build_object(
    'title',    coalesce(v_copy->>'fence_title',''),
    'subtitle', coalesce(v_copy->>'fence_subtitle',''),
    'status_label', case when (a->>'ok')::boolean
                         then coalesce(v_copy->>'fence_ok_label','')
                         else coalesce(v_copy->>'fence_bad_label','') end,
    'status_tone',  case when (a->>'ok')::boolean then 'success' else 'danger' end,
    'verify_label', coalesce(v_copy->>'fence_verify_label',''),
    'never_run',    coalesce(v_copy->>'fence_never_run',''),
    'rows', jsonb_build_array(
      jsonb_build_object('label', coalesce(v_copy->>'fence_denied',''),
                         'value', (a->>'partner_denied'), 'tone','success'),
      jsonb_build_object('label', coalesce(v_copy->>'fence_reachable',''),
                         'value', (a->>'partner_reachable'), 'tone','neutral'),
      jsonb_build_object('label', coalesce(v_copy->>'fence_scoped',''),
                         'value', (a->>'scoped_rpcs'),
                         'tone', case when (a->>'scoped_unclamped')::int = 0 then 'success' else 'danger' end),
      jsonb_build_object('label', coalesce(v_copy->>'fence_medibo',''),
                         'value', (a->>'medibo_only_registered'),
                         'tone', case when (a->>'medibo_only_ok')::boolean then 'success' else 'danger' end)
    ) || case when (a->>'scoped_unclamped')::int > 0
              then jsonb_build_array(jsonb_build_object(
                     'label', coalesce(v_copy->>'fence_unclamped',''),
                     'value', (select string_agg(x, ', ') from jsonb_array_elements_text(a->'scoped_unclamped_list') t(x)),
                     'tone','danger'))
              else '[]'::jsonb end
  );
end $function$;
grant execute on function public.partner_fence_card() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_partner_console() carries the card. Nothing else about it changes.
-- ---------------------------------------------------------------------------
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

  select jsonb_agg(jsonb_build_object(
           'id', al.id, 'feature_key', coalesce(al.feature_key,''),
           'action', al.action,
           'user_id', coalesce(al.user_id::text,''),
           'zone_id', al.zone_id,
           'at_label', to_char(al.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'))
         order by al.created_at desc)
    into v_audit
  from (select * from partner_audit_log where partner_id = p_partner_id
         order by created_at desc limit 25) al;

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
    -- CHANGE #321: what the screen says when the RPC itself never answers.
    'failed_message', coalesce(v_copy->>'failed_message',''),
    -- CHANGE #352 — the Partner fence card: what this login can actually reach
    -- over the raw API. Composed entirely by partner_fence_card().
    'fence', public.partner_fence_card(),
    'users', coalesce(v_users,'[]'::jsonb),
    'features', coalesce(v_feats,'[]'::jsonb),
    'audit', coalesce(v_audit,'[]'::jsonb));
end $function$;

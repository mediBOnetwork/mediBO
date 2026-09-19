-- CMD #2102 — push_admin_screen() gains 'refresh_label': the /admin/push AppBar
-- reload action (Semantics id push_admin_refresh) that feat-2102 taps to prove the
-- screen re-reads push_config_get() with the partner app id. Copy lives in ui_copy.
CREATE OR REPLACE FUNCTION public.push_admin_screen()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := public.role_for_medibo_only();
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('push.not_authorized','Not authorized'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'title',         public.uic('push_admin.title','Push notifications'),
    'config_title',  public.uic('push_admin.config_title','Firebase project'),
    'events_title',  public.uic('push_admin.events_title','Events'),
    'devices_title', public.uic('push_admin.devices_title','Registered devices'),
    'save_label',    public.uic('push_admin.save','Save'),
    'refresh_label', public.uic('push_admin.refresh','Reload'),
    'can_edit_config', v_role = 'super_admin',
    'config', public.push_config_get(),
    'devices', (select jsonb_build_object(
                  'active', count(*) filter (where is_active),
                  'total',  count(*),
                  'by_platform', coalesce(jsonb_object_agg(platform, c), '{}'::jsonb))
                from (select platform, count(*) c, bool_or(is_active) is_active
                        from push_tokens group by platform) p),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                   'event_key', event_key, 'label', label, 'audience', audience,
                   'push_enabled', push_enabled,
                   'push_title', push_title, 'push_body', push_body,
                   'push_title_hi', push_title_hi, 'push_body_hi', push_body_hi,
                   'ready', coalesce(nullif(btrim(push_body),''),'') <> ''
                 ) order by audience, label), '[]'::jsonb)
               from wa_event_routes));
end $function$

;

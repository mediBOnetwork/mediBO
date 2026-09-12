-- replay-target: production
-- CMD #1847 (QA fix) — the settings screen read a DIFFERENT zone than it wrote.
--
-- order_alert_settings() resolved the cut-off field with
--   v_zone := admin_active_zone()
-- while order_alert_settings_set() -> set_order_hours() writes to
--   zone_effective(admin_active_zone())
-- and the engine's _order_cutoff_at() falls back to the first zone that HAS a
-- cut-off. A super admin sits on "all zones", where admin_active_zone() is
-- NULL: `where h.zone_id = null` matches no row, so the field fell back to
-- cutoff_default_time and read back 12:00 while the clock, the console and
-- every order were already on 13:30. Om would have set the cut-off, seen the
-- old number and set it again.
--
-- One line: the READ resolves the zone exactly the way the WRITE does.
CREATE OR REPLACE FUNCTION public.order_alert_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cfg public.order_alert_config; v_phone text; v_open jsonb; v_log jsonb;
        v_zone smallint; v_cut time;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg := public._oa_cfg();
  v_phone := coalesce((select value #>> '{}' from public.app_settings
                        where key='admin_wa_phone'), '');
  -- CMD #1847 QA fix: zone_effective() is what set_order_hours() writes to.
  v_zone := public.zone_effective(public.admin_active_zone());
  select h.cutoff_time into v_cut from public.order_hours h where h.zone_id = v_zone;

  select coalesce(jsonb_agg(public._oa_item(a) order by a.created_at desc), '[]'::jsonb)
    into v_open
    from public.order_alert a where a.state = 'ringing';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id,
           'order_code', coalesce((select o.order_code from public.orders o where o.id = l.order_id),''),
           'supplier', coalesce(l.supplier_name,''),
           'allowed', l.allowed,
           'reason', coalesce(l.reason,''),
           'reason_label', public.oa_label(coalesce(l.detail->>'reason', l.reason)),
           'when_label', public._oa_age_label(l.created_at)) order by l.created_at desc), '[]'::jsonb)
    into v_log
    from (select * from public.purchase_gate_log order by created_at desc limit 30) l;

  return jsonb_build_object(
    'ok', true,
    'title',    public.oa_label('settings_title'),
    'subtitle', public.oa_label('settings_subtitle'),
    'sections', jsonb_build_object(
       'timings', public.oa_label('section_timings'),
       'credit',  public.oa_label('section_credit'),
       'open',    public.oa_label('section_open'),
       'log',     public.oa_label('section_log'),
       'cutoff',  public.oa_label('section_cutoff'),
       'device',  public.oa_label('fsi_section')),
    'groups', jsonb_build_array(
      jsonb_build_object('key','cutoff','label', public.oa_label('section_cutoff'),
        'fields', jsonb_build_array('cutoff_enabled','cutoff_time','cutoff_default_time',
          'cutoff_warn1_min','cutoff_warn2_min','cutoff_cancel_after_min',
          'cutoff_restore_min','cutoff_extend_min','cutoff_pause_outside_hours',
          'cutoff_behaviour','cutoff_warn_text'))),
    'fields', jsonb_build_array(
      jsonb_build_object('key','enabled','label',public.oa_label('field_enabled'),
                         'type','bool','value',cfg.enabled),
      jsonb_build_object('key','ring_delay_s','label',public.oa_label('field_ring_delay'),
                         'type','int','value',cfg.ring_delay_s),
      jsonb_build_object('key','rering_after_s','label',public.oa_label('field_rering'),
                         'type','int','value',cfg.rering_after_s),
      jsonb_build_object('key','wa_after_s','label',public.oa_label('field_wa'),
                         'type','int','value',cfg.wa_after_s),
      jsonb_build_object('key','critical_after_s','label',public.oa_label('field_critical'),
                         'type','int','value',cfg.critical_after_s),
      jsonb_build_object('key','ring_seconds','label',public.oa_label('field_ring_seconds'),
                         'type','int','value',cfg.ring_seconds),
      jsonb_build_object('key','autocancel_after_min','label',public.oa_label('field_autocancel'),
                         'type','int','value',cfg.autocancel_after_min),
      jsonb_build_object('key','admin_wa_phone','label',public.oa_label('escalation_phone_label'),
                         'type','text','value',v_phone,
                         'hint',public.oa_label('escalation_phone_hint')),
      jsonb_build_object('key','new_customer_prepaid_only','label',public.oa_label('field_prepaid_new'),
                         'type','bool','value',cfg.new_customer_prepaid_only),
      jsonb_build_object('key','established_credit_limit','label',public.oa_label('field_established_limit'),
                         'type','money','value',cfg.established_credit_limit,
                         'display',public.inr_money(cfg.established_credit_limit)),
      jsonb_build_object('key','established_min_paid_orders','label',public.oa_label('field_min_paid'),
                         'type','int','value',cfg.established_min_paid_orders),
      jsonb_build_object('key','enforce_credit_block','label',public.oa_label('field_enforce'),
                         'type','bool','value',cfg.enforce_credit_block),
      jsonb_build_object('key','purchase_gate_enabled','label',public.oa_label('field_gate'),
                         'type','bool','value',cfg.purchase_gate_enabled),
      jsonb_build_object('key','cutoff_enabled','label',public.oa_label('field_cutoff_enabled'),
                         'type','bool','value',cfg.cutoff_enabled),
      jsonb_build_object('key','cutoff_time','label',public.oa_label('field_cutoff_time'),
                         'type','text','value',to_char(coalesce(v_cut, cfg.cutoff_default_time),'HH24:MI'),
                         'hint', public.oa_label('cutoff_clock_title')),
      jsonb_build_object('key','cutoff_default_time','label',public.oa_label('field_cutoff_default'),
                         'type','text','value',to_char(cfg.cutoff_default_time,'HH24:MI')),
      jsonb_build_object('key','cutoff_warn1_min','label',public.oa_label('field_cutoff_warn1'),
                         'type','int','value',cfg.cutoff_warn1_min),
      jsonb_build_object('key','cutoff_warn2_min','label',public.oa_label('field_cutoff_warn2'),
                         'type','int','value',cfg.cutoff_warn2_min),
      jsonb_build_object('key','cutoff_cancel_after_min','label',public.oa_label('field_cutoff_cancel'),
                         'type','int','value',cfg.cutoff_cancel_after_min),
      jsonb_build_object('key','cutoff_restore_min','label',public.oa_label('field_cutoff_restore'),
                         'type','int','value',cfg.cutoff_restore_min),
      jsonb_build_object('key','cutoff_extend_min','label',public.oa_label('field_cutoff_extend'),
                         'type','int','value',cfg.cutoff_extend_min),
      jsonb_build_object('key','cutoff_pause_outside_hours','label',public.oa_label('field_cutoff_pause'),
                         'type','bool','value',cfg.cutoff_pause_outside_hours),
      jsonb_build_object('key','cutoff_behaviour','label',public.oa_label('field_cutoff_behaviour'),
                         'type','text','value',cfg.cutoff_behaviour,
                         'hint', public.oa_label('cutoff_behaviour_cancel') || ' / '
                                 || public.oa_label('cutoff_behaviour_hold')),
      jsonb_build_object('key','cutoff_warn_text','label',public.oa_label('field_cutoff_warntext'),
                         'type','text','value',cfg.cutoff_warn_text,
                         'multiline', true)),
    'phone_warning', case when v_phone = '' then public.oa_label('escalation_phone_missing') else '' end,
    'saved_label',   public.oa_label('saved'),
    'override_label',public.oa_label('override_label'),
    'override_hint', public.oa_label('override_hint'),
    'credit_limit_label',   public.oa_label('credit_limit_label'),
    'credit_prepaid_label', public.oa_label('credit_prepaid_label'),
    'credit_never_label',   public.oa_label('cutoff_never_label'),
    'empty_title',   public.oa_label('empty_title'),
    'empty_body',    public.oa_label('empty_body'),
    'fsi',           public.order_alert_fsi(),
    'open_count',    public.order_alert_open_count(),
    'open',          v_open,
    'cutoff',        public.order_cutoff_console(null, null),
    'log',           v_log);
end $function$;

-- create-or-replace keeps the existing grants; re-asserted so a fresh replay
-- of this file alone lands the same surface the audit signed off on.
revoke all on function public.order_alert_settings() from public, anon;
grant execute on function public.order_alert_settings() to authenticated, service_role;

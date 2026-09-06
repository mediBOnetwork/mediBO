-- CMD #1847 — full control from the app. Every value here is stored and
-- editable; the screen that already saves the auto-cancel saves these too.

-- Per-zone cut-off time, on the per-zone table that already holds order hours.
-- Dropped and recreated rather than overloaded: a second defaulted signature
-- would make every existing 6-argument call ambiguous.
drop function if exists public.set_order_hours(boolean, time, time, text, boolean, smallint);
create or replace function public.set_order_hours(
  p_is_open boolean,
  p_auto_close_time time default null,
  p_auto_open_time time default null,
  p_closed_message text default null,
  p_clear_auto_open boolean default false,
  p_zone smallint default null,
  p_cutoff_time time default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_zone smallint; v_prev boolean;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  v_zone := public.zone_effective(p_zone);
  select is_open into v_prev from order_hours where zone_id = v_zone;

  insert into order_hours(id, zone_id, is_open, updated_at)
  select coalesce((select max(id) from order_hours),0)+1, v_zone, coalesce(p_is_open,true), now()
  where not exists (select 1 from order_hours where zone_id = v_zone);

  update order_hours set
    is_open        = coalesce(p_is_open, is_open),
    auto_close_time= coalesce(p_auto_close_time, auto_close_time),
    auto_open_time = case when coalesce(p_clear_auto_open,false) then null
                          else coalesce(p_auto_open_time, auto_open_time) end,
    closed_message = coalesce(p_closed_message, closed_message),
    cutoff_time    = coalesce(p_cutoff_time, cutoff_time),
    last_opened_at = case when coalesce(p_is_open,false) and coalesce(v_prev,false) is not true
                          then now() else last_opened_at end,
    last_closed_at = case when p_is_open is false and coalesce(v_prev,true) is not false
                          then now() else last_closed_at end,
    updated_at = now(), updated_by = auth.uid()
  where zone_id = v_zone;

  perform public.audit_write('order_hours_set','zone', v_zone::text, null,
            jsonb_build_object('cutoff_time', p_cutoff_time, 'is_open', p_is_open,
                               'auto_close_time', p_auto_close_time));

  return public.order_hours_state(v_zone);
end $$;

-- Never-auto-cancel, on the per-customer row that already carries the credit
-- policy. Same drop-and-recreate for the same reason.
drop function if exists public.customer_credit_set(uuid, numeric, boolean, text);
create or replace function public.customer_credit_set(
  p_customer_id uuid, p_limit numeric, p_prepaid_only boolean,
  p_note text default null, p_never_auto_cancel boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_label text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  insert into public.customer_credit (customer_id, credit_limit, prepaid_only, note,
                                      never_auto_cancel, updated_at, updated_by)
  values (p_customer_id, greatest(coalesce(p_limit,0),0), coalesce(p_prepaid_only,false),
          nullif(btrim(coalesce(p_note,'')),''), coalesce(p_never_auto_cancel,false),
          now(), coalesce(v_label,'admin'))
  on conflict (customer_id) do update
     set credit_limit = excluded.credit_limit,
         prepaid_only = excluded.prepaid_only,
         note         = excluded.note,
         never_auto_cancel = coalesce(p_never_auto_cancel, customer_credit.never_auto_cancel),
         updated_at   = now(),
         updated_by   = excluded.updated_by;
  perform public.audit_write('customer_credit_set','customer', p_customer_id::text, null,
            jsonb_build_object('limit', p_limit, 'prepaid_only', p_prepaid_only,
                               'never_auto_cancel', p_never_auto_cancel, 'by', v_label));
  return jsonb_build_object('ok', true, 'state', public.customer_credit_state(p_customer_id),
                            'message', public.oa_label('saved'));
end $$;

create or replace function public.customer_credit_list(p_q text default null, p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
        v_zone smallint := public.scope_zone();
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb) into v
  from (
    select public.customer_credit_state(pp.id)
           || jsonb_build_object('customer_id', pp.id,
                                 'customer_name', coalesce(nullif(btrim(pp.pharmacy_name),''),
                                                           nullif(btrim(pp.customer_name),''), ''),
                                 'never_auto_cancel',
                                 coalesce((select cc.never_auto_cancel from public.customer_credit cc
                                            where cc.customer_id = pp.id), false)) as x
      from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false
       and not coalesce(pp.is_synthetic,false)
       and public.scope_zone_ok(pp.zone_id, v_zone)
       and (p_q is null or btrim(p_q) = ''
            or pp.pharmacy_name ilike '%'||p_q||'%'
            or pp.customer_name ilike '%'||p_q||'%')
       and exists (select 1 from public.orders o where o.customer_id = pp.id)
     limit greatest(coalesce(p_limit,30),1)
  ) s;
  return jsonb_build_object('ok', true, 'items', v,
    'never_label', public.oa_label('cutoff_never_label'));
end $$;

-- The settings screen. `groups` is the section→fields map the screen now
-- renders from the payload, so a new knob is a backend change with no deploy.
create or replace function public.order_alert_settings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg public.order_alert_config; v_phone text; v_open jsonb; v_log jsonb;
        v_zone smallint; v_cut time;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg := public._oa_cfg();
  v_phone := coalesce((select value #>> '{}' from public.app_settings
                        where key='admin_wa_phone'), '');
  v_zone := public.admin_active_zone();
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
end $$;

create or replace function public.order_alert_settings_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_label text; k text; v_before jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  v_before := to_jsonb(public._oa_cfg());

  for k in select jsonb_object_keys(coalesce(p_patch,'{}'::jsonb)) loop
    if k = 'admin_wa_phone' then
      insert into public.app_settings(key, value)
      values ('admin_wa_phone', to_jsonb(right(regexp_replace(coalesce(p_patch->>k,''),'\D','','g'),10)))
      on conflict (key) do update set value = excluded.value;
    elsif k = 'cutoff_time' then
      -- Per zone, on order_hours, through the RPC that already owns that table.
      perform public.set_order_hours(null, null, null, null, false,
                public.admin_active_zone(), nullif(btrim(p_patch->>k),'')::time);
    elsif k in ('enabled','new_customer_prepaid_only','enforce_credit_block',
                'block_at_placement','purchase_gate_enabled',
                'cutoff_enabled','cutoff_pause_outside_hours') then
      execute format('update public.order_alert_config set %I = $1, updated_at=now(), updated_by=$2 where id=''singleton''', k)
        using (p_patch->>k)::boolean, coalesce(v_label,'admin');
    elsif k in ('rering_after_s','wa_after_s','critical_after_s','autocancel_after_min',
                'ring_seconds','ring_delay_s','established_min_paid_orders',
                'cutoff_warn1_min','cutoff_warn2_min','cutoff_cancel_after_min',
                'cutoff_restore_min','cutoff_extend_min') then
      execute format('update public.order_alert_config set %I = greatest($1,0), updated_at=now(), updated_by=$2 where id=''singleton''', k)
        using (p_patch->>k)::int, coalesce(v_label,'admin');
    elsif k = 'cutoff_default_time' then
      update public.order_alert_config
         set cutoff_default_time = nullif(btrim(p_patch->>k),'')::time,
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton' and nullif(btrim(p_patch->>k),'') is not null;
    elsif k = 'cutoff_behaviour' then
      update public.order_alert_config
         set cutoff_behaviour = case when lower(btrim(p_patch->>k)) = 'hold' then 'hold' else 'cancel' end,
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'cutoff_warn_text' then
      update public.order_alert_config
         set cutoff_warn_text = coalesce(p_patch->>k,''),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'established_credit_limit' then
      update public.order_alert_config
         set established_credit_limit = greatest((p_patch->>k)::numeric, 0),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'labels' then
      update public.order_alert_config
         set labels = coalesce(labels,'{}'::jsonb) || (p_patch->'labels'),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    end if;
  end loop;

  -- Who changed a setting, and to what. The existing audit log, not a new one.
  perform public.audit_write('order_alert_settings_set','order_alert_config','singleton',
            v_before, p_patch || jsonb_build_object('by', coalesce(v_label,'admin')));

  return public.order_alert_settings() || jsonb_build_object('saved', true);
end $$;

-- DROP wiped the old grants and re-created them with the PUBLIC default.
-- Both are admin-only RPCs: anon never reaches them.
revoke all on function public.set_order_hours(boolean, time, time, text, boolean, smallint, time) from public, anon;
revoke all on function public.customer_credit_set(uuid, numeric, boolean, text, boolean) from public, anon;
grant execute on function public.set_order_hours(boolean, time, time, text, boolean, smallint, time) to authenticated, service_role;
grant execute on function public.customer_credit_set(uuid, numeric, boolean, text, boolean) to authenticated, service_role;

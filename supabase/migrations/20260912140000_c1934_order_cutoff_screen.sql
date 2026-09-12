-- replay-target: production
-- CMD #1934 — the order cut-off gets its own door.
--
-- CMD #1847 built the whole rule (order_cutoff_run, order_cutoff_tick on the
-- existing cron_task dispatcher, the two gates, the console, the per-order
-- actions, the settings on order_alert_config and the audit_write calls).
-- Every line of that is reused here untouched. What was missing was a way in:
-- the cut-off lived inside the "New-order alerts" screen, so nothing in nav,
-- search or the dashboard ever said "order cut-off", and the audit the engine
-- writes on every cancel, hold and restore was never shown to anyone.
--
-- This migration adds exactly three things and no second copy of anything:
--   1. order_cutoff_screen()  — ONE read that composes what already exists.
--   2. order_cutoff_never_set() — the per-pharmacy never-auto-cancel toggle,
--      delegating to the existing customer_credit_set().
--   3. a feature_registry row, so the screen is reachable like every other.

-- ── 1. LABELS ────────────────────────────────────────────────────────────────
-- Same store as every other cut-off string: order_alert_config.labels, read by
-- oa_label(). A word change is an UPDATE here, never a deploy.
-- The singleton is seeded by #306; this keeps the migration idempotent on a
-- database that has not had it yet (a fresh build branch, a restored dump).
insert into public.order_alert_config (id) values ('singleton')
on conflict (id) do nothing;

-- DEFAULTS, NEVER AN OVERWRITE. `defaults || labels` means an admin's own
-- wording always wins and a replay changes nothing; a key the database has
-- never seen gets its default. That also repairs a real hole: #1847 seeded its
-- labels with a bare UPDATE, so any database without the singleton row yet (a
-- fresh build branch, a restored dump) lost every cut-off string silently.
update public.order_alert_config
   set labels = jsonb_build_object(
     -- CMD #1847's own strings, re-stated as defaults so a fresh database is whole.
     'saved',                  'Saved.',
     'section_cutoff',         'Order cut-off & auto-cancel',
     'field_cutoff_enabled',   'Cut-off rule on',
     'field_cutoff_time',      'Cut-off time (this zone)',
     'field_cutoff_default',   'Default cut-off time',
     'field_cutoff_warn1',     'First warning (minutes before)',
     'field_cutoff_warn2',     'Second warning (minutes before)',
     'field_cutoff_cancel',    'Act this many minutes after cut-off',
     'field_cutoff_restore',   'Restoration window (minutes)',
     'field_cutoff_extend',    'Extend button (+minutes)',
     'field_cutoff_pause',     'Pause outside order hours',
     'field_cutoff_behaviour', 'At cut-off: cancel or hold',
     'field_cutoff_warntext',  'Warning message',
     'cutoff_clock_title',     'On the clock',
     'cutoff_clock_empty',     'No order is on the cut-off clock for this zone and date.',
     'cutoff_never_label',     'Never auto-cancel this pharmacy',
     'cutoff_restore_label',   'Restore',
     'cutoff_extend_label',    'Extend window',
     'cutoff_cancel_now_label','Cancel now',
     'cutoff_exempt_label',    'Exempt this order',
     'cutoff_unexempt_label',  'Put back on the clock',
     'cutoff_saved',           'Saved.',
     'cutoff_restored',        'Order restored — items, quantities and prices are as they were.',
     'cutoff_restore_closed',  'The restoration window for this order has closed.',
     'cutoff_window_open',     'Restoration window open — the inquiry is held until it closes.',
     'cutoff_inquiry_check',   'Restoration window',
     'cutoff_state_watching',  'On the clock',
     'cutoff_state_warned',    'Warned',
     'cutoff_state_cancelled', 'Auto-cancelled',
     'cutoff_state_held',      'Payment pending',
     'cutoff_state_restored',  'Restored',
     'cutoff_state_exempt',    'Exempt',
     'cutoff_state_paid',      'Advance paid',
     'cutoff_behaviour_cancel','cancel',
     'cutoff_behaviour_hold',  'hold')
     || jsonb_build_object(
     -- CMD #1934 — the screen of its own.
     'cutoff_screen_title',    'Order cut-off',
     'cutoff_screen_subtitle', 'The daily cut-off, the unpaid auto-cancel and the restoration window — every value on this screen is live.',
     'cutoff_sec_settings',    'The rule',
     'cutoff_sec_clock',       'On the clock',
     'cutoff_sec_never',       'Never auto-cancelled',
     'cutoff_sec_audit',       'What changed',
     'cutoff_never_empty',     'No pharmacy is exempt. Every unpaid order is on the clock.',
     'cutoff_never_hint',      'These pharmacies are never auto-cancelled, whatever the clock says.',
     'cutoff_never_add',       'Mark a pharmacy never-auto-cancel',
     'cutoff_never_remove',    'Put back on the clock',
     'cutoff_never_search',    'Search a pharmacy',
     'cutoff_audit_empty',     'Nothing has changed here yet.',
     'cutoff_audit_hint',      'Who changed a setting, and why each order was cancelled or restored.',
     'cutoff_off_note',        'The cut-off rule is switched off — no order is being cancelled.',
     'cutoff_audit_order_alert_settings_set',  'Setting changed',
     'cutoff_audit_order_cutoff_cancel',       'Auto-cancelled',
     'cutoff_audit_order_cutoff_hold',         'Held — payment pending',
     'cutoff_audit_order_cutoff_restore',      'Restored',
     'cutoff_audit_order_cutoff_extend',       'Cut-off extended',
     'cutoff_audit_order_cutoff_extend_window','Restore window extended',
     'cutoff_audit_order_cutoff_cancel_now',   'Cancelled now by admin',
     'cutoff_audit_order_cutoff_exempt',       'Exempted from the clock',
     'cutoff_audit_order_cutoff_unexempt',     'Put back on the clock',
     'cutoff_audit_customer_credit_set',       'Pharmacy rule changed',
     'cutoff_reason_advance_not_verified_by_cutoff', 'Advance not verified by the cut-off',
     'cutoff_reason_advance_verified',         'Advance verified',
     'cutoff_reason_never_auto_cancel',        'Pharmacy is never auto-cancelled',
     'cutoff_reason_restored_in_window',       'Restored inside the window',
     'cutoff_reason_sourcing_started',         'Sourcing had started — held, not cancelled')
     || coalesce(labels, '{}'::jsonb)
 where id = 'singleton';

-- ── 2. ONE AUDIT ROW, RENDERED ───────────────────────────────────────────────
-- audit_log is the log the engine already writes to. Nothing new is recorded;
-- this only turns a row into the sentence the screen prints.
create or replace function public._order_cutoff_audit_row(a public.audit_log)
returns jsonb language plpgsql stable as $$
declare v_code text := ''; v_why text := ''; v_keys text := '';
begin
  if a.entity_type = 'order' then
    select coalesce(o.order_code,'') into v_code from public.orders o
     where o.id::text = a.entity_id;
  end if;

  -- The WHY is the reason the engine itself stored, worded by oa_label.
  v_why := coalesce(a.after->>'reason', a.before->>'reason', '');
  if v_why <> '' then
    v_why := coalesce(nullif(public.oa_label('cutoff_reason_' || v_why), ''), v_why);
  end if;
  if v_why = '' and a.changed_keys is not null then
    v_keys := array_to_string(a.changed_keys, ', ');
    v_why  := v_keys;
  end if;

  return jsonb_build_object(
    'id',           a.id,
    'action',       a.action,
    'action_label', coalesce(nullif(public.oa_label('cutoff_audit_' || a.action), ''), a.action),
    'target_label', case when v_code <> '' then v_code else coalesce(a.entity_id,'') end,
    'who_label',    coalesce(nullif(btrim(coalesce(a.actor_email,'')),''),
                             coalesce(nullif(a.actor_role,''), 'system')),
    'why_label',    v_why,
    'when_label',   to_char(a.at at time zone 'Asia/Kolkata', 'DD/MM HH24:MI'),
    'tone',         case a.action
                      when 'order_cutoff_cancel'    then 'danger'
                      when 'order_cutoff_cancel_now'then 'danger'
                      when 'order_cutoff_hold'      then 'warning'
                      when 'order_cutoff_restore'   then 'success'
                      when 'order_cutoff_exempt'    then 'info'
                      else 'neutral' end);
end $$;

-- ── 3. THE SCREEN ────────────────────────────────────────────────────────────
-- One read for the whole page. The settings block is LIFTED from
-- order_alert_settings() rather than rebuilt, so a knob added there appears
-- here with no deploy and there is exactly one field list in the system.
create or replace function public.order_cutoff_screen(p_zone smallint default null,
                                                      p_date date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_settings jsonb; v_group jsonb; v_keys text[]; v_fields jsonb;
  v_console jsonb; v_never jsonb; v_audit jsonb; cfg public.order_alert_config;
  v_zone smallint; v_date date;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg    := public._oa_cfg();
  v_zone := coalesce(public.partner_zone_id(), p_zone, public.admin_active_zone());
  v_date := coalesce(p_date, public.admin_active_date());

  -- The rule's own knobs — the cutoff group of the screen that already saves them.
  v_settings := public.order_alert_settings();
  select g into v_group
    from jsonb_array_elements(coalesce(v_settings->'groups','[]'::jsonb)) g
   where g->>'key' = 'cutoff' limit 1;
  select coalesce(array_agg(x #>> '{}'), '{}'::text[]) into v_keys
    from jsonb_array_elements(coalesce(v_group->'fields','[]'::jsonb)) x;
  select coalesce(jsonb_agg(f order by ord), '[]'::jsonb) into v_fields
    from (select f, array_position(v_keys, f->>'key') ord
            from jsonb_array_elements(coalesce(v_settings->'fields','[]'::jsonb)) f
           where (f->>'key') = any(v_keys)) s;

  v_console := public.order_cutoff_console(v_zone, v_date);

  select coalesce(jsonb_agg(jsonb_build_object(
           'customer_id', pp.id,
           'name',        coalesce(nullif(btrim(pp.pharmacy_name),''),
                                   nullif(btrim(pp.customer_name),''), ''),
           'note',        coalesce(cc.note,''),
           'by_label',    coalesce(cc.updated_by,''),
           'remove_label',public.oa_label('cutoff_never_remove'))
           order by coalesce(nullif(btrim(pp.pharmacy_name),''), pp.customer_name)), '[]'::jsonb)
    into v_never
    from public.customer_credit cc
    join public.pharmacy_profiles pp on pp.id = cc.customer_id
   where cc.never_auto_cancel = true
     and coalesce(pp.is_deleted,false) = false
     and public.scope_zone_ok(pp.zone_id, v_zone);

  -- The audit the engine already writes. Order events are clamped to the zone
  -- and date on the picker; a settings change is global, so it always shows.
  select coalesce(jsonb_agg(public._order_cutoff_audit_row(a) order by a.at desc), '[]'::jsonb)
    into v_audit
    from (select l.* from public.audit_log l
           where l.action in ('order_alert_settings_set','customer_credit_set',
                              'order_cutoff_cancel','order_cutoff_hold',
                              'order_cutoff_restore','order_cutoff_extend',
                              'order_cutoff_extend_window','order_cutoff_cancel_now',
                              'order_cutoff_exempt','order_cutoff_unexempt',
                              'order_cutoff_pay_now')
             and (l.entity_type <> 'order'
                  or exists (select 1 from public.order_cutoff_run r
                              where r.order_id::text = l.entity_id
                                and r.cutoff_on = v_date
                                and (v_zone is null or r.zone_id = v_zone)))
           order by l.at desc limit 40) a;

  return jsonb_build_object(
    'ok', true,
    'title',        public.oa_label('cutoff_screen_title'),
    'subtitle',     public.oa_label('cutoff_screen_subtitle'),
    'zone_id',      v_zone,
    'date',         v_date,
    'date_label',   to_char(v_date,'DD/MM/YYYY'),
    'enabled',      coalesce(cfg.cutoff_enabled,false),
    'off_note',     case when coalesce(cfg.cutoff_enabled,false) then ''
                         else public.oa_label('cutoff_off_note') end,
    'saved_label',  public.oa_label('saved'),
    'sections',     jsonb_build_object(
                      'settings', public.oa_label('cutoff_sec_settings'),
                      'clock',    public.oa_label('cutoff_sec_clock'),
                      'never',    public.oa_label('cutoff_sec_never'),
                      'audit',    public.oa_label('cutoff_sec_audit')),
    'fields',       coalesce(v_fields,'[]'::jsonb),
    'clock',        v_console,
    'never',        jsonb_build_object(
                      'hint',         public.oa_label('cutoff_never_hint'),
                      'empty_label',  public.oa_label('cutoff_never_empty'),
                      'add_label',    public.oa_label('cutoff_never_add'),
                      'search_label', public.oa_label('cutoff_never_search'),
                      'items',        coalesce(v_never,'[]'::jsonb)),
    'audit',        jsonb_build_object(
                      'hint',        public.oa_label('cutoff_audit_hint'),
                      'empty_label', public.oa_label('cutoff_audit_empty'),
                      'items',       coalesce(v_audit,'[]'::jsonb)));
end $$;

-- ── 4. THE PER-PHARMACY TOGGLE ───────────────────────────────────────────────
-- Not a second writer: it delegates to customer_credit_set(), which owns the
-- row and already writes its own audit line.
create or replace function public.order_cutoff_never_set(p_customer_id uuid,
                                                         p_never boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_state jsonb; v_res jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  v_state := public.customer_credit_state(p_customer_id);
  v_res := public.customer_credit_set(
             p_customer_id,
             coalesce((v_state->>'credit_limit')::numeric, 0),
             coalesce((v_state->>'prepaid_only')::boolean, false),
             null,
             coalesce(p_never, false));
  if coalesce((v_res->>'ok')::boolean, false) is not true then return v_res; end if;
  return jsonb_build_object('ok', true, 'message', public.oa_label('saved'));
end $$;

-- ── 5. GRANTS ────────────────────────────────────────────────────────────────
-- Admin-only reads and writes: anon and the signed-out web client have no
-- business on this screen, and a SECURITY DEFINER function inherits PUBLIC
-- EXECUTE unless it is revoked (standing lesson 122).
revoke all on function public.order_cutoff_screen(smallint, date) from public, anon;
revoke all on function public.order_cutoff_never_set(uuid, boolean) from public, anon;
revoke all on function public._order_cutoff_audit_row(public.audit_log) from public, anon;
grant execute on function public.order_cutoff_screen(smallint, date) to authenticated, service_role;
grant execute on function public.order_cutoff_never_set(uuid, boolean) to authenticated, service_role;

-- ── 6. THE DOOR ──────────────────────────────────────────────────────────────
-- The registry row IS the entry point: nav, search, the Fulfil dashboard and
-- /admin/go/order_cutoff all read this table.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   deep_link, search_terms, description, canonical_key, dashboard_section,
   test_entry, test_roles, test_steps, test_expect, test_automatable,
   test_contract_at)
values
  ('admin.order_cutoff', 'Order cut-off', 'Orders', 'schedule', 'order_cutoff', 21,
   'medibo', false, 'none', true, 'home_fulfill', 'dashboard',
   array['admin','super_admin'], '/admin/go/order_cutoff',
   'cutoff cut-off order hours auto cancel unpaid advance restore restoration window payment pending',
   'The daily cut-off, the unpaid auto-cancel and the restoration window.',
   'admin.order_cutoff', 'needs_now',
   '/admin/go/order_cutoff', array['admin','super_admin'],
   '[{"kind":"auth","role":"{role}"},{"kind":"goto","path":"/admin/go/order_cutoff"},{"ms":6000,"kind":"settle"}]'::jsonb,
   '{"key":"boot_status","kind":"visible","equals":"painted","source":"render_log"}'::jsonb,
   true, now())
on conflict (feature_key) do update
   set label         = excluded.label,
       route_key     = excluded.route_key,
       category      = excluded.category,
       surface       = excluded.surface,
       roles_allowed = excluded.roles_allowed,
       deep_link     = excluded.deep_link,
       search_terms  = excluded.search_terms,
       description   = excluded.description,
       is_active     = true;

comment on function public.order_cutoff_screen(smallint, date) is
  'CMD #1934 — the whole Order cut-off screen in one read: the rule''s knobs (lifted from order_alert_settings so there is one field list), the clock (order_cutoff_console), the never-auto-cancel pharmacies and the audit the engine already writes. Zone and date come from admin_active_zone()/admin_active_date().';

-- The shell's own route table. `registered_routes.dart` is the offline mirror
-- the protected suite checks against, and admin_nav_reachability_test.dart
-- proves this key has a case in home_shell.dart — a tile with no door is a
-- dead tap, which is the whole bug CHANGE #325 exists to retire.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('order_cutoff', 'admin.order_cutoff', 'feature', 'home_shell',
        'Order cut-off — opened by shellExtraRouteScreen in shell/shell_extra_routes.dart (CMD #1934).', true)
on conflict (route_key, feature_key) do update
   set kind        = excluded.kind,
       handled_by  = excluded.handled_by,
       note        = excluded.note,
       is_active   = true;

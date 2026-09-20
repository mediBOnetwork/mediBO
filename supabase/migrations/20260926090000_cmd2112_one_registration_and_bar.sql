-- CMD #2112 — ONE registration screen, and ONE banner slot.
--
-- WHAT THIS MIGRATION OWNS
--  1. The registration BAR: `customer_registration_bar()`, the pill payload
--     that rides the SAME slot as the update bar (title, cta, route, anchor).
--  2. `customer_registration_payload()` — a mandatory paper that is OUT is
--     owed at EVERY stage, so a rejected licence or an extra paper asked for
--     later reopens the one form instead of dead-ending.
--  3. `app_update_check()` — there is no Later and no 24 h hide any more.
--  4. `customer_form_schema().geo` — the shop pin is Google Maps ONLY, with
--     the copy for a platform that has no Google key. No OSM fallback.
--  5. `customer_surfaces()` — "Complete registration" in the profile
--     dropdown, for exactly as long as something is owed, fresh accounts
--     included.
--
-- Idempotent: every statement is CREATE OR REPLACE or an ON CONFLICT upsert.
begin;

-- ── 1. Copy. New keys only: ON CONFLICT DO NOTHING so wording Om has already
--    edited on live is never overwritten by a replay. ───────────────────────
insert into public.ui_copy(key, value) values
  ('custreg.bar_title',   to_jsonb('Registration pending'::text)),
  ('custreg.bar_cta',     to_jsonb('Continue'::text)),
  ('custreg.menu_label',  to_jsonb('Complete registration'::text)),
  ('custreg.menu_caption',to_jsonb('Finish your shop details and documents'::text)),
  ('customer_form.pin_map_unavailable',
     to_jsonb('The map cannot open on this device. Tap “Use my location” to set the shop pin.'::text)),
  ('customer_form.pin_drag_hint',
     to_jsonb('Drag the map so the pin sits on your shop door.'::text))
on conflict (key) do nothing;

--- 2. app_update_check ---
CREATE OR REPLACE FUNCTION public.app_update_check(p_platform text DEFAULT 'web'::text, p_installed_version text DEFAULT NULL::text, p_live_version text DEFAULT NULL::text, p_platform_state text DEFAULT NULL::text, p_platform_version text DEFAULT NULL::text, p_dismissed_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cfg     jsonb := coalesce((select value from app_settings where key = 'app_update_bar'), '{}'::jsonb);
  v_chan    jsonb := coalesce((select value from app_settings where key = 'app_update_channel'), '{}'::jsonb);
  v_plat    text  := lower(coalesce(nullif(btrim(coalesce(p_platform, '')), ''), 'web'));
  v_state   text  := lower(coalesce(nullif(btrim(coalesce(p_platform_state, '')), ''), 'unknown'));
  v_on      bool  := coalesce((v_cfg->>'enabled')::boolean, true);
  v_poll    int   := greatest(30, coalesce((v_cfg->>'poll_seconds')::int, 300));
  v_min     int   := coalesce((v_cfg->>'min_version_code')::int, 0);
  v_hours   int   := greatest(0, coalesce((v_cfg->>'dismiss_hours')::int, 24));
  v_show    bool  := false;
  v_forced  bool  := coalesce((v_cfg->>'force_update')::boolean, false);
  v_action  text  := 'none';
  v_flow    text  := 'reload';
  v_reason  text  := 'no_update';
  v_target  text  := null;
  v_url     text  := null;
  v_code    int   := nullif(regexp_replace(coalesce(p_installed_version, ''), '\D', '', 'g'), '')::int;
  v_boot    text  := nullif(btrim(coalesce(p_installed_version, '')), '');
  v_live    text  := nullif(btrim(coalesce(p_live_version, '')), '');
  r         app_releases%rowtype;
begin
  if v_plat not in ('android', 'web', 'pwa') then
    v_plat := 'web';
  end if;

  if not v_on then
    v_reason := 'disabled';
  elsif v_plat = 'android' then
    v_action := 'play_in_app_update';
    if not coalesce((v_cfg->>'android_enabled')::boolean, true) then
      v_reason := 'disabled';
    -- THE WHOLE POINT OF THIS COMMAND. Play said so, or there is no bar.
    -- 'unknown' (the API could not be reached, a sideloaded build, no Play
    -- Store) is NOT an update: silence beats a button that does nothing.
    elsif v_state <> 'update_available' then
      v_reason := case v_state
                    when 'in_progress' then 'play_update_in_progress'
                    when 'none'        then 'play_says_up_to_date'
                    else 'play_unknown'
                  end;
    else
      v_show   := true;
      v_reason := 'play_update_available';
      -- app_releases NAMES the build; it never decides that there is one.
      -- CMD #2100 — the partner flavor has its own release row (platform 'android_partner').
      r := public.app_published_release(public.app_release_platform('android'));
      v_target := coalesce(
        nullif(btrim(coalesce(p_platform_version, '')), ''),
        r.version_name);
      v_url := coalesce(nullif(btrim(coalesce(v_chan->>(case when public.app_flavor() = 'partner' then 'partner_play_url' else 'play_url' end), '')), ''),
                        nullif(btrim(coalesce(r.apk_url, '')), ''));
      -- Too old to keep taking orders → Play's blocking flow, and no way out.
      if v_min > 0 and coalesce(v_code, 0) > 0 and v_code < v_min then
        v_forced := true;
      end if;
      v_flow := case when v_forced then 'immediate' else 'flexible' end;
    end if;
  elsif v_plat = 'pwa' then
    v_action := 'sw_skip_waiting';
    v_flow   := 'sw_skip_waiting';
    if not coalesce((v_cfg->>'pwa_enabled')::boolean, true) then
      v_reason := 'disabled';
    elsif v_state <> 'waiting' then
      v_reason := 'no_waiting_worker';
    else
      v_show   := true;
      v_reason := 'waiting_worker';
      v_target := v_live;
    end if;
  else
    v_action := 'reload';
    v_flow   := 'reload';
    if not coalesce((v_cfg->>'web_enabled')::boolean, true) then
      v_reason := 'disabled';
    -- Both strings must be real. A failed fetch is not a new build.
    elsif v_boot is null or v_live is null
       or v_boot = 'unknown' or v_live = 'unknown' then
      v_reason := 'unknown_build';
    elsif v_boot = v_live then
      v_reason := 'same_build';
    else
      v_show   := true;
      v_reason := 'newer_web_build';
      v_target := v_live;
    end if;
  end if;

  -- ── CMD #2112 — THERE IS NO DISMISSAL ANY MORE. ──────────────────────
  -- The bar used to carry a Later that hid it for `dismiss_hours` (24) on
  -- that device. An update that a shop can postpone for a day is an update
  -- that reaches it a day late, and the bar now shares its slot with the
  -- registration bar, where a dismissed pill would read as "nothing owed".
  -- `p_dismissed_at` is still ACCEPTED so an older build calling this RPC
  -- does not error; it is ignored. `dismiss_hours` is reported as 0 and
  -- `dismissible` as false, so nothing downstream draws a control.
  v_hours := 0;

  return jsonb_build_object(
    'show',             v_show,
    'platform',         v_plat,
    'reason',           v_reason,
    'title',            _c('app_update_bar.label'),
    'cta',              _c('app_update_bar.button'),
    'action',           case when v_show then v_action else 'none' end,
    'updating_label',   _c('app_update_bar.updating'),
    'downloaded_label', _c('app_update_bar.downloaded'),
    'dismiss_label',    null::text,
    'dismissible',      false,
    'forced',           v_forced,
    'dismiss_hours',    v_hours,
    'flow',             v_flow,
    'poll_seconds',     v_poll,
    'min_version_code', v_min,
    'installed_version', v_boot,
    'target_version',   v_target,
    'action_url',       v_url
  );
end $function$

;

-- ── 3. customer_registration_payload ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.customer_registration_payload()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sess jsonb; v_needs_profile boolean := false; v_cid uuid;
  v_stage text; v_zone smallint;
  v_schema jsonb := '{}'::jsonb; v_draft jsonb := '{}'::jsonb;
  v_map jsonb; v_pre jsonb := '{}'::jsonb; v_u record; v_row record;
  v_docs jsonb; v_route text; v_needs boolean;
  v_missing text := ''; v_imported boolean := false;
begin
  if auth.uid() is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', false);
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_needs_profile := coalesce((v_sess->>'needs_profile')::boolean, false);
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  -- Staff and suppliers are not half-registered pharmacies.
  if not v_needs_profile and v_cid is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', true);
  end if;

  v_route := coalesce(public.login_signup_cfg()->>'signup_form_route',
                      public.login_signup_cfg()->>'signup_route',
                      '/complete-registration');

  begin v_schema := public.customer_form_schema('signup');
  exception when others then v_schema := '{}'::jsonb; end;
  v_draft := public.customer_reg_draft_get('signup');

  -- Who is in front of us. An imported shop already has its row: every value
  -- on it becomes a prefill, so the person fills only what is blank.
  if v_cid is not null then
    select registration_stage::text as stage, zone_id,
           pharmacy_name, coalesce(owner_name, customer_name) as owner_name,
           phone, whatsapp_no, email, coalesce(address, address_local) as address,
           city, district, state, pincode, store_type, store_location_link,
           coalesce(gstin, gst_no) as gstin, dl_20b, dl_21b, dl_expiry,
           coalesce(drug_license,'') as drug_license,
           case when coalesce(created_by_admin,false) then 'admin_import' else '' end as source
      into v_row
      from public.pharmacy_profiles where id = v_cid;
    v_stage := v_row.stage;
    v_zone  := v_row.zone_id;
    v_imported := coalesce(lower(btrim(coalesce(v_row.source,''))) in ('import','admin','admin_import'), false);
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      'pharmacy_name',       nullif(btrim(coalesce(v_row.pharmacy_name,'')),''),
      'customer_name',       nullif(btrim(coalesce(v_row.owner_name,'')),''),
      'phone',               nullif(btrim(coalesce(v_row.phone,'')),''),
      'whatsapp_no',         nullif(btrim(coalesce(v_row.whatsapp_no,'')),''),
      'email',               nullif(btrim(coalesce(v_row.email,'')),''),
      'address',             nullif(btrim(coalesce(v_row.address,'')),''),
      'city',                nullif(btrim(coalesce(v_row.city,'')),''),
      'district',            nullif(btrim(coalesce(v_row.district,'')),''),
      'state',               nullif(btrim(coalesce(v_row.state,'')),''),
      'pincode',             nullif(btrim(coalesce(v_row.pincode,'')),''),
      'store_type',          nullif(btrim(coalesce(v_row.store_type,'')),''),
      'store_location_link', nullif(btrim(coalesce(v_row.store_location_link,'')),''),
      'gstin',               nullif(btrim(coalesce(v_row.gstin,'')),''),
      'dl_20b',              nullif(btrim(coalesce(v_row.dl_20b, v_row.drug_license,'')),''),
      'dl_21b',              nullif(btrim(coalesce(v_row.dl_21b,'')),''),
      'dl_expiry',           case when v_row.dl_expiry is null then null
                                  else to_char(v_row.dl_expiry,'YYYY-MM-DD') end));
  else
    -- Brand-new signup: the only thing known is the identity they logged in
    -- with, and WHICH field each identity value lands in is data.
    v_map := coalesce((select value from public.app_settings where key = 'signup_prefill_map'),
                      jsonb_build_object('name','customer_name','email','email','whatsapp','whatsapp_no'));
    select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name','')),''),
                    nullif(btrim(coalesce(u.raw_user_meta_data->>'name','')),''),
                    '') as nm,
           case when lower(coalesce(u.email,'')) like
                     ('%@' || coalesce(public.login_signup_cfg()->>'internal_email_domain','wa.medibo.in'))
                then '' else coalesce(u.email,'') end as em,
           coalesce(nullif(right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10),''),
                    coalesce(u.raw_user_meta_data->>'phone','')) as ph
      into v_u
      from auth.users u where u.id = auth.uid();
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      coalesce(v_map->>'name','customer_name'),   nullif(coalesce(v_u.nm,''),''),
      coalesce(v_map->>'email','email'),          nullif(coalesce(v_u.em,''),''),
      coalesce(v_map->>'whatsapp','whatsapp_no'), nullif(coalesce(v_u.ph,''),'')));
    v_zone := public.admin_active_zone();
  end if;

  v_docs := public.custdoc_form_block(v_zone, v_cid);

  if v_cid is not null then
    begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
    exception when others then v_missing := ''; end;
  end if;

  -- Owed while there is no profile at all, or while a mandatory paper is out.
  -- CMD #2112 — RE-SUBMISSION IS THE SAME SCREEN.
  -- The stage guard meant an APPROVED shop whose licence was later rejected,
  -- or which an admin later asked for an extra paper from, was told nothing
  -- was owed: `needs` was false, the bar never came up and there was no door
  -- back into the form. A mandatory paper that is OUT is owed at every stage;
  -- `customer_docs_missing_labels` already counts a rejected paper as out.
  v_needs := (v_cid is null)
             or coalesce(v_needs_profile, false)
             or (v_missing <> '');

  return jsonb_build_object(
    'signed_in',   true,
    'needs',       v_needs,
    -- CMD #2061 — one form. 'documents' is no longer a stage of its own.
    'stage',       case when v_needs then 'form' else 'done' end,
    'route',       v_route,
    'customer_id', v_cid,
    'title',       public._c('custreg.form_title'),
    'subtitle',    public._c('custreg.form_subtitle'),
    'submit_label',     public._c('custreg.submit_label'),
    'submitting_label', public._c('custreg.submitting_label'),
    'error_label',      public._c('custreg.err_save'),
    'retry_label',      public._c('custreg.retry'),
    'close_label',      public._c('custreg.close_label'),
    'done_title',       public._c('custreg.done_title'),
    'done_line',        public._c('custreg.done_line'),
    'imported',    jsonb_build_object(
                     'is',   v_imported,
                     'note', case when v_imported then public._c('custreg.imported_note') else '' end),
    'schema',      v_schema,
    'prefill',     v_pre,
    'draft',       v_draft,
    'has_draft',   (v_draft <> '{}'::jsonb),
    'draft_note',  case when v_draft <> '{}'::jsonb then public._c('custreg.draft_resumed') else '' end,
    'autosave',    jsonb_build_object(
                     'enabled', true, 'debounce_ms', 800,
                     'saving_label', public._c('custreg.draft_saving'),
                     'saved_label',  public._c('custreg.draft_saved')),
    'documents',   v_docs,
    -- The one line the customer sees once a starred paper was skipped.
    'docs_pending', jsonb_build_object(
                     'show',  (v_missing <> ''),
                     'title', public._c('custreg.pending_title'),
                     'line',  case when v_missing = '' then public._c('custreg.pending_done')
                                   else public._cf('custreg.pending_line',
                                          jsonb_build_object('docs', v_missing)) end,
                     'docs',  v_missing,
                     'cta',   public._c('custreg.pending_cta'),
                     'route', v_route,
                     'anchor','documents',
                     'tone',  case when v_missing = '' then 'success' else 'warning' end),
    -- Kept so anything still reading the old shape renders nothing rather
    -- than throwing. There are no steps any more.
    'steps',       '[]'::jsonb,
    'step',        jsonb_build_object('n', 1, 'total', 1, 'done', case when v_needs then 0 else 1 end,
                                      'label', '', 'progress_label', '', 'ratio', 0),
    'required_left', coalesce((v_docs->>'required_left')::int, 0),
    'sheet', jsonb_build_object(
               'title',        public._c('custreg.sheet_title'),
               'line',         public._c('custreg.sheet_line'),
               'close_label',  public._c('custreg.sheet_close'),
               'done_message', public._c('custreg.sheet_done')));
end $function$

;

-- ── 4. customer_form_schema (geo: google only) ───────────────────────────
CREATE OR REPLACE FUNCTION public.customer_form_schema(p_context text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ctx  text := case lower(btrim(coalesce(p_context,'admin')))
                   when 'signup'       then 'signup'
                   when 'lead_convert' then 'admin'
                   else 'admin' end;
  v_raw  text := lower(btrim(coalesce(p_context,'admin')));
  v_opts jsonb := public.customer_form_options();
  v_map  jsonb := public.map_config_get();
  v_fields jsonb;
  v_sections jsonb;
begin
  select coalesce(jsonb_agg(f order by (f->>'sort_order')::int), '[]'::jsonb)
    into v_fields
  from (
    select jsonb_build_object(
             'key',         cf.key,
             'section',     cf.section_key,
             'label',       cf.label,
             'hint',        cf.hint,
             'type',        cf.field_type,
             'required',    case when cf.required_in is not null
                                 then v_ctx = any (cf.required_in)
                                 else cf.required end,
             'sort_order',  cf.sort_order,
             'half_width',  cf.half_width,
             'max_lines',   cf.max_lines,
             'default',     cf.default_value,
             'options',     case when cf.options_key is null then '[]'::jsonb
                                 else coalesce(v_opts->cf.options_key, '[]'::jsonb) end
           ) as f
    from public.customer_form_field cf
    where cf.is_active and v_ctx = any (cf.contexts)
  ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', cs.key, 'title', cs.title,
           'fields', coalesce((
             select jsonb_agg(x order by (x->>'sort_order')::int)
             from jsonb_array_elements(v_fields) x
             where x->>'section' = cs.key), '[]'::jsonb))
         order by cs.sort_order), '[]'::jsonb)
    into v_sections
  from public.customer_form_section cs
  where cs.is_active
    and exists (select 1 from jsonb_array_elements(v_fields) x where x->>'section' = cs.key);

  return jsonb_build_object(
    'ok', true,
    'context', v_raw,
    'title', case v_raw
               when 'signup'       then public._c('customer_form.title_signup')
               when 'lead_convert' then public._c('customer_form.title_lead_convert')
               else public._c('customer_form.title_admin') end,
    'subtitle',        public._c('customer_form.subtitle'),
    'required_suffix', public._c('customer_form.required_suffix'),
    'loading_label',   public._c('customer_form.loading'),
    'flag_label',      public._c('customer_form.flag_check_this'),
    'missing_required_message', public._c('customer_form.missing_required'),
    'save_label',      public._c('customer_form.btn_save'),
    'cancel_label',    public._c('customer_form.btn_cancel'),
    -- CHANGE #1888 — everything the map pin renders. The picker writes
    -- latitude/longitude; it decides nothing else.
    'geo', jsonb_build_object(
      'lat_key',        'latitude',
      'lng_key',        'longitude',
      'use_device_label', public._c('customer_form.pin_use_device'),
      'locating_label', public._c('customer_form.pin_locating'),
      'denied_label',   public._c('customer_form.pin_denied'),
      'set_label',      public._c('customer_form.pin_set'),
      'none_label',     public._c('customer_form.pin_none'),
      'missing_message', public._c('customer_form.pin_required'),
      'default_center', v_map->'default_center',
      'default_zoom',   coalesce(v_map->'default_zoom', to_jsonb(14)),
      -- CMD #2112 — the shop pin is GOOGLE MAPS ONLY. `provider` is the
      -- requirement, not a preference: a platform whose map_config has no
      -- Google key for it prints `unavailable_label` and the current-location
      -- button, and never silently falls back to OSM tiles, which is how two
      -- different maps ended up behind one field.
      'provider',         'google',
      'unavailable_label', public._c('customer_form.pin_map_unavailable'),
      'drag_hint',        public._c('customer_form.pin_drag_hint')),
    'gst', jsonb_build_object(
      'none_key',       'gst_none',
      'gstin_key',      'gstin',
      'invalid_message', public._c('customer_form.gst_invalid'),
      'missing_message', public._c('customer_form.gst_required')),
    'sections',        v_sections,
    'fields',          v_fields,
    'required_fields', coalesce((select jsonb_agg(x->>'key')
                                   from jsonb_array_elements(v_fields) x
                                  where (x->>'required')::boolean), '[]'::jsonb)
  );
end $function$

;

-- ── 5. customer_surfaces (profile dropdown entry) ────────────────────────
CREATE OR REPLACE FUNCTION public.customer_surfaces()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role   text := coalesce(public.get_my_role(), 'none');
  v_cust   uuid := public.my_customer_id();
  v_prof   record;
  v_term   text;
  v_code   text;
  v_absent text := coalesce(public._c('cust_menu.value_absent'), '');
  v_place  jsonb := '{}'::jsonb;
  v_items  jsonb;
  v_wish   int := 0;
  v_wlabel text := '';
  v_rw     jsonb;
  v_rbadge text := '';
  v_rlines jsonb := '[]'::jsonb;
  v_notif  jsonb := '{}'::jsonb;
  v_regp   jsonb := '{}'::jsonb;
  v_nlabel text := '';
  v_has    boolean := (auth.uid() is not null and v_cust is not null);
  p        text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', true, 'role', v_role, 'has_account', false,
                              'placements', '{}'::jsonb);
  end if;

  -- The inbox belongs to a signed-in IDENTITY, not to a pharmacy row, so the
  -- unread label is read before the account gate below.
  begin
    v_notif := coalesce(public.notif_inbox_unread(), '{}'::jsonb);
  exception when others then
    v_notif := '{}'::jsonb;
  end;
  if coalesce((v_notif->>'show')::boolean, false) then
    v_nlabel := coalesce(v_notif->>'label', '');
  end if;

  if v_has then
    select pp.* into v_prof from public.pharmacy_profiles pp where pp.id = v_cust;

    select count(*)::int into v_wish
      from public.wishlist_items w where w.account_id = v_cust;
    v_wlabel := case when v_wish > 0 then v_wish::text else '' end;

    v_rw := public.loyalty_my_rewards();
    if coalesce((v_rw->'points'->>'on')::boolean, false) then
      v_rbadge := coalesce(v_rw->'points'->>'balance_label', '');
    else
      v_rbadge := coalesce(v_rw->'tier'->>'current_label', '');
    end if;

    if coalesce((v_rw->>'any_on')::boolean, false) then
      select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_rlines from (
        select 1 as ord, v_rw->'points'->>'balance_label' as x
         where coalesce((v_rw->'points'->>'on')::boolean, false)
        union all
        select 2, v_rw->'tier'->>'current_label'
         where coalesce((v_rw->'tier'->>'on')::boolean, false)
        union all
        select 3, btrim(coalesce(v_rw->'referral'->>'code_label','') || ' '
                        || coalesce(v_rw->'referral'->>'code',''))
         where coalesce((v_rw->'referral'->>'on')::boolean, false)
      ) s where coalesce(x, '') <> '';
    else
      v_rlines := jsonb_build_array(coalesce(public._c('cust_menu.rewards_off'), ''));
      v_rlines := (select coalesce(jsonb_agg(e), '[]'::jsonb)
                     from jsonb_array_elements_text(v_rlines) e where e <> '');
    end if;
  end if;

  foreach p in array array['profile_account','catalogue_appbar','orders_section',
                           'home_strip','profile_dropdown']
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'feature_key', f.feature_key,
             'label',       f.label,
             'caption',     coalesce(f.description, ''),
             'icon_key',    f.icon_key,
             'icon_letter', upper(left(f.label, 1)),
             'route_key',   f.route_key,
             'render_kind', cp.render_kind,
             'badge', case f.feature_key
                        when 'cust.wishlist'      then v_wlabel
                        when 'cust.rewards'       then v_rbadge
                        when 'cust.notifications' then v_nlabel
                        else '' end,
             'lines', case f.feature_key
                        when 'cust.rewards' then v_rlines
                        else '[]'::jsonb end)
           order by cp.sort_order, cp.placement, f.sort_order), '[]'::jsonb)
      into v_items
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     where cp.placement = any (case when p = 'home_strip'
                                    then array['home_chip','home_badge']
                                    else array[p] end)
       and cp.is_active
       and f.is_active
       and v_role = any (f.roles_allowed)
       and (v_has or not cp.needs_account);
    v_place := v_place || jsonb_build_object(p, v_items);
  end loop;

  -- CMD #2112 — COMPLETE / RESUME REGISTRATION, IN THE PROFILE DROPDOWN.
  -- It is not a feature_registry row because it is not a permanent door: it
  -- exists exactly while something is owed, which is a question only
  -- customer_registration_payload() can answer, and it must be offered to a
  -- FRESH account that has no pharmacy row at all (every placement row is
  -- gated on `needs_account`, which such an account fails). So it is
  -- synthesised here, from the same payload the bar and the screen read, and
  -- it disappears by itself the moment the last paper lands.
  begin
    v_regp := public.customer_registration_payload();
  exception when others then
    v_regp := '{}'::jsonb;
  end;
  if coalesce((v_regp->>'needs')::boolean, false) then
    v_place := jsonb_set(v_place, '{profile_dropdown}',
      jsonb_build_array(jsonb_build_object(
        'feature_key', 'cust.registration',
        'label',       public._c('custreg.menu_label'),
        'caption',     public._c('custreg.menu_caption'),
        'icon_key',    'rule',
        'icon_letter', 'R',
        'route_key',   'cust_registration',
        'render_kind', 'row',
        'badge',       public._c('custreg.bar_title'),
        'lines',       '[]'::jsonb))
      || coalesce(v_place->'profile_dropdown', '[]'::jsonb));
  end if;

  if not v_has then
    return jsonb_build_object(
      'ok', true, 'role', v_role, 'has_account', false,
      'placements', v_place,
      'notif', jsonb_build_object('label', v_nlabel,
                                  'empty_note', coalesce(public._c('cust_menu.notif_none'), '')),
      'dropdown_title',   coalesce(public._c('cust_menu.dropdown_title'), ''),
      'dropdown_caption', coalesce(public._c('cust_menu.dropdown_caption'), ''),
      'account_title', coalesce(public._c('cust_menu.account_title'), ''));
  end if;

  v_term := nullif(btrim(coalesce(v_prof.payment_term, '')), '');
  if v_term is null then
    v_term := nullif(btrim(coalesce(
      (select value #>> '{}' from public.app_settings
        where key = 'customer_default_payment_term'), '')), '');
  end if;
  v_code := nullif(btrim(coalesce(v_prof.customer_code, '')), '');

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'has_account', true,
    'placements', v_place,
    'offline_note', coalesce(public._c('cust_menu.offline_note'), ''),
    'account_setup', jsonb_build_object(
      'title', coalesce(public._c('cust_menu.setup_title'), ''),
      'rows', jsonb_build_array(
        jsonb_build_object(
          'key',      'payment_term',
          'label',    coalesce(public._c('cust_menu.row_payment_term'), ''),
          'value',    coalesce(v_term, v_absent),
          'has',      v_term is not null,
          'icon_key', 'payments'),
        jsonb_build_object(
          'key',      'customer_code',
          'label',    coalesce(public._c('cust_menu.row_customer_code'), ''),
          'value',    coalesce(v_code, v_absent),
          'has',      v_code is not null,
          'icon_key', 'rule'))),
    'account_title', coalesce(public._c('cust_menu.account_title'), ''),
    -- CMD #1914 — the profile dropdown's own heading and its one-line caption.
    'dropdown_title',   coalesce(public._c('cust_menu.dropdown_title'), ''),
    'dropdown_caption', coalesce(public._c('cust_menu.dropdown_caption'), ''),
    'notif', jsonb_build_object(
      'label',      v_nlabel,
      'count',      coalesce((v_notif->>'count')::int, 0),
      'tooltip',    coalesce(v_notif->>'tooltip', ''),
      'empty_note', coalesce(public._c('cust_menu.notif_none'), '')),
    'wishlist', jsonb_build_object(
      'has',   v_wish > 0,
      'count', v_wish,
      'count_label', v_wlabel,
      'tooltip', coalesce(public._c('cust_menu.wishlist_tooltip'), '')),
    'rewards', jsonb_build_object(
      'has',        coalesce((v_rw->>'any_on')::boolean, false),
      'title',      coalesce(v_rw->>'title', ''),
      'open_label', coalesce(public._c('cust_menu.rewards_open'), ''),
      'off_note',   coalesce(public._c('cust_menu.rewards_off'), ''),
      'badge_label', v_rbadge,
      'lines',      v_rlines));
end $function$

;

-- ── 6. THE REGISTRATION BAR ──────────────────────────────────────────────
--
-- The same SHAPE the update bar reads (`title` / `cta` / `show` /
-- `poll_seconds`), because it rides the same slot in the bottom stack and
-- only one of the two is ever on screen — the update wins, and this one comes
-- up once the app is up to date. Every string is here; the app prints them.
create or replace function public.customer_registration_bar()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_reg  jsonb;
  v_pend jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('show', false, 'reason', 'signed_out');
  end if;

  begin
    v_reg := public.customer_registration_payload();
  exception when others then
    return jsonb_build_object('show', false, 'reason', 'error');
  end;

  if coalesce((v_reg->>'needs')::boolean, false) is not true then
    return jsonb_build_object('show', false, 'reason', 'nothing_owed');
  end if;

  v_pend := coalesce(v_reg->'docs_pending', '{}'::jsonb);

  return jsonb_build_object(
    'show',         true,
    'reason',       case when coalesce((v_pend->>'show')::boolean, false)
                         then 'documents_pending' else 'registration_pending' end,
    -- ONE sentence, whatever is owed: the pill has a single line and the
    -- detail belongs on the form, not on a strip above the bottom nav.
    'title',        public._c('custreg.bar_title'),
    'cta',          public._c('custreg.bar_cta'),
    'route',        coalesce(nullif(v_reg->>'route',''), '/complete-registration'),
    -- Resume lands on the papers when the papers are what is out.
    'anchor',       case when coalesce((v_pend->>'show')::boolean, false)
                         then 'documents' else '' end,
    'required_left', coalesce((v_reg->>'required_left')::int, 0),
    'poll_seconds', 300);
end
$function$;

-- Every new SECURITY DEFINER function inherits PUBLIC EXECUTE. This one reads
-- the caller's own registration state, so anon has no business calling it.
revoke all on function public.customer_registration_bar() from public;
revoke all on function public.customer_registration_bar() from anon;
grant execute on function public.customer_registration_bar() to authenticated;
grant execute on function public.customer_registration_bar() to service_role;

commit;

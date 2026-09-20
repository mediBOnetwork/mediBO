-- CMD #2126 — Registration becomes 3 steps: Shop → Location → Licences, then Done.
--
-- Same backend as #2112 (customer_registration_payload / _submit) and the
-- same resume logic; only the LAYOUT and FLOW change, and the flow is DATA:
--
--   1. app_settings.custreg_wizard — the steps, which fields each one asks,
--      the Store type chips and where "Start browsing" goes. Re-ordering a
--      step or moving a field is an UPDATE, never a deploy.
--   2. customer_registration_wizard() — turns that config + the schema + the
--      person's values into the render-ready block: per-step labels, fields,
--      completeness, "Step n of 3", the step to resume on, every caption and
--      the Done screen's checklist. Pure: reads nothing but ui_copy/settings.
--   3. customer_registration_step_save(step, values, goto) — AUTO-SAVE after
--      every step. Continue validates that step's required fields server-side
--      and saves the draft with the step to come back to; Back / a tapped tick
--      saves without validating.
--   4. customer_registration_payload() — carries `wizard`, strips the private
--      `_step` key from the draft it hands out, and never pre-fills Owner name
--      from the email handle.
--
-- Zone/date: nothing here lists, counts or reports. The document block keeps
-- reading admin_active_zone() exactly as #2112 did.
--
-- Idempotent: CREATE OR REPLACE + ON CONFLICT DO NOTHING (live wording and a
-- config Om already edited are never overwritten by a replay).
begin;

-- ── 1. Copy ──────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('custreg.wiz_step_shop',       to_jsonb('Shop'::text)),
  ('custreg.wiz_step_location',   to_jsonb('Location'::text)),
  ('custreg.wiz_step_licences',   to_jsonb('Licences'::text)),
  ('custreg.wiz_title_shop',      to_jsonb('Your shop'::text)),
  ('custreg.wiz_title_location',  to_jsonb('Where is the shop?'::text)),
  ('custreg.wiz_title_licences',  to_jsonb('Licences and documents'::text)),
  ('custreg.wiz_step_of',         to_jsonb('Step {n} of {total}'::text)),
  ('custreg.wiz_continue',        to_jsonb('Continue'::text)),
  ('custreg.wiz_back',            to_jsonb('Back'::text)),
  ('custreg.wiz_saving',          to_jsonb('Saving…'::text)),
  ('custreg.wiz_missing',         to_jsonb('Please fill in: {fields}'::text)),
  ('custreg.wiz_saved',           to_jsonb('Saved — you can come back any time.'::text)),
  ('custreg.done_submitted_title',to_jsonb('Registration submitted'::text)),
  ('custreg.done_submitted_line', to_jsonb('We verify within 24 hours — you''ll get a WhatsApp message.'::text)),
  ('custreg.done_checklist_title',to_jsonb('Your registration'::text)),
  ('custreg.done_item_done',      to_jsonb('Done'::text)),
  ('custreg.done_item_later',     to_jsonb('Add later'::text)),
  ('custreg.done_part_shop',      to_jsonb('Shop details'::text)),
  ('custreg.done_part_location',  to_jsonb('Shop location'::text)),
  ('custreg.done_part_licences',  to_jsonb('Licence numbers'::text)),
  ('custreg.done_part_documents', to_jsonb('Documents'::text)),
  ('custreg.done_browse',         to_jsonb('Start browsing'::text))
on conflict (key) do nothing;

-- ── 2. The flow, as data ─────────────────────────────────────────────────
insert into public.app_settings(key, value) values
  ('custreg_wizard', jsonb_build_object(
     'enabled', true,
     'steps', jsonb_build_array(
       jsonb_build_object('key','shop',     'label_key','custreg.wiz_step_shop',
                          'title_key','custreg.wiz_title_shop',     'docs', false,
                          'sections', jsonb_build_array('business','contact'),
                          'fields', jsonb_build_array('pharmacy_name','customer_name','store_type','whatsapp_no','email')),
       jsonb_build_object('key','location', 'label_key','custreg.wiz_step_location',
                          'title_key','custreg.wiz_title_location', 'docs', false,
                          'sections', jsonb_build_array('address'),
                          'fields', jsonb_build_array('address','city','state','pincode','store_pin','store_location_link')),
       jsonb_build_object('key','licences', 'label_key','custreg.wiz_step_licences',
                          'title_key','custreg.wiz_title_licences', 'docs', true,
                          'sections', jsonb_build_array('statutory'),
                          'fields', jsonb_build_array('gstin','gst_none','dl_20b','dl_21b','dl_expiry'))),
     'chips', jsonb_build_object(
       'store_type', jsonb_build_array('Retail pharmacy','Hospital pharmacy','Clinic','Wholesale')),
     'browse_route', '/'))
on conflict (key) do nothing;

-- ── 3. Owner name is never the email handle ──────────────────────────────
create or replace function public.custreg_is_email_handle(p_name text, p_email text)
returns boolean
language sql
immutable
set search_path to 'public'
as $function$
  select case
    when nullif(btrim(coalesce(p_name,'')),'') is null then false
    when position('@' in p_name) > 0 then true
    when nullif(btrim(coalesce(p_email,'')),'') is null then false
    else lower(regexp_replace(p_name, '[^a-zA-Z0-9]', '', 'g'))
       = lower(regexp_replace(split_part(p_email,'@',1), '[^a-zA-Z0-9]', '', 'g'))
  end
$function$;

-- ── 4. The render-ready wizard block ─────────────────────────────────────
create or replace function public.customer_registration_wizard(
  p_schema jsonb, p_values jsonb, p_docs jsonb, p_needs boolean,
  p_stage text, p_step text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cfg    jsonb := coalesce((select value from public.app_settings where key = 'custreg_wizard'), '{}'::jsonb);
  v_fields jsonb := coalesce(p_schema->'fields', '[]'::jsonb);
  v_vals   jsonb := coalesce(p_values, '{}'::jsonb);
  v_steps  jsonb := '[]'::jsonb;
  v_total  int;
  v_step   jsonb; v_keys jsonb; v_f jsonb; v_k text;
  v_missing jsonb; v_i int := 0; v_resume int := -1; v_first_open int := -1;
  v_complete boolean; v_known text[] := '{}';
  v_by_key jsonb := '{}'::jsonb; v_done_map jsonb := '{}'::jsonb;
  v_docs_ok boolean; v_lic_any boolean; v_approved boolean;
begin
  if coalesce((v_cfg->>'enabled')::boolean, false) is not true
     or jsonb_array_length(coalesce(v_cfg->'steps','[]'::jsonb)) = 0 then
    return jsonb_build_object('enabled', false);
  end if;

  select coalesce(jsonb_object_agg(f->>'key', f), '{}'::jsonb) into v_by_key
    from jsonb_array_elements(v_fields) f;
  select coalesce(array_agg(x #>> '{}'), '{}') into v_known
    from jsonb_array_elements(v_cfg->'steps') s, jsonb_array_elements(s->'fields') x;
  v_total := jsonb_array_length(v_cfg->'steps');

  for v_step in select value from jsonb_array_elements(v_cfg->'steps') loop
    -- The step's own list, in config order, kept to what the schema carries…
    select coalesce(jsonb_agg(x order by o), '[]'::jsonb) into v_keys
      from jsonb_array_elements_text(coalesce(v_step->'fields','[]'::jsonb)) with ordinality t(x, o)
     where v_by_key ? x;
    -- …plus any REQUIRED signup field no step names, on the step that owns
    -- its section — a new mandatory field can never fall off the flow.
    select v_keys || coalesce(jsonb_agg(f->>'key' order by (f->>'sort_order')::int), '[]'::jsonb)
      into v_keys
      from jsonb_array_elements(v_fields) f
     where coalesce((f->>'required')::boolean, false)
       and not ((f->>'key') = any (v_known))
       and (v_step->'sections') ? (f->>'section');

    v_missing := '[]'::jsonb;
    for v_k in select jsonb_array_elements_text(v_keys) loop
      v_f := v_by_key->v_k;
      if coalesce((v_f->>'required')::boolean, false) then
        if (v_f->>'type') = 'geo' then
          if nullif(btrim(coalesce(v_vals->>'latitude','')),'') is null
             or nullif(btrim(coalesce(v_vals->>'longitude','')),'') is null then
            v_missing := v_missing || to_jsonb(v_f->>'label');
          end if;
        elsif nullif(btrim(coalesce(v_vals->>v_k,'')),'') is null then
          v_missing := v_missing || to_jsonb(v_f->>'label');
        end if;
      end if;
    end loop;
    v_complete := jsonb_array_length(v_missing) = 0;
    v_done_map := v_done_map || jsonb_build_object(v_step->>'key', v_complete);
    if not v_complete and v_first_open < 0 then v_first_open := v_i; end if;
    if p_step is not null and (v_step->>'key') = p_step then v_resume := v_i; end if;

    v_steps := v_steps || jsonb_build_object(
      'key',      v_step->>'key',
      'n',        v_i + 1,
      'label',    public._c(v_step->>'label_key'),
      'title',    public._c(v_step->>'title_key'),
      'step_of',  public._cf('custreg.wiz_step_of',
                    jsonb_build_object('n', v_i + 1, 'total', v_total)),
      'fields',   v_keys,
      'docs',     coalesce((v_step->>'docs')::boolean, false),
      'complete', v_complete,
      'missing',  v_missing);
    v_i := v_i + 1;
  end loop;

  -- Resume where the person left (the step saved with the draft); a fresh
  -- start opens on step 1 — never mid-flow on an unsaved guess.
  if v_resume < 0 then v_resume := 0; end if;

  v_docs_ok := coalesce((p_docs->>'required_left')::int, 0) = 0;
  v_lic_any := coalesce(nullif(btrim(coalesce(v_vals->>'dl_20b','')),''),
                        nullif(btrim(coalesce(v_vals->>'dl_21b','')),''),
                        nullif(btrim(coalesce(v_vals->>'gstin','')),'')) is not null;
  v_approved := coalesce(p_stage,'') = 'approved' and not coalesce(p_needs,false);

  return jsonb_build_object(
    'enabled',        true,
    'steps',          v_steps,
    'total',          v_total,
    'resume_step',    v_resume,
    'first_open',     greatest(v_first_open, 0),
    'continue_label', public._c('custreg.wiz_continue'),
    'back_label',     public._c('custreg.wiz_back'),
    'saving_label',   public._c('custreg.wiz_saving'),
    'submit_label',   public._c('custreg.submit_label'),
    'submitting_label', public._c('custreg.submitting_label'),
    'saved_label',    public._c('custreg.wiz_saved'),
    'chips',          coalesce(v_cfg->'chips', '{}'::jsonb),
    'done', jsonb_build_object(
      'title', case when v_approved then public._c('custreg.done_title')
                    else public._c('custreg.done_submitted_title') end,
      'line',  case when v_approved then public._c('custreg.done_line')
                    else public._c('custreg.done_submitted_line') end,
      'checklist_title', public._c('custreg.done_checklist_title'),
      'checklist', jsonb_build_array(
        jsonb_build_object('key','shop',      'label', public._c('custreg.done_part_shop'),
          'done', coalesce((v_done_map->>'shop')::boolean, false)),
        jsonb_build_object('key','location',  'label', public._c('custreg.done_part_location'),
          'done', coalesce((v_done_map->>'location')::boolean, false)),
        jsonb_build_object('key','licences',  'label', public._c('custreg.done_part_licences'),
          'done', v_lic_any),
        jsonb_build_object('key','documents', 'label', public._c('custreg.done_part_documents'),
          'done', v_docs_ok)),
      'done_label',  public._c('custreg.done_item_done'),
      'later_label', public._c('custreg.done_item_later'),
      'cta_label',   public._c('custreg.done_browse'),
      'cta_route',   coalesce(v_cfg->>'browse_route', '/')));
end $function$;

revoke all on function public.customer_registration_wizard(jsonb, jsonb, jsonb, boolean, text, text) from public, anon, authenticated;
grant execute on function public.customer_registration_wizard(jsonb, jsonb, jsonb, boolean, text, text) to service_role;
revoke all on function public.custreg_is_email_handle(text, text) from public, anon;
grant execute on function public.custreg_is_email_handle(text, text) to authenticated, service_role;

-- ── 5. Auto-save after every step ────────────────────────────────────────
create or replace function public.customer_registration_step_save(
  p_step text, p_values jsonb default '{}'::jsonb, p_goto text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_schema jsonb; v_wiz jsonb; v_step jsonb; v_next text; v_idx int := -1;
  v_steps jsonb; v_draft jsonb; v_vals jsonb; v_missing jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' then
    p_values := '{}'::jsonb;
  end if;

  begin v_schema := public.customer_form_schema('signup');
  exception when others then v_schema := '{}'::jsonb; end;
  v_draft := public.customer_reg_draft_get('signup');
  -- What this step is judged on: what was already saved, overlaid with what
  -- the person has on screen now.
  v_vals := (v_draft - '_step') || p_values;
  v_wiz := public.customer_registration_wizard(v_schema, v_vals, '{}'::jsonb, true, '', null);
  v_steps := coalesce(v_wiz->'steps', '[]'::jsonb);

  select value, (ordinality - 1)::int into v_step, v_idx
    from jsonb_array_elements(v_steps) with ordinality
   where value->>'key' = p_step;
  if v_step is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_step',
                              'message', public._c('custreg.err_save'));
  end if;

  if p_goto is not null then
    -- Back, or a tapped tick: save and move, never block.
    v_next := p_goto;
  else
    v_missing := coalesce(v_step->'missing', '[]'::jsonb);
    if jsonb_array_length(v_missing) > 0 then
      perform public.customer_reg_draft_save(p_values || jsonb_build_object('_step', p_step), 'signup');
      return jsonb_build_object(
        'ok', false, 'error', 'missing', 'missing', v_missing,
        'message', public._cf('custreg.wiz_missing', jsonb_build_object(
                     'fields', (select string_agg(x, ', ') from jsonb_array_elements_text(v_missing) x))));
    end if;
    v_next := coalesce(v_steps->(v_idx + 1)->>'key', p_step);
  end if;

  perform public.customer_reg_draft_save(p_values || jsonb_build_object('_step', v_next), 'signup');
  select (ordinality - 1)::int into v_idx
    from jsonb_array_elements(v_steps) with ordinality where value->>'key' = v_next;

  return jsonb_build_object(
    'ok', true, 'step', v_next, 'step_index', coalesce(v_idx, 0),
    'saved_label', public._c('custreg.wiz_saved'));
end $function$;

revoke all on function public.customer_registration_step_save(text, jsonb, text) from public, anon;
grant execute on function public.customer_registration_step_save(text, jsonb, text) to authenticated, service_role;

-- ── 6. customer_registration_payload — carries the wizard ─────────────────
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
  v_mail text := '';
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
    -- CMD #2126 — an owner name that is only the email handle is not a name.
    v_mail := coalesce(v_row.email, '');
    if public.custreg_is_email_handle(v_row.owner_name, v_mail) then
      v_row.owner_name := null;
    end if;
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
    -- CMD #2126 — Owner name is NEVER the email handle. A login that carries
    -- no real name (email/password signups copy the handle into `name`) leaves
    -- the field blank for the person to type.
    select coalesce(u.email,'') into v_mail from auth.users u where u.id = auth.uid();
    if public.custreg_is_email_handle(v_u.nm, v_mail) then
      v_u.nm := '';
    end if;
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
    'draft',       v_draft - '_step',
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
    -- CMD #2126 — the 3-step flow: steps, their fields, where to resume,
    -- every caption and the Done screen. Absent (or enabled=false) and the
    -- app renders the single form exactly as before.
    'wizard',      public.customer_registration_wizard(
                     v_schema, v_pre || (v_draft - '_step'), v_docs, v_needs,
                     coalesce(v_stage, ''), v_draft->>'_step'),
    'sheet', jsonb_build_object(
               'title',        public._c('custreg.sheet_title'),
               'line',         public._c('custreg.sheet_line'),
               'close_label',  public._c('custreg.sheet_close'),
               'done_message', public._c('custreg.sheet_done')));
end $function$;

revoke all on function public.customer_registration_payload() from public, anon;
grant execute on function public.customer_registration_payload() to authenticated, service_role;

commit;

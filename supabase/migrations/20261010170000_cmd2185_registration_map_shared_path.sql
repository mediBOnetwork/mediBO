-- CMD #2185 — the registration / Add-customer Location map uses the SHARED
-- map path, like every other map in the app.
--
-- Two causes were behind "Android shows no Google map":
--   1. android/app/src/main/AndroidManifest.xml carried no
--      com.google.android.geo.API_KEY, so google_maps_flutter could not start
--      the native SDK at all. That is fixed in the manifest, in this same
--      command.
--   2. customer_form_schema().geo.provider was the literal 'google' (CMD
--      #2112). AdaptiveMap treats that as a REQUIREMENT and draws
--      `unavailable_label` instead of a map when the asking platform has no
--      Google key — so the one map that was supposed to be the easiest thing
--      on the form was the only one that could not fall back to tiles.
--
-- This migration removes the hardcoded provider. Nothing else about the geo
-- block changes: the labels, the centre, the zoom and the Edit sheet are all
-- the same rows they were. customer_registration_wizard inherits this block
-- verbatim (p_schema->'geo'), so the Registration wizard, Add customer and
-- the admin form all move together.
--
-- Idempotent: CREATE OR REPLACE of one function, no data touched.

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
      -- CMD #2185 — NO HARDCODED PROVIDER. #2112 pinned this field to
      -- 'google', which made the shop pin the ONE map in the app that did not
      -- go down the shared path: every other surface (route builder, all
      -- plans, today's visit) asks map_config_get(<platform>) and renders
      -- Google when uses_google_js is true, else tile_url. Pinned to 'google'
      -- the registration/Add-customer Location step printed
      -- `unavailable_label` ("The map cannot open on this device") instead of
      -- a map the moment the asking platform had no Google key — which is
      -- exactly what Android did.
      --
      -- An EMPTY provider means "no requirement": AdaptiveMap then renders
      -- whatever map_config_get() answered for the platform that asked, which
      -- is the same decision, made once, in the same place, for every map.
      -- The tile_url fallback is therefore reached only when the key is
      -- missing. `unavailable_label` stays in the payload as the copy a
      -- surface prints if it ever declares a requirement again.
      'provider',         '',
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

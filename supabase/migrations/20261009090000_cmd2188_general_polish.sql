-- CMD #2188 — Registration General: Mr/Ms lives INSIDE the name box, and the
-- step bar carries exactly ONE signal.
--
-- Two live bugs Om reported on the same screen (customer registration AND
-- staff Add customer / Import — they draw the same widgets):
--
--   1. Mr/Ms was its own bordered box beside Owner name, so it read as a
--      second field and its green caret looked like a primary action. It is
--      now a compact prefix INSIDE the name box: one border, one radius, one
--      focus ring, a hairline divider between the two. The layout is the
--      BACKEND's call — `wizard.prefix.<field>.inline` — not a Dart guess.
--
--   2. The bar spoke twice: green meant "complete" and bold meant "you are
--      here", so standing on General with Location done made Location look
--      current. One signal now, and the rule is DATA in
--      `wizard.step_bar`: the current step is green (bar + bold label), a
--      completed step is grey with a small tick beside its label, an
--      untouched step is plain grey. A bar the person is not standing on is
--      never coloured. Completed steps stay tappable (unchanged).
--
-- Zone/date: nothing here lists, counts or reports — no zone or date scope to
-- honour. Idempotent: ON CONFLICT + a guarded pg_get_functiondef patch, so a
-- replay on live is a no-op.
begin;

-- ── 1. The tick is a WORD, so it lives in ui_copy ────────────────────────
insert into public.ui_copy(key, value) values
  ('custreg.wiz_step_tick', to_jsonb('✓'::text))
on conflict (key) do nothing;

-- ── 2. The flow config must exist before it can be patched ───────────────
-- Live has carried this row since #2126; a freshly cut build database may
-- not, and a missing row silently disables the whole wizard (the preview
-- then renders the old single form and every journey reads as "skipped").
-- Inserting the #2126 shape repairs that without ever touching live's own
-- copy, which Om may have edited.
insert into public.app_settings(key, value) values
  ('custreg_wizard', jsonb_build_object(
     'enabled', true,
     'layout', 'v4',
     'steps', jsonb_build_array(
       jsonb_build_object('key','shop',     'label_key','custreg.wiz_step_shop',
                          'title_key','custreg.wiz_title_shop', 'sub_key','custreg.wiz_sub_shop', 'docs', false,
                          'sections', jsonb_build_array('business','contact'),
                          'fields', jsonb_build_array('customer_name','pharmacy_name','store_type','whatsapp_no','email')),
       jsonb_build_object('key','location', 'label_key','custreg.wiz_step_location',
                          'title_key','custreg.wiz_title_location', 'sub_key','custreg.wiz_sub_location', 'docs', false,
                          'sections', jsonb_build_array('address'),
                          'fields', jsonb_build_array('address','city','state','pincode','store_pin','store_location_link')),
       jsonb_build_object('key','licences', 'label_key','custreg.wiz_step_licences',
                          'title_key','custreg.wiz_title_licences', 'sub_key','custreg.wiz_sub_licences', 'docs', true,
                          'sections', jsonb_build_array('statutory'),
                          'fields', jsonb_build_array('gstin','gst_none','dl_20b','dl_21b','dl_expiry'))),
     'chips', jsonb_build_object(
       'store_type', jsonb_build_array('Retail pharmacy','Hospital pharmacy','Clinic','Wholesale')),
     'street_zoom', 18,
     'check_debounce_ms', 400,
     'phone_digits', 10,
     'autofill', jsonb_build_object(
       'customer_name', 'name', 'pharmacy_name', 'organizationName',
       'whatsapp_no', 'telephoneNumberNational', 'email', 'email'),
     'checks', jsonb_build_object('whatsapp_no', 'phone', 'email', 'email'),
     'prefix', jsonb_build_object('customer_name', jsonb_build_object(
         'key', 'owner_salutation', 'default', 'Mr',
         'options', jsonb_build_array(
            jsonb_build_object('label','Mr','value','Mr'),
            jsonb_build_object('label','Ms','value','Ms')))),
     'browse_route', '/'))
on conflict (key) do nothing;

-- ── 3. Mr/Ms sits inside the name box, and the bar's one signal ──────────
-- Every colour, weight and mark below is DATA: recolouring the bar, or
-- putting Mr/Ms back beside the box, is an UPDATE here and no deploy.
update public.app_settings
   set value = jsonb_set(
         value,
         '{prefix,customer_name,inline}', 'true'::jsonb, true)
       || jsonb_build_object('step_bar', jsonb_build_object(
            -- You are HERE: the only coloured bar on the screen.
            'current', jsonb_build_object(
              'bar', 'brand', 'label', 'brand', 'bold', true, 'tick', false),
            -- Behind you: grey bar, a small tick beside the label.
            'done', jsonb_build_object(
              'bar', 'divider', 'label', 'secondary', 'bold', false, 'tick', true),
            -- Not reached: grey bar, grey label, no mark at all.
            'todo', jsonb_build_object(
              'bar', 'divider', 'label', 'secondary', 'bold', false, 'tick', false)))
 where key = 'custreg_wizard'
   and (not (value ? 'step_bar')
        or value #> '{prefix,customer_name,inline}' is distinct from 'true'::jsonb);

-- ── 4. The payload carries the block ─────────────────────────────────────
-- Patched the way #2141 patched it: read what LIVE actually has and add one
-- key, so nothing a later change put in the function is rewritten back.
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_wizard'::regproc) into d;
  if position('step_bar' in d) = 0 then
    d := replace(d, '''prefix'',         coalesce(v_cfg->''prefix'', ''{}''::jsonb),',
      '''prefix'',         coalesce(v_cfg->''prefix'', ''{}''::jsonb),' || chr(10) ||
      '    ''step_bar'',       coalesce(v_cfg->''step_bar'', ''{}''::jsonb)' || chr(10) ||
      '                        || jsonb_build_object(''tick'', public._c(''custreg.wiz_step_tick'')),');
    execute d;
  end if;
end $$;

commit;

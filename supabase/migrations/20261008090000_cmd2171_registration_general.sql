-- CMD #2171 — Registration + Add customer / Import · General, final gaps.
--
-- #2151 shipped the General screen; three things in the approved design
-- (artifact QPkmf4hsSN5jZW1LFKp8E6 · #general-step and #registration-final)
-- were still missing on live:
--
--  1. Every box that is NOT mandatory prints a grey "optional" after its
--     label — d02 ("Store type optional") and d03 (staff: "Owner name
--     optional", "Email optional", "Store type optional"). That word is the
--     only thing on the screen that says the two surfaces differ, and the
--     payload never carried it, so no screen could print it.
--  2. The staff required set. #2151 tried to wrap addcust_open's schema call
--     with _addcust_staff_schema by replacing the text
--     "v_schema := public.customer_form_schema('signup');" — addcust_open has
--     said "v_schema := public._addcust_schema();" since #2129, so the replace
--     matched nothing and re-executed the function unchanged. The staff set
--     therefore still comes from app_settings['addcust.required_fields'],
--     which is pinned here to the spec's own set: Pharmacy name + WhatsApp
--     (the shop pin is required on Location).
--  3. Nothing here — the Documents list, the OCR popup and the map already
--     render from the backend correctly (audited on live, 22 Sep).
--
-- Idempotent: copy is inserted only when absent; the wizard is patched by text
-- replace guarded on the new key being absent.

insert into public.ui_copy(key, value) values
  ('custreg.v4_optional_field', to_jsonb('optional'::text))
on conflict (key) do nothing;

-- ── 1. optional_label: the word every non-mandatory box prints ─────────────
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_wizard'::regproc) into d;
  if position('optional_label' in d) = 0 then
    execute replace(d,
      '''required_label'', public._c(''custreg.v4_required''),',
      '''required_label'', public._c(''custreg.v4_required''),' || chr(10) ||
      '    ''optional_label'', public._c(''custreg.v4_optional_field''),');
  end if;
end $$;

-- ── 2. The staff required set the spec names ───────────────────────────────
-- Pharmacy name + WhatsApp here; the shop pin is required on Location. Owner
-- name, email and store type stay optional for staff — that is exactly what
-- the "optional" word above now prints.
insert into public.app_settings(key, value)
values ('addcust.required_fields',
        '["pharmacy_name","whatsapp_no","store_pin"]'::jsonb)
on conflict (key) do update
   set value = excluded.value
 where public.app_settings.value is distinct from excluded.value;

-- ── 3. Om, live on APK 1.3.33: the number cleaner drops ANY country code ───
--
-- Picking "0835 788 1873" from the phone's own list filled the box with
-- "+448357881873" and the check said Invalid. The app half of that is fixed in
-- PhoneClean (one cleaner for picker / autofill / paste / typing); this is the
-- backend half, which only knew how to drop "91" and a leading 0. A number
-- longer than the expected length now keeps its LAST v_total digits, which
-- drops 91, 44 or anything else, and the leading 0 with it — and never ADDS a
-- code. Whether what is left is a real number is unchanged: ten digits
-- starting 6-9, judged exactly where it was judged before.
do $$
declare d text;
begin
  select pg_get_functiondef('public.custreg_contact_check(text, text, uuid)'::regprocedure) into d;
  if position('CMD #2171 — any country code' in d) = 0 then
    execute replace(d,
      '    if length(v_n) > v_total and left(v_n, 2) = ''91'' then v_n := substr(v_n, 3); end if;' || chr(10) ||
      '    if length(v_n) > v_total and left(v_n, 1) = ''0'' then v_n := substr(v_n, 2); end if;',
      '    -- CMD #2171 — any country code, not just 91: the last v_total digits' || chr(10) ||
      '    -- ARE the number. 918357881873, 448357881873 and 08357881873 all end' || chr(10) ||
      '    -- as 8357881873; nothing is ever prefixed.' || chr(10) ||
      '    if length(v_n) > v_total then v_n := right(v_n, v_total); end if;');
  end if;
end $$;

-- ── 4. The screen is told how long a number is ─────────────────────────────
-- phone_digits already sits in the custreg_wizard config; the payload never
-- carried it, so the app had 10 written into it.
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_wizard'::regproc) into d;
  if position('''phone_digits''' in d) = 0 then
    execute replace(d,
      '''phone_prefix'',   coalesce(v_cfg->>''phone_prefix'', ''+91''),',
      '''phone_prefix'',   coalesce(v_cfg->>''phone_prefix'', ''+91''),' || chr(10) ||
      '    ''phone_digits'',  coalesce((v_cfg->>''phone_digits'')::int, 10),');
  end if;
end $$;

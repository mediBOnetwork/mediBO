-- CMD #2171 — Om, live on APK 1.3.33, Add customer (staff).
--
-- Four things the screen was getting wrong, all of them because a word or a
-- decision had been made in the app instead of here:
--
--   1. The WhatsApp box printed TWO verdicts at once — "Already registered"
--      from addcust_number_check AND a green "New" from custreg_contact_check.
--      Two backends judging the same number is how they end up disagreeing.
--      On THIS surface addcust_number_check is the judge, so the payload stops
--      asking the form to run its own check on that field.
--   2. Continue was gated on the form's check, not on the one verdict, so a
--      number that was free could still leave the button dead. The verdict now
--      carries the cleaned number as well (`value`), which is what the box
--      shows — the same "last ten digits" rule as everywhere else.
--   3. Save meant "finish": it ran addcust_finish and jumped to the done
--      screen. Save now answers with its own line and the staff stay where
--      they are; only the last step finishes.
--   4. The done screen said "WhatsApp invite sent to …" whenever the send call
--      did not raise. It did not mean sent — wa_send_event QUEUES a recipient,
--      and the customer_imported template is still awaiting Meta. The screen
--      now prints what actually happened: sent / queued / not sent + reason.
--
-- Idempotent: every patch is guarded by its own marker.

-- ── 1. Copy for the honest invite line and for Save-and-stay ───────────────
insert into public.ui_copy (key, value) values
  ('addcust.invite_queued',
   to_jsonb('WhatsApp invite queued for {phone} — it goes out as soon as WhatsApp accepts it'::text)),
  ('addcust.invite_not_sent',
   to_jsonb('WhatsApp invite not sent to {phone} — {reason}'::text)),
  ('addcust.invite_reason_template',
   to_jsonb('the invite template is still {status} with Meta'::text)),
  ('addcust.invite_reason_unknown',
   to_jsonb('the send could not be started'::text)),
  ('addcust.saved_stay',
   to_jsonb('Saved. Carry on — the customer is told only at the last step.'::text))
on conflict (key) do nothing;

-- ── 2. One verdict on the number box ───────────────────────────────────────
-- The wizard payload this screen hands the shared form no longer lists
-- whatsapp_no in `checks`, so the form runs no second check on it and prints
-- no second suffix. addcust_number_check is the only judge here.
do $$
declare d text;
begin
  select pg_get_functiondef('public.addcust_open'::regproc) into d;
  if position('CMD #2171 — one verdict' in d) = 0 then
    d := replace(d,
      '    ''wizard'', (v_wiz - ''done'') || jsonb_build_object(' || chr(10) ||
      '                ''steps'', v_steps, ''resume_step'', 0, ''field_notes'', ''{}''::jsonb,',
      '    -- CMD #2171 — one verdict on the number box: addcust_number_check' || chr(10) ||
      '    -- is this screen''''s judge, so the shared form is not asked to run' || chr(10) ||
      '    -- custreg_contact_check on whatsapp_no as well.' || chr(10) ||
      '    ''wizard'', (v_wiz - ''done'') || jsonb_build_object(' || chr(10) ||
      '                ''checks'', coalesce(v_wiz->''checks'', ''{}''::jsonb) - ''whatsapp_no'',' || chr(10) ||
      '                ''steps'', v_steps, ''resume_step'', 0, ''field_notes'', ''{}''::jsonb,');
    if position('CMD #2171 — one verdict' in d) = 0 then
      raise exception 'CMD #2171: addcust_open no longer matches the wizard block this patch expects';
    end if;
    execute d;
  end if;
end $$;

-- ── 3. The verdict carries the cleaned number ──────────────────────────────
-- _phone10 has already reduced what was typed, picked, pasted or autofilled to
-- its last ten digits. Sending that back as `value` lets the box show the
-- number the check actually judged, instead of the "+448357881873" the phone's
-- own list offered.
do $$
declare d text;
begin
  select pg_get_functiondef('public.addcust_number_check(text, uuid)'::regprocedure) into d;
  if position('''value'', v_n' in d) = 0 then
    execute replace(d, 'jsonb_build_object(''ok'', true, ''state''',
                       'jsonb_build_object(''value'', v_n, ''ok'', true, ''state''');
  end if;
end $$;

-- ── 4. Save answers for itself ─────────────────────────────────────────────
-- Save used to be wired to the finish call; it is a save, and it says so.
do $$
declare d text;
begin
  select pg_get_functiondef('public.addcust_save'::regproc) into d;
  if position('CMD #2171 — Save says so' in d) = 0 then
    d := replace(d,
      '  return jsonb_build_object(''ok'', true, ''customer_id'', v_id, ''step'', p_step,' || chr(10) ||
      '                            ''licences'', public.addcust_licences(v_id),',
      '  -- CMD #2171 — Save says so, and the staff stay on the step. Only the' || chr(10) ||
      '  -- last step finishes and shows the done screen.' || chr(10) ||
      '  return jsonb_build_object(''ok'', true, ''customer_id'', v_id, ''step'', p_step,' || chr(10) ||
      '                            ''saved'', jsonb_build_object(''show'', true, ''tone'', ''success'',' || chr(10) ||
      '                                        ''label'', public._c(''addcust.saved_stay'')),' || chr(10) ||
      '                            ''licences'', public.addcust_licences(v_id),');
    if position('CMD #2171 — Save says so' in d) = 0 then
      raise exception 'CMD #2171: addcust_save no longer matches the return block this patch expects';
    end if;
    execute d;
  end if;
end $$;

-- ── 5. The done screen never claims an invite it did not send ──────────────
do $$
declare d text;
begin
  select pg_get_functiondef('public.addcust_finish(uuid, jsonb, jsonb)'::regprocedure) into d;
  if position('CMD #2171 — what actually happened' in d) = 0 then
    d := replace(d,
      '  v_sent boolean := false; v_phone text; v_lic_total int; v_lic_done int; v_lic jsonb;',
      '  v_sent boolean := false; v_phone text; v_lic_total int; v_lic_done int; v_lic jsonb;' || chr(10) ||
      '  v_wa jsonb; v_inv text := ''off''; v_reason text := ''''; v_tstat text; v_rstat text;');

    d := replace(d,
      '  if v_invite then' || chr(10) ||
      '    begin' || chr(10) ||
      '      perform public.wa_send_event(''customer_imported'', p_customer_id,' || chr(10) ||
      '        jsonb_build_object(''name'', r.pharmacy_name, ''pharmacy_name'', r.pharmacy_name, ''phone'', v_phone),' || chr(10) ||
      '        v_phone, null);' || chr(10) ||
      '      v_sent := true;' || chr(10) ||
      '    exception when others then v_sent := false; end;' || chr(10) ||
      '  end if;',
      '  -- CMD #2171 — what actually happened, not what was attempted.' || chr(10) ||
      '  -- wa_send_event QUEUES a recipient; it does not deliver, and it comes' || chr(10) ||
      '  -- back ok:false with its own sentence when it cannot even queue. The' || chr(10) ||
      '  -- screen prints exactly one of sent / queued / not sent + reason.' || chr(10) ||
      '  if v_invite then' || chr(10) ||
      '    begin' || chr(10) ||
      '      v_wa := public.wa_send_event(''customer_imported'', p_customer_id,' || chr(10) ||
      '        jsonb_build_object(''name'', r.pharmacy_name, ''pharmacy_name'', r.pharmacy_name, ''phone'', v_phone),' || chr(10) ||
      '        v_phone, null);' || chr(10) ||
      '    exception when others then' || chr(10) ||
      '      v_wa := jsonb_build_object(''ok'', false, ''message'', sqlerrm);' || chr(10) ||
      '    end;' || chr(10) ||
      '    if coalesce((v_wa->>''ok'')::boolean, false) then' || chr(10) ||
      '      select cr.status into v_rstat from public.wa_campaign_recipients cr' || chr(10) ||
      '       where cr.id = nullif(v_wa->>''recipient_id'','''')::uuid;' || chr(10) ||
      '      select t.status into v_tstat from public.wa_event_routes er' || chr(10) ||
      '        join public.wa_templates t on t.id = er.template_id' || chr(10) ||
      '       where er.event_key = ''customer_imported'' limit 1;' || chr(10) ||
      '      if coalesce(v_rstat,'''') in (''sent'',''delivered'',''read'') then' || chr(10) ||
      '        v_inv := ''sent'';' || chr(10) ||
      '      elsif v_tstat is not null and upper(v_tstat) <> ''APPROVED'' then' || chr(10) ||
      '        v_inv := ''not_sent'';' || chr(10) ||
      '        v_reason := replace(public._c(''addcust.invite_reason_template''), ''{status}'', lower(v_tstat));' || chr(10) ||
      '      else' || chr(10) ||
      '        v_inv := ''queued'';' || chr(10) ||
      '      end if;' || chr(10) ||
      '    else' || chr(10) ||
      '      v_inv := ''not_sent'';' || chr(10) ||
      '      v_reason := coalesce(nullif(v_wa->>''message'',''''), nullif(v_wa->>''reason'',''''),' || chr(10) ||
      '                           public._c(''addcust.invite_reason_unknown''));' || chr(10) ||
      '    end if;' || chr(10) ||
      '    v_sent := v_inv = ''sent'';' || chr(10) ||
      '  end if;');

    d := replace(d,
      '    ''invite'', jsonb_build_object(''show'', true, ''tone'', case when v_sent then ''success'' else ''neutral'' end,' || chr(10) ||
      '               ''label'', case when v_sent then replace(public._c(''addcust.invite_sent''), ''{phone}'', public._addcust_phone_label(v_phone))' || chr(10) ||
      '                             else public._c(''addcust.invite_off'') end),',
      '    ''invite'', jsonb_build_object(''show'', true, ''state'', v_inv,' || chr(10) ||
      '               ''tone'', case v_inv when ''sent'' then ''success'' when ''queued'' then ''info''' || chr(10) ||
      '                                   when ''not_sent'' then ''warning'' else ''neutral'' end,' || chr(10) ||
      '               ''label'', replace(replace(case v_inv' || chr(10) ||
      '                            when ''sent'' then public._c(''addcust.invite_sent'')' || chr(10) ||
      '                            when ''queued'' then public._c(''addcust.invite_queued'')' || chr(10) ||
      '                            when ''not_sent'' then public._c(''addcust.invite_not_sent'')' || chr(10) ||
      '                            else public._c(''addcust.invite_off'') end,' || chr(10) ||
      '                          ''{phone}'', public._addcust_phone_label(v_phone)), ''{reason}'', v_reason)),');

    if position('CMD #2171 — what actually happened' in d) = 0
       or position('''state'', v_inv' in d) = 0 then
      raise exception 'CMD #2171: addcust_finish no longer matches the blocks this patch expects';
    end if;
    execute d;
  end if;
end $$;

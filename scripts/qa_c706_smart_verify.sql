\set ON_ERROR_STOP on
begin;
-- Four synthetic applicants, torn down at the end. is_synthetic keeps them out
-- of every money report and out of the KYC gate's own enforcement.
do $$
declare
  z smallint; p1 uuid; p2 uuid; p3 uuid; p4 uuid; other uuid;
  d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid;
  v jsonb;
begin
  select id into z from zones order by is_default desc, id limit 1;
  update zones set gst_state_code = '22' where id = z;

  -- clean applicant: pin at the shop, licence + GST that agree with everything
  insert into pharmacy_profiles(pharmacy_name, phone, city, district, state, address, pincode,
                                latitude, longitude, zone_id, is_synthetic, approved, status)
  values ('C706 Clean Medical Stores','9000000706','Raipur','Raipur','Chhattisgarh',
          'Shop 1, GE Road','492001', 21.2514, 81.6296, z, true, false, 'pending')
  returning id into p1;

  insert into pharmacy_profiles(pharmacy_name, phone, city, address, pincode, zone_id, is_synthetic, approved, status)
  values ('C706 Bad Checksum Pharma','9000000707','Raipur','Addr 2','492001', z, true, false, 'pending') returning id into p2;

  insert into pharmacy_profiles(pharmacy_name, phone, city, address, pincode, zone_id, is_synthetic, approved, status)
  values ('C706 Duplicate Pharma','9000000708','Raipur','Addr 3','492001', z, true, false, 'pending') returning id into p3;

  insert into pharmacy_profiles(pharmacy_name, phone, city, address, pincode, zone_id, is_synthetic, approved, status,
                                latitude, longitude)
  values ('C706 Far Pin Pharma','9000000709','Raipur','Addr 4','492001', z, true, false, 'pending', 21.2514, 81.6296)
  returning id into p4;

  raise notice '--- SCENARIO 1: clean applicant ---';
  insert into kyc_documents(owner_kind, owner_id, kind, path, number, valid_to, zone_id, source)
  values ('pharmacy', p1, 'drug_licence', 'x/clean-dl.jpg', 'CG/RPR/20B/706001',
          (current_date + 400), z, 'admin') returning id into d1;
  -- the reader agrees with the applicant, and the address geocodes onto the pin
  perform public.kyc_ocr_ingest(d1, 'done',
    jsonb_build_object('licence_number','CG/RPR/20B/706001',
                       'licensee_name','C706 Clean Medical Stores',
                       'address','Shop 1, GE Road, Raipur, Chhattisgarh 492001',
                       'valid_to', (current_date + 400)::text),
    jsonb_build_object('source','osm','lat',21.2515,'lng',81.6297));
  raise notice 'doc1 -> % / account approved=%',
    (select status from kyc_documents where id = d1),
    (select approved from pharmacy_profiles where id = p1);
  raise notice 'doc1 tier=% verdict=%',
    (select tier from kyc_verify_run where doc_id=d1 order by seq desc limit 1),
    (select verdict from kyc_verify_run where doc_id=d1 order by seq desc limit 1);

  raise notice '--- SCENARIO 2: wrong GSTIN checksum ---';
  insert into kyc_documents(owner_kind, owner_id, kind, path, number, zone_id, source)
  values ('pharmacy', p2, 'gst_certificate', 'x/bad-gst.jpg', '27AAPFU0939F1ZZ', z, 'admin')
  returning id into d2;
  raise notice 'doc2 -> % : %',
    (select status from kyc_documents where id = d2),
    (select reason from kyc_documents where id = d2);

  raise notice '--- SCENARIO 3: duplicate drug licence ---';
  -- p1 already owns CG/RPR/20B/706001 (claimed when its document was verified)
  select public.kyc_identity_conflict('dl','CGRPR20B706001','pharmacy',p3::text) into v;
  raise notice 'conflict seen by p3 -> has=% name=% message=%',
    v->>'has', v->>'owner_name', v->>'message';
  begin
    insert into kyc_documents(owner_kind, owner_id, kind, path, number, valid_to, zone_id, source)
    values ('pharmacy', p3, 'drug_licence', 'x/dup-dl.jpg', 'CG-RPR-20B-706001',
            (current_date + 400), z, 'admin') returning id into d3;
    raise notice 'doc3 -> % : %',
      (select status from kyc_documents where id = d3),
      (select reason from kyc_documents where id = d3);
  end;
  -- and the profile write itself is refused
  begin
    update pharmacy_profiles set drug_license = 'CG/RPR/20B/706001' where id = p3;
    raise notice 'PROFILE WRITE WAS NOT BLOCKED (bug)';
  exception when others then
    raise notice 'profile write blocked -> %', sqlerrm;
  end;

  raise notice '--- SCENARIO 4: pin far from the printed address ---';
  insert into kyc_documents(owner_kind, owner_id, kind, path, number, valid_to, zone_id, source)
  values ('pharmacy', p4, 'drug_licence', 'x/far-dl.jpg', 'CG/RPR/20B/706004',
          (current_date + 400), z, 'admin') returning id into d4;
  perform public.kyc_ocr_ingest(d4, 'done',
    jsonb_build_object('licence_number','CG/RPR/20B/706004',
                       'licensee_name','C706 Far Pin Pharma',
                       'address','Civil Lines, Bilaspur, Chhattisgarh'),
    jsonb_build_object('source','osm','lat',22.0797,'lng',82.1409));
  raise notice 'doc4 -> % tier=% mismatches=%',
    (select status from kyc_documents where id = d4),
    (select tier from kyc_verify_run where doc_id=d4 order by seq desc limit 1),
    (select jsonb_pretty(jsonb_agg(c->>'label' || ': ' || (c->>'detail')))
       from kyc_verify_run r, jsonb_array_elements(r.checks) c
      where r.doc_id=d4 and c->>'status' in ('warn','fail'));

  raise notice '--- SCENARIO 5: expired document ---';
  insert into kyc_documents(owner_kind, owner_id, kind, path, number, valid_to, zone_id, source)
  values ('pharmacy', p2, 'pan', 'x/old.jpg', 'AAPFU0939F', (current_date - 5), z, 'admin')
  returning id into d5;
  raise notice 'doc5 -> % : %',
    (select status from kyc_documents where id = d5),
    (select reason from kyc_documents where id = d5);

  raise notice '--- panel payload (doc1) ---';
  raise notice '%', jsonb_pretty(public.kyc_verify_panel(d1));
end $$;
rollback;

-- CMD #426 — the /near proof. Seeds two pharmacies at KNOWN distances from one
-- consumer point, pours inferred stock into them, and drives every rule the
-- spec asks for: opt-in only, the honesty tiers, the distance fence, the two
-- ways a pharmacy drops off the list, the rate limit, and — the one that
-- matters most — that no trade data ever reaches a public payload.
-- One transaction, rolled back. It leaves nothing behind.
\set ON_ERROR_STOP on
\pset pager off
begin;

create or replace function pg_temp.chk(p_label text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS  %  %', p_label, p_detail;
  else        raise notice 'FAIL  %  %', p_label, p_detail;
  end if;
end $$;

do $proof$
declare
  -- Consumer stands here (central Raipur).
  c_lat double precision := 21.2514;
  c_lng double precision := 81.6296;
  v_near uuid; v_far uuid; v_closed uuid;
  v_med bigint; v_med2 bigint;
  v_lot1 uuid := gen_random_uuid(); v_lot2 uuid := gen_random_uuid();
  v_lot3 uuid := gen_random_uuid();
  v_r jsonb; v_rows jsonb; v_txt text; n int; v_tok text;
  v_km_near numeric; v_km_far numeric;
begin
  -- ── seed catalogue ───────────────────────────────────────────────────────
  select id into v_med  from public."MEDICINE"
   where public._norm_name(product_name) like 'c426alpha%' limit 1;
  if v_med is null then
    insert into public."MEDICINE" (product_name, buyable, status, data_source)
    values ('C426ALPHA 500MG TABLET', true, 'ACTIVE', 'c426_proof') returning id into v_med;
  end if;
  insert into public."MEDICINE" (product_name, buyable, status, data_source)
  values ('C426BETA 250MG TABLET', true, 'ACTIVE', 'c426_proof') returning id into v_med2;

  -- ── seed three pharmacies at known distances ─────────────────────────────
  -- 0.018° lat ≈ 2 km, 0.090° lat ≈ 10 km (outside the 8 km fence).
  insert into public.pharmacy_profiles (pharmacy_name, phone, city, pincode, address,
         latitude, longitude, approved, status)
  values ('C426 Near Chemist', '9426000001', 'Raipur', '492001', 'C426 proof address',
          c_lat + 0.018, c_lng, true, 'active') returning id into v_near;
  insert into public.pharmacy_profiles (pharmacy_name, phone, city, pincode, address,
         latitude, longitude, approved, status)
  values ('C426 Far Chemist', '9426000002', 'Raipur', '492001', 'C426 proof address',
          c_lat + 0.090, c_lng, true, 'active') returning id into v_far;
  insert into public.pharmacy_profiles (pharmacy_name, phone, city, pincode, address,
         latitude, longitude, approved, status)
  values ('C426 Opted Out Chemist', '9426000003', 'Raipur', '492001', 'C426 proof address',
          c_lat + 0.009, c_lng, true, 'active') returning id into v_closed;

  v_km_near := public._c426_km(c_lat, c_lng, c_lat + 0.018, c_lng);
  v_km_far  := public._c426_km(c_lat, c_lng, c_lat + 0.090, c_lng);
  perform pg_temp.chk('01 distance maths',
    v_km_near between 1.9 and 2.1 and v_km_far between 9.9 and 10.1,
    format('near=%s km far=%s km', v_km_near, v_km_far));

  -- Two opt in. The third never touches the toggle — it must stay invisible
  -- even though it is the CLOSEST of the three.
  insert into public.near_listing_config (pharmacy_id, opted_in, show_phone)
  values (v_near, true, true), (v_far, true, true);
  perform public._c426_ensure_token(v_near);
  perform public._c426_ensure_token(v_far);

  -- ── pour inferred stock ──────────────────────────────────────────────────
  -- the lots the inference engine pours over (its FK target)
  insert into public.pharmacy_stock (id, pharmacy_id, medicine_id, product_name,
         item_key, batch_no, expiry_on, qty, source_kind, received_on)
  values
    (v_lot1, v_near,   v_med, 'C426ALPHA 500MG TABLET', 'c426alpha', 'B1',
     current_date + 300, 100, 'bill', current_date - 20),
    (v_lot2, v_far,    v_med, 'C426ALPHA 500MG TABLET', 'c426alpha', 'B2',
     current_date + 300, 100, 'bill', current_date - 20),
    (v_lot3, v_closed, v_med, 'C426ALPHA 500MG TABLET', 'c426alpha', 'B3',
     current_date + 300, 100, 'bill', current_date - 20);

  insert into public.pharmacy_lot_inference
    (lot_id, pharmacy_id, medicine_id, received_on, expiry_on, qty_in,
     inferred_sold, inferred_left, left_low, left_high, confidence, method,
     per_day, days_live, computed_at)
  values
    (v_lot1, v_near, v_med, current_date - 20, current_date + 300, 100,
     40, 60, 40, 80, 0.80, 'inferred', 2, 20, now()),
    (v_lot2, v_far,  v_med, current_date - 20, current_date + 300, 100,
     60, 40, 20, 60, 0.45, 'inferred', 3, 20, now()),
    (v_lot3, v_closed, v_med, current_date - 20, current_date + 300, 100,
     10, 90, 80, 95, 0.95, 'inferred', 1, 20, now());

  -- ── 1) the search itself ─────────────────────────────────────────────────
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  v_rows := v_r->'rows';
  perform pg_temp.chk('02 search ok', (v_r->>'ok')::boolean, v_r->>'error');
  perform pg_temp.chk('03 opt-in only — the closest pharmacy never opted in',
    not (v_rows::text like '%Opted Out%'),
    'closest shop is 1.0 km away and absent');
  perform pg_temp.chk('04 distance fence — 10 km shop excluded at max_km=8',
    not (v_rows::text like '%Far Chemist%'), v_r->>'count_label');
  perform pg_temp.chk('05 the 2 km opted-in shop is listed',
    v_rows::text like '%Near Chemist%', v_r->>'count_label');

  -- ── 2) the honesty wording is the backend's, and tiered ──────────────────
  perform pg_temp.chk('06 tier sentence is confidence-tiered',
    v_rows->0->'tier'->>'label' = public.ui_text('near.tier_high'),
    v_rows->0->'tier'->>'label');
  perform pg_temp.chk('07 distance label is a backend string',
    v_rows->0->>'distance_label' = public.ui_text_f('near.distance_label',
      jsonb_build_object('km', to_char(v_km_near, 'FM999990.0'))),
    v_rows->0->>'distance_label');
  perform pg_temp.chk('08 call + directions are descriptors, not raw fields',
    (v_rows->0->'call'->>'has')::boolean
      and (v_rows->0->'directions'->>'has')::boolean
      and v_rows->0->'directions'->>'url' like 'https://www.google.com/maps/dir/%',
    v_rows->0->'call'->>'label');
  perform pg_temp.chk('09 the disclaimer travels with every result',
    length(coalesce(v_r->>'disclaimer','')) > 40, left(v_r->>'disclaimer', 48) || '…');

  -- ── 3) NO TRADE DATA. The one that must never regress. ───────────────────
  v_txt := lower(v_r::text);
  perform pg_temp.chk('10 no rupee figure anywhere in the public payload',
    v_txt not like '%₹%' and v_txt not like '%"mrp"%' and v_txt not like '%price%'
    and v_txt not like '%"rate"%' and v_txt not like '%cost%', 'payload scanned');
  perform pg_temp.chk('11 no quantity, no confidence number, no supplier',
    v_txt not like '%inferred_left%' and v_txt not like '%"qty%'
    and v_txt not like '%confidence%' and v_txt not like '%supplier%'
    and v_txt not like '%batch%' and v_txt not like '%invoice%',
    'only the tier SENTENCE crosses, never the number');
  perform pg_temp.chk('12 the internal pharmacy id never crosses either',
    v_txt not like '%' || v_near::text || '%', 'cards carry the poster token');

  -- ── 4) a "0 left" correction drops the listing immediately ───────────────
  insert into public.pharmacy_lot_correction
    (lot_id, pharmacy_id, medicine_id, actual_left, inferred_was, source)
  values (v_lot1, v_near, v_med, 0, 60, 'proof');
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('13 correction to 0 drops it at once',
    (v_r->>'count')::int = 0 and v_r->'rows'::text not like '%Near Chemist%',
    'inference row untouched; the correction is the authority');
  delete from public.pharmacy_lot_correction where lot_id = v_lot1 and source = 'proof';

  -- ── 5) one-tap "mark unavailable" ────────────────────────────────────────
  insert into public.near_unavailable (pharmacy_id, medicine_id, until)
  values (v_near, v_med, now() + interval '6 hours');
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('14 one-tap hide removes the card',
    (v_r->>'count')::int = 0, 'hidden for 6 h');
  update public.near_unavailable set until = now() - interval '1 minute'
   where pharmacy_id = v_near and medicine_id = v_med;
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('15 an expired hide comes back on its own',
    (v_r->>'count')::int = 1, 'until passed');
  delete from public.near_unavailable where pharmacy_id = v_near;

  -- ── 6) pincode fallback ──────────────────────────────────────────────────
  v_r := public.near_search('c426alpha', null, null, '492001');
  perform pg_temp.chk('16 pincode fallback places the consumer',
    (v_r->>'ok')::boolean and (v_r->>'count')::int >= 1, v_r->>'count_label');
  v_r := public.near_search('c426alpha', null, null, '999999');
  perform pg_temp.chk('17 an unknown pincode is an honest refusal',
    v_r->>'error' = 'need_origin', v_r->>'message');

  -- ── 7) below the confidence floor is silence, not a card ─────────────────
  update public.pharmacy_lot_inference set confidence = 0.05 where lot_id = v_lot1;
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('18 under min_confidence nothing is claimed',
    (v_r->>'count')::int = 0, 'no card rather than a weak one');
  update public.pharmacy_lot_inference set confidence = 0.80 where lot_id = v_lot1;

  -- ── 8) a SKU the shop never bought is not a result ───────────────────────
  v_r := public.near_search('c426beta', c_lat, c_lng);
  perform pg_temp.chk('19 no stock, no card',
    (v_r->>'count')::int = 0, 'never invented');

  -- ── 9) the pharmacy's own public page ────────────────────────────────────
  select token into v_tok from public.near_poster where pharmacy_id = v_near;
  v_r := public.near_pharmacy(v_tok);
  perform pg_temp.chk('20 the QR page resolves by token',
    (v_r->>'ok')::boolean and v_r->>'name' = 'C426 Near Chemist', v_r->>'name');
  perform pg_temp.chk('21 the QR page carries no trade data either',
    lower(v_r::text) not like '%price%' and lower(v_r::text) not like '%qty%'
    and lower(v_r::text) not like '%₹%', 'availability surface only');
  v_r := public.near_pharmacy('not-a-real-token');
  perform pg_temp.chk('22 an unknown token is the backend''s own empty state',
    v_r->>'error' = 'not_found' and length(coalesce(v_r->>'message','')) > 5,
    v_r->>'message');

  -- ── 10) an opted-out pharmacy disappears from its own page too ───────────
  update public.near_listing_config set opted_in = false where pharmacy_id = v_near;
  v_r := public.near_pharmacy(v_tok);
  perform pg_temp.chk('23 opting out unlists immediately',
    v_r->>'error' = 'not_found', 'toggle is the fence');
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('24 …and removes it from search',
    (v_r->>'count')::int = 0, 'strictly opt-in');
  update public.near_listing_config set opted_in = true where pharmacy_id = v_near;

  -- ── 11) rate limit / bot protection ──────────────────────────────────────
  update public.near_config set rate_per_min = 3 where id;
  delete from public.near_rate;
  for n in 1..3 loop perform public.near_search('c426alpha', c_lat, c_lng); end loop;
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('25 the 4th search past a cap of 3 is refused',
    v_r->>'error' = 'rate_limited' and (v_r->>'retry_after_s')::int > 0,
    v_r->>'message');
  perform pg_temp.chk('26 the refusal is copy, not a Postgres error',
    v_r->>'message' = public.ui_text('near.rate_limited'), v_r->>'message');
  perform pg_temp.chk('27 the block is recorded against a HASH, never an IP',
    exists (select 1 from public.near_rate where blocked_until > now()
              and bucket !~ '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'), 'bucket is opaque');
  update public.near_config set rate_per_min = 20 where id;
  delete from public.near_rate;

  -- ── 12) the kill switch ──────────────────────────────────────────────────
  update public.near_config set enabled = false where id;
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('28 the whole surface is one flag',
    v_r->>'error' = 'disabled' and v_r->>'message' = public.ui_text('near.disabled'),
    'no deploy needed to close it');
  update public.near_config set enabled = true where id;

  -- ── 13) the poster job ───────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v_r := public.near_poster_job(v_tok);
  perform pg_temp.chk('29 the poster job knows the name and the QR target',
    (v_r->>'ok')::boolean and v_r->>'url' = 'https://medibo.in/near/p/' || v_tok
    and v_r->>'bucket' = 'near-posters', v_r->>'url');
  perform pg_temp.chk('30 the poster carries no trade data',
    lower(v_r::text) not like '%price%' and lower(v_r::text) not like '%qty%',
    'name + area + QR');
  v_r := public.near_poster_report(v_tok, 'near-posters', v_tok || '.pdf', 40311, null);
  perform pg_temp.chk('31 the edge function reports back through the RPC',
    (v_r->>'ok')::boolean and exists (select 1 from public.near_poster
      where token = v_tok and status = 'ready' and bytes = 40311), 'status=ready');
  perform set_config('request.jwt.claims', '', true);

  -- ── 14) ranking: confidence x distance ───────────────────────────────────
  -- Put the far shop inside the fence and give it the WEAKER confidence: the
  -- nearer, more confident shop must rank first.
  update public.pharmacy_profiles set latitude = c_lat + 0.045 where id = v_far;
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('32 both in-fence shops are returned',
    (v_r->>'count')::int = 2, v_r->>'count_label');
  perform pg_temp.chk('33 confidence x distance decides the order',
    v_r->'rows'->0->>'name' = 'C426 Near Chemist'
    and v_r->'rows'->1->>'name' = 'C426 Far Chemist',
    format('%s then %s', v_r->'rows'->0->>'name', v_r->'rows'->1->>'name'));
  perform pg_temp.chk('34 the weaker shop gets the weaker sentence',
    v_r->'rows'->1->'tier'->>'label' = public.ui_text('near.tier_mid'),
    v_r->'rows'->1->'tier'->>'label');
  perform pg_temp.chk('35 plural count label comes from the backend',
    v_r->>'count_label' = public.ui_text_f('near.results_label_p',
      jsonb_build_object('n', 2)), v_r->>'count_label');

  -- ── 15) show_phone is a real fence ───────────────────────────────────────
  update public.near_listing_config set show_phone = false where pharmacy_id = v_near;
  v_r := public.near_search('c426alpha', c_lat, c_lng);
  perform pg_temp.chk('36 show_phone=false removes the number, not just the button',
    (v_r->'rows'->0->'call'->>'has')::boolean is false
      and v_r->'rows'->0->'call'->'tel' = 'null'::jsonb
      and v_r::text not like '%9426000001%', 'no phone in the payload at all');
  update public.near_listing_config set show_phone = true where pharmacy_id = v_near;

  -- ── 16) the boot payload prints the page ─────────────────────────────────
  v_r := public.near_boot();
  perform pg_temp.chk('37 every consumer string ships from the backend',
    (select count(*) from jsonb_each_text(v_r->'copy') where value <> '') = 18,
    (select count(*)::text from jsonb_each_text(v_r->'copy')) || ' keys, none empty');

  -- ── 17) the search log keeps a query, never a person ─────────────────────
  perform pg_temp.chk('38 the log stores the normalised query and a hash',
    exists (select 1 from public.near_search_log
             where q_norm = 'c426alpha' and bucket is not null), 'no PII column exists');

  -- ── 18) the sweep ────────────────────────────────────────────────────────
  insert into public.near_unavailable (pharmacy_id, medicine_id, until)
  values (v_near, v_med2, now() - interval '3 days');
  v_r := public.near_sweep();
  perform pg_temp.chk('39 the sweep clears an expired hide',
    (v_r->>'ok')::boolean and not exists (select 1 from public.near_unavailable
      where pharmacy_id = v_near and medicine_id = v_med2), v_r::text);

  -- ── 19) idempotency ──────────────────────────────────────────────────────
  perform pg_temp.chk('40 the poster token is stable across re-opt-in',
    public._c426_ensure_token(v_near) = v_tok, 'a printed poster keeps working');
end $proof$;

rollback;

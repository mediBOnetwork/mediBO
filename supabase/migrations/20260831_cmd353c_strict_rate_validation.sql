-- CHANGE #353 follow-up — hostile QA finding on my own code: the rate sanitiser
-- stripped every non-digit, so '-5' silently became 5 (a negative rate was
-- accepted) and '1.2.3' would have raised a raw cast error instead of the
-- backend's own refusal. Validate the typed text, refuse anything else.
create or replace function public.submit_inquiry_form(p_token text, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_supplier text; v_status text; v_expires timestamptz; ans record; r_inq inquiry%ROWTYPE;
  i int; ps_val text; as_val text; slot_n int; new_current text; new_next text; found_ct int;
  v_ps text; v_as text; relevant_ct int; answered_ct int;
  v_remember jsonb := '[]'::jsonb; m jsonb; v_r jsonb;
  v_rate numeric; v_required boolean;
BEGIN
  SELECT f.supplier_name, f.status, f.expires_at INTO v_supplier, v_status, v_expires
  FROM inquiry_forms f WHERE f.token = p_token;
  -- Fallback: accept the public inquiry code too.
  IF NOT FOUND THEN
    v_r := public.resolve_code(p_token);
    IF v_r ? 'token' THEN
      p_token := v_r->>'token';
      SELECT f.supplier_name, f.status, f.expires_at INTO v_supplier, v_status, v_expires
      FROM inquiry_forms f WHERE f.token = p_token;
    END IF;
    IF v_supplier IS NULL THEN RETURN jsonb_build_object('error','invalid'); END IF;
  END IF;
  IF v_status='expired' OR (v_expires IS NOT NULL AND v_expires < now()) THEN
    RETURN jsonb_build_object('error','expired'); END IF;

  v_required := coalesce((select (value #>> '{}')::boolean from app_settings where key='inquiry_rate_required'), false);

  FOR ans IN SELECT * FROM jsonb_to_recordset(p_answers)
                       AS x(inquiry_id bigint, answer text, rate text, scheme text) LOOP
    IF ans.answer NOT IN ('Available','Out of Stock','We don''t stock this product') THEN
      RETURN jsonb_build_object('error','invalid_answer','value',ans.answer); END IF;

    -- Strict, because a sanitiser that strips characters cannot refuse anything:
    -- regexp_replace(...,'[^0-9.]','') turned '-5' into 5 and would have thrown a
    -- raw cast error on '1.2.3'. Validate the TEXT the supplier actually typed.
    v_rate := NULL;
    IF ans.answer = 'Available' THEN
      IF ans.rate IS NOT NULL AND btrim(ans.rate) <> '' THEN
        IF btrim(ans.rate) !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN
          RETURN jsonb_build_object('error','invalid_rate',
                                    'message', public.uic('inquiry_rate.error_invalid','Rate must be a number greater than zero'));
        END IF;
        v_rate := btrim(ans.rate)::numeric;
      END IF;
      IF v_rate IS NOT NULL AND v_rate <= 0 THEN
        RETURN jsonb_build_object('error','invalid_rate',
                                  'message', public.uic('inquiry_rate.error_invalid','Rate must be a number greater than zero'));
      END IF;
      IF v_rate IS NULL AND v_required THEN
        RETURN jsonb_build_object('error','rate_required',
                                  'message', public.uic('inquiry_rate.error_required','Enter your rate for the items you marked Available'));
      END IF;
    ELSE
      v_rate := NULL;                       -- a rate is meaningless without stock
    END IF;

    SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = ans.inquiry_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    slot_n := NULL; as_val := NULL;
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING r_inq;
      IF ps_val = v_supplier THEN slot_n := i; EXIT; END IF;
      as_val := NULL;
    END LOOP;

    IF slot_n IS NOT NULL AND as_val IS NULL AND r_inq.current_supplier = v_supplier THEN
      EXECUTE format('UPDATE inquiry SET %I = $1 WHERE inquiry.id = $2','AS'||slot_n)
        USING ans.answer, ans.inquiry_id;

      -- the quote itself — one row per (supplier, product, batch date)
      IF v_rate IS NOT NULL AND r_inq.product_id IS NOT NULL THEN
        INSERT INTO supplier_quote (inquiry_id, supplier_name, product_id, batch_date, rate, scheme, source)
        VALUES (ans.inquiry_id, v_supplier, r_inq.product_id, r_inq.batch_date, round(v_rate,2),
                nullif(btrim(coalesce(ans.scheme,'')),''), 'supplier_form')
        ON CONFLICT (supplier_name, product_id, coalesce(batch_date,'1900-01-01'::date))
        DO UPDATE SET rate = EXCLUDED.rate, scheme = EXCLUDED.scheme,
                      inquiry_id = EXCLUDED.inquiry_id, quoted_at = now();
      END IF;

      v_remember := v_remember || jsonb_build_array(jsonb_build_object(
        'product_id', r_inq.product_id, 'answer', ans.answer));

      SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = ans.inquiry_id;
      new_current := NULL; new_next := NULL; found_ct := 0;
      FOR i IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO v_ps, v_as USING r_inq;
        IF v_ps IS NULL OR btrim(v_ps)='' THEN EXIT; END IF;
        IF v_as IS NULL OR btrim(v_as)='' OR v_as='Available' THEN
          found_ct := found_ct + 1;
          IF found_ct=1 THEN new_current := v_ps; ELSIF found_ct=2 THEN new_next := v_ps; EXIT; END IF;
        END IF;
      END LOOP;
      UPDATE inquiry SET current_supplier=new_current, next_supplier=new_next,
        asked_at = CASE WHEN new_current IS DISTINCT FROM r_inq.current_supplier
                        THEN now() ELSE inquiry.asked_at END
      WHERE inquiry.id = ans.inquiry_id;

      IF new_current IS NOT NULL AND new_current <> v_supplier THEN
        INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
        VALUES (new_current, now(), now()+interval '10 minutes','pending')
        ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
          last_sent_at=now(), expires_at=now()+interval '10 minutes',
          status=CASE WHEN inquiry_forms.status='expired' THEN 'pending'
                      ELSE inquiry_forms.status END;
      END IF;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO relevant_ct FROM inquiry WHERE inquiry.current_supplier = v_supplier;
  answered_ct := 0;
  FOR r_inq IN SELECT * FROM inquiry WHERE inquiry.current_supplier = v_supplier LOOP
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING r_inq;
      IF ps_val = v_supplier THEN
        IF as_val IS NOT NULL THEN answered_ct := answered_ct+1; END IF; EXIT; END IF;
      as_val := NULL;
    END LOOP;
  END LOOP;
  UPDATE inquiry_forms SET last_responded_at=now(),
    status=CASE WHEN relevant_ct=0 THEN 'responded'
                WHEN answered_ct>=relevant_ct THEN 'responded'
                WHEN answered_ct>0 THEN 'partially_responded'
                ELSE inquiry_forms.status END
  WHERE inquiry_forms.token = p_token;

  PERFORM commit_supplier_order(v_supplier);

  FOR m IN SELECT * FROM jsonb_array_elements(v_remember) LOOP
    PERFORM public.remember_supplier_answer(
      v_supplier, (m->>'product_id')::bigint, m->>'answer');
  END LOOP;

  RETURN get_inquiry_form(p_token);
END;
$function$;

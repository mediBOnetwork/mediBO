-- CHANGE #22: Fix 42702 "column reference supplier_name is ambiguous"
-- Root cause: RETURNS TABLE(supplier_name …) in start_inquiry_for_suppliers
-- creates an implicit OUT variable named supplier_name that clashes with the
-- bare ON CONFLICT (supplier_name) conflict-target syntax. Fix: use the named
-- constraint instead. All local/loop vars use v_ prefix; column refs qualified.

-- ── 1. start_inquiry_for_suppliers ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.start_inquiry_for_suppliers(
  p_supplier_names text[] DEFAULT NULL::text[]
)
RETURNS TABLE(supplier_name text, token text, status text, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_suppliers text[];
  v_sup       text;
  v_token     text;
  v_status    text;
  v_expires   timestamptz;
BEGIN
  IF p_supplier_names IS NULL THEN
    SELECT ARRAY_AGG(DISTINCT sup)
    INTO v_suppliers
    FROM (
      SELECT i.current_supplier AS sup FROM inquiry i WHERE i.current_supplier IS NOT NULL
      UNION
      SELECT i.next_supplier     AS sup FROM inquiry i WHERE i.next_supplier    IS NOT NULL
    ) t;
  ELSE
    v_suppliers := p_supplier_names;
  END IF;

  IF v_suppliers IS NULL OR array_length(v_suppliers, 1) = 0 THEN
    RETURN;
  END IF;

  FOREACH v_sup IN ARRAY v_suppliers LOOP
    -- ON CONFLICT ON CONSTRAINT avoids 42702: RETURNS TABLE(supplier_name …)
    -- creates an OUT var named supplier_name that makes ON CONFLICT (supplier_name)
    -- ambiguous between the table column and the OUT variable.
    INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
    VALUES (v_sup, now(), now() + interval '10 minutes', 'pending')
    ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
      last_sent_at = now(),
      expires_at   = now() + interval '10 minutes',
      status = CASE
        WHEN inquiry_forms.status = 'expired' THEN 'pending'
        ELSE inquiry_forms.status
      END;

    SELECT f.token, f.status, f.expires_at
    INTO   v_token, v_status, v_expires
    FROM   inquiry_forms f
    WHERE  f.supplier_name = v_sup;

    -- Stamp asked_at on newly relevant inquiry rows (only if not already set)
    UPDATE inquiry
    SET    asked_at = COALESCE(asked_at, now())
    WHERE  current_supplier = v_sup OR next_supplier = v_sup;

    -- TODO [STAGE 2 WhatsApp]: fire Meta Cloud API here with link
    -- lookup phone from supplier_profiles WHERE supplier_name = v_sup
    -- send_whatsapp_template(phone, 'medibo_inquiry', url => 'https://medibo.in/inquiry/' || v_token)

    RETURN QUERY SELECT v_sup, v_token, v_status, v_expires;
  END LOOP;
END;
$function$;


-- ── 2. start_inquiry_for_order ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.start_inquiry_for_order(
  p_supplier_order_id uuid
)
RETURNS TABLE(supplier_name text, token text, status text, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_supplier text;
BEGIN
  SELECT so.supplier_name INTO v_supplier
  FROM   supplier_orders so
  WHERE  so.id = p_supplier_order_id;

  IF v_supplier IS NULL THEN RETURN; END IF;

  RETURN QUERY SELECT * FROM start_inquiry_for_suppliers(ARRAY[v_supplier]);
END;
$function$;


-- ── 3. get_inquiry_form ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_inquiry_form(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_supplier text;
  v_status   text;
  v_expires  timestamptz;
  r          inquiry%ROWTYPE;
  i          int;
  ps_val     text;
  as_val     text;
  slot_n     int;
  v_items    jsonb := '[]'::jsonb;
BEGIN
  SELECT f.supplier_name, f.status, f.expires_at
  INTO   v_supplier, v_status, v_expires
  FROM   inquiry_forms f
  WHERE  f.token = p_token;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'invalid');
  END IF;

  IF v_status = 'expired' OR (v_expires IS NOT NULL AND v_expires < now()) THEN
    UPDATE inquiry_forms
    SET    status = 'expired'
    WHERE  inquiry_forms.token = p_token;
    RETURN jsonb_build_object('error', 'expired');
  END IF;

  -- Scan ALL inquiry rows where this supplier occupies any PS slot
  FOR r IN SELECT * FROM inquiry LOOP
    slot_n := NULL;
    as_val := NULL;
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||i, 'AS'||i)
      INTO ps_val, as_val USING r;
      IF ps_val = v_supplier THEN
        slot_n := i;
        EXIT;
      END IF;
      as_val := NULL;
    END LOOP;

    IF slot_n IS NOT NULL AND
       (r.current_supplier = v_supplier OR r.next_supplier = v_supplier OR as_val IS NOT NULL)
    THEN
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'inquiry_id',   r.id,
        'product_name', r.product_name,
        'quantity',     r.quantity,
        'mrp',          r.mrp,
        'slot',         slot_n,
        'answer',       as_val,
        'locked',       (as_val IS NOT NULL)
      ));
    END IF;
  END LOOP;

  SELECT jsonb_agg(item ORDER BY (item->>'locked')::boolean DESC, (item->>'inquiry_id')::bigint)
  INTO   v_items
  FROM   jsonb_array_elements(v_items) item;

  RETURN jsonb_build_object(
    'supplier_name', v_supplier,
    'status',        v_status,
    'expires_at',    v_expires,
    'items',         COALESCE(v_items, '[]'::jsonb)
  );
END;
$function$;


-- ── 4. submit_inquiry_form ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_inquiry_form(p_token text, p_answers jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_supplier    text;
  v_status      text;
  v_expires     timestamptz;
  ans           record;
  r_inq         inquiry%ROWTYPE;
  i             int;
  ps_val        text;
  as_val        text;
  slot_n        int;
  new_current   text;
  new_next      text;
  found_ct      int;
  v_ps          text;
  v_as          text;
  relevant_ct   int;
  answered_ct   int;
BEGIN
  SELECT f.supplier_name, f.status, f.expires_at
  INTO   v_supplier, v_status, v_expires
  FROM   inquiry_forms f
  WHERE  f.token = p_token;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'invalid');
  END IF;
  IF v_status = 'expired' OR (v_expires IS NOT NULL AND v_expires < now()) THEN
    RETURN jsonb_build_object('error', 'expired');
  END IF;

  FOR ans IN SELECT * FROM jsonb_to_recordset(p_answers) AS x(inquiry_id bigint, answer text)
  LOOP
    IF ans.answer NOT IN ('Available', 'Out of Stock', 'We don''t stock this product') THEN
      RETURN jsonb_build_object('error', 'invalid_answer', 'value', ans.answer);
    END IF;

    SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = ans.inquiry_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- Find this supplier's PS slot
    slot_n := NULL;
    as_val := NULL;
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||i, 'AS'||i)
      INTO ps_val, as_val USING r_inq;
      IF ps_val = v_supplier THEN
        slot_n := i;
        EXIT;
      END IF;
      as_val := NULL;
    END LOOP;

    -- Only write if slot found AND currently unanswered (never overwrite)
    IF slot_n IS NOT NULL AND as_val IS NULL THEN
      EXECUTE format('UPDATE inquiry SET %I = $1 WHERE inquiry.id = $2', 'AS'||slot_n)
      USING ans.answer, ans.inquiry_id;

      -- Re-read updated row and recompute current/next supplier
      SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = ans.inquiry_id;
      new_current := NULL; new_next := NULL; found_ct := 0;
      FOR i IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||i, 'AS'||i)
        INTO v_ps, v_as USING r_inq;
        IF v_ps IS NULL OR btrim(v_ps) = '' THEN EXIT; END IF;
        IF v_as IS NULL OR btrim(v_as) = '' OR v_as = 'Available' THEN
          found_ct := found_ct + 1;
          IF found_ct = 1 THEN new_current := v_ps;
          ELSIF found_ct = 2 THEN new_next := v_ps; EXIT;
          END IF;
        END IF;
      END LOOP;

      UPDATE inquiry
      SET current_supplier = new_current,
          next_supplier     = new_next,
          asked_at = CASE
            WHEN new_current IS DISTINCT FROM r_inq.current_supplier THEN now()
            ELSE inquiry.asked_at
          END
      WHERE inquiry.id = ans.inquiry_id;

      -- Mint token for newly promoted current supplier if they don't have one yet
      IF new_current IS NOT NULL AND new_current <> v_supplier THEN
        INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
        VALUES (new_current, now(), now() + interval '10 minutes', 'pending')
        ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
          last_sent_at = now(),
          expires_at   = now() + interval '10 minutes',
          status = CASE
            WHEN inquiry_forms.status = 'expired' THEN 'pending'
            ELSE inquiry_forms.status
          END;
      END IF;
    END IF;
  END LOOP;

  -- Update inquiry_forms status for this supplier
  SELECT COUNT(*) INTO relevant_ct
  FROM inquiry
  WHERE inquiry.current_supplier = v_supplier OR inquiry.next_supplier = v_supplier;

  answered_ct := 0;
  FOR r_inq IN
    SELECT * FROM inquiry
    WHERE inquiry.current_supplier = v_supplier OR inquiry.next_supplier = v_supplier
  LOOP
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||i, 'AS'||i)
      INTO ps_val, as_val USING r_inq;
      IF ps_val = v_supplier THEN
        IF as_val IS NOT NULL THEN answered_ct := answered_ct + 1; END IF;
        EXIT;
      END IF;
      as_val := NULL;
    END LOOP;
  END LOOP;

  UPDATE inquiry_forms SET
    last_responded_at = now(),
    status = CASE
      WHEN relevant_ct = 0            THEN 'responded'
      WHEN answered_ct >= relevant_ct THEN 'responded'
      WHEN answered_ct > 0            THEN 'partially_responded'
      ELSE inquiry_forms.status
    END
  WHERE inquiry_forms.token = p_token;

  -- Return updated form so UI can re-render
  RETURN get_inquiry_form(p_token);
END;
$function$;


-- ── 5. sweep_inquiry_timeouts ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sweep_inquiry_timeouts()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id        bigint;
  r_inq       inquiry%ROWTYPE;
  i           int;
  ps_val      text;
  as_val      text;
  slot_n      int;
  new_current text;
  new_next    text;
  found_ct    int;
  v_ps        text;
  v_as        text;
BEGIN
  -- Find inquiry rows where current_supplier was asked > 10 min ago and hasn't answered
  FOR v_id IN
    SELECT inquiry.id FROM inquiry
    WHERE inquiry.current_supplier IS NOT NULL
      AND inquiry.asked_at IS NOT NULL
      AND inquiry.asked_at < now() - interval '10 minutes'
  LOOP
    SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = v_id;

    -- Locate current_supplier's slot and check if answered
    slot_n := NULL;
    as_val := NULL;
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||i, 'AS'||i)
      INTO ps_val, as_val USING r_inq;
      IF ps_val = r_inq.current_supplier THEN
        slot_n := i;
        EXIT;
      END IF;
      as_val := NULL;
    END LOOP;

    -- Only act if slot found AND unanswered (idempotent guard)
    IF slot_n IS NOT NULL AND as_val IS NULL THEN
      -- Treat silence as 'Out of Stock' to advance the chain
      EXECUTE format('UPDATE inquiry SET %I = $1 WHERE inquiry.id = $2', 'AS'||slot_n)
      USING 'Out of Stock', v_id;

      -- Re-read and recompute current/next
      SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = v_id;
      new_current := NULL; new_next := NULL; found_ct := 0;
      FOR i IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||i, 'AS'||i)
        INTO v_ps, v_as USING r_inq;
        IF v_ps IS NULL OR btrim(v_ps) = '' THEN EXIT; END IF;
        IF v_as IS NULL OR btrim(v_as) = '' OR v_as = 'Available' THEN
          found_ct := found_ct + 1;
          IF found_ct = 1 THEN new_current := v_ps;
          ELSIF found_ct = 2 THEN new_next := v_ps; EXIT; END IF;
        END IF;
      END LOOP;

      UPDATE inquiry
      SET current_supplier = new_current,
          next_supplier     = new_next,
          asked_at = CASE WHEN new_current IS NOT NULL THEN now() ELSE inquiry.asked_at END
      WHERE inquiry.id = v_id;

      -- Mint token for newly promoted supplier if they don't have one
      IF new_current IS NOT NULL THEN
        INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
        VALUES (new_current, now(), now() + interval '10 minutes', 'pending')
        ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
          last_sent_at = now(),
          expires_at   = now() + interval '10 minutes',
          status = CASE
            WHEN inquiry_forms.status = 'expired' THEN 'pending'
            ELSE inquiry_forms.status
          END;
      END IF;
    END IF;
  END LOOP;

  -- Expire stale tokens
  UPDATE inquiry_forms
  SET    status = 'expired'
  WHERE  inquiry_forms.status NOT IN ('expired', 'responded')
    AND  inquiry_forms.expires_at IS NOT NULL
    AND  inquiry_forms.expires_at < now();

END;
$function$;

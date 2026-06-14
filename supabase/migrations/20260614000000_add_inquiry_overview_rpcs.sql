-- CHANGE #23: Add get_supplier_inquiry_overview and get_supplier_inquiry_items RPCs
-- Avoids 42702 (column reference ambiguity) by using v_-prefixed locals throughout
-- and qualifying all table column references with table aliases.

-- ── get_supplier_inquiry_overview ───────────────────────────────────────────
-- Returns one row per supplier currently in the inquiry loop
-- (current_supplier OR next_supplier with at least one unanswered AS slot).
CREATE OR REPLACE FUNCTION public.get_supplier_inquiry_overview()
RETURNS TABLE(
  supplier_name text,
  current_count bigint,
  next_count    bigint,
  token         text,
  form_status   text,
  expires_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_suppliers     text[];
  v_sup           text;
  v_current_count bigint;
  v_next_count    bigint;
  v_row           inquiry%ROWTYPE;
  v_slotidx       int;
  v_ps            text;
  v_as            text;
  v_token         text;
  v_fstatus       text;
  v_expires       timestamptz;
BEGIN
  SELECT ARRAY_AGG(DISTINCT sup) INTO v_suppliers
  FROM (
    SELECT inq.current_supplier AS sup FROM inquiry inq WHERE inq.current_supplier IS NOT NULL
    UNION
    SELECT inq.next_supplier    AS sup FROM inquiry inq WHERE inq.next_supplier    IS NOT NULL
  ) t;

  IF v_suppliers IS NULL THEN RETURN; END IF;

  FOREACH v_sup IN ARRAY v_suppliers LOOP
    v_current_count := 0;
    v_next_count    := 0;

    FOR v_row IN SELECT * FROM inquiry inq WHERE inq.current_supplier = v_sup LOOP
      FOR v_slotidx IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
        INTO v_ps, v_as USING v_row;
        IF v_ps = v_sup THEN
          IF v_as IS NULL OR btrim(v_as) = '' THEN
            v_current_count := v_current_count + 1;
          END IF;
          EXIT;
        END IF;
        v_as := NULL;
      END LOOP;
    END LOOP;

    FOR v_row IN SELECT * FROM inquiry inq WHERE inq.next_supplier = v_sup LOOP
      FOR v_slotidx IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
        INTO v_ps, v_as USING v_row;
        IF v_ps = v_sup THEN
          IF v_as IS NULL OR btrim(v_as) = '' THEN
            v_next_count := v_next_count + 1;
          END IF;
          EXIT;
        END IF;
        v_as := NULL;
      END LOOP;
    END LOOP;

    IF v_current_count = 0 AND v_next_count = 0 THEN CONTINUE; END IF;

    SELECT f.token, f.status, f.expires_at
    INTO   v_token, v_fstatus, v_expires
    FROM   inquiry_forms f
    WHERE  f.supplier_name = v_sup;

    RETURN QUERY SELECT v_sup, v_current_count, v_next_count, v_token, v_fstatus, v_expires;
  END LOOP;
END;
$fn$;


-- ── get_supplier_inquiry_items ───────────────────────────────────────────────
-- Returns per-item list for a given supplier in the inquiry loop.
-- Ordered: current items first, then next items.
CREATE OR REPLACE FUNCTION public.get_supplier_inquiry_items(p_supplier_name text)
RETURNS TABLE(
  inquiry_id   bigint,
  product_name text,
  quantity     int,
  mrp          numeric,
  role         text,
  slot_index   int,
  answer       text,
  answered     boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_row        inquiry%ROWTYPE;
  v_slotidx    int;
  v_ps         text;
  v_as         text;
  v_role       text;
  v_foundslot  int;
  v_foundas    text;
BEGIN
  FOR v_row IN
    SELECT * FROM inquiry inq
    WHERE inq.current_supplier = p_supplier_name
       OR inq.next_supplier    = p_supplier_name
    ORDER BY
      CASE WHEN inq.current_supplier = p_supplier_name THEN 0 ELSE 1 END,
      inq.id
  LOOP
    v_role := CASE WHEN v_row.current_supplier = p_supplier_name THEN 'current' ELSE 'next' END;

    v_foundslot := NULL;
    v_foundas   := NULL;
    FOR v_slotidx IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
      INTO v_ps, v_as USING v_row;
      IF v_ps = p_supplier_name THEN
        v_foundslot := v_slotidx;
        v_foundas   := v_as;
        EXIT;
      END IF;
    END LOOP;

    IF v_foundslot IS NOT NULL THEN
      RETURN QUERY SELECT
        v_row.id,
        v_row.product_name,
        v_row.quantity::int,
        v_row.mrp,
        v_role,
        v_foundslot,
        v_foundas,
        (v_foundas IS NOT NULL AND btrim(v_foundas) <> '')::boolean;
    END IF;
  END LOOP;
END;
$fn$;

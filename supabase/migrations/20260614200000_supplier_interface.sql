-- CHANGE #25: Supplier Interface — schema, RPCs, RLS
-- All locals use v_ prefix; all table cols fully qualified; no 42702 risk.

-- ── 1. supplier_profiles: add user_id if not exists ─────────────────────────
ALTER TABLE supplier_profiles
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id);

-- ── 2. supplier_schemes ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS supplier_schemes (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  supplier_id   uuid NOT NULL REFERENCES supplier_profiles(id) ON DELETE CASCADE,
  product_id    bigint REFERENCES "MEDICINE"(id),
  product_name  text,
  scheme_type   text NOT NULL CHECK (scheme_type IN ('free_goods','discount_pct','special_price')),
  order_qty     numeric,
  free_qty      numeric,
  discount_pct  numeric,
  special_price numeric,
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (supplier_id, product_id, scheme_type)
);

-- ── 3. supplier_pending_companies ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS supplier_pending_companies (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  supplier_id   uuid NOT NULL REFERENCES supplier_profiles(id) ON DELETE CASCADE,
  company_name  text NOT NULL,
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','approved','rejected')),
  reject_reason text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ── 4. supplier_pending_medicines ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS supplier_pending_medicines (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  supplier_id       uuid NOT NULL REFERENCES supplier_profiles(id) ON DELETE CASCADE,
  product_name      text NOT NULL,
  marketer          text NOT NULL,
  therapeutic_class text,
  mrp               numeric,
  status            text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected')),
  reject_reason     text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- ── 5. RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE supplier_profiles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_orders            ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_schemes           ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_pending_companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_pending_medicines ENABLE ROW LEVEL SECURITY;

-- service_role bypass (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_profiles' AND policyname='svc_all_sp') THEN
    CREATE POLICY svc_all_sp ON supplier_profiles FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_orders' AND policyname='svc_all_so') THEN
    CREATE POLICY svc_all_so ON supplier_orders FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

-- supplier sees only own profile row
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_profiles' AND policyname='sup_own_select') THEN
    CREATE POLICY sup_own_select ON supplier_profiles
      FOR SELECT USING (user_id = auth.uid());
  END IF;
END $$;

-- supplier sees only their orders
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_orders' AND policyname='sup_own_orders') THEN
    CREATE POLICY sup_own_orders ON supplier_orders
      FOR SELECT USING (
        supplier_name = (
          SELECT sp.supplier_name FROM supplier_profiles sp
          WHERE sp.user_id = auth.uid()
            AND sp.approved = true
            AND (sp.is_deleted IS NULL OR sp.is_deleted = false)
          LIMIT 1
        )
      );
  END IF;
END $$;

-- supplier_schemes: supplier owns
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_schemes' AND policyname='sup_own_schemes') THEN
    CREATE POLICY sup_own_schemes ON supplier_schemes
      FOR ALL USING (
        supplier_id = (
          SELECT sp.id FROM supplier_profiles sp
          WHERE sp.user_id = auth.uid()
            AND sp.approved = true
            AND (sp.is_deleted IS NULL OR sp.is_deleted = false)
          LIMIT 1
        )
      );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_pending_companies' AND policyname='sup_own_pc') THEN
    CREATE POLICY sup_own_pc ON supplier_pending_companies
      FOR ALL USING (
        supplier_id = (SELECT sp.id FROM supplier_profiles sp WHERE sp.user_id = auth.uid() LIMIT 1)
      );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='supplier_pending_medicines' AND policyname='sup_own_pm') THEN
    CREATE POLICY sup_own_pm ON supplier_pending_medicines
      FOR ALL USING (
        supplier_id = (SELECT sp.id FROM supplier_profiles sp WHERE sp.user_id = auth.uid() LIMIT 1)
      );
  END IF;
END $$;

-- ── 6. current_supplier_profile() ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.current_supplier_profile()
RETURNS supplier_profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_row supplier_profiles%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM supplier_profiles sp
  WHERE sp.user_id = auth.uid()
    AND sp.approved = true
    AND (sp.is_deleted IS NULL OR sp.is_deleted = false)
  LIMIT 1;
  RETURN v_row;
END;
$$;

-- ── 7. claim_supplier_profile(p_email) ──────────────────────────────────────
-- Called on login to link auth.uid() → supplier_profiles row via email match.
CREATE OR REPLACE FUNCTION public.claim_supplier_profile(p_email text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_row  supplier_profiles%ROWTYPE;
  v_uid  uuid := auth.uid();
BEGIN
  SELECT * INTO v_row FROM supplier_profiles sp
  WHERE lower(btrim(sp.email)) = lower(btrim(p_email))
    AND (sp.is_deleted IS NULL OR sp.is_deleted = false)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  IF v_row.approved IS NOT TRUE THEN
    RETURN jsonb_build_object('status', 'pending_approval', 'supplier_name', v_row.supplier_name);
  END IF;

  -- Conflict: email is claimed by a different auth user
  IF v_row.user_id IS NOT NULL AND v_row.user_id <> v_uid THEN
    RETURN jsonb_build_object('status', 'conflict');
  END IF;

  -- Claim: set user_id on first login
  IF v_row.user_id IS NULL THEN
    UPDATE supplier_profiles SET user_id = v_uid WHERE id = v_row.id;
    v_row.user_id := v_uid;
  END IF;

  RETURN jsonb_build_object(
    'status',        'ok',
    'id',            v_row.id::text,
    'supplier_name', v_row.supplier_name,
    'email',         v_row.email
  );
END;
$$;

-- ── 8. supplier_home_medicines(p_search, p_limit, p_offset) ─────────────────
CREATE OR REPLACE FUNCTION public.supplier_home_medicines(
  p_search text DEFAULT '',
  p_limit  int  DEFAULT 20,
  p_offset int  DEFAULT 0
)
RETURNS TABLE(
  id                bigint,
  product_name      text,
  marketer          text,
  therapeutic_class text,
  mrp               text,
  has_scheme        boolean,
  scheme_label      text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp         supplier_profiles%ROWTYPE;
  v_cnames     text[];
  v_dont_stock text[];
  v_row        inquiry%ROWTYPE;
  v_slotidx    int;
  v_ps         text;
  v_as         text;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RETURN; END IF;

  -- Stocked company names (normalised lower)
  SELECT ARRAY_AGG(DISTINCT lower(btrim(sc.supplier_company)))
  INTO v_cnames
  FROM supplier_company sc
  WHERE sc.supplier_id = v_sp.id;

  IF v_cnames IS NULL OR array_length(v_cnames, 1) = 0 THEN RETURN; END IF;

  -- Products this supplier marked "We don't stock this product"
  v_dont_stock := ARRAY[]::text[];
  FOR v_row IN SELECT * FROM inquiry inq LOOP
    FOR v_slotidx IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
      INTO v_ps, v_as USING v_row;
      IF v_ps = v_sp.supplier_name THEN
        IF v_as = 'We don''t stock this product' THEN
          v_dont_stock := v_dont_stock || lower(btrim(v_row.product_name));
        END IF;
        EXIT;
      END IF;
    END LOOP;
  END LOOP;

  RETURN QUERY
  SELECT
    m.id,
    m.product_name,
    m.marketer,
    m.therapeutic_class,
    m.mrp,
    COALESCE(m.has_scheme, false),
    CASE
      WHEN ss.scheme_type = 'free_goods'    THEN ss.order_qty::text || '+' || ss.free_qty::text
      WHEN ss.scheme_type = 'discount_pct'  THEN ss.discount_pct::text || '% off'
      WHEN ss.scheme_type = 'special_price' THEN '₹' || ss.special_price::text
      ELSE NULL
    END
  FROM "MEDICINE" m
  LEFT JOIN supplier_schemes ss ON ss.product_id = m.id
    AND ss.supplier_id = v_sp.id AND ss.active = true
  WHERE lower(btrim(m.marketer)) = ANY(v_cnames)
    AND (
      array_length(v_dont_stock, 1) IS NULL
      OR NOT (lower(btrim(m.product_name)) = ANY(v_dont_stock))
    )
    AND (
      p_search = ''
      OR m.product_name    ILIKE '%' || p_search || '%'
      OR m.marketer        ILIKE '%' || p_search || '%'
      OR m.salt_composition ILIKE '%' || p_search || '%'
    )
  ORDER BY m.sales_count DESC NULLS LAST, m.product_name
  LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ── 9. supplier_my_inquiry_items() ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.supplier_my_inquiry_items()
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
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp        supplier_profiles%ROWTYPE;
  v_row       inquiry%ROWTYPE;
  v_slotidx   int;
  v_ps        text;
  v_as        text;
  v_role      text;
  v_foundslot int;
  v_foundas   text;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RETURN; END IF;

  FOR v_row IN
    SELECT * FROM inquiry inq
    WHERE inq.current_supplier = v_sp.supplier_name
       OR inq.next_supplier    = v_sp.supplier_name
    ORDER BY
      CASE WHEN inq.current_supplier = v_sp.supplier_name THEN 0 ELSE 1 END,
      inq.id
  LOOP
    v_role := CASE WHEN v_row.current_supplier = v_sp.supplier_name THEN 'current' ELSE 'next' END;
    v_foundslot := NULL; v_foundas := NULL;
    FOR v_slotidx IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
      INTO v_ps, v_as USING v_row;
      IF v_ps = v_sp.supplier_name THEN
        v_foundslot := v_slotidx;
        v_foundas   := v_as;
        EXIT;
      END IF;
    END LOOP;

    IF v_foundslot IS NOT NULL THEN
      RETURN QUERY SELECT
        v_row.id, v_row.product_name, v_row.quantity::int, v_row.mrp,
        v_role, v_foundslot, v_foundas,
        (v_foundas IS NOT NULL AND btrim(v_foundas) <> '')::boolean;
    END IF;
  END LOOP;
END;
$$;

-- ── 10. supplier_answer_inquiry(p_inquiry_id, p_answer) ─────────────────────
CREATE OR REPLACE FUNCTION public.supplier_answer_inquiry(
  p_inquiry_id bigint,
  p_answer     text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp       supplier_profiles%ROWTYPE;
  v_row      inquiry%ROWTYPE;
  v_slotidx  int;
  v_ps       text;
  v_as       text;
  v_slot     int;
  v_cur_as   text;
  v_new_cur  text;
  v_new_next text;
  v_found_ct int;
  v_pss      text;
  v_ass      text;
  v_rel_ct   int;
  v_ans_ct   int;
BEGIN
  IF p_answer NOT IN ('Available', 'Out of Stock', 'We don''t stock this product') THEN
    RETURN jsonb_build_object('error', 'invalid_answer');
  END IF;

  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RETURN jsonb_build_object('error', 'not_supplier'); END IF;

  SELECT * INTO v_row FROM inquiry WHERE inquiry.id = p_inquiry_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not_found'); END IF;

  -- Locate this supplier's PS slot
  v_slot := NULL; v_cur_as := NULL;
  FOR v_slotidx IN 1..30 LOOP
    EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
    INTO v_ps, v_as USING v_row;
    IF v_ps = v_sp.supplier_name THEN
      v_slot := v_slotidx; v_cur_as := v_as; EXIT;
    END IF;
  END LOOP;

  IF v_slot IS NULL THEN RETURN jsonb_build_object('error', 'not_in_inquiry'); END IF;

  -- Suppliers cannot overwrite (admin uses admin_set_inquiry_answer)
  IF v_cur_as IS NOT NULL AND btrim(v_cur_as) <> '' THEN
    RETURN jsonb_build_object('error', 'already_answered', 'answer', v_cur_as);
  END IF;

  EXECUTE format('UPDATE inquiry SET %I = $1 WHERE inquiry.id = $2', 'AS'||v_slot)
  USING p_answer, p_inquiry_id;

  -- Recompute current/next (same logic as submit_inquiry_form)
  SELECT * INTO v_row FROM inquiry WHERE inquiry.id = p_inquiry_id;
  v_new_cur := NULL; v_new_next := NULL; v_found_ct := 0;
  FOR v_slotidx IN 1..30 LOOP
    EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
    INTO v_pss, v_ass USING v_row;
    IF v_pss IS NULL OR btrim(v_pss) = '' THEN EXIT; END IF;
    IF v_ass IS NULL OR btrim(v_ass) = '' OR v_ass = 'Available' THEN
      v_found_ct := v_found_ct + 1;
      IF v_found_ct = 1 THEN v_new_cur  := v_pss;
      ELSIF v_found_ct = 2 THEN v_new_next := v_pss; EXIT; END IF;
    END IF;
  END LOOP;

  UPDATE inquiry
  SET current_supplier = v_new_cur,
      next_supplier    = v_new_next,
      asked_at = CASE
        WHEN v_new_cur IS DISTINCT FROM v_row.current_supplier THEN now()
        ELSE inquiry.asked_at
      END
  WHERE inquiry.id = p_inquiry_id;

  -- Mint token for newly-promoted current supplier
  IF v_new_cur IS NOT NULL AND v_new_cur <> v_sp.supplier_name THEN
    INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
    VALUES (v_new_cur, now(), now() + interval '10 minutes', 'pending')
    ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
      last_sent_at = now(),
      expires_at   = now() + interval '10 minutes',
      status = CASE
        WHEN inquiry_forms.status = 'expired' THEN 'pending'
        ELSE inquiry_forms.status
      END;
  END IF;

  -- Update inquiry_forms.status for this supplier
  SELECT COUNT(*) INTO v_rel_ct
  FROM inquiry
  WHERE inquiry.current_supplier = v_sp.supplier_name
     OR inquiry.next_supplier    = v_sp.supplier_name;

  v_ans_ct := 0;
  FOR v_row IN
    SELECT * FROM inquiry
    WHERE inquiry.current_supplier = v_sp.supplier_name
       OR inquiry.next_supplier    = v_sp.supplier_name
  LOOP
    FOR v_slotidx IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
      INTO v_pss, v_ass USING v_row;
      IF v_pss = v_sp.supplier_name THEN
        IF v_ass IS NOT NULL AND btrim(v_ass) <> '' THEN v_ans_ct := v_ans_ct + 1; END IF;
        EXIT;
      END IF;
    END LOOP;
  END LOOP;

  UPDATE inquiry_forms SET
    last_responded_at = now(),
    status = CASE
      WHEN v_rel_ct = 0         THEN 'responded'
      WHEN v_ans_ct >= v_rel_ct THEN 'responded'
      WHEN v_ans_ct > 0         THEN 'partially_responded'
      ELSE inquiry_forms.status
    END
  WHERE inquiry_forms.supplier_name = v_sp.supplier_name;

  RETURN jsonb_build_object('status', 'ok', 'answer', p_answer);
END;
$$;

-- ── 11. supplier_pending_inquiry_count() ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.supplier_pending_inquiry_count()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp     supplier_profiles%ROWTYPE;
  v_row    inquiry%ROWTYPE;
  v_ct     int := 0;
  v_idx    int;
  v_ps     text;
  v_as     text;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RETURN 0; END IF;

  FOR v_row IN SELECT * FROM inquiry inq WHERE inq.current_supplier = v_sp.supplier_name LOOP
    FOR v_idx IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I', 'PS'||v_idx, 'AS'||v_idx)
      INTO v_ps, v_as USING v_row;
      IF v_ps = v_sp.supplier_name THEN
        IF v_as IS NULL OR btrim(v_as) = '' THEN v_ct := v_ct + 1; END IF;
        EXIT;
      END IF;
    END LOOP;
  END LOOP;
  RETURN v_ct;
END;
$$;

-- ── 12. upsert_supplier_scheme ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_supplier_scheme(
  p_product_id    bigint,
  p_product_name  text,
  p_scheme_type   text,
  p_order_qty     numeric DEFAULT NULL,
  p_free_qty      numeric DEFAULT NULL,
  p_discount_pct  numeric DEFAULT NULL,
  p_special_price numeric DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp supplier_profiles%ROWTYPE;
  v_id bigint;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RAISE EXCEPTION 'not_supplier'; END IF;
  IF p_scheme_type NOT IN ('free_goods','discount_pct','special_price') THEN
    RAISE EXCEPTION 'invalid_scheme_type';
  END IF;

  INSERT INTO supplier_schemes (
    supplier_id, product_id, product_name, scheme_type,
    order_qty, free_qty, discount_pct, special_price, active
  ) VALUES (
    v_sp.id, p_product_id, p_product_name, p_scheme_type,
    p_order_qty, p_free_qty, p_discount_pct, p_special_price, true
  )
  ON CONFLICT (supplier_id, product_id, scheme_type) DO UPDATE SET
    product_name  = EXCLUDED.product_name,
    order_qty     = EXCLUDED.order_qty,
    free_qty      = EXCLUDED.free_qty,
    discount_pct  = EXCLUDED.discount_pct,
    special_price = EXCLUDED.special_price,
    active        = true
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ── 13. submit_pending_company ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_pending_company(p_company_name text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp supplier_profiles%ROWTYPE;
  v_id bigint;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RAISE EXCEPTION 'not_supplier'; END IF;
  INSERT INTO supplier_pending_companies (supplier_id, company_name)
  VALUES (v_sp.id, btrim(p_company_name))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ── 14. submit_pending_medicine ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_pending_medicine(
  p_product_name      text,
  p_marketer          text,
  p_therapeutic_class text DEFAULT NULL,
  p_mrp               numeric DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp supplier_profiles%ROWTYPE;
  v_id bigint;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RAISE EXCEPTION 'not_supplier'; END IF;
  INSERT INTO supplier_pending_medicines (supplier_id, product_name, marketer, therapeutic_class, mrp)
  VALUES (v_sp.id, btrim(p_product_name), btrim(p_marketer), p_therapeutic_class, p_mrp)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ── 15. import_supplier_schemes (bulk OCR) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.import_supplier_schemes(p_schemes jsonb)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sp   supplier_profiles%ROWTYPE;
  v_item jsonb;
  v_ct   int := 0;
BEGIN
  SELECT * INTO v_sp FROM current_supplier_profile();
  IF v_sp.id IS NULL THEN RAISE EXCEPTION 'not_supplier'; END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_schemes) LOOP
    INSERT INTO supplier_schemes (
      supplier_id, product_id, product_name, scheme_type,
      order_qty, free_qty, discount_pct, special_price, active
    ) VALUES (
      v_sp.id,
      NULLIF(v_item->>'product_id','')::bigint,
      v_item->>'product_name',
      COALESCE(v_item->>'scheme_type','free_goods'),
      NULLIF(v_item->>'order_qty','')::numeric,
      NULLIF(v_item->>'free_qty','')::numeric,
      NULLIF(v_item->>'discount_pct','')::numeric,
      NULLIF(v_item->>'special_price','')::numeric,
      true
    )
    ON CONFLICT (supplier_id, product_id, scheme_type) DO UPDATE SET
      product_name  = EXCLUDED.product_name,
      order_qty     = EXCLUDED.order_qty,
      free_qty      = EXCLUDED.free_qty,
      discount_pct  = EXCLUDED.discount_pct,
      special_price = EXCLUDED.special_price,
      active        = true;
    v_ct := v_ct + 1;
  END LOOP;
  RETURN v_ct;
END;
$$;

-- ── 16. Test supplier seed ────────────────────────────────────────────────────
-- Ensure test.sup1@medibo.in has an approved supplier_profiles row.
DO $$
DECLARE v_id uuid;
BEGIN
  -- Only insert if no row with this email exists yet
  IF NOT EXISTS (
    SELECT 1 FROM supplier_profiles sp
    WHERE lower(btrim(sp.email)) = 'test.sup1@medibo.in'
  ) THEN
    INSERT INTO supplier_profiles (supplier_name, email, approved, status)
    VALUES ('TEST_Supplier_One', 'test.sup1@medibo.in', true, 'Active')
    RETURNING id INTO v_id;
  ELSE
    -- If exists, ensure approved=true
    UPDATE supplier_profiles
    SET approved = true, status = 'Active'
    WHERE lower(btrim(email)) = 'test.sup1@medibo.in'
    RETURNING id INTO v_id;
  END IF;
END $$;

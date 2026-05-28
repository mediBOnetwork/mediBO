-- mediBO: full schema for new Supabase project
-- Run this once in the Supabase SQL editor before running import.py

-- ── MEDICINE ─────────────────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS "MEDICINE_id_seq";
CREATE SEQUENCE IF NOT EXISTS "MEDICINE__row_id_seq";

CREATE TABLE IF NOT EXISTS "MEDICINE" (
  url                  text,
  product_name         text,
  salt_composition     text,
  marketer             text,
  rx_required          text,
  image_url_1          text,
  image_url_2          text,
  image_url_3          text,
  image_url_4          text,
  image_url_5          text,
  image_count          text,
  storage              text,
  mrp                  text,
  pack_size            text,
  pack_qty             text,
  pack_type            text,
  scrapping_status     text,
  status               text,
  status_reason        text,
  uses                 text,
  benefits             text,
  side_effects         text,
  how_it_works         text,
  habit_forming        text,
  therapeutic_class    text,
  chemical_class       text,
  action_class         text,
  product_introduction text,
  product_highlight    text,
  id                   bigint NOT NULL DEFAULT nextval('"MEDICINE_id_seq"'::regclass),
  _row_id              bigint NOT NULL DEFAULT nextval('"MEDICINE__row_id_seq"'::regclass),
  sales_count          integer DEFAULT 0,
  has_scheme           boolean DEFAULT false,
  has_image            boolean DEFAULT false,
  PRIMARY KEY (id)
);

-- ── contact_inquiries ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS contact_inquiries (
  id         bigserial PRIMARY KEY,
  name       text NOT NULL,
  phone      text NOT NULL,
  message    text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ── customers ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  airtable_id  text UNIQUE,
  name         text,
  phone        text,
  email        text,
  created_at   timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now(),
  synced_at    timestamptz DEFAULT now()
);

-- ── orders ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES auth.users(id),
  pharmacy_name text,
  items         jsonb,
  total_amount  numeric,
  payment_id    text,
  status        text DEFAULT 'pending',
  created_at    timestamptz DEFAULT now(),
  phone         text,
  address       text
);

-- ── pharmacy_profiles ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pharmacy_profiles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES auth.users(id),
  owner_name    text,
  pharmacy_name text NOT NULL,
  phone         text,
  gstin         text,
  drug_license  text,
  address       text NOT NULL,
  city          text NOT NULL,
  pincode       text NOT NULL,
  created_at    timestamptz DEFAULT now()
);

-- ── user_profiles ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_profiles (
  id              uuid PRIMARY KEY REFERENCES auth.users(id),
  full_name       text NOT NULL,
  phone           text NOT NULL,
  business_name   text,
  drug_license    text,
  gstin           text,
  city            text,
  state           text,
  created_at      timestamptz DEFAULT now(),
  approved        boolean DEFAULT false,
  approved_at     timestamptz,
  approved_by     text,
  approval_token  text DEFAULT (gen_random_uuid())::text,
  range           text,
  store_type      text,
  payment_term    text,
  address_line    text,
  pincode         text,
  whatsapp_number text,
  other_contact   text,
  dl1             text,
  dl2             text,
  google_map_link text,
  customer_id     text UNIQUE
);

-- ── Enable RLS ────────────────────────────────────────────────────────────────
ALTER TABLE "MEDICINE"          ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_inquiries   ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders              ENABLE ROW LEVEL SECURITY;
ALTER TABLE pharmacy_profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_profiles       ENABLE ROW LEVEL SECURITY;

-- ── RLS policies ──────────────────────────────────────────────────────────────

-- MEDICINE: anyone can read
CREATE POLICY "public read MEDICINE" ON "MEDICINE"
  FOR SELECT TO public USING (true);

-- contact_inquiries: anon can submit
CREATE POLICY "anon insert" ON contact_inquiries
  FOR INSERT TO anon WITH CHECK (true);

-- customers: service role only
CREATE POLICY "Service role only" ON customers
  FOR ALL TO public USING (auth.role() = 'service_role');

-- orders: own rows only
CREATE POLICY "Users can view own orders" ON orders
  FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own orders" ON orders
  FOR INSERT TO public WITH CHECK (auth.uid() = user_id);

-- pharmacy_profiles: own profile only
CREATE POLICY "own_profile_select" ON pharmacy_profiles
  FOR SELECT TO public USING (auth.uid() = user_id);
CREATE POLICY "own_profile_insert" ON pharmacy_profiles
  FOR INSERT TO public WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own_profile_update" ON pharmacy_profiles
  FOR UPDATE TO public USING (auth.uid() = user_id);

-- user_profiles: own profile only
CREATE POLICY "Users can view own profile" ON user_profiles
  FOR SELECT TO public USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile" ON user_profiles
  FOR INSERT TO public WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON user_profiles
  FOR UPDATE TO public USING (auth.uid() = id);

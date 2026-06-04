-- Migration: orders table — pending order flow (no payment gateway)
-- Apply via Supabase Dashboard → SQL Editor, or CLI: supabase db push
-- Project: svojhmarmaijkshsbeih

-- 1. Add order_number column (stores PO-YYMMDD-XXXX reference)
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS order_number text,
  ADD COLUMN IF NOT EXISTS net_payable  numeric,
  ADD COLUMN IF NOT EXISTS source       text DEFAULT 'website';

-- 2. Default status to 'pending' (orders now come in unpaid)
ALTER TABLE public.orders
  ALTER COLUMN status SET DEFAULT 'pending';

-- 3. Make payment_id nullable (no payment collected at checkout)
ALTER TABLE public.orders
  ALTER COLUMN payment_id DROP NOT NULL;

-- 4. Full row data for Realtime INSERT/UPDATE events
ALTER TABLE public.orders REPLICA IDENTITY FULL;

-- 5. Add to Supabase Realtime publication (admin dashboard live updates)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'orders'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
  END IF;
END;
$$;

-- 6. RLS: allow approved customers to insert their own orders
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'orders'
    AND policyname = 'Customers can insert own orders'
  ) THEN
    CREATE POLICY "Customers can insert own orders"
      ON public.orders FOR INSERT
      WITH CHECK (auth.uid() = user_id);
  END IF;
END;
$$;

-- 7. RLS: allow customers to read their own orders
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'orders'
    AND policyname = 'Customers can read own orders'
  ) THEN
    CREATE POLICY "Customers can read own orders"
      ON public.orders FOR SELECT
      USING (auth.uid() = user_id OR is_admin());
  END IF;
END;
$$;

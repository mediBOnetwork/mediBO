-- Cart admin columns: track who added each item and soft-delete by admin
ALTER TABLE public.cart_items
  ADD COLUMN IF NOT EXISTS added_by TEXT NOT NULL DEFAULT 'customer',
  ADD COLUMN IF NOT EXISTS removed_by_admin BOOLEAN NOT NULL DEFAULT FALSE;

-- FULL replica identity so UPDATE/DELETE events carry the complete old row
ALTER TABLE public.cart_items REPLICA IDENTITY FULL;

-- Ensure cart_items is in the realtime publication
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'cart_items'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.cart_items;
  END IF;
END $$;

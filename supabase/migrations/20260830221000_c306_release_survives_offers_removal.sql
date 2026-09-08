-- ============================================================================
-- CHANGE #306 — cancelling an order is a pure `orders` write.
--
-- History, because the file name still says "survives offers removal": this
-- started as a to_regclass guard around the offer_reservations release, so the
-- reject / auto-cancel path would not break while #308 was mid-removal. #308
-- then finished: offer_reservations is gone permanently, so a guard that can
-- never fire is dead code that reads like live logic to the next person. The
-- release step is deleted rather than guarded, and this file now asserts the
-- same definition #308 pinned — replay it in either order and the result is
-- identical.
--
-- If the alert path ever has something else to release on cancel, it goes here
-- explicitly; there is nothing today.
-- ============================================================================
create or replace function public._oa_release_and_cancel(p_order_id uuid, p_reason text, p_by text)
returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  -- #308: the reservation-release step that used to sit here died with the
  -- Offers marketplace. Do not re-add it, guarded or otherwise — the table it
  -- touched no longer exists and cancelling an order is a pure orders write.
  update public.orders
     set status        = 'cancelled',
         closed_at     = coalesce(closed_at, now()),
         closed_by     = coalesce(closed_by, p_by),
         closed_reason = coalesce(closed_reason, p_reason),
         close_mode    = coalesce(close_mode, 'order_alert')
   where id = p_order_id;
end $$;

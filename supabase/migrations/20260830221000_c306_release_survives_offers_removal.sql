-- ============================================================================
-- CHANGE #306 — the reject / auto-cancel path must not depend on a table that
-- another command is deleting.
--
-- "Releasing any reserved stock" is offer_reservations today, and #308 is
-- removing the Offers marketplace entirely while this is being built. A
-- function that names a dropped table fails at RUN time, inside the dispatcher
-- tick, on the one path that cancels an order — so the reservation release is
-- guarded by to_regclass and simply does nothing once the table is gone. The
-- order still cancels; only the release step becomes a no-op, which is the
-- correct behaviour when there are no reservations left to release.
-- ============================================================================
create or replace function public._oa_release_and_cancel(p_order_id uuid, p_reason text, p_by text)
returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if to_regclass('public.offer_reservations') is not null then
    execute 'update public.offer_reservations
                set status = ''released'', released_at = now(), order_id = null
              where order_id = $1 and status <> ''released'''
      using p_order_id;
  end if;

  update public.orders
     set status        = 'cancelled',
         closed_at     = coalesce(closed_at, now()),
         closed_by     = coalesce(closed_by, p_by),
         closed_reason = coalesce(closed_reason, p_reason),
         close_mode    = coalesce(close_mode, 'order_alert')
   where id = p_order_id;
end $$;

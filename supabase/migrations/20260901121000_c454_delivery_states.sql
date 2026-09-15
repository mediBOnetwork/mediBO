-- CMD #454 — the state vocabulary the three new paths need.
--
-- gap #115 needs to say "the rider never answered", which is NOT the same fact
-- as accept_status='rejected' (the rider said no) — the register's whole point
-- is that an unanswered assignment was indistinguishable from a live one. So
-- 'expired' is added to the accept constraint.
--
-- A released stop reuses the status that already means exactly this:
-- 'unassigned'. No new status value is invented.

alter table public.deliveries drop constraint if exists deliveries_accept_chk;
alter table public.deliveries add constraint deliveries_accept_chk
  check (accept_status = any (array['pending','accepted','rejected','expired']));

-- gap #102: an order whose parcel came back is neither 'shipped' nor
-- 'cancelled' — it went out and came home. 'returned' is the state that says so,
-- and without it delivery_rto_receive could not record the consequence at all.
alter table public.orders drop constraint if exists orders_fulfillment_status_chk;
alter table public.orders add constraint orders_fulfillment_status_chk
  check (fulfillment_status = any (array['open','collecting','waiting','in_transit',
         'ready','partial_ready','shipped','partially_shipped','cancelled','returned']));

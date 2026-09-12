-- CHANGE #306 — the reject note promised something that no longer exists.
-- "releases anything reserved for it" described offer_reservations, which #308
-- removed with the Offers marketplace. Cancelling is now purely the orders row,
-- so the sentence says that instead of describing a table that is gone.
update public.order_alert_config
   set labels = coalesce(labels,'{}'::jsonb) || jsonb_build_object(
         'reject_note', 'Rejects the order and closes it. The customer is not charged.'),
       updated_at = now(), updated_by = 'change_306'
 where id = 'singleton';

-- CMD #1940 — Pool settings copy for the deploy-lock waiter queue editor.
-- The queue itself lives on the control plane (deploy_waiters, deploy_wait_*);
-- the app reads these labels through ui_boot → c(). Idempotent upsert.
insert into public.ui_copy (key, value) values
  ('dev_queue.pool_deploy_wait_title',        to_jsonb('Deploy-lock waiter queue'::text)),
  ('dev_queue.pool_deploy_wait_minutes',      to_jsonb('Safety check by queue position (minutes)'::text)),
  ('dev_queue.pool_deploy_wait_minutes_hint', to_jsonb('Comma-separated, one value per position; the last value repeats. This is only the safety re-check — the wake itself is pushed by the lock release.'::text)),
  ('dev_queue.pool_deploy_wait_safety',       to_jsonb('Safety check ceiling (minutes)'::text)),
  ('dev_queue.pool_deploy_wait_safety_hint',  to_jsonb('A lost wake-up is caught within this many minutes.'::text)),
  ('dev_queue.pool_deploy_wait_urgent',       to_jsonb('Urgent commands jump the queue'::text)),
  ('dev_queue.pool_deploy_wait_urgent_hint',  to_jsonb('On: an urgent command joins at the head of the deploy-lock queue. Off: strict arrival order.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

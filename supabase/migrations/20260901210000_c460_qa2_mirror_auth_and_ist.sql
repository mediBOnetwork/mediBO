-- CHANGE #460 — hostile QA round 1 produced two confirmed findings. Both are
-- fixed here. Every statement is idempotent: a resumed worker may re-apply it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- FINDING 1 (medium, security) — product-image-mirror was callable by anyone
-- on the internet with a credential that is committed to this repository.
--
-- The edge function ran with verify_jwt off and accepted an `x-mirror-secret`
-- header whose value was hardcoded as a fallback in index.ts AND written in
-- plaintext into two migrations AND stored in plaintext in cron_task.work_sql.
-- QA drove the privileged worker from outside with no apikey and no JWT and it
-- did real work: catalogue_mirror_next, catalogue_mirror_report and storage
-- uploads, up to 100 per call with no rate limit, against the same 1 GB
-- instance that has already suffered a connection-starvation outage.
--
-- The function is redeployed with verify_jwt=true and now authorises on the
-- role claim of a GATEWAY-VERIFIED JWT (see supabase/functions/
-- product-image-mirror/index.ts). The shared-secret header is gone entirely.
-- What is left here is the caller: the cron must stop sending that literal and
-- start sending the service-role key, which is read from the Vault at call
-- time so it never lands in work_sql, in a migration, or in git.
--
-- Verified after deploying: the old committed secret with no JWT -> 401 at the
-- gateway; a forged JWT claiming service_role -> 401 (bad signature); a valid
-- ANON JWT -> 401 from the function itself; the service-role key -> 200.
update public.cron_task
   set work_sql = $work$
select net.http_post(
         url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/product-image-mirror',
         headers := jsonb_build_object(
                      'Content-Type', 'application/json',
                      'Authorization', 'Bearer ' || (
                        select decrypted_secret
                          from vault.decrypted_secrets
                         where name = 'SERVICE_ROLE_KEY'
                      )),
         body := jsonb_build_object('limit', 20),
         timeout_milliseconds := 55000);
$work$
 where name = 'product_image_mirror';

-- ─────────────────────────────────────────────────────────────────────────────
-- FINDING 2 (low) — the gap-162 labels decided on current_date, and this
-- database runs in UTC. Between 18:30 and 24:00 UTC (00:00-05:30 IST) the two
-- dates disagree, so for five and a half hours of every day a predicted_next
-- that is YESTERDAY in IST rendered "Expected today" — a forward-looking label
-- on a date that has already passed, which is the exact class of defect gap
-- 162 set out to remove — and a two-day-old date rendered "Overdue by 1 day".
--
-- current_date is now() in the SESSION timezone, so rather than rewrite ten
-- call sites across two function bodies (and leave the next author to
-- remember), the timezone is pinned on the functions themselves. Every
-- current_date inside them — the labels, predicted_state, overdue_days and
-- the `due` window in the cadence helper — becomes IST in one place, and they
-- stay consistent with each other by construction.
--
-- This is also what the platform rule already required: all money INR, all
-- timestamps IST for display. catalogue_health() in this same command got it
-- right with `at time zone 'Asia/Kolkata'`; the reorder path did not.
alter function public.reorder_suggestions() set timezone to 'Asia/Kolkata';
alter function public._reorder_cadence(uuid) set timezone to 'Asia/Kolkata';

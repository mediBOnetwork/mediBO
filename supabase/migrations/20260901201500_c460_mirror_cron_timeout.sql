-- CHANGE #460 / gap 161 — the mirror tick was logging a false failure.
--
-- net.http_post defaults to a 5,000 ms timeout. One pass fetches and uploads 20
-- images and takes 20-40 s, so pg_net stopped waiting every single time and
-- net._http_response recorded "Timeout of 5000 ms reached" for a call that had
-- in fact succeeded — the edge function kept running and the images landed
-- (done went 10 -> 110 across six ticks). Left alone that is a health signal
-- that cries wolf on every tick, which is how a real failure gets ignored.
-- Give the call a timeout that matches the work it actually does.
update public.cron_task
   set work_sql = 'select net.http_post(
           url := ''https://swojhmarmaijkshsbeih.supabase.co/functions/v1/product-image-mirror'',
           headers := jsonb_build_object(''Content-Type'',''application/json'',''x-mirror-secret'',''medibo_image_mirror_2027''),
           body := jsonb_build_object(''limit'', 20),
           timeout_milliseconds := 55000);',
       step_timeout_ms = 60000
 where name = 'product_image_mirror';

-- CHANGE #460 / gap 161 — the mirror drains itself.
--
-- One dispatcher task (never a bare */N pg_cron job — CHANGE #273), gated on
-- the queue actually having work so an empty queue costs one cheap EXISTS and
-- no HTTP call at all. 20 images per pass at a 5-minute interval is a
-- deliberately gentle rate: this is a background backfill of a quarter of a
-- million files, not a race, and it must never compete with a user request on
-- a 1 GB instance.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                              enabled, note, base_interval_s, max_interval_s, current_interval_s, dml)
values ('product_image_mirror', 945, 'poll',
        'select exists (select 1 from public.medicine_image_mirror where status = ''queued'')',
        'select net.http_post(
           url := ''https://swojhmarmaijkshsbeih.supabase.co/functions/v1/product-image-mirror'',
           headers := jsonb_build_object(''Content-Type'',''application/json'',''x-mirror-secret'',''medibo_image_mirror_2027''),
           body := jsonb_build_object(''limit'', 20));',
        20000, true,
        'CHANGE #460 / gap 161 — mirrors hotlinked 1mg CDN images into our own product-images bucket, 20 per pass, buyable products first. Gated on queue depth so an empty queue makes no HTTP call.',
        300, 1800, 300, true)
on conflict (name) do nothing;

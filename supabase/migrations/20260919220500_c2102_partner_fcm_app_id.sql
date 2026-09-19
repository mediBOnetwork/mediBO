-- CMD #2102 — the partner Android app is now registered in Firebase project
-- medibo-23aee (in.medibo.partner → 1:582317556056:android:adf22a86579c9f2254252d).
-- push_config_get() (CMD #2100) already hands the partner flavor
-- c.partner_app_id, but nothing ever wrote that column, so android_ready was
-- false for every partner build and FCM registration could not start.
-- Idempotent: fills the id only while it is empty and never touches the
-- customer app id (1:582317556056:android:07a3b7f92535f92354252d).
update public.push_config
   set partner_app_id  = '1:582317556056:android:adf22a86579c9f2254252d',
       partner_package = coalesce(nullif(partner_package, ''), 'in.medibo.partner'),
       updated_at      = now()
 where id = 'singleton'
   and coalesce(partner_app_id, '') = '';

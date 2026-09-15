-- CHANGE #394 — the one-time backfill, and the reason for it.
--
-- nav_registry now hides any admin.* tile the caller was not granted. Applied
-- literally on the day it ships, that would REMOVE access from the non-super
-- admins who had everything the minute before — a silent demotion nobody
-- asked for. So every admin who exists at this moment and has no grants at
-- all is seeded with the 'full' preset: same access as yesterday, but now
-- written down, editable per screen, and audited when it changes.
--
-- 'full' deliberately excludes admin.dev_queue, admin.manage_admins and
-- admin.audit_log — those three stay super-admin only, which is the fence the
-- spec asks for ("an accounts login must not reach Dev Queue").
--
-- Idempotent: an admin who already has a single grant row is left alone, so a
-- resumed worker (or a re-run) never overwrites a deliberate grant.
insert into public.admin_permissions(admin_id, feature_key, access, updated_at, updated_by)
select a.id, pf.feature_key, pf.access, now(), 'change-394-backfill'
  from public.admins a
  cross join public.admin_role_preset_feature pf
 where pf.preset_key = 'full'
   and not coalesce(a.is_super, false)
   and not exists (select 1 from public.admin_permissions ap where ap.admin_id = a.id)
on conflict (admin_id, feature_key) do nothing;

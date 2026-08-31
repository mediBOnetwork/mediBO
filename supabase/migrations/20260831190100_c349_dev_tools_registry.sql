-- CHANGE #349 — the Dev Queue's nine appbar icons become registry rows.
--
-- Om's report: "mail/bug/map/clock/key/cloud/chip and more running past the
-- right edge with no scroll affordance, unreachable and unlabelled." An AppBar
-- `actions:` list is a Row — it does not scroll and it does not wrap, so on a
-- phone the last four tools were simply gone. They are now DATA: label, group,
-- description, icon and order all live here, the app draws ONE entry point,
-- and `dev_tools()` is the only thing that can put a tool on that sheet.

alter table public.feature_registry
  add column if not exists description text;

comment on column public.feature_registry.description is
  'CHANGE #349 — the one-line subtitle under a tool label. Backend copy: an '
  'icon row could not carry it, a labelled row can.';

insert into public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key,
   sort_order, owner, partner_eligible, default_access, is_active, category,
   surface, roles_allowed, deep_link, search_terms, badge_source, badge_noun)
values
  ('devtool.journeys','Journey library',
   'Every proven journey and what it holds down','Proof & QA','map',
   'journey_library',10,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'journey journeys library proof qa green twice',null,null),
  ('devtool.bug_report','Report a bug',
   'File a finding — it becomes a permanent journey','Proof & QA','bug',
   'bug_report',20,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'bug report finding defect qa',null,null),
  ('devtool.drafts','Drafts inbox',
   'Commands still asking their questions','Proof & QA','drafts',
   'drafts_inbox',30,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'draft drafts inbox generate command questions','dev_drafts','drafts waiting'),
  ('devtool.cron_health','Cron health',
   'Schedules, the deploy lane, the database lane and the build lane',
   'Runtime & health','schedule','cron_health',40,'medibo',false,'none',true,
   'system','dev_tools',array['super_admin'],null,
   'cron health schedule deploy lane database lane build lane jobs',null,null),
  ('devtool.signin_diag','Sign-in diagnostics',
   'Why a login failed, per attempt','Runtime & health','key','signin_diag',
   50,'medibo',false,'none',true,'system','dev_tools',array['super_admin'],
   null,'signin sign-in login auth diagnostics otp',null,null),
  ('devtool.gcp','Cloud control',
   'The build VM, its disk, its APIs and its backups','Runtime & health',
   'cloud','gcp_control',60,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'gcp google cloud vm server backup disk',null,null),
  ('devtool.memory','Agent memory',
   'The rules every runner boots with','Knowledge & releases','memory',
   'memory',70,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'memory rules agent claude portable',null,null),
  ('devtool.threads','Threads',
   'Resumable conversations with the runner','Knowledge & releases','forum',
   'threads',80,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'thread threads conversation chat resume',null,null),
  ('devtool.play_store','Play Store',
   'The Android listing, its builds and its rollout','Knowledge & releases',
   'shop','play_store',90,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'play store android aab apk release listing',null,null)
on conflict (feature_key) do update set
  label            = excluded.label,
  description      = excluded.description,
  group_label      = excluded.group_label,
  icon_key         = excluded.icon_key,
  route_key        = excluded.route_key,
  sort_order       = excluded.sort_order,
  category         = excluded.category,
  surface          = excluded.surface,
  roles_allowed    = excluded.roles_allowed,
  search_terms     = excluded.search_terms,
  badge_source     = excluded.badge_source,
  badge_noun       = excluded.badge_noun,
  is_active        = true;

-- The tool groups, in the order the sheet draws them. A group with no visible
-- tool is skipped by dev_tools() rather than drawn empty.
insert into public.ui_copy (key, value) values
  ('dev_tools.button',      to_jsonb('Tools'::text)),
  ('dev_tools.title',       to_jsonb('Dev Queue tools'::text)),
  ('dev_tools.subtitle',    to_jsonb('Every tool, labelled. Nothing lives off the edge of the screen.'::text)),
  ('dev_tools.search_hint', to_jsonb('Filter tools'::text)),
  ('dev_tools.empty',       to_jsonb('No tool is registered for your role.'::text)),
  ('dev_tools.not_registered', to_jsonb('That tool is not in the feature registry.'::text))
on conflict (key) do update set value = excluded.value;

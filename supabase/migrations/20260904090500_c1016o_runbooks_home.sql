-- CHANGE #1016 (O): "Failure drills" (devtool.runbooks, registered by #474 in
-- the same batch that shipped the six-tab shell) still carried the pre-#1016
-- category 'system' ("Admin & System"), so the More tab drew a seventh,
-- one-tile section after "System & Dev tools". The More tab has exactly six
-- groups (spec item 1); every dev_tools feature lives in more_system.
-- Idempotent: a resumed worker re-applying this is a no-op.
update public.feature_registry
   set category = 'more_system'
 where surface = 'dev_tools'
   and category = 'system'
   and coalesce(is_active, false);

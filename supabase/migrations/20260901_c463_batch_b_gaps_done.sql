-- CHANGE #463 batch B: mark 7 delivery gaps as done.
-- Gaps resolved by this command: 111, 112, 117, 118, 119, 120, 121.
--
-- The per-row proof notes ("CMD #463 - FIXED. / REPRODUCED: ... / FIX: ... /
-- PROOF: ...") are written per row by the command itself. This file is the
-- idempotent record of the stamp: it only claims rows this command has not
-- already stamped, so re-applying it on a resumed worker is a silent no-op and
-- can never dilute or overwrite a proof note that is already there.

UPDATE public.feature_gaps
SET status         = 'done',
    dev_command_id = 463,
    updated_at     = now()
WHERE id IN (111, 112, 117, 118, 119, 120, 121)
  AND surface = 'delivery'
  AND (dev_command_id IS DISTINCT FROM 463 OR status IS DISTINCT FROM 'done');

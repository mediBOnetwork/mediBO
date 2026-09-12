-- Cleanup migration: fix existing data to match new constraints
-- This must run AFTER 20260902132055 to set all values to valid options

-- Update model column: set invalid values to claude-opus-5 (the default)
UPDATE dev_commands
SET model = 'claude-opus-5'
WHERE model IS NULL
   OR model NOT IN ('claude-opus-5', 'claude-fable-5-1', 'claude-fable-5', 'claude-opus-4-8');

-- Convert claude-fable-5 (legacy) to claude-fable-5-1 (latest Fable)
UPDATE dev_commands
SET model = 'claude-fable-5-1'
WHERE model = 'claude-fable-5';

-- Convert any remaining old Opus version to current
UPDATE dev_commands
SET model = 'claude-opus-5'
WHERE model IN ('claude-opus-4-8', 'claude-sonnet-4-6', 'claude-haiku-4-5-20251001',
                'opus', 'sonnet', 'haiku');

-- Update effort column: set invalid values to high (the default)
UPDATE dev_commands
SET effort = 'high'
WHERE effort IS NULL
   OR effort NOT IN ('high', 'extra');

-- Now add the CHECK constraints if they don't exist
-- Note: at this point, all data should be valid
DO $$
BEGIN
  ALTER TABLE dev_commands
  ADD CONSTRAINT dev_commands_model_valid
  CHECK (model IN ('claude-opus-5', 'claude-fable-5-1'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE dev_commands
  ADD CONSTRAINT dev_commands_effort_valid
  CHECK (effort IN ('high', 'extra'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

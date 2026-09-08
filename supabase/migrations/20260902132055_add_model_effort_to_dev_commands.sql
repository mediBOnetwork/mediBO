-- Add model and effort columns to dev_commands
-- Model: which Claude model to use (claude-opus-5 or claude-fable-5-1)
-- Effort: how much effort the model should use (high or extra)

BEGIN;

-- Add columns with defaults and NOT NULL
ALTER TABLE dev_commands
ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'claude-opus-5',
ADD COLUMN IF NOT EXISTS effort text NOT NULL DEFAULT 'high';

-- Add CHECK constraints for valid values
-- Using ALTER TABLE with separate constraints to avoid conflicts
DO $$
BEGIN
  -- Drop old constraints if they exist
  ALTER TABLE dev_commands DROP CONSTRAINT IF EXISTS dev_commands_model_valid;
  ALTER TABLE dev_commands DROP CONSTRAINT IF EXISTS dev_commands_effort_valid;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- Add new constraints
ALTER TABLE dev_commands
ADD CONSTRAINT dev_commands_model_valid
CHECK (model IN ('claude-opus-5', 'claude-fable-5-1'));

ALTER TABLE dev_commands
ADD CONSTRAINT dev_commands_effort_valid
CHECK (effort IN ('high', 'extra'));

COMMIT;

-- Store available Claude model IDs in dev_runner_config
-- Used by the runner to pass model selection to Claude Code invocation

INSERT INTO dev_runner_config (key, value)
VALUES ('models', '{"fable_5": "claude-fable-5-1", "opus_5": "claude-opus-5"}'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

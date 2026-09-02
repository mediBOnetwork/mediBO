-- CHANGE #656 — the runner never maps a model or an effort in bash.
-- The claim payload carries the EXACT Claude Code CLI flags the row resolves
-- to, so `extra` → `--effort max` is a backend fact, not a shell case statement.

CREATE OR REPLACE FUNCTION public.dev_cmd_run_flags(p_model text, p_effort text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT jsonb_build_object(
    'model',      coalesce(nullif(p_model,''),  'claude-opus-5'),
    'effort',     coalesce(nullif(p_effort,''), 'high'),
    'model_cli',  coalesce(
       (SELECT x->>'cli' FROM dev_runner_config c,
               jsonb_array_elements(coalesce(c.value->'models','[]'::jsonb)) x
         WHERE c.key='models' AND x->>'value' = p_model LIMIT 1), 'claude-opus-5'),
    'effort_cli', coalesce(
       (SELECT x->>'cli' FROM dev_runner_config c,
               jsonb_array_elements(coalesce(c.value->'efforts','[]'::jsonb)) x
         WHERE c.key='models' AND x->>'value' = p_effort LIMIT 1), 'high'),
    'model_label',  _dev_model_label(p_model),
    'effort_label', _dev_effort_label(p_effort),
    -- The runner refuses to start on anything but these two. The column CHECK
    -- already makes such a row unwritable; this is the second lock.
    'allowed', coalesce(p_model,'claude-opus-5') IN ('claude-opus-5','claude-fable-5-1'),
    'refusal', CASE WHEN coalesce(p_model,'claude-opus-5') IN ('claude-opus-5','claude-fable-5-1')
                    THEN NULL
                    ELSE 'CHANGE #656 — "'||p_model||'" is not a permitted model. Sonnet and Haiku lanes are removed; only Opus 5 and Fable 5 build.'
               END);
$fn$;
GRANT EXECUTE ON FUNCTION public.dev_cmd_run_flags(text,text) TO authenticated, service_role;

-- Bolt the flags onto both claim paths without retyping either function.
DO $do$
DECLARE d text; fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY['dev_cmd_claim','dev_cmd_claim_batch'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO d
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.proname = fn;
    CONTINUE WHEN d IS NULL OR position('dev_cmd_run_flags' in d) > 0;
    IF position('''session_guard'', db_guard_check()' in d) = 0 THEN CONTINUE; END IF;
    d := replace(d, '''session_guard'', db_guard_check()',
                    '''session_guard'', db_guard_check(),'
                 || ' ''run_flags'', dev_cmd_run_flags(v->>''model'', v->>''effort'')');
    EXECUTE d;
  END LOOP;
END $do$;

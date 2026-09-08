-- CHANGE #656 — per-command model + effort override.
--
-- dev_commands.model / dev_commands.effort are the AUTHORITATIVE request:
-- Om picks them per command, the runner obeys them, and nothing overwrites
-- them afterwards. What the session ACTUALLY ran on is recorded separately in
-- actual_model / actual_effort (reported by the bridge from session usage), so
-- the card can print real values instead of the old "(assumed)" guess.
--
-- Allowed models  : claude-opus-5 (default) · claude-fable-5-1 (Fable 5)
-- Allowed efforts : high (default) · extra  → Claude Code CLI --effort max
-- Sonnet and Haiku lanes are removed everywhere: routing, markers, config.
--
-- Every statement is idempotent — a resumed worker re-applies this as a no-op.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Columns
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE dev_commands ADD COLUMN IF NOT EXISTS model         text;
ALTER TABLE dev_commands ADD COLUMN IF NOT EXISTS effort        text;
ALTER TABLE dev_commands ADD COLUMN IF NOT EXISTS actual_model  text;
ALTER TABLE dev_commands ADD COLUMN IF NOT EXISTS actual_effort text;

COMMENT ON COLUMN dev_commands.model         IS 'CHANGE #656 — requested model, authoritative. Never overwritten by the runner.';
COMMENT ON COLUMN dev_commands.effort        IS 'CHANGE #656 — requested effort (high|extra), authoritative.';
COMMENT ON COLUMN dev_commands.actual_model  IS 'CHANGE #656 — model the session actually reported. History for old rows.';
COMMENT ON COLUMN dev_commands.actual_effort IS 'CHANGE #656 — effort the session actually reported.';

-- History is preserved, not rewritten: whatever model/effort a historical row
-- carried moves into actual_* before model/effort are normalised to the two
-- allowed values.
UPDATE dev_commands
   SET actual_model  = coalesce(actual_model,  nullif(model,'')),
       actual_effort = coalesce(actual_effort, nullif(effort,''))
 WHERE (actual_model IS NULL AND nullif(model,'') IS NOT NULL)
    OR (actual_effort IS NULL AND nullif(effort,'') IS NOT NULL);

UPDATE dev_commands SET model = 'claude-fable-5-1'
 WHERE model IS NOT NULL AND model LIKE 'claude-fable%' AND model <> 'claude-fable-5-1';
UPDATE dev_commands SET model = 'claude-opus-5'
 WHERE model IS NULL OR model NOT IN ('claude-opus-5','claude-fable-5-1');
UPDATE dev_commands SET effort = 'extra'
 WHERE effort IN ('max','xhigh','maximum');
UPDATE dev_commands SET effort = 'high'
 WHERE effort IS NULL OR effort NOT IN ('high','extra');

ALTER TABLE dev_commands ALTER COLUMN model  SET DEFAULT 'claude-opus-5';
ALTER TABLE dev_commands ALTER COLUMN effort SET DEFAULT 'high';
ALTER TABLE dev_commands ALTER COLUMN model  SET NOT NULL;
ALTER TABLE dev_commands ALTER COLUMN effort SET NOT NULL;

ALTER TABLE dev_commands DROP CONSTRAINT IF EXISTS dev_commands_model_valid;
ALTER TABLE dev_commands ADD  CONSTRAINT dev_commands_model_valid
  CHECK (model IN ('claude-opus-5','claude-fable-5-1'));
ALTER TABLE dev_commands DROP CONSTRAINT IF EXISTS dev_commands_effort_valid;
ALTER TABLE dev_commands ADD  CONSTRAINT dev_commands_effort_valid
  CHECK (effort IN ('high','extra'));

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Config — the model registry, the rates, and the end of the cheap lanes
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO dev_runner_config (key, value) VALUES ('models', '{}'::jsonb)
  ON CONFLICT (key) DO NOTHING;

UPDATE dev_runner_config SET value = jsonb_build_object(
  'note',           'CHANGE #656 — the ONLY models a command may build on. Discovered from the Claude Code CLI on the VM: the `fable` alias resolves to claude-fable-5-1. Effort maps to the CLI --effort flag (low|medium|high|xhigh|max); extra = max, the highest the CLI supports.',
  'default_model',  'claude-opus-5',
  'default_effort', 'high',
  'title',          'Model & effort',
  'hint',           'Every command builds on Opus 5 at High effort unless you change it here.',
  'model_title',    'Model',
  'effort_title',   'Effort',
  'models', jsonb_build_array(
     jsonb_build_object('value','claude-opus-5',   'label','Opus 5',  'short','opus-5',  'cli','claude-opus-5'),
     jsonb_build_object('value','claude-fable-5-1','label','Fable 5', 'short','fable-5', 'cli','claude-fable-5-1')),
  'efforts', jsonb_build_array(
     jsonb_build_object('value','high',  'label','High',  'cli','high', 'chip','High effort'),
     jsonb_build_object('value','extra', 'label','Extra', 'cli','max',  'chip','Extra effort'))
) WHERE key='models';

-- Rates for the two live models (INR is derived from usd_inr as before).
UPDATE dev_runner_config
   SET value = jsonb_set(value, '{models}',
         (value->'models')
         || jsonb_build_object('claude-opus-5',    jsonb_build_object('in', 5,  'out', 25,
                                                     'fast_in', 10, 'fast_out', 50))
         || jsonb_build_object('claude-fable-5-1', jsonb_build_object('in', 10, 'out', 50)))
 WHERE key='model_rates';

-- Routing: the sonnet and haiku lanes and every marker that fed them are gone.
UPDATE dev_runner_config
   SET value = jsonb_set(
         jsonb_set(value, '{routing}',
           (value->'routing')
           - 'sonnet_markers' - 'haiku_max_chars' - 'sonnet_max_chars'
           || jsonb_build_object(
                'note',  'CHANGE #656 — model and effort are per-command (dev_commands.model/effort). There are exactly two lanes left: fast (SQL grammar, no worker) and opus (a real build). Sonnet and Haiku are removed.',
                'lanes', jsonb_build_object('opus', coalesce((value->'routing'->'lanes'->>'opus')::int, 7)))),
         '{effort}',
           (value->'effort')
           || jsonb_build_object(
                'note',        'CHANGE #656 — high is the floor, extra is opt-in per command. Nothing auto-escalates any more.',
                'default',     'high',
                'extra_marker','effort: extra')
           - 'escalate_on' - 'high_marker' - 'was')
 WHERE key='worker_pool';

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Effort + model helpers
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_effort_for(p_spec text, p_size_class text, p_retry integer)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE cfg jsonb; v_def text; v_marker text;
BEGIN
  -- CHANGE #656: only two efforts exist and `high` is the FLOOR, so nothing
  -- auto-escalates on a retry or a big spec any more. Om asks for `extra`
  -- explicitly — on the card, or with the literal marker in the spec.
  SELECT value->'effort' INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  cfg      := coalesce(cfg,'{}'::jsonb);
  v_def    := coalesce(nullif(cfg->>'default',''),'high');
  v_marker := coalesce(nullif(cfg->>'extra_marker',''),'effort: extra');
  IF lower(coalesce(p_spec,'')) LIKE '%'||lower(v_marker)||'%' THEN RETURN 'extra'; END IF;
  IF v_def NOT IN ('high','extra') THEN RETURN 'high'; END IF;
  RETURN v_def;
END $fn$;

-- Normalise anything Om or an API caller sends into an allowed value.
CREATE OR REPLACE FUNCTION public._dev_model_norm(p_model text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_model IS NULL OR btrim(p_model) = '' THEN NULL
    WHEN lower(btrim(p_model)) IN ('claude-fable-5-1','fable','fable-5','fable 5','claude-fable-5') THEN 'claude-fable-5-1'
    WHEN lower(btrim(p_model)) IN ('claude-opus-5','opus','opus-5','opus 5') THEN 'claude-opus-5'
    ELSE lower(btrim(p_model))
  END;
$fn$;

CREATE OR REPLACE FUNCTION public._dev_effort_norm(p_effort text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_effort IS NULL OR btrim(p_effort) = '' THEN NULL
    WHEN lower(btrim(p_effort)) IN ('extra','max','xhigh','maximum') THEN 'extra'
    WHEN lower(btrim(p_effort)) IN ('high','standard') THEN 'high'
    ELSE lower(btrim(p_effort))
  END;
$fn$;

CREATE OR REPLACE FUNCTION public._dev_effort_label(e text)
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    (SELECT x->>'chip' FROM dev_runner_config c,
            jsonb_array_elements(coalesce(c.value->'efforts','[]'::jsonb)) x
      WHERE c.key='models' AND x->>'value' = coalesce(nullif(e,''),'high') LIMIT 1),
    initcap(coalesce(nullif(e,''),'high'))||' effort');
$fn$;

CREATE OR REPLACE FUNCTION public._dev_model_label(m text)
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    (SELECT x->>'label' FROM dev_runner_config c,
            jsonb_array_elements(coalesce(c.value->'models','[]'::jsonb)) x
      WHERE c.key='models' AND x->>'value' = m LIMIT 1),
    regexp_replace(coalesce(nullif(m,''),'claude-opus-5'), '^claude-', ''));
$fn$;

-- The card's model chip. CHANGE #656 removed "(assumed)": the chip prints the
-- model the session ACTUALLY ran on when the bridge has reported it, and the
-- requested model until then. A run that came back on a different model than
-- was asked for says so, rather than hiding it.
DROP FUNCTION IF EXISTS public._dev_model_chip(text, text, text);
CREATE OR REPLACE FUNCTION public._dev_model_chip(
  p_model text, p_effort text, p_mode text,
  p_actual_model text DEFAULT NULL, p_actual_effort text DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $fn$
  WITH v AS (
    SELECT coalesce(nullif(p_actual_model,''),  nullif(p_model,''),  'claude-opus-5') AS m,
           coalesce(nullif(p_actual_effort,''), nullif(p_effort,''), 'high')          AS e,
           nullif(p_actual_model,'') IS NOT NULL
             AND nullif(p_model,'') IS NOT NULL
             AND nullif(p_actual_model,'') <> nullif(p_model,'')                      AS drift
  )
  SELECT _dev_model_label(v.m)
         || ' · ' || _dev_effort_label(v.e)
         || coalesce(' · ' || nullif(p_mode,''), '')
         || CASE WHEN v.drift THEN ' · asked ' || _dev_model_label(p_model) ELSE '' END
    FROM v;
$fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Routing — two lanes left: fast and opus
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._route_detect(p_title text, p_spec text)
RETURNS TABLE(route text, area text, size_class text, reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  cfg jsonb; t text; n int;
  v_route text := 'opus'; v_area text := NULL; v_size text := 'normal'; v_why text := '';
  hit_opus text; hit_multi text;
  c_small int; c_large int; c_xlarge int;
BEGIN
  SELECT value->'routing' INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  cfg := coalesce(cfg, '{}'::jsonb);
  t := lower(coalesce(p_title,'')||' '||coalesce(p_spec,''));
  n := length(coalesce(p_spec,''));
  c_small  := coalesce((cfg->>'small_max_chars')::int, 400);
  c_large  := coalesce((cfg->>'large_min_chars')::int, 2000);
  c_xlarge := coalesce((cfg->>'opus_min_chars')::int, 4000);

  SELECT o INTO hit_opus  FROM jsonb_array_elements_text(coalesce(cfg->'opus_markers','[]'::jsonb)) o
    WHERE t LIKE '%'||o||'%' LIMIT 1;
  SELECT m INTO hit_multi FROM jsonb_array_elements_text(coalesce(cfg->'multi_markers','[]'::jsonb)) m
    WHERE t LIKE '%'||m||'%' LIMIT 1;

  -- size_class still grades the token budget; it no longer picks a model.
  v_size := CASE
    WHEN n >= c_xlarge OR (hit_opus IS NOT NULL AND n >= c_large) THEN 'xlarge'
    WHEN n >= c_large THEN 'large'
    WHEN n < c_small AND hit_opus IS NULL AND hit_multi IS NULL THEN 'small'
    ELSE 'normal' END;

  -- The instant fast lane stays: an exact one-line grammar runs in SQL with no
  -- worker and no model at all. Everything else is a real build on the model
  -- the ROW carries (dev_commands.model) — there is no cheap lane any more.
  IF p_spec ~* '^\s*ui_copy\s+[a-z0-9_.]+\s*=\s*.+'
     OR p_spec ~* '^\s*design\s+[a-z]+\.[a-zA-Z]+\s*=\s*.+' THEN
    v_route := 'fast'; v_why := 'Fast lane — exact one-line grammar, runs instantly with no worker.';
  ELSE
    v_route := 'opus';
    v_why := CASE
      WHEN hit_opus IS NOT NULL THEN
        'Build lane — spec mentions "'||hit_opus||'" ('||n||' chars); model and effort come from the command itself.'
      ELSE
        'Build lane — '||n||' chars. CHANGE #656: Sonnet and Haiku are removed, so every real build runs on the command''s own model.'
      END;
  END IF;

  v_area := CASE
    WHEN t ~ '(cart|storefront|product|pdp|search_medicines)' THEN 'storefront'
    WHEN t ~ '(delivery|rider|run sheet|dispatch)' THEN 'delivery'
    WHEN t ~ '(supplier|inquiry|waterfall|shop)' THEN 'supplier'
    WHEN t ~ '(pack|warehouse|bag|count)' THEN 'fulfillment'
    WHEN t ~ '(whatsapp|wa_|template|campaign)' THEN 'whatsapp'
    WHEN t ~ '(bill|payment|utr|invoice|gst)' THEN 'billing'
    WHEN t ~ '(dev queue|runner|worker|pool|lease|gcp|vm )' THEN 'devops'
    WHEN t ~ '(admin|dashboard|report)' THEN 'admin'
    ELSE NULL END;

  RETURN QUERY SELECT v_route, v_area, v_size, v_why;
END $fn$;

-- No pending row may still be waiting in a lane that no longer has workers.
UPDATE dev_commands SET route='opus'
 WHERE route IN ('sonnet','haiku') AND status IN ('pending','awaiting_approval','building','paused','needs_input');

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Write paths — model/effort are validated where they are written
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_cmd_bulk_add(p_items jsonb, p_force boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE r jsonb; v_warn jsonb := '[]'; v_added jsonb := '[]'; v_id bigint; v_dup record; v_deps bigint[];
        v_scan jsonb; v_kind text; v_danger boolean; v_title text; v_imgs jsonb; v_atts jsonb;
        v_route text; v_area text; v_size text; v_why text; v_effort text; v_fast text;
        v_model text;
BEGIN
  PERFORM _dev_guard();
  IF (_sec_cfg()->>'frozen')::boolean THEN RAISE EXCEPTION 'queue frozen — unlock with PIN first'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_title := coalesce(nullif(btrim(r->>'title'),''), left(regexp_replace(coalesce(r->>'spec',''), '\s+', ' ', 'g'), 60));
    v_scan := sec_scan_spec(coalesce(r->>'title','')||' '||coalesce(r->>'spec',''));
    IF NOT (v_scan->>'clean')::boolean THEN
      v_warn := v_warn || jsonb_build_object('title', v_title, 'reason','blocked', 'blocked_injection', v_scan->'hits');
      PERFORM _audit(_actor(),'cmd_blocked_injection', v_title, v_scan); CONTINUE;
    END IF;

    -- CHANGE #656: model/effort arrive from the add sheet and are AUTHORITATIVE.
    -- An unknown value is refused at write time — it never silently becomes Opus.
    v_model  := coalesce(_dev_model_norm(r->>'model'), 'claude-opus-5');
    v_effort := coalesce(_dev_effort_norm(r->>'effort'), _dev_effort_for(r->>'spec', NULL, 0));
    IF v_model NOT IN ('claude-opus-5','claude-fable-5-1') THEN
      RAISE EXCEPTION 'dev_cmd_bulk_add: model "%" is not allowed (CHANGE #656 — only claude-opus-5 and claude-fable-5-1)', r->>'model';
    END IF;
    IF v_effort NOT IN ('high','extra') THEN
      RAISE EXCEPTION 'dev_cmd_bulk_add: effort "%" is not allowed (CHANGE #656 — only high and extra)', r->>'effort';
    END IF;

    SELECT id, title INTO v_dup FROM dev_commands
      WHERE status IN ('pending','building','awaiting_approval')
        AND (similarity(title, v_title) > 0.6 OR similarity(spec, r->>'spec') > 0.8)
      ORDER BY similarity(spec, r->>'spec') DESC LIMIT 1;
    IF v_dup.id IS NOT NULL AND NOT p_force THEN
      v_warn := v_warn || jsonb_build_object('title', v_title, 'reason','duplicate', 'duplicate_of', v_dup.id, 'duplicate_title', v_dup.title); CONTINUE;
    END IF;
    SELECT coalesce(array_agg(x::bigint), '{}') INTO v_deps FROM jsonb_array_elements_text(coalesce(r->'depends_on','[]'::jsonb)) x;
    v_kind := CASE WHEN coalesce(r->>'kind','dev')='gcp' THEN 'gcp' ELSE 'dev' END;
    v_danger := sec_is_danger(coalesce(r->>'spec',''));
    SELECT route, area, size_class, reason INTO v_route, v_area, v_size, v_why
      FROM _route_detect(v_title, r->>'spec');
    IF v_kind='gcp' THEN
      v_route := 'opus'; v_size := coalesce(v_size,'normal');
      v_why := 'Build lane — Google Cloud command, runs the gcloud lane.';
    END IF;

    IF v_route='fast' AND v_kind='dev' AND NOT v_danger THEN
      v_fast := _fast_execute(r->>'spec');
      IF v_fast IS NOT NULL THEN
        INSERT INTO dev_commands (title, spec, status, kind, route, area, size_class, route_reason,
                                  plain_summary, result_summary, finished_at, started_at, created_by, qa_status, qa_required)
        VALUES (v_title, r->>'spec', 'completed', 'dev', 'fast', v_area, coalesce(v_size,'small'), v_why,
                v_fast, v_fast, now(), now(), auth.uid(), 'waived', false)
        RETURNING id INTO v_id;
        INSERT INTO dev_command_messages (command_id, sender, body) VALUES (v_id,'agent',v_fast);
        v_added := v_added || jsonb_build_object('id', v_id, 'title', v_title, 'route','fast', 'instant', true);
        PERFORM _audit(_actor(),'cmd_fastlane', v_id::text, jsonb_build_object('area',v_area));
        CONTINUE;
      ELSE
        -- CHANGE #656: no cheap lane to fall back to — it becomes a normal build.
        v_route := 'opus';
        v_why := 'Build lane — fast-lane grammar did not apply, so it is a normal build on the command''s own model.';
      END IF;
    END IF;

    INSERT INTO dev_commands (title, spec, status, priority, urgent, depends_on, batch_label, targets_web, targets_android, targets_ios, kind, is_danger, route, area, size_class, effort, model, route_reason, qa_required, created_by)
    VALUES (
      v_title, r->>'spec',
      CASE WHEN coalesce((r->>'require_approval')::boolean,false) THEN 'awaiting_approval' ELSE 'pending' END,
      coalesce((r->>'priority')::int, 100), coalesce((r->>'urgent')::boolean, false), v_deps,
      coalesce(r->>'batch_label', v_area),
      coalesce((r->>'targets_web')::boolean, v_kind='dev'),
      coalesce((r->>'targets_android')::boolean, false), coalesce((r->>'targets_ios')::boolean, false),
      v_kind, v_danger, v_route, v_area, v_size, v_effort, v_model, v_why,
      coalesce((r->>'qa_required')::boolean, true),
      auth.uid()
    ) RETURNING id INTO v_id;
    v_imgs := coalesce(r->'images','[]'::jsonb); v_atts := coalesce(r->'attachments','[]'::jsonb);
    IF jsonb_array_length(v_imgs) > 0 OR jsonb_array_length(v_atts) > 0 THEN
      INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
      VALUES (v_id, 'om', coalesce(nullif(btrim(r->>'media_note'),''),'Attached with the spec'), v_imgs, v_atts);
    END IF;
    v_added := v_added || jsonb_build_object('id', v_id, 'title', v_title, 'route', v_route, 'area', v_area,
                                             'size_class', v_size, 'effort', v_effort, 'model', v_model,
                                             'route_reason', v_why, 'is_danger', v_danger);
    PERFORM _audit(_actor(),'cmd_add', v_id::text, jsonb_build_object('route',v_route,'area',v_area,'size',v_size,'effort',v_effort,'model',v_model,'danger',v_danger,'why',v_why));
  END LOOP;
  RETURN jsonb_build_object('added', v_added, 'warnings', v_warn);
END $fn$;

-- Editing a pending card: model and effort join the editable patch.
CREATE OR REPLACE FUNCTION public.dev_cmd_update(p_id bigint, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_deps bigint[]; v_model text; v_effort text;
BEGIN
  PERFORM _dev_guard();
  IF p_patch ? 'depends_on' THEN
    SELECT coalesce(array_agg(x::bigint), '{}') INTO v_deps FROM jsonb_array_elements_text(p_patch->'depends_on') x;
  END IF;
  v_model  := _dev_model_norm(p_patch->>'model');
  v_effort := _dev_effort_norm(p_patch->>'effort');
  IF v_model IS NOT NULL AND v_model NOT IN ('claude-opus-5','claude-fable-5-1') THEN
    RAISE EXCEPTION 'dev_cmd_update: model "%" is not allowed (CHANGE #656 — only claude-opus-5 and claude-fable-5-1)', p_patch->>'model';
  END IF;
  IF v_effort IS NOT NULL AND v_effort NOT IN ('high','extra') THEN
    RAISE EXCEPTION 'dev_cmd_update: effort "%" is not allowed (CHANGE #656 — only high and extra)', p_patch->>'effort';
  END IF;
  UPDATE dev_commands SET
    title = coalesce(p_patch->>'title', title),
    spec = coalesce(p_patch->>'spec', spec),
    priority = coalesce((p_patch->>'priority')::int, priority),
    urgent = coalesce((p_patch->>'urgent')::boolean, urgent),
    depends_on = CASE WHEN p_patch ? 'depends_on' THEN v_deps ELSE depends_on END,
    batch_label = coalesce(p_patch->>'batch_label', batch_label),
    model = coalesce(v_model, model),
    effort = coalesce(v_effort, effort),
    targets_web = coalesce((p_patch->>'targets_web')::boolean, targets_web),
    targets_android = coalesce((p_patch->>'targets_android')::boolean, targets_android),
    targets_ios = coalesce((p_patch->>'targets_ios')::boolean, targets_ios)
  WHERE id = p_id AND status IN ('pending','awaiting_approval','paused','needs_input');
  IF NOT FOUND THEN RAISE EXCEPTION 'dev_cmd_update: row not editable'; END IF;
  RETURN jsonb_build_object('ok', true);
END $fn$;

-- The heartbeat records what the session REALLY used and never touches the
-- request. This is the #653 bug: a row asked for Fable and came back "opus"
-- because the heartbeat overwrote its own instruction.
CREATE OR REPLACE FUNCTION public.dev_cmd_heartbeat(p_id bigint, p_log_tail text DEFAULT NULL::text, p_tokens_in bigint DEFAULT 0, p_tokens_out bigint DEFAULT 0, p_model text DEFAULT NULL::text, p_effort text DEFAULT NULL::text, p_mode text DEFAULT NULL::text, p_eta_total_s integer DEFAULT NULL::integer, p_eta_left_s integer DEFAULT NULL::integer, p_eta_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_cfg jsonb; v_rates jsonb; v_model text; v_mode text; v_in_usd numeric; v_out_usd numeric; v_fx numeric;
        v_budget bigint; v_extra bigint; v_tokens bigint; v_class text;
BEGIN
  PERFORM _dev_guard();
  SELECT value INTO v_cfg FROM dev_runner_config WHERE key='model_rates';
  UPDATE dev_commands SET
    heartbeat_at = now(),
    build_log = right(build_log || coalesce(E'\n'||p_log_tail,''), 200000),
    cost_input_tokens = cost_input_tokens + p_tokens_in,
    cost_output_tokens = cost_output_tokens + p_tokens_out,
    -- CHANGE #656: the REQUEST is never overwritten; the observation lands in actual_*.
    actual_model  = coalesce(nullif(p_model,''),  actual_model),
    actual_effort = coalesce(nullif(p_effort,''), actual_effort),
    price_mode = coalesce(p_mode, price_mode, 'standard'),
    eta_total_s = coalesce(p_eta_total_s, eta_total_s),
    eta_left_s = coalesce(p_eta_left_s, eta_left_s),
    eta_note = coalesce(p_eta_note, eta_note)
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'kill', true, 'reason','row not building'); END IF;

  -- Costing follows the model the session actually ran on, falling back to the
  -- one that was asked for.
  SELECT coalesce(nullif(actual_model,''), model), price_mode, cost_input_tokens+cost_output_tokens, token_budget_extra, size_class
    INTO v_model, v_mode, v_tokens, v_extra, v_class FROM dev_commands WHERE id=p_id;
  v_rates := coalesce(v_cfg->'models'->v_model, v_cfg->'models'->'claude-opus-5', v_cfg->'models'->'claude-opus-4-8');
  v_fx := coalesce((v_cfg->>'usd_inr')::numeric, 88);
  IF v_mode='fast' AND v_rates ? 'fast_in' THEN v_in_usd:=(v_rates->>'fast_in')::numeric; v_out_usd:=(v_rates->>'fast_out')::numeric;
  ELSE v_in_usd:=(v_rates->>'in')::numeric; v_out_usd:=(v_rates->>'out')::numeric; END IF;
  UPDATE dev_commands SET cost_inr = round((cost_input_tokens*v_in_usd + cost_output_tokens*v_out_usd) * v_fx / 1000000.0, 2) WHERE id=p_id;

  v_budget := coalesce((SELECT (value->'token_budget_by_class'->>coalesce(v_class,'normal'))::bigint FROM dev_runner_config WHERE key='worker_pool'), 1500000)
              + coalesce(v_extra,0);
  IF v_tokens > v_budget THEN
    UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
      needs_input_question='Token budget for a '||coalesce(v_class,'normal')||' build hit ('||v_tokens||' > '||v_budget||'). Reply yes for one more window, or refine/split the spec.'
    WHERE id=p_id AND status='building';
    INSERT INTO dev_command_messages (command_id, sender, body) VALUES (p_id,'system','⛔ Auto-stopped: '||coalesce(v_class,'normal')||' token budget '||v_budget||' exceeded ('||v_tokens||').');
    PERFORM _lease_release_internal(p_id);
    PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',p_id::text,'reason','token budget ('||coalesce(v_class,'normal')||')','tokens',v_tokens::text), NULL, NULL);
    RETURN jsonb_build_object('ok', true, 'kill', true, 'reason','token_budget');
  END IF;
  RETURN jsonb_build_object('ok', true, 'model', v_model, 'mode', coalesce(v_mode,'standard'));
END $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. Surfaces — the card, the claim payload, the add sheet's options
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_card_keys()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $fn$
  select array[
    'id','title','status','kind','area','area_label','batch_label','priority',
    'urgent','is_danger','effort','route','route_label','route_tone',
    'claimed_by','model','model_chip','model_label','effort_label','retry_count',
    'created_at','started_at','finished_at','heartbeat_at','eta_at',
    'age_display','elapsed_display','remaining_display','tat_display',
    'ttt_display','speed_display','tokens_display','cost_display','cost_note',
    'has_eta','has_tokens','is_live','is_waiting','is_overrun','msg_count',
    'steps_done','steps_total','steps_chip','steps_stale_chip','steps_stale_hint',
    'spec_chip','spec_tone','spec_open','spec_total',
    'qa_chip','qa_tone','qa_status','qa_required','qa_open_findings',
    'journey_chip','preview_chip','preview_tone','preview_status',
    'chain_chip','chain_tone','finish_chip','finish_tone',
    'wait_chip','wait_tone','wait_kind','wait_reason','wait_hint','wait_state',
    'live_chip','stall_chip','resume_chip','debug_status','debug_requested',
    'auto_finished','auto_finish_source','rolled_back',
    'web_deploy_no','android_status','ios_status',
    'targets_web','targets_android','targets_ios'
  ]::text[];
$fn$;

-- The add sheet and the edit sheet render this verbatim — no model id, label,
-- default or separator is written in Dart.
CREATE OR REPLACE FUNCTION public.dev_model_options()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT jsonb_build_object(
    'ok', true,
    'title',         coalesce(value->>'title','Model & effort'),
    'hint',          coalesce(value->>'hint',''),
    'model_title',   coalesce(value->>'model_title','Model'),
    'effort_title',  coalesce(value->>'effort_title','Effort'),
    'default_model', coalesce(value->>'default_model','claude-opus-5'),
    'default_effort',coalesce(value->>'default_effort','high'),
    'models',        coalesce(value->'models','[]'::jsonb),
    'efforts',       coalesce(value->'efforts','[]'::jsonb))
  FROM dev_runner_config WHERE key='models';
$fn$;
GRANT EXECUTE ON FUNCTION public.dev_model_options() TO authenticated, anon, service_role;

-- The supervisor only ever asks for the two lanes that still exist.
CREATE OR REPLACE FUNCTION public.dev_supervisor_tick(p_agents text[] DEFAULT '{}'::text[], p_routes text[] DEFAULT ARRAY['fast'::text, 'opus'::text])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
declare v_ctl jsonb; v_slots jsonb; v_routes jsonb;
begin
  perform _dev_guard();

  v_ctl := public.dev_ctl_get();

  select coalesce(jsonb_object_agg(a.agent, coalesce(b.row_json, 'null'::jsonb)), '{}'::jsonb)
    into v_slots
  from unnest(coalesce(p_agents,'{}')) a(agent)
  left join lateral (
    select jsonb_build_object(
             'id', c.id, 'title', c.title, 'model', c.model, 'effort', c.effort,
             'model_label', _dev_model_label(c.model), 'effort_label', _dev_effort_label(c.effort),
             'eta_left_s', c.eta_left_s, 'started_at', c.started_at,
             'heartbeat_at', c.heartbeat_at) as row_json
      from dev_commands c
     where c.status = 'building' and c.claimed_by = a.agent and c.id > 0
     order by c.heartbeat_at desc nulls last
     limit 1
  ) b on true;

  select coalesce(jsonb_object_agg(r.route, coalesce(k.n, 0)), '{}'::jsonb)
    into v_routes
  from unnest(coalesce(p_routes,'{}')) r(route)
  left join lateral (
    select count(*)::int n from dev_commands c
     where c.status = 'pending' and c.route = r.route and c.id > 0
  ) k on true;

  return jsonb_build_object(
    'ok', true,
    'server_time', now(),
    'ctl', v_ctl,
    'workflow', coalesce(v_ctl #>> '{desired_state,workflow}', 'on'),
    'active_host', coalesce(nullif(v_ctl #>> '{pool,config,active_host}',''),
                            (select value #>> '{active_host}' from dev_runner_config
                              where key = 'worker_pool'), ''),
    'pending_count',  (select count(*)::int from dev_commands
                        where status = 'pending'  and id > 0),
    'building_count', (select count(*)::int from dev_commands
                        where status = 'building' and id > 0),
    'android_requested',
      (select count(*)::int from dev_commands
        where android_status = 'requested' and id > 0),
    'pending_by_route', v_routes,
    'slots', v_slots);
end $fn$;

-- dev_cmd_list_full is 200 lines of card composition; only the model chip line
-- changes here, so it is patched in place rather than retyped (and the guard
-- makes a re-apply a no-op).
DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='dev_cmd_list_full';
  IF d IS NULL THEN RETURN; END IF;
  IF position('dc.actual_model' in d) > 0 THEN RETURN; END IF;
  d := replace(d,
    '_dev_model_chip(dc.model, dc.effort, dc.price_mode) as model_chip',
    '_dev_model_chip(dc.model, dc.effort, dc.price_mode, dc.actual_model, dc.actual_effort) as model_chip,'
    || E'\n           coalesce(dc.actual_model,'''') as actual_model,'
    || E'\n           coalesce(dc.actual_effort,'''') as actual_effort,'
    || E'\n           _dev_model_label(dc.model) as model_label,'
    || E'\n           _dev_effort_label(dc.effort) as effort_label');
  EXECUTE d;
END $do$;

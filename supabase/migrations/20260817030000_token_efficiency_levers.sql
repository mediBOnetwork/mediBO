-- CHANGE #198 — Token-efficiency overhaul (5 levers)
--
-- Measured baseline before this migration (dev_commands, 92 rows):
--   • 17 rows (18%) were auto-spawned "Debug pass — verify & fix #N" twins and
--     they burned 18,191,685 of 72,615,853 total tokens = 25.1% of ALL spend.
--   • 91 of 92 rows routed 'opus', 1 'sonnet', 0 'fast'. Root cause: the
--     opus_markers list held 'rpc' / 'engine' / 'pipeline' / 'end-to-end' /
--     'realtime', and virtually every mediBO spec contains at least one of
--     those words, so the opus veto fired on everything.
--   • effort='high' on 57 rows, NULL (→ session default high) on 30. Nothing
--     ever ran at standard effort.
--   • avg 668,585 tokens per completed command.
--
-- Levers implemented here (1,2,3,5 are backend; 4 is scripts/REPO_MAP.md):
--   L1  debug-pass gate      — _dev_auto_debug_trg only fires on real evidence
--   L2  real size routing    — _route_detect gains a haiku lane + size_class
--   L3  effort default down  — _dev_effort_for(), default 'standard'
--   L5  small-job batching   — dev_cmd_claim_batch()
--
-- Everything is config-driven from dev_runner_config.worker_pool so the knobs
-- move with pool_set(), no deploy.

-- ────────────────────────────────────────────────────────────────────────────
-- route_reason: the backend's own sentence explaining WHY a row got its lane.
-- Rendered verbatim by the app (dev_cmd_spec → route_reason) so a misroute is
-- visible instead of buried in a log file.
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE dev_commands ADD COLUMN IF NOT EXISTS route_reason text;

-- the route CHECK predates the haiku lane and would reject every cheap row
ALTER TABLE dev_commands DROP CONSTRAINT IF EXISTS dev_commands_route_check;
ALTER TABLE dev_commands ADD CONSTRAINT dev_commands_route_check
  CHECK (route = ANY (ARRAY['opus'::text, 'sonnet'::text, 'haiku'::text, 'fast'::text]));

-- ────────────────────────────────────────────────────────────────────────────
-- CONFIG — routing lanes, thresholds, effort defaults, debug gate
-- ────────────────────────────────────────────────────────────────────────────
UPDATE dev_runner_config c
   SET value = c.value
     || jsonb_build_object('routing',
          coalesce(c.value->'routing','{}'::jsonb)
          || jsonb_build_object(
               'enabled', true,
               -- dedicated worker slots per lane (slot 1 always claims all three)
               'lanes', jsonb_build_object('haiku',2,'sonnet',3,'opus',2),
               'haiku_max_chars', 400,
               'sonnet_max_chars', 2000,
               'opus_min_chars', 4000,
               -- TIGHTENED (see header): only genuinely multi-system / risky
               -- words veto the cheap lanes. 'rpc'/'engine'/'pipeline'/
               -- 'end-to-end'/'realtime' were removed — they matched everything.
               'opus_markers', '["migration","schema","security","architecture",
                                 "payment","auth","rls","trigger","multi-system",
                                 "overhaul","re-architect","data model"]'::jsonb,
               -- WIDENED: the old 15-word list matched almost nothing.
               'sonnet_markers', '["text","label","copy","color","colour","rename",
                                   "toggle","padding","spacing","icon","tooltip","typo",
                                   "wording","small fix","minor","chip","badge","button",
                                   "screen","card","list","sort","filter","empty state",
                                   "banner","dialog","sheet","tab","header","footer",
                                   "field","form","validation","message","toast","hint",
                                   "placeholder","order","layout","align","width","height",
                                   "show","hide","add a","remove the","fix the","change the",
                                   "update the","ui","widget","chart","column","row"]'::jsonb,
               -- any of these means the job touches more than one file → never haiku
               'multi_markers', '["and also","across","every screen","all screens",
                                  "multiple","both ","end to end","end-to-end","plus ",
                                  "then also","several","each of","everywhere","suite",
                                  "engine","pipeline","realtime"]'::jsonb,
               'log', true))
     || jsonb_build_object('effort',
          jsonb_build_object(
            'default', 'standard',
            'was', 'high',
            'high_marker', 'effort: high',
            'escalate_on', '["retry","xlarge","spec_flag"]'::jsonb))
     || jsonb_build_object('debug_gate',
          jsonb_build_object(
            'enabled', true,
            'note', 'a debug twin is created ONLY on qa_status=failed, a red journey run, or an explicit Om request',
            'skip_areas', '["infra","devops"]'::jsonb,
            'require_app_deploy', true))
 WHERE c.key = 'worker_pool';

-- ────────────────────────────────────────────────────────────────────────────
-- LEVER 2 — REAL SIZE ROUTING
-- _route_detect now returns the lane, the area, a size_class and a plain
-- sentence saying why. Return type changed → DROP + CREATE (the only caller,
-- dev_cmd_bulk_add, is rewritten below in the same migration).
-- ────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public._route_detect(text, text);

CREATE FUNCTION public._route_detect(p_title text, p_spec text)
RETURNS TABLE(route text, area text, size_class text, reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  cfg jsonb; t text; n int;
  v_route text := 'opus'; v_area text := NULL; v_size text := 'normal'; v_why text := '';
  hit_opus text; hit_multi text; hit_sonnet text;
  c_haiku int; c_sonnet int; c_opus int;
BEGIN
  SELECT value->'routing' INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  cfg := coalesce(cfg, '{}'::jsonb);
  t := lower(coalesce(p_title,'')||' '||coalesce(p_spec,''));
  n := length(coalesce(p_spec,''));
  c_haiku  := coalesce((cfg->>'haiku_max_chars')::int, 400);
  c_sonnet := coalesce((cfg->>'sonnet_max_chars')::int, 2000);
  c_opus   := coalesce((cfg->>'opus_min_chars')::int, 4000);

  SELECT o INTO hit_opus   FROM jsonb_array_elements_text(coalesce(cfg->'opus_markers','[]'::jsonb)) o
    WHERE t LIKE '%'||o||'%' LIMIT 1;
  SELECT m INTO hit_multi  FROM jsonb_array_elements_text(coalesce(cfg->'multi_markers','[]'::jsonb)) m
    WHERE t LIKE '%'||m||'%' LIMIT 1;
  SELECT s INTO hit_sonnet FROM jsonb_array_elements_text(coalesce(cfg->'sonnet_markers','[]'::jsonb)) s
    WHERE t LIKE '%'||s||'%' LIMIT 1;

  -- size_class first — the token budget and the effort default both read it
  v_size := CASE
    WHEN n >= c_opus OR (hit_opus IS NOT NULL AND n >= c_sonnet) THEN 'xlarge'
    WHEN n >= c_sonnet THEN 'large'
    WHEN n < c_haiku AND hit_opus IS NULL AND hit_multi IS NULL THEN 'small'
    ELSE 'normal' END;

  -- fast lane: exact single-statement grammars, executed instantly, no worker
  IF p_spec ~* '^\s*ui_copy\s+[a-z0-9_.]+\s*=\s*.+'
     OR p_spec ~* '^\s*design\s+[a-z]+\.[a-zA-Z]+\s*=\s*.+' THEN
    v_route := 'fast'; v_why := 'Fast lane — exact one-line grammar, runs instantly with no worker.';
  ELSIF NOT coalesce((cfg->>'enabled')::boolean, true) THEN
    v_route := 'opus'; v_why := 'Opus — routing is switched off in worker_pool.routing.';
  ELSIF hit_opus IS NOT NULL THEN
    v_route := 'opus';
    v_why := 'Opus — spec mentions "'||hit_opus||'" ('||n||' chars), so it can change the data model or security surface.';
  ELSIF n >= c_opus THEN
    v_route := 'opus';
    v_why := 'Opus — spec is '||n||' chars, over the '||c_opus||'-char multi-system threshold.';
  ELSIF v_size = 'small' THEN
    v_route := 'haiku';
    v_why := 'Haiku — '||n||' chars, single-file scope, no heavy markers'
             ||coalesce(' (matched "'||hit_sonnet||'")','')||'.';
  ELSIF n < c_sonnet THEN
    v_route := 'sonnet';
    v_why := 'Sonnet — '||n||' chars, no schema/migration/payment/auth marker'
             ||coalesce(', matched "'||hit_sonnet||'"','')
             ||coalesce(', multi-file hint "'||hit_multi||'"','')||'.';
  ELSE
    v_route := 'opus';
    v_why := 'Opus — '||n||' chars, above the '||c_sonnet||'-char Sonnet ceiling.';
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
END $function$;

-- lane chrome: the app draws these verbatim, so 'haiku' needs its own row
CREATE OR REPLACE FUNCTION public._route_label(r text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE r WHEN 'fast' THEN 'Fast' WHEN 'haiku' THEN 'Haiku'
                WHEN 'sonnet' THEN 'Sonnet' WHEN 'opus' THEN 'Opus' ELSE '' END
$function$;

CREATE OR REPLACE FUNCTION public._route_tone(r text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE r WHEN 'fast' THEN 'success' WHEN 'haiku' THEN 'success'
                WHEN 'sonnet' THEN 'info' WHEN 'opus' THEN 'neutral' ELSE 'neutral' END
$function$;

CREATE OR REPLACE FUNCTION public._route_hint(r text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE r WHEN 'fast' THEN 'Will run instantly ⚡'
                WHEN 'haiku' THEN 'Haiku lane — cheapest'
                WHEN 'sonnet' THEN 'Sonnet lane'
                WHEN 'opus' THEN 'Opus lane' ELSE '' END
$function$;

-- ────────────────────────────────────────────────────────────────────────────
-- LEVER 3 — EFFORT DEFAULT DOWN (standard, not high)
-- Escalates to 'high' only on: a retry, size_class=xlarge, or the spec saying
-- so explicitly. Everything else builds at standard effort.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_effort_for(p_spec text, p_size_class text, p_retry int)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE cfg jsonb; v_def text; v_marker text;
BEGIN
  SELECT value->'effort' INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  cfg := coalesce(cfg,'{}'::jsonb);
  v_def := coalesce(cfg->>'default','standard');
  v_marker := coalesce(cfg->>'high_marker','effort: high');
  IF coalesce(p_retry,0) > 0 THEN RETURN 'high'; END IF;
  IF coalesce(p_size_class,'normal') = 'xlarge' THEN RETURN 'high'; END IF;
  IF lower(coalesce(p_spec,'')) LIKE '%'||lower(v_marker)||'%' THEN RETURN 'high'; END IF;
  RETURN v_def;
END $function$;

-- a failed first attempt escalates the retry to high effort (LEVER 3 rule)
CREATE OR REPLACE FUNCTION public.dev_cmd_fail(p_id bigint, p_error text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_retry int;
BEGIN
  PERFORM _dev_guard();
  SELECT retry_count INTO v_retry FROM dev_commands WHERE id=p_id;
  IF v_retry = 0 THEN
    UPDATE dev_commands SET status='pending', retry_count=1, claimed_by=NULL,
      effort='high',
      route_reason = coalesce(route_reason,'')||' · retry escalated to high effort',
      error_log = coalesce(error_log||E'\n---\n','')||'RETRY 1 after: '||p_error
    WHERE id=p_id AND status='building';
  ELSE
    UPDATE dev_commands SET status='failed', finished_at=now(), claimed_by=NULL,
      error_log = coalesce(error_log||E'\n---\n','')||p_error
    WHERE id=p_id AND status='building';
    IF FOUND THEN
      PERFORM wa_send_event('dev_cmd_failed', NULL, jsonb_build_object('command_id', p_id::text, 'error', left(p_error,300)), NULL, NULL);
    END IF;
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'retried', v_retry = 0);
END $function$;

-- ────────────────────────────────────────────────────────────────────────────
-- LEVER 1 — DEBUG-PASS GATE (the single biggest saving: 25% of all tokens)
-- A "Debug pass — verify & fix #N" twin is now created ONLY when there is real
-- evidence something is wrong:
--   (a) qa_status = 'failed', or
--   (b) at least one red journey run linked to this command, or
--   (c) Om explicitly asked for it (debug_requested / dev_cmd_request_debug).
-- QA passed = done. Config-only / infra jobs and builds that deployed no app
-- code never spawn a twin at all.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_auto_debug_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  gate jsonb; v_reason text := NULL; v_red int := 0; v_skip_areas jsonb;
BEGIN
  IF NOT (NEW.status='completed' AND OLD.status IS DISTINCT FROM 'completed') THEN
    RETURN NEW;
  END IF;
  IF coalesce(NEW.auto_debug_done,false)
     OR coalesce(NEW.kind,'dev') <> 'dev'
     OR coalesce(NEW.route,'') = 'fast'
     OR coalesce(NEW.debug_status,'') = 'running'
     OR NEW.title ILIKE '%debug pass%' THEN
    RETURN NEW;
  END IF;

  SELECT value->'debug_gate' INTO gate FROM dev_runner_config WHERE key='worker_pool';
  gate := coalesce(gate,'{}'::jsonb);

  -- ── EVIDENCE, not habit ───────────────────────────────────────────────────
  SELECT count(*) INTO v_red FROM dev_journey_runs
   WHERE command_id = NEW.id AND lower(coalesce(status,'')) IN ('failed','red','fail');

  IF coalesce(NEW.qa_status,'') = 'failed' THEN
    v_reason := 'QA reported failed';
  ELSIF v_red > 0 THEN
    v_reason := v_red||' journey run(s) came back red';
  ELSIF coalesce(NEW.debug_requested,false) THEN
    v_reason := 'Om requested a debug pass';
  END IF;

  IF v_reason IS NULL THEN
    -- QA passed / nothing red / nobody asked → done. No twin, no second bill.
    NEW.auto_debug_done := true;
    NEW.debug_status := 'not_needed';
    RETURN NEW;
  END IF;

  -- ── cheap-job skips: infra/config work and builds that shipped no app code ─
  IF coalesce((gate->>'enabled')::boolean, true) THEN
    v_skip_areas := coalesce(gate->'skip_areas','[]'::jsonb);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_skip_areas) a
                WHERE a = coalesce(NEW.area,'')) THEN
      NEW.auto_debug_done := true; NEW.debug_status := 'not_needed'; RETURN NEW;
    END IF;
    IF coalesce((gate->>'require_app_deploy')::boolean, true)
       AND NEW.web_deploy_no IS NULL THEN
      NEW.auto_debug_done := true; NEW.debug_status := 'not_needed'; RETURN NEW;
    END IF;
  END IF;

  NEW.auto_debug_done := true;
  NEW.debug_requested := true;
  NEW.debug_status := 'requested';

  INSERT INTO dev_commands (title, spec, urgent, priority, kind, area, qa_required,
                            auto_debug, size_class, route, effort, route_reason)
  VALUES ('Debug pass — verify & fix #'||NEW.id,
    'END-TO-END DEBUG PASS for completed command #'||NEW.id||' ("'||left(NEW.title,80)||'").'||
    E'\nTriggered because: '||v_reason||'.'||
    E'\nDo a 360 on what #'||NEW.id||' built: exercise every feature/flow it touched on the live preview, run its area journeys + QA, and if ANY bug/regression is found, FIX it (root cause, not patch), re-run until green, then complete. If nothing is wrong, complete with a short "verified clean" note. Read the command''s spec, build_log, and result before starting. Do NOT re-ask Om — pick sensible defaults per legal_get_page(''about'')/lessons and continue.',
    true, 5, 'dev', NEW.area, true, false, coalesce(NEW.size_class,'normal'),
    coalesce(NEW.route,'sonnet'), 'high',
    'Debug twin — '||v_reason||'.');

  INSERT INTO dev_command_messages(command_id, sender, body)
  VALUES (NEW.id,'system','🔎 Auto-debug queued: '||v_reason||' — an end-to-end debug pass will verify and fix this build.');
  RETURN NEW;
END $function$;

-- ────────────────────────────────────────────────────────────────────────────
-- dev_cmd_bulk_add — store the new routing outputs (size_class, effort,
-- route_reason) on every row it creates.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_cmd_bulk_add(p_items jsonb, p_force boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r jsonb; v_warn jsonb := '[]'; v_added jsonb := '[]'; v_id bigint; v_dup record; v_deps bigint[];
        v_scan jsonb; v_kind text; v_danger boolean; v_title text; v_imgs jsonb; v_atts jsonb;
        v_route text; v_area text; v_size text; v_why text; v_effort text; v_fast text;
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
      v_why := 'Opus — Google Cloud command, runs the gcloud lane.';
    END IF;
    v_effort := _dev_effort_for(r->>'spec', v_size, 0);

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
        v_route := 'sonnet';
        v_why := 'Sonnet — fast-lane grammar did not apply, handed to the cheap builder lane.';
      END IF;
    END IF;

    INSERT INTO dev_commands (title, spec, status, priority, urgent, depends_on, batch_label, targets_web, targets_android, targets_ios, kind, is_danger, route, area, size_class, effort, route_reason, qa_required, created_by)
    VALUES (
      v_title, r->>'spec',
      CASE WHEN coalesce((r->>'require_approval')::boolean,false) THEN 'awaiting_approval' ELSE 'pending' END,
      coalesce((r->>'priority')::int, 100), coalesce((r->>'urgent')::boolean, false), v_deps,
      coalesce(r->>'batch_label', v_area),
      coalesce((r->>'targets_web')::boolean, v_kind='dev'),
      coalesce((r->>'targets_android')::boolean, false), coalesce((r->>'targets_ios')::boolean, false),
      v_kind, v_danger, v_route, v_area, v_size, v_effort, v_why,
      coalesce((r->>'qa_required')::boolean, true),
      auth.uid()
    ) RETURNING id INTO v_id;
    v_imgs := coalesce(r->'images','[]'::jsonb); v_atts := coalesce(r->'attachments','[]'::jsonb);
    IF jsonb_array_length(v_imgs) > 0 OR jsonb_array_length(v_atts) > 0 THEN
      INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
      VALUES (v_id, 'om', coalesce(nullif(btrim(r->>'media_note'),''),'Attached with the spec'), v_imgs, v_atts);
    END IF;
    v_added := v_added || jsonb_build_object('id', v_id, 'title', v_title, 'route', v_route, 'area', v_area,
                                             'size_class', v_size, 'effort', v_effort, 'route_reason', v_why,
                                             'is_danger', v_danger);
    PERFORM _audit(_actor(),'cmd_add', v_id::text, jsonb_build_object('route',v_route,'area',v_area,'size',v_size,'effort',v_effort,'danger',v_danger,'why',v_why));
  END LOOP;
  RETURN jsonb_build_object('added', v_added, 'warnings', v_warn);
END $function$;

-- ────────────────────────────────────────────────────────────────────────────
-- LEVER 5 — SMALL-JOB BATCHING
-- One worker boot, one context, up to worker_pool.batch_max small commands from
-- the SAME area, built sequentially and shipped through ONE deploy-lane pass.
-- Rows are claimed atomically (SKIP LOCKED) and each keeps its own status, so a
-- sub-item that fails is failed alone and never sinks its siblings.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_cmd_claim_batch(
  p_agent text, p_routes text[] DEFAULT NULL::text[],
  p_prefer_area text DEFAULT NULL::text, p_max int DEFAULT NULL::int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_first jsonb; v_id bigint; v_area text; v_size text; v_route text;
  v_max int; v_label text; v_rows jsonb := '[]'; v_extra jsonb;
BEGIN
  -- first row uses the ordinary claim (guard, freeze, budget, deps, affinity)
  v_first := dev_cmd_claim(p_agent, p_routes, p_prefer_area);
  IF coalesce((v_first->>'empty')::boolean,false) THEN RETURN v_first; END IF;

  v_id   := (v_first->>'id')::bigint;
  v_area := v_first->>'area';
  v_size := coalesce(v_first->>'size_class','normal');
  v_route:= coalesce(v_first->>'route','opus');
  v_rows := jsonb_build_array(v_first);

  SELECT coalesce(p_max, (value->>'batch_max')::int, 4) INTO v_max
    FROM dev_runner_config WHERE key='worker_pool';
  v_max := greatest(coalesce(v_max,4), 1);

  -- only small jobs batch; anything bigger builds alone
  IF v_size <> 'small' OR v_max < 2 OR v_area IS NULL THEN
    RETURN jsonb_build_object('batch', false, 'count', 1, 'rows', v_rows, 'first', v_first);
  END IF;

  v_label := 'batch-'||v_id;

  WITH picked AS (
    SELECT c.id FROM dev_commands c
     WHERE c.status='pending'
       AND c.area IS NOT DISTINCT FROM v_area
       AND coalesce(c.size_class,'normal') = 'small'
       AND coalesce(c.kind,'dev') = 'dev'
       AND coalesce(c.is_danger,false) = false
       AND coalesce(c.route,'opus') = v_route
       AND (p_routes IS NULL OR c.route = ANY(p_routes))
       AND coalesce(array_length(c.depends_on,1),0) = 0
       AND NOT EXISTS (SELECT 1 FROM dev_commands d
                        WHERE d.depends_on @> ARRAY[c.id] AND d.status <> 'completed')
     ORDER BY c.urgent DESC, c.priority, c.id
     FOR UPDATE OF c SKIP LOCKED
     LIMIT (v_max - 1)
  ), upd AS (
    UPDATE dev_commands dc
       SET status='building', claimed_by=p_agent, started_at=now(),
           heartbeat_at=now(), batch_label=v_label
     WHERE dc.id IN (SELECT id FROM picked)
    RETURNING to_jsonb(dc) AS row
  )
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'id')::bigint), '[]'::jsonb) INTO v_extra FROM upd;

  IF jsonb_array_length(v_extra) > 0 THEN
    UPDATE dev_commands SET batch_label = v_label WHERE id = v_id;
    v_rows := v_rows || v_extra;
  END IF;

  RETURN jsonb_build_object(
    'batch', jsonb_array_length(v_rows) > 1,
    'batch_label', v_label,
    'count', jsonb_array_length(v_rows),
    'area', v_area,
    'note', 'Build each row in order in ONE context, then ship all of them through a single deploy-lane pass. Complete every row separately — a failure fails only its own row.',
    'ids', (SELECT jsonb_agg((x->>'id')::bigint) FROM jsonb_array_elements(v_rows) x),
    'rows', v_rows,
    'first', v_first);
END $function$;

REVOKE ALL ON FUNCTION public.dev_cmd_claim_batch(text, text[], text, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dev_cmd_claim_batch(text, text[], text, int) TO service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- FRONTEND WIRING — the app must be able to SEE the routing decision.
-- dev_cmd_spec gains route_reason + the size / effort chips, all pre-worded
-- server-side so Dart prints them verbatim.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_size_label(s text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE coalesce(s,'normal')
           WHEN 'small' THEN 'Small job'
           WHEN 'normal' THEN 'Normal'
           WHEN 'large' THEN 'Large'
           WHEN 'xlarge' THEN 'Extra large'
           ELSE '' END
$function$;

CREATE OR REPLACE FUNCTION public._dev_effort_label(e text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE coalesce(nullif(e,''),'standard')
           WHEN 'standard' THEN 'Standard effort'
           WHEN 'high' THEN 'High effort'
           ELSE initcap(e)||' effort' END
$function$;

-- Backfill the routing story onto rows that predate this migration so the app
-- never shows an empty chip on an old command.
UPDATE dev_commands
   SET size_class = coalesce(size_class,'normal'),
       effort = coalesce(nullif(effort,''), 'high'),
       route_reason = coalesce(route_reason,
         'Routed before CHANGE #198 — the old detector sent 91 of 92 commands to Opus.')
 WHERE route_reason IS NULL;

-- dev_cmd_spec: carry the routing decision to the command detail screen.
CREATE OR REPLACE FUNCTION public.dev_cmd_spec(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v jsonb; v_tat numeric;
BEGIN
  PERFORM _dev_guard();
  v_tat := _dev_cmd_base_tat();
  SELECT jsonb_build_object(
    'id', d.id, 'title', _dev_title(d.title, d.build_log), 'spec', d.spec, 'build_log', d.build_log,
    'images', coalesce(d.images,'[]'::jsonb), 'attachments', coalesce(d.attachments,'[]'::jsonb),
    'upload_bucket', 'dev-cmd-uploads',
    'status', d.status, 'heartbeat_at', d.heartbeat_at, 'is_live', (d.status = 'building'),
    'kind', coalesce(d.kind,'dev'), 'is_danger', coalesce(d.is_danger,false),
    'route', d.route, 'area', d.area,
    'route_label', _route_label(d.route), 'route_tone', _route_tone(d.route), 'area_label', _area_label(d.area),
    'enriched_spec', coalesce(d.enriched_spec,''),
    'has_enriched', (d.enriched_spec IS NOT NULL AND length(coalesce(d.enriched_spec,'')) > 0),
    'plain_summary', coalesce(d.plain_summary,''), 'result_actions', coalesce(d.result_actions,'[]'::jsonb),
    'model', coalesce(d.model,''), 'effort', coalesce(d.effort,''), 'price_mode', coalesce(d.price_mode,''),
    'model_chip', _dev_model_chip(d.model, d.effort, d.price_mode),
    'cost_note', CASE WHEN (d.cost_input_tokens > 0 OR d.cost_output_tokens > 0)
                      THEN ('₹' || to_char(round(d.cost_inr), 'FM9,99,99,990')) || ' — API-equivalent (included in your Max plan · ₹0 extra)'
                      ELSE '' END,
    'tokens_in', d.cost_input_tokens, 'tokens_out', d.cost_output_tokens,
    'tokens_total', d.cost_input_tokens + d.cost_output_tokens,
    'tokens_in_display', _fmt_tokens(d.cost_input_tokens),
    'tokens_out_display', _fmt_tokens(d.cost_output_tokens),
    'tokens_total_display', _fmt_tokens(d.cost_input_tokens + d.cost_output_tokens),
    'cost_display', '₹' || to_char(round(d.cost_inr), 'FM9,99,99,990'),
    'has_tokens', (d.cost_input_tokens > 0 OR d.cost_output_tokens > 0),
    'tat_seconds', tm.tat_seconds, 'tat_display', tm.tat_display,
    'eta_at', tm.eta_at,
    'elapsed_seconds', tm.elapsed_seconds, 'elapsed_display', tm.elapsed_display,
    'remaining_seconds', tm.remaining_seconds, 'remaining_display', tm.remaining_display,
    'is_overrun', tm.is_overrun,
    'has_eta', tm.has_eta, 'eta_note', tm.eta_note,
    'eta_total_s', d.eta_total_s, 'eta_left_s', d.eta_left_s,
    'ttt_seconds', tm.ttt_seconds,
    'ttt_display', tm.ttt_display,
    'messages', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'sender',sender,'body',body,'at',created_at,
        'images', coalesce(images,'[]'::jsonb), 'attachments', coalesce(attachments,'[]'::jsonb)) ORDER BY created_at, id),'[]')
      FROM dev_command_messages WHERE command_id=p_id))
  -- CHANGE #198 — routing story. This MUST stay a separate jsonb_build_object:
  -- the base object above is already close to postgres's hard limit of 100
  -- arguments per function call, and adding these seven pairs inline raised
  -- 54023 "cannot pass more than 100 arguments to a function", which returned
  -- NULL for the whole command-detail payload.
  || jsonb_build_object(
    'route_reason', coalesce(d.route_reason,''),
    'has_route_reason', (coalesce(d.route_reason,'') <> ''),
    'size_class', coalesce(d.size_class,'normal'),
    'size_label', _dev_size_label(d.size_class),
    'effort_label', _dev_effort_label(d.effort),
    'batch_label', coalesce(d.batch_label,''))
  INTO v
  FROM dev_commands d,
       LATERAL _dev_cmd_timing(d.started_at, d.finished_at, d.status, v_tat,
                               d.eta_total_s, d.eta_left_s, d.heartbeat_at, d.eta_note) tm
  WHERE d.id=p_id;
  RETURN v;
END $function$;

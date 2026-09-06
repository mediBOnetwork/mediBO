-- CHANGE #639 — Triage-to-fix loop.
-- Om approves on the phone, commands generate themselves, the bot re-verifies.
-- Idempotent: safe to replay on live at deploy time.

DROP TRIGGER IF EXISTS triage_on_cmd_complete ON public.dev_commands;
DROP FUNCTION IF EXISTS public._triage_on_cmd_complete_trg();

-- ─────────────────────────────────────────────────────────────
-- 1. THE INBOX TABLE
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.triage_finding (
  id              bigserial PRIMARY KEY,
  source          text        NOT NULL,          -- visual|auth|fuzz|invariant|journey|qa
  source_key      text        NOT NULL,          -- stable dedupe key inside that source
  surface         text,                          -- feature_key / route / rpc name
  area            text,
  severity        text        NOT NULL DEFAULT 'medium',
  plain_line      text        NOT NULL,          -- the ONE plain-language line Om reads
  detail          text,
  repro           jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- steps, behind a tap
  scenario        jsonb       NOT NULL DEFAULT '{}'::jsonb,   -- how to re-run THIS exact case
  shot_bucket     text,
  shot_path       text,
  status          text        NOT NULL DEFAULT 'new',
  reject_reason   text,
  fix_command     bigint,          -- the CONTROL-PLANE command id, bound by the bridge
  batch_id        bigint,
  attempted_fixes bigint[]    NOT NULL DEFAULT '{}',
  reopen_count    int         NOT NULL DEFAULT 0,
  seen_count      int         NOT NULL DEFAULT 1,
  found_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  approved_at     timestamptz,
  approved_by     text,
  rejected_at     timestamptz,
  queued_at       timestamptz,
  fixed_at        timestamptz,
  verified_at     timestamptz,
  verify_status   text,
  verify_detail   text,
  escalated_at    timestamptz,
  escalate_reason text
);

DO $$ BEGIN
  ALTER TABLE public.triage_finding
    ADD CONSTRAINT triage_finding_src_uq UNIQUE (source, source_key);
EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.triage_finding ADD CONSTRAINT triage_finding_status_ck
    CHECK (status IN ('new','approved','rejected','queued','verifying','fixed','reopened','escalated'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.triage_finding ADD CONSTRAINT triage_finding_sev_ck
    CHECK (severity IN ('critical','high','medium','low'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.triage_finding ADD COLUMN IF NOT EXISTS batch_id bigint;

CREATE INDEX IF NOT EXISTS triage_finding_status_idx  ON public.triage_finding(status, severity, found_at DESC);
CREATE INDEX IF NOT EXISTS triage_finding_surface_idx ON public.triage_finding(surface, status);
CREATE INDEX IF NOT EXISTS triage_finding_cmd_idx     ON public.triage_finding(fix_command) WHERE fix_command IS NOT NULL;

ALTER TABLE public.triage_finding ENABLE ROW LEVEL SECURITY;
-- No policy: reachable only through the SECURITY DEFINER RPCs below.

-- Every state change is auditable.
CREATE TABLE IF NOT EXISTS public.triage_event (
  id          bigserial PRIMARY KEY,
  finding_id  bigint      NOT NULL REFERENCES public.triage_finding(id) ON DELETE CASCADE,
  kind        text        NOT NULL,          -- found|approved|rejected|queued|verified|reopened|escalated
  actor       text,
  detail      text,
  command_id  bigint,
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS triage_event_finding_idx ON public.triage_event(finding_id, at DESC);
CREATE INDEX IF NOT EXISTS triage_event_kind_idx    ON public.triage_event(kind, at DESC);
ALTER TABLE public.triage_event ENABLE ROW LEVEL SECURITY;

-- ─────────────────────────────────────────────────────────────
-- 2. EVERY DISPLAY STRING (backend-owned; change wording with an UPDATE)
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.ui_copy(key, value)
SELECT k, to_jsonb(v) FROM (VALUES
  ('triage.title',              'Triage'),
  ('triage.subtitle',           'Approve what is real. Rejects teach the bot.'),
  ('triage.empty',              'Nothing waiting. The bot has found no new problems.'),
  ('triage.empty_hint',         'New findings land here the moment the safety net or the visual bot sees one.'),
  ('triage.approve',            'Approve'),
  ('triage.reject',             'Reject'),
  ('triage.repro',              'Repro steps'),
  ('triage.repro_hide',         'Hide steps'),
  ('triage.bulk_by_surface',    'Approve all on this surface'),
  ('triage.bulk_by_severity',   'Approve all at this severity'),
  ('triage.bulk_none',          'Nothing selected'),
  ('triage.reject_reason_hint', 'Why is this not a real problem?'),
  ('triage.reject_needs_reason','A rejection needs a reason — that is what stops the bot re-filing it.'),
  ('triage.sev.critical',       'Critical'),
  ('triage.sev.high',           'High'),
  ('triage.sev.medium',         'Medium'),
  ('triage.sev.low',            'Low'),
  ('triage.st.new',             'Waiting for you'),
  ('triage.st.approved',        'Approved'),
  ('triage.st.rejected',        'Rejected'),
  ('triage.st.queued',          'Fix queued'),
  ('triage.st.verifying',       'Re-checking the fix'),
  ('triage.st.fixed',           'Fixed and re-checked'),
  ('triage.st.reopened',        'Reopened — the fix did not fix it'),
  ('triage.st.escalated',       'Escalated to Om'),
  ('triage.src.visual',         'Visual bot'),
  ('triage.src.auth',           'Permission check'),
  ('triage.src.fuzz',           'Fuzz run'),
  ('triage.src.invariant',      'Data rule'),
  ('triage.src.journey',        'Journey'),
  ('triage.src.qa',             'Hostile QA'),
  ('triage.trend.title',        'Trend'),
  ('triage.trend.found_fixed',  'Found vs fixed'),
  ('triage.trend.worst',        'Worst surfaces'),
  ('triage.trend.reopen',       'Reopen rate'),
  ('triage.trend.mttf',         'Find to fixed'),
  ('triage.trend.coverage',     'Coverage'),
  ('triage.trend.empty',        'Not enough history yet.'),
  ('triage.human_only',         'A finding can only be approved by a person. The bot is not allowed to approve its own work.'),
  ('triage.escalate_note',      'This finding has survived two fixes. It needs a human decision before another command is generated.')
) AS t(k,v)
ON CONFLICT (key) DO NOTHING;

-- ─────────────────────────────────────────────────────────────
-- 3. HELPERS
-- ─────────────────────────────────────────────────────────────

-- The HUMAN gate. Guard rail #1: a finding is never auto-approved.
-- service_role (every bot, cron job and runner) is refused here on purpose.
CREATE OR REPLACE FUNCTION public._triage_human()
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_uid uuid; v_email text;
BEGIN
  BEGIN v_uid := auth.uid(); EXCEPTION WHEN OTHERS THEN v_uid := NULL; END;
  IF v_uid IS NULL OR coalesce(auth.jwt()->>'role','') = 'service_role' THEN
    RAISE EXCEPTION '%', coalesce((SELECT value#>>'{}' FROM ui_copy WHERE key='triage.human_only'),
                                  'triage: a person must approve');
  END IF;
  IF get_my_role() <> 'super_admin' THEN
    RAISE EXCEPTION 'triage: not authorized';
  END IF;
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = v_uid;
  RETURN coalesce(v_email, v_uid::text);
END $fn$;

CREATE OR REPLACE FUNCTION public._triage_tone(p_sev text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE p_sev WHEN 'critical' THEN 'danger' WHEN 'high' THEN 'danger'
                    WHEN 'medium'   THEN 'warning' ELSE 'neutral' END
$fn$;

CREATE OR REPLACE FUNCTION public._triage_status_tone(p_status text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE p_status
    WHEN 'fixed'     THEN 'success'
    WHEN 'reopened'  THEN 'danger'
    WHEN 'escalated' THEN 'danger'
    WHEN 'rejected'  THEN 'neutral'
    WHEN 'queued'    THEN 'info'
    WHEN 'verifying' THEN 'info'
    WHEN 'approved'  THEN 'info'
    ELSE 'warning' END
$fn$;

CREATE OR REPLACE FUNCTION public._triage_copy(p_key text, p_fallback text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT coalesce((SELECT value#>>'{}' FROM ui_copy WHERE key = p_key), p_fallback)
$fn$;

-- "3 days ago" style, IST, backend-worded.
CREATE OR REPLACE FUNCTION public._triage_ago(p_at timestamptz)
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT CASE
    WHEN p_at IS NULL THEN NULL
    WHEN now() - p_at < interval '1 minute' THEN 'just now'
    WHEN now() - p_at < interval '1 hour'   THEN (extract(epoch FROM now()-p_at)/60)::int || 'm ago'
    WHEN now() - p_at < interval '1 day'    THEN (extract(epoch FROM now()-p_at)/3600)::int || 'h ago'
    ELSE (extract(epoch FROM now()-p_at)/86400)::int || 'd ago'
  END
$fn$;

-- ─────────────────────────────────────────────────────────────
-- 4. INTAKE — the bot's findings become inbox rows
--    Severity is DATA, not code: a new rule is one INSERT.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.triage_source_rule (
  source     text NOT NULL,
  rule_key   text NOT NULL DEFAULT '*',
  severity   text NOT NULL DEFAULT 'medium',
  lead_in    text,                      -- prefix for the plain line when the source has none
  enabled    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (source, rule_key)
);
ALTER TABLE public.triage_source_rule ENABLE ROW LEVEL SECURITY;

INSERT INTO public.triage_source_rule(source, rule_key, severity, lead_in) VALUES
  ('visual',   'blank',    'high',     'A screen came up blank'),
  ('visual',   'changed',  'medium',   'A screen no longer looks like its approved baseline'),
  ('visual',   '*',        'medium',   'The visual bot flagged this screen'),
  ('auth',     '*',        'critical', 'The wrong role could reach something'),
  ('fuzz',     '*',        'high',     'A call crashed instead of refusing cleanly'),
  ('invariant','*',        'high',     'A data rule that must always hold does not'),
  ('journey',  '*',        'high',     'A journey that used to pass now fails'),
  ('qa',       'blocker',  'critical', 'Hostile QA found a blocker'),
  ('qa',       'major',    'high',     'Hostile QA found a defect'),
  ('qa',       'minor',    'low',      'Hostile QA found a rough edge'),
  ('qa',       '*',        'medium',   'Hostile QA found something')
ON CONFLICT (source, rule_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public._triage_rule(p_source text, p_rule text)
RETURNS public.triage_source_rule LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT r.* FROM triage_source_rule r
   WHERE r.source = p_source AND r.enabled
     AND r.rule_key IN (coalesce(p_rule,'*'), '*')
   ORDER BY (r.rule_key = coalesce(p_rule,'*')) DESC
   LIMIT 1
$fn$;

-- Upsert one finding. Re-seeing a KNOWN case only bumps last_seen_at —
-- it never resurrects a row Om rejected, and never un-fixes a fixed one.
CREATE OR REPLACE FUNCTION public._triage_file(
  p_source text, p_source_key text, p_surface text, p_area text,
  p_rule text, p_plain text, p_detail text, p_repro jsonb, p_scenario jsonb,
  p_bucket text DEFAULT NULL, p_path text DEFAULT NULL, p_severity text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE r public.triage_source_rule; v_id bigint; v_sev text; v_line text;
BEGIN
  r := public._triage_rule(p_source, p_rule);
  IF r.source IS NULL THEN RETURN NULL; END IF;             -- rule disabled = not filed
  v_sev  := coalesce(p_severity, r.severity);
  v_line := coalesce(nullif(btrim(coalesce(p_plain,'')),''),
                     coalesce(r.lead_in,'The bot found a problem'));

  INSERT INTO triage_finding(source, source_key, surface, area, severity,
                             plain_line, detail, repro, scenario, shot_bucket, shot_path)
  VALUES (p_source, p_source_key, p_surface, p_area, v_sev,
          v_line, p_detail, coalesce(p_repro,'[]'::jsonb), coalesce(p_scenario,'{}'::jsonb),
          p_bucket, p_path)
  ON CONFLICT (source, source_key) DO UPDATE
     SET last_seen_at = now(),
         seen_count   = triage_finding.seen_count + 1,
         -- a still-open row keeps the freshest evidence; a closed one is left alone
         plain_line   = CASE WHEN triage_finding.status IN ('new','approved','reopened')
                             THEN EXCLUDED.plain_line ELSE triage_finding.plain_line END,
         detail       = CASE WHEN triage_finding.status IN ('new','approved','reopened')
                             THEN EXCLUDED.detail ELSE triage_finding.detail END,
         repro        = CASE WHEN triage_finding.status IN ('new','approved','reopened')
                             THEN EXCLUDED.repro ELSE triage_finding.repro END,
         shot_bucket  = coalesce(EXCLUDED.shot_bucket, triage_finding.shot_bucket),
         shot_path    = coalesce(EXCLUDED.shot_path,   triage_finding.shot_path)
  RETURNING id INTO v_id;

  IF (SELECT seen_count FROM triage_finding WHERE id = v_id) = 1 THEN
    INSERT INTO triage_event(finding_id, kind, actor, detail)
    VALUES (v_id, 'found', p_source, left(v_line, 300));
  END IF;
  RETURN v_id;
END $fn$;

CREATE OR REPLACE FUNCTION public.triage_intake(p_limit int DEFAULT 200)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_new int := 0; v_before bigint; v_after bigint; rec record;
BEGIN
  PERFORM _dev_guard();
  SELECT count(*) INTO v_before FROM triage_finding;

  -- 4a. VISUAL BOT — a rule fired on a screenshot nobody has reviewed.
  FOR rec IN
    SELECT s.id, s.feature_key, s.role, s.viewport, s.rule_key, s.detail, s.bucket, s.path, s.diff_pct
      FROM visual_shot s
     WHERE s.rule_key IS NOT NULL AND coalesce(s.reviewed,false) = false
     ORDER BY s.id DESC LIMIT p_limit
  LOOP
    PERFORM _triage_file('visual',
      rec.feature_key||':'||coalesce(rec.role,'-')||':'||coalesce(rec.viewport,'-')||':'||rec.rule_key,
      rec.feature_key, NULL, rec.rule_key, rec.detail, NULL,
      jsonb_build_array(
        'Sign in as '||coalesce(rec.role,'admin'),
        'Open the '||rec.feature_key||' screen',
        'Use a '||coalesce(rec.viewport,'phone')||'-width window',
        'Compare against the approved baseline'),
      jsonb_build_object('kind','visual','shot_id',rec.id,'feature_key',rec.feature_key,
                         'role',rec.role,'viewport',rec.viewport,'rule_key',rec.rule_key),
      rec.bucket, rec.path);
  END LOOP;

  -- 4b. PERMISSION MATRIX — a role reached something it must not.
  FOR rec IN
    SELECT a.proname, a.role_key, a.expected, a.observed, a.severity, a.evidence
      FROM autotest_auth_check a
     WHERE a.verdict = 'fail'
     ORDER BY a.checked_at DESC LIMIT p_limit
  LOOP
    PERFORM _triage_file('auth', rec.proname||':'||rec.role_key, rec.proname, NULL, '*',
      'Role '||rec.role_key||' got "'||coalesce(rec.observed,'?')||'" from '||rec.proname
        ||' when it should have been "'||coalesce(rec.expected,'?')||'".',
      rec.evidence::text,
      jsonb_build_array('Sign in as '||rec.role_key, 'Call '||rec.proname,
                        'Expected: '||coalesce(rec.expected,'?')),
      jsonb_build_object('kind','auth','proname',rec.proname,'role_key',rec.role_key),
      NULL, NULL,
      -- A role that should have been DENIED and was not is never a middling
      -- problem, whatever the probe recorded: it is a way in.
      CASE WHEN rec.expected = 'deny' AND coalesce(rec.observed,'') <> 'deny' THEN 'critical'
           WHEN rec.severity IN ('critical','high','medium','low') THEN rec.severity
           ELSE NULL END);
  END LOOP;

  -- 4c. FUZZ — a call crashed instead of refusing.
  FOR rec IN
    SELECT f.case_id, c.proname, c.role_key, c.args_label, f.sqlstate, f.message, f.severity, f.assertion
      FROM autotest_fuzz_result f JOIN autotest_fuzz_case c ON c.id = f.case_id
     WHERE f.verdict = 'fail'
     ORDER BY f.ran_at DESC LIMIT p_limit
  LOOP
    PERFORM _triage_file('fuzz', rec.proname||':'||coalesce(rec.role_key,'-')||':'||coalesce(rec.assertion,'crash'),
      rec.proname, NULL, '*',
      rec.proname||' crashed ('||coalesce(rec.sqlstate,'?')||') on a '||coalesce(rec.role_key,'guest')
        ||' call instead of refusing it politely.',
      rec.message,
      jsonb_build_array('Sign in as '||coalesce(rec.role_key,'guest'),
                        'Call '||rec.proname||' with: '||coalesce(rec.args_label,'hostile arguments'),
                        'Expected a clean refusal, got SQLSTATE '||coalesce(rec.sqlstate,'?')),
      jsonb_build_object('kind','fuzz','case_id',rec.case_id,'proname',rec.proname,'role_key',rec.role_key),
      NULL, NULL,
      CASE WHEN rec.severity IN ('critical','high','medium','low') THEN rec.severity ELSE NULL END);
  END LOOP;

  -- 4d. INVARIANTS — a rule that must always hold, does not.
  FOR rec IN
    SELECT DISTINCT ON (r.key) r.key, r.violations, r.sample, r.severity, i.title, i.detail, i.family
      FROM autotest_invariant_result r JOIN autotest_invariant i ON i.key = r.key
     WHERE r.verdict = 'fail'
     ORDER BY r.key, r.ran_at DESC LIMIT p_limit
  LOOP
    PERFORM _triage_file('invariant', rec.key, coalesce(rec.family, rec.key), NULL, '*',
      coalesce(rec.title, rec.key)||' — '||coalesce(rec.violations,0)||' row(s) break this rule right now.',
      rec.detail,
      jsonb_build_array('Rule: '||coalesce(rec.title, rec.key),
                        'Broken rows: '||coalesce(rec.violations,0),
                        'Sample: '||left(coalesce(rec.sample::text,'-'), 400)),
      jsonb_build_object('kind','invariant','key',rec.key,'family',rec.family),
      NULL, NULL,
      CASE WHEN rec.severity IN ('critical','high','medium','low') THEN rec.severity ELSE NULL END);
  END LOOP;

  -- 4e. JOURNEYS — a scenario that used to pass now fails.
  FOR rec IN
    SELECT DISTINCT ON (j.name) j.name, j.area, j.required, r.evidence, r.commit_sha
      FROM dev_journey_runs r JOIN dev_journeys j ON j.id = r.journey_id
     WHERE r.status = 'failed'
     ORDER BY j.name, r.at DESC LIMIT p_limit
  LOOP
    PERFORM _triage_file('journey', rec.name, rec.name, rec.area, '*',
      'The journey "'||rec.name||'" fails: the thing it guards is broken again.',
      left(coalesce(rec.evidence::text,''), 2000),
      jsonb_build_array('Run the journey: '||rec.name,
                        'Area: '||coalesce(rec.area,'global'),
                        'Last seen on commit '||coalesce(rec.commit_sha,'?')),
      jsonb_build_object('kind','journey','name',rec.name),
      NULL, NULL,
      CASE WHEN rec.required THEN 'critical' ELSE NULL END);
  END LOOP;

  -- 4f. HOSTILE QA — an open finding from a QA round.
  FOR rec IN
    SELECT q.id, q.command_id, q.severity, q.title, q.detail, c.area
      FROM qa_findings q LEFT JOIN dev_commands c ON c.id = q.command_id
     WHERE q.status = 'open'
     ORDER BY q.id DESC LIMIT p_limit
  LOOP
    PERFORM _triage_file('qa', 'qa:'||rec.id, coalesce(rec.area,'app'), rec.area, rec.severity,
      coalesce(rec.title, 'QA finding'),
      rec.detail,
      jsonb_build_array('Filed by hostile QA on #'||coalesce(rec.command_id::text,'?'),
                        coalesce(left(rec.detail, 600), 'No further detail was recorded.')),
      jsonb_build_object('kind','qa','finding_id',rec.id,'command_id',rec.command_id));
  END LOOP;

  SELECT count(*) INTO v_after FROM triage_finding;
  v_new := (v_after - v_before)::int;
  RETURN jsonb_build_object('ok', true, 'new', v_new, 'total', v_after,
    'waiting', (SELECT count(*) FROM triage_finding WHERE status='new'));
END $fn$;

-- ─────────────────────────────────────────────────────────────
-- 5. THE INBOX — Om's entire job in the loop
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.triage_inbox(
  p_status   text DEFAULT 'new',
  p_surface  text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_limit    int  DEFAULT 30,
  p_offset   int  DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_rows jsonb; v_total bigint; v_lim int := least(greatest(coalesce(p_limit,30),1), 100);
BEGIN
  PERFORM _dev_guard();

  SELECT count(*) INTO v_total FROM triage_finding f
   WHERE (p_status   IS NULL OR f.status   = p_status)
     AND (p_surface  IS NULL OR f.surface  = p_surface)
     AND (p_severity IS NULL OR f.severity = p_severity);

  SELECT coalesce(jsonb_agg(r ORDER BY r_sev, r_found DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      CASE f.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 ELSE 4 END AS r_sev,
      f.found_at AS r_found,
      jsonb_build_object(
        'id',            f.id,
        'plain_line',    f.plain_line,
        'surface',       f.surface,
        'surface_label', coalesce(f.surface, 'app'),
        'severity',      f.severity,
        'severity_label', _triage_copy('triage.sev.'||f.severity, initcap(f.severity)),
        'severity_tone', _triage_tone(f.severity),
        'source',        f.source,
        'source_label',  _triage_copy('triage.src.'||f.source, initcap(f.source)),
        'status',        f.status,
        'status_label',  _triage_copy('triage.st.'||f.status, initcap(f.status)),
        'status_tone',   _triage_status_tone(f.status),
        'found_label',   _triage_ago(f.found_at),
        'seen_label',    CASE WHEN f.seen_count > 1
                              THEN 'seen '||f.seen_count||' times' ELSE NULL END,
        'repro_count',   jsonb_array_length(f.repro),
        'repro_label',   _triage_copy('triage.repro','Repro steps'),
        'repro_hide_label', _triage_copy('triage.repro_hide','Hide steps'),
        'repro',         f.repro,
        'has_shot',      (f.shot_path IS NOT NULL),
        'shot_bucket',   f.shot_bucket,
        'shot_path',     f.shot_path,
        -- Approve / Reject exist only while the row is Om's to decide.
        'can_decide',    (f.status IN ('new','reopened')),
        'approve_label', _triage_copy('triage.approve','Approve'),
        'reject_label',  _triage_copy('triage.reject','Reject'),
        'reject_hint',   _triage_copy('triage.reject_reason_hint','Why is this not a real problem?'),
        'fix_command',   f.fix_command,
        'fix_label',     CASE WHEN f.fix_command IS NOT NULL
                              THEN 'Fix #'||f.fix_command ELSE NULL END,
        'reopen_count',  f.reopen_count,
        'reopen_label',  CASE WHEN f.reopen_count > 0
                              THEN 'reopened '||f.reopen_count||'×' ELSE NULL END,
        'escalate_note', CASE WHEN f.status = 'escalated'
                              THEN coalesce(f.escalate_reason,
                                   _triage_copy('triage.escalate_note','Needs a human decision.'))
                              ELSE NULL END,
        'reject_reason', f.reject_reason,
        'verify_detail', f.verify_detail
      ) AS r
    FROM triage_finding f
    WHERE (p_status   IS NULL OR f.status   = p_status)
      AND (p_surface  IS NULL OR f.surface  = p_surface)
      AND (p_severity IS NULL OR f.severity = p_severity)
    ORDER BY r_sev, r_found DESC
    LIMIT v_lim OFFSET greatest(coalesce(p_offset,0),0)
  ) q;

  RETURN jsonb_build_object(
    'has',       true,
    'title',     _triage_copy('triage.title','Triage'),
    'subtitle',  _triage_copy('triage.subtitle',''),
    'rows',      v_rows,
    'total',     v_total,
    'has_more',  (greatest(coalesce(p_offset,0),0) + v_lim) < v_total,
    'next_offset', greatest(coalesce(p_offset,0),0) + v_lim,
    'empty',      _triage_copy('triage.empty','Nothing waiting.'),
    'empty_hint', _triage_copy('triage.empty_hint',''),
    'status_tabs', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'key', s.k, 'label', _triage_copy('triage.st.'||s.k, initcap(s.k)),
               'count', (SELECT count(*) FROM triage_finding t WHERE t.status = s.k),
               'selected', (s.k = coalesce(p_status,'new'))) ORDER BY s.o), '[]'::jsonb)
        FROM (VALUES ('new',1),('approved',2),('queued',3),('verifying',4),
                     ('reopened',5),('escalated',6),('fixed',7),('rejected',8)) AS s(k,o)),
    -- Bulk-approve by surface or by severity: the backend names the batch,
    -- the phone just prints and taps it. Nothing is approved by listing it.
    'bulk_surface_label',  _triage_copy('triage.bulk_by_surface','Approve all on this surface'),
    'bulk_severity_label', _triage_copy('triage.bulk_by_severity','Approve all at this severity'),
    'bulk_surfaces', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'surface', x.surface, 'label', x.surface||' · '||x.n,
               'count', x.n) ORDER BY x.n DESC, x.surface), '[]'::jsonb)
        FROM (SELECT surface, count(*) n FROM triage_finding
               WHERE status IN ('new','reopened') AND surface IS NOT NULL
               GROUP BY surface) x),
    'bulk_severities', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'severity', y.severity,
               'label', _triage_copy('triage.sev.'||y.severity, initcap(y.severity))||' · '||y.n,
               'tone', _triage_tone(y.severity),
               'count', y.n)
             ORDER BY CASE y.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                                      WHEN 'medium' THEN 3 ELSE 4 END), '[]'::jsonb)
        FROM (SELECT severity, count(*) n FROM triage_finding
               WHERE status IN ('new','reopened') GROUP BY severity) y)
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.triage_finding_detail(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE f triage_finding; 
BEGIN
  PERFORM _dev_guard();
  SELECT * INTO f FROM triage_finding WHERE id = p_id;
  IF f.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'That finding is gone.');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'id', f.id,
    'plain_line', f.plain_line,
    'detail', f.detail,
    'repro', f.repro,
    'repro_label', _triage_copy('triage.repro','Repro steps'),
    'scenario', f.scenario,
    'source_label', _triage_copy('triage.src.'||f.source, initcap(f.source)),
    'status_label', _triage_copy('triage.st.'||f.status, initcap(f.status)),
    'status_tone',  _triage_status_tone(f.status),
    'has_shot', (f.shot_path IS NOT NULL),
    'shot_bucket', f.shot_bucket, 'shot_path', f.shot_path,
    'attempted_fixes', to_jsonb(f.attempted_fixes),
    'timeline', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'kind', e.kind, 'detail', e.detail, 'actor', e.actor,
                    'command_id', e.command_id, 'when', _triage_ago(e.at))
                  ORDER BY e.at DESC), '[]'::jsonb)
                 FROM triage_event e WHERE e.finding_id = f.id));
END $fn$;

-- GUARD RAIL #1 — approve is a PERSON. _triage_human() refuses service_role,
-- so no bot, cron job or runner can approve its own finding.
CREATE OR REPLACE FUNCTION public.triage_approve(p_ids bigint[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_actor text; v_n int;
BEGIN
  v_actor := _triage_human();
  WITH upd AS (
    UPDATE triage_finding SET status='approved', approved_at=now(), approved_by=v_actor
     WHERE id = ANY(p_ids) AND status IN ('new','reopened')
    RETURNING id)
  SELECT count(*) INTO v_n FROM upd;
  INSERT INTO triage_event(finding_id, kind, actor, detail)
    SELECT id, 'approved', v_actor, 'approved on the phone'
      FROM triage_finding WHERE id = ANY(p_ids) AND status='approved' AND approved_at > now()-interval '5 seconds';
  RETURN jsonb_build_object('ok', true, 'approved', v_n,
    'message', v_n||' approved — a fix command will be generated.');
END $fn$;

CREATE OR REPLACE FUNCTION public.triage_reject(p_ids bigint[], p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_actor text; v_n int;
BEGIN
  v_actor := _triage_human();
  IF coalesce(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION '%', _triage_copy('triage.reject_needs_reason','A rejection needs a reason.');
  END IF;
  WITH upd AS (
    UPDATE triage_finding
       SET status='rejected', rejected_at=now(), reject_reason=btrim(p_reason)
     WHERE id = ANY(p_ids) AND status IN ('new','reopened','approved')
    RETURNING id)
  SELECT count(*) INTO v_n FROM upd;
  INSERT INTO triage_event(finding_id, kind, actor, detail)
    SELECT id, 'rejected', v_actor, btrim(p_reason)
      FROM triage_finding WHERE id = ANY(p_ids) AND status='rejected'
        AND rejected_at > now()-interval '5 seconds';
  RETURN jsonb_build_object('ok', true, 'rejected', v_n,
    'message', v_n||' rejected — the bot will not re-file these.');
END $fn$;

-- Bulk approve by surface OR severity. Still a person, still one deliberate tap.
CREATE OR REPLACE FUNCTION public.triage_approve_bulk(
  p_surface text DEFAULT NULL, p_severity text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_ids bigint[];
BEGIN
  PERFORM _triage_human();     -- refuse bots before doing anything
  IF p_surface IS NULL AND p_severity IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'message', _triage_copy('triage.bulk_none','Nothing selected'));
  END IF;
  SELECT coalesce(array_agg(id), '{}') INTO v_ids FROM triage_finding
   WHERE status IN ('new','reopened')
     AND (p_surface  IS NULL OR surface  = p_surface)
     AND (p_severity IS NULL OR severity = p_severity);
  RETURN triage_approve(v_ids);
END $fn$;

-- ─────────────────────────────────────────────────────────────
-- 6. AUTO-COMMAND GENERATION
--    Small batches, explicit row ids in the title, per-row proof,
--    overlaps chained by the conflict scheduler instead of duplicated.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.triage_config (
  id               int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  batch_min        int  NOT NULL DEFAULT 2,
  batch_max        int  NOT NULL DEFAULT 6,
  solo_after_min   int  NOT NULL DEFAULT 30,   -- a lone approved row waits this long for company
  max_open_batches int  NOT NULL DEFAULT 4,    -- never flood the queue
  reopen_limit     int  NOT NULL DEFAULT 2,    -- guard rail #3
  enabled          boolean NOT NULL DEFAULT true,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.triage_config ENABLE ROW LEVEL SECURITY;
INSERT INTO public.triage_config(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- A batch is what a fix command WILL be. The dev queue lives on the control
-- plane (medibo-dev); production cannot insert into it, so generation stops at
-- a ready-made title + spec and `scripts/triage_bridge.sh` posts it through
-- dev_cmd_bulk_add and binds the real command id back with triage_batch_bind().
CREATE TABLE IF NOT EXISTS public.triage_batch (
  id           bigserial PRIMARY KEY,
  area         text,
  title        text        NOT NULL,
  spec         text        NOT NULL,
  finding_ids  bigint[]    NOT NULL,
  urgent       boolean     NOT NULL DEFAULT false,
  status       text        NOT NULL DEFAULT 'ready',   -- ready|sent|closed|failed
  command_id   bigint,
  note         text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  sent_at      timestamptz,
  closed_at    timestamptz
);
CREATE INDEX IF NOT EXISTS triage_batch_status_idx ON public.triage_batch(status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS triage_batch_cmd_uq
  ON public.triage_batch(command_id) WHERE command_id IS NOT NULL;
ALTER TABLE public.triage_batch ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.triage_generate_commands()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  cfg triage_config; grp record; v_ids bigint[]; v_batch bigint; v_spec text;
  v_title text; v_area text; v_open int; v_made int := 0; v_attached int := 0;
  v_row record; n int;
BEGIN
  PERFORM _dev_guard();
  SELECT * INTO cfg FROM triage_config WHERE id = 1;
  IF NOT cfg.enabled THEN
    RETURN jsonb_build_object('ok', true, 'made', 0, 'reason', 'generation is off');
  END IF;

  -- Never flood the queue: count batches still in flight.
  SELECT count(*) INTO v_open FROM triage_batch WHERE status IN ('ready','sent');
  IF v_open >= cfg.max_open_batches THEN
    RETURN jsonb_build_object('ok', true, 'made', 0,
      'reason', v_open||' fix batches already open — waiting for the queue');
  END IF;

  -- ATTACH, DON'T DUPLICATE. An approved row whose surface is already being
  -- fixed joins THAT batch rather than opening a second command for it.
  FOR v_row IN
    SELECT f.id, f.surface, f.plain_line,
           (SELECT b.id FROM triage_finding g JOIN triage_batch b ON b.id = g.batch_id
             WHERE g.surface IS NOT DISTINCT FROM f.surface
               AND b.status IN ('ready','sent')
             ORDER BY b.id DESC LIMIT 1) AS open_batch
      FROM triage_finding f
     WHERE f.status = 'approved'
  LOOP
    IF v_row.open_batch IS NOT NULL THEN
      UPDATE triage_finding
         SET status='queued', queued_at=now(), batch_id=v_row.open_batch,
             fix_command=(SELECT command_id FROM triage_batch WHERE id=v_row.open_batch)
       WHERE id = v_row.id;
      UPDATE triage_batch
         SET finding_ids = array(SELECT DISTINCT unnest(finding_ids || v_row.id)),
             spec = spec||E'\n\nALSO (joined after this batch was cut) ROW #'||v_row.id
                    ||' — '||v_row.plain_line
       WHERE id = v_row.open_batch;
      INSERT INTO triage_event(finding_id, kind, actor, detail)
      VALUES (v_row.id, 'queued',
              'triage', 'joined the open fix for '||coalesce(v_row.surface,'this surface')
              ||' instead of opening a second command');
      v_attached := v_attached + 1;
    END IF;
  END LOOP;

  -- BATCH the rest: one command per area, 2..batch_max rows.
  FOR grp IN
    SELECT coalesce(f.area, f.surface, 'app') AS gkey,
           count(*) AS n, min(f.approved_at) AS oldest,
           bool_or(f.severity = 'critical') AS has_critical
      FROM triage_finding f
     WHERE f.status = 'approved'
     GROUP BY 1
     ORDER BY bool_or(f.severity='critical') DESC, min(f.approved_at)
  LOOP
    EXIT WHEN v_open + v_made >= cfg.max_open_batches;

    -- A lone row waits for company unless it is critical or has waited long enough.
    IF grp.n < cfg.batch_min
       AND NOT grp.has_critical
       AND grp.oldest > now() - make_interval(mins => cfg.solo_after_min)
    THEN CONTINUE; END IF;

    SELECT coalesce(array_agg(id ORDER BY sev_rank, approved_at), '{}') INTO v_ids
      FROM (SELECT f.id, f.approved_at,
                   CASE f.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                                   WHEN 'medium' THEN 3 ELSE 4 END AS sev_rank
              FROM triage_finding f
             WHERE f.status='approved' AND coalesce(f.area, f.surface, 'app') = grp.gkey
             ORDER BY sev_rank, f.approved_at
             LIMIT cfg.batch_max) s;

    IF coalesce(array_length(v_ids,1),0) = 0 THEN CONTINUE; END IF;
    SELECT f.area INTO v_area FROM triage_finding f WHERE f.id = v_ids[1];

    -- EXPLICIT ROW IDS IN THE TITLE — the card names exactly what it fixes.
    v_title := 'Triage fix '||
               (SELECT string_agg('#'||x::text, ',' ORDER BY x) FROM unnest(v_ids) x)
               ||' — '||grp.gkey;

    v_spec := 'AUTO-GENERATED from approved triage findings. Om approved every row below on the phone.'
      ||E'\n\nFix each row. PER-ROW PROOF IS REQUIRED: the bot re-runs each scenario after you complete,'
      ||E'\nand only a green re-run marks that row done. A row that still fails REOPENS and links this'
      ||E'\ncommand as an attempted fix — so do not report a row fixed that you have not actually fixed.'
      ||E'\n\nIf a row is a FALSE POSITIVE, do not "fix" it: reject it with a reason —'
      ||E'\n  select triage_reject_by_runner(<row id>, ''<why it is not real>'');   (production DB)'
      ||E'\n\nROWS:';

    n := 0;
    FOR v_row IN SELECT * FROM triage_finding WHERE id = ANY(v_ids) ORDER BY id LOOP
      n := n + 1;
      v_spec := v_spec
        ||E'\n\n'||n||') ROW #'||v_row.id||'  ['||upper(v_row.severity)||' · '||v_row.source||']'
        ||E'\n   Surface: '||coalesce(v_row.surface,'-')
        ||E'\n   '||v_row.plain_line
        ||E'\n   Repro:'
        ||coalesce((SELECT string_agg(E'\n     - '||(value#>>'{}'), '')
                      FROM jsonb_array_elements(v_row.repro)), E'\n     - (no steps recorded)')
        ||E'\n   Re-run scenario: '||v_row.scenario::text
        ||coalesce(E'\n   Detail: '||left(v_row.detail, 500), '');
    END LOOP;
    v_spec := v_spec||E'\n\nRun rg_check().';

    INSERT INTO triage_batch(area, title, spec, finding_ids, urgent)
    VALUES (v_area, left(v_title, 200), v_spec, v_ids, grp.has_critical)
    RETURNING id INTO v_batch;

    UPDATE triage_finding
       SET status='queued', queued_at=now(), batch_id=v_batch
     WHERE id = ANY(v_ids);

    INSERT INTO triage_event(finding_id, kind, actor, detail)
      SELECT id, 'queued', 'triage', 'batched into fix batch '||v_batch
        FROM triage_finding WHERE id = ANY(v_ids);

    v_made := v_made + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'made', v_made, 'attached', v_attached,
    'still_approved', (SELECT count(*) FROM triage_finding WHERE status='approved'));
END $fn$;

-- What the bridge posts to the control plane. Shaped for dev_cmd_bulk_add.
-- GUARD RAIL #2: qa_required is never sent as false — an auto-generated fix
-- goes through the same QA, journey and screenshot gates as anything Om typed.
CREATE OR REPLACE FUNCTION public.triage_batch_pending(p_limit int DEFAULT 4)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
BEGIN
  PERFORM _dev_guard();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'batch_id', b.id,
            'item', jsonb_build_object(
              'title',  b.title,
              'spec',   b.spec,
              'kind',   'dev',
              'area',   b.area,
              'urgent', b.urgent)) ORDER BY b.id), '[]'::jsonb)
          FROM (SELECT * FROM triage_batch WHERE status='ready'
                 ORDER BY id LIMIT greatest(coalesce(p_limit,4),1)) b);
END $fn$;

-- The bridge reports back what the control plane called it.
CREATE OR REPLACE FUNCTION public.triage_batch_bind(p_batch_id bigint, p_command_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_ids bigint[];
BEGIN
  PERFORM _dev_guard();
  UPDATE triage_batch SET status='sent', command_id=p_command_id, sent_at=now()
   WHERE id = p_batch_id AND status='ready'
  RETURNING finding_ids INTO v_ids;
  IF v_ids IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'batch '||p_batch_id||' is not waiting to be sent');
  END IF;
  UPDATE triage_finding SET fix_command = p_command_id WHERE id = ANY(v_ids);
  INSERT INTO triage_event(finding_id, kind, actor, detail, command_id)
    SELECT id, 'queued', 'bridge', 'fix command opened on the dev queue', p_command_id
      FROM triage_finding WHERE id = ANY(v_ids);
  RETURN jsonb_build_object('ok', true, 'batch', p_batch_id, 'command', p_command_id,
                            'rows', coalesce(array_length(v_ids,1),0));
END $fn$;

CREATE OR REPLACE FUNCTION public.triage_batch_fail(p_batch_id bigint, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_ids bigint[];
BEGIN
  PERFORM _dev_guard();
  UPDATE triage_batch SET status='failed', note=left(coalesce(p_note,''),500), closed_at=now()
   WHERE id = p_batch_id AND status='ready'
  RETURNING finding_ids INTO v_ids;
  IF v_ids IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'nothing to fail');
  END IF;
  -- The rows go back to Om's approved pile; they are not lost and not "fixed".
  UPDATE triage_finding SET status='approved', batch_id=NULL, queued_at=NULL
   WHERE id = ANY(v_ids) AND status='queued';
  RETURN jsonb_build_object('ok', true, 'returned', coalesce(array_length(v_ids,1),0));
END $fn$;

-- The control-plane command finished: its rows are now the bot's to re-check.
-- Which control-plane commands the bridge still has to watch.
CREATE OR REPLACE FUNCTION public.triage_batch_open_commands()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
BEGIN
  PERFORM _dev_guard();
  RETURN (SELECT coalesce(jsonb_agg(DISTINCT command_id), '[]'::jsonb)
            FROM triage_batch WHERE status='sent' AND command_id IS NOT NULL);
END $fn$;

CREATE OR REPLACE FUNCTION public.triage_batch_completed(p_command_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
BEGIN
  PERFORM _dev_guard();
  UPDATE triage_batch SET status='closed', closed_at=now()
   WHERE command_id = p_command_id AND status='sent';
  UPDATE triage_finding
     SET status='verifying', verify_status=NULL,
         verify_detail='the bot is re-running this scenario'
   WHERE fix_command = p_command_id AND status='queued';
  RETURN triage_reverify(p_command_id);
END $fn$;

-- The runner's escape hatch for a false positive it meets while fixing a batch.
CREATE OR REPLACE FUNCTION public.triage_reject_by_runner(p_id bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
BEGIN
  PERFORM _dev_guard();
  IF coalesce(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION '%', _triage_copy('triage.reject_needs_reason','A rejection needs a reason.');
  END IF;
  UPDATE triage_finding
     SET status='rejected', rejected_at=now(),
         reject_reason='false positive (runner): '||btrim(p_reason)
   WHERE id = p_id AND status IN ('queued','verifying','reopened');
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'That row is not in a fix batch.');
  END IF;
  INSERT INTO triage_event(finding_id, kind, actor, detail)
  VALUES (p_id, 'rejected', 'runner', btrim(p_reason));
  RETURN jsonb_build_object('ok', true, 'message', 'Row #'||p_id||' recorded as a false positive.');
END $fn$;

-- ─────────────────────────────────────────────────────────────
-- 7. RE-VERIFY — the bot re-runs THAT EXACT scenario.
--    Only a green re-run marks a row done. A still-failing case reopens.
-- ─────────────────────────────────────────────────────────────

-- Re-runs one finding's own scenario. Returns
--   {verdict: 'green'|'red'|'unknown', detail: text}
-- 'unknown' is honest: it never counts as green, so a row can never be
-- reported fixed because the checker could not check it.
CREATE OR REPLACE FUNCTION public._triage_rerun(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  f triage_finding; k text; v_out jsonb; v_n bigint; v_sample text;
  v_sql text; v_obs text; v_exp text; v_err text;
BEGIN
  SELECT * INTO f FROM triage_finding WHERE id = p_id;
  IF f.id IS NULL THEN
    RETURN jsonb_build_object('verdict','unknown','detail','the finding is gone');
  END IF;
  k := f.scenario->>'kind';

  IF k = 'journey' THEN
    BEGIN
      v_out := dev_journey_probe(f.scenario->>'name');
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('verdict','red','detail','the journey threw: '||SQLERRM);
    END;
    IF coalesce(v_out->>'status','') = 'passed' THEN
      RETURN jsonb_build_object('verdict','green','detail','journey "'||(f.scenario->>'name')||'" passes again');
    ELSIF coalesce(v_out->>'status','') = 'skipped' THEN
      RETURN jsonb_build_object('verdict','unknown',
        'detail','journey "'||(f.scenario->>'name')||'" could not run: '||left(coalesce(v_out->>'evidence',''),200));
    END IF;
    RETURN jsonb_build_object('verdict','red',
      'detail','journey "'||(f.scenario->>'name')||'" still fails: '||left(coalesce(v_out->>'evidence',''),300));

  ELSIF k = 'invariant' THEN
    SELECT i.check_sql INTO v_sql FROM autotest_invariant i WHERE i.key = f.scenario->>'key';
    IF v_sql IS NULL THEN
      RETURN jsonb_build_object('verdict','unknown','detail','that data rule no longer exists');
    END IF;
    BEGIN
      EXECUTE v_sql INTO v_n, v_sample;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('verdict','unknown','detail','the rule could not be evaluated: '||SQLERRM);
    END;
    IF coalesce(v_n,0) = 0 THEN
      RETURN jsonb_build_object('verdict','green','detail','the rule holds again — 0 rows break it');
    END IF;
    RETURN jsonb_build_object('verdict','red',
      'detail', v_n||' row(s) still break this rule: '||left(coalesce(v_sample,''),200));

  ELSIF k IN ('auth','fuzz') THEN
    BEGIN
      v_out := _autotest_call_as(f.scenario->>'proname', f.scenario->>'role_key',
                 CASE WHEN k='fuzz'
                      THEN (SELECT c.args_sql FROM autotest_fuzz_case c
                             WHERE c.id = (f.scenario->>'case_id')::bigint)
                      ELSE NULL END)::jsonb;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('verdict','red','detail','the call still blows up: '||SQLERRM);
    END;
    -- The matrix's own vocabulary, not a second one invented here:
    -- outcome 'reached' is observed 'allow', 'refused' is observed 'deny'.
    v_obs := CASE v_out->>'outcome' WHEN 'reached' THEN 'allow'
                                    WHEN 'refused' THEN 'deny' END;

    IF k = 'auth' THEN
      IF v_out->>'outcome' = 'probe_blocked' OR v_obs IS NULL THEN
        RETURN jsonb_build_object('verdict','unknown',
          'detail','the permission probe could not run: '||coalesce(v_out->>'outcome','?'));
      END IF;
      SELECT a.expected INTO v_exp FROM autotest_auth_check a
       WHERE a.proname = f.scenario->>'proname' AND a.role_key = f.scenario->>'role_key'
       ORDER BY a.checked_at DESC LIMIT 1;
      IF v_exp IS NULL THEN
        RETURN jsonb_build_object('verdict','unknown','detail','that permission row is no longer in the matrix');
      END IF;
      IF v_obs = v_exp THEN
        RETURN jsonb_build_object('verdict','green',
          'detail','role '||(f.scenario->>'role_key')||' now gets "'||v_obs||'" from '||(f.scenario->>'proname')||', as it should');
      END IF;
      RETURN jsonb_build_object('verdict','red',
        'detail','role '||(f.scenario->>'role_key')||' still gets "'||v_obs||'" instead of "'||v_exp||'"');
    END IF;

    -- FUZZ. A crash or a timeout is red; a deliberate refusal is green.
    -- The two ASSERTION failures (negative money, cross-tenant leak) are not
    -- re-judged here — that needs the fuzz engine's own assertions — so they
    -- stay 'unknown' and can never be reported fixed by this checker.
    IF v_out->>'outcome' = 'probe_blocked' THEN
      RETURN jsonb_build_object('verdict','unknown','detail','the fuzz probe could not run');
    END IF;
    IF (SELECT r.assertion FROM autotest_fuzz_result r
         WHERE r.case_id = (f.scenario->>'case_id')::bigint
         ORDER BY r.ran_at DESC LIMIT 1) IS NOT NULL
    THEN
      RETURN jsonb_build_object('verdict','unknown',
        'detail','this one failed an assertion, not a crash — the next full fuzz run judges it');
    END IF;
    IF left(coalesce(v_out->>'sqlstate',''), 2) IN ('XX','58','53','25') THEN
      RETURN jsonb_build_object('verdict','red',
        'detail','the call still crashes with SQLSTATE '||(v_out->>'sqlstate'));
    END IF;
    RETURN jsonb_build_object('verdict','green',
      'detail','the call answers or refuses cleanly now (SQLSTATE '||coalesce(v_out->>'sqlstate','00000')||')');

  ELSIF k = 'visual' THEN
    -- A screen can only be re-checked by taking a new screenshot. Ask for one
    -- and stay 'unknown' until it lands — never green on an old picture.
    IF EXISTS (SELECT 1 FROM visual_shot s
                WHERE s.feature_key = f.scenario->>'feature_key'
                  AND s.role IS NOT DISTINCT FROM (f.scenario->>'role')
                  AND s.viewport IS NOT DISTINCT FROM (f.scenario->>'viewport')
                  AND s.id > (f.scenario->>'shot_id')::bigint
                  AND s.rule_key IS NULL)
    THEN
      RETURN jsonb_build_object('verdict','green','detail','a fresh screenshot of this screen is clean');
    ELSIF EXISTS (SELECT 1 FROM visual_shot s
                   WHERE s.feature_key = f.scenario->>'feature_key'
                     AND s.role IS NOT DISTINCT FROM (f.scenario->>'role')
                     AND s.viewport IS NOT DISTINCT FROM (f.scenario->>'viewport')
                     AND s.id > (f.scenario->>'shot_id')::bigint
                     AND s.rule_key IS NOT NULL)
    THEN
      RETURN jsonb_build_object('verdict','red','detail','the newest screenshot of this screen still trips the same rule');
    END IF;
    BEGIN
      PERFORM test_run_request_add('visual',
        jsonb_build_object('scope','feature','feature_key', f.scenario->>'feature_key'));
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN jsonb_build_object('verdict','unknown','detail','waiting for a fresh screenshot of this screen');

  ELSIF k = 'qa' THEN
    -- A hostile-QA finding is proven by the fix command's own QA round.
    IF f.fix_command IS NOT NULL
       AND (SELECT c.qa_status FROM dev_commands c WHERE c.id = f.fix_command) = 'passed'
    THEN RETURN jsonb_build_object('verdict','green','detail','hostile QA passed on the fix'); END IF;
    IF f.fix_command IS NOT NULL
       AND (SELECT c.qa_status FROM dev_commands c WHERE c.id = f.fix_command) = 'failed'
    THEN RETURN jsonb_build_object('verdict','red','detail','hostile QA failed again on the fix'); END IF;
    RETURN jsonb_build_object('verdict','unknown','detail','waiting for the QA round on the fix');
  END IF;

  RETURN jsonb_build_object('verdict','unknown','detail','no re-run is defined for this kind of finding');
END $fn$;

-- Re-verify every row a fix command claims to have fixed.
CREATE OR REPLACE FUNCTION public.triage_reverify(p_command_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  cfg triage_config; f record; res jsonb; v_v text;
  v_green int := 0; v_red int := 0; v_unknown int := 0; v_esc int := 0;
BEGIN
  PERFORM _dev_guard();
  SELECT * INTO cfg FROM triage_config WHERE id = 1;

  FOR f IN SELECT * FROM triage_finding
            WHERE fix_command = p_command_id AND status IN ('queued','verifying')
  LOOP
    res := _triage_rerun(f.id);
    v_v := res->>'verdict';

    IF v_v = 'green' THEN
      UPDATE triage_finding
         SET status='fixed', fixed_at=now(), verified_at=now(),
             verify_status='green', verify_detail=res->>'detail'
       WHERE id = f.id;
      INSERT INTO triage_event(finding_id, kind, actor, detail, command_id)
      VALUES (f.id, 'verified', 'bot', res->>'detail', p_command_id);
      v_green := v_green + 1;

    ELSIF v_v = 'red' THEN
      UPDATE triage_finding
         SET reopen_count   = f.reopen_count + 1,
             attempted_fixes= array(SELECT DISTINCT unnest(f.attempted_fixes || p_command_id)),
             verify_status  = 'red',
             verify_detail  = res->>'detail',
             verified_at    = now(),
             fixed_at       = NULL,
             fix_command    = NULL,
             -- GUARD RAIL #3: two reopens is the ceiling. The third loop never starts.
             status         = CASE WHEN f.reopen_count + 1 >= cfg.reopen_limit
                                   THEN 'escalated' ELSE 'reopened' END,
             escalated_at   = CASE WHEN f.reopen_count + 1 >= cfg.reopen_limit
                                   THEN now() ELSE NULL END,
             escalate_reason= CASE WHEN f.reopen_count + 1 >= cfg.reopen_limit
                                   THEN _triage_copy('triage.escalate_note','Needs a human decision.')
                                        ||' Attempted fixes: #'
                                        ||array_to_string(array(SELECT DISTINCT unnest(f.attempted_fixes || p_command_id)), ', #')
                                   ELSE NULL END
       WHERE id = f.id;

      INSERT INTO triage_event(finding_id, kind, actor, detail, command_id)
      VALUES (f.id, 'reopened', 'bot',
              'the fix did not fix it — '||coalesce(res->>'detail',''), p_command_id);


      v_red := v_red + 1;

      IF f.reopen_count + 1 >= cfg.reopen_limit THEN
        v_esc := v_esc + 1;
        INSERT INTO triage_event(finding_id, kind, actor, detail, command_id)
        VALUES (f.id, 'escalated', 'bot',
                'reopened '||(f.reopen_count+1)||'× — no further command will be generated', p_command_id);
        INSERT INTO rg_alerts(fingerprint, severity, kind, name, detail)
        VALUES ('triage-escalate-'||f.id, 'critical', 'triage', 'triage row #'||f.id||' reopened twice',
                jsonb_build_object('finding', f.id, 'surface', f.surface,
                                   'plain_line', f.plain_line,
                                   'attempted_fixes', array(SELECT DISTINCT unnest(f.attempted_fixes || p_command_id))))
        ON CONFLICT (fingerprint) DO UPDATE
          SET last_seen = now(), seen_count = rg_alerts.seen_count + 1;
      END IF;

    ELSE
      UPDATE triage_finding
         SET status='verifying', verify_status='unknown', verify_detail=res->>'detail'
       WHERE id = f.id;
      v_unknown := v_unknown + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'command', p_command_id,
    'fixed', v_green, 'reopened', v_red, 'still_checking', v_unknown, 'escalated', v_esc,
    -- The bridge posts this verbatim into the command's own thread.
    'message', CASE WHEN v_green + v_red + v_unknown = 0 THEN NULL
      ELSE '🔁 Triage re-verify: '||v_green||' row(s) proven fixed, '||v_red||' REOPENED'
           ||CASE WHEN v_unknown > 0 THEN ', '||v_unknown||' still being checked' ELSE '' END
           ||CASE WHEN v_esc > 0 THEN ' — '||v_esc||' escalated to Om after two failed fixes' ELSE '' END
           ||'.'||coalesce((SELECT string_agg(E'\n  • row #'||t.id||': '||coalesce(t.verify_detail,''), '')
                              FROM triage_finding t
                             WHERE t.fix_command = p_command_id OR p_command_id = ANY(t.attempted_fixes)), '')
      END);
END $fn$;

-- Cron entry point: re-verify every command with rows waiting on it.
CREATE OR REPLACE FUNCTION public.triage_reverify_pending(p_limit int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE c bigint; v_out jsonb := '[]'::jsonb; n int := 0;
BEGIN
  PERFORM _dev_guard();
  FOR c IN SELECT DISTINCT fix_command FROM triage_finding
            WHERE status='verifying' AND fix_command IS NOT NULL
            ORDER BY fix_command LIMIT greatest(coalesce(p_limit,5),1)
  LOOP
    v_out := v_out || triage_reverify(c);
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'commands', n, 'results', v_out);
END $fn$;

-- ─────────────────────────────────────────────────────────────
-- 8. TREND DASHBOARD — every number and every word is computed here.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.triage_trends(p_weeks int DEFAULT 8)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_w int := least(greatest(coalesce(p_weeks,8),1), 26);
  v_weeks jsonb; v_worst jsonb; v_total bigint; v_reopened bigint;
  v_mttf_s numeric; v_cov_num bigint; v_cov_den bigint; v_reopen_pct numeric;
BEGIN
  PERFORM _dev_guard();

  -- Found vs fixed, per ISO week, in IST.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'week_start', to_char(w.wk, 'DD Mon'),
           'found', w.found, 'fixed', w.fixed,
           'label', to_char(w.wk,'DD Mon')||' · '||w.found||' found / '||w.fixed||' fixed'
         ) ORDER BY w.wk), '[]'::jsonb)
    INTO v_weeks
  FROM (
    SELECT g.wk,
      (SELECT count(*) FROM triage_finding f
        WHERE date_trunc('week', f.found_at AT TIME ZONE 'Asia/Kolkata') = g.wk) AS found,
      (SELECT count(*) FROM triage_finding f
        WHERE f.fixed_at IS NOT NULL
          AND date_trunc('week', f.fixed_at AT TIME ZONE 'Asia/Kolkata') = g.wk) AS fixed
    FROM (SELECT generate_series(
            date_trunc('week', (now() AT TIME ZONE 'Asia/Kolkata') - make_interval(weeks => v_w - 1)),
            date_trunc('week', (now() AT TIME ZONE 'Asia/Kolkata')),
            interval '1 week') AS wk) g
  ) w;

  -- Worst surfaces: most open findings, reopens weighted.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'surface', s.surface,
           'open', s.open_n, 'reopened', s.reopen_n, 'total', s.total_n,
           'label', s.surface,
           'value', s.open_n||' open of '||s.total_n,
           'sub', CASE WHEN s.reopen_n > 0
                       THEN s.reopen_n||' came back after a fix' ELSE NULL END,
           'tone', CASE WHEN s.reopen_n > 0 THEN 'danger'
                        WHEN s.open_n > 0   THEN 'warning' ELSE 'neutral' END
         ) ORDER BY s.reopen_n DESC, s.open_n DESC, s.surface), '[]'::jsonb)
    INTO v_worst
  FROM (
    SELECT coalesce(surface,'app') AS surface,
           count(*) FILTER (WHERE status IN ('new','approved','queued','verifying','reopened','escalated')) AS open_n,
           count(*) FILTER (WHERE reopen_count > 0) AS reopen_n,
           count(*) AS total_n
      FROM triage_finding GROUP BY 1
     ORDER BY 3 DESC, 2 DESC LIMIT 5
  ) s;

  SELECT count(*), count(*) FILTER (WHERE reopen_count > 0)
    INTO v_total, v_reopened FROM triage_finding
   WHERE status <> 'rejected';

  v_reopen_pct := CASE WHEN coalesce(v_total,0) = 0 THEN NULL
                       ELSE round(100.0 * v_reopened / v_total, 1) END;

  SELECT avg(extract(epoch FROM (fixed_at - found_at)))
    INTO v_mttf_s FROM triage_finding WHERE fixed_at IS NOT NULL;

  -- Coverage comes from the ledger, not from a number typed here.
  SELECT count(*) FILTER (WHERE has_contract AND NOT coalesce(never_tested,false)), count(*)
    INTO v_cov_num, v_cov_den FROM test_coverage;

  RETURN jsonb_build_object(
    'has', true,
    'title', _triage_copy('triage.trend.title','Trend'),
    'weeks_label', _triage_copy('triage.trend.found_fixed','Found vs fixed'),
    'weeks', v_weeks,
    'worst_label', _triage_copy('triage.trend.worst','Worst surfaces'),
    'worst', v_worst,
    'empty', _triage_copy('triage.trend.empty','Not enough history yet.'),
    'stats', jsonb_build_array(
      jsonb_build_object(
        'label', _triage_copy('triage.trend.reopen','Reopen rate'),
        'value', CASE WHEN v_reopen_pct IS NULL THEN '—' ELSE v_reopen_pct||'%' END,
        'sub',   CASE WHEN v_total = 0 THEN NULL
                      ELSE v_reopened||' of '||v_total||' came back' END,
        'tone',  CASE WHEN v_reopen_pct IS NULL THEN 'neutral'
                      WHEN v_reopen_pct >= 25 THEN 'danger'
                      WHEN v_reopen_pct >= 10 THEN 'warning' ELSE 'success' END),
      jsonb_build_object(
        'label', _triage_copy('triage.trend.mttf','Find to fixed'),
        'value', CASE WHEN v_mttf_s IS NULL THEN '—'
                      WHEN v_mttf_s < 3600  THEN round(v_mttf_s/60)||' min'
                      WHEN v_mttf_s < 86400 THEN round(v_mttf_s/3600,1)||' h'
                      ELSE round(v_mttf_s/86400,1)||' days' END,
        'sub',   CASE WHEN v_mttf_s IS NULL THEN 'nothing has completed the loop yet'
                      ELSE 'average across '||(SELECT count(*) FROM triage_finding WHERE fixed_at IS NOT NULL)||' fixed' END,
        'tone',  'neutral'),
      jsonb_build_object(
        'label', _triage_copy('triage.trend.coverage','Coverage'),
        'value', CASE WHEN coalesce(v_cov_den,0) = 0 THEN '—'
                      ELSE round(100.0 * v_cov_num / v_cov_den)||'%' END,
        'sub',   CASE WHEN coalesce(v_cov_den,0) = 0 THEN 'the ledger is empty'
                      ELSE v_cov_num||' of '||v_cov_den||' features have a contract' END,
        'tone',  CASE WHEN coalesce(v_cov_den,0) = 0 THEN 'neutral'
                      WHEN (100.0 * v_cov_num / v_cov_den) >= 80 THEN 'success'
                      WHEN (100.0 * v_cov_num / v_cov_den) >= 50 THEN 'warning'
                      ELSE 'danger' END),
      jsonb_build_object(
        'label', 'Waiting for you',
        'value', (SELECT count(*) FROM triage_finding WHERE status IN ('new','reopened'))::text,
        'sub',   CASE WHEN (SELECT count(*) FROM triage_finding WHERE status='escalated') > 0
                      THEN (SELECT count(*) FROM triage_finding WHERE status='escalated')||' escalated'
                      ELSE NULL END,
        'tone',  CASE WHEN (SELECT count(*) FROM triage_finding WHERE status='escalated') > 0
                      THEN 'danger'
                      WHEN (SELECT count(*) FROM triage_finding WHERE status IN ('new','reopened')) > 0
                      THEN 'warning' ELSE 'success' END)
    ));
END $fn$;

-- ─────────────────────────────────────────────────────────────
-- 9. THE LOOP RUNS ITSELF (cron dispatcher; never a bare */N schedule)
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.cron_task(name, ord, mode, work_sql, base_interval_s, enabled, dml, note)
VALUES
  ('c639_triage_intake',   662, 'poll', 'select public.triage_intake(200)',        900, true, true,
   'CHANGE #639 — the bot''s findings become inbox rows. Never approves anything.'),
  ('c639_triage_generate', 663, 'poll', 'select public.triage_generate_commands()', 600, true, true,
   'CHANGE #639 — approved rows batch into fix commands. Approval is a person''s tap.'),
  ('c639_triage_reverify', 664, 'poll', 'select public.triage_reverify_pending(5)', 300, true, true,
   'CHANGE #639 — re-runs the exact scenario behind every completed fix.')
ON CONFLICT (name) DO UPDATE
  SET work_sql = EXCLUDED.work_sql,
      base_interval_s = EXCLUDED.base_interval_s,
      mode = EXCLUDED.mode,
      note = EXCLUDED.note;

-- ─────────────────────────────────────────────────────────────
-- 10. GRANTS
-- ─────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.triage_inbox(text,text,text,int,int)      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.triage_finding_detail(bigint)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.triage_approve(bigint[])                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.triage_reject(bigint[],text)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.triage_approve_bulk(text,text)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.triage_trends(int)                        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.triage_intake(int)                        TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_generate_commands()                TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_reverify(bigint)                   TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_reverify_pending(int)              TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_reject_by_runner(bigint,text)      TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_batch_pending(int)                 TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_batch_bind(bigint,bigint)          TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_batch_fail(bigint,text)            TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_batch_completed(bigint)            TO service_role;
GRANT EXECUTE ON FUNCTION public.triage_batch_open_commands()              TO service_role;

-- ─────────────────────────────────────────────────────────────
-- 11. THE TOOL ROW — Triage is reachable, or it does not exist (§11)
--
-- `dev_tools()` reads feature_registry on the CONTROL PLANE, so the row that
-- actually lights the tile up is applied there (supabase/dev/c639_triage_tool.sql).
-- This copy keeps production's registry in step and is what
-- test/protected/dev_tools_registry_test.dart reads: a tool this build can open
-- must be registered by a migration, and a registered tool must be openable.
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key,
   sort_order, owner, partner_eligible, default_access, is_active, category,
   surface, roles_allowed, deep_link, search_terms, badge_source, badge_noun)
VALUES
  ('devtool.triage','Triage',
   'Approve what the bots found — fixes generate themselves','Proof & QA','fact_check',
   'triage',15,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],'/admin/go/triage',
   'triage inbox findings approve reject bot fix reopen trend coverage',null,null)
ON CONFLICT (feature_key) DO UPDATE
  SET label         = EXCLUDED.label,
      description   = EXCLUDED.description,
      group_label   = EXCLUDED.group_label,
      icon_key      = EXCLUDED.icon_key,
      route_key     = EXCLUDED.route_key,
      sort_order    = EXCLUDED.sort_order,
      surface       = EXCLUDED.surface,
      is_active     = true,
      roles_allowed = EXCLUDED.roles_allowed,
      search_terms  = EXCLUDED.search_terms,
      deep_link     = EXCLUDED.deep_link;

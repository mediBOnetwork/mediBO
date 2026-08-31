-- CHANGE #327 · the guard and the surface.
--
-- god_file_debt is the LAYER 1 guard's memory: one row per Dart file that is
-- either over the line threshold or owning more than one concern. It is a
-- warn-level rg_alerts entry, never a deploy gate — the three biggest files in
-- this repo are 13–15k-line admin screens, and failing the build on them would
-- block every deploy tomorrow instead of paying the debt down deliberately.
create table if not exists god_file_debt (
  path        text primary key,
  lines       int  not null,
  declarations int not null default 0,
  concerns    text[] not null default '{}',
  oversize    boolean not null default false,
  multi_concern boolean not null default false,
  reason      text not null,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);
alter table god_file_debt enable row level security;
drop policy if exists god_file_debt_no_public on god_file_debt;
create policy god_file_debt_no_public on god_file_debt for select using (false);

create or replace function public.dev_god_files_report(p_report jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_n int; v_gone int; r record;
BEGIN
  PERFORM _dev_guard();

  INSERT INTO god_file_debt (path, lines, declarations, concerns, oversize, multi_concern, reason, last_seen)
  SELECT f->>'path', (f->>'lines')::int, coalesce((f->>'declarations')::int,0),
         coalesce((SELECT array_agg(c) FROM jsonb_array_elements_text(f->'concerns') c), '{}'),
         coalesce((f->>'oversize')::boolean,false), coalesce((f->>'multi_concern')::boolean,false),
         f->>'reason', now()
  FROM jsonb_array_elements(coalesce(p_report->'files','[]'::jsonb)) f
  ON CONFLICT (path) DO UPDATE SET
    lines = excluded.lines, declarations = excluded.declarations,
    concerns = excluded.concerns, oversize = excluded.oversize,
    multi_concern = excluded.multi_concern, reason = excluded.reason,
    last_seen = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- A file that stopped being a god-file (it was sharded) leaves the list.
  DELETE FROM god_file_debt
   WHERE path NOT IN (SELECT f->>'path' FROM jsonb_array_elements(coalesce(p_report->'files','[]'::jsonb)) f);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  -- Flagged in rg, as tech debt: warn severity, so it is visible and never a gate.
  FOR r IN SELECT * FROM god_file_debt ORDER BY lines DESC LIMIT 25 LOOP
    INSERT INTO rg_alerts (fingerprint, severity, kind, name, detail)
    VALUES (md5('god_file|'||r.path), 'warn', 'god_file', r.path,
            jsonb_build_object('lines', r.lines, 'concerns', to_jsonb(r.concerns), 'reason', r.reason))
    ON CONFLICT (fingerprint) DO UPDATE
      SET last_seen = now(), seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'flagged', v_n, 'cleared', v_gone,
                            'scanned', coalesce((p_report->>'scanned')::int, 0));
END $$;

-- ── The Build lane read model ───────────────────────────────────────────────
-- Same shape as deploy_lane_status(): the widget renders sections in payload
-- order and decides nothing. Every label, every count sentence, every empty
-- hint and every tone name is built here.
create or replace function public.build_contention_status(p_days int default 7)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE
  v_conf int; v_def int; v_grant int; v_chained int; v_debt int; v_debt_lines bigint;
  v_since timestamptz; v_hot jsonb; v_chains jsonb; v_debt_rows jsonb; v_live jsonb;
BEGIN
  PERFORM _dev_guard();
  v_since := now() - make_interval(days => greatest(coalesce(p_days,7),1));

  SELECT count(*) FILTER (WHERE kind='conflict'),
         count(*) FILTER (WHERE kind='deferred'),
         count(*) FILTER (WHERE kind='granted')
    INTO v_conf, v_def, v_grant
  FROM lease_event WHERE at >= v_since;

  SELECT count(*) INTO v_chained
    FROM dev_commands WHERE status='pending' AND coalesce(chain_reason,'') <> '';

  SELECT count(*), coalesce(sum(lines),0) INTO v_debt, v_debt_lines FROM god_file_debt;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'label', path,
           'detail', 'last hit ' || _ist_age(mx),
           'value_label', n || ' conflict' || CASE WHEN n=1 THEN '' ELSE 's' END,
           'tone', CASE WHEN n >= 3 THEN 'error' WHEN n >= 1 THEN 'warning' ELSE 'neutral' END)
         ORDER BY n DESC), '[]')
    INTO v_hot
  FROM (SELECT path, count(*) n, max(at) mx FROM lease_event
         WHERE kind IN ('conflict','deferred') AND at >= v_since
         GROUP BY path ORDER BY count(*) DESC LIMIT 8) h;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'label', '#' || id || ' · ' || left(_dev_title(title, build_log), 48),
           'detail', chain_reason,
           'value_label', 'waiting, not building',
           'tone', 'info') ORDER BY id), '[]')
    INTO v_chains
  FROM dev_commands WHERE status='pending' AND coalesce(chain_reason,'') <> '';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'label', path,
           'detail', reason,
           'value_label', to_char(lines, 'FM9,99,990') || ' lines',
           'tone', CASE WHEN lines >= 5000 THEN 'error' WHEN lines >= 2000 THEN 'warning' ELSE 'neutral' END)
         ORDER BY lines DESC), '[]')
    INTO v_debt_rows
  FROM (SELECT * FROM god_file_debt ORDER BY lines DESC LIMIT 8) g;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'label', fl.path,
           'detail', 'held by #' || fl.command_id || ' · ' || coalesce(fl.worker,'—'),
           'value_label', _ist_age(fl.leased_at),
           'tone', 'neutral') ORDER BY fl.leased_at), '[]')
    INTO v_live
  FROM file_leases fl;

  RETURN jsonb_build_object(
    'ok', true,
    'title', 'Build lane',
    'subtitle', 'Collisions are decided in SQL before a worker boots. A command whose files are already spoken for stays pending — it never claims, never loads a context, never parks mid-build.',
    'mode_label', CASE WHEN v_conf = 0 THEN 'NO COLLISIONS' ELSE 'COLLISIONS: ' || v_conf END,
    'mode_tone',  CASE WHEN v_conf = 0 THEN 'success' WHEN v_conf <= 2 THEN 'warning' ELSE 'error' END,
    'headline', jsonb_build_object(
      'label', CASE WHEN v_conf = 0
                 THEN 'No build waited on another build.'
                 ELSE v_conf || ' lease refusal' || CASE WHEN v_conf=1 THEN '' ELSE 's' END || ' in the last ' || p_days || ' days.' END,
      'detail', v_grant || ' files leased · ' || v_def || ' deferred and picked up later · '
                || v_chained || ' command' || CASE WHEN v_chained=1 THEN '' ELSE 's' END || ' auto-chained before claim',
      'tone', CASE WHEN v_conf = 0 THEN 'success' ELSE 'warning' END),
    'sections', jsonb_build_array(
      jsonb_build_object('heading', 'Auto-chained — queued, not parked',
        'empty_hint', 'Nothing is queued behind another command right now.',
        'rows', v_chains),
      jsonb_build_object('heading', 'Files held right now',
        'empty_hint', 'No worker is holding a file.',
        'rows', v_live),
      jsonb_build_object('heading', 'Most contended files',
        'empty_hint', 'No file has been fought over in this window.',
        'rows', v_hot),
      jsonb_build_object('heading', 'God-file debt — ' || v_debt || ' files, ' || to_char(v_debt_lines,'FM9,99,99,990') || ' lines',
        'empty_hint', 'No Dart file is over the threshold. Run scripts/god_files.sh to refresh.',
        'rows', v_debt_rows)),
    'window_label', 'Last ' || p_days || ' days');
END $$;
